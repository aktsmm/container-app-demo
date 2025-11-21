# 管理アプリ (admin-app)

Azure Container Apps で稼働するシンプルな Flask API。Basic 認証で保護され、MySQL やバックアップコンテナの状態を API 経由で確認できます。

## 環境変数

| 変数                                | 説明                            |
| ----------------------------------- | ------------------------------- |
| `ADMIN_USERNAME` / `ADMIN_PASSWORD` | Basic 認証で利用する資格情報    |
| `DB_ENDPOINT`                       | 監視対象 MySQL の接続先表示     |
| `BACKUP_CONTAINER`                  | バックアップ格納先コンテナ名    |
| `LAST_BACKUP_UTC`                   | 最新バックアップ時刻（ISO8601） |
| `PENDING_UPLOADS`                   | 未アップロード数                |

## ローカル実行

```powershell
cd app/admin-app
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
set ADMIN_USERNAME=admin
set ADMIN_PASSWORD=changeme
python src/app.py
```

## コンテナビルド

```powershell
cd app/admin-app
docker build -t admin-app:dev .
```
