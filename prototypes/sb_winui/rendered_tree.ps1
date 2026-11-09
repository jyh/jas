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
# Exit 0 = mismatches=0, GAPS PASS and KINDS-VERDICT PASS; 1 = a mismatch, or a
# gap or kinds verdict that is not PASS (O97); 2 = NOT RUN or REFUSED.
# ASCII only: Windows PowerShell 5.1 reads a BOM-less script as cp1252.

# -FreezeGaps writes e2e_baselines/shell_gaps.json as the old ledger plus this
# launch's gaps (New-SbShellGapLedger), then judges against it.
# -Opener <menubar item id> (flask STATUS 749): -Panel names a DIALOG, opened by
# that menu item through SB_MENU_SYNTH (a person's Invoke), and the tree is read
# under the dialog layer (DialogScroll) instead of the dock (PaneScroll). The
# shell writes the dialog's plan only because SB_PANEL names it.
param([string]$Panel = 'align_panel_content', [int]$SettleSec = 4, [switch]$FreezeGaps, [string]$Opener = '')
if ($Opener -notmatch '^[a-z0-9_]*$') { "VERDICT: REFUSED: -Opener '$Opener' is not a menubar item id"; exit 2 }
$root = if ($Opener) { 'DialogScroll' } else { 'PaneScroll' }
# SB_DOCK too: the dock replaces the one pane, so SB_PANEL (the dialog's id) is
# never opened as a panel, and no dock pane's id matches it (measured 11-09:
# without the dock the shell refused `panel=document_setup` as a panel).
$openerEnv = if ($Opener) { "`$env:SB_DOCK='Default'; `$env:SB_MENU_SYNTH='" + $Opener + "'; " } else { '' }
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
# SB_TOOLBAR=0: the toolbar pane writes the same SB_PLAN_OUT file, and since it
# went default-on (#343) its plan landed LAST, so this compared the toolbar's
# plan against the dock's tree. The owner check below refuses that by name.
New-SbLaunchTask -TaskName $task -Exe $exe -EnvPrefix ("`$env:SB_SCENE='app'; `$env:SB_TOOLBAR='0'; `$env:SB_PANEL='" + $Panel + "'; `$env:SB_PLAN_OUT='rt-plan.json'; " + $openerEnv)
$known = Get-SbAppPids $exe
$st = Start-SbAppTask -TaskName $task -Exe $exe -Known $known
"start: pid=$($st.Pid) waited=$($st.Waited) refusal=$($st.Refusal)"
if ($st.Pid -eq 0) { Remove-SbTask $task; exit 2 }
$w = Wait-SbRow -Log $log -Mark $mark -Patterns @('PLAN OUT ', 'RUSTFAIL') -TimeoutSeconds 60
"wait: waited=$($w.Waited) row=$($w.Row)"
Start-Sleep -Seconds $SettleSec
$arg = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $dir 'uia_tree.ps1') + '" -ProcessId ' + $st.Pid + ' -Root ' + $root + ' -Through ' + $Panel + ' -Out "' + $uiaOut + '"'
$pr = New-ScheduledTaskPrincipal -UserId (Get-SbUid) -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $uTask -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg) -Principal $pr -Force | Out-Null
Start-ScheduledTask -TaskName $uTask
$sw = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path $uiaOut) -and $sw.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Milliseconds 250 }
Start-Sleep -Milliseconds 500
"uia: exists=$(Test-Path $uiaOut) after=$([math]::Round($sw.Elapsed.TotalSeconds,1))s"
"plan-out rows since mark:"; (@(Read-SbRows $log $mark) | Where-Object { $_ -match 'PLAN OUT|PANEL DRAWN|DIALOG (OPENED|SHOWN)|MENU SYNTH|RUSTFAIL' } | Select-Object -Last 6) | ForEach-Object { "  $_" }
$stop = Stop-SbAppByPid -TargetPid $st.Pid -ExpectName (Get-SbProcessName $exe)
"stop: $($stop.Verdict)"
Remove-SbTask $task; Remove-SbTask $uTask
"tasks left: " + @(Get-ScheduledTask -TaskName 'jas-rt-*' -ErrorAction SilentlyContinue).Count
$owner = Get-SbPlanOutOwner @(Read-SbRows $log $mark)
"plan-out owner: $owner"
# O97 rung A: the shell's own gap counts for THIS launch's panel (and every
# other pane it built), against the committed ledger. The corpus opens Layers
# 0 times in 116 launches (flask STATUS 726), so this per-panel launch is where
# findings 4 and 5 can red. A gap verdict that is not PASS makes the exit 1.
$gapLedgerPath = Join-Path $dir 'e2e_baselines\shell_gaps.json'
$gapLedger = if (Test-Path $gapLedgerPath) { Get-Content -Raw $gapLedgerPath | ConvertFrom-Json } else { $null }
if ($FreezeGaps) {
    $g = Get-SbShellGaps @(Read-SbRows $log $mark)
    if ($null -ne $g.Refusal) { "GAPS-FROZEN: REFUSED -- $($g.Refusal)"; exit 2 }
    $gapLedger = New-SbShellGapLedger $g $gapLedger
    [System.IO.File]::WriteAllText($gapLedgerPath, (ConvertTo-SbLfText ($gapLedger | ConvertTo-Json)), [System.Text.Encoding]::ASCII)
    "GAPS-FROZEN: -> $gapLedgerPath (review it before committing it)"
}
$gaps = Get-SbShellGapVerdict @(Read-SbRows $log $mark) $gapLedger
"GAPS: $gaps"
if ((Test-Path $planOut) -and $owner -ne $Panel) { "VERDICT: REFUSED: the plan file is $owner's, not $Panel's (the last PLAN OUT row)"; exit 2 }
if ((Test-Path $planOut) -and (Test-Path $uiaOut)) {
  $r = Compare-SbRenderedTree -Plan (Get-Content $planOut -Raw) -Uia (Get-Content $uiaOut -Raw)
  "VERDICT: $($r.Verdict)"; $r.Mismatches | ForEach-Object { "  $_" }
  $kinds = Get-SbRenderedKinds -Plan (Get-Content $planOut -Raw) -Uia (Get-Content $uiaOut -Raw)
  "KINDS: $kinds"
  $kindsMapPath = Join-Path $dir 'e2e_baselines\uia_kinds.json'
  $kindsMap = if (Test-Path $kindsMapPath) { Get-Content -Raw $kindsMapPath | ConvertFrom-Json } else { $null }
  $kindsVerdict = Test-SbRenderedKinds $kinds $kindsMap
  "KINDS-VERDICT: $kindsVerdict"
  if ($r.Verdict -like 'REFUSED*') { exit 2 }
  if ($r.Mismatches.Count -gt 0 -or $gaps -notlike 'PASS*' -or $kindsVerdict -notlike 'PASS*') { exit 1 }
  exit 0
} else { "VERDICT: NOT RUN (plan=$(Test-Path $planOut) uia=$(Test-Path $uiaOut))"; exit 2 }
