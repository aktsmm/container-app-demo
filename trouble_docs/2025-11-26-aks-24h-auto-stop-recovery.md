# Azure リソース 24 時間自動停止からの復旧手順

**作成日時**: 2025-11-26  
**最終更新**: 2025-11-26（VM 停止対応追加）  
**Status**: ✅ **解決済み**

---

## 📋 問題概要

組織の Azure Policy により、**AKS クラスター** と **MySQL VM** が **24 時間に 1 回自動停止** される。
停止後に手動でワークフローを再実行する必要があり、運用負荷が高い。

### 現象

1. AKS クラスターが自動停止される（`powerState: Stopped`）
2. **MySQL VM が自動停止される（`deallocated`）**
3. 停止後に Board App ワークフローを実行しても接続エラー
4. DNS 解決失敗や LoadBalancer IP 変更で疎通不可
5. **Board App で「MySQL永続化 API からの取得に失敗しました」エラー**

---

## 🔧 解決策

### 方法 1: 自動ヘルスチェック & 復旧ワークフロー（推奨）

新規追加した `azure-health-check.yml` ワークフローを使用：

```bash
# 手動実行（定期実行は一旦無効化）
gh workflow run azure-health-check.yml
```

**機能:**

- ✅ AKS クラスター状態を自動確認 & 自動起動
- ✅ **MySQL VM 状態を自動確認 & 自動起動**
- ✅ Ingress Controller / Pod 正常性確認
- ✅ LoadBalancer IP 取得待機
- ✅ 外部疎通確認（HTML / API）
- ✅ **VM 復旧時は board-api Pod を自動再起動**
- ✅ 問題検出時は再デプロイを推奨

### 方法 2: Board App ワークフローの既存機能を活用

`2-board-app-build-deploy.yml` には既に以下の機能が実装済み：

1. **AKS 停止検知 & 自動起動**（deploy ジョブ内）
2. **DNS 解決リトライ**（最大 5 回）
3. **クラスター接続リトライ**（最大 3 回）
4. **LoadBalancer IP 取得待機**

問題発生時は、以下のコマンドで再実行：

```bash
# 最新タグで再デプロイ（ビルドスキップ）
gh workflow run 2-board-app-build-deploy.yml

# または特定タグで再デプロイ
gh workflow run 2-board-app-build-deploy.yml -f redeployTag=abc123def456
```

---

## 📊 ワークフロー実行パターン

### パターン A: 手動ヘルスチェック（推奨）

```
┌──────────────────────────┐
│ azure-health-check.yml  │
│ (手動実行)              │
└────────────┬─────────────┘
             │
             ▼
┌─────────────────┐     ┌─────────────────┐
│ AKS 停止?       │──→  │ AKS 自動起動    │
│                 │     │ (az aks start)  │
└────────┬────────┘     └────────┬────────┘
         │                       │
         ▼                       ▼
┌─────────────────┐     ┌─────────────────┐
│ MySQL VM 停止?  │──→  │ VM 自動起動     │
│                 │     │ (az vm start)   │
└────────┬────────┘     └────────┬────────┘
         │                       │
         ▼                       ▼
┌─────────────────┐     ┌─────────────────┐
│ VM 復旧?        │──→  │ board-api Pod   │
│                 │     │ 自動再起動      │
└────────┬────────┘     └────────┬────────┘
         │                       │
         ▼                       ▼
┌─────────────────┐     ┌─────────────────┐
│ Ingress 正常?   │     │ DNS/LB 待機     │
│ App 正常?       │     │ (60秒)          │
└────────┬────────┘     └────────┬────────┘
         │                       │
         ▼                       ▼
┌─────────────────┐     ┌─────────────────┐
│ 問題なし        │     │ 再デプロイ推奨  │
│ ✅ 完了         │     │ (サマリに表示)  │
└─────────────────┘     └─────────────────┘
```

### パターン B: AKS 停止後に Board App ワークフロー実行

```
┌─────────────────────────────────────┐
│ 2-board-app-build-deploy.yml       │
│ (手動実行 or push トリガー)         │
└────────────────┬────────────────────┘
                 │
                 ▼
┌─────────────────┐
│ AKS 状態確認    │
│ (deploy ジョブ) │
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌─────────────────┐
│ Stopped?        │──→  │ az aks start    │
│                 │     │ + 待機 (60秒)   │
└────────┬────────┘     └────────┬────────┘
         │                       │
         ▼                       ▼
┌─────────────────┐     ┌─────────────────┐
│ DNS リトライ    │←────│ kubeconfig 取得 │
│ (5回 x 10秒)    │     │                 │
└────────┬────────┘     └─────────────────┘
         │
         ▼
┌─────────────────┐
│ デプロイ実行    │
│ + 疎通確認      │
└─────────────────┘
```

---

## ⚠️ 既知の問題と対処法

### 1. LoadBalancer IP 変更

**現象:** AKS 再起動後に External IP が変わる

**対処:**

- ワークフロー内で動的に IP を取得
- Static IP を使用する場合は Bicep で Public IP を事前作成

### 2. Ingress Controller Pod の起動遅延

**現象:** Ingress Controller が起動完了前にデプロイが進む

**対処:**

- `aks-health-check.yml` で Pod Ready 状態を確認
- `2-board-app-build-deploy.yml` で LB IP 取得を待機

### 3. DNS 伝播遅延

**現象:** AKS API Server の FQDN が解決できない

**対処:**

- DNS リトライロジック（最大 5 回 x 10 秒）
- `nslookup` 失敗時の詳細診断出力

---

## 🔄 自動再デプロイを有効化する方法

デフォルトでは、`azure-health-check.yml` は問題検出時に **通知のみ** を行います。
自動再デプロイを有効にするには、以下を変更：

```yaml
# azure-health-check.yml の auto-redeploy ジョブ

# 変更前（無効）
if: false

# 変更後（有効）
if: needs.health-check.outputs.needs_redeploy == 'true'
```

**注意:** 自動再デプロイは以下のコストがかかります：

- GitHub Actions 実行時間
- ACR へのイメージプッシュ
- AKS へのデプロイ時間

---

## 📝 関連ドキュメント

- [AKS LoadBalancer 接続問題](./2025-11-21-aks-loadbalancer-connection-issue.md)
- [AKS DNS 解決失敗](./2025-11-23-aks-dns-resolution-failure.md)
- [Ingress IP 動的変更](./2025-11-21-ingress-ip-dynamic-change.md)

---

## ✅ 確認コマンド

```bash
# AKS クラスター状態確認
az aks show -g $RESOURCE_GROUP_NAME -n $AKS_CLUSTER_NAME \
  --query '{powerState: powerState.code, provisioningState: provisioningState}'

# AKS 手動起動
az aks start -g $RESOURCE_GROUP_NAME -n $AKS_CLUSTER_NAME

# MySQL VM 状態確認
az vm get-instance-view -g $RESOURCE_GROUP_NAME -n $VM_NAME \
  --query 'instanceView.statuses[1].displayStatus' -o tsv

# MySQL VM 手動起動
az vm start -g $RESOURCE_GROUP_NAME -n $VM_NAME

# board-api Pod 手動再起動（VM 復旧後）
kubectl delete pod -l app=board-api -n default

# Board API 疎通確認
curl http://<INGRESS_IP>/api/posts

# ワークフロー実行履歴確認
gh run list --workflow=azure-health-check.yml --limit=5

# Board App ワークフロー手動実行
gh workflow run 2-board-app-build-deploy.yml
```
