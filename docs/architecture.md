# アーキテクチャ概要

本リポジトリでは Azure 上に低コストかつ再現性の高いデモ環境（掲示板アプリ + 管理アプリ + MySQL + バックアップ）を IaC と CI/CD で構築します。

## コンポーネント一覧

- **AKS クラスター**: 掲示板アプリと NGINX Ingress をホストし、ACR からコンテナを取得します。
- **Azure Container Apps**: 管理アプリをコンテナとして実行し、Basic 認証で保護します。
- **Azure VM (Ubuntu)**: MySQL を稼働させ、cron で自動バックアップを実行します。
- **Azure Storage Account**: MySQL バックアップファイルを保管し、Cool 階層を利用します。
- **Log Analytics Workspace**: すべてのリソースのログとメトリクスを一元管理します。
- **Azure Container Registry**: アプリケーションコンテナを保管し、Trivy スキャン済みイメージのみを受け入れます。

## ネットワーク構成

- 単一の仮想ネットワークに AKS、VM、Container Apps のサブネットを分離して配置します。
- NSG で最小限のポートのみ許可し、すべてのアウトバウンド通信は既定ポリシーに従います。

## ログ収集方針

- AKS と VM は Azure Monitor エージェントを介して Log Analytics に送信します。
- ACA と Storage は診断設定で Log Analytics を送信先に指定します。
- 監査目的で Azure Activity を必ず収集します。

## CI/CD フロー概要

1. **infra-deploy**: Bicep の Validate → What-If → Deploy を実施しインフラを更新します。
2. **app-build-board**: 掲示板アプリをビルドし、Trivy でイメージスキャン後 ACR に push します。
3. **app-deploy-board**: AKS へリリースし、Ingress を含むマニフェストを適用します。
4. **app-build-admin**: 管理アプリをビルド・スキャンし、ACR に push します。
5. **app-deploy-admin**: Container Apps へ新リビジョンをデプロイします。
6. **backup-upload**: VM で取得したバックアップをストレージへアップロードし、結果を Log Analytics に記録します。
7. **cleanup-failed-workflows**: 失敗状態のワークフローや一時ファイルをクリーンアップします。

## セキュリティ

- dummy-secret.txt はアプリ配下で公開し、実際の鍵ではない旨を明記します。
- Trivy / CodeQL / Gitleaks / Dependabot / Gitguardian を組み合わせ、SAST・SCA・Secret 検知を自動化します。
