# 文字化け (Mojibake) トラブルシュート

## 現象

日本語テキストが「縺薙※」「繝輔ぃ繧､繝ｫ」などの文字列に化ける。これは **UTF-8 のバイト列を Shift_JIS (CP932) として誤って解釈** した際に典型的に現れるパターン。

## 代表例

```
縺薙※繝輔ぃ繧､繝ｫ ...
```

## 主因一覧

- エディタ保存: VS Code が UTF-8 だが別ツールが Shift_JIS 前提で再解釈
- ターミナルコードページ: Windows PowerShell が `chcp 932` (CP932) のまま出力
- Docker コンテナ内ロケール未設定で一部ツールが ANSI 前提出力
- HTTP レスポンスヘッダに charset が無く古いブラウザ/ツールが誤推測
- Git コミットメッセージを CP932 端末で入力 → リポジトリ側は UTF-8 として保存

## 対策 (本リポで実施)

1. `index.html` に `<meta charset="UTF-8" />` あり → ブラウザ解釈を UTF-8 に固定
2. `dummy-secret.txt` は UTF-8 (BOM 無し) で保存済み
3. 各 Dockerfile に `LANG=ja_JP.UTF-8 LC_ALL=ja_JP.UTF-8` を追加
4. Python コンテナでは `locales` を導入し `ja_JP.UTF-8` を生成

## 追加で推奨

### GitHub Actions (Linux Runner)

通常は UTF-8 なので追加不要。ログ中で崩れる場合は念のためステップ先頭に:

```bash
locale
```

で確認。

### Windows PowerShell 手動操作

```powershell
chcp 65001   # UTF-8 コードページ
$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
```

### NGINX で明示的 charset 付与 (必要なら)

`/etc/nginx/conf.d/default.conf`:

```
add_header Content-Type "text/html; charset=UTF-8";
```

(現状 meta タグで十分なので省略中)

## 再発防止チェックリスト

| 項目          | 望ましい設定     | 確認方法                         |
| ------------- | ---------------- | -------------------------------- | ---------- |
| Editor 保存   | UTF-8 (BOM 無し) | VS Code 右下エンコーディング表示 |
| ターミナル CP | 65001            | `chcp`                           |
| Docker LANG   | ja_JP.UTF-8      | `docker exec env                 | grep LANG` |
| HTML charset  | `<meta charset>` | ページソース表示                 |
| Git commit    | UTF-8            | `git log --encoding=UTF-8`       |

## よくある誤解

- "ファイルを Shift_JIS で開けば直る" → 根本原因は表示側の推測。正しくは **全経路 UTF-8 統一**。
- "ロケール生成しないと UTF-8 使えない" → Alpine (musl) は生成不要。Debian/Ubuntu は `locale-gen` が必要な場合あり。

## もし再度発生したら

1. 問題文字列をコピー
2. VS Code の右下でエンコーディングを手動変更し表示差を見る
3. `file -i` (Linux) / PowerShell の `Get-Content -Encoding` でエンコーディング確認
4. 誤った端末コードページ (932) で入力していないか履歴を確認

## 参考

- UTF-8/Shift_JIS 典型的侵食: 多バイト先頭 0xE3 が CP932 で "縺" などに化ける
- Git はコミットメッセージをバイナリ扱いしないが慣例的に UTF-8 を推奨

---

更新日: 2025-11-20
