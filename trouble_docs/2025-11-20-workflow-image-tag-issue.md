# トラブルシューティング履歴：デプロイワークフローでの古いイメージタグ使用問題

## 📅 発生日時

2025-11-20 18:40 頃

---

## 🔴 問題の概要

### 症状

- Admin App のコードを修正してビルド＆デプロイ成功
- しかし、**修正前のエラーが継続**して表示される
- Container App が古いイメージを使用している

### エラー状況

```
💬 掲示板メッセージ管理
🔄 更新
(1054, "Unknown column 'content' in 'field list'")
```

修正済みコードをデプロイしたにも関わらず、エラーが解消されない。

---

## 🔍 根本原因

### Container App リビジョンの確認

```bash
az containerapp revision list --name admin-app --resource-group RG-bbs-app-demo-test
```

**結果：**

```
Name              Image                                          Active
----------------  ---------------------------------------------  --------
admin-app--gh-39  acrdemo8546.azurecr.io/admin-app:3d30f0ae1dbb  True
```

イメージタグ：`3d30f0ae1dbb`（古いコミット）

### ACR の最新イメージタグ確認

```bash
az acr repository show-tags --name acrdemo8546 --repository admin-app --orderby time_desc --top 3
```

**結果：**

```
Result
------------
latest
3616a735df3f  ← 最新（修正済み）
3d30f0ae1dbb  ← 古い（デプロイ中）
```

### デプロイログの確認

```bash
gh run view 19532417989 --log | Select-String -Pattern "IMAGE_TAG"
```

**結果：**

```
IMAGE_TAG: 3d30f0ae1dbb
IMAGE_FULL: acrdemo8546.azurecr.io/admin-app:3d30f0ae1dbb
```

### 原因まとめ

**`.github/workflows/3-deploy-admin-app.yml` のイメージタグ決定ロジック：**

```yaml
- name: イメージタグを決定
  run: |
    EVENT_NAME='${{ github.event_name }}'
    if [ "$EVENT_NAME" = 'workflow_run' ]; then
      HEAD_SHA='${{ github.event.workflow_run.head_sha }}'
      IMAGE_TAG="${HEAD_SHA:0:12}"  ← 問題：ビルド時のコミットSHA
    else
      IMAGE_TAG='${{ github.event.inputs.imageTag }}'
    fi
    if [ -z "$IMAGE_TAG" ]; then
      IMAGE_TAG='latest'
    fi
```

**問題点：**

1. `github.event.workflow_run.head_sha` は**デプロイワークフローが起動されたコミット**
2. ビルドワークフローが完了した時点の**最新イメージ**とは限らない
3. 複数回のビルドが連続した場合、古いイメージがデプロイされる可能性

---

## ✅ 解決策

### 1. ACR から最新イメージタグを取得するように修正

**修正後のロジック：**

```yaml
- name: イメージタグを決定
  id: image_meta
  run: |
    EVENT_NAME='${{ github.event_name }}'
    INPUT_TAG='${{ github.event.inputs.imageTag }}'

    # 入力タグが指定されている場合はそれを使用
    if [ -n "$INPUT_TAG" ]; then
      IMAGE_TAG="$INPUT_TAG"
      echo "指定されたタグを使用: $IMAGE_TAG"
    else
      # ACR から最新のイメージタグを取得（latest 以外）
      LATEST_TAG=$(az acr repository show-tags \
        --name "$ACR_NAME" \
        --repository "$ADMIN_IMAGE_NAME" \
        --orderby time_desc \
        --top 5 \
        -o tsv | grep -v '^latest$' | head -n 1)
      if [ -n "$LATEST_TAG" ]; then
        IMAGE_TAG="$LATEST_TAG"
        echo "ACR から最新タグを取得: $IMAGE_TAG"
      else
        IMAGE_TAG='latest'
        echo "ACR にタグが見つからないため latest を使用"
      fi
    fi

    echo "IMAGE_TAG=$IMAGE_TAG" >> "$GITHUB_ENV"
    echo "IMAGE_FULL=$ACR_LOGIN_SERVER/$ADMIN_IMAGE_NAME:$IMAGE_TAG" >> "$GITHUB_ENV"
```

### 2. 動作パターン

#### パターン A：自動デプロイ（workflow_run トリガー）

1. ビルドワークフロー成功
2. デプロイワークフロー自動起動
3. **ACR から最新タグを取得**
4. 最新イメージでデプロイ

#### パターン B：手動デプロイ（workflow_dispatch）

- **imageTag 指定あり**：指定したタグを使用（特定バージョンデプロイ）
- **imageTag 指定なし**：ACR から最新タグを取得（最新版デプロイ）

### 3. 修正のコミット＆デプロイ

```bash
# 修正1回目
git add .github/workflows/3-deploy-admin-app.yml
git commit -m "fix: Admin App で最新イメージタグを ACR から取得するように修正"
git push origin master

# 修正2回目（手動実行対応）
git add .github/workflows/3-deploy-admin-app.yml
git commit -m "fix: 手動実行時も ACR から最新イメージタグを取得"
git push origin master

# デプロイ実行
gh workflow run "3-deploy-admin-app.yml"
gh run watch 19532690967
```

---

## 📊 実行結果

### 修正後のデプロイ（Run 19532690967）

```
✓ deploy in 2m12s
  ✓ イメージタグを決定
  ✓ Container Apps へデプロイ
```

### イメージタグ確認

```bash
gh run view 19532690967 --log | Select-String -Pattern "IMAGE_TAG:"
```

**結果：**

```
IMAGE_TAG: 3616a735df3f  ← 最新のコミット！
```

### Container App リビジョン確認

```bash
az containerapp revision list --name admin-app --resource-group RG-bbs-app-demo-test
```

**結果：**

```
Name              Image                                          Traffic
----------------  ---------------------------------------------  ---------
admin-app--gh-42  acrdemo8546.azurecr.io/admin-app:3616a735df3f  100
```

**確認完了：** ✅ 最新イメージがデプロイされ、Admin App が正常に動作

---

## 🎓 教訓

### 1. workflow_run の挙動を理解する

**`github.event.workflow_run.head_sha` の問題：**

- デプロイワークフローが**起動されたコミット**の SHA
- ビルドワークフローが**完了したコミット**とは限らない
- 複数ビルドが連続した場合、古いコミットの SHA を参照する可能性

**正しいアプローチ：**

- ACR から実際にプッシュされた**最新イメージタグ**を取得
- タイムスタンプでソートして最新を特定

### 2. デプロイ後の検証方法

#### Step 1: Container App のリビジョン確認

```bash
az containerapp revision list \
  --name admin-app \
  --resource-group RG-bbs-app-demo-test \
  --query "[?properties.active].{Name:name, Image:properties.template.containers[0].image}"
```

#### Step 2: ACR の最新タグと比較

```bash
az acr repository show-tags \
  --name acrdemo8546 \
  --repository admin-app \
  --orderby time_desc \
  --top 3
```

#### Step 3: 一致しない場合は再デプロイ

```bash
gh workflow run "3-deploy-admin-app.yml"
```

### 3. イメージタグの命名戦略

#### 推奨される戦略

1. **コミット SHA（短縮版）**：`3616a735df3f`

   - メリット：Git 履歴と紐付けやすい
   - デメリット：時系列が分かりにくい

2. **タイムスタンプ**：`20251120184500`

   - メリット：新しさが一目瞭然
   - デメリット：Git コミットと紐付けが難しい

3. **セマンティックバージョニング**：`v1.2.3`
   - メリット：変更の種類が分かる
   - デメリット：自動化が複雑

**本プロジェクトの選択：**

- **コミット SHA（12 文字）** を使用
- ACR の `--orderby time_desc` でタイムスタンプ順に取得
- 両方のメリットを享受

### 4. デプロイの冪等性確保

同じコードを複数回デプロイしても：

- 同じイメージタグが使われる
- 同じ結果になる（副作用なし）
- ACR から常に最新を取得することで保証

---

## 🔧 予防策

### 1. CI/CD パイプラインのテスト

デプロイ後に自動で検証：

```yaml
- name: デプロイ検証
  run: |
    DEPLOYED_IMAGE=$(az containerapp revision list \
      --name admin-app \
      --resource-group RG-bbs-app-demo-test \
      --query "[?properties.active].properties.template.containers[0].image" \
      -o tsv)

    EXPECTED_IMAGE="$IMAGE_FULL"

    if [ "$DEPLOYED_IMAGE" != "$EXPECTED_IMAGE" ]; then
      echo "❌ デプロイされたイメージが期待と異なります"
      echo "Expected: $EXPECTED_IMAGE"
      echo "Deployed: $DEPLOYED_IMAGE"
      exit 1
    fi

    echo "✅ 正しいイメージがデプロイされました"
```

### 2. Blue-Green デプロイメント

Container Apps の Traffic Splitting を活用：

```bash
# 新リビジョンに 20% トラフィック
az containerapp ingress traffic set \
  --name admin-app \
  --resource-group RG-bbs-app-demo-test \
  --revision-weight admin-app--gh-42=80 admin-app--gh-43=20
```

検証後に 100% に切り替え。

### 3. イメージタグの明示的指定

重要なデプロイでは手動で特定バージョンを指定：

```bash
gh workflow run "3-deploy-admin-app.yml" \
  -f imageTag=3616a735df3f
```

### 4. デプロイ履歴の記録

各デプロイの情報を記録：

```yaml
- name: デプロイ履歴を記録
  run: |
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | $IMAGE_TAG | $GITHUB_RUN_ID" >> deployment-history.log
    git add deployment-history.log
    git commit -m "chore: デプロイ履歴を記録 [$IMAGE_TAG]"
```

---

## 📝 関連ドキュメント

- `.github/workflows/3-deploy-admin-app.yml` - Admin App デプロイワークフロー
- `.github/workflows/2-build-admin-app.yml` - Admin App ビルドワークフロー
- `trouble_docs/2025-11-20-admin-app-column-name-mismatch.md` - カラム名不一致エラー
- `docs/github-actions-sp-deploy.md` - GitHub Actions 認証設定

---

## ✅ 最終確認

### 動作確認項目

- [x] workflow_run 時に ACR から最新タグを取得
- [x] 手動実行時に最新タグをデフォルト使用
- [x] 特定タグの指定も可能（柔軟性）
- [x] デプロイされたイメージが最新であることを確認
- [x] Admin App が正常に動作

**対応完了日時：** 2025-11-20 19:00
