targetScope = 'resourceGroup'

@description('Log Analytics ワークスペース名')
param name string

@description('リソースのリージョン')
param location string

@description('SKU (例: PerGB2018)')
param sku string = 'PerGB2018'

@description('データ保持日数')
param retentionInDays int = 30

@description('共通タグ')
param tags object = {}

resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      name: sku
    }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

output id string = workspace.id
output customerId string = workspace.properties.customerId
output location string = workspace.location
// Bicep の親モジュールから listKeys を呼ぶと作成前参照になるため、ここで共有キーを返す
@secure()
output sharedKey string = listKeys(workspace.id, '2020-08-01').primarySharedKey
