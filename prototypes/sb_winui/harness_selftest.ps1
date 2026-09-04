# harness_selftest.ps1 -- exercise the harness's ROW READERS against real row
# text, with no app, no desktop and no Windows session.
#
# WHY THIS EXISTS.
#
# Every gate this harness had before today proved that its scripts PARSE. A
# parser is a statement about syntax; it has never read a row. Measured on kenai
# 2026-09-04 (the second harness run, on main f2da1654): the sitting died at run
# 2 of 8 because `Get-SbField <row> 'scale'` matched INSIDE the shell wave's new
# `composition-scale=1.5x1.5` field and returned `1.5x1.5`, which threw on the
# `[double]` cast. Seven scripts parsed. The gate was green. The sitting was
# dead from its second launch onward, and every run after it was lost.
#
# ⛔ THE READERS ARE PURE FUNCTIONS OVER STRINGS. That is the whole argument for
# this file: they need no window, no scheduled task and no session 1, so the one
# thing about this harness that CAN be tested without a desktop is exactly the
# thing that broke. It runs anywhere PowerShell runs, CI included.
#
# It asserts nothing about behaviour, about the app, or about any measurement.
# It is a test of PURE READERS over strings and over parsed documents, and it
# must never be read as more.
#
# ⭐ IT GREW A SECOND HALF ON THE SECOND SITTING'S RULINGS, and the reason is
# the same one twice. The chooser that picks the gesture's target was measured
# WRONG on the box -- it aimed at the largest filled shape while the app selects
# the topmost one over that point -- and it could not have had an arm, because it
# lived in `verify_window.ps1`, which cannot run without a Windows desktop. It
# lives in `harness_common.ps1` now, with the document readers around it, and
# the arms below drive it with no app, no window and no session.
#
#   powershell -File harness_selftest.ps1        # exit 0 = every case held

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')

$pass = 0
$fail = 0
$cases = @()

function Test-Case([string]$Name, [scriptblock]$Actual, $Expected) {
    # ⛔ A THROW IS A RESULT, NOT A CRASH. The defect this file was written for
    # was a THROW, so a case that dies must be recorded as a failing case and
    # the rest must still run -- otherwise the first regression hides every one
    # after it, which is precisely what happened to the sitting.
    $got = $null
    $threw = $null
    try { $got = & $Actual } catch { $threw = $_.Exception.Message }

    $ok = $false
    if ($null -ne $threw) { $ok = $false }
    elseif ($null -eq $Expected) { $ok = ($null -eq $got) }
    else { $ok = ("$got" -eq "$Expected") }

    if ($ok) {
        $script:pass++
        $script:cases += ("  ok  : {0} -- {1}" -f $Name, $(if ($null -eq $got) { '$null' } else { $got }))
    } else {
        $script:fail++
        $shown = if ($null -ne $threw) { "THREW: $threw" }
                 elseif ($null -eq $got) { '$null' }
                 else { $got }
        $script:cases += ("  FAIL: {0} -- expected '{1}', got {2}" -f
                          $Name, $(if ($null -eq $Expected) { '$null' } else { $Expected }), $shown)
    }
}

# ⛔ AND A FIXTURE LINE MUST NOT ABORT THE FILE EITHER. `Test-Case` catches a
# throw because "a throw is a result, not a crash" -- but the SCRIPT-LEVEL lines
# that BUILD the fixtures did not, and this file's own red-first run proved it:
# at the sha carrying these cases without their readers, the run died on
# `$aPrimePattern = Get-SbRowPattern ...` with `The term 'Get-SbRowPattern' is
# not recognized`, printed NOT ONE case, and produced a receipt with one bit in
# it. The law was written for the assertions and not for their setup, which is
# exactly where the next reader will be missing.
#
# A fixture that cannot be built becomes `$null`, every case that reads it fails
# BY NAME, and the file still enumerates.
function Get-SbFixture([scriptblock]$Block) {
    try { return (& $Block) } catch { return $null }
}

# ---------------------------------------------------------------------------
# The rows. VERBATIM, off kenai's sb-runs.log at main f2da1654 -- not invented.
# ---------------------------------------------------------------------------
$startupRow = "02:02:14`tSB_MODE=(default:offscreen)`tSB_SIZE=(window)`tSB_FRAMES=(default:60)`t" +
    "STARTUP dpi-awareness=DPI_AWARENESS_PER_MONITOR_AWARE dpi-for-window=144 " +
    "composition-scale=1.5x1.5 client-dips=1905x953 surface-request=2858x1429 " +
    "ui-tid=0 render-tid=0 paint-tid=0 present-tid=0 render-has-dispatcher=true"

$pointerRow = "02:03:01`tRUSTOK POINTER press=1 move=7 release=1 selected=1 doc=HELD loads(shell)=1 " +
    "point=(37.00,23.00) surface=2856x1464 scale=1.5 " +
    "ui-tid=2 render-tid=4 paint-tid=4 present-tid=4 render-has-dispatcher=false"

$squeezeRow = "02:04:11`tSQUEEZE delivered 2856x8 (requested height 0; min-height policy=8) " +
    "policy=Refuse ui-tid=2 render-tid=4 paint-tid=4 present-tid=4"

# ---------------------------------------------------------------------------
# ⛔ THE CASE THIS FILE WAS WRITTEN FOR
# ---------------------------------------------------------------------------
#
# `scale` is a SUFFIX of `composition-scale`, and the rows are whitespace-
# separated, so a field name is only a field name at the start of a token. The
# first two cases are the regression; the third is the POSITIVE CONTROL that
# proves the reader still reads the field it is supposed to read -- without it,
# a reader that returned $null for everything would pass the first two.
Test-Case 'scale= is not read out of the middle of composition-scale=' { Get-SbField $startupRow 'scale' } $null
Test-Case 'composition-scale= is read whole' { Get-SbField $startupRow 'composition-scale' } '1.5x1.5'
Test-Case 'CONTROL: a bare scale= is still read' { Get-SbField $pointerRow 'scale' } '1.5'

# ⚠️ THE LIMITATION, PINNED AS A CASE RATHER THAN CLAIMED AWAY. The anchor fixes
# a name matched INSIDE a longer field; it does NOT disambiguate two fields of
# the same name, and the `SQUEEZE delivered` row has exactly that -- `min-height
# policy=<m>` and `policy=<decision>`, both token-initial. `Get-SbField` returns
# the FIRST, which is the clamp and not the decision. That is why PR #115 reads
# it with its own `) policy=` pattern. This case exists so the next reader meets
# the limitation here instead of in a run.
Test-Case 'LIMITATION: policy= on the squeeze row reads the CLAMP, not the decision' { Get-SbField $squeezeRow 'policy' } '8)'

# ---------------------------------------------------------------------------
# The readers that were always correct -- kept so the anchor cannot silently
# break them. Every one of these passed BEFORE the repair.
# ---------------------------------------------------------------------------
Test-Case 'a first field on the row' { Get-SbField $startupRow 'dpi-awareness' } 'DPI_AWARENESS_PER_MONITOR_AWARE'
Test-Case 'a numeric field' { Get-SbField $startupRow 'dpi-for-window' } '144'
Test-Case 'a field after a tab' { Get-SbField $startupRow 'SB_MODE' } '(default:offscreen)'
Test-Case 'the last field on the row' { Get-SbField $startupRow 'render-has-dispatcher' } 'true'
Test-Case 'paint-tid is not confused with paint' { Get-SbField $startupRow 'paint-tid' } '0'
Test-Case 'an absent field reads $null' { Get-SbField $startupRow 'mutation' } $null
Test-Case 'an empty row reads $null' { Get-SbField '' 'scale' } $null
Test-Case 'move= on the pointer row' { Get-SbField $pointerRow 'move' } '7'
Test-Case 'doc= on the pointer row' { Get-SbField $pointerRow 'doc' } 'HELD'
Test-Case 'surface= is not read out of surface-request=' { Get-SbField $startupRow 'surface' } $null
Test-Case 'surface-request= is read whole' { Get-SbField $startupRow 'surface-request' } '2858x1429'

# Get-SbPoint carries the same unanchored name and the same exposure.
Test-Case 'Get-SbPoint reads a point' { (Get-SbPoint $pointerRow 'point').X } '37'
Test-Case 'Get-SbPoint on an absent name' { Get-SbPoint $pointerRow 'nosuch' } $null

# Get-SbSteadyMean: the space before `first=` is load-bearing (`paint first=`
# must not match inside `paint+copy first=`). This one was already anchored by
# construction; the case is here because it is the same class.
$benchRow = "RUSTOK BENCHMARK frames=60 paint first=2.10ms steady-mean=1.05ms min=1.0ms max=1.2ms n=59+1 | " +
    "paint+copy first=3.58ms steady-mean=1.32ms min=1.02ms max=1.66ms n=59+1 | " +
    "present first=0.82ms steady-mean=4.67ms min=0.09ms max=5.26ms n=59+1"
Test-Case 'paint steady-mean is not paint+copy''s' { Get-SbSteadyMean $benchRow 'paint' } '1.05'
Test-Case 'paint+copy steady-mean' { Get-SbSteadyMean $benchRow 'paint+copy' } '1.32'
Test-Case 'present steady-mean' { Get-SbSteadyMean $benchRow 'present' } '4.67'

# ---------------------------------------------------------------------------
# Resolve-SbScale's ROW SELECTOR is the other half of the same defect: an
# unanchored selector picks the STARTUP row, and the reader then has nothing to
# read on it. Both halves are asserted, because fixing either alone leaves a
# wrong answer -- a silent fallback to 1.0 instead of a throw.
#
# THE PATTERN IS BUILT BY THE FUNCTION THE HARNESS ITSELF CALLS, not typed out
# here: a test that asserts against its own copy of a string proves only that
# the author can type it twice.
# ---------------------------------------------------------------------------
$scaleSelector = Get-SbFieldPattern 'scale' '[0-9.]+'
Test-Case 'the scale row selector skips the STARTUP row' { if ($startupRow -match $scaleSelector) { 'MATCHED' } else { 'skipped' } } 'skipped'
Test-Case 'CONTROL: the scale row selector still picks a POINTER row' { if ($pointerRow -match $scaleSelector) { 'MATCHED' } else { 'skipped' } } 'MATCHED'

# ---------------------------------------------------------------------------
# ⛔ THE SECOND DEFECT OF THE SAME RUN, AND IT IS A CULTURE BUG.
#
# `verify_window.ps1` dispatches the liveness sampler through a scheduled task as
#     powershell.exe -File sample_liveness.ps1 -ProcessId <n> -At 2,5,10 -Out <p>
# and `-File` passes every argument as a LITERAL STRING -- it does not parse
# PowerShell array syntax. So `[int[]]` binding coerces the single string
# "2,5,10", and in an en-US console the comma is the DIGIT GROUP SEPARATOR:
# the result is the single integer 2510. Measured on kenai 2026-09-04: the
# sampler's own receipt printed `at=2510s`, it slept toward t=2510 s (41.8 min),
# wrote ZERO of 3 samples, and left a 42-minute orphan process behind on every
# stall run. O3.3 and O3.C1 both read NOT RUN -- the instrument went from
# VACUOUS (session 0) to SILENT, which is a different failure and not a smaller
# one.
#
# ⚠️ AND IT IS CULTURE-DEPENDENT, which is why it is pinned here rather than
# fixed and forgotten: under a culture whose group separator is not a comma the
# same string THROWS instead of quietly becoming 2510. Neither reading is a
# sample. The parser below takes a string and never a typed array, so the
# binding cannot make this decision at all.
Test-Case 'the sample list parses from a -File literal' { (ConvertTo-SbIntList '2,5,10') -join '|' } '2|5|10'
Test-Case 'CONTROL: this is what [int[]] binding did instead' { ([int[]]'2,5,10') -join '|' } '2510'
Test-Case 'a single time still parses as a list of one' { (ConvertTo-SbIntList '7') -join '|' } '7'
Test-Case 'spaces and empty entries are tolerated' { (ConvertTo-SbIntList ' 2 , ,5 ') -join '|' } '2|5'
Test-Case 'an unparseable entry is refused, not silently dropped' { try { ConvertTo-SbIntList '2,x,5'; 'NO THROW' } catch { 'refused' } } 'refused'

# ===========================================================================
# THE SECOND SITTING'S RULINGS -- one arm per repaired reader
# ===========================================================================
#
# ⛔ EVERY CASE BELOW WAS SEEN RED FIRST, AND THE RED ARM IS THE OLD BEHAVIOUR
# ITSELF rather than a planted mutant: this block was pushed ALONE, on top of the
# harness as it stood, before any repair landed. The functions it drives either
# did not exist (a throw, which `Test-Case` records as a failing case, which is
# why it catches throws at all) or returned the answer the box measured wrong.
# The PR body carries both shas.

# ---------------------------------------------------------------------------
# F-A -- THE SUBJECT OF O3.1/O3.2 IS THE ROWS THE RENDER THREAD WROTE
# ---------------------------------------------------------------------------
#
# 8 of the second sitting's 11 FAILs were ONE ROW, once per run. `STARTUP` is
# written at first layout on the UI thread, before the render thread exists, so
# its tid tail was zeros and `render-has-dispatcher=true` described the XAML
# thread. The shell prints `n/a` there now; the harness reads only rows whose
# `render-tid` is a NON-ZERO INTEGER, which excludes both shapes.
$startupNaRow = "02:02:14`tSB_MODE=(default:offscreen)`tSB_SIZE=(window)`tSB_FRAMES=(default:60)`t" +
    "STARTUP dpi-awareness=DPI_AWARENESS_PER_MONITOR_AWARE dpi-for-window=144 " +
    "composition-scale=1.5x1.5 client-dips=1905x953 surface-request=2858x1429 " +
    "ui-tid=1 render-tid=n/a paint-tid=n/a present-tid=n/a render-has-dispatcher=n/a"

# A row the render thread DID write, reporting a dispatcher on itself: the shape
# O3.2 exists to convict. It must still red once STARTUP stops being counted.
$repaintDispRow = "02:03:00`tRUSTOK REPAINT events_total=3 distinct_sizes=1 arrivals=none frames=1 " +
    "cause=resize resizes-in-drain=1 surface=2858x1429 paint=1.90ms present=0.51ms occluded=0 " +
    "loads(shell)=1 ui-tid=2 render-tid=4 paint-tid=4 present-tid=4 render-has-dispatcher=true"

Test-Case 'F-A: a STARTUP row with an n/a tail is not a row the render thread wrote' { Test-SbRenderThreadRow $startupNaRow } 'False'
Test-Case 'F-A: the PRE-REPAIR STARTUP row (render-tid=0) is excluded by the same predicate' { Test-SbRenderThreadRow $startupRow } 'False'
Test-Case 'CONTROL: a POINTER row IS a row the render thread wrote' { Test-SbRenderThreadRow $pointerRow } 'True'

# ⛔ THE TWO HALVES TOGETHER, WHICH IS THE RULING. Over one three-row set:
# STARTUP is excluded, and a REPAINT row reporting a dispatcher STILL REDS. A
# case that only proved the exclusion could be satisfied by a predicate that
# excluded everything.
$o3Rows = @($startupNaRow, $repaintDispRow, $pointerRow)
Test-Case 'F-A: O3.2 examines 2 of the 3 rows (STARTUP is not one of them)' {
    @($o3Rows | Where-Object { Test-SbRenderThreadRow $_ }).Count } '2'
Test-Case 'F-A: and O3.2 still reds on the REPAINT row that reports a dispatcher' {
    @($o3Rows | Where-Object { Test-SbRenderThreadRow $_ } |
      Where-Object { (Get-SbField $_ 'render-has-dispatcher') -ne 'false' }).Count } '1'

# ---------------------------------------------------------------------------
# THE BENCHMARK ROW'S SURFACE -- O2.2's BAND SOURCE
# ---------------------------------------------------------------------------
#
# The pre-repair label applied the composition scale a SECOND time since the
# surface became physical, and the band source scraped exactly that half.
$benchRowPhysical = "02:05:20`tSB_MODE=direct`tSB_SIZE=(window)`tSB_FRAMES=(default:60)`t" +
    "RUSTOK BENCHMARK frames=60 DIRECT surface=2858x1429 physical @scale 1.5x1.5 (client 1905x953 DIP) " +
    "on NVIDIA :: paint first=2.10ms steady-mean=1.05ms min=1.0ms max=1.2ms n=59+1"
$benchRowOldLabel = "02:05:20`tSB_MODE=direct`tSB_SIZE=(window)`tSB_FRAMES=(default:60)`t" +
    "RUSTOK BENCHMARK frames=60 DIRECT 2858x1429DIP buffer @scale 1.5x1.5 -> 4287x2144px on screen " +
    "(COMPOSITOR UPSCALES; jyh/jas#16) on NVIDIA :: paint first=2.10ms steady-mean=1.05ms min=1.0ms max=1.2ms n=59+1"

Test-Case 'the repaired BENCHMARK row yields the PHYSICAL surface' { (Get-SbBenchmarkSurface $benchRowPhysical).Surface } '2858x1429'
Test-Case 'the repaired BENCHMARK row is accepted' { (Get-SbBenchmarkSurface $benchRowPhysical).Ok } 'True'
Test-Case 'the PRE-REPAIR BENCHMARK label is REFUSED, not read' { (Get-SbBenchmarkSurface $benchRowOldLabel).Ok } 'False'
# ⛔ THE CONTROL THAT MAKES THE REFUSAL MEAN SOMETHING: the old reader on the
# old row returns a size this machine cannot display (the panel is 3840 wide).
Test-Case 'CONTROL: the OLD reader on the old row returns the impossible 4287x2144' {
    if ($benchRowOldLabel -match '([0-9]+x[0-9]+)px') { $Matches[1] } else { 'no match' } } '4287x2144'
Test-Case 'CONTROL: the old reader finds nothing on the repaired row' {
    if ($benchRowPhysical -match '([0-9]+x[0-9]+)px') { $Matches[1] } else { 'no match' } } 'no match'
Test-Case 'the repaired row reads through the ordinary anchored field reader too' { Get-SbField $benchRowPhysical 'surface' } '2858x1429'

# ---------------------------------------------------------------------------
# F-C -- `move != k` IS THE DRAG'S DURATION, PRICED
# ---------------------------------------------------------------------------
#
# O4.4 := move >= k with the extras priced at one arrival per 160 ms of
# post-press drag, rounded up. O4.4x asserts EQUALITY under that boundary.
Test-Case 'F-C: k=7 over a 280ms drag reading move=8 is within budget' { (Test-SbMoveCount -Move 8 -K 7 -PostPressMs 280).Ok } 'True'
Test-Case 'F-C: and the row it prints' { (Test-SbMoveCount -Move 8 -K 7 -PostPressMs 280).Text } 'move=8 k=7 extras=1 post-press=280ms budget=2'
Test-Case 'F-C: k=7 over a 70ms drag reading move=8 FAILS the exact arm' {
    $r = Test-SbMoveExact -Move 8 -K 7 -PostPressMs 70; "$($r.Applies)/$($r.Ok)" } 'True/False'
Test-Case 'F-C: CONTROL -- k=7 over 70ms reading 7 passes the exact arm' {
    $r = Test-SbMoveExact -Move 7 -K 7 -PostPressMs 70; "$($r.Applies)/$($r.Ok)" } 'True/True'
Test-Case 'F-C: the exact arm does NOT apply past the boundary' {
    $r = Test-SbMoveExact -Move 8 -K 7 -PostPressMs 280; "$($r.Applies)/$($r.Text)" } 'False/move=8 k=7 post-press=280ms boundary=160ms'
Test-Case 'F-C: k=2 over an 800ms drag reading move=8 EXCEEDS the budget' {
    $r = Test-SbMoveCount -Move 8 -K 2 -PostPressMs 800; "$($r.Ok)/$($r.Text)" } 'False/move=8 k=2 extras=6 post-press=800ms budget=5'
# ⚠️ THE RULING'S OWN THIRD CASE, PINNED AS IT ACTUALLY READS. The ruling gave
# both a formula (`extras <= ceil(post_press_ms / 160)`) and an example
# (k=2, 800 ms, move=6 "fails the budget"). They disagree: 800/160 = 5 and the
# example's extras are 4, so under the ruled formula it PASSES. The FORMULA is
# what runs on the box, so the formula is implemented and the example is
# recorded here with its arithmetic visible rather than silently dropped -- and
# the failing case above is the same configuration one arrival further out.
Test-Case 'F-C: the ruling''s (k=2, 800ms, move=6) PASSES under the ruled formula' {
    $r = Test-SbMoveCount -Move 6 -K 2 -PostPressMs 800; "$($r.Ok)/$($r.Text)" } 'True/move=6 k=2 extras=4 post-press=800ms budget=5'
Test-Case 'F-C: move < k is refused whatever the duration' { (Test-SbMoveCount -Move 1 -K 2 -PostPressMs 800).Ok } 'False'
Test-Case 'F-C: a 0ms drag budgets nothing, so the reading must be exact' {
    $r = Test-SbMoveCount -Move 8 -K 7 -PostPressMs 0; "$($r.Ok)/$($r.Budget)" } 'False/0'

# ---------------------------------------------------------------------------
# THE TITLE ORACLE -- the rule is right and it stays
# ---------------------------------------------------------------------------
$required = 'JAS S-B MATERIALIZER CHECKPOINT 3 | RUSTOK'
$titlesOk = @('JAS S-B MATERIALIZER CHECKPOINT 3 | RUSTOK A'' surface=2858x1429 hash=5808b7a6 engines-created=1')
$titlesFail = @('JAS S-B MATERIALIZER CHECKPOINT 3 | RUSTFAIL render thread died: InvalidOperationException')
$titlesPreRepair = @('JAS S-B MATERIALIZER CHECKPOINT 3 | A'' surface=2858x1429 hash=5808b7a6 engines-created=1')
# ⛔ AND THE PATTERN THAT FINDS A COMPLETION ROW MUST ACCEPT THE PREFIX
# WITHOUT REQUIRING IT -- otherwise the repair that fixes the title breaks every
# wait and every hash-row reader against a bisected build. THE PATTERN IS BUILT
# BY THE FUNCTION THE HARNESS ITSELF CALLS, not typed out here.
$aPrimeRow = "02:06:31`tSB_MODE=(default:offscreen)`tSB_SIZE=(window)`tSB_FRAMES=(default:60)`t" +
    "RUSTOK A' surface=2858x1429 hash=5808b7a6 engines-created=1 engines-freed=0 loads(shell)=1 " +
    "ui-tid=2 render-tid=4 paint-tid=4 present-tid=4 render-has-dispatcher=false"
$aPrimeRowOld = $aPrimeRow.Replace("`tRUSTOK A' surface=", "`tA' surface=")
$proseRow = "02:06:31`tSB_MODE=(default:offscreen)`tSB_SIZE=(window)`tSB_FRAMES=(default:60)`t" +
    "RUSTOK NOTE the walk hashes A, A-MUT, H1 and A' surface=2858x1429 is the round trip's"
$aPrimePattern = Get-SbFixture { Get-SbRowPattern "A'" " surface=" }
# ⛔ `-match $null` MATCHES EVERYTHING, so an unbuilt pattern is named rather
# than silently turning the two MATCHED controls green for the wrong reason.
function Test-SbPatternOn([string]$Row) {
    if ($null -eq $aPrimePattern) { return 'no pattern' }
    if ($Row -match $aPrimePattern) { return 'MATCHED' }
    return 'missed'
}
Test-Case 'the completion-row pattern matches the PREFIXED row' { Test-SbPatternOn $aPrimeRow } 'MATCHED'
Test-Case 'CONTROL: it still matches a BISECTED build''s unprefixed row' { Test-SbPatternOn $aPrimeRowOld } 'MATCHED'
Test-Case 'CONTROL: and the tab anchor still keeps A'' out of another row''s prose' { Test-SbPatternOn $proseRow } 'missed'

Test-Case 'CONTROL: a RUSTOK title satisfies the oracle' { (Select-SbTitleMatch $titlesOk $required).Count } '1'
Test-Case 'the oracle still REFUSES a RUSTFAIL title' { (Select-SbTitleMatch $titlesFail $required).Count } '0'
Test-Case 'the PRE-REPAIR completion row''s title did not satisfy it either (the defect)' { (Select-SbTitleMatch $titlesPreRepair $required).Count } '0'

# ---------------------------------------------------------------------------
# F-B -- THE CHOOSER AIMS AT THE LARGEST, THE APP TAKES THE TOPMOST
# ---------------------------------------------------------------------------
#
# The fixture is the kenai document's shape: a 72x72 filled rect at the origin
# (the LARGEST filled shape, so the aim lands at its centre) and, LATER IN
# DOCUMENT ORDER, a group whose line spans the same region. The app's hit test
# returns the topmost top-level layer child over the point -- `[0,2]` -- and the
# after-dump says so in `selection[0].path`.
$beforeJson = @'
{"layers":[{"type":"layer","id":"L","children":[
  {"type":"rect","id":"big","x":0,"y":0,"width":72,"height":72,"fill":"#ff0000"},
  {"type":"rect","id":"small","x":300,"y":300,"width":10,"height":10,"fill":"#00ff00"},
  {"type":"group","id":"g","children":[
    {"type":"line","id":"ln","x1":0,"y1":150,"x2":200.000025,"y2":0}]}]}]}
'@
$afterJson = @'
{"layers":[{"type":"layer","id":"L","children":[
  {"type":"rect","id":"big","x":0,"y":0,"width":72,"height":72,"fill":"#ff0000"},
  {"type":"rect","id":"small","x":300,"y":300,"width":10,"height":10,"fill":"#00ff00"},
  {"type":"group","id":"g","children":[
    {"type":"line","id":"ln","x1":36.666664,"y1":172.666668,"x2":236.666689,"y2":22.666668}]}]}],
 "selection":[{"kind":"all","path":[0,2]}]}
'@
# The same after-dump with the app naming a DIFFERENT element: O1.2c's FAIL arm.
$afterJsonOther = $afterJson.Replace('"path":[0,2]', '"path":[0,1]')

$beforeDoc = $beforeJson | ConvertFrom-Json
$afterDoc = $afterJson | ConvertFrom-Json
$afterDocOther = $afterJsonOther | ConvertFrom-Json
$target = Get-SbFixture { Get-SbHitTargetFromDoc $beforeDoc }

Test-Case 'F-B: the chooser AIMS at the largest filled shape' { $target.AimPath } '$.layers[0].children[0]'
Test-Case 'F-B: the aim point is that shape''s centre' { "$($target.X),$($target.Y)" } '36,36'
Test-Case 'F-B: but it TARGETS the topmost element over that point, as the app does' { $target.Path } '$.layers[0].children[2]'
Test-Case 'F-B: the app''s own answer is read from selection[0].path' { Get-SbSelectionPathFromDoc $afterDoc } '$.layers[0].children[2]'
Test-Case 'F-B: O1.2c -- the chooser and the app agree' { ((Get-SbSelectionPathFromDoc $afterDoc) -eq $target.Path) } 'True'
Test-Case 'F-B: O1.2c REPORTS a mismatch instead of charging it to the app' { ((Get-SbSelectionPathFromDoc $afterDocOther) -eq $target.Path) } 'False'

# ⛔ THE TWO READINGS SIDE BY SIDE, WHICH IS THE WHOLE DEFECT. Read at the app's
# selected path the delta is the asked one; read at the harness's OLD choice the
# element is byte-identical -- which is what produced two reds on a run in which
# everything worked.
$selEl = Get-SbFixture { Get-SbElementByPathFromDoc $afterDoc '$.layers[0].children[2]' }
$selElBefore = Get-SbFixture { Get-SbElementByPathFromDoc $beforeDoc '$.layers[0].children[2]' }
$aimElBefore = Get-SbFixture { Get-SbElementByPathFromDoc $beforeDoc '$.layers[0].children[0]' }
$aimElAfter = Get-SbFixture { Get-SbElementByPathFromDoc $afterDoc '$.layers[0].children[0]' }
Test-Case 'F-B: the selected element is the group' { $selEl.type } 'group'
# ⛔ AND A MISSING ELEMENT READS AS A (0,0) DELTA. Named, or the "nothing
# moved" CONTROL below goes green for the wrong reason -- which is the exact
# shape of the defect this whole clause exists to repair.
function Get-SbDeltaText($Before, $After) {
    $b = Get-SbElementOrigin $Before
    $a = Get-SbElementOrigin $After
    if ($null -eq $b -or $null -eq $a) { return 'no position' }
    return ("{0:N2},{1:N2}" -f ($a.X - $b.X), ($a.Y - $b.Y))
}
Test-Case 'F-B: O1.2b reads the SELECTED element''s delta -- the asked one' { Get-SbDeltaText $selElBefore $selEl } '36.67,22.67'
Test-Case 'F-B: CONTROL -- at the OLD chosen path nothing moved (the two false reds)' { Get-SbDeltaText $aimElBefore $aimElAfter } '0.00,0.00'
Test-Case 'F-B: both dumps'' positions are read by the SAME rule' {
    ((Get-SbElementOrigin $selElBefore).How -eq (Get-SbElementOrigin $selEl).How) } 'True'
Test-Case 'F-B: and the rule is NAMED, not implied' { (Get-SbElementOrigin $selElBefore).How } 'the origin of its bounding box (min over this element and its descendants)'
Test-Case 'a rect still answers with its x/y pair' { (Get-SbElementOrigin $aimElBefore).How } 'the x/y pair'
Test-Case 'the index list renders in this harness''s path spelling' { ConvertTo-SbElementPath @(0, 2, 0) } '$.layers[0].children[2].children[0]'
Test-Case 'a dump with no selection reads $null (the older dump shape)' { Get-SbSelectionPathFromDoc $beforeDoc } $null

# ---------------------------------------------------------------------------
Write-Host ""
$cases | ForEach-Object { Write-Host $_ }
Write-Host ""
Write-Host ("--- $pass passed, $fail failed, of {0} case(s) ---" -f ($pass + $fail))
if ($fail -gt 0) { exit 1 }
exit 0
