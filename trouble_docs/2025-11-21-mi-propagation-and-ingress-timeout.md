# トラブルシューティング履歴：MI 伝搬遅延 & ingress-nginx タイムアウト

## 📅 発生日時

- Managed Identity ロール割り当て：2025-11-21 10:05 頃
- ingress-nginx デプロイタイムアウト：2025-11-21 11:10 頃

---

## 🔴 事象 1: Managed Identity のロール割り当てが PrincipalNotFound で失敗

### 症状

- `3️⃣ Deploy Admin App (Container Apps)` が `PrincipalNotFound` で失敗。
- ログ抜粋：
  ```
  ERROR: (PrincipalNotFound) Principal dfabb78302b14d95bafb09f0fc475da2 does not exist...
  ...set the role assignment principalType property to a value, such as ServicePrincipal
  ```

### 原因

- System Assigned Managed Identity を付与して即座に RBAC を割り当てると、Microsoft Entra 側のレプリケーションがまだ完了しておらず CLI から Principal を解決できない。
- 公式ドキュメントでも replication delay の場合は `principalType` の明示や待機が推奨されている（[Troubleshoot Azure RBAC](https://learn.microsoft.com/azure/role-based-access-control/troubleshooting#azure-role-assignments)）。

### 対応

1. MI 付与後に最大 300 秒（30 秒 ×10 回）`az ad sp show --id <principalId>` をポーリングし、AAD 上で参照可能になるまで待機。
2. `az role assignment create` に `--assignee-object-id` と `--assignee-principal-type ServicePrincipal` を追加し、Graph 参照をスキップ。
3. Storage Blob Data Contributor 付与時も同じ指定を適用。

### 結果

- 待機と `principalType` 指定により再実行で成功。
- 再発時は `MAX_MI_WAIT` を引き上げればよい。

### 再発防止策

- MI を使うワークフローでは **1) 伝搬待ち → 2) principalType 指定** をテンプレ化。
- 可能であれば RBAC を Bicep など IaC 側で行い、デプロイスクリプトでのオンザフライ割り当てを避ける。

---

## 🔴 事象 2: ingress-nginx Helm install が `context deadline exceeded`

### 症状

- `3️⃣ Deploy Board App (AKS)` の Ingress Controller インストール手順が 10 分待機後に `INSTALLATION FAILED: context deadline exceeded` で終了。
- `kubectl get ns ingress-nginx` は空、Helm install 直後に失敗。

### 原因

- B2s 単一ノードで初回イメージプルに時間がかかり、Helm の `--wait --timeout=10m` を超過。
- `gh variable set` で GH_TOKEN 未設定の警告も併発。
- AKS/Helm ではリソース不足やイメージ取得遅延がタイムアウト原因として挙げられている（[Troubleshoot AKS cluster extensions](https://learn.microsoft.com/azure/troubleshoot/azure/azure-kubernetes/extensions/cluster-extension-deployment-errors#helm-errors)）。

### 対応

1. workflow 全体の `env` に `GH_TOKEN=${{ github.token }}` を追加し、Helm 手順内の `gh` コマンド失敗を解消。
2. `helm show chart ingress-nginx/ingress-nginx` から `appVersion` を取得し、そのタグの controller イメージを `az acr import` で ACR にキャッシュ。
3. Helm install/upgrade にて `--set controller.image.registry/image/tag` で自前 ACR を参照。
4. タイムアウトを 15 分へ延長、`--atomic` 追加、さらに `kubectl rollout status` で Ready まで待機。

### 結果

- 以降の run で ingress-nginx が安定して展開され、LoadBalancer IP 取得まで完走。
- ACR にキャッシュされたタグを再利用するため、以後のデプロイは 1–2 分で安定。

### 再発防止策

- チャートが参照する全イメージ（controller, kube-webhook-certgen 等）を定期的に ACR へ import。
- `kubectl describe pod -n ingress-nginx` を実行するデバッグステップをワークフローに用意し、再度遅延が発生した場合にイベントを即確認できるようにする。
- ノードスケールアウト（最低 2 ノード）や node auto-upgrade 時の再インストールでも同様のキャッシュ手順を流用する。

---

## 🧾 Lesson Learned

| 観点     | 学び                                                                        | 対応ステータス                      |
| -------- | --------------------------------------------------------------------------- | ----------------------------------- |
| RBAC     | MI 付与直後は principalType の明示と待機が必須                              | ワークフローへ実装済み              |
| Helm     | 低スペックノードではイメージプルを ACR へ取り込み、タイムアウトを長めに取る | イメージ import + `--atomic` で解決 |
| ログ管理 | トラブル内容を `trouble_docs/` に即記録し、再発時に参照できるようにする     | 本ドキュメントで反映                |

---

## 🔗 参考リンク

- Managed Identity レプリケーション遅延：<https://learn.microsoft.com/azure/role-based-access-control/troubleshooting#azure-role-assignments>
- Helm インストールタイムアウトの原因：<https://learn.microsoft.com/azure/troubleshoot/azure/azure-kubernetes/extensions/cluster-extension-deployment-errors#helm-errors>
