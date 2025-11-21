/*
  board-api: AKS 上で動作し、Azure VM (MySQL) に掲示板投稿を永続化する軽量 REST API。
  要件:
    - GET /api/posts : すべての投稿を時系列降順で返す
    - POST /api/posts { author, message } : 新規投稿を作成し返す
    - テーブルが存在しない場合は自動作成 (冪等性確保)
    - DB 接続情報は Kubernetes Secret から環境変数で渡す (GitHub Actions の変数/Secrets 由来)
  非要件 (拡張余地): 認証 / 削除 / 更新 / ページング
  低コスト設計: Node.js + mysql2 のみ、追加ライブラリ最小限
*/
import express from "express";
import mysql from "mysql2/promise";
import { randomUUID } from "crypto";

// 環境変数 (GitHub Actions -> k8s Secret 経由で注入)
// DB_ENDPOINT 形式: host:port
const {
  DB_ENDPOINT = "",
  DB_APP_USERNAME = "",
  DB_APP_PASSWORD = "",
} = process.env;

if (!DB_ENDPOINT || !DB_APP_USERNAME || !DB_APP_PASSWORD) {
  // 起動時に必須情報が欠けている場合は明示的に終了 (クラッシュループで検知しやすい)
  console.error(
    "必須環境変数(DB_ENDPOINT/DB_APP_USERNAME/DB_APP_PASSWORD)が未設定です"
  );
  process.exit(1);
}

const [DB_HOST, DB_PORT_STR] = DB_ENDPOINT.split(":");
const DB_PORT = Number(DB_PORT_STR || 3306);

// コネクションプール (最小限の接続を維持し MySQL 側負荷を抑制)
const pool = mysql.createPool({
  host: DB_HOST,
  port: DB_PORT,
  user: DB_APP_USERNAME,
  password: DB_APP_PASSWORD,
  database: "boardapp", // 初回接続で存在しない場合は作成する方針
  waitForConnections: true,
  connectionLimit: 5,
  queueLimit: 0,
});

async function ensureDatabaseAndTable() {
  // DB がない場合作成 (CREATE DATABASE IF NOT EXISTS) 後にテーブル作成
  const rootConn = await mysql.createConnection({
    host: DB_HOST,
    port: DB_PORT,
    user: DB_APP_USERNAME,
    password: DB_APP_PASSWORD,
  });
  await rootConn.query(
    "CREATE DATABASE IF NOT EXISTS boardapp CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
  );
  await rootConn.end();

  const conn = await pool.getConnection();
  await conn.query(`CREATE TABLE IF NOT EXISTS posts (
    id VARCHAR(36) PRIMARY KEY,
    author VARCHAR(100) NOT NULL,
    message TEXT NOT NULL,
    created_at DATETIME NOT NULL
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`);
  conn.release();
}

// 起動前に初期化
ensureDatabaseAndTable().catch((err) => {
  console.error("DB 初期化に失敗しました", err);
  process.exit(2);
});

const app = express();
app.use(express.json());

// ヘルスチェック (readiness / liveness 用)
app.get("/health", (_, res) => {
  res.json({ status: "ok" });
});

// 全投稿取得
app.get("/api/posts", async (_, res) => {
  try {
    const conn = await pool.getConnection();
    const [rows] = await conn.query(
      "SELECT id, author, message, created_at FROM posts ORDER BY created_at DESC"
    );
    conn.release();
    res.json(
      rows.map((r) => ({
        id: r.id,
        author: r.author,
        message: r.message,
        createdAt: r.created_at.toISOString?.() || r.created_at,
      }))
    );
  } catch (err) {
    console.error("投稿一覧取得失敗", err);
    res.status(500).json({ error: "サーバ内部エラー (一覧取得)" });
  }
});

// 新規投稿
app.post("/api/posts", async (req, res) => {
  const { author, message } = req.body || {};
  if (!author || !message) {
    return res.status(400).json({ error: "author と message は必須です" });
  }
  try {
    const id = randomUUID();
    const createdAt = new Date();
    const conn = await pool.getConnection();
    await conn.query(
      "INSERT INTO posts (id, author, message, created_at) VALUES (?, ?, ?, ?)",
      [id, author, message, createdAt]
    );
    conn.release();
    res
      .status(201)
      .json({ id, author, message, createdAt: createdAt.toISOString() });
  } catch (err) {
    console.error("投稿追加失敗", err);
    res.status(500).json({ error: "サーバ内部エラー (投稿追加)" });
  }
});

// 最低限のエラーハンドラ (JSON 形式統一)
app.use((err, _req, res, _next) => {
  console.error("未処理エラー", err);
  res.status(500).json({ error: "未処理エラー" });
});

const PORT = 3000;
app.listen(PORT, () => {
  console.log(`board-api 起動: ポート ${PORT} (MySQL: ${DB_HOST}:${DB_PORT})`);
});
