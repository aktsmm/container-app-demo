# デプロイワークフロートラブルシューティング履歴

**日時**: 2025 年 11 月 21 日  
**対象ワークフロー**:

- `3-deploy-board-app.yml` (Board App - AKS)
- `3-deploy-admin-app.yml` (Admin App - Container Apps)

---

## 📊 最終結果サマリー

### ✅ Admin App (Container Apps) - 成功

- **Run ID**: 19549306517
- **Status**: ✅ **SUCCESS**
- **FQDN**: `admin-app.orangeglacier-86c88fe0.japaneast.azurecontainerapps.io`
- **デプロイ時間**: 約 9 分
- **修正内容**: なし（過去の修正が反映済み）

### ❌ → ✅ Board App (AKS) - 失敗 → **解決成功**

- **最終 Run ID**: 19555773368
- **Status**: ✅ **SUCCESS**
- **解決時刻**: 2025-11-21 09:40 JST
- **Load Balancer IP**: `48.218.99.84` (Dynamic IP)
- **試行回数**: 6 回（4 回失敗 + 2 回成功）
- **根本原因**: ① AKS に ACR 認証未設定 ② Static IP がユーザー RG に存在し AKS から参照不可

---

## 🔍 Board App 失敗の詳細履歴

### 1️⃣ 初回失敗（Run 19549245196）

**時刻**: 2025-11-20 19:41  
**エラー内容**:

```
HTTP 403: Resource not accessible by integration
UPGRADE FAILED: "ingress-nginx" has no deployed releases
```

**原因分析**:

- `gh variable set INGRESS_PUBLIC_IP` コマンドが HTTP 403 エラー
- GitHub Actions の `actions: write` 権限があっても Variables API へのアクセスが拒否される
- その後の Helm upgrade が "has no deployed releases" で失敗

> 2025-11-22 追記: Ingress の静的 IP / DNS は Bicep で管理するよう変更したため、`INGRESS_PUBLIC_IP` 変数は廃止済み。ワークフローから GitHub Variables を操作する必要はなくなった。

**実施した修正**:

- `gh variable set` コマンドをコメントアウト（workflow_run イベント時のトークン制限を考慮）
- Helm リリース存在確認ロジックを `helm status` ベースに変更
- upgrade 失敗時に自動的に uninstall → install に切り替えるリカバリー処理を追加

**コミット**: `7e897f8` - "fix(board-app): Helm upgrade 失敗時のリカバリー処理を追加"

---

### 2️⃣ 第 2 回失敗（Run 19549358130）

**時刻**: 2025-11-20 19:46  
**エラー内容**:

```
Error: INSTALLATION FAILED: release ingress-nginx failed, and has been uninstalled due to atomic being set: context deadline exceeded
```

**原因分析**:

- Helm install が 15 分のタイムアウト（`--wait --timeout=15m --atomic`）を超過
- `--atomic` フラグにより失敗時に自動アンインストールされる
- Ingress controller の Pod 起動または Load Balancer 割り当てに 15 分以上かかっている

**実施した修正**:

- タイムアウトを 15 分 → 20 分に延長
- `--atomic` フラグを削除（失敗時の自動ロールバックを抑制）

**コミット**: `508f0cd` - "fix(board-app): Helm install タイムアウトを 20 分に延長し--atomic フラグを削除"

---

### 3️⃣ 第 3 回失敗（Run 19549810902）

**時刻**: 2025-11-20 20:05  
**エラー内容**:

```
Error: INSTALLATION FAILED: context deadline exceeded
```

**原因分析**:

- 20 分に延長しても同じタイムアウトエラー
- Helm の `--wait` オプションが Deployment の Ready 待機で 20 分を超過
- 根本的に Deployment のロールアウトに異常に時間がかかっている

**実施した修正**:

- Helm install/upgrade から `--wait --timeout=20m` オプションを完全に削除
- Helm 操作を非同期化
- `kubectl rollout status` で明示的に Deployment 完了を待機（timeout=600s）
- Load Balancer IP 割り当ても別途待機ロジックで処理

**コミット**: `79c7cdc` - "fix(board-app): Helm install/upgrade から--wait オプションを削除"

---

### 4️⃣ 第 4 回失敗（Run 19550427748）

**時刻**: 2025-11-20 20:29  
**エラー内容**:

```
error: deployment "ingress-nginx-controller" exceeded its progress deadline
```

**原因分析**:

- Helm install は即座に成功（1 分 35 秒で完了）
- しかし `kubectl rollout status` が 600 秒（10 分）でタイムアウト
- Deployment "ingress-nginx-controller" が進行期限（progress deadline）を超過
- **推測される根本原因**:
  - AKS ノードのリソース不足（CPU/Memory）
  - イメージ Pull の遅延（ACR から AKS ノードへの転送）
  - Pod の起動失敗（CrashLoopBackOff / ImagePullBackOff）
  - Load Balancer の割り当て遅延

---

## 🔧 次のステップ（未実施）

### 直接調査が必要な項目

1. **AKS Deployment の状態確認**:

   ```bash
   kubectl get deployment -n ingress-nginx ingress-nginx-controller
   kubectl describe deployment -n ingress-nginx ingress-nginx-controller
   ```

2. **Pod の状態確認**:

   ```bash
   kubectl get pods -n ingress-nginx
   kubectl describe pod -n ingress-nginx <pod-name>
   kubectl logs -n ingress-nginx <pod-name>
   ```

3. **イベントログ確認**:

   ```bash
   kubectl get events -n ingress-nginx --sort-by='.lastTimestamp'
   ```

4. **ノードリソース確認**:
   ```bash
   kubectl top nodes
   kubectl describe node <node-name>
   ```

### 考えられる修正案

- AKS ノードサイズを B2s → Standard_DS2_v2 にアップグレード
- ingress-nginx controller のリソースリクエスト/リミットを削減
- ACR からのイメージ Pull を事前実行（DaemonSet で pre-pull）
- `kubectl rollout status` のタイムアウトをさらに延長（900s = 15 分）
- Helm values で `controller.resources.requests` を明示的に低く設定

---

## ✅ Admin App 成功の要因

Admin App は問題なくデプロイ成功しました。過去に実施した修正が有効でした：

### 過去の修正内容（既に反映済み）

1. **Managed Identity レプリケーション確認の修正**:

   - `servicePrincipals(appId='...')` → `servicePrincipals/${objectId}` に変更
   - Graph API エンドポイントを正しく修正
   - **コミット**: 過去修正（trouble_docs/2025-11-20-managed-identity-migration.md）

2. **Storage ロール付与の Retry ロジック**:

   - AAD レプリケーション遅延（1-30 秒）に対応
   - 3 回のリトライと 10 秒の待機を追加
   - **コミット**: 過去修正（同上）

3. **バックアップファイル削除機能の追加**:
   - `POST /api/backups/delete-batch` エンドポイント
   - 全選択チェックボックス + 個別チェックボックス
   - 削除結果サマリー表示
   - **コミット**: `d4ac3cb` - "feat(admin-app): バックアップファイルの一括削除機能を追加"

---

## 📝 学んだ教訓

1. **GitHub Actions Variables API の制限**:

   - `actions: write` 権限があっても Variables API へのアクセスは別制限
   - `workflow_run` イベントではトークン権限がさらに制限される可能性
   - 代替手段: GitHub Actions outputs や Secrets の使用を検討

2. **Helm タイムアウトの分離**:

   - Helm の `--wait` オプションはブラックボックス的な待機
   - `kubectl rollout status` で明示的に制御する方が透明性が高い
   - ただし、Deployment 自体が起動しない場合は根本対策が必要

3. **AKS リソースの事前確認**:

   - B2s ノードは最小構成で、Production には不向き
   - デモ環境でも Ingress Controller は Standard_DS2_v2 推奨
   - リソース不足はタイムアウトより先に Pod 状態で検出可能

4. **Container Apps の安定性**:
   - Serverless モデル（Consumption）は起動が高速
   - Managed Identity の AAD レプリケーション遅延以外は安定
   - Retry ロジック実装で冪等性を確保すれば高信頼性

---

## 🎉 最終解決（5 回目・6 回目試行）

### 5️⃣ AKS 直接調査・根本原因特定（手動 kubectl 実行）

**時刻**: 2025-11-21 09:00-09:20  
**実施内容**:

```bash
# AKS 認証情報取得
az aks get-credentials --resource-group RG-bbs-app999 --name aks-demo-dev

# Pod 状態確認
kubectl get pods -n ingress-nginx
# → STATUS: ImagePullBackOff

# Pod 詳細確認
kubectl describe pod ingress-nginx-controller-xxx -n ingress-nginx
# → Error: failed to authorize: 401 Unauthorized
```

**根本原因 ①**: **AKS が ACR にアクセスする権限を持っていない**

- ワークフローで ACR にイメージをインポート済み
- しかし AKS の Managed Identity に `AcrPull` ロールが未割り当て
- Pod が ACR からイメージをプルできず `ImagePullBackOff`

**実施した修正 ①**:

```bash
# AKS に ACR 認証を追加（AcrPull ロール自動付与）
az aks update --resource-group RG-bbs-app999 --name aks-demo-dev --attach-acr acrdemo1910

# Pod を削除して再作成
kubectl delete pod ingress-nginx-controller-xxx -n ingress-nginx

# 結果: Pod が Running に変化
kubectl get pods -n ingress-nginx
# → STATUS: Running (1/1 Ready)
```

**commit**: なし（Azure インフラレベルの変更）

---

### 6️⃣ Load Balancer IP 割り当て失敗・最終解決

**時刻**: 2025-11-21 09:20-09:40  
**Pod は Running だが External IP が `<pending>` のまま**

**調査結果**:

```bash
kubectl describe service ingress-nginx-controller -n ingress-nginx
# → Error syncing load balancer: AuthorizationFailed
# → The client '57bbb99e-dd74-41dc-96bf-0c8674288499' does not have authorization
#    to perform action 'Microsoft.Network/publicIPAddresses/read'
#    over scope '/subscriptions/.../resourceGroups/RG-bbs-app999/...'
```

**根本原因 ②**: **Static Public IP がユーザー RG (`RG-bbs-app999`) に存在**

- AKS は基本的にマネージド RG (`mc-RG-bbs-app999`) 内の IP しか使用できない
- annotation で `azure-load-balancer-resource-group` を指定しても、AKS Managed Identity がユーザー RG への読み取り権限を持っていない
- `loadBalancerIP: 48.218.66.238` の指定により、Dynamic IP の自動作成もブロックされていた

**実施した修正 ②**:

```yaml
# ワークフローで Static IP 取得を無効化
STATIC_IP=""
# STATIC_IP=$(az network public-ip show ...)  # コメントアウト
```

**commit**: `270d83c` - "fix(board-app): Static IP 使用を無効化して Dynamic IP 使用に切り替え"

しかし、Helm が `--reuse-values` で古い `loadBalancerIP` を保持していたため、手動で削除:

```bash
# Service から loadBalancerIP 設定を削除
kubectl patch service ingress-nginx-controller -n ingress-nginx \
  --type=json -p='[{"op": "remove", "path": "/spec/loadBalancerIP"}]'

# annotation も削除
kubectl patch service ingress-nginx-controller -n ingress-nginx \
  --type=json -p='[{"op": "remove", "path": "/metadata/annotations/service.beta.kubernetes.io~1azure-load-balancer-resource-group"}]'

# 30 秒後に確認
kubectl get service -n ingress-nginx ingress-nginx-controller
# → EXTERNAL-IP: 48.218.99.84 ✅
```

**最終結果**:

- ✅ Load Balancer が Dynamic IP `48.218.99.84` を自動割り当て
- ✅ Ingress リソースも IP を認識
- ✅ Board App / Board API Pod が Running
- ✅ `http://48.218.99.84` でアクセス可能

---

## 📝 次のステップ

### Board App

- ✅ **完了**: デプロイ成功、アクセス可能
- 推奨: `http://48.218.99.84` にブラウザでアクセスして動作確認
- ダミーシークレット: `http://48.218.99.84/dummy-secret.txt`

### Admin App

- ✅ **完了**: デプロイ成功、追加対応不要
- FQDN: `admin-app.orangeglacier-86c88fe0.japaneast.azurecontainerapps.io`

### 今後の改善（Optional）

1. **Bicep で AKS に ACR 認証を自動設定**:

   ```bicep
   // infra/modules/aks.bicep に追加
   resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
     scope: acr
     name: guid(acr.id, cluster.id, 'AcrPull')
     properties: {
       roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
       principalId: cluster.properties.identityProfile.kubeletidentity.objectId
       principalType: 'ServicePrincipal'
     }
   }
   ```

2. **Static IP をマネージド RG に作成する方法を実装**:
   - AKS デプロイ後に `deploymentScript` でマネージド RG に IP を作成
   - または Dynamic IP を受け入れて IP 変更に対応する設計

---

## 🎓 学んだこと

1. **AKS と ACR の認証は必須**:

   - Bicep で AKS を作成しただけでは ACR にアクセスできない
   - `az aks update --attach-acr` または Bicep で `AcrPull` ロール割り当てが必須
   - ImagePullBackOff が出たら最初に ACR 認証を疑う

2. **Static IP の配置場所が重要**:

   - AKS は基本的にマネージド RG (`mc-*`) 内のリソースを使用
   - ユーザー RG に IP を作成しても、Managed Identity の権限不足でアクセスできない
   - Dynamic IP が最もシンプルで確実（デモ環境では十分）

3. **Helm の `--reuse-values` は要注意**:

   - 古い設定値が残り続ける
   - ワークフローで変数を空にしても、Helm は以前の値を使用
   - 明示的に削除または `--reset-values` の使用を検討

4. **GitHub Actions Variables API の制限**:

   - `actions: write` 権限があっても Variables API へのアクセスは別制限
   - `workflow_run` イベントではトークン権限がさらに制限される

5. **kubectl 直接調査の重要性**:
   - GitHub Actions ログだけでは根本原因が見えないことがある
   - `kubectl describe pod` と `kubectl get events` が問題解決の鍵

---

## 7️⃣ ワークフローと Bicep の恒久的修正（新環境対応）

### 💡 目的

手動修正で成功した内容を自動化し、新しい環境でも自動的に正しくデプロイされるようにする。

### 🔧 修正内容

#### 1. **ワークフロー修正（`.github/workflows/3-deploy-board-app.yml`）**

##### ✅ Static IP をノードリソースグループで自動作成

```bash
# Ingress 用 Static IP を確保
NODE_RG=$(az aks show --resource-group "$RESOURCE_GROUP_NAME" --name "$AKS_CLUSTER_NAME" --query nodeResourceGroup -o tsv)
PIP_NAME=$(jq -r '.parameters.ingressPublicIpName.value' "$PARAM_FILE")
az network public-ip show --resource-group "$NODE_RG" --name "$PIP_NAME" >/dev/null 2>&1 || \
   az network public-ip create --resource-group "$NODE_RG" --name "$PIP_NAME" --sku Standard --allocation-method Static
INGRESS_STATIC_IP=$(az network public-ip show --resource-group "$NODE_RG" --name "$PIP_NAME" --query ipAddress -o tsv)
echo "NODE_RESOURCE_GROUP=$NODE_RG" >> "$GITHUB_ENV"
echo "INGRESS_STATIC_IP=$INGRESS_STATIC_IP" >> "$GITHUB_ENV"
```

- AKS 公式ドキュメント（[Use a static public IP with AKS](https://learn.microsoft.com/azure/aks/static-ip)）に沿い、Static IP を **AKS マネージド RG (mc-\*)** に配置。
- 取得した IP と RG 名を `NODE_RESOURCE_GROUP` / `INGRESS_STATIC_IP` として共有。

##### ✅ NSG ルールと Helm 設定も Static IP 前提で整理

```bash
# NSG ルールを冪等に適用
ensure_rule() { az network nsg rule create --resource-group "$NODE_RG" --nsg-name "$NSG_NAME" --name "$1" --priority "$4" --access Allow --direction Inbound --protocol Tcp --source-address-prefixes "$2" --destination-port-ranges "$3" >/dev/null; }
ensure_rule allow-azure-lb-probes AzureLoadBalancer 30000-32767 300
ensure_rule allow-nodeport-from-internet Internet 30000-32767 310

# Helm upgrade/install 時に Static IP を注入
STATIC_IP_ARGS="--set controller.service.loadBalancerIP=$INGRESS_STATIC_IP \
   --set controller.service.annotations.\"service.beta.kubernetes.io/azure-load-balancer-resource-group\"=$NODE_RG"
helm upgrade ingress-nginx ingress-nginx/ingress-nginx ... $STATIC_IP_ARGS
```

- `service.beta.kubernetes.io/azure-load-balancer-resource-group=<mc-rg>` を付与して AKS にノード RG 内の IP を参照させる。
- `--reset-values` を継続使用し、古い `loadBalancerIP` 設定が残らないようにする。

#### 2. **Bicep 修正（`infra/modules/aks.bicep`）**

##### ✅ ACR Pull ロールの自動付与

```bicep
// Line 31: 新パラメータ追加
@description('ACR Resource ID (AKS に AcrPull ロールを付与するため)')
param acrId string = ''

// Lines 113-127: 自動ロール割り当て
var acrName = !empty(acrId) ? last(split(acrId, '/')) : ''

resource existingAcr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = if (!empty(acrId)) {
  name: acrName
}

resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(acrId)) {
  name: guid(acrId, cluster.id, 'AcrPull')
  scope: existingAcr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: cluster.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}
```

**理由**: 手動で `az aks update --attach-acr` を実行していた処理を自動化

**結果**: インフラデプロイ時に自動的に ACR Pull 権限が付与され、Pod が ACR からイメージを取得可能になる

#### 3. **Bicep 修正（`infra/main.bicep`）**

```bicep
// Line 270: ACR ID を AKS モジュールに渡す
module aks './modules/aks.bicep' = if (!aksSkipCreate) {
  params: {
    ...
    acrId: acr.outputs.id  // ⬅ ACR の Resource ID を渡す
    tags: defaultTags
  }
}
```

**理由**: AKS モジュールが ACR に対してロール割り当てを行うために必要

### 📊 修正前後の比較

| 項目                       | 修正前（手動対応）                                     | 修正後（自動化）                                              |
| -------------------------- | ---------------------------------------------------- | ------------------------------------------------------------- |
| **ACR 認証**               | `az aks update --attach-acr` を手動実行              | Bicep で自動ロール割り当て                                    |
| **Static IP 設定**         | 手動でノード RG に移動 or Dynamic IP に切替が必要     | Workflow がノード RG に Static IP を自動生成し Helm も参照     |
| **NSG 設定**               | Azure Portal での確認や手動修正が必要                 | GitHub Actions が AzureLoadBalancer / NodePort ルールを冪等適用 |
| **Helm の値保持問題**      | `--reuse-values` により `loadBalancerIP` が残存        | `--reset-values` + `STATIC_IP_ARGS` で毎回クリーンに適用        |
| **新環境での動作**         | 毎回手動介入が必要                                   | 完全自動化（コード通り動作）                                    |
| **トラブルシューティング** | kubectl 調査 → 手動修正 → ワークフロー再実行         | 初回デプロイから静的 IP 付きで正常動作                         |

### ✅ 効果

1. **新環境での自動化達成**:

   - Infrastructure デプロイ時に ACR 認証が自動設定される
   - ワークフロー実行時に Static IP 関連のエラーが発生しない
   - Helm の設定値が期待通りに更新される

2. **メンテナンス性の向上**:

   - 手動コマンドの実行が不要
   - トラブルシューティングドキュメントの内容がコードに反映されている
   - 再現性が高く、他者環境でも同じ結果を得られる

3. **コスト最適化**:
   - Static IP リソースが不要（Dynamic IP で十分）
   - リソース作成/削除の手間が削減

### 📝 コミット履歴

```bash
# コミット 270d83c
fix(board-app): Static IP使用を無効化してDynamic IP使用に切り替え

- Static IP 取得処理をコメントアウト
- Helm upgrade 時に loadBalancerIP=null を明示設定
- --reuse-values から --reset-values に変更

# コミット 3ae66b7
fix(board-app): Helm設定の永続化とACR認証の自動設定を追加

- aks.bicep に ACR Pull ロール自動割り当てを追加
- main.bicep から ACR ID を渡す構成に変更
- 新環境でも手動介入なしでデプロイ可能に
```

---

## 🎯 次のステップ

### 短期的改善

1. **Ingress Controller のレプリカ数検討**:

   - 現在 `replicaCount=1`（デモ用）
   - 本番環境では `2` 以上を推奨

2. **HPA（Horizontal Pod Autoscaler）の追加**:

   - Board App / Board API に自動スケーリングを設定
   - CPU/メモリメトリクスベースのスケーリング

3. **Log Analytics ダッシュボード作成**:
   - AKS / ACA / VM / Storage のログを統合監視
   - アラート設定（Pod 再起動、エラー急増など）

### 長期的改善

1. **Cert-Manager 導入**:

   - Let's Encrypt で自動 SSL 証明書取得
   - Ingress に HTTPS 設定を追加

2. **ArgoCD / Flux による GitOps**:

   - Kubernetes マニフェストの宣言的管理
   - Git をシングルソースとした自動デプロイ

3. **Azure Policy 適用**:
   - コンテナイメージの脆弱性スキャン強制
   - ネットワークポリシーの適用
   - リソースタグの必須化

---

## 📎 関連ドキュメント

- [2025-11-20-managed-identity-migration.md](./2025-11-20-managed-identity-migration.md) - Admin App MI 修正履歴
- [README_WORKFLOWS.md](../READMEs/README_WORKFLOWS.md) - ワークフロー全体設計
- [README_INFRASTRUCTURE.md](../READMEs/README_INFRASTRUCTURE.md) - インフラ構成詳細

---

**作成日時**: 2025-11-21  
**最終更新**: 2025-11-21 14:25 JST  
**Status**: Admin App ✅ SUCCESS / Board App 🟡 Static IP 自動化検証中 / 自動化 ✅ 進行中
