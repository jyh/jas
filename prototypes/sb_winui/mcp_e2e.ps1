# mcp_e2e.ps1 -- (A) W2: the Windows agent path, end to end, against the corpus.
#
# Holds the shell (sitting.ps1 -Stay) with SB_MCP_PIPE=1 and the corpus's own
# document; a stepped client (mcp_steps.ps1) replays the mcp_exchanges case
# whose artist acts are accept, reject and undo; at each artist step THIS
# script acts through the real UI in session 1 -- Accept and Reject pressed by
# UI Automation on the accept bar (uia_invoke.ps1), the undo a real Ctrl+Z
# (uia_key.ps1) -- then lets the client go on. mcp_e2e_judge.py judges every
# reply with the corpus's own rule and that a Reject leaves the document
# byte-identical.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File mcp_e2e.ps1
#
# Exit 0 = PASS; 1 = FAIL; 2 = NOT RUN (no app, no client, no reply).
# The client runs in THIS session (an ssh shell is session 0): the pipe is the
# user's, not the session's. UIA and keys need the desktop, so those run in
# session 1 as scheduled tasks, as every other harness hand does.
# ASCII only: Windows PowerShell 5.1 reads a BOM-less script as cp1252.
param([int]$StepTimeoutSec = 180)
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
. (Join-Path $dir 'harness_common.ps1')
$repo = (Resolve-Path (Join-Path $dir '..\..')).Path
$bin = Join-Path $dir 'bin\Debug\net10.0-windows10.0.22621.0\win-x64'
$work = Join-Path $bin 'mcp-e2e'
$flags = Join-Path $work 'flags'
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $flags | Out-Null
$plan = & python (Join-Path $dir 'mcp_e2e_judge.py') steps $work
$plan | ForEach-Object { "plan: $_" }
$svgName = ($plan | Select-String '^setup_svg=(.+)$').Matches[0].Groups[1].Value
$log = Join-Path $bin 'sb-runs.log'
$before = if (Test-Path $log) { (Get-Content $log).Count } else { 0 }
$env:SB_MCP_PIPE = '1'
$env:SB_SVG = Join-Path $repo "test_fixtures\svg\$svgName"
foreach ($n in 'SB_DOCK', 'SB_DOCK_SNAP', 'SB_DOCK_COLLAPSE', 'SB_DOCK_FLOAT_TOUR') { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
# The launcher rebuilds the cdylib, and cargo's warnings arrive on stderr; under
# 'Stop', 5.1 turns a native command's stderr into a terminating error.
$ErrorActionPreference = 'Continue'
$stay = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'sitting.ps1') -Stay -Force *>&1
$m = $stay | Select-String 'STAY pid=(\d+)' | Select-Object -First 1
$appPid = if ($m) { [int]$m.Matches[0].Groups[1].Value } else { 0 }
"app: pid=$appPid svg=$svgName"
if ($appPid -eq 0) { "VERDICT: NOT RUN (the app did not stay)"; exit 2 }
try {
    Start-Sleep -Seconds 3
    $out = Join-Path $work 'out.jsonl'
    $client = Start-Job -ScriptBlock { param($c, $p, $st, $o, $f) & powershell -NoProfile -ExecutionPolicy Bypass -File $c -Pipe $p -Steps $st -Out $o -FlagDir $f } `
        -ArgumentList (Join-Path $dir 'mcp_steps.ps1'), "jas-mcp-$appPid", (Join-Path $work 'steps.json'), $out, $flags
    $pr = New-ScheduledTaskPrincipal -UserId (Get-SbUid) -LogonType Interactive -RunLevel Limited
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($client.State -eq 'Running' -and $sw.Elapsed.TotalSeconds -lt $StepTimeoutSec) {
        foreach ($ready in @(Get-ChildItem $flags -Filter 'ready-*' -ErrorAction SilentlyContinue)) {
            $n = $ready.Name.Substring(6)
            if (Test-Path (Join-Path $flags "done-$n")) { continue }
            $act = (Get-Content $ready.FullName).Trim()
            $res = Join-Path $flags "act-$n.txt"
            $script = if ($act -eq 'undo') { 'uia_key.ps1' } else { 'uia_invoke.ps1' }
            $arg = '-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $dir $script) + '" -ProcessId ' + $appPid + ' -Out "' + $res + '"'
            switch ($act) {
                'accept' { $arg += ' -Id ProposalAccept' }
                'reject' { $arg += ' -Id ProposalReject' }
                'undo' { }
                default { "VERDICT: NOT RUN (the plan names an artist act this driver does not know: $act)"; exit 2 }
            }
            Register-ScheduledTask -TaskName 'jas-mcp-e2e-act' -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg) -Principal $pr -Force | Out-Null
            Start-ScheduledTask -TaskName 'jas-mcp-e2e-act'
            $sw2 = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path $res) -and $sw2.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 200 }
            Start-Sleep -Milliseconds 300
            "artist step $n ($act): $(if (Test-Path $res) { (Get-Content $res) -join ' ' } else { 'no answer' })"
            Remove-SbTask 'jas-mcp-e2e-act'
            Set-Content -Path (Join-Path $flags "done-$n") -Value 'done' -Encoding ascii
        }
        Start-Sleep -Milliseconds 200
    }
    Receive-Job $client -Wait -AutoRemoveJob | ForEach-Object { "client: $_" }
} finally {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'sitting.ps1') -Stop $appPid *>&1 | Select-String 'stopped' | Select-Object -First 1 | ForEach-Object { "stop: $($_.Line.Trim())" }
}
$all = Get-Content -Encoding utf8 $log
$all[$before..($all.Count - 1)] | Select-String 'MCP ATT|MCP DET|PROPOSAL |KEY RAN|RUSTFAIL' | ForEach-Object { "row: " + ($_.Line -split "`t")[-1] }
& python (Join-Path $dir 'mcp_e2e_judge.py') judge $work
exit $LASTEXITCODE
