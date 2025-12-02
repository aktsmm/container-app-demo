# README_QUICKSTART – セットアップとデプロイの手順

## 🚀 全体の流れ（概要）

以下の手順でデモ環境をセットアップします。所要時間の目安は **初回 30〜60 分** です。

```
┌──────────────────────────────────────────────────────────────────────────┐
│  1. 前提条件の確認     必要なツール（Azure CLI, GitHub CLI 等）    　　     │
│         ↓                                                                │
│  2. リポジトリの準備   フォーク or 新規リポジトリにプッシュ         　　      │
│         ↓                                                                │
│  3. Azure サインイン   az login でサブスクリプションを選択          　　     │
│         ↓                                                                │
│  4. Service Principal  GitHub Actions 用の認証情報を作成          　       │
│         ↓                                                                │
│  5. Secrets/Variables  GitHub に認証情報・設定値を登録            　       │
│         ↓                                                                │
│  6. インフラデプロイ   Bicep で AKS/ACA/VM/Storage 等を構築         　     │
│         ↓              （GitHub Actions: Infrastructure Deploy）         │
│  7. アプリデプロイ     掲示板アプリ・管理アプリをビルド＆デプロイ      　 　  │
│         ↓              （GitHub Actions: Build & Deploy）                │
│  8. 運用ワークフロー   バックアップ・クリーンアップ・スキャン有効化   　　　   │
│         ↓                                                                │
│  9. 動作確認           ブラウザでアプリにアクセス                           │
└──────────────────────────────────────────────────────────────────────────┘
```

| 手順 | 作業場所           | 主な操作                                        |
| ---- | ------------------ | ----------------------------------------------- |
| 1〜5 | **ローカル PC**    | ツール確認、git clone、az login、スクリプト実行 |
| 6〜8 | **GitHub Actions** | ワークフロー手動実行（自動でも可）              |
| 9    | **ブラウザ**       | アプリ動作確認                                  |

> **⏱️ 初回フルデプロイ合計: 約 15〜20 分**（Board/Admin は並列実行）  
> 詳細なワークフロー実行時間は [README.md](../README.md#%EF%B8%8F-ワークフロー実行時間の目安) を参照

> **💡 ヒント**: インフラデプロイ（手順 6）のワークフローが成功すると、アプリデプロイ（手順 7）のワークフローが **自動でトリガー** されます。初回は手順 6 を実行するだけで、インフラ構築からアプリデプロイまで一気に完了します。

---

## 1. 前提条件

### 1.1 必須ツール

> 💡 **ローカル開発しない場合**: GitHub Actions でビルド・デプロイするだけなら、Node.js / Python / Docker Desktop は不要です。

#### ✅ 必須

| ツール                 | 用途                           | 確認コマンド                     | インストール                                |
| ---------------------- | ------------------------------ | -------------------------------- | ------------------------------------------- |
| **Git**                | リポジトリクローン             | `git --version`                  | `winget install Git.Git`                    |
| **Azure CLI** (v2.60+) | Azure 操作                     | `az --version`                   | `winget install Microsoft.AzureCLI`         |
| **GitHub CLI (gh)**    | Secrets/Variables 登録         | `gh --version`                   | `winget install GitHub.cli`                 |
| **PowerShell 7+**      | スクリプト実行                 | `$PSVersionTable.PSVersion`      | `winget install Microsoft.PowerShell`       |
| **kubectl**            | AKS 操作                       | `kubectl version --client`       | `az aks install-cli`                        |
| **kubelogin**          | AKS 認証                       | （kubectl と同時にインストール） | `az aks install-cli`                        |
| **Visual Studio Code** | コード編集・IaC 管理・k8s 操作 | -                                | `winget install Microsoft.VisualStudioCode` |

#### 📝 ローカル開発時のみ必要（GitHub Actions でデプロイするなら不要）

| ツール                  | 用途                       | 確認コマンド         | インストール                          |
| ----------------------- | -------------------------- | -------------------- | ------------------------------------- |
| **Node.js 20 系 + npm** | board-app / board-api 開発 | `node -v` / `npm -v` | [nodejs.org](https://nodejs.org/)     |
| **Python 3.10+**        | admin-app (Flask) 開発     | `python --version`   | [python.org](https://www.python.org/) |
| **Docker Desktop**      | コンテナビルド             | `docker version`     | [docker.com](https://www.docker.com/) |

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

### 1.4 新規サブスクリプション利用時の Resource Provider 登録

Azure では、サブスクリプションごとに利用するリソースプロバイダー (Microsoft.Compute / Microsoft.Network / Microsoft.Storage / Microsoft.ContainerRegistry / Microsoft.ContainerService / Microsoft.Web / Microsoft.OperationalInsights など) を事前登録しておく必要があります。未登録のまま `1️⃣ Infrastructure Deploy` を実行すると `SubscriptionNotFound` や `MissingSubscriptionRegistration` エラーが発生するため、**新しいサブスクリプションで初めてデプロイする前に必ず登録**してください。また、ポリシー割り当てやマネージド ID/Key Vault/監査ログを IaC で扱う場合は Microsoft.Authorization / Microsoft.ManagedIdentity / Microsoft.KeyVault / Microsoft.Insights も登録しておくと後段のワークフローで 403 や登録エラーを避けられます。

```powershell
az account set --subscription "<SUBSCRIPTION_ID>"
$providers = @(
  "Microsoft.Compute",
  "Microsoft.Network",
  "Microsoft.Storage",
  "Microsoft.ContainerRegistry",
  "Microsoft.ContainerService",
  "Microsoft.Web",
  "Microsoft.OperationalInsights",
  # ポリシー/ID/Key Vault/Monitor を IaC で管理する場合に備えて登録
  "Microsoft.Authorization",
  "Microsoft.ManagedIdentity",
  "Microsoft.KeyVault",
  "Microsoft.Insights"
)
foreach ($ns in $providers) {
  az provider register --namespace $ns
}
az provider list --query "[?namespace=='Microsoft.Compute'||namespace=='Microsoft.Network'||namespace=='Microsoft.Storage'||namespace=='Microsoft.ContainerRegistry'||namespace=='Microsoft.ContainerService'||namespace=='Microsoft.Web'||namespace=='Microsoft.OperationalInsights'||namespace=='Microsoft.Authorization'||namespace=='Microsoft.ManagedIdentity'||namespace=='Microsoft.KeyVault'||namespace=='Microsoft.Insights'].[namespace,registrationState]" -o table
```

> 📖 参考: [Resolve errors for resource provider registration](https://learn.microsoft.com/azure/azure-resource-manager/troubleshooting/error-register-resource-provider#solution)

## 2. リポジトリの準備

GitHub Actions で CI/CD を実行するには、**自分が管理権限を持つリポジトリ**が必要です。  
以下の 2 つの方法から選択してください。

| 方法                                    | おすすめケース                                  | メリット                  |
| --------------------------------------- | ----------------------------------------------- | ------------------------- |
| **A. 新規リポジトリにプッシュ（推奨）** | デモ・学習用途、独自にカスタマイズしたい        | シンプル、完全に独立      |
| **B. フォーク**                         | 元リポジトリの更新を取り込みたい、PR を送りたい | upstream の変更を追跡可能 |

---

### 方法 A: 新規リポジトリにプッシュ（推奨）

デモ環境として独自にカスタマイズする場合はこちらがシンプルです。

```powershell
# 1. GitHub で空のリポジトリを作成（README なし、.gitignore なし）
#    https://github.com/new から作成

# 2. 任意の作業フォルダへ移動してクローン
# （d:/00_temp は例です。お好みのフォルダに変更してください）
Set-Location d:/00_temp
git clone git@github.com:aktsmm/azure-devsecops-demo.git
Set-Location azure-devsecops-demo

# 3. リモート origin を自分のリポジトリに変更
# <YOUR_GITHUB_USERNAME> を自分の GitHub ユーザー名に置き換え
git remote set-url origin git@github.com:<YOUR_GITHUB_USERNAME>/azure-devsecops-demo.git

# 4. プッシュ
git push -u origin master
```

---

### 方法 B: フォーク

元リポジトリの更新を取り込みたい場合や、改善点を PR で送りたい場合はこちら。

#### B-1. GitHub でフォーク

1. ブラウザで [aktsmm/azure-devsecops-demo](https://github.com/aktsmm/azure-devsecops-demo) を開く
2. 右上の **Fork** ボタンをクリック
3. 自分のアカウントにフォークを作成

#### B-2. フォークしたリポジトリをクローン

```powershell
# 任意の作業フォルダへ移動（d:/00_temp は例です）
Set-Location d:/00_temp
# <YOUR_GITHUB_USERNAME> を自分の GitHub ユーザー名に置き換え
git clone git@github.com:<YOUR_GITHUB_USERNAME>/azure-devsecops-demo.git
Set-Location azure-devsecops-demo
```

#### B-3. （任意）upstream を設定して元リポジトリの更新を取得

```powershell
# upstream（元リポジトリ）を追加
git remote add upstream git@github.com:aktsmm/azure-devsecops-demo.git

# 元リポジトリの更新を取得してマージ
git fetch upstream
git merge upstream/master
```

---

> **💡 重要**: どちらの方法でも、後続の手順 5 で GitHub Secrets/Variables を設定し、GitHub Actions を実行するためには、**自分が管理権限を持つリポジトリ**が必要です。

## 3. Azure へのサインイン

```powershell
az login
az account set --subscription "<SUBSCRIPTION_ID>"
```

- 複数アカウントを扱う場合は `az account show` で現在のサブスクリプションを確認してください。

## 4. Service Principal の発行

`scripts/create-github-actions-sp.ps1`（Windows）または `scripts/create-github-actions-sp.sh`（Mac/Linux）を使うと GitHub Actions 専用の Service Principal (クライアントシークレット方式) を作成し、必要な値を一括出力できます。

### 自動付与されるロール

このスクリプトは以下の 3 つのロールを自動で付与します：

1. **Contributor** (指定したロール) – リソースの作成・更新・削除
2. **Resource Policy Contributor** (自動追加) – Azure Policy の割り当て・管理（`infra/policy.bicep` デプロイに必要）
3. **User Access Administrator** (自動追加) – Managed Identity へのロール割り当て（VM/ACA の Managed Identity に権限付与）

### 実行例

#### Windows (PowerShell)

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

#### Mac / Linux (Bash)

**最低限の実行（サブスクリプションスコープ）**:

```bash
chmod +x ./scripts/create-github-actions-sp.sh
./scripts/create-github-actions-sp.sh -s "<SUBSCRIPTION_ID>"
```

**リソースグループスコープで実行（推奨）**:

```bash
./scripts/create-github-actions-sp.sh \
    -s "<SUBSCRIPTION_ID>" \
    -g "RG-bbs-app-demo"
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

### 5.1 スクリプトを利用する場合

規定値は `scripts/setup-github-secrets_variables.ps1`（Windows）または `scripts/setup-github-secrets_variables.sh`（Mac/Linux）で一括反映できます。GitHub CLI で認証済みであることが前提です。

> ⚠️ **必須編集**: スクリプト実行前に以下の値を編集してください。プレースホルダーのまま実行するとエラーで停止します。
>
> - `$DefaultRepo` / `DEFAULT_REPO` → 自分のリポジトリ（例: `"your-username/azure-devsecops-demo"`）
> - `$AzureCredentials` / Azure 認証情報 → 手順 4 の `create-github-actions-sp` 出力値を転記

#### Windows (PowerShell)

```powershell
pwsh ./scripts/setup-github-secrets_variables.ps1             # $DefaultRepo に設定したリポジトリへ適用
pwsh ./scripts/setup-github-secrets_variables.ps1 -Repo "owner/repo"  # 別リポジトリへ適用
pwsh ./scripts/setup-github-secrets_variables.ps1 -DryRun     # 設定内容のみ確認
```

#### Mac / Linux (Bash)

```bash
chmod +x ./scripts/setup-github-secrets_variables.sh
./scripts/setup-github-secrets_variables.sh                    # DEFAULT_REPO に設定したリポジトリへ適用
./scripts/setup-github-secrets_variables.sh -r "owner/repo"   # 別リポジトリへ適用
./scripts/setup-github-secrets_variables.sh --dry-run         # 設定内容のみ確認
```

- スクリプト起動時に「デフォルトパスワードをランダムな値に一括変更しますか？」と確認されます。`Y` を選ぶと `P@ssw0rd!<乱数>` 形式の値が自動生成され、VM/DB/ACA の各パスワード (`VM_ADMIN_PASSWORD`, `MYSQL_ROOT_PASSWORD`, `DB_APP_PASSWORD`, `ACA_ADMIN_PASSWORD`) に一括適用されます。複数項目を同一パスワードで安全に更新できるため、初期セットアップでは **必ず Y を選択** し、出力されたパスワードを安全な場所へ退避してください。`N` を選ぶとデフォルトの `P@ssw0rd!2025` がそのまま使われます（非推奨）。

- スクリプト先頭の変数（`$DefaultRepo` / `$AzureCredentials`）を編集するだけで既定値を切り替え可能。プレースホルダーのまま実行するとエラーで制御されます。
- `AZURE_CLIENT_ID / SECRET / TENANT_ID / AZURE_SUBSCRIPTION_ID` は **手順 4** のスクリプト実行結果を `$AzureCredentials` に転記する。
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

> **💡 ヒント**: スクリプト実行前に `scripts/setup-github-secrets_variables.ps1` 先頭の `$DefaultRepo` と `$AzureCredentials` を編集してください。プレースホルダーのまま実行するとエラーで制御されます。実行後は GitHub リポジトリの Settings → Secrets and variables → Actions で確認できます。

スクリプト内の `$DefaultRepo` / `$AzureCredentials` を編集することで、プロジェクト固有の値を一括管理できます。

### 5.2 手動で設定する場合

最低限必要な項目:

- **Secrets**: `AZURE_SUBSCRIPTION_ID`
- **Variables**: `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`, `RESOURCE_GROUP_NAME`, `LOCATION`, `ACR_NAME_PREFIX`, `STORAGE_ACCOUNT_PREFIX`, `AKS_CLUSTER_NAME`, `ACA_ENVIRONMENT_NAME`, `ADMIN_CONTAINER_APP_NAME`, `VM_NAME`, `VM_ADMIN_USERNAME`, `VM_ADMIN_PASSWORD`, `DB_APP_USERNAME`, `DB_APP_PASSWORD`, `MYSQL_ROOT_PASSWORD`, `BACKUP_CONTAINER_NAME`, `ACA_ADMIN_USERNAME`, `ACA_ADMIN_PASSWORD` など。

## 6. IaC (インフラ) デプロイ

### ⚠️ ワークフローが表示されない場合

新規リポジトリやフォーク直後は、**Actions タブにワークフロー一覧が表示されない**ことがあります。
これは GitHub がワークフローファイルをまだインデックス（認識）していないためです。

**解決方法**:

1. **ブラウザで Actions タブを開く** → 「I understand my workflows, go ahead and enable them」ボタンが表示されたらクリック
2. **それでも表示されない場合**: ワークフローファイルに軽微な変更を加えてプッシュ

```powershell
# ワークフローファイルにコメントを追加してプッシュ（強制的に認識させる）
Add-Content -Path ".github/workflows/1-infra-deploy.yml" -Value "`n# trigger workflow registration"
git add .github/workflows/1-infra-deploy.yml
git commit -m "chore: ワークフロー登録をトリガー"
git push
```

3. 数秒〜1 分待ってからブラウザをリロード（F5）すると、左側にワークフロー一覧が表示されます

**確認コマンド（GitHub CLI）**:

```powershell
# ワークフローが認識されているか確認
gh workflow list --repo <owner>/<repo>

# 認識されていれば以下のように表示される
# NAME                          STATE   ID
# 1️⃣ Infrastructure Deploy      active  123456789
```

---

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

1. ワークフローのログで `ingress-nginx-controller` Service に割り当てられた `nodePort` と LoadBalancer IP が表示されるか確認
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
