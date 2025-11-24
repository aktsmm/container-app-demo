# Container App Demo – プロジェクト概要とドキュメント案内

### 最初にやること 3 ステップ

1. **Service Principal を発行** – `scripts/create-github-actions-sp.ps1` を実行して `AZURE_CLIENT_ID / SECRET / TENANT_ID / SUBSCRIPTION_ID` を取得し、出力内容をメモします。
2. **GitHub Secrets/Variables を登録** – `scripts/setup-github-secrets_variables.ps1` で上記クレデンシャルと各種パラメーターを GitHub リポジトリへ投入し、`READMEs/README_SECRETS_VARIABLES.md` で定義された最低限のキーが揃っているか確認します。
3. **Infrastructure Deploy ワークフローを実行** – `1-infra-deploy.yml` を手動トリガーし、Validate → What-If → Deploy → Policy 適用を完了させて基盤を構築します。

> 詳細手順は [`READMEs/README_QUICKSTART.md`](READMEs/README_QUICKSTART.md) にまとまっています。セットアップ全体を一気に把握したい場合はそちらを先に確認してください。

## 1. プロジェクトの目的

このプロジェクトは、Azure 上に「掲示板アプリ (AKS)」「管理アプリ (Azure Container Apps)」「MySQL VM」「ACR」「Storage (バックアップ)」「Log Analytics」を **フル IaC (Bicep)** と **GitHub Actions (6 本のワークフロー)** で再現し、CodeQL + Trivy + Gitleaks + GitGuardian でシークレット/脆弱性検知を自動化することで、**モダンな DevOps・DevSecOps の実践価値を体験**していただくことを目的としています。

### 体験できる価値

- **IaC (Infrastructure as Code) の便利さ**: すべてのインフラ構成を `infra/main.bicep` と `parameters/*.json` でコード化することで、環境の再現性・変更履歴の可視化・レビューによる品質向上を実現。手作業での構築ミスを防ぎ、何度でも同じ環境を迅速に構築できます。
- **CI/CD パイプラインの自動化**: GitHub Actions による 6 本のワークフローで、インフラのデプロイ (`1️⃣ Infrastructure Deploy`)、掲示板アプリ（フロントエンド + API）と管理アプリのビルド & デプロイ統合ワークフロー (`2️⃣ Board App Build & Deploy`, `2️⃣ Admin App Build & Deploy`)、定期バックアップ・クリーンアップ・セキュリティスキャンを完全自動化。コードをプッシュするだけで、Validate → What-If → Deploy → Policy 適用まで一貫して実行されます。
- **DevOps の文化**: インフラチームとアプリチームが同じリポジトリで協働し、IaC とアプリコードを統合管理。変更はすべて Git で追跡され、Pull Request レビュー → 自動テスト → 本番反映という DevOps サイクルを体感できます。
- **DevSecOps によるセキュリティシフトレフト**: CodeQL (SAST)、Trivy (コンテナ・IaC スキャン)、Secret Scanning (Gitleaks + GitGuardian)、Dependabot (SCA) を組み込み、開発初期段階から脆弱性を検出・修正。**Azure Policy** (`infra/policy.bicep`) によるコンプライアンス強制とガバナンス自動化、Log Analytics への全ログ統合により、セキュリティとガバナンスを開発プロセスに組み込んだ運用を実現します。
- **ドキュメント整合性**: ワークフロー全体を定期的にレビューし README 群を更新していますが、改修の進行により一時的に内容が最新と異なる場合があります。差分を見つけた際は Issue / PR でお知らせください。

### 技術的特徴

- すべてのリソースは `infra/main.bicep` と `infra/parameters/*.json` で定義され、`1️⃣ Infrastructure Deploy` ワークフローで Validate → What-If → Deploy → **Azure Policy 適用** (`infra/policy.bicep` + `parameters/policy-dev.parameters.json`) の順に実行されます。
- **Azure Policy によるガバナンス自動化**: タグ強制、リソース種別制限、SKU 制限、リージョン制限などのコンプライアンスルールを IaC で定義し、自動適用。ポリシー違反リソースの検出・修正を CI/CD に組み込むことで、組織のセキュリティ基準を開発フロー全体で担保します。
- コスト最適化のため、AKS ノード (Standard_B2s)、Container Apps (Consumption)、VM (Standard_B1ms)、ストレージ (Standard_LRS + Cool) など **低コスト SKU** を標準採用しています。
- Security Scan ワークフローでは GitGuardian の API キーベース検査も有効化しており、`vars.GITGUARDIAN_API_KEY` が設定されている場合は 400+ パターンで履歴全体のシークレット検出を実施します。
- `app/board-app/public/dummy-secret.txt` は UI からリンクされるダミー資格情報であり、本物の機密情報ではありません。

## 2. 主要コンポーネント

| 分類       | 実体                           | 主なファイル / ディレクトリ                                                 | 役割                                                                                                                              |
| ---------- | ------------------------------ | --------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| フロント   | `app/board-app` (React + Vite) | `src/App.jsx`, `public/dummy-secret.txt`                                    | AKS 上で公開される掲示板 UI。NGINX Ingress 経由で HTTP 配信し、dummy-secret へのリンクを持つ。board-api REST エンドポイントと連携 |
| API        | `app/board-api` (Node/Express) | `server.js`, `Dockerfile`                                                   | 掲示板投稿を MySQL へ永続化。Kubernetes Secret (`board-db-conn`) から接続情報を受け取る                                           |
| 管理アプリ | `app/admin-app` (Flask)        | `src/app.py`                                                                | Azure Container Apps (Consumption) に配置。Basic 認証、Backup 一覧、投稿削除を提供                                                |
| IaC        | `infra/`                       | `main.bicep`, `modules/*.bicep`, `parameters/*.json`                        | AKS/ACA/ACR/VM/Storage/Log Analytics/VNet/Policy/診断設定をモジュール化                                                           |
| CI/CD      | `.github/workflows/`           | 6 本の YAML                                                                 | Infrastructure Deploy、Board/Admin アプリの Build & Deploy 統合、バックアップ、クリーンアップ、セキュリティスキャン               |
| スクリプト | `scripts/`                     | `create-github-actions-sp.ps1`, `mysql-init.sh`, `sync-board-vars.ps1` など | Service Principal 発行、MySQL 初期化、K8s 変数同期、GitHub Secrets 自動設定                                                       |
| ナレッジ   | `READMEs/`, `trouble_docs/`    | 役割別 README と障害対応メモ                                                | デプロイやランブック情報を Markdown 化                                                                                            |

## 3. ディレクトリ構造 (抜粋)

```
app/
	board-app/        # React + Vite + Kustomize 構成 (dummy-secret公開)
	board-api/        # Node/Express REST API (MySQL 永続化)
	admin-app/        # Flask + Azure Identity クライアント
infra/
	main.bicep        # 低コスト Azure リソース一式
	modules/          # acr / aks / containerAppEnv / vm / storage / vnet / logAnalytics / policy
	parameters/       # main-dev.parameters.json / policy-dev.parameters.json
.github/workflows/  # 1-infra, 2-board-app-build-deploy, 2-admin-app-build-deploy, backup-upload, cleanup-workflows, security-scan
scripts/            # SP発行、GitHub Secrets投入、MySQL初期化、K8s変数同期
trouble_docs/       # トラブルシューティング履歴
```

## 4. ドキュメント一覧

### 読み始める順番のガイド (READMEs/)

- [`READMEs/README_QUICKSTART.md`](READMEs/README_QUICKSTART.md) – 🚀 クイックスタート 🚀！とりあえず試したい方向け。
  必要ツール、Service Principal 発行、Secrets 登録、IaC/アプリ展開手順
- [`READMEs/README_WORKFLOWS.md`](READMEs/README_WORKFLOWS.md) – 6 本の GitHub Actions 詳細 (トリガー、依存関係、主処理)
- [`READMEs/README_INFRASTRUCTURE.md`](READMEs/README_INFRASTRUCTURE.md) – Bicep モジュール、Azure リソース、VNet/ログ/診断、Kubernetes YAML の構造説明
- [`READMEs/README_PERMISSIONS.md`](READMEs/README_PERMISSIONS.md) – Service Principal・Managed Identity・ロール割り当て方針
- [`READMEs/README_SECRETS_VARIABLES.md`](READMEs/README_SECRETS_VARIABLES.md) – GitHub Secrets/Variables 一覧と dummy-secret 注意事項
- [`READMEs/README_TECHNOLOGIES.md`](READMEs/README_TECHNOLOGIES.md) – 採用技術・言語・ツールチェーンの全体像
- [`READMEs/README_ARCHITECTURE.md`](READMEs/README_ARCHITECTURE.md) – テキストベースの全体アーキテクチャ図とデータフロー
- [`READMEs/README_SECURITY.md`](READMEs/README_SECURITY.md) – RBAC/スキャン/ポリシー/ログ統合などのセキュリティ対策

### トラブルシューティング履歴 (trouble_docs/)

- `trouble_docs/*.md` – 発生日ごとの障害記録・暫定対応・恒久対策メモ。例: [`trouble_docs/2025-11-21-ingress-ip-dynamic-change.md`](trouble_docs/2025-11-21-ingress-ip-dynamic-change.md)

## 5. 運用のポイント

** あくまでも検証・デモ用で、かつ [MIT ライセンス](https://github.com/aktsmm/container-app-demo/blob/master/LICENSE)です **

- **フル IaC**: AKS/ACA/VM/Storage/Log Analytics/Policy を `infra/main.bicep` に集約し、すべての定数は `infra/parameters/main-dev.parameters.json` に退避。
- **低コスト設計**: VM `Standard_B1ms`, AKS `Standard_B2s`、Storage `Standard_LRS + Cool`、ACA Consumption など最小構成。
- **ログ統合**: 現在は AKS Control Plane・Container Apps・Storage からの診断ログ/メトリックを `logAnalytics.outputs.id` に集約済み。VM (MySQL) の Syslog やバックアップスクリプトのログを Log Analytics へ転送するには Azure Monitor Agent + Data Collection Rule の構成が必要であり（参考: [Collect Syslog events from virtual machine client with Azure Monitor](https://learn.microsoft.com/azure/azure-monitor/vm/data-collection-syslog)）、本リポジトリではまだ未導入です。
- **GitGuardian API キー**: `vars.GITGUARDIAN_API_KEY` を登録すると Security Scan ワークフロー内の GitGuardian ジョブが有効化され、`security-scan` の Step Summary とカテゴリ別アラートに GitGuardian の検出結果が集計されます。未設定の場合は GitGuardian ジョブのみスキップされるため、環境に応じて設定可否を判断してください。
- **dummy-secret 露出**: `public/dummy-secret.txt` はダミー値であり、本物の秘密情報を置かない。[`READMEs/README_SECRETS_VARIABLES.md`](READMEs/README_SECRETS_VARIABLES.md) にも明記。
- **Service Principal 認証**: すべてのワークフローが `vars.AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID` と `secrets.AZURE_SUBSCRIPTION_ID` を使用。
- **Secrets/Variables 参照表**: 運用に必要なキーは README からも確認できるようにしています。詳細は [`READMEs/README_SECRETS_VARIABLES.md`](READMEs/README_SECRETS_VARIABLES.md) を参照してください。

| 区分     | キー                       | 役割 / 参照ワークフロー                                                               |
| -------- | -------------------------- | ------------------------------------------------------------------------------------- |
| Secret   | `AZURE_SUBSCRIPTION_ID`    | すべての `azure/login@v2` で Subscription を指定                                      |
| Variable | `AZURE_CLIENT_ID`          | 全ワークフロー共通の Service Principal 認証                                           |
| Variable | `AZURE_CLIENT_SECRET`      | 同上。秘匿度が気になる場合は Secret への移行も可                                      |
| Variable | `AZURE_TENANT_ID`          | 同上                                                                                  |
| Variable | `RESOURCE_GROUP_NAME`      | `1-infra`, `2-board-app`, `2-admin-app`, `backup-upload` など RG 指定が必要なステップ |
| Variable | `LOCATION`                 | `1-infra` で RG/Policy の配置リージョンを指定                                         |
| Variable | `ACR_NAME_PREFIX`          | ボード/管理アプリの Build & Deploy、Trivy スキャン                                    |
| Variable | `STORAGE_ACCOUNT_PREFIX`   | Infra デプロイ、バックアップアップロードで Storage を一意に識別                       |
| Variable | `AKS_CLUSTER_NAME`         | `2-board-app-build-deploy` の `az aks get-credentials`                                |
| Variable | `ACA_ENVIRONMENT_NAME`     | `2-admin-app-build-deploy` で ACA を参照                                              |
| Variable | `ADMIN_CONTAINER_APP_NAME` | ACA リビジョン更新時の対象 App 名                                                     |
| Variable | `VM_NAME`                  | `backup-upload` で SSH 実行する VM を指定                                             |
| Variable | `VM_ADMIN_USERNAME`        | `1-infra` の Bicep パラメーター、VM 拡張スクリプト                                    |
| Variable | `VM_ADMIN_PASSWORD`        | 同上                                                                                  |
| Variable | `MYSQL_ROOT_PASSWORD`      | Infra デプロイとバックアップ処理の両方で必要                                          |
| Variable | `DB_APP_USERNAME`          | アプリ用 DB ユーザー。Board/Admin デプロイで Secret を生成                            |
| Variable | `DB_APP_PASSWORD`          | 同上                                                                                  |
| Variable | `BACKUP_CONTAINER_NAME`    | ACA とバックアップワークフローで Blob Container を識別                                |
| Variable | `ACA_ADMIN_USERNAME`       | 管理アプリの Basic 認証ユーザー                                                       |
| Variable | `ACA_ADMIN_PASSWORD`       | 同上                                                                                  |
| Variable | `GITGUARDIAN_API_KEY`      | `security-scan.yml` の GitGuardian ジョブを有効化                                     |

> デモ環境ではセットアップ手順を簡略化するため、Subscription ID 以外をあえて GitHub Variables で扱っています。本番運用では `AZURE_CLIENT_SECRET` や DB/VM パスワードなど秘匿性が高い値を Secrets 側へ移し、参照元 YAML も適宜更新してください。

- **免責事項**: このリポジトリは MIT ライセンスです。作成者は本コード・手順の利用に伴ういかなる損害についても責任を負いません。自己責任でご利用ください。

詳細は [`READMEs/`](READMEs/) 配下の各ドキュメントを参照してください。

## 6. ローカル開発クイックガイド

`READMEs/README_TECHNOLOGIES.md` に詳細なツールチェーン解説がありますが、以下のコマンドだけ覚えておけばローカル検証を素早く開始できます。

```bash
# Board App (React + Vite): 依存関係を入れて開発サーバーを起動
cd app/board-app
npm install
npm run dev -- --host

# Board API (Express): MySQL への接続情報は .env で注入
cd ../board-api
npm install
npm run dev

# Admin App (Flask): 仮想環境を作成し、ストレージ接続用の環境変数をエクスポート
cd ../admin-app
python -m venv .venv && .\.venv\Scripts\activate
pip install -r requirements.txt
set FLASK_APP=src/app.py
flask run --debug
```

> **Tip**: API/Flask アプリの DB 接続値は `scripts/sync-board-vars.ps1` と同じ書式で `.env` に記載すると、CI/CD と揃った挙動を再現できます。

## 7. セキュリティスキャン可視化

`cleanup-failed-workflows.yml` を除くすべてのワークフローが Security Gate に貢献します。特に `security-scan.yml` では、各エンジンの検知結果を Step Summary と `security-top-findings.json`（ワークフロー アーティファクト）に集約しています。

```
CodeQL (JavaScript/Python) ┐
Gitleaks (ソース全体)      │        ┌─> GitHub Step Summary でトップ発見を要約
GitGuardian (履歴スキャン) ├─> SARIF/JSON を統合──┤
Trivy (コンテナ/IaC)       │        └─> artifacts/security-top-findings.json で詳細追跡
Dependabot (SCA)          ┘
```

- Step Summary: 実行完了後に GitHub Actions の結果画面を開き、「Security Scan」ジョブ → Step Summary を確認すると、検出ツールごとの件数・重大度・参照チケットを一覧できます。
- `security-top-findings.json`: アーティファクトをダウンロードし、`jq '.findings[] | {tool, severity, summary}'` のようにフィルタすると機械判読可能な形式で triage を自動化できます。
- `READMEs/README_SECURITY.md` に各スキャナーのポリシーや抑止ロジックをまとめているため、誤検知対応はそちらに記録するのがベストプラクティスです。
