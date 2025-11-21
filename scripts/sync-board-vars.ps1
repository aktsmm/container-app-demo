[CmdletBinding()]
param(
    [string]$ParametersFile = (Join-Path $PSScriptRoot '../infra/parameters/main-dev.parameters.json'),
    [string]$OutputFile = (Join-Path $PSScriptRoot '../app/board-app/k8s/vars.env')
)

# パラメータファイルから Namespace と Ingress Host を読み出して vars.env を更新する補助スクリプト
if (-not (Test-Path -Path $ParametersFile)) {
    throw "Parameters file not found: $ParametersFile"
}

$raw = Get-Content -Path $ParametersFile -Raw | ConvertFrom-Json
$namespace = $raw.parameters.boardAppNamespace.value
$ingressHost = $raw.parameters.boardAppIngressHost.value

if ([string]::IsNullOrWhiteSpace($namespace)) {
    throw 'boardAppNamespace is empty in the parameters file.'
}

if ([string]::IsNullOrWhiteSpace($ingressHost)) {
    throw 'boardAppIngressHost is empty in the parameters file.'
}

$content = @(
    '# このファイルは scripts/sync-board-vars.ps1 で自動生成されます',
    "kubernetesNamespace=$namespace",
    "ingressHost=$ingressHost"
)

Set-Content -Path $OutputFile -Value $content -Encoding utf8NoBOM
