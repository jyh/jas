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
# ============================================================================
# WHAT THE FIRST RUN ON THE BOX CHANGED (PR #110's rows, 2026-09-03)
# ============================================================================
#
# The harness was executed for the first time and six of its own mechanisms were
# measured wrong. Every one below is a repair to THIS harness, not to the app:
#
# 5. THE LIVENESS ORACLE MOVED INTO SESSION 1 (`sample_liveness.ps1`). Reading
#    `Responding` from session 0 was proved VACUOUS by a positive control -- the
#    handle is always 0 across the boundary and `Responding` returns True when it
#    is. Every sample now carries its own precondition.
# 6. O2's BAND IS ONE FRAME, not `2 x present-mean` -- which asserted that paint
#    costs no more than present and redded in all four runs while the subject
#    improved 110-275x. It comes from the SAME SITTING's DIRECT benchmark run.
# 7. O6.4 IS TWO RUNS. One run cannot hold both arms: the probe moves the surface
#    permanently, so `A'` is never written and `surface(A) == surface(A')` cannot
#    hold. The arms travel between runs as receipts scoped to one sitting.
# 8. `-Scale` IS GONE. It reached nothing -- measured identical readings with and
#    without it. The scale is READ from the shell's rows and its source named.
# 9. O3.1 IS ASSERTED OVER ROWS THAT PAINTED, with the count printed. A `DUMP`
#    row carries the tid tail with `paint-tid=0`.
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
    # O2.3's "before". A number in ms, or a path to a file whose first number is
    # the ms figure. UNSUPPLIED PRINTS "before: not supplied" -- the N0b figure
    # (363 ms at 984x526) is NOT hardcoded here, because a hardcoded before is a
    # number nobody re-measures and every comparison inherits it silently.
    [string]$Before = '',
    # O2.2's BAND SOURCE: one benchmark frame, paint+present, in ms. A number, or
    # a path to a file whose first number is it. Normally UNSUPPLIED -- the
    # `benchmark` run of the SAME SITTING writes it to a receipt and this run
    # reads it from there, so the band is a figure this box produced today rather
    # than a constant. Supplying it by hand overrides the receipt and says so.
    [string]$BenchmarkFrameMs = '',
    # Drive O4's session-1 hand after the scene's before-dump appears.
    [switch]$Hand,
    # k, VARIED. O4 asks for 2, then 7.
    [int]$HandMoves = 2,
    # The injector's pause between steps, in ms, FORWARDED to `send_hand.ps1`
    # (whose own default is 40). 0 = leave the injector's default alone.
    #
    # ⛔ THIS IS THE KNOB `-Scale` WAS NOT. `-Scale` was removed in PR #115
    # because it reached nothing; this one reaches `send_hand.ps1 -SettleMs` and
    # its whole purpose is to SEPARATE TWO EXPLANATIONS of a defect that has now
    # survived two repair waves. Measured on kenai 2026-09-04: the real hand's
    # `move=` reads exactly k at k=2,3,4 and k+1 at k=5,6,7,8 -- and because the
    # injector pauses 40 ms per step, the k<=4 / k>=5 boundary is also the
    # 160 ms / 200 ms boundary in post-press DRAG DURATION. Step count and
    # elapsed time are perfectly confounded while this pause is fixed, and
    # varying it is the one arm that tells them apart: k=4 at 100 ms lasts
    # 400 ms with four steps, so a reading of 5 convicts TIME and a reading of 4
    # convicts the STEP COUNT.
    [int]$HandSettleMs = 0,
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
$liveTask = "jas-sb-liveness"

# The cross-run receipts (see `harness_common.ps1`): figures that belong to a
# DIFFERENT run of the SAME sitting, and are therefore outside this run's log
# window by construction.
$benchDirectReceipt = Join-Path $scratch 'sb-benchmark-frame-DIRECT.json'
$benchOffscreenReceipt = Join-Path $scratch 'sb-benchmark-frame-OFFSCREEN.json'
$o6SqueezeReceipt = Join-Path $scratch 'sb-o6-squeeze.json'
$o6ProbeReceipt = Join-Path $scratch 'sb-o6-probe.json'
$liveReceipt = Join-Path $scratch 'sb-liveness.txt'

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
    # ⛔ THE VERDICT PREFIX IS OPTIONAL IN THE PATTERN, AND THAT IS NOT
    # LOOSENESS. The shell wave in this PR puts `RUSTOK `/`RUSTFAIL ` in front of
    # every scene-COMPLETION row, because `Report` writes the last row into the
    # window title and the session-1 oracle requires `| RUSTOK` there -- three
    # successful runs were FAILED by it on kenai 2026-09-04. A pattern that
    # REQUIRED the prefix would stop matching a bisected build's rows, which is
    # the mirror defect of the one being repaired: this harness must read both
    # shells. The tab is still the anchor, so `A'` cannot match inside prose.
    'retained' = @{
        Done    = @((Get-SbRowPattern "A'" " surface="))
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
        Done    = @((Get-SbRowPattern 'STALL' ' render-stall='))
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
# THE DOCUMENT, AS THE HARNESS READS IT -- MOVED INTO `harness_common.ps1`
# ---------------------------------------------------------------------------
#
# ⛔ `Get-SbFlatElements`, `Get-SbHitTarget`, `Get-SbDocExtent` and
# `Get-SbElementByPath` now live in `harness_common.ps1`, WITH THE CHOOSER'S
# REPAIR, because they are pure functions over a parsed document and this file
# cannot be dot-sourced without a Windows desktop. The one mechanism of this
# harness that the box measured WRONG on 2026-09-04 -- the chooser aiming at the
# largest filled shape while the app selects the topmost one over that point --
# had no arm that could see it, and it could not have had one while it lived
# here. `harness_selftest.ps1` drives them now, in CI, with no app.
#
# The discriminator itself is unchanged and is still the point: the aim comes
# from `sb-doc-before.json`, which the shell WROTE and never reads back, so an
# element chosen from it is chosen outside the app entirely.

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

# THE SCALE. Physical = DIP * scale.
#
# ⛔ `-Scale` IS GONE, AND ITS REMOVAL IS A DEFECT REPAIR. It was measured on
# kenai 2026-09-03 (PR #110) to reach NOTHING: `send_hand.ps1` has no `-Scale`
# parameter and derives the factor solely from `GetDpiForWindow`, so
# `verify_window.ps1 -Scale 1.5` governed only the synthetic arm and the tolerance
# text -- a run driven with it produced readings identical to a run without it,
# down to the digit. A knob that appears in the plan, is echoed in the detail and
# changes no behaviour is worse than no knob: it invites the reader to believe the
# coordinate chain was corrected when it was not.
#
# The real chain is the SHELL's: an unpackaged WinUI 3 app with no application
# manifest is DPI-unaware, Windows bitmap-virtualises it, `GetDpiForWindow`
# honestly returns 96, and the gesture lands at 2/3 of the asked point on a 150%
# display. That is the shell wave's manifest to fix; it is not something a
# harness parameter can paper over.
#
# So the scale is READ, never supplied: the last `scale=` field THIS RUN has
# written, else the last one this log has ever carried, else 1.0 -- and the plan
# and every detail SAY which of the three, because a silently assumed scale puts
# the gesture somewhere else and the miss looks like a seam failure.
#
# ⛔ AND THE SELECTOR IS ANCHORED, WHICH IS NOT A STYLE POINT. Measured on kenai
# 2026-09-04: the shell wave's `STARTUP ... composition-scale=1.5x1.5` row
# satisfied the unanchored `scale=[0-9.]+` selector, the reader then pulled
# `1.5x1.5` out of the middle of that field, and the `[double]` cast below threw
# and killed the sitting at run 2 of 8 -- every run after the first, because the
# first run is what WROTE the row. The selector and the reader now share one
# definition of what a field is (`Get-SbFieldPattern`), so they cannot disagree
# about which rows carry a scale.
$scaleSource = ''
$scaleRowPattern = Get-SbFieldPattern 'scale' '[0-9.]+'
function Resolve-SbScale {
    param($RunRows)
    $row = $null
    if ($null -ne $RunRows -and @($RunRows).Count -gt 0) {
        $row = Select-SbRow $RunRows $scaleRowPattern
    }
    if ($null -ne $row) {
        return @{ Scale = [double](Get-SbField $row 'scale')
                  Source = "the last scale= field THIS RUN wrote" }
    }
    $histRow = Select-SbRow (Read-SbRows $log 0) $scaleRowPattern
    $histScale = Get-SbField $histRow 'scale'
    if ($null -ne $histScale) {
        return @{ Scale = [double]$histScale
                  Source = "the last scale= field in $([IO.Path]::GetFileName($log)) (an EARLIER run's; this run had written none when the point was chosen)" }
    }
    return @{ Scale = 1.0; Source = 'ASSUMED 1.0 -- this log has never carried a scale= field' }
}
$resolved = Resolve-SbScale $null
$Scale = $resolved.Scale
$scaleSource = $resolved.Source

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
    Write-Output "  scale          : $Scale  (from $scaleSource; -Scale no longer exists -- it reached nothing)"
    Write-Output "  sitting        : $(Get-SbSittingId)"
    Write-Output "  forwarded env  : $(if ($fwd.Names.Count) { $fwd.Names -join ' ' } else { '(none)' })"
    Write-Output "  teardown       : $(if ($NoKill) { 'NONE (-NoKill): the launched process is LEFT RUNNING' } else { 'kill the launched pid ONLY; refuse if it is gone' })"
    Write-Output "  O2.3 before    : $(if ($Before) { $Before } else { 'not supplied -- O2.3 will be NOT RUN' })"
    $benchPlan = if ($BenchmarkFrameMs) { "$BenchmarkFrameMs (supplied, overrides the receipt)" } else { (Read-SbReceipt $benchDirectReceipt 'benchmark-frame DIRECT').Reason }
    if (-not $BenchmarkFrameMs -and (Read-SbReceipt $benchDirectReceipt 'benchmark-frame DIRECT').Ok) {
        $bd = (Read-SbReceipt $benchDirectReceipt 'benchmark-frame DIRECT').Data
        $benchPlan = "$($bd.frame_ms) ms/frame at surface $($bd.surface) on route $($bd.route), from this sitting's benchmark run"
    }
    Write-Output "  O2.2 band src  : $benchPlan"
    if ($Scene -eq 'stall') {
        Write-Output "  liveness       : session-1 sampler '$liveTask' at t=2,5,10s, dispatched on the shell's own STALL ARMED row -> $([IO.Path]::GetFileName($liveReceipt))"
        Write-Output "                   (the session-0 Responding reading is kept as a NOTE only: it is VACUOUS across the session boundary)"
    }
    Write-Output "  probe capture  : $(if ($ProbeCapture) { $ProbeCapture } else { 'not supplied -- O1.7 will be NOT RUN' })"
    if ($SynthFromDump) { Write-Output "  synth drag     : $synthNote" }
    if ($Hand) {
        $t = Get-SbHitTarget $beforeDump
        Write-Output "  hand           : k=$HandMoves delta=($handDx,$handDy) DIP  empty-canvas=$([bool]$HandEmpty)  settle=$(if ($HandSettleMs -gt 0) { "$HandSettleMs ms (forwarded)" } else { "the injector's own default" })"
        if ($null -ne $t) {
            Write-Output "                   element chosen from the EXISTING dump: $($t.Type) id='$($t.Id)' at doc ($($t.X),$($t.Y))"
            Write-Output "                   aim: the centre of $($t.AimPath); target: $($t.Path)"
            Write-Output "                   rule: $($t.Rule)"
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
Remove-SbTask $liveTask
Remove-Item $png, "$png.json", "$png.error.txt" -ErrorAction SilentlyContinue
# ⛔ THE LIVENESS RECEIPT IS DELETED BEFORE THE RUN, NOT READ PAST. It is a FILE,
# not a log window, so a previous run's samples would be read as this run's --
# the exact defect the log's byte mark exists to prevent, arriving through the
# one reading that does not come from the log.
Remove-Item $liveReceipt -ErrorAction SilentlyContinue

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

# ⛔ THE SESSION-0 SAMPLER IS KEPT AND IS NO LONGER AN ORACLE. It rides the
# scene's own wait at t=2, 5 and 10 s exactly as before, and its readings are
# printed as a NOTE beside the session-1 ones -- because the two arms side by side
# ARE the evidence. Measured on kenai 2026-09-03 (PR #110): from session 0 a
# session-1 window's `MainWindowHandle` is always 0, and `Process.Responding`
# returns True whenever the handle is 0. The positive control was the reading
# shell itself, which has no window at all and also read True. So this arm returns
# True for a live app, a hung app and a windowless process alike, and NO assertion
# reads it any more.
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

# ---- O3's LIVENESS ORACLE, IN SESSION 1, ON THE SHELL'S OWN `STALL ARMED` ---
#
# ⭐ THIS IS THE REPAIR PR #110's ROWS ASKED FOR. The oracle moves into session 1
# through the SAME scheduled-task mechanism the launcher, the camera and the hand
# already use -- `send_hand.ps1` resolved this app's `hwnd` from session 1 on the
# same box on the same night, so the mechanism was never in question.
#
# ⛔ IT IS DISPATCHED ON A ROW, NOT ON A CLOCK. `STALL ARMED` is written by the
# scene immediately before the sleeps begin, so t=0 in the sampler is the top of
# the stall. Dispatching it at launch would sample the load, the paint and the
# first present and call them the stall.
$liveDispatched = $false
$liveArmedWait = $null
if ($Scene -eq 'stall') {
    $liveArmedWait = Wait-SbRow -Log $log -Mark $logMark -Patterns @('STALL ARMED render-stall=') `
                                -TimeoutSeconds ([math]::Min($timeout, 90)) -Tick $sampler
    if ($null -eq $liveArmedWait.Row) {
        $verdicts += "note: no STALL ARMED row within $($liveArmedWait.Waited)s -- the session-1 liveness sampler was NOT dispatched, and O3.3/O3.C1 will say so by name"
    } else {
        $liveArg = ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'sample_liveness.ps1') + '"' +
                    " -ProcessId $appPid -At 2,5,10 -Out `"$liveReceipt`"")
        $livePrincipal = New-ScheduledTaskPrincipal -UserId (Get-SbUid) -LogonType Interactive -RunLevel Limited
        $liveAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $liveArg
        Register-ScheduledTask -TaskName $liveTask -Action $liveAction -Principal $livePrincipal -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $liveTask
        $liveDispatched = $true
        $verdicts += "ok  : session-1 liveness sampler dispatched on the shell's own STALL ARMED row (after $($liveArmedWait.Waited)s) -- pid $appPid, t=2,5,10s [O3.3/O3.C1]"
        $verdicts += "      row: $($liveArmedWait.Row)"
    }
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
        # ⛔ THE SCALE IS RE-READ HERE, FROM THE ROWS THIS RUN HAS ALREADY
        # WRITTEN. Before launch there were none, so the pre-launch resolution
        # could only read history; by the time the before-dump exists the shell
        # has written rows of its own, and an empty-canvas point derived from an
        # EARLIER run's scale would be aimed with a number this run never
        # produced. The source is reported either way.
        $resolved = Resolve-SbScale $dumpWait.Rows
        $Scale = $resolved.Scale
        $scaleSource = $resolved.Source
        $verdicts += "ok  : scale $Scale for the hand's aim, from $scaleSource (there is no -Scale: it reached nothing, PR #110)"
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
                            " -Moves $HandMoves -Out `"$handReceipt`"" +
                            $(if ($HandSettleMs -gt 0) { " -SettleMs $HandSettleMs" } else { '' }))
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

# ---- the session-1 liveness samples, read back ----------------------------
#
# ⛔ READ AFTER THE SCENE'S WAIT, AND BOUNDED AGAIN. The sampler needs ~10 s and
# the scene normally outlives it, but a scene that TIMED OUT (PR #110 measured a
# UI-only stall writing no STALL row at all, so the run timed out at 140 s) must
# still be able to hand back its samples: the sampler is dispatched on STALL
# ARMED, so its evidence exists whether or not the completion row ever does.
$live = @{}
$liveText = 'not dispatched'
if ($liveDispatched) {
    $lw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($lw.Elapsed.TotalSeconds -lt 25) {
        if ((Test-Path $liveReceipt) -and ((Get-Content $liveReceipt -Raw) -match 'done samples=')) { break }
        Start-Sleep -Milliseconds 300
    }
    if (Test-Path $liveReceipt) {
        foreach ($l in (Get-Content $liveReceipt)) {
            $m = [regex]::Match($l, '^t=([0-9]+)s handle=(\S+) responding=(\S+)')
            if ($m.Success) {
                $live[[int]$m.Groups[1].Value] = @{ Handle = $m.Groups[2].Value; Responding = $m.Groups[3].Value }
            }
        }
        $liveText = ((Get-Content $liveReceipt) -join ' | ')
        $verdicts += "ok  : session-1 liveness receipt read -- $liveText"
    } else {
        $liveText = "the sampler was dispatched and wrote no receipt within $([math]::Round($lw.Elapsed.TotalSeconds,1))s"
        $verdicts += "note: $liveText"
    }
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
    # ⛔ THE RULE IS `| RUSTOK` IN THE TITLE AND IT DOES NOT MOVE. It read
    # FAIL on three successful runs (kenai 2026-09-04) because the scenes'
    # LAST rows carried no verdict; the repair is in the shell, not here. The
    # comparison is `Select-SbTitleMatch` so the self-test can drive the rule
    # itself rather than a copy of it.
    $hit = @(Select-SbTitleMatch $meta.windowsAtCap $Title)
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

# ---------------------------------------------------------------------------
# O2.2's BAND SOURCE -- ONE BENCHMARK FRAME, WRITTEN BY THE RUN THAT MEASURED IT
# ---------------------------------------------------------------------------
#
# ⭐ THE BAND IS RE-CUT, AND THE OLD ONE WAS MEASURING THE WRONG THING. The
# canvas freeze v3.1's ruling: `2 x present-mean` asserted that PAINT COSTS NO
# MORE THAN PRESENT, and on this hardware present is 0.29-1.20 ms against a paint
# of 1.0-4.3 ms, so it redded in all four runs of PR #110 while its subject
# improved 110-275x. A gate that reds while the thing it measures gets two orders
# of magnitude better is not a gate, it is a mislabelled constant.
#
# The claim O2 actually makes is that A RESIZE DRAIN COSTS ONE FRAME. So the band
# is ONE FRAME, measured by this box today: the `benchmark` scene's steady-state
# paint + present, on the SAME ROUTE and at the SAME SURFACE as the row being
# priced. `Repaint()` always paints the back buffer directly, so the comparable
# benchmark run is the DIRECT one (`SB_MODE=direct`); an OFFSCREEN+copy benchmark
# is written to its own file and NEVER silently substituted.
if ($Scene -eq 'benchmark') {
    $benchRow = Select-SbRow $rows 'BENCHMARK frames='
    if ($null -ne $benchRow) {
        $paintMean = Get-SbSteadyMean $benchRow 'paint'
        $presentMean = Get-SbSteadyMean $benchRow 'present'
        $route = if ($benchRow -match 'BENCHMARK frames=[0-9]+ (\S+) ') { $Matches[1] } else { 'UNKNOWN' }
        # ⛔ THE SURFACE IS READ AS A FIELD AND THE OLD LABEL IS REFUSED BY
        # NAME. `([0-9]+x[0-9]+)px` scraped the pre-repair label's doubly-scaled
        # half and returned `4287x2144` for a 2858x1429 surface on a 3840-wide
        # panel, so O2.2 refused on a mismatch that was a LABEL and not a
        # geometry. `Get-SbBenchmarkSurface` refuses the old shape rather than
        # reading its DIP half: a band priced off a row written by a different
        # shell is the wave-boundary defect, not a fallback.
        $bs = Get-SbBenchmarkSurface $benchRow
        $surfaceLabel = $bs.Surface
        if ($null -eq $paintMean -or $null -eq $presentMean -or -not $bs.Ok) {
            $why = if (-not $bs.Ok) { $bs.Reason } else { 'the row carried no readable paint/present steady-mean' }
            $verdicts += "note: NO band source was written for O2.2 -- $why"
        } else {
            $target = if ($route -eq 'DIRECT') { $benchDirectReceipt } else { $benchOffscreenReceipt }
            Write-SbReceipt -Path $target -Data @{
                frame_ms = [math]::Round($paintMean + $presentMean, 4)
                paint_mean_ms = $paintMean
                present_mean_ms = $presentMean
                route = $route
                surface = $surfaceLabel
                row = $benchRow
            }
            $verdicts += ("ok  : band source written -- one {0} frame = paint {1:N2} + present {2:N2} = {3:N2} ms at {4} -> {5} [O2.2]" -f
                          $route, $paintMean, $presentMean, ($paintMean + $presentMean), $surfaceLabel, [IO.Path]::GetFileName($target))
        }
    }
}

# The band source THIS run will price against: the caller's figure if one was
# supplied (and named as such), else this sitting's DIRECT benchmark receipt.
$benchFrame = $null
$benchFrameSource = ''
$benchFrameReason = ''
if (-not [string]::IsNullOrWhiteSpace($BenchmarkFrameMs)) {
    $bfv = $BenchmarkFrameMs
    if (Test-Path $BenchmarkFrameMs) {
        $rawB = Get-Content $BenchmarkFrameMs -Raw
        $mb = [regex]::Match($rawB, '([0-9]+(\.[0-9]+)?)')
        if ($mb.Success) { $bfv = $mb.Groups[1].Value }
    }
    $benchFrame = @{ FrameMs = [double]$bfv; Route = 'UNSTATED'; Surface = 'UNSTATED' }
    $benchFrameSource = "supplied via -BenchmarkFrameMs '$BenchmarkFrameMs' -- the route and the surface it was taken at are NOT carried by this parameter and must be checked by the reader"
} else {
    $br = Read-SbReceipt $benchDirectReceipt 'benchmark-frame DIRECT'
    if ($br.Ok) {
        $benchFrame = @{ FrameMs = [double]$br.Data.frame_ms; Route = [string]$br.Data.route; Surface = [string]$br.Data.surface }
        $benchFrameSource = "this sitting's benchmark run: one $($br.Data.route) frame = paint $($br.Data.paint_mean_ms) + present $($br.Data.present_mean_ms) ms at $($br.Data.surface)"
    } else {
        $benchFrameReason = $br.Reason
    }
}

. (Join-Path $PSScriptRoot 'verify_assertions.ps1')

# ---------------------------------------------------------------------------
# TEARDOWN -- BY PID, AND ONLY THIS RUN'S PID
# ---------------------------------------------------------------------------
Remove-SbTask $handTask
Remove-SbTask $liveTask
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
