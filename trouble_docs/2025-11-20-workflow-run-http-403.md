# GitHub Actions workflow_run トリガーでの HTTP 403 エラー

**日時**: 2025-11-20  
**対象ワークフロー**: `3️⃣ Deploy Admin App (Container Apps)`, `3️⃣ Deploy Board App (AKS)`  
**エラー**: `HTTP 403: Resource not accessible by integration`

---

## 📌 問題の概要

`workflow_run` トリガーで起動されたデプロイワークフローが、Infrastructure Deploy の成果物を取得しようとした際に HTTP 403 エラーで失敗した。

### エラーメッセージ

```
couldn't fetch workflows for aktsmm/container-app-demo: HTTP 403: Resource not accessible by integration
(https://api.github.com/repos/aktsmm/container-app-demo/actions/workflows?per_page=100&page=1)
```

---

## 🔍 根本原因

### 1. `gh run list --workflow` の権限不足

`workflow_run` トリガーで起動されたワークフローでは、`GITHUB_TOKEN` に **workflow リスト取得権限**がデフォルトで付与されていない。

以下のコードが失敗:

```bash
gh run list --workflow "1️⃣ Infrastructure Deploy" --status success --json databaseId --limit 1
```

### 2. `actions: read` 権限の不足

当初は `actions: read` 権限を追加したが、これだけでは **workflow API へのアクセス**には不十分だった。

```yaml
permissions:
  contents: read
  id-token: write
  actions: read # アーティファクトダウンロードには有効だが workflow リスト取得には不十分
```

---

## ✅ 解決策

### GitHub REST API を直接使用

`gh run list` の代わりに、`curl` と GitHub REST API を使用して workflow 実行履歴を検索。

#### 修正前のコード

```bash
if [ "${{ github.event_name }}" = "workflow_run" ] && [ "${{ github.event.workflow_run.name }}" = "$INFRA_WORKFLOW_NAME" ]; then
  TARGET_RUN_ID='${{ github.event.workflow_run.id }}'
else
  TARGET_RUN_ID=$(gh run list --workflow "$INFRA_WORKFLOW_NAME" --status success --json databaseId --limit 1 | jq -r '.[0].databaseId')
fi
```

#### 修正後のコード

```bash
if [ "${{ github.event_name }}" = "workflow_run" ] && [ "${{ github.event.workflow_run.name }}" = "$INFRA_WORKFLOW_NAME" ]; then
  TARGET_RUN_ID='${{ github.event.workflow_run.id }}'
  echo "workflow_run トリガー: run_id=$TARGET_RUN_ID"
else
  # 手動実行時は GitHub REST API 経由で検索（gh run list が workflow 権限不足で失敗する場合の回避策)
  TARGET_RUN_ID=$(curl -s -H "Authorization: token $GH_TOKEN" \
    "https://api.github.com/repos/${{ github.repository }}/actions/workflows/1-infra-deploy.yml/runs?status=success&per_page=1" \
    | jq -r '.workflow_runs[0].id')
  echo "手動実行: 最新の成功した Infrastructure Deploy run_id=$TARGET_RUN_ID"
fi
```

#### ポイント

1. **workflow ファイル名で直接指定**: `1-infra-deploy.yml` を URL に含める
2. **REST API のクエリパラメータ**: `?status=success&per_page=1` で最新の成功実行を取得
3. **jq でパース**: `.workflow_runs[0].id` で run ID を抽出
4. **環境変数 `GH_TOKEN`**: `${{ github.token }}` を使用して認証

---

## 🛠️ 修正対象ファイル

### 1. `.github/workflows/3-deploy-admin-app.yml`

```diff
       - name: インフラ出力アーティファクトから MySQL IP を取得
         id: mysql_endpoint
         env:
           GH_TOKEN: ${{ github.token }}
           INFRA_WORKFLOW_NAME: "1️⃣ Infrastructure Deploy"
         run: |
           set -euo pipefail
           mkdir -p infra-output
           if [ "${{ github.event_name }}" = "workflow_run" ] && [ "${{ github.event.workflow_run.name }}" = "$INFRA_WORKFLOW_NAME" ]; then
             TARGET_RUN_ID='${{ github.event.workflow_run.id }}'
+            echo "workflow_run トリガー: run_id=$TARGET_RUN_ID"
           else
-            TARGET_RUN_ID=$(gh run list --workflow "$INFRA_WORKFLOW_NAME" --status success --json databaseId --limit 1 | jq -r '.[0].databaseId')
+            TARGET_RUN_ID=$(curl -s -H "Authorization: token $GH_TOKEN" \
+              "https://api.github.com/repos/${{ github.repository }}/actions/workflows/1-infra-deploy.yml/runs?status=success&per_page=1" \
+              | jq -r '.workflow_runs[0].id')
+            echo "手動実行: 最新の成功した Infrastructure Deploy run_id=$TARGET_RUN_ID"
           fi
```

### 2. `.github/workflows/3-deploy-board-app.yml`

同様の修正を適用。

---

## 🎯 検証結果

### 修正前

- **Run ID**: 19541820795
- **Status**: ❌ Failed
- **Error**: `HTTP 403: Resource not accessible by integration`

### 修正後

- **Run ID**: 19542118168 (Deploy Admin App)
- **Status**: ✅ Success
- **Elapsed**: 2m50s

### ワークフロー全体の成功

```
✓ 3️⃣ Deploy Admin App (Container Apps)  - 19542118168 - Success
✓ 3️⃣ Deploy Board App (AKS)             - 19541832257 - Success
✓ 2️⃣ Build Admin App                    - 19542052635 - Success
✓ 2️⃣ Build Board App                    - 19541749887 - Success
```

---

## 💡 教訓

### 1. `workflow_run` のトークン制限

`workflow_run` トリガーで起動されたワークフローでは、`GITHUB_TOKEN` の権限が制限される。特に workflow リスト取得は明示的な権限が必要。

### 2. GitHub CLI の制限

`gh` CLI は内部的に GitHub API を呼び出すが、トークン権限不足時のエラーハンドリングが不十分。REST API を直接使用する方が柔軟。

### 3. Workflow ファイル名の利用

GitHub Actions の `workflow_run` では workflow **名前**（例: `"1️⃣ Infrastructure Deploy"`）で検索できるが、REST API では **ファイル名**（例: `1-infra-deploy.yml`）が必要。

### 4. `gh run rerun` の落とし穴

`gh run rerun` は**古いコミット時点のワークフローコード**を再実行する。修正を反映させるには、元のトリガー（Build workflow）を再実行する必要がある。

---

## 🔗 関連リソース

- [GitHub Actions Permissions](https://docs.github.com/en/actions/security-guides/automatic-token-authentication#permissions-for-the-github_token)
- [GitHub REST API - List workflow runs](https://docs.github.com/en/rest/actions/workflow-runs#list-workflow-runs-for-a-workflow)
- [workflow_run event](https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows#workflow_run)

---

## 📊 コミット履歴

```bash
# 1回目の修正（actions: read 権限追加 - 効果なし）
git commit -m "fix: デプロイワークフローにactions:read権限を追加してアーティファクトダウンロードエラーを解消"

# 2回目の修正（GitHub REST API に切り替え - 解決）
git commit -m "fix: gh run list の HTTP 403 を回避するため GitHub REST API に切り替え"
```

---

## 🚀 今後の対策

1. **REST API の積極活用**: GitHub CLI に依存せず、直接 REST API を使用する
2. **権限の明示化**: `permissions` ブロックで必要な権限を明示的に宣言
3. **デバッグログの充実**: `echo` でトリガー元や取得した値を出力
4. **ドキュメント化**: 同様のエラーが発生した場合の参照資料として保存

---

**関連トラブルシューティング**:

- [2025-11-20-vm-admin-username-invalid.md](./2025-11-20-vm-admin-username-invalid.md)
- [2025-11-20-managed-identity-migration.md](./2025-11-20-managed-identity-migration.md)
