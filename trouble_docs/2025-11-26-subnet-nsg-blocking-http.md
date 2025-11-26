# 2025-11-26 サブネット NSG による HTTP/HTTPS ブロック

## 事象概要

- Azure LB の External IP に対して curl すると **HTTP 000**（タイムアウト）が発生
- クラスタ内部からの疎通は正常（Pod 間、NodePort 経由）
- Health Probe は 100% Healthy
- NIC レベルの NSG (`aks-agentpool-*-nsg`) には HTTP/HTTPS 許可ルールあり

## 原因

**サブネットレベルの NSG** (`vnet-*-nsg-japaneast`) にカスタムルールがなく、デフォルトの `DenyAllInBound` (Priority 65500) によりインターネットからの通信がブロックされていた。

### Azure NSG の評価順序

```
外部クライアント
      │
      ▼
┌─────────────────────────────┐
│  サブネット NSG             │ ← ここでブロック
│  - AllowVnetInBound (65000) │
│  - AllowAzureLB (65001)     │
│  - DenyAllInBound (65500)   │ ← インターネットからは拒否
└─────────────────────────────┘
      │
      ▼
┌─────────────────────────────┐
│  NIC NSG                    │ ← ここまで到達しない
│  - Allow-HTTP (320)         │
│  - Allow-HTTPS (330)        │
└─────────────────────────────┘
```

**Azure NSG は NIC とサブネット両方を通過する必要があり、どちらかで拒否されると通信できない。**

## 確認コマンド

```bash
# サブネットに関連付けられた NSG を確認
SUBNET_ID=$(az aks show -g <RG> -n <AKS_NAME> --query "agentPoolProfiles[0].vnetSubnetId" -o tsv)
az network vnet subnet show --ids "$SUBNET_ID" --query "networkSecurityGroup.id" -o tsv

# サブネット NSG のインバウンドルールを確認
az network nsg rule list -g <NSG_RG> --nsg-name <NSG_NAME> \
  --query "[?direction=='Inbound'].{name:name, priority:priority, access:access, destinationPortRange:destinationPortRange}" -o table
```

## 対応

サブネット NSG に HTTP/HTTPS/NodePort の許可ルールを追加：

```bash
NSG_RG="rg-cicd-demo"
NSG_NAME="vnet-demo-dev-snet-aks-nsg-japaneast"

# HTTP (80) 許可
az network nsg rule create -g $NSG_RG --nsg-name $NSG_NAME \
  --name "Allow-HTTP-Inbound" --priority 100 \
  --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes "*" --destination-port-ranges 80

# HTTPS (443) 許可
az network nsg rule create -g $NSG_RG --nsg-name $NSG_NAME \
  --name "Allow-HTTPS-Inbound" --priority 110 \
  --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes "*" --destination-port-ranges 443

# NodePort (30000-32767) 許可
az network nsg rule create -g $NSG_RG --nsg-name $NSG_NAME \
  --name "Allow-NodePort-Inbound" --priority 120 \
  --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes "*" --destination-port-ranges "30000-32767"
```

## ワークフローへの組み込み

`azure-health-check.yml` の Step 4.7 に「サブネット NSG 確認・補正」ステップを追加。
AKS 起動後に自動でサブネット NSG を確認し、必要なルールがなければ追加する。

## 今後の防止策

- Bicep テンプレートでサブネット NSG を作成する際に、HTTP/HTTPS/NodePort の許可ルールを含める
- ヘルスチェックワークフローで自動検出・修正するため、再発しても自動復旧される

## 関連ドキュメント

- [Azure NSG 概要](https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview)
- [NSG の評価順序](https://learn.microsoft.com/azure/virtual-network/network-security-group-how-it-works)
