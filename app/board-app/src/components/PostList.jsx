import dayjs from "dayjs";

export default function PostList({ posts, onDelete }) {
  if (!posts.length) {
    return (
      <p className="empty-state">
        まだ投稿がありません。最初のメッセージを残してみましょう。
      </p>
    );
  }

  return (
    <ul className="post-list">
      {posts.map((post) => (
        <li key={post.id} className={post.pending ? "pending" : ""}>
          <div className="post-header">
            <h3>{post.author}</h3>
            <time dateTime={post.createdAt}>
              {dayjs(post.createdAt).format("YYYY/MM/DD HH:mm")}
            </time>
          </div>
          {post.pending && (
            <span className="post-badge" aria-live="polite">
              同期中 (MySQL)
            </span>
          )}
          <p>{post.message}</p>
          <button type="button" onClick={() => onDelete(post.id)}>
            削除
          </button>
        </li>
      ))}
    </ul>
  );
}
