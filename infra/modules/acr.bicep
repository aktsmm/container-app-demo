targetScope = 'resourceGroup'

@description('ACR 名称')
param name string

@description('リージョン')
param location string

@description('SKU 名 (Basic 推奨)')
param sku string = 'Basic'

@description('共通タグ')
param tags object = {}

resource registry 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
  }
  properties: {
    adminUserEnabled: false
    dataEndpointEnabled: false
    policies: {
      quarantinePolicy: {
        status: 'disabled'
      }
      trustPolicy: {
        status: 'disabled'
        type: 'Notary'
      }
      retentionPolicy: {
        status: 'disabled'
        days: 7
      }
    }
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

output id string = registry.id
