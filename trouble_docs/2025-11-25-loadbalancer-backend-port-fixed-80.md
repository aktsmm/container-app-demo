# LoadBalancer Rule の BackendPort が 80 に固定され外部アクセス不能（3回目の再発）

**日時**: 2025-11-25  
**対象リソース**: AKS, Azure LoadBalancer, Ingress Controller  
**Run ID**: 19663062180  
**エラー**: LoadBalancer ポート 80 への接続が6分間のリトライでも失敗

---

## 🔴 問題の概要

Board App Deploy ワークフローで、デプロイ後の疎通確認ステップが失敗。

```
[3/4] LoadBalancer 経由で HTML を取得
❌ HTML 配信失敗
Error: Process completed with exit code 1.
```

### 症状

1. ✅ AKS クラスター: 正常稼働
2. ✅ Ingress Controller: 正常稼働 (4h34m, 1/1 Ready)
3. ✅ Ingress Controller ヘルスチェック: 成功 (HTTP 200)
4. ✅ クラスタ内 Service アクセス: 成功 (HTTP 200)
5. ✅ LoadBalancer IP 割り当て: 完了 (20.18.94.114)
6. ❌ LoadBalancer ポート 80 への外部接続: **6分間（36回）すべて失敗**

### ネットワーク診断結果

```bash
# 6分間のリトライ
[1/36] LoadBalancer ポート 80 接続待機中... (最大6分)
...
[36/36] LoadBalancer ポート 80 接続待機中... (最大6分)
⚠️ LoadBalancer ポート 80 への接続が確認できませんでしたが、続行します
```

---

## 🔍 根本原因

### LoadBalancer Rule の BackendPort が固定値 80 のまま

| 項目                              | 値              | 期待値       | 状態 |
| --------------------------------- | --------------- | ------------ | ---- |
| **Ingress HTTP NodePort**         | **31778**       | -            | ✅   |
| **Ingress Health Check NodePort** | **30254**       | -            | ✅   |
| **LoadBalancer Rule BackendPort** | **80** ← 問題！ | **31778**    | ❌   |
| **LoadBalancer Probe Port**       | **30254**       | **30254**    | ✅   |
| **結果**                          | -               | 通信不可     | ❌   |

### 発生メカニズム

```
インターネット
    ↓ HTTP リクエスト (Port 80)
Azure LoadBalancer (Frontend IP: 20.18.94.114)
    ↓ LoadBalancer Rule: FrontendPort=80 → BackendPort=80 ❌
AKS ノード (VM)
    ↓ Port 80: 何もリッスンしていない ❌
    ↓ Port 31778: Ingress Controller が実際にリッスン中 ✅
    ✗ トラフィックが届かない
```

### Azure Cloud Controller Manager の挙動

`externalTrafficPolicy: Local` の場合:

1. **ヘルスプローブ**: `healthCheckNodePort` (30254) を使用 ✅
2. **トラフィック転送**: `nodePort` (31778) に転送すべき
3. **実際の挙動**: なぜか BackendPort が 80 に固定される ❌

**推定原因**:

- Infrastructure Deploy で Ingress Controller を作成した際、Azure Cloud Controller Manager が LoadBalancer Rule を作成する前に Service の情報が完全に伝播していなかった
- その結果、デフォルト値 80 で LoadBalancer Rule が作成されてしまった
- 一度作成された LoadBalancer Rule は自動的に更新されない

---

## 📊 過去の再発履歴

### 1回目: 2025-01-21

- **ドキュメント**: `2025-01-21-loadbalancer-healthprobe-nodeport-mismatch.md`
- **対策**: `externalTrafficPolicy: Local` を設定
- **結果**: 一時的に解決

### 2回目: 2025-11-24

- **ドキュメント**: `2025-11-24-board-app-deploy-healthprobe-mismatch.md`
- **問題**: Board App Deploy で Ingress Controller を再作成すると NodePort が変わる
- **対策**: Board App Deploy で既存 Ingress Controller をスキップする処理を追加
- **結果**: Board App Deploy 単発実行時は解決したが、Infrastructure Deploy 時の問題は未解決

### 3回目: 2025-11-25 (今回)

- **問題**: Infrastructure Deploy で作成された Ingress Controller の LoadBalancer Rule が不正
- **根本原因**: Azure Cloud Controller Manager が LoadBalancer Rule を作成する際、NodePort 情報が伝播する前にデフォルト値 80 で作成されてしまう

---

## ✅ 恒久的な解決策

### 採用する解決策: LoadBalancer Rule の自動修正

Infrastructure Deploy ワークフローで、Ingress Controller 作成後に以下の処理を追加:

1. **LoadBalancer IP が割り当てられるまで待機** (既存)
2. **LoadBalancer Rule の BackendPort を確認**
3. **BackendPort が NodePort と一致しない場合は自動修正**

**メリット**:

- ✅ 完全な冪等性: 何度実行しても正しい状態になる
- ✅ 自動修復: 手動介入不要
- ✅ 再発防止: Infrastructure Deploy 時に必ず修正される

### 実装方針

```bash
# ステップ1: NodePort を取得
HTTP_NODEPORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
HTTPS_NODEPORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')

# ステップ2: LoadBalancer Rule を確認
NODE_RG=$(az aks show --resource-group "$RESOURCE_GROUP_NAME" \
  --name "$AKS_CLUSTER_NAME" --query nodeResourceGroup -o tsv)

LB_RULES=$(az network lb rule list --resource-group "$NODE_RG" \
  --lb-name kubernetes --query "[?frontendPort==\`80\` || frontendPort==\`443\`]" -o json)

# ステップ3: BackendPort が NodePort と一致しない場合は修正
for rule in $(echo "$LB_RULES" | jq -r '.[] | @base64'); do
  _jq() {
    echo "$rule" | base64 --decode | jq -r "$1"
  }
  RULE_NAME=$(_jq '.name')
  FRONTEND_PORT=$(_jq '.frontendPort')
  BACKEND_PORT=$(_jq '.backendPort')
  
  if [ "$FRONTEND_PORT" = "80" ] && [ "$BACKEND_PORT" != "$HTTP_NODEPORT" ]; then
    echo "⚠️ LoadBalancer Rule の BackendPort (HTTP) を修正: $BACKEND_PORT → $HTTP_NODEPORT"
    az network lb rule update --resource-group "$NODE_RG" --lb-name kubernetes \
      --name "$RULE_NAME" --backend-port "$HTTP_NODEPORT"
  fi
  
  if [ "$FRONTEND_PORT" = "443" ] && [ "$BACKEND_PORT" != "$HTTPS_NODEPORT" ]; then
    echo "⚠️ LoadBalancer Rule の BackendPort (HTTPS) を修正: $BACKEND_PORT → $HTTPS_NODEPORT"
    az network lb rule update --resource-group "$NODE_RG" --lb-name kubernetes \
      --name "$RULE_NAME" --backend-port "$HTTPS_NODEPORT"
  fi
done
```

---

## 🔧 手動修復方法（緊急時）

現在の環境を今すぐ修復する場合:

```bash
# 1. NodePort を確認
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' && echo

# 出力例: 31778

# 2. LoadBalancer Rule を修正
NODE_RG="mc-RG-cicd-Quick-demo"
LB_NAME="kubernetes"
RULE_NAME="af5f11047e122466eb9f86df9f511087-TCP-80"
HTTP_NODEPORT="31778"

az network lb rule update \
  --resource-group "$NODE_RG" \
  --lb-name "$LB_NAME" \
  --name "$RULE_NAME" \
  --backend-port "$HTTP_NODEPORT"

# 3. 確認
az network lb rule show --resource-group "$NODE_RG" --lb-name "$LB_NAME" \
  --name "$RULE_NAME" --query '{FrontendPort:frontendPort,BackendPort:backendPort}' -o table

# 4. 疎通テスト
LB_IP="20.18.94.114"
curl -I "http://${LB_IP}/"
```

---

## 📝 ワークフロー修正内容

### 修正対象ファイル

- `.github/workflows/1-infra-deploy.yml`
  - Ingress Controller 作成後に LoadBalancer Rule 自動修正ステップを追加

### 修正ポイント

1. **Ingress Controller 作成 → LoadBalancer IP 割り当て待機** (既存)
2. **新規追加**: LoadBalancer Rule の BackendPort 自動修正
3. **新規追加**: 修正後の疎通確認

---

## 🔗 関連トラブルシューティング

- `2025-01-21-loadbalancer-healthprobe-nodeport-mismatch.md`: 初回発生
- `2025-11-21-aks-loadbalancer-nodeport-mismatch.md`: NodePort 不一致の詳細分析
- `2025-11-24-board-app-deploy-healthprobe-mismatch.md`: Board App Deploy 時の再発

---

## 📚 参考情報

### Azure LoadBalancer Rule の仕様

- **FrontendPort**: 外部からのアクセスポート (80, 443)
- **BackendPort**: ノード (VM) のリッスンポート (NodePort)
- **Probe**: ヘルスチェック用ポート (`healthCheckNodePort`)

### externalTrafficPolicy: Local の挙動

- ヘルスプローブは `healthCheckNodePort` を使用
- トラフィックは各ポートの `nodePort` に転送される
- Azure Cloud Controller Manager が自動的に LoadBalancer Rule を作成
- **問題**: Rule 作成時に NodePort 情報が伝播していないと、デフォルト値 (FrontendPort と同じ値) で作成される

### なぜ3回も再発したか

1. **1回目の対策**: `externalTrafficPolicy: Local` 設定 → **不十分**（Rule 作成タイミングの問題が未解決）
2. **2回目の対策**: Board App Deploy で Ingress Controller をスキップ → **部分的解決**（Infrastructure Deploy の問題は残存）
3. **3回目（今回）**: Infrastructure Deploy で作成された LoadBalancer Rule が不正 → **恒久的解決が必要**

### 恒久的解決の必要性

- Azure Cloud Controller Manager の動作タイミングは制御できない
- Infrastructure Deploy で **必ず LoadBalancer Rule を検証・修正** する処理を追加
- 冪等性を保証し、何度実行しても正しい状態にする
