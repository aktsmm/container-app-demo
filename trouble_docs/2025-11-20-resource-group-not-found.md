# トラブルシューティング履歴：リソースグループ削除によるワークフロー一斉失敗

## 📅 発生日時

2025-11-20 17:50 頃

---

## 🔴 問題の概要

### 症状

以下の 3 つのワークフローが同時に失敗：

1. **MySQL Backup Upload (Scheduled)** - Run ID: 19531590022
2. **Deploy Board App (AKS)** - Run ID: 19531081006
3. **Deploy Admin App (Container Apps)** - Run ID: 19531056288

### エラーメッセージ

#### 1. MySQL Backup Upload

```
ERROR: (ResourceGroupNotFound) Resource group 'RG-bbs-app-demo' could not be found.
Code: ResourceGroupNotFound
Message: Resource group 'RG-bbs-app-demo' could not be found.
```

#### 2. Deploy Board App

```
指定プレフィックスの ACR が存在しません。infra-deploy を先に実行してください
```

#### 3. Deploy Admin App

```
ERROR: (ResourceGroupBeingDeleted) The resource group 'RG-bbs-app-demo' is in deprovisioning
state and cannot perform this operation.
```

---

## 🔍 根本原因

### リソースグループの削除

- 元々使用していた **RG-bbs-app-demo** が削除された
- 新しいリソースグループ **RG-bbs-app-demo-test** に移行済み
- しかし、**GitHub Actions の環境変数 `RESOURCE_GROUP_NAME` は古い名前のまま**だった

### 影響範囲

- すべての Azure リソースへのアクセスが失敗
- ACR、AKS、Container Apps、Storage Account すべてが見つからない
- バックアップスクリプトが Storage Account にアクセスできない

---

## ✅ 解決策

### 1. リソースグループ状況の確認

```powershell
az group list --query "[].name" -o table
```

**結果：**

- `RG-bbs-app-demo` は存在しない（削除済み）
- `RG-bbs-app-demo-test` が存在

### 2. GitHub Actions 変数の更新

```powershell
gh variable set RESOURCE_GROUP_NAME --body "RG-bbs-app-demo-test"
```

### 3. ワークフローの再実行

#### MySQL Backup Upload

```powershell
gh workflow run "backup-upload.yml"
gh run watch 19531966654
```

**結果：** ✅ 成功（1m5s）

#### Deploy Board App

```powershell
gh workflow run "3-deploy-board-app.yml"
gh run watch 19532080272
```

**結果：** ✅ 成功（2m13s）

#### Deploy Admin App

```powershell
gh workflow run "3-deploy-admin-app.yml"
gh run watch 19532162911
```

**結果：** ✅ 成功（2m32s）

---

## 📊 実行結果詳細

### MySQL Backup Upload（Run 19531966654）

```
✓ Azure に Service Principal でログイン
✓ ストレージアカウント名を解決
✓ バックアップコンテナを確保
✓ Storage 用 SAS を発行
✓ VM 上でバックアップを実行しアップロード
✓ バックアップサマリを出力
```

### Deploy Board App（Run 19532080272）

```
✓ ACR 名を解決
✓ AKS に ACR Pull 権限を付与
✓ Ingress Controller (nginx) を確認/インストール
✓ ACR 認証情報で Secret を作成
✓ DB 接続 Secret(board-db-conn) を作成/更新
✓ Kustomize を適用
✓ デプロイサマリを出力
```

### Deploy Admin App（Run 19532162911）

```
✓ Container Apps Environment 名を動的解決
✓ Container Apps Environment のプロビジョニング完了を待機
✓ MySQL VM の IP アドレスを取得
✓ Container Apps へデプロイ
✓ Container App に Managed Identity を付与
✓ FQDN を表示
```

---

## 🎓 教訓

### 1. リソースグループ変更時のチェックリスト

- [ ] Bicep parameters ファイルの更新
- [ ] GitHub Actions 変数の更新
- [ ] GitHub Actions シークレットの確認
- [ ] ドキュメント（環境情報.md など）の更新

### 2. 環境変数の一元管理

- `RESOURCE_GROUP_NAME` は複数ワークフローで使用される
- 変更時は **すべてのワークフローに影響**する
- GitHub CLI で一括更新可能：
  ```powershell
  gh variable set RESOURCE_GROUP_NAME --body "新しいリソースグループ名"
  ```

### 3. リソースグループ削除のタイミング

- Azure のリソースグループ削除は **プロビジョニング解除状態**になる
- この状態では一切の操作ができない
- 削除が完了するまで数分かかる場合がある

---

## 🔧 予防策

### 1. パラメータファイルとの同期

`infra/parameters/main-dev.parameters.json` と GitHub Actions 変数を同期：

```powershell
# パラメータファイルから読み取って GitHub Actions 変数に設定
$params = Get-Content infra/parameters/main-dev.parameters.json | ConvertFrom-Json
$rgName = $params.parameters.resourceGroupName.value
gh variable set RESOURCE_GROUP_NAME --body $rgName
```

### 2. ワークフロー実行前の検証

- `az group show --name $RESOURCE_GROUP_NAME` でリソースグループの存在確認
- 存在しない場合は `infra-deploy.yml` を先に実行

### 3. 環境情報ドキュメントの自動更新

- パラメータ変更時に `環境情報.md` を自動更新するスクリプト
- GitHub Actions でパラメータ変更を検知して PR を作成

---

## 📝 関連ドキュメント

- `trouble_docs/2025-11-20-backup-upload.md` - MySQL バックアップスクリプトの引数渡し問題
- `trouble_docs/2025-11-20-mysql-apt-repository-error.md` - MySQL Init Script のトラブルシューティング
- `docs/troubleshooting-infra-deploy.md` - インフラデプロイ全般のトラブルシューティング
- `infra/parameters/main-dev.parameters.json` - リソースグループ名が定義されたパラメータファイル

---

## ✅ 最終確認

すべてのワークフローが正常に動作することを確認：

```powershell
gh run list --limit 10 --status success
```

**結果：**

- ✅ MySQL Backup Upload: 成功
- ✅ Deploy Board App: 成功
- ✅ Deploy Admin App: 成功

**対応完了日時：** 2025-11-20 18:10
