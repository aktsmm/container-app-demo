# VM Extension MySQL 初期化エラー (command-not-found)

## 概要

- **対象ワークフロー**: `1️⃣ Infrastructure Deploy`
- **影響範囲**: VM 拡張機能 `MysqlInit` (CustomScript) が `ProvisioningState=Failed` で停止し、VM 作成がロールバック。
- **発生日時**: 2025-11-20 05:41/06:01 UTC 付近のデプロイ。
- **対処状況**: `scripts/mysql-init.sh` に command-not-found フック無効化処理を追加し、修正を `master` へ反映済み (commits `e3c0b8e`, `a81c43d`).

## 症状

GitHub Actions の `bicep-deploy` ジョブで以下のようなメッセージが表示される。

```
ERROR: ... VMExtensionProvisioningError ... command terminated with exit status=100
[stderr]
E: Could not open file /var/lib/apt/lists/archive.ubuntu.com_ubuntu_dists_jammy_multiverse_cnf_Commands-amd64 - open (2: No such file or directory)
Traceback (most recent call last):
  File "/usr/lib/cnf-update-db", line 32, ...
subprocess.CalledProcessError: Command '/usr/lib/apt/apt-helper cat-file ...' returned non-zero exit status 100.
```

## 原因

Ubuntu 22.04 LTS イメージでは `command-not-found` パッケージが `APT::Update::Post-Invoke-Success` フックを登録しており、`/var/lib/apt/lists/*command-not-found*` が欠損すると `cnf-update-db` が `exit 100` で失敗する。この例外が Custom Script Extension を巻き込んで `MysqlInit` の Enable ハンドラーを失敗させる。

参考: Azure 公式トラブルシューティング (#microsoft.docs.mcp https://learn.microsoft.com/azure/virtual-machines/extensions/custom-script-linux#troubleshooting)

## 調査に使ったコマンド

```pwsh
az deployment operation group list \
  --name deploy-<timestamp> \
  --resource-group RG-bbs-app-demo \
  --query "[].{resource:properties.targetResource.resourceName,state:properties.provisioningState,message:properties.statusMessage}" \
  -o table
```

```pwsh
az vm extension show \
  --resource-group RG-bbs-app-demo \
  --vm-name vm-mysql-demo \
  --name MysqlInit \
  --expand instanceView
```

## 恒久対処

`scripts/mysql-init.sh` に以下のロジックを追加し、apt 実行前にすべての command-not-found フックを無効化する。

```bash
# command-not-found の Post-Invoke を全パターン無効化
log "Disabling command-not-found apt hooks"
targets=$(sudo find /etc/apt/apt.conf.d -maxdepth 1 -type f -name '*command-not-found*' 2>/dev/null || true)
if [[ -n "$targets" ]]; then
  while IFS= read -r file; do
    sudo mv "$file" "${file}.disabled" || sudo truncate -s 0 "$file"
  done <<< "$targets"
fi
sudo rm -f /var/lib/apt/lists/*command-not-found* 2>/dev/null || true
sudo DEBIAN_FRONTEND=noninteractive apt-get update -y -o APT::Update::Post-Invoke-Success::=
```

## 再発防止メモ

1. **スクリプトを最新化**: `scripts/mysql-init.sh` の変更が VM に反映されるよう、`infra/main.bicep` を再デプロイする。
2. **デプロイ再実行**: GitHub Actions `1️⃣ Infrastructure Deploy` を `workflow_dispatch` で再実行。
3. **Extension 状態確認**: `az vm extension show ... --expand instanceView` で `ProvisioningState/Succeeded` を確認。
4. **MySQL 疎通**: VM のパブリック IP に対して `mysql -h <pip> -u <app-user> -p` で接続確認。

## 実践的な Tips

- `AZURE_CLIENT_ID` などの資格情報を変更した場合は `prepare` ジョブのみ再実行しても AKS/VM リソースを安全に再利用できる。
- `command-not-found` 由来のエラーは Ubuntu 以外でも `APT::Update::Post-Invoke-Success` に独自スクリプトを登録しているカスタムイメージで再発する。カスタム Script Extension を使う場合は `apt-get update` 直前に不要フックを明示的に無効化すると安全。
- 長時間失敗が続いた場合は VM を `az vm delete --yes --force-deletion` で完全削除してから再デプロイした方が早い。
