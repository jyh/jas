# prove_e2e.ps1 -- ONE spec item, end to end, with nobody at the console.
#
# Council 2026-10-10 (14:42): level 2 of the three-level testing process is
# AUTOMATED look + function -- drive the app, examine the result -- and the Windows box's
# first act is an UNATTENDED end-to-end proof of one spec item. This is that
# proof, for the selection tool's drag (workspace/tools/selection.yaml): a
# press on an element selects it, the drag moves it, and the highlight draws.
#
#   drive   : a real SendInput drag (send_hand.ps1, session 1, by pid)
#   core    : the document the core now holds (SB_PROBE's `doc`, `selection`)
#   tree    : the open panel's plan as the core resolved it (`plan_sha`)
#   pixels  : the hash of the frame on screen (`frame_hash`, the back buffer)
#   cert    : one line, against FROZEN baselines, naming the commit
#
# PRIVACY: the screenshot is a full-desktop capture and never leaves bin/.
#
# -Freeze writes the baseline from this run (review it before committing it).
# Without -Freeze each reading is compared with the baseline and the line says
# CERTIFIED only when every level matches. A surface that differs from the
# baseline's is NOT COMPARABLE, never a pass and never a fail.
#
# ASCII only: Windows PowerShell 5.1 reads a BOM-less script as cp1252.

param(
    [string]$Baseline = '',
    [switch]$Freeze,
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')

$item    = 'selection.drag'
$exeDir  = Join-Path $PSScriptRoot 'bin\Debug\net10.0-windows10.0.22621.0\win-x64'
$log     = Join-Path $exeDir 'sb-runs.log'
$probe   = Join-Path $exeDir 'sb-probe.json'
$receipt = Join-Path $exeDir 'sb-e2e-hand.json'
$shot    = Join-Path $exeDir 'sb-e2e-shot.png'
$repo    = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$capExe  = Join-Path $repo 'jas_dioxus\target\debug\capture_desktop.exe'
# Harness-local data beside its only consumer: test_fixtures/ is the cross-language
# corpus, whose consumers are the ports and scripts/, and this is neither.
if ($Baseline -eq '') { $Baseline = Join-Path $PSScriptRoot "e2e_baselines\$item" }

# The gesture: press inside the sample's rect (document units), drag it by the
# same delta the harness's pointer arm uses.
$docX = 36; $docY = 36; $dx = 37; $dy = 23; $moves = 7

function Out-Line([string]$s) { Write-Host $s }

foreach ($p in @($probe, $receipt, $shot)) { Remove-Item $p -ErrorAction SilentlyContinue }
$mark = if (Test-Path $log) { (Get-Item $log).Length } else { 0 }

# ---- launch, holding, with the probe on ------------------------------------
$env:SB_PROBE = 'sb-probe.json'
# The launcher runs in the BACKGROUND and the log is watched HERE: its own wait
# is 90 s whatever happens, and a dead window must fail in seconds, not then.
$stayOut = Join-Path $exeDir 'sb-e2e-stay.txt'
$launcher = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -RedirectStandardOutput $stayOut `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'sitting.ps1'), '-Stay', '-Scene', 'app', '-NoRebuild')
$exePath = (Join-Path $exeDir 'SbWinUi.exe')
function Stop-OurApps {
    # Only THIS tree's executable, found by path: never another tree's, never a person's.
    Get-CimInstance Win32_Process -Filter "Name='SbWinUi.exe'" | Where-Object { $_.ExecutablePath -eq $exePath } |
        ForEach-Object { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'sitting.ps1') -Stop ([int]$_.ProcessId) *> $null }
}
$up = Wait-SbRow -Log $log -Mark $mark -Patterns @('RUSTOK APP pid=', 'RUSTFAIL ') -TimeoutSeconds $TimeoutSeconds
Remove-Item Env:\SB_PROBE
if ($null -eq $up.Row -or $up.Row -match 'RUSTFAIL ') {
    Stop-OurApps
    if (-not $launcher.HasExited) { $launcher | Stop-Process -Force -ErrorAction SilentlyContinue }
    $why = if ($null -ne $up.Row) { "the shell said: $($up.Row.Trim())" } else { "no APP row within $($up.Waited)s" }
    Out-Line "E2E-CERT v1 item=$item verdict=NOT RUN -- the app did not come up (after $($up.Waited)s); $why"
    exit 3
}
$appPid = [int](Get-SbField $up.Row 'pid')
$launcher.WaitForExit(30000) | Out-Null

$tasks = @('jas-e2e-hand', 'jas-e2e-shot')
try {
    $ht = Wait-SbRow -Log $log -Mark $mark -Patterns @('HITTARGET which=', 'RUSTFAIL ') -TimeoutSeconds $TimeoutSeconds
    if ($null -ne $ht.Row -and $ht.Row -match 'RUSTFAIL ') {
        Out-Line "E2E-CERT v1 item=$item verdict=NOT RUN -- the shell failed before the drive: $($ht.Row.Trim())"
        exit 3
    }
    $offX = 0.0; $offY = 0.0
    if ($null -ne $ht.Row -and (Get-SbField $ht.Row 'offset-dips') -match '^\(([-0-9.]+),([-0-9.]+)\)$') {
        $offX = [double]$Matches[1]; $offY = [double]$Matches[2]
    }

    # ---- drive: a real SendInput drag, in session 1 -------------------------
    $handArg = ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'send_hand.ps1') + '"' +
                " -ProcessId $appPid -DocX $docX -DocY $docY -DocDx $dx -DocDy $dy -Moves $moves" +
                " -Out `"$receipt`" -TargetOffsetXDips $offX -TargetOffsetYDips $offY")
    $principal = New-ScheduledTaskPrincipal -UserId (Get-SbUid) -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $tasks[0] -Principal $principal -Force `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $handArg) | Out-Null
    Start-ScheduledTask -TaskName $tasks[0]

    # ---- the shell's own reading, written after the release lands -----------
    $pr = Wait-SbRow -Log $log -Mark $mark -Patterns @('PROBE seq=', 'RUSTFAIL ') -TimeoutSeconds $TimeoutSeconds
    if ($null -ne $pr.Row -and $pr.Row -match 'RUSTFAIL ') {
        Out-Line "E2E-CERT v1 item=$item verdict=NOT RUN -- the shell failed during the drive: $($pr.Row.Trim())"
        exit 4
    }
    if ($null -eq $pr.Row -or -not (Test-Path $probe)) {
        Out-Line "E2E-CERT v1 item=$item verdict=NOT RUN -- no PROBE row within $($pr.Waited)s (did the hand press? receipt: $(if (Test-Path $receipt) { Get-Content $receipt -Raw } else { 'none' }))"
        exit 4
    }
    $r = Get-Content $probe -Raw | ConvertFrom-Json

    # ---- a screenshot of the same moment, archived beside the certificate ---
    Start-Sleep -Milliseconds 1500
    $wrap = Join-Path $exeDir 'run-e2e-shot.ps1'
    "& '$capExe' '$shot' *> '$shot.log'" | Set-Content -Path $wrap -Encoding ascii
    Register-ScheduledTask -TaskName $tasks[1] -Principal $principal -Force `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "' + $wrap + '"')) | Out-Null
    Start-ScheduledTask -TaskName $tasks[1]
    for ($i = 0; $i -lt 40 -and -not (Test-Path $shot); $i++) { Start-Sleep -Milliseconds 250 }
}
finally {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'sitting.ps1') -Stop $appPid *> $null
    Stop-OurApps
    foreach ($t in $tasks) { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }
    if (Get-Process -Id $appPid -ErrorAction SilentlyContinue) { Out-Line "E2E-CERT v1 item=$item verdict=NOT RUN -- the app (pid $appPid) is STILL ALIVE after -Stop"; exit 5 }
}

$selCount = @($r.selection).Count

# ---- DRIVE INTEGRITY: did the shell receive exactly the gesture we sent? --
# A real mouse moving during the run interleaves with the injected one, and the
# shell then applies a different gesture than was asked (measured 2026-10-10:
# move=212 against k=7, the line moved by (-72,2) instead of (37,23)). A run
# whose drive cannot be accounted for proves nothing and is never certified.
$ptr = Select-SbRow (Read-SbRows $log $mark) 'POINTER REAL '
$drive = 'UNREADABLE(no POINTER REAL row)'
if ($null -ne $ptr) {
    $mv = Get-SbField $ptr 'move'; $sc = [double](Get-SbField $ptr 'scale')
    $pa = (Get-SbField $ptr 'press@') -replace '[()]', '' -split ','
    $ra = (Get-SbField $ptr 'release@') -replace '[()]', '' -split ','
    $ddx = ([double]$ra[0] - [double]$pa[0]) / $sc; $ddy = ([double]$ra[1] - [double]$pa[1]) / $sc
    $tol = 1.0 / $sc
    if ([int]$mv -ne $moves -or [math]::Abs($ddx - $dx) -gt $tol -or [math]::Abs($ddy - $dy) -gt $tol) {
        $drive = "DISTURBED(move=$mv want=$moves delta=($([math]::Round($ddx,2)),$([math]::Round($ddy,2))) want=($dx,$dy))"
    } else { $drive = "PASS(move=$mv delta=($([math]::Round($ddx,2)),$([math]::Round($ddy,2))))" }
}

# ---- THE SPEC, independent of any baseline: the selected element moved by
# exactly the drag THE SHELL DELIVERED (the injector quantizes to physical
# pixels, so it is (36.67,22.67) for an asked (37,23) at 1.5x). Every
# x/x1/x2/cx under the selected path moved by it, every y/y1/y2/cy likewise,
# against the document as opened (sb-doc-open.json). Zero coordinates read is a
# FAIL, never a vacuous pass.
function Get-SbAtPath($root, $path) {
    $n = $root.layers[[int]$path[0]]
    for ($i = 1; $i -lt $path.Count; $i++) { $n = $n.children[[int]$path[$i]] }
    return $n
}
function Get-SbCoords($node, [string]$pfx, $acc) {
    if ($null -eq $node) { return }
    foreach ($prop in $node.PSObject.Properties) {
        # ANY number: 5.1's ConvertFrom-Json types 0.0 as an integer and others as decimal.
        if ($prop.Name -in @('x','x1','x2','cx','y','y1','y2','cy') -and $null -ne $prop.Value -and
            $prop.Value -is [ValueType] -and $prop.Value -isnot [bool]) { $acc[$pfx + $prop.Name] = [double]$prop.Value }
    }
    if ($node.PSObject.Properties.Name -contains 'children') {
        $k = 0; foreach ($c in $node.children) { Get-SbCoords $c ("$pfx$k/") $acc; $k++ }
    }
}
$moved = 'UNREADABLE'
if ($drive -notlike 'PASS*') { $ddx = [double]::NaN; $ddy = [double]::NaN }
$openDoc = Join-Path $exeDir 'sb-doc-open.json'
if ($selCount -eq 1 -and (Test-Path $openDoc)) {
    $selPath = @($r.selection)[0].path
    $before = @{}; $after = @{}
    Get-SbCoords (Get-SbAtPath (Get-Content $openDoc -Raw | ConvertFrom-Json) $selPath) '' $before
    Get-SbCoords (Get-SbAtPath $r.doc $selPath) '' $after
    $bad = @($before.Keys | Where-Object {
        $want = if ($_ -match '(^|/)(x|x1|x2|cx)$') { $ddx } else { $ddy }
        -not $after.ContainsKey($_) -or [math]::Abs(($after[$_] - $before[$_]) - $want) -gt 1e-4 })
    $by = "($([math]::Round($ddx,4)),$([math]::Round($ddy,4)))"
    $moved = if ($before.Count -gt 0 -and $bad.Count -eq 0) { "PASS(path=[$($selPath -join ',')] coords=$($before.Count) by $by)" }
             else { "FAIL(path=[$($selPath -join ',')] $($bad.Count) of $($before.Count) coord(s) not moved by $by)" }
}

$shotSha = if (Test-Path $shot) { (Get-FileHash $shot -Algorithm SHA256).Hash.Substring(0, 16).ToLower() } else { 'NONE' }
$commit = (& git -C $repo rev-parse --short=12 HEAD).Trim()
$dirty = if ((& git -C $repo status --porcelain -- jas_dioxus/src prototypes/sb_winui | Measure-Object -Line).Lines -gt 0) { '+dirty' } else { '' }
$reading = [ordered]@{
    item = $item; surface = $r.surface; frame_hash = $r.frame_hash; doc_sha = $r.doc_sha
    plan_panel = $r.plan_panel; plan_sha = $r.plan_sha; selection_count = $selCount
}

if ($Freeze) {
    if ($drive -notlike 'PASS*' -or $moved -notlike 'PASS*') {
        Out-Line "E2E-FROZEN v1 item=$item REFUSED -- a baseline is frozen only from a clean run: drive=$drive spec=$moved"
        exit 7
    }
    New-Item -ItemType Directory -Force -Path $Baseline | Out-Null
    ($reading | ConvertTo-Json) | Set-Content -Path (Join-Path $Baseline 'baseline.json') -Encoding ascii
    Copy-Item $probe (Join-Path $Baseline 'probe.json') -Force
    # NEVER copy the screenshot into the baseline: it is a FULL-DESKTOP capture
    # of the person's screen (other windows, URLs) and the baseline is
    # committed to a public repo. It stays in bin/ (git-ignored); the
    # certificate carries its hash only.
    Out-Line "E2E-FROZEN v1 item=$item commit=$commit$dirty drive=$drive spec=$moved surface=$($r.surface) frame=$($r.frame_hash) doc-sha=$($r.doc_sha) plan-sha=$($r.plan_sha) selection=$selCount screenshot=$shotSha -> $Baseline"
    exit 0
}

$bfile = Join-Path $Baseline 'baseline.json'
if (-not (Test-Path $bfile)) { Out-Line "E2E-CERT v1 item=$item verdict=NOT RUN -- no frozen baseline at $bfile (run with -Freeze, then review it)"; exit 6 }
$b = Get-Content $bfile -Raw | ConvertFrom-Json

# The spec's own observable, independent of any baseline: one element selected.
$core = if ($moved -like 'PASS*' -and $selCount -eq 1 -and $r.doc_sha -eq $b.doc_sha) { 'PASS' } else { "FAIL(selection=$selCount doc-sha=$($r.doc_sha) want=$($b.doc_sha))" }
$tree = if ($r.plan_panel -eq $b.plan_panel -and $r.plan_sha -eq $b.plan_sha) { 'PASS' } else { "FAIL(plan=$($r.plan_panel)/$($r.plan_sha) want=$($b.plan_panel)/$($b.plan_sha))" }
$pix  = if ($r.surface -ne $b.surface) { "NOT COMPARABLE(surface=$($r.surface) baseline=$($b.surface))" }
        elseif ($r.frame_hash -eq $b.frame_hash) { 'PASS' } else { "FAIL(frame=$($r.frame_hash) want=$($b.frame_hash))" }
$verdict = if ($drive -like 'PASS*' -and $core -eq 'PASS' -and $tree -eq 'PASS' -and $pix -eq 'PASS') { 'CERTIFIED' } else { 'NOT CERTIFIED' }
$line = "E2E-CERT v1 item=$item commit=$commit$dirty drive=SendInput(session=1,pid=$appPid,moves=$moves):$drive " +
        "spec=$moved core=$core tree=$tree pixels=$pix@$($r.surface) screenshot=$shotSha(archived,not compared) " +
        "foreign-input=$(if ($drive -like 'PASS*') { 'none-reached-the-gesture' } else { 'DETECTED-or-unreadable' }) verdict=$verdict date=$((Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'))"
Out-Line $line
Add-Content -Path (Join-Path $exeDir 'e2e-certificates.log') -Value $line -Encoding ascii
if ($verdict -ne 'CERTIFIED') { exit 1 }
exit 0
