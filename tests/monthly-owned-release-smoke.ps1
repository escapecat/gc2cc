[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$workflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/monthly-copilot-api-update.yml') -Raw
$match = [regex]::Match($workflow, '(?s)- name: Update the pinned version.*?run: \|\r?\n(?<code>.*?)(?=\r?\n      - name: Run offline smoke tests)')
if (-not $match.Success) { throw 'Owned release update step missing' }
$code = $match.Groups['code'].Value -replace '(?m)^          ', ''
$source = Get-Content -LiteralPath (Join-Path $repoRoot 'install.ps1') -Raw
$current = [regex]::Match($source, 'gc2cc-v(\d+\.\d+\.\d+-gc2cc\.\d+)').Groups[1].Value
$latest = '99.0.0-gc2cc.1'
$digest = '1' * 64
$code = $code.Replace('${{ steps.version.outputs.current }}', $current).Replace('${{ steps.version.outputs.latest }}', $latest).Replace('${{ steps.version.outputs.digest }}', $digest)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('gc2cc-release-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    Copy-Item -LiteralPath (Join-Path $repoRoot 'install.ps1') -Destination (Join-Path $testRoot 'install.ps1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination (Join-Path $testRoot 'README.md')
    Push-Location $testRoot
    try { Invoke-Expression $code } finally { Pop-Location }
    $updated = Get-Content -LiteralPath (Join-Path $testRoot 'install.ps1') -Raw
    $actual = [regex]::Match($updated, "\`$ProxyPackageSha256\s*=\s*'([a-f0-9]{64})'").Groups[1].Value
    if ($actual -ne $digest -or -not $updated.Contains("gc2cc-v$latest/jeffreycao-copilot-api-$latest.tgz")) {
        throw 'Update did not keep owned version and digest together'
    }
    if (-not (Get-Content -LiteralPath (Join-Path $testRoot 'README.md') -Raw).Contains($latest)) { throw 'Version documentation not updated' }
    Write-Host 'monthly owned release version/digest update smoke test passed'
} finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedTestRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolvedTestRoot -Leaf) -notlike 'gc2cc-release-test-*') { throw 'Unsafe test cleanup path' }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
