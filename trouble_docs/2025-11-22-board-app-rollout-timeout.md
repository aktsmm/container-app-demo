# Board App ロールアウト待機が 120 秒でタイムアウトする問題

**日時**: 2025 年 11 月 22 日 10:05 JST 頃  
**対象ワークフロー**: `3️⃣ Deploy Board App (AKS)`  
**Run**: workflow_dispatch（Run ID は Actions 履歴を参照）  
**ステータス**: ⚠️ 再発防止策を実装済み（要再実行で確認）

---

## 📋 現象

- Step `Kustomize を適用` で `kubectl rollout status deployment/board-app -n board-app --timeout=120s` が 120 秒で終了。
- ログには以下のようなメッセージのみが繰り返し出力され、Pod イメージの Pull 失敗等は記録されない。

```
Waiting for deployment "board-app" rollout to finish: 0 of 1 updated replicas are available...
error: timed out waiting for the condition
```

- ワークフローは exit code 1 で停止するが、AKS クラスタ上ではロールアウト処理自体が継続しており、数分後に Pod が Ready になるケースがある。

---

## 🔍 調査メモ

1. `kubectl` の `--timeout` は CLI 側の待機時間であり、Deployment の `progressDeadlineSeconds` とは別物。120 秒で待機を打ち切ると、クラスタ側で処理が続いていても CI が失敗扱いになる。
2. Standard_B2s (1 vCPU / 4 GiB) ノード 1 台で ingress-nginx / board-api / board-app / kube-system を同居させているため、寒い状態からのコンテナ Pull + 起動に 2 分超かかることがある。
3. ログに `ImagePullBackOff` 等の致命的エラーは出ていないため、純粋に待機時間不足が原因と判断。

---

## 🧠 原因

- `kubectl rollout status` の `--timeout` を 120 秒に固定していたため、実際のデプロイ時間（150-240 秒）と乖離。
- 120 秒経過時点で `kubectl` が `timed out waiting for the condition` を返し、ワークフロー全体が失敗扱いになる。
- Deployment は裏側で進行しており、CI の制限値だけがボトルネックだった。

---

## 🛠️ 対応

1. `3-deploy-board-app.yml` の `wait_rollout` ロジックを追加し、`board-app` / `board-api` いずれも **420 秒**（7 分）まで待つよう変更。
2. タイムアウトが発生した場合でも即終了せず、`kubectl get pods` / `kubectl describe deployment` / `kubectl get events` を収集してログ・Step Summary に残す診断関数を追加。
3. `board-api` は従来通り MySQL 待ちで失敗するケースがあるため、警告を出しつつワークフロー継続に変更なし。
4. `set -euo pipefail` を明示してロールアウト待機のハンドリングを一元化。

---

## ✅ フォローアップ

- 次回 `3️⃣ Deploy Board App (AKS)` 実行時にロールアウト待ちが 420 秒で十分か確認。必要ならパラメータ化する。
- 新しい診断出力に `ImagePullBackOff` や `FailedScheduling` が現れた場合は追加対策を検討。
- 監視結果は本ファイルに追記する。
