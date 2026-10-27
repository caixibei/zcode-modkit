# ZCode timezone restore (v1, portable) - save as UTF-8 WITHOUT BOM
# - Undoes patch-zcode-timezone.ps1: writes back the previous USER-level TZ
#   value recorded in zcode-timezone-state.json, or simply deletes the user
#   TZ variable when the previous value was unset / the state file is missing.
# - After restoring, the machine-level TZ=UTC becomes effective again for
#   this user, i.e. ZCode cron schedules go back to UTC interpretation (the
#   pre-patch behaviour).
# - ZCode does NOT need to be closed; quit and relaunch it afterwards so it
#   re-reads the environment.
# Re-apply the patch with patch-zcode-timezone.bat
param([switch]$NoRestart)   # toolbox mode: the toolbox relaunches ZCode itself
$ErrorActionPreference = 'Stop'
# Clear NODE_OPTIONS from this process so the ZCode.exe we (re)start never
# inherits unsupported flags (packaged Electron apps print a startup ERROR for
# e.g. --max-old-space-size); the machine/user registry value is NOT touched.
try { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue } catch {}
$patchedTz = 'Asia/Shanghai'
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

# [1/2] check state: only act when the patch is actually present
Write-Host '[1/2] checking current user TZ ...'
$userTz = [Environment]::GetEnvironmentVariable('TZ', 'User')
if ($userTz -ne $patchedTz) {
    Write-Host ("[1/2] user TZ is {0}, patch not present - nothing to restore" -f $(if ($userTz) { "'$userTz'" } else { '(not set)' }))
    exit 0
}

# [2/2] restore the previous value (empty/missing state = delete the variable)
$prev = $null
if (Test-Path $statePath) {
    try {
        $st = Get-Content $statePath -Raw | ConvertFrom-Json
        if ($st.previousUserTz) { $prev = [string]$st.previousUserTz }
    } catch {
        Write-Host '      (state file unreadable; falling back to deleting the variable)'
    }
}
if ($prev) {
    [Environment]::SetEnvironmentVariable('TZ', $prev, 'User')
    $check = [Environment]::GetEnvironmentVariable('TZ', 'User')
    if ($check -ne $prev) {
        Read-Host 'Press Enter to exit'
        throw "user TZ verify failed: expected '$prev', got '$check'."
    }
    Write-Host ("[2/2] user TZ restored to previous value '{0}'" -f $prev)
} else {
    [Environment]::SetEnvironmentVariable('TZ', $null, 'User')
    if ([Environment]::GetEnvironmentVariable('TZ', 'User')) {
        Read-Host 'Press Enter to exit'
        throw 'user TZ delete failed: variable still present.'
    }
    Write-Host '[2/2] user TZ deleted (machine-level setting takes effect again)'
}
Remove-Item $statePath -ErrorAction SilentlyContinue
Write-Host 'restore point cleaned up.'

if ($NoRestart) {
    Write-Host 'done (NoRestart: toolbox will relaunch ZCode).'
} else {
    $zcodeExe = Find-ZCodeExe
    if (Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue) {
        Write-Host 'ZCode is RUNNING with the old environment (Asia/Shanghai).' -ForegroundColor Yellow
        Write-Host 'Quit it (tray icon -> Quit) and start it again to apply the restored setting.' -ForegroundColor Yellow
    } elseif ($zcodeExe) {
        Start-Process $zcodeExe
        Write-Host 'done. ZCode (re)started with the restored timezone setting.'
    } else {
        Write-Host 'done. ZCode.exe not found on disk; start ZCode manually to apply the restored setting.'
    }
}
