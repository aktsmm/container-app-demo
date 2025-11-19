import { useState } from "react";

export default function PostForm({ onSubmit }) {
  const [author, setAuthor] = useState("");
  const [message, setMessage] = useState("");

  const handleSubmit = (event) => {
    event.preventDefault();
    if (!author.trim() || !message.trim()) {
      return;
    }
    onSubmit({ author: author.trim(), message: message.trim() });
    setMessage("");
  };

  return (
    <form className="post-form" onSubmit={handleSubmit}>
      <label>
        投稿者
        <input
          value={author}
          onChange={(e) => setAuthor(e.target.value)}
          placeholder="例: demo-user"
        />
      </label>
      <label>
        メッセージ
        <textarea
          value={message}
          onChange={(e) => setMessage(e.target.value)}
          placeholder="進捗や障害メモをここに書きます"
        />
      </label>
      <button type="submit">投稿する</button>
    </form>
  );
}
