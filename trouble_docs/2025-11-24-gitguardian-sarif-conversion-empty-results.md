# GitGuardian SARIF 変換スクリプトのバグで検出結果が空になる問題

**日時**: 2025 年 11 月 24 日  
**影響範囲**: Security Scan ワークフロー - GitGuardian 結果表示  
**重要度**: 🔴 HIGH（セキュリティスキャン結果が表示されない）

---

## 📋 問題の概要

GitGuardian のスキャンは正常に実行され、JSON 結果には検出があるにもかかわらず、SARIF 変換後のファイルが空（`results: []`）になり、「📊 実行されたスキャン」セクションに結果が表示されない。

---

## 🐛 症状

### 観察された動作

- GitGuardian ジョブ自体は成功（✅）
- `gitguardian-results.json` には検出結果が含まれている（7 件のシークレット）
- `gitguardian-repo.sarif` のサイズは正常（5.2KB）
- しかし SARIF の `results` 配列が空 `[]`
- 「📊 実行されたスキャン」に「3. GitGuardian - ✅ シークレットなし」と誤表示

### ログ出力

```
✅ GitGuardian スキャン完了
✅ SARIF 変換完了: 0 件の検出  ← 本来は 7 件あるはず
GitGuardian: 0 件のシークレット検出
```

---

## 🔍 原因分析

### Python 変換スクリプトの不具合

**security-scan.yml 行 222-306 の Python スクリプトが間違った JSON 構造を参照していた：**

```python
# ❌ 修正前（誤り）
if isinstance(gg_data, dict) and "secrets" in gg_data:
    for idx, secret in enumerate(gg_data.get("secrets", [])):
        breaks = secret.get("policy_breaks", [])  # 存在しないキー
        # ...
```

**GitGuardian の実際の JSON 構造：**

```json
{
  "scans": [
    {
      "id": "e73224c914144e75f4fb8eb2e74418ece061572c",
      "entities_with_incidents": [
        {
          "filename": "infra/aks_ssh",
          "incidents": [
            {
              "type": "OpenSSH Private Key",
              "policy": "Secrets detection",
              "occurrences": [
                {
                  "match": "-----BEGIN OPENSSH PRIVATE KEY-----...",
                  "line_start": 1,
                  "line_end": 49
                }
              ]
            }
          ]
        }
      ]
    }
  ],
  "total_incidents": 7
}
```

スクリプトは存在しない `"secrets"` キーを探していたため、常に空の SARIF を生成していた。

---

## ✅ 解決方法

### 修正内容（Commit: ebc9360）

Python 変換スクリプトを正しい JSON 構造に対応するよう完全書き換え：

```python
# ✅ 修正後（正しい）
if isinstance(gg_data, dict) and "scans" in gg_data:
    scans = gg_data.get("scans", [])
    for scan in scans:
        if not isinstance(scan, dict):
            continue

        # 各コミットの entities_with_incidents を処理
        entities = scan.get("entities_with_incidents", [])
        for entity in entities:
            if not isinstance(entity, dict):
                continue

            filename = entity.get("filename", "unknown")
            incidents = entity.get("incidents", [])

            # 各インシデントを SARIF に変換
            for incident in incidents:
                if not isinstance(incident, dict):
                    continue

                incident_type = incident.get("type", "secret-detected")
                policy = incident.get("policy", "Secrets detection")
                occurrences = incident.get("occurrences", [])

                # 最初の occurrence から位置情報を取得
                line_start = 1
                line_end = 1
                if occurrences and isinstance(occurrences, list) and len(occurrences) > 0:
                    first_occ = occurrences[0]
                    if isinstance(first_occ, dict):
                        line_start = first_occ.get("line_start", 1)
                        line_end = first_occ.get("line_end", line_start)

                # SARIF result に追加
                sarif["runs"][0]["results"].append({
                    "ruleId": f"gitguardian/{incident_type}",
                    "level": "error",
                    "message": {
                        "text": f"GitGuardian detected {incident_type} in {filename}"
                    },
                    "locations": [{
                        "physicalLocation": {
                            "artifactLocation": {
                                "uri": filename
                            },
                            "region": {
                                "startLine": line_start,
                                "endLine": line_end
                            }
                        }
                    }],
                    "properties": {
                        "severity": "HIGH",
                        "policy": policy
                    }
                })
```

### 修正範囲

- **ファイル**: `.github/workflows/security-scan.yml`
- **行**: 222-306
- **変更内容**: Python インライン変換スクリプト全体（56 行追加、40 行削除）

---

## 🧪 検証方法

### 1. artifact のダウンロードと確認

```powershell
gh run download <RUN_ID> -n gitguardian-results
Get-Content gitguardian-repo.sarif | ConvertFrom-Json | Select-Object -ExpandProperty runs | Select-Object -ExpandProperty results
```

**修正前**: `[]`（空配列）  
**修正後**: 7 件の result オブジェクトを含む

### 2. ワークフロー実行の確認

```
✅ GitGuardian スキャン完了
✅ SARIF 変換完了: 7 件の検出  ← 正しい件数
GitGuardian: 7 件のシークレット検出
```

### 3. Summary の確認

「📊 実行されたスキャン」セクションに以下が表示される：

```
3. **GitGuardian** - ⚠️ 7 件のシークレット検出 (400+ パターン検証)
   **検出されたシークレット（上位5件）:**
   - gitguardian/Generic Password: GitGuardian detected Generic Password in app/board-app/public/dummy-secret.txt (app/board-app/public/dummy-secret.txt:6)
   - gitguardian/OpenSSH Private Key: GitGuardian detected OpenSSH Private Key in infra/aks_ssh (infra/aks_ssh:1)
   ...
```

---

## 📝 教訓

### 1. **外部ツールの JSON 構造を事前確認**

- GitGuardian の公式ドキュメントや実際の出力サンプルを確認すべきだった
- スキーマ変更の可能性を考慮し、バージョン固定を検討

### 2. **変換スクリプトのテスト**

- 実際の JSON サンプルでローカルテストを行う
- 空の結果が出た場合のデバッグ出力を追加

### 3. **Silent Failure の検出**

- スクリプトがエラーなく終了しても、出力が意図と異なる場合がある
- 件数チェックやアサーションを追加

---

## 🔗 関連情報

- **関連 Commit**:
  - ebc9360: Python 変換スクリプト修正（この問題の解決）
  - 025603f: jq クエリ修正（次の問題の解決）
- **Workflow Run**: 19628985193（修正後の成功実行）
- **関連ドキュメント**: `2025-11-24-gitguardian-summary-categorized-alerts.md`（次の問題）

---

## 🎯 結果

✅ GitGuardian の検出結果が正しく SARIF に変換されるようになった  
✅ 「📊 実行されたスキャン」に正確な件数と詳細が表示される  
✅ Security タブの Code scanning alerts にも正しくアップロードされる

**次の課題**: 「📁 カテゴリ別アラート」にも表示されるようにする（別問題として対応）
