# GitGuardian が「📁 カテゴリ別アラート」に表示されない問題

**日時**: 2025 年 11 月 24 日  
**影響範囲**: Security Scan ワークフロー - カテゴリ別アラート集計  
**重要度**: 🟡 MEDIUM（検出自体は動作、表示のみの問題）

---

## 📋 問題の概要

GitGuardian の SARIF 変換が正常に動作し、「📊 実行されたスキャン」には結果が表示されるようになったが、「📁 カテゴリ別アラート」のカテゴリ集計には依然として GitGuardian が含まれない。

---

## 🐛 症状

### 観察された動作

- GitGuardian スキャンは正常に実行（✅）
- SARIF ファイルには 7 件の検出結果が含まれる（確認済み）
- 「📊 実行されたスキャン」に「⚠️ 7 件のシークレット検出」と表示される
- しかし「📁 カテゴリ別アラート」に GitGuardian のカテゴリが一切表示されない

### ログ出力

```bash
🔍 Processing category: gitguardian
  Files found: sarif/gitguardian-repo.sarif  ← ファイルは検出されている
  SARIF copied to temp dir
  Extracting results from SARIF...
  jq: error (at <stdin>:1): Cannot index string with string "results"  ← エラー発生
  ❌ No results found for category: gitguardian  ← 結果抽出失敗
```

---

## 🔍 原因分析

### jq クエリの構文エラー

**security-scan.yml 行 615 の jq クエリに構文エラーがあった：**

```bash
# ❌ 修正前（構文エラー）
CATEGORY_RESULTS=$(jq -r '.runs[]? .results[]? | {
  ruleId: .ruleId,
  level: .level,
  message: .message.text,
  location: (.locations[0].physicalLocation.artifactLocation.uri // "unknown")
} | @json' "${SARIF_FILE}")
```

**問題点**: `.runs[]? .results[]?` の間に `.` が欠落

- jq は `.runs[]?` を評価後、その結果（文字列またはオブジェクト）に対して `.results[]?` を適用しようとする
- しかし `.runs[]?` と次のフィルタの間に **ドット演算子がない**ため、jq は構文エラーと解釈
- エラーメッセージ: `Cannot index string with string "results"`

### SARIF の構造

```json
{
  "runs": [
    {
      "results": [
        {
          "ruleId": "gitguardian/OpenSSH Private Key",
          "level": "error",
          "message": { "text": "..." },
          "locations": [ ... ]
        }
      ]
    }
  ]
}
```

正しいクエリは: `.runs[]?.results[]?`（オプショナルチェーンの連結）

---

## ✅ 解決方法

### 修正内容（Commit: 025603f）

jq クエリにドット演算子を追加：

```bash
# ✅ 修正後（正しい構文）
CATEGORY_RESULTS=$(jq -r '.runs[]?.results[]? | {
  ruleId: .ruleId,
  level: .level,
  message: .message.text,
  location: (.locations[0].physicalLocation.artifactLocation.uri // "unknown")
} | @json' "${SARIF_FILE}")
```

**変更点**: `.runs[]? .results[]?` → `.runs[]?.results[]?`（ドット追加）

### 修正範囲

- **ファイル**: `.github/workflows/security-scan.yml`
- **行**: 615
- **変更内容**: 1 文字追加（`.`）

---

## 🧪 検証方法

### 1. 手動での jq クエリテスト

```bash
# 修正前のクエリ（エラー）
jq -r '.runs[]? .results[]? | .ruleId' sarif/gitguardian-repo.sarif
# jq: error (at sarif/gitguardian-repo.sarif:1): Cannot index string with string "results"

# 修正後のクエリ（成功）
jq -r '.runs[]?.results[]? | .ruleId' sarif/gitguardian-repo.sarif
# gitguardian/Generic Password
# gitguardian/OpenSSH Private Key
# gitguardian/Generic High Entropy Secret
# ...
```

### 2. ワークフロー実行の確認（Run 19629219232）

```
🔍 Processing category: gitguardian
  Files found: sarif/gitguardian-repo.sarif
  SARIF copied to temp dir
  Extracting results from SARIF...
  ✅ 7 results found for category: gitguardian  ← 成功
```

### 3. Summary の確認

「📁 カテゴリ別アラート」セクションに以下が表示される：

```markdown
### 🔐 Secrets Management (7 件)

**検出されたアラート（上位 5 件）:**

1. **gitguardian/Generic Password** [ERROR]

   - Location: app/board-app/public/dummy-secret.txt
   - Message: GitGuardian detected Generic Password in app/board-app/public/dummy-secret.txt

2. **gitguardian/OpenSSH Private Key** [ERROR]
   - Location: infra/aks_ssh
   - Message: GitGuardian detected OpenSSH Private Key in infra/aks_ssh
     ...
```

---

## 📝 教訓

### 1. **jq のオプショナルチェーン構文は厳密**

- `.runs[]?` と `.results[]?` を連結する場合は **必ず `.` が必要**
- 構文エラーが silent failure にならず、エラーメッセージを出すのは良い設計
- ただし「Cannot index string with string "results"」は原因が分かりにくい

### 2. **SARIF パース処理の共通化**

- 複数のカテゴリで同じ jq クエリを使用している
- 一箇所のバグが全カテゴリに影響する
- 共通関数化やテスト強化が必要

### 3. **段階的な検証**

- ローカルでの jq クエリテストを先に実行すべきだった
- SARIF ファイルをダウンロードして手動検証することで早期発見可能

---

## 🔗 関連情報

- **前提問題**: `2025-11-24-gitguardian-sarif-conversion-empty-results.md`（SARIF 変換の修正）
- **関連 Commit**:
  - 025603f: jq クエリ構文修正（この問題の解決）
  - ebc9360: Python 変換スクリプト修正（前段階の修正）
- **Workflow Run**: 19629219232（修正後の成功実行）

### デバッグプロセス

1. ログで「ファイルは見つかるが結果が 0 件」を確認
2. jq コマンド部分のエラーメッセージに注目
3. SARIF artifact をダウンロードしてローカルで jq テスト
4. 構文エラーを発見・修正
5. 1 文字の変更で解決

---

## 🎯 結果

✅ GitGuardian の検出結果が「📁 カテゴリ別アラート」に表示される  
✅ Secrets Management カテゴリに 7 件のアラートが正しく集計される  
✅ 上位 5 件の詳細（ruleId, location, message）が表示される

**総合結果**: GitGuardian が全 3 セクション（実行スキャン / カテゴリ別 / サマリー統計）で正常に表示されるようになった 🎉
