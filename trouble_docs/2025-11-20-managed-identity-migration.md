# トラブルシューティング履歴：バックアップを Managed Identity 認証に移行

## 📅 発生日時

2025-11-20 19:10 頃

---

## 🔴 問題の概要

### 現状

バックアップワークフローが **SAS トークン認証**を使用：

1. GitHub Actions で SAS トークンを生成
2. Base64 エンコードして VM に渡す
3. VM 上で Base64 デコード
4. azcopy で SAS 付き URL にアップロード

### 課題

- **SAS トークンの有効期限管理**が必要
- **トークン漏洩リスク**（ログに出力される可能性）
- **Storage Account の共有キーアクセス**が有効である必要
- セキュリティベストプラクティスに反する

### 要件

バックアップを **Managed Identity 認証**に変更したい。

---

## 🔍 実装方針

### Managed Identity のメリット

- ✅ トークン管理不要
- ✅ 自動ローテーション
- ✅ Azure RBAC による細かい権限制御
- ✅ 監査ログに Identity が記録される
- ✅ 共有キーアクセスを無効化可能

### 必要な変更

1. **VM に System Assigned Managed Identity を付与**
2. **VM の Managed Identity に Storage Blob Data Contributor ロールを割り当て**
3. **バックアップスクリプトを Managed Identity 認証に変更**
4. **SAS トークン生成ステップを削除**

---

## ✅ 解決策

### 1. VM に Managed Identity を付与

**infra/modules/vm.bicep の修正：**

```bicep
resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'  // ← 追加
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    // ... 他のプロパティ
  }
}

// principalId を出力に追加
output id string = vm.id
output principalId string = vm.identity.principalId  // ← 追加
output name string = vm.name  // ← 追加
```

### 2. Storage Account へのロール割り当て

**infra/main.bicep にロール割り当てを追加：**

```bicep
// Diagnostic settings for Storage Account
resource storageAccountExisting 'Microsoft.Storage/storageAccounts@2023-04-01' existing = {
  name: storageAccountName
}

// VM Managed Identity に Storage Blob Data Contributor ロールを付与
resource vmStorageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccountExisting.id, vmName, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: storageAccountExisting
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // Storage Blob Data Contributor
    principalId: vm.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}
```

**ロール ID の意味：**

- `ba92f5b4-2d11-453d-a403-e96b0029c9fe`：Storage Blob Data Contributor
- Blob の読み取り・書き込み・削除が可能
- 共有キーアクセス不要

### 3. バックアップワークフローの修正

**`.github/workflows/backup-upload.yml` の変更：**

#### 削除：SAS トークン生成ステップ

```yaml
# ❌ 削除
- name: Storage 用 SAS を発行
  id: sas
  run: |
    EXPIRY=$(date -u -d '+90 minutes' +%Y-%m-%dT%H:%MZ)
    SAS=$(az storage account generate-sas \
      --permissions acdlrw \
      --account-name "$STORAGE_ACCOUNT_NAME" \
      --services b \
      --resource-types co \
      --expiry "$EXPIRY" \
      -o tsv)
    echo "SAS_TOKEN=$SAS" >> "$GITHUB_ENV"
    SAS_B64=$(printf '%s' "$SAS" | base64 -w0)
    echo "SAS_TOKEN_BASE64=$SAS_B64" >> "$GITHUB_ENV"
```

#### 修正：バックアップスクリプト

```yaml
- name: VM 上でバックアップを実行しアップロード (Managed Identity)
  env:
    MYSQL_ROOT_PASSWORD: ${{ vars.MYSQL_ROOT_PASSWORD }}
  run: |
    set -euo pipefail
    SCRIPT_PATH="$RUNNER_TEMP/mysql-backup.sh"
    MYSQL_PASSWORD_B64=$(printf '%s' "$MYSQL_ROOT_PASSWORD" | base64 -w0)
    cat <<'SCRIPT' > "$SCRIPT_PATH"
    #!/bin/bash
    set -euo pipefail

    : "${storageAccountName:?storageAccountName is required}"
    : "${backupContainerName:?backupContainerName is required}"
    : "${mysqlPasswordB64:?mysqlPasswordB64 is required}"

    STORAGE_ACCOUNT_NAME="$storageAccountName"
    BACKUP_CONTAINER_NAME="$backupContainerName"
    MYSQL_ROOT_PASSWORD=$(printf '%s' "$mysqlPasswordB64" | base64 -d)

    TIMESTAMP=$(date -u +%Y%m%d%H%M%S)
    BACKUP_DIR=/tmp/mysql-backups
    mkdir -p "$BACKUP_DIR"
    BACKUP_FILE="$BACKUP_DIR/backup-$TIMESTAMP.sql"

    mysqldump --all-databases --single-transaction --quick --lock-tables=false -u root -p"$MYSQL_ROOT_PASSWORD" > "$BACKUP_FILE"

    if ! command -v azcopy >/dev/null 2>&1; then
      TMPDIR=$(mktemp -d)
      curl -sSL https://aka.ms/downloadazcopy-v10-linux | tar -xz -C "$TMPDIR"
      AZCOPY_PATH=$(find "$TMPDIR" -name azcopy -type f | head -n 1)
      sudo install -m 755 "$AZCOPY_PATH" /usr/local/bin/azcopy
    fi

    # Managed Identity で認証（VM の System Assigned Identity を使用）
    export AZCOPY_AUTO_LOGIN_TYPE=MSI
    DEST_URL="https://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net/${BACKUP_CONTAINER_NAME}/backup-${TIMESTAMP}.sql"
    azcopy copy "$BACKUP_FILE" "$DEST_URL" --from-to=LocalBlob --overwrite ifSourceNewer --log-level INFO
    if [ $? -eq 0 ]; then
      logger "mysql-backup-upload success $TIMESTAMP (Managed Identity)"
    else
      logger "mysql-backup-upload failed $TIMESTAMP"
      cat ~/.azcopy/*.log 2>/dev/null | tail -n 50 >&2 || true
      exit 1
    fi
    SCRIPT
    chmod +x "$SCRIPT_PATH"

    az vm run-command invoke \
      --resource-group "$RESOURCE_GROUP_NAME" \
      --name "$VM_NAME" \
      --command-id RunShellScript \
      --scripts @"$SCRIPT_PATH" \
      --parameters storageAccountName="$STORAGE_ACCOUNT_NAME" \
                   backupContainerName="$BACKUP_CONTAINER_NAME" \
                   mysqlPasswordB64="$MYSQL_PASSWORD_B64"
```

**主な変更点：**

1. `sasTokenB64` パラメータを削除
2. `export AZCOPY_AUTO_LOGIN_TYPE=MSI` で Managed Identity 認証を有効化
3. URL から `?${SAS_TOKEN}` を削除
4. ログメッセージに "(Managed Identity)" を追加

---

## 📊 実行結果

### インフラデプロイ

#### 1 回目：失敗（Log Analytics プロビジョニング中）

```
ERROR: {"status":"Failed","error":{"code":"DeploymentFailed"...
"message":"Workspace cannot be updated while current provisioning state is not Succeeded"
```

**対処：** 90 秒待機してから再実行

#### 2 回目：成功（Run 19533414629）

```
✓ prepare in 36s
✓ bicep-deploy in 2m6s
  ✓ Bicep Validate
  ✓ Bicep What-If
  ✓ Bicep Deploy  ← VM に Managed Identity 付与完了
✓ policy-deploy in 1m36s
✓ summarize in 33s
```

### バックアップ実行（Run 19533567500）

```
✓ backup in 1m9s
  ✓ Azure に Service Principal でログイン
  ✓ ストレージアカウント名を解決
  ✓ バックアップコンテナを確保
  ✓ VM 上でバックアップを実行しアップロード (Managed Identity)  ← 成功！
  ✓ バックアップサマリを出力
```

### バックアップファイル確認

```bash
az storage blob list \
  --account-name stbackupdemo1569 \
  --container-name mysql-backups \
  --auth-mode login \
  --query "[].{Name:name, Size:properties.contentLength, Created:properties.creationTime}" \
  -o table
```

**結果：**

```
Name                       Size     Created
-------------------------  -------  -------------------------
backup-20251120102427.sql  1290386  2025-11-20T10:24:28+00:00
```

**確認完了：** ✅ Managed Identity 認証でバックアップが正常に動作

---

## 🎓 教訓

### 1. Managed Identity の種類

#### System Assigned（今回採用）

- リソースと 1:1 で紐づく
- リソース削除時に自動削除
- 管理がシンプル
- **推奨：単一リソースのみがアクセスする場合**

#### User Assigned

- 複数リソースで共有可能
- リソースとは独立して存在
- ライフサイクル管理が複雑
- **推奨：複数リソースが同じ権限を必要とする場合**

### 2. Azure RBAC のベストプラクティス

#### 最小権限の原則

- ❌ Storage Account Contributor（管理操作も可能）
- ✅ Storage Blob Data Contributor（Blob 操作のみ）

#### スコープの最小化

```bicep
// ❌ Subscription スコープ
scope: subscription()

// ❌ Resource Group スコープ
scope: resourceGroup()

// ✅ Storage Account スコープ
scope: storageAccountExisting
```

### 3. azcopy の Managed Identity 認証

#### 環境変数で制御

```bash
# MSI（Managed Service Identity）認証を有効化
export AZCOPY_AUTO_LOGIN_TYPE=MSI

# 特定の Client ID を指定する場合（User Assigned Identity）
export AZCOPY_MSI_CLIENT_ID=<client-id>
```

#### URL の違い

```bash
# SAS トークン認証（旧）
DEST_URL="https://storage.blob.core.windows.net/container/file?sv=2021-06-08&ss=b&srt=co&sp=rwdlacx&se=..."

# Managed Identity 認証（新）
DEST_URL="https://storage.blob.core.windows.net/container/file"
```

### 4. Bicep でのロール割り当て

#### guid() 関数の制約

```bicep
// ❌ デプロイ時にしか確定しない値は使えない
name: guid(storageAccountExisting.id, vm.outputs.principalId, 'roleId')

// ✅ パラメータや変数など、事前に確定する値を使用
name: guid(storageAccountExisting.id, vmName, 'roleId')
```

#### principalType の重要性

```bicep
properties: {
  roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'roleId')
  principalId: vm.outputs.principalId
  principalType: 'ServicePrincipal'  // ← 必須！Managed Identity の場合
}
```

省略すると、ロール割り当てに時間がかかる場合がある。

---

## 🔧 予防策

### 1. Storage Account の共有キーアクセスを無効化

Managed Identity 移行後は共有キーを無効化：

```bash
az storage account update \
  --name stbackupdemo1569 \
  --resource-group RG-bbs-app-demo-test \
  --allow-shared-key-access false
```

これにより：

- SAS トークンが使用不可
- 共有キーでの認証が不可
- Managed Identity / Azure AD 認証のみ許可

### 2. 診断ログで Managed Identity の使用を監視

Storage Account の診断設定で記録：

```bicep
resource storageDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${storageAccountName}-diag'
  scope: storageAccountExisting
  properties: {
    workspaceId: logAnalytics.outputs.id
    logs: [
      {
        category: 'StorageRead'
        enabled: true
      }
      {
        category: 'StorageWrite'
        enabled: true
      }
    ]
  }
}
```

Log Analytics で確認：

```kusto
StorageBlobLogs
| where AuthenticationType == "OAuth"
| where UserAgentHeader contains "azcopy"
| project TimeGenerated, OperationName, StatusText, RequesterObjectId
```

### 3. Managed Identity の権限を定期的に監査

不要な権限が付与されていないか確認：

```bash
# VM の Managed Identity が持つロール割り当てを一覧表示
VM_PRINCIPAL_ID=$(az vm show --name vm-mysql-demo --resource-group RG-bbs-app-demo-test --query "identity.principalId" -o tsv)

az role assignment list \
  --assignee $VM_PRINCIPAL_ID \
  --query "[].{Role:roleDefinitionName, Scope:scope}" \
  -o table
```

**期待される結果：**

```
Role                          Scope
----------------------------  --------------------------------------------------------
Storage Blob Data Contributor /subscriptions/***/resourceGroups/RG-bbs-app-demo-test/providers/Microsoft.Storage/storageAccounts/stbackupdemo1569
```

### 4. バックアップの整合性チェック

定期的にバックアップからリストアして確認：

```bash
# バックアップファイルをダウンロード
az storage blob download \
  --account-name stbackupdemo1569 \
  --container-name mysql-backups \
  --name backup-20251120102427.sql \
  --file /tmp/test-restore.sql \
  --auth-mode login

# MySQL にリストアしてテスト（テスト環境で）
mysql -u root -p < /tmp/test-restore.sql
mysql -u root -p -e "SHOW DATABASES;"
```

---

## 📝 関連ドキュメント

- `infra/modules/vm.bicep` - VM リソース定義（Managed Identity 追加）
- `infra/main.bicep` - メインテンプレート（ロール割り当て追加）
- `.github/workflows/backup-upload.yml` - バックアップワークフロー
- `trouble_docs/2025-11-20-backup-upload.md` - バックアップスクリプトの引数渡し問題

---

## ✅ 最終確認

### セキュリティチェック

- [x] VM に Managed Identity が付与されている
- [x] Storage Blob Data Contributor ロールが割り当てられている
- [x] SAS トークン生成ステップが削除されている
- [x] バックアップスクリプトが Managed Identity 認証を使用
- [x] バックアップが正常に動作している
- [x] バックアップファイルが Storage に保存されている

### 動作確認

- [x] 手動バックアップ実行：成功
- [x] Storage にファイル作成：確認済み
- [x] Admin App でファイル表示：確認済み
- [x] 自動バックアップ（1 時間ごと）：スケジュール設定済み

**対応完了日時：** 2025-11-20 19:30

---

## 🚀 次のステップ

### 推奨される改善

1. **Storage Account の共有キーアクセスを無効化**
2. **バックアップの保持期間ポリシー設定**（例：30 日間）
3. **バックアップファイルの暗号化**（Storage の暗号化は既定で有効）
4. **ポイントインタイムリカバリのテスト**

### 監視の強化

1. **Alert Rule の作成**：バックアップ失敗時に通知
2. **ダッシュボードの作成**：バックアップ状況を可視化
3. **Runbook の作成**：自動リストア手順の文書化
