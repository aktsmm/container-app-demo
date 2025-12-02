# GitHub Actions 変数が適用されない

- 発生日: 2025-12-03
- 担当: Copilot
- 関連ワークフロー: `1-infra-deploy`, `2-board-app-build-deploy`, `2-admin-app-build-deploy`

## GitHub Actions の LOCATION や AKS 名が反映されない

| 項目 | 内容                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 症状 | GitHub Actions の `vars.LOCATION` を `japanwest` に変更しても、デプロイ結果は `japaneast` のまま。`AKS_CLUSTER_NAME` や `VM_NAME` も Actions 変数を変更しても反映されず、parameters ファイルに書かれている固定値が使用される。                                                                                                                                                                                                                                                                                                                                                              |
| 原因 | `infra/parameters/main-dev.parameters.json` に `location`, `aksName`, `vmName` の固定値が記載されており、Bicep デプロイ時に `--parameters @main-dev.parameters.json` だけを渡していた。パラメータの優先順位は「最後に指定された値が勝つ」（[Parameter precedence](https://learn.microsoft.com/azure/azure-resource-manager/bicep/parameter-files#parameter-precedence)）ため、GitHub Actions の env で指定した `LOCATION` などは上書きできなかった。さらに `2-board-app / 2-admin-app` ワークフローでは MySQL VM 名を parameters ファイルから読んでおり、Actions 側の変数が無視されていた。 |
| 対応 | 1) `location` / `aksName` / `vmName` の値を `__PIPELINE_OVERRIDDEN__` に変更し、CI 経由で必ず上書きする前提にした。2) `1-infra-deploy.yml` の Validate / What-If / Deploy すべてに `--parameters location="$LOCATION" --parameters aksName="$AKS_CLUSTER_NAME" --parameters vmName="$VM_NAME"` を追加。3) ACA 環境名も `ACA_ENVIRONMENT_NAME` を優先し、未指定時のみ `cae-<RG>` を自動生成。4) Board/Admin デプロイワークフローで MySQL Private IP を解決する際、`VM_NAME` 環境変数を最優先で読み取り、未設定時のみ parameters ファイルを参照するように変更。                               |
| 検証 | `vars.LOCATION` を `japanwest` に変更 → `1️⃣ Infrastructure Deploy` を実行し、`az resource list --resource-group RG-bbs-app-demo --query "[?type=='Microsoft.ContainerService/managedClusters'].location"` で `japanwest` になっていることを確認。その後 `2️⃣ Board/Admin` ワークフローで MySQL Private IP が最新の VM 名から取得できることを確認。                                                                                                                                                                                                                                           |
| メモ | 今後リージョンやリソース名を切り替える場合は GitHub Actions の Variables だけを書き換えればよい。パラメータファイルから直接値を渡す運用は禁止。                                                                                                                                                                                                                                                                                                                                                                                                                                             |

## 学び

- GitHub Actions で環境ごとの値を切り替える場合、parameters ファイルにはダミー値を置き、CI から `--parameters` で常に上書きする。
- `az deployment group` のパラメータは後勝ちなので、ファイル＋ CLI の順序を守る。
- トラブル対応内容は即 `trouble_docs/` に残し、次回の手戻りを防止する。
