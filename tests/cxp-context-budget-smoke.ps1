#Requires -Version 5.1
param([string]$WrapperPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'cxp.ps1'))
$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($wrapperPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw $parseErrors[0].Message }
foreach ($definition in $ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $false)) {
    Invoke-Expression $definition.Extent.Text
}

function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -ne $Expected) { throw "$Label`: expected '$Expected', got '$Actual'." }
}

$base = 'http://fixture.invalid'
# Synthetic limits exercise the budget independently of live model availability.
$script:fixtureModels = @(
    @{ id = 'gpt-5.5'; capabilities = @{ limits = @{
        max_context_window_tokens = 1178000; max_prompt_tokens = 1050000; max_output_tokens = 128000
    } } },
    @{ id = 'gpt-5.4'; capabilities = @{ limits = @{
        max_context_window_tokens = 1050000; max_prompt_tokens = 922000; max_output_tokens = 128000
    } } }
)
function Invoke-WebRequest { return @{ Content = (@{ data = $script:fixtureModels } | ConvertTo-Json -Depth 10) } }
$models = Get-AvailableModels
$largeModel = $models | Where-Object id -eq 'gpt-5.5'
Assert-Equal $largeModel.maxPrompt 1050000 'Provider input limit survives discovery'

$budget = Get-CodexContextBudget $largeModel
Assert-Equal $budget.contextWindow 1178000 'Real context window is preserved'
Assert-Equal $budget.inputLimit 1050000 'Input ceiling'
Assert-Equal $budget.autoCompactLimit 840000 'Compaction reserves twenty percent of input capacity'
if ($budget.autoCompactLimit -ge $budget.inputLimit) { throw 'Compaction would begin after the input ceiling.' }
if (940000 -lt $budget.autoCompactLimit) { throw 'A near-limit session still would not compact.' }

$smallerModel = $models | Where-Object id -eq 'gpt-5.4'
Assert-Equal (Get-CodexContextBudget $smallerModel).autoCompactLimit 737600 'Sibling model uses its own input limit'
Assert-Equal (Get-CodexContextBudget ([pscustomobject]@{ctx=200000;maxOut=50000})).inputLimit 150000 'Missing prompt limit reserves output'
Assert-Equal (Get-CodexContextBudget ([pscustomobject]@{ctx=200000;maxPrompt=190000;maxOut=50000})).inputLimit 150000 'Combined window also constrains input'
Assert-Equal (Get-CodexContextBudget ([pscustomobject]@{ctx=200000;maxPrompt=120000;maxOut=50000})).inputLimit 120000 'Stricter prompt limit wins'
Assert-Equal (Get-CodexContextBudget ([pscustomobject]@{ctx=200000})).autoCompactLimit 160000 'Missing output metadata remains bounded'
Assert-Equal (Get-CodexContextBudget ([pscustomobject]@{ctx=0})) $null 'Missing context leaves native defaults'
$invalidRejected = $false
try { Get-CodexContextBudget ([pscustomobject]@{ctx=100;maxOut=100}) | Out-Null } catch { $invalidRejected = $true }
Assert-Equal $invalidRejected $true 'Impossible metadata fails closed'

$baseModel = [pscustomobject]@{
    slug = 'gpt-5.4'; display_name = 'GPT-5.4'; base_instructions = 'fixture instructions'
    context_window = 272000; max_context_window = 272000; auto_compact_token_limit = 258400
}
$catalog = @(Merge-CodexCatalogModels @($baseModel) $models)
foreach ($meta in $models) {
    $entry = $catalog | Where-Object slug -eq $meta.id
    $expected = Get-CodexContextBudget $meta
    Assert-Equal $entry.context_window $expected.contextWindow 'Catalog context'
    Assert-Equal $entry.max_context_window $expected.contextWindow 'Catalog max context'
    Assert-Equal $entry.auto_compact_token_limit $expected.autoCompactLimit 'Catalog compaction threshold'
    Assert-Equal $entry.base_instructions 'fixture instructions' 'Catalog preserves native instructions'
    $arguments = @(Get-CodexContextArguments $meta)
    if ($arguments -notcontains "model_auto_compact_token_limit=$($expected.autoCompactLimit)") { throw 'Launch/catalog threshold drift.' }
    if ($arguments -notcontains 'model_auto_compact_token_limit_scope="total"') { throw 'Preserved prefix is excluded from the trigger.' }
}

$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('gc2cc-context-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory | Out-Null
try {
    $codexHome = $testDirectory
    $testConfig = Join-Path $testDirectory 'config.toml'
    [IO.File]::WriteAllText($testConfig, "model_auto_compact_token_limit_scope = `"body_after_prefix`"`n[model_providers.fixture]`nname = `"fixture`"`n")
    Set-CodexTomlOverrides (Join-Path $testDirectory 'catalog.json')
    $config = Get-Content -Raw -LiteralPath $testConfig
    if ($config -notmatch 'model_auto_compact_token_limit_scope = "total"') { throw 'Managed TOML still excludes the prefix.' }
    if ($config -match 'body_after_prefix') { throw 'Stale scope remains in managed TOML.' }
    if ($config -notmatch 'name = "fixture"') { throw 'Unrelated provider configuration changed.' }
    Set-CodexTomlOverrides (Join-Path $testDirectory 'catalog.json')
    Assert-Equal (Get-Content -Raw -LiteralPath $testConfig) $config 'Config update is idempotent'

    function Write-CodexCatalog { return (Join-Path $testDirectory 'catalog.json') }
    function codex { $script:capturedLaunchArguments = @($args) }
    $savedCodeHome = $env:CODEX_HOME
    $savedApiKey = $env:OPENAI_API_KEY
    try {
        Invoke-CodexWithModel 'gpt-5.5' @{reasoningEfforts=@{};bypassPermissions=$false} @('app-server') $null
    } finally {
        $env:CODEX_HOME = $savedCodeHome
        $env:OPENAI_API_KEY = $savedApiKey
    }
    if ($script:capturedLaunchArguments -notcontains 'model_auto_compact_token_limit=840000') { throw 'Actual launch uses a stale threshold.' }
    if ($script:capturedLaunchArguments -notcontains 'model_auto_compact_token_limit_scope="total"') { throw 'Actual launch excludes the prefix.' }
    if ($script:capturedLaunchArguments -notcontains 'model_context_window=1178000') { throw 'Actual launch changes the real window.' }
    if ($script:capturedLaunchArguments -notcontains 'app-server') { throw 'Launch dropped the requested native operation.' }
} finally {
    $resolvedTest = [IO.Path]::GetFullPath($testDirectory)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if ([IO.Path]::GetDirectoryName($resolvedTest) -ne $expectedParent -or [IO.Path]::GetFileName($resolvedTest) -notmatch '^gc2cc-context-test-[0-9a-f]{32}$') {
        throw 'Refusing to remove an unexpected test directory.'
    }
    Remove-Item -LiteralPath $resolvedTest -Recurse -Force
}
Write-Host 'CXP context budget behavior tests passed (no model or production runtime invoked).'
