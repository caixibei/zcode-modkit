# ZCode boot-animation restore (v1, portable) - save as UTF-8 WITHOUT BOM
# - Removes ONLY the boot-animation block (ZCODE-BOOT-ANIMATION-* markers) from
#   out/renderer/index.html in the CURRENT asar: every other patch (font /
#   wallpaper / gear wallpaper / update disable / ...) is preserved regardless
#   of backup age.
# - The backup (app.asar.boot-backup + .sha256 sidecar) is written by the patch
#   script for reference/upgrade bookkeeping; this restore never overwrites the
#   whole archive with it, so patches applied after the boot patch survive.
# - Never touches any other file in the archive.
param(
    [switch]$NoRestart,   # toolbox mode: do not relaunch ZCode after restoring
    [string]$TargetAsar   # advanced/testing: operate on this app.asar instead of the auto-located one (skips the running check)
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
# Clear NODE_OPTIONS from this process so the ZCode.exe we (re)start never
# inherits unsupported flags (packaged Electron apps print a startup ERROR for
# e.g. --max-old-space-size); the machine/user registry value is NOT touched.
try { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue } catch {}

$backupPath = Join-Path $PSScriptRoot 'app.asar.boot-backup'
$hashPath   = Join-Path $PSScriptRoot 'app.asar.boot-backup.sha256'

$markerBegin = '<!-- ZCODE-BOOT-ANIMATION-BEGIN -->'
$markerEnd   = '<!-- ZCODE-BOOT-ANIMATION-END -->'
$htmlRelPath = 'out/renderer/index.html'

function Count-Str([string]$hay, [string]$s) {
    return ([regex]::Matches($hay, [regex]::Escape($s))).Count
}
function Hash-Bytes([byte[]]$b) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($b) | ForEach-Object { $_.ToString('X2') }) -join '') } finally { $sha.Dispose() }
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

# Electron asar integrity: SHA256 of the whole payload (hex) plus SHA256 of
# every 4 MiB block (hex), matching electron/asar's filesystem integrity format.
function New-AsarIntegrity([byte[]]$bytes) {
    $blocks = New-Object System.Collections.Generic.List[string]
    $blockSize = 4194304
    for ($off = 0; $off -lt $bytes.Length; $off += $blockSize) {
        $len = [Math]::Min($blockSize, $bytes.Length - $off)
        $chunk = New-Object byte[] $len
        [Array]::Copy($bytes, $off, $chunk, 0, $len)
        [void]$blocks.Add((Hash-Bytes $chunk).ToLowerInvariant())
    }
    return @{
        algorithm = 'SHA256'
        hash      = (Hash-Bytes $bytes).ToLowerInvariant()
        blockSize = $blockSize
        blocks    = $blocks.ToArray()
    }
}

function Write-Asar($asar, [string]$relPath, [byte[]]$newBytes, [string]$outPath) {
    # Walk-Assign2 rewrites offsets in place, so it must walk a CLONE of the
    # header (a second call on the same $asar would shift offsets twice).
    $header = ($asar.header | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json
    $script:zba_rel = $relPath
    $script:zba_new = $newBytes
    $script:zba_cursor = 0L
    $script:zba_map = @{}
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
        $script:zba_map[$path] = [long]$node.offset
        $size = [long]$node.size
        $newSize = $size
        if ($path -eq $script:zba_rel) {
            $newSize = [long]$script:zba_new.Length
            $node.size = $newSize
            if ($node.PSObject.Properties['integrity'] -and $null -ne $node.integrity) {
                $node.integrity = New-AsarIntegrity $script:zba_new
            }
        }
        $node.offset = [string]$script:zba_cursor
        $script:zba_cursor += $newSize
    }
    Walk-Assign2 $header ''

    $json      = $header | ConvertTo-Json -Depth 100 -Compress
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
        if ($path -eq $script:zba_rel) {
            $bw.Write($script:zba_new)
        } elseif ($size -gt 0) {
            $oldOff = [long]$script:zba_map[$path]
            $srcOff = $asar.contentBase + $oldOff
            $chunk = New-Object byte[] $size
            [Array]::Copy($asar.bytes, $srcOff, $chunk, 0, $size)
            $bw.Write($chunk)
        }
    }
    Walk-Write $header ''
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($outPath, $ms.ToArray())
    $bw.Dispose(); $ms.Dispose()
}

function Assert-SentinelsUnchanged([string]$srcPath, $tmpAsar, [string]$tmpPath) {
    $srcCheck = [System.IO.File]::ReadAllBytes($srcPath)
    $hdrTotal2 = [BitConverter]::ToUInt32($srcCheck, 4)
    $jsonLen2 = [BitConverter]::ToUInt32($srcCheck, 12)
    $srcHdr = ([System.Text.Encoding]::UTF8.GetString($srcCheck, 16, [int]$jsonLen2)) | ConvertFrom-Json
    $srcBase = 8 + [int]$hdrTotal2
    foreach ($sentinel in @('package.json', 'out/main/index.js')) {
        $n = $srcHdr
        foreach ($s in ($sentinel -split '/')) { $n = $n.files.$s }
        $sLen = [int]$n.size
        $srcBytes = New-Object byte[] $sLen
        [Array]::Copy($srcCheck, $srcBase + [long]$n.offset, $srcBytes, 0, $sLen)
        $t = $tmpAsar.header
        foreach ($s in ($sentinel -split '/')) { $t = $t.files.$s }
        $tLen = [int]$t.size
        $tmpBytes = New-Object byte[] $tLen
        [Array]::Copy($tmpAsar.bytes, $tmpAsar.contentBase + [long]$t.offset, $tmpBytes, 0, $tLen)
        if ($sLen -ne $tLen -or -not [System.Linq.Enumerable]::SequenceEqual([byte[]]$srcBytes, [byte[]]$tmpBytes)) {
            Remove-Item $tmpPath -ErrorAction SilentlyContinue
            throw "rebuilt asar failed self-check (payload sentinel $sentinel differs from source); original untouched."
        }
    }
}

# ================= main =================
$resourcesDir = Find-ZCodeDir
if (-not $resourcesDir -and -not $TargetAsar) {
    Write-Host '[?] Could not auto-locate ZCode. Example: D:\installer\zcode\resources' -ForegroundColor Yellow
    $manual = Read-Host 'Enter the folder that contains app.asar (resources dir)'
    if (-not (Test-Path (Join-Path $manual 'app.asar'))) {
        Write-Host "[X] app.asar not found under: $manual" -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
    $resourcesDir = $manual
}
if ($TargetAsar) {
    $asarPath = $TargetAsar
    $zcodeExe = $null
    Write-Host "target (override): $asarPath"
} else {
    $asarPath = Join-Path $resourcesDir 'app.asar'
    $zcodeExe = Join-Path (Split-Path $resourcesDir -Parent) 'ZCode.exe'
    if (-not (Test-Path $zcodeExe)) { $zcodeExe = $null }
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
$htmlHit = Get-EntryAndBytes $asar $htmlRelPath
if (-not $htmlHit) { throw "renderer entry page not found ($htmlRelPath); cannot restore." }
$htmlText = [System.Text.Encoding]::UTF8.GetString($htmlHit.bytes)
$cBegin = Count-Str $htmlText $markerBegin
$cEnd   = Count-Str $htmlText $markerEnd

if ($cBegin -eq 0 -and $cEnd -eq 0) {
    Write-Host '[1/3] no boot-animation patch present, nothing to restore.'
    if ($NoRestart) {
        Write-Host 'done (NoRestart: leave ZCode closed).'
    } elseif ($zcodeExe) { Start-Process $zcodeExe; Write-Host 'ZCode restarted.' }
    Read-Host 'Press Enter to exit'
    exit 0
}
if ($cBegin -ne 1 -or $cEnd -ne 1) {
    throw 'app.asar contains a broken boot-animation block; cannot restore automatically.'
}
Write-Host '[1/3] state: patched'

# preferred: strip the block from the CURRENT asar (keeps every other patch)
Write-Host '[2/3] stripping boot-animation block in place (other patches preserved)'
$idx = $htmlText.IndexOf($markerBegin)
$endIdx = $htmlText.IndexOf($markerEnd) + $markerEnd.Length
$before = $htmlText.Substring(0, $idx)
$after = $htmlText.Substring($endIdx)
if ($before.EndsWith("`r`n")) { $before = $before.Substring(0, $before.Length - 2) }
elseif ($before.EndsWith("`n") -or $before.EndsWith("`r")) { $before = $before.Substring(0, $before.Length - 1) }
if ($after.StartsWith("`r`n")) { $after = $after.Substring(2) }
elseif ($after.StartsWith("`n") -or $after.StartsWith("`r")) { $after = $after.Substring(1) }
$cleanText = $before + $after
$cleanBytes = [System.Text.Encoding]::UTF8.GetBytes($cleanText)
$tmpPath = "$asarPath.tmp"
Write-Asar $asar $htmlRelPath $cleanBytes $tmpPath
$tmpAsar = Read-Asar $tmpPath
Assert-SentinelsUnchanged $asarPath $tmpAsar $tmpPath
Move-Item -Force $tmpPath $asarPath

# verify
$chk = Read-Asar $asarPath
$chkHit = Get-EntryAndBytes $chk $htmlRelPath
$chkText = [System.Text.Encoding]::UTF8.GetString($chkHit.bytes)
if ((Count-Str $chkText $markerBegin) -ne 0 -or (Count-Str $chkText $markerEnd) -ne 0) {
    throw 'restore verification failed (boot block still present); asar left in current state.'
}
Write-Host '[3/3] verified: boot-animation block removed.'

if ($NoRestart) {
    Write-Host 'done (NoRestart: leave ZCode closed).'
} elseif ($zcodeExe) {
    Start-Process $zcodeExe
    Write-Host 'ZCode restarted.'
} else {
    Write-Host 'done. Start ZCode manually.'
}
