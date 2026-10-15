# Revert ZCode desktop UI font (v3, portable): restore app.asar and restart
# Auto-locates ZCode install; every probe is fault-tolerant.
# Exits automatically on success; pauses only on errors.
# Restore order: (1) if the CURRENT asar still shows a known font patch, reverse
# it in place — this preserves any other patches (wallpaper block / update
# disable) that were applied after the backup was taken; (2) otherwise fall back
# to the verbatim backup restore (factory state).
param(
    [switch]$NoRestart,   # toolbox mode: do not relaunch ZCode after restoring
    [string]$TargetAsar     # advanced/testing: operate on this app.asar instead of the auto-located one (skips the running check)
)
$ErrorActionPreference = 'Stop'
# Clear NODE_OPTIONS from this process so the ZCode.exe we (re)start never
# inherits unsupported flags (packaged Electron apps print a startup ERROR for
# e.g. --max-old-space-size); the machine/user registry value is NOT touched.
try { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue } catch {}

$backupPath = Join-Path $PSScriptRoot 'app.asar.font-backup'
$hashPath   = Join-Path $PSScriptRoot 'app.asar.font-backup.sha256'

function Find-ZCodeDir {
    try {
        $p = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1
        if ($p) { return Split-Path (Split-Path $p.Path -Parent) -Parent }
    } catch {}
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')
    foreach ($k in $keys) {
        try {
            $hit = Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*ZCode*' -and $_.InstallLocation } | Select-Object -First 1
            if ($hit) {
                $cand = Join-Path $hit.InstallLocation 'resources\app.asar'
                if (Test-Path $cand) { return (Split-Path $cand -Parent) }
            }
        } catch {}
    }
    $candidates = @('D:\installer\zcode', "$env:LOCALAPPDATA\Programs\zcode", "$env:ProgramFiles\zcode", "${env:ProgramFiles(x86)}\zcode")
    foreach ($d in $candidates) {
        try {
            if (-not (Test-Path $d)) { continue }
            $cand = Join-Path $d 'resources\app.asar'
            if (Test-Path $cand) { return (Split-Path $cand -Parent) }
        } catch { continue }
    }
    return $null
}

$resourcesDir = Find-ZCodeDir
if (-not $resourcesDir) {
    Write-Host '[?] Could not auto-locate ZCode. Example: D:\installer\zcode\resources' -ForegroundColor Yellow
    $manual = Read-Host 'Enter the folder that contains app.asar (resources dir)'
    if (-not $manual -or -not (Test-Path (Join-Path $manual 'app.asar'))) {
        Write-Host "[X] app.asar not found under: $manual" -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
    $resourcesDir = $manual
}
$asarPath  = Join-Path $resourcesDir 'app.asar'
$zcodeExe  = Join-Path (Split-Path $resourcesDir -Parent) 'ZCode.exe'
if (-not (Test-Path $zcodeExe)) { $zcodeExe = $null }
if ($TargetAsar) {
    # explicit override (toolbox/testing): operate on the given asar and skip
    # the running-process guard, so the caller controls those concerns
    $asarPath = $TargetAsar
    $zcodeExe = $null
    Write-Host "target (override): $asarPath"
} else {
    Write-Host "target: $asarPath"
}

if (-not $TargetAsar) {
    $procs = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Host '[X] ZCode is running. Quit it from the tray icon first, then run this script again.' -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
}
# the backup must be a clean unpatched asar, never a patched one (checked only
# when the backup path is actually taken)
$latin1 = [System.Text.Encoding]::GetEncoding(28591)

# ---- path 1 (preferred): reverse the known font stacks in the CURRENT asar ----
# The current asar may carry other patches applied after the font backup was
# taken; reversing in place keeps them intact. A backup is not required here.
$ct = $latin1.GetString([System.IO.File]::ReadAllBytes($asarPath))
$oldSans = '--font-sans:ui-sans-serif, system-ui, sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji";'
$oldMono = '--font-mono:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", "Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC", "Noto Sans CJK SC", monospace;'
# padded legacy/new stacks, built the same way the patch script builds them
function Pad-To([string]$old, [string]$new) {
    $pad = $old.Length - $new.Length
    if ($pad -eq 0) { return $new }
    return $new.Substring(0, $new.Length - 1) + (' ' * $pad) + ';'
}
$stacks = @(
    (Pad-To $oldSans '--font-sans:"Fragment Mono","SFMono-Regular","HarmonyOS Sans SC","PingFang SC","Source Han Sans SC","Noto Sans SC";'),
    (Pad-To $oldMono '--font-mono:"AnthropicMono Medium","Fragment Mono","SFMono-Regular","HarmonyOS Sans SC","Noto Sans SC","PingFang SC","JetBrains Mono";'),
    (Pad-To $oldSans '--font-sans:"HarmonyOS Sans SC","PingFang SC","Source Han Sans SC","Noto Sans SC";'),
    (Pad-To $oldMono '--font-mono:"AnthropicMono Medium","HarmonyOS Sans SC","PingFang SC","JetBrains Mono";'),
    (Pad-To $oldSans '--font-sans:"Anthropic Mono Variable", system-ui, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji";'),
    (Pad-To $oldMono '--font-mono:"Anthropic Mono Variable", Consolas, "Liberation Mono", "Courier New", "Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC", "Noto Sans CJK SC", monospace;'),
    (Pad-To $oldSans '--font-sans:"Anthropic Mono Variable", "Noto Sans SC", "Segoe UI Emoji", "Noto Color Emoji";'),
    (Pad-To $oldMono '--font-mono:"Anthropic Mono Variable", "Noto Sans SC", "Segoe UI Emoji", "Noto Color Emoji";')
)
$fontHits = 0
$reversed = $ct
foreach ($s in $stacks) {
    if (([regex]::Matches($reversed, [regex]::Escape($s))).Count -eq 1) {
        $reversed = $reversed.Replace($s, $(if ($s -like '--font-sans*') { $oldSans } else { $oldMono }))
        $fontHits++
    }
}
# exact pad-length match is required; also accept stacks whose padding makes the
# replace above ambiguous by verifying the final state
$cleanNow = (([regex]::Matches($reversed, [regex]::Escape($oldSans))).Count -eq 1 -and ([regex]::Matches($reversed, [regex]::Escape($oldMono))).Count -eq 1)
if ($fontHits -ge 1 -and $cleanNow -and $fontHits -eq 2) {
    $newBytes = [System.Text.Encoding]::GetEncoding(28591).GetBytes($reversed)
    [System.IO.File]::WriteAllBytes($asarPath, $newBytes)
    Write-Host '[OK] font stacks reversed in place (other patches preserved).'
    if ($NoRestart) {
        Write-Host '[OK] done (NoRestart: leave ZCode closed).'
    } elseif ($zcodeExe) {
        Start-Process $zcodeExe
        Write-Host '[OK] ZCode restarted.'
    } else {
        Write-Host '[OK] Start ZCode manually.'
    }
    exit 0
}
if ($fontHits -eq 1) {
    # one stack matched but the other is unknown state — too risky to guess
    Write-Host '[X] only one of the two font stacks matches a known revision; refusing in-place restore.' -ForegroundColor Red
    Write-Host '    Use the backup restore path by removing other patches first, or re-check the asar.' -ForegroundColor Yellow
    Read-Host 'Press Enter to exit'
    exit 1
}

# ---- path 2 (fallback): verbatim backup restore (factory state) ----
if (-not (Test-Path $backupPath)) {
    Write-Host '[X] backup not found: ' $backupPath -ForegroundColor Red
    Write-Host '    (was the patch ever applied on this machine? The backup is created by the patch script.)' -ForegroundColor Yellow
    Read-Host 'Press Enter to exit'
    exit 1
}

# sidecar hash must match the backup file itself
if (Test-Path $hashPath) {
    $expect = (Get-Content $hashPath -ErrorAction SilentlyContinue)
    $actual = (Get-FileHash $backupPath -Algorithm SHA256).Hash
    if (-not $expect -or ($actual -ne $expect.Trim())) {
        Write-Host '[X] backup hash mismatch with sidecar, refusing to overwrite.' -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
}

# the backup must be a clean unpatched asar, never a patched one
$bt = $latin1.GetString([System.IO.File]::ReadAllBytes($backupPath))
if (([regex]::Matches($bt, [regex]::Escape($oldSans))).Count -ne 1 -or ([regex]::Matches($bt, [regex]::Escape($oldMono))).Count -ne 1) {
    Write-Host '[X] backup is not a clean original asar (looks patched or from a different ZCode version), refusing to overwrite.' -ForegroundColor Red
    Read-Host 'Press Enter to exit'
    exit 1
}

Copy-Item $backupPath $asarPath -Force
Write-Host '[OK] app.asar restored from backup (factory state; later patches were absent anyway).'
if ($NoRestart) {
    Write-Host '[OK] done (NoRestart: leave ZCode closed).'
} elseif ($zcodeExe) {
    Start-Process $zcodeExe
    Write-Host '[OK] ZCode restarted.'
} else {
    Write-Host '[OK] Start ZCode manually.'
}
