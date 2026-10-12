# ZCode session title patch (v3, portable) - restore auto title generation
# - Targets resources\glm\zcode.cjs (agent CLI runtime), NOT app.asar
# - Regression (3.12.3 through 3.14.1, still present): eligibility check requires
#   truthy config.titleGeneration, but the desktop host passes {} and an upstream
#   merge can leave it undefined -> eligibility functions bail out silently and no
#   session_title model request is ever issued.
#   Patch removes the "||!e.config.titleGeneration" clause from BOTH eligibility
#   functions using an equal-length /*...*/ filler.
#   Function names are minified per version, so this kit carries a per-version
#   signature table:
#     3.12.3: FYi / NYi / _J
#     3.14.1: Pba / Tba / Zye
# - Weak language rule fix: the title prompt rule "- Use the user's primary
#   language." is too weak for some models (e.g. minimax-m3 answered an all-Chinese
#   input with an English title). Strengthened to "- MUST use the user's primary
#   language." (+5 bytes). zcode.cjs is a standalone file (NOT inside the asar
#   archive), so a small size change is safe: no offsets or headers depend on it.
# - Backup = clean original zcode.cjs of THIS machine; an existing verified backup is
#   never overwritten; missing backup is self-healed by reverse replacement
# - Upgrades v1/v2 in place; idempotent when already patched
# - Exits automatically on success; pauses only on errors
# Revert with restore-zcode-title.bat
param(
    [switch]$NoRestart,   # toolbox mode: do not relaunch ZCode after patching
    [string]$TargetCjs    # advanced/testing: operate on this zcode.cjs instead of the auto-located one (skips the running check)
)
$ErrorActionPreference = 'Stop'
$latin1 = [System.Text.Encoding]::GetEncoding(28591)  # lossless byte<->char round-trip (all patch strings are pure ASCII)

$backupPath = Join-Path $PSScriptRoot 'zcode.cjs.title-backup'
$hashPath   = Join-Path $PSScriptRoot 'zcode.cjs.title-backup.sha256'

# ---- per-version signature table ----
# Each entry: original eligibility fragments (must occur exactly once each) + shared
# language-rule fragment. The filler logic is identical across versions (drop the
# 27-char "||!e.config.titleGeneration" clause, pad with a 27-char /*...*/ comment).
$versions = @(
    @{
        tag    = '3.14.1'
        eligA  = 'function Pba(e,t,n={}){if(e.sessionTitleGenerationAttempted||e.config.titleGeneration?.enabled===!1||!e.config.titleGeneration||!e.sessionStore||e.config.parentSessionId||e.config.taskType&&e.config.taskType!=="interactive"||e.turnNumber!==0)return!1;'
        eligB  = 'function Tba(e,t,n){return e.config.titleGeneration?.enabled===!1||!e.config.titleGeneration||!e.sessionStore||e.config.parentSessionId||e.config.taskType&&e.config.taskType!=="interactive"||n.trim().length===0?!1:Zye(t).length>0}'
    },
    @{
        tag    = '3.12.3'
        eligA  = 'function FYi(e,t,r={}){if(e.sessionTitleGenerationAttempted||e.config.titleGeneration?.enabled===!1||!e.config.titleGeneration||!e.sessionStore||e.config.parentSessionId||e.config.taskType&&e.config.taskType!=="interactive"||e.turnNumber!==0)return!1;'
        eligB  = 'function NYi(e,t,r){return e.config.titleGeneration?.enabled===!1||!e.config.titleGeneration||!e.sessionStore||e.config.parentSessionId||e.config.taskType&&e.config.taskType!=="interactive"||r.trim().length===0?!1:_J(t).length>0}'
    }
)
$oldLang = "- Use the user's primary language."
$newLang = "- MUST use the user's primary language."
$langDelta = $newLang.Length - $oldLang.Length   # +5

function Count-Str([string]$hay, [string]$s) {
    return ([regex]::Matches($hay, [regex]::Escape($s))).Count
}
function Hash-Bytes([byte[]]$b) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($b) | ForEach-Object { $_.ToString('X2') }) -join '') } finally { $sha.Dispose() }
}
# Build patched (new) forms for a signature entry
function New-PatchedPair([string]$a, [string]$b) {
    $filler = '/*' + ('x' * 23) + '*/'   # 27 chars, JS comment -> no runtime effect
    $na = $a.Replace('||!e.config.titleGeneration', '').Replace('{if(', '{' + $filler + 'if(')
    $nb = $b.Replace('||!e.config.titleGeneration', '').Replace('{return ', '{' + $filler + 'return ')
    if ($na.Length -ne $a.Length) { throw "eligA patch length mismatch for current signature, aborting." }
    if ($nb.Length -ne $b.Length) { throw "eligB patch length mismatch for current signature, aborting." }
    return @($na, $nb)
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
                $cand = Join-Path $hit.InstallLocation 'resources\glm\zcode.cjs'
                if (Test-Path $cand) { return (Split-Path $cand -Parent) }
            }
        } catch {}
    }
    # 3) common dirs
    $candidates = @('D:\installer\zcode', "$env:LOCALAPPDATA\Programs\zcode", "$env:ProgramFiles\zcode", "${env:ProgramFiles(x86)}\zcode")
    foreach ($d in $candidates) {
        try {
            if (-not (Test-Path $d)) { continue }
            $cand = Join-Path $d 'resources\glm\zcode.cjs'
            if (Test-Path $cand) { return (Split-Path $cand -Parent) }
        } catch { continue }
    }
    return $null
}

$glmDir = Find-ZCodeDir
if (-not $glmDir) {
    Write-Host '[?] Could not auto-locate ZCode. Example: D:\installer\zcode\resources\glm' -ForegroundColor Yellow
    $manual = Read-Host 'Enter the folder that contains zcode.cjs (resources\glm dir)'
    if (-not $manual -or -not (Test-Path (Join-Path $manual 'zcode.cjs'))) {
        Write-Host "[X] zcode.cjs not found under: $manual" -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
    $glmDir = $manual
}
$cjsPath  = Join-Path $glmDir 'zcode.cjs'
$zcodeExe = Join-Path (Split-Path (Split-Path $cjsPath -Parent) -Parent) 'ZCode.exe'
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
$procs = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue
if ($procs -and -not $TargetCjs) {
    Write-Host '[X] ZCode is running, zcode.cjs is locked.' -ForegroundColor Red
    Write-Host '    Quit ZCode first (right-click tray icon -> Quit; clicking X may only minimize to tray).' -ForegroundColor Yellow
    Read-Host 'Press Enter to exit'
    exit 1
}

# 1) read current file and match it against the signature table
$bytes   = [System.IO.File]::ReadAllBytes($cjsPath)
$text    = $latin1.GetString($bytes)
$cjsHash = Hash-Bytes $bytes

$cOldLang = Count-Str $text $oldLang
$cNewLang = Count-Str $text $newLang
$isLangClean   = ($cOldLang -eq 1)
$isLangPatched = ($cNewLang -eq 1)

# upstream-fixed check (ZCode 3.14.3+): the fix shipped upstream is byte-identical
# to this kit's patched form, so a patched-pair match with the strengthened language
# rule and no weak rule means the fix is ALREADY present (upstream or kit) and the
# kit must not touch the file — "restoring" here would reintroduce the bug.
if ($isLangPatched -and -not $isLangClean) {
    foreach ($v in $versions) {
        $ua, $ub = New-PatchedPair $v.eligA $v.eligB
        if ((Count-Str $text $ua) -eq 1 -and (Count-Str $text $ub) -eq 1) {
            Write-Host "[1/4] title fix already present (shipped upstream in this ZCode build or applied by this kit); nothing to patch."
            if ($NoRestart) {
                Write-Host '[4/4] done (NoRestart: leave ZCode closed).'
            } elseif ($zcodeExe) {
                Start-Process $zcodeExe
                Write-Host '[4/4] ZCode restarted.'
            } else {
                Write-Host '[4/4] done. Start ZCode manually.'
            }
            exit 0
        }
    }
}

$sig = $null; $sigTag = ''; $state = 'unknown'
$counts = @()
foreach ($v in $versions) {
    $na, $nb = New-PatchedPair $v.eligA $v.eligB
    $ca = Count-Str $text $v.eligA; $cb = Count-Str $text $v.eligB
    $naCnt = Count-Str $text $na;   $nbCnt = Count-Str $text $nb
    $counts += "[$($v.tag)] A=$ca/$naCnt B=$cb/$nbCnt"
    $cleanPair   = ($ca -eq 1 -and $cb -eq 1)
    $patchedPair = ($naCnt -eq 1 -and $nbCnt -eq 1)
    if ($cleanPair -and $isLangClean)   { $sig = $v; $sigTag = $v.tag; $state = 'unpatched'; break }
    if ($patchedPair -and $isLangPatched) { $sig = $v; $sigTag = $v.tag; $state = 'v2v3'; break }
    if ($patchedPair -and $isLangClean)   { $sig = $v; $sigTag = $v.tag; $state = 'v1'; break }
}

function Get-CleanBaseline($sig) {
    # baseline = existing backup if it verifies as a clean original for THIS signature...
    if (Test-Path $backupPath) {
        $sidecarOk = $false
        if (Test-Path $hashPath) {
            $expect = (Get-Content $hashPath -ErrorAction SilentlyContinue)
            $actual = (Get-FileHash $backupPath -Algorithm SHA256).Hash
            $sidecarOk = ($expect -and ($actual -eq $expect.Trim()))
        }
        if ($sidecarOk) {
            $bt = $latin1.GetString([System.IO.File]::ReadAllBytes($backupPath))
            if ((Count-Str $bt $sig.eligA) -eq 1 -and (Count-Str $bt $sig.eligB) -eq 1 -and (Count-Str $bt $oldLang) -eq 1) {
                Write-Host '[2/4] clean backup verified'
                return $bt
            }
        }
    }
    # ...otherwise self-heal: reverse the patch to rebuild the clean original
    $na, $nb = New-PatchedPair $sig.eligA $sig.eligB
    $rt = $text.Replace($na, $sig.eligA).Replace($nb, $sig.eligB).Replace($newLang, $oldLang)
    if ((Count-Str $rt $sig.eligA) -ne 1 -or (Count-Str $rt $sig.eligB) -ne 1 -or (Count-Str $rt $oldLang) -ne 1) {
        throw 'clean backup missing/invalid and cannot be reconstructed from the patched file; refusing.'
    }
    Write-Host '[2/4] clean backup missing/invalid, reconstructed from patched file'
    return $rt
}

$baseText = $null
if ($state -eq 'unpatched') {
    Write-Host "[1/4] state: unpatched (ZCode $sigTag original)"
    $baseText = $text
} elseif ($state -eq 'v2v3') {
    Write-Host "[1/4] state: title patch already applied (ZCode $sigTag)"
    $baseText = Get-CleanBaseline $sig
} elseif ($state -eq 'v1') {
    Write-Host "[1/4] state: v1 patch detected (ZCode $sigTag) - upgrading: strengthening language rule"
    $baseText = Get-CleanBaseline $sig
} else {
    throw "unknown zcode.cjs state (lang=$cOldLang/$cNewLang; $($counts -join ' ')). ZCode version changed? Update the signature table in this script. Refusing."
}

# baseline must belong to the SAME zcode.cjs generation as the target file:
# a same-length difference outside the known patch windows means the backup was
# taken from a different version (or carries foreign patches) and must not be
# promoted to the baseline of this file
if ($baseText.Length -ne $text.Length) {
    # the language rule shifts length by exactly $langDelta; anything else is a
    # version mismatch (e.g. -TargetCjs pointing at another install)
    Write-Host "[X] backup baseline length $($baseText.Length) != target length $($text.Length) (allowed delta: $langDelta)." -ForegroundColor Red
    Write-Host '    The backup belongs to a different ZCode build; refusing to reuse or overwrite it.' -ForegroundColor Red
    Write-Host '    Delete the stale zcode.cjs.title-backup files to let this script take a fresh baseline.' -ForegroundColor Yellow
    Read-Host 'Press Enter to exit'
    exit 1
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

# 4) apply the patch onto the baseline and write only if content changes
$na, $nb = New-PatchedPair $sig.eligA $sig.eligB
$patched  = $baseText.Replace($sig.eligA, $na).Replace($sig.eligB, $nb).Replace($oldLang, $newLang)
$newBytes = $latin1.GetBytes($patched)
# eligibility swaps are equal-length; the language rule adds exactly $langDelta bytes
$expectedLen = $baseBytes.Length + $langDelta
if ($newBytes.Length -ne $expectedLen) { throw "unexpected length: $($baseBytes.Length) -> $($newBytes.Length) (expected $expectedLen), refusing to write." }
if ((Count-Str $patched $sig.eligA) -ne 0 -or (Count-Str $patched $sig.eligB) -ne 0 -or (Count-Str $patched $oldLang) -ne 0) { throw 'old fragment still present after replace.' }
if ((Count-Str $patched $na) -ne 1 -or (Count-Str $patched $nb) -ne 1 -or (Count-Str $patched $newLang) -ne 1) { throw 'new fragment missing after replace.' }

if ((Hash-Bytes $newBytes) -eq $cjsHash) {
    Write-Host '[3/4] zcode.cjs already carries the title patch, nothing to write'
} else {
    [System.IO.File]::WriteAllBytes($cjsPath, $newBytes)
    Write-Host "[3/4] patch written (ZCode $sigTag; eligibility equal-length; language rule +$langDelta bytes)"
}

if ($NoRestart) {
    Write-Host '[4/4] done (NoRestart: leave ZCode closed).'
} elseif ($zcodeExe) {
    Start-Process $zcodeExe
    Write-Host '[4/4] ZCode restarted.'
} else {
    Write-Host '[4/4] done. Start ZCode manually.'
}
Write-Host 'Auto session title generation is restored; titles now MUST follow the user primary language.'
