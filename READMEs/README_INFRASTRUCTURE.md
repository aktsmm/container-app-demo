# README_INFRASTRUCTURE – IaC / Azure リソース / Kubernetes マニフェスト

## 1. Bicep 構成概要

| モジュール         | ファイル                               | 主な役割                                                                                                                               |
| ------------------ | -------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| ルートテンプレート | `infra/main.bicep`                     | 低コスト VNet + AKS + Container Apps Env + VM (MySQL) + ACR + Storage + Log Analytics + 診断設定をまとめて展開                         |
| `logAnalytics`     | `infra/modules/logAnalytics.bicep`     | Log Analytics Workspace (PerGB2018, retention 30 日、`enableLogAccessUsingOnlyResourcePermissions`)                                    |
| `vnet`             | `infra/modules/vnet.bicep`             | `10.0.0.0/16` の VNet と 3 サブネット (AKS/VM/ACA)。Container Apps サブネットには `Microsoft.App/environments` デリゲーションを付与    |
| `acr`              | `infra/modules/acr.bicep`              | Basic SKU、管理者ユーザー無効、匿名 Pull 不可                                                                                          |
| `storageAccount`   | `infra/modules/storageAccount.bicep`   | Backup 用 StorageV2、Standard_LRS + Cool、Blob 公開禁止、TLS1.2 強制。Blob Service とバックアップコンテナ（`mysql-backups`）を自動作成 |
| `containerAppEnv`  | `infra/modules/containerAppEnv.bicep`  | Consumption workload profile + Log Analytics ログ出力 + VNet 統合                                                                      |
| `aks`              | `infra/modules/aks.bicep`              | SystemAssigned ID、`Standard_B2s` 1 ノード、Overlay ネットワーク、OMS Agent Add-on (Log Analytics 連携)                                |
| `vm`               | `infra/modules/vm.bicep`               | Standard_B1ms Linux VM、SystemAssigned ID、`mysql-init.sh` を Custom Script 拡張で実行、NSG で 22/3306 を許可                          |
| `policyAssignment` | `infra/modules/policyAssignment.bicep` | Resource Group スコープでポリシー イニシアチブを割り当て (Managed Identity オプションあり)                                             |

### 1.1 パラメーター管理

- すべての入力値は `infra/parameters/main-dev.parameters.json` に格納し、ワークフローから `--parameters @file` + 一部上書きで利用。
- ハードコード禁止項目 (VNet CIDR、AKS DNS、VM 管理者、MySQL 資格情報等) もすべて JSON に退避。

## 2. ネットワーク & ログ設計

```
VNet 10.0.0.0/16
├─ snet-aks        (10.0.0.0/22)  : AKS ノードプール (Standard_B2s 1 台)
├─ snet-vm         (10.0.4.0/24)  : MySQL VM (Standard_B1ms)
└─ snet-aca        (10.0.5.0/24)  : Container Apps Environment (Consumption)
```

- **Log Analytics** (`law-demo-dev`): すべてのログ/メトリックを中央集約。
  - AKS Control Plane: kube-apiserver / controller-manager / scheduler / cluster-autoscaler
  - Container Apps: Console + System logs
  - Storage Account: Transaction メトリック (必要に応じてログカテゴリを追加可能)
  - VM: System Assigned ID + Custom Script。Azure Monitor Agent は DCR 整備後に追加予定 (コメント参照)。
- **Role Assignment**: VM の Managed Identity に Storage Blob Data Contributor (バックアップ用) を割り当て。

## 3. Kubernetes (app/board-app/k8s) の構造

| ファイル                    | 役割                                                                                                                                        |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `namespace.yaml`            | `board-app` Namespace を作成。ワークフローで `kubectl apply` し、再実行に備えて宣言的に維持                                                 |
| `deployment.yaml`           | React/Vite UI の Deployment。`acr-secret` 参照、`dummy-secret.txt` を静的配信するため `public/` 以下を含んだ Docker イメージを利用          |
| `service.yaml`              | UI 用 ClusterIP Service。Ingress から 80/TCP で参照                                                                                         |
| `board-api-deployment.yaml` | Node/Express API。DB 接続情報は Secret `board-db-conn` から `env` 経由で注入。`readinessProbe` `/health`                                    |
| `board-api-service.yaml`    | API 用 ClusterIP Service (3000/TCP)。Ingress の `/api` パスで利用                                                                           |
| `ingress.yaml`              | nginx Ingress。Host 指定なし（LoadBalancer IP 直アクセス専用）。`/dummy-secret.txt` も UI から直接参照できます                              |
| `kustomization.yaml`        | Namespace/Ingress/Deployments/Services を束ね、`configMapGenerator` で `vars.env` を注入。イメージタグは GitHub Actions の `sed` で差し替え |
| `vars.env`                  | `scripts/sync-board-vars.ps1` が `infra/parameters/main-dev.parameters.json` から Namespace のみを同期                                      |

## 4. dummy-secret.txt の扱い

- パス: `app/board-app/public/dummy-secret.txt`
- 内容: デモ用の ID/PASSWORD (`demoadmin-42`, `Pa55w0rd!`)。本物の秘密ではないことをファイル先頭コメントと UI (`App.jsx`) のリンクテキストで明示。
- Frontend (`App.jsx`) では `<a href="/dummy-secret.txt">` をトップページに常設し、HTTP GET で取得できるようにしています。

## 5. VM/MySQL 初期化

- `scripts/mysql-init.sh` を VM 拡張 (`CustomScript`) で実行し、以下を自動化。
  - apt リポジトリ再試行、mysql-server インストール (fallback 付き)、`bind-address` を 0.0.0.0 に変更
  - root とアプリユーザーの作成 (`mysqlRootPassword`, `mysqlAppUsername`, `mysqlAppPassword`)
  - 外部接続許可 & サービス再起動
- GitHub Actions の `backup-upload` では VM の Managed Identity + AzCopy (MSI) で `mysqldump` を Storage にアップロード。

## 6. Azure Policy

- `infra/policy.bicep` + `infra/parameters/policy-dev.parameters.json` で Resource Group スコープのポリシー イニシアチブを割り当てます。

### 6.1 適用中のポリシーイニシアチブ

| 項目                   | 値                                                                  |
| ---------------------- | ------------------------------------------------------------------- |
| **イニシアチブ名**     | **Microsoft Cloud Security Benchmark v2 (Preview)**                 |
| **ID**                 | `e3ec7e09-768c-4b64-882c-fcada3772047`                              |
| **割り当て名**         | `initiative-container-app-demo`                                     |
| **表示名**             | Container App Demo ガードレール                                     |
| **含まれるポリシー数** | 約 200 以上のセキュリティポリシー                                   |
| **主なカバー範囲**     | コンテナセキュリティ、ネットワーク、ID 管理、データ保護、監視・ログ |
| **Managed Identity**   | 有効（修復アクションに必要）                                        |
| **参考リンク**         | [Microsoft Cloud Security Benchmark](https://aka.ms/azsecbm)        |

### 6.2 主なポリシーカテゴリ

- **コンテナセキュリティ**: AKS 特権コンテナ制限、イメージスキャン、ネットワークポリシー
- **ネットワークセキュリティ**: NSG 構成、パブリックアクセス制限、TLS/SSL 強制
- **ID とアクセス管理**: Managed Identity 推奨、RBAC 構成、特権アクセス監査
- **データ保護**: ストレージ・データベース暗号化、診断ログ有効化
- **監視とログ**: Log Analytics 接続、アクティビティログ保持、セキュリティアラート

**Note**: このイニシアチブは Microsoft Defender for Cloud のデフォルトポリシーであり、多くのポリシーは監査（Audit）モードで動作します。

## 7. テキストアーキテクチャ図

```
[Users]
   │ HTTP
   ▼
Azure Load Balancer (ingress-nginx)
   │
   ├─> Service: board-app (React UI) ──┐
   │                                  │ REST (/api)
   └─> Service: board-api (Express) ──┴─> MySQL VM (Standard_B1ms)
                                          │ mysqldump
                                          ▼
                                Storage Account (Cool tier backups)

[Operators]
   │ HTTPS + Basic Auth
   ▼
Azure Container Apps (admin-app)
   │ Azure Identity / pymysql / Blob SDK
   ├─> MySQL VM (posts, delete)
   └─> Storage Account (backup listing)

[Observability]
AKS Control Plane / Container Apps / Storage / VM ──> Log Analytics Workspace
```

## 8. 低コスト設計の根拠

- AKS: `Standard_B2s`, ノード数 1, Standard Load Balancer
- VM: `Standard_B1ms`, Standard_LRS OS Disk
- ACA: Consumption profile のみ (Dedicated 0 台)
- Storage: `Standard_LRS` + `Cool` tier
- Log Analytics: `PerGB2018`, 30 日保持

## 9. 今後の拡張余地

- `vm.bicep` に Azure Monitor Agent を再有効化する際は Data Collection Rule を追加
- Storage Diagnostic logs (現在は Transaction メトリックのみ) のカテゴリ拡張
- `ingress.yaml` の host ベースルーティングを DNS 設定に合わせて更新
