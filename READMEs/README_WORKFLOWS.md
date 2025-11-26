# README_WORKFLOWS – GitHub Actions パイプライン一覧

## 0. 共通仕様

- すべてのワークフローは **Service Principal + クライアントシークレット** 認証で Azure にログインします。
- `vars.AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID` と `secrets.AZURE_SUBSCRIPTION_ID` が未設定の場合は早期に失敗します。
- これらの資格情報は `scripts/create-github-actions-sp.ps1` を実行して生成し、`scripts/setup-github-secrets_variables.ps1` の `$GitHubVariables/$GitHubSecrets` へ転記してから `gh variable`/`gh secret` で登録します。
- セキュリティスキャン (Trivy, Gitleaks, CodeQL) は可能な限り **SARIF** を生成して Security タブへアップロードします (公開リポジトリ、または GitHub Advanced Security 契約済みプライベートリポジトリが対象)。
- ビルド系ワークフローは成果物 (SBOM, SARIF, image metadata) を `actions/upload-artifact` で保存し、後続のデプロイ/セキュリティワークフローが参照できるようにしています。
- GitGuardian スキャンを有効化する場合は GitHub Variables に `GITGUARDIAN_API_KEY`（`scan` / `incident:read` / `incident:write` スコープ）を登録してください。未設定時は GitGuardian ジョブのみ自動でスキップされ、他ジョブには影響しません。

## ワークフロー一覧（全 7 本）

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
  - Storage アカウントの `defaultAction=Deny` を維持したまま、`vmSubnetName` と `containerAppSubnetName` をワークフロー側で解決してネットワークルールを自動整備

### 1.1 Azure Policy / Initiative 架構

- `policy-deploy` ジョブではリソース グループ スコープに **Microsoft Cloud Security Benchmark v2 (Preview)** イニシアチブ (`/providers/Microsoft.Authorization/policySetDefinitions/e3ec7e09-768c-4b64-882c-fcada3772047`) を割り当て、タグ強制・SKU/リージョン制限・ログ送信など約 200 ルールをガードレール化します。
- 割り当て名は `initiative-container-app-demo` で固定し、`infra/parameters/policy-dev.parameters.json` から `policyDefinitionReferenceId` ごとのパラメーターや `notScopes` を差し替えられるため、ステージング/本番で厳格度を簡単に調整できます。
- `enableManagedIdentity=true` の場合は Policy Assignment に System Assigned ID を付与し、自動修復 (DeployIfNotExists/Modify) ポリシーが正しく動作するよう `managedIdentityLocation` を `LOCATION` 環境変数から注入します。
- `README_INFRASTRUCTURE.md` 6 章でカテゴリ別の適用範囲 (コンテナ・ネットワーク・ID・データ保護・監視) を参照でき、`policy-dev.parameters.json` で `nonComplianceMessages` を随時更新することでガバナンス通知を改善できます。

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

### Admin App ワークフロー実行例

![Admin App Build & Deploy ワークフロー](./imgs/bbs-demo-ACA_Deploy_After_CodeScan.png)

> コードスキャン (Gitleaks / Trivy) を先行させてから Docker Build → ACR プッシュ → Container Apps 更新へと進む手順が確認できる画面例です。失敗時はスキャン段階で止まるため、脆弱性を修正してから再実行すると良いでしょう。

## 4. `🔄 MySQL Backup Upload (Scheduled)` (`.github/workflows/backup-upload.yml`)

- **トリガー**: `schedule` (週 1 回・毎週月曜日 00:00 UTC), `workflow_dispatch`
- **処理内容**:
  - Storage Account 名を prefix から解決し、バックアップ用コンテナを作成/検証
  - ワークフロー内で一時的な `mysql-backup.sh` を生成し、その場で `az vm run-command invoke` から VM 上で実行（専用スクリプトはリポジトリに常設していません）
  - VM 上で Azure CLI を使用してコンテナ存在確認、AzCopy MSI 認証で Blob へアップロード（Azure CLI は `scripts/mysql-init.sh` で自動インストール）
  - Step Summary にバックアップファイル名と Blob URL を記載

## 5. `🧹 Cleanup Workflow Runs (Scheduled)` (`.github/workflows/cleanup-workflows.yml`)

- **トリガー**: `schedule` (月 1 回), `workflow_dispatch`, `push` (main ブランチ)
- **処理内容**:
  - `gh run list` / `gh api` を駆使して古い実行を削除
  - 保持ポリシー: 成功 (人間) 7 件、成功 (Dependabot) 3 件、失敗 1 件
  - `secrets.GH_PAT_ACTIONS_DELETE` があれば PAT を優先使用し、未設定の場合は `GITHUB_TOKEN` で実行

## 6. `🔐 Security Scan (CodeQL + Trivy + Gitleaks + GitGuardian)` (`.github/workflows/security-scan.yml`)

- **トリガー**: `push`, `pull_request`, `schedule` (毎日 12:00 JST), `workflow_dispatch`
- **ジョブ**:
  1. `codeql` – JavaScript + Python の security-extended クエリ、SARIF 収集
  2. `gitleaks-scan` – リポジトリ履歴全体を Gitleaks でスキャンし、SARIF を Security タブへアップロード
  3. `gitguardian-scan` – `vars.GITGUARDIAN_API_KEY` が設定されている場合に ggshield を使って JSON + SARIF を生成し、カテゴリ別アラートへ統合
  4. `iac-security` – Trivy (FS/IaC/Kubernetes/Image) によりアプリ/Infra を多層スキャン
  5. `summary` – CodeQL/Gitleaks/GitGuardian/Trivy の検出を統合し、Step Summary + `security-top-findings-json` に上位 3〜5 件を出力
- **成果物**: `iac-scan-results` (SARIF 一式), `codeql-sarif`, `gitleaks-sarif`, `security-top-findings-json`

### Security Scan ワークフロー実行例

![Security Scan ワークフロー](./imgs/WorkFlow-SecurityScan.png)

> セキュリティスキャンは複数のジョブで構成され、SARIF 形式で GitHub Security タブへ自動統合されます。検出結果は Step Summary で一覧表示されます。

## 7. `🔄 Azure Health Check & Recovery` (`.github/workflows/azure-health-check.yml`)

- **トリガー**: `workflow_dispatch` (手動実行)
  - 定期実行が必要な場合は `schedule` を有効化可能（コメントアウト済み）
- **目的**: 組織の Azure Policy による AKS/VM 24 時間自動停止への対応
- **ジョブ構成**:
  1. `health-check` – AKS/VM 状態確認、停止時は自動起動、Ingress / App 正常性確認
- **主なステップ**:
  - AKS クラスターの `powerState` を確認し、`Stopped` の場合は `az aks start` で自動起動
  - MySQL VM の `powerState` を確認し、`VM deallocated` の場合は `az vm start` で自動起動
  - VM 復旧時は board-api Pod を自動再起動（MySQL 接続エラー回避）
  - Ingress Controller Pod の Running 状態を確認
  - LoadBalancer External IP の取得を待機（最大 5 分）
  - Board App / API の外部疎通確認（HTML / API エンドポイント）
  - 問題検出時は Step Summary で再デプロイ推奨を通知
- **入力オプション**:
  - `force_redeploy`: 問題検出時に Board App を強制再デプロイ（現在は通知のみ）
  - `skip_app_check`: アプリ疎通確認をスキップ
- **ポイント**:
  - デフォルトでは問題検出時の通知のみ。自動再デプロイを有効化するには `auto-redeploy` ジョブの `if: false` を変更
  - 関連ドキュメント: `trouble_docs/2025-11-26-aks-24h-auto-stop-recovery.md`

## 8. 推奨実行順序

1. `1️⃣ Infrastructure Deploy`
2. `2️⃣ Board App Build & Deploy`
3. `2️⃣ Admin App Build & Deploy`
4. `🔄 MySQL Backup Upload` (スケジュール ON)
5. `🔐 Security Scan` (日次)
6. `🧹 Cleanup Workflow Runs` (定期)
7. `🔄 Azure Health Check & Recovery` (手動 / 必要に応じて定期化)

## 9. 再実行性と手動トリガー入力

- `workflow_dispatch` を備えるワークフローはすべて単体で再実行できます。`workflow_run` トリガー（例: 1️⃣ の完了後に 2️⃣ が走る設定）は「直前が success のときだけ」発火する条件を付けているため、個別再実行が他ワークフローへ連鎖することはありません。
- `1️⃣ Infrastructure Deploy` は追加入力なしで `workflow_dispatch` が可能です。Validate/What-If/Deploy は常に同じパラメーターを読み込むため、同一コミットでも安全に再適用できます。
- `2️⃣ Board App Build & Deploy` の `redeployTag` 入力を空にすると最新コミットから新しいイメージをビルドします。既存タグを再利用したい場合は `redeployTag` へ `board-app:abc123` のように入力するとビルドをスキップして AKS へ再配置できます。`resourceGroupName` / `aksClusterName` を与えると既定値を上書きできるため、検証用 RG に対する個別再実行時にも YAML を弄らず柔軟に対応できます。
- `2️⃣ Admin App Build & Deploy` でも `redeployTag` 入力で ACR 既存タグを再利用可能です。コンテナアプリのリビジョン衝突を防ぐため、ワークフロー内で `REVISION_SUFFIX=gh-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}` を自動生成しており、同じ Run の再試行や手動リトライでもユニークなリビジョン名が保証されます。
- `🔄 MySQL Backup Upload` と `🧹 Cleanup Workflow Runs` も `workflow_dispatch` から即時実行できます。定期実行の待ち時間なしで挙動を確認したい場合は手動トリガーを使ってください。
- `🔄 Azure Health Check & Recovery` は AKS/VM が Azure Policy により停止された場合に手動で実行します。AKS/VM を自動起動し、VM 復旧時は board-api Pod も自動再起動します。

## 10. トラブルシューティングヒント

- ワークフローエラー時は `trouble_docs/*.md` に過去の事例があります。
- AKS が 24 時間ポリシーで停止される環境では `trouble_docs/2025-11-26-aks-24h-auto-stop-recovery.md` を参照してください。
- `AZURE_CLIENT_SECRET` を GitHub **Variables** に置いているため、権限を絞りたい場合は Secret へ移行し、YAML も修正してください。
