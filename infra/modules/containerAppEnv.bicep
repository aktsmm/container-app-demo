targetScope = 'resourceGroup'

@description('Container Apps Environment 名')
param name string

@description('リージョン')
param location string

@description('Log Analytics ワークスペースの Customer ID')
param logAnalyticsCustomerId string

@description('Log Analytics ワークスペースのプライマリキー')
@secure()
param logAnalyticsSharedKey string

@description('VNet 連携に使用するサブネット ID (Delegation: Microsoft.App/environments)')
param subnetResourceId string

@description('共通タグ')
param tags object = {}

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsCustomerId
        sharedKey: logAnalyticsSharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: subnetResourceId
    }
    workloadProfiles: [
      {
        name: 'consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

output id string = managedEnvironment.id
