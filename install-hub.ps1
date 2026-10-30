# StreamHaven - one-time hub bootstrap (Claude, 2026-10-29).
#
# Run ONCE on each hub. It:
#   1. downloads the auto-updater (update-streamhaven.ps1 + .cmd) into C:\Hub\apps
#   2. adds a Startup launcher so every logon runs the updater (which updates, then launches the app)
#   3. runs the updater once now
# After this the hub self-updates from the public GitHub release with no further action, from any
# network (the update download is plain GitHub over the internet).
#
# Easiest install - paste this into Windows PowerShell on the hub:
#   irm https://raw.githubusercontent.com/mattyjsherm/streamhaven-releases/main/install-hub.ps1 | iex
#
# Optional env overrides (set before running): SH_INSTALL_ROOT, SH_NO_STARTUP, SH_NO_RUN, SH_NO_LAUNCH.

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
$RawBase = 'https://raw.githubusercontent.com/mattyjsherm/streamhaven-releases/main'

$root = $env:SH_INSTALL_ROOT; if (-not $root) { $root = 'C:\Hub\apps' }
$installDir = Join-Path $root 'StreamHaven'
$updater = Join-Path $root 'update-streamhaven.ps1'
function Say([string]$m) { Write-Host ('[hub-setup] ' + $m) }

if (-not (Test-Path $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }

Say "downloading updater -> $root"
Invoke-WebRequest -Uri "$RawBase/update-streamhaven.ps1" -OutFile $updater -UseBasicParsing -TimeoutSec 60
Invoke-WebRequest -Uri "$RawBase/update-streamhaven.cmd" -OutFile (Join-Path $root 'update-streamhaven.cmd') -UseBasicParsing -TimeoutSec 60

if (-not $env:SH_NO_STARTUP) {
    $startup = [Environment]::GetFolderPath('Startup')
    $launcher = Join-Path $startup 'StreamHaven.cmd'
    $body = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$updater`" -InstallDir `"$installDir`"`r`n"
    Set-Content -LiteralPath $launcher -Value $body -Encoding ascii
    Say "startup launcher installed -> $launcher"
}
else { Say 'skipping startup launcher (SH_NO_STARTUP set)' }

if (-not $env:SH_NO_RUN) {
    Say 'running the updater now (first install)...'
    # Run as a child process so the updater's exit codes don't end this bootstrap.
    $pa = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $updater, '-InstallDir', $installDir)
    if ($env:SH_NO_LAUNCH) { $pa += '-NoLaunch' }
    $proc = Start-Process -FilePath 'powershell' -ArgumentList $pa -Wait -PassThru -NoNewWindow
    Say ('updater exit code: ' + $proc.ExitCode)
}
else { Say 'skipping first run (SH_NO_RUN set)' }

Say 'done - this hub will self-update at every logon.'
