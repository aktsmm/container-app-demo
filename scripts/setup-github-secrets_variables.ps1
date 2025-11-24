# 初回セットアップ用: GitHub Actions の Variables/Secrets に一括設定するスクリプト
# 用途: プロジェクト初回構築時や環境変数の全体リセット時に使用
# セキュリティ: パスワード類はスクリプト内で規定値を設定していますが、本番環境では必ず変更してください

param(
	[string]$Repo,
	[switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# --- 設定値(必要に応じて編集) ---
$DefaultRepo = 'aktsmm/ContainerApp-demo2'

# パスワード一括変更機能
Write-Host '================================' -ForegroundColor Cyan
Write-Host '🔐 パスワード設定' -ForegroundColor Cyan
Write-Host '================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '現在のデフォルトパスワード: P@ssw0rd!2025' -ForegroundColor Yellow
Write-Host ''
$response = Read-Host 'デフォルトパスワードをランダムな値に一括変更しますか？ (Y/N)'

if ($response -eq 'Y' -or $response -eq 'y') {
	$randomSuffix = Get-Random -Minimum 100 -Maximum 99999
	$newPassword = "P@ssw0rd!$randomSuffix"
	Write-Host ''
	Write-Host "✅ 新しいパスワード: $newPassword" -ForegroundColor Green
	Write-Host '   このパスワードは全ての項目に適用されます' -ForegroundColor Gray
	Write-Host ''
} else {
	$newPassword = 'P@ssw0rd!2025'
	Write-Host ''
	Write-Host '⚠️  デフォルトパスワードを使用します (推奨しません)' -ForegroundColor Yellow
	Write-Host ''
}

$GitHubSecrets = @{
	# scripts/create-github-actions-sp.ps1 の出力値を転記する
	AZURE_SUBSCRIPTION_ID = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
}

$GitHubVariables = @{

	# scripts/create-github-actions-sp.ps1 の出力値を転記する
	AZURE_CLIENT_ID          = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
	AZURE_CLIENT_SECRET      = 'xxx~xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
	AZURE_TENANT_ID          = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
    
	RESOURCE_GROUP_NAME      = 'RG-bbs-app-demo'
	LOCATION                 = 'japaneast'
	ACR_NAME_PREFIX          = 'acrdemo'
	STORAGE_ACCOUNT_PREFIX   = 'demo'
	AKS_CLUSTER_NAME         = 'aks-demo-dev'
	ACA_ENVIRONMENT_NAME     = 'cae-demo-dev'
	ADMIN_CONTAINER_APP_NAME = 'admin-app'
	ACA_ADMIN_USERNAME       = 'test-admin'
	ACA_ADMIN_PASSWORD       = $newPassword
	BACKUP_CONTAINER_NAME    = 'mysql-backups'
	VM_NAME                  = 'vm-mysql-demo'
	VM_ADMIN_USERNAME        = 'test-admin'
	DB_APP_USERNAME          = 'test-admin'
	VM_ADMIN_PASSWORD        = $newPassword
	MYSQL_ROOT_PASSWORD      = $newPassword
	DB_APP_PASSWORD          = $newPassword
	
	# GitGuardian API Key (オプション)
	# https://dashboard.gitguardian.com/api/personal-access-tokens で取得
	# 必要なスコープ: scan (必須), incident:read, incident:write
	GITGUARDIAN_API_KEY      = ''
}



function Test-Command {
	param([string]$Name)
	return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Get-GitHubRepoFromGit {
	if (-not (Test-Command -Name 'git')) {
		return $null
	}

	$remoteUrl = git config --get remote.origin.url
	if (-not $remoteUrl) {
		return $null
	}

	# HTTPS(e.g. https://github.com/owner/repo.git) または SSH(e.g. git@github.com:owner/repo.git) をサポート
	if ($remoteUrl -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+)') {
		return "$($Matches.owner)/$($Matches.repo)"
	}

	return $null
}

if (-not (Test-Command -Name 'gh')) {
	throw 'GitHub CLI (gh) が見つかりません。https://cli.github.com/ を参照してインストールしてください。'
}

if (-not $Repo -and $DefaultRepo) {
	$Repo = $DefaultRepo
}

if (-not $Repo) {
	$Repo = Get-GitHubRepoFromGit
}

if (-not $Repo) {
	$Repo = Read-Host '適用対象の GitHub リポジトリ (owner/repo) を入力してください'
}

if (-not $Repo) {
	throw '対象リポジトリが特定できませんでした。-Repo "owner/repo" を指定するか、$DefaultRepo に既定値を設定してください。'
}

Write-Host "対象リポジトリ: $Repo"
if ($DryRun) {
	Write-Host '[DRY-RUN] gh CLI には適用せず、設定内容のみを表示します。' -ForegroundColor Yellow
}

function Set-GitHubVariable {
	param(
		[string]$Name,
		[string]$Value
	)

	if ($DryRun) {
		Write-Host "[DRY-RUN] gh variable set $Name --body ***" -ForegroundColor Yellow
		return
	}

	gh variable set $Name --repo $Repo --body $Value | Out-Null
	Write-Host "Variable $Name を設定しました。"
}

function Set-GitHubSecret {
	param(
		[string]$Name,
		[string]$Value
	)

	if ($DryRun) {
		Write-Host "[DRY-RUN] gh secret set $Name --body ***" -ForegroundColor Yellow
		return
	}

	gh secret set $Name --repo $Repo --body $Value | Out-Null
	Write-Host "Secret $Name を設定しました。"
}

Write-Host '--- Repository Variables ---'
foreach ($entry in $GitHubVariables.GetEnumerator()) {
	# GitGuardian API Key が空の場合はスキップしてメッセージ表示
	if ($entry.Key -eq 'GITGUARDIAN_API_KEY' -and [string]::IsNullOrWhiteSpace($entry.Value)) {
		Write-Host ''
		Write-Host '⚠️  GITGUARDIAN_API_KEY が設定されていません（スキップ）' -ForegroundColor Yellow
		Write-Host ''
		Write-Host '📋 GitGuardian API Key の取得手順:' -ForegroundColor Cyan
		Write-Host '  1. https://dashboard.gitguardian.com/api/personal-access-tokens にアクセス'
		Write-Host '  2. 新しいトークンを作成し、以下のスコープを選択:'
		Write-Host '     ✅ scan (必須)'
		Write-Host '     ✅ incident:read'
		Write-Host '     ✅ incident:write'
		Write-Host '  3. スクリプト内の GITGUARDIAN_API_KEY にトークンを設定'
		Write-Host '  4. 再度スクリプトを実行'
		Write-Host ''
		Write-Host '💡 GitGuardian を使用しない場合は、このまま続行できます。' -ForegroundColor Gray
		Write-Host '   ワークフローで GitGuardian スキャンはスキップされます。' -ForegroundColor Gray
		Write-Host ''
		continue
	}
	
	Set-GitHubVariable -Name $entry.Key -Value $entry.Value
}

Write-Host '--- Repository Secrets ---'
foreach ($entry in $GitHubSecrets.GetEnumerator()) {
	Set-GitHubSecret -Name $entry.Key -Value $entry.Value
}

Write-Host ''
Write-Host '================================' -ForegroundColor Green
Write-Host '✅ GitHub Actions の初期設定が完了しました' -ForegroundColor Green
Write-Host '================================' -ForegroundColor Green
Write-Host ''

# 設定値一覧を生成
$summary = @"
========================================
設定された Variables と Secrets の一覧
========================================
リポジトリ: $Repo

【GitHub Secrets】
"@

foreach ($entry in $GitHubSecrets.GetEnumerator() | Sort-Object Key) {
	$summary += "`n  $($entry.Key) = $($entry.Value)"
}

$summary += "`n`n【GitHub Variables】"

foreach ($entry in $GitHubVariables.GetEnumerator() | Sort-Object Key) {
	# GitGuardian API Key が空の場合はスキップ
	if ($entry.Key -eq 'GITGUARDIAN_API_KEY' -and [string]::IsNullOrWhiteSpace($entry.Value)) {
		$summary += "`n  $($entry.Key) = (未設定 - スキップされました)"
		continue
	}
	
	$maskedValue = if ($entry.Key -match 'PASSWORD|SECRET|KEY') {
		'********'
	} else {
		$entry.Value
	}
	$summary += "`n  $($entry.Key) = $maskedValue"
}

$summary += "`n`n【パスワード項目（安全な場所に保管してください）】"
$summary += "`n  VM_ADMIN_PASSWORD = $($GitHubVariables['VM_ADMIN_PASSWORD'])"
$summary += "`n  MYSQL_ROOT_PASSWORD = $($GitHubVariables['MYSQL_ROOT_PASSWORD'])"
$summary += "`n  DB_APP_PASSWORD = $($GitHubVariables['DB_APP_PASSWORD'])"
$summary += "`n  ACA_ADMIN_PASSWORD = $($GitHubVariables['ACA_ADMIN_PASSWORD'])"

# GitGuardian API Key が設定されている場合のみ表示
if (-not [string]::IsNullOrWhiteSpace($GitHubVariables['GITGUARDIAN_API_KEY'])) {
	$summary += "`n`n【GitGuardian API Key】"
	$summary += "`n  GITGUARDIAN_API_KEY = $($GitHubVariables['GITGUARDIAN_API_KEY'])"
	$summary += "`n  スコープ: scan, incident:read, incident:write"
} else {
	$summary += "`n`n【GitGuardian API Key】"
	$summary += "`n  ⚠️  未設定 - GitGuardian スキャンはスキップされます"
	$summary += "`n  取得URL: https://dashboard.gitguardian.com/api/personal-access-tokens"
	$summary += "`n  必要なスコープ: scan (必須), incident:read, incident:write"
}

$summary += "`n`n========================================`n"

# 画面に表示
Write-Host $summary -ForegroundColor Cyan

# クリップボードにコピー
try {
	$summary | Set-Clipboard
	Write-Host '📋 設定値一覧をクリップボードにコピーしました' -ForegroundColor Green
} catch {
	Write-Host '⚠️  クリップボードへのコピーに失敗しました' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '値を変更する場合は本スクリプトのテーブルを更新してください。' -ForegroundColor Gray
