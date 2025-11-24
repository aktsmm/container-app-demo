# README_SECURITY – セキュリティ対策と監査

## 1. 認証・認可

- **Service Principal 認証**: すべての GitHub Actions が同一 Service Principal (Client Secret) で Azure にログイン。`create-github-actions-sp.ps1` が Contributor / Resource Policy Contributor / User Access Administrator を付与。
- **Managed Identity**:
  - AKS, VM, Container Apps, Azure Policy に System Assigned ID を付与。
  - VM ID には Storage Blob Data Contributor を割り当て、AzCopy でのバックアップにのみ利用。
  - Container App ID にはデモ用途で Subscription レベルの Contributor を付与しているため、本番では最小権限に調整してください。
- **Basic 認証**: 管理アプリ (ACA) の UI は `ACA_ADMIN_USERNAME` / `ACA_ADMIN_PASSWORD` を Container App Secret で注入し、`require_basic_auth` デコレーターで保護。

## 2. シークレット管理

- GitHub Secrets/Variables は `README_SECRETS_VARIABLES.md` に一覧化。
- `dummy-secret.txt` はダミー情報と明示し、実鍵を置かない。
- Kubernetes Secret (`board-db-conn`) は `2️⃣ Board App Build & Deploy` ワークフローで `kubectl apply` され、DB 認証情報を環境変数としてのみ参照。

## 3. スキャンと監査

| ツール           | 実行場所                           | 検査対象                                                                                                     |
| ---------------- | ---------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| **Gitleaks**     | Build / Security Scan ワークフロー | ソース全体、履歴、アプリごとの差分                                                                           |
| **GitGuardian**  | Security Scan ワークフロー         | GitGuardian API (ggshield) による 400+ パターンのシークレット検出。`vars.GITGUARDIAN_API_KEY` 設定時のみ実行 |
| **Trivy FS**     | Build / Security Scan              | `app/*`, `infra/`, `app/board-app/k8s` (config/secret/vuln)                                                  |
| **Trivy Image**  | Build ワークフロー                 | `board-app`, `board-api`, `admin-app` コンテナイメージ                                                       |
| **CodeQL**       | `security-scan.yml`                | JavaScript (React/Node) + Python (Flask)                                                                     |
| **Azure Policy** | `infra/policy.bicep`               | Resource Group ガードレール (initiative)                                                                     |

> GitGuardian の実行には GitHub Variables へ `GITGUARDIAN_API_KEY`（`scan` / `incident:read` / `incident:write` スコープ付き PAT）を登録する必要があります。未設定の場合は GitGuardian ジョブのみスキップされます。

- SARIF ファイルは GitHub Security (Code scanning) にアップロードされ、上位検出は `security-scan` の Step Summary と `top-findings.json` に集約。GitGuardian の JSON→SARIF 変換も同 Summary に統合され、カテゴリ別アラートへ表示されます。※Security タブへの反映は **公開リポジトリ** または **GitHub Advanced Security ライセンスを持つプライベートリポジトリ** が対象。
- `backup-upload` は成功/失敗ログを Syslog (`logger mysql-backup-upload`) に書き込み、Log Analytics 経由で監査可能。

## 4. ログ & モニタリング

- `main.bicep` で以下の Diagnostic Settings を構成し、`logAnalytics.outputs.id` に送信:
  - AKS control plane (kube-apiserver/controller-manager/scheduler/cluster-autoscaler)
  - Container Apps Environment (Console/System logs)
  - Storage Account (Transaction metrics)
- VM ログは今後 Azure Monitor Agent + DCR で収集予定 (コード内 TODO)。

## 5. RBAC とガードレール

- `VM` に対する NSG は `AllowSSH` (22/TCP) と `AllowMySQL` (3306/TCP) のみ。デモ構成では送信元制限なしのため、本番では Source IP 制限または Azure Bastion/Private Endpoint 化を推奨。
- AKS には RBAC 有効化 (`enableRBAC: true`)。
- Storage は全通信 HTTPS/TLS1.2、匿名アクセス無効。

## 6. デプロイ時の安全策

- `1️⃣ Infrastructure Deploy` は Validate → What-If → Deploy の順で実行し、Plan の差分を明示。
- `2️⃣ Board App Build & Deploy` は `kubectl rollout status` で Deployment の完了を確認し、失敗時は `kubectl get ingress/pods` 出力を Step Summary に表示。
- `2️⃣ Admin App Build & Deploy` は Container Apps の provisioningState が `Succeeded` になるまでリトライ。

## 7. 改善候補

1. GitHub Variables に保存している `AZURE_CLIENT_SECRET`, `DB_APP_PASSWORD` などを Secrets へ移行し、ワークフロー YAML を更新。
2. Container App Managed Identity のロールをリソースグループ単位で最小化 (例: Storage Blob Data Reader + Key Vault Secrets User)。
3. VM NSG の送信元制限、または Azure Firewall / Private Link 経由のアクセスに変更。
4. Security Scan をブロッキングにする場合は Trivy/Gitleaks の `exit-code` を 1 に設定し、PR をブロック。
