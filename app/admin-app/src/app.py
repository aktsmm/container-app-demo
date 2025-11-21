import os
from base64 import b64encode
from functools import wraps
from typing import Callable
from datetime import datetime
import re

from flask import Flask, Response, jsonify, request, render_template_string
from azure.storage.blob import BlobServiceClient
from azure.identity import DefaultAzureCredential
import pymysql

app = Flask(__name__)

ADMIN_USERNAME = os.environ.get('ADMIN_USERNAME', 'admin')
ADMIN_PASSWORD = os.environ.get('ADMIN_PASSWORD', 'changeme')
DB_ENDPOINT = os.environ.get('DB_ENDPOINT', 'mysql.internal:3306')
DB_USER = os.environ.get('DB_APP_USERNAME', 'boardapp')
DB_PASSWORD = os.environ.get('DB_APP_PASSWORD', '')
DB_NAME = os.environ.get('DB_NAME', 'boarddb')
BACKUP_CONTAINER = os.environ.get('BACKUP_CONTAINER', 'mysql-backup')
STORAGE_ACCOUNT_NAME = os.environ.get('STORAGE_ACCOUNT_NAME', '')


def require_basic_auth(view_func: Callable):
  """非常にシンプルな Basic 認証。ACA の Ingress で追加保護される前提。"""

  @wraps(view_func)
  def wrapper(*args, **kwargs):
    auth = request.authorization
    if not auth or auth.username != ADMIN_USERNAME or auth.password != ADMIN_PASSWORD:
      return Response('認証が必要です', 401, {'WWW-Authenticate': 'Basic realm="Admin"'})
    return view_func(*args, **kwargs)

  return wrapper


def get_blob_service_client():
  """Azure Storage Blob クライアントを取得（Managed Identity 使用）"""
  if not STORAGE_ACCOUNT_NAME:
    return None
  try:
    account_url = f"https://{STORAGE_ACCOUNT_NAME}.blob.core.windows.net"
    credential = DefaultAzureCredential()
    return BlobServiceClient(account_url=account_url, credential=credential)
  except Exception as e:
    app.logger.error(f"Storage client error: {e}")
    return None


def get_mysql_connection():
  """MySQL 接続を取得"""
  try:
    host, port = DB_ENDPOINT.split(':')
    return pymysql.connect(
      host=host,
      port=int(port),
      user=DB_USER,
      password=DB_PASSWORD,
      database=DB_NAME,
      charset='utf8mb4',
      cursorclass=pymysql.cursors.DictCursor
    )
  except Exception as e:
    app.logger.error(f"MySQL connection error: {e}")
    return None


@app.get('/healthz')
def health_check():
  return jsonify(status='ok', source='admin-app')


@app.get('/api/status')
@require_basic_auth
def status():
  """システムステータスを返す"""
  payload = {
    'mysql': {
      'endpoint': DB_ENDPOINT,
      'replicationLagSec': 0,
      'lastBackupUtc': os.environ.get('LAST_BACKUP_UTC', 'unknown')
    },
    'backup': {
      'container': BACKUP_CONTAINER,
      'storageAccount': STORAGE_ACCOUNT_NAME,
      'pendingUploads': int(os.environ.get('PENDING_UPLOADS', '0'))
    },
    'observability': 'Log Analytics へ forwarded'
  }
  return jsonify(payload)


@app.get('/api/backups')
@require_basic_auth
def list_backups():
  """Azure Storage からバックアップファイル一覧を取得"""
  blob_service = get_blob_service_client()
  if not blob_service:
    return jsonify(error='Storage client not configured'), 500
  
  try:
    container_client = blob_service.get_container_client(BACKUP_CONTAINER)
    blobs = container_client.list_blobs()
    
    backup_list = []
    for blob in blobs:
      backup_list.append({
        'name': blob.name,
        'size': blob.size,
        'created': blob.creation_time.isoformat() if blob.creation_time else None,
        'lastModified': blob.last_modified.isoformat() if blob.last_modified else None
      })
    
    # 最新順にソート
    backup_list.sort(key=lambda x: x['lastModified'] or '', reverse=True)
    
    return jsonify(backups=backup_list, count=len(backup_list))
  except Exception as e:
    app.logger.error(f"Backup list error: {e}")
    return jsonify(error=str(e)), 500


@app.delete('/api/backups/<path:backup_name>')
@require_basic_auth
def delete_backup(backup_name):
  """指定したバックアップファイルを削除"""
  blob_service = get_blob_service_client()
  if not blob_service:
    return jsonify(error='Storage client not configured'), 500
  
  try:
    container_client = blob_service.get_container_client(BACKUP_CONTAINER)
    blob_client = container_client.get_blob_client(backup_name)
    blob_client.delete_blob()
    
    return jsonify(success=True, message=f'Backup {backup_name} deleted')
  except Exception as e:
    app.logger.error(f"Backup delete error: {e}")
    return jsonify(error=str(e)), 500


@app.post('/api/backups/delete-batch')
@require_basic_auth
def delete_backups_batch():
  """複数のバックアップファイルを一括削除"""
  blob_service = get_blob_service_client()
  if not blob_service:
    return jsonify(error='Storage client not configured'), 500
  
  data = request.get_json()
  if not data or 'names' not in data:
    return jsonify(error='names parameter required'), 400
  
  names = data['names']
  if not isinstance(names, list) or len(names) == 0:
    return jsonify(error='names must be a non-empty array'), 400
  
  try:
    container_client = blob_service.get_container_client(BACKUP_CONTAINER)
    deleted = []
    failed = []
    
    for name in names:
      try:
        blob_client = container_client.get_blob_client(name)
        blob_client.delete_blob()
        deleted.append(name)
      except Exception as e:
        app.logger.error(f"Failed to delete {name}: {e}")
        failed.append({'name': name, 'error': str(e)})
    
    return jsonify(
      success=True,
      deleted=deleted,
      deletedCount=len(deleted),
      failed=failed,
      failedCount=len(failed)
    )
  except Exception as e:
    app.logger.error(f"Batch delete error: {e}")
    return jsonify(error=str(e)), 500


@app.get('/api/messages')
@require_basic_auth
def list_messages():
  """掲示板のメッセージ一覧を取得"""
  conn = get_mysql_connection()
  if not conn:
    return jsonify(error='Database connection failed'), 500
  
  try:
    with conn.cursor() as cursor:
      cursor.execute("""
        SELECT id, author, message, created_at 
        FROM posts 
        ORDER BY created_at DESC 
        LIMIT 100
      """)
      messages = cursor.fetchall()
    
    return jsonify(messages=messages, count=len(messages))
  except Exception as e:
    app.logger.error(f"Message list error: {e}")
    return jsonify(error=str(e)), 500
  finally:
    conn.close()


@app.delete('/api/messages/<int:message_id>')
@require_basic_auth
def delete_message(message_id):
  """指定したメッセージを削除"""
  conn = get_mysql_connection()
  if not conn:
    return jsonify(error='Database connection failed'), 500
  
  try:
    with conn.cursor() as cursor:
      cursor.execute("DELETE FROM posts WHERE id = %s", (message_id,))
      conn.commit()
      
      if cursor.rowcount > 0:
        return jsonify(success=True, message=f'Message {message_id} deleted')
      else:
        return jsonify(error='Message not found'), 404
  except Exception as e:
    app.logger.error(f"Message delete error: {e}")
    conn.rollback()
    return jsonify(error=str(e)), 500
  finally:
    conn.close()


@app.get('/')
@require_basic_auth
def index():
  """管理UI画面を表示"""
  html = '''
<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>管理アプリ - Container App Demo</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f5f5f5; padding: 20px; }
    .container { max-width: 1200px; margin: 0 auto; }
    h1 { color: #333; margin-bottom: 10px; }
    .subtitle { color: #666; margin-bottom: 30px; }
    .section { background: white; border-radius: 8px; padding: 20px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
    .section h2 { color: #0078d4; margin-bottom: 15px; font-size: 18px; }
    .status-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 15px; }
    .status-card { background: #f9f9f9; padding: 15px; border-radius: 6px; border-left: 4px solid #0078d4; }
    .status-card h3 { font-size: 14px; color: #666; margin-bottom: 8px; }
    .status-card .value { font-size: 20px; color: #333; font-weight: 600; }
    table { width: 100%; border-collapse: collapse; }
    th, td { text-align: left; padding: 12px; border-bottom: 1px solid #e0e0e0; }
    th { background: #f5f5f5; font-weight: 600; color: #333; }
    button { background: #d13438; color: white; border: none; padding: 6px 12px; border-radius: 4px; cursor: pointer; font-size: 12px; }
    button:hover { background: #a02a2d; }
    button.refresh { background: #0078d4; margin-bottom: 15px; padding: 8px 16px; }
    button.refresh:hover { background: #005a9e; }
    button.batch-delete { background: #d13438; margin-left: 10px; padding: 8px 16px; }
    button.batch-delete:hover { background: #a02a2d; }
    button.batch-delete:disabled { background: #ccc; cursor: not-allowed; }
    .loading { color: #666; font-style: italic; }
    .error { color: #d13438; padding: 10px; background: #fef0f0; border-radius: 4px; }
    .time { font-size: 12px; color: #888; }
    input[type="checkbox"] { cursor: pointer; }
  </style>
</head>
<body>
  <div class="container">
    <h1>🛠️ 管理アプリ (Azure Container Apps)</h1>
    <p class="subtitle">MySQL 掲示板とバックアップの管理ダッシュボード</p>

    <div class="section">
      <h2>📊 システムステータス</h2>
      <div id="status" class="loading">読み込み中...</div>
    </div>

    <div class="section">
      <h2>💾 バックアップファイル</h2>
      <button class="refresh" onclick="loadBackups()">🔄 更新</button>
      <button class="batch-delete" id="batchDeleteBtn" onclick="deleteBatchBackups()" disabled>🗑️ 選択を削除</button>
      <div id="backups" class="loading">読み込み中...</div>
    </div>

    <div class="section">
      <h2>💬 掲示板メッセージ管理</h2>
      <button class="refresh" onclick="loadMessages()">🔄 更新</button>
      <div id="messages" class="loading">読み込み中...</div>
    </div>
  </div>

  <script>
    async function loadStatus() {
      try {
        const res = await fetch('/api/status');
        const data = await res.json();
        document.getElementById('status').innerHTML = `
          <div class="status-grid">
            <div class="status-card">
              <h3>MySQL エンドポイント</h3>
              <div class="value">${data.mysql.endpoint}</div>
            </div>
            <div class="status-card">
              <h3>バックアップコンテナ</h3>
              <div class="value">${data.backup.container}</div>
            </div>
            <div class="status-card">
              <h3>Storage Account</h3>
              <div class="value">${data.backup.storageAccount || 'N/A'}</div>
            </div>
          </div>
        `;
      } catch (e) {
        document.getElementById('status').innerHTML = `<div class="error">エラー: ${e.message}</div>`;
      }
    }

    async function loadBackups() {
      document.getElementById('backups').innerHTML = '<div class="loading">読み込み中...</div>';
      try {
        const res = await fetch('/api/backups');
        const data = await res.json();
        
        if (data.error) {
          document.getElementById('backups').innerHTML = `<div class="error">${data.error}</div>`;
          return;
        }

        if (data.count === 0) {
          document.getElementById('backups').innerHTML = '<p>バックアップファイルが見つかりません</p>';
          return;
        }

        let html = `<p>合計: ${data.count} ファイル</p><table><thead><tr><th><input type="checkbox" id="selectAllBackups" onchange="toggleAllBackups()"></th><th>ファイル名</th><th>サイズ (KB)</th><th>最終更新</th><th>操作</th></tr></thead><tbody>`;
        data.backups.forEach(b => {
          const sizeKB = Math.round(b.size / 1024);
          const date = b.lastModified ? new Date(b.lastModified).toLocaleString('ja-JP') : 'N/A';
          html += `<tr><td><input type="checkbox" class="backup-checkbox" value="${b.name}" onchange="updateBatchDeleteButton()"></td><td>${b.name}</td><td>${sizeKB}</td><td class="time">${date}</td><td><button onclick="deleteBackup('${b.name}')">削除</button></td></tr>`;
        });
        html += '</tbody></table>';
        document.getElementById('backups').innerHTML = html;
        updateBatchDeleteButton();
      } catch (e) {
        document.getElementById('backups').innerHTML = `<div class="error">エラー: ${e.message}</div>`;
      }
    }

    async function loadMessages() {
      document.getElementById('messages').innerHTML = '<div class="loading">読み込み中...</div>';
      try {
        const res = await fetch('/api/messages');
        const data = await res.json();
        
        if (data.error) {
          document.getElementById('messages').innerHTML = `<div class="error">${data.error}</div>`;
          return;
        }

        if (data.count === 0) {
          document.getElementById('messages').innerHTML = '<p>メッセージがありません</p>';
          return;
        }

        let html = `<p>合計: ${data.count} メッセージ</p><table><thead><tr><th>ID</th><th>投稿者</th><th>内容</th><th>投稿日時</th><th>操作</th></tr></thead><tbody>`;
        data.messages.forEach(m => {
          const date = new Date(m.created_at).toLocaleString('ja-JP');
          const message = m.message.length > 50 ? m.message.substring(0, 50) + '...' : m.message;
          html += `<tr><td>${m.id}</td><td>${m.author}</td><td>${message}</td><td class="time">${date}</td><td><button onclick="deleteMessage(${m.id})">削除</button></td></tr>`;
        });
        html += '</tbody></table>';
        document.getElementById('messages').innerHTML = html;
      } catch (e) {
        document.getElementById('messages').innerHTML = `<div class="error">エラー: ${e.message}</div>`;
      }
    }

    async function deleteMessage(id) {
      if (!confirm(`メッセージ ID ${id} を削除しますか?`)) return;
      
      try {
        const res = await fetch(`/api/messages/${id}`, { method: 'DELETE' });
        const data = await res.json();
        
        if (data.success) {
          alert('削除しました');
          loadMessages();
        } else {
          alert('エラー: ' + (data.error || '削除に失敗しました'));
        }
      } catch (e) {
        alert('エラー: ' + e.message);
      }
    }

    async function deleteBackup(name) {
      if (!confirm(`バックアップ "${name}" を削除しますか？\\n\\n⚠️ この操作は取り消せません`)) return;
      
      try {
        const res = await fetch(`/api/backups/${encodeURIComponent(name)}`, { method: 'DELETE' });
        const data = await res.json();
        
        if (data.success) {
          alert('削除しました');
          loadBackups();
        } else {
          alert('エラー: ' + (data.error || '削除に失敗しました'));
        }
      } catch (e) {
        alert('エラー: ' + e.message);
      }
    }

    function toggleAllBackups() {
      const selectAll = document.getElementById('selectAllBackups');
      const checkboxes = document.querySelectorAll('.backup-checkbox');
      checkboxes.forEach(cb => cb.checked = selectAll.checked);
      updateBatchDeleteButton();
    }

    function updateBatchDeleteButton() {
      const checkboxes = document.querySelectorAll('.backup-checkbox:checked');
      const btn = document.getElementById('batchDeleteBtn');
      btn.disabled = checkboxes.length === 0;
      btn.textContent = checkboxes.length > 0 ? `🗑️ 選択を削除 (${checkboxes.length})` : '🗑️ 選択を削除';
    }

    async function deleteBatchBackups() {
      const checkboxes = document.querySelectorAll('.backup-checkbox:checked');
      if (checkboxes.length === 0) return;
      
      const names = Array.from(checkboxes).map(cb => cb.value);
      const confirmMsg = `${names.length} 個のバックアップを削除しますか？\\n\\n⚠️ この操作は取り消せません`;
      if (!confirm(confirmMsg)) return;
      
      try {
        const res = await fetch('/api/backups/delete-batch', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ names })
        });
        const data = await res.json();
        
        if (data.success) {
          let msg = `✅ ${data.deletedCount} 個削除しました`;
          if (data.failedCount > 0) {
            msg += `\\n⚠️ ${data.failedCount} 個失敗しました`;
          }
          alert(msg);
          loadBackups();
        } else {
          alert('エラー: ' + (data.error || '削除に失敗しました'));
        }
      } catch (e) {
        alert('エラー: ' + e.message);
      }
    }

    // 初回ロード
    loadStatus();
    loadBackups();
    loadMessages();
  </script>
</body>
</html>
  '''
  return render_template_string(html)


if __name__ == '__main__':  # 手元デバッグ用
  app.run(host='0.0.0.0', port=8000)
