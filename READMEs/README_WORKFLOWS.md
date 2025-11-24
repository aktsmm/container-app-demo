# README_WORKFLOWS – GitHub Actions パイプライン一覧

## 0. 共通仕様

- すべてのワークフローは **Service Principal + クライアントシークレット** 認証で Azure にログインします。
- `vars.AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID` と `secrets.AZURE_SUBSCRIPTION_ID` が未設定の場合は早期に失敗します。
- これらの資格情報は `scripts/create-github-actions-sp.ps1` を実行して生成し、`scripts/setup-github-secrets_variables.ps1` の `$GitHubVariables/$GitHubSecrets` へ転記してから `gh variable`/`gh secret` で登録します。
- セキュリティスキャン (Trivy, Gitleaks, CodeQL) は可能な限り **SARIF** を生成して Security タブへアップロードします (公開リポジトリ、または GitHub Advanced Security 契約済みプライベートリポジトリが対象)。
- ビルド系ワークフローは成果物 (SBOM, SARIF, image metadata) を `actions/upload-artifact` で保存し、後続のデプロイ/セキュリティワークフローが参照できるようにしています。
- GitGuardian スキャンを有効化する場合は GitHub Variables に `GITGUARDIAN_API_KEY`（`scan` / `incident:read` / `incident:write` スコープ）を登録してください。未設定時は GitGuardian ジョブのみ自動でスキップされ、他ジョブには影響しません。

## ワークフロー一覧（全 6 本）

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

## 2. `2️⃣ Board App Build & Deploy` (`.github/workflows/2-board-app-build-deploy.yml`)

- **トリガー**: `push` (`app/board-app/**`, `app/board-api/**`, `app/board-app/k8s/**`), `workflow_run` (1️⃣ 完了時), `workflow_dispatch`
- **主なステップ**:
  - Gitleaks / Trivy FS でソースと IaC をスキャン。
  - Trivy FS が失敗した場合でも空の `trivy-fs-board.sarif` を自動生成し、Step Summary へフォールバック理由を明記して Security タブのノイズを防止。
  - `app/board-app` (React/Vite) と `app/board-api` (Node.js/Express) の Docker Build → `<short_sha>` + `latest` タグ付与 → Trivy Image Scan / SBOM 生成。
  - ACR プッシュ後に Step Summary へ SBOM/SARIF のダウンロードリンクを掲示。
  - `scripts/sync-board-vars.ps1` で Kustomize 変数 (`vars.env`) を Bicep パラメーターと同期（Namespace のみ）。
  - AKS へ `az aks get-credentials`、ingress-nginx を Helm でデプロイ/更新し、LoadBalancer IP を自動割り当て。
  - ACR Pull と DB 接続 Secret (`board-db-conn`) を apply。
  - `kubectl kustomize app/board-app/k8s` → イメージ名差し替え → `kubectl apply`。`dummy-secret.txt` 公開ルートもこの段階で有効化。
  - Step Summary で LoadBalancer IP (`http://<LB_IP>`) や Pod/Ingress 状態を報告し、`dummy-secret` の URL を明示。
- **成果物**: `sbom-board.cdx.json`, `sbom-board-api.cdx.json`, 各種 SARIF, Docker build log, K8s manifest snapshot。
- **ポイント**: ビルドとデプロイを 1 つのワークフローに統合し、board-app と board-api を一括でデプロイします。

## 3. `2️⃣ Admin App Build & Deploy` (`.github/workflows/2-admin-app-build-deploy.yml`)

- **トリガー**: `push` (`app/admin-app/**`), `workflow_run` (1️⃣ 完了時), `workflow_dispatch`
- **主なステップ**:
  - Gitleaks / Trivy FS / Trivy Image で Flask 管理アプリをスキャンしつつ Docker Build。
  - Trivy FS のレポートが不足する場合は空 SARIF を生成してアップロードし、検出結果がゼロでも監査証跡を欠かさない。
  - `<short_sha>` と `latest` タグを ACR へプッシュ、SBOM/SARIF を成果物へアップロード。
  - Container Apps Environment の状態を監視しつつ `az containerapp create`/`az containerapp update` で外部 Ingress (port 8000) を更新。Basic 認証情報と DB 接続設定を Secret として注入。
  - Managed Identity へ Contributor + Storage Blob Data Contributor を割り当て、バックアップ閲覧や Blob 操作を最小権限で実現。
  - Step Summary で FQDN、Revision、ProvisioningState、最近のログ (console tail) を提示。
- **成果物**: `sbom-admin.cdx.json`, SARIF, `admin-app-image` アーカイブ。
- **ポイント**: ビルドとデプロイを 1 つのワークフローに統合し、管理アプリを Container Apps へデプロイします。

## 4. `🔄 MySQL Backup Upload (Scheduled)` (`.github/workflows/backup-upload.yml`)

- **トリガー**: `schedule` (毎時), `workflow_dispatch`
- **処理内容**:
  - Storage Account 名を prefix から解決し、バックアップ用コンテナを作成/検証
  - ワークフロー内で一時的な `mysql-backup.sh` を生成し、その場で `az vm run-command invoke` から VM 上で実行（専用スクリプトはリポジトリに常設していません）
  - VM の System Assigned Identity と AzCopy MSI 認証を使って Blob へアップロード
  - Step Summary にバックアップファイル名と Blob URL を記載

## 5. `🧹 Cleanup Workflow Runs (Scheduled)` (`.github/workflows/cleanup-workflows.yml`)

- **トリガー**: `schedule` (12 時間毎), `workflow_dispatch`, `push` (main ブランチ)
- **処理内容**:
  - `gh run list` / `gh api` を駆使して古い実行を削除
  - 保持ポリシー: 成功 (人間) 7 件、成功 (Dependabot) 3 件、失敗 1 件
  - `GITHUB_TOKEN` を使用（PAT は不要）

## 6. `🔐 Security Scan (CodeQL + Trivy + Gitleaks + GitGuardian)` (`.github/workflows/security-scan.yml`)

- **トリガー**: `push`, `pull_request`, `schedule` (毎日 12:00 JST), `workflow_dispatch`
- **ジョブ**:
  1. `codeql` – JavaScript + Python の security-extended クエリ、SARIF 収集
  2. `gitleaks-scan` – リポジトリ履歴全体を Gitleaks でスキャンし、SARIF を Security タブへアップロード
  3. `gitguardian-scan` – `vars.GITGUARDIAN_API_KEY` が設定されている場合に ggshield を使って JSON + SARIF を生成し、カテゴリ別アラートへ統合
  4. `iac-security` – Trivy (FS/IaC/Kubernetes/Image) によりアプリ/Infra を多層スキャン
  5. `summary` – CodeQL/Gitleaks/GitGuardian/Trivy の検出を統合し、Step Summary + `security-top-findings-json` に上位 3〜5 件を出力
- **成果物**: `iac-scan-results` (SARIF 一式), `codeql-sarif`, `gitleaks-sarif`, `security-top-findings-json`

## 7. 推奨実行順序

1. `1️⃣ Infrastructure Deploy`
2. `2️⃣ Board App Build & Deploy`
3. `2️⃣ Admin App Build & Deploy`
4. `🔄 MySQL Backup Upload` (スケジュール ON)
5. `🔐 Security Scan` (日次)
6. `🧹 Cleanup Workflow Runs` (定期)

## 8. トラブルシューティングヒント

- ワークフローエラー時は `trouble_docs/*.md` に過去の事例があります。
- `AZURE_CLIENT_SECRET` を GitHub **Variables** に置いているため、権限を絞りたい場合は Secret へ移行し、YAML も修正してください。
