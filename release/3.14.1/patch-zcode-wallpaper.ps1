# ZCode desktop wallpaper patch (v1, portable) - save as UTF-8 WITH BOM
# - Replaces the ZCode desktop app root background with a user-selected photo:
#   the photo is scaled (long edge 1920), JPEG-compressed and embedded into the
#   renderer CSS inside app.asar as a data URI, painted behind the whole window
#   with a theme-colored translucent veil for text readability.
# - app.asar is FULLY REBUILT (equal-length replacement cannot embed a photo).
#   Safety verified beforehand on this machine:
#     * Electron asar-integrity fuse is NOT enabled in ZCode.exe
#     * rebuilt asar passes the official @electron/asar reader
#   The rebuild keeps every original file byte-identical and in the original
#   order; only the target CSS gains an appended block and the header gains
#   recomputed offsets; per-file "integrity" fields are dropped (not validated
#   without the fuse).
# - Photo sources: built-in images in .\wallpapers\ (auto-listed by menu), or
#   any image via manual path input (CJK paths supported).
# - Veil: theme-colored translucent layer over the photo. 0 = pure photo,
#   higher = more solid veil / fainter photo (default 60).
# - Re-run to switch photo or opacity at any time.
# - Backup = clean original app.asar of THIS machine (never overwritten by a
#   patched asar; rebuilt from the patched asar when missing/invalid).
# - Coexists with the font patch: font stacks live in the same CSS before the
#   appended block, the font patch's signature strings remain intact.
# - Exits automatically on success; pauses only on errors
# Revert with restore-zcode-wallpaper.bat
param(
    [switch]$NoRestart,   # toolbox mode: do not relaunch ZCode after patching
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

# ---- the renderer CSS this kit patches (ZCode 3.14.1) ----
$cssRelPath = 'out/renderer/assets/styles-C8Nayk5k.css'

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
            # p.Path = <install root>\ZCode.exe; resources lives next to the exe
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

function Remove-Integrity($node) {
    if ($node.PSObject.Properties['integrity']) { $node.PSObject.Properties.Remove('integrity') }
    if ($node.PSObject.Properties['files']) {
        foreach ($p in $node.files.PSObject.Properties) { Remove-Integrity $p.Value }
    }
}

# Rebuild the archive from $asar with one inline file replaced by $newBytes.
# Every other inline file is copied byte-identical in header key order; offsets
# after the replaced file shift by the size delta and are written back into the
# header BEFORE serialization.
function Write-Asar($asar, [string]$relPath, [byte[]]$newBytes, [string]$outPath) {
    Remove-Integrity $asar.header

    # Walk-Assign2 below rewrites offsets in place, so it must walk a CLONE of
    # the header: a second Write-Asar call on the same $asar (backup rebuild +
    # patch write) would otherwise treat already-shifted offsets as source
    # positions and corrupt every payload file after the replaced one.
    $header = ($asar.header | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json

    # pass 1: ordered walk, assign new offsets; remember every file's OLD offset
    # in $script:wp_map so pass 2 can locate the original bytes exactly.
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

    # pass 2: ordered walk again (same order), copy contents
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

# ---- wallpaper CSS block -----------------------------------------------------------
function ConvertTo-WallpaperCss([string]$photoPath, [int]$veilPct) {
    $fs = [System.IO.File]::OpenRead($photoPath)
    $img = $null
    try {
        $img = [System.Drawing.Image]::FromStream($fs)
        $maxEdge = 1920
        $scale = [Math]::Min(1.0, $maxEdge / [Math]::Max($img.Width, $img.Height))
        $w = [int]([Math]::Round($img.Width * $scale))
        $h = [int]([Math]::Round($img.Height * $scale))
        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.DrawImage($img, 0, 0, $w, $h)
        $g.Dispose()
        $jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
        $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]82)
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, $jpegCodec, $ep)
        $bmp.Dispose(); $ep.Dispose()
        $jpegBytes = $ms.ToArray()
        $ms.Dispose()
    } finally {
        if ($img) { $img.Dispose() }
        $fs.Dispose()
    }
    $b64 = [Convert]::ToBase64String($jpegBytes)
    $css = @"
$markerBegin
/* ZCode desktop wallpaper patch. Veil: 0 = pure photo, 100 = no photo.
   Re-run patch-zcode-wallpaper.bat to switch; restore-zcode-wallpaper.bat reverts. */
:root{--wp-veil:$veilPct%}
[data-desktop-window-frame].bg-background-win-alt{
background-image:url("data:image/jpeg;base64,$b64");
background-size:cover;
background-position:center;
background-repeat:no-repeat;
background-color:transparent;
}
[data-desktop-window-frame] .bg-background{
background-color:color-mix(in srgb,var(--color-background) var(--wp-veil),transparent);
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

# 0) ZCode must not be running (skipped for explicit -AsarPath overrides)
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
    # stripped css matches the backup css byte-for-byte (keeps backups stable)
    if ($idx -gt 0 -and $cleanCssText[$idx - 1] -eq [char]10) {
        $cleanCssText = $cleanCssText.Substring(0, $idx - 1) + $cleanCssText.Substring($idx)
    }
} else {
    throw 'app.asar contains a broken wallpaper block; run restore-zcode-wallpaper.bat first. Refusing.'
}
Write-Host "[1/4] state: $state"

# 2) backup must hold the clean (block-free) asar of this machine
$needBackupWrite = $true
if (Test-Path $backupPath) {
    $sidecarOk = $false
    if (Test-Path $hashPath) {
        $expect = (Get-Content $hashPath -ErrorAction SilentlyContinue)
        $actual = (Get-FileHash $backupPath -Algorithm SHA256).Hash
        $sidecarOk = ($expect -and ($actual -eq $expect.Trim()))
    }
    if ($sidecarOk) {
        $bk = Read-Asar $backupPath
        $bkCss = Get-CssEntryAndBytes $bk $cssRelPath
        if ($bkCss) {
            $bkText = [System.Text.Encoding]::UTF8.GetString($bkCss.bytes)
            if ((Count-Str $bkText $markerBegin) -eq 0 -and $bkText -eq $cleanCssText) {
                $needBackupWrite = $false
            }
        }
    }
}
if ($needBackupWrite) {
    if ($state -eq 'clean') {
        # current asar has no block: keep a BYTE-IDENTICAL copy so a later
        # restore returns the exact factory file (hash-equal)
        Copy-Item -Force $asarPath "$backupPath.tmp"
        Move-Item -Force "$backupPath.tmp" $backupPath
        Write-Host '[2/4] backup (re)created (byte-identical clean asar)'
    } else {
        # patched asar without a valid backup: strip the block via rebuild
        $cleanBytes = [System.Text.Encoding]::UTF8.GetBytes($cleanCssText)
        $tmpBak = "$backupPath.tmp"
        Write-Asar $asar $cssRelPath $cleanBytes $tmpBak
        Move-Item -Force $tmpBak $backupPath
        Write-Host '[2/4] backup (re)created from clean baseline'
    }
    [System.IO.File]::WriteAllText($hashPath, (Hash-Bytes ([System.IO.File]::ReadAllBytes($backupPath))))
} else {
    Write-Host '[2/4] clean backup verified'
}

# 3) choose photo + veil
$wpDir = Join-Path $PSScriptRoot 'wallpapers'
$choices = @()
if (Test-Path $wpDir) {
    $choices = @(Get-ChildItem -LiteralPath $wpDir -File | Where-Object { $_.Extension -match '^\.(jpg|jpeg|png|bmp)$' } | Sort-Object Name)
}
Write-Host ''
Write-Host '===== choose a wallpaper ====='
for ($i = 0; $i -lt $choices.Count; $i++) {
    Write-Host ("  [{0}] {1}" -f ($i + 1), $choices[$i].BaseName)
}
Write-Host '  [0] custom image (type a full path)'
$sel = Read-Host 'number'
$photoPath = $null
if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $choices.Count) {
    $photoPath = $choices[[int]$sel - 1].FullName
} elseif ($sel -eq '0') {
    $photoPath = Read-Host 'full path of the image file'
    if (-not (Test-Path -LiteralPath $photoPath)) {
        Write-Host "[X] file not found: $photoPath" -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
} else {
    Write-Host "[X] invalid selection: $sel" -ForegroundColor Red
    Read-Host 'Press Enter to exit'
    exit 1
}

$veilInput = Read-Host 'veil opacity 0-85, higher = fainter photo [default 60]'
$veilPct = 60
if ($veilInput -match '^\d+$') { $veilPct = [Math]::Max(0, [Math]::Min(85, [int]$veilInput)) }

Write-Host "[3/4] photo: $(Split-Path $photoPath -Leaf), veil $veilPct%"
$blockBytes = ConvertTo-WallpaperCss $photoPath $veilPct

# assemble the css payload from the CURRENT css: strip the old block if present
# (state 'patched'), then append the new block after a single newline
# assemble the css payload from the CURRENT css (stripped of any old block):
# $cleanCssText was computed in step 1 exactly for this purpose
$cleanBytes = [System.Text.Encoding]::UTF8.GetBytes($cleanCssText)
$patchedCssBytes = New-Object byte[] ($cleanBytes.Length + 1 + $blockBytes.Length)
[Array]::Copy($cleanBytes, 0, $patchedCssBytes, 0, $cleanBytes.Length)
$patchedCssBytes[$cleanBytes.Length] = 0x0A
[Array]::Copy($blockBytes, 0, $patchedCssBytes, $cleanBytes.Length + 1, $blockBytes.Length)

# 4) rebuild the asar from the CURRENT asar with the new css block swapped in.
#    Building from the CURRENT file (not the backup) keeps any other patches
#    (font stacks / update-disable) that were applied after the backup; the
#    backup is only kept as a factory-restore fallback for restore-zcode-wallpaper.
#    Note: the font/update patches live in a different file (out/main/index.js)
#    and other css assets; the block-swap below touches only the wallpaper css.
$tmpPath = "$asarPath.tmp"
Write-Asar $asar $cssRelPath $patchedCssBytes $tmpPath

# self-check: tmp parses, css holds exactly one block, old file intact until swap
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
# and verify untouched sentinel files byte-for-byte. Catches any rebuild bug
# (e.g. a shifted-offset double rebuild) that marker-based self-checks miss;
# package.json is the Electron entry point and the last file in the payload.
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
Write-Host "Wallpaper applied: $(Split-Path $photoPath -Leaf), veil $veilPct%. Re-run to switch; restore-zcode-wallpaper.bat reverts."
