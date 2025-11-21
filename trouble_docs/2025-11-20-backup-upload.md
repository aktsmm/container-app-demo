# MySQL バックアップ (backup-upload.yml) トラブルシュート

## 発生日時

- 2025-11-20 14:30 JST 頃 (GitHub Actions `backup-upload.yml` を手動実行)

## 事象

- ワークフローは `Success` 表示だが Azure Storage の `mysql-backups` コンテナにバックアップファイルが生成されない。
- `run_after_fix.log` を確認すると Run Command が `command not found` と `$1: unbound variable` を返しており、VM 上で `mysqldump` が実行されていない。

## 影響

- 直近 1 回分の MySQL フルバックアップが保存されず、RPO が 1 時間分リスク状態。
- 自動実行 (cron: hourly) でも同じ失敗パターンになりうるため、恒常的にバックアップ欠落の可能性。

## 原因

1. `az vm run-command invoke --parameters` を無名引数 (`"$STORAGE_ACCOUNT" "$CONTAINER" ...`) で渡していた。
2. Linux Run Command の仕様では `name=value` 形式で指定しないと環境変数が生成されず、スクリプト側に `$1` 等の値が一切渡らない。
3. その結果、VM 側で生成された一時スクリプト `/var/lib/waagent/run-command/download/5/script.sh` の 1 行目に **MySQL root パスワード文字列** がそのまま展開され、`TempRootP@ssw0rd!2025: command not found` が発生。
4. 次の行で `$1` を参照していたため `line 5: $1: unbound variable` が連鎖し、`mysqldump` 以降の処理がスキップされた。

## 調査ログ抜粋

```
[stderr]
/var/lib/waagent/run-command/download/5/script.sh: line 3: TempRootP@ssw0rd!2025: command not found
/var/lib/waagent/run-command/download/5/script.sh: line 5: $1: unbound variable
```

> 出典: `run_after_fix.log` (`Select-String -Pattern "[stderr]" -Context 0,5`)

## 対応

1. `.github/workflows/backup-upload.yml` のバックアップステップを修正し、`cat <<'SCRIPT'` で Bash スクリプトを生成。
2. `az vm run-command invoke` の `--parameters` を以下のように名前付きへ変更。
   ```yaml
   --parameters \
   storageAccountName="$STORAGE_ACCOUNT_NAME" \
   backupContainerName="$BACKUP_CONTAINER_NAME" \
   sasToken="$SAS_TOKEN" \
   mysqlPassword="$MYSQL_ROOT_PASSWORD"
   ```
3. VM 側スクリプトでは `:"${storageAccountName:?...}"` で必須チェックを行い、安全に大文字変数へ代入。
4. 併せて `azcopy` の存在確認や `logger` 送信など、既存処理を維持しつつ構成を整理。

## 検証

- 修正後にワークフローを再実行予定。Run Command の `Enable succeeded` 出力から `mysql-backup-upload success <timestamp>` ログを確認し、Azure Storage に `.sql` が生成されることをもって完了とする。
- 追加で `az storage blob list --container-name mysql-backups --account-name <name>` を実行し、タイムスタンプ一致ファイルを確認する。

## 再発防止 / Tips

- Linux VM への Run Command では **必ず `name=value` 形式でパラメータを渡す**。これは Microsoft Learn の `az vm run-command invoke` ドキュメントにも記載されている。
- Jenkins / GitHub Actions など CI から Run Command を呼ぶ際にパスワード等をそのままスクリプト先頭へ流さないよう注意 (想定外の `command not found` で漏洩する恐れ)。
- 失敗時は `az vm run-command invoke --ids ... --output table` より、GitHub Actions の `run_after_fix.log` のようにログ全文を取得しておくと再現性高く原因を特定できる。

## メモ

- 今回の修正により `mysql-backup.sh` は Bash 前提で実行されるため、今後同様のツールを追加する際も `set -euo pipefail` が効いた状態で安全。
- 追加で `azcopy` を VM にプリインストールしておくと毎回のダウンロードを省ける。デモ構成では `mktemp` 方式でも十分だが、長期運用ではカスタムスクリプト拡張に切り出すと良い。
