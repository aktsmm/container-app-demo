import { useEffect, useState } from "react";

const STORAGE_KEY = "board-app-posts";

function loadFromStorage() {
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch (error) {
    console.error("ローカルストレージの読み込みに失敗しました", error);
    return [];
  }
}

function persistToStorage(data) {
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(data));
  } catch (error) {
    console.error("ローカルストレージの書き込みに失敗しました", error);
  }
}

export default function useBoardStore() {
  const [posts, setPosts] = useState(() => loadFromStorage());

  useEffect(() => {
    persistToStorage(posts);
  }, [posts]);

  const addPost = (post) => {
    const newPost = {
      id: crypto.randomUUID(),
      ...post,
      createdAt: new Date().toISOString(),
    };
    setPosts((prev) => [newPost, ...prev]);
  };

  const deletePost = (id) => {
    setPosts((prev) => prev.filter((post) => post.id !== id));
  };

  return { posts, addPost, deletePost };
}
