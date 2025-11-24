# Board App Deploy 単発実行時の LoadBalancer 接続失敗

## 🔴 問題

Board App Deploy ワークフローを単発実行すると、デプロイ後の疎通確認で失敗する。

```
[3/4] LoadBalancer 経由で HTML を取得
❌ HTML 配信失敗
Error: Process completed with exit code 1.
```

## 📊 発生状況

- **発生日時**: 2025-11-24 06:01 (UTC)
- **Run ID**: 19626391893
- **Workflow**: 2️⃣ Board App Build & Deploy
- **トリガー**: push（単発実行）

### 症状

1. ✅ Pod: すべて Running
2. ✅ Service: ClusterIP で正常動作
3. ✅ Ingress: ADDRESS に LoadBalancer IP 割り当て済み
4. ✅ LoadBalancer IP: `4.190.96.0` 割り当て済み
5. ❌ LoadBalancer への HTTP 接続: タイムアウト

### ネットワーク診断結果

```powershell
Test-NetConnection -ComputerName 4.190.96.0 -Port 80

PingSucceeded     : True   # ICMP は通る
TcpTestSucceeded  : False  # TCP 接続失敗
```

## 🔍 根本原因

### LoadBalancer ヘルスプローブと Ingress Controller NodePort の不一致

| 項目                                       | 値                  | 状態                             |
| ------------------------------------------ | ------------------- | -------------------------------- |
| **LoadBalancer ヘルスプローブ**            | Port **30254**      | 古い値                           |
| **Ingress Controller HTTP NodePort**       | Port **32038**      | 新しい値                         |
| **Ingress Controller healthCheckNodePort** | Port **30254**      | Service 作成時に固定             |
| **結果**                                   | ❌ **ポート不一致** | すべてのバックエンドが Unhealthy |

### 発生メカニズム

1. **Infrastructure Deploy** (05:46)

   - AKS + Ingress Controller を作成
   - Ingress Controller Service が作成され、NodePort が割り当てられる
   - 例: HTTP NodePort = **32038**, healthCheckNodePort = **30254**
   - Azure LoadBalancer が自動作成され、ヘルスプローブが **Port 30254** で設定される

2. **Board App Deploy を単発実行** (06:01)

   - `helm upgrade --install ingress-nginx` を実行
   - Ingress Controller の Service が**再作成される**
   - 新しい NodePort が割り当てられる: HTTP = **32038** (変わる可能性あり)
   - **しかし**: healthCheckNodePort は Service 作成時に固定され、**30254 のまま**
   - **問題**: Azure LoadBalancer のヘルスプローブは古い Port 30254 を見続ける

3. **結果**
   - LoadBalancer は Port 30254 でヘルスチェック → **失敗**
   - すべてのバックエンドが「Unhealthy」と判定
   - トラフィックが転送されない

### Kubernetes の仕様

```yaml
apiVersion: v1
kind: Service
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local # この場合 healthCheckNodePort が自動割り当て
  healthCheckNodePort: 30254 # Service 作成時に固定（変更されない）
  ports:
    - name: http
      port: 80
      nodePort: 32038 # helm upgrade で変わる可能性がある
```

- `healthCheckNodePort`: Service 作成時に Kubernetes が自動割り当て（変更不可）
- `nodePort`: helm upgrade 時に変わる可能性がある
- Azure LoadBalancer Controller は `healthCheckNodePort` を使ってヘルスプローブを設定
- **NodePort が変わっても LoadBalancer のヘルスプローブは更新されない**

## 🔧 確認コマンド

### 1. Ingress Controller Service の情報確認

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller -o yaml | grep -E 'nodePort:|healthCheckNodePort:'
```

**期待される出力**:

```yaml
  healthCheckNodePort: 30254   # ← LoadBalancer はこのポートでヘルスチェック
  - nodePort: 32038            # ← 実際の HTTP トラフィックはこのポート
    nodePort: 31130            # ← HTTPS
```

### 2. LoadBalancer ヘルスプローブ確認

```bash
NODE_RG=$(az aks show --resource-group RG-bbs-app-demo --name aks-demo-dev --query nodeResourceGroup -o tsv)
az network lb probe list --resource-group $NODE_RG --lb-name kubernetes --query "[].{Name:name, Port:port}" -o table
```

**出力例**:

```
Name                                        Port
------------------------------------------  ------
a646537a12e5d4bcca7c58d86401aff4-TCP-30254  30254  # ← 古いポート番号
```

### 3. Service 作成日時確認

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.metadata.creationTimestamp}'
```

Infrastructure Deploy と Board App Deploy のタイムスタンプを比較すると、Board App Deploy 時に再作成されていることがわかる。

## ✅ 解決策

### 採用した解決策: Ingress Controller の既存チェック

Board App Deploy ワークフローで、既に Ingress Controller が存在する場合は `helm upgrade` をスキップする。

**メリット**:

- ✅ NodePort が変わらない（Service 再作成されない）
- ✅ ダウンタイムなし
- ✅ シンプルで安全

**実装**:

```bash
# Ingress Controller の既存確認
INGRESS_EXISTS=$(helm list -n ingress-nginx -q 2>/dev/null | grep -c "^ingress-nginx$" || echo "0")

if [ "$INGRESS_EXISTS" != "0" ]; then
  echo "✅ Ingress Controller は既に存在（スキップ）"
  # 既存設定を表示
  kubectl get svc -n ingress-nginx ingress-nginx-controller
else
  echo "🚀 Ingress Controller を新規インストール"
  helm upgrade --install ingress-nginx ...
fi
```

**変更ファイル**:

- `.github/workflows/2-board-app-build-deploy.yml`
  - Lines 1275-1390: "Ingress Controller (nginx) を確認/インストール" ステップ

### 他の解決策（未採用）

#### Option 2: NodePort 固定値設定

```bash
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --set controller.service.nodePorts.http=32080 \
  --set controller.service.nodePorts.https=32443 \
  --set controller.service.healthCheckNodePort=32254
```

**メリット**: 完全な予測可能性  
**デメリット**: Infrastructure Deploy でも設定が必要（管理コスト増）

#### Option 3: LoadBalancer の動的更新

NodePort 変更を検知して Azure LoadBalancer のヘルスプローブを更新。

**メリット**: 動的に対応  
**デメリット**: 複雑、タイミング問題が発生しやすい

## 📝 運用ガイドライン

### 正しいワークフロー実行順序

```bash
# 1. Infrastructure Deploy（初回 or インフラ変更時）
gh workflow run 1-infra-deploy.yml

# 2. 完了を確認してから Board App Deploy
gh workflow run 2-board-app-build-deploy.yml
```

### Board App Deploy 単発実行時の動作

- ✅ **既に Ingress Controller が存在**: スキップ（NodePort 保持）
- 🚀 **Ingress Controller が未存在**: 新規インストール

### トラブルシューティング

#### 症状: LoadBalancer に接続できない

```bash
# 1. NodePort とヘルスプローブの一致確認
kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.healthCheckNodePort}'
# → 例: 30254

NODE_RG=$(az aks show --resource-group <RG> --name <AKS> --query nodeResourceGroup -o tsv)
az network lb probe list --resource-group $NODE_RG --lb-name kubernetes --query "[].port" -o tsv
# → 例: 30254

# ポートが一致していない場合は修復が必要
```

#### 修復方法: Infrastructure Deploy を再実行

```bash
# 最もシンプルで確実な方法
gh workflow run 1-infra-deploy.yml
```

これにより、Ingress Controller が正しい順序で作成され、NodePort とヘルスプローブが一致します。

## 🔗 関連トラブルシューティング

- `2025-01-21-loadbalancer-healthprobe-nodeport-mismatch.md`: 同様の問題（初回発生）
- `2025-11-21-aks-loadbalancer-nodeport-mismatch.md`: NodePort 不一致の詳細分析

## 📚 参考リンク

- [Kubernetes Service - externalTrafficPolicy](https://kubernetes.io/docs/tasks/access-application-cluster/create-external-load-balancer/#preserving-the-client-source-ip)
- [Azure LoadBalancer Controller](https://learn.microsoft.com/en-us/azure/aks/load-balancer-standard)
- [Ingress-NGINX Helm Chart](https://github.com/kubernetes/ingress-nginx/tree/main/charts/ingress-nginx)
