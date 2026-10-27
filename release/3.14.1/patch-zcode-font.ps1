# ZCode desktop UI font patch (v3, portable)
# - Auto-locates ZCode install (running process / registry / common dirs / manual input);
#   every probe is fault-tolerant, a missing drive or path never aborts the search
# - Patches Tailwind root vars --font-sans / --font-mono inside app.asar with the
#   user-specified priority stack (first installed family wins, CJK falls through):
#   "Anthropic Mono Variable" -> "MiSans" -> "HarmonyOS Sans SC"
#   -> "Source Han Sans SC" -> "Noto Sans SC" -> "HarmonyOS Sans"
#   (emoji fonts omitted: Chromium still renders emoji via its own system fallback)
# - Equal-length byte replacement: asar header offsets/sizes stay intact
# - Backup = clean original asar of THIS machine; state is detected BEFORE any
#   backup decision, so an existing clean backup is never overwritten by a
#   patched asar; a missing/invalid backup is self-healed by reverse replacement
# - Upgrades v1/v2 patch layouts in place; idempotent when already v3
# - Exits automatically on success; pauses only on errors
# Revert with restore-zcode-font.bat
param(
    [switch]$NoRestart,   # toolbox mode: do not relaunch ZCode after patching
    [string]$TargetAsar     # advanced/testing: operate on this app.asar instead of the auto-located one (skips the running check)
)
$ErrorActionPreference = 'Stop'
# Clear NODE_OPTIONS from this process so the ZCode.exe we (re)start never
# inherits unsupported flags (packaged Electron apps print a startup ERROR for
# e.g. --max-old-space-size); the machine/user registry value is NOT touched.
try { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue } catch {}
$latin1 = [System.Text.Encoding]::GetEncoding(28591)  # lossless byte<->char round-trip

$backupPath = Join-Path $PSScriptRoot 'app.asar.font-backup'
$hashPath   = Join-Path $PSScriptRoot 'app.asar.font-backup.sha256'

# ---- exact strings present in current ZCode builds (each must occur exactly once) ----
$oldSans = '--font-sans:ui-sans-serif, system-ui, sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji";'
$oldMono = '--font-mono:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", "Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC", "Noto Sans CJK SC", monospace;'

# ---- patched strings (v9): separate stacks per variable, user-specified priority ----
# sans: Fragment Mono (latin) -> SFMono-Regular (mac-only, inert on Windows, kept
#       per user request) -> HarmonyOS Sans SC -> PingFang SC
#       -> Source Han Sans SC -> Noto Sans SC
# mono: AnthropicMono Medium -> Fragment Mono -> SFMono-Regular
#       -> HarmonyOS Sans SC -> Noto Sans SC -> PingFang SC -> JetBrains Mono
$newSans = '--font-sans:"Fragment Mono","SFMono-Regular","HarmonyOS Sans SC","PingFang SC","Source Han Sans SC","Noto Sans SC";'
$newMono = '--font-mono:"AnthropicMono Medium","Fragment Mono","SFMono-Regular","HarmonyOS Sans SC","Noto Sans SC","PingFang SC","JetBrains Mono";'

# ---- v8 patch strings (previous kit version) ----
$v8Sans = '--font-sans:"HarmonyOS Sans SC","PingFang SC","Source Han Sans SC","Noto Sans SC";'
$v8Mono = '--font-mono:"AnthropicMono Medium","HarmonyOS Sans SC","PingFang SC","JetBrains Mono";'

# ---- v7 patch strings (intermediate revision, mono had no CJK-capable family) ----
$v7Sans = '--font-sans:"HarmonyOS Sans SC","Source Han Sans SC","Noto Sans SC";'
$v7Mono = '--font-mono:"AnthropicMono Medium","JetBrains Mono";'

# ---- v6 patch strings (previous kit version) ----
$v6Sans = '--font-sans:"AnthropicSans","LXGW WenKai","PingFang SC","HarmonyOS Sans SC","Source Han Sans SC","Noto Sans SC","MiSans";'
$v6Mono = '--font-mono:"AnthropicMono","Anthropic Mono Variable","PingFang SC","JetBrains Mono","LXGW WenKai";'

# ---- v5 patch strings (previous kit version) ----
$v5Sans = '--font-sans:"LXGW WenKai","PingFang SC","HarmonyOS Sans SC","Source Han Sans SC","Noto Sans SC","HarmonyOS Sans","MiSans";'
$v5Mono = '--font-mono:"Anthropic Mono Variable", "PingFang SC", "JetBrains Mono", "LXGW WenKai";'

# ---- v4 patch strings (previous kit version) ----
$v4Sans = '--font-sans:"LXGW WenKai", "HarmonyOS Sans SC", "Source Han Sans SC", "Noto Sans SC", "HarmonyOS Sans", "MiSans";'
$v4Mono = '--font-mono:"Anthropic Mono Variable", "LXGW WenKai", "JetBrains Mono";'

# ---- v3 patch strings (previous kit version, single stack for both variables) ----
$v3Sans = '--font-sans:"Anthropic Mono Variable", "MiSans", "HarmonyOS Sans SC", "Source Han Sans SC", "Noto Sans SC", "HarmonyOS Sans";'
$v3Mono = '--font-mono:"Anthropic Mono Variable", "MiSans", "HarmonyOS Sans SC", "Source Han Sans SC", "Noto Sans SC", "HarmonyOS Sans";'

function Pad-To([string]$old, [string]$new) {
    if ($new.Length -gt $old.Length) { throw "new string longer than old, cannot pad: $($new.Length) > $($old.Length)" }
    $pad = $old.Length - $new.Length
    if ($pad -eq 0) { return $new }
    return $new.Substring(0, $new.Length - 1) + (' ' * $pad) + ';'
}
$newSans = Pad-To $oldSans $newSans
$newMono = Pad-To $oldMono $newMono

# ---- legacy patch strings (v1 / v2 kit versions), padded exactly as they were written ----
$v1Sans = Pad-To $oldSans '--font-sans:"Anthropic Mono Variable", system-ui, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji";'
$v1Mono = Pad-To $oldMono '--font-mono:"Anthropic Mono Variable", Consolas, "Liberation Mono", "Courier New", "Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC", "Noto Sans CJK SC", monospace;'
$v2Sans = Pad-To $oldSans '--font-sans:"Anthropic Mono Variable", "Noto Sans SC", "Segoe UI Emoji", "Noto Color Emoji";'
$v2Mono = Pad-To $oldMono '--font-mono:"Anthropic Mono Variable", "Noto Sans SC", "Segoe UI Emoji", "Noto Color Emoji";'
$v3Sans = Pad-To $oldSans $v3Sans
$v3Mono = Pad-To $oldMono $v3Mono
$v4Sans = Pad-To $oldSans $v4Sans
$v4Mono = Pad-To $oldMono $v4Mono
$v5Sans = Pad-To $oldSans $v5Sans
$v5Mono = Pad-To $oldMono $v5Mono
$v6Sans = Pad-To $oldSans $v6Sans
$v6Mono = Pad-To $oldMono $v6Mono
$v7Sans = Pad-To $oldSans $v7Sans
$v7Mono = Pad-To $oldMono $v7Mono
$v8Sans = Pad-To $oldSans $v8Sans
$v8Mono = Pad-To $oldMono $v8Mono

function Count-Str([string]$hay, [string]$s) {
    return ([regex]::Matches($hay, [regex]::Escape($s))).Count
}
function Hash-Bytes([byte[]]$b) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($b) | ForEach-Object { $_.ToString('X2') }) -join '') } finally { $sha.Dispose() }
}

function Find-ZCodeDir {
    # 1) running process path
    try {
        $p = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1
        if ($p) { return Split-Path (Split-Path $p.Path -Parent) -Parent }
    } catch {}
    # 2) registry uninstall entries (32/64-bit + per-user)
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
    # 3) common dirs; Join-Path with an absent drive throws, so test the path first
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

# 0) ZCode must not be running (skipped for explicit -AsarPath overrides)
if (-not $TargetAsar) {
    $procs = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Host '[X] ZCode is running, app.asar is locked.' -ForegroundColor Red
        Write-Host '    Quit ZCode first (right-click tray icon -> Quit; clicking X may only minimize to tray).' -ForegroundColor Yellow
        Read-Host 'Press Enter to exit'
        exit 1
    }
}

# 1) read current asar and detect its state BEFORE touching any backup
$bytes    = [System.IO.File]::ReadAllBytes($asarPath)
$text     = $latin1.GetString($bytes)
$asarHash = Hash-Bytes $bytes

$cOldSans = Count-Str $text $oldSans
$cOldMono = Count-Str $text $oldMono
$cV1Sans  = Count-Str $text $v1Sans
$cV1Mono  = Count-Str $text $v1Mono
$cV2Sans  = Count-Str $text $v2Sans
$cV2Mono  = Count-Str $text $v2Mono
$cV3Sans  = Count-Str $text ($v3Sans.TrimEnd(';').TrimEnd())
$cV3Mono  = Count-Str $text ($v3Mono.TrimEnd(';').TrimEnd())
$cV4Sans  = Count-Str $text ($v4Sans.TrimEnd(';').TrimEnd())
$cV4Mono  = Count-Str $text ($v4Mono.TrimEnd(';').TrimEnd())
$cV5Sans  = Count-Str $text ($v5Sans.TrimEnd(';').TrimEnd())
$cV5Mono  = Count-Str $text ($v5Mono.TrimEnd(';').TrimEnd())
$cV6Sans  = Count-Str $text ($v6Sans.TrimEnd(';').TrimEnd())
$cV6Mono  = Count-Str $text ($v6Mono.TrimEnd(';').TrimEnd())
$cV7Sans  = Count-Str $text ($v7Sans.TrimEnd(';').TrimEnd())
$cV7Mono  = Count-Str $text ($v7Mono.TrimEnd(';').TrimEnd())
$cV8Sans  = Count-Str $text ($v8Sans.TrimEnd(';').TrimEnd())
$cV8Mono  = Count-Str $text ($v8Mono.TrimEnd(';').TrimEnd())
$cNewSans = Count-Str $text ($newSans.TrimEnd(';').TrimEnd())
$cNewMono = Count-Str $text ($newMono.TrimEnd(';').TrimEnd())

$isUnpatched = ($cOldSans -eq 1 -and $cOldMono -eq 1)
$isV1        = ($cV1Sans -eq 1 -and $cV1Mono -eq 1)
$isV2        = ($cV2Sans -eq 1 -and $cV2Mono -eq 1)
$isV3        = ($cV3Sans -ge 1 -and $cV3Mono -ge 1 -and $cNewSans -eq 0 -and $cV4Sans -eq 0 -and $cV5Sans -eq 0 -and $cV6Sans -eq 0 -and $cV7Sans -eq 0)
$isV4        = ($cV4Sans -ge 1 -and $cV4Mono -ge 1 -and $cNewSans -eq 0 -and $cV5Sans -eq 0 -and $cV6Sans -eq 0 -and $cV7Sans -eq 0)
$isV5        = ($cV5Sans -ge 1 -and $cV5Mono -ge 1 -and $cNewSans -eq 0 -and $cV6Sans -eq 0 -and $cV7Sans -eq 0)
$isV6        = ($cV6Sans -ge 1 -and $cV6Mono -ge 1 -and $cNewSans -eq 0 -and $cV7Sans -eq 0 -and $cV8Sans -eq 0)
$isV7        = ($cV7Sans -ge 1 -and $cV7Mono -ge 1 -and $cNewSans -eq 0 -and $cV8Sans -eq 0)
$isV8        = ($cV8Sans -ge 1 -and $cV8Mono -ge 1 -and $cNewSans -eq 0)
$isV9        = ($cNewSans -ge 1 -and $cNewMono -ge 1)

# 2) determine the clean baseline asar (what the backup must contain)
$baseText = $null
if ($isUnpatched) {
    Write-Host '[1/4] state: unpatched'
    $baseText = $text
} elseif ($isV1 -or $isV2 -or $isV3 -or $isV4 -or $isV5 -or $isV6 -or $isV7 -or $isV8 -or $isV9) {
    if ($isV1) { Write-Host '[1/4] state: v1 patch detected (upgrade)' }
    elseif ($isV2) { Write-Host '[1/4] state: v2 patch detected (upgrade)' }
    elseif ($isV3) { Write-Host '[1/4] state: v3 patch detected (upgrade)' }
    elseif ($isV4) { Write-Host '[1/4] state: v4 patch detected (upgrade)' }
    elseif ($isV5) { Write-Host '[1/4] state: v5 patch detected (upgrade)' }
    elseif ($isV6) { Write-Host '[1/4] state: v6 patch detected (upgrade)' }
    elseif ($isV7) { Write-Host '[1/4] state: v7 patch detected (upgrade)' }
    elseif ($isV8) { Write-Host '[1/4] state: v8 patch detected (upgrade)' }
    else { Write-Host '[1/4] state: v9 patch detected' }
    # baseline = existing backup if it verifies as a clean original...
    if (Test-Path $backupPath) {
        $sidecarOk = $false
        if (Test-Path $hashPath) {
            $expect = (Get-Content $hashPath -ErrorAction SilentlyContinue)
            $actual = (Get-FileHash $backupPath -Algorithm SHA256).Hash
            $sidecarOk = ($expect -and ($actual -eq $expect.Trim()))
        }
        if ($sidecarOk) {
            $bt = $latin1.GetString([System.IO.File]::ReadAllBytes($backupPath))
            if ((Count-Str $bt $oldSans) -eq 1 -and (Count-Str $bt $oldMono) -eq 1) {
                $baseText = $bt
                Write-Host '[2/4] clean backup verified'
            }
        }
    }
    # ...otherwise self-heal: reverse the known patch strings to rebuild the clean original
    if (-not $baseText) {
        $rt = $text
        foreach ($pair in @(($v1Sans, $oldSans), ($v1Mono, $oldMono), ($v2Sans, $oldSans), ($v2Mono, $oldMono), ($v3Sans, $oldSans), ($v3Mono, $oldMono), ($v4Sans, $oldSans), ($v4Mono, $oldMono), ($v5Sans, $oldSans), ($v5Mono, $oldMono), ($v6Sans, $oldSans), ($v6Mono, $oldMono), ($v7Sans, $oldSans), ($v7Mono, $oldMono), ($v8Sans, $oldSans), ($v8Mono, $oldMono), ($newSans, $oldSans), ($newMono, $oldMono))) {
            $rt = $rt.Replace($pair[0], $pair[1])
        }
        if ((Count-Str $rt $oldSans) -ne 1 -or (Count-Str $rt $oldMono) -ne 1) {
            throw 'clean backup missing/invalid and cannot be reconstructed from the patched asar; refusing.'
        }
        $baseText = $rt
        Write-Host '[2/4] clean backup missing/invalid, reconstructed from patched asar'
    }
} else {
    throw "unknown asar state (oldSans=$cOldSans oldMono=$cOldMono v1=$cV1Sans/$cV1Mono v2=$cV2Sans/$cV2Mono v3=$cV3Sans/$cV3Mono v4=$cV4Sans/$cV4Mono v5=$cV5Sans/$cV5Mono v6=$cV6Sans/$cV6Mono v7=$cV7Sans/$cV7Mono v8=$cV8Sans/$cV8Mono v9=$cNewSans/$cNewMono). Version changed? Refusing."
}
$baseBytes = $latin1.GetBytes($baseText)
$baseHash  = Hash-Bytes $baseBytes

# 3) make the backup equal the clean baseline (never the patched state)
$needBackupWrite = $true
if (Test-Path $backupPath) {
    if ((Get-FileHash $backupPath -Algorithm SHA256).Hash -eq $baseHash) {
        $needBackupWrite = $false
    }
}
if ($needBackupWrite) {
    [System.IO.File]::WriteAllBytes($backupPath, $baseBytes)
    [System.IO.File]::WriteAllText($hashPath, $baseHash)
    Write-Host '[2/4] backup (re)created from clean baseline'
} elseif (-not (Test-Path $hashPath) -or (Get-Content $hashPath -ErrorAction SilentlyContinue).Trim() -ne $baseHash) {
    [System.IO.File]::WriteAllText($hashPath, $baseHash)
    Write-Host '[2/4] backup verified (sidecar refreshed)'
}

# 4) apply v9 stacks onto the CURRENT asar (never onto the backup): the current
#    asar may already carry other patches (wallpaper block / update-disable), and
#    rebuilding from the backup would erase them. Equal-length replace in place.
$patched  = $text.Replace($oldSans, $newSans).Replace($oldMono, $newMono)
$newBytes = $latin1.GetBytes($patched)
if ($newBytes.Length -ne $bytes.Length) { throw "length changed: $($bytes.Length) -> $($newBytes.Length), refusing to write." }
if ((Count-Str $patched $oldSans) -ne 0) { throw 'old sans still present after replace.' }
if ((Count-Str $patched ($newSans.TrimEnd(';').TrimEnd())) -lt 1) { throw 'new sans missing after replace.' }

if ((Hash-Bytes $newBytes) -eq $asarHash) {
    Write-Host '[3/4] asar already carries the v9 stacks, nothing to write'
} else {
    [System.IO.File]::WriteAllBytes($asarPath, $newBytes)
    Write-Host '[3/4] patch written (equal-length, size unchanged, other patches preserved)'
}

if ($NoRestart) {
    Write-Host '[4/4] done (NoRestart: leave ZCode closed).'
} elseif ($zcodeExe) {
    Start-Process $zcodeExe
    Write-Host '[4/4] ZCode restarted.'
} else {
    Write-Host '[4/4] done. Start ZCode manually.'
}
Write-Host '--font-sans: "Fragment Mono" -> "SFMono-Regular" -> "HarmonyOS Sans SC" -> "PingFang SC" -> "Source Han Sans SC" -> "Noto Sans SC".'
Write-Host '--font-mono: "AnthropicMono Medium" -> "Fragment Mono" -> "SFMono-Regular" -> "HarmonyOS Sans SC" -> "Noto Sans SC" -> "PingFang SC" -> "JetBrains Mono".'
