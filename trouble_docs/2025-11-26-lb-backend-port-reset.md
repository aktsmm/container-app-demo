# 2025-11-26 AKS 起動後の LB BackendPort リセット問題

## 事象概要

- AKS を起動後、`curl http://<LB_IP>/` がタイムアウト（HTTP 000）
- Pod は Running 状態、NSG ルールも正常
- Health Probe も 100% Healthy
- **しかし実際には接続できない**

## 原因

AKS 起動後に Azure Load Balancer の **BackendPort が 80/443 にリセット**されていた。

### 期待される構成

```
外部クライアント → LB (FrontendPort: 80) → BackendPort: NodePort (例: 32573) → Ingress Pod
```

### 問題の構成

```
外部クライアント → LB (FrontendPort: 80) → BackendPort: 80 → ??? (何も応答しない)
```

### 確認コマンド

```bash
# 1. Ingress Controller の NodePort を確認
kubectl get svc -n ingress-nginx ingress-nginx-controller
# 出力例: 80:32573/TCP, 443:31489/TCP

# 2. LB Rule の BackendPort を確認
az network lb rule list -g mc-<RG> --lb-name kubernetes \
  --query "[].{name:name, frontendPort:frontendPort, backendPort:backendPort}" -o table
# 問題時: BackendPort が 80, 443 になっている（NodePort ではない）
```

## 対応

LB Rule の BackendPort を正しい NodePort に修正：

```bash
# HTTP の BackendPort を NodePort に修正
az network lb rule update -g "mc-rg-cicd-demo" --lb-name "kubernetes" \
  -n "<RULE_NAME>-TCP-80" --backend-port 32573

# HTTPS の BackendPort を NodePort に修正
az network lb rule update -g "mc-rg-cicd-demo" --lb-name "kubernetes" \
  -n "<RULE_NAME>-TCP-443" --backend-port 31489
```

## ワークフローへの組み込み

`azure-health-check.yml` の Step 4.6.1 に「Load Balancer BackendPort 確認・補正」ステップを追加。

処理内容：

1. `kubectl` で Ingress Controller の実際の NodePort を取得
2. Azure LB Rule の BackendPort と比較
3. 不一致があれば自動修正

## 根本原因の考察

- AKS が停止・起動されると Kubernetes Service が再作成される
- その際、Azure Cloud Controller Manager が LB Rule を再構成
- 何らかの理由で BackendPort が NodePort ではなく Port (80/443) に設定されることがある
- 特に 24 時間自動停止ポリシーが適用されている環境で発生しやすい

## 関連ドキュメント

- [trouble_docs/2025-11-25-loadbalancer-backend-port-fixed-80.md](./2025-11-25-loadbalancer-backend-port-fixed-80.md)
- [trouble_docs/2025-11-21-aks-loadbalancer-connection-issue.md](./2025-11-21-aks-loadbalancer-connection-issue.md)
- [Azure Load Balancer の構成](https://learn.microsoft.com/azure/load-balancer/load-balancer-overview)
