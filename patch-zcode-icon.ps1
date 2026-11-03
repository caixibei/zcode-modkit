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
    [switch]$WithShortcuts   # with -TargetDir: still update shortcuts (default off in test mode)
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

# 1) source icon: prefer the PNG (largest, no frame loss), fall back to the .ico
if (-not $IconPath) {
    $pngCandidate = Join-Path $iconDir 'app-icon.png'
    if (Test-Path -LiteralPath $pngCandidate) {
        $IconPath = $pngCandidate
    } else {
        $IconPath = Join-Path $iconDir 'app-icon.ico'
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
Write-Host "[3/5] tray_icon.ico written ($([Math]::Round($icoBytes.Length / 1KB, 1)) KB, multi-size)"

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
Write-Host "[4/5] icon_windows.png written (${winSize}x${winSize})"

# resources\icon.png is a third Windows consumer: the About window
# (resolveAboutIconPath) and the drag helper (resolveZCodeIcon -> 64px data URL).
$appPngPath = Join-Path $resourcesDir 'icon.png'
Save-IconBackup 'icon.png'
[System.IO.File]::WriteAllBytes("$appPngPath.tmp", $winBytes)
Move-Item -Force "$appPngPath.tmp" $appPngPath
Write-Host "[4/5] icon.png written (${winSize}x${winSize})"

# 4) shortcuts: point IconLocation at the new .ico (ZCode.exe itself untouched)
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
        $newIcon = "$trayPath,0"
        foreach ($lnkPath in (Get-ZCodeShortcuts $exeForMatch)) {
            try {
                $lnk = $wsh.CreateShortcut($lnkPath)
                $target = $lnk.TargetPath
                if (-not $target -or ($target -ine $exeForMatch)) { continue }
                if ($lnk.IconLocation -ieq $newIcon) { continue }
                $orig = $lnk.IconLocation
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
    Write-Host '[5/5] shortcuts skipped'
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
Write-Host "[5/5] state saved: $(Split-Path $statePath -Leaf)"
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
