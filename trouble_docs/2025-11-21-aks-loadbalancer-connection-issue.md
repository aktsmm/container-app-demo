# AKS Load Balancer 接続問題のトラブルシューティング

**作成日時**: 2025-11-21  
**Status**: 🔴 **調査中**

---

## 📋 問題概要

Board App（AKS 上の ingress-nginx）に External IP は割り当てられるが、外部から接続できない問題が発生。

### 現象

- ✅ AKS Service は `LoadBalancer` type で作成される
- ✅ External IP が割り当てられる（例: `4.190.67.118`）
- ✅ Azure Load Balancer ルールが作成される
- ✅ バックエンドプールに VMSS ノードが登録される
- ✅ ヘルスプローブは正常（NodePort 経由で `/healthz` が `200 OK` を返す）
- ❌ **外部からの HTTP/HTTPS 接続が失敗**（タイムアウト）

### 発生タイミング

- 直近のワークフロー実行後
- Static IP → Dynamic IP への切り替え実施後
- Bicep で ACR Pull ロール自動割り当て実装後

---

## 🔍 調査内容

### 1️⃣ Kubernetes Service 状態

```bash
$ kubectl get service -n ingress-nginx ingress-nginx-controller
NAME                       TYPE           CLUSTER-IP   EXTERNAL-IP    PORT(S)                      AGE
ingress-nginx-controller   LoadBalancer   10.10.0.39   4.190.67.118   80:30682/TCP,443:30487/TCP   5m
```

**結果**: ✅ External IP `4.190.67.118` 正常に割り当て

### 2️⃣ Pod 状態

```bash
$ kubectl get pods -n ingress-nginx
NAME                                        READY   STATUS    RESTARTS   AGE
ingress-nginx-controller-7574477b4d-xxxxx   1/1     Running   0          5m

$ kubectl get pods -n board-app
NAME                         READY   STATUS    RESTARTS   AGE
board-api-xxxxxxxxxx-xxxxx   1/1     Running   0          5m
board-app-xxxxxxxxxx-xxxxx   1/1     Running   0          5m
```

**結果**: ✅ すべての Pod が `Running` 状態

### 3️⃣ Azure Load Balancer ルール

```bash
$ az network lb rule show --resource-group mc-RG-bbs-app999 --lb-name kubernetes \
  --name a8b2649f359094786a6d52bd3b849174-TCP-80
```

**結果**:

- ✅ Frontend IP Configuration: 正しく設定
- ✅ Backend Address Pool: `kubernetes` プールに関連付け
- ✅ Probe: `a8b2649f359094786a6d52bd3b849174-TCP-32550` に関連付け
- ✅ Port 80 → 80 のマッピング正常

### 4️⃣ バックエンドプール

```bash
$ az network lb address-pool show --resource-group mc-RG-bbs-app999 \
  --lb-name kubernetes --name kubernetes
```

**結果**:

- ✅ BackendCount: 1
- ✅ VMSS ノード (`aks-systempool-37775191-vmss/virtualMachines/0`) が登録済み

### 5️⃣ ヘルスプローブ

```bash
$ az network lb probe show --resource-group mc-RG-bbs-app999 --lb-name kubernetes \
  --name a8b2649f359094786a6d52bd3b849174-TCP-32550
```

**設定**:

- Protocol: `Http`
- Port: `32550` (Service の `healthCheckNodePort` と一致)
- Request Path: `/healthz`
- Interval: 5 秒
- Number of Probes: 2

**内部確認（ノードから）**:

```bash
$ kubectl run test-healthcheck --image=curlimages/curl:latest --rm -i --restart=Never \
  -- curl -s http://10.0.0.4:32550/healthz
{
  "service": {
    "namespace": "ingress-nginx",
    "name": "ingress-nginx-controller"
  },
  "localEndpoints": 1,
  "serviceProxyHealthy": true
}
```

**結果**: ✅ ヘルスチェックは内部から正常

### 6️⃣ NSG（Network Security Group）

```bash
$ az network nsg rule list --resource-group mc-RG-bbs-app999 \
  --nsg-name aks-agentpool-75522612-nsg --query "[?direction=='Inbound' && access=='Allow']"
```

**結果**:

- ✅ ルール `k8s-azure-lb_allow_IPv4_xxx`:
  - Source: `Internet`
  - Destination Ports: `80`, `443`
  - Protocol: `Tcp`
  - Access: `Allow`
  - Priority: 500

### 7️⃣ AKS ネットワーク設定

```bash
$ az aks show --resource-group RG-bbs-app999 --name aks-demo-dev \
  --query "networkProfile"
```

**結果**:

- ✅ Network Plugin: `azure`（Azure CNI）
- ✅ Network Policy: `none`
- ✅ Load Balancer SKU: `standard`
- ✅ Outbound Type: `loadBalancer`
- ✅ Service CIDR: `10.10.0.0/24`

### 8️⃣ 外部からの接続テスト

```bash
$ curl -I http://4.190.67.118 --connect-timeout 10
curl: (28) Connection timed out after 10011 milliseconds
```

**結果**: ❌ 接続タイムアウト

---

## 🚨 特定した問題パターン

### 問題パターン A: Frontend IP Configuration が `null`

初回のデプロイ時（Run 19557252281）に発生:

```json
{
  "Frontend": null,
  "Name": "af19133c0daa24fee96e47c6ccf962ef-TCP-80",
  "Backend": "/subscriptions/.../kubernetes/backendAddressPools/kubernetes",
  "Probe": "/subscriptions/.../kubernetes/probes/af19133c0daa24fee96e47c6ccf962ef-TCP-31042"
}
```

**手動修正で一時的に解決**:

```bash
$ az network lb rule update --resource-group mc-RG-bbs-app999 --lb-name kubernetes \
  --name af19133c0daa24fee96e47c6ccf962ef-TCP-80 \
  --frontend-ip-name af19133c0daa24fee96e47c6ccf962ef
```

しかし、**手動修正後も外部からの接続は失敗**。

### 問題パターン B: Load Balancer 設定は完璧だが接続できない

2 回目のデプロイ（Run 19557533418）では、Frontend IP Configuration が最初から正しく設定されているが、**それでも外部から接続できない**。

---

## 🔎 推測される根本原因

### 仮説 1: Azure Load Balancer のバックエンドヘルスが `Unhealthy`

**可能性**: ヘルスプローブが NodePort に到達できていない

**調査方法**:

- Azure Portal → Load Balancer → Insights → Backend Health
- または Azure Monitor で `DipAvailability` メトリクスを確認

### 仮説 2: AKS Cloud Provider の既知の問題

**可能性**: AKS 1.32.9 と Azure Cloud Provider の互換性問題

**根拠**:

- Frontend IP が `null` になる現象は、過去の AKS Cloud Provider バグで報告されている
- Dynamic IP への切り替え後に発生

### 仮説 3: NSG ルールの伝播遅延

**可能性**: NSG ルールが実際の VMSS インスタンスに適用されるまで時間がかかる

**調査方法**:

```bash
$ az vmss list-instances --resource-group mc-RG-bbs-app999 \
  --name aks-systempool-37775191-vmss \
  --query "[].{Name:name, HealthState:instanceView.statuses}"
```

### 仮説 4: Service `externalTrafficPolicy: Local` による問題

**可能性**: `Local` ポリシーで、ノードに Pod がない場合に接続できない

**確認**:

```bash
$ kubectl get service ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.spec.externalTrafficPolicy}'
# 結果: Local
```

**ingress-nginx Pod がどのノードで動いているか**:

```bash
$ kubectl get pods -n ingress-nginx -o wide
NAME                                        NODE
ingress-nginx-controller-7574477b4d-vdhgb   aks-systempool-37775191-vmss000000
```

**ノード数**:

```bash
$ kubectl get nodes
NAME                                 STATUS   ROLES    AGE
aks-systempool-37775191-vmss000000   Ready    <none>   7h
```

**結果**: ノードは 1 つのみで、Pod も同じノード上にあるため、`Local` ポリシーは問題ないはず。

### 仮説 5: Bicep で作成された Static Public IP リソースの干渉

**可能性**: Bicep の `infra/modules/aks.bicep` で `ingressPublicIp` リソースを定義しているが、実際にはワークフローで使用していない

**確認**:

```bash
$ az network public-ip show --resource-group RG-bbs-app999 --name pip-ingress-demo-dev
(ResourceNotFound) The Resource '...' was not found.
```

**結果**: リソースは存在しないため、干渉はない。

---

## 🛠️ 試行した対処法

### ✅ 試行 1: Frontend IP Configuration の手動設定

```bash
$ az network lb rule update --resource-group mc-RG-bbs-app999 --lb-name kubernetes \
  --name af19133c0daa24fee96e47c6ccf962ef-TCP-80 \
  --frontend-ip-name af19133c0daa24fee96e47c6ccf962ef
```

**結果**: Frontend IP は設定されたが、接続は失敗

### ✅ 試行 2: Service 削除 → ワークフロー再実行

```bash
$ kubectl delete service ingress-nginx-controller -n ingress-nginx
$ gh workflow run 3-deploy-board-app.yml
```

**結果**: 新しい IP が割り当てられ、Frontend IP も最初から正しく設定されたが、接続は失敗

### ✅ 試行 3: Namespace 完全削除 → ワークフロー再実行

```bash
$ kubectl delete namespace ingress-nginx
$ gh workflow run 3-deploy-board-app.yml
```

**結果**: 完全にクリーンな状態からデプロイされたが、接続は失敗

### ✅ 試行 4: 長時間待機（Load Balancer ヘルスプローブの安定化）

```bash
$ Start-Sleep -Seconds 120
$ curl -I http://4.190.67.118 --connect-timeout 10
```

**結果**: 120 秒待機後も接続失敗

---

## 📊 現在の状態（Run 19557533418 後）

| 項目                          | 状態 |
| ----------------------------- | ---- |
| **Kubernetes Service**        | ✅   |
| **External IP 割り当て**      | ✅   |
| **Pod Running**               | ✅   |
| **Load Balancer ルール**      | ✅   |
| **Frontend IP Configuration** | ✅   |
| **Backend Address Pool**      | ✅   |
| **Health Probe 設定**         | ✅   |
| **Health Probe 内部テスト**   | ✅   |
| **NSG ルール**                | ✅   |
| **外部からの接続**            | ❌   |

---

## 🎯 次のステップ

### 優先度 1: Azure Portal でバックエンドヘルスを確認

Azure Portal → Load Balancer → Insights → Backend Health を確認し、バックエンドが `Healthy` になっているか確認する。

### 優先度 2: Azure Monitor でメトリクスを確認

以下のメトリクスを確認:

- `DipAvailability` (Backend Health)
- `VipAvailability` (Frontend Health)
- `ByteCount` (データ転送量)
- `SYNCount` (SYN パケット数)

### 優先度 3: AKS Cloud Provider ログを確認

マネージドコントロールプレーンのログにアクセスできないため、Azure サポートに問い合わせる必要がある可能性。

### 優先度 4: 代替アプローチの検討

- **オプション A**: `externalTrafficPolicy: Cluster` に変更
- **オプション B**: NodePort Service を使用してテスト
- **オプション C**: Azure Application Gateway + AKS Ingress Controller を使用

---

## 📎 関連ドキュメント

- [2025-11-21-deploy-workflows-troubleshooting.md](./2025-11-21-deploy-workflows-troubleshooting.md) - デプロイワークフロー全体のトラブルシューティング
- [README_INFRASTRUCTURE.md](../READMEs/README_INFRASTRUCTURE.md) - インフラ構成詳細

---

## 🔧 ワークフロー実行履歴

| Run ID      | 結果 | External IP   | Frontend IP | 接続テスト |
| ----------- | ---- | ------------- | ----------- | ---------- |
| 19557252281 | 成功 | 74.176.234.81 | ❌ null     | ❌ 失敗    |
| 19557533418 | 成功 | 4.190.67.118  | ✅ 設定済み | ❌ 失敗    |

---
## 🚧 新たな恒久対処（Static IP を AKS マネージド RG で確保）

### 背景

- `loadBalancerIP` をユーザー RG (例: `RG-bbs-app999`) の Public IP に固定すると、AKS の Managed Identity が `Microsoft.Network/publicIPAddresses/*` にアクセスできず `AuthorizationFailed` になることを 2025-11-21 午前の再現実験で確認。
- Microsoft 公式ガイドでも、AKS Service に静的 IP を割り当てる場合は **ノードリソースグループ (mc-*) に Public IP を作成し、その RG 名を Service annotation で参照する** 必要があると明記されている（[Use a static public IP with AKS](https://learn.microsoft.com/azure/aks/static-ip)）。

### 実施内容（2025-11-21 午後）

1. `.github/workflows/3-deploy-board-app.yml` の `ingress-controller` ジョブに **「Ingress 用 Static Public IP を確保」** ステップを追加。
   - `az aks show --query nodeResourceGroup` でノード RG を取得し、`NODE_RESOURCE_GROUP` としてエクスポート。
   - `jq '.parameters.ingressPublicIpName.value'` でパラメータファイルの IP 名を取得し、ノード RG 内で `az network public-ip show/create` を実行して Standard SKU/Static IP を確保。
   - 取得した IP を `INGRESS_STATIC_IP` に保存し、後続 Step から参照可能にする。
2. NSG ルール適用 Step を関数化し、`AzureLoadBalancer -> NodePort(30000-32767)` と `Internet -> NodePort` の 2 ルールを冪等に作成。
3. Helm upgrade/install Step で `STATIC_IP_ARGS` に `loadBalancerIP` と `service.beta.kubernetes.io/azure-load-balancer-resource-group=<node-rg>` を同時に渡し、ノード RG 内の Static IP を確実に参照。

```bash
# Public IP 作成 & 取得
az network public-ip create \
  --resource-group "$NODE_RG" \
  --name "$PIP_NAME" \
  --sku Standard \
  --allocation-method Static \
  --version IPv4
INGRESS_STATIC_IP=$(az network public-ip show \
  --resource-group "$NODE_RG" \
  --name "$PIP_NAME" \
  --query ipAddress -o tsv)

# Helm で Static IP を反映
STATIC_IP_ARGS="--set controller.service.loadBalancerIP=$INGRESS_STATIC_IP \
  --set controller.service.annotations.\"service.beta.kubernetes.io/azure-load-balancer-resource-group\"=$NODE_RG"
```

### 今後の検証計画

1. 修正済みワークフローを `master` にマージし、`gh workflow run 3-deploy-board-app.yml` を実行。
2. Run 完了後に `kubectl get svc -n ingress-nginx ingress-nginx-controller -o wide` で `EXTERNAL-IP` が `pip-aks-ingress-dev` と一致することを確認。
3. Azure Portal で `pip-aks-ingress-dev` の Resource Group が `mc-*` になっているか確認。
4. `curl -I http://<static-ip>` とブラウザアクセスで疎通確認し、成功したら本ドキュメントのステータスを 🟢 に更新。
5. 併せて `trouble_docs/2025-11-21-deploy-workflows-troubleshooting.md` にも恒久対処を追記。

**Status**: 🟡 **暫定対応（Static IP をノード RG で自動確保する仕組みを実装、検証待ち）**

---

**最終更新**: 2025-11-21 14:20 JST

