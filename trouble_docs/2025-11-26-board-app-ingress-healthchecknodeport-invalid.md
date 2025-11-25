# 2025-11-26 Board App Ingress `healthCheckNodePort` Invalid エラー

## 事象概要

- GitHub Actions の `2️⃣ Board App Build & Deploy` ワークフロー (#130) が `Ingress Controller (nginx) を確認/インストール` ステップで失敗。
- Helm の `upgrade --install` 実行時に `Service "ingress-nginx-controller" is invalid: spec.healthCheckNodePort: Invalid value: 30254: may only be set when type is 'LoadBalancer' and externalTrafficPolicy is 'Local'` が発生し、`ingress-nginx` リリースがロールバックされた。
- 失敗後は Ingress Controller の Service が存在せず、後続のアプリデプロイ処理（Kustomize 適用）がブロックされた。

## 影響範囲

- `ingress-nginx` の Helm リリースが作成されないため、掲示板アプリの Ingress が全停止。
- ワークフローが `deploy` ジョブで必ず失敗する状態となり、CI/CD パイプライン全体が停止。

## 原因

- `app/board-app/k8s/ingress-nginx-values.yaml` で `externalTrafficPolicy: Cluster` に変更した後も、`healthCheckNodePort: 30254` を固定指定していた。
- Kubernetes Service の仕様上、`healthCheckNodePort` は `externalTrafficPolicy: Local` のときのみ設定可能なフィールドであり、`Cluster` ではバリデーションエラーになる。
  - 参考: [Configure a public standard load balancer in Azure Kubernetes Service (AKS)](https://learn.microsoft.com/azure/aks/configure-load-balancer-standard#customizations-via-kubernetes-annotations)

## 対応

1. `app/board-app/k8s/ingress-nginx-values.yaml` から `healthCheckNodePort` 設定を削除し、Azure Standard Load Balancer の共有ヘルスプローブに任せる構成へ変更（コミット `d0354c9`）。
2. `trouble_docs/2025-11-25-board-app-lb-dsr-timeout.md` に共有プローブへ切り替えた旨を追記し、手順の整合性を保全。
3. `READMEs/README_QUICKSTART.md` の確認手順を更新し、`healthCheckNodePort` 固定の参照を除去。
4. 変更を `origin/master` にプッシュ後、ワークフロー再実行で Helm インストールが成功することを確認。

## 検証結果

- `helm upgrade` が成功し、`kubectl get svc -n ingress-nginx ingress-nginx-controller` で自動割り当ての `nodePort` と LoadBalancer IP を取得できる状態を確認。
- `kubectl describe svc` で HTTP probe (`/healthz`) が標準設定として適用されていることを確認。

## 今後の防止策 / TODO

- `externalTrafficPolicy` を今後変更する場合は、`healthCheckNodePort` の互換性を必ず確認する運用ルールを README に明記済み。
- `2️⃣ Board App Build & Deploy` ワークフローで Helm 失敗時に `kubectl describe svc ingress-nginx-controller` が空の場合は `healthCheckNodePort` 設定を再確認するよう Step Summary に注意書きを追加予定。
