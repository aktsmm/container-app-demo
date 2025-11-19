targetScope = 'resourceGroup'

@description('仮想マシン名')
param name string

@description('リージョン')
param location string

@description('サイズ (例: Standard_B1ms)')
param vmSize string = 'Standard_B1ms'

@description('サブネット ID')
param subnetId string

@description('管理者ユーザー名')
param adminUsername string

@description('管理者パスワード')
@secure()
param adminPassword string

@description('MySQL 用ポート (例: 3306)')
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

@description('Log Analytics Workspace Customer ID')
param logAnalyticsCustomerId string

@description('Log Analytics Workspace Shared Key')
@secure()
param logAnalyticsSharedKey string

@description('共通タグ')
param tags object = {}

var mysqlInitScript = loadTextContent('../../scripts/mysql-init.sh')
// スクリプトと引数をすべて base64 エンコードして bash に渡す（引用符エスケープ回避）
var mysqlInitCommand = format('''bash -c "echo {0} | base64 -d > /tmp/mysql-init.sh && chmod +x /tmp/mysql-init.sh && /tmp/mysql-init.sh {1} {2} {3}"''', base64(mysqlInitScript), base64(mysqlRootPassword), base64(mysqlAppUsername), base64(mysqlAppPassword))

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${name}-pip'
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    publicIPAllocationMethod: 'Dynamic'
  }
  tags: tags
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${name}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSSH'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 100
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: string(sshPort)
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowMySQL'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 110
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: string(mysqlPort)
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
  tags: tags
}

resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${name}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: nsg.id
    }
  }
  tags: tags
}

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
    }
    osProfile: {
      computerName: name
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        patchSettings: {
          patchMode: 'ImageDefault'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

// Azure Monitor Agent は Data Collection Rule (DCR) が必要なため一時無効化
// TODO: DCR 作成後に有効化
/*
resource azureMonitorAgent 'Microsoft.Compute/virtualMachines/extensions@2022-11-01' = {
  name: 'AzureMonitorLinuxAgent'
  parent: vm
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    settings: {
      workspaceId: logAnalyticsCustomerId
    }
    protectedSettings: {
      workspaceKey: logAnalyticsSharedKey
    }
  }
}
*/

resource mysqlInit 'Microsoft.Compute/virtualMachines/extensions@2022-11-01' = {
  name: 'MysqlInit'
  parent: vm
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      fileUris: []
    }
    protectedSettings: {
      // Protected settings を利用し、シークレットをログに出さずに MySQL 初期化を実行
      commandToExecute: mysqlInitCommand
    }
  }
}

output id string = vm.id
output publicIpAddress string = publicIp.properties.ipAddress
