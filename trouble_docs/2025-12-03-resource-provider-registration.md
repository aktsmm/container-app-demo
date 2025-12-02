# SubscriptionNotFound / Resource Provider 未登録

- 発生日: 2025-12-03
- 担当: Copilot
- 関連ワークフロー: `1-infra-deploy`

| 項目 | 内容 |
| --- | --- |
| 症状 | `az acr check-name` や `az storage account check-name` を実行する早い段階で `ERROR: (SubscriptionNotFound) Subscription *** was not found.` が発生し、ユニーク名決定ステップで停止。 |
| 原因 | 新規サブスクリプションで Azure Resource Provider (Microsoft.Compute / Network / Storage / ContainerRegistry / ContainerService / Web / OperationalInsights 等) が未登録だったため、CLI がリソースタイプを解決できなかった。Portal で一度も該当リソースを作成していない場合、自動登録されない。 |
| 対応 | Owner/Contributor 権限を持つ Service Principal で `az account set --subscription <SUB_ID>` を実行した後、`az provider register --namespace Microsoft.Compute` など必要な RP を順に登録。基本 7 つを登録し、他は利用直前に追加する方針。 |
| 検証 | `az provider list --query "[?namespace=='Microsoft.Compute'||namespace=='Microsoft.Network'||namespace=='Microsoft.Storage'||namespace=='Microsoft.ContainerRegistry'||namespace=='Microsoft.ContainerService'||namespace=='Microsoft.Web'||namespace=='Microsoft.OperationalInsights'].[namespace,registrationState]" -o table` で `Registered` を確認。 |
| メモ | 未登録 RP を一括登録する場合は `az provider list --query "[?registrationState!='Registered'].namespace" -o tsv` で一覧化し、PowerShell で `foreach ($ns in $notRegistered) { az provider register --namespace $ns }` を実行。 |

## Tips
- 新サブスクリプションを初めて使うときは、利用予定リソースの RP を先に登録しておく。Portal の「Subscriptions → Resource providers」から GUI でも登録可能。
- Service Principal に `/register/action` 権限（Owner/Contributor）があることを確認する。 lacking rights results `MissingSubscriptionRegistration`.
- 登録直後は `Registering` 状態が続くため、CI から `az provider list --query "[?registrationState=='Registering'].[namespace]" -o table` を実行し、完了後にデプロイを再開する。