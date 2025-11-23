# 掲示板 API (board-api)

AKS 上で動作し、Azure VM (MySQL) に掲示板投稿を永続化する軽量 REST API です。Node.js + Express で実装され、`board-app` (React フロントエンド) からの REST リクエストを処理します。

## 主な機能

- **GET /api/posts**: すべての投稿を時系列降順で返す
- **POST /api/posts**: 新規投稿を作成（`{ author, message }` を受け取り、投稿を MySQL に保存）
- **テーブル自動作成**: DB やテーブルが存在しない場合は初回起動時に自動作成（冪等性確保）
- **ヘルスチェック**: `/health` エンドポイントで Readiness Probe をサポート

## 環境変数

| 変数名              | 説明                                           | 例                         |
| ------------------- | ---------------------------------------------- | -------------------------- |
| `DB_ENDPOINT`       | MySQL ホストとポート（`host:port` 形式）       | `10.0.4.4:3306`            |
| `DB_APP_USERNAME`   | MySQL アプリケーションユーザー名               | `boarduser`                |
| `DB_APP_PASSWORD`   | MySQL アプリケーションパスワード               | `SecurePass123!`           |

これらの環境変数は Kubernetes Secret (`board-db-conn`) から注入され、GitHub Actions の変数/シークレットから自動的に設定されます。

## ローカル実行

```bash
cd app/board-api
npm install

# 環境変数を設定（実際の MySQL 接続情報に置き換えてください）
export DB_ENDPOINT="localhost:3306"
export DB_APP_USERNAME="boarduser"
export DB_APP_PASSWORD="your_password"

node server.js
```

API サーバーは `http://localhost:3000` で起動します。

## コンテナビルド

```bash
cd app/board-api
docker build -t board-api:dev .
```

## デプロイ

`board-api` は `2️⃣ Board App Build & Deploy` ワークフローで自動的にビルド・デプロイされます。

- Dockerfile を使用して ACR にプッシュ
- Kubernetes Deployment として AKS にデプロイ
- Ingress の `/api/*` パスで公開
- `board-db-conn` Secret から DB 接続情報を取得

## セキュリティ

- DB 接続情報は環境変数経由で Secret から取得（平文での保存を回避）
- 最小限のライブラリ構成（Node.js + mysql2 + Express のみ）
- Trivy Image Scan による脆弱性チェックを CI/CD で実施

## 非対応機能（将来拡張可能）

- 認証・認可機能
- 投稿の更新・削除
- ページング
- レート制限

## トラブルシューティング

- **DB 接続エラー**: `DB_ENDPOINT`, `DB_APP_USERNAME`, `DB_APP_PASSWORD` が正しく設定されているか確認
- **テーブル作成失敗**: MySQL の root 権限でテーブルを手動作成するか、`mysql-init.sh` スクリプトの実行を確認
- **Pod が起動しない**: `kubectl logs <pod-name>` で詳細なエラーメッセージを確認
