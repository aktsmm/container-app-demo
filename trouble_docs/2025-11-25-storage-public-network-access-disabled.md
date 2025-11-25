# Storage Account - Public Network Access 無効化による AuthorizationFailure

## 発生日時

- 2025-11-25 11:53 JST 頃（管理アプリからバックアップファイルへのアクセス時）

## 現象

- 管理アプリ（Container Apps）からバックアップ用 Storage Account（`demo1820`）の Blob にアクセスすると、以下のエラーが発生：

```
This request is not authorized to perform this operation.
RequestId:5d80ce7c-b01e-0013-3bb6-5ddc00000000
Time:2025-11-25T02:53:58.5834852Z
ErrorCode:AuthorizationFailure
```

## 原因

Storage Account の **`publicNetworkAccess`** が **`Disabled`** に設定されていたため。

### 詳細な構成と問題点

| 設定項目                       | 設定値                                 | 影響                                                                                |
| ------------------------------ | -------------------------------------- | ----------------------------------------------------------------------------------- |
| `publicNetworkAccess`          | `Disabled`                             | ❌ **全てのパブリックエンドポイント経由のアクセスをブロック**                       |
| `networkRuleSet.defaultAction` | `Deny`                                 | VNet ルールが存在するが、Public が Disabled なので無効化される                      |
| `virtualNetworkRules`          | `snet-vm`, `snet-aca` 許可             | Service Endpoint 経由でアクセス可能なはず**だが**、Public Disabled により機能しない |
| Managed Identity               | Storage Blob Data Contributor 付与済み | RBAC 権限自体は問題なし                                                             |
| Private Endpoint               | 未構成                                 | `publicNetworkAccess: Disabled` の場合は必須だが存在しない                          |

### `publicNetworkAccess: Disabled` の仕様

Microsoft 公式ドキュメント:  
https://learn.microsoft.com/azure/storage/common/storage-network-security#change-the-default-network-access-rule

> When you set `publicNetworkAccess` to `Disabled`, all public endpoint access is blocked, **regardless of firewall rules or virtual network rules**. Access is only possible through **private endpoints**.

つまり:

- `Disabled` の場合、**VNet Service Endpoint では到達できない**
- Private Endpoint を作成しない限り、VNet 統合された Container Apps からも接続不可
- `virtualNetworkRules` や `bypass: AzureServices` も無視される

## 環境情報

### Container Apps Environment（VNet 構成）

```json
{
  "vnetConfiguration": {
    "infrastructureSubnetId": "/subscriptions/.../subnets/snet-aca",
    "internal": false
  }
}
```

- Container Apps Environment は **VNet-scoped**（`snet-aca` に配置）
- 管理アプリの Managed Identity: `55e20109-ca15-4fb8-883e-0b3fd554c5f7`
- ロール割り当て: Storage Blob Data Contributor ✅

### Storage Account（問題の構成）

```json
{
  "publicNetworkAccess": "Disabled", // ❌ 問題
  "networkRuleSet": {
    "defaultAction": "Deny",
    "bypass": "AzureServices",
    "virtualNetworkRules": [
      { "virtualNetworkResourceId": ".../subnets/snet-vm" },
      { "virtualNetworkResourceId": ".../subnets/snet-aca" }
    ]
  }
}
```

## 解決策

### 実施した対応（即時）

Azure CLI で `publicNetworkAccess` を `Enabled` に変更:

```pwsh
az storage account update `
  --name demo1820 `
  --resource-group RG-cicd-Quick-demo2 `
  --public-network-access Enabled
```

この変更により:

- VNet Service Endpoint 経由でのアクセスが有効化
- `snet-aca` および `snet-vm` からの接続が可能に
- `defaultAction: Deny` により、許可された VNet 以外はブロックされる
- RBAC（Managed Identity + Storage Blob Data Contributor）による認証・認可が正常に機能

### セキュリティレベルの評価

#### 現在の構成（推奨・デモ環境向け）

✅ **良い点**:

- `publicNetworkAccess: Enabled` により VNet Service Endpoint が機能
- `defaultAction: Deny` + VNet 許可リストでネットワーク制限
- `bypass: AzureServices` により Azure サービス経由のアクセスを許可
- `allowBlobPublicAccess: false` により匿名アクセスは引き続き無効
- `minimumTlsVersion: TLS1_2` でセキュアな通信を強制
- Managed Identity + RBAC による認証・認可

⚠️ **注意点**:

- パブリックエンドポイントは有効だが、VNet 許可リスト以外は拒否
- より厳格なセキュリティが必要な本番環境では Private Endpoint を推奨

#### 本番環境での推奨構成

Private Endpoint + `publicNetworkAccess: Disabled` の組み合わせ:

```bicep
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-04-01' = {
  properties: {
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: 'pe-storage-blob'
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        privateLinkServiceId: storageAccount.id
        groupIds: ['blob']
      }
    ]
  }
}
```

- VNet 内からのみアクセス可能（完全プライベート）
- Private DNS Zone の構成が必要
- GitHub Actions は VPN または Azure VNet 統合が必要

## IaC への反映

### 修正内容

#### 1. `infra/modules/storageAccount.bicep`

```bicep
@description('VNet 統合用サブネット ID の配列（Service Endpoint 経由でアクセス許可）')
param allowedSubnetIds array = []

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-04-01' = {
  properties: {
    // Public Network Access を有効化（VNet Service Endpoint 経由のアクセスに必要）
    // publicNetworkAccess: 'Disabled' の場合は Private Endpoint が必須となる
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: [for subnetId in allowedSubnetIds: {
        id: subnetId
        action: 'Allow'
      }]
      ipRules: []
    }
  }
}
```

#### 2. `infra/main.bicep`

```bicep
module storage './modules/storageAccount.bicep' = {
  name: 'storage-${deploymentTimestamp}'
  dependsOn: [vnet]
  params: {
    name: storageAccountName
    location: location
    sku: storageSku
    accessTier: storageAccessTier
    backupContainerName: backupContainerName
    // VNet 統合：VM サブネットと Container Apps サブネットからのアクセスを許可
    allowedSubnetIds: [
      resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, vmSubnetName)
      resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, containerAppSubnetName)
    ]
    tags: defaultTags
  }
}
```

## 参考情報

### Microsoft 公式ドキュメント

- [Troubleshoot 403 errors in Azure Blob Storage](https://learn.microsoft.com/troubleshoot/azure/azure-storage/blobs/authentication/storage-troubleshoot-403-errors)
- [Configure Azure Storage firewalls and virtual networks](https://learn.microsoft.com/azure/storage/common/storage-network-security)
- [Azure Container Apps VNet integration](https://learn.microsoft.com/azure/container-apps/vnet-custom)

### 関連トラブルシューティング

- `trouble_docs/2025-11-23-backup-workflow-storage-network-deny.md` - バックアップワークフローでのネットワーク制限問題
- `trouble_docs/2025-11-20-managed-identity-migration.md` - Managed Identity 移行時のロール割り当て

## 教訓

1. **`publicNetworkAccess: Disabled` の影響範囲を正確に理解する**

   - VNet Service Endpoint や `virtualNetworkRules` も無効化される
   - Private Endpoint が必須となる構成

2. **デモ環境と本番環境で適切なセキュリティレベルを選択**

   - デモ: `Enabled` + `defaultAction: Deny` + VNet 許可リスト
   - 本番: `Disabled` + Private Endpoint

3. **Azure Policy による自動修復に注意**

   - Microsoft Cloud Security Benchmark などの Initiative が、より厳格な設定を強制する場合がある
   - IaC とポリシーの整合性を保つ

4. **VNet 統合の用語を正確に使い分ける**
   - Container Apps: "VNet-scoped" / "Custom VNet" / "VNet injection"
   - App Service: "VNet Integration"（アウトバウンドのみ）

## ステータス

✅ **解決済み**（2025-11-25 12:30 JST）

- CLI で `publicNetworkAccess: Enabled` に変更
- 管理アプリからバックアップファイルへのアクセス正常化を確認
- Bicep に反映済み（次回デプロイで恒久化）
