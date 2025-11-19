# ignore/環境情報.md の値を GitHub Actions の Variables/Secrets に同期するスクリプト

Param (
    [string]$EnvFilePath = "ignore/環境情報.md"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -Path $EnvFilePath)) {
    throw "環境情報ファイル $EnvFilePath が見つかりません"
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) が見つかりません。インストール後に再実行してください"
}

$content = Get-Content -Path $EnvFilePath

function Get-CodeValue {
    Param (
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    $line = $content | Where-Object { $_ -match [Regex]::Escape($Key) } | Select-Object -First 1
    if (-not $line) {
        throw "キー $Key が $EnvFilePath に見つかりません"
    }

    $plain = ($line -replace '[`]', '').Trim()
    $plain = $plain.TrimStart('-').Trim()
    $parts = $plain.Split('=', 2)
    if ($parts.Count -lt 2) {
        throw "キー $Key の値を解析できません"
    }

    return $parts[1].Trim()
}

$variableKeys = @(
    'AZURE_CLIENT_ID',
    'AZURE_CLIENT_SECRET',
    'AZURE_TENANT_ID',
    'RESOURCE_GROUP_NAME',
    'LOCATION',
    'ACR_NAME_PREFIX',
    'STORAGE_ACCOUNT_PREFIX',
    'AKS_CLUSTER_NAME',
    'ACA_ENVIRONMENT_NAME',
    'ADMIN_CONTAINER_APP_NAME',
    'DB_ENDPOINT',
    'BACKUP_CONTAINER_NAME',
    'VM_NAME',
    'VM_ADMIN_USERNAME',
    'VM_ADMIN_PASSWORD',
    'DB_APP_USERNAME',
    'DB_APP_PASSWORD',
    'MYSQL_ROOT_PASSWORD',
    'GH_PAT_ACTIONS_DELETE'
)

$secretKeys = @(
    'AZURE_SUBSCRIPTION_ID'
)

foreach ($key in $variableKeys) {
    $value = Get-CodeValue -Key $key
    gh variable set $key --body $value | Out-Null
    Write-Host "✅ Variable $key を設定しました"
}

foreach ($key in $secretKeys) {
    $value = Get-CodeValue -Key $key
    gh secret set $key --body $value | Out-Null
    Write-Host "✅ Secret $key を設定しました"
}
