#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $env:ProgramData 'gc2cc-updater\config.json')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-UpgradeStatus {
    param([string] $State, [string] $Message = '')
    $directory = Split-Path $ConfigPath
    $statusPath = Join-Path $directory 'status.json'
    $temporary = "$statusPath.tmp"
    [ordered]@{
        state = $State
        message = $Message
        updated_at = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $statusPath -Force
}

try {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Updater configuration is missing: $ConfigPath"
    }
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($required in @('pages_base_url', 'install_dir', 'user_home', 'service_name', 'port', 'npm_registry', 'install_clis')) {
        if (-not $config.$required) { throw "Updater configuration is missing '$required'" }
    }
    if ([string]$config.pages_base_url -ne 'https://escapecat.github.io/gc2cc') {
        throw 'Updater pages_base_url is not allowlisted'
    }

    Write-UpgradeStatus 'preparing'
    $active = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('codex.exe', 'claude.exe')
    })
    if ($active.Count -gt 0) {
        Write-UpgradeStatus 'waiting_for_idle' "Waiting for $($active.Count) active Agent process(es)"
        exit 2
    }

    $directory = Split-Path $ConfigPath
    $installer = Join-Path $directory 'install.ps1'
    Invoke-WebRequest `
        -Uri "$($config.pages_base_url)/install.ps1?updater=$([DateTime]::UtcNow.Ticks)" `
        -OutFile $installer `
        -UseBasicParsing
    Write-UpgradeStatus 'installing'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer `
        -Port ([int]$config.port) `
        -ServiceName ([string]$config.service_name) `
        -InstallDir ([string]$config.install_dir) `
        -NpmRegistry ([string]$config.npm_registry) `
        -PagesBaseUrl ([string]$config.pages_base_url) `
        -UserHome ([string]$config.user_home) `
        -InstallClis ([string]$config.install_clis) `
        -NonInteractive `
        -Elevated
    if ($LASTEXITCODE -ne 0) { throw "gc2cc installer exited with $LASTEXITCODE" }
    $packagePath = Join-Path $config.install_dir 'npm\global\node_modules\@jeffreycao\copilot-api\package.json'
    $version = if (Test-Path -LiteralPath $packagePath) {
        (Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json).version
    } else { 'unknown' }
    Write-UpgradeStatus 'completed' "copilot-api $version"
} catch {
    Write-UpgradeStatus 'failed' ([string]$_)
    throw
}
