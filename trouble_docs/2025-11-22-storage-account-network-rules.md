# ストレージアカウントのネットワークルール設定によるバックアップ失敗

## 発生日時

- 2025-11-22 17:08 JST 頃 (GitHub Actions `backup-upload.yml` の定期実行)

## 事象

- バックアップワークフロー（Run #87）が失敗
- エラーメッセージ: ストレージアカウント `demo8211` への接続がネットワークルールによりブロックされた
- 前回の実行（Run #85）は成功していたが、その後の実行（Run #86, #87）で失敗が発生

## 影響

- MySQL の定期バックアップが失敗し、バックアップファイルが Azure Storage にアップロードされない
- 1時間ごとの定期バックアップが機能せず、データ損失のリスクが増大

## 原因

1. ストレージアカウント `demo8211` にネットワークファイアウォールルールが設定された（手動またはポリシー経由）
2. Bicep コードには `networkAcls` プロパティの定義がなかったため、インフラデプロイ時に明示的な設定がされていなかった
3. その結果、後から設定されたネットワークルールが GitHub Actions ランナーからのアクセスをブロックした

## エラーログ抜粋

```
Error: This request is not authorized to perform this operation using this permission.
Status Code: 403 (Forbidden)
Storage Account: demo8211
Resource Group: RG-BBS-Appzz
Error Details: Network rules are blocking access
```

## 対応

### 1. Bicep コードの修正

`infra/modules/storageAccount.bicep` に `networkAcls` プロパティを追加：

```bicep
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-04-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
  }
  kind: 'StorageV2'
  properties: {
    accessTier: accessTier
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    // ネットワークルールを設定：デフォルトで拒否し、Azure サービスからのアクセスは許可
    // これにより GitHub Actions（Azure 認証経由）からのアクセスが可能になる
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: []
      ipRules: []
    }
    encryption: {
      // ... 既存の暗号化設定
    }
  }
}
```

### 2. 設定の説明

- `defaultAction: 'Deny'`: デフォルトで全アクセスを拒否（セキュリティ維持）
- `bypass: 'AzureServices'`: Azure サービス（Azure ログイン経由の GitHub Actions、VM の Managed Identity など）からのアクセスを許可
- `virtualNetworkRules: []`: VNet 統合は今回使用しない
- `ipRules: []`: 特定 IP からのアクセス許可は今回使用しない

### 3. デプロイ手順

```bash
# インフラデプロイワークフローを実行してストレージアカウント設定を更新
az deployment group create \
  --resource-group RG-BBS-Appzz \
  --template-file infra/main.bicep \
  --parameters @infra/parameters/main-dev.parameters.json

# または GitHub Actions の infra-deploy ワークフローを実行
```

## 検証

### 修正前の確認

```bash
# ストレージアカウントのネットワークルール確認
az storage account show \
  --name demo8211 \
  --resource-group RG-BBS-Appzz \
  --query networkRuleSet
```

### 修正後の検証

1. インフラデプロイワークフローを実行
2. ネットワークルールが正しく設定されたことを確認：
   ```bash
   az storage account show \
     --name demo8211 \
     --resource-group RG-BBS-Appzz \
     --query "networkRuleSet.{defaultAction:defaultAction,bypass:bypass}"
   ```
3. バックアップワークフローを手動実行して成功を確認
4. 定期実行（1時間ごと）で継続的に成功することを確認

## セキュリティ考慮事項

### この設定のセキュリティレベル

✅ **良い点**:
- デフォルトでアクセス拒否（`defaultAction: 'Deny'`）
- Azure サービスのみ許可（`bypass: 'AzureServices'`）
- パブリックアクセスは引き続き無効（`allowBlobPublicAccess: false`）
- TLS 1.2 必須（`minimumTlsVersion: 'TLS1_2'`）

⚠️ **注意点**:
- `bypass: 'AzureServices'` は Azure 内のサービスであれば広範にアクセスを許可する
- より厳格にする場合は Private Endpoint の利用を検討
- 本番環境では追加のセキュリティレイヤー（Private Link、VNet統合）の検討を推奨

### 代替案の検討

1. **Private Endpoint（最も安全）**
   - VNet 内からのみアクセス可能
   - コスト増加、構成複雑化

2. **特定 IP アドレス許可（中程度）**
   - GitHub Actions のホストされたランナー IP は動的で管理困難
   - セルフホステッドランナーが必要

3. **AzureServices バイパス（今回採用）**
   - セキュリティと運用のバランスが良い
   - デモ環境に適している

## 再発防止

### IaC での明示的な定義

- すべてのセキュリティ関連設定は Bicep/Terraform で明示的に定義する
- パラメータファイルでカスタマイズ可能にする場合は、デフォルト値をセキュアに設定

### ポリシーとの整合性

- Azure Policy で強制されるネットワークルールがある場合、Bicep コードと整合性を取る
- ポリシーの適用タイミングとインフラデプロイのタイミングを考慮

### モニタリング

- ストレージアカウントへのアクセス失敗を Log Analytics で監視
- バックアップワークフローの失敗時にアラートを送信

```kusto
// ストレージアカウントへのアクセス失敗を検出
StorageBlobLogs
| where StatusCode == 403
| where TimeGenerated > ago(1h)
| project TimeGenerated, AccountName, OperationName, StatusCode, StatusText
| summarize Count=count() by bin(TimeGenerated, 5m), AccountName
```

## 関連資料

- [Azure Storage のファイアウォールと仮想ネットワークを構成する](https://learn.microsoft.com/ja-jp/azure/storage/common/storage-network-security)
- [信頼できる Azure サービスによるストレージ アカウントへのアクセス](https://learn.microsoft.com/ja-jp/azure/storage/common/storage-network-security#trusted-access-based-on-a-managed-identity)
- [GitHub Actions で Azure にデプロイ](https://learn.microsoft.com/ja-jp/azure/developer/github/connect-from-azure)

## 備考

- この問題は Run #85 までは発生していなかったため、最近ネットワークルールが追加された可能性が高い
- VM の Managed Identity を使用したバックアップアップロード（azcopy）は、`bypass: 'AzureServices'` により引き続き動作する
- GitHub Actions からのコンテナ作成・確認操作も `--auth-mode login` で Azure AD 認証を使用しているため、同様に動作する
