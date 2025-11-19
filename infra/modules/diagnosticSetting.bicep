targetScope = 'resourceGroup'

@description('診断設定名（リソース単位で一意な値）')
param name string

@description('診断設定を適用するリソース ID')
param targetResourceId string

@description('ログを送信する Log Analytics Workspace ID')
param logAnalyticsWorkspaceId string

@description('ログカテゴリ設定')
param logs array = []

@description('メトリックカテゴリ設定')
param metrics array = []

resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: resourceId(targetResourceId)
  name: name
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: logs
    metrics: metrics
  }
}
