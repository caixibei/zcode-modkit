# ZCode gear-wallpaper patch (v2, portable) - save as UTF-8 WITH BOM
# - Dynamically switches the desktop background photo by the CURRENT THOUGHT
#   LEVEL shown in the composer toolbar ("低/中/高/极高/最高" and similar):
#     4 images (M1..M4): M1 = minimal/low, M2 = medium/on,
#                        M3 = high/xhigh, M4 = max/ultra
#     3 images (M1..M3): M1 = minimal/low, M2 = medium/high/on,
#                        M3 = xhigh/max/ultra
#   OFF ("关闭") gets NO image on purpose: no selector is generated for it, so
#   the window falls back to the stock background (or the static wallpaper
#   patch's photo when that patch is installed).
#   ZCode's renderer exposes the live level on a hidden node
#   ([data-thought="..."]); the appended CSS uses :has() so the switch is
#   instant, purely declarative, and survives every app update pattern that
#   keeps that attribute. No JavaScript is injected.
# - Images come from .\images\ and are named M<n> (n = 1.., consecutive):
#     M1.jpg / M1.jpeg / M1.png / M1.bmp / M1.gif -> gear 1 (lowest)
#     M2.* -> gear 2 ... every non-off level is covered by exactly one gear.
#   JPEG/PNG/BMP are scaled to a 1920 long edge and encoded as JPEG q82.
#   GIF is embedded as-is to keep its animation: System.Drawing reads only the
#   active frame and cannot write an animated GIF, so rescaling would drop
#   every frame after the first. Each GIF is capped at 2 MiB; an oversize GIF
#   falls back to its first frame encoded as JPEG.
#     To change a picture, just replace the file (any of the supported
#     extensions) and re-run this script.
# - app.asar is FULLY REBUILT (same technique as patch-zcode-wallpaper.ps1):
#   every original file stays byte-identical and in order; only the target CSS
#   gains an appended block and the header offsets are recomputed. Integrity
#   fields are dropped (not validated without the asar fuse).
# - Independent from the static wallpaper patch: its own CSS markers
#   (ZCODE-GWP-*) and its own backup file (app.asar.gwp-backup), so both
#   patches can coexist. This script never touches the wallpaper patch block.
# - Re-run at any time to pick new images or change the veil.
# - Exits automatically on success; pauses only on errors
# Revert with restore-zcode-wallpaper-gear.bat
param(
    [switch]$NoRestart,   # toolbox mode: do not relaunch ZCode after patching
    [string]$TargetAsar   # advanced/testing: operate on this app.asar instead of the auto-located one (skips the running check)
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
# Clear NODE_OPTIONS from this process so the ZCode.exe we (re)start never
# inherits unsupported flags (packaged Electron apps print a startup ERROR for
# e.g. --max-old-space-size); the machine/user registry value is NOT touched.
try { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue } catch {}
Add-Type -AssemblyName System.Drawing

$backupPath = Join-Path $PSScriptRoot 'app.asar.gwp-backup'
$hashPath   = Join-Path $PSScriptRoot 'app.asar.gwp-backup.sha256'

$markerBegin = '/* ZCODE-GWP-GEAR-WALLPAPER-BEGIN */'
$markerEnd   = '/* ZCODE-GWP-GEAR-WALLPAPER-END */'

# GIFs are embedded untouched (no rescale/re-encode), so each data URI lands in
# the renderer CSS at roughly 4/3 of the file size. The cap keeps four gears
# from adding tens of megabytes to a stylesheet the renderer parses at startup;
# 2 MiB of GIF becomes about 2.7 MiB of base64.
$script:maxGifBytes = 2MB

# ---- the renderer CSS this kit patches ----
# stylesheet name carries a build hash (3.14.1: styles-C8Nayk5k.css,
# 3.16.3: styles-9Z13W0KP.css), resolved from the asar header at runtime
# via Resolve-RendererCss
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

# ---- asar primitives (same as patch-zcode-wallpaper.ps1; self-contained by design) ----
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

function Write-Asar($asar, [string]$relPath, [byte[]]$newBytes, [string]$outPath) {
    # Walk-Assign2 below rewrites offsets in place, so it must walk a CLONE of
    # the header: a second Write-Asar call on the same $asar (backup rebuild +
    # patch write) would otherwise treat already-shifted offsets as source
    # positions and corrupt every payload file after the replaced one.
    $header = ($asar.header | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json
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
            if ($node.PSObject.Properties['integrity'] -and $null -ne $node.integrity) {
                $node.integrity = New-AsarIntegrity $script:gwp_new
            }
        }
        $node.offset = [string]$script:gwp_cursor
        $script:gwp_cursor += $newSize
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
    Walk-Write $header ''
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($outPath, $ms.ToArray())
    $bw.Dispose(); $ms.Dispose()
}

# ---- raster -> JPEG data URI: scale long edge to 1920, q82 ----
function ConvertTo-JpegDataUri([string]$photoPath) {
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
    return 'data:image/jpeg;base64,' + [Convert]::ToBase64String($jpegBytes)
}

# ---- gear image -> data URI ----
# A GIF within the cap keeps its animation by embedding the file bytes as-is:
# the CSS background-image decoder plays animated GIFs, while re-encoding here
# would flatten it to one frame. Anything else (and an oversize GIF) takes the
# JPEG path above.
function ConvertTo-GearDataUri([string]$photoPath) {
    $file = Get-Item -LiteralPath $photoPath
    if ($file.Extension -eq '.gif') {
        if ($file.Length -le $script:maxGifBytes) {
            $gifBytes = [System.IO.File]::ReadAllBytes($photoPath)
            Write-Host ("  gif kept animated: {0} ({1:N1} MB)" -f $file.Name, ($file.Length / 1MB))
            return 'data:image/gif;base64,' + [Convert]::ToBase64String($gifBytes)
        }
        Write-Host ("  [!] {0} is {1:N1} MB, over the {2:N0} MB gif cap; using its first frame as JPEG." -f $file.Name, ($file.Length / 1MB), ($script:maxGifBytes / 1MB)) -ForegroundColor Yellow
    }
    return ConvertTo-JpegDataUri $photoPath
}

# ---- gear wallpaper CSS block ------------------------------------------------------
# Gear -> data-thought value groups (low to high). data-thought carries the RAW
# option value from the model config; the renderer's label map (kU) accepts:
# off-family (disabled/false/no/none/nothink/no-think/no_think/off), the generic
# on-family (enable/enabled/on/true), and effort levels
# minimal/low/medium/high/xhigh/max/ultra (extra-high/extra_high normalize to
# xhigh only for LABELS, so the CSS matches the raw ids).
# OFF and off-family values are deliberately NOT mapped: when thinking is off
# no :has() rule matches and the window keeps its stock (or static-wallpaper)
# background. 'on'-family sits between off and the concrete effort levels, so
# it shows the medium gear.
$gearLevels4 = @(
    @('minimal', 'low'),
    @('medium', 'on', 'enable', 'enabled', 'true'),
    @('high', 'xhigh'),
    @('max', 'ultra')
)
$gearLevels3 = @(
    @('minimal', 'low'),
    @('medium', 'high', 'on', 'enable', 'enabled', 'true'),
    @('xhigh', 'max', 'ultra')
)

function ConvertTo-GearWallpaperCss([string[]]$dataUris, [int]$veilPct, [object[]]$levelGroups) {
    # $dataUris per gear (low -> high). There is NO base/fallback rule: the
    # stock .bg-background-win-alt styling (or the static wallpaper patch)
    # shows through whenever the current level has no gear image (off, or an
    # unknown future level id).
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($markerBegin)
    [void]$sb.AppendLine('/* ZCode gear wallpaper patch: background follows the composer thought level.')
    [void]$sb.AppendLine('   Re-run patch-zcode-wallpaper-gear.bat to switch images;')
    [void]$sb.AppendLine('   restore-zcode-wallpaper-gear.bat reverts. */')
    [void]$sb.AppendLine(":root{--gwp-veil:$veilPct%}")
    for ($i = 0; $i -lt $levelGroups.Count; $i++) {
        $levels = @($levelGroups[$i])
        # compound selector (no space): bg-background-win-alt sits on the SAME
        # element as data-desktop-window-frame, exactly like the static patch
        $selectors = foreach ($lv in $levels) { "[data-desktop-window-frame]:has([data-thought=`"$lv`"]).bg-background-win-alt" }
        [void]$sb.AppendLine(($selectors -join ",`n") + '{')
        [void]$sb.AppendLine("background-image:url(`"$($dataUris[$i])`");")
        [void]$sb.AppendLine('background-size:cover;')
        [void]$sb.AppendLine('background-position:center;')
        [void]$sb.AppendLine('background-repeat:no-repeat;')
        [void]$sb.AppendLine('background-color:transparent;')
        [void]$sb.AppendLine('}')
    }
    [void]$sb.AppendLine('[data-desktop-window-frame] .bg-background{')
    [void]$sb.AppendLine('background-color:color-mix(in srgb,var(--color-background) var(--gwp-veil),transparent);')
    [void]$sb.AppendLine('}')
    [void]$sb.Append($markerEnd)
    return [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
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
$asarPath  = Join-Path $resourcesDir 'app.asar'
$zcodeExe  = Join-Path (Split-Path $resourcesDir -Parent) 'ZCode.exe'
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
    if ($idx -gt 0 -and $cleanCssText[$idx - 1] -eq [char]10) {
        $cleanCssText = $cleanCssText.Substring(0, $idx - 1) + $cleanCssText.Substring($idx)
    }
} else {
    throw 'app.asar contains a broken gear-wallpaper block; run restore-zcode-wallpaper-gear.bat first. Refusing.'
}
Write-Host "[1/4] state: $state"

# 2) backup must hold the gwp-block-free asar of this machine (may still carry
#    the static wallpaper patch or other patches; we only strip our own block)
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
        Copy-Item -Force $asarPath "$backupPath.tmp"
        Move-Item -Force "$backupPath.tmp" $backupPath
        Write-Host '[2/4] backup (re)created (byte-identical current asar, gwp-free)'
    } else {
        $cleanBytes = [System.Text.Encoding]::UTF8.GetBytes($cleanCssText)
        $tmpBak = "$backupPath.tmp"
        Write-Asar $asar $cssRelPath $cleanBytes $tmpBak
        Move-Item -Force $tmpBak $backupPath
        Write-Host '[2/4] backup (re)created from gwp-stripped baseline'
    }
    [System.IO.File]::WriteAllText($hashPath, (Hash-Bytes ([System.IO.File]::ReadAllBytes($backupPath))))
} else {
    Write-Host '[2/4] clean backup verified'
}

# 3) discover gear images M1..Mn (consecutive from 1) in .\images\
$imgDir = Join-Path $PSScriptRoot 'images'
$gearFiles = @()
$n = 1
while ($true) {
    $hit = Get-ChildItem -LiteralPath $imgDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -eq "M$n" -and $_.Extension -match '^\.(jpg|jpeg|png|bmp|gif)$' } |
        Sort-Object Name | Select-Object -First 1
    if (-not $hit) { break }
    $gearFiles += $hit.FullName
    $n++
}
if ($gearFiles.Count -lt 3) {
    Write-Host "[X] found $($gearFiles.Count) gear image(s) in images\, need at least 3 (M1, M2, M3)." -ForegroundColor Red
    Write-Host '    Naming: M1 = lowest gear ... M<n> = higher gear (off needs no image).'
    Read-Host 'Press Enter to exit'
    exit 1
}
if ($gearFiles.Count -gt 4) {
    # more levels than ZCode exposes: cap at 4 groups (highest group wins)
    Write-Host "[!] found $($gearFiles.Count) gear images; ZCode has 4 level groups, using M1..M4." -ForegroundColor Yellow
    $gearFiles = $gearFiles[0..3]
}
$levelGroups = if ($gearFiles.Count -eq 3) { $gearLevels3 } else { $gearLevels4 }

# gear display names derive from the ACTIVE level groups, capped to the first
# two ids so the menu stays readable (aliases like on/enabled are implied)
$gearNames = @($levelGroups | ForEach-Object {
    $g = @($_)
    if ($g.Count -gt 2) { ($g[0..1] -join '/') } else { ($g -join '/') }
})
Write-Host ''
Write-Host '===== gear images ====='
for ($i = 0; $i -lt $gearFiles.Count; $i++) {
    Write-Host ("  gear {0} ({1}): {2}" -f ($i + 1), $gearNames[$i], (Split-Path $gearFiles[$i] -Leaf))
}

$veilInput = Read-Host 'veil opacity 0-85, higher = fainter photo [default 60]'
$veilPct = 60
if ($veilInput -match '^\d+$') { $veilPct = [Math]::Max(0, [Math]::Min(85, [int]$veilInput)) }

Write-Host '[3/4] encoding images (gif kept animated; others long edge 1920, jpeg q82)...'
$uris = foreach ($f in $gearFiles) { ConvertTo-GearDataUri $f }
$blockBytes = ConvertTo-GearWallpaperCss @($uris) $veilPct $levelGroups

# assemble the css payload from the CURRENT css stripped of our old block
$cleanBytes = [System.Text.Encoding]::UTF8.GetBytes($cleanCssText)
$patchedCssBytes = New-Object byte[] ($cleanBytes.Length + 1 + $blockBytes.Length)
[Array]::Copy($cleanBytes, 0, $patchedCssBytes, 0, $cleanBytes.Length)
$patchedCssBytes[$cleanBytes.Length] = 0x0A
[Array]::Copy($blockBytes, 0, $patchedCssBytes, $cleanBytes.Length + 1, $blockBytes.Length)

# 4) rebuild the asar from the CURRENT asar (keeps every other patch intact)
$tmpPath = "$asarPath.tmp"
Write-Asar $asar $cssRelPath $patchedCssBytes $tmpPath

# self-check: tmp parses, css holds exactly one gwp block in order
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
Write-Host 'Gear wallpaper applied. Switch the thought level in the composer to see the background change.'
Write-Host 'Re-run to change images/veil; restore-zcode-wallpaper-gear.bat reverts.'
