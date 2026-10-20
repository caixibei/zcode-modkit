# ZCode session title patch v4 (last-turn context)
# - Targets resources\glm\zcode.cjs (agent CLI runtime), NOT app.asar
# - Supersedes patch-zcode-title.ps1: applies the same base fix (missing
#   config.titleGeneration guard + MUST language rule) and adds the last-turn
#   behavior:
#     1) title generation is no longer limited to turnNumber===0; it runs after
#        the first turn that completes successfully (so a cancelled first turn
#        no longer loses the title forever);
#     2) the title prompt receives the last successful turn's user input plus
#        the assistant's final answer (600 chars each), not just the first input;
#     3) the immediate pre-turn title attempt is disabled; generation always
#        runs after the turn so the assistant answer is available;
#     4) a cancelled/failed title attempt clears sessionTitleGenerationAttempted
#        so the next successful turn retries (the flag still prevents duplicate
#        in-flight attempts).
# - zcode.cjs is a standalone file (NOT inside the asar archive), so its length
#   may change safely.
# - Backup: zcode.cjs.title-backup (clean original of THIS machine); an existing
#   verified backup is never overwritten. Restore via
#   restore-zcode-title-lastturn.bat (reverses v4 and the base title fix in
#   place, so unrelated patches in other byte regions survive).
# - Supports ZCode 3.14.1 only. Other versions are refused loudly.
param(
    [switch]$NoRestart,   # toolbox mode: do not relaunch ZCode after patching
    [string]$TargetCjs,   # advanced/testing: operate on this zcode.cjs instead of the auto-located one (skips the running check)
    [string]$BackupDir    # advanced/testing: directory for backup files (defaults to this script's folder)
)
$ErrorActionPreference = 'Stop'
# Clear NODE_OPTIONS from this process so the ZCode.exe we (re)start never
# inherits unsupported flags (packaged Electron apps print a startup ERROR for
# e.g. --max-old-space-size); the machine/user registry value is NOT touched.
try { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue } catch {}
$latin1 = [System.Text.Encoding]::GetEncoding(28591)  # lossless byte<->char round-trip (all patch strings are pure ASCII)
if (-not $BackupDir) { $BackupDir = $PSScriptRoot }
$backupPath = Join-Path $BackupDir 'zcode.cjs.title-backup'
$hashPath   = Join-Path $BackupDir 'zcode.cjs.title-backup.sha256'

# ---- 3.14.1 signatures ----
$tag    = '3.14.1'
$eligA  = 'function Pba(e,t,n={}){if(e.sessionTitleGenerationAttempted||e.config.titleGeneration?.enabled===!1||!e.config.titleGeneration||!e.sessionStore||e.config.parentSessionId||e.config.taskType&&e.config.taskType!=="interactive"||e.turnNumber!==0)return!1;'
$eligB  = 'function Tba(e,t,n){return e.config.titleGeneration?.enabled===!1||!e.config.titleGeneration||!e.sessionStore||e.config.parentSessionId||e.config.taskType&&e.config.taskType!=="interactive"||n.trim().length===0?!1:Zye(t).length>0}'
$oldLang = "- Use the user's primary language."
$newLang = "- MUST use the user's primary language."
$fillerBase = '/*' + ('x' * 23) + '*/'   # 27 chars, JS comment -> no runtime effect
$patchedA = $eligA.Replace('||!e.config.titleGeneration', '').Replace('{if(', '{' + $fillerBase + 'if(')
$patchedB = $eligB.Replace('||!e.config.titleGeneration', '').Replace('{return ', '{' + $fillerBase + 'return ')
$pbaFiller = '/*' + ('x' * 15) + '*/'    # 19 chars == "||e.turnNumber!==0"

$deferMarker = '/*ZCODE-LASTTURN-DEFER*/'
$oldCall = 'ie=!Qgt.call(this,_,K,b,{deferIfProviderRuntimeHeadersRefresh:!0})'
$newCall = 'ie=!0' + $deferMarker
$oldWxo  = 'wxo.call(this,_,K,b)'
$newWxo  = 'wxo.call(this,String(_||"").slice(0,600)+"\n\n"+String(q.modelResponse||"").slice(0,600),K,b)'
$retryOld = '.catch(async s=>{this.logger?.warn("Session title generation failed"'
$retryNew = '.catch(async s=>{this.sessionTitleGenerationAttempted=!1;this.logger?.warn("Session title generation failed"'

function Count-Str([string]$hay, [string]$s) {
    return ([regex]::Matches($hay, [regex]::Escape($s))).Count
}
function Hash-Bytes([byte[]]$b) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($b) | ForEach-Object { $_.ToString('X2') }) -join '') } finally { $sha.Dispose() }
}
function Test-JsSyntax([string]$js) {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { return $true }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + '.cjs')
    try {
        [System.IO.File]::WriteAllBytes($tmp, $latin1.GetBytes($js))
        & $node.Source --check $tmp 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}
function Find-ZCodeDir {
    # returns the resources\glm dir (the folder containing zcode.cjs)
    try {
        $p = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1
        if ($p) {
            $cand = Join-Path (Split-Path $p.Path -Parent) 'resources\glm\zcode.cjs'
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
                $cand = Join-Path $hit.InstallLocation 'resources\glm\zcode.cjs'
                if (Test-Path $cand) { return (Split-Path $cand -Parent) }
            }
        } catch {}
    }
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
$cjsPath = Join-Path $glmDir 'zcode.cjs'
$zcodeExe = Join-Path (Split-Path (Split-Path (Split-Path $cjsPath -Parent) -Parent) -Parent) 'ZCode.exe'
if (-not (Test-Path $zcodeExe)) { $zcodeExe = $null }
if ($TargetCjs) {
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

# 1) read current file and classify its state
$bytes   = [System.IO.File]::ReadAllBytes($cjsPath)
$text    = $latin1.GetString($bytes)
$cjsHash = Hash-Bytes $bytes

$isV4 = ((Count-Str $text $deferMarker) -eq 1 -and (Count-Str $text 'String(_||"").slice(0,600)') -eq 1 -and (Count-Str $text $retryNew) -eq 1)
$isClean = ((Count-Str $text $eligA) -eq 1 -and (Count-Str $text $eligB) -eq 1 -and (Count-Str $text $oldLang) -eq 1)
$isBase  = ((Count-Str $text $patchedA) -eq 1 -and (Count-Str $text $patchedB) -eq 1 -and (Count-Str $text $newLang) -eq 1 -and (Count-Str $text $oldLang) -eq 0)

if ($isV4) {
    Write-Host '[1/5] last-turn title patch already present; nothing to patch.'
    if ($NoRestart) {
        Write-Host '[5/5] done (NoRestart: leave ZCode closed).'
    } elseif ($zcodeExe) {
        Start-Process $zcodeExe
        Write-Host '[5/5] ZCode restarted.'
    } else {
        Write-Host '[5/5] done. Start ZCode manually.'
    }
    exit 0
}
if (-not $isClean -and -not $isBase) {
    throw "unknown zcode.cjs state for $tag (clean=$isClean base=$isBase v4=$isV4). ZCode version changed? This v4 patch supports only $tag. Refusing."
}
Write-Host ("[1/5] state: " + $(if ($isClean) { 'unpatched (clean)' } else { 'base title fix present' }) + " (ZCode $tag)")

# 2) clean baseline for restore: verify/reuse backup, or reconstruct it
function Get-CleanBaseline {
    if (Test-Path $backupPath) {
        $sidecarOk = $false
        if (Test-Path $hashPath) {
            $expect = (Get-Content $hashPath -ErrorAction SilentlyContinue)
            $actual = (Get-FileHash $backupPath -Algorithm SHA256).Hash
            $sidecarOk = ($expect -and ($actual -eq $expect.Trim()))
        }
        if ($sidecarOk) {
            $bt = $latin1.GetString([System.IO.File]::ReadAllBytes($backupPath))
            if ((Count-Str $bt $eligA) -eq 1 -and (Count-Str $bt $eligB) -eq 1 -and (Count-Str $bt $oldLang) -eq 1) {
                Write-Host '[2/5] clean backup verified'
                return $bt
            }
        }
    }
    if ($isClean) {
        Write-Host '[2/5] clean backup missing; using the current clean file'
        return $text
    }
    # current file is base-patched: reverse the base fix to rebuild the clean original
    $rt = $text.Replace($patchedA, $eligA).Replace($patchedB, $eligB).Replace($newLang, $oldLang)
    if ((Count-Str $rt $eligA) -ne 1 -or (Count-Str $rt $eligB) -ne 1 -or (Count-Str $rt $oldLang) -ne 1) {
        throw 'clean backup missing/invalid and cannot be reconstructed from the base-patched file; refusing.'
    }
    Write-Host '[2/5] clean backup missing/invalid, reconstructed from the base-patched file'
    return $rt
}
$baseText = Get-CleanBaseline
$baseBytes = $latin1.GetBytes($baseText)
$baseHash  = Hash-Bytes $baseBytes
if (Test-Path $backupPath) {
    $existingBackupLen = (Get-Item $backupPath).Length
    if ($existingBackupLen -ne $baseBytes.Length) {
        Write-Host "[X] existing backup length $existingBackupLen != clean baseline $($baseBytes.Length)." -ForegroundColor Red
        Write-Host '    The backup belongs to a different ZCode build; refusing to reuse or overwrite it.' -ForegroundColor Red
        Write-Host '    Delete the stale zcode.cjs.title-backup files to let this script take a fresh baseline.' -ForegroundColor Yellow
        Read-Host 'Press Enter to exit'
        exit 1
    }
}
$needBackupWrite = $true
if (Test-Path $backupPath) {
    if ((Get-FileHash $backupPath -Algorithm SHA256).Hash -eq $baseHash) { $needBackupWrite = $false }
}
if ($needBackupWrite) {
    [System.IO.File]::WriteAllBytes($backupPath, $baseBytes)
    [System.IO.File]::WriteAllText($hashPath, $baseHash)
    Write-Host '[2/5] backup (re)created from clean baseline'
} elseif (-not (Test-Path $hashPath) -or (Get-Content $hashPath -ErrorAction SilentlyContinue).Trim() -ne $baseHash) {
    [System.IO.File]::WriteAllText($hashPath, $baseHash)
    Write-Host '[2/5] backup verified (sidecar refreshed)'
}

# 3) build the v4 patched text
$patched = $text
if ($isClean) {
    $patched = $patched.Replace($eligA, $patchedA).Replace($eligB, $patchedB).Replace($oldLang, $newLang)
}
# sanity: base fragments must now be the patched forms exactly once
if ((Count-Str $patched $patchedA) -ne 1 -or (Count-Str $patched $patchedB) -ne 1 -or (Count-Str $patched $newLang) -ne 1) {
    throw 'base title fragments are not in the expected patched form; refusing.'
}
# v4 anchors must each occur exactly once before replacement
$pre = @{
    turnGuard = (Count-Str $patched '||e.turnNumber!==0')
    call      = (Count-Str $patched $oldCall)
    wxo       = (Count-Str $patched $oldWxo)
    retry     = (Count-Str $patched $retryOld)
}
foreach ($k in $pre.Keys) {
    if ($pre[$k] -ne 1) { throw "anchor '$k' occurs $($pre[$k]) times (expected 1); refusing." }
}
$patched = $patched.Replace('||e.turnNumber!==0', $pbaFiller)
$patched = $patched.Replace($oldCall, $newCall)
$patched = $patched.Replace($oldWxo, $newWxo)
$patched = $patched.Replace($retryOld, $retryNew)

# 4) post-conditions
if ((Count-Str $patched '||e.turnNumber!==0') -ne 0) { throw 'turnNumber guard still present after patch.' }
if ((Count-Str $patched $oldCall) -ne 0) { throw 'old immediate title call still present after patch.' }
if ((Count-Str $patched $oldWxo) -ne 0) { throw 'old wxo call still present after patch.' }
if ((Count-Str $patched $retryOld) -ne 0) { throw 'old retry anchor still present after patch.' }
if ((Count-Str $patched $deferMarker) -ne 1) { throw 'defer marker missing.' }
if ((Count-Str $patched $retryNew) -ne 1) { throw 'retry reset missing.' }
if ((Count-Str $patched 'String(_||"").slice(0,600)') -ne 1) { throw 'last-turn context expression missing.' }
if ((Count-Str $patched ('"interactive"' + $pbaFiller + ')')) -ne 1) { throw 'Pba filler context missing.' }
if (-not (Test-JsSyntax $patched)) { throw 'node --check failed after patch; refusing to write.' }

$newBytes = $latin1.GetBytes($patched)
if ((Hash-Bytes $newBytes) -eq $cjsHash) {
    Write-Host '[3/5] zcode.cjs already carries the v4 title patch, nothing to write'
} else {
    [System.IO.File]::WriteAllBytes($cjsPath, $newBytes)
    Write-Host "[3/5] v4 title patch written (ZCode $tag; last-turn context; retry-on-failure)"
}

if ($NoRestart) {
    Write-Host '[5/5] done (NoRestart: leave ZCode closed).'
} elseif ($zcodeExe) {
    Start-Process $zcodeExe
    Write-Host '[5/5] ZCode restarted.'
} else {
    Write-Host '[5/5] done. Start ZCode manually.'
}
Write-Host 'Titles now use the first successfully completed turn (last user input + assistant answer) and retry after failures.'
