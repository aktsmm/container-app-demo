targetScope = 'resourceGroup'

@description('ストレージアカウント名')
param name string

@description('リージョン')
param location string

@description('SKU (例: Standard_LRS)')
param sku string = 'Standard_LRS'

@description('アクセス層 (Hot/Cool)')
@allowed([
  'Hot'
  'Cool'
])
param accessTier string = 'Cool'

@description('バックアップコンテナ名')
param backupContainerName string = 'mysql-backups'

@description('VNet 統合用サブネット ID の配列（Service Endpoint 経由でアクセス許可）')
param allowedSubnetIds array = []

@description('共通タグ')
param tags object = {}

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
    // Public Network Access を有効化（VNet Service Endpoint 経由のアクセスに必要）
    // publicNetworkAccess: 'Disabled' の場合は Private Endpoint が必須となる
    publicNetworkAccess: 'Enabled'
    // ネットワークルール：デフォルト拒否 + VNet サブネット（snet-vm, snet-aca）のみ許可
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: [for subnetId in allowedSubnetIds: {
        id: subnetId
        action: 'Allow'
      }]
      ipRules: []
    }
    encryption: {
      services: {
        file: {
          keyType: 'Account'
          enabled: true
        }
        blob: {
          keyType: 'Account'
          enabled: true
        }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

// Blob Service（コンテナ作成に必要）
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-04-01' = {
  name: 'default'
  parent: storageAccount
}

// MySQL バックアップ用コンテナ
resource backupContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-04-01' = {
  name: backupContainerName
  parent: blobService
  properties: {
    publicAccess: 'None'
  }
}

output id string = storageAccount.id
output primaryEndpoints object = storageAccount.properties.primaryEndpoints
output backupContainerName string = backupContainer.name
