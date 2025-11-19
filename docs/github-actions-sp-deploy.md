# GitHub Actions による Azure デプロイ（Service Principal 認証）

## 目的

- `.github/copilot-instructions.md`・`docs/architecture.md`・`ignore/環境情報`のルールを唯一の真実源として参照し、AKS + ACA + VM(MySQL) + Storage + Log Analytics を **低コスト SKU** で IaC 化する。
- GitHub Actions では **Service Principal + Client Secret** 認証を使用し、OIDC は明示的に無効化する。
- `AZURE_SUBSCRIPTION_ID` のみを GitHub Secrets に、残りの値を GitHub Actions Variables に保持し、再現性のある Bicep デプロイを実施する。
- デプロイ後の監視、失敗時のトラブルシュート履歴、類似環境との比較を Markdown で管理する。

## 1. 必須変数一覧

### GitHub Secrets

| 変数名                  | 用途                                                                                                                                      |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `AZURE_SUBSCRIPTION_ID` | 対象サブスクリプション ID（例: `7134d7ae-2fe3-4eec-8f0b-5ffad8355907`）。Azure CLI の `--subscription` へ引き渡す唯一の必須シークレット。 |
| `GH_PAT_ACTIONS_DELETE` | 任意。`cleanup-failed-workflows` が `gh run delete` を大量実行する際の PAT。未設定時は `GITHUB_TOKEN` を利用し、削除対象が制限される。    |

> Policy: Secrets は最小限に抑え、PAT が不要であれば `GH_PAT_ACTIONS_DELETE` を登録しない。PAT を使う場合も scope を `repo` のみに限定する。

### GitHub Actions Variables

| 変数名                     | 用途                                                                             |
| -------------------------- | -------------------------------------------------------------------------------- |
| `AZURE_CLIENT_ID`          | Service Principal の Client ID。`azure/login@v2` の `client-id` に渡す。         |
| `AZURE_TENANT_ID`          | 同上テナント ID。                                                                |
| `AZURE_CLIENT_SECRET`      | Service Principal のクライアントシークレット。                                   |
| `RESOURCE_GROUP_NAME`      | すべての IaC デプロイ先 RG 名。                                                  |
| `LOCATION`                 | 既定リージョン（例: `japaneast`）。                                              |
| `ACR_NAME_PREFIX`          | infra-deploy で ACR 名を生成/検索する際のプレフィックス。                        |
| `STORAGE_ACCOUNT_PREFIX`   | バックアップ用 Storage Account のプレフィックス。                                |
| `VM_NAME`                  | MySQL VM リソース名。`backup-upload` 等が `az vm run-command` を行う際に使用。   |
| `VM_ADMIN_USERNAME`        | VM 管理者アカウント名（Bicep へパラメータ渡し）。                                |
| `VM_ADMIN_PASSWORD`        | VM 管理者パスワード。`parameters/*.json` の `__PIPELINE_OVERRIDDEN__` を上書き。 |
| `DB_APP_USERNAME`          | アプリケーション用 MySQL ユーザー名。                                            |
| `DB_APP_PASSWORD`          | 上記ユーザーのパスワード。`mysql-init.sh` へ渡し DB 接続を確立。                 |
| `MYSQL_ROOT_PASSWORD`      | MySQL root アカウント用パスワード。                                              |
| `AKS_CLUSTER_NAME`         | 掲示板アプリを載せる AKS クラスタ名。                                            |
| `ACA_ENVIRONMENT_NAME`     | 管理アプリ用 Container Apps Environment 名。                                     |
| `ADMIN_CONTAINER_APP_NAME` | ACA のコンテナアプリ名。                                                         |
| `DB_ENDPOINT`              | 管理アプリへ注入する MySQL エンドポイント表示用文字列。                          |
| `BACKUP_CONTAINER_NAME`    | Storage Account 側で MySQL バックアップを保管するコンテナ名。                    |

> Note: パスワード系を Variables に置く理由は「Secrets は購読 ID のみ」というルールを守りつつ再現性を確保するためであり、必要に応じて Environment ごとに overrides 可。

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

   - `infra/parameters/*.json` へ LOCATION・VNet・NSG・ノード SKU などを全てパラメータ化して格納。`mysqlRootPassword` / `mysqlAppUsername` / `mysqlAppPassword` は `__PIPELINE_OVERRIDDEN__` とし、パイプラインから上書きする。
   - `scripts/mysql-init.sh` が VM 初回起動時に MySQL をインストールし、`MYSQL_ROOT_PASSWORD` と `DB_APP_*` Variable を用いて root / アプリユーザーを作成する。あわせて `mysqld.cnf` の `bind-address` / `mysqlx-bind-address` を `0.0.0.0` へ更新し、サービスを再起動して AKS/ACA からのリモート接続を許可する。シークレットは購読 ID のみに限定する運用。
   - `az deployment sub what-if --no-pretty-print` で差分を確認し、意図しないリソース変更を検知する。

3. **dummy-secret 公開**
   - `app/board-app/public/dummy-secret.txt` を配置しトップページから「ダミーシークレットはこちら」リンクを追加。
   - ファイル内コメントで「ダミーであり本番鍵ではない」旨を明示し、UI 上で確認できるようにする。

## 3. GitHub Actions ワークフロー整理

| Workflow                       | 主な処理                                   | 実装ポイント                                                                                                                                                                                                       |
| ------------------------------ | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `infra-deploy.yml`             | Bicep Validate → What-If → Deploy          | `azure/login@v2` を Client Secret 認証で利用。`az deployment sub create` に `parameters/*.json` を指定。                                                                                                           |
| `app-build-board.yml`          | 掲示板アプリ build + Trivy scan + ACR push | `workflow_run` で `infra-deploy` 成功後にも自動起動し、`github.event.workflow_run.head_sha` を checkout して同一コミットをビルド。`docker/login-action` と SP 資格情報で ACR にログイン。scan 結果を Artifact 化。 |
| `app-deploy-board.yml`         | AKS へ Deployment/Service/Ingress 適用     | `workflow_run` で `app-build-board` 成功後にのみ自動実行。`github.event.workflow_run.head_sha` から 12 桁タグを算出し、`kubectl apply -k app/board-app/k8s` を行う。                                               |
| `app-build-admin.yml`          | 管理アプリ build + Trivy + ACR push        | `workflow_run` で `infra-deploy` 成功後にも自動起動。`github.event.workflow_run.head_sha` を checkout して ACA 用コンテナをビルドし、後続 deploy workflow へ渡す。                                                 |
| `app-deploy-admin.yml`         | ACA リビジョン更新 + Basic 認証            | `workflow_run` で `app-build-admin` 成功後にのみ自動実行。`workflow_dispatch` 入力と SHA 由来タグを自動で切り替えて `az containerapp up` を実行。                                                                  |
| `backup-upload.yml`            | VM → Storage へ MySQL バックアップ送信     | GitHub Actions から VM へ SSH し `azcopy`/`rsync` を実行。`MYSQL_ROOT_PASSWORD` は Variable を参照し `mysqldump` を認証、Log Analytics へ結果を送る。                                                              |
| `cleanup-failed-workflows.yml` | 失敗 Workflow とキャッシュ清掃             | `gh run list --status failure` → `gh run delete` で停滞を解消。                                                                                                                                                    |

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
