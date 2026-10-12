# Revert ZCode session title patch (v3, portable)
# v4 behavior: prefer reversing the patched fragments in the CURRENT zcode.cjs
# in place (equal-length), so a coexisting usage-retention patch (different byte
# region of the same file) survives; the clean whole-file backup is only used as
# a fallback when the in-place path cannot apply. The usage patch has its own
# reverse path, so whole-file overwrite would silently erase it.
# Auto-locates ZCode install; every probe is fault-tolerant.
# Signature table mirrors patch-zcode-title.ps1 (3.14.1 / 3.12.3).
param(
    [switch]$NoRestart,   # toolbox mode: do not relaunch ZCode after restoring
    [string]$TargetCjs    # advanced/testing: operate on this zcode.cjs instead of the auto-located one (skips the running check)
)
$ErrorActionPreference = 'Stop'

$backupPath = Join-Path $PSScriptRoot 'zcode.cjs.title-backup'
$hashPath   = Join-Path $PSScriptRoot 'zcode.cjs.title-backup.sha256'

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

function Find-ZCodeDir {
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

$procs = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue
if ($procs -and -not $TargetCjs) {
    Write-Host '[X] ZCode is running. Quit it from the tray icon first, then run this script again.' -ForegroundColor Red
    Read-Host 'Press Enter to exit'
    exit 1
}
if (-not (Test-Path $backupPath)) {
    Write-Host '[X] backup not found: ' $backupPath -ForegroundColor Red
    Write-Host '    (was the title patch ever applied on this machine? The backup is created by the patch script.)' -ForegroundColor Yellow
    Read-Host 'Press Enter to exit'
    exit 1
}

# sidecar hash must match the backup file itself
if (Test-Path $hashPath) {
    $expect = (Get-Content $hashPath -ErrorAction SilentlyContinue)
    $actual = (Get-FileHash $backupPath -Algorithm SHA256).Hash
    if (-not $expect -or ($actual -ne $expect.Trim())) {
        Write-Host '[X] backup hash mismatch with sidecar, refusing to overwrite.' -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
}

# the backup must match a clean original of a KNOWN version (all fragments exactly once)
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
$ct = $latin1.GetString([System.IO.File]::ReadAllBytes($cjsPath))

# upstream-fixed check (ZCode 3.14.3+): the fix shipped upstream is byte-identical
# to this kit's patched form. Reversing it would REINTRODUCE the bug — refuse.
foreach ($v in $versions) {
    $filler0 = '/*' + ('x' * 23) + '*/'
    $ua = $v.eligA.Replace('||!e.config.titleGeneration', '').Replace('{if(', '{' + $filler0 + 'if(')
    $ub = $v.eligB.Replace('||!e.config.titleGeneration', '').Replace('{return ', '{' + $filler0 + 'return ')
    $cUa = ([regex]::Matches($ct, [regex]::Escape($ua))).Count
    $cUb = ([regex]::Matches($ct, [regex]::Escape($ub))).Count
    if ($cUa -eq 1 -and $cUb -eq 1) {
        Write-Host '[X] this zcode.cjs carries the title fix SHIPPED UPSTREAM (byte-identical to this kit'"'"'s patch form).' -ForegroundColor Red
        Write-Host '    There is nothing from this kit to restore here; reversing would reintroduce the title bug.' -ForegroundColor Yellow
        Write-Host '    If you really want the bug back, reinstall ZCode — this toolkit will not do it.' -ForegroundColor Yellow
        Read-Host 'Press Enter to exit'
        exit 1
    }
}

$bt = $latin1.GetString([System.IO.File]::ReadAllBytes($backupPath))
$matched = $false
$matchedVersion = $null
foreach ($v in $versions) {
    $ca = ([regex]::Matches($bt, [regex]::Escape($v.eligA))).Count
    $cb = ([regex]::Matches($bt, [regex]::Escape($v.eligB))).Count
    $cl = ([regex]::Matches($bt, [regex]::Escape($oldLang))).Count
    if ($ca -eq 1 -and $cb -eq 1 -and $cl -eq 1) {
        Write-Host "[OK] backup matches clean original of ZCode $($v.tag)."
        $matched = $true
        $matchedVersion = $v
        break
    }
}
if (-not $matched) {
    Write-Host '[X] backup does not match any known clean original zcode.cjs (looks patched or from an unsupported ZCode version), refusing to overwrite.' -ForegroundColor Red
    Read-Host 'Press Enter to exit'
    exit 1
}

# v4: preferred path — reverse the patched fragments in the CURRENT file in
# place (equal-length), so a coexisting usage-retention patch survives. The
# current file must still carry THIS kit's patched fragments; anything else
# (unknown state) falls through to the whole-file backup restore.
$ct = $latin1.GetString([System.IO.File]::ReadAllBytes($cjsPath))
$restored = $false
$patchedA, $patchedB = $null, $null
if ($matchedVersion -eq $null) { throw 'internal: matched version not captured' }
# rebuild the patched forms for the matched version (same filler as the patch script)
$filler = '/*' + ('x' * 23) + '*/'
$patchedA = $matchedVersion.eligA.Replace('||!e.config.titleGeneration', '').Replace('{if(', '{' + $filler + 'if(')
$patchedB = $matchedVersion.eligB.Replace('||!e.config.titleGeneration', '').Replace('{return ', '{' + $filler + 'return ')
$cPa = ([regex]::Matches($ct, [regex]::Escape($patchedA))).Count
$cPb = ([regex]::Matches($ct, [regex]::Escape($patchedB))).Count
$cPl = ([regex]::Matches($ct, [regex]::Escape($newLang))).Count
$cCl = ([regex]::Matches($ct, [regex]::Escape($oldLang))).Count
# language fragment may be patched (+5 bytes) or clean; both mean the title
# patch is present in the current file and can be reversed in place
if (($cPa -eq 1 -and $cPb -eq 1) -and (($cPl -eq 1 -and $cCl -eq 0) -or ($cPl -eq 0 -and $cCl -eq 1))) {
    $curPatchedA = $patchedA
    $curPatchedB = $patchedB
    if ($cPl -eq 1) { $curPatchedA = $curPatchedA.Replace($oldLang, $newLang); $curPatchedB = $curPatchedB.Replace($oldLang, $newLang) }
    $nt = $ct.Replace($curPatchedA, $matchedVersion.eligA).Replace($curPatchedB, $matchedVersion.eligB).Replace($newLang, $oldLang)
    # sanity: after reversal the current file must contain all three clean fragments exactly once
    if (([regex]::Matches($nt, [regex]::Escape($matchedVersion.eligA))).Count -eq 1 -and
        ([regex]::Matches($nt, [regex]::Escape($matchedVersion.eligB))).Count -eq 1 -and
        ([regex]::Matches($nt, [regex]::Escape($oldLang))).Count -eq 1) {
        [System.IO.File]::WriteAllBytes($cjsPath, $latin1.GetBytes($nt))
        $restored = $true
        Write-Host '[OK] title fragments reversed in place (other patches preserved).'
    }
}
if (-not $restored) {
    Write-Host '[..] in-place reversal not applicable (current file lacks recognizable title-patch fragments).'
    Write-Host '     Falling back to whole-file backup restore — NOTE: patches applied after the backup'
    Write-Host '     (e.g. the usage-retention patch) are erased by this path; re-apply them afterwards.'
    Copy-Item $backupPath $cjsPath -Force
    Write-Host '[OK] zcode.cjs restored.'
}
if ($NoRestart) {
    Write-Host '[OK] done (NoRestart: leave ZCode closed).'
} elseif ($zcodeExe) {
    Start-Process $zcodeExe
    Write-Host '[OK] ZCode restarted.'
} else {
    Write-Host '[OK] Start ZCode manually.'
}
