# gc2cc

[![Stars](https://img.shields.io/github/stars/escapecat/gc2cc?style=flat&logo=github)](https://github.com/escapecat/gc2cc/stargazers)
[![Installs](https://img.shields.io/github/downloads/escapecat/gc2cc/install-counter/gc2cc-install-counter.txt?label=installs&color=blue)](https://github.com/escapecat/gc2cc/releases/tag/install-counter)
[![NSSM downloads](https://img.shields.io/github/downloads/escapecat/gc2cc/nssm-2.24/nssm-2.24.zip?label=nssm.zip%20pulls&color=gray)](https://github.com/escapecat/gc2cc/releases/tag/nssm-2.24)
[![Last commit](https://img.shields.io/github/last-commit/escapecat/gc2cc?label=last%20commit)](https://github.com/escapecat/gc2cc/commits/main)

Run **Claude Code** *or* **OpenAI Codex CLI** backed by **GitHub Copilot's models** on Windows, with a one-line installer.

What this gives you:

- A Windows Service (`gc2cc-copilot-api`, managed via [NSSM](https://nssm.cc/)) that auto-starts at boot, runs as `LocalSystem` in the background, and auto-restarts on crash. It proxies GitHub Copilot to an OpenAI/Anthropic-compatible endpoint on `http://localhost:4141`.
- A `ccp` command **on user PATH** that picks a model and launches `claude --dangerously-skip-permissions` against the proxy. Works in any shell — PS 5.1, PS 7, VSCode terminal, cmd. No profile editing.
- A `cxp` command (optional, opt-in at install) that does the same for [`@openai/codex`](https://github.com/openai/codex). Uses an **isolated `CODEX_HOME`** under `%LOCALAPPDATA%\gc2cc\codex-home\`, so your own `~/.codex/config.toml` is never touched. Only OpenAI-Responses-capable models (gpt-5.x, gpt-5-codex, gemini-3.x) are listed, since `wire_api = "chat"` is no longer supported by codex.
- At install time you pick which wrappers to deploy (ccp, cxp, both, or neither).
- The `ccp.cmd` / `cxp.cmd` shims invoke Windows PowerShell by absolute system path, so they keep working even in shells whose PATH has not refreshed after install.
- The model menu is **built dynamically** from the proxy's `/v1/models` — restart the service and any new Copilot model (gpt-5.5, gpt-5.6, claude-opus-4.8, …) shows up automatically. No need to bump `ccp.ps1`.
- The proxy is [`caozhiyuan/copilot-api`](https://github.com/caozhiyuan/copilot-api) (a.k.a. `@jeffreycao/copilot-api` on npm) — the actively maintained fork of `ericc-ch/copilot-api`. Translates between Anthropic Messages / OpenAI Chat Completions / OpenAI Responses APIs so 1M-context Claude models, gpt-5.5 / 5.4 / 5.3-codex, and Anthropic-native features (`interleaved-thinking`, `advanced-tool-use`, `context-management`) all work end-to-end through Claude Code.

## Install

```powershell
irm https://escapecat.github.io/gc2cc/install.ps1 | iex
```

The installer needs **Administrator** (Windows Services live in `HKLM\SYSTEM\...\Services` + the SCM). Run the one-liner from a normal shell — it self-elevates via UAC, you'll see one prompt, and the elevated instance does the work.

The installer will:

1. Self-elevate via UAC if needed (re-fetches `install.ps1` into `%TEMP%` and relaunches `-Verb RunAs`).
2. Install missing prereqs (`node`, `winget`) — `git` and `bun` are no longer required.
3. Read and print the global npm source (`npm config get registry --location=global`); every package install explicitly uses that URL via `--registry`.
4. Download `nssm.exe` from our GitHub Release mirror into `%LOCALAPPDATA%\gc2cc\bin\` (with `nssm.cc` as fallback).
5. `npm install -g @jeffreycao/copilot-api@2.3.3` into a private prefix at `%LOCALAPPDATA%\gc2cc\npm\global\` (so the LocalSystem service has a stable path independent of the user's npm prefix).
6. Prompt you once for **GitHub Copilot device-code auth** (skipped on re-runs if a token is already present).
7. Register the `gc2cc-copilot-api` Windows Service (LocalSystem, auto-start, crash-restart, NSSM-native log rotation at 5 MB) and start it.
8. `npm install -g @anthropic-ai/claude-code` into your *user* npm prefix.
9. Install the pinned stable `@openai/codex@0.149.1` when `cxp` is selected.
10. Drop `ccp.ps1` + `ccp.cmd` into `%LOCALAPPDATA%\gc2cc\bin\` and add that dir to your **user PATH** (HKCU).

Open a **fresh** shell after install so PATH refreshes.

### Re-running install (upgrade-safe)

`install.ps1` is idempotent and tolerates every prior gc2cc layout we've ever shipped:

- **Pre-NSSM Scheduled Task** (`\gc2cc\gc2cc-copilot-api`): stopped and unregistered.
- **NSSM + bakapiano (git clone + bun)**: stale `copilot-api/` and `run-proxy.ps1` are deleted; the service is removed and re-registered to exec `node` on the new npm-installed `@jeffreycao/copilot-api` entrypoint.
- **GitHub Copilot auth token** stays put — both forks use `~/.local/share/copilot-api/github_token`, so you don't re-auth on upgrade.

If you've ever installed gc2cc, you can re-run the one-liner and it converges. No `uninstall.ps1` needed for upgrades.

### Service account & the GitHub token

The service runs as `LocalSystem`, but Copilot's auth token lives under the *invoking* user's home (`%USERPROFILE%\.local\share\copilot-api\github_token`). The installer sets `nssm AppEnvironmentExtra USERPROFILE=<your-home> HOME=<your-home>` so Node's `os.homedir()` inside the proxy resolves back to your real home — no token copy, no symlinks. Trade-off vs binding the service to your user account: no stored password in LSA, no service breakage when you rotate your password.

## Usage

```powershell
ccp                                   # pick a Copilot-backed model, then Claude Code
ccp --resume                          # any extra args are forwarded to claude
ccp -p "say hi"                       # one-shot via claude -p
ccp -Model gpt-5.5 -p "..."           # skip the picker; -Model accepts -model/-Mode/-mode too
ccp -- --help                         # `--` forwards the rest to claude (so `ccp --help` stays ccp)
ccp --help                            # show ccp usage + current settings

ccp config                            # interactive: pick default model + toggle bypass-permissions
ccp restart proxy                     # force-restart the local copilot-api proxy (UAC may pop)
ccp upgrade                           # re-run the gc2cc one-liner installer (UAC will pop)
ccp ccsm                              # register ccp in ccsm without stopping ccsm

cxp                                   # same idea but for OpenAI Codex CLI
cxp -Model gpt-5.5 -- exec "say hi"   # `--` forwards the rest to codex
cxp config                            # interactive: pick default model + toggle Codex bypass permissions
cxp restart proxy                     # same forced proxy restart + health check
cxp ccsm                              # register cxp in ccsm without stopping ccsm
cxp --help                            # show cxp usage + current settings
```

`cxp` uses an isolated `CODEX_HOME` at `%LOCALAPPDATA%\gc2cc\codex-home\` — codex's own state (project trust, NUX flags, etc.) lands there, never in your user `~/.codex`. Only models that expose `/v1/responses` are listed (Anthropic-native Claude models are filtered out, since codex dropped `wire_api = "chat"`). On launch it patches Codex's model catalog from the proxy's `/v1/models` limits and prints `ctx` plus `autoCompactAt`; for 1M-capable GPT models you should see about `ctx=1050K autoCompactAt=945K`, not the bundled ~272K window. By default, `cxp` also launches Codex with `--sandbox danger-full-access --ask-for-approval never`; use `cxp config` to turn that off.

The managed provider's display name is intentionally `OpenAI`. `copilot-api`
requires that exact identity for Codex encrypted Responses/tool-content and
compaction-cache compatibility; changing it can make a resumed session fail
with `Encrypted function output content could not be decrypted or decoded`
([copilot-api#339](https://github.com/caozhiyuan/copilot-api/issues/339)).

`ccp ccsm` and `cxp ccsm` register the wrappers as launchable CLIs in ccsm. If
ccsm is running, they update it through ccsm's own `/api/config` endpoint; if it
is offline, they edit `~/.ccsm/config.json` directly. They do not stop ccsm.

On launch, `ccp` and `cxp` probe `http://localhost:4141/v1/models`. If the
proxy is not reachable, they try to recover the Windows Service with
`%LOCALAPPDATA%\gc2cc\bin\nssm.exe restart gc2cc-copilot-api`, falling back to
`start` if needed. If service control needs elevation, a UAC prompt is shown;
after that they wait up to 30 seconds for the proxy to come back before failing.
Use `ccp restart proxy` or `cxp restart proxy` to force the same restart and
health-check flow even while the proxy is currently reachable.

The installer also tunes the shared `copilot-api` config for Codex stability:

```json
{
  "contextManagement": {
    "responses": false
  },
  "useResponsesApiWebSocket": false
}
```

`contextManagement.responses=false` leaves compaction to Codex/cxp's 1M-aware client-side limits. `useResponsesApiWebSocket=false` forces HTTP `/responses` streaming instead of Copilot's `ws:/responses` transport, avoiding the proxy WebSocket-to-SSE path that can close before `response.completed`. To test or revert the transport choice, edit `~/.local/share/copilot-api/config.json` and restart `gc2cc-copilot-api`.

### First-run wizard

The very first time you launch `ccp`, if `~/.local/share/gc2cc/ccp.json` doesn't exist, you're walked through the same flow as `ccp config` to set a default model and the bypass-permissions toggle. Hitting Enter for both still creates a placeholder file (defaults preserved) so subsequent launches go straight to the picker.

### Update banner

On each launch ccp compares the SHA-256 of its local `ccp.ps1` to the copy served from Pages. If they diverge it prints:

```
[ccp] gc2cc has updates available -- run 'ccp upgrade' to refresh
```

The check is cached in `ccp.json` for 24h, so it adds no per-launch latency in the common case. Network errors are silent — the banner never blocks ccp. After `ccp upgrade` the cache is cleared so the banner disappears immediately.

### Config file

Settings live in `~/.local/share/gc2cc/ccp.json`:

```json
{
  "defaultModel": "claude-opus-4.7",
  "bypassPermissions": true
}
```

- `defaultModel`: skip the picker and use this id on plain `ccp`. Set to `null` (or use `ccp config` → `[0]`) to always prompt.
- `bypassPermissions`: pass `--dangerously-skip-permissions` to claude. Default `true` (the original YOLO behavior). Flip it off if you want claude to ask for tool-use confirmations.

(Two other keys — `updateCheckAt` and `updateAvailable` — are managed by ccp itself for the update-banner cache. Don't hand-edit them.)

`cxp` has its own settings file at `~/.local/share/gc2cc/cxp.json`:

```json
{
  "defaultModel": "gpt-5.5",
  "bypassPermissions": true
}
```

- `defaultModel`: skip the picker and use this id on plain `cxp`. Set to `null` (or use `cxp config` -> `[0]`) to always prompt.
- `bypassPermissions`: pass `--sandbox danger-full-access --ask-for-approval never` to Codex. Default `true`, matching ccp's low-friction default. Flip it off if you want Codex's normal sandbox/approval behavior from `%LOCALAPPDATA%\gc2cc\codex-home\config.toml`.

The menu is built fresh from the proxy each time, with these rules:

- Embedding models, Microsoft router shims, and dated snapshots (e.g. `gpt-4o-2024-08-06`) are filtered out.
- Model ids are passed through verbatim from the proxy. In particular, the `[1m]` marker that `copilot-api` attaches to 1M-context SKUs (e.g. `claude-opus-4.7-1m-internal[1m]`) is preserved — Claude Code reads it to enable its 1M-context UI/budget and strips it before forwarding the request upstream.
- Preferred families bubble to the top: `claude-opus-4.7` → `gpt-5.5` → `gpt-5.4` → `gemini-3.1-pro` → ...
- The "small/fast" model is picked by family (Claude → `claude-haiku-4.5`, GPT-5 → `gpt-5-mini`, etc).

### Important: do NOT manually pin model ids with `[1m]`

Quoting `caozhiyuan/copilot-api`'s README verbatim:

> When using with Claude Code, please configure the model ID as `claude-opus-4-6` or `claude-opus-4.6` (**without the `[1m]` suffix**, exceeding GitHub Copilot's context window limit too much may lead to **being banned**).

`ccp` exposes 1M-context SKUs as separate menu entries (e.g. `claude-opus-4.7-1m-internal[1m]` alongside `claude-opus-4.7`) so you can pick them deliberately. The bare ids are the standard ~200k SKUs; the `[1m]` variants route to GitHub Copilot's 1M-capable channel. Don't hand-edit `settings.json` to append `[1m]` to an arbitrary id — the proxy only advertises `[1m]` on ids the upstream confirms support a 1M context window.

GitHub's abuse-detection systems flag bulk/automated Copilot traffic. Use this responsibly:

> Excessive automated or scripted use of Copilot ... may trigger GitHub's abuse-detection systems. You may receive a warning from GitHub Security, and further anomalous activity could result in temporary suspension of your Copilot access.

## Service control

```powershell
Get-Service     gc2cc-copilot-api
Restart-Service gc2cc-copilot-api          # needs admin
Stop-Service    gc2cc-copilot-api
Start-Service   gc2cc-copilot-api
```

Or via NSSM directly:

```powershell
& "$env:LOCALAPPDATA\gc2cc\bin\nssm.exe" status  gc2cc-copilot-api
& "$env:LOCALAPPDATA\gc2cc\bin\nssm.exe" restart gc2cc-copilot-api
& "$env:LOCALAPPDATA\gc2cc\bin\nssm.exe" edit    gc2cc-copilot-api   # GUI editor
```

Logs: `%LOCALAPPDATA%\gc2cc\logs\copilot-api.log` (NSSM online rotation at 5 MB; older copies are kept as `copilot-api.log-<timestamp>`).

Quick health check + log helper:

```powershell
irm https://escapecat.github.io/gc2cc/status.ps1 | iex            # show service + reachable models

# or download for arg passing:
irm https://escapecat.github.io/gc2cc/status.ps1 -OutFile status.ps1
.\status.ps1 -Action restart    # prompts for UAC
.\status.ps1 -Action tail
```

## Updating

Easiest: `ccp upgrade` — it fetches the latest `install.ps1` from Pages and re-runs it (will trigger UAC). Equivalent to running the one-liner again.

Either path always runs `npm install -g @jeffreycao/copilot-api@2.3.3`, so a re-run keeps the proxy pinned to the tested version (check `package.json` in `%LOCALAPPDATA%\gc2cc\npm\global\node_modules\@jeffreycao\copilot-api\`).

> **Heads-up:** the upgrade stops the running service, swaps it, and restarts. There's a 1–3s window where `localhost:4141` is unreachable. Don't `ccp upgrade` while a long-running `claude` task is mid-flight.

On the first day of each month, GitHub Actions checks the Microsoft npm proxy
for a newer stable `@jeffreycao/copilot-api` version. When one is available it
updates the pinned version, runs offline installer tests, opens or refreshes a
single upgrade PR, and requests review from `@escapecat`. The review request
appears in GitHub Notifications and is also emailed when review-request email
notifications are enabled. Version PRs are never merged or deployed
automatically; the staging checks listed in the PR remain required.

The same workflow independently checks stable Codex CLI versions. It considers
only exact `x.y.z` releases from the Microsoft npm proxy, excluding alpha,
beta, and platform-suffixed packages. Codex updates use a separate PR and the
same explicit review and staging gate.

The installer also registers a fixed-command elevated task at
`\gc2cc\upgrade-runtime`. Mori can request this task after the user explicitly
approves an upgrade and all local Agent turns are idle. The task accepts no
command, URL, or package arguments from Mori; it downloads only the allowlisted
gc2cc installer, runs without a visible console, and writes status under
`%ProgramData%\gc2cc-updater\`. Installing or changing the task still requires
administrator approval, but subsequent approved upgrades do not require RDP.

## Uninstall

```powershell
irm https://escapecat.github.io/gc2cc/uninstall.ps1 | iex
```

Self-elevates via UAC, then removes the service, the install dir (including `bin/`, `npm/`, and `codex-home/`), the user-PATH entry, the global `@anthropic-ai/claude-code` and `@openai/codex` packages, and any legacy `ccp` block left over in `$PROFILE`. Also best-effort cleans up legacy Scheduled Tasks from pre-NSSM installs.

Pass `-KeepClaudeCode` / `-KeepCodex` to leave the corresponding npm-global package in place.

The GitHub Copilot auth token at `~\.local\share\copilot-api\github_token` is **not** removed — delete it manually for a full reset.

## Custom args

The `irm | iex` form doesn't accept arguments. To override defaults:

```powershell
irm https://escapecat.github.io/gc2cc/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File install.ps1 -Port 5151 -SkipClaudeCode
```

Switches: `-Port`, `-ServiceName`, `-InstallDir`, `-NpmPackage`, `-NpmRegistry`, `-SkipAuth`, `-SkipClaudeCode`, `-SkipPath`, `-InstallClis`, `-NonInteractive`.

`-NpmRegistry` defaults to the global npm setting. Pass it explicitly only to override that source for one install.

`-InstallClis` accepts a comma-separated list (`ccp`, `cxp`, `ccp,cxp`, or empty string for proxy-only). Without it, the installer prompts interactively. `-NonInteractive` skips the prompt and defaults to `ccp`.

`-NpmPackage` defaults to `@jeffreycao/copilot-api@2.3.3`. Override it to pin another exact version or swap to a different fork without code changes.

## Layout

| Path | What |
|---|---|
| `%LOCALAPPDATA%\gc2cc\npm\global\` | private npm prefix where `@jeffreycao/copilot-api` is installed |
| `%LOCALAPPDATA%\gc2cc\npm\global\node_modules\@jeffreycao\copilot-api\` | proxy source (after `npm install`) |
| `%LOCALAPPDATA%\gc2cc\bin\nssm.exe` | NSSM service wrapper |
| `%LOCALAPPDATA%\gc2cc\bin\ccp.ps1` | model-picker + claude launcher (PowerShell) |
| `%LOCALAPPDATA%\gc2cc\bin\ccp.cmd` | shim for cmd / non-PowerShell shells |
| `%LOCALAPPDATA%\gc2cc\bin\cxp.ps1` | model-picker + codex launcher (PowerShell, opt-in) |
| `%LOCALAPPDATA%\gc2cc\bin\cxp.cmd` | shim for cmd / non-PowerShell shells |
| `%LOCALAPPDATA%\gc2cc\codex-home\config.toml` | isolated `CODEX_HOME` for cxp; defines `model_providers.gc2cc` |
| `%LOCALAPPDATA%\gc2cc\logs\copilot-api.log` | proxy stdout/stderr (NSSM rotated at 5 MB) |
| `%LOCALAPPDATA%\gc2cc\logs\install.log` | install transcript (handy when self-elevation fails) |
| `~\.local\share\copilot-api\github_token` | GitHub Copilot auth (created by `copilot-api auth`) |
| `~\.local\share\gc2cc\ccp.json` | ccp settings (default model, bypass-permissions, update-check cache); preserved across `uninstall` |
| `~\.local\share\gc2cc\cxp.json` | cxp settings (default model, Codex bypass-permissions, update-check cache); preserved across `uninstall` |
| User PATH (HKCU\Environment) | gets `%LOCALAPPDATA%\gc2cc\bin\` appended |
| HKLM\SYSTEM\...\Services\gc2cc-copilot-api | Windows Service entry |

The service runs at boot (no user login required), so it survives sign-out, lock screen, sleep, and reboots.

## Star history

[![Star History Chart](https://api.star-history.com/svg?repos=escapecat/gc2cc&type=Date)](https://star-history.com/#escapecat/gc2cc&Date)

## What we count

The only thing gc2cc tracks is how often `install.ps1` runs. After UAC self-elevation it issues a single `GET` to a 99-byte file on a GitHub Release (tag `install-counter`). GitHub's own download counter is what powers the "installs" badge above. No request body, no version, no user identifier, no IP collected by us. The number you see on the badge is the only data we have. The fetch is best-effort: offline installs still complete normally.

## Credits

- Proxy: [caozhiyuan/copilot-api](https://github.com/caozhiyuan/copilot-api) (npm: [`@jeffreycao/copilot-api`](https://www.npmjs.com/package/@jeffreycao/copilot-api)) — the actively maintained fork of [ericc-ch/copilot-api](https://github.com/ericc-ch/copilot-api).
- Service wrapper: [NSSM — the Non-Sucking Service Manager](https://nssm.cc/).
- Claude Code: [@anthropic-ai/claude-code](https://www.npmjs.com/package/@anthropic-ai/claude-code).
