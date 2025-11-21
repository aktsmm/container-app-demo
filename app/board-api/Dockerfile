# board-api: 掲示板投稿データを Azure VM 上の MySQL に永続化する API コンテナ
# 最低コスト志向: 小型ベースイメージ利用 (node:20-alpine)
FROM node:20-alpine

WORKDIR /app

# 依存関係のみ先にコピーしてレイヤーキャッシュ最適化
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund

# アプリ本体コピー
COPY server.js ./

# ポート 3000 を公開 (Service 経由で Ingress の /api/ パスにマッピング)
EXPOSE 3000

# 本番起動コマンド
CMD ["node", "server.js"]
