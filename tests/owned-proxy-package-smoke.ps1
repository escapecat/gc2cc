[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$installer = Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw $parseErrors }
$definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-OwnedProxyPackage' }, $true)
Invoke-Expression $definition.Extent.Text
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('gc2cc-owned-package-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$bytes = [Text.Encoding]::UTF8.GetBytes('owned-test-package')
$sha = [Security.Cryptography.SHA256]::Create()
try { $digest = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
$script:downloadCount = 0
function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing)
    $script:downloadCount++
    [IO.File]::WriteAllBytes($OutFile, $bytes)
}
$package = 'https://github.com/escapecat/copilot-api/releases/download/gc2cc-v2.3.3-gc2cc.1/jeffreycao-copilot-api-2.3.3-gc2cc.1.tgz'
try {
    $resolved = Resolve-OwnedProxyPackage $package $digest $testRoot
    if ((Get-FileHash $resolved -Algorithm SHA256).Hash -ne $digest) { throw 'Wrong installed bytes' }
    $cached = Resolve-OwnedProxyPackage $package $digest $testRoot
    if ($cached -ne $resolved -or $script:downloadCount -ne 1) { throw 'Verified package cache was not reused' }
    foreach ($invalid in @('https://example.invalid/package.tgz', '@jeffreycao/copilot-api@2.3.3', ($package + '?replace=true'))) {
        try { Resolve-OwnedProxyPackage $invalid $digest $testRoot; throw 'Unexpected origin accepted' }
        catch { if ($_ -notmatch 'immutable escapecat') { throw } }
    }
    try { Resolve-OwnedProxyPackage $package ('f' * 64) $testRoot; throw 'Wrong digest accepted' }
    catch { if ($_ -notmatch 'SHA-256 mismatch') { throw } }
    if (Get-ChildItem -LiteralPath $testRoot -Filter 'download-*') { throw 'Failed download was retained' }
    if ((Get-FileHash $resolved -Algorithm SHA256).Hash -ne $digest) { throw 'Rejected update overwrote validated package' }
    try { Resolve-OwnedProxyPackage $package ('0' * 64) $testRoot; throw 'Missing digest accepted' }
    catch { if ($_ -notmatch 'pinned SHA-256') { throw } }
    Write-Host 'owned proxy package integrity and cache smoke test passed'
} finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedTestRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolvedTestRoot -Leaf) -notlike 'gc2cc-owned-package-*') { throw 'Unsafe test cleanup path' }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
