# AKS LoadBalancer の BackendPort と NodePort 不一致による外部アクセス不能

**日時**: 2025-11-21  
**対象リソース**: AKS (Azure Kubernetes Service), Azure LoadBalancer, Ingress Controller  
**エラー**: `Connection timed out` when accessing LoadBalancer IP

---

## 📌 問題の概要

AKS 上の Board App に外部から LoadBalancer IP（20.89.34.202）経由でアクセスしようとすると、`Connection timed out` エラーが発生した。

### 症状

```bash
$ curl http://20.89.34.202/
curl: (28) Connection timed out after 10010 milliseconds
```

### 内部からのアクセスは正常

```bash
$ kubectl exec -n ingress-nginx deploy/ingress-nginx-controller -- curl -s localhost:80
<!DOCTYPE html>
<html lang="ja">
  <head>
    ...
  </head>
</html>
```

---

## 🔍 根本原因

### 1. Azure LoadBalancer Rule の BackendPort が誤っている

Azure LoadBalancer の LoadBalancing Rule で、**BackendPort が 80** に設定されているが、実際の Kubernetes Service の **NodePort は 32170** だった。

#### 実際の LoadBalancer Rule

```bash
$ az network lb rule list --resource-group mc-RG-bbs-app-demodemo --lb-name kubernetes --output table

Name                              FrontendPort  BackendPort  Protocol  LoadDistribution
--------------------------------  ------------  -----------  --------  ----------------
ad3becb35f6ee4efb96b384ecf56d002  80            80           Tcp       Default
ad3becb35f6ee4efb96b384ecf56d002  443           443          Tcp       Default
```

#### 実際の NodePort

```bash
$ kubectl get svc ingress-nginx-controller -n ingress-nginx -o wide

NAME                       TYPE           EXTERNAL-IP    PORT(S)                      NODE-PORT
ingress-nginx-controller   LoadBalancer   20.89.34.202   80:32170/TCP,443:30600/TCP   ...
```

**問題**: Azure LB は Port 80 にトラフィックを送信するが、実際には NodePort 32170 でリッスンしているため、接続が失敗する。

---

### 2. externalTrafficPolicy のデフォルト値

Kubernetes Service の `externalTrafficPolicy` がデフォルトで **Cluster** に設定されていた。

#### Cluster vs Local の違い

| 設定 | 動作 | Azure LB の BackendPort |
|------|------|-------------------------|
| **Cluster** (デフォルト) | kube-proxy が任意ノードの任意ポートで受信可能 | 固定ポート (80, 443) を使用 |
| **Local** | トラフィックはローカルノードの NodePort のみ | NodePort を自動検出して使用 |

**結論**: `externalTrafficPolicy: Local` を設定すると、Azure は正しい NodePort (32170, 30600) を LoadBalancer Rule に設定する。

---

## ✅ 解決策

### 1. Helm で externalTrafficPolicy=Local を設定

`.github/workflows/3-deploy-board-app.yml` の Ingress Controller インストール/アップグレード時に `externalTrafficPolicy=Local` を追加。

#### 修正前のコード

```yaml
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.replicaCount=1
```

#### 修正後のコード

```yaml
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.replicaCount=1 \
  --set controller.service.externalTrafficPolicy=Local \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
  --wait --timeout=5m
```

### 2. Helm リポジトリの事前追加

`helm upgrade` 時に "Error: repo ingress-nginx not found" エラーが発生したため、upgrade パスでも Helm リポジトリを追加するように修正。

```yaml
# Helm リポジトリを追加・更新（upgrade/install 両パスで必要）
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
helm repo update
```

### 3. Helm ロック状態の自動解除

CI/CD の中断やタイムアウトで Helm リリースがロック状態（`pending-install`, `pending-upgrade`, `pending-rollback`）になることがあるため、自動解除処理を追加。

```bash
# Helm ロック状態を事前にチェック・解除
if kubectl get secret -n ingress-nginx | grep -q 'sh\.helm\.release\.v1\.ingress-nginx'; then
  echo "Helm リリースの状態を確認します"
  HELM_STATUS=$(helm status ingress-nginx -n ingress-nginx -o json 2>/dev/null | jq -r '.info.status' || echo "unknown")
  if [[ "$HELM_STATUS" == "pending-install" || "$HELM_STATUS" == "pending-upgrade" || "$HELM_STATUS" == "pending-rollback" ]]; then
    echo "⚠️  Helm リリースがロック状態（$HELM_STATUS）です。ロックを解除します"
    helm rollback ingress-nginx 0 -n ingress-nginx --wait=false || kubectl delete secret -n ingress-nginx -l owner=helm,name=ingress-nginx,status=pending-install || true
    sleep 5
  fi
fi
```

---

## 🛠️ 修正対象ファイル

### `.github/workflows/3-deploy-board-app.yml`

```diff
       - name: Ingress Controller (nginx) を確認/インストール
         run: |
           set -euo pipefail
+          # Helm リポジトリを追加・更新（upgrade/install 両パスで必要）
+          helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
+          helm repo update
+
+          # Helm ロック状態を事前にチェック・解除
+          if kubectl get secret -n ingress-nginx | grep -q 'sh\.helm\.release\.v1\.ingress-nginx'; then
+            HELM_STATUS=$(helm status ingress-nginx -n ingress-nginx -o json 2>/dev/null | jq -r '.info.status' || echo "unknown")
+            if [[ "$HELM_STATUS" == "pending-install" || "$HELM_STATUS" == "pending-upgrade" || "$HELM_STATUS" == "pending-rollback" ]]; then
+              echo "⚠️  Helm リリースがロック状態（$HELM_STATUS）です。ロックを解除します"
+              helm rollback ingress-nginx 0 -n ingress-nginx --wait=false || kubectl delete secret -n ingress-nginx -l owner=helm,name=ingress-nginx,status=pending-install || true
+              sleep 5
+            fi
+          fi
+
           if kubectl get ns ingress-nginx >/dev/null 2>&1; then
             echo "既に ingress-nginx Namespace が存在します。Service を再作成して LoadBalancer 設定を修正します";
             helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
               --namespace ingress-nginx \
               --reuse-values \
+              --set controller.service.externalTrafficPolicy=Local \
+              --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
+              --wait --timeout=5m
           else
             helm install ingress-nginx ingress-nginx/ingress-nginx \
               --namespace ingress-nginx \
               --create-namespace \
               --set controller.replicaCount=1 \
+              --set controller.service.externalTrafficPolicy=Local \
+              --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
+              --wait --timeout=5m
           fi
```

---

## 🎯 検証手順

### 1. Service の externalTrafficPolicy を確認

```bash
$ kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.externalTrafficPolicy}'
Local
```

### 2. Azure LoadBalancer Rule を確認

```bash
$ az network lb rule list --resource-group mc-RG-bbs-app-demodemo --lb-name kubernetes --output table

Name                              FrontendPort  BackendPort  Protocol
--------------------------------  ------------  -----------  --------
ad3becb35f6ee4efb96b384ecf56d002  80            32170        Tcp
ad3becb35f6ee4efb96b384ecf56d002  443           30600        Tcp
```

✅ **BackendPort が NodePort と一致**

### 3. 外部アクセステスト

```bash
$ curl -I http://20.89.34.202/
HTTP/1.1 200 OK
Server: nginx/1.14.0
Content-Type: text/html
```

✅ **外部からのアクセス成功**

---

## 📊 ワークフロー実行履歴

### 修正前

| Run ID | Workflow | Status | Error |
|--------|----------|--------|-------|
| 19541832257 | Deploy Board App | ✅ Success | デプロイ成功だが外部アクセス不能 |

### 修正後（externalTrafficPolicy 追加）

| Run ID | Workflow | Status | Error |
|--------|----------|--------|-------|
| 19542484257 | Build Board App | ✅ Success | 2m53s |
| 19542572709 | Deploy Board App | ❌ Failed | `Error: repo ingress-nginx not found` |

### 修正後（Helm repo 追加）

| Run ID | Workflow | Status | Error |
|--------|----------|--------|-------|
| 19542670702 | Build Board App | ✅ Success | 2m17s |
| 19542754586 | Deploy Board App | ✅ Success | 2m46s |

---

## 💡 教訓

### 1. Kubernetes と Azure LoadBalancer の相互作用

Kubernetes Service の `externalTrafficPolicy` 設定が Azure LoadBalancer の動作に直接影響する。

- **Cluster**: kube-proxy が DNAT を使用し、任意ノードで受信可能。Azure LB は固定ポートを使用。
- **Local**: トラフィックはローカルノードの NodePort のみ。Azure LB は NodePort を自動検出。

### 2. Helm upgrade 時のリポジトリ要件

`helm upgrade` を実行する際も、Helm リポジトリが登録されている必要がある。`helm install` だけでなく `helm upgrade` パスでも `helm repo add` を実行する。

### 3. Helm ロック状態の自動解除

GitHub Actions の中断やタイムアウトで Helm リリースがロック状態になることがある。ワークフロー内で自動検出・解除する処理を追加することで、手動介入を不要にする。

### 4. --wait と --timeout の重要性

`helm install/upgrade` に `--wait --timeout=5m` を追加することで、リソースが完全にデプロイされるまで待機し、不完全な状態でワークフローが終了するのを防ぐ。

---

## 🔗 関連リソース

- [Kubernetes Service externalTrafficPolicy](https://kubernetes.io/docs/tasks/access-application-cluster/create-external-load-balancer/#preserving-the-client-source-ip)
- [Azure Load Balancer と AKS の統合](https://learn.microsoft.com/ja-jp/azure/aks/load-balancer-standard)
- [NGINX Ingress Controller - Azure](https://kubernetes.github.io/ingress-nginx/deploy/#azure)
- [Helm Rollback](https://helm.sh/docs/helm/helm_rollback/)

---

## 📝 コミット履歴

```bash
# 1回目の修正（externalTrafficPolicy=Local 追加）
git commit -m "fix: Ingress Controller に externalTrafficPolicy=Local を設定して Azure LB の NodePort 不一致を解消"

# 2回目の修正（Helm repo 追加）
git commit -m "fix: helm upgrade 前に helm repo add を実行"

# 3回目の修正（Helm ロック自動解除）
git commit -m "feat: Helm ロック状態を自動検出・解除する処理を追加"
```

---

## 🚀 今後の対策

1. **externalTrafficPolicy=Local の標準化**: すべての LoadBalancer Service で Local を使用
2. **Health Probe の明示的設定**: Azure LB のヘルスチェックパスを `/healthz` に設定
3. **Helm ベストプラクティス**: `--wait --timeout` を常に指定
4. **CI/CD のロバスト化**: ロック状態の自動検出・解除を標準化

---

**関連トラブルシューティング**:

- [2025-11-20-workflow-run-http-403.md](./2025-11-20-workflow-run-http-403.md)
- [2025-11-20-managed-identity-migration.md](./2025-11-20-managed-identity-migration.md)
