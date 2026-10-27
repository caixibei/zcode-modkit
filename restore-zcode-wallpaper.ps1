# ZCode desktop wallpaper restore (v1, portable) - save as UTF-8 WITH BOM
# - Removes the wallpaper block from the CURRENT asar in place (preferred): this
#   preserves any other patches (font stacks / update disable) regardless of
#   when the backup was taken.
# - Falls back to restoring app.asar verbatim from the clean backup created by
#   patch-zcode-wallpaper.ps1 (app.asar.wallpaper-backup + .sha256 sidecar) when
#   the current asar carries no recognizable wallpaper block (factory fallback).
param(
    [switch]$NoRestart,   # toolbox mode: do not relaunch ZCode after restoring
    [string]$TargetAsar     # advanced/testing: operate on this app.asar instead of the auto-located one (skips the running check)
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
# Clear NODE_OPTIONS from this process so the ZCode.exe we (re)start never
# inherits unsupported flags (packaged Electron apps print a startup ERROR for
# e.g. --max-old-space-size); the machine/user registry value is NOT touched.
try { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue } catch {}
Add-Type -AssemblyName System.Drawing

$backupPath = Join-Path $PSScriptRoot 'app.asar.wallpaper-backup'
$hashPath   = Join-Path $PSScriptRoot 'app.asar.wallpaper-backup.sha256'

$markerBegin = '/* ZCODE-WALLPAPER-PATCH-BEGIN */'
$markerEnd   = '/* ZCODE-WALLPAPER-PATCH-END */'
# stylesheet name carries a build hash (3.16.3: styles-9Z13W0KP.css), resolved
# from the asar header at runtime via Resolve-RendererCss
$cssRelPath  = $null

function Resolve-RendererCss($asar) {
    # pick the main renderer stylesheet: out/renderer/assets/styles-*.css
    # (exactly one; the sibling styles-*.js bundle is not matched)
    $assets = $asar.header.files.out.files.renderer.files.assets
    $hits = @()
    foreach ($p in $assets.files.PSObject.Properties) {
        if ($p.Name -like 'styles-*.css' -and -not $p.Value.unpacked -and -not $p.Value.link) { $hits += $p.Name }
    }
    if ($hits.Count -eq 1) { return "out/renderer/assets/$($hits[0])" }
    throw "cannot identify the renderer stylesheet in this ZCode build (styles-*.css hits: $($hits.Count)). Version changed? Refusing."
}

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

. {
    # asar primitives shared with the patch script (kept in one place by copying;
    # the toolkit ships both scripts self-contained by design)
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

# Electron asar integrity: SHA256 of the whole payload (hex) plus SHA256 of
# every 4 MiB block (hex), matching electron/asar's filesystem integrity
# format verified against the 3.16.3 header.
function New-AsarIntegrity([byte[]]$bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
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
    } finally {
        $sha.Dispose()
    }
}
function Hash-Bytes([byte[]]$b) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($b) | ForEach-Object { $_.ToString('X2') }) -join '') } finally { $sha.Dispose() }
}
function Write-Asar($asar, [string]$relPath, [byte[]]$newBytes, [string]$outPath) {
    # Walk-Assign2 below rewrites offsets in place, so it must walk a CLONE of
    # the header: a second Write-Asar call on the same $asar would otherwise
    # treat already-shifted offsets as source positions and corrupt every
    # payload file after the replaced one.
    $header = ($asar.header | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json
    $script:wp_rel = $relPath
    $script:wp_new = $newBytes
    $script:wp_cursor = 0L
    $script:wp_delta = 0L
    $script:wp_map = @{}
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
        $script:wp_map[$path] = [long]$node.offset
        $size = [long]$node.size
        $newSize = $size
        if ($path -eq $script:wp_rel) {
            $newSize = [long]$script:wp_new.Length
            $node.size = $newSize
            $script:wp_delta = $newSize - $size
            if ($node.PSObject.Properties['integrity'] -and $null -ne $node.integrity) {
                $node.integrity = New-AsarIntegrity $script:wp_new
            }
        }
        $node.offset = [string]$script:wp_cursor
        $script:wp_cursor += $newSize
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
        if ($path -eq $script:wp_rel) {
            $bw.Write($script:wp_new)
        } elseif ($size -gt 0) {
            $oldOff = [long]$script:wp_map[$path]
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
$cssRelPath = Resolve-RendererCss $asar
$cssHit = Get-CssEntryAndBytes $asar $cssRelPath
if (-not $cssHit) { throw "renderer css not found ($cssRelPath); cannot restore." }
$cssText = [System.Text.Encoding]::UTF8.GetString($cssHit.bytes)
$cBegin = Count-Str $cssText $markerBegin
$cEnd   = Count-Str $cssText $markerEnd

if ($cBegin -eq 0 -and $cEnd -eq 0) {
    Write-Host '[1/3] no wallpaper patch present, nothing to restore.'
    if ($NoRestart) {
        Write-Host 'done (NoRestart: leave ZCode closed).'
    } elseif ($zcodeExe) { Start-Process $zcodeExe; Write-Host 'ZCode restarted.' }
    Read-Host 'Press Enter to exit'
    exit 0
}
if ($cBegin -ne 1 -or $cEnd -ne 1) {
    throw 'app.asar contains a broken wallpaper block; cannot restore automatically.'
}
Write-Host '[1/3] state: patched'

# preferred: strip the block from the CURRENT asar (keeps font/update patches
# regardless of backup age); the verbatim backup is only a factory fallback
$restored = $false
if ($cBegin -eq 1 -and $cEnd -eq 1) {
    Write-Host '[2/3] stripping wallpaper block in place (other patches preserved)'
    $idx = $cssText.IndexOf($markerBegin)
    $endIdx = $cssText.IndexOf($markerEnd) + $markerEnd.Length
    $cleanText = ($cssText.Substring(0, $idx) + $cssText.Substring($endIdx))
    # also drop the single newline the patch appended before the block
    if ($idx -gt 0 -and $cleanText[$idx - 1] -eq "`n") {
        $cleanText = $cleanText.Substring(0, $idx - 1) + $cleanText.Substring($idx)
    }
    $cleanBytes = [System.Text.Encoding]::UTF8.GetBytes($cleanText)
    $tmpPath = "$asarPath.tmp"
    Write-Asar $asar $cssRelPath $cleanBytes $tmpPath
    # payload spot-check before the final swap: re-read the SOURCE asar from
    # disk and verify untouched sentinel files byte-for-byte. Catches any
    # rebuild bug (e.g. a shifted-offset double rebuild) that the marker
    # verification below misses; package.json is the Electron entry point and
    # the last file in the payload.
    $srcCheck = [System.IO.File]::ReadAllBytes($asarPath)
    $hdrTotal2 = [BitConverter]::ToUInt32($srcCheck, 4)
    $jsonLen2 = [BitConverter]::ToUInt32($srcCheck, 12)
    $srcHdr = ([System.Text.Encoding]::UTF8.GetString($srcCheck, 16, [int]$jsonLen2)) | ConvertFrom-Json
    $srcBase = 8 + [int]$hdrTotal2
    $tmpAsar = Read-Asar $tmpPath
    foreach ($sentinel in @('package.json', 'out/main/index.js')) {
        $segs = $sentinel -split '/'
        $n = $srcHdr
        foreach ($s in $segs) { $n = $n.files.$s }
        $sLen = [int]$n.size
        $srcBytes = New-Object byte[] $sLen
        [Array]::Copy($srcCheck, $srcBase + [long]$n.offset, $srcBytes, 0, $sLen)
        $tSegs = $sentinel -split '/'
        $t = $tmpAsar.header
        foreach ($s in $tSegs) { $t = $t.files.$s }
        $tLen = [int]$t.size
        $tmpBytes = New-Object byte[] $tLen
        [Array]::Copy($tmpAsar.bytes, $tmpAsar.contentBase + [long]$t.offset, $tmpBytes, 0, $tLen)
        if ($sLen -ne $tLen -or -not [System.Linq.Enumerable]::SequenceEqual([byte[]]$srcBytes, [byte[]]$tmpBytes)) {
            Remove-Item $tmpPath -ErrorAction SilentlyContinue
            throw "rebuilt asar failed self-check (payload sentinel $sentinel differs from source); original untouched."
        }
    }
    Move-Item -Force $tmpPath $asarPath
    $restored = $true
}

# fallback: restore the clean backup asar verbatim (factory state)
if (-not $restored) {
    Write-Host '[2/3] no recognizable wallpaper block in current asar; trying backup restore'
    if (Test-Path $backupPath) {
        $sidecarOk = $false
        if (Test-Path $hashPath) {
            $expect = (Get-Content $hashPath -ErrorAction SilentlyContinue)
            $actual = (Get-FileHash $backupPath -Algorithm SHA256).Hash
            $sidecarOk = ($expect -and ($actual -eq $expect.Trim()))
        }
        if ($sidecarOk) {
            Copy-Item -Force $backupPath $asarPath
            $restored = $true
            Write-Host '     restored from clean backup (verbatim factory state)'
            Write-Host '     (note: any patches applied after that backup was taken are gone with it)'
        }
    }
    if (-not $restored) {
        Write-Host '[X] nothing to restore from: current asar has no wallpaper block and no valid backup exists.' -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
}

# verify
$chk = Read-Asar $asarPath
$chkCss = Get-CssEntryAndBytes $chk $cssRelPath
$chkText = [System.Text.Encoding]::UTF8.GetString($chkCss.bytes)
if ((Count-Str $chkText $markerBegin) -ne 0) {
    throw 'restore verification failed (block still present); asar left in current state.'
}
Write-Host '[3/3] verified: wallpaper block removed.'

if ($NoRestart) {
    Write-Host 'done (NoRestart: leave ZCode closed).'
} elseif ($zcodeExe) {
    Start-Process $zcodeExe
    Write-Host 'ZCode restarted.'
} else {
    Write-Host 'done. Start ZCode manually.'
}
