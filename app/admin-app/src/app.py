import os
from base64 import b64encode
from functools import wraps
from typing import Callable

from flask import Flask, Response, jsonify, request

app = Flask(__name__)

ADMIN_USERNAME = os.environ.get('ADMIN_USERNAME', 'admin')
ADMIN_PASSWORD = os.environ.get('ADMIN_PASSWORD', 'changeme')
DB_ENDPOINT = os.environ.get('DB_ENDPOINT', 'mysql.internal:3306')
BACKUP_CONTAINER = os.environ.get('BACKUP_CONTAINER', 'mysql-backup')


def require_basic_auth(view_func: Callable):
  """非常にシンプルな Basic 認証。ACA の Ingress で追加保護される前提。"""

  @wraps(view_func)
  def wrapper(*args, **kwargs):
    auth = request.authorization
    if not auth or auth.username != ADMIN_USERNAME or auth.password != ADMIN_PASSWORD:
      return Response('認証が必要です', 401, {'WWW-Authenticate': 'Basic realm="Admin"'})
    return view_func(*args, **kwargs)

  return wrapper


@app.get('/healthz')
def health_check():
  return jsonify(status='ok', source='admin-app')


@app.get('/api/status')
@require_basic_auth
def status():
  # 本来は MySQL やバックアップ VM の実データを参照する。
  payload = {
    'mysql': {
      'endpoint': DB_ENDPOINT,
      'replicationLagSec': 0,
      'lastBackupUtc': os.environ.get('LAST_BACKUP_UTC', 'unknown')
    },
    'backup': {
      'container': BACKUP_CONTAINER,
      'pendingUploads': int(os.environ.get('PENDING_UPLOADS', '0'))
    },
    'observability': 'Log Analytics へ forwarded'
  }
  return jsonify(payload)


@app.get('/')
@require_basic_auth
def index():
  return jsonify(
    message='管理アプリ (ACA)',
    instructions='MySQL/バックアップの状態を API 経由で確認できます',
    docs='docs/github-actions-sp-deploy.md'
  )


if __name__ == '__main__':  # 手元デバッグ用
  app.run(host='0.0.0.0', port=8000)
