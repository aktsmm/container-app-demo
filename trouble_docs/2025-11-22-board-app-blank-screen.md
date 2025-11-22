# 2025-11-22: 掲示板アプリが真っ白に表示される問題

## 🔍 問題

デプロイワークフローは成功するが、ブラウザで LoadBalancer IP にアクセスしても真っ白で何も表示されない。

## 🩺 トラブルシューティング実施内容

### 1. AKS クラスタ状態確認
```bash
kubectl get pods -n board-app -o wide
kubectl get svc,endpoints,ingress -n board-app
```

**結果**:
- ✅ Pod: Running（board-app, board-api 両方とも正常）
- ✅ Service: ClusterIP で正しく作成
- ✅ Endpoints: Pod IP が正しく登録
- ✅ Ingress: LoadBalancer IP `74.176.19.199` に紐付き

### 2. Ingress ルーティング検証
```bash
kubectl describe ingress board-app -n board-app
```

**結果**:
- ✅ ルールが正しく設定（`/` → board-app:80, `/api` → board-api:3000）
- ✅ Events に "Scheduled for sync" が記録
- ⚠️ 初期段階で "does not have any active Endpoint" 警告（後に解消）

### 3. Pod ログ確認
```bash
kubectl logs -n board-app -l app=board-app --tail=50
```

**結果**:
- ✅ NGINX が正常起動
- ✅ Readiness Probe が 200 OK で成功
- ✅ アクセスログで kube-probe からのヘルスチェックが定期的に記録

### 4. クラスタ内疎通テスト
```bash
kubectl run tmp-curl --rm -i --restart=Never --image=curlimages/curl -n board-app \
  -- curl -I http://board-app.board-app.svc.cluster.local/
```

**結果**:
```
HTTP/1.1 200 OK
Server: nginx/1.27.2
Content-Type: text/html
Content-Length: 407
```
✅ Service 経由でアクセス可能

### 5. 外部アクセス確認
```bash
curl http://74.176.19.199/
```

**結果**:
```html
<!DOCTYPE html>
<html lang="ja">
  <head>
    <meta charset="UTF-8" />
    <title>Container BBS demo app</title>
    <script type="module" crossorigin src="/assets/index-CjMgkz_J.js"></script>
    <link rel="stylesheet" crossorigin href="/assets/index-DV5bMHxl.css">
  </head>
  <body>
    <div id="root"></div>
  </body>
</html>
```
✅ HTML は正しく配信

### 6. 静的ファイル配信確認
```bash
curl http://74.176.19.199/assets/index-CjMgkz_J.js -I
```

**結果**:
```
HTTP/1.1 200 OK
Content-Type: application/javascript
Content-Length: 154535
```
✅ JS/CSS も正しく配信

### 7. API エンドポイント確認
```bash
curl http://74.176.19.199/api/posts -I
```

**結果**:
```
HTTP/1.1 200 OK
Content-Type: application/json; charset=utf-8
```
✅ API も正常動作

## 💡 原因分析

**すべての要素が正常に動作している**にもかかわらず真っ白に見えた理由：

1. **ブラウザキャッシュ**: 以前の失敗した状態がキャッシュされている可能性
2. **JavaScript 実行タイミング**: React アプリの初期化で API 呼び出しが失敗すると白画面になることがある
3. **CORS/Content-Type 設定**: ブラウザが静的ファイルを正しく解釈できていない可能性

## ✅ 解決策

### ワークフロー改善

デプロイ後に自動で疎通確認を行うステップを追加：

```yaml
- name: デプロイ後の疎通確認
  run: |
    # クラスタ内から Service への直接アクセステスト
    kubectl run tmp-curl --rm -i --restart=Never --image=curlimages/curl -n "$BOARD_NS" \
      -- curl -sI http://board-app.board-app.svc.cluster.local/
    
    # LoadBalancer 経由で HTML を取得
    curl -sf "http://${LB_IP}/" -o /dev/null
    
    # API エンドポイントを確認
    API_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${LB_IP}/api/posts")
    echo "API レスポンス: $API_STATUS"
```

### ユーザー側の対処法

1. **ブラウザキャッシュをクリア**
   - Ctrl + F5（強制リロード）
   - シークレットモードで開く

2. **ブラウザ開発者ツールで確認**
   - F12 → Console タブで JavaScript エラーを確認
   - Network タブで 404/500 エラーがないか確認

3. **DNS 名でアクセス**
   - IP アドレスではなく FQDN（`aksdemodevingress.japaneast.cloudapp.azure.com`）でアクセス

4. **API 応答を直接確認**
   ```bash
   curl http://74.176.19.199/api/posts
   ```

## 📊 検証結果まとめ

| 項目 | 状態 | 詳細 |
|------|------|------|
| Pod 起動 | ✅ | board-app, board-api ともに Running |
| Service | ✅ | ClusterIP で正しく公開 |
| Endpoints | ✅ | Pod IP が正しく登録 |
| Ingress | ✅ | LoadBalancer IP に紐付き |
| HTML 配信 | ✅ | 200 OK, Content-Length: 407 |
| JS/CSS 配信 | ✅ | 200 OK, Content-Type 正常 |
| API 応答 | ✅ | 200 OK, JSON 形式で返答 |
| クラスタ内疎通 | ✅ | Service 経由でアクセス可能 |
| 外部疎通 | ✅ | LoadBalancer 経由でアクセス可能 |

## 🔧 今後の対策

1. **ワークフローに疎通確認ステップを追加**（実施済み）
2. **デプロイサマリに API ステータスを表示**（実施済み）
3. **README にトラブルシューティング手順を追加**（推奨）
4. **ヘルスチェックエンドポイント `/health` の追加**（推奨）

## 📝 関連リンク

- [Troubleshoot AKS workloads - Microsoft Learn](https://learn.microsoft.com/azure/aks/troubleshooting)
- [NGINX Ingress Controller - Troubleshooting](https://kubernetes.github.io/ingress-nginx/troubleshooting/)
