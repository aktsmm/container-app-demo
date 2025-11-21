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

クラスタ内部から Ingress Controller に直接アクセスすると正常に動作する：

```bash
$ kubectl exec -n ingress-nginx deploy/ingress-nginx-controller -- curl -s localhost:80
<!DOCTYPE html>
<html lang="ja">
  <head>
    ...
  </head>
</html>
```

**結論**: アプリ自体は正常に動作しているが、外部からの通信経路に問題がある。

---

## 🔍 根本原因の詳細解説

### まず理解すべき Kubernetes の仕組み

#### Kubernetes Service の Type=LoadBalancer の動作

1. **NodePort の自動割り当て**

   - Kubernetes が Service を作成すると、各ノード（VM）に **ランダムなポート番号（30000-32767）** が割り当てられる
   - 例: `80:32170/TCP` → ポート 80 への通信を NodePort 32170 で受け付ける

2. **Azure LoadBalancer の自動作成**

   - AKS が Azure LoadBalancer を自動的に作成
   - LoadBalancer → ノードの特定ポートへトラフィックを転送

3. **問題が発生する条件**
   - Kubernetes の設定によって、Azure LB がどのポートに転送するかが変わる

---

### 具体的に何が起きていたか

#### 🔴 問題の状態（修正前）

```
インターネット
    ↓ (http://20.89.34.202:80)
Azure LoadBalancer (Frontend IP: 20.89.34.202)
    ↓ LoadBalancing Rule: FrontendPort=80 → BackendPort=80 ❌
AKS ノード（VM）
    ↓ ポート 80 で待ち受けているプロセスがない！
    ✅ 実際は NodePort 32170 でリッスン中
    ↓
Ingress Controller Pod
```

**問題点**: Azure LB がポート 80 にトラフィックを送信しているが、ノード（VM）はポート 32170 でしか受け付けていない。

#### ✅ 正常な状態（修正後）

```
インターネット
    ↓ (http://20.89.34.202:80)
Azure LoadBalancer (Frontend IP: 20.89.34.202)
    ↓ LoadBalancing Rule: FrontendPort=80 → BackendPort=32170 ✅
AKS ノード（VM）
    ↓ NodePort 32170 で受信
    ↓
Ingress Controller Pod
```

**解決**: Azure LB が正しい NodePort 32170 にトラフィックを送信するようになった。

---

### externalTrafficPolicy の役割

Kubernetes Service には `externalTrafficPolicy` という設定があり、外部トラフィックの処理方法を決定します。

#### 1️⃣ externalTrafficPolicy: Cluster（デフォルト）

```
インターネット → Azure LB → 任意のノード → kube-proxy が転送 → Pod
                          ↓
                  ポート番号は "通常のポート" (80, 443)
                  Azure LB は固定ポート 80 に送信 ❌
```

**特徴**:

- **メリット**: すべてのノードで受信可能、負荷分散が均等
- **デメリット**: Azure LB が NodePort を認識しない → ポート番号が一致しない
- **AKS での問題**: Azure は「ポート 80」に送信するが、実際は「NodePort 32170」でリッスン

#### 2️⃣ externalTrafficPolicy: Local（今回の解決策）

```
インターネット → Azure LB → 実際に Pod が動いているノード → 直接 Pod へ
                          ↓
                  NodePort (32170) を使用
                  Azure LB が自動検出して正しいポート番号に送信 ✅
```

**特徴**:

- **メリット**: Azure LB が NodePort を自動検出、ポート番号が一致
- **デメリット**: Pod が存在するノードのみトラフィックを受信（若干の偏り）
- **AKS での効果**: Azure は「NodePort 32170」に送信 → 通信成功

---

### なぜ Azure だけこの問題が起きるのか

#### 他のクラウドプロバイダー

- **AWS ELB/NLB**: NodePort を自動検出して正しく設定される
- **GCP Load Balancer**: NodePort を自動検出して正しく設定される

#### Azure LoadBalancer の特性

- **externalTrafficPolicy=Cluster の場合**:
  - Azure LB は Service に定義された「通常のポート」（80, 443）をそのまま BackendPort に設定
  - NodePort の存在を認識しない
- **externalTrafficPolicy=Local の場合**:
  - Azure Cloud Controller Manager が NodePort を検出
  - LoadBalancer Rule の BackendPort を自動的に NodePort に設定

**結論**: Azure では `externalTrafficPolicy: Local` が **必須**。

---

## ✅ 解決策の詳細

### 実際に行った修正

#### 実際の LoadBalancer Rule（修正前）

```bash
$ az network lb rule list --output table

Name       FrontendPort  BackendPort  Protocol
---------  ------------  -----------  --------
Rule-80    80            80           Tcp      ❌ ポート不一致
Rule-443   443           443          Tcp      ❌ ポート不一致
```

#### 実際の NodePort（確認）

```bash
$ kubectl get svc ingress-nginx-controller -n ingress-nginx

NAME                       PORT(S)
ingress-nginx-controller   80:32170/TCP,443:30600/TCP
                           ↑  ↑
                       公開  NodePort（実際にリッスンしているポート）
```

#### 期待される LoadBalancer Rule（修正後）

```bash
Name       FrontendPort  BackendPort  Protocol
---------  ------------  -----------  --------
Rule-80    80            32170        Tcp      ✅ NodePort と一致
Rule-443   443           30600        Tcp      ✅ NodePort と一致
```

---

## 🛠️ 解決策：ワークフローでの修正内容

### 1. externalTrafficPolicy=Local を設定

Helm で Ingress Controller をインストール/アップグレードする際に `externalTrafficPolicy=Local` を追加。

#### `.github/workflows/3-deploy-board-app.yml` の修正

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

**重要なポイント**:

- `--set controller.service.externalTrafficPolicy=Local`: Azure LB が NodePort を自動検出
- `--wait --timeout=5m`: デプロイが完全に完了するまで待機
- ヘルスプローブパス: Azure LB が Pod の健全性を `/healthz` エンドポイントで確認

### 2. Helm リポジトリの事前追加（補足）

`helm upgrade` 実行前に Helm リポジトリを追加しないと "Error: repo ingress-nginx not found" エラーが発生します。

```bash
# Helm リポジトリを追加・更新（upgrade/install 両パスで必要）
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
helm repo update
```

### 3. Helm ロック状態の自動解除（補足）

GitHub Actions が中断された場合、Helm リリースがロック状態のまま残ることがあります。これを自動的に解除します。

```bash
# Helm ロック状態を事前にチェック・解除
if kubectl get secret -n ingress-nginx | grep -q 'sh\.helm\.release\.v1\.ingress-nginx'; then
  HELM_STATUS=$(helm status ingress-nginx -n ingress-nginx -o json 2>/dev/null | jq -r '.info.status' || echo "unknown")
  if [[ "$HELM_STATUS" == "pending-install" || "$HELM_STATUS" == "pending-upgrade" || "$HELM_STATUS" == "pending-rollback" ]]; then
    echo "⚠️  Helm リリースがロック状態（$HELM_STATUS）です。ロックを解除します"
    helm rollback ingress-nginx 0 -n ingress-nginx --wait=false || kubectl delete secret -n ingress-nginx -l owner=helm,name=ingress-nginx,status=pending-install || true
    sleep 5
  fi
fi
```

---

## 🔬 修正の効果を確認する方法

### ステップ 1: Service の externalTrafficPolicy を確認

```bash
$ kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.externalTrafficPolicy}'
Local  ✅
```

### ステップ 2: Azure LoadBalancer Rule を確認

```bash
$ az network lb rule list --resource-group mc-RG-bbs-app-demodemo --lb-name kubernetes --output table

Name       FrontendPort  BackendPort  Protocol
---------  ------------  -----------  --------
Rule-80    80            32170        Tcp      ✅ NodePort と一致！
Rule-443   443           30600        Tcp      ✅ NodePort と一致！
```

### ステップ 3: 外部アクセスをテスト

```bash
$ curl -I http://20.89.34.202/
HTTP/1.1 200 OK
Server: nginx/1.14.0
Content-Type: text/html
✅ 成功！
```

---

## 🛠️ ワークフローでの修正内容（diff 形式）

### `.github/workflows/3-deploy-board-app.yml`

-
-          # Helm ロック状態を事前にチェック・解除
-          if kubectl get secret -n ingress-nginx | grep -q 'sh\.helm\.release\.v1\.ingress-nginx'; then
-            HELM_STATUS=$(helm status ingress-nginx -n ingress-nginx -o json 2>/dev/null | jq -r '.info.status' || echo "unknown")
-            if [[ "$HELM_STATUS" == "pending-install" || "$HELM_STATUS" == "pending-upgrade" || "$HELM_STATUS" == "pending-rollback" ]]; then
-              echo "⚠️  Helm リリースがロック状態（$HELM_STATUS）です。ロックを解除します"
-              helm rollback ingress-nginx 0 -n ingress-nginx --wait=false || kubectl delete secret -n ingress-nginx -l owner=helm,name=ingress-nginx,status=pending-install || true
-              sleep 5
-            fi
-          fi
-           if kubectl get ns ingress-nginx >/dev/null 2>&1; then
              echo "既に ingress-nginx Namespace が存在します。Service を再作成して LoadBalancer 設定を修正します";
              helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
                --namespace ingress-nginx \
                --reuse-values \
-              --set controller.service.externalTrafficPolicy=Local \
-              --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
-              --wait --timeout=5m
           else
             helm install ingress-nginx ingress-nginx/ingress-nginx \
               --namespace ingress-nginx \
               --create-namespace \
               --set controller.replicaCount=1 \
-              --set controller.service.externalTrafficPolicy=Local \
-              --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
-              --wait --timeout=5m
           fi

```

---

## 💡 まとめ：なぜこの修正で動くようになったのか

### 問題の本質

1. **Kubernetes は NodePort を使う**
   - Service Type=LoadBalancer では、各ノードに 30000-32767 のランダムポートが割り当てられる
   - 例: ポート 80 → NodePort 32170

2. **Azure LoadBalancer は設定次第**
   - `externalTrafficPolicy=Cluster`: 固定ポート 80 を使用（デフォルト）❌
   - `externalTrafficPolicy=Local`: NodePort 32170 を自動検出 ✅

3. **ポート番号が一致しないと通信できない**
   - Azure LB がポート 80 に送信 → ノードはポート 32170 でリッスン → タイムアウト

### 修正のポイント

✅ **`externalTrafficPolicy: Local` を設定**
- Azure Cloud Controller Manager が NodePort を検出
- LoadBalancer Rule の BackendPort を自動的に NodePort (32170) に設定
- 外部トラフィックが正しいポートに到達

### 簡単な例え

```

❌ 修正前
宅配便（Azure LB）: 「80 号室にお届けします」
受取人（ノード）: 「私は 32170 号室にいます」
→ 届かない

✅ 修正後
宅配便（Azure LB）: 「32170 号室ですね、確認しました」
受取人（ノード）: 「はい、32170 号室です」
→ 届く

````

---

## 📊 ワークフロー実行履歴

### 修正前

| Run ID      | Workflow         | Status     | Error                            |
| ----------- | ---------------- | ---------- | -------------------------------- |
| 19541832257 | Deploy Board App | ✅ Success | デプロイ成功だが外部アクセス不能 |

### 修正後（externalTrafficPolicy 追加）

| Run ID      | Workflow         | Status     | Error                                 |
| ----------- | ---------------- | ---------- | ------------------------------------- |
| 19542484257 | Build Board App  | ✅ Success | 2m53s                                 |
| 19542572709 | Deploy Board App | ❌ Failed  | `Error: repo ingress-nginx not found` |

### 修正後（Helm repo 追加）

| Run ID      | Workflow         | Status     | Error |
| ----------- | ---------------- | ---------- | ----- |
| 19542670702 | Build Board App  | ✅ Success | 2m17s |
| 19542754586 | Deploy Board App | ✅ Success | 2m46s |

---

## 🎓 技術的な学び

### 1. Azure は他のクラウドと動作が違う

**AWS や GCP では externalTrafficPolicy を意識しなくても動く**が、Azure では明示的に `Local` を設定する必要があります。

| クラウド | externalTrafficPolicy=Cluster | externalTrafficPolicy=Local |
|---------|------------------------------|----------------------------|
| AWS ELB/NLB | NodePort を自動検出 ✅ | NodePort を使用 ✅ |
| GCP LB | NodePort を自動検出 ✅ | NodePort を使用 ✅ |
| Azure LB | 固定ポート使用 ❌ | NodePort を自動検出 ✅ |

**結論**: AKS では `externalTrafficPolicy: Local` が **ほぼ必須**。

### 2. Helm の --wait と --timeout は重要

Helm でリソースをデプロイする際、`--wait` を付けないと Pod が起動する前にワークフローが終了してしまいます。

```bash
# ❌ ダメな例（Pod が起動する前に終了）
helm install ingress-nginx ingress-nginx/ingress-nginx

# ✅ 良い例（完全にデプロイされるまで待機）
helm install ingress-nginx ingress-nginx/ingress-nginx --wait --timeout=5m
````

### 3. Helm リポジトリは常に最新化

CI/CD 環境では、Helm リポジトリが登録されていない可能性があります。

```bash
# upgrade でもリポジトリ追加が必要
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
helm repo update
```

### 4. Helm のロック状態に注意

GitHub Actions が中断すると、Helm リリースがロック状態のまま残ります。

**対策**: ワークフロー内で自動検出・解除する処理を追加。

```bash
HELM_STATUS=$(helm status ingress-nginx -n ingress-nginx -o json 2>/dev/null | jq -r '.info.status')
if [[ "$HELM_STATUS" == "pending-install" ]]; then
  helm rollback ingress-nginx 0 -n ingress-nginx --wait=false || kubectl delete secret ...
fi
```

---

## 💡 教訓

### 重要なポイント

1. **AKS では externalTrafficPolicy=Local を使う**

   - Azure LoadBalancer が NodePort を正しく検出するために必須

2. **Helm のベストプラクティスを守る**

   - `--wait --timeout` でデプロイ完了を待機
   - リポジトリは毎回 `helm repo update` で最新化

3. **CI/CD のロバスト化**

   - Helm ロック状態の自動解除処理を追加
   - エラーハンドリングを充実させる

4. **問題は段階的に解決**
   - 今回は 3 回のコミットで完全解決
   - 1 回目: externalTrafficPolicy 追加
   - 2 回目: Helm リポジトリ追加
   - 3 回目: ロック解除処理追加

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
