# Azure リソース 24 時間自動停止 - 完全復旧ガイド

**作成日時**: 2025-11-26  
**最終更新**: 2025-11-26  
**Status**: ✅ **解決済み - ワークフロー 1 本で完全自動復旧**

---

## 📋 問題概要

組織の Azure Policy により、**AKS クラスター** と **MySQL VM** が **24 時間に 1 回自動停止** される。
停止後は複数のネットワーク設定がリセットされ、手動での復旧作業が必要だった。

### 発生する問題一覧

| # | 問題 | 症状 | 自動修正 |
|---|------|------|---------|
| 1 | AKS/VM 停止 | クラスター・DB にアクセス不可 | ✅ |
| 2 | LB BackendPort リセット | HTTP 000 タイムアウト | ✅ |
| 3 | サブネット NSG ルール欠落 | 外部からアクセス不可 | ✅ |
| 4 | externalTrafficPolicy 不整合 | DSR 関連の接続問題 | ✅ |
| 5 | MySQL 接続エラー | API で DB 取得失敗 | ✅ |

---

## 🎯 解決策: Health Check ワークフロー

**`azure-health-check.yml` を実行するだけで全て自動復旧！**

```bash
gh workflow run azure-health-check.yml
```

### 自動修正される項目

```
┌─────────────────────────────────────────────────────────────┐
│                 azure-health-check.yml                      │
├─────────────────────────────────────────────────────────────┤
│ Step 1-2: AKS/VM 起動                                       │
│   └─ 停止検知 → az aks start / az vm start                  │
│                                                             │
│ Step 3: Pod 再起動                                          │
│   └─ VM 復旧時は board-api Pod を自動再起動                  │
│                                                             │
│ Step 4.5: externalTrafficPolicy 修正                        │
│   └─ Local → Cluster に変更（DSR 問題回避）                  │
│                                                             │
│ Step 4.6: DSR 設定修正                                      │
│   └─ enableFloatingIP / disableOutboundSnat を無効化        │
│                                                             │
│ Step 4.6.1: LB BackendPort 修正  ← 今回追加                 │
│   └─ 80/443 → NodePort (32573/31489 等) に修正              │
│                                                             │
│ Step 4.7: サブネット NSG ルール追加  ← 今回追加             │
│   └─ HTTP/HTTPS/NodePort の許可ルールを自動追加             │
│                                                             │
│ Step 5: 疎通確認                                            │
│   └─ Board App / API の HTTP 200 確認                       │
└─────────────────────────────────────────────────────────────┘
```

---

## 🔍 問題詳細と原因

### 1. AKS/VM 自動停止

**原因**: 組織の Azure Policy で 24 時間後に自動停止  
**対応**: `az aks start` / `az vm start` で自動起動

### 2. LB BackendPort リセット

**症状**: Pod は Running なのに HTTP 000 タイムアウト

**原因**: AKS 起動後に LB Rule の BackendPort が 80/443 にリセット  
（本来は NodePort 32573/31489 が必要）

```
期待: LB → BackendPort:32573 → Ingress Pod ✅
実際: LB → BackendPort:80 → ??? ❌
```

**確認コマンド**:
```bash
# NodePort 確認
kubectl get svc -n ingress-nginx ingress-nginx-controller
# 80:32573/TCP, 443:31489/TCP

# LB Rule 確認（BackendPort が 80/443 なら問題）
az network lb rule list -g mc-<RG> --lb-name kubernetes \
  --query "[].{name:name, frontendPort:frontendPort, backendPort:backendPort}" -o table
```

### 3. サブネット NSG ルール欠落

**症状**: NIC の NSG には HTTP 許可ルールがあるのにアクセス不可

**原因**: サブネットレベルの NSG に HTTP/HTTPS 許可ルールがない

```
Azure NSG の評価順序:
外部 → [サブネット NSG] → [NIC NSG] → Pod
         ↑ ここで DenyAllInBound
```

**確認コマンド**:
```bash
# サブネット NSG のルール確認
SUBNET_ID=$(az aks show -g <RG> -n <AKS> --query "agentPoolProfiles[0].vnetSubnetId" -o tsv)
NSG_ID=$(az network vnet subnet show --ids "$SUBNET_ID" --query "networkSecurityGroup.id" -o tsv)
NSG_NAME=$(echo $NSG_ID | cut -d'/' -f9)
NSG_RG=$(echo $NSG_ID | cut -d'/' -f5)

az network nsg rule list -g $NSG_RG --nsg-name $NSG_NAME \
  --query "[?direction=='Inbound'].{name:name, port:destinationPortRange}" -o table
```

### 4. externalTrafficPolicy 不整合

**症状**: DSR 関連のタイムアウト

**原因**: `externalTrafficPolicy: Local` だと SNAT されず、GitHub Actions からの応答が破棄される

**対応**: `Cluster` に変更して SNAT を有効化

### 5. healthCheckNodePort エラー（過去の問題）

**症状**: Helm upgrade で `healthCheckNodePort: Invalid value` エラー

**原因**: `externalTrafficPolicy: Cluster` なのに `healthCheckNodePort` を固定指定

**対応**: `healthCheckNodePort` 設定を削除（Azure LB の共有プローブに任せる）

---

## 📊 実行結果

### 正常復旧時のログ例

```
🔍 AKS クラスター状態確認
  - 電源状態: Stopped
🔄 AKS クラスターを起動中...
✅ AKS クラスター起動完了

🔍 MySQL VM 状態確認
  - 電源状態: VM deallocated
🔄 MySQL VM を起動中...
✅ MySQL VM 起動完了
🔄 board-api Pod を再起動中...

🔍 Load Balancer BackendPort 確認
  - HTTP: BackendPort=80 → 期待: 32573
⚠️ BackendPort が不正です
🔧 BackendPort を修正中...
✅ 修正完了: BackendPort=32573

🔍 サブネット NSG 確認
⚠️ HTTP (80) 許可ルールがありません
🔧 HTTP 許可ルールを追加中...
✅ HTTP 許可ルール追加完了

🔍 外部疎通確認
✅ Board App: HTTP 200 OK
✅ Board API: HTTP 200 OK

🎉 ヘルスチェック完了 - すべて正常
```

---

## ⚠️ 手動確認コマンド

```bash
# AKS 状態確認
az aks show -g $RG -n $AKS --query 'powerState.code' -o tsv

# VM 状態確認
az vm get-instance-view -g $RG -n $VM --query 'instanceView.statuses[1].displayStatus' -o tsv

# Pod 状態確認
kubectl get pods -A | grep -E "ingress|board"

# 疎通確認
curl -I http://<LB_IP>/
curl http://<LB_IP>/api/posts

# LB Rule 確認
az network lb rule list -g mc-$RG --lb-name kubernetes -o table

# サブネット NSG ルール確認
az network nsg rule list -g $RG --nsg-name <NSG_NAME> -o table
```

---

## 📝 関連ドキュメント

- [AKS LoadBalancer 接続問題](./2025-11-21-aks-loadbalancer-connection-issue.md)
- [AKS DNS 解決失敗](./2025-11-23-aks-dns-resolution-failure.md)
- [LoadBalancer BackendPort 固定 80 問題](./2025-11-25-loadbalancer-backend-port-fixed-80.md)
- [Azure NSG 概要 (Microsoft Learn)](https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview)
- [Azure Load Balancer 構成 (Microsoft Learn)](https://learn.microsoft.com/azure/load-balancer/load-balancer-overview)

---

## ✅ 結論

**`azure-health-check.yml` を実行するだけで、24 時間自動停止後の全ての問題が自動復旧される。**

再デプロイ（Board App Build & Deploy）は **不要**。
