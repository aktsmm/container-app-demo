# Admin App Container Apps で revision suffix が衝突する

**日時**: 2025-11-24  
**影響範囲**: `.github/workflows/2-admin-app-build-deploy.yml` (deploy ジョブ)  
**重要度**: 🔴 HIGH（Container Apps へのデプロイ全体が失敗）

---

## 📋 事象の概要

GitHub Actions から Azure Container Apps (管理アプリ) を更新するとき、`--revision-suffix "gh-${GITHUB_RUN_NUMBER}"` を毎回固定で指定していた。Workflow を再実行すると Run 番号が変わらないケースがあり、既存リビジョンと suffix が重複して `Failed to provision revision ... revision with suffix gh-55 already exists.` で停止した。

---

## 🐛 症状

- Workflow: `2️⃣ Admin App Build & Deploy #55`
- 失敗ジョブ: `deploy`
- ログ抜粋:

```
ERROR: Failed to provision revision for container app 'admin-app'.
Field 'template.revisionsuffix' is invalid with details: 'Invalid value: "gh-55": revision with suffix gh-55 already exists.'
```

既存リビジョン `admin-app--gh-55` が残っていると、同じ suffix を付けた Update/Create が Azure Resource Manager に拒否される。

---

## 🔍 原因

1. `GITHUB_RUN_NUMBER` は Workflow の手動再実行や `workflow_run` トリガー時でも変わらない。
2. Container Apps の revision suffix は各リビジョンで一意である必要がある（[Customize revisions | Azure Container Apps](https://learn.microsoft.com/azure/container-apps/revisions#customize-revisions)）。
3. その結果、再実行＝同じ suffix で再登録 → ARM エラー → デプロイ失敗。

---

## ✅ 対応内容

- Workflow の `deploy` ジョブに「リビジョンサフィックス生成」ステップを追加。
  ```bash
  ATTEMPT=${GITHUB_RUN_ATTEMPT:-1}
  echo "REVISION_SUFFIX=gh-${GITHUB_RUN_ID}-${ATTEMPT}" >> "$GITHUB_ENV"
  ```
- `az containerapp update/create --revision-suffix "$REVISION_SUFFIX"` に置き換え、Run ID + Attempt で常にユニークな suffix を付与。
- コミット: `df600ea (AdminアプリのリビジョンサフィックスをRunIDベースで一意化)`

これにより単発実行・再実行・`workflow_run` いずれでも suffix 衝突が起こらなくなった。

---

## 🧪 検証

1. 修正後に Workflow を連続実行しても `revision... already exists` が再発しないことを確認。
2. `az containerapp revision list --name admin-app --resource-group <RG>` で `admin-app--gh-<RunID>-<Attempt>` が生成されることを確認。
3. `revision set-mode single` 継続のため古いリビジョンは自動的に非アクティブ化され、リソース数が増えないことも確認済み。

---

## 📌 再発防止策

- Container Apps や Functions など **revision suffix が必要なサービスでは必ずユニークな ID を付与** する。Run ID / Commit ハッシュ / タイムスタンプなどを組み合わせる。
- Workflow を再実行する可能性があるジョブは `GITHUB_RUN_ATTEMPT` を併用し、リトライ時にも suffix が変わるようにする。
- 同様の競合を防ぐため、他のワークフローでも固定 suffix/名前を使用していないか定期的にレビューする。

---

## 🔗 関連情報

- 参考ドキュメント: [Azure Container Apps - Customize revisions](https://learn.microsoft.com/azure/container-apps/revisions#customize-revisions)
- GitHub Actions: `.github/workflows/2-admin-app-build-deploy.yml` (deploy ジョブ)

---

## 🎯 結果

- Admin App のデプロイが再実行でも安定し、`revision suffix` 衝突が解消。
- 再度同様の状況が発生しても Run ID ベースでユニーク化されるため、自動復旧可能。
