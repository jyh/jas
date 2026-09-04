# verify_window.ps1 -- drive ONE scene of the S-B shell in session 1, wait for
# the row that scene writes, and assert the canvas freeze's observables against
# the rows it produced.
#
# WRITTEN BEFORE THE APP, and the reason is this seat's own finding: a windowed
# app launched from the session-0 agent shell gets a window created at the right
# size and SILENTLY NEVER SHOWN -- no error, no log line. So "it built and exited
# 0" proves nothing, and neither does `MainWindowHandle`, which reads 0 from
# session 0 for a rendering app and a blank one alike.
#
# THE ORACLE MUST ASSERT A VALUE ONLY THE THING ACTUALLY RUNNING CAN PRODUCE --
# the window's TITLE observed from session 1, the pixels of a composed capture,
# and (since the canvas freeze) THE SHELL'S OWN RECEIPT ROWS in `sb-runs.log`.
#
# ============================================================================
# WHAT CHANGED IN THIS HARNESS, AND WHY EACH CHANGE IS A DEFECT REPAIR
# ============================================================================
#
# 1. PID-SCOPED TEARDOWN. The old teardown was
#        Get-Process -Name SbWinUi | Stop-Process -Force
#    which kills EVERY instance on the desktop -- including a `-Stay` instance an
#    operator deliberately left up. O5 (run-and-stay) died under its own harness
#    because of it. Now the launched process is IDENTIFIED BY DIFFERENCE against
#    the set that was already running, killed BY PID, and a pid that is already
#    gone is REFUSED rather than reported as a clean exit.
#
# 2. SCENE-AWARE WAITS. The old script slept a fixed 8 s twice and 12 s once.
#    O3's stall is 20 s long, so a fixed 8 s wait tore the window down MID-STALL
#    and the row the oracle reads was never written. Every wait here is on the
#    scene's OWN completion row, bounded, and a timeout is `NOT RUN: timed out
#    waiting for <row>` BY NAME -- never a pass, and never a silent short read.
#
# 3. THE ASSERTIONS. Every observable the freeze names is asserted here against
#    the rows, each printing PASS / FAIL / NOT RUN BY NAME together with the row
#    it read. An assertion that cannot run says why; it never passes by default.
#
# 4. `-DryRun` (alias `-WhatIf`). Resolves every knob, prints the plan -- the
#    scene, the completion row, the timeout, the forwarded environment, the
#    hand's chosen point -- and launches NOTHING. The box is expensive; a plan
#    that can be read before it is spent is cheaper than a run that measured the
#    wrong thing.
#
# ⛔ WHAT THIS FILE CANNOT DO IS DECIDE WHETHER AN ASSERTION PASSED WITHOUT THE
# BOX. Nothing below has been executed: it was written on a Mac with no
# PowerShell and no Windows desktop. The CI gate on it parses it; only kenai
# measures it.

param(
    # The window title to require (exact substring match). `| RUSTOK` in the
    # title is what turns "a window exists" into "the Rust half succeeded".
    [Parameter(Mandatory = $true)][string]$Title,
    # The app to launch through the interactive scheduled task. MUST be
    # absolute (a scheduled task's working directory is not the caller's);
    # resolved and refused below rather than remembered.
    [Parameter(Mandatory = $true)][string]$Exe,
    # How long to wait for the CAPTURE tasks' artifacts. It is no longer a
    # settle for the app -- that is the scene's completion row now.
    [int]$Seconds = 12,
    # "r,g,b" values that must appear in the capture.
    [string[]]$ExpectColor = @(),

    # ---- the canvas freeze's parameters -----------------------------------
    # Which scene is being driven. Decides the completion row and the timeout.
    # Empty means "read SB_SCENE", and an empty SB_SCENE means `benchmark`,
    # which is exactly what the shell itself does.
    [string]$Scene = '',
    # Override the derived timeout, in seconds. 0 = derive it.
    [int]$TimeoutSeconds = 0,
    # O2's "before". A number in ms, or a path to a file whose first number is
    # the ms figure. UNSUPPLIED PRINTS "before: not supplied" -- the N0b figure
    # (363 ms at 984x526) is NOT hardcoded here, because a hardcoded before is a
    # number nobody re-measures and every comparison inherits it silently.
    [string]$Before = '',
    # Drive O4's session-1 hand after the scene's before-dump appears.
    [switch]$Hand,
    # k, VARIED. O4 asks for 2, then 7.
    [int]$HandMoves = 2,
    # Aim the hand at EMPTY canvas -- O4's negative control. The expected row is
    # `press=1 move>=1 release=1 selected=0` WITH `doc=HELD`; the zero proves the
    # MISS only because `doc=HELD` proves the subject was loaded.
    [switch]$HandEmpty,
    # The drag, in DOCUMENT units (DIPs). Deliberately not axis-aligned and
    # deliberately not round, so a coalesced or zeroed move is legible.
    [string]$HandDelta = '37,23',
    # Set SB_SYNTH_DRAG from an EXISTING `sb-doc-before.json` before launching --
    # the seam's positive control, with the SAME harness-chosen element and delta
    # the hand would have used.
    [switch]$SynthFromDump,
    # Physical pixels per DIP. 0 = read the last `scale=` the log has ever
    # carried; 1.0 if the log has none, and the plan says which it used.
    [double]$Scale = 0,
    # O1's probe-colour arm needs a POSITIVE half: a DXGI capture of a frame that
    # DOES contain PROBE_FG. Without it the absence arm is vacuous and says so.
    [string]$ProbeCapture = '',
    # Do not kill the app at teardown (used by `sitting.ps1 -Stay`).
    [switch]$NoKill,
    # Print the plan and launch nothing.
    [Alias('WhatIf')][switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')

$tools = "$env:LOCALAPPDATA\jas-tools"

$Exe = Resolve-SbExe $Exe
if (-not (Test-Path $Exe)) {
    Write-Output "  FAIL: -Exe does not exist: $Exe"
    Write-Output "VERIFY: FAIL"
    exit 1
}
$scratch = Split-Path $Exe -Parent
$png = Join-Path $scratch "sb-verify.png"
$log = Get-SbLogPath $Exe
$procName = Get-SbProcessName $Exe
$launchTask = "jas-sb-app"
$capTask = "jas-sb-capture"
$handTask = "jas-sb-hand"
$dupTask = "jas-sb-capture-dxgi"

# ---------------------------------------------------------------------------
# THE SCENES, AND THE ROW EACH ONE FINISHES WITH
# ---------------------------------------------------------------------------
#
# ⛔ THIS TABLE IS THE REPLACEMENT FOR THE FIXED SLEEPS, AND IT IS THE WHOLE
# REPAIR. A sleep asks "has enough time passed"; a row asks "has the thing I am
# measuring happened". The two differ exactly when the answer matters -- O3's
# 20 s stall against an 8 s sleep.
#
# `Done` entries are matched as regular expressions against rows written SINCE
# this run's mark. The leading tab is `Report`'s own separator, and it is there so
# `A'` cannot be matched inside some other row's prose.
$sceneSpec = @{
    'retained' = @{
        Done    = @("`tA' surface=")
        Label   = "the A' hash row (the round trip's H2)"
        Timeout = 150
    }
    'benchmark' = @{
        Done    = @("RUSTOK BENCHMARK frames=", "RUSTFAIL BENCHMARK")
        Label   = "the BENCHMARK row"
        Timeout = 150
    }
    'document' = @{
        Done    = @("RUSTOK DOCUMENT '", "RUSTFAIL DOCUMENT")
        Label   = "the DOCUMENT control row"
        Timeout = 120
    }
    'goldens' = @{
        Done    = @("RUSTOK GOLDENS ", "GOLDENS FAILED")
        Label   = "the GOLDENS row"
        Timeout = 120
    }
    'selection-marquee' = @{
        Done    = @("RUSTOK SELECTION '", "RUSTFAIL SELECTION")
        Label   = "the SELECTION row"
        Timeout = 120
    }
    'stall' = @{
        Done    = @("`tSTALL render-stall=")
        Label   = "the STALL row (written by the POST-stall drain, not at the end of the sleep)"
        Timeout = 120
    }
    'pointer' = @{
        Done    = @("HAND CLOSED scene=", "NOT RUN: hand refused")
        Label   = "the HAND CLOSED row, or its named refusal"
        Timeout = 120
    }
    'stay' = @{
        Done    = @("RUSTOK STAY pid=")
        Label   = "the STAY pid row"
        Timeout = 120
    }
}

if ([string]::IsNullOrWhiteSpace($Scene)) { $Scene = $env:SB_SCENE }
if ([string]::IsNullOrWhiteSpace($Scene)) { $Scene = 'benchmark' }
if (-not $sceneSpec.ContainsKey($Scene)) {
    Write-Output "  REFUSED: scene '$Scene' is not one this harness knows how to wait for."
    Write-Output "           Known: $(($sceneSpec.Keys | Sort-Object) -join ', ')"
    Write-Output "           A scene with no completion row would be waited on by a SLEEP, which is"
    Write-Output "           the defect this table replaces. Add it here with the row it finishes on."
    Write-Output "VERIFY: FAIL"
    exit 1
}
$spec = $sceneSpec[$Scene]

# ⛔ AND THE RESOLVED SCENE GOES BACK INTO THE ENVIRONMENT, or this harness waits
# for one experiment while the app runs another. `-Scene` READ SB_SCENE above and
# never wrote it, so a direct `verify_window.ps1 -Scene retained` launched the app
# on its DEFAULT scene (benchmark) while every assertion here was written for
# `retained`: measured on kenai 2026-09-03, it produced 13 NOT RUN and one FAIL
# that read as findings about the app. `sitting.ps1` set it and so hid this.
# This is the defect Get-SbForwardedEnv's own header names -- a run LABELLED as
# one experiment while MEASURING another -- arriving through the one SB_* knob
# that was not taken from the environment in the first place.
$env:SB_SCENE = $Scene

# The stall and the hand wait are knobs, so the bound must be derived from them.
# A hardcoded 90 s would tear down a 120 s stall and read as an app failure.
function Get-KnobMs([string]$name) {
    $v = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($v)) { return 0 }
    $n = 0
    if ([int]::TryParse($v, [ref]$n)) { return $n }
    return 0
}
$knobSeconds = [int][math]::Ceiling(
    ((Get-KnobMs 'SB_RENDER_STALL_MS') + (Get-KnobMs 'SB_UI_STALL_MS') + (Get-KnobMs 'SB_POINTER_WAIT_MS')) / 1000.0)
$timeout = if ($TimeoutSeconds -gt 0) { $TimeoutSeconds } else { $spec.Timeout + $knobSeconds }

# ---------------------------------------------------------------------------
# THE VERDICT LEDGER
# ---------------------------------------------------------------------------
$verdicts = @()
$assertions = New-Object System.Collections.Generic.List[object]
$ok = $true
$inconclusive = $false

# ⛔ THREE VERDICTS, AND `NOT RUN` IS NOT ONE OF THE OTHER TWO. An assertion that
# could not be evaluated is not a pass (that is how a gate with no failure mode
# is born) and not a failure (that would make an absent precondition look like a
# broken app). It is recorded by name, with its reason, and the summary counts it
# separately.
function Add-Assert {
    param([string]$Name, [string]$Verdict, [string]$Detail, [string]$Row = '')
    $assertions.Add([pscustomobject]@{
        Name = $Name; Verdict = $Verdict; Detail = $Detail; Row = $Row
    })
}
function Add-NotRun {
    param([string]$Name, [string]$Reason, [string]$Row = '')
    Add-Assert -Name $Name -Verdict 'NOT RUN' -Detail $Reason -Row $Row
}

# ---------------------------------------------------------------------------
# THE DOCUMENT, AS THE HARNESS READS IT
# ---------------------------------------------------------------------------
#
# ⭐ THE DISCRIMINATOR LIVES HERE. O4's claim is not that a pointer arrived; it
# is that a pointer arrived AT A POINT THE SHELL COULD NOT HAVE COMPUTED. The
# point comes from `sb-doc-before.json`, which the shell WROTE and never reads
# back, so an element chosen from it is chosen outside the app entirely. A
# hardwired synthetic gesture cannot follow it, and that is the whole difference
# between this and the marquee it replaces.

function Get-SbFlatElements($node, [string]$path, $acc) {
    if ($null -eq $node) { return }
    # ⛔ SCALARS FIRST, AND `-isnot [psobject]` IS NOT THE TEST. Everything in
    # PowerShell is a PSObject, including a string and a double, so that spelling
    # excludes nothing and the walk would recurse into every leaf.
    if ($node -is [string] -or $node -is [bool] -or $node -is [valuetype]) { return }
    if ($node -is [System.Collections.IList]) {
        for ($i = 0; $i -lt $node.Count; $i++) {
            Get-SbFlatElements $node[$i] "$path[$i]" $acc
        }
        return
    }
    $props = @($node.PSObject.Properties | ForEach-Object { $_.Name })
    if ($props -contains 'type') {
        $acc.Add([pscustomobject]@{ Path = $path; Node = $node }) | Out-Null
    }
    foreach ($key in @('layers', 'children')) {
        if ($props -contains $key) {
            Get-SbFlatElements $node.$key "$path.$key" $acc
        }
    }
}

function Get-SbHitTarget([string]$JsonPath) {
    if (-not (Test-Path $JsonPath)) { return $null }
    $doc = Get-Content $JsonPath -Raw | ConvertFrom-Json
    $flat = New-Object System.Collections.Generic.List[object]
    Get-SbFlatElements $doc '$' $flat
    $cands = @()
    foreach ($e in $flat) {
        $n = $e.Node
        $props = @($n.PSObject.Properties | ForEach-Object { $_.Name })
        $t = [string]$n.type
        $hit = $null
        $area = 0.0
        if ($t -eq 'rect' -and ($props -contains 'x') -and ($props -contains 'width')) {
            $hit = @{ X = [double]$n.x + ([double]$n.width / 2.0); Y = [double]$n.y + ([double]$n.height / 2.0) }
            $area = [double]$n.width * [double]$n.height
        } elseif (($t -eq 'ellipse' -or $t -eq 'circle') -and ($props -contains 'cx')) {
            $rx = if ($props -contains 'rx') { [double]$n.rx } elseif ($props -contains 'r') { [double]$n.r } else { 0.0 }
            $ry = if ($props -contains 'ry') { [double]$n.ry } elseif ($props -contains 'r') { [double]$n.r } else { $rx }
            $hit = @{ X = [double]$n.cx; Y = [double]$n.cy }
            $area = 4.0 * $rx * $ry
        }
        if ($null -eq $hit) { continue }
        # FILLED FIRST. A stroke-only shape is a hairline at its centre: aiming
        # there would test the hit test rather than the pointer seam, and a miss
        # would be indistinguishable from an input failure.
        $filled = 0
        if (($props -contains 'fill') -and ($null -ne $n.fill)) { $filled = 1 }
        $id = if ($props -contains 'id') { [string]$n.id } else { '' }
        $cands += [pscustomobject]@{
            Path = $e.Path; Id = $id; Type = $t; Filled = $filled; Area = $area
            X = $hit.X; Y = $hit.Y; Node = $n
        }
    }
    if ($cands.Count -eq 0) { return $null }
    return @($cands | Sort-Object -Property @{Expression = 'Filled'; Descending = $true},
                                            @{Expression = 'Area'; Descending = $true},
                                            @{Expression = 'Path'; Descending = $false})[0]
}

# The furthest coordinate any element in the document reaches, so a point can be
# shown to be OUTSIDE the artwork rather than assumed to be. Returns $null when
# the document holds nothing with readable coordinates.
function Get-SbDocExtent([string]$JsonPath) {
    if (-not (Test-Path $JsonPath)) { return $null }
    $doc = Get-Content $JsonPath -Raw | ConvertFrom-Json
    $flat = New-Object System.Collections.Generic.List[object]
    Get-SbFlatElements $doc '$' $flat
    $maxX = $null
    $maxY = $null
    foreach ($e in $flat) {
        $n = $e.Node
        $props = @($n.PSObject.Properties | ForEach-Object { $_.Name })
        $xs = @()
        $ys = @()
        if (($props -contains 'x') -and ($props -contains 'width')) {
            $xs += ([double]$n.x + [double]$n.width); $ys += ([double]$n.y + [double]$n.height)
        }
        if ($props -contains 'cx') {
            $r = if ($props -contains 'r') { [double]$n.r } elseif ($props -contains 'rx') { [double]$n.rx } else { 0.0 }
            $xs += ([double]$n.cx + $r); $ys += ([double]$n.cy + $r)
        }
        foreach ($pair in @(@('x1', 'y1'), @('x2', 'y2'))) {
            if ($props -contains $pair[0]) { $xs += [double]$n.($pair[0]); $ys += [double]$n.($pair[1]) }
        }
        foreach ($v in $xs) { if ($null -eq $maxX -or $v -gt $maxX) { $maxX = $v } }
        foreach ($v in $ys) { if ($null -eq $maxY -or $v -gt $maxY) { $maxY = $v } }
    }
    if ($null -eq $maxX) { return $null }
    return @{ MaxX = $maxX; MaxY = $maxY }
}

function Get-SbElementByPath([string]$JsonPath, [string]$Path) {
    if (-not (Test-Path $JsonPath)) { return $null }
    $doc = Get-Content $JsonPath -Raw | ConvertFrom-Json
    $flat = New-Object System.Collections.Generic.List[object]
    Get-SbFlatElements $doc '$' $flat
    foreach ($e in $flat) { if ($e.Path -eq $Path) { return $e.Node } }
    return $null
}

$handDx = 0.0
$handDy = 0.0
$deltaParts = @($HandDelta -split ',')
if ($deltaParts.Count -eq 2) {
    $handDx = [double]$deltaParts[0]
    $handDy = [double]$deltaParts[1]
} else {
    Write-Output "  REFUSED: -HandDelta '$HandDelta' is not 'dx,dy'"
    Write-Output "VERIFY: FAIL"
    exit 1
}

# THE SCALE. Physical = DIP * scale, and the shell reports `scale=` only on a row
# it has already written. So: the caller's value, else the last one this log has
# ever carried, else 1.0 -- and the plan SAYS which, because a silently assumed
# scale puts the gesture somewhere else and the miss looks like a seam failure.
$scaleSource = 'the -Scale parameter'
if ($Scale -le 0) {
    $histRow = Select-SbRow (Read-SbRows $log 0) 'scale=[0-9.]+'
    $histScale = Get-SbField $histRow 'scale'
    if ($null -ne $histScale) {
        $Scale = [double]$histScale
        $scaleSource = "the last scale= field in $([IO.Path]::GetFileName($log))"
    } else {
        $Scale = 1.0
        $scaleSource = 'ASSUMED 1.0 -- this log has never carried a scale= field'
    }
}

$beforeDump = Join-Path $scratch 'sb-doc-before.json'
$afterDump = Join-Path $scratch 'sb-doc-after.json'

# ---------------------------------------------------------------------------
# THE ENVIRONMENT, RESOLVED ONCE
# ---------------------------------------------------------------------------
# ⛔ THE CHOSEN POINT AND DELTA ARE DECLARED HERE, ABOVE BOTH ARMS THAT SET THEM.
# The synthetic arm chooses BEFORE launch (the knob must be set for the shell to
# read it) and the hand arm chooses DURING the run (from the dump this run
# writes). If these were initialised between the two, the synthetic arm's choice
# would be erased and every coordinate assertion in the SEAM CONTROL would read
# `NOT RUN: this harness did not choose the delta` -- a control that measures
# nothing while reporting that it was run.
$handTarget = $null
$handAsked = $null

$synthNote = ''
if ($SynthFromDump) {
    $t = Get-SbHitTarget $beforeDump
    if ($null -eq $t) {
        # ⛔ A DRY RUN REPORTS THIS; A REAL RUN REFUSES. Exiting 1 from a plan that
        # was asked to launch nothing would print `VERIFY: FAIL` over an
        # experiment nobody attempted -- the mislabelling this harness exists to
        # avoid, arriving through the switch added to avoid it.
        $synthNote = "-SynthFromDump has no $([IO.Path]::GetFileName($beforeDump)) to choose from yet; run the hand arm (or -Scene pointer) once first"
        if (-not $DryRun) {
            Write-Output "  NOT RUN: $synthNote"
            Write-Output "VERIFY: FAIL"
            exit 1
        }
    } else {
        $env:SB_SYNTH_DRAG = ("{0},{1},{2},{3},{4}" -f
            [math]::Round($t.X * $Scale, 2), [math]::Round($t.Y * $Scale, 2),
            [math]::Round($handDx * $Scale, 2), [math]::Round($handDy * $Scale, 2), $HandMoves)
        # The SAME chosen element and the SAME delta the hand would have used --
        # which is what makes this the same oracle read through the other
        # provenance, rather than a second experiment wearing the name of a
        # control.
        $handTarget = $t
        $handAsked = @{ X = $t.X; Y = $t.Y; Dx = $handDx; Dy = $handDy; K = $HandMoves }
        $synthNote = "element $($t.Type) id='$($t.Id)' at doc ($($t.X),$($t.Y)) -> SB_SYNTH_DRAG=$env:SB_SYNTH_DRAG"
        Write-Host "synth-from-dump: $synthNote"
    }
}

# A knob whose VALUE contains a single quote cannot be forwarded through the
# generated command, and the refusal is named here rather than thrown: an
# unhandled throw exits with a stack trace and no `VERIFY:` line, which is the
# one output shape every caller of this script parses.
try {
    $fwd = Get-SbForwardedEnv
} catch {
    Write-Output "  REFUSED: $($_.Exception.Message)"
    Write-Output "VERIFY: FAIL"
    exit 2
}
if ($fwd.Names.Count -gt 0) { Write-Host "forwarding: $($fwd.Names -join ' ')" }
else { Write-Host "forwarding: (no SB_* variables set)" }

# ---------------------------------------------------------------------------
# -DryRun: THE PLAN, AND NOTHING IS SPENT
# ---------------------------------------------------------------------------
if ($DryRun) {
    Write-Output "== DRY RUN -- resolved plan, nothing launched =="
    Write-Output "  exe            : $Exe"
    Write-Output "  title required : $Title"
    Write-Output "  scene          : $Scene"
    Write-Output "  waits for      : $($spec.Label)"
    # ⛔ COMPUTED BEFORE THE STRING, NOT INSIDE IT. A double-quoted string nested
    # inside a `$()` inside another double-quoted string parses, and it parses
    # differently in enough hosts that it is not worth finding out which one this
    # box has.
    $patternText = (@($spec.Done | ForEach-Object { $_.Replace("`t", '<TAB>') }) -join '  |  ')
    Write-Output "  wait patterns  : $patternText"
    Write-Output "  timeout        : $($timeout)s  (base $($spec.Timeout)s + $($knobSeconds)s derived from SB_RENDER_STALL_MS/SB_UI_STALL_MS/SB_POINTER_WAIT_MS)"
    Write-Output "  log            : $log (mark: $(Get-SbLogMark $log) bytes)"
    Write-Output "  already up     : $(($(Get-SbAppPids $Exe) -join ', '))  <- left alive; the teardown is PID-scoped"
    Write-Output "  launch task    : $launchTask   capture: $capTask   dxgi: $dupTask   hand: $handTask"
    Write-Output "  scale          : $Scale  (from $scaleSource)"
    Write-Output "  forwarded env  : $(if ($fwd.Names.Count) { $fwd.Names -join ' ' } else { '(none)' })"
    Write-Output "  teardown       : $(if ($NoKill) { 'NONE (-NoKill): the launched process is LEFT RUNNING' } else { 'kill the launched pid ONLY; refuse if it is gone' })"
    Write-Output "  O2 before      : $(if ($Before) { $Before } else { 'not supplied' })"
    Write-Output "  probe capture  : $(if ($ProbeCapture) { $ProbeCapture } else { 'not supplied -- O1.7 will be NOT RUN' })"
    if ($SynthFromDump) { Write-Output "  synth drag     : $synthNote" }
    if ($Hand) {
        $t = Get-SbHitTarget $beforeDump
        Write-Output "  hand           : k=$HandMoves delta=($handDx,$handDy) DIP  empty-canvas=$([bool]$HandEmpty)"
        if ($null -ne $t) {
            Write-Output "                   element chosen from the EXISTING dump: $($t.Type) id='$($t.Id)' at doc ($($t.X),$($t.Y))"
            Write-Output "                   (the real run re-chooses from the dump THIS run writes)"
        } else {
            Write-Output "                   no $([IO.Path]::GetFileName($beforeDump)) on disk yet; the element is chosen from the one this run writes"
        }
    }
    Write-Output "  assertions     : the O1-O6 list for scene '$Scene' (see the PR body for each one's expected reading)"
    Write-Output "VERIFY: DRY RUN (nothing measured)"
    exit 0
}

# ---------------------------------------------------------------------------
# LAUNCH
# ---------------------------------------------------------------------------
Remove-SbTask $launchTask
Remove-SbTask $capTask
Remove-SbTask $handTask
Remove-SbTask $dupTask
Remove-Item $png, "$png.json", "$png.error.txt" -ErrorAction SilentlyContinue

# ⭐ O5's CONTROL, RECORDED BEFORE ANYTHING IS STARTED. Whatever is already
# running is NOT this run's subject and is NOT killed by it. The old name-sweep
# teardown could not tell the difference; this one cannot fail to.
$known = Get-SbAppPids $Exe
if ($known.Count -gt 0) {
    $verdicts += "ok  : $($known.Count) $procName process(es) already running (pid $($known -join ', ')) -- NOT this run's subject, and the PID-scoped teardown leaves them alive [O5.5]"
}

$logMark = Get-SbLogMark $log
New-SbLaunchTask -TaskName $launchTask -Exe $Exe -EnvPrefix $fwd.Prefix
$start = Start-SbAppTask -TaskName $launchTask -Exe $Exe -Known $known -TimeoutSeconds 60
$appPid = $start.Pid
if ($appPid -le 0) {
    $verdicts += "FAIL: $($start.Refusal)"
    $verdicts | ForEach-Object { Write-Output "  $_" }
    Remove-SbTask $launchTask
    Write-Output "VERIFY: FAIL"
    exit 1
}
$verdicts += "ok  : launched pid $appPid after $($start.Waited)s (identified by difference against the pids already running)"

# ---------------------------------------------------------------------------
# THE WAITS -- each on a row, each bounded, each refusing BY NAME
# ---------------------------------------------------------------------------

# O3's LIVENESS SAMPLER rides the scene's own wait, at t=2, 5 and 10 s. It is
# here and not in a sleep beside the run because `Responding` has to be read
# WHILE the stall is happening -- the whole claim is that the UI thread pumps
# while the render thread sleeps.
$respond = @{}
$sampler = {
    param($elapsed)
    foreach ($t in @(2, 5, 10)) {
        if ($elapsed -ge $t -and -not $respond.ContainsKey($t)) {
            $p = Get-Process -Id $appPid -ErrorAction SilentlyContinue
            $respond[$t] = if ($null -eq $p) { 'GONE' } else { [string]$p.Responding }
        }
    }
}

# ---- the DXGI eye, TIMED ON `FIRST-PRESENT` (O3's one gated row) -----------
$dxgiPng = Join-Path $scratch "sb-verify-dxgi.png"
$dxgiLog = "$dxgiPng.txt"
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$dupExe = Join-Path $repoRoot "jas_dioxus\target\debug\capture_desktop.exe"
$dxgiStarted = $false
$firstPresentRow = $null

function Start-SbDxgiCapture {
    # ⛔ A WRAPPER SCRIPT, NOT AN INLINE -Command. The first version passed the
    # exe, the PNG path and a `*>` redirect inside one -Command string; every one
    # needs its own layer of escaped quotes, and the result ran, wrote NOTHING and
    # reported NOTHING -- because the redirect that would have carried the error
    # was itself part of what was malformed.
    $dupWrap = Join-Path $scratch "run-dxgi-capture.ps1"
    @"
`$ErrorActionPreference = 'Continue'
try {
    `$out = & '$dupExe' '$dxgiPng' 2>&1
    `$rc = `$LASTEXITCODE
    "exit=`$rc session=`$((Get-Process -Id `$PID).SessionId)`n`$out" |
        Set-Content -Path '$dxgiLog' -Encoding utf8
} catch {
    `$_ | Out-String | Set-Content -Path '$dxgiLog' -Encoding utf8
}
"@ | Set-Content -Path $dupWrap -Encoding utf8
    $principal = New-ScheduledTaskPrincipal -UserId (Get-SbUid) -LogonType Interactive -RunLevel Limited
    $dupAction = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument ('-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "' + $dupWrap + '"')
    Register-ScheduledTask -TaskName $dupTask -Action $dupAction -Principal $principal -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $dupTask
}

Remove-Item $dxgiPng, $dxgiLog -ErrorAction SilentlyContinue
if (Test-Path $dupExe) {
    # The gate is ONE row: the first worker-thread present in `retained`. Waiting
    # for it is bounded and NON-FATAL -- every other scene's capture is a
    # demonstration, so a scene that emits no FIRST-PRESENT still gets its picture
    # taken, just not on that cue.
    if ($Scene -eq 'retained') {
        $fp = Wait-SbRow -Log $log -Mark $logMark -Patterns @("FIRST-PRESENT surface=") `
                         -TimeoutSeconds ([math]::Min($timeout, 90)) -Tick $sampler
        $firstPresentRow = $fp.Row
        if ($null -eq $firstPresentRow) {
            $verdicts += "note: no FIRST-PRESENT row within $($fp.Waited)s -- the DXGI capture below is untimed and is a demonstration, not O3's gate"
        } else {
            $verdicts += "ok  : FIRST-PRESENT seen after $($fp.Waited)s; the DXGI capture is taken ON that row [O3 gate]"
        }
    }
    Start-SbDxgiCapture
    $dxgiStarted = $true
} else {
    Write-Host "note: $dupExe not built; the DXGI eye is unavailable this run"
    Write-Host "      cargo build --no-default-features --features d2d,ffi --bin capture_desktop"
}

# ---- O4's hand: fire it when the shell has written the before-dump ---------
# `$handTarget` / `$handAsked` are NOT reset here: the synthetic arm may already
# have set them (see the declaration above), and this arm sets them itself.
$handReceipt = Join-Path $scratch 'sb-hand.txt'
if ($Hand) {
    Remove-Item $handReceipt -ErrorAction SilentlyContinue
    $dumpWait = Wait-SbRow -Log $log -Mark $logMark -Patterns @("DUMP sb-doc-before\.json bytes=") `
                           -TimeoutSeconds ([math]::Min($timeout, 90)) -Tick $sampler
    if ($null -eq $dumpWait.Row) {
        Add-NotRun 'O4 hand' "timed out after $($dumpWait.Waited)s waiting for the DUMP sb-doc-before.json row -- the harness never had a document to choose a point from"
    } else {
        $handTarget = Get-SbHitTarget $beforeDump
        if ($null -eq $handTarget) {
            Add-NotRun 'O4 hand' "sb-doc-before.json holds no element with readable coordinates -- the harness will not aim at a point it did not derive"
        } else {
            $aimX = $handTarget.X
            $aimY = $handTarget.Y
            if ($HandEmpty) {
                # THE EMPTY-CANVAS CONTROL. The point is derived from the OBSERVED
                # surface, never guessed -- and then CHECKED against the document's
                # own extent. "The far corner is empty" is true of this fixture at
                # this surface and would silently stop being true of a document
                # that filled the canvas; a control aimed at artwork reports
                # `selected=1` and reads as a broken negative control rather than
                # as a badly chosen point.
                $surfRow = Select-SbRow (Read-SbRows $log $logMark) 'surface=[0-9]+x[0-9]+'
                $surf = Get-SbField $surfRow 'surface'
                $extent = Get-SbDocExtent $beforeDump
                if ($null -eq $surf) {
                    Add-NotRun 'O4.C1 empty-canvas control' 'no row carrying a surface=WxH field yet -- the empty point is derived from the OBSERVED surface and is never guessed'
                    $handTarget = $null
                } else {
                    $sw2 = [double]($surf -split 'x')[0]
                    $sh2 = [double]($surf -split 'x')[1]
                    $aimX = ($sw2 / $Scale) - 40.0
                    $aimY = ($sh2 / $Scale) - 40.0
                    if ($null -eq $extent) {
                        Add-NotRun 'O4.C1 empty-canvas control' 'the document''s extent could not be read, so no point in it can be shown to be empty'
                        $handTarget = $null
                    } elseif ($aimX -le ($extent.MaxX + 10.0) -or $aimY -le ($extent.MaxY + 10.0)) {
                        Add-NotRun 'O4.C1 empty-canvas control' ("the derived point ({0},{1}) is not clear of the artwork (extent {2},{3} + 10 DIP margin) at surface $surf, scale $Scale -- refusing to aim a MISS control at a place that may hold an element" -f $aimX, $aimY, $extent.MaxX, $extent.MaxY)
                        $handTarget = $null
                    }
                }
            }
            if ($null -ne $handTarget) {
                $handAsked = @{ X = $aimX; Y = $aimY; Dx = $handDx; Dy = $handDy; K = $HandMoves }
                $handArg = ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'send_hand.ps1') + '"' +
                            " -ProcessId $appPid -DocX $aimX -DocY $aimY -DocDx $handDx -DocDy $handDy" +
                            " -Moves $HandMoves -Out `"$handReceipt`"")
                $principal = New-ScheduledTaskPrincipal -UserId (Get-SbUid) -LogonType Interactive -RunLevel Limited
                $handAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $handArg
                Register-ScheduledTask -TaskName $handTask -Action $handAction -Principal $principal -Force -ErrorAction Stop | Out-Null
                Start-ScheduledTask -TaskName $handTask
                $verdicts += "ok  : hand dispatched to session 1 -- pid $appPid, doc ($aimX,$aimY), delta ($handDx,$handDy), k=$HandMoves$(if ($HandEmpty) { ' [EMPTY-CANVAS CONTROL]' })"
            }
        }
    }
}

# ---- the scene's own completion row ---------------------------------------
$done = Wait-SbRow -Log $log -Mark $logMark -Patterns $spec.Done -TimeoutSeconds $timeout -Tick $sampler
$rows = $done.Rows
$sceneTimedOut = ($null -eq $done.Row)
if ($sceneTimedOut) {
    $verdicts += "FAIL: NOT RUN: timed out waiting for $($spec.Label) after $($done.Waited)s (scene '$Scene')"
    $ok = $false
} else {
    $verdicts += "ok  : scene '$Scene' completed after $($done.Waited)s -- $($spec.Label)"
}

# ---------------------------------------------------------------------------
# THE CAPTURES
# ---------------------------------------------------------------------------
# The GDI capture stays as the CONTROL: it carries the session id and the window
# list, so a disagreement between the two eyes is visible AS a disagreement
# rather than as a silent instrument swap.
#
# ⛔ AND THE CAMERAS MUST HIDE THEIR OWN CONSOLES -- the instrument was
# photographing itself.
$capArg = '-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $tools 'capture_desktop.ps1') + '" -Out "' + $png + '"'
$capPrincipal = New-ScheduledTaskPrincipal -UserId (Get-SbUid) -LogonType Interactive -RunLevel Limited
$capAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $capArg
Register-ScheduledTask -TaskName $capTask -Action $capAction -Principal $capPrincipal -Force -ErrorAction Stop | Out-Null
Start-ScheduledTask -TaskName $capTask
$capSw = [System.Diagnostics.Stopwatch]::StartNew()
while ($capSw.Elapsed.TotalSeconds -lt $Seconds -and -not (Test-Path "$png.json")) {
    Start-Sleep -Milliseconds 300
}

if ($dxgiStarted) {
    $dxSw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($dxSw.Elapsed.TotalSeconds -lt $Seconds -and -not (Test-Path $dxgiLog)) {
        Start-Sleep -Milliseconds 300
    }
    Remove-SbTask $dupTask
    # A SCENE-STAMPED COPY, so a later run can be handed THIS run's picture as its
    # positive control (`-ProbeCapture`). One overwritten file cannot be two arms.
    if (Test-Path $dxgiPng) {
        Copy-Item $dxgiPng (Join-Path $scratch "sb-verify-dxgi-$Scene.png") -Force -ErrorAction SilentlyContinue
    }
}

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

# WHICH EYE THE COLOUR ARM USES -- the DXGI capture when it exists, because it is
# the only one that can see a hardware-composed swapchain; the GDI one otherwise.
# The choice is REPORTED, never silent.
$colorPng = $png
$colorEye = "GDI (cannot see hardware-composed swapchains)"
if (Test-Path $dxgiPng) {
    $colorPng = $dxgiPng
    $colorEye = "DXGI Desktop Duplication"
} elseif (Test-Path $dxgiLog) {
    $verdicts += "note: the DXGI eye ran and produced no PNG -- $(Get-Content $dxgiLog -Raw)"
}

# Count the sampled pixels of each named colour in an image. ONE implementation,
# used by the ExpectColor arm and by O1's probe-colour arm, so the two cannot
# disagree about what "found" means.
function Measure-SbColors([string]$Path, [string[]]$Wanted, [int]$Step = 3) {
    $counts = @{}
    foreach ($c in $Wanted) { $counts[$c] = 0 }
    if (-not (Test-Path $Path)) { return $null }
    Add-Type -AssemblyName System.Drawing
    $b = [System.Drawing.Bitmap]::FromFile($Path)
    try {
        for ($y = 0; $y -lt $b.Height; $y += $Step) {
            for ($x = 0; $x -lt $b.Width; $x += $Step) {
                $p = $b.GetPixel($x, $y)
                $key = "$($p.R),$($p.G),$($p.B)"
                if ($counts.ContainsKey($key)) { $counts[$key]++ }
            }
        }
    } finally { $b.Dispose() }
    return $counts
}

if ($ExpectColor.Count -gt 0 -and (Test-Path $colorPng)) {
    $verdicts += "ok  : colour arm reading $([IO.Path]::GetFileName($colorPng)) via $colorEye"
    $want = Measure-SbColors $colorPng $ExpectColor
    $missing = @()
    foreach ($c in $ExpectColor) {
        if ($want[$c] -ge 50) { $verdicts += "ok  : probe colour $c found ($($want[$c]) sampled pixels)" }
        else { $missing += "$c ($($want[$c]))" }
    }
    if ($missing.Count -gt 0) {
        if ($colorPng -eq $dxgiPng) {
            # ⛔ UNDER THE DXGI EYE THIS IS A FAILURE, NOT AN AMBIGUITY. Desktop
            # Duplication reads the composed desktop, so "the camera cannot see
            # that surface" is no longer one of the two readings.
            $verdicts += "FAIL: colour(s) not found in the COMPOSED desktop: $($missing -join ', ')"
            $verdicts += "      This eye sees hardware-composed swapchains, so this is a"
            $verdicts += "      rendering result, not a capture limitation."
            $ok = $false
        } else {
            $verdicts += "INCONCLUSIVE: probe colour(s) not found: $($missing -join ', ')"
            $verdicts += "              either the core did not paint, OR a GDI screen copy"
            $verdicts += "              cannot see hardware-composed swapchain content."
            $inconclusive = $true
        }
    }
}

. (Join-Path $PSScriptRoot 'verify_assertions.ps1')

# ---------------------------------------------------------------------------
# TEARDOWN -- BY PID, AND ONLY THIS RUN'S PID
# ---------------------------------------------------------------------------
Remove-SbTask $handTask
if ($NoKill) {
    $verdicts += "ok  : -NoKill -- pid $appPid is LEFT RUNNING on the desktop (stop it with sitting.ps1 -Stop $appPid)"
} else {
    $stop = Stop-SbAppByPid -TargetPid $appPid -ExpectName $procName
    $verdicts += "      $($stop.Verdict)"
    if (-not $stop.Ok) { $ok = $false }
    $stillUp = @(Get-SbAppPids $Exe | Where-Object { $known -contains $_ })
    if ($known.Count -gt 0) {
        $verdicts += "ok  : $($stillUp.Count) of $($known.Count) pre-existing $procName process(es) survived this run's teardown [O5.5: a name sweep would have killed them]"
        if ($stillUp.Count -ne $known.Count) { $ok = $false }
    }
}
Remove-SbTask $launchTask
Remove-SbTask $capTask

# ---------------------------------------------------------------------------
# THE REPORT
# ---------------------------------------------------------------------------
$verdicts | ForEach-Object { Write-Output "  $_" }

$nPass = 0; $nFail = 0; $nNotRun = 0
if ($assertions.Count -gt 0) {
    Write-Output "  --- assertions (scene '$Scene') ---"
    foreach ($a in $assertions) {
        switch ($a.Verdict) {
            'PASS'    { $nPass++ }
            'FAIL'    { $nFail++ }
            default   { $nNotRun++ }
        }
        Write-Output ("  {0,-7} {1} -- {2}" -f $a.Verdict, $a.Name, $a.Detail)
        if ($a.Row) { Write-Output "          row: $($a.Row)" }
    }
    # THE TOTALS MUST CLOSE, same law as the sitting's summary.
    Write-Output ("  --- {0} PASS, {1} FAIL, {2} NOT RUN, of {3} ---" -f $nPass, $nFail, $nNotRun, $assertions.Count)
    if (($nPass + $nFail + $nNotRun) -ne $assertions.Count) {
        Write-Output "  |X| THE ASSERTION TOTALS DO NOT CLOSE -- this verdict is void."
        exit 3
    }
}
if ($nFail -gt 0) { $ok = $false }

if (-not $ok) { Write-Output "VERIFY: FAIL"; exit 1 }
if ($inconclusive) { Write-Output "VERIFY: WINDOW OK, PIXELS INCONCLUSIVE"; exit 2 }
if ($nNotRun -gt 0) {
    # ⛔ NOT A PASS. A run with an assertion that could not be evaluated has not
    # measured what it was asked to measure, and reporting it as a pass is how a
    # missing arm becomes an established green.
    Write-Output "VERIFY: INCOMPLETE ($nNotRun assertion(s) NOT RUN, none failed)"
    exit 6
}
Write-Output "VERIFY: PASS"
exit 0
