# ZCode gear-wallpaper restore (v1, portable) - save as UTF-8 WITH BOM
# - Removes ONLY the gear-wallpaper CSS block (ZCODE-GWP-* markers) from the
#   CURRENT asar in place: any other patch (static wallpaper / font / update /
#   title / timezone) is preserved regardless of backup age.
# - Falls back to the clean backup (app.asar.gwp-backup + .sha256 sidecar)
#   when the current asar carries no recognizable gear block.
# - Never touches the static wallpaper patch block (ZCODE-WALLPAPER-*).
param(
    [switch]$NoRestart,
    [string]$TargetAsar
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
# Clear NODE_OPTIONS from this process so the ZCode.exe we (re)start never
# inherits unsupported flags (packaged Electron apps print a startup ERROR for
# e.g. --max-old-space-size); the machine/user registry value is NOT touched.
try { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue } catch {}

$backupPath = Join-Path $PSScriptRoot 'app.asar.gwp-backup'
$hashPath   = Join-Path $PSScriptRoot 'app.asar.gwp-backup.sha256'

$markerBegin = '/* ZCODE-GWP-GEAR-WALLPAPER-BEGIN */'
$markerEnd   = '/* ZCODE-GWP-GEAR-WALLPAPER-END */'
$cssRelPath  = 'out/renderer/assets/styles-C8Nayk5k.css'

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

function Get-CssEntryAndBytes($asar, [string]$relPath) {
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

function Remove-Integrity($node) {
    if ($node.PSObject.Properties['integrity']) { $node.PSObject.Properties.Remove('integrity') }
    if ($node.PSObject.Properties['files']) {
        foreach ($p in $node.files.PSObject.Properties) { Remove-Integrity $p.Value }
    }
}

function Write-Asar($asar, [string]$relPath, [byte[]]$newBytes, [string]$outPath) {
    Remove-Integrity $asar.header
    $script:gwp_rel = $relPath
    $script:gwp_new = $newBytes
    $script:gwp_cursor = 0L
    $script:gwp_map = @{}
    function Walk-Assign2($node, [string]$path) {
        if ($node.PSObject.Properties['files']) {
            foreach ($p in $node.files.PSObject.Properties) {
                $child = if ($path) { $path + '/' + $p.Name } else { $p.Name }
                Walk-Assign2 $p.Value $child
            }
            return
        }
        if ($node.PSObject.Properties['link'] -and $null -ne $node.link) { return }
        if ($node.PSObject.Properties['unpacked'] -and $node.unpacked) { return }
        if (-not ($node.PSObject.Properties['offset'])) { return }
        $script:gwp_map[$path] = [long]$node.offset
        $size = [long]$node.size
        $newSize = $size
        if ($path -eq $script:gwp_rel) {
            $newSize = [long]$script:gwp_new.Length
            $node.size = $newSize
        }
        $node.offset = [string]$script:gwp_cursor
        $script:gwp_cursor += $newSize
    }
    Walk-Assign2 $asar.header ''

    $json      = $asar.header | ConvertTo-Json -Depth 100 -Compress
    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $padLen        = (4 - ($jsonBytes.Length % 4)) % 4
    $headerBufLen  = 8 + $jsonBytes.Length + $padLen
    $payloadSize   = 4 + $jsonBytes.Length + $padLen

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint32]4)
    $bw.Write([uint32]$headerBufLen)
    $bw.Write([uint32]$payloadSize)
    $bw.Write([uint32]$jsonBytes.Length)
    $bw.Write($jsonBytes)
    if ($padLen -gt 0) { $bw.Write((New-Object byte[] $padLen)) }

    function Walk-Write($node, [string]$path) {
        if ($node.PSObject.Properties['files']) {
            foreach ($p in $node.files.PSObject.Properties) {
                $child = if ($path) { $path + '/' + $p.Name } else { $p.Name }
                Walk-Write $p.Value $child
            }
            return
        }
        if ($node.PSObject.Properties['link'] -and $null -ne $node.link) { return }
        if ($node.PSObject.Properties['unpacked'] -and $node.unpacked) { return }
        if (-not ($node.PSObject.Properties['offset'])) { return }
        $size = [int]$node.size
        if ($path -eq $script:gwp_rel) {
            $bw.Write($script:gwp_new)
        } elseif ($size -gt 0) {
            $oldOff = [long]$script:gwp_map[$path]
            $srcOff = $asar.contentBase + $oldOff
            $chunk = New-Object byte[] $size
            [Array]::Copy($asar.bytes, $srcOff, $chunk, 0, $size)
            $bw.Write($chunk)
        }
    }
    Walk-Write $asar.header ''
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($outPath, $ms.ToArray())
    $bw.Dispose(); $ms.Dispose()
}

# ================= main =================
$resourcesDir = Find-ZCodeDir
if (-not $resourcesDir) {
    Write-Host '[?] Could not auto-locate ZCode. Example: D:\installer\zcode\resources' -ForegroundColor Yellow
    $manual = Read-Host 'Enter the folder that contains app.asar (resources dir)'
    if (-not (Test-Path (Join-Path $manual 'app.asar'))) {
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
$cssHit = Get-CssEntryAndBytes $asar $cssRelPath
if (-not $cssHit) { throw "renderer css not found ($cssRelPath); cannot restore." }
$cssText = [System.Text.Encoding]::UTF8.GetString($cssHit.bytes)
$cBegin = Count-Str $cssText $markerBegin
$cEnd   = Count-Str $cssText $markerEnd

if ($cBegin -eq 0 -and $cEnd -eq 0) {
    Write-Host '[1/3] no gear-wallpaper patch present, nothing to restore.'
    if ($NoRestart) {
        Write-Host 'done (NoRestart: leave ZCode closed).'
    } elseif ($zcodeExe) { Start-Process $zcodeExe; Write-Host 'ZCode restarted.' }
    Read-Host 'Press Enter to exit'
    exit 0
}
if ($cBegin -ne 1 -or $cEnd -ne 1) {
    throw 'app.asar contains a broken gear-wallpaper block; cannot restore automatically.'
}
Write-Host '[1/3] state: patched'

# preferred: strip the gear block from the CURRENT asar (keeps every other patch)
Write-Host '[2/3] stripping gear-wallpaper block in place (other patches preserved)'
$idx = $cssText.IndexOf($markerBegin)
$endIdx = $cssText.IndexOf($markerEnd) + $markerEnd.Length
$cleanText = ($cssText.Substring(0, $idx) + $cssText.Substring($endIdx))
if ($idx -gt 0 -and $cleanText[$idx - 1] -eq "`n") {
    $cleanText = $cleanText.Substring(0, $idx - 1) + $cleanText.Substring($idx)
}
$cleanBytes = [System.Text.Encoding]::UTF8.GetBytes($cleanText)
$tmpPath = "$asarPath.tmp"
Write-Asar $asar $cssRelPath $cleanBytes $tmpPath
Move-Item -Force $tmpPath $asarPath

# verify
$chk = Read-Asar $asarPath
$chkCss = Get-CssEntryAndBytes $chk $cssRelPath
$chkText = [System.Text.Encoding]::UTF8.GetString($chkCss.bytes)
if ((Count-Str $chkText $markerBegin) -ne 0) {
    throw 'restore verification failed (gear block still present); asar left in current state.'
}
Write-Host '[3/3] verified: gear-wallpaper block removed.'

if ($NoRestart) {
    Write-Host 'done (NoRestart: leave ZCode closed).'
} elseif ($zcodeExe) {
    Start-Process $zcodeExe
    Write-Host 'ZCode restarted.'
} else {
    Write-Host 'done. Start ZCode manually.'
}
