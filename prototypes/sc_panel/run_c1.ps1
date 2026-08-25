# run_c1.ps1 -- run the S-C.1 materializer in SESSION 1 and collect the C1 receipt.
#
# ASCII ONLY: Windows PowerShell 5.1 reads a BOM-less UTF-8 .ps1 as cp1252, and
# one em dash in a comment kills the parser with errors pointing at correct lines
# (seat breadcrumb 5b trap 5).
#
# WHY A SCHEDULED TASK. A windowed app launched from the session-0 agent shell
# gets a window created at the right size and SILENTLY NEVER SHOWN. Launched
# directly here it also produced no receipt file at all, so the app is not merely
# invisible -- it does not get far enough to write one. An interactive scheduled
# task runs it on the real desktop, where WinUI has a session to attach to.
#
# THE RECEIPT IS THE FILE, NOT THE EXIT CODE. Exit status cannot distinguish
# "measured C1" from "started and did nothing", which is the vacuous-pass shape
# this spike keeps meeting. sc-c1.json is written only by a run that got all the
# way through the materialization.

param(
    [int]$Seconds = 20
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe  = Join-Path $here 'bin\Debug\net10.0-windows10.0.22621.0\win-x64\ScPanel.exe'
$out  = Join-Path (Split-Path -Parent $exe) 'sc-c1.json'
$err  = Join-Path (Split-Path -Parent $exe) 'sc-error.txt'
$task = 'jas-sc1-c1'

if (-not (Test-Path $exe)) { throw "exe not found: $exe" }
Remove-Item $out, $err -ErrorAction SilentlyContinue

# USE $env:COMPUTERNAME, NOT $env:USERDOMAIN. In an ssh session the latter reads
# "WORKGROUP" and Register-ScheduledTask dies with "No mapping between account
# names and security IDs was done".
$uid = "$env:COMPUTERNAME\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal -UserId $uid -LogonType Interactive -RunLevel Limited

# DOTNET_ROOT is required at APP RUNTIME, not just at build time: the runtime-only
# dotnet in Program Files shadows the real SDK install and the app dies with
# "You must install or update .NET" (breadcrumb 5b trap 2).
$arg = '-NoProfile -ExecutionPolicy Bypass -Command ' +
       '"$env:DOTNET_ROOT=''' + "$env:LOCALAPPDATA\Microsoft\dotnet" + '''; & ''' + $exe + '''"'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg

Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
try {
    Start-ScheduledTask -TaskName $task
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline -and -not (Test-Path $out) -and -not (Test-Path $err)) {
        Start-Sleep -Milliseconds 500
    }

    if (Test-Path $out) {
        Write-Host "RECEIPT: $out"
        Get-Content $out -Raw
    } elseif (Test-Path $err) {
        Write-Host "APP ERROR:"
        Get-Content $err -Raw | Select-Object -First 40
    } else {
        Write-Host "NO RECEIPT after $Seconds s -- the run did not reach the end of C1."
        Write-Host "Titled windows now visible to this session (expected: none from session 0):"
        Get-Process | Where-Object { $_.MainWindowTitle } | Select-Object -First 5 ProcessName, MainWindowTitle | Format-Table -AutoSize | Out-String
    }
} finally {
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
}
