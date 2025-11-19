<#
このスクリプトは GitHub Actions から Azure へ接続するための Service Principal (クライアントシークレット方式) を作成します。
主な処理:
1. 指定スコープで Service Principal を作成
2. ロールを割り当て
3. GitHub Actions に設定すべき `AZURE_CLIENT_ID` などの値を出力
4. シークレットの有効期限 (年数) を任意に設定可能
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # ロールをひもづけるサブスクリプション ID
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    # 既定ではサブスクリプション全体に割り当て。ResourceGroupName か Scope で上書き可能
    [Parameter()]
    [string]$ResourceGroupName,

    # Scope を完全修飾で指定したい場合に使用 (例: /subscriptions/<id>/resourceGroups/<name>)
    [Parameter()]
    [string]$Scope,

    # App Registration の表示名
    [Parameter()]
    [string]$DisplayName = 'gha-sp-secret',

    # 付与するロール (既定: Contributor)。CI/CD ポリシーに合わせて最小権限で上書きする。
    [Parameter()]
    [string]$RoleDefinitionName = 'Contributor',

    # シークレットの有効期限 (年)。1〜5 年程度を推奨。
    [Parameter()]
    [ValidateRange(1, 5)]
    [int]$SecretDurationYears = 2
)

function Test-AzCliReady {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) が見つかりません。https://learn.microsoft.com/cli/azure/install-azure-cli を参照してインストールしてください。'
    }

    az account show 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Azure CLI にサインインしていません。事前に az login を実行してください。'
    }
}

function Resolve-Scope {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$Scope
    )

    if ($Scope) {
        return $Scope
    }

    if ($ResourceGroupName) {
        $groupId = az group show --name $ResourceGroupName --subscription $SubscriptionId --query id -o tsv
        if (-not $groupId) {
            throw "指定のリソースグループ $ResourceGroupName が見つかりません。"
        }
        return $groupId
    }

    return "/subscriptions/$SubscriptionId"
}

function New-ServicePrincipalWithSecret {
    param(
        [string]$SubscriptionId,
        [string]$Scope,
        [string]$DisplayName,
        [string]$RoleDefinitionName,
        [int]$SecretDurationYears
    )

    az account set --subscription $SubscriptionId | Out-Null

    $result = az ad sp create-for-rbac `
        --name $DisplayName `
        --role $RoleDefinitionName `
        --scopes $Scope `
        --years $SecretDurationYears `
        --only-show-errors | ConvertFrom-Json

    if (-not $result) {
        throw 'Service Principal の作成に失敗しました。権限と名前の重複を確認してください。'
    }

    return [pscustomobject]@{
        AzureClientId       = $result.appId
        AzureTenantId       = $result.tenant
        AzureSubscriptionId = $SubscriptionId
        AzureClientSecret   = $result.password
        ServicePrincipalId  = $result.objectId
        RoleScope           = $Scope
    }
}

Test-AzCliReady
$scopeValue = Resolve-Scope -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -Scope $Scope

if ($PSCmdlet.ShouldProcess("Service Principal $DisplayName", '作成とロール割り当て')) {
    $result = New-ServicePrincipalWithSecret `
        -SubscriptionId $SubscriptionId `
        -Scope $scopeValue `
        -DisplayName $DisplayName `
        -RoleDefinitionName $RoleDefinitionName `
        -SecretDurationYears $SecretDurationYears

    Write-Host '--- GitHub Actions に設定するシークレット ---'
    Write-Host "AZURE_CLIENT_ID = $($result.AzureClientId)"
    Write-Host "AZURE_TENANT_ID = $($result.AzureTenantId)"
    Write-Host "AZURE_SUBSCRIPTION_ID = $($result.AzureSubscriptionId)"
    Write-Host "AZURE_CLIENT_SECRET = $($result.AzureClientSecret)"
    Write-Host '----------------------------------------'
    Write-Host 'Scope:' $result.RoleScope
}
