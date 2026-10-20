# ZCode session title refresh variant restore
# - Reverts only the refresh add-on, leaving the v4 last-turn patch in place.
# - Prefers an in-place reverse so unrelated patches in other byte regions
#   (e.g. usage retention) survive; falls back to the v4 backup if needed.
# - Supports ZCode 3.14.1 only.
param(
    [switch]$NoRestart,
    [string]$TargetCjs,
    [string]$BackupDir
)
$ErrorActionPreference = 'Stop'
try { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue } catch {}
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
if (-not $BackupDir) { $BackupDir = $PSScriptRoot }
$backupPath = Join-Path $BackupDir 'zcode.cjs.title-refresh-backup'

$refreshPrefix = '/*ZCODE-TITLE-REFRESH:'
$sameMarker    = '/*ZCODE-TITLE-REFRESH-SAME*/'
$pbaOld = 'e.sessionTitleGenerationAttempted||'
$pbaNew = '/*' + ('x' * 31) + '*/'
$wwnOld = 'return!1;this.sessionTitleGenerationAttempted=!0;let n=this.agentTelemetry'
$obaOld = 'let n=t.title,o=await this.sessionStore?.updateSession({expectedTitleSources:Eba,id:this.sessionId,title:e.title,'
$obaNew = 'let n=t.title;' + $sameMarker + 'if(n===e.title){this.logger?.debug("Session title generation skipped",{...Cr(e.traceContext),event:"session_title_generation.skipped",module:"core.runtime",reason:"unchanged_title"});return}let o=await this.sessionStore?.updateSession({expectedTitleSources:Eba,id:this.sessionId,title:e.title,'

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
$prefixCount = Count-Str $text $refreshPrefix
if ($prefixCount -eq 0) {
    Write-Host '[1/3] no refresh variant detected; nothing to reverse.'
    if ($NoRestart) {
        Write-Host '[3/3] done (NoRestart: leave ZCode closed).'
    } elseif ($zcodeExe) {
        Start-Process $zcodeExe
        Write-Host '[3/3] ZCode restarted.'
    } else {
        Write-Host '[3/3] done. Start ZCode manually.'
    }
    exit 0
}
if ($prefixCount -ne 1) { throw "refresh marker occurs $prefixCount times (expected 1); refusing." }

$m = [regex]::Match($text, [regex]::Escape($refreshPrefix) + '(\d+)\*/')
if (-not $m.Success) { throw 'cannot parse RefreshTurns from refresh marker; refusing.' }
$n = [int]$m.Groups[1].Value
$refreshMarker = $refreshPrefix + $n + '*/'
$wwnNew = 'return!1;' + $refreshMarker + 'if(this.sessionTitleGenerationAttempted&&(this.turnNumber-(this.sessionTitleGenerationTurn||0))<' + $n + ')return!1;this.sessionTitleGenerationTurn=this.turnNumber;this.sessionTitleGenerationAttempted=!0;let n=this.agentTelemetry'

if ((Count-Str $text $wwnNew) -ne 1) { throw 'Wwn refresh block not found exactly once; refusing.' }
if ((Count-Str $text $obaNew) -ne 1) { throw 'Oba same-title block not found exactly once; refusing.' }
if ((Count-Str $text ('if(' + $pbaNew + 'e.config.titleGeneration')) -ne 1) { throw 'Pba refresh filler not found exactly once; refusing.' }

$text = $text.Replace($wwnNew, $wwnOld)
$text = $text.Replace($obaNew, $obaOld)
$text = $text.Replace('if(' + $pbaNew + 'e.config.titleGeneration', 'if(' + $pbaOld + 'e.config.titleGeneration')
if ((Count-Str $text $refreshPrefix) -ne 0) { throw 'refresh marker still present after reverse.' }
if ((Count-Str $text '/*ZCODE-LASTTURN-DEFER*/') -ne 1) { throw 'v4 base missing after refresh reverse; refusing.' }
if ((Count-Str $text $pbaOld) -ne 1) { throw 'Pba flag not restored.' }
if ((Count-Str $text $wwnOld) -ne 1) { throw 'Wwn base not restored.' }
if ((Count-Str $text $obaOld) -ne 1) { throw 'Oba base not restored.' }
if (-not (Test-JsSyntax $text)) { throw 'node --check failed after refresh reverse; refusing to write.' }

[System.IO.File]::WriteAllBytes($cjsPath, $latin1.GetBytes($text))
Write-Host '[2/3] refresh variant reversed; v4 base title patch is still present.'

if ($NoRestart) {
    Write-Host '[3/3] done (NoRestart: leave ZCode closed).'
} elseif ($zcodeExe) {
    Start-Process $zcodeExe
    Write-Host '[3/3] ZCode restarted.'
} else {
    Write-Host '[3/3] done. Start ZCode manually.'
}
