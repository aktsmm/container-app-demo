# 🎯 修正サマリ - Issue #64

## 📌 対応した問題

**Issue**: Board App Build & Deploy ワークフロー #64 でアノテーション 1 エラーが発生

**エラー内容**:
```
server can't find aksdemodev-nxzok1nt.hcp.japaneast.azmk8s.io: NXDOMAIN
❌ DNS 解決に失敗しました
```

## 🔍 根本原因

AKS クラスターが **停止状態（Stopped）** の場合、API サーバーの DNS 名が解決できません。これは以下の理由によります：

1. AKS の停止機能は API サーバーを含むコントロールプレーンを停止する
2. 停止中は DNS エンドポイントが無効化される
3. 既存のワークフローは停止状態を検出・対応する仕組みがなかった

## ✅ 実施した修正

### 1. 新機能: AKS 自動起動

**場所**: `.github/workflows/2-board-app-build-deploy.yml`

**追加したステップ** (行 631-711):
```yaml
- name: AKS クラスターの状態を確認
  run: |
    # AKS の電源状態を確認
    # Stopped の場合は自動的に起動
    # 起動完了まで最大 10 分待機
    # DNS 伝播のため追加 30 秒待機
```

**動作**:
1. `az aks show` で `powerState.code` を取得
2. `Stopped` → `az aks start --no-wait` で起動開始
3. 15秒間隔で状態をポーリング（最大 10 分）
4. `Running` になったら DNS 伝播待機（30秒）
5. 接続検証に進む

### 2. エラーメッセージの改善

**場所**: `.github/workflows/2-board-app-build-deploy.yml` (行 743-767)

**改善内容**:
- DNS 解決失敗時に考えられる原因を列挙
- AKS クラスターの詳細情報を JSON で表示
- 推奨される対応手順を明示
- 不要なネットワーク診断を削除（ノイズ削減）

### 3. トラブルシューティングドキュメント

**場所**: `trouble_docs/aks-dns-resolution-failure.md`

**内容**:
- 問題の原因分析（4 パターン）
- 自動修正の仕組み
- 手動対応方法
- 動作フローチャート

## 🎯 効果

| 項目 | 修正前 | 修正後 |
|------|--------|--------|
| AKS 停止時の挙動 | ❌ 即座にエラー終了 | ✅ 自動起動してデプロイ継続 |
| エラー診断 | ⚠️ 最小限の情報 | ✅ 詳細な原因と対応手順 |
| 復旧時間 | ⏱️ 約 15分（手動） | ⚡ 約 11分（自動） |
| 運用性 | ⚠️ 停止機能が使いにくい | ✅ コスト削減と自動復旧を両立 |

## 🔄 動作フロー

```
[デプロイワークフロー開始]
        ↓
[AKS 資格情報取得]
        ↓
[🆕 AKS 状態確認] ← 新しいステップ
   ├─ Running の場合
   │    └→ [接続検証へ]
   │
   └─ Stopped の場合
        ├→ [AKS 起動開始]
        ├→ [起動完了待機：最大 10 分]
        ├→ [DNS 伝播待機：30 秒]
        └→ [接続検証へ]
             ↓
[DNS 解決テスト（5回リトライ）]
             ↓
[kubectl 接続テスト（3回リトライ）]
             ↓
[デプロイ続行]
```

## 🧪 テスト方法

### シナリオ 1: 通常動作（AKS Running）
```bash
# 確認
az aks show --resource-group RG-BBS-Appzz --name aks-demo-dev --query 'powerState.code' -o tsv
# 期待値: Running

# ワークフロー実行
# → 新しいステップは "✅ AKS クラスターは実行中です" と表示してスキップ
```

### シナリオ 2: 自動起動（AKS Stopped）
```bash
# AKS を停止
az aks stop --resource-group RG-BBS-Appzz --name aks-demo-dev

# ワークフロー実行
# → "⚠️ AKS クラスターが停止中です。起動を開始します..."
# → 約 10-11 分後にデプロイ継続
```

### シナリオ 3: エラー表示の改善
```bash
# AKS を削除（極端なケース）
az aks delete --resource-group RG-BBS-Appzz --name aks-demo-dev --yes --no-wait

# ワークフロー実行
# → 詳細なエラーメッセージと診断情報が表示される
```

## 🔒 セキュリティ

- ✅ CodeQL スキャン: アラート 0 件
- ✅ 認証情報: 環境変数経由で安全に使用
- ✅ エラーログ: 機密情報のマスキング維持

## 📁 変更ファイル

```
.github/workflows/2-board-app-build-deploy.yml  (+109行, -7行)
trouble_docs/aks-dns-resolution-failure.md      (新規作成)
```

## 💡 今後の推奨事項

1. **コスト最適化**: 
   - 開発時間外は AKS を停止してコスト削減
   - デプロイ時は自動起動するので問題なし

2. **モニタリング**:
   - 起動時間が 10 分を超える場合は調査
   - `MAX_WAIT_SECONDS` の調整を検討

3. **通知**:
   - AKS 自動起動時に Slack/Teams に通知する（オプション）

## 🔗 関連リンク

- [GitHub Issue #64](https://github.com/aktsmm/container-app-demo/issues/64)
- [トラブルシューティングドキュメント](../trouble_docs/aks-dns-resolution-failure.md)
- [Azure AKS Start/Stop ドキュメント](https://learn.microsoft.com/ja-jp/azure/aks/start-stop-cluster)

---

**修正日**: 2025-11-23  
**修正者**: GitHub Copilot  
**レビュー状態**: Code Review 完了、CodeQL スキャン完了
