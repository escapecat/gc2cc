[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$patchScript = Join-Path $repoRoot 'patch-copilot-api.ps1'
$installedRoot = Join-Path $env:LOCALAPPDATA 'gc2cc\npm\global\node_modules\@jeffreycao\copilot-api'
if (-not (Test-Path -LiteralPath $installedRoot)) { throw "Test fixture source not installed: $installedRoot" }

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('gc2cc-patch-smoke-' + [guid]::NewGuid().ToString('N'))
Copy-Item -LiteralPath $installedRoot -Destination $testRoot -Recurse
try {
    $bundle = Get-ChildItem -LiteralPath (Join-Path $testRoot 'dist') -Filter 'server-*.js' -File
    & $patchScript -PackageRoot $testRoot
    $firstHash = (Get-FileHash -LiteralPath $bundle.FullName -Algorithm SHA256).Hash
    & $patchScript -PackageRoot $testRoot
    $secondHash = (Get-FileHash -LiteralPath $bundle.FullName -Algorithm SHA256).Hash
    if ($firstHash -ne $secondHash) { throw 'Patch is not idempotent.' }

    $patched = Get-Content -LiteralPath $bundle.FullName -Raw
    foreach ($required in @(
        'gc2cc encrypted replay recovery v2',
        'GC2CC_MAX_ENCRYPTED_REPLAY_RETRIES = 32',
        'isGc2ccEncryptedReplayHttpResponse',
        'retrying HTTP after removing ${removedCount} oldest encrypted item(s)',
        '!outputStarted && isGc2ccEncryptedReplayError',
        'removeOldestGc2ccEncryptedReplayItem',
        'retrying after removing ${removedCount} oldest encrypted item(s)'
    )) {
        if (-not $patched.Contains($required)) { throw "Patched bundle is missing: $required" }
    }
    & node --check $bundle.FullName
    if ($LASTEXITCODE -ne 0) { throw 'Patched JavaScript failed node --check.' }
    & node (Join-Path $PSScriptRoot 'encrypted-replay-recovery-behavior.mjs') $bundle.FullName
    if ($LASTEXITCODE -ne 0) { throw 'Encrypted replay recovery behavior test failed.' }
    Write-Host 'patch-copilot-api smoke test passed'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
