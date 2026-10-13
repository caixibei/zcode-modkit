# ZCode usage-retention restore (v1, portable) - save as UTF-8 WITHOUT BOM
# - Restores the 30-day usage-prune behavior by reversing the equal-length
#   retention-constant patch in the CURRENT zcode.cjs in place (preferred), or
#   falling back to the clean backup created by patch-zcode-usage.ps1.
# - In-place first so a coexisting title patch (different byte region) survives.
param(
    [switch]$NoRestart,   # toolbox mode: do not relaunch ZCode after restoring
    [string]$TargetCjs    # advanced/testing: operate on this zcode.cjs instead of the auto-located one (skips the running check)
)
$ErrorActionPreference = 'Stop'
$latin1 = [System.Text.Encoding]::GetEncoding(28591)

# backup lives NEXT TO THE TARGET FILE (mirrors the patch script); $backupPath
# is resolved after the target file is known
$retentionRegex = '(\w+)=30,(\w+)=\1\*24\*60\*60\*1e3'
$patchedRegex   = '(\w+)=30,(\w+)=9e15/\*x+\*/'

function ConvertTo-CleanText([string]$text) {
    $ms = [regex]::Matches($text, $patchedRegex)
    foreach ($m in $ms) {
        # the multiplier is the FIRST identifier (X): Y=X*24*60*60*1e3 in the clean form
        $clean = '{0}=30,{1}={0}*24*60*60*1e3' -f $m.Groups[1].Value, $m.Groups[2].Value
        if ($clean.Length -ne $m.Value.Length) { throw "reverse fragment length mismatch: $($clean.Length) vs $($m.Value.Length)" }
        $text = $text.Replace($m.Value, $clean)
    }
    return @($text, $ms.Count)
}
function Count-Str([string]$hay, [string]$s) {
    return ([regex]::Matches($hay, [regex]::Escape($s))).Count
}
function Find-ZCodeDir {
    # returns the resources\glm dir (the folder containing zcode.cjs); every
    # branch must agree on this convention or the main path joins break
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

# ================= main =================
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
# zcode.cjs -> resources\glm -> resources -> install dir containing ZCode.exe
$zcodeExe = Join-Path (Split-Path (Split-Path (Split-Path $cjsPath -Parent) -Parent) -Parent) 'ZCode.exe'
if (-not (Test-Path $zcodeExe)) { $zcodeExe = $null }
if ($TargetCjs) {
    $cjsPath = $TargetCjs
    $zcodeExe = $null
    Write-Host "target (override): $cjsPath"
} else {
    Write-Host "target: $cjsPath"
}

if (-not $TargetCjs) {
    $procs = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Host '[X] ZCode is running. Quit it from the tray icon first, then run this script again.' -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
}

# current state
$backupPath = Join-Path (Split-Path $cjsPath -Parent) 'zcode.cjs.usage-backup'
$hashPath   = "$backupPath.sha256"
$text = $latin1.GetString([System.IO.File]::ReadAllBytes($cjsPath))
$msPatched = [regex]::Matches($text, $patchedRegex)
$msClean   = [regex]::Matches($text, $retentionRegex)

if ($msPatched.Count -eq 0 -and $msClean.Count -eq 1) {
    Write-Host '[1/3] no usage-retention patch present, nothing to restore.'
    if ($NoRestart) {
        Write-Host 'done (NoRestart: leave ZCode closed).'
    } elseif ($zcodeExe) { Start-Process $zcodeExe; Write-Host 'ZCode restarted.' }
    Read-Host 'Press Enter to exit'
    exit 0
}
if ($msPatched.Count -ne 1 -or $msClean.Count -ne 0) {
    throw "zcode.cjs is in an unknown state (clean=$($msClean.Count) patched=$($msPatched.Count)); cannot restore automatically."
}
Write-Host '[1/3] state: patched'

# preferred: reverse the 36-byte fragment in the CURRENT file in place —
# preserves any coexisting patches (title fix) regardless of backup age
$cleanText, $cnt = ConvertTo-CleanText $text
if ($cnt -ne 1) { throw "expected exactly one patched fragment, got $cnt" }
$cleanBytes = $latin1.GetBytes($cleanText)
if ($cleanBytes.Length -ne $text.Length) { throw 'length mismatch on reverse replacement; refusing.' }
[System.IO.File]::WriteAllBytes("$cjsPath.tmp", $cleanBytes)
Move-Item -Force "$cjsPath.tmp" $cjsPath
Write-Host '[2/3] fragment reversed in place (other patches preserved)'

# verify
$check = $latin1.GetString([System.IO.File]::ReadAllBytes($cjsPath))
if (([regex]::Matches($check, $patchedRegex)).Count -ne 0 -or ([regex]::Matches($check, $retentionRegex)).Count -ne 1) {
    throw 'restore verification failed; zcode.cjs left in an unexpected state.'
}
Write-Host '[3/3] verified: 30-day usage pruning restored.'

if ($NoRestart) {
    Write-Host 'done (NoRestart: leave ZCode closed).'
} elseif ($zcodeExe) {
    Start-Process $zcodeExe
    Write-Host 'ZCode restarted.'
} else {
    Write-Host 'done. Start ZCode manually.'
}
Read-Host 'Press Enter to exit'
