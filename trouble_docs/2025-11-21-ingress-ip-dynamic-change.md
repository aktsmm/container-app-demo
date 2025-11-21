# Ingress Load Balancer IP が再デプロイ時に変更される問題

**日時**: 2025 年 11 月 21 日  
**影響範囲**: AKS Ingress Controller (NGINX)  
**ステータス**: ✅ 解決済み

---

## 📋 問題の概要

Ingress Controller を再デプロイするたびに Load Balancer の Public IP アドレスが変更され、アクセス URL が不安定になる。

### 現象

- 初回デプロイ時: `4.190.34.52`
- 再デプロイ後: `4.190.32.132`
- IP が固定されず、再デプロイのたびに新しい IP が割り当てられる

---

## 🔍 原因分析

### 1. 現状の構成確認

```powershell
# Load Balancer SKU の確認
az aks show --resource-group RG-bbs-app10000 --name aks-demo-dev --query "networkProfile.loadBalancerSku" -o tsv
# 結果: standard

# Public IP SKU の確認
az network public-ip show --resource-group mc-RG-bbs-app10000 --name kubernetes-a8e6365aec03b49d1adb779b9af29e05 --query "{Name:name, IP:ipAddress, SKU:sku.name, AllocationMethod:publicIPAllocationMethod}" -o table
# 結果: Standard / Static
```

### 2. 根本原因

- **Azure リソースとして Public IP を事前作成していない**
- Kubernetes が Ingress Controller デプロイ時に**動的に Public IP を作成**
- Standard SKU + Static 割り当てだが、Bicep で管理されていないため**削除・再作成のたびに新しい IP が生成される**
- Helm values または kubectl で**特定の IP を指定していない**

### 3. Azure Public IP の仕様

| SKU          | 割り当て方法            | Load Balancer SKU |
| ------------ | ----------------------- | ----------------- |
| Basic        | Dynamic / Static 両方可 | Basic LB のみ     |
| **Standard** | **Static のみ**         | Standard LB 必須  |

Standard SKU では `publicIPAllocationMethod: 'Static'` が必須だが、**事前作成して明示的に指定しない限り、リソースが削除・再作成されるたびに新しい IP が割り当てられる**。

---

## ✅ 解決策

### 実装内容

#### 1. Bicep で Static Public IP を事前作成

**ファイル**: `infra/modules/aks.bicep`

```bicep
@description('Ingress用Static Public IP名')
param ingressPublicIpName string

// Ingress Controller用のStatic Public IP(Standard SKU必須)
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

// Output に IP アドレスを追加
output ingressPublicIpAddress string = ingressPublicIp.properties.ipAddress
output nodeResourceGroup string = cluster.properties.nodeResourceGroup
```

#### 2. Parameters ファイルに追加

**ファイル**: `infra/parameters/main-dev.parameters.json`

```json
"ingressPublicIpName": {
  "value": "pip-aks-ingress-dev"
}
```

#### 3. main.bicep で Output 公開

**ファイル**: `infra/main.bicep`

```bicep
@description('Ingress用Static Public IP名')
param ingressPublicIpName string

module aks './modules/aks.bicep' = if (!aksSkipCreate) {
  params: {
    // ... 既存パラメータ ...
    ingressPublicIpName: ingressPublicIpName
  }
}

output aksNodeResourceGroup string = aksSkipCreate ? aksNodeResourceGroup : aks!.outputs.nodeResourceGroup
output ingressPublicIpAddress string = aksSkipCreate ? '' : aks!.outputs.ingressPublicIpAddress
```

#### 4. Workflow で Static IP を指定

**ファイル**: `.github/workflows/3-deploy-board-app.yml`

```bash
# Bicep でデプロイした Static Public IP を取得
STATIC_IP=$(az network public-ip show \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name pip-aks-ingress-dev \
  --query ipAddress -o tsv 2>/dev/null || echo "")

# AKS の Managed Resource Group 名を取得
NODE_RG=$(az aks show \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "$AKS_CLUSTER_NAME" \
  --query nodeResourceGroup -o tsv)

# Helm install/upgrade 時に Static IP を指定
STATIC_IP_ARGS=""
if [ -n "$STATIC_IP" ]; then
  STATIC_IP_ARGS="--set controller.service.loadBalancerIP=$STATIC_IP --set controller.service.annotations.\"service\.beta\.kubernetes\.io/azure-load-balancer-resource-group\"=$NODE_RG"
fi

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.replicaCount=1 \
  --set controller.service.externalTrafficPolicy=Local \
  $STATIC_IP_ARGS \
  --wait --timeout=5m
```

## 🔧 適用手順

### 1. Infrastructure Deploy ワークフローを実行

```bash
# GitHub Actions で "1️⃣ Infrastructure Deploy" を手動実行
# または infra/ ディレクトリに変更を push
```

これにより `pip-aks-ingress-dev` という名前で Static Public IP が作成される。

### 2. Deploy Board App ワークフローを実行

```bash
# GitHub Actions で "3️⃣ Deploy Board App (AKS)" を実行
```

Ingress Controller が作成済みの Static IP を使用し、以降は **IP が固定される**。2025-11-22 以降は Bicep が DNS ラベル (`ingressPublicIpDnsLabel`) まで払い出すため、ワークフローは `az network public-ip show` から FQDN を解決し、アプリは IP ではなく DNS 名でアクセスする。

### 3. 確認

```powershell
# Public IP の確認
az network public-ip show --resource-group RG-bbs-app-demo --name pip-aks-ingress-dev --query ipAddress -o tsv

# Ingress Controller Service の確認
kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

両方のコマンドで **同じ IP アドレス** が表示されることを確認。

---

## 📝 技術的な補足

### Kubernetes Service の loadBalancerIP 指定

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-resource-group: "mc-RG-bbs-app10000"
spec:
  type: LoadBalancer
  loadBalancerIP: "4.190.34.52" # 事前作成した Static IP を指定
```

### Helm での指定方法

```bash
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --set controller.service.loadBalancerIP=4.190.34.52 \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-resource-group"=mc-RG-bbs-app10000
```

---

## 🎯 結果

- ✅ IP アドレスが固定され、再デプロイしても変更されない
- ✅ DNS やアクセス URL の更新が不要
- ✅ IaC (Bicep) で完全に管理可能
- ✅ コスト影響なし（Standard Public IP は既に使用中）

---

## 🔗 参考リンク

- [Azure Load Balancer SKUs](https://learn.microsoft.com/azure/load-balancer/skus)
- [Azure Public IP addresses](https://learn.microsoft.com/azure/virtual-network/ip-services/public-ip-addresses)
- [AKS Load Balancer](https://learn.microsoft.com/azure/aks/load-balancer-standard)
- [NGINX Ingress Controller - Azure](https://kubernetes.github.io/ingress-nginx/deploy/#azure)

---

## 📌 教訓

1. **Standard Load Balancer では Public IP の事前作成が推奨**
2. **IaC で管理しないリソースは削除・再作成時に値が変わる**
3. **Helm values で明示的に IP を指定しないと動的割り当てになる**
4. **Bicep の output を活用してワークフローに値を渡す**
