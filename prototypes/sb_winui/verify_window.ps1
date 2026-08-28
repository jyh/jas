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
    [int]$Seconds = 12,
    # "r,g,b" values that must appear in the capture. Used from checkpoint 3 on,
    # where the question stops being "is there a window" and becomes "did the
    # RUST core's pixels reach the screen".
    [string[]]$ExpectColor = @()
)

$ErrorActionPreference = 'Stop'
$tools = "$env:LOCALAPPDATA\jas-tools"

# ⛔ RESOLVE -Exe TO AN ABSOLUTE PATH, AND REFUSE IF IT DOES NOT EXIST.
#
# A RELATIVE -Exe MAKES THIS ENTIRE SCRIPT A SILENT NO-OP. The launcher and the
# capture both run as SCHEDULED TASKS in session 1, whose working directory is
# NOT the caller's -- so `& 'prototypes\sb_winuiin\...\SbWinUi.exe'` resolves
# against C:\Windows\system32, finds nothing, and the app never starts. $scratch
# (derived from the same path) then points somewhere else again, so the PNG and
# its sidecar are looked for where nothing was ever written.
#
# Measured 2026-08-27: a relative -Exe produced "no capture sidecar / no PNG
# produced / VERIFY: FAIL" -- which reads as THE ORACLE FAILING, and sent me to
# probe the interactive-task mechanism with a control before the real cause was
# visible. The mechanism was fine the whole time.
#
# ⇒ THE FAILURE POINTED AT THE WRONG COMPONENT, which is the expensive kind. A
# path that cannot work must be refused HERE, with the reason, rather than
# reappearing as a missing artifact two layers away.
# AND ONLY JOIN WHEN IT IS ACTUALLY RELATIVE. The first version of this fix
# joined unconditionally, which turns an ALREADY-ABSOLUTE path into a
# doubled one and GetFullPath throws 'The given path format is not
# supported.' I shipped that, because I tested the new REFUSAL branch (a bad
# relative path, correctly refused by name) and never re-tested the ordinary
# success branch it sits in front of. A guard needs a positive control as
# much as any other instrument: assert that a GOOD input still passes, not
# only that a bad one is caught.
if (-not [System.IO.Path]::IsPathRooted($Exe)) {
    $Exe = Join-Path (Get-Location) $Exe
}
$Exe = [System.IO.Path]::GetFullPath($Exe)
if (-not (Test-Path $Exe)) {
    Write-Output "  FAIL: -Exe does not exist: $Exe"
    Write-Output "VERIFY: FAIL"
    exit 1
}
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
$extraEnv = ''
# ⛔ FORWARD EVERY SB_* VARIABLE, GENERICALLY. This used to be one `if` per
# variable and the file's own comment recorded the consequence twice: SB_FRAMES
# was silently not forwarded, so a run that asked for 120 frames quietly measured
# 60; the fix was applied to SB_FRAMES, and the comment then warned in as many
# words that "the NEXT variable added needs it again -- a correction arrives
# attached to its own instance and gives no signal that a neighbour exists."
#
# SB_RESIZE is that next variable, and rather than prove the prediction right a
# third time this enumerates the environment instead of naming members of it. An
# unforwarded setting is the worst kind of defect this harness can have: the app
# falls back to a default, every number looks reasonable, and the run is LABELLED
# as one experiment while MEASURING another.
#
# The receipt below is the other half -- the launcher prints what it forwarded, so
# a run's own output says which variables reached the app rather than which ones
# the operator believed they set.
$forwarded = @()
foreach ($v in (Get-ChildItem env: | Where-Object { $_.Name -like 'SB_*' } | Sort-Object Name)) {
    # Single quotes are the delimiter in the generated command, so a value
    # containing one would break out of the string. Refuse rather than mangle.
    if ($v.Value -match "'") {
        Write-Error "verify_window: $($v.Name) contains a single quote; refusing to forward it."
        exit 2
    }
    $extraEnv += '$env:' + $v.Name + '=''' + $v.Value + '''; '
    $forwarded += "$($v.Name)=$($v.Value)"
}
if ($forwarded.Count -gt 0) { Write-Host "forwarding: $($forwarded -join ' ')" }
else { Write-Host "forwarding: (no SB_* variables set)" }
$launchArg = '-NoProfile -ExecutionPolicy Bypass -Command ' +
    '"$env:DOTNET_ROOT=''' + "$env:LOCALAPPDATA\Microsoft\dotnet" + '''; ' + $extraEnv + '& ''' + $Exe + '''"'
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

# THE CHECKPOINT-3 ARM: exact probe colours, counted.
#
# The window title proves the SHELL ran. It says nothing about whether the Rust
# core painted, because a WinUI window with a dead SwapChainPanel has the same
# title as a live one. These colours are produced by `jas_paint_probe_surface`
# and by nothing else on this desktop, which is what makes them evidence.
#
# A CAVEAT THAT MUST NOT BE READ AS A RESULT: a GDI screen copy does not always
# capture hardware-composed swapchain content. If the colours are absent, that is
# EITHER a rendering failure OR a capture limitation, and the two are not
# distinguishable from this arm alone. It is reported as INCONCLUSIVE rather than
# FAIL for exactly that reason -- calling it a failure would be asserting
# something this instrument cannot see.
if ($ExpectColor.Count -gt 0 -and (Test-Path $png)) {
    Add-Type -AssemblyName System.Drawing
    $bmp = [System.Drawing.Bitmap]::FromFile($png)
    $want = @{}
    foreach ($c in $ExpectColor) { $want[$c] = 0 }
    for ($y = 0; $y -lt $bmp.Height; $y += 3) {
        for ($x = 0; $x -lt $bmp.Width; $x += 3) {
            $p = $bmp.GetPixel($x, $y)
            $key = "$($p.R),$($p.G),$($p.B)"
            if ($want.ContainsKey($key)) { $want[$key]++ }
        }
    }
    $bmp.Dispose()
    $missing = @()
    foreach ($c in $ExpectColor) {
        if ($want[$c] -ge 50) { $verdicts += "ok  : probe colour $c found ($($want[$c]) sampled pixels)" }
        else { $missing += "$c ($($want[$c]))"; }
    }
    if ($missing.Count -gt 0) {
        $verdicts += "INCONCLUSIVE: probe colour(s) not found: $($missing -join ', ')"
        $verdicts += "              either the core did not paint, OR a GDI screen copy"
        $verdicts += "              cannot see hardware-composed swapchain content."
        $verdicts += "              This arm cannot tell those apart; do not report either."
        $inconclusive = $true
    }
}

# Leave nothing running on JYH's desktop.
Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Exe)) -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Drop-Task $launchTask
Drop-Task $capTask

$verdicts | ForEach-Object { Write-Output "  $_" }
if (-not $ok) { Write-Output "VERIFY: FAIL"; exit 1 }
if ($inconclusive) { Write-Output "VERIFY: WINDOW OK, PIXELS INCONCLUSIVE"; exit 2 }
Write-Output "VERIFY: PASS"
exit 0
