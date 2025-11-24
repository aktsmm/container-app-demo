# README_TECHNOLOGIES – 採用技術とツールチェーン

## 1. Azure サービス

| サービス                                    | 用途                                                            | 低コストへの配慮                                                             |
| ------------------------------------------- | --------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Azure Kubernetes Service (AKS)              | 掲示板 UI/API をホスト。`app/board-app/k8s` で Kustomize 管理。 | Standard_B2s 1 ノード、Standard Load Balancer、ContainerInsights Add-on のみ |
| Azure Container Apps (Consumption)          | Flask 製管理アプリ (`app/admin-app`) をホスト。                 | Consumption workload profile、Ingress 1 ポートのみ                           |
| Azure Container Registry (Basic)            | UI/API/Admin の Docker イメージ保管。                           | SKU Basic、adminUser 無効、匿名 Pull 無効                                    |
| Azure Virtual Machine (Ubuntu 22.04)        | MySQL サーバー。`scripts/mysql-init.sh` で自動構成。            | Standard_B1ms、Standard_LRS ディスク                                         |
| Azure Storage Account (Standard_LRS + Cool) | MySQL バックアップ Blob。                                       | Cool tier、Public Access 無効、HTTPS 強制                                    |
| Log Analytics Workspace                     | AKS Control Plane / Container Apps / Storage / VM のログ集約。  | PerGB2018、保持 30 日                                                        |
| Azure Policy                                | `policy.bicep` でガードレール適用。                             | Resource Group Scope、必要最小限の割り当て                                   |

## 2. アプリケーションスタック

| 層             | 技術                                                            | ファイル                                                          |
| -------------- | --------------------------------------------------------------- | ----------------------------------------------------------------- |
| フロントエンド | React + Vite + 独自フック (`useBoardStore.js`) + dayjs          | `app/board-app/src/**/*.jsx`                                      |
| API            | Node.js 20 + Express + mysql2/promise                           | `app/board-api/server.js`, `package.json`                         |
| 管理アプリ     | Python 3 + Flask + Azure Identity + Azure Storage SDK + PyMySQL | `app/admin-app/src/app.py`, `requirements.txt`                    |
| インフラ       | Bicep + Azure CLI + Azure Policy                                | `infra/main.bicep`, `infra/modules/*.bicep`, `infra/policy.bicep` |
| Kubernetes     | Kustomize + NGINX Ingress + Secrets                             | `app/board-app/k8s/*.yaml`                                        |

## 3. CI/CD & セキュリティ

| コンポーネント        | 役割                                                                                                                  |
| --------------------- | --------------------------------------------------------------------------------------------------------------------- |
| GitHub Actions (6 本) | `README_WORKFLOWS.md` 参照。Validate→Deploy、Build→Deploy（統合）、バックアップ、クリーンアップ、セキュリティスキャン |
| Trivy                 | コンテナ/ファイルシステム/IaC/Kubernetes の脆弱性・シークレット検知 (`0.28.0` アクション)                             |
| Gitleaks              | ソース全体のシークレットリーク検出 (`8.18.4`)                                                                         |
| GitGuardian           | `vars.GITGUARDIAN_API_KEY` 設定時に ggshield で 400+ パターンの秘密情報を検知、JSON→SARIF 変換して集計                |
| CodeQL                | JavaScript + Python コードの SAST (`security-extended` クエリ)                                                        |
| GitHub Code Scanning  | SARIF の集約先。Security タブで上位検出を確認 (公開リポジトリ or GHAS 契約が前提)                                     |

## 4. スクリプト & 自動化

| スクリプト                                   | 概要                                                          | 呼び出し先/タイミング                                                                                                                                                                                                                  |
| -------------------------------------------- | ------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `scripts/create-github-actions-sp.ps1`       | Service Principal 発行 + 権限割り当て + GitHub 用出力         | すべてのワークフローの前提。手動実行し Client ID/Secret を GitHub Variables/Secrets へ登録。実行者には Azure AD の `Application Administrator` (または同等) と Subscription の `Owner` もしくは `User Access Administrator` 権限が必要 |
| `scripts/setup-github-secrets_variables.ps1` | `$GitHubVariables/$GitHubSecrets` を gh CLI で一括登録        | `$DefaultRepo` で対象リポジトリを宣言し、未指定時は git remote → 対話入力の順で解決。`scripts/create-github-actions-sp.ps1` で発行した Service Principal 値をハッシュテーブルへ転記してから運用。`-DryRun` でプラン確認後に本番実行。  |
| `scripts/mysql-init.sh`                      | VM 上で MySQL をインストール、ユーザー作成、外部接続有効化    | `1-infra-deploy.yml` で Bicep デプロイ実行時に Custom Script Extension から自動実行                                                                                                                                                    |
| `scripts/sync-board-vars.ps1`                | `main-dev.parameters.json` から Kustomize `vars.env` を再生成 | `2-board-app-build-deploy.yml` の「Namespace/Ingress の値を同期」ステップで実行。ローカル検証時も同コマンドを推奨                                                                                                                      |

## 5. ログ & 監視

- Diagnostic Settings (Storage / AKS / Container Apps) → Log Analytics Workspace
- VM バックアップは `logger "mysql-backup-upload"` で Syslog にも記録
- GitHub Actions Step Summary で各デプロイ/バックアップ/スキャン結果を共有

## 6. ローカル開発ポインタ

- `app/board-app`: `npm install && npm run dev`
- `app/board-api`: `npm install && npm run dev`
- `app/admin-app`: `pip install -r requirements.txt && flask run --app app.app --debug`
- Docker Build: `docker build -f app/board-app/Dockerfile app/board-app`
