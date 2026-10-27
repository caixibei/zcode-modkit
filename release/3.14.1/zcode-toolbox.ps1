# ZCode Patch Toolbox (v1, portable) - unified menu for all patch/restore tasks
# - Lists the 7 patches (apply) and 7 restores as a picklist; the user selects
#   ONE OR MANY tasks (e.g. "1 3" or "1,3"), they run in ascending order.
# - ZCode running-check happens ONCE up front; ZCode (if found) is restarted
#   ONCE at the end when any selected task actually patched something.
# - Each task shells out to the existing single-purpose script with -NoRestart,
#   so behavior, backups and state detection stay identical to the standalone
#   .bat entries (those keep working unchanged).
# - Interactive inputs (wallpaper photo / veil selection, gear image veil,
#   manual install dir) still come from the underlying scripts; run tasks one
#   at a time if you prefer. Exits automatically when done; pauses only on errors.
# Save as UTF-8 WITHOUT BOM
param([string]$PsExe = 'powershell')   # host used to run the sub scripts
$ErrorActionPreference = 'Continue'
# Clear NODE_OPTIONS from this process so the ZCode.exe we (re)start never
# inherits unsupported flags (packaged Electron apps print a startup ERROR for
# e.g. --max-old-space-size); the machine/user registry value is NOT touched.
try { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$tasks = @(
    [pscustomobject]@{ Id = '1'; Kind = 'patch';   Label = 'UI font patch';            Script = 'patch-zcode-font.ps1' },
    [pscustomobject]@{ Id = '2'; Kind = 'patch';   Label = 'session title fix + refresh (default 5 turns)'; Script = 'patch-zcode-title-lastturn.ps1' },
    [pscustomobject]@{ Id = '3'; Kind = 'patch';   Label = 'wallpaper patch';          Script = 'patch-zcode-wallpaper.ps1' },
    [pscustomobject]@{ Id = '4'; Kind = 'patch';   Label = 'disable update checks';    Script = 'patch-zcode-updates.ps1' },
    [pscustomobject]@{ Id = '5'; Kind = 'patch';   Label = 'Shanghai timezone fix';    Script = 'patch-zcode-timezone.ps1' },
    [pscustomobject]@{ Id = '6'; Kind = 'patch';   Label = 'keep usage history (no 30d prune)'; Script = 'patch-zcode-usage.ps1' },
    [pscustomobject]@{ Id = '7'; Kind = 'patch';   Label = 'gear wallpaper (thought-level switch)'; Script = 'patch-zcode-wallpaper-gear.ps1' },
    [pscustomobject]@{ Id = '9'; Kind = 'restore'; Label = 'restore font';             Script = 'restore-zcode-font.ps1' },
    [pscustomobject]@{ Id = '10'; Kind = 'restore'; Label = 'restore title fix + refresh'; Script = 'restore-zcode-title-lastturn.ps1' },
    [pscustomobject]@{ Id = '11'; Kind = 'restore'; Label = 'restore wallpaper';       Script = 'restore-zcode-wallpaper.ps1' },
    [pscustomobject]@{ Id = '12'; Kind = 'restore'; Label = 're-enable update checks'; Script = 'restore-zcode-updates.ps1' },
    [pscustomobject]@{ Id = '13'; Kind = 'restore'; Label = 'restore timezone setting'; Script = 'restore-zcode-timezone.ps1' },
    [pscustomobject]@{ Id = '14'; Kind = 'restore'; Label = 'restore 30d usage prune'; Script = 'restore-zcode-usage.ps1' },
    [pscustomobject]@{ Id = '15'; Kind = 'restore'; Label = 'restore gear wallpaper';  Script = 'restore-zcode-wallpaper-gear.ps1' }
)

function Show-Menu {
    Write-Host ''
    Write-Host '===== ZCode Patch Toolbox =====' -ForegroundColor Cyan
    Write-Host '  apply patches:' -ForegroundColor Gray
    foreach ($t in ($tasks | Where-Object { $_.Kind -eq 'patch' })) {
        Write-Host ("  [{0}] {1}" -f $t.Id, $t.Label)
    }
    Write-Host '  restore:' -ForegroundColor Gray
    foreach ($t in ($tasks | Where-Object { $_.Kind -eq 'restore' })) {
        Write-Host ("  [{0}] {1}" -f $t.Id, $t.Label)
    }
    Write-Host '  [0] exit'
}

function Get-ZCodeExePath {
    try {
        $p = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1
        if ($p) { return $p.Path }
    } catch {}
    $candidates = @('D:\installer\zcode\ZCode.exe', "$env:LOCALAPPDATA\Programs\zcode\ZCode.exe", "$env:ProgramFiles\zcode\ZCode.exe")
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

# 0) ZCode must not be running while we patch (single check covers all tasks)
$zcodeExe = Get-ZCodeExePath
$procs = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue
if ($procs) {
    Write-Host '[X] ZCode is running, app.asar / zcode.cjs are locked.' -ForegroundColor Red
    Write-Host '    Quit ZCode first (right-click tray icon -> Quit; clicking X may only minimize to tray).' -ForegroundColor Yellow
    Read-Host 'Press Enter to exit'
    exit 1
}

Show-Menu
$sel = Read-Host 'select task number(s), separated by space or comma (e.g. 1 3 or 1,3,4)'
if ($sel -eq '0' -or -not $sel) { exit 0 }

$ids = $sel -split '[\s,;]+' | Where-Object { $_ -ne '' }
$chosen = @()
foreach ($id in $ids) {
    $hit = $tasks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    if (-not $hit) {
        Write-Host "[X] invalid selection: $id" -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
    $chosen += $hit
}
# de-duplicate while preserving ascending order (numeric: 2-digit ids like
# 10-14 must sort after single-digit ones, not between 1 and 2)
$chosen = $chosen | Sort-Object { [int]$_.Id } -Unique

Write-Host ''
Write-Host 'will run:' -ForegroundColor Cyan
foreach ($t in $chosen) { Write-Host ("  [{0}] {1} ({2})" -f $t.Id, $t.Label, $t.Script) }
$confirm = Read-Host 'continue? [Y/n]'
if ($confirm -match '^[nN]') { exit 0 }

# 1) run each selected task with -NoRestart; abort the batch on the first hard failure
$failed = $false
$i = 0
foreach ($t in $chosen) {
    $i++
    Write-Host ''
    Write-Host ("===== task {0}/{1}: [{2}] {3} =====" -f $i, $chosen.Count, $t.Id, $t.Label) -ForegroundColor Cyan
    & $PsExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $t.Script) -NoRestart
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("[X] task [{0}] {1} exited with code {2}; batch stopped." -f $t.Id, $t.Label, $LASTEXITCODE) -ForegroundColor Red
        $failed = $true
        break
    }
}

# 2) restart ZCode once when anything actually ran
if (-not $failed) {
    Write-Host ''
    if ($zcodeExe) {
        Start-Process $zcodeExe
        Write-Host 'All selected tasks done. ZCode restarted.'
    } else {
        Write-Host 'All selected tasks done. Start ZCode manually.'
    }
} else {
    Write-Host 'Batch stopped early. Fix the failing task, then re-run the toolbox (done tasks keep their state).'
}
Read-Host 'Press Enter to exit'
