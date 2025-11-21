targetScope = 'resourceGroup'

@description('全リソースを展開するリージョン')
param location string

@description('環境を識別する名前（タグなどに活用）')
param environmentName string

@description('共通タグ')
param tags object = {}

@description('デプロイメント名を一意にするためのタイムスタンプ（既定: 現在時刻）')
param deploymentTimestamp string = utcNow('yyyyMMddHHmmss')

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

@description('バックアップコンテナ名')
param backupContainerName string = 'mysql-backups'

@description('Container Apps Environment 名')
param containerAppsEnvironmentName string

@description('Container Apps が利用するユーザー割り当てマネージド ID 名')
param containerAppManagedIdentityName string

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

@description('既存 AKS がある場合は true にして再作成をスキップ (SSH 公開鍵変更禁止エラーを回避)')
param aksSkipCreate bool = false

@description('AKS Service CIDR')
param aksServiceCidr string = '10.10.0.0/24'

@description('AKS DNS Service IP')
param aksDnsServiceIp string = '10.10.0.10'

@description('AKS Pod CIDR (Overlay 利用時)')
param aksPodCidr string = '10.244.0.0/16'

@description('Ingress用Static Public IP名')
param ingressPublicIpName string

@description('Ingress 用 Public IP に付与する DNS ラベル（<label>.<region>.cloudapp.azure.com を生成）')
param ingressPublicIpDnsLabel string

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

@description('MySQL の root パスワード (セキュア)')
@secure()
param mysqlRootPassword string

@description('アプリケーション用 MySQL ユーザー名')
param mysqlAppUsername string

@description('アプリケーション用 MySQL パスワード (セキュア)')
@secure()
param mysqlAppPassword string

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
  name: 'logAnalytics-${deploymentTimestamp}'
  params: {
    name: logAnalyticsName
    location: location
    sku: logAnalyticsSku
    retentionInDays: logAnalyticsRetentionDays
    tags: defaultTags
  }
}

module vnet './modules/vnet.bicep' = {
  name: 'network-${deploymentTimestamp}'
  params: {
    name: vnetName
    location: location
    addressSpace: vnetAddressPrefix
    subnets: vnetSubnets
    tags: defaultTags
  }
}

module acr './modules/acr.bicep' = {
  name: 'acr-${deploymentTimestamp}'
  params: {
    name: acrName
    location: location
    tags: defaultTags
  }
}

module storage './modules/storageAccount.bicep' = {
  name: 'storage-${deploymentTimestamp}'
  params: {
    name: storageAccountName
    location: location
    sku: storageSku
    accessTier: storageAccessTier
    backupContainerName: backupContainerName
    tags: defaultTags
  }
}

module containerAppsEnv './modules/containerAppEnv.bicep' = {
  name: 'containerAppsEnv-${deploymentTimestamp}'
  dependsOn: [
    vnet
  ]
  params: {
    name: containerAppsEnvironmentName
    location: location
    logAnalyticsCustomerId: logAnalytics.outputs.customerId
    logAnalyticsSharedKey: logAnalytics.outputs.sharedKey
    subnetResourceId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, containerAppSubnetName)
    tags: defaultTags
  }
}

resource containerAppUserAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: containerAppManagedIdentityName
  location: location
  tags: defaultTags
}

module aks './modules/aks.bicep' = if (!aksSkipCreate) {
  name: 'aks-${deploymentTimestamp}'
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
    ingressPublicIpName: ingressPublicIpName
    ingressPublicIpDnsLabel: ingressPublicIpDnsLabel
    acrId: acr.outputs.id
    tags: defaultTags
  }
}


module vm './modules/vm.bicep' = {
  name: 'vm-${deploymentTimestamp}'
  dependsOn: [
    logAnalytics
  ]
  params: {
    name: vmName
    location: location
    vmSize: vmSize
    subnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, vmSubnetName)
    adminUsername: vmAdminUsername
    adminPassword: vmAdminPassword
    mysqlPort: mysqlPort
    sshPort: sshPort
    mysqlRootPassword: mysqlRootPassword
    mysqlAppUsername: mysqlAppUsername
    mysqlAppPassword: mysqlAppPassword
    tags: defaultTags
  }
}

// 既存 Ingress Public IP (AKS スキップ時の出力用)
resource ingressPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' existing = {
  name: ingressPublicIpName
}


// Diagnostic settings for Storage Account
resource storageAccountExisting 'Microsoft.Storage/storageAccounts@2023-04-01' existing = {
  name: storageAccountName
}

// VM Managed Identity に Storage Blob Data Contributor ロールを付与
resource vmStorageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccountExisting.id, vmName, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: storageAccountExisting
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // Storage Blob Data Contributor
    principalId: vm.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

// ACA 管理アプリが MySQL バックアップを操作できるよう Container Apps 用 ID にも権限を付与
resource containerAppIdentityStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccountExisting.id, containerAppManagedIdentityName, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: storageAccountExisting
  dependsOn: [
    storage
  ]
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: containerAppUserAssignedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${storageAccountName}-diag'
  scope: storageAccountExisting
  dependsOn: [
    storage
  ]
  properties: {
    workspaceId: logAnalytics.outputs.id
    logs: []
    metrics: [
      {
        category: 'Transaction'
        enabled: true
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
  dependsOn: aksSkipCreate ? [] : [
    aks
  ]
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
  dependsOn: [
    containerAppsEnv
  ]
  properties: {
    workspaceId: logAnalytics.outputs.id
    logs: [
      {
        category: 'ContainerAppConsoleLogs'
        enabled: true
      }
      {
        category: 'ContainerAppSystemLogs'
        enabled: true
      }
    ]
    metrics: []
  }
}

output azureContainerRegistryId string = acr.outputs.id
// 既存クラスタ再利用時も ID を一貫して出力 (aksSkipCreate=true の場合 module は作成されない)
output aksClusterId string = resourceId('Microsoft.ContainerService/managedClusters', aksName)
output aksNodeResourceGroup string = aksSkipCreate ? aksNodeResourceGroup : aks!.outputs.nodeResourceGroup
// DNS ラベルを未設定でも評価が落ちないように既存 Public IP の参照をガード
output ingressPublicIpAddress string = aksSkipCreate
  ? ingressPublicIp.properties.ipAddress
  : aks!.outputs.ingressPublicIpAddress
// DNS ラベルの FQDN はパラメータ値から算出できるため Azure 側の dnsSettings を参照しない
output ingressPublicIpFqdn string = boardAppIngressHost
output containerAppsEnvironmentId string = containerAppsEnv.outputs.id
output logAnalyticsId string = logAnalytics.outputs.id
output virtualNetworkId string = vnet.outputs.id
output storageAccountId string = storage.outputs.id
// GitHub Actions から DB 接続先を解決できるように MySQL VM の Private IP を出力
output mysqlPrivateIp string = vm.outputs.privateIp
output containerAppUserAssignedIdentityId string = containerAppUserAssignedIdentity.id
output containerAppUserAssignedIdentityPrincipalId string = containerAppUserAssignedIdentity.properties.principalId
