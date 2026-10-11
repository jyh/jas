# rendered_tree.ps1 -- #323: the RENDERED widget tree's STATE against the plan
# it was drawn from, one panel per launch, the same selection on both sides.
#
# Launches the app in session 1 with SB_SCENE=app, SB_PANEL=<panel> and
# SB_PLAN_OUT, waits for the `PLAN OUT` row, reads the live window with
# uia_tree.ps1 (-Root PaneScroll) in session 1, stops the app BY PID, and
# prints `Compare-SbRenderedTree`'s verdict and every mismatch.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File rendered_tree.ps1 -Panel color_panel_content
#
# Exit 0 = mismatches=0; 1 = a mismatch; 2 = NOT RUN or REFUSED.
# ASCII only: Windows PowerShell 5.1 reads a BOM-less script as cp1252.

param([string]$Panel = 'align_panel_content', [int]$SettleSec = 4)
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
. (Join-Path $dir 'harness_common.ps1')
$exe = Join-Path $dir 'bin\Debug\net10.0-windows10.0.22621.0\win-x64\SbWinUi.exe'
$log = Get-SbLogPath $exe
$mark = Get-SbLogMark $log
$planOut = Join-Path (Split-Path $exe -Parent) 'rt-plan.json'
$uiaOut = Join-Path (Split-Path $exe -Parent) 'rt-uia.json'
Remove-Item $planOut, $uiaOut -ErrorAction SilentlyContinue
$task = 'jas-rt-app'; $uTask = 'jas-rt-uia'
New-SbLaunchTask -TaskName $task -Exe $exe -EnvPrefix ("`$env:SB_SCENE='app'; `$env:SB_PANEL='" + $Panel + "'; `$env:SB_PLAN_OUT='rt-plan.json'; ")
$known = Get-SbAppPids $exe
$st = Start-SbAppTask -TaskName $task -Exe $exe -Known $known
"start: pid=$($st.Pid) waited=$($st.Waited) refusal=$($st.Refusal)"
if ($st.Pid -eq 0) { Remove-SbTask $task; exit 2 }
$w = Wait-SbRow -Log $log -Mark $mark -Patterns @('PLAN OUT ', 'RUSTFAIL') -TimeoutSeconds 60
"wait: waited=$($w.Waited) row=$($w.Row)"
Start-Sleep -Seconds $SettleSec
$arg = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $dir 'uia_tree.ps1') + '" -ProcessId ' + $st.Pid + ' -Root PaneScroll -Out "' + $uiaOut + '"'
$pr = New-ScheduledTaskPrincipal -UserId (Get-SbUid) -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $uTask -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg) -Principal $pr -Force | Out-Null
Start-ScheduledTask -TaskName $uTask
$sw = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path $uiaOut) -and $sw.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Milliseconds 250 }
Start-Sleep -Milliseconds 500
"uia: exists=$(Test-Path $uiaOut) after=$([math]::Round($sw.Elapsed.TotalSeconds,1))s"
"plan-out rows since mark:"; (@(Read-SbRows $log $mark) | Where-Object { $_ -match 'PLAN OUT|PANEL DRAWN|RUSTFAIL' } | Select-Object -Last 6) | ForEach-Object { "  $_" }
$stop = Stop-SbAppByPid -TargetPid $st.Pid -ExpectName (Get-SbProcessName $exe)
"stop: $($stop.Verdict)"
Remove-SbTask $task; Remove-SbTask $uTask
"tasks left: " + @(Get-ScheduledTask -TaskName 'jas-rt-*' -ErrorAction SilentlyContinue).Count
if ((Test-Path $planOut) -and (Test-Path $uiaOut)) {
  $r = Compare-SbRenderedTree -Plan (Get-Content $planOut -Raw) -Uia (Get-Content $uiaOut -Raw)
  "VERDICT: $($r.Verdict)"; $r.Mismatches | ForEach-Object { "  $_" }
  if ($r.Verdict -like 'REFUSED*') { exit 2 }
  if ($r.Mismatches.Count -gt 0) { exit 1 }
  exit 0
} else { "VERDICT: NOT RUN (plan=$(Test-Path $planOut) uia=$(Test-Path $uiaOut))"; exit 2 }
