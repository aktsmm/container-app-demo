import { useEffect, useState } from "react";

// 掲示板投稿の状態管理フック
// 仕様変更: LocalStorage 単体 -> MySQL 永続化 API(/api/posts) + LocalStorage フォールバック
// 目的: オフライン時/API 障害時でも投稿を一時保持し UX を損なわない。
// 注意: フォールバック時の投稿は他端末と共有されない (従来仕様と同じ)。

const STORAGE_KEY = "board-app-posts-cache"; // API 応答キャッシュ

function loadCache() {
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch (e) {
    console.error("キャッシュ読み込み失敗", e);
    return [];
  }
}

function saveCache(data) {
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(data));
  } catch (e) {
    console.error("キャッシュ保存失敗", e);
  }
}

export default function useBoardStore() {
  const [posts, setPosts] = useState(() => loadCache());
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  // 初期ロード: API から取得 / 失敗時はキャッシュ利用
  useEffect(() => {
    let cancelled = false;
    async function fetchPosts() {
      try {
        setLoading(true);
        const res = await fetch("/api/posts");
        if (!res.ok) throw new Error(`API 状態異常: ${res.status}`);
        const data = await res.json();
        if (!cancelled) {
          setPosts(data);
          saveCache(data);
        }
      } catch (e) {
        console.warn("API 取得失敗。キャッシュへフォールバック", e);
        if (!cancelled) setError(e.message);
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    fetchPosts();
    return () => {
      cancelled = true;
    };
  }, []);

  // 新規投稿: API 経由。失敗時はローカル生成で一時保持 (ユーザー通知可)
  const addPost = async (post) => {
    const tempId = crypto.randomUUID();
    const optimistic = {
      id: tempId,
      ...post,
      createdAt: new Date().toISOString(),
    };
    setPosts((prev) => [optimistic, ...prev]); // 楽観的更新
    try {
      const res = await fetch("/api/posts", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(post),
      });
      if (!res.ok) throw new Error(`投稿失敗: ${res.status}`);
      const created = await res.json();
      // ID/createdAt を確定レスポンスで置換
      setPosts((prev) => prev.map((p) => (p.id === tempId ? created : p)));
      saveCache(posts);
    } catch (e) {
      console.error("API 投稿失敗。ローカルのみ保持", e);
      setError("サーバ永続化に失敗しました (一時保存)");
      // キャッシュへも保存しておく
      saveCache(posts);
    }
  };

  const deletePost = (id) => {
    // 現段階では削除 API 未実装: UI 上のみ除去
    setPosts((prev) => prev.filter((p) => p.id !== id));
    saveCache(posts);
  };

  return { posts, addPost, deletePost, loading, error };
}
