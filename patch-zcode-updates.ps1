# ZCode desktop update-check disable patch (v1, portable) - save as UTF-8 WITHOUT BOM
# - Disables the desktop updater so ZCode never checks for updates and the green
#   "更新" chip in the sidebar never appears. Users update manually when they want.
# - Mechanism (verified by static analysis of the 3.18.2 bundle; same entry in
#   3.14.1 Ge / 3.16.3-3.17.2 pt, only the minified names change):
#   * out/main/index.js has ONE updater init entry: initAutoUpdater (minified: wP),
#     called once as  wP({enabled:ht==="production"&&nh,...})  where ht is a
#     build-time constant equal to "production" and nh a build-time boolean
#     ("&&nh" is new in 3.18.2; earlier builds ended at ==="production").
#   * wP's first branch is the app's own "product flavor disabled" switch and it
#     tests STRICT equality: if(e.enabled===!1){fp=!0; clearInterval(poll); return}
#     A numeric 0 does NOT satisfy ===false, so the older "&&0" patch form silently
#     stopped disabling on 3.18.2 (the Nov-2026 regression this form fixes).
#     With fp set: no startup check, no poll timer, no updater event handlers, no
#     UpdateStateChanged/UpdateReady IPC broadcasts, and manual "Check for updates"
#     replies {kind:"dev-skipped"} (renderer shows the toast and no badge).
# - Patch = equal-length (25-byte window) in-place replacement inside app.asar:
#     enabled:<id>==="production"    ->   enabled:<id>&&!1/*xxxxxxx*/
#   "!1" is boolean false so the strict guard fires even with the new "&&nh" term;
#   asar header offsets/sizes stay intact; every other byte untouched. Asars still
#   carrying the legacy "&&0/*xxxxxxxx*/" window are detected and upgraded in place.
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

# ---- the main-process bundle this kit patches (ZCode 3.14.1 .. 3.18.2) ----
$mainRelPath = 'out/main/index.js'

# The windows are derived from the CURRENT bundle instead of fixed per-version
# literals: only the minified identifier in front of ==="production" changes
# between builds (3.14.1: Ge, 3.16.3/3.17.2: pt, 3.18.2: ht). Every form keeps
# the identifier visible, so the file can always be reversed byte-exactly
# without an external mapping.
#   clean : enabled:<id>==="production"     -> enabled is <id> === "production"
#   legacy: enabled:<id>&&0/*xxxxxxxx*/     -> number 0; does NOT satisfy the
#           3.18.2 strict guard (enabled===!1); upgraded to the fixed form
#   fixed : enabled:<id>&&!1/*xxxxxxx*/     -> boolean false; the 15-byte
#           suffix keeps the whole window equal-length, and the JS comment
#           filler keeps the bundle syntactically valid.
$cleanPattern  = 'enabled:(\w+)==="production"'
$legacyPattern = 'enabled:(\w+)&&0/\*x{8}\*/'
$fixedPattern  = 'enabled:(\w+)&&!1/\*x{7}\*/'
$fixedSuffix   = '&&!1/*xxxxxxx*/'   # 15 bytes, same width as ==="production"

function Get-UpdatesFragments([string]$text) {
    $mc = [regex]::Matches($text, $cleanPattern)
    $ml = [regex]::Matches($text, $legacyPattern)
    $mf = [regex]::Matches($text, $fixedPattern)
    $id = ''
    if     ($mc.Count -eq 1) { $id = $mc[0].Groups[1].Value }
    elseif ($ml.Count -eq 1) { $id = $ml[0].Groups[1].Value }
    elseif ($mf.Count -eq 1) { $id = $mf[0].Groups[1].Value }
    $clean  = 'enabled:' + $id + '==="production"'
    $legacy = 'enabled:' + $id + '&&0/*xxxxxxxx*/'
    $fixed  = 'enabled:' + $id + $fixedSuffix
    if ($mc.Count -eq 1 -and $ml.Count -eq 0 -and $mf.Count -eq 0) {
        return @{ id = $id; state = 'unpatched'; clean = $clean; cur = $clean; target = $fixed }
    }
    if ($ml.Count -eq 1 -and $mc.Count -eq 0 -and $mf.Count -eq 0) {
        return @{ id = $id; state = 'legacy'; clean = $clean; cur = $legacy; target = $fixed }
    }
    if ($mf.Count -eq 1 -and $mc.Count -eq 0 -and $ml.Count -eq 0) {
        return @{ id = $id; state = 'patched'; clean = $clean; cur = $fixed; target = $null }
    }
    throw "unknown app.asar state (clean=$($mc.Count) legacy=$($ml.Count) fixed=$($mf.Count)). ZCode version changed? Update the signature in this script. Refusing."
}

function Count-Str([string]$hay, [string]$s) {
    return ([regex]::Matches($hay, [regex]::Escape($s))).Count
}
function Hash-Bytes([byte[]]$b) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($b) | ForEach-Object { $_.ToString('X2') }) -join '') } finally { $sha.Dispose() }
}
function Find-ZCodeDir {
    # toolbox resolves the folder once and passes it down (ZCODE_RESOURCES_DIR),
    # so a multi-task run does not ask for the same path in every script
    if ($env:ZCODE_RESOURCES_DIR -and (Test-Path (Join-Path $env:ZCODE_RESOURCES_DIR 'app.asar'))) { return $env:ZCODE_RESOURCES_DIR }
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
# derive the equal-length window for THIS build (identifier captured, not assumed)
$frag = Get-UpdatesFragments $mainText
$curFrag = $frag.cur
$targetFrag = $frag.target
$cleanFrag = $frag.clean
$state = $frag.state
if ($state -eq 'legacy') {
    Write-Host "[1/4] state: legacy (outdated numeric-0 patch, updater flag var: $($frag.id)) -> upgrading to strict-false form"
} else {
    Write-Host "[1/4] state: $state (updater flag var: $($frag.id))"
}

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
            # a valid backup must hold the CLEAN window exactly once and neither
            # patched form (legacy numeric-0 or fixed boolean-false) anywhere;
            # both forms are derived for the captured id so the check is uniform
            # across all three states
            $bkLegacyFrag = 'enabled:' + $frag.id + '&&0/*xxxxxxxx*/'
            $bkFixedFrag  = 'enabled:' + $frag.id + $fixedSuffix
            if ((Count-Str $bkText $cleanFrag) -eq 1 -and
                (Count-Str $bkText $bkLegacyFrag) -eq 0 -and
                (Count-Str $bkText $bkFixedFrag) -eq 0) {
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
        $cleanMain = $latin1.GetBytes($mainText.Replace($curFrag, $cleanFrag))
        if ((Count-Str ($latin1.GetString($cleanMain)) $cleanFrag) -ne 1) { throw 'cannot reconstruct clean baseline; refusing.' }
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
#    wallpaper block / zusage injection), and an asar rebuilt from the backup
#    would erase them. Equal-length 25-byte window replacement; header/offsets
#    untouched. A legacy numeric-0 window is upgraded to the strict-false form
#    on the spot, so one run always leaves the effective patch behind.
if ($state -eq 'patched') {
    Write-Host '[3/4] app.asar already carries the update-disable patch, nothing to write'
} else {
    $patchedText = $mainText.Replace($curFrag, $targetFrag)
    if ((Count-Str $patchedText $curFrag) -ne 0) { throw 'current fragment still present after replace.' }
    if ((Count-Str $patchedText $targetFrag) -ne 1) { throw 'target fragment missing after replace.' }
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
    # expected window diffs computed from the two windows themselves: both are
    # equal-length, and everything outside the window is a verbatim clone, so the
    # global diff must equal the per-char diff of cur vs target (clean->fixed: 15,
    # legacy->fixed: 4)
    $expectedDiffs = 0
    for ($i = 0; $i -lt $curFrag.Length; $i++) {
        if ($curFrag[$i] -ne $targetFrag[$i]) { $expectedDiffs++ }
    }
    if ($diffs -ne $expectedDiffs) { throw "unexpected diff byte count inside the patch window: $diffs (expected $expectedDiffs), refusing to write." }
    if ([System.Linq.Enumerable]::SequenceEqual($newAsarBytes, $asar.bytes)) { throw 'patched buffer is identical to the current asar; window copy failed.' }

    $tmpPath = "$asarPath.tmp"
    [System.IO.File]::WriteAllBytes($tmpPath, $newAsarBytes)
    # verify tmp parses as asar and holds the patch before swapping in
    $chk = Read-Asar $tmpPath
    $chkMain = Get-EntryAndBytes $chk $mainRelPath
    if (-not $chkMain -or (Count-Str ($latin1.GetString($chkMain.bytes)) $targetFrag) -ne 1) {
        Remove-Item $tmpPath -ErrorAction SilentlyContinue
        throw 'rebuilt asar failed self-check; original untouched.'
    }
    Move-Item -Force $tmpPath $asarPath
    if ($state -eq 'legacy') {
        Write-Host "[4/4] legacy numeric-0 patch upgraded in place (equal-length, $($targetFrag.Length)-byte window, $diffs bytes changed, other patches preserved)."
    } else {
        Write-Host "[4/4] patch written (equal-length, $($targetFrag.Length)-byte window, $diffs bytes changed, other patches preserved)."
    }
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
