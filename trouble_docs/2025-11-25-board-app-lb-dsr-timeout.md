# 2025-11-25 Board App LB DSR Timeout

## 事象概要
- GitHub Actions の `2️⃣ Board App Build & Deploy` ワークフローが「LoadBalancer 経由で HTML を取得」ステップで毎回 `HTTP 000` となり失敗していた。
- ローカル環境から `curl -I http://20.18.94.114` を実行しても 10 秒でタイムアウトし、`Test-NetConnection` でも TCP セッション確立に失敗。
- しかし世界各地のスキャナからのアクセスや AKS 内部 Pod からのアクセスは正常に 200 応答を返していた。

## 原因
- Ingress コントローラ Service が `externalTrafficPolicy: Local` (DSR) で公開されており、SNAT が行われないため一部ネットワークからのフローで TCP ハンドシェイクが成立しなくなっていた。
- GitHub Actions ランナーおよび社内ネットワークからの通信が影響を受け、Ingress まで到達できずにタイムアウトしていた。

## 対応
- `app/board-app/k8s/ingress-nginx-values.yaml` の `externalTrafficPolicy` を `Cluster` に変更し、従来の NodePort 指定はヘルスチェック継続用に維持。
- 変更後 2 分待機して再度 `curl -I http://20.18.94.114` を実行すると HTTP 200 を取得でき、`Test-NetConnection` でも `TcpTestSucceeded: True` を確認済み。
- 今後のワークフロー実行時は同設定が適用されるため、外部疎通ステップも完了する見込み。

## メモ
- 参考ドキュメント: [Azure Load Balancer のトラブルシューティング](https://learn.microsoft.com/azure/load-balancer/load-balancer-troubleshoot)
- 再発した場合は `externalTrafficPolicy` が意図せず `Local` に戻っていないか、Helm values 上書き設定を確認する。
