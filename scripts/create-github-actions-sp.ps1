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
    # [必須] ロールをひもづけるサブスクリプション ID
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    # [任意] 既定ではサブスクリプション全体に割り当て。ResourceGroupName か Scope で上書き可能
    [Parameter()]
    [string]$ResourceGroupName,

    # [任意] Scope を完全修飾で指定したい場合に使用 (例: /subscriptions/<id>/resourceGroups/<name>)
    [Parameter()]
    [string]$Scope,

    # [任意] App Registration の表示名 (既定: gha-sp-secret)
    [Parameter()]
    [string]$DisplayName = 'gha-sp-secret2',

    # [任意] 付与するロール (既定: Contributor)。CI/CD ポリシーに合わせて最小権限で上書きする。
    [Parameter()]
    [string]$RoleDefinitionName = 'Contributor',

    # [任意] シークレットの有効期限 (年)。1〜5 年程度を推奨。(既定: 2年)
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

    # Service Principal の Object ID を取得
    $spObjectId = az ad sp show --id $result.appId --query id -o tsv

    return [pscustomobject]@{
        AzureClientId       = $result.appId
        AzureTenantId       = $result.tenant
        AzureSubscriptionId = $SubscriptionId
        AzureClientSecret   = $result.password
        ServicePrincipalId  = $spObjectId
        RoleScope           = $Scope
    }
}

function Set-RoleAssignmentIfMissing {
    param(
        [string]$AssigneeObjectId,
        [string]$RoleDefinitionName,
        [string]$Scope
    )

    $existing = az role assignment list `
        --assignee-object-id $AssigneeObjectId `
        --scope $Scope `
        --role $RoleDefinitionName `
        --only-show-errors | ConvertFrom-Json

    if (-not $existing -or $existing.Count -eq 0) {
        Write-Host "追加ロール '$RoleDefinitionName' を $Scope に割り当てます..."
        az role assignment create `
            --assignee-object-id $AssigneeObjectId `
            --scope $Scope `
            --role $RoleDefinitionName `
            --only-show-errors | Out-Null
    }
    else {
        Write-Verbose "ロール $RoleDefinitionName は既に $Scope に割り当て済みです。"
    }
}

Test-AzCliReady
$scopeValue = Resolve-Scope -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -Scope $Scope

# ポリシー配備を CI/CD から実行できるよう Resource Policy Contributor を自動付与する
$policyRoleDefinitionName = 'Resource Policy Contributor'
if ($ResourceGroupName) {
    $policyScopeValue = Resolve-Scope -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -Scope $null
}
elseif ($Scope -and $Scope -match '/resourceGroups/') {
    # Scope にリソースグループが含まれる場合はそのスコープを流用
    $policyScopeValue = $scopeValue
}
else {
    # RG 情報がない場合はサブスクリプションスコープで付与しておく
    $policyScopeValue = $scopeValue
}

if ($PSCmdlet.ShouldProcess("Service Principal $DisplayName", '作成とロール割り当て')) {
    $result = New-ServicePrincipalWithSecret `
        -SubscriptionId $SubscriptionId `
        -Scope $scopeValue `
        -DisplayName $DisplayName `
        -RoleDefinitionName $RoleDefinitionName `
        -SecretDurationYears $SecretDurationYears

    Set-RoleAssignmentIfMissing `
        -AssigneeObjectId $result.ServicePrincipalId `
        -RoleDefinitionName $policyRoleDefinitionName `
        -Scope $policyScopeValue

    # Managed Identity へのロール割り当てを CI/CD から実行できるよう User Access Administrator を付与する
    $userAccessAdminRoleName = 'User Access Administrator'
    Set-RoleAssignmentIfMissing `
        -AssigneeObjectId $result.ServicePrincipalId `
        -RoleDefinitionName $userAccessAdminRoleName `
        -Scope $policyScopeValue

    Write-Host ''
    Write-Host '============================================'
    Write-Host '--- setup-github-secrets_variables.ps1 に転記 ---'
    Write-Host '============================================'
    Write-Host ''
    Write-Host '$AzureCredentials = @{'
    Write-Host "`tAZURE_SUBSCRIPTION_ID = '$($result.AzureSubscriptionId)'"
    Write-Host "`tAZURE_CLIENT_ID       = '$($result.AzureClientId)'"
    Write-Host "`tAZURE_CLIENT_SECRET   = '$($result.AzureClientSecret)'"
    Write-Host "`tAZURE_TENANT_ID       = '$($result.AzureTenantId)'"
    Write-Host '}'
    Write-Host ''
    Write-Host '============================================'
    Write-Host "Scope: $($result.RoleScope)"
    Write-Host '============================================'
    Write-Host ''
    Write-Host '💡 上記の値を scripts/setup-github-secrets_variables.ps1 の $AzureCredentials に転記してください。'
}
