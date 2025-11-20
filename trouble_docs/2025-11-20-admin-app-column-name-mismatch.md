# トラブルシューティング履歴：Admin App カラム名不一致エラー

## 📅 発生日時

2025-11-20 18:30 頃

---

## 🔴 問題の概要

### 症状

Admin App（Container Apps）の管理画面で以下のエラーが表示：

```
💬 掲示板メッセージ管理
🔄 更新
(1054, "Unknown column 'content' in 'field list'")
```

### 影響範囲

- 掲示板メッセージの一覧表示が不可能
- メッセージ削除機能が使用不可
- Admin App の主要機能が停止

---

## 🔍 根本原因

### データベーススキーマの確認

MySQL の `posts` テーブルの実際の構造：

```sql
mysql> DESCRIBE posts;
+------------+-------------+------+-----+---------+-------+
| Field      | Type        | Null | Key | Default | Extra |
+------------+-------------+------+-----+---------+-------+
| id         | varchar(36) | NO   | PRI | NULL    |       |
| author     | varchar(100)| NO   |     | NULL    |       |
| message    | text        | NO   |     | NULL    |       |  ← 実際は message
| created_at | datetime    | NO   |     | NULL    |       |
+------------+-------------+------+-----+---------+-------+
```

### コード側の想定

**app/admin-app/src/app.py (Line 134):**

```python
cursor.execute("""
  SELECT id, author, content, created_at  ← content を参照
  FROM posts
  ORDER BY created_at DESC
  LIMIT 100
""")
```

**app/admin-app/src/app.py (Line 308 - JavaScript):**

```javascript
const content =
  m.content.length > 50 ? m.content.substring(0, 50) + "..." : m.content;
```

### 原因まとめ

- 実際のカラム名：`message`
- コードの想定：`content`
- **カラム名の不一致**により SQL エラー発生

---

## ✅ 解決策

### 1. Python コードの修正（SQL クエリ）

**修正前：**

```python
cursor.execute("""
  SELECT id, author, content, created_at
  FROM posts
  ORDER BY created_at DESC
  LIMIT 100
""")
```

**修正後：**

```python
cursor.execute("""
  SELECT id, author, message, created_at
  FROM posts
  ORDER BY created_at DESC
  LIMIT 100
""")
```

### 2. JavaScript コードの修正（UI 表示）

**修正前：**

```javascript
const content =
  m.content.length > 50 ? m.content.substring(0, 50) + "..." : m.content;
html += `<tr><td>${m.id}</td><td>${m.author}</td><td>${content}</td>...`;
```

**修正後：**

```javascript
const message =
  m.message.length > 50 ? m.message.substring(0, 50) + "..." : m.message;
html += `<tr><td>${m.id}</td><td>${m.author}</td><td>${message}</td>...`;
```

### 3. ビルド＆デプロイ

```bash
# コード修正後
git add app/admin-app/src/app.py
git commit -m "fix: MySQL カラム名を content から message に修正"
git push origin master

# ビルド実行
gh workflow run "2-build-admin-app.yml"

# デプロイ実行（自動起動 or 手動）
gh workflow run "3-deploy-admin-app.yml"
```

---

## 📊 実行結果

### ビルド（Run 19532354957）

```
✓ code-security-scans in 17s
✓ build-and-push in 1m51s
  ✓ コンテナイメージをビルド
  ✓ Trivy でコンテナをスキャン
  ✓ イメージを ACR へプッシュ
```

### デプロイ（Run 19532417989）

```
✓ deploy in 2m37s
  ✓ ACR 名を解決
  ✓ Storage Account 名を解決
  ✓ MySQL VM の IP アドレスを取得
  ✓ Container Apps へデプロイ
  ✓ Container App に Managed Identity を付与
```

### 最終確認

```bash
# Container App のリビジョン確認
az containerapp revision list --name admin-app --resource-group RG-bbs-app-demo-test

Name              Image                                          Traffic
----------------  ---------------------------------------------  ---------
admin-app--gh-42  acrdemo8546.azurecr.io/admin-app:3616a735df3f  100
```

**結果：** ✅ Admin App でメッセージ一覧が正常に表示されることを確認

---

## 🎓 教訓

### 1. データベーススキーマの確認方法

開発時には必ず実際のテーブル構造を確認：

```bash
# VM 上で直接確認
az vm run-command invoke \
  --resource-group RG-bbs-app-demo-test \
  --name vm-mysql-demo \
  --command-id RunShellScript \
  --scripts "mysql -u boardapp -p'PASSWORD' -D boardapp -e 'DESCRIBE posts;'"
```

### 2. フロントエンドとバックエンドの整合性

- API レスポンスのフィールド名
- UI での参照名
- データベースのカラム名

**すべて一致している必要がある**

### 3. エラーメッセージの読み方

```
(1054, "Unknown column 'content' in 'field list'")
```

- エラーコード `1054`：MySQL のカラム不存在エラー
- `'content'`：存在しないカラム名
- `'field list'`：SELECT 句で指定したフィールドリスト

→ SQL クエリを確認すべきと判断できる

### 4. Container Apps のイメージキャッシュ問題

デプロイ成功後もエラーが継続する場合：

1. **最新イメージタグが使われているか確認**

   ```bash
   az containerapp revision list --name admin-app --resource-group RG-bbs-app-demo-test
   ```

2. **ACR の最新タグと比較**

   ```bash
   az acr repository show-tags --name acrdemo8546 --repository admin-app --orderby time_desc --top 3
   ```

3. **タグ取得ロジックの修正**
   - workflow_run トリガー時に ACR から最新タグを自動取得
   - 手動実行時も最新タグをデフォルト使用

---

## 🔧 予防策

### 1. 型定義の活用

TypeScript や Python の型ヒントでカラム名を明示：

```python
from typing import TypedDict

class Post(TypedDict):
    id: str
    author: str
    message: str  # ← カラム名を型で明示
    created_at: str
```

### 2. ORM の使用検討

SQLAlchemy や Prisma などの ORM を使用すると：

- カラム名のタイポを防げる
- スキーマ変更時の影響範囲が明確
- IDE の補完が効く

### 3. 統合テストの実装

実際のデータベースに対してテストを実行：

```python
def test_list_messages():
    response = client.get('/api/messages')
    assert response.status_code == 200
    assert 'messages' in response.json()
```

### 4. スキーマドキュメントの管理

データベーススキーマを `docs/database-schema.md` などで管理：

```markdown
## posts テーブル

| カラム名   | 型           | 説明           |
| ---------- | ------------ | -------------- |
| id         | varchar(36)  | UUID           |
| author     | varchar(100) | 投稿者名       |
| message    | text         | メッセージ本文 |
| created_at | datetime     | 投稿日時       |
```

---

## 📝 関連ドキュメント

- `app/admin-app/src/app.py` - 管理アプリのメインコード
- `scripts/mysql-init.sh` - MySQL 初期化スクリプト（テーブル定義）
- `trouble_docs/2025-11-20-resource-group-not-found.md` - リソースグループ削除問題
- `trouble_docs/2025-11-20-mysql-apt-repository-error.md` - MySQL インストールエラー

---

## ✅ 最終確認

### 動作確認項目

- [x] 掲示板メッセージ一覧が表示される
- [x] メッセージの内容が正しく表示される
- [x] メッセージ削除機能が動作する
- [x] 最新のコンテナイメージがデプロイされている

**対応完了日時：** 2025-11-20 18:50
