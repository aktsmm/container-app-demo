# GitGuardian API Key スコープ不足エラー

## 🔴 問題

```
Error: Token is missing the required scope scan to perform this operation.
```

GitGuardian API Key が設定されているが、`scan` スコープが不足しているため `ggshield secret scan repo` コマンドが実行できない。

## 📊 発生日時

- **日時**: 2025-11-24 06:41:21 (UTC)
- **Run ID**: 19625649812
- **Workflow**: 2️⃣ Board App Build & Deploy
- **Job**: gitguardian-scan

## 🔍 根本原因

設定されている GitGuardian API Key（Personal Access Token）に **`scan` スコープ**が付与されていない。

## ✅ 解決方法

### 1. GitGuardian で新しい API Key を生成

1. https://dashboard.gitguardian.com/api/personal-access-tokens にアクセス
2. 「Create Token」をクリック
3. Token 設定:
   - **Name**: `GitHub Actions - container-app-demo`
   - **Scopes**: ✅ **`scan`** （必須）
   - **Expiration**: お好みで設定（推奨: 90 日または無期限）
4. 「Create」をクリックしてトークンをコピー

### 2. GitHub Variables を更新

```powershell
# PowerShell
gh variable set GITGUARDIAN_API_KEY --body "<新しいAPIキー>"

# または GitHub Web UI から
# Settings → Variables → GITGUARDIAN_API_KEY → Update
```

### 3. ワークフロー再実行で確認

```powershell
gh workflow run "2-board-app-build-deploy.yml"
```

## 📝 必要なスコープ

GitGuardian API Key には以下のスコープが必要：

| スコープ          | 用途                           | 必須    |
| ----------------- | ------------------------------ | ------- |
| **`scan`**        | リポジトリ・ファイルのスキャン | ✅ 必須 |
| `incidents:read`  | インシデント閲覧               | 任意    |
| `incidents:write` | インシデント管理               | 任意    |

本ワークフローでは **`scan`** スコープのみで十分。

## 🔒 セキュリティ注意事項

- API Key は **Variables**（暗号化）に保存
- Secrets ではなく Variables を使用する理由:
  - `vars.GITGUARDIAN_API_KEY` で条件分岐可能
  - ログに値が表示されないよう `::add-mask::` で保護済み
- トークンは定期的に更新することを推奨

## 🧪 検証方法

### ローカルでテスト

```bash
export GITGUARDIAN_API_KEY="your-new-api-key"
ggshield secret scan repo .
```

### GitHub Actions で確認

- GitGuardian scan ジョブが緑色（成功）になること
- 検出結果が Summary に表示されること
- Security タブに SARIF がアップロードされること

## 📚 参考リンク

- [GitGuardian API Documentation](https://docs.gitguardian.com/api-docs/getting-started)
- [ggshield secret scan documentation](https://docs.gitguardian.com/ggshield-docs/reference/secret/scan/repo)
- [GitGuardian Personal Access Tokens](https://dashboard.gitguardian.com/api/personal-access-tokens)
