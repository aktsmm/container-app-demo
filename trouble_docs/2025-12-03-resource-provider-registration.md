# SubscriptionNotFound / Resource Provider 未登録

- 発生日: 2025-12-03
- 担当: Copilot
- 関連ワークフロー: `1-infra-deploy`

| 項目 | 内容 |
| ---- | ---- |
| 症状 | `az acr check-name` や `az storage account check-name` の段階で `ERROR: (SubscriptionNotFound) Subscription *** was not found.` が発生し、ユニーク名チェックが停止する。 |
| 原因 | 新規サブスクリプションで必要な Azure Resource Provider (Microsoft.Compute / Network / Storage / ContainerRegistry / ContainerService / Web / OperationalInsights / Authorization / ManagedIdentity / KeyVault / Insights) が未登録だったため、CLI がリソースタイプを解決できなかった。Portal で未作成のサービスは自動登録されない。 |
| 対応 | Owner/Contributor 権限を持つ Service Principal で `az account set --subscription <SUB_ID>` を実行後、`az provider register --namespace <ProviderName>` を順に実行。基本 11 種類をまとめて登録し、その他はサービス追加時に都度登録する運用に変更。 |
| 検証 | `az provider list --query "[?namespace=='Microsoft.Compute'||namespace=='Microsoft.Network'||namespace=='Microsoft.Storage'||namespace=='Microsoft.ContainerRegistry'||namespace=='Microsoft.ContainerService'||namespace=='Microsoft.Web'||namespace=='Microsoft.OperationalInsights'||namespace=='Microsoft.Authorization'||namespace=='Microsoft.ManagedIdentity'||namespace=='Microsoft.KeyVault'||namespace=='Microsoft.Insights'].[namespace,registrationState]" -o table` が全て `Registered` になることを確認。 |
| メモ | 未登録 RP は `az provider list --query "[?registrationState!='Registered'].namespace" -o tsv` で抽出し、PowerShell の `foreach ($ns in $notRegistered) { az provider register --namespace $ns }` で一括登録すると早い。 |

## Tips

- 新サブスクリプションを初めて使うときは、利用予定リソースの RP を先に登録しておく。Portal の「Subscriptions → Resource providers」から GUI でも登録可能。
- Service Principal に `/register/action` 権限（Owner/Contributor）があることを確認する。 lacking rights results `MissingSubscriptionRegistration`.
- 登録直後は `Registering` 状態が続くため、CI から `az provider list --query "[?registrationState=='Registering'].[namespace]" -o table` を実行し、完了後にデプロイを再開する。
