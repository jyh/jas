# verify_window.ps1 -- assert the S-B shell actually PUT A WINDOW ON THE DESKTOP.
#
# WRITTEN BEFORE THE APP, and the reason is this seat's own §5 finding: a windowed
# app launched from the session-0 agent shell gets a window created at the right
# size and SILENTLY NEVER SHOWN -- no error, no log line. It looks exactly like an
# application bug and is not one. So "it built and exited 0" proves nothing about
# S-B, and neither does `MainWindowHandle`, which reads 0 from session 0 for a
# rendering app and a blank one alike.
#
# THE ORACLE MUST ASSERT A VALUE ONLY THE THING ACTUALLY RUNNING CAN PRODUCE --
# the same law the native-backend CI lane is built on. Here that value is the
# window's TITLE, observed by a process running in SESSION 1, plus pixels.
#
#   -Title   the window title to require (exact substring match)
#   -Exe     the app to launch through the interactive scheduled task
#   -Seconds how long to let it come up before looking

param(
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][string]$Exe,
    [int]$Seconds = 12
)

$ErrorActionPreference = 'Stop'
$tools = "$env:LOCALAPPDATA\jas-tools"
$scratch = Split-Path $Exe -Parent
$png = Join-Path $scratch "sb-verify.png"
$launchTask = "jas-sb-app"
$capTask = "jas-sb-capture"

function Drop-Task([string]$n) {
    try { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction Stop } catch { }
}

# USE $env:COMPUTERNAME, NOT $env:USERDOMAIN. In an ssh session the latter reads
# "WORKGROUP" and Register-ScheduledTask dies with "No mapping between account
# names and security IDs was done" -- and the failure is NON-TERMINATING, so a
# script that prints its own success line will happily do so over nothing.
$uid = "$env:COMPUTERNAME\$env:USERNAME"

Drop-Task $launchTask
Drop-Task $capTask
Remove-Item $png, "$png.json", "$png.error.txt" -ErrorAction SilentlyContinue

# DOTNET_ROOT is not optional here: the dotnet on PATH is a RUNTIME-ONLY install
# (Program Files, 8.0.13) that shadows the real SDK in LOCALAPPDATA, and an app
# built against net10 dies with "You must install or update .NET" without it.
$principal = New-ScheduledTaskPrincipal -UserId $uid -LogonType Interactive -RunLevel Limited
$launchArg = '-NoProfile -ExecutionPolicy Bypass -Command ' +
    '"$env:DOTNET_ROOT=''' + "$env:LOCALAPPDATA\Microsoft\dotnet" + '''; & ''' + $Exe + '''"'
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $launchArg
Register-ScheduledTask -TaskName $launchTask -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
if (-not (Get-ScheduledTask -TaskName $launchTask -ErrorAction SilentlyContinue)) {
    throw "task registration reported success but no task exists"
}
Start-ScheduledTask -TaskName $launchTask
Start-Sleep -Seconds $Seconds

# The capture runs in session 1 and records the session id it ACTUALLY ran in.
$capArg = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $tools 'capture_desktop.ps1') + '" -Out "' + $png + '"'
$capAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $capArg
Register-ScheduledTask -TaskName $capTask -Action $capAction -Principal $principal -Force -ErrorAction Stop | Out-Null
Start-ScheduledTask -TaskName $capTask
Start-Sleep -Seconds 8

$verdicts = @()
$ok = $true

if (-not (Test-Path "$png.json")) {
    $verdicts += "FAIL: no capture sidecar -- the oracle itself did not run"
    $ok = $false
} else {
    $meta = Get-Content "$png.json" -Raw | ConvertFrom-Json
    # THE SIDECAR'S SESSION IS CHECKED FIRST. A capture taken in session 0 is a
    # picture of an empty window station: near-black, no windows, and it would
    # report this app missing no matter how well it ran.
    if ($meta.session -ne 1) {
        $verdicts += "FAIL: capture ran in session $($meta.session), not the desktop (1)"
        $ok = $false
    } else {
        $verdicts += "ok  : capture ran in session 1, bounds $($meta.bounds)"
    }
    $hit = @($meta.windowsAtCap | Where-Object { $_ -like "*$Title*" })
    if ($hit.Count -gt 0) {
        $verdicts += "ok  : window present -- $($hit -join '; ')"
    } else {
        $verdicts += "FAIL: no window matching '$Title'. Titled windows seen: $($meta.windowsAtCap -join ' | ')"
        $ok = $false
    }
}

# Pixels, as the independent second arm. An empty station is near-uniform black;
# a real desktop is not. This does NOT prove the app drew correctly -- it proves
# the capture is of a real desktop, so the window verdict above means something.
if (Test-Path $png) {
    Add-Type -AssemblyName System.Drawing
    $bmp = [System.Drawing.Bitmap]::FromFile($png)
    $sum = 0.0; $n = 0; $colors = @{}
    for ($y = 0; $y -lt $bmp.Height; $y += 17) {
        for ($x = 0; $x -lt $bmp.Width; $x += 17) {
            $c = $bmp.GetPixel($x, $y)
            $sum += ($c.R * 0.299 + $c.G * 0.587 + $c.B * 0.114); $n++
            $colors["$($c.R),$($c.G),$($c.B)"] = 1
        }
    }
    $bmp.Dispose()
    $luma = $sum / $n
    if ($luma -gt 5 -and $colors.Count -gt 100) {
        $verdicts += ("ok  : real desktop pixels (mean luma {0:N1}, {1} colours)" -f $luma, $colors.Count)
    } else {
        $verdicts += ("FAIL: capture looks like an empty station (mean luma {0:N1}, {1} colours)" -f $luma, $colors.Count)
        $ok = $false
    }
} else {
    $verdicts += "FAIL: no PNG produced"
    $ok = $false
}

# Leave nothing running on JYH's desktop.
Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Exe)) -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Drop-Task $launchTask
Drop-Task $capTask

$verdicts | ForEach-Object { Write-Output "  $_" }
if ($ok) { Write-Output "VERIFY: PASS"; exit 0 } else { Write-Output "VERIFY: FAIL"; exit 1 }
