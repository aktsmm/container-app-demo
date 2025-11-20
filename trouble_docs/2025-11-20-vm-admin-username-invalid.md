# VM 管理者ユーザー名の不正な値によるデプロイ失敗

**日時:** 2025-11-20  
**対象ワークフロー:** `1️⃣ Infrastructure Deploy`

---

## 問題の概要

GitHub Actions の `1️⃣ Infrastructure Deploy` ワークフロー実行時に、VM リソース (`vm-mysql-demo`) が以下のエラーで失敗しました。

```
ERROR: {"status":"Failed","error":{"code":"DeploymentFailed",...
```

デプロイ操作の詳細ログを確認したところ、以下のエラーメッセージが記録されていました。

```json
{
  "error": {
    "code": "InvalidParameter",
    "message": "The Admin Username specified is not allowed. For more information about disallowed usernames, see https://aka.ms/vmosprofile",
    "target": "osProfile.adminUsername"
  },
  "status": "Failed"
}
```

---

## 根本原因

### 1. 不正な管理者ユーザー名の使用

GitHub Actions Variables で `VM_ADMIN_USERNAME` に **`admin`** という値を設定していましたが、Azure VM では以下のユーザー名が**予約語**として使用禁止になっています。

- `administrator`
- `admin`
- `user`
- `user1`
- `test`
- `user2`
- `test1`
- `user3`
- `admin1`
- `1`
- `123`
- `a`
- `actuser`
- `adm`
- `admin2`
- `aspnet`
- `backup`
- `console`
- `david`
- `guest`
- `john`
- `owner`
- `root`
- `server`
- `sql`
- `support`
- `support_388945a0`
- `sys`
- `test2`
- `test3`
- `user4`
- `user5`

参考: https://aka.ms/vmosprofile

### 2. 影響を受けた Variables

同様に `admin` を使用していた以下の Variables も修正対象となりました。

- `VM_ADMIN_USERNAME`: VM の管理者ユーザー名
- `DB_APP_USERNAME`: MySQL アプリケーションユーザー名
- `ACA_ADMIN_USERNAME`: Container Apps の Basic 認証ユーザー名

---

## 対応内容

### 修正した GitHub Actions Variables

以下のコマンドで Variables を更新しました。

```pwsh
# 最終的には setup-github-secrets_variables.ps1 で一括更新
gh variable set VM_ADMIN_USERNAME --body "test-admin" --repo aktsmm/container-app-demo
gh variable set DB_APP_USERNAME --body "test-admin" --repo aktsmm/container-app-demo
gh variable set ACA_ADMIN_USERNAME --body "test-admin" --repo aktsmm/container-app-demo
```

| Variable 名          | 変更前  | 変更後       | 理由                                        |
| -------------------- | ------- | ------------ | ------------------------------------------- |
| `VM_ADMIN_USERNAME`  | `admin` | `test-admin` | Azure VM の予約語を回避                     |
| `DB_APP_USERNAME`    | `admin` | `test-admin` | MySQL の予約語ではないが明確化のため変更    |
| `ACA_ADMIN_USERNAME` | `admin` | `test-admin` | Container Apps Basic 認証の明確化のため変更 |

---

## 検証方法

### 1. デプロイ操作履歴の確認

```pwsh
az deployment operation group list `
  --name infra-main-1763649929 `
  --resource-group RG-bbs-app-demo `
  --query "[].{resource:properties.targetResource.resourceName, state:properties.provisioningState}" `
  -o table
```

**結果:**

```
Resource                         State
-------------------------------  ---------
vm-20251120144541                Failed
```

### 2. VM サブデプロイの詳細確認

```pwsh
az deployment operation group list `
  --name vm-20251120144541 `
  --resource-group RG-bbs-app-demo `
  --query "[].{resource:properties.targetResource.resourceName, state:properties.provisioningState, message:properties.statusMessage}" `
  -o json | ConvertFrom-Json | ConvertTo-Json -Depth 10
```

**結果:**

```json
{
  "message": {
    "error": {
      "code": "InvalidParameter",
      "message": "The Admin Username specified is not allowed...",
      "target": "osProfile.adminUsername"
    }
  },
  "resource": "vm-mysql-demo",
  "state": "Failed"
}
```

### 3. Variables 更新後の確認

```pwsh
gh variable list --repo aktsmm/container-app-demo | Select-String "ADMIN|USERNAME"
```

**期待される出力:**

```
ACA_ADMIN_USERNAME        test-admin
DB_APP_USERNAME           test-admin
VM_ADMIN_USERNAME         test-admin
```

---

## 再デプロイ手順

1. **最新の Variables を確認**

   ```pwsh
   gh variable list --repo aktsmm/container-app-demo
   ```

2. **Infrastructure Deploy ワークフローを手動実行**

   GitHub Actions から `1️⃣ Infrastructure Deploy` を `workflow_dispatch` で実行します。

3. **デプロイ成功を確認**

   ```pwsh
   az deployment group show `
     --name infra-main-<timestamp> `
     --resource-group RG-bbs-app-demo `
     --query "properties.provisioningState" `
     -o tsv
   ```

   期待される結果: `Succeeded`

4. **VM への接続確認**

   ```pwsh
   az vm show `
     --resource-group RG-bbs-app-demo `
     --name vm-mysql-demo `
     --query "osProfile.adminUsername" `
     -o tsv
   ```

   期待される結果: `test-admin`

---

## 学んだ教訓

### 1. Azure VM の予約語を事前確認

- 新規プロジェクト開始時は Azure の予約語リストを確認する
- `admin`, `root`, `test` などの一般的な名前は避ける

### 2. 命名規則のドキュメント化

- プロジェクトの命名規則を `docs/naming-conventions.md` などに記録
- Variables の初期値を `scripts/setup-github-secrets_variables.ps1` に明記

### 3. エラーメッセージの活用

- Azure のエラーメッセージには `target` フィールドがあり、問題箇所を特定しやすい
- `az deployment operation group list` で詳細ログを取得すると根本原因が明確になる

### 4. Variables の一括管理

- セキュリティ上の理由で Secrets とは別に Variables を管理
- `gh variable set` コマンドで一括更新が可能

---

## 今後の推奨事項

### 1. 初期セットアップスクリプトの改善

`scripts/setup-github-secrets_variables.ps1` に以下を追加:

```powershell
# Azure VM 予約語チェック
$reservedUsernames = @('admin', 'administrator', 'root', 'test', 'user', 'guest')
if ($VM_ADMIN_USERNAME -in $reservedUsernames) {
    Write-Warning "VM_ADMIN_USERNAME '$VM_ADMIN_USERNAME' is a reserved username in Azure. Consider using 'test-admin' or another safe name."
}
```

### 2. Bicep テンプレートでのバリデーション

`infra/modules/vm.bicep` の `adminUsername` パラメータに `@allowed` デコレータを追加して、予約語を事前にブロックする:

```bicep
@description('管理者ユーザー名 (Azure 予約語以外)')
@allowed([
  'test-admin'
  'azureuser'
  'vmadmin'
  'sysadmin'
])
param adminUsername string
```

### 3. Pre-deployment チェックの自動化

GitHub Actions ワークフローに `validate` ステップを追加し、Variables の値をチェック:

```yaml
- name: Validate Variables
  run: |
    $reservedUsernames = @('admin', 'administrator', 'root', 'test')
    if ($env:VM_ADMIN_USERNAME -in $reservedUsernames) {
      Write-Error "Invalid VM_ADMIN_USERNAME: $env:VM_ADMIN_USERNAME"
      exit 1
    }
  env:
    VM_ADMIN_USERNAME: ${{ vars.VM_ADMIN_USERNAME }}
```

---

## 関連ドキュメント

- [Azure VM の OS プロファイル制約](https://aka.ms/vmosprofile)
- [MySQL 初期化スクリプトの apt リポジトリエラー対応](./2025-11-20-mysql-apt-repository-error.md)
- [VM 拡張機能 MySQL 初期化エラー](./vm-extension-mysql-init.md)

---

## コミット履歴

- **変更内容:** GitHub Actions Variables の修正 (最終的に `test-admin` で統一)
- **対象 Variables:**
  - `VM_ADMIN_USERNAME`: `admin` → `test-admin`
  - `DB_APP_USERNAME`: `admin` → `test-admin`
  - `ACA_ADMIN_USERNAME`: `admin` → `test-admin`
- **実行日時:** 2025-11-20/21
- **実行者:** platform-team
- **修正スクリプト:** `scripts/setup-github-secrets_variables.ps1`
