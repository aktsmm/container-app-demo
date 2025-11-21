# README_PERMISSIONS – 認証と RBAC 方針

## 1. GitHub Actions 用 Service Principal

- 作成スクリプト: `scripts/create-github-actions-sp.ps1`
- 必要権限:
  - **Azure AD ロール**: アプリ登録/Service Principal 作成のために `Application Administrator`、`Cloud Application Administrator`、または `Privileged Role Administrator` いずれかのロールが必要です ([参考](https://learn.microsoft.com/azure/active-directory/develop/howto-create-service-principal-portal#prerequisites)).
  - **Azure RBAC**: 作成した Service Principal に Contributor などを割り当てるため、対象サブスクリプションで `Owner` または少なくとも `User Access Administrator` ロール (roleAssignments/write 権限) が必要です ([参考](https://learn.microsoft.com/azure/role-based-access-control/role-assignments-portal#prerequisites)).
- 付与ロール (既定):
  1. **Contributor** – リソース作成/更新 (AKS, ACA, VM, Storage, Policy 等)
  2. **Resource Policy Contributor** – `infra/policy.bicep` で Azure Policy を割り当てるために必須
  3. **User Access Administrator** – `az role assignment create` をワークフローから実行し、Managed Identity へ権限付与できるようにするため
- 認証方式: Client Secret。GitHub Actions では以下を使用します。
  - `vars.AZURE_CLIENT_ID`
  - `vars.AZURE_TENANT_ID`
  - `vars.AZURE_CLIENT_SECRET`
  - `secrets.AZURE_SUBSCRIPTION_ID`

## 2. GitHub Actions での認証利用箇所

| ワークフロー               | ログインステップ | 追加権限操作                                                                  |
| -------------------------- | ---------------- | ----------------------------------------------------------------------------- |
| `1️⃣ Infrastructure Deploy` | `azure/login@v2` | Service Principal への Policy ロール付与、Resource Group 作成                 |
| `2️⃣ Board App Build & Deploy` | `azure/login@v2` | ACR 管理者認証の一時有効化、`az acr update --admin-enabled true`、`az aks get-credentials`、`az aks update --attach-acr`、`kubectl`/`helm` 操作 |
| `2️⃣ Admin App Build & Deploy` | `azure/login@v2` | Container Apps のシークレット更新、Managed Identity へのロール割り当て        |
| `backup-upload`            | `azure/login@v2` | `az vm run-command invoke`, Storage コンテナ作成                              |

## 3. Managed Identity の利用

### 3.1 AKS (System Assigned)

- `infra/modules/aks.bicep` で SystemAssigned ID を有効化。
- 目的: Azure Monitor / ACR Pull (`--attach-acr`) の際に使用。

### 3.2 MySQL VM (System Assigned)

- `infra/modules/vm.bicep` で SystemAssigned ID。
- `main.bicep` で VM の `principalId` に対し **Storage Blob Data Contributor** を割り当て。
- `backup-upload` ワークフローでは `azcopy` の MSI 認証を使用し、Storage へ直接アップロード。

### 3.3 Container App (System Assigned)

- `2️⃣ Admin App Build & Deploy` の `az containerapp identity assign` で有効化。
- その後、ワークフロー内で以下を実施:
  - Subscription スコープに **Contributor** (デモ用。実環境では最小権限に絞る想定)
  - Storage Account に **Storage Blob Data Contributor**
- Flask アプリ (`app/admin-app/src/app.py`) 内では `DefaultAzureCredential()` で Blob Storage を操作。

### 3.4 Azure Policy の Managed Identity

- `infra/policy.bicep` は `policy-dev.parameters.json` の `enableManagedIdentity=true` に応じて SystemAssigned ID を割り当てます。
- `managedIdentityLocation` は `LOCATION` 環境変数から注入。

## 4. Kubernetes シークレット / 認証素材

| 名称                                | 作成箇所                                                       | 用途                                  |
| ----------------------------------- | -------------------------------------------------------------- | ------------------------------------- |
| `acr-secret`                        | `2️⃣ Board App Build & Deploy` (ACR 資格情報。`az acr credential show`) | board-app / board-api のイメージ Pull |
| `board-db-conn`                     | 同上 (GitHub Variables から DB 接続情報を注入)                 | board-api Pod が MySQL に接続するため |
| `admin-username` / `admin-password` | `2️⃣ Admin App Build & Deploy` (`az containerapp secret set`)   | Container Apps の Basic 認証          |

## 5. GitHub PAT の利用 (任意)

- `cleanup-workflows.yml` は古い Actions 実行を削除するため、`GH_PAT_ACTIONS_DELETE` が存在すれば優先的に使用。無ければ `GITHUB_TOKEN`。
- PAT を利用する場合は **repo** / **workflow** 権限のみを付与したトークンを推奨。

## 6. 最小権限への移行ヒント

- Container App の Managed Identity には、実運用では Storage Blob Data Reader 程度に制限し、Subscription レベルの Contributor を削除してください。
- GitHub Variables に平文で保存している `AZURE_CLIENT_SECRET` は Secret へ移設することで監査ログが強化されます。
- `backup-upload` で使用する `MYSQL_ROOT_PASSWORD` は GitHub Variable ですが、シークレットに移行可能です。

## 7. 監査ログ

- Role Assignment は `az role assignment create` を実行するたびに Azure Activity Log に記録され、`main.bicep` で構成した Log Analytics Workspace へも取り込まれます。
