# ZCode session title refresh variant (topic-change / every N turns)
# - Add-on on top of patch-zcode-title-lastturn.ps1 (v4). It does NOT work on a
#   clean zcode.cjs; apply the v4 last-turn patch first.
# - Behavior:
#     1) removes the one-shot sessionTitleGenerationAttempted gate from Pba;
#     2) Wwn enforces a cooldown: after a title is generated, the next attempt
#        is allowed only after RefreshTurns successful turns;
#     3) Oba skips writing when the newly generated title equals the current one;
#     4) custom titles are still never overwritten, and failed/cancelled calls
#        still retry on the next successful turn.
# - The title input remains v4's "latest user message + assistant final answer".
# - RefreshTurns default 5; use 1 for every successful turn.
# - Backup: zcode.cjs.title-refresh-backup (the v4 state of THIS machine).
#   Revert with restore-zcode-title-refresh.bat.
# - Supports ZCode 3.14.1 only.
param(
    [switch]$NoRestart,
    [string]$TargetCjs,
    [string]$BackupDir,
    [ValidateRange(1, 100)]
    [int]$RefreshTurns = 5
)
$ErrorActionPreference = 'Stop'
try { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue } catch {}
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
if (-not $BackupDir) { $BackupDir = $PSScriptRoot }
$backupPath = Join-Path $BackupDir 'zcode.cjs.title-refresh-backup'
$hashPath   = Join-Path $BackupDir 'zcode.cjs.title-refresh-backup.sha256'

$refreshPrefix = '/*ZCODE-TITLE-REFRESH:'
$refreshMarker = $refreshPrefix + $RefreshTurns + '*/'
$sameMarker    = '/*ZCODE-TITLE-REFRESH-SAME*/'
$pbaOld = 'e.sessionTitleGenerationAttempted||'
$pbaNew = '/*' + ('x' * 31) + '*/'   # 35 chars == "e.sessionTitleGenerationAttempted||"
$wwnOld = 'return!1;this.sessionTitleGenerationAttempted=!0;let n=this.agentTelemetry'
$wwnNew = 'return!1;' + $refreshMarker + 'if(this.sessionTitleGenerationAttempted&&(this.turnNumber-(this.sessionTitleGenerationTurn||0))<' + $RefreshTurns + ')return!1;this.sessionTitleGenerationTurn=this.turnNumber;this.sessionTitleGenerationAttempted=!0;let n=this.agentTelemetry'
$obaOld = 'let n=t.title,o=await this.sessionStore?.updateSession({expectedTitleSources:Eba,id:this.sessionId,title:e.title,'
$obaNew = 'let n=t.title;' + $sameMarker + 'if(n===e.title){this.logger?.debug("Session title generation skipped",{...Cr(e.traceContext),event:"session_title_generation.skipped",module:"core.runtime",reason:"unchanged_title"});return}let o=await this.sessionStore?.updateSession({expectedTitleSources:Eba,id:this.sessionId,title:e.title,'

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
$cjsHash = Hash-Bytes $bytes

$hasRefresh = ((Count-Str $text $refreshPrefix) -gt 0)
$isV4 = ((Count-Str $text '/*ZCODE-LASTTURN-DEFER*/') -eq 1 -and (Count-Str $text 'String(_||"").slice(0,600)') -eq 1)
if ($hasRefresh) {
    Write-Host '[1/5] refresh variant already present; nothing to patch.'
    Write-Host '      To change RefreshTurns, run restore-zcode-title-refresh.bat first, then patch again.'
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
if (-not $isV4) {
    throw 'v4 last-turn title patch not detected. Apply patch-zcode-title-lastturn.ps1 first; this refresh variant is an add-on.'
}
Write-Host "[1/5] v4 base detected; applying refresh variant (RefreshTurns=$RefreshTurns)"
if ((Count-Str $text $pbaOld) -ne 1) { throw "Pba anchor occurs $(Count-Str $text $pbaOld) times (expected 1)." }
if ((Count-Str $text $wwnOld) -ne 1) { throw "Wwn anchor occurs $(Count-Str $text $wwnOld) times (expected 1)." }
if ((Count-Str $text $obaOld) -ne 1) { throw "Oba anchor occurs $(Count-Str $text $obaOld) times (expected 1)." }

# backup = current v4 state (never the refresh state)
if (Test-Path $backupPath) {
    $sidecarOk = $false
    if (Test-Path $hashPath) {
        $expect = (Get-Content $hashPath -ErrorAction SilentlyContinue)
        $actual = (Get-FileHash $backupPath -Algorithm SHA256).Hash
        $sidecarOk = ($expect -and ($actual -eq $expect.Trim()))
    }
    if (-not $sidecarOk) {
        Write-Host '[X] refresh backup hash mismatch; refusing to reuse it.' -ForegroundColor Red
        Write-Host '    Delete zcode.cjs.title-refresh-backup* and re-run.' -ForegroundColor Yellow
        Read-Host 'Press Enter to exit'
        exit 1
    }
    $bt = $latin1.GetString([System.IO.File]::ReadAllBytes($backupPath))
    if ((Count-Str $bt '/*ZCODE-LASTTURN-DEFER*/') -ne 1 -or (Count-Str $bt $pbaOld) -ne 1) {
        Write-Host '[X] refresh backup is not a v4 base; refusing to reuse it.' -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
    Write-Host '[2/5] v4 refresh backup verified'
} else {
    [System.IO.File]::WriteAllBytes($backupPath, $bytes)
    [System.IO.File]::WriteAllText($hashPath, $cjsHash)
    Write-Host '[2/5] v4 refresh backup created'
}

$patched = $text.Replace($pbaOld, $pbaNew).Replace($wwnOld, $wwnNew).Replace($obaOld, $obaNew)
if ((Count-Str $patched $pbaOld) -ne 0) { throw 'Pba old flag still present.' }
if ((Count-Str $patched $refreshMarker) -ne 1) { throw 'refresh marker missing.' }
if ((Count-Str $patched $sameMarker) -ne 1) { throw 'same-title marker missing.' }
if ((Count-Str $patched $wwnNew) -ne 1) { throw 'Wwn cooldown missing.' }
if ((Count-Str $patched $obaNew) -ne 1) { throw 'Oba same-title check missing.' }
if (-not (Test-JsSyntax $patched)) { throw 'node --check failed after refresh patch; refusing to write.' }

$newBytes = $latin1.GetBytes($patched)
if ((Hash-Bytes $newBytes) -eq $cjsHash) {
    Write-Host '[3/5] zcode.cjs already carries the refresh variant, nothing to write'
} else {
    [System.IO.File]::WriteAllBytes($cjsPath, $newBytes)
    Write-Host "[3/5] refresh variant written (RefreshTurns=$RefreshTurns)"
}

if ($NoRestart) {
    Write-Host '[5/5] done (NoRestart: leave ZCode closed).'
} elseif ($zcodeExe) {
    Start-Process $zcodeExe
    Write-Host '[5/5] ZCode restarted.'
} else {
    Write-Host '[5/5] done. Start ZCode manually.'
}
Write-Host "Session titles refresh every $RefreshTurns successful turn(s); custom titles are never overwritten."
