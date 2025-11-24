# README_SECRETS_VARIABLES – GitHub Secrets / Variables / dummy-secret 管理

## 1. ルール

- **Secrets** は GitHub Actions からもマスクされるため、クレデンシャルや Subscription ID を格納します。
- **Variables** は値がログに出力される可能性があるため、低機密情報またはクロスワークフローで共通のパラメーターに使用します。
- 値の一括投入: `scripts/setup-github-secrets_variables.ps1`（`-Repo` 省略時は `$DefaultRepo` → git remote → 対話入力の順で解決）
- `AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID / AZURE_SUBSCRIPTION_ID` は `scripts/create-github-actions-sp.ps1` で発行した Service Principal 情報を転記する。ダミー値はデモ確認用であり、本番では必ず再生成する。

## 2. GitHub Secrets 一覧

| キー                    | 用途 / 参照箇所                                                                                                                                                  |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AZURE_SUBSCRIPTION_ID` | すべての `azure/login@v2` で使用。`1-infra-deploy.yml`, `2-board-app-build-deploy.yml`, `2-admin-app-build-deploy.yml`, `backup-upload.yml`, `security-scan.yml` |

## 3. GitHub Variables 一覧

| キー                                        | 用途 / 参照ワークフロー                                                                             |
| ------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `AZURE_CLIENT_ID`                           | 全ワークフローの `azure/login@v2`                                                                   |
| `AZURE_CLIENT_SECRET`                       | 同上 (現在は Variable。秘匿度を高めたい場合は Secret へ移行してください)                            |
| `AZURE_TENANT_ID`                           | 同上                                                                                                |
| `RESOURCE_GROUP_NAME`                       | 全ワークフロー (ACR/Storage 解決、`az group create`)                                                |
| `LOCATION`                                  | `1-infra-deploy.yml` (RG 作成、Policy パラメーター)                                                 |
| `ACR_NAME_PREFIX`                           | ビルド/デプロイ/バックアップ全般 (ACR 名解決)                                                       |
| `STORAGE_ACCOUNT_PREFIX`                    | `1-infra`, `2-admin-app-build-deploy`, `backup-upload`                                              |
| `AKS_CLUSTER_NAME`                          | `2-board-app-build-deploy` (AKS 認証)                                                               |
| `ACA_ENVIRONMENT_NAME`                      | `2-admin-app-build-deploy` (初期値。実際は RG から再解決)                                           |
| `ADMIN_CONTAINER_APP_NAME`                  | `2-admin-app-build-deploy`                                                                          |
| `VM_NAME`                                   | `backup-upload` (VM コマンド実行)                                                                   |
| `VM_ADMIN_USERNAME` / `VM_ADMIN_PASSWORD`   | `1-infra-deploy.yml` (Bicep パラメーター)                                                           |
| `MYSQL_ROOT_PASSWORD`                       | `1-infra-deploy.yml`, `backup-upload.yml`                                                           |
| `DB_APP_USERNAME` / `DB_APP_PASSWORD`       | `1-infra-deploy.yml`, `2-board-app-build-deploy`, `2-admin-app-build-deploy`                        |
| `BACKUP_CONTAINER_NAME`                     | `2-admin-app-build-deploy`, `backup-upload.yml`                                                     |
| `ACA_ADMIN_USERNAME` / `ACA_ADMIN_PASSWORD` | `2-admin-app-build-deploy` の Basic 認証シークレット                                                |
| `GITGUARDIAN_API_KEY`                       | `security-scan.yml` の GitGuardian ジョブ。`scan` / `incident:read` / `incident:write` スコープ必須 |

`DB_ENDPOINT` は Bicep デプロイの出力 (`infra-outputs` アーティファクト) から `2️⃣ Board App Build & Deploy` / `2️⃣ Admin App Build & Deploy` が自動で解決し、`DB_ENDPOINT_RESOLVED` として利用します。GitHub Variables で管理する必要はありません。

> **補足**: `jobs.json` や `sec_scan_jobs.json` は Secrets 管理には使用していません。

## 4. dummy-secret.txt の注意点

- パス: `app/board-app/public/dummy-secret.txt`
- 目的: フロントエンド上でダミーの資格情報を公開し、実際の秘密を含めない方針を徹底すること。
- `App.jsx` の `<a href="/dummy-secret.txt">` から誰でもアクセスできるため、**本物のキーを絶対に配置しない**。
- README やコメントには「ダミーであり本物ではない」ことを必ず記述済み。

## 5. 推奨運用

1. 新しい環境値を追加する場合は、まず `ignore/環境情報.md` に記述し、Pull Request でコンテキストを共有する。
2. `scripts/setup-github-secrets_variables.ps1` で GitHub CLI を通して変数/シークレットを一括設定。以下の仕様を満たすため、値の更新はスクリプト冒頭の設定ブロックのみを修正すればよい。
   - `$DefaultRepo` に既定の `owner/repo` を宣言。`-Repo` 未指定かつ git remote が解決できない場合は `Read-Host` で入力を促す。
   - `$GitHubVariables` / `$GitHubSecrets` のハッシュテーブルを編集すると、同じ順で `gh variable set` / `gh secret set` を実行。
   - `-DryRun` スイッチで gh CLI を呼ばずに適用内容のみ確認可能。
3. クリティカルな値 (DB パスワード、Client Secret 等) はできるだけ Secret 側へ移し、YAML で `secrets.*` を参照するように更新。
4. 変更後は `gh variable list` / `gh secret list` で実際に登録されているかを確認。

## 6. 参照方法の例

```powershell
# 例: GitHub CLI で AZURE_CLIENT_SECRET を Secret に移行
$repo = "aktsmm/container-app-demo"
$value = Read-Host -AsSecureString "Enter AZURE_CLIENT_SECRET"
$plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($value)
)
echo $plain | gh secret set AZURE_CLIENT_SECRET --repo $repo
```

## 7. Secrets ローテーション

- Service Principal シークレット: `create-github-actions-sp.ps1` の `-SecretDurationYears` で有効期限を制御。期限前に再発行し、GitHub Secrets/Variables を更新。
- VM / DB アカウント: `infra/main.bicep` のパラメーターを書き換えて再デプロイすると Custom Script が再適用されるため、既存 DB への影響を考慮してローテーションしてください。
