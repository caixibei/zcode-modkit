# ZCode desktop update-check disable patch (v1, portable) - save as UTF-8 WITHOUT BOM
# - Disables the desktop updater so ZCode never checks for updates and the green
#   "更新" chip in the sidebar never appears. Users update manually when they want.
# - Mechanism (ZCode 3.16.3, verified by static analysis of app.asar; the same
#   initAutoUpdater entry exists in 3.14.1, only the minified var name changed):
#   * out/main/index.js has ONE updater init entry: initAutoUpdater (minified: Ly),
#     called once as  Ly({enabled:pt==="production",...})  where pt is a build-time
#     constant equal to "production" (3.14.1 named it Ge).
#   * Ly's first branch is the app's own "product flavor disabled" switch:
#     if(e.enabled===!1){Gd=!0; clearInterval(poll timer); return}
#     With Gd set: no startup check, no hourly poll (mM=3600e3 never scheduled),
#     no updater event handlers, no UpdateStateChanged/UpdateReady IPC broadcasts,
#     and manual "Check for updates" replies {kind:"dev-skipped"} (renderer shows
#     the "开发环境不检查更新" toast and no badge).
# - Patch = equal-length (25 bytes) in-place replacement inside app.asar:
#     enabled:pt==="production"   ->   enabled:!1/*xxxxxxxxxxx*/
#   asar header offsets/sizes stay intact; every other byte untouched.
# - The green chip is rendered by the renderer from main's update state only
#   (getUpdateState IPC + UpdateStateChanged events); with the updater disabled
#   the state stays {kind:"idle"} forever, so the chip cannot appear.
# - Backup = clean original app.asar of THIS machine; an existing verified backup
#   is never overwritten; a missing backup is self-healed by reverse replacement.
# - Idempotent when already patched; refuses on unknown state (version changed).
# - Coexists with font/wallpaper patches: those touch renderer CSS only, this
#   patch touches out/main/index.js only.
# - Exits automatically on success; pauses only on errors
# Revert with restore-zcode-updates.bat
param(
    [switch]$NoRestart,   # toolbox mode: do not relaunch ZCode after patching
    [string]$TargetAsar     # advanced/testing: operate on this app.asar instead of the auto-located one (skips the running check)
)
$ErrorActionPreference = 'Stop'
# Clear NODE_OPTIONS from this process so the ZCode.exe we (re)start never
# inherits unsupported flags (packaged Electron apps print a startup ERROR for
# e.g. --max-old-space-size); the machine/user registry value is NOT touched.
try { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue } catch {}
$latin1 = [System.Text.Encoding]::GetEncoding(28591)  # lossless byte<->char round-trip (all patch strings are pure ASCII)

$backupPath = Join-Path $PSScriptRoot 'app.asar.updates-backup'
$hashPath   = Join-Path $PSScriptRoot 'app.asar.updates-backup.sha256'

# ---- the main-process bundle this kit patches (ZCode 3.14.1 / 3.16.3) ----
$mainRelPath = 'out/main/index.js'

# original fragment: must occur exactly once in out/main/index.js
$oldFrag = 'enabled:pt==="production"'        # 25 bytes
# patched fragment: equal length; JS comment filler keeps the bundle valid
$newFrag = 'enabled:!1/*xxxxxxxxxxx*/'        # 25 bytes

function Count-Str([string]$hay, [string]$s) {
    return ([regex]::Matches($hay, [regex]::Escape($s))).Count
}
function Hash-Bytes([byte[]]$b) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($b) | ForEach-Object { $_.ToString('X2') }) -join '') } finally { $sha.Dispose() }
}
function Find-ZCodeDir {
    # all branches return the resources dir (the folder containing app.asar)
    try {
        $p = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1
        if ($p) {
            $cand = Join-Path (Split-Path $p.Path -Parent) 'resources\app.asar'
            if (Test-Path $cand) { return (Split-Path $cand -Parent) }
        }
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

# ---- asar primitives (same reader as the wallpaper kit) ----------------------------
function Read-Asar([string]$path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $hdrTotal    = [BitConverter]::ToUInt32($bytes, 4)
    $jsonLen     = [BitConverter]::ToUInt32($bytes, 12)
    $json        = [System.Text.Encoding]::UTF8.GetString($bytes, 16, [int]$jsonLen)
    $header      = $json | ConvertFrom-Json
    return @{
        bytes        = $bytes
        header       = $header
        contentBase  = 8 + [int]$hdrTotal
    }
}
function Get-EntryAndBytes($asar, [string]$relPath) {
    # walk directories by path segments ('/'-separated), return file node + bytes
    $parts = $relPath -split '/'
    $node = $asar.header
    $last = $parts[-1]
    foreach ($seg in ($parts | Select-Object -First ($parts.Count - 1))) {
        if (-not $node.files -or -not $node.files.PSObject.Properties[$seg]) { return $null }
        $node = $node.files.$seg
    }
    if (-not $node.files -or -not $node.files.PSObject.Properties[$last]) { return $null }
    $file = $node.files.$last
    if ($file.unpacked -or $file.link) { return $null }
    $len = [int]$file.size
    $off = [long]$file.offset
    $bytes = New-Object byte[] $len
    [Array]::Copy($asar.bytes, $asar.contentBase + $off, $bytes, 0, $len)
    return @{ node = $file; bytes = $bytes }
}

# ================= main =================
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

# 1) read current asar, extract main bundle, detect state
$asar = Read-Asar $asarPath
$mainHit = Get-EntryAndBytes $asar $mainRelPath
if (-not $mainHit) {
    throw "main bundle not found in this ZCode build ($mainRelPath). Version changed? Refusing."
}
$mainText = $latin1.GetString($mainHit.bytes)
$cOld = Count-Str $mainText $oldFrag
$cNew = Count-Str $mainText $newFrag

if ($cOld -eq 1) {
    $state = 'unpatched'
} elseif ($cNew -eq 1) {
    $state = 'patched'
} else {
    throw "unknown app.asar state (old=$cOld new=$cNew). ZCode version changed? Update the signature in this script. Refusing."
}
Write-Host "[1/4] state: $state"

# 2) backup must hold the clean (unpatched) asar of this machine
$needBackupWrite = $true
if (Test-Path $backupPath) {
    $sidecarOk = $false
    if (Test-Path $hashPath) {
        $expect = (Get-Content $hashPath -ErrorAction SilentlyContinue)
        $actual = (Get-FileHash $backupPath -Algorithm SHA256).Hash
        $sidecarOk = ($expect -and ($actual -eq $expect.Trim()))
    }
    if ($sidecarOk) {
        $bk = Read-Asar $backupPath
        $bkMain = Get-EntryAndBytes $bk $mainRelPath
        if ($bkMain) {
            $bkText = $latin1.GetString($bkMain.bytes)
            if ((Count-Str $bkText $oldFrag) -eq 1 -and (Count-Str $bkText $newFrag) -eq 0) {
                $needBackupWrite = $false
            }
        }
    }
}
if ($needBackupWrite) {
    if ($state -eq 'unpatched') {
        # current asar has no patch: keep a BYTE-IDENTICAL copy so a later
        # restore returns the exact factory file (hash-equal)
        Copy-Item -Force $asarPath "$backupPath.tmp"
        Move-Item -Force "$backupPath.tmp" $backupPath
        Write-Host '[2/4] backup (re)created (byte-identical clean asar)'
    } else {
        # patched asar without a valid backup: rebuild the clean original by
        # reverse replacement (equal-length, header untouched)
        $cleanMain = $latin1.GetBytes($mainText.Replace($newFrag, $oldFrag))
        if ((Count-Str ($latin1.GetString($cleanMain)) $oldFrag) -ne 1) { throw 'cannot reconstruct clean baseline; refusing.' }
        $cleanAsarBytes = [byte[]]$asar.bytes.Clone()
        $fileStart = [long]$asar.contentBase + [long]$mainHit.node.offset
        [Array]::Copy($cleanMain, 0, $cleanAsarBytes, $fileStart, $cleanMain.Length)
        [System.IO.File]::WriteAllBytes("$backupPath.tmp", $cleanAsarBytes)
        Move-Item -Force "$backupPath.tmp" $backupPath
        Write-Host '[2/4] backup (re)created from clean baseline'
    }
    [System.IO.File]::WriteAllText($hashPath, (Hash-Bytes ([System.IO.File]::ReadAllBytes($backupPath))))
} else {
    Write-Host '[2/4] clean backup verified'
}

# 3) apply the patch onto the CURRENT asar in place (never rebuild from the
#    backup): the current asar may already carry other patches (font stacks /
#    wallpaper block), and an asar rebuilt from the backup would erase them.
#    Equal-length 25-byte window replacement; header/offsets untouched.
if ($state -eq 'patched') {
    Write-Host '[3/4] app.asar already carries the update-disable patch, nothing to write'
} else {
    $patchedText = $mainText.Replace($oldFrag, $newFrag)
    if ((Count-Str $patchedText $oldFrag) -ne 0) { throw 'old fragment still present after replace.' }
    if ((Count-Str $patchedText $newFrag) -ne 1) { throw 'new fragment missing after replace.' }
    $patchedMain = $latin1.GetBytes($patchedText)
    if ($patchedMain.Length -ne $mainHit.bytes.Length) { throw 'patch must be equal-length; length mismatch, refusing to write.' }

    $newAsarBytes = [byte[]]$asar.bytes.Clone()
    $fileStart = [long]$asar.contentBase + [long]$mainHit.node.offset
    [Array]::Copy($patchedMain, 0, $newAsarBytes, $fileStart, $patchedMain.Length)

    # self-check: the patch is an equal-length in-place replacement, so the new
    # asar can only differ from the current one inside the 25-byte window (the
    # rest of the buffer is a verbatim clone). Count diffs inside the window
    # (fast), then confirm globally via .NET SequenceEqual that the buffers are
    # NOT identical (copy actually landed) without a per-byte PowerShell loop —
    # a full 322M-iteration loop here used to run for tens of minutes.
    $diffs = 0
    for ($i = 0; $i -lt $patchedMain.Length; $i++) {
        if ($patchedMain[$i] -ne $mainHit.bytes[$i]) { $diffs++ }
    }
    if ($diffs -ne 17) { throw "unexpected diff byte count inside the patch window: $diffs (expected 17), refusing to write." }
    if ([System.Linq.Enumerable]::SequenceEqual($newAsarBytes, $asar.bytes)) { throw 'patched buffer is identical to the current asar; window copy failed.' }

    $tmpPath = "$asarPath.tmp"
    [System.IO.File]::WriteAllBytes($tmpPath, $newAsarBytes)
    # verify tmp parses as asar and holds the patch before swapping in
    $chk = Read-Asar $tmpPath
    $chkMain = Get-EntryAndBytes $chk $mainRelPath
    if (-not $chkMain -or (Count-Str ($latin1.GetString($chkMain.bytes)) $newFrag) -ne 1) {
        Remove-Item $tmpPath -ErrorAction SilentlyContinue
        throw 'rebuilt asar failed self-check; original untouched.'
    }
    Move-Item -Force $tmpPath $asarPath
    Write-Host '[4/4] patch written (equal-length, 25-byte window, 17 bytes changed, other patches preserved).'
}

if ($NoRestart) {
    Write-Host 'done (NoRestart: leave ZCode closed).'
} elseif ($zcodeExe) {
    Start-Process $zcodeExe
    Write-Host 'ZCode restarted.'
} else {
    Write-Host 'done. Start ZCode manually.'
}
Write-Host 'Update checks are disabled: no polling, no green update badge. Update manually by downloading new releases.'
