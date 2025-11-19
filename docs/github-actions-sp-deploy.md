# GitHub Actions による Azure デプロイ（Service Principal 認証）

## 目的

- `.github/copilot-instructions.md`・`docs/architecture.md`・`ignore/環境情報`のルールを唯一の真実源として参照し、AKS + ACA + VM(MySQL) + Storage + Log Analytics を **低コスト SKU** で IaC 化する。
- GitHub Actions では **Service Principal + Client Secret** 認証を使用し、OIDC は明示的に無効化する。
- `AZURE_SUBSCRIPTION_ID` のみを GitHub Secrets に、残りの値を GitHub Actions Variables に保持し、再現性のある Bicep デプロイを実施する。
- デプロイ後の監視、失敗時のトラブルシュート履歴、類似環境との比較を Markdown で管理する。

## 1. 必須変数一覧

### GitHub Secrets

| 変数名                  | 用途                                                                    |
| ----------------------- | ----------------------------------------------------------------------- |
| `AZURE_SUBSCRIPTION_ID` | 対象サブスクリプション ID（例: `7134d7ae-2fe3-4eec-8f0b-5ffad8355907`） |

### GitHub Actions Variables

| 変数名                                    | 用途                                            |
| ----------------------------------------- | ----------------------------------------------- |
| `AZURE_CLIENT_ID`                         | Service Principal の Client ID                  |
| `AZURE_TENANT_ID`                         | Tenant ID                                       |
| `AZURE_CLIENT_SECRET`                     | Service Principal のクライアントシークレット    |
| `RESOURCE_GROUP_NAME`                     | 例: `rg-demodemo`                               |
| `LOCATION`                                | 例: `JapanEast`                                 |
| `VM_ADMIN_USERNAME` / `VM_ADMIN_PASSWORD` | VM の管理者資格情報                             |
| `DB_USERNAME` / `DB_PASSWORD`             | MySQL 接続資格情報                              |
| `AKS_CLUSTER_NAME`                        | AKS クラスタ名（B 系や DS 系の 1 ノードプール） |
| `CONTAINER_REGISTRY_NAME`                 | ACR 名（Basic SKU）                             |

> Tip: Variables はリポジトリ共通値を置き、必要に応じて Environment Variables で上書きすると PR 用の検証環境を安全に切り替えられる。

## 2. 事前準備フロー

1. **Service Principal 作成**

   ```powershell
   # 必要に応じてテナント・サブスクリプションへログイン
   az login --tenant 892fd90b-434b-42d0-bd82-41f9e1ba23f3
   az account set --subscription 7134d7ae-2fe3-4eec-8f0b-5ffad8355907

   # GitHub Actions 用の Service Principal を Contributor 権限で作成
   az ad sp create-for-rbac `
     --name "gha-sp-secret" `
     --role Contributor `
     --scopes /subscriptions/${env:AZURE_SUBSCRIPTION_ID} `
     --sdk-auth
   ```

   - 出力 JSON から Client ID / Tenant / Secret を抽出し Variables へ登録、`AZURE_SUBSCRIPTION_ID` のみ Secrets に保存。
   - `scripts/create-github-actions-sp.ps1` を利用するとシークレット期限の統一や Scope 検証を自動化できる。

2. **Bicep パラメータ更新**

   - `infra/parameters/*.json` へ LOCATION・VNet・NSG・ノード SKU などを全てパラメータ化して格納。
   - `az deployment sub what-if --no-pretty-print` で差分を確認し、意図しないリソース変更を検知する。

3. **dummy-secret 公開**
   - `app/board-app/public/dummy-secret.txt` を配置しトップページから「ダミーシークレットはこちら」リンクを追加。
   - ファイル内コメントで「ダミーであり本番鍵ではない」旨を明示し、UI 上で確認できるようにする。

## 3. GitHub Actions ワークフロー整理

| Workflow                       | 主な処理                                   | 実装ポイント                                                                                             |
| ------------------------------ | ------------------------------------------ | -------------------------------------------------------------------------------------------------------- |
| `infra-deploy.yml`             | Bicep Validate → What-If → Deploy          | `azure/login@v2` を Client Secret 認証で利用。`az deployment sub create` に `parameters/*.json` を指定。 |
| `app-build-board.yml`          | 掲示板アプリ build + Trivy scan + ACR push | `docker/login-action` と SP 資格情報で ACR にログイン。scan 結果を Artifact 化。                         |
| `app-deploy-board.yml`         | AKS へ Deployment/Service/Ingress 適用     | `azure/aks-set-context@v3` で kubeconfig を取得し、`kubectl apply -k app/board-app/k8s` を実行。         |
| `app-build-admin.yml`          | 管理アプリ build + Trivy + ACR push        | ACA スペック(0.5vCPU/1Gi)などをタグ化し、後続の deploy workflow へ渡す。                                 |
| `app-deploy-admin.yml`         | ACA リビジョン更新 + Basic 認証            | `az containerapp update` で `--secrets` と `--ingress-target-port` を指定しゼロダウンタイム更新。        |
| `backup-upload.yml`            | VM → Storage へ MySQL バックアップ送信     | GitHub Actions から VM へ SSH し `azcopy`/`rsync` を実行。Log Analytics に結果を送る。                   |
| `cleanup-failed-workflows.yml` | 失敗 Workflow とキャッシュ清掃             | `gh run list --status failure` → `gh run delete` で停滞を解消。                                          |

### 共通の Azure ログインステップ

```yaml
- name: Azure login
  uses: azure/login@v2
  with:
    client-id: ${{ vars.AZURE_CLIENT_ID }} # Service Principal 認証を明示
    tenant-id: ${{ vars.AZURE_TENANT_ID }} # OIDC を使わず Client Secret でログイン
    subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
    client-secret: ${{ vars.AZURE_CLIENT_SECRET }}
```

- ログアウトは `- name: Azure logout` → `run: az logout` を末尾に追加し、セッション残留を防ぐ。

## 4. 監視とログ統合

- **AKS**: Container Insights + control plane ログ（kube-apiserver / scheduler / controller-manager）を Log Analytics へ。`az aks enable-addons -a monitoring` で有効化し、コスト最適化のためワークスペース保持期間を 30 日 + アーカイブ 90 日に設定。
- **ACA**: `az monitor diagnostic-settings create` で Console/System/HTTP ログを Log Analytics へ送信。必要に応じて Storage へも複製し長期保管。
- **VM(MySQL)**: Azure Monitor Agent をインストールして Syslog/MySQL error/cron/Heartbeat を収集。バックアップスクリプト結果をカスタムログとして送る。
- **Storage Account**: 読み書き削除操作を Log Analytics に送信し、MySQL バックアップの成否を追跡。
- **Azure Activity**: サブスクリプション全体で必須。What-If と実デプロイとの差異調査に利用。

## 5. トラブルシュート履歴テンプレート

```
# トラブルシュート履歴

## 発生日時
2025-11-19 21:00 JST

## 事象
`az deployment group create` が失敗（エラーコード: InvalidTemplate）

## 原因
Bicep テンプレートのパラメータ不足（location 未指定）

## 対応
`--parameters location=JapanEast` を追加して再実行 → 成功
```

- 各インシデントの発生日時・原因・対応に加えて、Log Analytics のクエリや GitHub Actions run ID を併記すると MTTR を短縮できる。

## 6. 類似環境の参考

- `D:\00_temp\wizwork3_For_internal\CICD-AKS-technical-exercise` で使用している Bicep/Workflow 名や変数命名を流用可能。
- ただし本リポジトリは **dummy-secret 公開要件** と **7 本のワークフロー分割** が追加要件のため、その差分を必ず反映する。

## 7. 参考資料

- #microsoft.docs.mcp [GitHub Actions で Azure にデプロイする際の Service Principal 設定手順](https://learn.microsoft.com/en-us/azure/stream-analytics/cicd-github-actions#step-2-set-up-secrets-in-github)
- #microsoft.docs.mcp [Service Principal 認証で Azure CLI を実行する GitHub Actions サンプル](https://learn.microsoft.com/en-us/visualstudio/azure/azure-deployment-using-github-actions?view=visualstudio#deploy-multiple-projects-to-azure-container-apps-using-github-actions)
