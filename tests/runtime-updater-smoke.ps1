[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$updater = Join-Path $repoRoot 'upgrade-runtime.ps1'
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $updater,
    [ref]$tokens,
    [ref]$errors
) | Out-Null
if ($errors) { throw "upgrade-runtime.ps1 has parser errors: $errors" }

$source = Get-Content -LiteralPath $updater -Raw
foreach ($required in @(
    "'https://escapecat.github.io/gc2cc'",
    "Write-UpgradeStatus 'waiting_for_idle'"
)) {
    if (-not $source.Contains($required)) {
        throw "Updater is missing a required safety boundary: $required"
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('gc2cc-updater-' + [guid]::NewGuid().ToString('N'))
$config = Join-Path $testRoot 'config.json'
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    @{
        pages_base_url = 'https://example.invalid/gc2cc'
        install_dir = 'C:\gc2cc'
        user_home = 'C:\Users\test'
        service_name = 'gc2cc-copilot-api'
        port = 4141
        npm_registry = 'https://packagefeedproxy.microsoft.io/npm/'
        install_clis = 'ccp,cxp'
    } | ConvertTo-Json | Set-Content -LiteralPath $config -Encoding UTF8
    try {
        & $updater -ConfigPath $config
        throw 'Updater accepted a non-allowlisted release origin'
    } catch {
        if ($_ -notmatch 'not allowlisted') { throw }
    }
    $status = Get-Content (Join-Path $testRoot 'status.json') -Raw | ConvertFrom-Json
    if ($status.state -ne 'failed' -or $status.message -notmatch 'not allowlisted') {
        throw "Updater did not persist the rejected status: $($status | ConvertTo-Json -Compress)"
    }
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'runtime updater smoke test passed'
