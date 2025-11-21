targetScope = 'resourceGroup'

@description('仮想ネットワーク名')
param name string

@description('リソース配置リージョン')
param location string

@description('VNet全体のアドレス空間（CIDR）')
param addressSpace string

@description('作成するサブネットの設定一覧（各要素に name と properties を含める）')
param subnets array

@description('共通タグ')
param tags object = {}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressSpace
      ]
    }
    subnets: [
      for subnet in subnets: {
        name: subnet.name
        properties: subnet.properties
      }
    ]
  }
}

output id string = virtualNetwork.id
output subnetIds array = [
  for subnet in subnets: {
    name: subnet.name
    id: resourceId('Microsoft.Network/virtualNetworks/subnets', name, subnet.name)
  }
]
