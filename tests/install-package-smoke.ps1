[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repoRoot 'install.ps1'
$source = Get-Content -LiteralPath $installer -Raw
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $installer,
    [ref]$tokens,
    [ref]$errors
) | Out-Null
if ($errors) { throw "install.ps1 has parser errors: $errors" }

foreach ($required in @(
    "@jeffreycao/copilot-api@2.3.3",
    "Name = 'useResponsesApiWebSocket'; Value = `$false",
    "'contextManagement'",
    "'responses'",
    "Join-Path `$InstallDir 'patch-copilot-api.ps1'"
)) {
    if (-not $source.Contains($required)) {
        throw "install.ps1 is missing expected 2.3.1 migration behavior: $required"
    }
}

foreach ($forbidden in @(
    '@jeffreycao/copilot-api@1.14.14',
    'Resolve-CopilotPatchPath',
    'useResponsesApiContextManagement',
    'encrypted replay recovery is installed'
)) {
    if ($source.Contains($forbidden)) {
        throw "install.ps1 still contains retired compatibility behavior: $forbidden"
    }
}

Write-Host 'install package smoke test passed'
