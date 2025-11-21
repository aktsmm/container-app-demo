import { useState } from "react";

export default function PostForm({ onSubmit, disabled = false }) {
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
          placeholder="demo-user"
          disabled={disabled}
        />
      </label>
      <label>
        メッセージ
        <textarea
          value={message}
          onChange={(e) => setMessage(e.target.value)}
          placeholder="メッセージを書いてください。"
          disabled={disabled}
        />
      </label>
      <button type="submit" disabled={disabled}>
        {disabled ? "同期待ち" : "投稿する"}
      </button>
    </form>
  );
}
