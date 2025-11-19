# Container App Demo

This repository was bootstrapped to demonstrate container app experiments. Commit history begins with this initialization.

# 設定すべき GitHub Actions Secret ＆ Variables

## Service Principal 作成スクリプトの概要

`scripts/create-github-actions-sp.ps1` は GitHub Actions から Azure へ接続するための Service Principal をクライアント シークレット方式で作成し、必要な `AZURE_*` シークレット値をまとめて出力します。サブスクリプション全体や特定のリソースグループに対して Contributor など任意のロールを付与でき、シークレットの有効期限年数も `-SecretDurationYears` で調整できます。実行には事前の `az login` と Azure CLI のインストールが必要です。

## 使い方

`-ResourceGroupName` を指定するとリソースグループ単位にスコープを絞れますが、省略すればサブスクリプション全体が対象になります。

`-ResourceGroupName` や `-Scope` を指定しなければ、スクリプトはサブスクリプション全体 (`/subscriptions/<ID>`) をスコープとして扱います。例えば以下のように実行すると、指定サブスクリプションの全リソースに対して `Contributor` 権限を持つ Service Principal が発行されます。

```powershell
pwsh ./scripts/create-github-actions-sp.ps1 `
	-SubscriptionId "00000000-0000-0000-0000-000000000000" `
	-DisplayName "gha-sp-secret" `
	-RoleDefinitionName "Contributor" `
	-SecretDurationYears 2
```

## 実行結果の例

以下はダミー値を用いた出力例です。実際の値が表示された場合は即座に GitHub Actions のシークレットへ登録し、他者へ共有しないでください。

```
--- GitHub Actions に設定するシークレット ---
AZURE_CLIENT_ID = 11111111-2222-3333-4444-555555555555
AZURE_TENANT_ID = 66666666-7777-8888-9999-aaaaaaaaaaaa
AZURE_SUBSCRIPTION_ID = 00000000-0000-0000-0000-000000000000
AZURE_CLIENT_SECRET = <redacted-secret-value>
----------------------------------------
Scope: /subscriptions/00000000-0000-0000-0000-000000000000
```
