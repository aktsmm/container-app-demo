# README_ARCHITECTURE – 全体アーキテクチャとデータフロー

## 1. テキストベースアーキテクチャ図

```
                           ┌────────────────────────────────────┐
                           │  GitHub Actions (6 workflows)     │
                           │  - IaC (Bicep) Deploy             │
                           │  - Board/Admin App Build & Deploy │
                           │  - Backup / Security / Cleanup    │
                           └────────────────────────────────────┘
                                           │ Service Principal
                                           ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ Azure Resource Group (japaneast)                                            │
│                                                                             │
│  ┌───────────────┐      ┌────────────────┐                                   │
│  │ Azure ACR     │<────>│ GitHub Actions │ (docker login/push)               │
│  └───────────────┘      └────────────────┘                                   │
│         │pull                                                         logs  │
│         ▼                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │ VNet 10.0.0.0/16                                                     │   │
│  │ ┌─────────────┐ ┌─────────────┐ ┌─────────────────┐                  │   │
│  │ │snet-aks     │ │snet-vm      │ │snet-aca         │                  │   │
│  │ │AKS          │ │MySQL VM     │ │Container Apps   │                  │   │
│  │ └─────────────┘ └─────────────┘ └─────────────────┘                  │   │
│  │  │                │                   │                              │   │
│  │  │Ingress LB      │mysqldump          │Basic Auth + REST             │   │
│  │  ▼                ▼                   ▼                              │   │
│  │ Users ──HTTP──> nginx Ingress ──> board-app Deployment (React)        │   │
│  │                         │                     │ REST /api            │   │
│  │                         └──────────────> board-api Deployment        │   │
│  │                                                  │ mysql2 (Node.js)  │   │
│  │                                                  ▼                   │   │
│  │                                        MySQL VM (Standard_B1ms)       │   │
│  │                                                  │ AzCopy (MSI)      │   │
│  │                                                  ▼                   │   │
│  │                                        Storage Account (Cool tier)    │   │
│  │                                                                      │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│             ▲                                     │                         │
│             │ HTTPS + Basic Auth                  │ Blob SDK + pymysql      │
│     Admin Users ───────────────> Azure Container Apps (admin-app)           │
│                                                                             │
│  Diagnostics: Storage / AKS / Container Apps ─────> Log Analytics Workspace │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 2. データフロー

### 掲示板アプリ (AKS)

![掲示板アプリ](imgs/bbs-demo-AKS.png)

1. **掲示板投稿**
   1. ユーザーのブラウザ → `board-app` (React) → `/api/posts` へ REST 呼び出し。
   2. `board-app` の Ingress ルールは `/` と `/api` を分離し、NGINX Controller 経由で ClusterIP Service へ転送。
   3. `board-api` (Express) が MySQL VM (`boardapp` DB) に挿入。
2. **dummy-secret 配信**
   - `public/dummy-secret.txt` を NGINX 経由で直接配信。`App.jsx` に「ダミーシークレットはこちら」リンクを常設。

### 管理アプリ (Azure Container Apps)

![管理アプリ](imgs/kanri-aap-demo-ACA.png)

3. **管理アプリ操作**
   1. 管理者が ACA の FQDN にアクセスし、Basic 認証 (`admin-username`/`admin-password` secret) を入力。
   2. Flask アプリが `DefaultAzureCredential()` を使って Storage へ接続し、`BACKUP_CONTAINER` の Blob を列挙。
   3. 同じアプリが PyMySQL で MySQL VM に接続し、投稿削除 API を提供。
4. **バックアップ**
   - `backup-upload` ワークフローが週 1 回（毎週月曜日 00:00 UTC）`mysqldump` を生成し、VM の Managed Identity + Azure CLI + AzCopy MSI 認証で Storage Blob へアップロード。
5. **ログ / テレメトリ**
   - AKS Control Plane、Container Apps、Storage は `main.bicep` の Diagnostic Settings で Log Analytics へ送信。
   - GitHub Actions の Step Summary にも各デプロイ結果が書き込まれ、人的レビューを補助。

## 3. ネットワーク経路とセキュリティ境界

- **パブリックエントリポイント**
  - AKS: Standard Load Balancer の Public IP → nginx ingress controller → 内部サービス
  - ACA: 外部 Ingress + TLS (managed)。Basic 認証で最低限保護。
- **プライベート通信**
  - board-api ⇄ MySQL VM は VNet 内 (snet-aks ↔ snet-vm)。Security Group は 3306/TCP を全開放しているため、実運用ではソース IP 制限を推奨。
  - ACA ⇄ Storage / VM も VNet 経由。Container Apps Environment は `snet-aca` に接続。
- **バックアップ経路**
  - VM から Storage へは HTTPS + MSI 認証 (AzCopy)。外向き通信のみ。
- **ログ経路**
  - すべての診断ログ/メトリックは HTTPS で Log Analytics Workspace に送信。

## 4. 依存関係

| レイヤー            | 依存対象                                                                                            |
| ------------------- | --------------------------------------------------------------------------------------------------- |
| board-app (React)   | board-api REST エンドポイント、dummy-secret.txt (静的ファイル)                                      |
| board-api (Express) | Kubernetes Secret `board-db-conn` (DB_ENDPOINT, DB_APP_USERNAME, DB_APP_PASSWORD)                   |
| admin-app (Flask)   | Container App Secret (Basic 認証)、Log Analytics (Observability メッセージ)、Storage Blob、MySQL VM |
| GitHub Actions      | ACR, AKS, ACA, Storage, VM, Policy, Log Analytics                                                   |

## 5. 運用フェーズの可視化

- 本 README のテキスト図と `README_WORKFLOWS.md` で Execution Flow を追えるようにしています。
- トラブル発生時は `trouble_docs/*.md` に時系列で記録します (例: `2025-11-20-admin-app-column-name-mismatch.md`)。

## 6. 将来拡張の想定

1. Private Endpoint 化 (AKS/ACA/Storage/VM を完全閉域化し、Azure Application Gateway で公開)
2. Azure Key Vault を追加し、GitHub Secrets ではなく Managed Identity + Key Vault リファレンスを利用
3. Azure Monitor Workbook / Grafana で Log Analytics データを可視化
