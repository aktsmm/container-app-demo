# LoadBalancer ヘルスプローブ不一致によるアクセス不可問題

**日時**: 2025-01-21  
**カテゴリ**: AKS, Ingress, LoadBalancer, ネットワーク

---

## 問題の概要

AKS の Ingress Controller (NGINX) 経由で掲示板アプリにアクセスできない。ワークフローは正常に完了しているが、LoadBalancer の IP アドレス (`20.222.232.70`) に HTTP 接続がタイムアウトする。

### 症状

```bash
$ curl -v http://20.222.232.70/ -H "Host: board.localdemo.internal"
* Failed to connect to 20.222.232.70 port 80 after 21058 ms: Could not connect to server
```

### 確認した状態

- ✅ Pod: 正常稼働 (`board-app`, `board-api`)
- ✅ Service: ClusterIP で公開
- ✅ Ingress: `board-app` ネームスペースに存在、ADDRESS = `20.222.232.70`
- ✅ Ingress Controller Pod: Running
- ✅ LoadBalancer Service: EXTERNAL-IP = `20.222.232.70`
- ✅ Public IP: 割り当て済み (`pip-aks-ingress-dev`)
- ✅ LoadBalancer ルール: 80/443 → 80/443 転送設定あり
- ❌ **接続**: タイムアウト

---

## 根本原因

**Azure LoadBalancer のヘルスプローブが古い NodePort を参照していた**

### 詳細

1. LoadBalancer のヘルスプローブが NodePort **30143** を監視
2. 実際の Ingress Controller Service は NodePort **32199** (HTTP) と **30891** (HTTPS) を使用
3. この不一致により、LoadBalancer がバックエンドを「異常」と判定
4. 結果として、トラフィックが転送されない

### 確認コマンド

```bash
# Ingress Controller の実際の NodePort
$ kubectl get svc -n ingress-nginx
NAME                       TYPE           EXTERNAL-IP     PORT(S)
ingress-nginx-controller   LoadBalancer   20.222.232.70   80:32199/TCP,443:30891/TCP

# LoadBalancer のヘルスプローブ
$ az network lb probe list --resource-group mc-rg-demo-app --lb-name kubernetes -o table
Name                                        Port    Protocol    RequestPath
------------------------------------------  ------  ----------  -------------
ae3f94b3d23304b5c99316a6da9704ef-TCP-30143  30143   Http        /healthz
```

**ポート不一致** (`30143` vs `32199`) が問題の原因。

---

## 解決策

### 1. **Helm values.yaml を作成**

LoadBalancer のヘルスプローブ設定を明示的に指定する values ファイルを作成。

**ファイルパス**: `app/board-app/k8s/ingress-nginx-values.yaml`

```yaml
controller:
  replicaCount: 1

  service:
    type: LoadBalancer
    externalTrafficPolicy: Local
    
    # 🔑 重要: ヘルスチェック用の固定 NodePort
    # これにより LoadBalancer のヘルスプローブが毎回同じポートを参照
    healthCheckNodePort: 30254

    annotations:
      # ヘルスプローブのパスと設定を明示
      service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: "/healthz"
      service.beta.kubernetes.io/azure-load-balancer-health-probe-interval: "5"
      service.beta.kubernetes.io/azure-load-balancer-health-probe-num-of-probe: "2"
      service.beta.kubernetes.io/azure-load-balancer-tcp-idle-timeout: "30"

  livenessProbe:
    httpGet:
      path: /healthz
      port: 10254

  readinessProbe:
    httpGet:
      path: /healthz
      port: 10254
```

**重要ポイント**: `healthCheckNodePort: 30254` を固定化することで、Kubernetes が毎回同じ NodePort でヘルスプローブを受け付けるようになります。これにより Azure LoadBalancer のヘルスプローブ設定との不一致が解消されます。

### 2. **ワークフローを修正**

`.github/workflows/3-deploy-board-app.yml` の `Ingress Controller (nginx) を確認/インストール` ステップを修正。

#### 主な変更点

1. **values.yaml ベースの設定**

   ```bash
   helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
     --namespace ingress-nginx \
     --values app/board-app/k8s/ingress-nginx-values.yaml \
     --set controller.image.registry=$ACR_LOGIN_SERVER \
     --set controller.service.loadBalancerIP=$STATIC_IP \
     --wait --timeout=10m
   ```

2. **既存 LoadBalancer サービスの削除**

   ```bash
   # upgrade 前に古い設定の LoadBalancer を削除
   kubectl delete svc ingress-nginx-controller -n ingress-nginx --ignore-not-found=true
   sleep 10
   ```

3. **LoadBalancer IP 取得の確実化**

   ```bash
   # 最大 10分待機（60回 × 10秒）
   ATTEMPTS=60
   for i in $(seq 1 $ATTEMPTS); do
     LB_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
       -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
     if [ -n "$LB_IP" ]; then
       echo "✅ LoadBalancer IP 取得成功: $LB_IP"
       break
     fi
     sleep 10
   done
   ```

4. **接続確認ステップを追加**

   ```bash
   # Ingress Controller のヘルスチェック
   kubectl exec -n ingress-nginx deployment/ingress-nginx-controller -- \
     curl -s -o /dev/null -w "%{http_code}" http://localhost:10254/healthz

   # LoadBalancer ポート 80 への接続テスト
   timeout 5 bash -c "echo > /dev/tcp/$LB_IP/80"
   ```

---

## 修正後の動作

### 期待される状態

1. ✅ Helm が values.yaml を使用して Ingress Controller をデプロイ
2. ✅ Azure LoadBalancer が `/healthz` エンドポイントを正しい NodePort で監視
3. ✅ ヘルスプローブが成功し、バックエンドプールが「正常」状態になる
4. ✅ LoadBalancer がトラフィックを転送開始
5. ✅ アプリに HTTP でアクセス可能

### 検証コマンド

```bash
# LoadBalancer のヘルスプローブ確認
az network lb probe list \
  --resource-group mc-rg-demo-app \
  --lb-name kubernetes \
  -o table

# 実際の NodePort 確認
kubectl get svc -n ingress-nginx ingress-nginx-controller

# アプリへアクセス
curl -H "Host: board.localdemo.internal" http://20.222.232.70/
```

---

## 再発防止策

1. **healthCheckNodePort を固定化**（最重要）

   - `externalTrafficPolicy: Local` 使用時は `healthCheckNodePort` を明示的に指定
   - Kubernetes がランダムに割り当てる問題を回避
   - 推奨値: 30254（30000-32767 の範囲で任意のポート）
   - 参考: [Kubernetes LoadBalancer - Preserving the client source IP](https://kubernetes.io/docs/tasks/access-application-cluster/create-external-load-balancer/#preserving-the-client-source-ip)

2. **values.yaml で設定を一元管理**

   - `--set` での個別指定ではなく、values.yaml で標準設定を定義
   - ヘルスプローブ設定を明示的に含める

3. **LoadBalancer の強制再作成**

   - Helm upgrade 時に既存サービスを削除して再作成
   - 古い設定が残らないようにする

4. **ヘルスプローブ設定の確認ステップを追加**

   - デプロイ後に Azure LoadBalancer のヘルスプローブ設定を確認
   - `healthCheckNodePort: 30254` が正しく使用されているか検証
   - 問題を早期に検出

5. **接続確認ステップの追加**

   - デプロイ後に LoadBalancer への接続テストを実施
   - 接続失敗時は診断情報を出力

6. **タイムアウト時間の延長**
   - LoadBalancer IP 割り当て待機を 10 分に延長
   - ヘルスプローブ作成待機を 3 分に設定
   - Azure のプロビジョニング時間に余裕を持たせる

### 新しいリソースグループでのデプロイ時の注意

**初回デプロイ時の推奨手順**:

1. インフラデプロイ（`1️⃣ Infrastructure Deploy`）を実行
2. **5-10 分待機** して Azure LoadBalancer のプロビジョニングを待つ
3. アプリデプロイ（`3️⃣ Deploy Board App`）を実行
4. ワークフローの `LoadBalancer 接続確認` ステップで接続成功を確認

もし接続確認が失敗した場合:

- 5-10 分待機後、ワークフローを再実行
- ヘルスプローブのポートが `30254` になっているか確認:
  ```bash
  az network lb probe list --resource-group <node-rg> --lb-name kubernetes -o table
  ```
- それでも失敗する場合は Service を削除して再作成:
  ```bash
  kubectl delete svc ingress-nginx-controller -n ingress-nginx
  # ワークフローを再実行
  ```

---

## 関連ドキュメント

- [Azure Kubernetes Service での HTTP アプリケーション ルーティング アドオン](https://learn.microsoft.com/ja-jp/azure/aks/http-application-routing)
- [Azure Load Balancer のヘルス プローブ](https://learn.microsoft.com/ja-jp/azure/load-balancer/load-balancer-custom-probe-overview)
- [NGINX Ingress Controller - Azure Load Balancer](https://kubernetes.github.io/ingress-nginx/deploy/#azure)

---

## 教訓

- Kubernetes の LoadBalancer Service は NodePort を動的に割り当てるため、ヘルスプローブの設定を明示的に行わないと不一致が発生する
- Azure LoadBalancer のアノテーションを正しく設定することで、ヘルスプローブのパスとポートを制御できる
- Helm の `--reset-values` や `--reuse-values` は予期しない設定の持ち越しを引き起こすため、values.yaml での管理が推奨される
