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
#   tree    : the open panel's plan as the core resolved it (`plan_sha`), and
#             the canvas strip's document tabs, each one's name and active state
#             (`tab_sha`; its reading is `tab`). The panel plan is the Align
#             panel's, which no tab is part of, so without `tab_sha` a regression
#             in the tab would certify green (STATUS-flask section 260).
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
# `pixels` is an EXACT hash of the back buffer, so a baseline is pinned to the
# box that froze it: its DPI, its graphics driver, and its desktop -- the
# window's height follows the desktop's state (this box's root measured 992.67
# DIPs one morning and 987.33 after a reboot, same build, 8 device pixels at
# 1.5x). Re-freeze only from a clean run on the box that certifies, and commit
# the new baseline with a `Baseline-Refreeze: <item>: <reason>` line unless the
# spec item changed in the same PR: scripts/check_baseline_spec_change.py reds a
# baseline that moves on its own (docs/TESTING.md section 2).
#
# The gesture is an INPUT SCRIPT (docs/TESTING.md section 6), always: -Script
# <path> names one, and the default is test_fixtures/input_scripts/
# selection.drag.json, the gesture e2e_baselines/selection.drag is frozen from.
# There is no built-in gesture: one gesture, one baseline. A relative path is
# tried from the current directory, then from the repo root. Its press/move/
# release become the SendInput drag, its setup_svg the document, and its
# read=document is compared BYTE FOR BYTE with its expected_json (`readback=`).
# A script this driver cannot deliver exactly is refused by name
# (`Read-SbInputScript`), never approximated. `core` is the read-back against
# the script's expected document, which the ports agree on at level 1, and no
# baseline is needed for it.
#
# `paint` needs no baseline either: any `RUSTFAIL REPAINT-FAILED` row this run
# wrote, or no drawn repaint at all, is a FAIL, and -Freeze refuses on it. A
# refused repaint keeps the PREVIOUS frame on screen, so without this arm a
# frame hash can freeze and then certify a picture of an earlier state
# (flask STATUS 483: a stacked superscript + underline did exactly that).
#
# ASCII only: Windows PowerShell 5.1 reads a BOM-less script as cp1252.

param(
    [string]$Baseline = '',
    [string]$Script = '',
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
$probeDoc = [System.IO.Path]::ChangeExtension($probe, '.doc.json')
if ($Script -eq '') { $Script = 'test_fixtures\input_scripts\selection.drag.json' }
$scriptFull = if (Test-Path $Script) { (Resolve-Path $Script).Path }
              elseif (-not [System.IO.Path]::IsPathRooted($Script) -and (Test-Path (Join-Path $repo $Script))) { (Resolve-Path (Join-Path $repo $Script)).Path }
              else { $null }
if ($null -eq $scriptFull) {
    Write-Host "E2E-CERT v1 script=$Script verdict=NOT RUN -- REFUSED: no input script at that path (from here or from the repo root)"
    exit 2
}
$sc = Read-SbInputScript ([System.IO.File]::ReadAllText($scriptFull, [System.Text.Encoding]::UTF8))
if ($null -ne $sc.Refusal) {
    Write-Host "E2E-CERT v1 script=$Script verdict=NOT RUN -- REFUSED: $($sc.Refusal)"
    exit 2
}
$item = $sc.Item
# Captured here: `$sc` is reused below for the display scale.
$tool = $sc.Tool
$expectedPath = Join-Path (Split-Path $scriptFull -Parent) $sc.Expected
if (-not (Test-Path $expectedPath)) {
    Write-Host "E2E-CERT v1 item=$item verdict=NOT RUN -- the script's expected_json is not at $expectedPath"
    exit 2
}
$svgArgs = @('-Svg', "test_fixtures\svg\$($sc.Svg)")
# Harness-local data beside its only consumer: test_fixtures/ is the cross-language
# corpus, whose consumers are the ports and scripts/, and this is neither.
if ($Baseline -eq '') { $Baseline = Join-Path $PSScriptRoot "e2e_baselines\$item" }

# The gesture, in document units, exactly as the script states it.
$docX = $sc.DocX; $docY = $sc.DocY; $dx = $sc.Dx; $dy = $sc.Dy; $moves = $sc.Moves
# Captured here for the same reason as `$tool`: `$sc` is reused for the scale.
$shiftMode = if ($sc.Shift) { $sc.Shift } else { 'none' }
$altMode = if ($sc.Alt) { $sc.Alt } else { 'none' }
$keyText = "$($sc.KeyText)"; $keyCount = [int]$sc.Keys
# PANEL STEPS (jas section 373): delivered last by the hand through UI
# Automation, carried across -File as one base64 string.
$panelText = "$($sc.PanelText)"; $panelCount = [int]$sc.Panels; $panelShow = "$($sc.PanelShow)"
# MENU STEPS (jas sections 389/392) ride in the same list, in script order.
$menuCount = [int]$sc.Menus
# LATE CLICKS (flask section 443, node 29) ride the same list; each release
# probes, so each is one more PROBE seq, and each writes its own POINTER row.
$clickCount = [int]$sc.Clicks
$clickPoints = @(ConvertFrom-SbPanelText $panelText | Where-Object { $_.click })
$lateCount = $panelCount + $menuCount + $clickCount

function Out-Line([string]$s) { Write-Host $s }

# ---- BUILD WHAT THE CERTIFICATE NAMES, first, every time --------------------
# The line below says build=<HEAD>, so the shell and the cdylib it loads must BE
# HEAD. Neither is rebuilt by launching (sitting.ps1 runs -NoRebuild here, since
# its build would race the wait below), and a stale cdylib still certifies a
# gesture it never exercised: on 2026-10-11 the loaded jas_dioxus.dll was 16 h
# and several merges older than the build= it was certified as, found only when
# a dock run died on `jas_dock_layout`. The native lane is sitting.ps1's (see
# its header: the last lane to touch target/ decides what the shell loads).
# Through cmd so a build's stderr is a log line, never a PowerShell error.
$buildLog = New-SbBuildLog $exeDir 'sb-e2e-build.txt'
$sdk = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'
& cmd /c "cd /d `"$(Join-Path $repo 'jas_dioxus')`" && cargo $($SbCdylibLane -join ' ') > `"$buildLog`" 2>&1"
if ($LASTEXITCODE -ne 0) { Out-Line "E2E-CERT v1 item=$item verdict=NOT RUN -- the cdylib did not build (cargo exit $LASTEXITCODE; see $buildLog)"; exit 2 }
& cmd /c "`"$sdk`" build `"$(Join-Path $PSScriptRoot 'SbWinUi.csproj')`" -nologo >> `"$buildLog`" 2>&1"
if ($LASTEXITCODE -ne 0) { Out-Line "E2E-CERT v1 item=$item verdict=NOT RUN -- the shell did not build (dotnet exit $LASTEXITCODE; see $buildLog)"; exit 2 }

foreach ($p in @($probe, $probeDoc, $receipt, $shot)) { Remove-Item $p -ErrorAction SilentlyContinue }
$mark = if (Test-Path $log) { (Get-Item $log).Length } else { 0 }

# ---- launch, holding, with the probe on ------------------------------------
$env:SB_PROBE = 'sb-probe.json'
# The script's tool, by NAME: the shell resolves it against the core's list and
# refuses an unknown one by name (`ToolKnob.Resolve`). Selection is the shell's
# default, so the selection script launches exactly as it always has.
$isSelection = $tool -eq 'selection'
if (-not $isSelection) { $env:SB_TOOL = $tool }
# The launcher runs in the BACKGROUND and the log is watched HERE: its own wait
# is 90 s whatever happens, and a dead window must fail in seconds, not then.
$stayOut = Join-Path $exeDir 'sb-e2e-stay.txt'
$launcher = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -RedirectStandardOutput $stayOut `
    -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'sitting.ps1'), '-Stay', '-Scene', 'app', '-NoRebuild') + $svgArgs)
$exePath = (Join-Path $exeDir 'SbWinUi.exe')
function Stop-OurApps {
    # Only THIS tree's executable, found by path: never another tree's, never a person's.
    Get-CimInstance Win32_Process -Filter "Name='SbWinUi.exe'" | Where-Object { $_.ExecutablePath -eq $exePath } |
        ForEach-Object { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'sitting.ps1') -Stop ([int]$_.ProcessId) *> $null }
}
$up = Wait-SbRow -Log $log -Mark $mark -Patterns @('RUSTOK APP pid=', 'RUSTFAIL ') -TimeoutSeconds $TimeoutSeconds
Remove-Item Env:\SB_PROBE
Remove-Item Env:\SB_TOOL -ErrorAction SilentlyContinue
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
                " -ProcessId $appPid -DocX $docX -DocY $docY -DocDx $dx -DocDy $dy -Moves $moves -Shift $shiftMode -Alt $altMode -Keys `"$keyText`" -Panels `"$panelText`"" +
                " -Out `"$receipt`" -TargetOffsetXDips $offX -TargetOffsetYDips $offY")
    $principal = New-ScheduledTaskPrincipal -UserId (Get-SbUid) -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $tasks[0] -Principal $principal -Force `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $handArg) | Out-Null
    Start-ScheduledTask -TaskName $tasks[0]

    # ---- the shell's own reading, written after the release lands -----------
    # The shell probes after the release, after each key (flask section 333) and
    # after each panel step (jas section 373), so the reading that describes the
    # script's end is probe 1 + keys + panel steps.
    $wantSeq = 1 + $keyCount + $lateCount
    # A panel step the hand REFUSES (an id not found, found twice, a disabled
    # control, no pattern for the event) is written to its receipt and nothing
    # more is sent, so no probe will come: the wait ends on the receipt too.
    $handSw = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        $pr = Wait-SbRow -Log $log -Mark $mark -Patterns @("PROBE seq=$wantSeq ", 'RUSTFAIL ') -TimeoutSeconds 1
        $handRefused = if ($null -eq $pr.Row -and (Test-Path $receipt)) {
            @(Get-Content $receipt | Where-Object { $_ -like 'PANEL REFUSED:*' }) | Select-Object -First 1
        }
    } while ($null -eq $pr.Row -and $null -eq $handRefused -and $handSw.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    if ($null -ne $handRefused) {
        Out-Line "E2E-CERT v1 item=$item verdict=NOT RUN -- the hand refused a panel or menu step: $($handRefused.Trim())"
        exit 4
    }
    if ($null -ne $pr.Row -and $pr.Row -match 'RUSTFAIL ') {
        Out-Line "E2E-CERT v1 item=$item verdict=NOT RUN -- the shell failed during the drive: $($pr.Row.Trim())"
        exit 4
    }
    if ($null -eq $pr.Row -or -not (Test-Path $probe)) {
        Out-Line "E2E-CERT v1 item=$item verdict=NOT RUN -- no PROBE seq=$wantSeq row within $($pr.Waited)s (did the hand press$(if ($keyCount -gt 0) { ', and did the shell see its keys' })? receipt: $(if (Test-Path $receipt) { Get-Content $receipt -Raw } else { 'none' }))"
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

# ---- the INPUT SCRIPT's read-back, byte for byte (docs/TESTING.md section 6) --
$got = if (Test-Path $probeDoc) { [System.IO.File]::ReadAllText($probeDoc, [System.Text.Encoding]::UTF8) } else { '' }
$readback = Compare-SbReadBack -Got $got -Want ([System.IO.File]::ReadAllText($expectedPath, [System.Text.Encoding]::UTF8))

# ---- DRIVE INTEGRITY: did the shell receive exactly the gesture we sent? --
# A real mouse moving during the run interleaves with the injected one, and the
# shell then applies a different gesture than was asked (measured 2026-10-10:
# move=212 against k=7, the line moved by (-72,2) instead of (37,23)). A run
# whose drive cannot be accounted for proves nothing and is never certified.
# THE GESTURE IS THE FIRST `POINTER REAL` ROW, NOT THE LAST: a late click
# (node 29) writes a row of its own after it, and `Select-SbRow` returns the
# last match. Each later row must be one late click: no move, and offset from
# the gesture's press by exactly the script's offset.
$ptrRows = @(Select-SbRows (Read-SbRows $log $mark) 'POINTER REAL ')
$ptr = if ($ptrRows.Count -gt 0) { $ptrRows[0] } else { $null }
$drive = 'UNREADABLE(no POINTER REAL row)'
if ($null -ne $ptr -and $ptrRows.Count -ne 1 + $clickCount) {
    $drive = "DISTURBED(pointer-rows=$($ptrRows.Count) want=$(1 + $clickCount): one for the gesture and one per late click)"
    $ptr = $null
}
if ($null -ne $ptr) {
    $mv = Get-SbField $ptr 'move'; $sc = [double](Get-SbField $ptr 'scale')
    $pa = (Get-SbField $ptr 'press@') -replace '[()]', '' -split ','
    $ra = (Get-SbField $ptr 'release@') -replace '[()]', '' -split ','
    $ddx = ([double]$ra[0] - [double]$pa[0]) / $sc; $ddy = ([double]$ra[1] - [double]$pa[1]) / $sc
    $tol = 1.0 / $sc
    if ([int]$mv -ne $moves -or [math]::Abs($ddx - $dx) -gt $tol -or [math]::Abs($ddy - $dy) -gt $tol) {
        $drive = "DISTURBED(move=$mv want=$moves delta=($([math]::Round($ddx,2)),$([math]::Round($ddy,2))) want=($dx,$dy))"
    } else { $drive = "PASS(move=$mv delta=($([math]::Round($ddx,2)),$([math]::Round($ddy,2))))" }
    for ($ci = 0; $ci -lt $clickCount -and $drive -like 'PASS*'; $ci++) {
        $crow = $ptrRows[1 + $ci]; $cp = $clickPoints[$ci]
        $cpa = (Get-SbField $crow 'press@') -replace '[()]', '' -split ','
        $cra = (Get-SbField $crow 'release@') -replace '[()]', '' -split ','
        $ox = ([double]$cpa[0] - [double]$pa[0]) / $sc; $oy = ([double]$cpa[1] - [double]$pa[1]) / $sc
        $wx = [double]$cp.x - $docX; $wy = [double]$cp.y - $docY
        $still = [math]::Abs([double]$cra[0] - [double]$cpa[0]) -le 1.0 -and [math]::Abs([double]$cra[1] - [double]$cpa[1]) -le 1.0
        if ([int](Get-SbField $crow 'move') -ne 0 -or -not $still -or [math]::Abs($ox - $wx) -gt $tol -or [math]::Abs($oy - $wy) -gt $tol) {
            $drive = "DISTURBED(click $($ci + 1) move=$(Get-SbField $crow 'move') offset=($([math]::Round($ox,2)),$([math]::Round($oy,2))) want=($wx,$wy))"
        }
    }
    if ($clickCount -gt 0 -and $drive -like 'PASS*') { $drive = $drive -replace '\)$', " clicks=$clickCount)" }
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
# A HELD SHIFT IS READ FROM THE HAND'S OWN RECEIPT: the shell's POINTER row does
# not carry modifiers, so the hand saying it put shift down and lifted it after
# the release is the drive's evidence; the read-back is the arrival's.
$shiftTag = ''
if ($shiftMode -ne 'none') {
    # The hand writes its receipt AFTER the release that triggers the probe, so
    # wait (bounded) for it rather than read a file that may not exist yet.
    $hr = ''
    for ($w = 0; $w -lt 50 -and -not $hr.Contains('shift-up='); $w++) {
        if (Test-Path $receipt) { $hr = [string](Get-Content $receipt -Raw -Encoding UTF8) }
        if (-not $hr.Contains('shift-up=')) { Start-Sleep -Milliseconds 100 }
    }
    $want = "shift=$shiftMode shift-down=before-$shiftMode shift-up=after-release"
    $shiftTag = ",shift=$shiftMode"
    if (-not $hr.Contains($want) -and $drive -like 'PASS*') { $drive = "FAIL(the hand's receipt lacks '$want')" }
}
if ($altMode -ne 'none') {
    $hr = ''
    for ($w = 0; $w -lt 50 -and -not $hr.Contains('alt-up='); $w++) {
        if (Test-Path $receipt) { $hr = [string](Get-Content $receipt -Raw -Encoding UTF8) }
        if (-not $hr.Contains('alt-up=')) { Start-Sleep -Milliseconds 100 }
    }
    $want = "alt=$altMode alt-down=before-$altMode alt-up=after-release"
    $shiftTag += ",alt=$altMode"
    if (-not $hr.Contains($want) -and $drive -like 'PASS*') { $drive = "FAIL(the hand's receipt lacks '$want')" }
}
if ($drive -notlike 'PASS*') { $ddx = [double]::NaN; $ddy = [double]::NaN }
$openDoc = Join-Path $exeDir 'sb-doc-open.json'
# The moved-by-delta arm is a SECOND METHOD for a selection drag only: another
# tool's gesture draws or edits, and its whole claim is the read-back below.
# KEYS AFTER THE DRAG (flask section 333) change what the drag left (Delete
# removes it, Ctrl+Z puts it back), so the arm describes a moment the script
# has moved past: with keys, the read-back is the whole claim.
# An ALT drag copies (selection.yaml: alt_held at mousedown copies on the
# first move), so the selected path names the COPY, not the element that was
# under the press: the arm's before/after pairing does not hold either.
$dragOnly = $isSelection -and $keyCount -eq 0 -and $lateCount -eq 0 -and $altMode -eq 'none'
if (-not $isSelection) { $moved = "NOT APPLICABLE(tool=$($tool): the moved-by-delta arm is the selection tool's)" }
elseif ($altMode -ne 'none') { $moved = "NOT APPLICABLE(alt=$($altMode): an alt drag copies, so the selection names the copy and the read-back is the claim)" }
elseif ($keyCount -gt 0) { $moved = "NOT APPLICABLE(keys=$($keyText): the moved-by-delta arm describes the drag, and the keys after it change the document)" }
elseif ($lateCount -gt 0) { $moved = "NOT APPLICABLE(panels=$($panelShow): the moved-by-delta arm describes the drag, and the panel or menu steps after it change the document)" }
elseif ($selCount -eq 1 -and (Test-Path $openDoc)) {
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
# docs/TESTING.md section 3: a certificate's key is SPEC HASH x BUILD SHA x PLATFORM,
# with the spec hash computed exactly as scripts/yaml_coverage_census.py does
# (sha256 of the compiled workspace/workspace.json, first 16 hex) and the build
# as git's short-8.
$specSha = (Get-FileHash (Join-Path $repo 'workspace\workspace.json') -Algorithm SHA256).Hash.Substring(0, 16).ToLower()
$build = (& git -C $repo rev-parse --short=8 HEAD).Trim()
$os = [System.Environment]::OSVersion.Version
$platform = "windows-winui-$($os.Major).$($os.Minor).$($os.Build)"
$dirty = if ((& git -C $repo status --porcelain -- jas_dioxus/src prototypes/sb_winui | Measure-Object -Line).Lines -gt 0) { '+dirty' } else { '' }
# No `doc_sha`: since #461 the open adds an artboard with a freshly minted id,
# so the document's digest differs on every run (flask STATUS 325: ten runs,
# ten values), and the read-back above already compares the same document,
# byte for byte, against the corpus. A recorded field that moves on every
# re-freeze and is compared nowhere only trains a reviewer to skim the diff.
# `probe.json` is the shell's raw probe and still carries it.
$reading = [ordered]@{
    item = $item; surface = $r.surface; frame_hash = $r.frame_hash
    plan_panel = $r.plan_panel; plan_sha = $r.plan_sha; tab = $r.tab; tab_sha = $r.tab_sha; selection_count = $selCount
}

# The paint arm (harness_common.ps1 Get-SbPaintVerdict): a refused repaint
# leaves the PREVIOUS frame on screen, so this run's frame hash would be a
# picture of an earlier state. Read from this run's own rows, frozen or not.
$paint = Get-SbPaintVerdict (Read-SbRows $log $mark)

if ($Freeze) {
    if ($drive -notlike 'PASS*' -or ($dragOnly -and $moved -notlike 'PASS*') -or $readback -notlike 'PASS*' -or $paint -notlike 'PASS*') {
        Out-Line "E2E-FROZEN v1 item=$item REFUSED -- a baseline is frozen only from a clean run: drive=$drive spec=$moved readback=$readback paint=$paint"
        exit 7
    }
    if ($r.tab_sha -eq 'UNREADABLE') {
        Out-Line "E2E-FROZEN v1 item=$item REFUSED -- the canvas strip was open and its plan did not parse (tab=UNREADABLE); a baseline is never frozen from an unread strip"
        exit 7
    }
    New-Item -ItemType Directory -Force -Path $Baseline | Out-Null
    ($reading | ConvertTo-Json) | Set-Content -Path (Join-Path $Baseline 'baseline.json') -Encoding ascii
    Copy-Item $probe (Join-Path $Baseline 'probe.json') -Force
    # NEVER copy the screenshot into the baseline: it is a FULL-DESKTOP capture
    # of the person's screen (other windows, URLs) and the baseline is
    # committed to a public repo. It stays in bin/ (git-ignored); the
    # certificate carries its hash only.
    Out-Line "E2E-FROZEN v1 item=$item commit=$commit$dirty drive=$drive spec=$moved readback=$readback paint=$paint surface=$($r.surface) frame=$($r.frame_hash) plan-sha=$($r.plan_sha) tab-sha=$($r.tab_sha) selection=$selCount screenshot=$shotSha -> $Baseline"
    exit 0
}

$bfile = Join-Path $Baseline 'baseline.json'
if (-not (Test-Path $bfile)) { Out-Line "E2E-CERT v1 item=$item verdict=NOT RUN -- no frozen baseline at $bfile (run with -Freeze, then review it)"; exit 6 }
$b = Get-Content $bfile -Raw | ConvertFrom-Json

# The spec's own observable, independent of any baseline: one element selected.
$core = if ($dragOnly) {
    if ($moved -like 'PASS*' -and $selCount -eq 1 -and $readback -like 'PASS*') { 'PASS' } else { "FAIL(selection=$selCount readback=$readback)" }
} else {
    if ($readback -like 'PASS*') { 'PASS' } else { "FAIL(readback=$readback)" }
}
# A baseline frozen before the tab was read has no `tab_sha`: that is a FAIL
# naming the re-freeze, never a pass on the half of `tree` it does hold.
$planOk = $r.plan_panel -eq $b.plan_panel -and $r.plan_sha -eq $b.plan_sha
$tabOk  = $null -ne $b.tab_sha -and $r.tab_sha -ne 'UNREADABLE' -and $r.tab_sha -eq $b.tab_sha
$tree = if ($planOk -and $tabOk) { 'PASS' }
        elseif (-not $planOk) { "FAIL(plan=$($r.plan_panel)/$($r.plan_sha) want=$($b.plan_panel)/$($b.plan_sha))" }
        elseif ($r.tab_sha -eq 'UNREADABLE') { "FAIL(tab=UNREADABLE: the strip was open and its plan did not parse)" }
        elseif ($null -eq $b.tab_sha) { "FAIL(tab=$($r.tab_sha) want=NONE-FROZEN: the baseline predates the tab reading; re-freeze)" }
        else { "FAIL(tab=$($r.tab_sha) want=$($b.tab_sha))" }
$pix  = if ($r.surface -ne $b.surface) { "NOT COMPARABLE(surface=$($r.surface) baseline=$($b.surface))" }
        elseif ($r.frame_hash -eq $b.frame_hash) { 'PASS' } else { "FAIL(frame=$($r.frame_hash) want=$($b.frame_hash))" }
# Each panel step must have reached the SHELL as a person's click: one
# `PANEL CLICK panel=<p> widget=<w> via=hand event=<e>` row per step, which only
# the control's own handler writes. The hand's `PANEL SENT` is evidence of
# sending, never of arrival.
if ($lateCount -gt 0 -and $drive -like 'PASS*') {
    $clickRows = @(Read-SbRows $log $mark | Where-Object { $_ -match 'PANEL CLICK panel=\S+ widget=\S+ via=hand ' -and $_ -notmatch 'PANEL CLICK (DROPPED|REFUSED)' })
    # A menu step's arrival is the shell's `MENU ACTION RAN item=<id>` row.
    $menuRows = @(Read-SbRows $log $mark | Where-Object { $_ -match 'MENU ACTION RAN item=' })
    # A late click (node 29) is not a panel step: its arrival is its own
    # POINTER REAL row, which the drive check above already holds to the script.
    $missing = @(ConvertFrom-SbPanelText $panelText | Where-Object { -not $_.click } | Where-Object {
        if ($_.menu) { $want = "MENU ACTION RAN item=$($_.menu) "; @($menuRows | Where-Object { $_.Contains($want) }).Count -eq 0 }
        else {
            $want = "PANEL CLICK panel=$($_.panel) widget=$($_.widget) via=hand event=$($_.event) "
            @($clickRows | Where-Object { $_.Contains($want) }).Count -eq 0 } } |
        ForEach-Object { if ($_.menu) { "menu:$($_.menu)" } else { "$($_.panel)/$($_.widget)" } })
    if ($missing.Count -gt 0) { $drive = "FAIL(no shell PANEL CLICK or MENU ACTION RAN row for $($missing -join ','))" }
}
$verdict = if ($drive -like 'PASS*' -and $core -eq 'PASS' -and $tree -eq 'PASS' -and $pix -eq 'PASS' -and $paint -like 'PASS*') { 'CERTIFIED' } else { 'NOT CERTIFIED' }
$line = "E2E-CERT v1 spec=$specSha build=$build$dirty platform=$platform item=$item drive=SendInput(session=1,pid=$appPid,moves=$moves$shiftTag$(if ($keyCount -gt 0) { ",keys=$keyText" })$(if ($lateCount -gt 0) { ",panels=$panelShow" })):$drive " +
        "spec=$moved script=$Script readback=$readback core=$core tree=$tree pixels=$pix@$($r.surface) paint=$paint screenshot=$shotSha(archived,not compared) " +
        "foreign-input=$(if ($drive -like 'PASS*') { 'none-reached-the-gesture' } else { 'DETECTED-or-unreadable' }) verdict=$verdict date=$((Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'))"
Out-Line $line
Add-Content -Path (Join-Path $exeDir 'e2e-certificates.log') -Value $line -Encoding ascii
if ($verdict -ne 'CERTIFIED') { exit 1 }
exit 0
