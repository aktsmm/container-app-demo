# Node ステージ: Vite でビルド
FROM node:20.16.0-alpine3.19 AS build
# 文字化け防止: ビルド時も UTF-8 ロケールを明示 (Alpine は musl なので生成不要だが環境変数で統一)
ENV LANG=ja_JP.UTF-8 \
	LC_ALL=ja_JP.UTF-8
WORKDIR /workspace
COPY package.json package-lock.json* .npmrc* ./
RUN npm install --legacy-peer-deps
COPY . ./
RUN npm run build

# NGINX ステージ: 静的ファイルを配信
FROM nginx:1.27.2-alpine-slim
# 配信側も UTF-8 ロケールを統一 (ブラウザは meta charset を参照するがログ/ヘッダの一貫性確保)
ENV LANG=ja_JP.UTF-8 \
	LC_ALL=ja_JP.UTF-8
COPY --from=build /workspace/dist /usr/share/nginx/html
COPY nginx/default.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
