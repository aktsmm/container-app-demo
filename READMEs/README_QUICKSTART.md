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
- **Node.js 20 系 + npm**: `app/board-app` / `app/board-api` をローカルでビルド・テストする際に利用。`node -v` / `npm -v` で確認し、<https://nodejs.org/en/download> から LTS をインストール。
- **Python 3.10+**: `app/admin-app` の Flask サーバーをローカル実行・検証する際に利用。`python --version` で確認。`pip install -r app/admin-app/requirements.txt` を実行できる環境を整備してください。
- **Docker Desktop**: コンテナビルドをローカル再現する際に必須。`docker version` で確認。WSL2 ベースのバックエンドを推奨。

### 1.2 推奨 VS Code 拡張機能

- **GitHub Pull Requests and Issues** (`GitHub.vscode-pull-request-github`): GitHub 統合・PR/Issue 管理
- **GitLens** (`eamodio.gitlens`): Git 履歴・blame・差分表示
- **Azure Account** (`ms-vscode.azure-account`): Azure へのサインイン
- **Azure Resources** (`ms-azuretools.vscode-azureresourcegroups`): リソース管理
- **Bicep** (`ms-azuretools.vscode-bicep`): IaC 編集・検証
- **Kubernetes** (`ms-kubernetes-tools.vscode-kubernetes-tools`): AKS 管理
- **YAML** (`redhat.vscode-yaml`): k8s manifest 編集
- **Docker** (`ms-azuretools.vscode-docker`): コンテナ管理
- **GitHub Copilot Chat** (`GitHub.copilot-chat`) + **Copilot Extensions** (Azure / GitHub MCP): Azure CLI や IaC のコマンド補助、ワークフローの不具合調査を対話で実施。MCP サーバー (Azure Rules / Microsoft Docs など) を有効化しておくと、Azure ベストプラクティスや公式ドキュメント参照をその場で確認できます。

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

- スクリプト起動時に PowerShell から「デフォルトパスワードをランダムな値に一括変更しますか？」と確認されます。`Y` を選ぶと `P@ssw0rd!<乱数>` 形式の値が自動生成され、VM/DB/ACA の各パスワード (`VM_ADMIN_PASSWORD`, `MYSQL_ROOT_PASSWORD`, `DB_APP_PASSWORD`, `ACA_ADMIN_PASSWORD`) に一括適用されます。複数項目を同一パスワードで安全に更新できるため、初期セットアップでは **必ず Y を選択** し、出力されたパスワードを安全な場所へ退避してください。`N` を選ぶとデフォルトの `P@ssw0rd!2025` がそのまま使われます（非推奨）。

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

**セキュリティスキャン関連**:

- `GITGUARDIAN_API_KEY` – GitGuardian (ggshield) でシークレット検出を行う際の Personal Access Token。`scan` / `incident:read` / `incident:write` スコープを必ず付与してください。未設定時は GitGuardian ジョブのみ自動スキップされます。

**自動設定項目（編集不要）**:

- Ingress 用 Static Public IP / DNS 名（`<label>.<region>.cloudapp.azure.com`）は Bicep で作成されるため、GitHub Variables への個別設定は不要です。

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

- **推奨**: インフラデプロイ完了後、**最低 5-10 分待機**してからアプリデプロイ ( `2️⃣ Board App Build & Deploy` ) を実行
- **理由**: Azure LoadBalancer のヘルスプローブ設定が完全にプロビジョニングされるまで時間がかかる
- **確認方法**: `2️⃣ Board App Build & Deploy` の `LoadBalancer 接続確認` ステップで接続成功を確認

もし接続確認が失敗した場合:

1. ワークフローのログで `healthCheckNodePort: 30254` が正しく設定されているか確認
2. 5-10 分待機後、ワークフローを再実行
3. それでも失敗する場合は `trouble_docs/2025-01-21-loadbalancer-healthprobe-nodeport-mismatch.md` を参照

## 7. アプリケーションビルド & デプロイ

- `2️⃣ Board App Build & Deploy`

  - `app/board-app/**` や `app/board-api/**` に変更が入ると自動でトリガー (手動起動も可)。
  - **前半 (Build)**: Gitleaks / Trivy FS → Docker Build (board-app, board-api) → Trivy Image → SBOM/SARIF を生成し ACR へ push。
  - **後半 (Deploy)**: `scripts/sync-board-vars.ps1` で Bicep から Ingress DNS (`<label>.<region>.cloudapp.azure.com`) を同期し、ingress-nginx + Kustomize を AKS に適用。`dummy-secret.txt` ルートもこのとき公開されます。

- `2️⃣ Admin App Build & Deploy`
  - `app/admin-app/**` 変更または手動起動で実行。Docker Build → Trivy/Gitleaks → SBOM/SARIF を ACR/Artifacts に格納。
  - Container Apps へ最新タグをデプロイし、Basic 認証 (ID/PW) と DB 接続情報を Secret 経由で注入。Managed Identity へのロール付与も自動化しています。

## 8. 運用ワークフローの有効化

- `🔄 MySQL Backup Upload (Scheduled)` – 1 時間ごとに VM 上で `mysqldump` を取り、Managed Identity + AzCopy で Storage へアップロード。
- `🧹 Cleanup Workflow Runs (Scheduled)` – 12 時間ごとに古い Actions 実行を削除。
- `🔐 Security Scan (CodeQL + Trivy + Gitleaks)` – 毎日/PR で実行し、SARIF を Security タブへアップロード (公開リポジトリまたは GitHub Advanced Security 契約が必要)。

## 9. 動作確認

1. AKS Ingress の DNS FQDN を取得

```powershell
kubectl get ingress -n board-app board-app-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

もしくは `az network public-ip show -g <RG> -n pip-aks-ingress-dev --query dnsSettings.fqdn -o tsv` で Static IP の DNS ラベルを確認できます。 2. ブラウザで `http://<FQDN>/` にアクセスし、掲示板 UI と `ダミーシークレットはこちら` のリンク (`/dummy-secret`) が表示されることを確認。 3. 管理アプリの FQDN (`az containerapp show --name <app> --resource-group <RG> --query properties.configuration.ingress.fqdn -o tsv`) に Basic 認証でアクセスし、バックアップ一覧や投稿削除が機能することを確認。

## 10. 次のステップ

- `README_WORKFLOWS.md` でワークフローパラメーターやトラブルシュートを確認。
- `README_SECURITY.md` で Secrets 取り扱いやスキャンルールを把握し、必要に応じて独自ルールを追加してください。
