# README_WORKFLOWS – GitHub Actions パイプライン一覧

## 0. 共通仕様

- すべてのワークフローは **Service Principal + クライアントシークレット** 認証で Azure にログインします。
- `vars.AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID` と `secrets.AZURE_SUBSCRIPTION_ID` が未設定の場合は早期に失敗します。
- これらの資格情報は `scripts/create-github-actions-sp.ps1` を実行して生成し、`scripts/setup-github-secrets_variables.ps1` の `$GitHubVariables/$GitHubSecrets` へ転記してから `gh variable`/`gh secret` で登録します。
- セキュリティスキャン (Trivy, Gitleaks, CodeQL) は可能な限り **SARIF** を生成して Security タブへアップロードします (公開リポジトリ、または GitHub Advanced Security 契約済みプライベートリポジトリが対象)。
- ビルド系ワークフローは成果物 (SBOM, SARIF, image metadata) を `actions/upload-artifact` で保存し、後続のデプロイ/セキュリティワークフローが参照できるようにしています。

## 1. `1️⃣ Infrastructure Deploy` (`.github/workflows/1-infra-deploy.yml`)

- **トリガー**: `workflow_dispatch`, `push` (infra や自身の変更)
- **ジョブ構成**:
  1. `prepare` – Azure ログイン、Policy 権限付与、ACR/Storage 名の一意決定、AKS 既存判定、SSH 鍵生成
  2. `bicep-deploy` – `infra/main.bicep` を Validate → What-If → Deploy、動的パラメーター上書き
  3. `policy-deploy` – `infra/policy.bicep` + `infra/parameters/policy-dev.parameters.json`
  4. `summarize` – Resource Group 内リソースの表、ACR/AKS/ACA/VM/Storage/LAW の主要情報
- **ポイント**:
  - `aksSkipCreate` フラグで既存クラスタを再利用可能
  - Storage/AKS/Container Apps への診断設定を main.bicep で自動作成し、Log Analytics に統合

## 2. `2️⃣ Build Board App` (`.github/workflows/2-build-board-app.yml`)

- **トリガー**: `push` (board-app ディレクトリ)、`workflow_run` (1️⃣ 完了時)、`workflow_dispatch`
- **主なステップ**:
  - Gitleaks + Trivy FS スキャン
  - Azure ログイン → ACR 名解決 → 管理者認証有効化 → `app/board-app` と `app/board-api` の Docker Build
  - Tag 付与 (`<short_sha>` & `latest`) → Trivy Image Scan (UI/API 両方) → SBOM 生成
  - ACR プッシュ + 成果物アップロード (`board-app-image`)
- **成果物**: `sbom-board.cdx.json`, `sbom-board-api.cdx.json`, SARIF 2 種、`build-output.txt`

## 3. `2️⃣ Build Admin App` (`.github/workflows/2-build-admin-app.yml`)

- **トリガー**: `push` (admin-app), `workflow_run` (1️⃣ 完了), `workflow_dispatch`
- **主なステップ**:
  - `app/admin-app` の Docker Build、Trivy/Gitleaks スキャン、SBOM/SARIF 出力
  - ACR プッシュ (タグは `<short_sha>` と `latest`)
  - 成果物 `admin-app-image` に SBOM/SARIF を同梱

## 4. `3️⃣ Deploy Board App (AKS)` (`.github/workflows/3-deploy-board-app.yml`)

- **トリガー**: `workflow_run` (2️⃣ Build Board App 成功時), `workflow_dispatch`
- **主なステップ**:
  - Azure ログイン → ACR 解決 → `az aks install-cli`
  - `scripts/sync-board-vars.ps1` で `app/board-app/k8s/vars.env` を最新化
  - AKS への ACR Pull 権限付与 (`az aks update --attach-acr`)
  - `kubectl get-credentials`、Ingress Controller (Helm ingress-nginx) の存在確認とインストール
  - ACR 認証 Secret (`acr-secret`) と DB 接続 Secret (`board-db-conn`) を Namespace 単位で適用
  - Kustomize 適用 (`kubectl kustomize app/board-app/k8s`) → イメージ名を sed で置換 → `kubectl apply`
  - Step Summary で Load Balancer IP / ingress / Pod 状態を報告 (`dummy-secret` の公開 URL も記載)

## 5. `3️⃣ Deploy Admin App (Container Apps)` (`.github/workflows/3-deploy-admin-app.yml`)

- **トリガー**: `workflow_run` (2️⃣ Build Admin App 成功時), `workflow_dispatch`
- **主なステップ**:
  - Azure ログイン → ACR/Storage/Container Apps Environment 名の解決
  - ACA プロビジョニング完了待ち (`Succeeded` になるまでポーリング)
  - `az containerapp create/update` で外部 Ingress + target port 8000 + revision suffix を設定
  - `az containerapp secret set` で Basic 認証と DB 接続環境変数を注入
  - Managed Identity を付与 → Subscription スコープに Contributor、Storage へ Storage Blob Data Contributor
  - Step Summary で FQDN、Provisioning/Running 状態、環境変数を出力

## 6. `🔄 MySQL Backup Upload (Scheduled)` (`.github/workflows/backup-upload.yml`)

- **トリガー**: `schedule` (毎時), `workflow_dispatch`
- **処理内容**:
  - Storage Account 名を prefix から解決し、バックアップ用コンテナを作成/検証
  - ワークフロー内で一時的な `mysql-backup.sh` を生成し、その場で `az vm run-command invoke` から VM 上で実行（専用スクリプトはリポジトリに常設していません）
  - VM の System Assigned Identity と AzCopy MSI 認証を使って Blob へアップロード
  - Step Summary にバックアップファイル名と Blob URL を記載

## 7. `🧹 Cleanup Workflow Runs (Scheduled)` (`.github/workflows/cleanup-workflows.yml`)

- **トリガー**: `schedule` (12 時間毎), `workflow_dispatch`, `push` (main ブランチ)
- **処理内容**:
  - `gh run list` / `gh api` を駆使して古い実行を削除
  - 保持ポリシー: 成功 (人間) 7 件、成功 (Dependabot) 3 件、失敗 1 件
  - `GH_PAT_ACTIONS_DELETE` があれば優先利用し、無ければ `GITHUB_TOKEN`

## 8. `🔐 Security Scan (CodeQL + Trivy + Gitleaks)` (`.github/workflows/security-scan.yml`)

- **トリガー**: `push`, `pull_request`, `schedule` (毎日 12:00 JST), `workflow_dispatch`
- **ジョブ**:
  1. `codeql` – JavaScript + Python の security-extended クエリ、SARIF 収集
  2. `iac-security` – 全リポジトリを Trivy/Gitleaks、`infra/` や `app/board-app/k8s` を個別スキャン
  3. `summary` – 各カテゴリ (CodeQL, Gitleaks, Trivy image/fs/infra/k8s) の上位 3 アラートを Markdown/JSON にまとめ、Step Summary へ出力
- **成果物**: `iac-scan-results` (SARIF 一式), `codeql-sarif`, `security-top-findings-json`

## 9. 推奨実行順序

1. `1️⃣ Infrastructure Deploy`
2. `2️⃣ Build Board App` / `2️⃣ Build Admin App`
3. `3️⃣ Deploy Board App (AKS)` / `3️⃣ Deploy Admin App (Container Apps)`
4. `🔄 MySQL Backup Upload` (スケジュール ON)
5. `🔐 Security Scan` (日次)
6. `🧹 Cleanup Workflow Runs` (定期)

## 10. トラブルシューティングヒント

- ワークフローエラー時は `trouble_docs/*.md` に過去の事例があります。
- `AZURE_CLIENT_SECRET` を GitHub **Variables** に置いているため、権限を絞りたい場合は Secret へ移行し、YAML も修正してください。
