[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repoRoot 'install.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $installer,
    [ref]$tokens,
    [ref]$errors
)
if ($errors) { throw "install.ps1 has parser errors: $errors" }

foreach ($functionName in @(
    'Get-NssmConfigurationMismatches'
)) {
    $function = $ast.Find(
        {
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
        },
        $true
    )
    if (-not $function) { throw "$functionName was not found." }
    Invoke-Expression $function.Extent.Text
}

$service = [pscustomobject]@{
    DisplayName = 'gc2cc Copilot API proxy (gctest231)'
    ObjectName = 'LocalSystem'
    Start = 2
}
$parameters = [pscustomobject]@{
    Application = 'C:\Program Files\nodejs\node.exe'
    AppParameters = 'C:\gc2cc\dist\main.js start --port 4141'
    AppDirectory = 'C:\gc2cc'
    AppEnvironmentExtra = @(
        'USERPROFILE=C:\Users\test',
        'HOME=C:\Users\test',
        'NODE_OPTIONS=--no-warnings'
    )
    AppStdout = 'C:\gc2cc\logs\copilot-api.log'
    AppStderr = 'C:\gc2cc\logs\copilot-api.log'
    AppRestartDelay = 1000
    AppRotateFiles = 1
    AppRotateOnline = 1
    AppRotateBytes = 5242880
}
$arguments = @{
    Service = $service
    Parameters = $parameters
    ExitAction = 'Restart'
    ExpectedDisplayName = 'gc2cc Copilot API proxy (gctest231)'
    ExpectedApplication = 'C:\Program Files\nodejs\node.exe'
    ExpectedArguments = 'C:\gc2cc\dist\main.js start --port 4141'
    ExpectedDirectory = 'C:\gc2cc'
    ExpectedUserHome = 'C:\Users\test'
    ExpectedLog = 'C:\gc2cc\logs\copilot-api.log'
}
$valid = @(Get-NssmConfigurationMismatches @arguments)
if ($valid.Count -ne 0) { throw "Valid NSSM configuration was rejected: $valid" }

$parameters.AppParameters = 'C:\gc2cc\dist\main.js start --port 9999'
$invalid = @(Get-NssmConfigurationMismatches @arguments)
if ($invalid.Count -ne 1 -or $invalid[0] -notmatch 'AppParameters') {
    throw "Invalid NSSM arguments were not detected: $invalid"
}

Write-Host 'NSSM configuration smoke test passed'
