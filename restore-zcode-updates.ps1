# ZCode desktop update-disable restore (v1, portable) - save as UTF-8 WITHOUT BOM
# - Restores app.asar from the clean backup created by patch-zcode-updates.ps1
#   (app.asar.updates-backup + .sha256 sidecar).
# - Falls back to reverse-replacing the 25-byte patch fragment in the current
#   asar when the backup is missing/invalid (equal-length, header untouched).
# - Coexists with the font/wallpaper patches: those live in renderer CSS, this
#   patch lives in out/main/index.js only.
param(
    [switch]$NoRestart,   # toolbox mode: do not relaunch ZCode after restoring
    [string]$TargetAsar     # advanced/testing: operate on this app.asar instead of the auto-located one (skips the running check)
)
$ErrorActionPreference = 'Stop'
# Clear NODE_OPTIONS from this process so the ZCode.exe we (re)start never
# inherits unsupported flags (packaged Electron apps print a startup ERROR for
# e.g. --max-old-space-size); the machine/user registry value is NOT touched.
try { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue } catch {}
$latin1 = [System.Text.Encoding]::GetEncoding(28591)

$backupPath = Join-Path $PSScriptRoot 'app.asar.updates-backup'
$hashPath   = Join-Path $PSScriptRoot 'app.asar.updates-backup.sha256'

$mainRelPath = 'out/main/index.js'
$oldFrag = 'enabled:pt==="production"'        # 25 bytes (clean original; 3.14.1 named the var Ge)
$newFrag = 'enabled:!1/*xxxxxxxxxxx*/'        # 25 bytes (patched)

function Count-Str([string]$hay, [string]$s) {
    return ([regex]::Matches($hay, [regex]::Escape($s))).Count
}
function Find-ZCodeDir {
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
$asarPath = Join-Path $resourcesDir 'app.asar'
$zcodeExe = Join-Path (Split-Path $resourcesDir -Parent) 'ZCode.exe'
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

if (-not $TargetAsar) {
    $procs = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Host '[X] ZCode is running, app.asar is locked.' -ForegroundColor Red
        Write-Host '    Quit ZCode first (right-click tray icon -> Quit; clicking X may only minimize to tray).' -ForegroundColor Yellow
        Read-Host 'Press Enter to exit'
        exit 1
    }
}

# current state
$asar = Read-Asar $asarPath
$mainHit = Get-EntryAndBytes $asar $mainRelPath
if (-not $mainHit) { throw "main bundle not found ($mainRelPath); cannot restore." }
$mainText = $latin1.GetString($mainHit.bytes)
$cOld = Count-Str $mainText $oldFrag
$cNew = Count-Str $mainText $newFrag

if ($cNew -eq 0 -and $cOld -eq 1) {
    Write-Host '[1/3] no update-disable patch present, nothing to restore.'
    if ($NoRestart) {
        Write-Host 'done (NoRestart: leave ZCode closed).'
    } elseif ($zcodeExe) { Start-Process $zcodeExe; Write-Host 'ZCode restarted.' }
    Read-Host 'Press Enter to exit'
    exit 0
}
if ($cNew -ne 1 -or $cOld -ne 0) {
    throw 'app.asar is in an unknown state (both/neither fragment present); cannot restore automatically.'
}
Write-Host '[1/3] state: patched'

# preferred: reverse the 25-byte fragment in the CURRENT asar in place — the
# state gate above guarantees the fragment is present exactly once, so this
# always applies and preserves any other patches (font stacks / wallpaper block)
# regardless of backup age
$restored = $false
$patchedMain = $latin1.GetBytes($mainText.Replace($newFrag, $oldFrag))
if ($patchedMain.Length -ne $mainHit.bytes.Length) { throw 'length mismatch on reverse replacement; refusing.' }
$newAsarBytes = [byte[]]$asar.bytes.Clone()
$fileStart = [long]$asar.contentBase + [long]$mainHit.node.offset
[Array]::Copy($patchedMain, 0, $newAsarBytes, $fileStart, $patchedMain.Length)
$tmpPath = "$asarPath.tmp"
[System.IO.File]::WriteAllBytes($tmpPath, $newAsarBytes)
$chk = Read-Asar $tmpPath
$chkMain = Get-EntryAndBytes $chk $mainRelPath
if ($chkMain -and (Count-Str ($latin1.GetString($chkMain.bytes)) $oldFrag) -eq 1) {
    Move-Item -Force $tmpPath $asarPath
    $restored = $true
    Write-Host '[2/3] fragment reversed in place (other patches preserved)'
} else {
    Remove-Item $tmpPath -ErrorAction SilentlyContinue
    throw 'in-place reverse failed self-check; asar left in current state.'
}

# fallback: restore the clean backup asar verbatim (factory state) — only used
# when the in-place path threw above, which the state gate makes unreachable
if (-not $restored) {
    Write-Host '[2/3] falling back to backup restore'
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
            if ($bkMain -and (Count-Str ($latin1.GetString($bkMain.bytes)) $oldFrag) -eq 1) {
                Copy-Item -Force $backupPath $asarPath
                $restored = $true
                Write-Host '     restored from clean backup (verbatim factory state)'
                Write-Host '     (note: patches applied after that backup was taken are gone with it)'
            }
        }
    }
    if (-not $restored) {
        Write-Host '[X] no valid backup available and the in-place path failed.' -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
}

# verify
$chkAsar = Read-Asar $asarPath
$chkMain = Get-EntryAndBytes $chkAsar $mainRelPath
if (-not $chkMain -or (Count-Str ($latin1.GetString($chkMain.bytes)) $newFrag) -ne 0) {
    throw 'restore verification failed (patch still present); asar left in current state.'
}
Write-Host '[3/3] verified: update-disable patch removed.'

if ($NoRestart) {
    Write-Host 'done (NoRestart: leave ZCode closed).'
} elseif ($zcodeExe) {
    Start-Process $zcodeExe
    Write-Host 'ZCode restarted.'
} else {
    Write-Host 'done. Start ZCode manually.'
}
Read-Host 'Press Enter to exit'
