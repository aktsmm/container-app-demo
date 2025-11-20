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

@description('Ingress用Static Public IP名')
param ingressPublicIpName string

@description('共通タグ')
param tags object = {}

// Ingress Controller用のStatic Public IP（Standard SKU必須）
resource ingressPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: ingressPublicIpName
  location: location
  sku: {
    name: 'Standard'  // AKS Standard Load Balancerに必須
  }
  properties: {
    publicIPAllocationMethod: 'Static'  // Standard SKUではStaticのみ可
    publicIPAddressVersion: 'IPv4'
  }
  tags: tags
}

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

output id string = cluster.id
output principalId string = cluster.identity.principalId
output kubeletIdentity object = cluster.properties.identityProfile.kubeletidentity
output nodeResourceGroup string = cluster.properties.nodeResourceGroup
output ingressPublicIpAddress string = ingressPublicIp.properties.ipAddress
output ingressPublicIpId string = ingressPublicIp.id
