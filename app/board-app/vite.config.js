import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Vite 設定。ACA/AKS どちらでもビルド成果物を配信できるようにする。
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    host: "0.0.0.0",
  },
  build: {
    outDir: "dist",
    sourcemap: true,
  },
});
