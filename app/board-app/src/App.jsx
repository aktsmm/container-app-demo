import { useMemo, useState } from "react";
import dayjs from "dayjs";
import useBoardStore from "./hooks/useBoardStore.js";
import PostForm from "./components/PostForm.jsx";
import PostList from "./components/PostList.jsx";

const filters = {
  all: "すべて",
  today: "今日の投稿",
};

export default function App() {
  const { posts, addPost, deletePost, loading, error, refresh } =
    useBoardStore();
  const [filter, setFilter] = useState("all");

  const filteredPosts = useMemo(() => {
    if (filter !== "today") {
      return posts;
    }
    const today = dayjs().format("YYYY-MM-DD");
    return posts.filter(
      (post) => dayjs(post.createdAt).format("YYYY-MM-DD") === today
    );
  }, [posts, filter]);

  return (
    <div className="app-shell">
      <header>
        <h1>掲示板デモアプリ</h1>
        <p>
          AKS 上でホストされる簡易掲示板。投稿は Azure VM 上の MySQL
          に永続化され、ネットワーク障害時のみブラウザの LocalStorage
          キャッシュへフォールバックします。
        </p>
        <a
          className="secret-link"
          href="/dummy-secret.txt"
          target="_blank"
          rel="noreferrer"
        >
          ダミーシークレットはこちら
        </a>
      </header>

      <section className="filter-bar">
        {Object.entries(filters).map(([key, label]) => (
          <button
            key={key}
            className={filter === key ? "active" : ""}
            type="button"
            onClick={() => setFilter(key)}
          >
            {label}
          </button>
        ))}
      </section>

      <section className="status-bar" aria-live="polite">
        {loading && (
          <span className="status-message">MySQL から投稿を同期中...</span>
        )}
        {error && (
          <span className="status-message error">
            {error}
            <button type="button" onClick={refresh}>
              再読み込み
            </button>
          </span>
        )}
      </section>

      <main>
        <PostForm onSubmit={addPost} disabled={loading} />
        <PostList posts={filteredPosts} onDelete={deletePost} />
      </main>

      <footer>
        <small>
          Azure Kubernetes Service や Azure Container Registry
          を用いてこのアプリは作っています
        </small>
      </footer>
    </div>
  );
}
