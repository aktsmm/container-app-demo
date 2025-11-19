# Node ステージ: Vite でビルド
FROM node:20.16.0-alpine3.19 AS build
WORKDIR /workspace
COPY package.json package-lock.json* .npmrc* ./
RUN npm install --legacy-peer-deps
COPY . ./
RUN npm run build

# NGINX ステージ: 静的ファイルを配信
FROM nginx:1.27.2-alpine-slim
COPY --from=build /workspace/dist /usr/share/nginx/html
COPY nginx/default.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
