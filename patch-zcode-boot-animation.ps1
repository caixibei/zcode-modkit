# ZCode boot-animation patch (v1, portable) - save as UTF-8 WITHOUT BOM
# - Plays a full-window intro video once per ZCode window session (i.e. once per
#   app launch), then fades out. Click anywhere or press Esc to skip.
# - Where it lives: the whole feature is one block appended to
#   out/renderer/index.html inside app.asar, between the markers
#     <!-- ZCODE-BOOT-ANIMATION-BEGIN --> ... <!-- ZCODE-BOOT-ANIMATION-END -->
#   index.html is the Electron entry page for the main window (loadFile), has no
#   CSP meta, and is NOT content-hashed, so it survives version bumps as long as
#   the file still exists in the asar header.
# - Why a separate block instead of patching the renderer bundle: the bundle name
#   carries a build hash and its internals are minified; index.html is a stable,
#   human-readable anchor that only needs "</body>" to exist.
# - The update-status window (windowKind=update-status) loads the SAME index.html.
#   The injected script exits early there, so the small updater window never
#   shows the intro.
# - Video source: the first video in .\boot-animation\ (sorted by name; .mp4,
#   .webm or .mov), embedded as a data: URI inside index.html. Nothing is read
#   from disk at runtime, so the patch keeps working after the toolkit folder
#   moves or is deleted. To change the intro, drop another clip in that folder
#   (or pass -Clip <name>) and re-run this script.
# - Playback rules (mirrors dsh-boot-animation's decidePlay contract):
#     * one play per renderer session -> sessionStorage flag; an F5 reload in the
#       same window does NOT replay, closing the window does clear it
#     * starts only after the app's own boot settles (zcode-react-startup-ready
#       event, or body.zcode-startup-ready, with a 2.5 s safety net)
#     * muted autoplay first (Chromium always allows that), then a best-effort
#       unmute; if unmuting pauses the element it silently reverts to muted
#     * never blocks or breaks the app: 'ended', 'error' or a 25 s stall all end
#       in the same fade-out-and-remove path
# - app.asar is FULLY REBUILT (same technique as patch-zcode-wallpaper.ps1):
#   every other file stays byte-identical and in order; only index.html grows and
#   the header offsets are recomputed. Integrity fields of untouched files are
#   preserved, the replaced file's integrity is recomputed.
# - Independent from every other patch: own markers (ZCODE-BOOT-ANIMATION-*),
#   own backup (app.asar.boot-backup) and it only touches out/renderer/index.html.
# - Re-run at any time to pick a new clip or after a ZCode upgrade.
# - Exits automatically on success; pauses only on errors
# Revert with restore-zcode-boot-animation.bat
param(
    [switch]$NoRestart,   # toolbox mode: do not relaunch ZCode after patching
    [string]$TargetAsar,  # advanced/testing: operate on this app.asar instead of the auto-located one (skips the running check)
    [string]$Clip         # optional: file name (or stem) inside .\boot-animation\ to use
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

# the renderer entry page this kit patches (stable name, resolved from the asar
# header at runtime so a future layout change fails loudly instead of silently)
$htmlRelPath = 'out/renderer/index.html'

# 12 MiB of video becomes ~16 MiB of base64 inside a page the renderer parses on
# every window open; the cap keeps a stray 4K clip from bloating startup.
$script:maxClipBytes = 12MB

# ---- the markup block -------------------------------------------------------
# Pure ASCII on purpose (PowerShell 5.1 needs a BOM to read UTF-8 source), so the
# only non-ASCII characters are HTML entities / JS \u escapes.
# __ZBA_DATA_URI__ is replaced with the clip's data: URI after selection.
$script:blockTemplate = @'
<!-- ZCODE-BOOT-ANIMATION-BEGIN -->
<style>
#zcode-boot-animation{position:fixed;inset:0;z-index:2147483647;background:#000;display:flex;align-items:center;justify-content:center;opacity:1;transition:opacity .45s ease;cursor:pointer}
#zcode-boot-animation.zba-fade{opacity:0}
#zcode-boot-animation video{width:100%;height:100%;object-fit:cover;display:block;background:#000}
#zcode-boot-animation .zba-skip{position:absolute;right:28px;bottom:24px;padding:6px 14px;border-radius:999px;font:500 13px/1.4 system-ui,-apple-system,"Segoe UI",sans-serif;color:rgba(255,255,255,.86);background:rgba(0,0,0,.38);border:1px solid rgba(255,255,255,.22);pointer-events:none;user-select:none}
</style>
<div id="zcode-boot-animation" role="presentation">
<video id="zba-video" muted autoplay playsinline preload="auto" disablepictureinpicture src="__ZBA_DATA_URI__"></video>
<div class="zba-skip">Skip &#9656;</div>
</div>
<script>
(function () {
  var el = document.getElementById('zcode-boot-animation');
  var v = document.getElementById('zba-video');
  if (!el || !v) return;
  try {
    // the updater window loads this same page; it must never show the intro
    if (new URLSearchParams(window.location.search).get('windowKind') === 'update-status') { el.remove(); return; }
  } catch (e) {}
  var KEY = 'zcode-boot-animation:played';
  try { if (sessionStorage.getItem(KEY) === '1') { el.remove(); return; } } catch (e) {}
  var finished = false;
  function done() {
    if (finished) return;
    finished = true;
    try { sessionStorage.setItem(KEY, '1'); } catch (e) {}
    try { v.pause(); v.removeAttribute('src'); v.load(); } catch (e) {}
    el.classList.add('zba-fade');
    setTimeout(function () { el.remove(); }, 500);
  }
  el.addEventListener('click', done);
  document.addEventListener('keydown', function (ev) {
    if (ev.key === 'Escape' || ev.keyCode === 27) done();
  });
  var stall = setTimeout(done, 25000);
  v.addEventListener('ended', function () { clearTimeout(stall); done(); });
  v.addEventListener('error', function () { clearTimeout(stall); done(); });
  function start() {
    var p;
    try { p = v.play(); } catch (e) { done(); return; }
    if (!p || typeof p.then !== 'function') return;
    p.then(function () {
      try {
        v.muted = false;
        setTimeout(function () {
          if (v.paused && !finished) { v.muted = true; try { v.play(); } catch (e) {} }
        }, 300);
      } catch (e) { try { v.muted = true; } catch (e2) {} }
    }, function () { done(); });
  }
  function whenReady() {
    var fired = false;
    function fire() { if (fired) return; fired = true; start(); }
    try {
      if (document.body && document.body.classList.contains('zcode-startup-ready')) { fire(); return; }
    } catch (e) {}
    window.addEventListener('zcode-react-startup-ready', function () { setTimeout(fire, 60); }, { once: true });
    setTimeout(fire, 2500);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', whenReady, { once: true });
  else whenReady();
})();
</script>
<!-- ZCODE-BOOT-ANIMATION-END -->
'@

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
# every 4 MiB block (hex), matching electron/asar's filesystem integrity
# format verified against the 3.16.3 header.
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
    # Walk-Assign2 below rewrites offsets in place, so it must walk a CLONE of
    # the header: a second Write-Asar call on the same $asar (backup rebuild +
    # patch write) would otherwise treat already-shifted offsets as source
    # positions and corrupt every payload file after the replaced one.
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

# Re-read the SOURCE asar from disk and compare untouched sentinel files (the
# Electron entry point and the main-process bundle) byte-for-byte against the
# rebuilt one. Catches a shifted-offset rebuild that marker checks cannot see.
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

# ---- clip selection ---------------------------------------------------------
function Select-Clip([string]$clipDir, [string]$want) {
    if (-not (Test-Path -LiteralPath $clipDir)) { return $null }
    $clips = @(Get-ChildItem -LiteralPath $clipDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -match '^\.(mp4|webm|mov)$' } | Sort-Object Name)
    if ($clips.Count -eq 0) { return $null }
    if ($want) {
        $hit = $clips | Where-Object { $_.Name -ieq $want -or $_.BaseName -ieq $want } | Select-Object -First 1
        if (-not $hit) { throw "clip '$want' not found in $clipDir (available: $(($clips | ForEach-Object { $_.Name }) -join ', '))" }
        return $hit
    }
    return $clips[0]
}

function Get-ClipMime([string]$ext) {
    switch ($ext.ToLowerInvariant()) {
        '.mp4'  { return 'video/mp4' }
        '.webm' { return 'video/webm' }
        '.mov'  { return 'video/quicktime' }
        default { throw "unsupported clip extension: $ext" }
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

# 1) pick the clip first: no point touching the asar for a missing video
$clipDir = Join-Path $PSScriptRoot 'boot-animation'
$clipFile = Select-Clip $clipDir $Clip
if (-not $clipFile) {
    Write-Host "[X] no intro clip found in: $clipDir" -ForegroundColor Red
    Write-Host '    Put one .mp4 / .webm / .mov file there (e.g. boot.mp4) and re-run.' -ForegroundColor Yellow
    Read-Host 'Press Enter to exit'
    exit 1
}
$clipBytes = [System.IO.File]::ReadAllBytes($clipFile.FullName)
if ($clipBytes.Length -eq 0) {
    Write-Host "[X] clip is empty: $($clipFile.Name)" -ForegroundColor Red
    Read-Host 'Press Enter to exit'
    exit 1
}
if ($clipBytes.Length -gt $script:maxClipBytes) {
    Write-Host ("[X] clip is {0:N1} MiB, above the {1} MiB cap." -f ($clipBytes.Length / 1MB), ($script:maxClipBytes / 1MB)) -ForegroundColor Red
    Write-Host '    Re-encode it smaller (720p H.264 is plenty for a 7 s intro) and re-run.' -ForegroundColor Yellow
    Read-Host 'Press Enter to exit'
    exit 1
}
$mime = Get-ClipMime $clipFile.Extension
$dataUri = 'data:' + $mime + ';base64,' + [Convert]::ToBase64String($clipBytes)
$blockText = $script:blockTemplate.Replace('__ZBA_DATA_URI__', $dataUri)
Write-Host ("[1/5] clip: {0} ({1:N2} MiB, {2}, embedded as data URI)" -f $clipFile.Name, ($clipBytes.Length / 1MB), $mime)

# 2) read current asar, extract index.html, detect state
$asar = Read-Asar $asarPath
$htmlHit = Get-EntryAndBytes $asar $htmlRelPath
if (-not $htmlHit) {
    throw "renderer entry page not found in this ZCode build ($htmlRelPath). Version changed? Refusing."
}
$htmlText = [System.Text.Encoding]::UTF8.GetString($htmlHit.bytes)
$cBegin = Count-Str $htmlText $markerBegin
$cEnd   = Count-Str $htmlText $markerEnd
if ($cBegin -eq 0 -and $cEnd -eq 0) {
    $state = 'clean'
    $cleanHtmlText = $htmlText
} elseif ($cBegin -eq 1 -and $cEnd -eq 1 -and $htmlText.IndexOf($markerBegin) -lt $htmlText.IndexOf($markerEnd)) {
    $state = 'patched'
    # strip the block plus the one CRLF this script inserts on each side, so a
    # re-run sees exactly the same clean text it wrote (no blank line creep)
    $idx = $htmlText.IndexOf($markerBegin)
    $endIdx = $htmlText.IndexOf($markerEnd) + $markerEnd.Length
    $before = $htmlText.Substring(0, $idx)
    $after = $htmlText.Substring($endIdx)
    if ($before.EndsWith("`r`n")) { $before = $before.Substring(0, $before.Length - 2) }
    elseif ($before.EndsWith("`n") -or $before.EndsWith("`r")) { $before = $before.Substring(0, $before.Length - 1) }
    if ($after.StartsWith("`r`n")) { $after = $after.Substring(2) }
    elseif ($after.StartsWith("`n") -or $after.StartsWith("`r")) { $after = $after.Substring(1) }
    $cleanHtmlText = $before + $after
} else {
    throw 'app.asar contains a broken boot-animation block; run restore-zcode-boot-animation.bat first. Refusing.'
}
Write-Host "[2/5] state: $state"

# 3) backup must hold the boot-free asar of THIS machine (may carry other patches)
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
        $bkHtml = Get-EntryAndBytes $bk $htmlRelPath
        if ($bkHtml) {
            $bkText = [System.Text.Encoding]::UTF8.GetString($bkHtml.bytes)
            if ((Count-Str $bkText $markerBegin) -eq 0 -and $bkText -eq $cleanHtmlText) {
                $needBackupWrite = $false
            }
        }
    }
}
if ($needBackupWrite) {
    if ($state -eq 'clean') {
        Copy-Item -Force $asarPath "$backupPath.tmp"
        Move-Item -Force "$backupPath.tmp" $backupPath
        Write-Host '[3/5] backup (re)created (byte-identical current asar, boot-free)'
    } else {
        $cleanBytes = [System.Text.Encoding]::UTF8.GetBytes($cleanHtmlText)
        $tmpBak = "$backupPath.tmp"
        Write-Asar $asar $htmlRelPath $cleanBytes $tmpBak
        Move-Item -Force $tmpBak $backupPath
        Write-Host '[3/5] backup (re)created from boot-stripped baseline'
    }
    [System.IO.File]::WriteAllText($hashPath, (Hash-Bytes ([System.IO.File]::ReadAllBytes($backupPath))))
} else {
    Write-Host '[3/5] clean backup verified'
}

# 4) insert the block right before </body> of the CLEAN html
$bodyClose = $cleanHtmlText.LastIndexOf('</body>')
if ($bodyClose -lt 0) {
    throw 'cannot find </body> in out/renderer/index.html. Version changed? Refusing.'
}
$blockTrimmed = $blockText.Trim()
$patchedHtmlText = $cleanHtmlText.Substring(0, $bodyClose) + "`r`n" + $blockTrimmed + "`r`n" + $cleanHtmlText.Substring($bodyClose)
$patchedHtmlBytes = [System.Text.Encoding]::UTF8.GetBytes($patchedHtmlText)

# 5) rebuild the asar from the CURRENT asar (keeps every other patch intact)
$tmpPath = "$asarPath.tmp"
Write-Asar $asar $htmlRelPath $patchedHtmlBytes $tmpPath

# self-check: tmp parses, html holds exactly one block in order, data URI present
$tmpAsar = Read-Asar $tmpPath
$tmpHtmlHit = Get-EntryAndBytes $tmpAsar $htmlRelPath
if (-not $tmpHtmlHit) {
    Remove-Item $tmpPath -ErrorAction SilentlyContinue
    throw 'rebuilt asar failed self-check (html unreadable); original untouched.'
}
$tmpText = [System.Text.Encoding]::UTF8.GetString($tmpHtmlHit.bytes)
if ((Count-Str $tmpText $markerBegin) -ne 1 -or (Count-Str $tmpText $markerEnd) -ne 1) {
    Remove-Item $tmpPath -ErrorAction SilentlyContinue
    throw 'rebuilt asar failed self-check (markers); original untouched.'
}
if ($tmpText.IndexOf($markerEnd) -le $tmpText.IndexOf($markerBegin)) {
    Remove-Item $tmpPath -ErrorAction SilentlyContinue
    throw 'rebuilt asar failed self-check (marker order); original untouched.'
}
if (-not $tmpText.Contains('data:video/')) {
    Remove-Item $tmpPath -ErrorAction SilentlyContinue
    throw 'rebuilt asar failed self-check (clip data URI missing); original untouched.'
}

# payload spot-check before the final swap
Assert-SentinelsUnchanged $asarPath $tmpAsar $tmpPath

Move-Item -Force $tmpPath $asarPath
Write-Host '[4/5] patch written (asar rebuilt from current; other patches preserved).'

# verify from disk
$chk = Read-Asar $asarPath
$chkHit = Get-EntryAndBytes $chk $htmlRelPath
$chkText = [System.Text.Encoding]::UTF8.GetString($chkHit.bytes)
if ((Count-Str $chkText $markerBegin) -ne 1 -or -not $chkText.Contains('data:video/')) {
    throw 'post-write verification failed; run restore-zcode-boot-animation.bat.'
}
Write-Host '[5/5] verified: intro block present in out/renderer/index.html.'

if ($NoRestart) {
    Write-Host 'done (NoRestart: leave ZCode closed).'
} elseif ($zcodeExe) {
    Start-Process $zcodeExe
    Write-Host 'ZCode restarted.'
} else {
    Write-Host 'done. Start ZCode manually.'
}
Write-Host 'Boot animation applied: plays once per app launch, click or Esc to skip.'
Write-Host 'Re-run to change the clip; restore-zcode-boot-animation.bat reverts.'
