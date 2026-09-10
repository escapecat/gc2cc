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
$digest = [regex]::Match($source, "\`$ProxyPackageSha256\s*=\s*'([a-f0-9]{64})'").Groups[1].Value
if (-not $digest -or $digest -eq ('0' * 64)) { throw 'Installer does not pin a released proxy digest' }

foreach ($required in @(
    "https://github.com/escapecat/copilot-api/releases/download/gc2cc-v",
    "Resolve-OwnedProxyPackage -Package `$NpmPackage -Sha256 `$ProxyPackageSha256",
    "npm.cmd install -g `$verifiedProxyPackage",
    "Native agent sessions are still open.",
    "@openai/codex@0.149.1",
    "Name = 'useResponsesApiWebSocket'; Value = `$false",
    "'contextManagement'",
    "'responses'",
    "Join-Path `$InstallDir 'patch-copilot-api.ps1'",
    "New-ScheduledTaskPrincipal",
    "-RunLevel Highest",
    "-WindowStyle Hidden",
    "'upgrade-runtime'",
    "Install-NpmCli -Pkg `$CodexPackage -BinName 'codex' -Upgrade"
)) {
    if (-not $source.Contains($required)) {
        throw "install.ps1 is missing expected package migration behavior: $required"
    }
}

foreach ($forbidden in @(
    '@jeffreycao/copilot-api@1.14.14',
    'npm.cmd install -g $NpmPackage',
    'Resolve-CopilotPatchPath',
    'useResponsesApiContextManagement',
    'encrypted replay recovery is installed'
)) {
    if ($source.Contains($forbidden)) {
        throw "install.ps1 still contains retired compatibility behavior: $forbidden"
    }
}

Write-Host 'install package smoke test passed'
