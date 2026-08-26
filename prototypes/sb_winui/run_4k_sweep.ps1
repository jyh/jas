# run_4k_sweep.ps1 -- the 4K re-measurement, ALL ARMS IN ONE SESSION.
#
# ASCII ONLY: Windows PowerShell 5.1 reads a BOM-less UTF-8 .ps1 as cp1252 and
# dies in the PARSER on one non-ASCII byte, pointing at correct lines.
#
# ===========================================================================
# CONTROL PAIRS OR NOTHING, AND THAT IS THE WHOLE DESIGN OF THIS SCRIPT.
#
# The banked S-B paint figure did not reproduce in a later session: 0.92 ms
# became 1.14 ms, +24%. The CROSS-SESSION DRIFT IS LARGER THAN THE COPY COST
# BEING MEASURED (~0.15 ms, ~16%). So comparing today's 4K number against a
# banked 1904x941 number would measure ambient conditions and call it an effect.
#
# ==> All four arms run back to back in ONE invocation:
#         direct    @ control size      offscreen @ control size
#         direct    @ 3840x2160         offscreen @ 3840x2160
#     The control pair reproduces (or refutes) the banked baseline IN THIS
#     SESSION, and the 4K pair is read against it rather than against history.
# ===========================================================================
#
# WHY A SCHEDULED TASK: a windowed app launched from the session-0 agent shell
# gets a window created at the right size and SILENTLY NEVER SHOWN. The app must
# run in session 1 or it measures nothing.
#
# THE RECEIPT IS sb-runs.log, NOT THE EXIT CODE. Exit status cannot distinguish
# "measured four arms" from "started and did nothing".

param(
    [int]$Frames = 300,
    [string]$ControlSize = "",          # empty = whatever WinUI gives the window
    [string]$FourKSize = "3840x2160",
    [int]$Seconds = 60
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe  = Join-Path $here 'bin\Debug\net10.0-windows10.0.22621.0\win-x64\SbWinUi.exe'
$log  = Join-Path (Split-Path -Parent $exe) 'sb-runs.log'
$task = 'jas-sb-4k'

if (-not (Test-Path $exe)) { throw "exe not found: $exe" }

# CLEAN UP AT START AS WELL AS AT EXIT. A finally is only reliable while nobody
# truncates the caller's pipeline -- measured yesterday, when a Select-Object
# -First on this script's output stopped the pipeline, skipped the finally, and
# left a task registered and an exe locked (MSB3027, which reads as a toolchain
# fault and is not one).
Get-Process SbWinUi -ErrorAction SilentlyContinue | Stop-Process -Force
try { Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction Stop } catch { }
Remove-Item $log -ErrorAction SilentlyContinue

# USE $env:COMPUTERNAME, NOT $env:USERDOMAIN -- the latter reads WORKGROUP over
# ssh and Register-ScheduledTask dies with "No mapping between account names and
# security IDs was done", NON-TERMINATINGLY.
$uid = "$env:COMPUTERNAME\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal -UserId $uid -LogonType Interactive -RunLevel Limited

function Run-Arm([string]$mode, [string]$size, [string]$label) {
    Write-Host "ARM $label : SB_MODE=$mode SB_SIZE=$(if($size){$size}else{'(window)'}) SB_FRAMES=$Frames"

    $before = 0
    if (Test-Path $log) { $before = (Get-Content $log | Measure-Object -Line).Lines }

    # DOTNET_ROOT is required at APP RUNTIME: the dotnet on PATH is runtime-only
    # and shadows the real SDK, and the app dies with "You must install or update
    # .NET" -- which survives a correct build and looks like a packaging fault.
    $sets = "`$env:DOTNET_ROOT='" + "$env:LOCALAPPDATA\Microsoft\dotnet" + "';" +
            "`$env:SB_MODE='$mode';" +
            "`$env:SB_FRAMES='$Frames';"
    if ($size) { $sets += "`$env:SB_SIZE='$size';" }
    $arg = '-NoProfile -ExecutionPolicy Bypass -Command "' + $sets + " & '$exe'" + '"'

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $task

    $deadline = (Get-Date).AddSeconds($Seconds)
    $landed = $false
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $log) {
            $now = (Get-Content $log | Measure-Object -Line).Lines
            if ($now -gt $before) { $landed = $true; break }
        }
        Start-Sleep -Milliseconds 500
    }

    Get-Process SbWinUi -ErrorAction SilentlyContinue | Stop-Process -Force
    try { Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction Stop } catch { }

    if ($landed) {
        Write-Host ("  " + (Get-Content $log | Select-Object -Last 1))
    } else {
        # A SILENT ARM IS RED, NOT SKIPPED. An arm that produced no line did not
        # run, and a sweep that quietly reported three of four would read as a
        # complete measurement.
        Write-Host "  NO LINE after $Seconds s -- THIS ARM DID NOT RUN. The sweep is incomplete."
    }
    return $landed
}

$ok = @()
try {
    $ok += Run-Arm 'direct'    $ControlSize 'A control/direct'
    $ok += Run-Arm 'offscreen' $ControlSize 'B control/offscreen'
    $ok += Run-Arm 'direct'    $FourKSize   'C 4K/direct'
    $ok += Run-Arm 'offscreen' $FourKSize   'D 4K/offscreen'
}
finally {
    Get-Process SbWinUi -ErrorAction SilentlyContinue | Stop-Process -Force
    try { Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction Stop } catch { }
    $leftTask = [bool](Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue)
    $leftProc = [bool](Get-Process SbWinUi -ErrorAction SilentlyContinue)
    if ($leftTask -or $leftProc) {
        Write-Host "CLEANUP INCOMPLETE: task=$leftTask process=$leftProc"
    } else {
        Write-Host "CLEANUP: no scheduled task, no SbWinUi process. Verified, not assumed."
    }
}

Write-Host ""
Write-Host "ARMS THAT PRODUCED A LINE: $(($ok | Where-Object {$_}).Count) of 4"
Write-Host "RECEIPT: $log"
if (Test-Path $log) { Get-Content $log }
