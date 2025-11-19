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
  const { posts, addPost, deletePost } = useBoardStore();
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
        <h1>低コスト掲示板デモ</h1>
        <p>
          AKS 上でホストされる簡易掲示板。投稿はブラウザの LocalStorage
          に保存されるためデータベース不要です。
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

      <main>
        <PostForm onSubmit={addPost} />
        <PostList posts={filteredPosts} onDelete={deletePost} />
      </main>

      <footer>
        <small>
          ログは Log Analytics
          に転送されます。ブラウザを閉じると投稿は残りますが、別の端末とは共有されません。
        </small>
      </footer>
    </div>
  );
}
