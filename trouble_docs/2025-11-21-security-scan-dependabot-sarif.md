# Dependabot 実行時に Security Scan が失敗する

## 概要

Dependabot が作成した PR 上で `🔐 Security Scan (CodeQL + Trivy + Gitleaks)` ワークフローが毎回失敗。失敗箇所は CodeQL/Gitleaks/Trivy の SARIF アップロードステップで、`Resource not accessible by integration` が返っていた。

## タイムライン

- 2025-11-21 10:05 JST: Dependabot が `azure-identity` 等のライブラリ更新 PR を作成し、自動で security-scan を実行 → 失敗。
- 2025-11-21 10:30 JST: ログ調査で `security-events: write` が付与されているにも関わらず SARIF アップロードだけが 403 応答となっていることを確認。
- 2025-11-21 11:10 JST: GitHub Docs の [pull_request イベント解説](https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows#pull-request)（#microsoft.docs.mcp）で「Dependabot PR はフォーク扱いとなり `GITHUB_TOKEN` が read-only になる」旨を確認。
- 2025-11-21 11:40 JST: `security-scan.yml` の全 `github/codeql-action/upload-sarif@v4` ステップへ `if: github.actor != 'dependabot[bot]'` を追加して Dependabot 時は SARIF アップロードをスキップするよう修正。

## 影響範囲

- Dependabot PR でのみ security-scan が失敗し、Code Scanning タブに最新結果が反映されなかった。
- 手動 PR や `master` ブランチへの push / 定期実行には影響なし。

## 原因

Dependabot が起動したワークフローは GitHub によって「フォークからの PR」と同等に扱われ、`GITHUB_TOKEN` が強制的に read-only となる。そのため `security-events: write` を要求する SARIF アップロード API が 403 で拒否されていた。

## 対応

1. `security-scan.yml` の以下ステップへ条件を追加して Dependabot 実行時には SARIF をアップロードしないよう変更。
   - `Gitleaks SARIF アップロード`
   - `Trivy SARIF アップロード (全体 / infra / k8s)`
2. 代替として Gitleaks/Trivy 結果はアーティファクトに残るため、人手での確認は継続可能。

## 再発防止 / TODO

- Dependabot 専用に `pull_request_target` でベースブランチ権限を使うワークフローを検討（安全にコードを扱うため checkout 方針要検討）。
- SARIF が存在しない実行だった場合も summary で Dependabot スキップを明示するロギングを追加予定。

## メモ

- 参考: GitHub Docs "Events that trigger workflows > pull_request"（#microsoft.docs.mcp）に Dependabot の権限制約が記載されている。
