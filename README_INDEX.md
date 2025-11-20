# README_INDEX – プロジェクト概要とドキュメント案内

## 1. プロジェクトの目的

- Azure 上に「掲示板アプリ (AKS)」「管理アプリ (Azure Container Apps)」「MySQL VM」「ACR」「Storage (バックアップ)」「Log Analytics」を **フル IaC (Bicep)** と **疎結合な GitHub Actions (8 本)** で再現するデモ環境です。
- すべてのリソースは `infra/main.bicep` と `infra/parameters/*.json` で定義され、`1️⃣ Infrastructure Deploy` ワークフローで Validate → What-If → Deploy → Policy の順に適用されます。
- コスト最適化のため、AKS ノード (Standard_B2s)、Container Apps (Consumption)、VM (Standard_B1ms)、ストレージ (Standard_LRS + Cool) など **低コスト SKU** を標準採用しています。
- `app/board-app/public/dummy-secret.txt` は UI からリンクされるダミー資格情報であり、本物の鍵を置かない運用ポリシーを README 群でも明記します。

## 2. 主要コンポーネント

| 分類       | 実体                           | 主なファイル / ディレクトリ                                                 | 役割                                                                                         |
| ---------- | ------------------------------ | --------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| フロント   | `app/board-app` (React + Vite) | `src/App.jsx`, `public/dummy-secret.txt`                                    | AKS 上で公開される掲示板 UI。NGINX Ingress 経由で HTTP 配信し、dummy-secret へのリンクを持つ |
| API        | `app/board-api` (Node/Express) | `server.js`, `Dockerfile`                                                   | 掲示板投稿を MySQL へ永続化。Kubernetes Secret (`board-db-conn`) から接続情報を受け取る      |
| 管理アプリ | `app/admin-app` (Flask)        | `src/app.py`                                                                | Azure Container Apps (Consumption) に配置。Basic 認証、Backup 一覧、投稿削除を提供           |
| IaC        | `infra/`                       | `main.bicep`, `modules/*.bicep`, `parameters/*.json`                        | AKS/ACA/ACR/VM/Storage/Log Analytics/VNet/Policy/診断設定をモジュール化                      |
| CI/CD      | `.github/workflows/`           | 8 本の YAML                                                                 | Build/Deploy/バックアップ/クリーンアップ/セキュリティスキャンを疎結合で実行                  |
| スクリプト | `scripts/`                     | `create-github-actions-sp.ps1`, `mysql-init.sh`, `sync-board-vars.ps1` など | Service Principal 発行、MySQL 初期化、K8s 変数同期、GitHub Secrets 自動設定                  |
| ナレッジ   | `docs/`, `trouble_docs/`       | 既存トラブルシュート                                                        | デプロイやランブック情報を Markdown 化                                                       |

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
.github/workflows/  # 1-infra, 2-build-*, 3-deploy-*, backup-upload, cleanup-workflows, security-scan
scripts/            # SP発行、GitHub Secrets投入、MySQL初期化、K8s変数同期
trouble_docs/       # トラブルシューティング履歴
```

## 4. ドキュメント一覧

- `README_QUICKSTART.md` – 必要ツール、Service Principal 発行、Secrets 登録、IaC/アプリ展開手順
- `README_WORKFLOWS.md` – 8 本の GitHub Actions 詳細 (トリガー、依存関係、主処理)
- `README_INFRASTRUCTURE.md` – Bicep モジュール、Azure リソース、VNet/ログ/診断、Kubernetes YAML の構造説明
- `README_PERMISSIONS.md` – Service Principal・Managed Identity・ロール割り当て方針
- `README_SECRETS_VARIABLES.md` – GitHub Secrets/Variables 一覧と dummy-secret 注意事項
- `README_TECHNOLOGIES.md` – 採用技術・言語・ツールチェーンの全体像
- `README_ARCHITECTURE.md` – テキストベースの全体アーキテクチャ図とデータフロー
- `README_SECURITY.md` – RBAC/スキャン/ポリシー/ログ統合などのセキュリティ対策

## 5. 運用のポイント

- **フル IaC**: AKS/ACA/VM/Storage/Log Analytics/Policy を `infra/main.bicep` に集約し、すべての定数は `infra/parameters/main-dev.parameters.json` に退避。
- **低コスト設計**: VM `Standard_B1ms`, AKS `Standard_B2s`、Storage `Standard_LRS + Cool`、ACA Consumption など最小構成。
- **ログ統合**: AKS Control Plane, Container Apps, Storage, VM から全ログを `logAnalytics.outputs.id` へ転送する診断リソースを main.bicep で作成。
- **dummy-secret 露出**: `public/dummy-secret.txt` はダミー値であり、本物の秘密情報を置かない。README_SECRETS_VARIABLES にも明記。
- **Service Principal 認証**: すべてのワークフローが `vars.AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID` と `secrets.AZURE_SUBSCRIPTION_ID` を使用。

詳細は上記 README\_\* を参照してください。
