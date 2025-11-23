# 掲示板アプリ (board-app)

低コスト構成の AKS 上で動作する React + Vite 製の掲示板フロントエンドです。投稿機能は `board-api` (Node.js/Express) バックエンドと連携し、MySQL VM にデータを永続化します。

## ローカル実行
```powershell
cd app/board-app
npm install
npm run dev -- --host 0.0.0.0 --port 5173
```

## コンテナビルド
```powershell
cd app/board-app
docker build -t board-app:dev .
```

## 主な仕様
- `public/dummy-secret.txt` を公開し、UI からリンクできるようにしている。
- 投稿データは `board-api` (REST API) を介して MySQL VM に保存される。
- Ingress 経由で NGINX から配信され、`/api/*` へのリクエストは `board-api` サービスへルーティングされる。
- 将来的な API 拡張や認証機能の追加も容易に実装可能。
