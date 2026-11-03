# ZCode empty-draft watermark patch (v1, portable) - save as UTF-8 WITHOUT BOM
# - Replaces the big "Z" watermark on the new-task (empty draft) screen with a
#   text wordmark drawn from an inline SVG data URI.
# - Pure CSS: a block with its own markers (ZCODE-DRAFTLOGO-*) is appended to the
#   main renderer stylesheet inside app.asar. The original watermark nodes are
#   hidden with attribute selectors, so no JavaScript bundle is touched and a
#   later ZCode version can still be re-patched without adapting source code.
#   Selectors used (verified against 3.16.3 renderer bundle styles-*.js):
#     * div[aria-hidden="true"][class*="aspect-[5/4]"]  -> watermark container
#       (empty-draft greeting block, flex column, position:absolute)
#     * img[data-v4-draft-logo]                        -> dark-theme Z image
#     * svg[viewBox="0 0 400 320"]                     -> light-theme Z svg
# - app.asar is FULLY REBUILT (the CSS block changes the file length).
#   Safety verified beforehand on this machine:
#     * Electron asar-integrity fuse is NOT enabled in ZCode.exe
#     * rebuilt asar passes the official @electron/asar reader
#   The rebuild keeps every original file byte-identical and in the original
#   order; only the target CSS gains an appended block and the header gains
#   recomputed offsets; per-file "integrity" fields are recomputed/dropped.
# - Coexists with the other CSS-block patches (wallpaper ZCODE-WALLPAPER-*,
#   gear wallpaper ZCODE-GWP-*, font stacks): each patch strips and re-appends
#   only its own block. Re-running this patch only swaps its own block.
# - Restore point: app.asar.draftlogo-css-backup.bin (+ .sha256) holds this
#   stylesheet WITHOUT this block at patch time. It is a fallback only (used
#   when the markers are damaged); no 350 MB asar copy is made.
# - Exits automatically on success; pauses only on errors
# Revert with restore-zcode-draft-logo.bat
param(
    [switch]$NoRestart,                       # toolbox mode: do not relaunch ZCode after patching
    [string]$TargetAsar,                      # advanced/testing: operate on this app.asar instead of the auto-located one (skips the running check)
    [string]$Text = 'DeepSeek Harness',       # watermark text
    [ValidateRange(1, 100)]
    [int]$Opacity = 0                         # watermark opacity in percent; 0 = ask (default 16)
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

# ---- the renderer CSS this kit patches ----
# The bundled stylesheet name carries a content hash that changes every build,
# so it is discovered from the asar header at runtime instead of hardcoded.
$cssRelPath = $null

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
    # all branches return the resources dir (the folder containing app.asar)
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

# ---- asar primitives ---------------------------------------------------------------
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
    # walk directories by path segments, tolerating node objects under .files
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
            $blocks.Add((Hash-Bytes $chunk).ToLowerInvariant())
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

# Rebuild the archive from $asar with one inline file replaced by $newBytes.
# Every other inline file is copied byte-identical in header key order; offsets
# after the replaced file shift by the size delta and are written back into the
# header BEFORE serialization. The header is walked as a CLONE so a second call
# on the same $asar object cannot reuse already-shifted offsets.
function Write-Asar($asar, [string]$relPath, [byte[]]$newBytes, [string]$outPath) {
    $header = ($asar.header | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json

    $script:wp_delta = 0L
    $script:wp_cursor = 0L
    $script:wp_rel = $relPath
    $script:wp_new = $newBytes
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

# ---- watermark CSS block -----------------------------------------------------------
# Single-line lockup drawn ABOVE the greeting. The ::after box is wider than the
# container (left/right -25%) so the wordmark can be rendered large, and it ends
# at 40% of the container height, leaving a clear gap to the greeting line.
# The watermark is real CSS text (not an SVG background image) so it can reuse the
# app font stack: `var(--font-sans)` is the variable the UI font patch rewrites.
# (An SVG loaded as an image cannot see CSS variables or web fonts, only system
#  fonts by name - that is why the previous version could not reuse it.)
# Two colour variants because ZCode switches themes with
# @media (prefers-color-scheme: dark) - verified in the built stylesheet:
#   * light theme -> dark ink   (#3B4048 -> #171A1F, black-ish)
#   * dark theme  -> white ink  (#FFFFFF -> #B6BCC7, white-ish)
function ConvertTo-DraftLogoCss([string]$text, [int]$opacityPct) {
    # CSS string escaping for content:"..."
    $cssText = $text.Replace('\', '\\').Replace('"', '\"')
    $opacity = ([double]$opacityPct / 100.0).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $css = @"
$markerBegin
/* ZCode empty-draft watermark patch: hides the Z mark and paints "$text".
   Text is real CSS text so font-family can reuse --font-sans (the UI font stack).
   Light theme = dark ink, dark theme = white ink (ZCode uses prefers-color-scheme).
   Re-run patch-zcode-draft-logo.bat to change text/opacity; restore-zcode-draft-logo.bat reverts. */
:root{--zdl-opacity:$opacity}
div[aria-hidden="true"][class*="aspect-[5/4]"]>svg,
div[aria-hidden="true"][class*="aspect-[5/4]"]>img,
img[data-v4-draft-logo],
svg[viewBox="0 0 400 320"]{display:none!important}
div[aria-hidden="true"][class*="aspect-[5/4]"]::after{
content:"$cssText";
position:absolute;left:50%;right:auto;top:-40%;bottom:62%;
transform:translateX(-50%);
width:max-content;max-width:calc(100vw - 1rem);
display:flex;align-items:flex-end;justify-content:center;padding-bottom:12px;
font-family:"LXGW WenKai","LXGW WenKai Lite","LXGW WenKai Screen",var(--font-sans, "Segoe UI Semibold"),"Segoe UI Semibold","Segoe UI",Inter,Arial,sans-serif;
font-size:78px;font-weight:500;letter-spacing:.05em;line-height:1;white-space:nowrap;
color:transparent;
background-image:linear-gradient(180deg,#3B4048 0%,#22262C 45%,#171A1F 100%);
-webkit-background-clip:text;background-clip:text;
text-shadow:none;
opacity:calc(var(--zdl-opacity) * 1.5);pointer-events:none;
}
@media (prefers-color-scheme:dark){
div[aria-hidden="true"][class*="aspect-[5/4]"]::after{
background-image:linear-gradient(180deg,#FFFFFF 0%,#D5DAE3 45%,#B6BCC7 100%);
opacity:var(--zdl-opacity);
}
}
$markerEnd
"@
    return [System.Text.Encoding]::UTF8.GetBytes($css)
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
$asarPath  = Join-Path $resourcesDir 'app.asar'
$zcodeExe  = Join-Path (Split-Path $resourcesDir -Parent) 'ZCode.exe'
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

# 1) read current asar, extract css, detect state
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
    $state = 'clean'
    $cleanCssText = $cssText
} elseif ($cBegin -eq 1 -and $cEnd -eq 1 -and $cssText.IndexOf($markerBegin) -lt $cssText.IndexOf($markerEnd)) {
    $state = 'patched'
    $idx = $cssText.IndexOf($markerBegin)
    $endIdx = $cssText.IndexOf($markerEnd) + $markerEnd.Length
    $cleanCssText = ($cssText.Substring(0, $idx) + $cssText.Substring($endIdx))
    # also drop the newline the patch prepended before the block, so the
    # stripped css stays stable across re-runs
    if ($idx -gt 0 -and $cleanCssText[$idx - 1] -eq [char]10) {
        $cleanCssText = $cleanCssText.Substring(0, $idx - 1) + $cleanCssText.Substring($idx)
    }
} else {
    throw 'app.asar contains a broken draft-logo block; run restore-zcode-draft-logo.bat first. Refusing.'
}
Write-Host "[1/4] state: $state"

# 2) keep a block-free copy of this stylesheet as the restore fallback
#    (small, unlike the whole-asar backups of the wallpaper patches)
$cleanCssBytes = [System.Text.Encoding]::UTF8.GetBytes($cleanCssText)
[System.IO.File]::WriteAllBytes($cssBackupPath, $cleanCssBytes)
[System.IO.File]::WriteAllText($cssHashPath, (Hash-Bytes $cleanCssBytes))
Write-Host "[2/4] restore point: $(Split-Path $cssBackupPath -Leaf) ($($cleanCssBytes.Length) bytes)"

# 3) ask for opacity (text comes from -Text, default 'DeepSeek Harness')
if ($Opacity -le 0) {
    $opacityInput = Read-Host 'watermark opacity 5-45 (higher = more visible) [default 16]'
    $Opacity = 16
    if ($opacityInput -match '^\d+$') { $Opacity = [Math]::Max(5, [Math]::Min(45, [int]$opacityInput)) }
}
Write-Host "[3/4] text: `"$Text`", opacity $Opacity%"
$blockBytes = ConvertTo-DraftLogoCss $Text $Opacity

# assemble the css payload from the CURRENT css (stripped of this block only):
# every other CSS-block patch (wallpaper / gear / font) is preserved verbatim
$patchedCssBytes = New-Object byte[] ($cleanCssBytes.Length + 1 + $blockBytes.Length)
[Array]::Copy($cleanCssBytes, 0, $patchedCssBytes, 0, $cleanCssBytes.Length)
$patchedCssBytes[$cleanCssBytes.Length] = 0x0A
[Array]::Copy($blockBytes, 0, $patchedCssBytes, $cleanCssBytes.Length + 1, $blockBytes.Length)

# 4) rebuild the asar from the CURRENT asar with the new css block swapped in
$tmpPath = "$asarPath.tmp"
Write-Asar $asar $cssRelPath $patchedCssBytes $tmpPath

# self-check: tmp parses, css holds exactly one block, markers in order
$tmpAsar = Read-Asar $tmpPath
$tmpCssHit = Get-CssEntryAndBytes $tmpAsar $cssRelPath
if (-not $tmpCssHit) {
    Remove-Item $tmpPath -ErrorAction SilentlyContinue
    throw 'rebuilt asar failed self-check (css unreadable); original untouched.'
}
$tmpText = [System.Text.Encoding]::UTF8.GetString($tmpCssHit.bytes)
if ((Count-Str $tmpText $markerBegin) -ne 1 -or (Count-Str $tmpText $markerEnd) -ne 1) {
    Remove-Item $tmpPath -ErrorAction SilentlyContinue
    throw 'rebuilt asar failed self-check (markers); original untouched.'
}
if ($tmpText.IndexOf($markerEnd) -le $tmpText.IndexOf($markerBegin)) {
    Remove-Item $tmpPath -ErrorAction SilentlyContinue
    throw 'rebuilt asar failed self-check (marker order); original untouched.'
}

# payload spot-check before the final swap: re-read the SOURCE asar from disk
# and verify untouched sentinel files byte-for-byte (catches offset-shift bugs)
$srcCheck = [System.IO.File]::ReadAllBytes($asarPath)
$hdrTotal2 = [BitConverter]::ToUInt32($srcCheck, 4)
$jsonLen2 = [BitConverter]::ToUInt32($srcCheck, 12)
$srcHdr = ([System.Text.Encoding]::UTF8.GetString($srcCheck, 16, [int]$jsonLen2)) | ConvertFrom-Json
$srcBase = 8 + [int]$hdrTotal2
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
Write-Host '[4/4] patch written (asar rebuilt from current; other patches preserved).'

if ($NoRestart) {
    Write-Host 'done (NoRestart: leave ZCode closed).'
} elseif ($zcodeExe) {
    Start-Process $zcodeExe
    Write-Host 'ZCode restarted.'
} else {
    Write-Host 'done. Start ZCode manually.'
}
Write-Host "Draft watermark applied: `"$Text`", opacity $Opacity%. Re-run to change; restore-zcode-draft-logo.bat reverts."
