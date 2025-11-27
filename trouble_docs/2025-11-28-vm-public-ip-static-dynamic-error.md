# VM Public IP の Static/Dynamic 変更エラー

**日時**: 2025 年 11 月 28 日  
**影響範囲**: VM (vm-mysql-demo) の Public IP  
**ステータス**: ✅ 解決済み

---

## 📋 問題の概要

Infrastructure Deploy ワークフローで VM デプロイ時にエラーが発生。

### エラーメッセージ

```
PublicIPAddressInUseCannotUpdateToDynamic
Public IP address /subscriptions/***/resourceGroups/RG-cicd-demo/providers/Microsoft.Network/publicIPAddresses/vm-mysql-demo-pip
is in use by ipconfig /subscriptions/***/resourceGroups/RG-cicd-demo/providers/Microsoft.Network/networkInterfaces/vm-mysql-demo-nic/ipConfigurations/ipconfig1
and cannot be updated from static to dynamic.
```

---

## 🔍 原因分析

### Azure の制約

**使用中の Public IP は Static ↔ Dynamic を変更できない**

| 変更パターン         | 結果                      |
| -------------------- | ------------------------- |
| Static → Static      | ✅ OK                     |
| Dynamic → Dynamic    | ✅ OK                     |
| **Static → Dynamic** | ❌ エラー（使用中は不可） |
| Dynamic → Static     | ❌ エラー（使用中は不可） |

### 状況

- Bicep (`vm.bicep`) では `publicIPAllocationMethod: 'Dynamic'` を指定
- 既存の Azure リソース (`vm-mysql-demo-pip`) は **Static** で作成されていた
- 再デプロイ時に Static → Dynamic への変更を試み、Azure の制約でエラー

### 既存リソースが Static だった理由（推測）

1. 過去に手動で Azure Portal から変更された可能性
2. 別のデプロイ方法で作成された
3. 24 時間自動停止からの復旧時に Azure が Static で再作成した可能性

---

## ✅ 解決策

### Bicep を Static に統一

**ファイル**: `infra/modules/vm.bicep`

```bicep
// 変更前
properties: {
  publicIPAllocationMethod: 'Dynamic'
}

// 変更後
properties: {
  // Static に設定：再デプロイ時のエラー防止、IP 固定で SSH 接続先が安定
  publicIPAllocationMethod: 'Static'
}
```

---

## 📊 Static vs Dynamic 比較

| 項目                    | Static（静的）        | Dynamic（動的）                 |
| ----------------------- | --------------------- | ------------------------------- |
| **IP 固定**             | ✅ 常に同じ IP        | ❌ VM 停止 → 起動で変わる可能性 |
| **再デプロイ安定性**    | ✅ エラーが起きにくい | ⚠️ 今回のようなエラーリスク     |
| **SSH 接続**            | ✅ 接続先が安定       | ⚠️ IP 変更時に再確認必要        |
| **コスト（Basic SKU）** | 💰 約 ¥400〜500/月    | 💰 約 ¥300〜400/月              |
| **コスト差**            | +約 ¥100/月 程度      | ベースライン                    |
| **IaC との相性**        | ✅ 冪等性が高い       | ⚠️ 状態変更でエラーリスク       |

---

## 📝 教訓

1. **IaC では Static を推奨** — 再デプロイ時の安定性が向上
2. **コスト差は微小** — Basic SKU の Static/Dynamic 差は月 ¥100 程度
3. **既存リソースとの整合性** — 手動変更が入ると IaC との不整合が発生する
4. **Azure の制約を把握** — 使用中リソースの変更制限を理解しておく

---

## 🔗 関連情報

- **コミット**: `72ac60c` - fix(infra): VM Public IP を Static に変更
- **関連ドキュメント**: [Azure Public IP の割り当て方法](https://learn.microsoft.com/ja-jp/azure/virtual-network/ip-services/public-ip-addresses)
- **関連トラブル**: `2025-11-21-ingress-ip-dynamic-change.md` (Ingress の Public IP 問題)
