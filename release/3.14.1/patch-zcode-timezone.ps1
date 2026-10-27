# ZCode timezone patch (v1, portable) - save as UTF-8 WITHOUT BOM
# - Makes ZCode schedule/automation cron fields fire on Shanghai time (UTC+8)
#   instead of UTC.
# - Root cause: this machine carries a MACHINE-level environment variable
#   TZ=UTC which overrides the correct Windows time zone (China Standard
#   Time). Electron/Node.js prefers the TZ env var when resolving the local
#   time zone, so ZCode sees "UTC" and interprets cron schedules 8 hours
#   early. (The Windows time zone itself is correct - only the env var lies.)
# - Patch = set the USER-level TZ=Asia/Shanghai. A user variable shadows the
#   machine variable for every process of this user, needs no admin rights
#   and leaves the machine value untouched.
# - Zone name: IANA "Asia/Shanghai" (resolved by Electron/Node ICU; verified
#   that Node reports UTC+8 with it). MSYS/Git Bash "date" ignores IANA names
#   and keeps printing GMT - cosmetic only, ZCode itself is unaffected.
# - ZCode does NOT need to be closed (no file locks involved): processes
#   started AFTER the patch pick up the new zone; a running ZCode keeps UTC
#   until it is quit and relaunched.
# - Idempotent: re-running detects the patch and writes nothing.
# - Restore point: zcode-timezone-state.json records the previous user TZ
#   value so restore-zcode-timezone.ps1 can put it back exactly.
# Revert with restore-zcode-timezone.bat
param([switch]$NoRestart)   # toolbox mode: the toolbox relaunches ZCode itself
$ErrorActionPreference = 'Stop'
# Clear NODE_OPTIONS from this process so the ZCode.exe we (re)start never
# inherits unsupported flags (packaged Electron apps print a startup ERROR for
# e.g. --max-old-space-size); the machine/user registry value is NOT touched.
try { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue } catch {}
$wantTz = 'Asia/Shanghai'
$statePath = Join-Path $PSScriptRoot 'zcode-timezone-state.json'

function Find-ZCodeExe {
    try {
        $p = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1
        if ($p) { return $p.Path }
    } catch {}
    foreach ($c in @('D:\installer\zcode\ZCode.exe', "$env:LOCALAPPDATA\Programs\zcode\ZCode.exe", "$env:ProgramFiles\zcode\ZCode.exe")) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

# [1/3] diagnose: every layer that decides ZCode's "local time zone"
Write-Host '[1/3] diagnosing ...'
$sysTz     = (Get-TimeZone).Id
$machineTz = [Environment]::GetEnvironmentVariable('TZ', 'Machine')
$userTz    = [Environment]::GetEnvironmentVariable('TZ', 'User')
Write-Host ("      Windows time zone  : {0}" -f $sysTz)
Write-Host ("      machine TZ env var : {0}" -f $(if ($machineTz) { $machineTz } else { '(not set)' }))
Write-Host ("      user TZ env var    : {0}" -f $(if ($userTz) { $userTz } else { '(not set)' }))

if ($userTz -eq $wantTz) {
    Write-Host '[1/3] state: patched (user TZ is already Asia/Shanghai), nothing to write'
    if (-not (Test-Path $statePath)) {
        # self-heal the restore point; the original user TZ value is unknown
        # at this point, so restore will just delete the variable
        @{ patchedAt = (Get-Date).ToString('o'); previousUserTz = ''; note = 'self-healed: original user TZ unknown, restore deletes the variable' } |
            ConvertTo-Json | Set-Content -Encoding ASCII $statePath
        Write-Host '      (missing state file re-created for restore)'
    }
    Write-Host 'done. Processes started after the variable was set run on Shanghai time.'
    exit 0
}
Write-Host '[1/3] state: unpatched (user TZ is not Asia/Shanghai)'

# [2/3] restore point: remember the previous user TZ value (may be unset)
if (Test-Path $statePath) {
    Write-Host '[2/3] state file already exists, keeping it as the restore point'
} else {
    @{
        patchedAt           = (Get-Date).ToString('o')
        previousUserTz      = $(if ($userTz) { $userTz } else { '' })
        machineTzSeen       = $(if ($machineTz) { $machineTz } else { '' })
        windowsTimeZoneSeen = $sysTz
    } | ConvertTo-Json | Set-Content -Encoding ASCII $statePath
    Write-Host '[2/3] previous user TZ recorded (restore point)'
}

# [3/3] apply: the user-level TZ shadows the machine-level TZ=UTC for this user
[Environment]::SetEnvironmentVariable('TZ', $wantTz, 'User')
$check = [Environment]::GetEnvironmentVariable('TZ', 'User')
if ($check -ne $wantTz) {
    Read-Host 'Press Enter to exit'
    throw "user TZ verify failed: expected $wantTz, got '$check'."
}
Write-Host ("[3/3] user TZ set to {0} and verified (machine TZ=UTC untouched, now shadowed)" -f $wantTz)

if ($NoRestart) {
    Write-Host 'done (NoRestart: toolbox will relaunch ZCode).'
} else {
    $zcodeExe = Find-ZCodeExe
    if (Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue) {
        Write-Host 'ZCode is RUNNING with the old environment (UTC).' -ForegroundColor Yellow
        Write-Host 'Quit it (tray icon -> Quit) and start it again to pick up Shanghai time.' -ForegroundColor Yellow
    } elseif ($zcodeExe) {
        Start-Process $zcodeExe
        Write-Host 'done. ZCode (re)started and now runs on Shanghai time.'
    } else {
        Write-Host 'done. ZCode.exe not found on disk; start ZCode manually to pick up Shanghai time.'
    }
}
