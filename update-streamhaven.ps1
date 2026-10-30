# StreamHaven - hub-side auto-updater / launcher (Claude, 2026-10-29).
#
# Run this at hub startup and/or right before StreamHaven should open. With no login or token it:
#   1. reads the public version manifest (GitHub Releases 'latest/download', tokenless)
#   2. compares it to the installed streamhaven.exe ProductVersion
#   3. if newer (or not installed, or -Force): downloads the pinned zip, verifies size + SHA-256,
#      stages it to a sibling folder, confirms the staged exe carries the expected version, stops
#      only THIS install's running process, then atomically swaps the new build into place
#   4. launches StreamHaven (unless -NoLaunch)
#
# Safety: the live install is never touched until a fresh download has passed size + checksum +
# version checks in a staging folder, so a bad/partial download or a dead network can never leave
# the hub without a working app. Everything is logged. Transient network errors are retried.
#
# Typical use (Task Scheduler at logon, or a startup .cmd):
#   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Hub\apps\update-streamhaven.ps1"
# Update only, don't launch:   ...-File ... -NoLaunch
# Force a clean reinstall:     ...-File ... -Force
param(
    [string]$ManifestUrl = 'https://github.com/mattyjsherm/streamhaven-releases/releases/latest/download/streamhaven-version.json',
    [string]$InstallDir = 'C:\Hub\apps\StreamHaven',
    [string]$LogFile = 'C:\Hub\logs\streamhaven-update.log',
    [switch]$NoLaunch,
    [switch]$Force,
    [switch]$NoFirewallRule,
    [int]$Retries = 4,
    [int]$TimeoutSec = 600
)

$ErrorActionPreference = 'Continue'   # gate on results, not on cmdlet/native stderr
$ProgressPreference = 'SilentlyContinue'
# GitHub requires TLS 1.2+; PS 5.1 can still default lower for the web cmdlets.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$Exe = Join-Path $InstallDir 'streamhaven.exe'

# ---- logging -------------------------------------------------------------
$script:LogReady = $false
function Ensure-Log {
    if ($script:LogReady) { return }
    try {
        $dir = Split-Path -Parent $LogFile
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $script:LogReady = $true
    }
    catch {
        # Fall back to the temp dir if the preferred log location can't be created.
        $script:LogFile = Join-Path $env:TEMP 'streamhaven-update.log'
        $script:LogReady = $true
    }
}
function Log([string]$msg) {
    $line = ('[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $msg)
    Write-Host $line
    Ensure-Log
    try {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8
        # Trim to the newest ~256 KB so it can't grow without bound.
        $fi = Get-Item -LiteralPath $LogFile -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 512KB) {
            $txt = Get-Content -LiteralPath $LogFile -Raw
            Set-Content -LiteralPath $LogFile -Value $txt.Substring($txt.Length - 256KB) -Encoding utf8
        }
    }
    catch {}
}

# ---- version compare (major.minor.patch+build, e.g. 1.1.0+2) ------------
function Parse-Ver([string]$v) {
    if (-not $v) { $v = '0' }
    $parts = $v.Split('+', 2)
    $nums = @()
    foreach ($x in $parts[0].Split('.')) { $n = 0; [void][int]::TryParse($x, [ref]$n); $nums += $n }
    while ($nums.Count -lt 3) { $nums += 0 }
    if ($parts.Count -gt 1 -and $parts[1]) { $b = 0; [void][int]::TryParse($parts[1], [ref]$b); $nums += $b } else { $nums += 0 }
    return , $nums
}
function Is-Newer([string]$candidate, [string]$have) {
    $a = Parse-Ver $candidate; $b = Parse-Ver $have
    for ($i = 0; $i -lt 4; $i++) { if ($a[$i] -ne $b[$i]) { return ($a[$i] -gt $b[$i]) } }
    return $false
}

# ---- small retry helper for flaky I/O -----------------------------------
function Retry([scriptblock]$action, [int]$times, [int]$delayMs) {
    for ($i = 1; $i -le $times; $i++) {
        try { & $action; return $true } catch { if ($i -ge $times) { throw } ; Start-Sleep -Milliseconds $delayMs }
    }
    return $false
}

function Launch-App {
    if ($NoLaunch) { return }
    if (Test-Path $Exe) {
        Log "launching $Exe"
        try { Start-Process -FilePath $Exe -WorkingDirectory $InstallDir } catch { Log "WARN launch failed: $($_.Exception.Message)" }
    }
    else { Log 'WARN nothing to launch (no installed exe)' }
}

function Installed-Version {
    if (Test-Path $Exe) { try { return (Get-Item $Exe).VersionInfo.ProductVersion.Trim() } catch { return '0' } }
    return '0'
}

# ---- only one updater at a time -----------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Global\StreamHavenHubUpdater')
$held = $false
try { $held = $mutex.WaitOne(0) } catch { $held = $true }
if (-not $held) { Log 'another updater run is active - exiting'; exit 0 }

try {
    Log "=== check === manifest=$ManifestUrl  install=$InstallDir"

    # 1. manifest (retry transient failures)
    $manifest = $null
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            $tmpM = Join-Path $env:TEMP ('sh-manifest-' + [Guid]::NewGuid().ToString('N') + '.json')
            Invoke-WebRequest -Uri $ManifestUrl -OutFile $tmpM -UseBasicParsing -TimeoutSec 60
            $text = (Get-Content -LiteralPath $tmpM -Raw).TrimStart([char]0xFEFF)   # tolerate a BOM
            Remove-Item -LiteralPath $tmpM -Force -ErrorAction SilentlyContinue
            $manifest = $text | ConvertFrom-Json
            break
        }
        catch {
            Log "manifest fetch attempt $i/$Retries failed: $($_.Exception.Message)"
            if ($i -lt $Retries) { Start-Sleep -Seconds ([Math]::Min(10, $i * 2)) }
        }
    }
    if (-not $manifest -or -not $manifest.version -or -not $manifest.zip -or -not $manifest.sha256) {
        Log 'ERROR could not read a valid manifest - leaving the current install as-is'
        Launch-App
        exit 2
    }

    $have = Installed-Version
    $want = ('' + $manifest.version).Trim()
    Log "installed=$have  latest=$want"

    if (-not $Force -and -not (Is-Newer $want $have)) {
        Log 'up to date'
        Launch-App
        exit 0
    }
    Log ("update needed -> $want" + $(if ($Force) { ' (forced)' } else { '' }))

    # 2. download the pinned zip (retry), then verify size + sha256
    $zipUrl = ('' + $manifest.zip).Trim()
    $wantSha = ('' + $manifest.sha256).Trim().ToLower()
    $wantSize = 0; if ($manifest.size) { $wantSize = [int64]$manifest.size }
    $tmpZip = Join-Path $env:TEMP ('sh-update-' + [Guid]::NewGuid().ToString('N') + '.zip')
    $got = $false
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Log "downloading ($i/$Retries) $zipUrl"
            Invoke-WebRequest -Uri $zipUrl -OutFile $tmpZip -UseBasicParsing -TimeoutSec $TimeoutSec
            $sz = (Get-Item -LiteralPath $tmpZip).Length
            if ($wantSize -gt 0 -and $sz -ne $wantSize) { throw "size $sz != manifest $wantSize" }
            $sha = (Get-FileHash -LiteralPath $tmpZip -Algorithm SHA256).Hash.ToLower()
            if ($sha -ne $wantSha) { throw "sha256 mismatch" }
            $got = $true; Log "download ok ($sz bytes, sha verified)"; break
        }
        catch {
            Log "download/verify attempt $i failed: $($_.Exception.Message)"
            Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
            if ($i -lt $Retries) { Start-Sleep -Seconds ([Math]::Min(15, $i * 3)) }
        }
    }
    if (-not $got) {
        Log 'ERROR download failed verification after retries - keeping the current install'
        Launch-App
        exit 3
    }

    # 3. stage, verify the staged exe, then atomically swap
    $parent = Split-Path -Parent $InstallDir
    $leaf = Split-Path -Leaf $InstallDir
    $staging = Join-Path $parent ($leaf + '.new')
    $backup = Join-Path $parent ($leaf + '.old')
    try {
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
        Log "staging -> $staging"
        Expand-Archive -LiteralPath $tmpZip -DestinationPath $staging -Force
        $stagedExe = Join-Path $staging 'streamhaven.exe'
        if (-not (Test-Path $stagedExe)) { throw 'staged build has no streamhaven.exe at its root' }
        $stagedVer = (Get-Item $stagedExe).VersionInfo.ProductVersion.Trim()
        if ($stagedVer -ne $want) { throw "staged exe version ($stagedVer) != manifest ($want)" }
        Log "staged build verified ($stagedVer)"

        # Stop ONLY the process running out of this install dir (never a different instance).
        $stopped = 0
        foreach ($p in @(Get-Process -Name streamhaven -ErrorAction SilentlyContinue)) {
            $path = $null; try { $path = $p.Path } catch {}
            if ($path -and $path.ToLower().StartsWith($InstallDir.ToLower())) {
                try { Stop-Process -Id $p.Id -Force; $stopped++ } catch {}
            }
        }
        if ($stopped) { Log "stopped $stopped running instance(s); waiting for file handles"; Start-Sleep -Seconds 2 }

        # Swap: old -> .old, new -> live. Retry around lingering handles.
        if (Test-Path $backup) { Retry { Remove-Item -Recurse -Force $backup } 3 1000 | Out-Null }
        if (Test-Path $InstallDir) {
            Retry { Rename-Item -LiteralPath $InstallDir -NewName ($leaf + '.old') } 4 1000 | Out-Null
        }
        try {
            Rename-Item -LiteralPath $staging -NewName $leaf
        }
        catch {
            # Roll back so the hub keeps its previous, working install.
            if ((Test-Path $backup) -and -not (Test-Path $InstallDir)) {
                Rename-Item -LiteralPath $backup -NewName $leaf
                Log 'ERROR swap failed - rolled back to the previous install'
            }
            throw
        }
        if (Test-Path $backup) { Remove-Item -Recurse -Force $backup -ErrorAction SilentlyContinue }
        Log "installed $want"
    }
    catch {
        Log "ERROR install/swap failed: $($_.Exception.Message)"
        Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
        Launch-App
        exit 4
    }
    Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue

    # 4. first-run firewall rule for the Local Theatre LAN server (best-effort; needs admin)
    if (-not $NoFirewallRule) {
        try {
            & netsh advfirewall firewall show rule name="StreamHaven" *> $null
            if ($LASTEXITCODE -ne 0) {
                & netsh advfirewall firewall add rule name="StreamHaven" dir=in action=allow program="$Exe" enable=yes *> $null
                if ($LASTEXITCODE -eq 0) { Log 'added inbound firewall rule "StreamHaven"' } else { Log 'WARN could not add firewall rule (admin rights needed) - skipping' }
            }
        }
        catch { Log "WARN firewall step skipped: $($_.Exception.Message)" }
    }

    Launch-App
    Log '=== done ==='
    exit 0
}
finally {
    if ($held) { try { $mutex.ReleaseMutex() } catch {} }
}
