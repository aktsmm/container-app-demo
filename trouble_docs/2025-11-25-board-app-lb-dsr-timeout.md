# 2025-11-25 Board App LB DSR Timeout

## 事象概要

- GitHub Actions の `2️⃣ Board App Build & Deploy` ワークフローが「LoadBalancer 経由で HTML を取得」ステップで毎回 `HTTP 000` となり失敗していた。
- ローカル環境から `curl -I http://20.18.94.114` を実行しても 10 秒でタイムアウトし、`Test-NetConnection` でも TCP セッション確立に失敗。
- しかし世界各地のスキャナからのアクセスや AKS 内部 Pod からのアクセスは正常に 200 応答を返していた。

## 原因

- Ingress コントローラ Service が `externalTrafficPolicy: Local` (DSR) で公開されており、SNAT が行われないため一部ネットワークからのフローで TCP ハンドシェイクが成立しなくなっていた。
- GitHub Actions ランナーおよび社内ネットワークからの通信が影響を受け、Ingress まで到達できずにタイムアウトしていた。

## 対応

- `app/board-app/k8s/ingress-nginx-values.yaml` の `externalTrafficPolicy` を `Cluster` に変更。これにより Azure Load Balancer 経由で入ってきたトラフィックでも Kubernetes ノードが SNAT を行うため、GitHub Actions ランナーや社内ネットワークのように戻りのパケット経路が制御できない環境でも正しく TCP ハンドシェイクが成立する。`healthCheckNodePort: 30254` はそのまま残すことで、Load Balancer 側のヘルスプローブ定義を変えずに済み安定運用できる。
- Azure Standard Load Balancer の HTTP/HTTPS ルールに対し、`floatingIp=false`（DSR 無効化）と `disableOutboundSnat=false`（SNAT 有効化）を必ず適用する処理を GitHub Actions ワークフローに実装。ルール取得時に不一致を検知すると `az network lb rule update` を自動実行して補正するため、インフラ再作成や手動操作で DSR が再度有効化されても次のデプロイ時に必ず通常モードへ戻る。既存リソースにも同じコマンドを適用済みで、`curl -I http://20.18.94.114` で即座に HTTP 200 を返すことを確認できた。
- 変更後 2 分待機して再度 `curl -I http://20.18.94.114` を実行すると HTTP 200 を取得でき、`Test-NetConnection` でも `TcpTestSucceeded: True` を確認済み。
- 今後のワークフロー実行時は同設定が適用されるため、外部疎通ステップも完了する見込み。

## メモ

- 参考ドキュメント: [Azure Load Balancer のトラブルシューティング](https://learn.microsoft.com/azure/load-balancer/load-balancer-troubleshoot)
- 再発した場合は `externalTrafficPolicy` が意図せず `Local` に戻っていないか、Helm values 上書き設定を確認する。
