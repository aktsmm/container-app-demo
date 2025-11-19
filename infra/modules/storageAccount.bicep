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

output id string = storageAccount.id
output primaryEndpoints object = storageAccount.properties.primaryEndpoints
