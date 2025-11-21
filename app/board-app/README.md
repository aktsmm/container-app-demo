# 掲示板アプリ (board-app)

低コスト構成の AKS 上で動作する React + Vite 製の掲示板デモです。投稿はブラウザの LocalStorage に保存され、バックエンドを持たずに UI 動作のみを確認できます。

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
- 投稿データは LocalStorage に保持され、リロードしても端末内では残る。
- 将来的に API を接続したい場合は `useBoardStore` を差し替えることで拡張可能。
```
