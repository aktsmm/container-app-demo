targetScope = 'resourceGroup'

@description('全リソースを展開するリージョン')
param location string

@description('環境を識別する名前（タグなどに活用）')
param environmentName string

@description('共通タグ')
param tags object = {}

@description('仮想ネットワーク名')
param vnetName string

@description('VNet アドレス空間 (例: 10.0.0.0/16)')
param vnetAddressPrefix string

@description('AKS 用サブネット名')
param aksSubnetName string

@description('AKS 用サブネットの CIDR')
param aksSubnetPrefix string

@description('VM 用サブネット名')
param vmSubnetName string

@description('VM 用サブネットの CIDR')
param vmSubnetPrefix string

@description('Container Apps 用サブネット名')
param containerAppSubnetName string

@description('Container Apps 用サブネット CIDR')
param containerAppSubnetPrefix string

@description('Log Analytics ワークスペース名')
param logAnalyticsName string

@description('Log Analytics SKU')
param logAnalyticsSku string = 'PerGB2018'

@description('Log Analytics 保持日数')
param logAnalyticsRetentionDays int = 30

@description('ACR 名 (Basic SKU)')
param acrName string

@description('Storage Account 名 (MySQL バックアップ用)')
param storageAccountName string

@description('Storage SKU (例: Standard_LRS)')
param storageSku string = 'Standard_LRS'

@description('Storage アクセス層')
param storageAccessTier string = 'Cool'

@description('Container Apps Environment 名')
param containerAppsEnvironmentName string

@description('AKS クラスタ名')
param aksName string

@description('AKS DNS プレフィックス')
param aksDnsPrefix string

@description('AKS 対象 Kubernetes バージョン (空文字で最新)')
param aksKubernetesVersion string = ''

@description('AKS ノードリソースグループ名')
param aksNodeResourceGroup string

@description('AKS システムプール名')
param aksSystemPoolName string = 'systempool'

@description('AKS ノード VM サイズ')
param aksNodeVmSize string = 'Standard_B2s'

@description('AKS ノード数 (デモ用途なので最小構成)')
@minValue(1)
param aksNodeCount int = 1

@description('AKS ノード OS ディスクサイズ (GB)')
param aksNodeOsDiskSizeGB int = 64

@description('AKS 管理者ユーザー名')
param aksAdminUsername string = 'aksadmin'

@description('AKS ノード用 SSH 公開鍵')
param aksSshPublicKey string

@description('AKS Service CIDR')
param aksServiceCidr string = '10.10.0.0/24'

@description('AKS DNS Service IP')
param aksDnsServiceIp string = '10.10.0.10'

@description('AKS Pod CIDR (Overlay 利用時)')
param aksPodCidr string = '10.244.0.0/16'

@description('MySQL VM 名')
param vmName string

@description('VM サイズ')
param vmSize string = 'Standard_B1ms'

@description('VM 管理者ユーザー名')
param vmAdminUsername string

@description('VM 管理者パスワード')
@secure()
param vmAdminPassword string

@description('MySQL ポート')
param mysqlPort int = 3306

@description('SSH ポート')
param sshPort int = 22

@description('掲示板アプリが使用する Kubernetes Namespace')
param boardAppNamespace string

@description('掲示板アプリの Ingress ホスト名')
param boardAppIngressHost string

var defaultTags = union(tags, {
  environment: environmentName
  boardAppNamespace: boardAppNamespace
  boardAppIngressHost: boardAppIngressHost
})

var vnetSubnets = [
  {
    name: aksSubnetName
    properties: {
      addressPrefix: aksSubnetPrefix
      delegations: []
      privateEndpointNetworkPolicies: 'Enabled'
      privateLinkServiceNetworkPolicies: 'Enabled'
    }
  }
  {
    name: vmSubnetName
    properties: {
      addressPrefix: vmSubnetPrefix
      delegations: []
    }
  }
  {
    name: containerAppSubnetName
    properties: {
      addressPrefix: containerAppSubnetPrefix
      delegations: [
        {
          name: 'appsvc'
          properties: {
            serviceName: 'Microsoft.App/environments'
          }
        }
      ]
      privateEndpointNetworkPolicies: 'Enabled'
      privateLinkServiceNetworkPolicies: 'Enabled'
    }
  }
]

module logAnalytics './modules/logAnalytics.bicep' = {
  name: 'logAnalytics'
  params: {
    name: logAnalyticsName
    location: location
    sku: logAnalyticsSku
    retentionInDays: logAnalyticsRetentionDays
    tags: defaultTags
  }
}

var logAnalyticsWorkspaceId = resourceId('Microsoft.OperationalInsights/workspaces', logAnalyticsName)
var logAnalyticsSharedKey = listKeys(logAnalyticsWorkspaceId, '2020-08-01').primarySharedKey

module vnet './modules/vnet.bicep' = {
  name: 'network'
  params: {
    name: vnetName
    location: location
    addressSpace: vnetAddressPrefix
    subnets: vnetSubnets
    tags: defaultTags
  }
}

module acr './modules/acr.bicep' = {
  name: 'acr'
  params: {
    name: acrName
    location: location
    tags: defaultTags
  }
}

module storage './modules/storageAccount.bicep' = {
  name: 'storage'
  params: {
    name: storageAccountName
    location: location
    sku: storageSku
    accessTier: storageAccessTier
    tags: defaultTags
  }
}

module containerAppsEnv './modules/containerAppEnv.bicep' = {
  name: 'containerAppEnv'
  params: {
    name: containerAppsEnvironmentName
    location: location
    logAnalyticsCustomerId: logAnalytics.outputs.customerId
    logAnalyticsSharedKey: logAnalyticsSharedKey
    subnetResourceId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, containerAppSubnetName)
    tags: defaultTags
  }
}

module aks './modules/aks.bicep' = {
  name: 'aks'
  params: {
    name: aksName
    location: location
    dnsPrefix: aksDnsPrefix
    kubernetesVersion: aksKubernetesVersion
    nodeResourceGroup: aksNodeResourceGroup
    systemPool: {
      name: aksSystemPoolName
      count: aksNodeCount
      vmSize: aksNodeVmSize
      osDiskSizeGB: aksNodeOsDiskSizeGB
      adminUsername: aksAdminUsername
      sshPublicKey: aksSshPublicKey
      serviceCidr: aksServiceCidr
      dnsServiceIp: aksDnsServiceIp
      podCidr: aksPodCidr
    }
    subnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, aksSubnetName)
    logAnalyticsWorkspaceId: logAnalytics.outputs.id
    tags: defaultTags
  }
}

module vm './modules/vm.bicep' = {
  name: 'vm'
  params: {
    name: vmName
    location: location
    vmSize: vmSize
    subnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, vmSubnetName)
    adminUsername: vmAdminUsername
    adminPassword: vmAdminPassword
    mysqlPort: mysqlPort
    sshPort: sshPort
    logAnalyticsCustomerId: logAnalytics.outputs.customerId
    logAnalyticsSharedKey: logAnalyticsSharedKey
    tags: defaultTags
  }
}

// Diagnostic settings for Storage Account
resource storageAccountExisting 'Microsoft.Storage/storageAccounts@2023-04-01' existing = {
  name: storageAccountName
}

resource storageDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${storageAccountName}-diag'
  scope: storageAccountExisting
  properties: {
    workspaceId: logAnalytics.outputs.id
    logs: [
      {
        category: 'StorageRead'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'StorageWrite'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'StorageDelete'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
    ]
  }
}

// Diagnostic settings for AKS control plane
resource aksExisting 'Microsoft.ContainerService/managedClusters@2024-05-01' existing = {
  name: aksName
}

resource aksDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${aksName}-diag'
  scope: aksExisting
  properties: {
    workspaceId: logAnalytics.outputs.id
    logs: [
      {
        category: 'kube-apiserver'
        enabled: true
      }
      {
        category: 'kube-controller-manager'
        enabled: true
      }
      {
        category: 'kube-scheduler'
        enabled: true
      }
      {
        category: 'cluster-autoscaler'
        enabled: true
      }
    ]
    metrics: []
  }
}

// Diagnostic settings for Container Apps Environment
resource caeExisting 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: containerAppsEnvironmentName
}

resource caeDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${containerAppsEnvironmentName}-diag'
  scope: caeExisting
  properties: {
    workspaceId: logAnalytics.outputs.id
    logs: [
      {
        category: 'SystemLogs'
        enabled: true
      }
      {
        category: 'IngressLogs'
        enabled: true
      }
      {
        category: 'ConsoleLogs'
        enabled: true
      }
    ]
    metrics: []
  }
}

output azureContainerRegistryId string = acr.outputs.id
output aksClusterId string = aks.outputs.id
output containerAppsEnvironmentId string = containerAppsEnv.outputs.id
output logAnalyticsId string = logAnalytics.outputs.id
output virtualNetworkId string = vnet.outputs.id
output storageAccountId string = storage.outputs.id
