targetScope = 'resourceGroup'

@description('AKS クラスタ名')
param name string

@description('リージョン')
param location string

@description('DNS プレフィックス')
param dnsPrefix string

@description('Kubernetes バージョン。空文字の場合は最新安定版')
param kubernetesVersion string = ''

@description('ノードリソースグループ名')
param nodeResourceGroup string

@description('システムプール設定')
param systemPool object

@description('VNet 接続に使用するサブネット ID')
param subnetId string

@description('Log Analytics Workspace Resource ID')
param logAnalyticsWorkspaceId string

@description('ACR Resource ID (AKS に AcrPull ロールを付与するため)')
param acrId string = ''

@description('共通タグ')
param tags object = {}

resource cluster 'Microsoft.ContainerService/managedClusters@2024-05-01' = {
  name: name
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Base'
    tier: 'Standard'
  }
  properties: {
    dnsPrefix: dnsPrefix
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    nodeResourceGroup: nodeResourceGroup
    addonProfiles: {
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: logAnalyticsWorkspaceId
        }
      }
    }
    agentPoolProfiles: [
      {
        name: systemPool.name
        mode: 'System'
        count: systemPool.count
        vmSize: systemPool.vmSize
        osDiskSizeGB: systemPool.osDiskSizeGB
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
        availabilityZones: []
        vnetSubnetID: subnetId
        enableAutoScaling: false
        orchestratorVersion: empty(kubernetesVersion) ? null : kubernetesVersion
      }
    ]
    linuxProfile: {
      adminUsername: systemPool.adminUsername
      ssh: {
        publicKeys: [
          {
            keyData: systemPool.sshPublicKey
          }
        ]
      }
    }
    enableRBAC: true
    enablePodSecurityPolicy: false
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'Overlay'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
      podCidr: empty(systemPool.podCidr) ? null : systemPool.podCidr
      serviceCidrs: [
        systemPool.serviceCidr
      ]
      dnsServiceIP: systemPool.dnsServiceIp
    }
  }
  tags: tags
}

// AKS の kubelet identity に ACR Pull ロールを付与
// Note: ACR は既に存在することを前提とする（main.bicep で作成済み）
var acrName = !empty(acrId) ? last(split(acrId, '/')) : ''

resource existingAcr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = if (!empty(acrId)) {
  name: acrName
}

resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(acrId)) {
  name: guid(acrId, cluster.id, 'AcrPull')
  scope: existingAcr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d') // AcrPull
    principalId: cluster.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

output id string = cluster.id
output principalId string = cluster.identity.principalId
output kubeletIdentity object = cluster.properties.identityProfile.kubeletidentity
output nodeResourceGroup string = cluster.properties.nodeResourceGroup
