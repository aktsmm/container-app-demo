# 初回セットアップ用: GitHub Actions の Variables/Secrets に一括設定するスクリプト
# 用途: プロジェクト初回構築時や環境変数の全体リセット時に使用
# NOTE: デモ環境の利便性を優先するため平文の資格情報をハードコードしているが、本番では必ず Key Vault や GitHub Secrets などで安全に管理すること。

param(
	[string]$Repo,
	[switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# --- 設定値(必要に応じて編集) ---
$DefaultRepo = 'aktsmm/ContainerApp-demo2'

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
	ACA_ADMIN_PASSWORD       = 'P@ssw0rd!2025'
	BACKUP_CONTAINER_NAME    = 'mysql-backups'
	VM_NAME                  = 'vm-mysql-demo'
	VM_ADMIN_USERNAME        = 'test-admin'
	DB_APP_USERNAME          = 'test-admin'
	VM_ADMIN_PASSWORD        = 'P@ssw0rd!2025'
	MYSQL_ROOT_PASSWORD      = 'P@ssw0rd!2025'
	DB_APP_PASSWORD          = 'P@ssw0rd!2025'
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
	Set-GitHubVariable -Name $entry.Key -Value $entry.Value
}

Write-Host '--- Repository Secrets ---'
foreach ($entry in $GitHubSecrets.GetEnumerator()) {
	Set-GitHubSecret -Name $entry.Key -Value $entry.Value
}

Write-Host 'GitHub Actions の初期設定が完了しました。値を変更する場合は本スクリプトのテーブルを更新してください。'
