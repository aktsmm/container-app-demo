# README_QUICKSTART – セットアップとデプロイの手順

## 1. 前提条件

### 1.1 必須ツール

- **Visual Studio Code**: コード編集・IaC 管理・k8s 操作の統合環境。Windows: `winget install Microsoft.VisualStudioCode`
- **Git**: リポジトリクローンに必要。`git --version` で確認。Windows: `winget install Git.Git`
- **Azure CLI** (v2.60+): `az --version` で確認。Windows: `winget install Microsoft.AzureCLI`。公式手順: <https://learn.microsoft.com/cli/azure/install-azure-cli-windows>
- **kubectl**: AKS 操作に必須。`kubectl version --client` で確認。インストール: `az aks install-cli` または `winget install Kubernetes.kubectl`
- **kubelogin**: AKS 認証プラグイン。kubectl と同時に `az aks install-cli` でインストール済み
- **GitHub CLI (gh)**: リポジトリ変数/シークレット登録に利用。`gh --version` で確認。Windows: `winget install GitHub.cli`。初回: `gh auth login` で認証。公式手順: <https://cli.github.com/manual/installation>
- **PowerShell 7 以降**: すべての補助スクリプト (`scripts/*.ps1`) で使用。`$PSVersionTable.PSVersion` で確認。Windows: `winget install Microsoft.PowerShell`

### 1.2 推奨 VS Code 拡張機能

- **GitHub Pull Requests and Issues** (`GitHub.vscode-pull-request-github`): GitHub 統合・PR/Issue 管理
- **GitLens** (`eamodio.gitlens`): Git 履歴・blame・差分表示
- **Azure Account** (`ms-vscode.azure-account`): Azure へのサインイン
- **Azure Resources** (`ms-azuretools.vscode-azureresourcegroups`): リソース管理
- **Bicep** (`ms-azuretools.vscode-bicep`): IaC 編集・検証
- **Kubernetes** (`ms-kubernetes-tools.vscode-kubernetes-tools`): AKS 管理
- **YAML** (`redhat.vscode-yaml`): k8s manifest 編集
- **Docker** (`ms-azuretools.vscode-docker`): コンテナ管理

### 1.3 Azure / GitHub 権限

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

`scripts/create-github-actions-sp.ps1` を使うと GitHub Actions 専用の Service Principal (クライアントシークレット方式) を作成し、必要な値を一括出力できます。

### 自動付与されるロール

このスクリプトは以下の 3 つのロールを自動で付与します：

1. **Contributor** (指定したロール) – リソースの作成・更新・削除
2. **Resource Policy Contributor** (自動追加) – Azure Policy の割り当て・管理（`infra/policy.bicep` デプロイに必要）
3. **User Access Administrator** (自動追加) – Managed Identity へのロール割り当て（VM/ACA の Managed Identity に権限付与）

### 実行例

**最低限の実行（サブスクリプションスコープ）**:

```powershell
pwsh ./scripts/create-github-actions-sp.ps1 -SubscriptionId "<SUBSCRIPTION_ID>"
```

**リソースグループスコープで実行（推奨）**:

```powershell
pwsh ./scripts/create-github-actions-sp.ps1 `
    -SubscriptionId "<SUBSCRIPTION_ID>" `
    -ResourceGroupName "RG-bbs-app-demo"
```

### パラメータ説明

- **SubscriptionId** (必須) – Azure サブスクリプション ID
- **ResourceGroupName** (オプション) – 指定するとリソースグループスコープで権限付与（推奨）  
  💡 省略時: サブスクリプション全体に権限付与
- **DisplayName** (オプション) – Service Principal の表示名  
  💡 省略時: `gha-sp-secret`
- **RoleDefinitionName** (オプション) – 基本ロール  
  💡 省略時: `Contributor`
- **SecretDurationYears** (オプション) – シークレット有効期限（範囲: 1-5 年）  
  💡 省略時: `2` 年

### 出力例

```
--- GitHub Actions に設定するシークレット ---
AZURE_CLIENT_ID = xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
AZURE_TENANT_ID = xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
AZURE_SUBSCRIPTION_ID = xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
AZURE_CLIENT_SECRET = xxx~xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
----------------------------------------
```

この 4 つの値を **手順 5** で使用するため、メモしてください。

## 5. GitHub Secrets / Variables の登録

### 5.1 GitHub CLI を利用する場合

規定値は `scripts/setup-github-secrets_variables.ps1` で一括反映できます。GitHub CLI で認証済みであることが前提です。

```powershell
pwsh ./scripts/setup-github-secrets_variables.ps1             # $DefaultRepo に設定したリポジトリへ適用
pwsh ./scripts/setup-github-secrets_variables.ps1 -Repo "owner/repo"  # 別リポジトリへ適用
pwsh ./scripts/setup-github-secrets_variables.ps1 -DryRun     # 設定内容のみ確認
```

- スクリプト冒頭の `$DefaultRepo`, `$GitHubVariables`, `$GitHubSecrets` を編集するだけで既定値を切り替え可能。
- `AZURE_CLIENT_ID / SECRET / TENANT_ID / AZURE_SUBSCRIPTION_ID` は **手順 4** の `scripts/create-github-actions-sp.ps1` 実行結果をそのまま転記する。（ダミー値はデモ向け）
- `-Repo` を省略し `$DefaultRepo` も空の場合、git remote から自動取得し、それでも不明な場合は対話入力を促します。
- `-DryRun` は gh CLI を呼ばず実行プランだけを表示します。実際に反映する前の確認に使用してください。

#### 自動設定される項目一覧

このスクリプトで以下の全項目を一括登録できます：

**GitHub Secrets（機密情報）**:

- `AZURE_SUBSCRIPTION_ID` – Azure サブスクリプション ID  
  ⚠️ **必須編集**: 手順 4 の `create-github-actions-sp.ps1` 出力値を転記

**GitHub Variables（非機密の設定値）**:

**Azure 認証関連（必須編集）**:

- `AZURE_CLIENT_ID` – Service Principal のクライアント ID  
  ⚠️ **必須編集**: 手順 4 の出力値を転記（デフォルト: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`）
- `AZURE_CLIENT_SECRET` – Service Principal のクライアントシークレット  
  ⚠️ **必須編集**: 手順 4 の出力値を転記（デフォルト: `xxx~xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`）
- `AZURE_TENANT_ID` – Azure テナント ID  
  ⚠️ **必須編集**: 手順 4 の出力値を転記（デフォルト: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`）

**インフラ設定（環境に応じて編集推奨）**:

- `RESOURCE_GROUP_NAME` – リソースグループ名（デフォルト: `RG-bbs-app-demo`）
- `LOCATION` – Azure リージョン（デフォルト: `japaneast`）
- `ACR_NAME_PREFIX` – ACR 名のプレフィックス（デフォルト: `acrdemo`、後ろに 4 桁乱数が自動付与）
- `STORAGE_ACCOUNT_PREFIX` – Storage Account 名のプレフィックス（デフォルト: `demo`、後ろに 4 桁乱数が自動付与）
- `AKS_CLUSTER_NAME` – AKS クラスタ名（デフォルト: `aks-demo-dev`）
- `ACA_ENVIRONMENT_NAME` – Container Apps Environment 名（デフォルト: `cae-demo-dev`）
- `ADMIN_CONTAINER_APP_NAME` – 管理アプリ名（デフォルト: `admin-app`）
- `VM_NAME` – MySQL VM 名（デフォルト: `vm-mysql-demo`）
- `BACKUP_CONTAINER_NAME` – バックアップ用 Blob コンテナ名（デフォルト: `mysql-backups`）

**データベース/アプリ認証（本番環境では必ず変更）**:

- `VM_ADMIN_USERNAME` – VM 管理者ユーザー名（デフォルト: `test-admin`）
- `VM_ADMIN_PASSWORD` – VM 管理者パスワード（デフォルト: `P@ssw0rd!2025`）  
  ⚠️ **セキュリティ注意**: 本番環境では強固なパスワードに変更してください
- `MYSQL_ROOT_PASSWORD` – MySQL root パスワード（デフォルト: `P@ssw0rd!2025`）  
  ⚠️ **セキュリティ注意**: 本番環境では強固なパスワードに変更してください
- `DB_APP_USERNAME` – アプリ用 DB ユーザー名（デフォルト: `test-admin`）
- `DB_APP_PASSWORD` – アプリ用 DB パスワード（デフォルト: `P@ssw0rd!2025`）  
  ⚠️ **セキュリティ注意**: 本番環境では強固なパスワードに変更してください
- `ACA_ADMIN_USERNAME` – 管理アプリの Basic 認証ユーザー名（デフォルト: `test-admin`）
- `ACA_ADMIN_PASSWORD` – 管理アプリの Basic 認証パスワード（デフォルト: `P@ssw0rd!2025`）  
  ⚠️ **セキュリティ注意**: 本番環境では強固なパスワードに変更してください

**自動設定項目（編集不要）**:

- `INGRESS_PUBLIC_IP` – Ingress 用 Static IP（デフォルト: 空文字列）  
  📝 Bicep デプロイ後、`3️⃣ Deploy Board App (AKS)` ワークフローが自動設定します

> **💡 ヒント**: スクリプト実行前に `scripts/setup-github-secrets_variables.ps1` 冒頭の `$GitHubVariables` / `$GitHubSecrets` ハッシュテーブルを編集してください。実行後は GitHub リポジトリの Settings → Secrets and variables → Actions で確認できます。

スクリプト内の `$GitHubVariables` / `$GitHubSecrets` ハッシュテーブルを編集することで、プロジェクト固有の値を一括管理できます。

### 5.2 手動で設定する場合

最低限必要な項目:

- **Secrets**: `AZURE_SUBSCRIPTION_ID`
- **Variables**: `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`, `RESOURCE_GROUP_NAME`, `LOCATION`, `ACR_NAME_PREFIX`, `STORAGE_ACCOUNT_PREFIX`, `AKS_CLUSTER_NAME`, `ACA_ENVIRONMENT_NAME`, `ADMIN_CONTAINER_APP_NAME`, `VM_NAME`, `VM_ADMIN_USERNAME`, `VM_ADMIN_PASSWORD`, `DB_APP_USERNAME`, `DB_APP_PASSWORD`, `MYSQL_ROOT_PASSWORD`, `BACKUP_CONTAINER_NAME`, `ACA_ADMIN_USERNAME`, `ACA_ADMIN_PASSWORD` など。

## 6. IaC (インフラ) デプロイ

1. GitHub Actions の `1️⃣ Infrastructure Deploy` を手動実行するか、`infra/` へ push して自動トリガーします。
2. このワークフローは以下を順番に実施します。
   - Service Principal への追加権限チェック
   - Bicep Validate / What-If / Deploy (`infra/main.bicep` + `infra/parameters/main-dev.parameters.json`)
   - Azure Policy (resource group scope) の割り当て (`infra/policy.bicep`)
   - Step Summary で ACR / AKS / ACA / VM / Storage / Log Analytics の情報を出力
3. 完了後 `az resource list -g <RG>` でリソースが揃っていることを確認します。

### ⚠️ 新しいリソースグループでの初回デプロイ時の注意

**初回デプロイ時は、Ingress Controller の LoadBalancer 設定が安定するまで時間がかかる場合があります。**

- **推奨**: インフラデプロイ完了後、**最低 5-10 分待機**してからアプリデプロイを実行
- **理由**: Azure LoadBalancer のヘルスプローブ設定が完全にプロビジョニングされるまで時間がかかる
- **確認方法**: `3️⃣ Deploy Board App (AKS)` の `LoadBalancer 接続確認` ステップで接続成功を確認

もし接続確認が失敗した場合:
1. ワークフローのログで `healthCheckNodePort: 30254` が正しく設定されているか確認
2. 5-10 分待機後、ワークフローを再実行
3. それでも失敗する場合は `trouble_docs/2025-01-21-loadbalancer-healthprobe-nodeport-mismatch.md` を参照

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
