# ZCode app icon patch (v1, portable) - save as UTF-8 WITHOUT BOM
# - Replaces the icons ZCode shows on this machine without touching ZCode.exe:
#     * resources\tray_icon.ico     -> tray icon (multi-size rebuilt)
#     * resources\icon_windows.png  -> window / taskbar icon (BrowserWindow icon)
#     * resources\icon.png          -> About window icon + drag helper (resolveZCodeIcon)
#     * ZCode shortcuts (.lnk)      -> Start Menu / Desktop / taskbar-pinned icon
# - Source: an .ico or .png/.jpg (ico recommendations: 256x256 PNG frame, or a
#   multi-size ico). The multi-size ico written to resources is rebuilt from the
#   largest available frame: 16/20/24/32/40/48 as 32-bpp DIB frames (crisp at
#   small sizes, no downscale fuzz from a single 256 frame) and 64/128/256 as
#   PNG frames (Vista+ shell support).
# - Factory baseline: icon\app-icon-original.ico is generated once from
#   resources\icon.png (the untouched factory app icon), so restore can always
#   rebuild the original look even after this patch ran several times.
# - Restore point: app-icon-backup\ holds the tray_icon.ico / icon_windows.png
#   found on disk at the first run, plus zcode-icon-state.json with every
#   shortcut's original IconLocation. Restore only reverts a shortcut when its
#   current IconLocation is still the one this patch wrote.
# - ZCode.exe itself is never modified (its explorer icon and code signature
#   stay intact); only the shell shortcuts point at the new .ico.
# - Exits automatically on success; pauses only on errors
# Revert with restore-zcode-icon.bat
param(
    [switch]$NoRestart,      # toolbox mode: do not relaunch ZCode after patching
    [string]$IconPath,       # source icon (.ico/.png/.jpg); default icon\app-icon.ico
    [string]$TargetDir,      # advanced/testing: operate on a COPY of the resources dir (shortcuts skipped unless -WithShortcuts)
    [switch]$NoShortcuts,    # do not touch .lnk files
    [switch]$WithShortcuts,  # with -TargetDir: still update shortcuts (default off in test mode)
    [switch]$RestartExplorer, # restart explorer.exe so the shell drops its icon cache (closes open File Explorer windows)
    [ValidateSet('auto', 'color', 'mono')]
    [string]$SidebarStyle = 'auto'  # sidebar logo: auto (dark icon -> light silhouette) | color | mono
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue } catch {}
Add-Type -AssemblyName System.Drawing

$backupDir  = Join-Path $PSScriptRoot 'app-icon-backup'
$statePath  = Join-Path $PSScriptRoot 'zcode-icon-state.json'
$iconDir  = Join-Path $PSScriptRoot 'icon'
$factoryIco = Join-Path $iconDir 'app-icon-original.ico'

# ---- icon encoding helpers ---------------------------------------------------------
function Resize-Bitmap([System.Drawing.Bitmap]$src, [int]$w, [int]$h) {
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.CompositingMode   = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.DrawImage($src, (New-Object System.Drawing.Rectangle(0, 0, $w, $h)))
    } finally { $g.Dispose() }
    return $bmp
}

# 32-bpp bottom-up DIB frame + all-zero AND mask (alpha carries the shape)
function ConvertTo-DibFrame([System.Drawing.Bitmap]$bmp) {
    $w = $bmp.Width
    $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $stride = $data.Stride
        $buf = New-Object byte[] ($stride * $h)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $buf.Length)
    } finally { $bmp.UnlockBits($data) }

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    try {
        $bw.Write([uint32]40)          # biSize
        $bw.Write([int32]$w)           # biWidth
        $bw.Write([int32]($h * 2))     # biHeight (XOR + AND)
        $bw.Write([uint16]1)           # biPlanes
        $bw.Write([uint16]32)          # biBitCount
        $bw.Write([uint32]0)           # biCompression = BI_RGB
        $bw.Write([uint32]($w * $h * 4))
        $bw.Write([int32]0); $bw.Write([int32]0)
        $bw.Write([uint32]0); $bw.Write([uint32]0)
        for ($y = $h - 1; $y -ge 0; $y--) { $bw.Write($buf, $y * $stride, $w * 4) }
        $maskRow = [int]([Math]::Ceiling($w / 32.0) * 4)
        $bw.Write((New-Object byte[] ($maskRow * $h)))
        $bw.Flush()
        return $ms.ToArray()
    } finally { $bw.Dispose(); $ms.Dispose() }
}

function ConvertTo-PngFrame([System.Drawing.Bitmap]$bmp) {
    $ms = New-Object System.IO.MemoryStream
    try {
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        return $ms.ToArray()
    } finally { $ms.Dispose() }
}

# build a complete .ico byte stream from one source bitmap
function New-IcoBytes([System.Drawing.Bitmap]$src) {
    $sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
    $frames = New-Object System.Collections.ArrayList
    foreach ($s in $sizes) {
        if ($s -gt $src.Width) { continue }
        $b = Resize-Bitmap $src $s $s
        try {
            if ($s -le 128) { $data = ConvertTo-DibFrame $b } else { $data = ConvertTo-PngFrame $b }
        } finally { $b.Dispose() }
        [void]$frames.Add(@{ size = $s; data = $data })
    }
    if ($frames.Count -eq 0) { throw 'source icon too small (need at least 16x16).' }

    $count = $frames.Count
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    try {
        $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$count)
        $offset = 6 + 16 * $count
        foreach ($f in $frames) {
            $dim = if ($f.size -ge 256) { 0 } else { $f.size }
            $bw.Write([byte]$dim); $bw.Write([byte]$dim)
            $bw.Write([byte]0); $bw.Write([byte]0)
            $bw.Write([uint16]1); $bw.Write([uint16]32)
            $bw.Write([uint32]$f.data.Length); $bw.Write([uint32]$offset)
            $offset += $f.data.Length
        }
        foreach ($f in $frames) { $bw.Write([byte[]]$f.data) }
        $bw.Flush()
        return $ms.ToArray()
    } finally { $bw.Dispose(); $ms.Dispose() }
}

# load any supported source (ico / png / jpg) as a 32-bpp ARGB bitmap
function Load-SourceBitmap([string]$path) {
    $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    if ($ext -ne '.ico') {
        $img = [System.Drawing.Image]::FromFile($path)
        try { return (New-Object System.Drawing.Bitmap($img)) } finally { $img.Dispose() }
    }
    # ico: GDI+ defaults to 32x32 for multi-frame files and cannot decode
    # PNG-compressed frames at all, so parse the header, ask for the LARGEST
    # frame, and fall back to the embedded PNG when GDI+ refuses.
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $count = [BitConverter]::ToUInt16($bytes, 4)
    $bestW = 0; $bestH = 0; $best = $null
    for ($i = 0; $i -lt $count; $i++) {
        $o = 6 + 16 * $i
        $w = [int]$bytes[$o]; if ($w -eq 0) { $w = 256 }
        $h = [int]$bytes[$o + 1]; if ($h -eq 0) { $h = 256 }
        if ($w * $h -gt $bestW * $bestH) { $bestW = $w; $bestH = $h }
        $len = [int][BitConverter]::ToUInt32($bytes, $o + 8)
        $off = [int][BitConverter]::ToUInt32($bytes, $o + 12)
        if ($off + $len -gt $bytes.Length) { continue }
        $magic = ($bytes[$off] -eq 0x89 -and $bytes[$off + 1] -eq 0x50 -and $bytes[$off + 2] -eq 0x4E -and $bytes[$off + 3] -eq 0x47)
        if ($magic -and ($null -eq $best -or $len -gt $best.len)) { $best = @{ off = $off; len = $len; w = $w; h = $h } }
    }
    # the largest frame is often the PNG one; GDI+ silently returns a smaller
    # DIB frame in that case, so decode the PNG directly when it is the biggest
    if ($best -and $best.w -eq $bestW -and $best.h -eq $bestH) {
        $ms0 = New-Object System.IO.MemoryStream(,$bytes[$best.off..($best.off + $best.len - 1)])
        $img0 = [System.Drawing.Image]::FromStream($ms0)
        try { return (New-Object System.Drawing.Bitmap($img0)) } finally { $img0.Dispose(); $ms0.Dispose() }
    }
    if ($bestW -gt 0) {
        try {
            $ico = New-Object System.Drawing.Icon($path, $bestW, $bestH)
            try {
                $bmp = $ico.ToBitmap()
                $copy = New-Object System.Drawing.Bitmap($bmp)
                $bmp.Dispose()
                return $copy
            } finally { $ico.Dispose() }
        } catch {}
    }
    if (-not $best) {
        throw 'this .ico has no readable frame. Convert it to PNG and pass the .png instead.'
    }
    $ms = New-Object System.IO.MemoryStream(,$bytes[$best.off..($best.off + $best.len - 1)])
    $img = [System.Drawing.Image]::FromStream($ms)
    try { return (New-Object System.Drawing.Bitmap($img)) } finally { $img.Dispose(); $ms.Dispose() }
}

# ---- target discovery --------------------------------------------------------------
function Find-ZCodeDir {
    # returns the resources dir (the folder containing app.asar)
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

function Get-ZCodeShortcuts([string]$exePath) {
    $roots = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:USERPROFILE 'Desktop'),
        'C:\Users\Public\Desktop',
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
    )
    $found = New-Object System.Collections.ArrayList
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        try {
            foreach ($f in (Get-ChildItem -LiteralPath $r -Filter *.lnk -Recurse -File -ErrorAction SilentlyContinue)) {
                [void]$found.Add($f.FullName)
            }
        } catch {}
    }
    return $found
}

function Invoke-ShellIconRefresh {
    # ask Explorer to drop cached .lnk icons (Win10/11); harmless if unavailable
    foreach ($cmd in @(@('ie4uinit.exe', '-show'), @('ie4uinit.exe', '-ClearIconCache'))) {
        try { Start-Process -FilePath $cmd[0] -ArgumentList $cmd[1] -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue } catch {}
    }
}

# ---- asar primitives (self-contained; same code as the CSS-block patches) ----------
function Count-Str([string]$hay, [string]$s) {
    return ([regex]::Matches($hay, [regex]::Escape($s))).Count
}
function Read-Asar([string]$path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $hdrTotal = [BitConverter]::ToUInt32($bytes, 4)
    $jsonLen  = [BitConverter]::ToUInt32($bytes, 12)
    $json     = [System.Text.Encoding]::UTF8.GetString($bytes, 16, [int]$jsonLen)
    return @{
        bytes       = $bytes
        header      = ($json | ConvertFrom-Json)
        contentBase = 8 + [int]$hdrTotal
    }
}
function Resolve-RendererCss($asar) {
    $assets = $asar.header.files.out.files.renderer.files.assets
    $hits = @()
    foreach ($p in $assets.files.PSObject.Properties) {
        if ($p.Name -like 'styles-*.css' -and -not $p.Value.unpacked -and -not $p.Value.link) { $hits += $p.Name }
    }
    if ($hits.Count -eq 1) { return "out/renderer/assets/$($hits[0])" }
    throw "cannot identify the renderer stylesheet in this ZCode build (styles-*.css hits: $($hits.Count)). Version changed? Refusing."
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
            [void]$blocks.Add((Get-Sha256 $chunk).ToLowerInvariant())
        }
        return @{
            algorithm = 'SHA256'
            hash      = (Get-Sha256 $bytes).ToLowerInvariant()
            blockSize = $blockSize
            blocks    = $blocks.ToArray()
        }
    } finally { $sha.Dispose() }
}
function Write-Asar($asar, [string]$relPath, [byte[]]$newBytes, [string]$outPath) {
    $header = ($asar.header | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json
    $script:ai_rel = $relPath
    $script:ai_new = $newBytes
    $script:ai_cursor = 0L
    $script:ai_map = @{}
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
        $script:ai_map[$path] = [long]$node.offset
        $size = [long]$node.size
        $newSize = $size
        if ($path -eq $script:ai_rel) {
            $newSize = [long]$script:ai_new.Length
            $node.size = $newSize
            if ($node.PSObject.Properties['integrity'] -and $null -ne $node.integrity) {
                $node.integrity = New-AsarIntegrity $script:ai_new
            }
        }
        $node.offset = [string]$script:ai_cursor
        $script:ai_cursor += $newSize
    }
    Walk-Assign2 $header ''

    $json      = $header | ConvertTo-Json -Depth 100 -Compress
    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $padLen       = (4 - ($jsonBytes.Length % 4)) % 4
    $headerBufLen = 8 + $jsonBytes.Length + $padLen
    $payloadSize  = 4 + $jsonBytes.Length + $padLen

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
        if ($path -eq $script:ai_rel) {
            $bw.Write($script:ai_new)
        } elseif ($size -gt 0) {
            $srcOff = $asar.contentBase + [long]$script:ai_map[$path]
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
if ($TargetDir) {
    $resourcesDir = $TargetDir
    $zcodeExe = $null
    Write-Host "target (override): $resourcesDir"
} else {
    $resourcesDir = Find-ZCodeDir
    if (-not $resourcesDir) {
        Write-Host '[?] Could not auto-locate ZCode. Example: D:\installer\zcode\resources' -ForegroundColor Yellow
        $manual = Read-Host 'Enter the resources folder (the one containing app.asar)'
        if (-not $manual -or -not (Test-Path (Join-Path $manual 'app.asar'))) {
            Write-Host "[X] app.asar not found under: $manual" -ForegroundColor Red
            Read-Host 'Press Enter to exit'
            exit 1
        }
        $resourcesDir = $manual
    }
    $zcodeExe = Join-Path (Split-Path $resourcesDir -Parent) 'ZCode.exe'
    if (-not (Test-Path $zcodeExe)) { $zcodeExe = $null }
    Write-Host "target: $resourcesDir"
}

# 0) ZCode must not be running (icon files are rewritten in place)
if (-not $TargetDir) {
    if (Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue) {
        Write-Host '[X] ZCode is running.' -ForegroundColor Red
        Write-Host '    Quit ZCode first (right-click tray icon -> Quit; clicking X may only minimize to tray).' -ForegroundColor Yellow
        Read-Host 'Press Enter to exit'
        exit 1
    }
}

# 1) source icon: interactive picker over icon\ (PNG preferred, .ico as fallback),
#    or pass -IconPath to skip the menu entirely
if (-not $IconPath) {
    $choices = New-Object System.Collections.ArrayList
    $pngNames = @{}
    if (Test-Path -LiteralPath $iconDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $iconDir -File | Where-Object { $_.Extension -ieq '.png' })) {
            $pngNames[$f.BaseName] = $true
        }
    }
    $preferred = Join-Path $iconDir 'app-icon.png'
    if (Test-Path -LiteralPath $preferred) { [void]$choices.Add((Get-Item -LiteralPath $preferred)) }
    if (Test-Path -LiteralPath $iconDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $iconDir -File | Sort-Object Name)) {
            if ($f.Name -eq 'app-icon.png' -or $f.Name -eq 'app-icon-original.ico') { continue }
            if ($f.Extension -ieq '.png') { [void]$choices.Add($f); continue }
            # an .ico is only listed when it has no same-named .png companion
            if ($f.Extension -ieq '.ico' -and -not $pngNames.ContainsKey($f.BaseName)) { [void]$choices.Add($f) }
        }
    }
    if ($choices.Count -gt 0) {
        Write-Host ''
        Write-Host '===== choose an app icon ====='
        for ($i = 0; $i -lt $choices.Count; $i++) {
            $label = $choices[$i].BaseName
            if ($label -eq 'app-icon') { $label = 'app-icon (blue whale, default)' }
            elseif ($label -eq 'app-icon-alt-black') { $label = 'app-icon-alt-black (black whale)' }
            Write-Host ("  [{0}] {1}  ({2})" -f ($i + 1), $label, $choices[$i].Extension.TrimStart('.').ToUpperInvariant())
        }
        Write-Host '  [0] custom path'
        $sel = Read-Host 'number [default 1]'
        if ($sel -eq '0') {
            $IconPath = Read-Host 'full path of the .ico / .png to install'
        } elseif ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $choices.Count) {
            $IconPath = $choices[[int]$sel - 1].FullName
        } elseif (-not $sel) {
            $IconPath = $choices[0].FullName
        } else {
            Write-Host "[X] invalid selection: $sel" -ForegroundColor Red
            Read-Host 'Press Enter to exit'
            exit 1
        }
    } else {
        $IconPath = Read-Host 'full path of the .ico / .png to install'
    }
}
if (-not (Test-Path -LiteralPath $IconPath)) {
    Write-Host "[?] source icon not found: $IconPath" -ForegroundColor Yellow
    $IconPath = Read-Host 'full path of the .ico / .png to install'
    if (-not (Test-Path -LiteralPath $IconPath)) {
        Write-Host "[X] file not found: $IconPath" -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
}
$srcBmp = Load-SourceBitmap (Resolve-Path -LiteralPath $IconPath).Path
Write-Host "[1/5] source: $(Split-Path $IconPath -Leaf) ($($srcBmp.Width)x$($srcBmp.Height))"

# 2) factory baseline + backup of what is on disk right now
if (-not (Test-Path -LiteralPath $iconDir)) { New-Item -ItemType Directory -Path $iconDir | Out-Null }
if (-not (Test-Path -LiteralPath $factoryIco)) {
    $factoryPng = Join-Path $resourcesDir 'icon.png'
    if (Test-Path -LiteralPath $factoryPng) {
        $fb = Load-SourceBitmap $factoryPng
        try { [System.IO.File]::WriteAllBytes($factoryIco, (New-IcoBytes $fb)) } finally { $fb.Dispose() }
        Write-Host '[2/5] factory baseline generated: icon\app-icon-original.ico'
    } else {
        Write-Host '[2/5] factory baseline skipped (resources\icon.png not found)'
    }
} else {
    Write-Host '[2/5] factory baseline present: icon\app-icon-original.ico'
}

if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }

function Get-Sha256([byte[]]$b) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($b) | ForEach-Object { $_.ToString('X2') }) -join '') } finally { $sha.Dispose() }
}
# Back up an icon file only when it is NOT the icon source itself.
# If resources\tray_icon.ico already IS the custom .ico (e.g. it was swapped by
# hand before this tool existed), backing it up would make "restore" write the
# custom icon back; in that case restore rebuilds the factory look from
# icon\app-icon-original.ico instead.
$sourceSha = Get-Sha256 ([System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $IconPath).Path))
function Save-IconBackup([string]$name) {
    $src = Join-Path $resourcesDir $name
    $dst = Join-Path $backupDir $name
    if (-not (Test-Path -LiteralPath $src)) { return }
    if (Test-Path -LiteralPath $dst) { return }
    if ((Get-Sha256 ([System.IO.File]::ReadAllBytes($src))) -eq $sourceSha) {
        Write-Host "    no backup needed: $name is already the custom icon"
        return
    }
    Copy-Item -LiteralPath $src -Destination $dst -Force
    Write-Host "    backup: $name"
}

# 3) write the three icon files (tray ico + two PNGs), temp + move so a failed write leaves no half file
$icoBytes = New-IcoBytes $srcBmp
$trayPath = Join-Path $resourcesDir 'tray_icon.ico'
Save-IconBackup 'tray_icon.ico'
[System.IO.File]::WriteAllBytes("$trayPath.tmp", $icoBytes)
Move-Item -Force "$trayPath.tmp" $trayPath
Write-Host "[3/6] tray_icon.ico written ($([Math]::Round($icoBytes.Length / 1KB, 1)) KB, multi-size)"

# Shortcuts get a CONTENT-HASHED copy instead of tray_icon.ico: Explorer keys its
# icon cache on the path, so re-painting the same file name (blue -> black) keeps
# showing the old bitmap until the cache is rebuilt. A new path per content hash
# always resolves to the new image.
$hash8 = (Get-Sha256 $icoBytes).Substring(0, 8).ToLowerInvariant()
$shortcutIcon = Join-Path $resourcesDir "zcode-icon-$hash8.ico"
[System.IO.File]::WriteAllBytes("$shortcutIcon.tmp", $icoBytes)
Move-Item -Force "$shortcutIcon.tmp" $shortcutIcon
Get-ChildItem -LiteralPath $resourcesDir -Filter 'zcode-icon-*.ico' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne "zcode-icon-$hash8.ico" } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
Write-Host "[3/6] shortcut icon: zcode-icon-$hash8.ico"

$winSize = [Math]::Min(512, $srcBmp.Width)
$winBmp = Resize-Bitmap $srcBmp $winSize $winSize
$winPath = Join-Path $resourcesDir 'icon_windows.png'
$winMs = New-Object System.IO.MemoryStream
try { $winBmp.Save($winMs, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $winBmp.Dispose() }
$winBytes = $winMs.ToArray()
$winMs.Dispose()
Save-IconBackup 'icon_windows.png'
[System.IO.File]::WriteAllBytes("$winPath.tmp", $winBytes)
Move-Item -Force "$winPath.tmp" $winPath
Write-Host "[4/6] icon_windows.png written (${winSize}x${winSize})"

# resources\icon.png is a third Windows consumer: the About window
# (resolveAboutIconPath) and the drag helper (resolveZCodeIcon -> 64px data URL).
$appPngPath = Join-Path $resourcesDir 'icon.png'
Save-IconBackup 'icon.png'
[System.IO.File]::WriteAllBytes("$appPngPath.tmp", $winBytes)
Move-Item -Force "$appPngPath.tmp" $appPngPath
Write-Host "[4/6] icon.png written (${winSize}x${winSize})"

# ---- 4b) sidebar logo (renderer) ------------------------------------------------
# The top-left "Z" in the sidebar is an inline <svg viewBox="0 0 256 218"> drawn
# by the renderer bundle, not a resources file. A CSS block with its own markers
# (ZCODE-APPICON-*) hides its paths and paints the chosen icon as the svg box's
# background, so no JavaScript bundle is touched.
$markerBegin = '/* ZCODE-APPICON-PATCH-BEGIN */'
$markerEnd   = '/* ZCODE-APPICON-PATCH-END */'
$asarPath = Join-Path $resourcesDir 'app.asar'
$logoApplied = $false
if (Test-Path -LiteralPath $asarPath) {
    $asar = Read-Asar $asarPath
    $cssRel = Resolve-RendererCss $asar
    $cssHit = Get-CssEntryAndBytes $asar $cssRel
    if (-not $cssHit) { throw "renderer css not found in this ZCode build ($cssRel). Refusing." }
    $cssText = [System.Text.Encoding]::UTF8.GetString($cssHit.bytes)
    $cB = Count-Str $cssText $markerBegin
    $cE = Count-Str $cssText $markerEnd
    if ($cB -eq 0 -and $cE -eq 0) {
        $cleanText = $cssText
    } elseif ($cB -eq 1 -and $cE -eq 1 -and $cssText.IndexOf($markerBegin) -lt $cssText.IndexOf($markerEnd)) {
        $idx = $cssText.IndexOf($markerBegin)
        $endIdx = $cssText.IndexOf($markerEnd) + $markerEnd.Length
        $cleanText = ($cssText.Substring(0, $idx) + $cssText.Substring($endIdx))
        if ($idx -gt 0 -and $cleanText[$idx - 1] -eq [char]10) {
            $cleanText = $cleanText.Substring(0, $idx - 1) + $cleanText.Substring($idx)
        }
    } else {
        throw 'app.asar contains a broken app-icon block; run restore-zcode-icon.bat first. Refusing.'
    }
    $b64 = [Convert]::ToBase64String($winBytes)
    # average luminance of the opaque pixels: the sidebar sits on a dark brand
    # chip, so a dark icon is drawn as a light silhouette there (like the
    # original Z) while a bright icon keeps its colour.
    $lum = 0.5
    try {
        $sum = 0.0; $n = 0
        $stepX = [Math]::Max(1, [int]($srcBmp.Width / 64))
        $stepY = [Math]::Max(1, [int]($srcBmp.Height / 64))
        for ($yy = 0; $yy -lt $srcBmp.Height; $yy += $stepY) {
            for ($xx = 0; $xx -lt $srcBmp.Width; $xx += $stepX) {
                $c = $srcBmp.GetPixel($xx, $yy)
                if ($c.A -lt 32) { continue }
                $sum += (0.2126 * $c.R + 0.7152 * $c.G + 0.0722 * $c.B) / 255.0
                $n++
            }
        }
        if ($n -gt 0) { $lum = $sum / $n }
    } catch {}
    $useMono = ($SidebarStyle -eq 'mono') -or (($SidebarStyle -eq 'auto') -and ($lum -lt 0.45))
    if ($useMono) {
        $sidebarRule = @"
svg[viewBox="0 0 256 218"]{
background-color:currentColor!important;
background-image:none!important;
-webkit-mask-image:url("data:image/png;base64,$b64");
mask-image:url("data:image/png;base64,$b64");
-webkit-mask-repeat:no-repeat;mask-repeat:no-repeat;
-webkit-mask-position:center;mask-position:center;
-webkit-mask-size:contain;mask-size:contain;
filter:none!important;
}
"@
        $sidebarMode = 'mono (theme-coloured silhouette)'
    } else {
        $halo = if ($lum -lt 0.45) { '0 0 2px rgba(255,255,255,0.85)' } else { 'none' }
        $sidebarRule = @"
svg[viewBox="0 0 256 218"]{
background-image:url("data:image/png;base64,$b64")!important;
background-repeat:no-repeat;background-position:center;background-size:contain!important;
filter:drop-shadow($halo)!important;
}
"@
        $sidebarMode = 'colour'
    }
    $block = @"
$markerBegin
/* Sidebar corner logo: hide the bundled Z paths and paint the chosen icon.
   auto: dark icon -> light silhouette; bright icon -> original colour. */
$sidebarRule
svg[viewBox="0 0 256 218"]>path{display:none!important}
$markerEnd
"@
    $cleanBytes = [System.Text.Encoding]::UTF8.GetBytes($cleanText)
    $blockBytes = [System.Text.Encoding]::UTF8.GetBytes($block)
    $patchedCss = New-Object byte[] ($cleanBytes.Length + 1 + $blockBytes.Length)
    [Array]::Copy($cleanBytes, 0, $patchedCss, 0, $cleanBytes.Length)
    $patchedCss[$cleanBytes.Length] = 0x0A
    [Array]::Copy($blockBytes, 0, $patchedCss, $cleanBytes.Length + 1, $blockBytes.Length)

    $tmpPath = "$asarPath.tmp"
    Write-Asar $asar $cssRel $patchedCss $tmpPath
    $tmpAsar = Read-Asar $tmpPath
    $tmpHit = Get-CssEntryAndBytes $tmpAsar $cssRel
    $tmpText = if ($tmpHit) { [System.Text.Encoding]::UTF8.GetString($tmpHit.bytes) } else { '' }
    if (-not $tmpHit -or (Count-Str $tmpText $markerBegin) -ne 1 -or (Count-Str $tmpText $markerEnd) -ne 1) {
        Remove-Item $tmpPath -ErrorAction SilentlyContinue
        throw 'rebuilt asar failed self-check (app-icon block); original untouched.'
    }
    Move-Item -Force $tmpPath $asarPath
    $logoApplied = $true
    Write-Host ("[5/6] sidebar logo patched (app.asar css block, " + $sidebarMode + ")")
} else {
    Write-Host '[5/6] sidebar logo skipped (no app.asar in the target dir)'
}

# 5) shortcuts: point IconLocation at the new .ico (ZCode.exe itself untouched)
$shortcutRecords = New-Object System.Collections.ArrayList
$doShortcuts = (-not $NoShortcuts) -and ((-not $TargetDir) -or $WithShortcuts)
if ($doShortcuts -and $zcodeExe -eq $null -and -not $TargetDir) { $zcodeExe = $null }
if ($doShortcuts) {
    $exeForMatch = $zcodeExe
    if (-not $exeForMatch) {
        # test mode: infer from the target dir's parent
        $cand = Join-Path (Split-Path $resourcesDir -Parent) 'ZCode.exe'
        if (Test-Path -LiteralPath $cand) { $exeForMatch = $cand }
    }
    if ($exeForMatch) {
        $wsh = New-Object -ComObject WScript.Shell
        $newIcon = "$shortcutIcon,0"
        # keep the FIRST recorded original across re-runs (otherwise a second
        # colour switch would record our own path as the "original")
        $priorOriginals = @{}
        if (Test-Path -LiteralPath $statePath) {
            try {
                $prior = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($rec in @($prior.shortcuts)) {
                    if ($rec -and $rec.path -and $rec.original) { $priorOriginals[$rec.path] = $rec.original }
                }
            } catch {}
        }
        foreach ($lnkPath in (Get-ZCodeShortcuts $exeForMatch)) {
            try {
                $lnk = $wsh.CreateShortcut($lnkPath)
                $target = $lnk.TargetPath
                if (-not $target -or ($target -ine $exeForMatch)) { continue }
                if ($lnk.IconLocation -ieq $newIcon) {
                    # identical icon path (same colour re-run): just bump the
                    # .lnk write time so the shell re-reads it
                    $lnk.Save()
                    if ($priorOriginals.ContainsKey($lnkPath)) {
                        [void]$shortcutRecords.Add(@{ path = $lnkPath; original = $priorOriginals[$lnkPath]; applied = $newIcon })
                    }
                    Write-Host "      shortcut refreshed (cache bust): $lnkPath"
                    continue
                }
                $orig = if ($priorOriginals.ContainsKey($lnkPath)) { $priorOriginals[$lnkPath] } else { $lnk.IconLocation }
                $lnk.IconLocation = $newIcon
                $lnk.Save()
                [void]$shortcutRecords.Add(@{ path = $lnkPath; original = $orig; applied = $newIcon })
                Write-Host "      shortcut updated: $lnkPath"
            } catch {
                Write-Host "      [warn] shortcut not updated (permission?): $lnkPath" -ForegroundColor Yellow
            }
        }
    }
} else {
    Write-Host '[6/6] shortcuts skipped'
}

# 5) state + shell refresh
$state = [ordered]@{
    version     = 1
    installedAt = (Get-Date).ToString('s')
    sourceIcon  = (Resolve-Path -LiteralPath $IconPath).Path
    resources   = $resourcesDir
    trayIcon    = $trayPath
    windowIcon  = $winPath
    shortcuts   = @($shortcutRecords)
}
($state | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $statePath -Encoding UTF8
if ($doShortcuts) { Invoke-ShellIconRefresh }
if ($RestartExplorer) {
    Write-Host 'restarting explorer.exe to clear the shell icon cache...'
    try { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 } catch {}
    try { Start-Process explorer.exe } catch {}
}
Write-Host "[6/6] state saved: $(Split-Path $statePath -Leaf)"
$srcBmp.Dispose()

if ($NoRestart) {
    Write-Host 'done (NoRestart: leave ZCode closed).'
} elseif ($zcodeExe -and (Test-Path -LiteralPath $zcodeExe)) {
    Start-Process $zcodeExe
    Write-Host 'ZCode restarted.'
} else {
    Write-Host 'done. Start ZCode manually.'
}
Write-Host "Icon applied: $(Split-Path $IconPath -Leaf). Re-run to switch; restore-zcode-icon.bat reverts."
