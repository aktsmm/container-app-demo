# バックアップワークフロー失敗: GitHub Actions が Azure Services に含まれない問題

## 発生日時

- 2025-11-23 15:09 JST 頃（Run #107）
- 同様の失敗が Run #98-107 で継続的に発生

## 事象

- バックアップワークフロー `backup-upload.yml` が **"バックアップコンテナを確保"** ステップで失敗
- エラーメッセージ: "The request may be blocked by network rules of storage account"
- ストレージアカウント `demo8211` への接続がネットワークルールによりブロックされた

## 影響

- MySQL の定期バックアップ（1時間ごと）が完全に停止
- バックアップファイルが Azure Storage にアップロードされない
- データ損失のリスクが増大

## 原因

### 根本原因

ストレージアカウントの Bicep 設定で `networkAcls.defaultAction: 'Deny'` と `bypass: 'AzureServices'` が設定されていたが、**GitHub Actions ホステッドランナーは Azure Services に含まれない**ため、アクセスがブロックされていた。

### 誤解されていたこと

以前のトラブルシューティングドキュメント（2025-11-22-storage-account-network-rules.md）では、以下のように記載されていた：

> `bypass: 'AzureServices'`: Azure サービス（Azure ログイン経由の GitHub Actions、VM の Managed Identity など）からのアクセスを許可

**この記述は誤り**で、GitHub Actions からのアクセスは `AzureServices` バイパスでは許可されない。

### Azure Services バイパスの実際の動作

`bypass: 'AzureServices'` が適用されるのは以下のみ：
- 同一リージョン内の Azure サービス（一部例外あり）
- Microsoft の信頼できるサービス（特定のリスト）
- VM の System Assigned Managed Identity（リソースベースのアクセス）

GitHub Actions ホステッドランナーは：
- Azure 外部でホストされている
- IP アドレスが動的に変わる
- Service Principal で認証しても「Azure Service」として扱われない

## エラーログ抜粋

```
2025-11-23T15:10:05.2210940Z ERROR: 
2025-11-23T15:10:05.2211837Z The request may be blocked by network rules of storage account. 
Please check network rule set using 'az storage account show -n accountname --query networkRuleSet'.
2025-11-23T15:10:05.2212902Z If you want to change the default action to apply when no rule matches, 
please use 'az storage account update'.
```

## 対応

### 1. Bicep コードの修正

`infra/modules/storageAccount.bicep` の `networkAcls` を以下のように変更：

**修正前:**
```bicep
networkAcls: {
  defaultAction: 'Deny'
  bypass: 'AzureServices'
  virtualNetworkRules: []
  ipRules: []
}
```

**修正後:**
```bicep
// ネットワークルールを設定：デモ環境のため全アクセスを許可
// GitHub Actions ホステッドランナーは Azure Services に含まれないため、
// Deny + AzureServices バイパスではアクセスできない
// 本番環境では Private Endpoint または特定 IP の許可を検討すること
networkAcls: {
  defaultAction: 'Allow'
  bypass: 'AzureServices'
  virtualNetworkRules: []
  ipRules: []
}
```

### 2. デプロイと検証

```bash
# 1. インフラデプロイワークフローを実行
# GitHub Actions の "1️⃣ Infra Deploy" ワークフローを手動実行

# 2. ネットワークルール設定を確認
az storage account show \
  --name demo8211 \
  --resource-group RG-BBS-Appzz \
  --query "networkRuleSet.{defaultAction:defaultAction,bypass:bypass}" \
  -o table

# 期待される出力:
# DefaultAction    Bypass
# ---------------  ---------------
# Allow            AzureServices

# 3. バックアップワークフローを手動実行して成功を確認
# GitHub Actions の "🔄 MySQL Backup Upload (Scheduled)" ワークフローを手動実行
```

## セキュリティ考慮事項

### この設定のセキュリティレベル

✅ **良い点**:
- パブリックアクセスは引き続き無効（`allowBlobPublicAccess: false`）
- TLS 1.2 必須（`minimumTlsVersion: 'TLS1_2'`）
- 認証が必要（匿名アクセスは不可）
- デモ環境として適切な設定

⚠️ **注意点**:
- `defaultAction: 'Allow'` により、認証されたユーザーは誰でもアクセス可能
- デモ環境としては許容範囲だが、本番環境には推奨しない

### 本番環境での推奨構成

本番環境では以下のいずれかを検討：

1. **Private Endpoint（最も安全）**
   ```bicep
   networkAcls: {
     defaultAction: 'Deny'
     bypass: 'AzureServices'
   }
   // + Private Endpoint リソースを追加
   ```
   - VNet 内からのみアクセス可能
   - GitHub Actions は VPN または Azure VNet 統合が必要

2. **セルフホステッドランナー + IP 制限**
   ```bicep
   networkAcls: {
     defaultAction: 'Deny'
     bypass: 'AzureServices'
     ipRules: [
       {
         value: 'セルフホステッドランナーのIP'
         action: 'Allow'
       }
     ]
   }
   ```
   - 固定 IP のセルフホステッドランナーを Azure VM などで構築

3. **Managed Identity + RBAC（VM バックアップのみ）**
   - VM からのバックアップは System Assigned MI で実行（既に実装済み）
   - GitHub Actions からのコンテナ作成を事前に手動実行

## 再発防止策

### 1. ドキュメントの修正

- 誤った情報を含む過去のトラブルシューティングドキュメントを更新
- Azure Services バイパスの正確な動作を記載

### 2. IaC ベストプラクティス

- セキュリティ設定は環境（dev/prod）ごとにパラメータ化
- デモ環境と本番環境で異なるネットワークポリシーを適用

```bicep
// パラメータファイルで環境ごとに設定
param storageNetworkDefaultAction string = 'Allow' // dev
// param storageNetworkDefaultAction string = 'Deny' // prod
```

### 3. モニタリング強化

```kusto
// GitHub Actions からのストレージアクセスを監視
StorageBlobLogs
| where AccountName == "demo8211"
| where CallerIpAddress startswith "20." or CallerIpAddress startswith "40." // Azure Public IP範囲
| where StatusCode == 403
| summarize Count=count() by bin(TimeGenerated, 5m), OperationName, CallerIpAddress
```

## 関連資料

- [Azure Storage のファイアウォールと仮想ネットワーク](https://learn.microsoft.com/ja-jp/azure/storage/common/storage-network-security)
- [信頼できる Azure サービス](https://learn.microsoft.com/ja-jp/azure/storage/common/storage-network-security#trusted-microsoft-services)
- [GitHub Actions IP アドレス範囲](https://docs.github.com/en/actions/using-github-hosted-runners/about-github-hosted-runners#ip-addresses)
- [Azure Private Endpoint](https://learn.microsoft.com/ja-jp/azure/private-link/private-endpoint-overview)

## 学んだこと

1. **Azure Services != Azure 認証を使った外部サービス**
   - Service Principal での認証 ≠ Azure Service としての扱い
   - GitHub Actions は Azure 外部でホストされているため対象外

2. **セキュリティとアクセシビリティのトレードオフ**
   - 最高のセキュリティ = Private Endpoint（コストと複雑性が増す）
   - バランス重視 = セルフホステッドランナー（運用コスト）
   - シンプル重視 = Allow（デモ環境向け）

3. **IaC でのセキュリティ設定の重要性**
   - コメントは動作の理由を正確に記述する
   - 環境ごとに適切な設定を選択する

## 備考

- VM からの `azcopy` によるバックアップアップロードは System Assigned Managed Identity を使用しているため、`defaultAction: 'Deny'` でも動作する
- ただし、GitHub Actions からのコンテナ存在確認・作成は外部からのアクセスとなるためブロックされる
- 今回の修正により、両方のアクセスパターンが正常に動作する
