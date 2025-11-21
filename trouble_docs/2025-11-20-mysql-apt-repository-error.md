# MySQL 初期化スクリプトの apt リポジトリエラー対応

**日時:** 2025-11-20

**発生環境:** 新規リソースグループ (`RG-bbs-app-demo-test`) への Infrastructure Deploy

---

## 問題の概要

新しいリソースグループへのデプロイ時に、VM 拡張機能 (MysqlInit) が以下のエラーで失敗：

```
ERROR: VM has reported a failure when processing extension 'MysqlInit'
Error message: 'Enable failed: failed to execute command: command terminated with exit status=100

[stderr]
W: GPG error: http://archive.ubuntu.com/ubuntu jammy InRelease: Splitting up /var/lib/apt/lists/archive.ubuntu.com_ubuntu_dists_jammy_InRelease into data and signature failed
E: The repository 'http://archive.ubuntu.com/ubuntu jammy InRelease' is not signed.
```

---

## 根本原因

1. **apt キャッシュの破損**

   - VM 初期化時に `/var/lib/apt/lists/` 内のファイルが破損
   - GPG 署名検証が失敗し、apt-get update がエラー終了

2. **一時的なネットワーク問題**

   - Ubuntu apt リポジトリへのアクセス時に一時的な接続問題が発生
   - リトライロジックがなく、1 回の失敗で即座にデプロイ全体が失敗

3. **既存スクリプトの脆弱性**
   - `apt-get update` が 1 回のみ実行
   - キャッシュクリーンアップ処理なし
   - エラーハンドリング不足

---

## 対応内容

### 修正ファイル

- `scripts/mysql-init.sh`

### 実装した改善策

#### 1. apt キャッシュのクリーンアップ

```bash
log "Fixing potentially broken apt lists"
sudo rm -rf /var/lib/apt/lists/*
sudo mkdir -p /var/lib/apt/lists/partial
sudo apt-get clean
```

- `/var/lib/apt/lists/` を完全にクリア
- 破損したキャッシュを引きずらない

#### 2. リトライロジックの実装

```bash
retry_apt_update() {
    for i in {1..5}; do
        log "apt-get update (try $i)..."
        if sudo apt-get update -y; then
            log "apt-get update succeeded"
            return 0
        fi
        log "apt-get update failed. Sleeping 10s and retrying..."
        sleep 10
    done
    log "apt-get update failed after 5 attempts" >&2
    return 1
}
```

- 最大 5 回のリトライ
- 各試行間に 10 秒の待機
- 一時的なネットワーク問題を吸収

#### 3. 環境変数の明示的設定

```bash
export DEBIAN_FRONTEND=noninteractive
```

- 対話的なプロンプトを抑制
- スクリプト実行の確実性を向上

#### 4. 重複した apt-get update の削除

- `disable_command_not_found_update` 直後の `apt-get update` を削除
- リトライロジック付きの統一された更新処理のみを使用

---

## 検証結果

### テスト環境

- **リソースグループ:** `RG-bbs-app-demo-test`
- **ワークフロー:** `1-infra-deploy.yml` (Infrastructure Deploy)
- **実行日時:** 2025-11-20

### 1 回目の試行（修正前）

- **結果:** ❌ 失敗
- **エラー:** apt GPG 署名エラー
- **所要時間:** 約 7 分で失敗

### 2 回目の試行（修正前）

- **結果:** ❌ 失敗
- **エラー:** 同じ apt GPG 署名エラー
- **所要時間:** 約 2 分で失敗

### 3 回目の試行（修正後）

- **結果:** ✅ 成功
- **所要時間:**
  - prepare: 33 秒
  - bicep-deploy: 3 分 41 秒
  - policy-deploy: 1 分 32 秒
  - summarize: 36 秒
  - **合計:** 約 6 分

---

## 影響範囲

### デプロイ成功率の向上

- 新規リソースグループへのデプロイが安定化
- 一時的なネットワーク問題に対する耐性が向上

### 再現性の確保

- Infrastructure as Code (IaC) の冪等性が強化
- 異なる環境でも同じ結果を再現可能

---

## 学んだ教訓

1. **クリティカルな処理にはリトライロジックが必須**

   - 外部リソース（apt リポジトリ）への依存がある場合は特に重要

2. **キャッシュクリーンアップの重要性**

   - VM 初期化時のキャッシュ状態は予測不可能
   - 明示的なクリーンアップで一貫性を確保

3. **段階的なフォールバック戦略**

   - 既存の `install_mysql_server()` 関数も複数の代替手段を実装
   - 環境依存の問題を軽減

4. **ログの重要性**
   - 各試行で詳細なログを出力
   - トラブルシューティングが容易に

---

## 今後の推奨事項

### 1. 他のスクリプトへの適用

- AKS ノードプロビジョニングスクリプト
- バックアップスクリプト
- 同様のリトライロジックとクリーンアップ処理を追加

### 2. モニタリングの強化

- VM 拡張機能の実行時間を監視
- 異常に長い実行時間の検出とアラート

### 3. タイムアウトの設定

- apt-get update のタイムアウト設定
- 無限待機の防止

---

## 関連ドキュメント

- [VM 拡張機能 MySQL 初期化の文字化け問題](./encoding-mojibake.md)
- [VM 拡張機能のトラブルシューティング](./vm-extension-mysql-init.md)
- [Azure VM 拡張機能のベストプラクティス](https://aka.ms/VMExtensionCSELinuxTroubleshoot)

---

## コミット履歴

- **コミット:** `802c4d6`
- **メッセージ:** "MySQL 初期化スクリプトを強化して apt エラーに対応"
- **変更ファイル:** `scripts/mysql-init.sh`
- **追加行数:** 24 行
- **削除行数:** 2 行
