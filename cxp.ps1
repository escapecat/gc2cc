# cxp -- OpenAI Codex CLI routed through caozhiyuan/copilot-api on http://localhost:4141.
# Mirror of ccp.ps1 but for `codex` instead of `claude`. Zero-pollution: uses an
# isolated CODEX_HOME under %LOCALAPPDATA%\gc2cc\codex-home\ so the user's own
# ~/.codex/config.toml (if any) is never touched.
#
# The provider definition lives in $env:CODEX_HOME\config.toml (written by
# install.ps1), pointing at the local copilot-api proxy with wire_api="responses".
#
# Usage:
#   cxp [-Model <id>] [codex args...]
#   cxp config                           Interactive: pick default model and
#                                        toggle danger-full-access/no-approval.
#   cxp restart proxy                    Force-restart the copilot-api service.
#   cxp upgrade                          Re-run the gc2cc one-liner installer.
#   cxp --help                           Show usage.
#
# Config: ~/.local/share/gc2cc/cxp.json
#   {
#     "defaultModel": "gpt-5.5",          // null = always prompt
#     "bypassPermissions": true            // pass --sandbox danger-full-access
#                                           // and --ask-for-approval never
#   }

$base       = 'http://localhost:4141'
$pagesBase  = 'https://escapecat.github.io/gc2cc'
$configPath = Join-Path $HOME '.local\share\gc2cc\cxp.json'
$codexHome  = Join-Path $env:LOCALAPPDATA 'gc2cc\codex-home'
$proxyService = 'gc2cc-copilot-api'
$script:cxpPipelineInput = if ($MyInvocation.ExpectingInput) { @($input) } else { $null }

function Get-WindowsPowerShellExe {
    $candidates = @()
    if ($env:SystemRoot) { $candidates += (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') }
    if ($env:WINDIR)     { $candidates += (Join-Path $env:WINDIR     'System32\WindowsPowerShell\v1.0\powershell.exe') }
    if ($PSHOME)         { $candidates += (Join-Path $PSHOME 'powershell.exe') }
    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return 'powershell.exe'
}

# ---------- config ----------
function Load-CxpConfig {
    # User-facing keys: defaultModel, bypassPermissions, reasoningEfforts
    # Internal cache keys (managed by Test-UpdateAvailable / Invoke-CxpUpgrade,
    # not surfaced except through the update banner): updateCheckAt, updateAvailable.
    #
    # reasoningEfforts: per-model map (id -> effort). Levels are constrained to
    # each model's upstream /v1/models capabilities at config time. Stored as a
    # PSCustomObject when round-tripped through JSON, normalized to a hashtable
    # on load so callers can index/assign uniformly.
    $defaults = @{
        defaultModel      = $null
        bypassPermissions = $true
        reasoningEfforts  = @{}
        updateCheckAt     = $null
        updateAvailable   = $false
    }
    if (-not (Test-Path $configPath)) { return $defaults }
    try {
        $loaded = Get-Content $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        Write-Warning "[cxp] $configPath is invalid JSON; using defaults"
        return $defaults
    }
    foreach ($k in 'defaultModel','bypassPermissions','updateCheckAt','updateAvailable') {
        if ($loaded.PSObject.Properties.Name -contains $k) {
            $defaults[$k] = $loaded.$k
        }
    }
    if ($loaded.PSObject.Properties.Name -contains 'reasoningEfforts' -and $loaded.reasoningEfforts) {
        $map = @{}
        foreach ($p in $loaded.reasoningEfforts.PSObject.Properties) { $map[$p.Name] = $p.Value }
        $defaults['reasoningEfforts'] = $map
    }
    return $defaults
}

function Save-CxpConfig($cfg) {
    $dir = Split-Path $configPath -Parent
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $cfg | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
}

function Test-HasCodexArg {
    param(
        [object[]]$argv,
        [string[]]$names
    )
    foreach ($tok in $argv) {
        $s = [string]$tok
        foreach ($name in $names) {
            if ($s -eq $name -or $s.StartsWith($name + '=')) { return $true }
        }
    }
    return $false
}

# ---------- update check (24h-cached) ----------
function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToUpper() }
    finally { $sha.Dispose() }
}

function Get-OnlineCxpHash {
    try {
        $resp = Invoke-WebRequest "$pagesBase/cxp.ps1" -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop
        $bytes = $resp.Content
        if ($bytes -isnot [byte[]]) { $bytes = [Text.Encoding]::UTF8.GetBytes($bytes) }
        return Get-Sha256Hex $bytes
    } catch { return $null }
}

function Get-LocalCxpHash {
    if (-not $PSCommandPath -or -not (Test-Path $PSCommandPath)) { return $null }
    return Get-Sha256Hex ([System.IO.File]::ReadAllBytes($PSCommandPath))
}

function Test-UpdateAvailable($cfg) {
    $now = (Get-Date).ToUniversalTime()
    if ($cfg.updateCheckAt) {
        try {
            $lastCheck = [datetime]::Parse($cfg.updateCheckAt).ToUniversalTime()
            if (($now - $lastCheck).TotalHours -lt 24 -and ($now - $lastCheck).TotalHours -ge 0) {
                return [bool]$cfg.updateAvailable
            }
        } catch {}
    }
    $online = Get-OnlineCxpHash
    if (-not $online) { return [bool]$cfg.updateAvailable }
    $local = Get-LocalCxpHash
    $available = ($local -and ($online -ne $local))
    $cfg.updateCheckAt   = $now.ToString('o')
    $cfg.updateAvailable = $available
    try { Save-CxpConfig $cfg } catch {}
    return $available
}

# ---------- proxy + model discovery ----------
function Test-Proxy {
    try {
        Invoke-WebRequest "$base/v1/models" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop | Out-Null
        return $true
    } catch { return $false }
}

function Restart-ProxyWithNssm {
    $nssm = Join-Path $env:LOCALAPPDATA 'gc2cc\bin\nssm.exe'
    if (-not (Test-Path $nssm)) {
        Write-Warning "[cxp] nssm.exe not found at $nssm; cannot restart $proxyService"
        return $false
    }

    Write-Host "[cxp] trying NSSM restart/start for $proxyService..." -ForegroundColor Yellow
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($action in @('restart', 'start')) {
            & $nssm $action $proxyService 2>&1 | Out-Host
            if ($LASTEXITCODE -eq 0) { return $true }
        }
    } finally {
        $ErrorActionPreference = $prev
    }

    Write-Host "[cxp] NSSM restart needs elevation; requesting UAC..." -ForegroundColor Yellow
    try {
        $nssmEsc = $nssm -replace "'", "''"
        $serviceEsc = $proxyService -replace "'", "''"
        # Propagate NSSM's final exit code to this process. Start-Process itself
        # succeeds as soon as the elevated child launches, even if NSSM fails.
        $cmd = "& '$nssmEsc' restart '$serviceEsc'; if (`$LASTEXITCODE -ne 0) { & '$nssmEsc' start '$serviceEsc' }; exit `$LASTEXITCODE"
        $restartProcess = Start-Process (Get-WindowsPowerShellExe) -Verb RunAs -Wait -PassThru -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-Command', $cmd
        ) -ErrorAction Stop
        if ($restartProcess.ExitCode -ne 0) {
            Write-Warning "[cxp] elevated NSSM restart/start failed (exit $($restartProcess.ExitCode))."
            return $false
        }
        return $true
    } catch {
        Write-Warning "[cxp] NSSM restart failed or was cancelled: $_"
        return $false
    }
}

function Restart-ProxyAndWait {
    if (-not (Restart-ProxyWithNssm)) { return $false }

    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-Proxy) {
            return $true
        }
    }
    return $false
}

function Ensure-Proxy {
    if (Test-Proxy) { return $true }
    Write-Host "[cxp] copilot-api is not reachable." -ForegroundColor Yellow
    $restarted = Restart-ProxyAndWait
    if ($restarted) { Write-Host "[cxp] copilot-api is reachable again." -ForegroundColor Green }
    return $restarted
}

function Invoke-CxpProxyRestart {
    Write-Host "[cxp] force-restarting copilot-api proxy..." -ForegroundColor Cyan
    if (Restart-ProxyAndWait) {
        Write-Host "[cxp] copilot-api proxy restarted and is reachable at $base." -ForegroundColor Green
        return
    }
    Write-Error "[cxp] copilot-api restart failed or the proxy did not become reachable at $base within 30 seconds."
}

# Sort key: family bucket first (smaller = higher priority), then version
# descending within bucket (so gpt-5.5 outranks 5.4 automatically when GitHub
# rolls out new SKUs -- no cxp edit needed). cxp's tier order favors OpenAI
# families first since codex is an OpenAI CLI; Anthropic/Gemini come after.
function Get-ModelRank($id) {
    $tier = switch -regex ($id) {
        '^gpt-5(?:\.\d+)?-codex' { 150; break }
        '^gpt-5(?:\.\d+)?-mini'  { 700; break }
        '^gpt-5-mini'       { 700; break }
        '^gpt-5\.'          { 100; break }
        '^claude-opus-'     { 200; break }
        '^claude-sonnet-'   { 300; break }
        '^gemini-3\.'       { 400; break }
        '^gemini-'          { 500; break }
        '^claude-haiku-'    { 600; break }
        '^gpt-4\.'          { 900; break }
        default             { 999 }
    }
    $major = 0; $minor = 0
    if ($id -match '(?:opus|sonnet|haiku|gpt|gemini)-(\d+)(?:\.(\d+))?') {
        $major = [int]$matches[1]
        if ($matches[2]) { $minor = [int]$matches[2] }
    }
    return $tier * 10000 + (1000 - $major * 100 - $minor)
}

# Same filter rules as ccp -- the upstream /v1/models is shared. Additional cxp-
# only filter: drop models that don't expose an OpenAI `/v1/responses` endpoint
# (Anthropic-native models do not), since `wire_api = "chat"` is no longer
# supported by codex.
function Get-AvailableModels {
    $raw = (Invoke-WebRequest "$base/v1/models" -TimeoutSec 4 -UseBasicParsing).Content
    $drop = @(
        '^accounts/msft/',
        '^text-embedding-',
        '-embedding\b', '-inference$',
        '^gpt-3\.5', '^gpt-4-0', '^gpt-4-o-',
        '^gpt-4o-2024-', '^gpt-4o-mini-2024-', '^gpt-4\.1-2025-',
        '^gpt-4$',
        '^gpt-41-copilot$',
        '^claude-',                        # cxp-only: no /v1/responses for Claude
        '^lark-',                          # router shim, not chat
        '^gemini-2\.5-'
    )
    $dropOwners  = @('Experimental','Fireworks')
    $stripSuffix = '(?:\[1m\]|-1m(?:-internal)?|-(high|xhigh))$'

    $entries = ($raw | ConvertFrom-Json).data | ForEach-Object {
        if ($dropOwners -contains $_.owned_by) { return }
        foreach ($p in $drop) { if ($_.id -match $p) { return } }
        $clean = $_.id
        while ($clean -match $stripSuffix) { $clean = $clean -replace $stripSuffix, '' }
        [pscustomobject]@{
            id      = $clean
            owner   = $_.owned_by
            efforts = $_.capabilities.supports.reasoning_effort
            ctx     = $_.capabilities.limits.max_context_window_tokens
            maxPrompt = $_.capabilities.limits.max_prompt_tokens
            maxOut  = $_.capabilities.limits.max_output_tokens
        }
    }
    # Dedup by id explicitly. We can't use `Sort-Object id -Unique` here: with an
    # array-valued property (efforts) it merges the property across duplicate
    # rows. Also do NOT keep the first duplicate blindly: suffix stripping can
    # collapse a standard SKU and a 1M SKU into the same clean id, and whichever
    # one the proxy lists first would otherwise decide Codex's context window.
    # Keep the row with the largest advertised context instead.
    $bestById = @{}
    foreach ($e in $entries) {
        if (-not $bestById.ContainsKey($e.id)) {
            $bestById[$e.id] = $e
            continue
        }
        $cur = $bestById[$e.id]
        $curCtx = if ($cur.ctx) { [int64]$cur.ctx } else { 0 }
        $newCtx = if ($e.ctx) { [int64]$e.ctx } else { 0 }
        if ($newCtx -gt $curCtx) { $bestById[$e.id] = $e }
    }
    $unique = $bestById.Values
    return ,($unique | Sort-Object @{e={Get-ModelRank $_.id}}, id)
}

# ---------- subcommands ----------
function Show-Help {
    $cur = Load-CxpConfig
    $curDefault = if ($cur.defaultModel) { $cur.defaultModel } else { '(none -- always prompt)' }
    Write-Host @"
cxp -- OpenAI Codex CLI routed through caozhiyuan/copilot-api on $base

Usage:
  cxp [-Model <id>] [codex args...]    Launch codex. -Model skips the picker.
  cxp config                           Interactive: pick default model and
                                       toggle danger-full-access/no-approval.
  cxp restart proxy                    Force-restart copilot-api, then wait
                                       until its health endpoint responds.
  cxp upgrade                          Re-run the gc2cc one-liner installer.
  cxp ccsm                             Register cxp as a launchable CLI in
                                       ccsm (~/.ccsm/config.json).
  cxp --help                           Show this help.

Isolated CODEX_HOME: $codexHome
  (Your own ~/.codex/config.toml is never touched.)
Config file: $configPath
Current settings:
  defaultModel      = $curDefault
  bypassPermissions = $($cur.bypassPermissions)
"@
}

# Interactive effort picker for one model, constrained to that model's
# upstream-supported levels (capabilities.supports.reasoning_effort from
# /v1/models). The proxy forwards Codex's reasoning.effort untouched, and Codex
# itself passes the -c value through without validating, so the real ceiling is
# the upstream model's own list (e.g. gpt-5.5 supports up to xhigh; gpt-5-mini
# only to high). Returns the chosen effort, or $null for "unset / Codex default".
function Read-EffortChoice($model, $supported, $current) {
    if (-not $supported -or $supported.Count -eq 0) {
        Write-Host ("  ({0} advertises no reasoning_effort levels; skipping)" -f $model) -ForegroundColor DarkGray
        return $current
    }
    Write-Host ''
    Write-Host ("Reasoning effort for {0} (Enter to keep current):" -f $model) -ForegroundColor Cyan
    Write-Host '  [ 0] (unset -- use Codex default)'
    for ($i = 0; $i -lt $supported.Count; $i++) {
        $marker = if ($current -eq $supported[$i]) { ' *current*' } else { '' }
        Write-Host ('  [{0,2}] {1}{2}' -f ($i + 1), $supported[$i], $marker)
    }
    $pick = Read-Host 'Number'
    if ([string]::IsNullOrWhiteSpace($pick)) { return $current }
    $idx = [int]$pick - 1
    if ($idx -eq -1) { return $null }
    if ($idx -ge 0 -and $idx -lt $supported.Count) { return $supported[$idx] }
    Write-Warning '[cxp] invalid effort choice; keeping current'
    return $current
}

function Invoke-CxpConfig {
    if (-not (Ensure-Proxy)) {
        Write-Error "[cxp] copilot-api not reachable at $base after NSSM restart attempt. Check: Get-Service gc2cc-copilot-api"
        return
    }
    $config = Load-CxpConfig
    $curDefault = if ($config.defaultModel) { $config.defaultModel } else { '(none -- always prompt)' }
    Write-Host ''
    Write-Host "Current config ($configPath):" -ForegroundColor Cyan
    Write-Host ('  defaultModel      = {0}' -f $curDefault)
    Write-Host ('  bypassPermissions = {0}' -f $config.bypassPermissions)
    Write-Host ''

    $models = Get-AvailableModels
    Write-Host 'Pick a default model (Enter to keep current):' -ForegroundColor Cyan
    Write-Host '  [ 0] (none -- always prompt at cxp launch)'
    for ($i = 0; $i -lt $models.Count; $i++) {
        $marker = if ($config.defaultModel -eq $models[$i].id) { ' *current*' } else { '' }
        Write-Host ('  [{0,2}] {1}{2}' -f ($i + 1), $models[$i].id, $marker)
    }
    $pick = Read-Host 'Number'
    if (-not [string]::IsNullOrWhiteSpace($pick)) {
        $idx = [int]$pick - 1
        if ($idx -eq -1) {
            $config.defaultModel = $null
        } elseif ($idx -ge 0 -and $idx -lt $models.Count) {
            $config.defaultModel = $models[$idx].id
        } else {
            Write-Warning '[cxp] invalid choice; keeping current'
        }
    }

    # If a concrete default model is set, let the user pick its reasoning effort,
    # constrained to that model's upstream-supported levels.
    if ($config.defaultModel) {
        if (-not ($config.reasoningEfforts -is [hashtable])) { $config.reasoningEfforts = @{} }
        $cur = $config.reasoningEfforts[$config.defaultModel]
        $selected = $models | Where-Object { $_.id -eq $config.defaultModel } | Select-Object -First 1
        $eff = Read-EffortChoice $config.defaultModel $selected.efforts $cur
        if ($eff) {
            $config.reasoningEfforts[$config.defaultModel] = $eff
        } elseif ($config.reasoningEfforts.ContainsKey($config.defaultModel)) {
            $config.reasoningEfforts.Remove($config.defaultModel)
        }
    }

    Write-Host ''
    $bypassDefault = if ($config.bypassPermissions) { 'Y' } else { 'N' }
    $bp = Read-Host ('Bypass permissions (--sandbox danger-full-access --ask-for-approval never)? [Y/N, default {0}]' -f $bypassDefault)
    if (-not [string]::IsNullOrWhiteSpace($bp)) {
        $config.bypassPermissions = ($bp.Trim() -match '^[Yy]')
    }

    Save-CxpConfig $config
    $newDefault = if ($config.defaultModel) { $config.defaultModel } else { '(none -- always prompt)' }
    Write-Host ''
    Write-Host "Saved to $configPath" -ForegroundColor Green
    Write-Host ('  defaultModel      = {0}' -f $newDefault)
    Write-Host ('  bypassPermissions = {0}' -f $config.bypassPermissions)
    if ($config.defaultModel -and $config.reasoningEfforts[$config.defaultModel]) {
        Write-Host ('  reasoningEffort   = {0}' -f $config.reasoningEfforts[$config.defaultModel])
    }
}

function Invoke-CxpUpgrade {
    Write-Host "[cxp] Fetching latest installer from $pagesBase/install.ps1 ..." -ForegroundColor Cyan
    $b = (Invoke-WebRequest "$pagesBase/install.ps1" -UseBasicParsing).Content
    if ($b -is [byte[]]) { $b = [Text.Encoding]::UTF8.GetString($b) }
    Invoke-Expression $b
    try {
        $cfg = Load-CxpConfig
        $cfg.updateCheckAt   = (Get-Date).ToUniversalTime().ToString('o')
        $cfg.updateAvailable = $false
        Save-CxpConfig $cfg
    } catch {}
}

# ---------- ccsm integration ----------
# Register this wrapper (cxp.cmd) as a CLI in ccsm's config.json so ccsm's
# Launch page can spawn it directly. ccsm runs a .cmd via its shell:'direct'
# strategy (cmd.exe /d /s /c <path>), and uses the `type` field to pick the
# matching resume templates. If ccsm is running, update through its own
# /api/config so the live backend owns the write. If it is offline, write
# ~/.ccsm/config.json directly. CCSM_HOME is honoured in both paths.
function Get-CcsmHome {
    if ($env:CCSM_HOME) { return $env:CCSM_HOME }
    return (Join-Path $HOME '.ccsm')
}

function Get-CcsmPreferredPort {
    $cfg = Join-Path (Get-CcsmHome) 'config.json'
    if (Test-Path $cfg) {
        try {
            $j = Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.port) { return [int]$j.port }
        } catch {}
    }
    return 7777
}

function Test-CcsmHealth([int]$Port) {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$Port/api/health" -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop
        $j = $r.Content | ConvertFrom-Json
        return ($j.name -eq '@bakapiano/ccsm')
    } catch {
        return $false
    }
}

function Get-RunningCcsmPort {
    $preferred = Get-CcsmPreferredPort
    $ports = @($preferred)
    for ($i = 1; $i -le 9; $i++) { $ports += ($preferred + $i) }

    foreach ($port in $ports) {
        if (Test-CcsmHealth $port) { return $port }
    }
    return $null
}

function Set-CcsmCliEntry($cfg, $entry, [string]$id) {
    $existing = @()
    if (($cfg.PSObject.Properties.Name -contains 'clis') -and $cfg.clis) {
        $existing = @($cfg.clis | Where-Object { $_.id -ne $id })
    }
    $clis = @($existing + $entry)
    if ($cfg.PSObject.Properties.Name -contains 'clis') {
        $cfg.clis = $clis
    } else {
        $cfg | Add-Member -NotePropertyName 'clis' -NotePropertyValue $clis
    }
    return $cfg
}

function Save-CcsmCliEntry($ccsmHome, $ccsmCfg, $entry, [string]$id) {
    $runningPort = Get-RunningCcsmPort
    if ($runningPort) {
        $baseUrl = "http://localhost:$runningPort"
        Write-Host "[cxp] ccsm is running on port $runningPort; updating config through /api/config." -ForegroundColor Cyan
        try {
            $cfg = (Invoke-WebRequest -Uri "$baseUrl/api/config" -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop).Content | ConvertFrom-Json
            $cfg = Set-CcsmCliEntry $cfg $entry $id
            $json = $cfg | ConvertTo-Json -Depth 50
            Invoke-WebRequest -Uri "$baseUrl/api/config" -Method PUT -Body $json -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop | Out-Null
            return "api:$runningPort"
        } catch {
            Write-Error "[cxp] failed to update running ccsm via ${baseUrl}: $_"
            return $null
        }
    }

    if (Test-Path $ccsmCfg) {
        try {
            $cfg = Get-Content $ccsmCfg -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-Error "[cxp] $ccsmCfg is invalid JSON; refusing to overwrite. Fix or remove it, then re-run 'cxp ccsm'."
            return $null
        }
    } else {
        New-Item -ItemType Directory -Force -Path $ccsmHome | Out-Null
        $cfg = [pscustomobject]@{}
    }

    $cfg = Set-CcsmCliEntry $cfg $entry $id
    try {
        $json = $cfg | ConvertTo-Json -Depth 50
        [System.IO.File]::WriteAllText($ccsmCfg, $json, (New-Object System.Text.UTF8Encoding $false))
        return 'file'
    } catch {
        Write-Error "[cxp] failed to write ${ccsmCfg}: $_"
        return $null
    }
}

function Invoke-CxpCcsmSetup {
    $ccsmHome = if ($env:CCSM_HOME) { $env:CCSM_HOME } else { Join-Path $HOME '.ccsm' }
    $ccsmCfg  = Join-Path $ccsmHome 'config.json'

    # The .cmd shim sits next to this script (the gc2cc bin dir). Prefer the
    # script's own dir; fall back to the canonical install location.
    $cmdPath = Join-Path $PSScriptRoot 'cxp.cmd'
    if (-not (Test-Path $cmdPath)) {
        $cmdPath = Join-Path $env:LOCALAPPDATA 'gc2cc\bin\cxp.cmd'
    }
    if (-not (Test-Path $cmdPath)) {
        Write-Warning "[cxp] cxp.cmd not found (looked in $PSScriptRoot and %LOCALAPPDATA%\gc2cc\bin). Registering the path anyway: $cmdPath"
    }

    # shell='direct': ccsm's resolveCommand sees the .cmd extension and runs it
    # via cmd.exe /d /s /c, appending resume args after. type='codex' selects
    # Codex-style resume templates (resume --last / resume).
    $entry = [pscustomobject][ordered]@{
        id               = 'cxp'
        name             = 'cxp (gc2cc Codex)'
        command          = $cmdPath
        args             = @()
        resumeLatestArgs = @('resume', '--last')
        resumePickerArgs = @('resume')
        shell            = 'direct'
        type             = 'codex'
    }

    $saveMode = Save-CcsmCliEntry $ccsmHome $ccsmCfg $entry 'cxp'
    if (-not $saveMode) { return }

    Write-Host ''
    Write-Host "[cxp] Registered 'cxp' as a ccsm CLI." -ForegroundColor Green
    Write-Host ('  config : {0}' -f $ccsmCfg)
    Write-Host ('  command: {0}' -f $cmdPath)
    Write-Host  '  type   : codex (resume: resume --last / resume)'
    Write-Host ''
    if ($saveMode -like 'api:*') {
        Write-Host "[cxp] ccsm is still running; refresh the ccsm page if the Launch picker is already open." -ForegroundColor Yellow
    } else {
        Write-Host "[cxp] Start ccsm to see it on the Launch page." -ForegroundColor Yellow
    }
}

# ---------- model picker ----------
function Invoke-ModelPicker {
    $models = Get-AvailableModels
    if (-not $models -or $models.Count -eq 0) {
        Write-Warning '[cxp] no models matched after filtering. Falling back to free-form prompt.'
        $main = Read-Host 'Enter model id'
        if ([string]::IsNullOrWhiteSpace($main)) { return $null }
        return $main
    }
    Write-Host ''
    Write-Host 'Pick a model:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $models.Count; $i++) {
        Write-Host ('  [{0,2}] {1}' -f ($i + 1), $models[$i].id)
    }
    $pick = Read-Host 'Number (default 1)'
    if ([string]::IsNullOrWhiteSpace($pick)) { $pick = '1' }
    $idx = [int]$pick - 1
    if ($idx -lt 0 -or $idx -ge $models.Count) {
        Write-Error '[cxp] invalid choice'
        return $null
    }
    return $models[$idx].id
}

# ---------- model catalog ----------
# Generate a complete, self-contained model catalog for codex's
# StaticModelsManager, patching each model's context window to the value the
# proxy actually reports. This is what delivers a true 1M window: codex clamps
# `-c model_context_window` to the bundled max_context_window (272K), but a
# catalog file sets BOTH context_window and max_context_window directly, so the
# 1M lands un-clamped. The catalog is also the persistent source codex's
# auto-compact trigger reads each turn, so the window survives compaction.
# We still pass matching `model_context_window`,
# `model_auto_compact_token_limit`, and `model_auto_compact_token_limit_scope`
# startup overrides below, because Codex's session config path is the final
# source for the full-context compaction scope.
#
# Source: `codex debug models` (codex's own ModelsResponse), NOT a hand-written
# file or a download. codex emits every field correctly — including the
# mandatory ~21KB base_instructions per model — and it tracks the installed
# codex version automatically.
#
# auto_compact_token_limit is patched too so both Codex's model metadata and
# session config paths agree on the same trigger.
function Get-CodexContextBudget($metadata) {
    if (-not $metadata -or -not $metadata.ctx) { return $null }
    $contextWindow = [int64]$metadata.ctx
    $maxOutput = [math]::Max(0, [int64]$metadata.maxOut)
    $inputLimit = $contextWindow - $maxOutput
    if ([int64]$metadata.maxPrompt -gt 0) {
        $inputLimit = [math]::Min($inputLimit, [int64]$metadata.maxPrompt)
    }
    if ($inputLimit -le 0) { throw '[cxp] Provider token limits leave no capacity for input.' }
    # Compaction also has to fit the input limit. Leave room for new tool output
    # and accounting differences; the combined input/output window is not that limit.
    return [pscustomobject]@{
        contextWindow = $contextWindow
        inputLimit = [int64]$inputLimit
        autoCompactLimit = [math]::Max(1, [int64][math]::Floor($inputLimit * 0.8))
    }
}

function Get-CodexContextArguments($metadata) {
    $budget = Get-CodexContextBudget $metadata
    if (-not $budget) { return }
    return @(
        '-c', "model_context_window=$($budget.contextWindow)",
        '-c', "model_auto_compact_token_limit=$($budget.autoCompactLimit)",
        '-c', 'model_auto_compact_token_limit_scope="total"'
    )
}

function Set-CodexCatalogModelLimits($model, $metadata) {
    $budget = Get-CodexContextBudget $metadata
    $model | Add-Member -MemberType NoteProperty -Name context_window -Value $budget.contextWindow -Force
    $model | Add-Member -MemberType NoteProperty -Name max_context_window -Value $budget.contextWindow -Force
    $model | Add-Member -MemberType NoteProperty -Name auto_compact_token_limit `
        -Value $budget.autoCompactLimit -Force
}

function Get-CodexCatalogTemplate($catalogModels, $modelId) {
    if ($modelId -notmatch '^gpt-\d+(?:\.\d+)?(?:-|$)') { return $null }

    $versionStem = if ($modelId -match '^(gpt-\d+(?:\.\d+)?)') { $matches[1] } else { return $null }
    $wantMini = $modelId -match '-mini(?:-|$)'
    $sameVersion = $catalogModels | Where-Object {
        ($_.slug -eq $versionStem -or $_.slug.StartsWith($versionStem + '-')) -and
        ([bool]($_.slug -match '-mini(?:-|$)')) -eq $wantMini
    } | Select-Object -First 1
    if ($sameVersion) { return $sameVersion }

    return $catalogModels | Where-Object {
        $_.slug -match '^gpt-\d+(?:\.\d+)?(?:-|$)' -and
        ([bool]($_.slug -match '-mini(?:-|$)')) -eq $wantMini
    } | Select-Object -First 1
}

function Get-CodexCatalogDisplayName($modelId) {
    return (($modelId -split '-') | ForEach-Object {
        if ($_ -eq 'gpt') { 'GPT' }
        elseif ($_.Length -gt 0) { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }
    }) -join '-'
}

function Merge-CodexCatalogModels($catalogModels, $models) {
    $merged = @($catalogModels)
    foreach ($model in $merged) {
        $hit = $models | Where-Object { $_.id -eq $model.slug } | Select-Object -First 1
        if ($hit -and $hit.ctx) {
            Set-CodexCatalogModelLimits $model $hit
        }
    }

    # GitHub can expose a new GPT SKU before the installed Codex version has
    # that slug in its bundled catalog. A startup model_context_window override
    # then appears to work only until compact/resume reloads model metadata and
    # falls back to Codex's 272K default (258.4K effective). Clone a compatible
    # bundled entry so the generated catalog covers that rollout gap. Using
    # Codex's own entry keeps its schema and base instructions version-matched.
    foreach ($hit in $models) {
        if (-not $hit.ctx) { continue }
        if ($merged | Where-Object { $_.slug -eq $hit.id } | Select-Object -First 1) { continue }
        $template = Get-CodexCatalogTemplate $merged $hit.id
        if (-not $template) { continue }
        $clone = ($template | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json
        $clone.slug = $hit.id
        $clone.display_name = Get-CodexCatalogDisplayName $hit.id
        Set-CodexCatalogModelLimits $clone $hit
        $merged += $clone
    }
    return $merged
}

function Write-CodexCatalog($models) {
    $catalogPath = Join-Path $codexHome 'catalog.json'
    try {
        # Generate the bundled model list from a THROWAWAY CODEX_HOME that has no
        # model_catalog_json. codex 0.142+ loads model_catalog_json even for
        # `debug models`, so running it against our real $codexHome makes codex
        # merge the existing catalog's base_instructions back into its output;
        # cxp then writes that back and EACH run doubles base_instructions
        # (21KB -> ~21MB after ~10 runs -> a 1.5GB catalog that OOMs codex on
        # load: "Error loading configuration: out of memory"). A clean temp home
        # breaks the feedback loop -- codex always reports its pristine bundled
        # models, never our patched catalog.
        $tmpHome = Join-Path ([System.IO.Path]::GetTempPath()) ('cxp-cat-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tmpHome | Out-Null
        $minimalCfg = @"
model_provider = "gc2cc"
model = "gpt-5.5"
[model_providers.gc2cc]
name = "OpenAI"
base_url = "$base/v1"
wire_api = "responses"
env_key = "OPENAI_API_KEY"
requires_openai_auth = false
"@
        [System.IO.File]::WriteAllText((Join-Path $tmpHome 'config.toml'), $minimalCfg, (New-Object System.Text.UTF8Encoding $false))
        $savedHome = $env:CODEX_HOME
        $env:CODEX_HOME = $tmpHome
        try {
            $raw = & codex debug models 2>$null | Out-String
        } finally {
            $env:CODEX_HOME = $savedHome
            Remove-Item -Recurse -Force $tmpHome -ErrorAction SilentlyContinue
        }
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        # Sanity cap: a healthy `codex debug models` is ~200KB. If it is wildly
        # larger, the feedback loop somehow re-armed -- refuse to write rather
        # than persist a multi-MB catalog that bricks codex.
        if ($raw.Length -gt 5MB) {
            Write-Warning "[cxp] codex debug models returned $([int]($raw.Length/1MB))MB (expected ~0.2MB); skipping catalog to avoid OOM loop."
            return $null
        }
        $cat = $raw | ConvertFrom-Json
        if (-not $cat.models) { return $null }
        $cat.models = @(Merge-CodexCatalogModels $cat.models $models)
        # -Depth 100: ModelInfo is deeply nested; the default depth (2) would
        # stringify nested arrays/objects and corrupt the file. Write UTF-8
        # without BOM so serde_json doesn't choke on a leading byte-order mark.
        $json = $cat | ConvertTo-Json -Depth 100 -Compress
        [System.IO.File]::WriteAllText($catalogPath, $json, (New-Object System.Text.UTF8Encoding $false))
        return $catalogPath
    } catch {
        return $null
    }
}

function Set-CodexTomlOverrides($catalogPath) {
    $cfgPath = Join-Path $codexHome 'config.toml'
    if (-not (Test-Path $cfgPath)) { return }
    $catalogToml = ($catalogPath -replace '\\', '/')
    $managed = @(
        ('model_catalog_json = "{0}"' -f $catalogToml),
        'model_auto_compact_token_limit_scope = "total"'
    ) -join "`r`n"

    $raw = Get-Content $cfgPath -Raw
    $raw = [Regex]::Replace($raw, '(?m)^\s*model_catalog_json\s*=.*\r?\n?', '')
    $raw = [Regex]::Replace($raw, '(?m)^\s*model_auto_compact_token_limit_scope\s*=.*\r?\n?', '')
    $sectionIdx = $raw.IndexOf("`n[")
    if ($sectionIdx -lt 0) {
        $updated = $raw.TrimEnd() + "`r`n" + $managed + "`r`n"
    } else {
        $head = $raw.Substring(0, $sectionIdx).TrimEnd()
        $tail = $raw.Substring($sectionIdx)
        $updated = $head + "`r`n" + $managed + $tail
    }
    if ($updated -ne $raw) {
        [System.IO.File]::WriteAllText($cfgPath, $updated, (New-Object System.Text.UTF8Encoding $false))
    }
}

# ---------- codex exec ----------
function Invoke-CodexWithModel($mainModel, $cfg, $passthrough, $stdinInput) {
    if (-not (Test-Path (Join-Path $codexHome 'config.toml'))) {
        Write-Error "[cxp] $codexHome\config.toml not found. Re-run the gc2cc installer."
        return
    }
    # Isolation: CODEX_HOME redirects codex to gc2cc-managed config dir, leaving
    # the user's ~/.codex untouched. OPENAI_API_KEY=dummy satisfies the provider's
    # env_key requirement (the proxy doesn't care what we send).
    $env:CODEX_HOME     = $codexHome
    $env:OPENAI_API_KEY = 'dummy'

    # `-c model=<id>` overrides the toml's `model` for this invocation only.
    # The proxy forwards Codex's reasoning.effort untouched on the /v1/responses
    # path, so an optional `-c model_reasoning_effort=<v>` is the real lever.
    $codexArgs = @("-c", "model=`"$mainModel`"")
    $eff = if ($cfg.reasoningEfforts -is [hashtable]) { $cfg.reasoningEfforts[$mainModel] } else { $null }
    if ($eff) {
        $codexArgs += @("-c", "model_reasoning_effort=`"$eff`"")
    }
    # Codex clamps `-c model_context_window=N` to the model's max_context_window.
    # The catalog raises that max to the proxy's real /v1/models limit; after
    # that, matching config overrides keep the live session's context window and
    # auto-compact threshold aligned with the patched metadata.
    # NB: assign to $models first. Get-AvailableModels returns a comma-wrapped
    # array (`,(...)`); piping it straight into Where-Object passes the whole
    # array as a single $_, so $meta.ctx member-enumerates into an Object[].
    $models = Get-AvailableModels
    $meta = $models | Where-Object { $_.id -eq $mainModel } | Select-Object -First 1
    $catalogPath = Write-CodexCatalog $models
    if ($catalogPath) {
        Set-CodexTomlOverrides $catalogPath
        # TOML parses the `-c` value; a Windows '\' path triggers invalid escape
        # errors (\U, \g ...). Forward slashes are accepted by Rust on Windows
        # and need no escaping in TOML.
        $catalogToml = ($catalogPath -replace '\\', '/')
        $codexArgs += @("-c", "model_catalog_json=`"$catalogToml`"")
    } else {
        # No catalog this run: strip any stale model_catalog_json line so codex
        # doesn't abort with "cannot find the file" / OOM on a leftover path.
        $cfgPath = Join-Path $codexHome 'config.toml'
        if (Test-Path $cfgPath) {
            $rawCfg = Get-Content $cfgPath -Raw
            $stripped = [Regex]::Replace($rawCfg, '(?m)^\s*model_catalog_json\s*=.*\r?\n?', '')
            if ($stripped -ne $rawCfg) {
                [System.IO.File]::WriteAllText($cfgPath, $stripped, (New-Object System.Text.UTF8Encoding $false))
            }
        }
    }
    $contextBudget = Get-CodexContextBudget $meta
    $autoCompactLimit = if ($contextBudget) { $contextBudget.autoCompactLimit } else { $null }
    $codexArgs += @(Get-CodexContextArguments $meta)
    if ($meta.maxOut) { $codexArgs += @("-c", "model_max_output_tokens=$($meta.maxOut)") }
    $bypassEnabled = [bool]$cfg.bypassPermissions
    if ($bypassEnabled) {
        $hasBypass = Test-HasCodexArg -argv $passthrough -names @('--dangerously-bypass-approvals-and-sandbox','--yolo')
        $hasSandbox = Test-HasCodexArg -argv $passthrough -names @('--sandbox','-s')
        $hasApproval = Test-HasCodexArg -argv $passthrough -names @('--ask-for-approval','-a')
        if (-not $hasBypass -and -not $hasSandbox) {
            $codexArgs += @('--sandbox', 'danger-full-access')
        }
        if (-not $hasBypass -and -not $hasApproval) {
            $codexArgs += @('--ask-for-approval', 'never')
        }
    }
    $effNote = if ($eff) { $eff } else { '(codex default)' }
    $ctxNote = if ($meta.ctx) { '{0}K' -f [int]($meta.ctx / 1000) } else { '?' }
    $inputNote = if ($contextBudget) { '{0}K' -f [int]($contextBudget.inputLimit / 1000) } else { '?' }
    $compactNote = if ($autoCompactLimit) { '{0}K' -f [int]($autoCompactLimit / 1000) } else { '?' }
    $catNote = if ($catalogPath) { 'catalog' } else { 'bundled(272K cap)' }
    $bypassNote = if ($bypassEnabled) { 'on' } else { 'off' }
    Write-Host ('[cxp] model={0}  effort={1}  bypass={2}  ctx={3}  autoCompactAt={4}  compactScope=total  via={5}  CODEX_HOME={6}  inputLimit={7}' -f $mainModel, $effNote, $bypassNote, $ctxNote, $compactNote, $catNote, $codexHome, $inputNote) -ForegroundColor Cyan
    if ($null -ne $stdinInput) {
        $stdinInput | & codex @codexArgs @passthrough
    } else {
        & codex @codexArgs @passthrough
    }
}

# ---------- dispatch ----------
if ($args.Count -gt 0) {
    switch ($args[0]) {
        '--help'  { Show-Help;        return }
        '-h'      { Show-Help;        return }
        '-Help'   { Show-Help;        return }
        'help'    { Show-Help;        return }
        'config'  { Invoke-CxpConfig; return }
        'restart' {
            if ($args.Count -ne 2 -or $args[1] -ne 'proxy') {
                Write-Error '[cxp] usage: cxp restart proxy'
                return
            }
            Invoke-CxpProxyRestart
            return
        }
        'upgrade' { Invoke-CxpUpgrade; return }
        'ccsm'    { Invoke-CxpCcsmSetup; return }
    }
}

$passthrough = @()
$modelOverride = $null
$skipNext = $false
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($skipNext) { $skipNext = $false; continue }
    $a = $args[$i]
    if ($a -in @('-Model','-model','-Mode','-mode')) {
        if ($i + 1 -ge $args.Count) {
            Write-Error '[cxp] -Model requires a value'
            return
        }
        $modelOverride = $args[$i + 1]
        $skipNext = $true
    } elseif ($a -eq '--') {
        $passthrough += $args[($i + 1)..($args.Count - 1)]
        break
    } else {
        $passthrough += $a
    }
}

if (-not (Ensure-Proxy)) {
    Write-Error "[cxp] copilot-api not reachable at $base after NSSM restart attempt. Check: Get-Service gc2cc-copilot-api"
    return
}

if (-not (Test-Path $configPath)) {
    Write-Host ''
    Write-Host "[cxp] No config found at $configPath -- first-run setup." -ForegroundColor Cyan
    Write-Host "[cxp] You can re-run this any time with 'cxp config'." -ForegroundColor Cyan
    Invoke-CxpConfig
    Write-Host ''
}

$config = Load-CxpConfig

if (Test-UpdateAvailable $config) {
    Write-Host "[cxp] gc2cc has updates available -- run 'cxp upgrade' to refresh" -ForegroundColor Yellow
}

$main = $modelOverride
if (-not $main) { $main = $config.defaultModel }
if (-not $main) {
    $main = Invoke-ModelPicker
    if (-not $main) { return }
}

Invoke-CodexWithModel -mainModel $main -cfg $config -passthrough $passthrough -stdinInput $script:cxpPipelineInput
