# box_ready.ps1 -- the box preflight, as one line a runner can read (O97).
#
# Asks whether this box can take an unattended UI run right now, BEFORE the
# first script:
# * someone is logged on at the console;
# * the console is not locked;
# * no reboot is pending;
# * no topmost window other than the shell's covers the screen (the post-update
#   dim of 2026-10-13 was one).
# Prints one BOX-READY row and the window rows it judged.
#
#   exit 0  verdict=READY
#   exit 3  verdict=NOT RUN(box: <every reason>)
#
# NOT RUN is never a failure of the app: a runner reports it apart from red and
# green, so a box that could not take the run can never read as N failed scripts.
# The verdict itself is Get-SbBoxReadiness in harness_common.ps1, a pure
# function with its arms in harness_selftest.ps1.
#
#   powershell -File box_ready.ps1

[CmdletBinding()]
param([int]$TimeoutSeconds = 20)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')

$snap = Read-SbBoxSnapshot -TimeoutSeconds $TimeoutSeconds
$verdict = Get-SbBoxReadiness $snap
$stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
Write-Output ("BOX-READY v1 verdict=$verdict console=$($snap.ConsoleSession) " +
    "explorer=$(@($snap.ExplorerSessions) -join ',') date=$stamp")
foreach ($r in @($snap.WindowRows)) { if ($null -ne $r) { Write-Output "  $r" } }
if ($verdict -eq 'READY') { exit 0 }
exit 3
