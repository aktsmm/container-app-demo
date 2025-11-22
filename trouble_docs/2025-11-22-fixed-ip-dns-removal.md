# 固定 IP と DNS 名の完全廃止対応

## 📅 発生日時

2025 年 11 月 22 日

## 🔍 問題の概要

Board App をデプロイ後、DNS 名 `aksdemodevingress.japaneast.cloudapp.azure.com` にアクセスすると接続タイムアウトが発生する問題が発生。調査の結果、DNS 名が古い IP アドレス（48.210.73.177）を指しているのに対し、実際の AKS LoadBalancer は新しい IP アドレス（74.176.19.199）を使用していることが判明。

## 🎯 根本原因

1. **過去のワークフロー変更で固定 IP 指定を削除**
   - 以前のコミットで Helm values から `loadBalancerIP` 指定を削除
   - AKS が新しい LoadBalancer IP を自動作成
2. **Bicep で作成した Public IP リソースが残存**

   - `pip-aks-ingress-dev` という Public IP リソースが Bicep で作成されたまま
   - この Public IP に DNS ラベル `aksdemodevingress` が設定されていた
   - 古い IP アドレス（48.210.73.177）が DNS に紐づいたまま

3. **ワークフローと Bicep の不整合**
   - ワークフロー：固定 IP を使わない（AKS に自動割り当て）
   - Bicep：固定 IP リソースを作成
   - 結果：使用されない Public IP リソースが残り続ける

## 🛠️ 対応内容

### 1️⃣ Bicep から Public IP リソース定義を削除

**修正ファイル**: `infra/main.bicep`, `infra/modules/aks.bicep`

- Public IP リソース `pip-aks-ingress-dev` の作成処理を削除
- 関連するパラメータ（`ingressPublicIpName`, `ingressPublicIpDnsLabel`）を削除
- 関連する出力（`ingressPublicIpAddress`, `ingressPublicIpFqdn`）を削除

```diff
- param ingressPublicIpName string
- param ingressPublicIpDnsLabel string
- param boardAppIngressHost string

- resource ingressPublicIp 'Microsoft.Network/publicIPAddresses@2024-01-01' existing = {
-   scope: resourceGroup(nodeResourceGroup)
-   name: ingressPublicIpName
- }

- output ingressPublicIpAddress string = ingressPublicIp.properties.ipAddress
- output ingressPublicIpFqdn string = ingressPublicIp.properties.dnsSettings.fqdn
```

### 2️⃣ parameters.json から Public IP パラメータを削除

**修正ファイル**: `infra/parameters/main-dev.parameters.json`

```diff
- "ingressPublicIpName": {
-   "value": "pip-aks-ingress-dev"
- },
- "ingressPublicIpDnsLabel": {
-   "value": "aksdemodevingress"
- },
- "boardAppIngressHost": {
-   "value": "aksdemodevingress.japaneast.cloudapp.azure.com"
- }
```

### 3️⃣ ワークフローから Ingress IP 解決ロジックを削除

**修正ファイル**: `.github/workflows/2-board-app-build-deploy.yml`

- `prepare-context` job の outputs から `ingress_ip` と `ingress_fqdn` を削除
- `mysql_endpoint` ステップから Public IP 解決ロジックを削除
- `deploy` job から `INGRESS_STATIC_IP` と `INGRESS_FQDN` 環境変数を削除
- "Bicep で作成した Public IP の DNS を更新" ステップを完全削除
- LoadBalancer ヘルスチェックから固定 IP フォールバック処理を削除
- デプロイサマリから DNS URL 表示を削除、LoadBalancer IP のみ表示

### 4️⃣ Kubernetes Ingress 定義から DNS ホスト指定を削除

**修正ファイル**: `app/board-app/k8s/ingress.yaml`, `app/board-app/k8s/kustomization.yaml`

- `kustomization.yaml` から `BOARD_APP_INGRESS_HOST` 変数定義を削除
- `ingress.yaml` から DNS ホスト指定ルールを削除
- LoadBalancer IP への直接アクセスのみをサポートする構成に変更

```diff
spec:
  rules:
-   # Host 指定なし: Load Balancer IP への直接アクセス用
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: board-app
                port:
                  number: 80
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: board-api
                port:
                  number: 3000
-   # Host 指定あり: Bicep で確保した Public IP の DNS 名を使用
-   - host: $(BOARD_APP_INGRESS_HOST)
-     http:
-       paths: ...
```

### 5️⃣ vars.env と同期スクリプトを更新

**修正ファイル**: `app/board-app/k8s/vars.env`, `scripts/sync-board-vars.ps1`

- `vars.env` から `ingressHost` エントリを削除
- `sync-board-vars.ps1` から `ingressHost` 処理を完全削除
- Namespace 情報のみを管理するように簡素化

### 6️⃣ Helm クリーンアップロジックの強化

**修正ファイル**: `.github/workflows/2-board-app-build-deploy.yml`

前回のデプロイ失敗で Helm Release が `pending-upgrade` 状態でロックされる問題に対応。

```bash
# 固まっている Helm Release を強制的にクリーンアップ
# pending-install, pending-upgrade, failed 状態の場合は即座に削除
if helm list -n ingress-nginx | grep -q ingress-nginx; then
  HELM_STATUS=$(helm status ingress-nginx -n ingress-nginx -o json 2>/dev/null | jq -r '.info.status // empty' || echo "unknown")
  echo "現在の Helm リリース状態: $HELM_STATUS"

  if [ "$HELM_STATUS" = "pending-install" ] || [ "$HELM_STATUS" = "pending-upgrade" ] || [ "$HELM_STATUS" = "failed" ]; then
    echo "⚠️ Helm Release が ${HELM_STATUS} 状態です。強制クリーンアップを実行します..."
    helm uninstall ingress-nginx -n ingress-nginx --wait --timeout=2m || true
    sleep 10
    echo "✅ Helm Release をクリーンアップしました"
  fi
fi
```

## 📋 トラブルシューティング手順

### エラー 1: kustomize で ingressHost フィールドが見つからない

```
error: field specified in var '{BOARD_APP_INGRESS_HOST ConfigMap.v1.[noGrp] {data.ingressHost}}' not found in corresponding resource
```

**原因**: `vars.env` から `ingressHost` を削除したが、`kustomization.yaml` でまだ参照していた

**対応**: `kustomization.yaml` から `BOARD_APP_INGRESS_HOST` 変数定義を削除

### エラー 2: Helm が pending-upgrade 状態でロック

```
Error: UPGRADE FAILED: another operation (install/upgrade/rollback) is in progress
```

**原因**: 前回のデプロイ失敗時に Helm Release が `pending-upgrade` 状態でロックされた

**対応**: Helm クリーンアップロジックを強化し、pending/failed 状態を自動検出して強制削除

### エラー 3: AKS クラスターへの接続失敗

```
Unable to connect to the server: dial tcp: lookup aksdemodev-komm1npo.hcp.japaneast.azmk8s.io: no such host
```

**原因**: AKS クラスター名の DNS 解決に失敗（一時的なネットワーク問題）

**対応**: ワークフロー再実行で自動解決

## ✅ 最終的な構成

### アクセス方法

- **DNS 名**: 使用しない（廃止）
- **LoadBalancer IP**: AKS が自動割り当てした IP で直接アクセス
  - 例: `http://4.190.74.201`
  - ダミーシークレット: `http://4.190.74.201/dummy-secret.txt`

### リソース構成

```
┌─────────────────────────────────────────┐
│ GitHub Actions Workflow                 │
│ ・固定 IP 指定なし                      │
│ ・AKS 自動割り当て IP を使用            │
└─────────────────────────────────────────┘
              ↓ デプロイ
┌─────────────────────────────────────────┐
│ Azure AKS                               │
│ ├─ NGINX Ingress Controller             │
│ │   └─ Service (LoadBalancer)           │
│ │       └─ EXTERNAL-IP: 4.190.74.201    │
│ │          (AKS が自動割り当て)          │
│ └─ Board App/API Pods                   │
└─────────────────────────────────────────┘
              ↓ 公開
┌─────────────────────────────────────────┐
│ Internet Users                          │
│ ・http://4.190.74.201 でアクセス        │
│ ・DNS 名は使用しない                    │
└─────────────────────────────────────────┘
```

### Bicep リソース

- **作成するもの**: VNet, AKS, ACR, VM (MySQL), Storage Account, Log Analytics
- **作成しないもの**: Public IP リソース（AKS が自動作成）

## 🔄 デプロイフロー

1. Infrastructure デプロイ（Bicep）
   - Public IP リソースは作成しない
   - AKS クラスターのみ作成
2. Board App ビルド・デプロイ
   - NGINX Ingress Controller を Helm でインストール
   - LoadBalancer Service が作成される
   - **AKS が自動的に Public IP を割り当て**
3. LoadBalancer IP 取得
   ```bash
   kubectl get svc -n ingress-nginx ingress-nginx-controller \
     -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
   ```
4. アクセス
   - 取得した IP アドレスで直接アクセス
   - DNS 名は使用しない

## 📝 学んだこと

### 1. Infrastructure as Code の一貫性

- ワークフローと Bicep の両方で同じ設計思想を持つことが重要
- 片方で固定 IP を削除したら、もう片方も削除する必要がある

### 2. AKS LoadBalancer の動作

- `loadBalancerIP` を指定しない場合、AKS が自動的に Public IP を作成
- この自動作成された IP は AKS の Node Resource Group に配置される
- Bicep で別途作成した Public IP とは独立して動作する

### 3. DNS の罠

- Public IP に DNS ラベルを設定すると、IP が変わっても DNS レコードは残る
- 使わなくなった Public IP リソースは明示的に削除する必要がある

### 4. Helm のロック問題

- `--atomic` オプション使用時、失敗すると `pending-upgrade` 状態でロックされる
- 次回デプロイ前に明示的にクリーンアップする必要がある
- `helm uninstall` で強制削除が有効

## 🎓 ベストプラクティス

### ✅ DO

- AKS LoadBalancer の自動 IP 割り当てを活用する（低コスト）
- DNS が必要な場合は Azure DNS Zone で管理する
- Helm Release の状態を毎回チェックしてクリーンアップする
- Infrastructure as Code とワークフローの設計を統一する

### ❌ DON'T

- Bicep で Public IP を作成して、ワークフローで使わない
- 使わなくなった Public IP リソースを放置する
- Helm の `pending-*` 状態を放置する
- DNS 名に依存したアーキテクチャを組む（デモ環境の場合）

## 📚 関連ドキュメント

- [2025-11-22-board-app-blank-screen.md](./2025-11-22-board-app-blank-screen.md) - 初期トラブルシューティング
- [2025-01-21-loadbalancer-healthprobe-nodeport-mismatch.md](./2025-01-21-loadbalancer-healthprobe-nodeport-mismatch.md) - LoadBalancer 関連の過去事例

## 🔗 参考リンク

- [AKS での LoadBalancer サービスの使用](https://learn.microsoft.com/ja-jp/azure/aks/load-balancer-standard)
- [Kubernetes Ingress の概念](https://kubernetes.io/docs/concepts/services-networking/ingress/)
- [Helm の atomic フラグ](https://helm.sh/docs/helm/helm_upgrade/)

---

**ステータス**: ✅ 解決完了  
**最終更新**: 2025 年 11 月 22 日  
**対応者**: GitHub Copilot + User
