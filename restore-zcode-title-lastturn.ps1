# ZCode session title v4 restore (last-turn context)
# - Reverses the v4 additions in the CURRENT zcode.cjs in place, then reverses
#   the base title fix in place too. Unrelated patches in other byte regions
#   (e.g. usage retention) are preserved.
# - If the in-place reverse is not applicable, falls back to the clean whole-file
#   backup (this erases patches applied after the backup; the script warns).
# - Supports ZCode 3.14.1 only (matches patch-zcode-title-lastturn.ps1).
param(
    [switch]$NoRestart,
    [string]$TargetCjs,
    [string]$BackupDir
)
$ErrorActionPreference = 'Stop'
try { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue } catch {}
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
if (-not $BackupDir) { $BackupDir = $PSScriptRoot }
$backupPath = Join-Path $BackupDir 'zcode.cjs.title-backup'

# ---- 3.14.1 base title fix signatures (same as patch-zcode-title-lastturn.ps1) ----
$eligA  = 'function Pba(e,t,n={}){if(e.sessionTitleGenerationAttempted||e.config.titleGeneration?.enabled===!1||!e.config.titleGeneration||!e.sessionStore||e.config.parentSessionId||e.config.taskType&&e.config.taskType!=="interactive"||e.turnNumber!==0)return!1;'
$eligB  = 'function Tba(e,t,n){return e.config.titleGeneration?.enabled===!1||!e.config.titleGeneration||!e.sessionStore||e.config.parentSessionId||e.config.taskType&&e.config.taskType!=="interactive"||n.trim().length===0?!1:Zye(t).length>0}'
$oldLang = "- Use the user's primary language."
$newLang = "- MUST use the user's primary language."
$fillerBase = '/*' + ('x' * 23) + '*/'
$patchedA = $eligA.Replace('||!e.config.titleGeneration', '').Replace('{if(', '{' + $fillerBase + 'if(')
$patchedB = $eligB.Replace('||!e.config.titleGeneration', '').Replace('{return ', '{' + $fillerBase + 'return ')
$pbaFiller = '/*' + ('x' * 15) + '*/'

$deferMarker = '/*ZCODE-LASTTURN-DEFER*/'
$oldCall = 'ie=!Qgt.call(this,_,K,b,{deferIfProviderRuntimeHeadersRefresh:!0})'
$newCall = 'ie=!0' + $deferMarker
$oldWxo  = 'wxo.call(this,_,K,b)'
$newWxo  = 'wxo.call(this,String(_||"").slice(0,600)+"\n\n"+String(q.modelResponse||"").slice(0,600),K,b)'
$retryOld = '.catch(async s=>{this.logger?.warn("Session title generation failed"'
$retryNew = '.catch(async s=>{this.sessionTitleGenerationAttempted=!1;this.logger?.warn("Session title generation failed"'
$oldPbaCtx = '"interactive"||e.turnNumber!==0)'
$newPbaCtx = '"interactive"' + $pbaFiller + ')'

function Count-Str([string]$hay, [string]$s) {
    return ([regex]::Matches($hay, [regex]::Escape($s))).Count
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
$procs = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue
if ($procs -and -not $TargetCjs) {
    Write-Host '[X] ZCode is running, zcode.cjs is locked.' -ForegroundColor Red
    Write-Host '    Quit ZCode first (right-click tray icon -> Quit; clicking X may only minimize to tray).' -ForegroundColor Yellow
    Read-Host 'Press Enter to exit'
    exit 1
}

$bytes = [System.IO.File]::ReadAllBytes($cjsPath)
$text  = $latin1.GetString($bytes)
$hasV4 = ((Count-Str $text $deferMarker) -eq 1 -and (Count-Str $text 'String(_||"").slice(0,600)') -eq 1 -and (Count-Str $text $retryNew) -eq 1)

if ($hasV4) {
    Write-Host '[1/3] last-turn title patch detected; reversing it in place.'
    $pre = @{
        call = (Count-Str $text $newCall)
        wxo  = (Count-Str $text $newWxo)
        retry = (Count-Str $text $retryNew)
        pba  = (Count-Str $text $newPbaCtx)
    }
    foreach ($k in $pre.Keys) {
        if ($pre[$k] -ne 1) { throw "v4 anchor '$k' occurs $($pre[$k]) times (expected 1); refusing." }
    }
    $text = $text.Replace($newCall, $oldCall)
    $text = $text.Replace($newWxo, $oldWxo)
    $text = $text.Replace($retryNew, $retryOld)
    $text = $text.Replace($newPbaCtx, $oldPbaCtx)
    if ((Count-Str $text $deferMarker) -ne 0 -or (Count-Str $text 'String(_||"").slice(0,600)') -ne 0 -or (Count-Str $text $retryNew) -ne 0) {
        throw 'v4 markers still present after reverse; refusing.'
    }
    if (-not (Test-JsSyntax $text)) { throw 'node --check failed after v4 reverse; refusing to write.' }
    [System.IO.File]::WriteAllBytes($cjsPath, $latin1.GetBytes($text))
    Write-Host '[1/3] v4 additions reversed; base title fix still present.'
} else {
    Write-Host '[1/3] no last-turn title patch detected (nothing to reverse here).'
}

# Reverse the base title fix in place. The existing restore-zcode-title.ps1
# refuses to reverse a file whose base fragments match the "shipped upstream"
# form, so do it here explicitly for the 3.14.1 kit signature.
$isBase = ((Count-Str $text $patchedA) -eq 1 -and (Count-Str $text $patchedB) -eq 1 -and (Count-Str $text $newLang) -eq 1 -and (Count-Str $text $oldLang) -eq 0)
$isCleanNow = ((Count-Str $text $eligA) -eq 1 -and (Count-Str $text $eligB) -eq 1 -and (Count-Str $text $oldLang) -eq 1)
if ($isBase) {
    Write-Host '[2/3] base title fix detected; reversing it in place.'
    $text = $text.Replace($patchedA, $eligA).Replace($patchedB, $eligB).Replace($newLang, $oldLang)
    if ((Count-Str $text $eligA) -ne 1 -or (Count-Str $text $eligB) -ne 1 -or (Count-Str $text $oldLang) -ne 1 -or (Count-Str $text $newLang) -ne 0) {
        throw 'base title reverse verification failed; refusing to write.'
    }
    if (-not (Test-JsSyntax $text)) { throw 'node --check failed after base reverse; refusing to write.' }
    [System.IO.File]::WriteAllBytes($cjsPath, $latin1.GetBytes($text))
    Write-Host '[2/3] base title fix reversed; file is back to the original.'
} elseif ($isCleanNow) {
    Write-Host '[2/3] file is already clean; no base title fix to reverse.'
} else {
    # Last resort: restore the clean whole-file backup. Warn that unrelated
    # patches applied after the backup are erased by this path.
    if (Test-Path $backupPath) {
        Write-Host '[2/3] in-place reverse not applicable; restoring clean backup (other patches may be erased).' -ForegroundColor Yellow
        Copy-Item $backupPath $cjsPath -Force
        $restored = $latin1.GetString([System.IO.File]::ReadAllBytes($cjsPath))
        if ((Count-Str $restored $eligA) -ne 1 -or (Count-Str $restored $eligB) -ne 1 -or (Count-Str $restored $oldLang) -ne 1) {
            throw 'backup restore verification failed.'
        }
    } else {
        throw 'unknown zcode.cjs state and no clean backup available; refusing.'
    }
}

if ($NoRestart) {
    Write-Host '[3/3] done (NoRestart: leave ZCode closed).'
} elseif ($zcodeExe) {
    Start-Process $zcodeExe
    Write-Host '[3/3] ZCode restarted.'
} else {
    Write-Host '[3/3] done. Start ZCode manually.'
}
