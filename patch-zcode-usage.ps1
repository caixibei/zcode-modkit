# ZCode usage-retention patch (v1, portable) - save as UTF-8 WITHOUT BOM
# - Stops ZCode from auto-deleting historical usage statistics. The "累计 Token 数"
#   card in Settings -> Usage is NOT lifetime: the agent runtime keeps a 30-day
#   rolling window and deletes older rows on every usage write, so the total
#   shrinks as heavy days fall out of the window.
# - Mechanism (verified by static analysis of resources\glm\zcode.cjs, 3.14.3):
#   * Every usage write (recordModelUsage / upsertTurnUsage / upsertToolUsage)
#     ends with a call to the minified prune function: KPe(db, {beforeTime}).
#   * KPe runs  DELETE FROM model_usage / turn_usage / tool_usage
#               WHERE started_at < (t.beforeTime ?? Date.now() - hos)
#     inside one transaction.
#   * hos = mos*24*60*60*1e3 with mos = 30 (days). hos is referenced ONLY inside
#     KPe, so widening it to 9e15 ms (~285k years) disables pruning without any
#     other behavioral change; the retention constant stays visibly "=30" for
#     readability. beforeTime callers (none today) could still prune explicitly.
# - Patch = equal-length (27 bytes) in-place replacement in zcode.cjs:
#     mos=30,hos=mos*24*60*60*1e3  ->  mos=30,hos=9e15/*xxxxxxxx*/
#   zcode.cjs is a standalone file (NOT inside the asar archive), so equal-length
#   keeps every byte offset stable and the file loads exactly as before.
# - Signature is regex-based (captures the minified variable names) instead of a
#   fixed per-version fragment table, so minor version bumps that only rename
#   minified identifiers still match. A version bump that restructures the prune
#   code itself falls back to "unknown state" and the script refuses to touch it.
# - Backup = clean original zcode.cjs of THIS machine; an existing verified backup
#   is never overwritten; a missing backup is self-healed by reverse replacement.
# - Idempotent when already patched; pauses only on errors.
# - Coexists with the title patch: different byte regions of zcode.cjs, and both
#   patch/restore scripts only do equal-length in-place replacement, never a
#   whole-file overwrite from backup.
# Revert with restore-zcode-usage.bat
param(
    [switch]$NoRestart,   # toolbox mode: do not relaunch ZCode after patching
    [string]$TargetCjs    # advanced/testing: operate on this zcode.cjs instead of the auto-located one (skips the running check)
)
$ErrorActionPreference = 'Stop'
$latin1 = [System.Text.Encoding]::GetEncoding(28591)  # lossless byte<->char round-trip (all patch strings are pure ASCII)

$backupPath = $null
$hashPath   = $null

# ---- signature: retention constants "X=30,Y=X*24*60*60*1e3" (X/Y are minified ids)
# regex captures the exact identifier pair (the multiplier X is group 1, \1 backrefs
# it inside the ms expression) so the reverse replacement is byte-exact
$retentionRegex = '(\w+)=30,(\w+)=\1\*24\*60\*60\*1e3'
# patched form: X=30,Y=9e15 + a /*xxx*/ filler; the multiplier is X (group 1),
# which the reverse path must preserve (Y=X*... in the clean fragment)
$patchedReverseRegex = '(\w+)=30,(\w+)=9e15/\*x+\*/'

function Get-PatchedFragment([string]$orig) {
    # equal-length rewrite: keep "X=30," visible, replace the ms expression with
    # 9e15 (~285,000 years) and pad the rest with a JS comment
    $m = [regex]::Match($orig, "^$retentionRegex$")
    if (-not $m.Success) { throw "fragment does not match the retention signature: $orig" }
    $a = $m.Groups[1].Value; $b = $m.Groups[2].Value
    $prefix = '{0}=30,{1}=9e15' -f $a, $b
    $filler = $orig.Length - $prefix.Length - 4   # '/*' + x... + '*/'
    if ($filler -lt 0) { throw 'patched form longer than the original fragment; cannot build an equal-length replacement' }
    $new = $prefix + '/*' + ('x' * $filler) + '*/'
    if ($new.Length -ne $orig.Length) { throw "patched fragment length mismatch: $($new.Length) vs $($orig.Length)" }
    return $new
}
function ConvertTo-PatchedText([string]$text) {
    # replace every retention-constant occurrence (expected exactly one); returns (text, count)
    $ms = [regex]::Matches($text, $retentionRegex)
    foreach ($m in $ms) {
        $text = $text.Replace($m.Value, (Get-PatchedFragment $m.Value))
    }
    return @($text, $ms.Count)
}
function ConvertTo-CleanText([string]$text) {
    # reverse: X=30,Y=9e15/*...*/ back to X=30,Y=X*24*60*60*1e3 (byte-exact)
    $ms = [regex]::Matches($text, $patchedReverseRegex)
    foreach ($m in $ms) {
        $clean = '{0}=30,{1}={0}*24*60*60*1e3' -f $m.Groups[1].Value, $m.Groups[2].Value
        if ($clean.Length -ne $m.Value.Length) { throw "reverse fragment length mismatch: $($clean.Length) vs $($m.Value.Length)" }
        $text = $text.Replace($m.Value, $clean)
    }
    return @($text, $ms.Count)
}
function Count-Str([string]$hay, [string]$s) {
    return ([regex]::Matches($hay, [regex]::Escape($s))).Count
}
function Hash-Bytes([byte[]]$b) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($b) | ForEach-Object { $_.ToString('X2') }) -join '') } finally { $sha.Dispose() }
}
function Find-ZCodeDir {
    # returns the install dir containing ZCode.exe (parent of resources\glm)
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
                $cand = Join-Path $hit.InstallLocation 'resources\glm\zcode.cjs'
                if (Test-Path $cand) { return (Split-Path (Split-Path $cand -Parent) -Parent) }
            }
        } catch {}
    }
    $candidates = @('D:\installer\zcode', "$env:LOCALAPPDATA\Programs\zcode", "$env:ProgramFiles\zcode", "${env:ProgramFiles(x86)}\zcode")
    foreach ($d in $candidates) {
        try {
            if (-not (Test-Path $d)) { continue }
            $cand = Join-Path $d 'resources\glm\zcode.cjs'
            if (Test-Path $cand) { return (Split-Path (Split-Path $cand -Parent) -Parent) }
        } catch { continue }
    }
    return $null
}

# ================= main =================
$installDir = Find-ZCodeDir
if (-not $installDir) {
    Write-Host '[?] Could not auto-locate ZCode. Example: D:\installer\zcode\resources\glm' -ForegroundColor Yellow
    $manual = Read-Host 'Enter the folder that contains zcode.cjs (resources\glm dir)'
    if (-not $manual -or -not (Test-Path (Join-Path $manual 'zcode.cjs'))) {
        Write-Host "[X] zcode.cjs not found under: $manual" -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
    $installDir = $manual
}
$cjsPath  = Join-Path $installDir 'resources\glm\zcode.cjs'
$zcodeExe = Join-Path $installDir 'ZCode.exe'
if (-not (Test-Path $zcodeExe)) { $zcodeExe = $null }
if ($TargetCjs) {
    # explicit override (toolbox/testing): operate on the given file and skip
    # the running-process guard, so the caller controls those concerns
    $cjsPath = $TargetCjs
    $zcodeExe = $null
    Write-Host "target (override): $cjsPath"
} else {
    Write-Host "target: $cjsPath"
}

# 0) ZCode must not be running (zcode.cjs is memory-mapped/locked by worker processes)
if (-not $TargetCjs) {
    $procs = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Host '[X] ZCode is running, zcode.cjs is locked.' -ForegroundColor Red
        Write-Host '    Quit ZCode first (right-click tray icon -> Quit; clicking X may only minimize to tray).' -ForegroundColor Yellow
        Read-Host 'Press Enter to exit'
        exit 1
    }
}

# 1) read current file and detect state
$bytes   = [System.IO.File]::ReadAllBytes($cjsPath)
$text    = $latin1.GetString($bytes)
$cjsHash = Hash-Bytes $bytes

# state detection: count CLEAN and PATCHED fragment occurrences independently
$cClean = ([regex]::Matches($text, $retentionRegex)).Count
$cPatch = ([regex]::Matches($text, $patchedReverseRegex)).Count

if ($cClean -eq 1 -and $cPatch -eq 0) {
    $state = 'unpatched'
} elseif ($cPatch -eq 1 -and $cClean -eq 0) {
    $state = 'patched'
} else {
    throw "unknown zcode.cjs state (retention clean=$cClean patched=$cPatch). ZCode version changed or file already modified in an unrecognized way? Refusing."
}
Write-Host "[1/4] state: $state"

# 2) backup must hold the clean (unpatched) file of this machine; the backup
#    lives NEXT TO THE TARGET FILE (each ZCode install keeps its own baseline;
#    -TargetCjs test runs therefore never pollute the kit directory)
$backupPath = Join-Path (Split-Path $cjsPath -Parent) 'zcode.cjs.usage-backup'
$hashPath   = "$backupPath.sha256"
$baseText = $null
if ($state -eq 'unpatched') {
    $baseText = $text
} else {
    # patched: prefer a verified clean backup, otherwise rebuild via reverse replacement
    $backupUsable = $false
    if (Test-Path $backupPath) {
        $sidecarOk = $false
        if (Test-Path $hashPath) {
            $expect = (Get-Content $hashPath -ErrorAction SilentlyContinue)
            $actual = (Get-FileHash $backupPath -Algorithm SHA256).Hash
            $sidecarOk = ($expect -and ($actual -eq $expect.Trim()))
        }
        if ($sidecarOk) {
            $bt = $latin1.GetString([System.IO.File]::ReadAllBytes($backupPath))
            $btClean, $btCount = ConvertTo-CleanText $bt
            if ($btCount -eq 1 -and ([regex]::Matches($bt, $retentionRegex)).Count -eq 1) {
                $baseText = $bt
                $backupUsable = $true
                Write-Host '[2/4] clean backup verified'
            }
        }
    }
    if (-not $backupUsable) {
        $cleanText, $null = ConvertTo-CleanText $text
        $baseText = $cleanText
        Write-Host '[2/4] clean backup missing/invalid, reconstructed by reverse replacement'
    }
}
$baseBytes = $latin1.GetBytes($baseText)
$baseHash  = Hash-Bytes $baseBytes

$needBackupWrite = $true
if (Test-Path $backupPath) {
    if ((Get-FileHash $backupPath -Algorithm SHA256).Hash -eq $baseHash) { $needBackupWrite = $false }
}
if ($needBackupWrite) {
    [System.IO.File]::WriteAllBytes("$backupPath.tmp", $baseBytes)
    Move-Item -Force "$backupPath.tmp" $backupPath
    [System.IO.File]::WriteAllText($hashPath, $baseHash)
    Write-Host '[2/4] backup (re)created from clean baseline'
} elseif (-not (Test-Path $hashPath) -or (Get-Content $hashPath -ErrorAction SilentlyContinue).Trim() -ne $baseHash) {
    [System.IO.File]::WriteAllText($hashPath, $baseHash)
    Write-Host '[2/4] backup verified (sidecar refreshed)'
}

# 3) apply the patch onto the CURRENT file in place (never rebuild from the
#    backup): the current file may already carry other patches (title fix), and
#    a whole-file rewrite from the backup would erase them.
if ($state -eq 'patched') {
    Write-Host '[3/4] zcode.cjs already carries the usage-retention patch, nothing to write'
} else {
    $patchedOut, $cnt = ConvertTo-PatchedText $baseText
    if ($cnt -ne 1) { throw "expected exactly one retention-constant occurrence in the baseline, got $cnt" }
    $newBytes = $latin1.GetBytes($patchedOut)
    if ($newBytes.Length -ne $baseBytes.Length) { throw 'patch must be equal-length; length mismatch, refusing to write.' }

    $diffs = 0
    for ($i = 0; $i -lt $newBytes.Length; $i++) {
        if ($newBytes[$i] -ne $baseBytes[$i]) { $diffs++ }
    }
    if ($diffs -ne 16) { throw "unexpected diff byte count: $diffs (expected 16), refusing to write." }

    [System.IO.File]::WriteAllBytes("$cjsPath.tmp", $newBytes)
    Move-Item -Force "$cjsPath.tmp" $cjsPath
    Write-Host '[3/4] patch written (equal-length, 27-byte window, 16 bytes changed).'
}

# 4) restart / finish
if ($NoRestart) {
    Write-Host '[4/4] done (NoRestart: leave ZCode closed).'
} elseif ($zcodeExe) {
    Start-Process $zcodeExe
    Write-Host '[4/4] ZCode restarted.'
} else {
    Write-Host '[4/4] done. Start ZCode manually.'
}
Write-Host 'Usage history is no longer pruned: the 累计 Token 数 card now keeps growing across window boundaries. Existing rows deleted before this patch cannot be recovered.'
