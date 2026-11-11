# edge_dock_e2e.ps1 -- R1-4b S6 (flask STATUS 829): the Left and Bottom docks
# as a person's screen holds them, against the engine's rects.
#
# Launches the app in session 1 with SB_SCENE=app, SB_DOCK=Default and
# SB_DOCK_SNAP=<dock key>:<left|bottom>, waits for the shell's EDGE DOCK DRAWN
# row, reads each edge frame's and the canvas strip's UIA rect in session 1
# (uia_rects.ps1), photographs the window, stops the app BY PID, and prints
# Test-SbEdgeDockUia's verdict: every frame at the engine's rect, and the canvas
# cut to sit beside them, in DIPs at the window's own composition scale.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File edge_dock_e2e.ps1 -Snap dock1:left
#
# Exit 0 = PASS; 1 = FAIL; 2 = NOT RUN or REFUSED (no row, no read, no scale).
# ASCII only: Windows PowerShell 5.1 reads a BOM-less script as cp1252.
param([string]$Snap = 'dock1:left', [int]$SettleSec = 3, [string]$Png = '')
if ($Snap -notmatch '^dock\d+:(left|bottom)$') { "VERDICT: REFUSED: -Snap '$Snap' is not <dock key>:<left|bottom>"; exit 2 }
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
. (Join-Path $dir 'harness_common.ps1')
$exe = Join-Path $dir 'bin\Debug\net10.0-windows10.0.22621.0\win-x64\SbWinUi.exe'
$bin = Split-Path $exe -Parent
$log = Get-SbLogPath $exe
$mark = Get-SbLogMark $log
$uiaOut = Join-Path $bin 'edge-uia.json'
if (-not $Png) { $Png = Join-Path $bin 'edge-e2e.png' }
Remove-Item $uiaOut, $Png -ErrorAction SilentlyContinue
$task = 'jas-edge-app'; $uTask = 'jas-edge-uia'
New-SbLaunchTask -TaskName $task -Exe $exe -EnvPrefix ("`$env:SB_SCENE='app'; `$env:SB_DOCK='Default'; `$env:SB_DOCK_SNAP='" + $Snap + "'; ")
$known = Get-SbAppPids $exe
$st = Start-SbAppTask -TaskName $task -Exe $exe -Known $known
"start: pid=$($st.Pid) waited=$($st.Waited) refusal=$($st.Refusal)"
if ($st.Pid -eq 0) { Remove-SbTask $task; "VERDICT: NOT RUN (the app did not start)"; exit 2 }
$w = Wait-SbRow -Log $log -Mark $mark -Patterns @('EDGE DOCK DRAWN ', 'RUSTFAIL') -TimeoutSeconds 60
"wait: waited=$($w.Waited) row=$($w.Row)"
Start-Sleep -Seconds $SettleSec
$rows = @(Read-SbRows $log $mark)
$rectsRow = $rows | Where-Object { $_ -match "`tEDGE RECTS cell=" } | Select-Object -Last 1
$drawnRow = $rows | Where-Object { $_ -match "`tEDGE DOCK DRAWN " } | Select-Object -Last 1
$startup = $rows | Where-Object { $_ -match "`tSTARTUP " } | Select-Object -First 1
$ids = New-Object System.Collections.Generic.List[string]
$lm = [regex]::Match([string]$drawnRow, ' left=dock(\d+):\d+@')
if ($lm.Success) { $ids.Add("edgeL$($lm.Groups[1].Value)") }
$bm = [regex]::Match([string]$drawnRow, ' bottom=dock(\d+):(\d+)@')
if ($bm.Success) { for ($i = 0; $i -lt [int]$bm.Groups[2].Value; $i++) { $ids.Add("edgeB$($bm.Groups[1].Value)g$i") } }
$ids.Add('CanvasStripScroll')
# -WindowStyle Hidden: this task's own console lands on the desktop, over the
# window it photographs (measured 11-11: it covered the canvas and the column).
$arg = '-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $dir 'uia_rects.ps1') + '" -ProcessId ' + $st.Pid +
    ' -Ids ' + ($ids -join ',') + ' -Out "' + $uiaOut + '" -Png "' + $Png + '"'
$pr = New-ScheduledTaskPrincipal -UserId (Get-SbUid) -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $uTask -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg) -Principal $pr -Force | Out-Null
Start-ScheduledTask -TaskName $uTask
$sw = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path $uiaOut) -and $sw.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Milliseconds 250 }
Start-Sleep -Milliseconds 500
"uia: exists=$(Test-Path $uiaOut) after=$([math]::Round($sw.Elapsed.TotalSeconds,1))s png=$(Test-Path $Png)"
$stop = Stop-SbAppByPid -TargetPid $st.Pid -ExpectName (Get-SbProcessName $exe)
"stop: $($stop.Verdict)"
Remove-SbTask $task; Remove-SbTask $uTask
"tasks left: " + @(Get-ScheduledTask -TaskName 'jas-edge-*' -ErrorAction SilentlyContinue).Count
"rects row: $rectsRow"
"drawn row: $drawnRow"
$bad = @($rows | Where-Object { $_ -match "`tRUSTFAIL " })
if ($bad.Count -gt 0) { "RUSTFAIL rows: $($bad.Count)"; $bad | Select-Object -First 3 | ForEach-Object { "  $_" } }
# The window's own scale (STARTUP composition-scale=<x>x<y>), never a constant.
$scaleText = Get-SbField ([string]$startup) 'composition-scale'
$scale = 0.0
if ($null -eq $scaleText -or -not [double]::TryParse($scaleText.Split('x')[0], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$scale)) {
    "VERDICT: REFUSED: no composition-scale on the STARTUP row"; exit 2
}
"scale: $scale"
if (-not (Test-Path $uiaOut)) { "VERDICT: NOT RUN (no UIA read)"; exit 2 }
$read = Get-Content -Raw $uiaOut | ConvertFrom-Json
if ($read.error) { "VERDICT: NOT RUN (the UIA read: $($read.error))"; exit 2 }
$uia = @{}
foreach ($p in $read.rects.PSObject.Properties) { $uia[$p.Name] = @{ X = [double]$p.Value.X; Y = [double]$p.Value.Y; W = [double]$p.Value.W; H = [double]$p.Value.H } }
"uia: asked=$($read.asked) found=$($read.found) " + (($uia.Keys | Sort-Object | ForEach-Object { "$_=$($uia[$_].X),$($uia[$_].Y),$($uia[$_].W),$($uia[$_].H)" }) -join ' ')
$v = Test-SbEdgeDockUia -RectsRow ([string]$rectsRow) -DrawnRow ([string]$drawnRow) -Uia $uia -Scale $scale
if ($bad.Count -gt 0 -and $v -like 'PASS*') { $v = "FAIL(the shell wrote $($bad.Count) RUSTFAIL row(s))" }
"VERDICT: $v"
if ($v -like 'PASS*') { exit 0 }
if ($v -like 'FAIL*') { exit 1 }
exit 2
