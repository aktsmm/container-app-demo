# infra-deploy トラブルシューティング履歴

## 概要

`infra-deploy` ワークフローの初回実行から成功までに発生した問題と解決策を時系列で記録。

---

## 問題 1: MySQL 認証情報未設定

**発生日時**: 2025-11-19  
**エラー内容**:

```
MySQL の認証情報が未設定です。GitHub Actions で MYSQL_ROOT_PASSWORD / DB_APP_USERNAME / DB_APP_PASSWORD を定義してください
```

**原因**:

- GitHub Actions Variables に MySQL 関連の認証情報が設定されていなかった

**解決策**:

1. `scripts/sync-gh-actions-config.ps1` スクリプトを作成
2. `ignore/環境情報.md` から認証情報を読み取り、GitHub CLI で Variables/Secrets を一括設定
3. コメント除去処理を追加（括弧付き日本語コメントが環境変数に混入する問題を予防）

```powershell
gh variable set VM_ADMIN_USERNAME --body "mysqladmin"
gh variable set MYSQL_ROOT_PASSWORD --body "TempRootP@ssw0rd!2025"
# ... 他の変数も同様に設定
```

**コミット**: `7028d2e`

---

## 問題 2: AKS SSH 公開鍵が無効

**発生日時**: 2025-11-19  
**エラー内容**:

```
InvalidParameter: The SSH public key data is invalid.
```

**原因**:

- `infra/parameters/main-dev.parameters.json` の `aksSshPublicKey` に実際の公開鍵ではなくプレースホルダ文字列が設定されていた

**解決策**:

1. RSA 4096 ビット鍵ペアを生成
2. パラメータファイルに実際の公開鍵を設定

**コミット**: `ca29b11`

---

## 問題 3: PropertyChangeNotAllowed - AKS SSH 公開鍵変更不可

**発生日時**: 2025-11-19  
**エラー内容**:

```
PropertyChangeNotAllowed: Changing property 'linuxProfile.ssh.publicKeys.keyData' is not allowed.
```

**原因**:

- 既存の AKS クラスターに対して SSH 公開鍵を変更しようとした
- AKS の GA API バージョンでは SSH 鍵の変更が許可されていない（イミュータブル）

**解決策（段階的アプローチ）**:

### ステップ 1: エフェメラル SSH 鍵への移行

- SSH 鍵ペアをリポジトリから削除
- ワークフロー内で一時的に生成する方式に変更
- `.gitignore` に SSH 鍵パスを追加

```yaml
- name: AKS 用一時 SSH 鍵生成
  run: |
    ssh-keygen -t rsa -b 4096 -f aks_temp_key -N '' -C "aks-demo-dev"
    PUB_KEY=$(cat aks_temp_key.pub | tr -d '\n')
    echo "AKS_SSH_PUBLIC_KEY=$PUB_KEY" >> "$GITHUB_ENV"
    rm -f aks_temp_key
```

**コミット**: `712d7dc`

### ステップ 2: 条件付き AKS デプロイ

- `main.bicep` に `aksSkipCreate` パラメータ追加
- AKS モジュールを条件付きで作成: `module aks ... = if (!aksSkipCreate)`
- ワークフローで AKS 存在判定を追加

```bicep
param aksSkipCreate bool = false

module aks './modules/aks.bicep' = if (!aksSkipCreate) {
  name: 'aks-${deploymentTimestamp}'
  // ...
}
```

**コミット**: `9feaafc`, `64591a0`

---

## 問題 4: 環境変数の括弧付きコメント混入

**発生日時**: 2025-11-19  
**エラー内容**:

```bash
/bin/sh: line 4: syntax error near unexpected token `('
```

**原因**:

- GitHub Actions Variables に日本語コメント `（Bicep パラメータ...）` が残っていた
- bash 実行時に構文エラーとなった

**解決策**:

```powershell
gh variable set VM_ADMIN_USERNAME --body "mysqladmin"  # コメント除去
gh variable set VM_ADMIN_PASSWORD --body "TempMySqlP@ssw0rd!2025"
# ... 全変数のコメント除去
```

---

## 問題 5: ワークフローステップ順序エラー

**発生日時**: 2025-11-19  
**エラー内容**:

- SSH 鍵生成ステップの条件 `if: env.AKS_SKIP_CREATE == 'false'` が常に失敗

**原因**:

- SSH 鍵生成が AKS 存在判定の**前**に配置されていた
- `AKS_SKIP_CREATE` 環境変数が未設定の状態で条件評価

**解決策**:
ステップ順序を以下のように修正：

1. Resource Group 作成
2. **AKS 存在判定** → `AKS_SKIP_CREATE` 設定
3. **SSH 鍵生成**（条件付き）
4. Bicep Validate/What-If/Deploy

**コミット**: `60a00da`

---

## 問題 6: DeploymentActive - 並行デプロイ競合

**発生日時**: 2025-11-19  
**エラー内容**:

```json
{
  "code": "DeploymentActive",
  "message": "The deployment with resource id '.../deployments/logAnalytics' cannot be saved, because this would overwrite an existing deployment which is still active."
}
```

**原因**:

- push トリガーと workflow_dispatch が同時実行
- Bicep モジュールのデプロイメント名が固定（`name: 'logAnalytics'` など）
- 並行実行時に同一名のネストデプロイが競合

**解決策**:

1. `deploymentTimestamp` パラメータを追加（`utcNow('yyyyMMddHHmmss')`）
2. 全モジュールのデプロイメント名に一意サフィックスを追加

```bicep
param deploymentTimestamp string = utcNow('yyyyMMddHHmmss')

module logAnalytics './modules/logAnalytics.bicep' = {
  name: 'logAnalytics-${deploymentTimestamp}'
  // ...
}
```

**コミット**: `eb1036f`

---

## 問題 7: 診断設定のサポート外カテゴリ

**発生日時**: 2025-11-19  
**エラー内容**:

```json
{
  "code": "BadRequest",
  "message": "Category 'StorageRead' is not supported."
}
{
  "code": "BadRequest",
  "message": "Category 'SystemLogs' is not supported."
}
```

**原因**:

- Storage Account で `StorageRead`/`StorageWrite`/`StorageDelete` カテゴリが存在しない
- Container Apps Environment で `SystemLogs`/`IngressLogs`/`ConsoleLogs` カテゴリ名が誤り

**解決策**:

### Storage Account 診断設定

```bicep
// 修正前: logs に StorageRead/Write/Delete
// 修正後: logs を空配列、metrics のみ Transaction
resource storageDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  properties: {
    workspaceId: logAnalytics.outputs.id
    logs: []
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}
```

### Container Apps Environment 診断設定

```bicep
// 修正前: SystemLogs, IngressLogs, ConsoleLogs
// 修正後: ContainerAppSystemLogs, ContainerAppConsoleLogs
resource caeDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  properties: {
    logs: [
      {
        category: 'ContainerAppConsoleLogs'
        enabled: true
      }
      {
        category: 'ContainerAppSystemLogs'
        enabled: true
      }
    ]
  }
}
```

**コミット**: `78e7224`

---

## 問題 8: ACR 暗号化設定エラー

**発生日時**: 2025-11-19  
**エラー内容**:

```
InvalidEncryptionKeyVaultProperties: Invalid encryption key vault property specified for registry. Property Identity and KeyIdentifier must be set when encryption is enabled.
```

**原因**:

- ACR で `encryption.status = 'enabled'` が設定されていた
- Basic SKU では暗号化がサポートされていない
- Key Vault の設定も不足

**解決策**:
暗号化設定を削除

```bicep
// 修正前
properties: {
  encryption: {
    status: 'enabled'
  }
}

// 修正後（encryption プロパティ削除）
properties: {
  anonymousPullEnabled: false
  publicNetworkAccess: 'Enabled'
}
```

**コミット**: `78e7224`

---

## 問題 9: VM Extensions の LocationRequired エラー

**発生日時**: 2025-11-19  
**エラー内容**:

```
LocationRequired: The location property is required for this definition.
```

**原因**:

- VM Extensions リソース（`AzureMonitorLinuxAgent`, `MysqlInit`）に `location` プロパティが未設定
- `parent` プロパティで VM を指定しても、一部の API バージョンでは明示的な location が必要

**解決策**:
両 Extension に `location` プロパティを追加

```bicep
resource azureMonitorAgent 'Microsoft.Compute/virtualMachines/extensions@2022-11-01' = {
  name: 'AzureMonitorLinuxAgent'
  parent: vm
  location: location  // 追加
  // ...
}

resource mysqlInit 'Microsoft.Compute/virtualMachines/extensions@2022-11-01' = {
  name: 'MysqlInit'
  parent: vm
  location: location  // 追加
  // ...
}
```

**コミット**: `ce6af5f`

---

## 問題 10: Azure Monitor Agent の GCS パラメータ不足

**発生日時**: 2025-11-19  
**エラー内容**:

```
VMExtensionProvisioningError: VM has reported a failure when processing extension 'AzureMonitorLinuxAgent'. Error message: 'Not all required GCS parameters are provided'.
```

**原因**:

- Azure Monitor Linux Agent は Data Collection Rule (DCR) の設定が必須
- DCR が作成されていない状態で Agent をデプロイしようとした

**解決策**:
Agent を一時的にコメントアウト（TODO として DCR 作成後に有効化）

```bicep
// Azure Monitor Agent は Data Collection Rule (DCR) が必要なため一時無効化
// TODO: DCR 作成後に有効化
/*
resource azureMonitorAgent 'Microsoft.Compute/virtualMachines/extensions@2022-11-01' = {
  // ...
}
*/
```

**コミット**: `2b67010`

---

## 問題 11: MySQL Init スクリプトの引用符エスケープエラー

**発生日時**: 2025-11-19  
**エラー内容**:

```
VMExtensionProvisioningError: VM has reported a failure when processing extension 'MysqlInit'. Error message: 'Enable failed: failed to execute command: command terminated with exit status=2
[stderr]
/bin/sh: 66: Syntax error: Unterminated quoted string'
```

**原因**:

- Custom Script Extension の `commandToExecute` で複雑な bash heredoc と引用符エスケープを使用
- パスワードに特殊文字が含まれる場合に構文エラー
- Bicep の `format()` 関数内でのエスケープが困難

**試行錯誤**:

1. ❌ Here-document with escaped quotes: `cat <<'EOF' ... EOF`
2. ❌ Single quote escaping: `cat <<'\''EOFSCRIPT'\'' ...`
3. ✅ **Base64 エンコード方式**

**最終解決策**:
スクリプト本体と全引数を base64 エンコードして転送

```bicep
var mysqlInitScript = loadTextContent('../../scripts/mysql-init.sh')
var mysqlInitCommand = format('''bash -c "echo {0} | base64 -d > /tmp/mysql-init.sh && chmod +x /tmp/mysql-init.sh && /tmp/mysql-init.sh {1} {2} {3}"''',
  base64(mysqlInitScript),
  base64(mysqlRootPassword),
  base64(mysqlAppUsername),
  base64(mysqlAppPassword)
)
```

スクリプト側で base64 デコード対応を追加：

```bash
#!/usr/bin/env bash
set -euo pipefail

# 引数が base64 エンコードされている場合はデコード
if [[ "${1:-}" =~ ^[A-Za-z0-9+/=]+$ ]]; then
    ROOT_PASSWORD=$(echo "$1" | base64 -d)
    APP_USER=$(echo "$2" | base64 -d)
    APP_PASSWORD=$(echo "$3" | base64 -d)
else
    ROOT_PASSWORD="${1:-}"
    APP_USER="${2:-}"
    APP_PASSWORD="${3:-}"
fi
```

**コミット**: `177de5e` ✅ **最終成功**

---

## 成功時の構成

### デプロイされたリソース

- ✅ Log Analytics Workspace
- ✅ VNet + サブネット（AKS, VM, Container Apps）
- ✅ Azure Container Registry (Basic SKU)
- ✅ Storage Account（バックアップ用）
- ✅ Container Apps Environment
- ✅ VM (Ubuntu + MySQL)
  - Custom Script Extension による MySQL 初期化
  - データベース・ユーザー作成
  - bind-address 設定
- ✅ AKS クラスターはスキップ（既存のため）

### ワークフロー最終構成

```yaml
steps:
  1. Checkout
  2. Azure login
  3. ユニーク名を決定（ACR, Storage）
  4. 入力値を検証
  5. Resource group 作成
  6. AKS 存在判定 → AKS_SKIP_CREATE 設定
  7. SSH 鍵生成（条件: AKS_SKIP_CREATE == false）
  8. Bicep Validate（aksSkipCreate パラメータ付き）
  9. Bicep What-If
  10. Bicep Deploy
  11. Azure logout
```

---

## 教訓と推奨事項

### 1. エフェメラル認証情報

- SSH 鍵などの認証情報はリポジトリに保存せず、ワークフロー内で生成
- base64 エンコードで安全にスクリプトへ転送

### 2. 冪等性の確保

- リソース存在チェックと条件付きデプロイを実装
- Azure のイミュータブルプロパティに注意（AKS SSH 鍵など）

### 3. デプロイメント名の一意化

- 並行実行を考慮して `utcNow()` などでタイムスタンプを付与
- ネストされたモジュールデプロイも同様に一意化

### 4. 診断設定の検証

- リソースタイプごとにサポートされるカテゴリを事前確認
- Azure Portal や `az monitor diagnostic-settings categories list` で検証

### 5. VM Extensions の注意点

- `location` プロパティは明示的に設定
- Azure Monitor Agent は DCR 必須
- Custom Script で複雑なコマンドは base64 エンコード推奨

### 6. 段階的なトラブルシューティング

- エラーログから具体的なリソース・プロパティを特定
- 1 つずつ修正してコミット・再実行で検証
- 失敗パターンをドキュメント化

---

## 参考リンク

- [Azure Bicep ドキュメント](https://learn.microsoft.com/azure/azure-resource-manager/bicep/)
- [AKS SSH 鍵の管理](https://learn.microsoft.com/azure/aks/ssh)
- [Azure Monitor Agent 設定](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-manage)
- [診断設定カテゴリ一覧](https://learn.microsoft.com/azure/azure-monitor/essentials/diagnostic-settings)
- [VM Extensions トラブルシューティング](https://aka.ms/vmextensionlinuxtroubleshoot)
