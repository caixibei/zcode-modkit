# ZCode empty-draft watermark restore (v1, portable) - save as UTF-8 WITHOUT BOM
# - Removes the ZCODE-DRAFTLOGO-* block from the CURRENT asar in place: every
#   other CSS-block patch (wallpaper / gear wallpaper / font stacks) and every
#   main-process patch stays exactly as it is.
# - Fallback: if the block markers are damaged (only one of the two present),
#   the stylesheet captured at patch time (app.asar.draftlogo-css-backup.bin)
#   is used. That restores this stylesheet to its state at patch time, so blocks
#   added by later patches are NOT included - the script asks before doing it.
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

$cssBackupPath = Join-Path $PSScriptRoot 'app.asar.draftlogo-css-backup.bin'
$cssHashPath   = Join-Path $PSScriptRoot 'app.asar.draftlogo-css-backup.sha256'

$markerBegin = '/* ZCODE-DRAFTLOGO-PATCH-BEGIN */'
$markerEnd   = '/* ZCODE-DRAFTLOGO-PATCH-END */'
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
function Hash-Bytes([byte[]]$b) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($b) | ForEach-Object { $_.ToString('X2') }) -join '') } finally { $sha.Dispose() }
}
function Find-ZCodeDir {
    # toolbox resolves the folder once and passes it down (ZCODE_RESOURCES_DIR),
    # so a multi-task run does not ask for the same path in every script
    if ($env:ZCODE_RESOURCES_DIR -and (Test-Path (Join-Path $env:ZCODE_RESOURCES_DIR 'app.asar'))) { return $env:ZCODE_RESOURCES_DIR }
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

# ---- asar primitives (self-contained, identical to the patch script) --------------
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
function Write-Asar($asar, [string]$relPath, [byte[]]$newBytes, [string]$outPath) {
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
function Assert-Sentinels([string]$srcPath, $newAsar, [string]$tmpPath) {
    # untouched files must be byte-identical between source and rebuilt asar
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
        $t = $newAsar.header
        foreach ($s in ($sentinel -split '/')) { $t = $t.files.$s }
        $tLen = [int]$t.size
        $tmpBytes = New-Object byte[] $tLen
        [Array]::Copy($newAsar.bytes, $newAsar.contentBase + [long]$t.offset, $tmpBytes, 0, $tLen)
        if ($sLen -ne $tLen -or -not [System.Linq.Enumerable]::SequenceEqual([byte[]]$srcBytes, [byte[]]$tmpBytes)) {
            Remove-Item $tmpPath -ErrorAction SilentlyContinue
            throw "rebuilt asar failed self-check (payload sentinel $sentinel differs from source); original untouched."
        }
    }
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
    $asarPath = $TargetAsar
    $zcodeExe = $null
    Write-Host "target (override): $asarPath"
} else {
    Write-Host "target: $asarPath"
}

# 0) ZCode must not be running (skipped for explicit -TargetAsar overrides)
if (-not $TargetAsar) {
    $procs = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Host '[X] ZCode is running, app.asar is locked.' -ForegroundColor Red
        Write-Host '    Quit ZCode first (right-click tray icon -> Quit; clicking X may only minimize to tray).' -ForegroundColor Yellow
        Read-Host 'Press Enter to exit'
        exit 1
    }
}

# 1) read current asar + stylesheet, detect block state
$asar = Read-Asar $asarPath
$cssRelPath = Resolve-RendererCss $asar
$cssHit = Get-CssEntryAndBytes $asar $cssRelPath
if (-not $cssHit) {
    throw "renderer css not found in this ZCode build ($cssRelPath). Version changed? Refusing."
}
$cssText = [System.Text.Encoding]::UTF8.GetString($cssHit.bytes)
$cBegin = Count-Str $cssText $markerBegin
$cEnd   = Count-Str $cssText $markerEnd

if ($cBegin -eq 0 -and $cEnd -eq 0) {
    Write-Host '[=] no draft-logo block present: nothing to restore.'
    $restored = $false
} elseif ($cBegin -eq 1 -and $cEnd -eq 1 -and $cssText.IndexOf($markerBegin) -lt $cssText.IndexOf($markerEnd)) {
    Write-Host '[1/3] state: patched (in-place strip)'
    $idx = $cssText.IndexOf($markerBegin)
    $endIdx = $cssText.IndexOf($markerEnd) + $markerEnd.Length
    $cleanCssText = ($cssText.Substring(0, $idx) + $cssText.Substring($endIdx))
    # drop the newline the patch prepended before the block
    if ($idx -gt 0 -and $cleanCssText[$idx - 1] -eq [char]10) {
        $cleanCssText = $cleanCssText.Substring(0, $idx - 1) + $cleanCssText.Substring($idx)
    }
    $cleanBytes = [System.Text.Encoding]::UTF8.GetBytes($cleanCssText)
    $tmpPath = "$asarPath.tmp"
    Write-Asar $asar $cssRelPath $cleanBytes $tmpPath
    $tmpAsar = Read-Asar $tmpPath
    $tmpHit = Get-CssEntryAndBytes $tmpAsar $cssRelPath
    if (-not $tmpHit) {
        Remove-Item $tmpPath -ErrorAction SilentlyContinue
        throw 'rebuilt asar failed self-check (css unreadable); original untouched.'
    }
    $tmpText = [System.Text.Encoding]::UTF8.GetString($tmpHit.bytes)
    if ((Count-Str $tmpText $markerBegin) -ne 0 -or (Count-Str $tmpText $markerEnd) -ne 0) {
        Remove-Item $tmpPath -ErrorAction SilentlyContinue
        throw 'rebuilt asar failed self-check (markers remain); original untouched.'
    }
    Assert-Sentinels $asarPath $tmpAsar $tmpPath
    Move-Item -Force $tmpPath $asarPath
    Write-Host '[2/3] block stripped; other patches preserved.'
    $restored = $true
} else {
    # damaged markers: use the stylesheet captured at patch time (fallback)
    Write-Host '[!] draft-logo markers are damaged (only one of BEGIN/END present).' -ForegroundColor Yellow
    if (-not (Test-Path $cssBackupPath)) {
        throw 'no restore point (app.asar.draftlogo-css-backup.bin). Re-run patch-zcode-draft-logo.bat, then restore again. Refusing.'
    }
    $sidecarOk = $false
    if (Test-Path $cssHashPath) {
        $expect = (Get-Content $cssHashPath -ErrorAction SilentlyContinue)
        $actual = (Hash-Bytes ([System.IO.File]::ReadAllBytes($cssBackupPath)))
        $sidecarOk = ($expect -and ($actual -eq $expect.Trim()))
    }
    if (-not $sidecarOk) { throw 'restore point hash mismatch (file edited or truncated). Refusing.' }
    Write-Host '    Using the stylesheet captured at patch time. Any CSS block added by a later patch'
    Write-Host '    (wallpaper / gear wallpaper) will be gone as well - re-run that patch afterwards.'
    $ok = Read-Host 'continue? [y/N]'
    if ($ok -notmatch '^[yY]') { exit 0 }
    $cleanBytes = [System.IO.File]::ReadAllBytes($cssBackupPath)
    $tmpPath = "$asarPath.tmp"
    Write-Asar $asar $cssRelPath $cleanBytes $tmpPath
    $tmpAsar = Read-Asar $tmpPath
    $tmpHit = Get-CssEntryAndBytes $tmpAsar $cssRelPath
    if (-not $tmpHit) {
        Remove-Item $tmpPath -ErrorAction SilentlyContinue
        throw 'rebuilt asar failed self-check (css unreadable); original untouched.'
    }
    $tmpText = [System.Text.Encoding]::UTF8.GetString($tmpHit.bytes)
    if ((Count-Str $tmpText $markerBegin) -ne 0 -or (Count-Str $tmpText $markerEnd) -ne 0) {
        Remove-Item $tmpPath -ErrorAction SilentlyContinue
        throw 'restore point still contains draft-logo markers; refusing (delete the .bin and re-patch).'
    }
    Assert-Sentinels $asarPath $tmpAsar $tmpPath
    Move-Item -Force $tmpPath $asarPath
    Write-Host '[2/3] restored from patch-time stylesheet.'
    $restored = $true
}

if (-not $restored) {
    Write-Host 'nothing changed.'
} else {
    Write-Host '[3/3] done.'
    if ($NoRestart) {
        Write-Host 'done (NoRestart: leave ZCode closed).'
    } elseif ($zcodeExe) {
        Start-Process $zcodeExe
        Write-Host 'ZCode restarted.'
    } else {
        Write-Host 'done. Start ZCode manually.'
    }
}
