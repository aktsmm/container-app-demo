# README_QUICKSTART – セットアップとデプロイの手順

## 1. 前提条件

- **Azure CLI** (v2.60+): Windows では `winget install Microsoft.AzureCLI`。公式手順: <https://learn.microsoft.com/cli/azure/install-azure-cli-windows>
- **GitHub CLI (gh)**: リポジトリ変数/シークレット登録に利用。公式手順: <https://learn.microsoft.com/cli/github/get-started>
- **PowerShell 7 以降**: すべての補助スクリプト (`scripts/*.ps1`) はクロスプラットフォームな PowerShell で動作。
- **Azure サブスクリプションの Contributor 以上の権限**: Resource Group 作成、AKS/ACA/VM/Storage のデプロイ、Policy 割り当てが可能であること。
- **GitHub リポジトリ管理権限**: Actions の設定変更、Secrets/Variables 作成、ワークフロー実行を行うため。

## 2. リポジトリのクローン

```powershell
Set-Location d:/00_temp
git clone git@github.com:aktsmm/container-app-demo.git
Set-Location container-app-demo
```

## 3. Azure へのサインイン

```powershell
az login
az account set --subscription "<SUBSCRIPTION_ID>"
```

- 複数アカウントを扱う場合は `az account show` で現在のサブスクリプションを確認してください。

## 4. Service Principal の発行

`scripts/create-github-actions-sp.ps1` を使うと GitHub Actions 専用の Service Principal (クライアントシークレット方式) を作成し、必要な値を一括出力できます。Contributor に加えて Resource Policy Contributor / User Access Administrator を自動付与します。

```powershell
pwsh ./scripts/create-github-actions-sp.ps1 `
    -SubscriptionId "<SUBSCRIPTION_ID>" `
    -ResourceGroupName "rg-container-app-demo" `
    -DisplayName "gha-container-app-demo" `
    -RoleDefinitionName "Contributor" `
    -SecretDurationYears 2
```

- 出力される `AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_CLIENT_SECRET / AZURE_SUBSCRIPTION_ID` をメモします。

## 5. GitHub Secrets / Variables の登録

### 5.1 GitHub CLI を利用する場合

規定値は `scripts/setup-github-secrets_variables.ps1` で一括反映できます。
＊GitHub CLI を利用している場合前提

```powershell
pwsh ./scripts/setup-github-secrets_variables.ps1 -EnvFilePath "ignore/環境情報.md"
```

### 5.2 手動で設定する場合

最低限必要な項目:

- **Secrets**: `AZURE_SUBSCRIPTION_ID`
- **Variables**: `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`, `RESOURCE_GROUP_NAME`, `LOCATION`, `ACR_NAME_PREFIX`, `STORAGE_ACCOUNT_PREFIX`, `AKS_CLUSTER_NAME`, `ACA_ENVIRONMENT_NAME`, `ADMIN_CONTAINER_APP_NAME`, `VM_NAME`, `VM_ADMIN_USERNAME`, `VM_ADMIN_PASSWORD`, `DB_APP_USERNAME`, `DB_APP_PASSWORD`, `MYSQL_ROOT_PASSWORD`, `BACKUP_CONTAINER_NAME`, `ACA_ADMIN_USERNAME`, `ACA_ADMIN_PASSWORD` など。
- `DB_ENDPOINT` は Bicep デプロイの出力 (`infra-outputs` アーティファクト) からワークフローが自動算出するため、リポジトリ変数としては不要です。

## 6. IaC (インフラ) デプロイ

1. GitHub Actions の `1️⃣ Infrastructure Deploy` を手動実行するか、`infra/` へ push して自動トリガーします。
2. このワークフローは以下を順番に実施します。
   - Service Principal への追加権限チェック
   - Bicep Validate / What-If / Deploy (`infra/main.bicep` + `infra/parameters/main-dev.parameters.json`)
   - Azure Policy (resource group scope) の割り当て (`infra/policy.bicep`)
   - Step Summary で ACR / AKS / ACA / VM / Storage / Log Analytics の情報を出力
3. 完了後 `az resource list -g <RG>` でリソースが揃っていることを確認します。

## 7. アプリケーションビルド & デプロイ

1. **ビルド**
   - `2️⃣ Build Board App` と `2️⃣ Build Admin App` を手動または `app/**` の変更で実行。
   - Docker Build → Trivy / Gitleaks → SBOM → ACR push を行い、成果物を Actions アーティファクトへアップロードします。
2. **デプロイ**
   - `3️⃣ Deploy Board App (AKS)` を実行し、`app/board-app/k8s` の Kustomize を AKS に適用。`dummy-secret.txt` へのリンクも自動で有効になります。
   - `3️⃣ Deploy Admin App (Container Apps)` を実行し、最新タグまたは指定タグで ACA を更新。Basic 認証の ID/PW は GitHub Variables から `az containerapp secret set` で注入されます。

## 8. 運用ワークフローの有効化

- `🔄 MySQL Backup Upload (Scheduled)` – 1 時間ごとに VM 上で `mysqldump` を取り、Managed Identity + AzCopy で Storage へアップロード。
- `🧹 Cleanup Workflow Runs (Scheduled)` – 12 時間ごとに古い Actions 実行を削除。
- `🔐 Security Scan (CodeQL + Trivy + Gitleaks)` – 毎日/PR で実行し、SARIF を Security タブへアップロード (公開リポジトリまたは GitHub Advanced Security 契約が必要)。

## 9. 動作確認

1. AKS Ingress の Public IP を取得
   ```powershell
   kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
   ```
2. ブラウザで `http://<IP>/` にアクセスし、掲示板 UI と `ダミーシークレットはこちら` のリンクが表示されることを確認。
3. 管理アプリの FQDN (`az containerapp show` で取得可能) に Basic 認証でアクセスし、バックアップ一覧や投稿削除が機能することを確認。

## 10. 次のステップ

- `README_WORKFLOWS.md` でワークフローパラメーターやトラブルシュートを確認。
- `README_SECURITY.md` で Secrets 取り扱いやスキャンルールを把握し、必要に応じて独自ルールを追加してください。
