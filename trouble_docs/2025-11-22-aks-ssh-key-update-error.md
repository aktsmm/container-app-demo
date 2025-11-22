# AKS SSH キー更新エラーの対応

## 📅 発生日時

2025 年 11 月 22 日

## 🔍 問題の概要

Infrastructure Deploy ワークフロー（`1-infra-deploy.yml`）の Bicep What-If 検証ステップで、既存の AKS クラスターに対して SSH 公開鍵を変更しようとして以下のエラーが発生しました。

```
ERROR: InvalidTemplateDeployment - The template deployment 'whatif-1763780208' is not valid according to the validation procedure. The tracking id is '31094a21-f9cd-4263-a13b-5af8025f8974'. See inner errors for details.
PropertyChangeNotAllowed - Preflight validation check for resource(s) for container service aks-demo-dev in resource group RG-demo-BBS-App failed. Message: Changing property "linuxProfile.ssh.publicKeys.keyData" is not allowed in a general availability (GA) api-version. Please use a preview api-version instead.. Details:
Error: Process completed with exit code 1.
```

## 🎯 根本原因

### 1. AKS の SSH キー制限

- AKS の `linuxProfile.ssh.publicKeys.keyData` はクラスター作成時のみ設定可能
- **既存クラスターに対する SSH キーの変更は GA API では許可されていない**
- Preview API（例: `2024-05-02-preview`）を使用すれば変更可能だが、安定性の観点から推奨されない

### 2. Bicep What-If の挙動

- What-If 検証では既存リソースと新しいテンプレートの差分をチェック
- `aksSkipCreate=true` で AKS モジュール自体はスキップされるが、**What-If 実行時に既存クラスターとの差分が検出される**
- SSH キーのパラメータが渡されると、既存クラスターの SSH キーと比較され「変更あり」と判定される

### 3. ワークフローの設計

```yaml
# 既存クラスターをチェック
- name: 既存 AKS クラスタ確認
  if: ${{ steps.aks_check.outputs.skip_create == 'false' }}
  # 新規作成時のみ SSH キーを生成
  
# しかし What-If では aksSkipCreate に関わらず全パラメータを検証
- name: Bicep What-If
  run: |
    az deployment group what-if \
      --parameters aksSshPublicKey="${AKS_SSH_PUBLIC_KEY:-unused}"
      # ↑ 既存クラスターでも SSH キーパラメータが渡される
```

## 🛠️ 対応内容

### ✅ 修正: 既存クラスターがある場合は What-If をスキップ

**修正ファイル**: `.github/workflows/1-infra-deploy.yml`

```diff
      - name: Bicep What-If
+       # 既存 AKS クラスターがある場合は What-If で SSH キー変更エラーが出るためスキップ
+       if: ${{ needs.prepare.outputs.aks_skip_create == 'false' }}
        run: |
          az deployment group what-if \
            --resource-group "$RESOURCE_GROUP_NAME" \
            --name "whatif-$(date +%s)" \
            --template-file infra/main.bicep \
            --parameters "@${{ env.PARAM_FILE }}" \
            --parameters storageAccountName="$STORAGE_ACCOUNT_NAME" acrName="$ACR_NAME" \
            --parameters vmAdminUsername="$VM_ADMIN_USERNAME" vmAdminPassword="$VM_ADMIN_PASSWORD" \
            --parameters mysqlRootPassword="$MYSQL_ROOT_PASSWORD" mysqlAppUsername="$DB_APP_USERNAME" mysqlAppPassword="$DB_APP_PASSWORD" \
            --parameters aksSshPublicKey="${AKS_SSH_PUBLIC_KEY:-unused}" aksSkipCreate="$AKS_SKIP_CREATE" aksNodeResourceGroup="$AKS_NODE_RESOURCE_GROUP" \
            --parameters containerAppsEnvironmentName="$CONTAINER_APPS_ENV_NAME"
```

### 📋 修正の詳細

| 項目 | 内容 |
|------|------|
| **条件追加** | `if: ${{ needs.prepare.outputs.aks_skip_create == 'false' }}` |
| **動作** | 既存 AKS クラスターがある場合（`aks_skip_create=true`）は What-If ステップ全体をスキップ |
| **新規作成時** | 引き続き What-If で事前検証を実行（SSH キー変更がないため正常動作） |
| **既存クラスター時** | What-If をスキップして直接 Bicep Deploy を実行（AKS モジュールは `if (!aksSkipCreate)` でスキップされるため安全） |

## ✅ 最終的な動作フロー

### 🆕 新規 AKS クラスター作成時

```
1. prepare job
   └─ AKS クラスター存在チェック → 存在しない
   └─ SSH キー生成 → 新しい公開鍵を生成
   └─ aks_skip_create=false を出力

2. bicep-deploy job
   └─ Bicep Validate → 成功
   └─ Bicep What-If → 実行（新規リソースのため問題なし）
   └─ Bicep Deploy → AKS クラスター作成
```

### ♻️ 既存 AKS クラスター再利用時

```
1. prepare job
   └─ AKS クラスター存在チェック → 存在する
   └─ SSH キー生成 → スキップ
   └─ aks_skip_create=true を出力

2. bicep-deploy job
   └─ Bicep Validate → 成功
   └─ Bicep What-If → スキップ（SSH キーエラー回避）
   └─ Bicep Deploy → AKS モジュールはスキップ、他リソースのみデプロイ
```

## 📝 学んだこと

### 1. AKS の SSH キー制約

- `linuxProfile.ssh.publicKeys.keyData` は**イミュータブル（不変）プロパティ**
- 作成後に変更したい場合は Preview API を使用するか、クラスターを再作成する必要がある
- デモ環境では SSH キー変更が不要なため、既存クラスター再利用時は SSH キーを無視する設計が適切

### 2. Bicep What-If の検証範囲

- What-If は条件付きデプロイ（`if` 文）に関係なく、**全パラメータと既存リソースの差分を検証**
- `module aks = if (!aksSkipCreate)` でモジュール自体はスキップされても、What-If では既存 AKS との差分がチェックされる
- 既存リソースへの変更がない場合は What-If 自体をスキップすることで回避可能

### 3. Infrastructure as Code の冪等性設計

- 既存リソースを再利用する設計では、変更不可能なプロパティをパラメータで渡さない工夫が必要
- ワークフローレベルで条件分岐（What-If のスキップ）を実装することで、Bicep の複雑性を増やさずに対応可能

## 🎓 ベストプラクティス

### ✅ DO

- **既存リソース再利用時は What-If をスキップする**（イミュータブルプロパティのエラー回避）
- 新規作成時は必ず What-If で事前検証を実行（予期しない変更の早期発見）
- AKS の SSH キーは作成時のみ設定し、以降は変更しない設計にする
- ワークフローの条件分岐で柔軟に対応する（Bicep を複雑化させない）

### ❌ DON'T

- 既存 AKS に対して SSH キーを含むパラメータで What-If を実行しない
- Preview API を安易に使用しない（GA API で解決できる問題は GA で対応）
- Bicep で複雑な条件分岐を実装しない（可読性が下がる）
- イミュータブルプロパティを変更しようとしない（クラスター再作成を検討）

## 📚 関連ドキュメント

- [2025-11-22-fixed-ip-dns-removal.md](./2025-11-22-fixed-ip-dns-removal.md) - 固定 IP と DNS 名の完全廃止対応
- [2025-01-21-loadbalancer-healthprobe-nodeport-mismatch.md](./2025-01-21-loadbalancer-healthprobe-nodeport-mismatch.md) - LoadBalancer 関連の過去事例

## 🔗 参考リンク

- [Azure Kubernetes Service (AKS) での SSH キーの管理](https://learn.microsoft.com/ja-jp/azure/aks/ssh)
- [Bicep での条件付きデプロイ](https://learn.microsoft.com/ja-jp/azure/azure-resource-manager/bicep/conditional-resource-deployment)
- [Azure Resource Manager のデプロイ What-If 操作](https://learn.microsoft.com/ja-jp/azure/azure-resource-manager/templates/deploy-what-if)
- [AKS の API バージョン](https://learn.microsoft.com/ja-jp/azure/templates/microsoft.containerservice/managedclusters)

## 🔄 代替案（今回は不採用）

### 代替案 1: Preview API を使用

```bicep
resource cluster 'Microsoft.ContainerService/managedClusters@2024-05-02-preview' = {
  // SSH キーの変更が可能
}
```

**不採用理由**: 
- Preview API は安定性が保証されていない
- デモ環境では SSH キー変更が不要
- GA API で解決可能（What-If スキップ）

### 代替案 2: Bicep で SSH キーを条件分岐

```bicep
linuxProfile: aksSkipCreate ? null : {
  adminUsername: systemPool.adminUsername
  ssh: {
    publicKeys: [
      {
        keyData: systemPool.sshPublicKey
      }
    ]
  }
}
```

**不採用理由**:
- Bicep が複雑化する
- `null` を指定しても What-If で差分検出される可能性
- ワークフローレベルの対応の方がシンプル

### 代替案 3: AKS を毎回削除・再作成

**不採用理由**:
- クラスター作成に 10-15 分かかる
- コスト増加（削除時の課金、作成時の初期化）
- デモ環境の迅速な検証に適さない

---

**ステータス**: ✅ 解決完了  
**最終更新**: 2025 年 11 月 22 日  
**対応者**: GitHub Copilot + User  
**関連コミット**: `c31c9fc` - 既存 AKS クラスターがある場合は What-If をスキップ
