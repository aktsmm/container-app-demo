# AKS DNS 解決失敗によるデプロイ失敗

## 📅 発生日時
2025-11-23 00:20:17 UTC

## 🔴 問題の概要
`2️⃣ Board App Build & Deploy` ワークフローの `deploy` ジョブが失敗。
`kubectl` コマンドが AKS クラスターの API サーバーに接続できず、DNS 解決エラーが発生。

## ❌ エラーメッセージ
```
error: error validating "STDIN": error validating data: failed to download openapi: 
Get "https://aksdemodev-nxzok1nt.hcp.japaneast.azmk8s.io:443/openapi/v2?timeout=32s": 
dial tcp: lookup aksdemodev-nxzok1nt.hcp.japaneast.azmk8s.io on 127.0.0.53:53: no such host
```

## 🔍 根本原因

### 1. 失敗箇所
ワークフローの「Ingress Controller (nginx) を確認/インストール」ステップで以下のコマンド実行時に失敗：

```bash
kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f -
```

### 2. タイムライン
1. ✅ `az aks get-credentials` は成功（00:19:52）
   ```
   WARNING: Merged "aks-demo-dev" as current context in /home/runner/.kube/config
   ```

2. ✅ NSG ルール設定も成功（00:19:52 - 00:20:01）

3. ❌ `kubectl create namespace` で DNS 解決失敗（00:20:17）

### 3. 原因分析

#### 可能性 1: NODE_RESOURCE_GROUP の誤設定
ログから以下の環境変数が確認できる：
```
NODE_RESOURCE_GROUP: mc-RG-BBS-Appzz
```

AKS が自動生成するノードリソースグループ名の命名規則は：
```
MC_{resource-group-name}_{cluster-name}_{region}
```

しかし、実際の値は：
- 期待値: `MC_RG-BBS-Appzz_aks-demo-dev_japaneast`
- 実際値: `mc-RG-BBS-Appzz`（region とクラスター名が欠落）

#### 可能性 2: AKS クラスター設定の問題
- クラスターが Private クラスターとして構成されている可能性
- API サーバーの FQDN が GitHub Actions ランナーからアクセス不可

#### 可能性 3: kubeconfig の問題
- `az aks get-credentials` で取得した kubeconfig の内容が不正
- API サーバーエンドポイントが解決不可能なホスト名を含んでいる

## ✅ 解決策

### 即時対応（ワークフロー修正）

#### 対策 1: NODE_RESOURCE_GROUP の正しい取得
`prepare-context` ジョブの `AKS メタデータを取得` ステップを修正：

```yaml
- name: AKS メタデータを取得
  id: aks_info
  env:
    RESOLVED_RG: ${{ steps.resolve_rg.outputs.resource_group_name }}
  run: |
    set -euo pipefail
    if [ -z "$AKS_CLUSTER_NAME" ]; then
      echo "AKS クラスター名が未設定です" >&2
      exit 1
    fi
    AKS_JSON=$(az aks show --resource-group "$RESOLVED_RG" --name "$AKS_CLUSTER_NAME" 2>/dev/null || true)
    if [ -z "$AKS_JSON" ]; then
      echo "AKS クラスター $AKS_CLUSTER_NAME を RG=$RESOLVED_RG で取得できません" >&2
      exit 1
    fi

    # ノードリソースグループ名を取得
    NODE_RG=$(echo "$AKS_JSON" | jq -r '.nodeResourceGroup // empty')
    
    # デバッグ出力
    echo "Debug: Retrieved NODE_RG=$NODE_RG"
    
    if [ -z "$NODE_RG" ]; then
      echo "AKS ノードリソースグループを解決できません" >&2
      echo "AKS JSON: $AKS_JSON" >&2
      exit 1
    fi
    
    # 取得したノードリソースグループが正しい形式か検証
    if ! az group show --name "$NODE_RG" &>/dev/null; then
      echo "⚠️ ノードリソースグループ '$NODE_RG' が存在しません" >&2
      echo "利用可能なリソースグループ一覧:" >&2
      az group list --query '[].name' -o tsv >&2
      exit 1
    fi
    
    echo "node_resource_group=$NODE_RG" >> "$GITHUB_OUTPUT"
    
    AKS_LOCATION=$(echo "$AKS_JSON" | jq -r '.location // empty')
    if [ -n "$AKS_LOCATION" ]; then
      echo "aks_location=$AKS_LOCATION" >> "$GITHUB_OUTPUT"
    fi
```

#### 対策 2: kubectl 接続の事前検証
`deploy` ジョブの `AKS 資格情報を取得` ステップの直後に検証ステップを追加：

```yaml
- name: AKS 接続を検証
  run: |
    set -euo pipefail
    
    echo "=== kubeconfig の確認 ==="
    kubectl config view --minify
    
    echo "=== API サーバーエンドポイントの確認 ==="
    API_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
    echo "API Server: $API_SERVER"
    
    echo "=== DNS 解決テスト ==="
    API_HOST=$(echo "$API_SERVER" | sed 's|https://||' | sed 's|:.*||')
    echo "Hostname: $API_HOST"
    
    if ! nslookup "$API_HOST"; then
      echo "❌ DNS 解決に失敗しました" >&2
      echo "=== /etc/resolv.conf の内容 ===" >&2
      cat /etc/resolv.conf >&2
      exit 1
    fi
    
    echo "=== クラスター接続テスト ==="
    if ! kubectl cluster-info; then
      echo "❌ クラスターへの接続に失敗しました" >&2
      exit 1
    fi
    
    echo "=== ノード一覧の取得 ==="
    kubectl get nodes
    
    echo "✅ AKS 接続検証完了"
```

#### 対策 3: Private クラスター対応
AKS が Private クラスターの場合、GitHub Actions セルフホストランナーまたは VPN 経由でのアクセスが必要。

一時的な回避策として、`--validate=false` フラグを追加：

```bash
kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f - --validate=false
```

ただし、これはセキュリティリスクがあるため恒久的な対策ではない。

### 根本対策

#### 1. AKS クラスターの設定確認
```bash
az aks show --resource-group RG-BBS-Appzz --name aks-demo-dev --query '{apiServerAccessProfile: apiServerAccessProfile, nodeResourceGroup: nodeResourceGroup, fqdn: fqdn, privateFqdn: privateFqdn}'
```

#### 2. Public クラスターとして再構成（推奨）
Bicep ファイルで AKS を Public クラスターとして構成：

```bicep
resource aks 'Microsoft.ContainerService/managedClusters@2024-02-01' = {
  name: aksClusterName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    // ...
    apiServerAccessProfile: {
      enablePrivateCluster: false  // Public クラスターとして構成
    }
  }
}
```

#### 3. セルフホストランナーの使用
Private クラスターを維持する場合、VNet 内にセルフホストランナーをデプロイ。

## 🔄 再発防止策

1. **ワークフローに接続検証ステップを追加**
   - `az aks get-credentials` の直後に `kubectl cluster-info` を実行
   - DNS 解決を事前に確認

2. **デバッグ情報の充実化**
   - NODE_RESOURCE_GROUP の値を明示的にログ出力
   - kubeconfig の内容をマスキングして出力

3. **IaC での明示的な設定**
   - AKS を Public クラスターとして明示的に設定
   - API サーバーのアクセスプロファイルをパラメータファイルで管理

## 📚 参考資料

- [AKS Private Cluster](https://learn.microsoft.com/ja-jp/azure/aks/private-clusters)
- [kubectl 接続のトラブルシューティング](https://kubernetes.io/docs/tasks/debug/debug-cluster/#debugging-dns-resolution)
- [GitHub Actions セルフホストランナー](https://docs.github.com/ja/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners)

## ✅ 実施状況

- [x] 問題の特定と原因分析
- [x] ワークフロー修正の実装
  - [x] AKS 接続検証ステップを追加（DNS 解決とクラスター接続をリトライロジックで実装）
  - [x] NODE_RESOURCE_GROUP 取得時のデバッグ出力を追加
  - [x] エラー時の詳細な診断情報収集を実装
- [x] AKS 設定の確認（Public クラスターとして構成されていることを確認）
- [ ] 修正後のテスト実行
- [ ] ドキュメントの更新

## 🎯 期待される結果

修正後のワークフローでは：
1. DNS 解決が失敗した場合、最大 5 回リトライ（10 秒間隔）
2. クラスター接続が失敗した場合、最大 3 回リトライ（5 秒間隔）
3. 失敗時には詳細な診断情報（resolv.conf、ネットワーク設定、AKS 状態等）を出力
4. NODE_RESOURCE_GROUP の正確な値を確認

これにより、DNS 伝播の遅延やネットワークの一時的な問題に対応でき、問題が継続する場合は詳細な診断情報から根本原因を特定できるようになる。
