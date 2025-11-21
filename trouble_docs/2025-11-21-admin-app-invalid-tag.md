# Admin App デプロイで Container Apps イメージタグが無効になる問題

**日時**: 2025 年 11 月 21 日 11:30 JST  
**対象ワークフロー**: `3️⃣ Deploy Admin App (Container Apps)`  
**Run**: #78（workflow_dispatch）  
**ステータス**: ⚠️ 失敗 → ワークフロー修正済み

---

## 📋 症状

- `az containerapp update` 実行時に `Failed to provision revision for container app 'admin-app'`。
- 詳細メッセージ: `template.containers.admin-app.image` が `acrdemo9894.azurecr.io/admin-app:2025-11-21T04:01:34.371343Z` となり、`could not parse reference` で拒否される。
- Container Apps では Docker と同じタグ形式制約（英数字 + `._-`）があるため、コロンや ISO8601 を含むタグは無効。

---

## 🔍 原因

1. `3-deploy-admin-app.yml` で最新タグを探す際、`az acr repository show-tags --detail -o tsv` の出力先頭列が `lastUpdateTime` になっており、ISO 8601 の値をそのままタグとして採用してしまった。
2. 手動入力 `imageTag` のバリデーションも無く、仮にユーザーが `2025-11-21T04:01:34.371343Z` のような文字列を指定しても検知できなかった。
3. その結果、`admin-app` の新 revision 作成時に無効なタグが渡り rollback された。

---

## 🛠️ 対応

1. `az acr repository show-tags` を `--detail` なし & `-o tsv` に変更し、タグだけを行単位で取得。
2. `validate_tag()` を追加し、`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` のみ許可。
3. 手動入力タグも同じ関数で検証し、違反時は即座に失敗させるよう変更。
4. ACR 側で無効タグが混入していた場合でもスキップし、最終的に `latest` へフォールバックする `pick_latest_tag()` を実装。
5. ワークフロー修正内容: `.github/workflows/3-deploy-admin-app.yml` の `image_meta` ステップを書き換え。

---

## ✅ 今後の確認事項

- 次回 `3️⃣ Deploy Admin App (Container Apps)` 実行時にタグ検出ログを確認し、`Image:` が `SHA` ベースの期待値になっているか検証。
- もし `az acr repository show-tags` に 50 件以上の履歴があり `latest` 以外が古い場合は `--top` を拡大する。
- コンテナタグ命名規則は [ACR のタグ推奨事項](https://learn.microsoft.com/azure/container-registry/container-registry-image-tag-version) を踏襲し、ISO 文字列をそのまま採用しない運用を周知する。
