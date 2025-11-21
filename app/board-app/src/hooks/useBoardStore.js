import { useCallback, useEffect, useState } from "react";

// 掲示板投稿の状態管理フック
// 方針: MySQL 永続化 API(/api/posts) を正としつつ LocalStorage をキャッシュ/フォールバックに利用。
// ねらい: オフライン時でも直前の投稿を確認でき、再接続後は API へ自動再同期できるようにする。

const STORAGE_KEY = "board-app-posts-cache"; // API 応答キャッシュ
const API_BASE = import.meta.env.VITE_BOARD_API_BASE ?? ""; // 必要ならリバースプロキシ外部の API を指定

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

  const updatePosts = useCallback((updater) => {
    setPosts((prev) => {
      const next = typeof updater === "function" ? updater(prev) : updater;
      saveCache(next);
      return next;
    });
  }, []);

  const fetchFromApi = useCallback(async () => {
    setLoading(true);
    try {
      const res = await fetch(`${API_BASE}/api/posts`);
      if (!res.ok) throw new Error(`API 応答が不正です (${res.status})`);
      const data = await res.json();
      updatePosts(data);
      setError(null);
      return true;
    } catch (e) {
      console.warn("API 取得失敗。キャッシュへフォールバック", e);
      setError("MySQL 永続化 API からの取得に失敗しました (キャッシュ表示中)");
      return false;
    } finally {
      setLoading(false);
    }
  }, [updatePosts]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      if (!cancelled) await fetchFromApi();
    })();
    return () => {
      cancelled = true;
    };
  }, [fetchFromApi]);

  const randomId = () =>
    typeof crypto !== "undefined" && crypto.randomUUID
      ? crypto.randomUUID()
      : `temp-${Date.now()}`;

  // 新規投稿: API 経由。失敗時は pending 状態のままローカル保持
  const addPost = async (post) => {
    const tempId = randomId();
    const optimistic = {
      id: tempId,
      ...post,
      createdAt: new Date().toISOString(),
      pending: true,
    };
    updatePosts((prev) => [optimistic, ...prev]);

    try {
      const res = await fetch(`${API_BASE}/api/posts`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(post),
      });
      if (!res.ok) throw new Error(`投稿失敗 (${res.status})`);
      const created = await res.json();
      updatePosts((prev) =>
        prev.map((p) => (p.id === tempId ? { ...created, pending: false } : p))
      );
      setError(null);
      return true;
    } catch (e) {
      console.error("API 投稿失敗。ローカルのみ保持", e);
      setError("サーバ永続化に失敗したため一時保存しました");
      return false;
    }
  };

  const deletePost = (id) => {
    updatePosts((prev) => prev.filter((p) => p.id !== id));
  };

  return { posts, addPost, deletePost, loading, error, refresh: fetchFromApi };
}
