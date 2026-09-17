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

$pointerRow = "02:03:01`tRUSTOK POINTER press=1 move=7 release=1 dup-frames=5 raised=12 selected=1 doc=HELD loads(shell)=1 " +
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
# F-C RE-CUT -- `move == k`, UNCONDITIONALLY (jas, 2026-09-06)
# ---------------------------------------------------------------------------
#
# ⛔ THE OLD RULING WAS `move >= k` WITH THE EXTRAS PRICED against the drag's
# duration (one arrival per 160 ms, rounded up), and the budget existed for
# exactly ONE reason, stated in the ruling itself: the extras had no identified
# source, so they could not be charged to the app's counting. flask's third
# harness run IDENTIFIED them -- XAML RE-DELIVERING a pointer frame the shell
# had already applied, same FrameId AND Timestamp AND position -- and excluded
# everything below the app by measurement (`probe_hold.ps1`: a bare Win32 window
# driven by this harness's own injector reads arrivals == k exactly, in BOTH
# input stacks, with and without a 5 ms repaint). The shell now suppresses the
# repeat and reports it as `dup-frames=`.
#
# ⇒ THE PREMISE IS REFUTED, SO THE RULING IS RE-CUT RATHER THAN LEFT SLACK.
# A budget whose stated reason has been withdrawn is not a merely loose
# assertion -- it is an assertion about nothing, and it would absorb a NEW
# duplicate shape (one the FrameId/Timestamp/position triple does not catch) in
# perfect silence. That is the exact failure the suppression was written to make
# visible. O4.4 is now `move == k` at EVERY duration and any extra is a finding.
#
# ⭐ AND THE EVIDENCE MOVED, WHICH IS WHY O4.4x IS RE-CUT AND NOT DELETED.
# Before the repair, the proof that duplicates existed WAS the extras count.
# After it, the only remaining evidence is `dup-frames=` -- and no assertion read
# that field's value, only a lexical case proving `frames=` cannot match inside
# it. So O4.4x hands "convict the app of miscounting" to O4.4 (which now does it
# at every duration, not just under a boundary) and takes the job no arm held.
#
# ⚠️ `-PostPressMs` SURVIVES AS A REPORTED FIELD AND NO LONGER GATES ANYTHING.
# It is kept because the duration is the first thing a reader of a failing row
# wants, and it is named here so the next reader does not assume a parameter
# that appears in the signature is deciding the verdict.
Test-Case 'F-C RE-CUT: k=7 reading move=8 is a FINDING however long the drag was' {
    (Test-SbMoveCount -Move 8 -K 7 -PostPressMs 280).Ok } 'False'
Test-Case 'F-C RE-CUT: and the row it prints carries no budget' {
    (Test-SbMoveCount -Move 8 -K 7 -PostPressMs 280).Text } 'move=8 k=7 extras=1 post-press=280ms'
# The configuration that produced the largest extras count on record (k=2 over
# 800 ms read move=4, two extras) is now a finding at its OWN measured reading,
# not only at some larger one -- under the old budget of 5 it passed.
Test-Case 'F-C RE-CUT: k=2 over 800ms reading move=4 is now a finding' {
    $r = Test-SbMoveCount -Move 4 -K 2 -PostPressMs 800; "$($r.Ok)/$($r.Text)" } 'False/move=4 k=2 extras=2 post-press=800ms'
# ⚠️ THE OLD RULING'S OWN THIRD CASE, KEPT AS THE HINGE OF THE RE-CUT. The old
# ruling gave both a formula and an example (k=2, 800 ms, move=6) that its own
# formula PASSED -- the disagreement was pinned here rather than dropped. Under
# the re-cut the disagreement is moot: both readings are findings.
Test-Case 'F-C RE-CUT: the old ruling''s (k=2, 800ms, move=6) is a finding too' {
    $r = Test-SbMoveCount -Move 6 -K 2 -PostPressMs 800; "$($r.Ok)/$($r.Text)" } 'False/move=6 k=2 extras=4 post-press=800ms'
Test-Case 'F-C RE-CUT: CONTROL -- the post-repair reading passes at every duration' {
    $a = (Test-SbMoveCount -Move 7 -K 7 -PostPressMs 70).Ok
    $b = (Test-SbMoveCount -Move 2 -K 2 -PostPressMs 800).Ok
    $c = (Test-SbMoveCount -Move 7 -K 7 -PostPressMs 280).Ok
    "$a/$b/$c" } 'True/True/True'
Test-Case 'F-C RE-CUT: move < k is still refused, and by its own sign' {
    $r = Test-SbMoveCount -Move 1 -K 2 -PostPressMs 800; "$($r.Ok)/$($r.Extras)" } 'False/-1'

# ⭐ O4.4x -- `dup-frames=` IS REPORTED. The duplicates did not stop; they are
# suppressed, and this is the only surface that still says so. The shell's own
# comment says a shell that quietly swallowed them "would be indistinguishable
# from one where they had stopped happening, and the next wave would have to
# rediscover the whole finding" -- this is the arm that holds it to that.
Test-Case 'O4.4x: a POINTER row carrying dup-frames reports it' {
    $r = Test-SbDupFramesReported $pointerRow; "$($r.Ok)/$($r.Dups)/$($r.Text)" } 'True/5/dup-frames=5'
Test-Case 'O4.4x: zero is REPORTED, not read as absent' {
    $r = Test-SbDupFramesReported ($pointerRow -replace 'dup-frames=5', 'dup-frames=0'); "$($r.Ok)/$($r.Dups)" } 'True/0'
Test-Case 'O4.4x: ⭐ THE MUTANT -- a row with the field REMOVED is refused' {
    $r = Test-SbDupFramesReported ($pointerRow -replace 'dup-frames=5 ', ''); "$($r.Ok)/$($r.Dups)" } 'False/-1'
Test-Case 'O4.4x: a non-numeric value is refused rather than coerced' {
    $r = Test-SbDupFramesReported ($pointerRow -replace 'dup-frames=5', 'dup-frames=none'); $r.Ok } 'False'
Test-Case 'O4.4x: CONTROL -- an empty row is refused, not crashed on' {
    $r = Test-SbDupFramesReported ''; $r.Ok } 'False'
# ⛔ THE RESULT KEY IS `Dups` BECAUSE `Count` IS A HASHTABLE MEMBER. A key named
# `Count` is shadowed by the table's OWN `Count` (its number of entries), so
# `$r.Count` would read 4 here and look exactly like a measurement. The
# invariant is that the table has no such key at all -- asserted that way rather
# than by pinning the entry count, which would red on any future key.
Test-Case 'O4.4x: the result carries no key that its own Count would shadow' {
    $r = Test-SbDupFramesReported $pointerRow
    "$($r.Dups)/$($r.ContainsKey('Count'))" } '5/False'

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
# THE FOLDED TITLE -- the shell now writes the RUN's verdict, not the row's
# ---------------------------------------------------------------------------
#
# ⛔ `TitleVerdict.Compose` (C#) changed the title's SHAPE: `<name> | <verdict>
# [fails=N] | <last row>`. `Select-SbTitleMatch` is unchanged and must stay so,
# but a rule that is never driven against the shape the app actually writes is a
# rule about a title nobody produces. These cases pin the two halves together
# from THIS side; `../sb_winui_tests/` drives the C# side. The fixtures are the
# literal output of that project's `Compose`, not a paraphrase of it.
$titlesFolded = @("JAS S-B MATERIALIZER CHECKPOINT 3 | RUSTOK | A' scene=retained surface=2858x1429")
$titlesFoldedTally = @('JAS S-B MATERIALIZER CHECKPOINT 3 | RUSTOK fails=1 | RUSTOK STAY pid=4812')
$titlesFoldedFail = @('JAS S-B MATERIALIZER CHECKPOINT 3 | RUSTFAIL | RUSTFAIL render thread died')
$titlesPending = @('JAS S-B MATERIALIZER CHECKPOINT 3 | RUSTPENDING')
# ⛔ THE NEAR MISS. The last-row half can itself contain `RUSTOK` (`Report`
# composes `RECEIPT-LOST <ex> | <status>`), so a FAILED run's title can carry the
# word. The oracle must key on the APP NAME plus the verdict, never on `RUSTOK`
# loose in the string -- a shorter name hiding inside a longer one is how this
# seat lost a sitting.
$titlesFailCarryingTheWord = @(
    'JAS S-B MATERIALIZER CHECKPOINT 3 | RUSTFAIL | RECEIPT-LOST IOException | RUSTOK GOLDENS 21/21')

Test-Case 'the FOLDED title satisfies the oracle when the last row has no verdict' { (Select-SbTitleMatch $titlesFolded $required).Count } '1'
Test-Case 'a folded title with a fail TALLY still satisfies it (O5 must not go red)' { (Select-SbTitleMatch $titlesFoldedTally $required).Count } '1'
Test-Case 'CONTROL: a folded RUSTFAIL title is still refused' { (Select-SbTitleMatch $titlesFoldedFail $required).Count } '0'
Test-Case 'CONTROL: a run that reported nothing (RUSTPENDING) is refused' { (Select-SbTitleMatch $titlesPending $required).Count } '0'
Test-Case 'CONTROL: RUSTOK loose in the LAST-ROW half does not pass a failed run' { (Select-SbTitleMatch $titlesFailCarryingTheWord $required).Count } '0'

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
# O1.2c -- THE CHOOSER AGAINST THE PORT'S *LIVE* HIT TEST
# ---------------------------------------------------------------------------
#
# ⛔ EVERYTHING ABOVE IN F-B IS DRIVEN ON A HAND-WRITTEN `selection[0].path`.
# The chooser mirrors the app's topmost-at-point rule, but that mirror was READ
# OUT OF THE REFERENCE INTERPRETER'S SOURCE (`workspace_interpreter/
# doc_primitives.py`) and the fixture's "app answer" was written from the same
# reading. A hand-written oracle CANNOT disagree with the mirror it came from,
# so those cases pin the chooser to itself. jas's #118 ruling says so in its own
# words: "the chooser's mirror was read from the reference, never against the
# shell's live hit test -- O1.2c is where that shows."
#
# ⭐ THIS BLOCK IS THAT GAP CLOSED. The document below is not a fixture in this
# file: it is `test_fixtures/gestures/select_click_topmost_over_largest_filled_
# expected.json`, the canonical output of a gesture the PORT'S OWN SELECTION
# TOOL executed -- a press at doc (36,36) replayed through `YamlTool` and
# `doc_primitives::hit_test`, which is the same path `jas_pointer_event` drives
# from the shell. Its `selection[0].path` is a MEASUREMENT, not a transcription.
# So the comparison below is chooser-vs-app, across two languages, on one file.
#
# 📌 THE VECTOR IS NOT VACUOUS, and that was measured too: with the children
# `.rev()` removed from `doc_primitives::hit_test`, the full Rust suite is
# 3066 passed / 0 failed WITHOUT this vector and fails on it alone WITH it.
#
# ⛔ AND A MISSING FILE IS `NOT RUN`, NEVER A PASS. This is the one case in this
# file that reads something off disk; if the corpus moves, it must say so rather
# than compare two nulls and go green.
$corpusPath = Join-Path $PSScriptRoot '..\..\test_fixtures\gestures\select_click_topmost_over_largest_filled_expected.json'
$corpusDoc = $null
$corpusState = 'NOT RUN: the corpus file is not there'
if (Test-Path $corpusPath) {
    $corpusDoc = Get-Content -Raw -LiteralPath $corpusPath | ConvertFrom-Json
    $corpusState = 'read'
}
$corpusTarget = Get-SbFixture { if ($null -eq $corpusDoc) { $null } else { Get-SbHitTargetFromDoc $corpusDoc } }

Test-Case 'O1.2c: the live-hit-test corpus vector is on disk' { $corpusState } 'read'
Test-Case 'O1.2c: the PORT selected the group, measured (not transcribed)' { Get-SbSelectionPathFromDoc $corpusDoc } '$.layers[0].children[2]'
Test-Case 'O1.2c: the chooser AIMS elsewhere -- so this document discriminates' { $corpusTarget.AimPath } '$.layers[0].children[0]'
Test-Case 'O1.2c: ⭐ THE CHOOSER AGREES WITH THE PORT''S LIVE HIT TEST' { ((Get-SbSelectionPathFromDoc $corpusDoc) -eq $corpusTarget.Path) } 'True'
Test-Case 'O1.2c: CONTROL -- aim and answer really are different paths here' { ($corpusTarget.AimPath -eq $corpusTarget.Path) } 'False'

# ---------------------------------------------------------------------------
# `dup-frames=` MUST NOT BE READ AS `frames=`
# ---------------------------------------------------------------------------
#
# The shell's POINTER row gained `dup-frames=<n>` when the `move != k` extras
# were identified as RE-DELIVERED pointer frames. `verify_assertions.ps1` reads a
# field called `frames` off REPAINT rows, and `frames` is a suffix of
# `dup-frames` -- the exact shape that killed a whole sitting when `scale`
# matched inside `composition-scale=`. The anchor already forbids it; these
# cases are what keep it forbidden, with the positive control beside them.
Test-Case 'frames= is not read out of the middle of dup-frames=' { Get-SbField $pointerRow 'frames' } $null
Test-Case 'dup-frames= is read whole' { Get-SbField $pointerRow 'dup-frames' } '5'
Test-Case 'CONTROL: the reader still reads frames= where it IS a field' { Get-SbField $repaintDispRow 'frames' } '1'
Test-Case 'CONTROL: move= is unaffected by the new neighbour' { Get-SbField $pointerRow 'move' } '7'

# ---------------------------------------------------------------------------
# O4.4y -- THE IDENTITY, AND WHY THE ROUTE §18 P4 PROPOSED IS NOT IT
# ---------------------------------------------------------------------------
#
# `raised == move + dup-frames`, over three counters incremented at three
# different sites. The fixture row reads move=7 dup-frames=5 raised=12.
#
# ⛔ THE `Applies=$false` CASE IS THE ONE THAT MATTERS MOST. A row from a build
# older than the field must be NOT RUN -- not a pass, and not a fail. An arm
# that failed a bisected build's row would be making a claim about a field that
# build never carried, which is the mirror of the defect it exists to catch.
$identRow    = $pointerRow
$identOldRow = "02:03:01`tRUSTOK POINTER press=1 move=7 release=1 dup-frames=5 selected=1 surface=2856x1464"
$identBadRow = "02:03:01`tRUSTOK POINTER press=1 move=7 release=1 dup-frames=4 raised=12 selected=1"
$identSynthRow = "02:03:01`tRUSTOK POINTER SYNTHETIC press=1 move=7 release=1 dup-frames=0 raised=n/a pointer=SYNTHETIC"
$identZeroRow  = "02:03:01`tRUSTOK POINTER SYNTHETIC press=1 move=7 release=1 dup-frames=0 raised=0 pointer=SYNTHETIC"

Test-Case 'O4.4y: the identity holds on a consistent row' { (Test-SbMoveIdentity $identRow).Ok } 'True'
Test-Case 'O4.4y: ...and it APPLIES to that row' { (Test-SbMoveIdentity $identRow).Applies } 'True'
Test-Case 'O4.4y: CONTROL -- a row whose counts disagree FAILS' { (Test-SbMoveIdentity $identBadRow).Ok } 'False'
Test-Case 'O4.4y: ...and the failing row still APPLIES (a fail, not a skip)' { (Test-SbMoveIdentity $identBadRow).Applies } 'True'
Test-Case 'O4.4y: a row with no raised= does NOT apply (bisected build)' { (Test-SbMoveIdentity $identOldRow).Applies } 'False'
# ⛔ AND THE SYNTHETIC ARM'S `n/a` IS A THIRD ANSWER, not a zero and not an
# absence. A shell that printed `raised=0` there made this arm FAIL on a row it
# cannot judge -- measured on the box before the repair.
Test-Case 'O4.4y: raised=n/a does NOT apply (the synthetic control)' { (Test-SbMoveIdentity $identSynthRow).Applies } 'False'
Test-Case 'O4.4y: ...and its reason names the synthetic arm' { if ((Test-SbMoveIdentity $identSynthRow).Text -match 'synthetic control') { 'named' } else { 'not named' } } 'named'
Test-Case 'O4.4y: CONTROL -- raised=0 with move=7 WOULD fail (the pre-repair shape)' { (Test-SbMoveIdentity $identZeroRow).Ok } 'False'
Test-Case 'O4.4y: ...and that zero row DOES apply, which is why n/a was needed' { (Test-SbMoveIdentity $identZeroRow).Applies } 'True'
Test-Case 'O4.4y: ...and it does not report itself as a pass either' { (Test-SbMoveIdentity $identOldRow).Ok } 'False'
Test-Case 'O4.4y: the identity names all three counters in its text' { if ((Test-SbMoveIdentity $identRow).Text -match 'raised=12 move=7 dup-frames=5') { 'named' } else { 'not named' } } 'named'

# ⛔ `raised=` MUST NOT BE READ OUT OF ANOTHER FIELD, and `dup-frames=` must
# still read whole beside it -- the same anchor law that killed a sitting when
# `scale` matched inside `composition-scale=`.
Test-Case 'raised= is read whole beside its neighbours' { Get-SbField $pointerRow 'raised' } '12'
Test-Case 'CONTROL: dup-frames= still reads beside raised=' { Get-SbField $pointerRow 'dup-frames' } '5'

# ---------------------------------------------------------------------------
# O4.4z -- THE FIELD O4.4y READS MUST ITSELF BE REPORTED
# ---------------------------------------------------------------------------
#
# ⛔ THE HOLE IS ONE LEVEL UP FROM THE ONE O4.4y CLOSED, AND IT IS THE SAME HOLE.
# O4.4y tolerates a row with no `raised=` by design -- `Applies = $false`, NOT
# RUN -- so that a build older than the identity is not failed for a field it
# never carried. That tolerance is right for the IDENTITY question and it is
# also, unmodified, a way to switch the arm off: delete `raised=` from
# `Canvas.cs` and O4.4y stops running instead of going red, while `NOT RUN` is
# tallied separately from FAIL and no run fails.
#
# That is exactly the asymmetry O4.4x already refuses for its own field:
# `dup-frames=` ABSENT is a FAIL, measured by the §18 P3 mutant. `raised=`
# ABSENT was a silence. The split is the same one O4.4/O4.4x drew -- the REPORT
# and the VALUE are two questions -- so `raised=` gets the report arm its
# sibling has, and O4.4y keeps its tolerance for the value.
#
# ⚠️ `n/a` IS REPORTED, NOT MISSING. The synthetic arm declines the COUNT (it
# never enters `MainWindow.OnPointerMoved`, where the three counters live); it
# does not drop the FIELD. A row that carries no `raised=` at all is a different
# event from one that carries `raised=n/a`, and only the first is a defect.
$raisedDecoyRow = "02:03:01`tRUSTOK POINTER press=1 move=7 moves-raised=99 raised=12 dup-frames=5"
$raisedBadRow   = "02:03:01`tRUSTOK POINTER press=1 move=7 release=1 dup-frames=5 raised=xyz"

Test-Case 'O4.4z: raised= is reported on a REAL row' { (Test-SbRaisedReported $pointerRow).Ok } 'True'
Test-Case 'O4.4z: raised=n/a IS reported (the synthetic arm declines the count, not the field)' { (Test-SbRaisedReported $identSynthRow).Ok } 'True'
# ⛔ THE FIELD-REMOVAL MUTANT. This is the case whose absence let the hole exist:
# before this arm, a row with no `raised=` reached O4.4y alone and came back NOT
# RUN. Here it must be a refusal.
Test-Case 'O4.4z: CONTROL -- the field-removal mutant, an ABSENT raised= is refused' { (Test-SbRaisedReported $identOldRow).Ok } 'False'
Test-Case 'O4.4z: ...and its text names the absence rather than a value' { if ((Test-SbRaisedReported $identOldRow).Text -match 'ABSENT') { 'named' } else { 'not named' } } 'named'
Test-Case 'O4.4z: CONTROL -- a malformed raised= is refused too' { (Test-SbRaisedReported $raisedBadRow).Ok } 'False'
# ⛔ AND THE ANCHOR, AGAINST THE SUFFIX DECOY -- the `frames=` inside
# `dup-frames=` class, one field on. `moves-raised=` is the name a reader would
# most plausibly reach for next, so it is the decoy worth pinning.
Test-Case 'O4.4z: CONTROL -- raised= is not read out of moves-raised=' { Get-SbField $raisedDecoyRow 'raised' } '12'

# ===========================================================================
# WAVE 1's ROWS (P1-P4) -- VERBATIM OFF KENAI, 2026-09-09, jas main 2d24d782
# ===========================================================================
#
# ⭐ THESE ARE READINGS, NOT SHAPES, AND THAT DISTINCTION IS WHY W5 WAITED.
# The design block held P1-P4 back on the ground that an oracle written against
# a row that has never been emitted is a fixture defect waiting for the seat
# least able to tell whose defect it is. The rows below are what the box
# printed. Two of the four assertions were re-cut because of what is in them.
$abiRow = "09:02:31`tSB_MODE=(default:offscreen)`tSB_SIZE=(window)`tSB_FRAMES=(default:60)`t" +
    "RUSTOK ABI menu-items=55 menu-enabled=43/44 can-undo=false/true/false edit=Ok undo=Ok " +
    "detail=none svg-bytes=505/616 struct-nodes=73 struct-labelled=62 " +
    "struct-kinds=item|menu|separator|submenu"

# ⛔ NO `RUSTOK ` ON THIS ONE, AND THAT IS THE POINT. `OnMenuChanged` calls
# `Report(...)`; only the SCENE row carries a verdict prefix. My first draft of
# this fixture had one -- copied from the ABI row beside it -- and it would have
# made a P4 pattern of `'RUSTOK MENU rebuilds='` look correct while matching
# nothing in a real log. A fixture written from an assumption agrees with it.
$menuRow = "09:02:31`tMENU rebuilds=1 items=55 enabled=43 disabled=12 seq=1 state-age=0 missed=0"

$appRow = "09:02:31`tRUSTOK APP pid=5920 surface=2858x1369 menu-rebuilds=1 menu-items=55 " +
    "menu-enabled=43 doc=(empty) — run-and-stay: this scene does NOT complete and does NOT exit"

# ---------------------------------------------------------------------------
# ⛔ THE SUFFIX COLLISION ON THE NEW ROWS -- the `composition-scale` class again
# ---------------------------------------------------------------------------
#
# `enabled` is a suffix of `disabled`, and BOTH are fields on the same MENU row.
# `items` is a suffix of `menu-items` and BOTH are on the ABI and APP rows.
# `undo` is a suffix of `can-undo`; `rebuilds` of `menu-rebuilds`. Four live
# collisions on rows nothing had ever read. The anchor is what makes them safe,
# and reasoning that it does is not the same as driving it.
Test-Case 'P4: enabled= is not read out of disabled=' { Get-SbField $menuRow 'enabled' } '43'
Test-Case 'P4: disabled= is read whole' { Get-SbField $menuRow 'disabled' } '12'
Test-Case 'P4: items= is not read out of menu-items=' { Get-SbField $menuRow 'items' } '55'
Test-Case 'P4: menu-items= on a row that has ONLY the prefixed form' { Get-SbField $abiRow 'menu-items' } '55'
Test-Case 'P4: CONTROL -- bare items= is ABSENT from the ABI row, not 55' { Get-SbField $abiRow 'items' } $null
Test-Case 'P2: undo= is not read out of can-undo=' { Get-SbField $abiRow 'undo' } 'Ok'
Test-Case 'P2: can-undo= is read whole' { Get-SbField $abiRow 'can-undo' } 'false/true/false'
Test-Case 'P4: rebuilds= is not read out of menu-rebuilds=' { Get-SbField $appRow 'menu-rebuilds' } '1'
Test-Case 'P4: CONTROL -- bare rebuilds= is ABSENT from the APP row' { Get-SbField $appRow 'rebuilds' } $null

# ---------------------------------------------------------------------------
# Get-SbSlashField -- the paired readings, and its REFUSALS
# ---------------------------------------------------------------------------
Test-Case 'P4: menu-enabled=43/44 reads as two parts' { (Get-SbSlashField $abiRow 'menu-enabled' 2).Parts -join ',' } '43,44'
Test-Case 'P2: can-undo reads as three parts' { (Get-SbSlashField $abiRow 'can-undo' 3).Parts -join ',' } 'false,true,false'
Test-Case 'P3: svg-bytes reads as two parts' { (Get-SbSlashField $abiRow 'svg-bytes' 2).Parts -join ',' } '505,616'
# ⛔ THE ARITY REFUSAL. Asking for the wrong number of parts must REFUSE, not
# truncate -- a three-reading field read as two compares readings that are not
# the ones named, and the verdict would be about the wrong pair.
Test-Case 'CONTROL: can-undo asked for 2 parts REFUSES' { (Get-SbSlashField $abiRow 'can-undo' 2).Ok } 'False'
Test-Case '...and the refusal names the arity it actually found' { if ((Get-SbSlashField $abiRow 'can-undo' 2).Reason -match '3 slash-separated') { 'named' } else { 'not named' } } 'named'
# ⛔ AND AN ABSENT FIELD IS A DIFFERENT REFUSAL FROM A MALFORMED ONE. A reader
# that answered $null for both would hand an assertion a value reading as FALSE.
Test-Case 'CONTROL: an ABSENT field refuses and says so' { (Get-SbSlashField $menuRow 'svg-bytes' 2).Ok } 'False'
Test-Case '...naming the absence, not an arity' { if ((Get-SbSlashField $menuRow 'svg-bytes' 2).Reason -match 'no .svg-bytes=. field') { 'named' } else { 'not named' } } 'named'

# ---------------------------------------------------------------------------
# Get-SbStableCount -- the anti-collapse form must PARSE, not look malformed
# ---------------------------------------------------------------------------
Test-Case 'P4: menu-items=55 is a stable count' { (Get-SbStableCount $abiRow 'menu-items').Stable } 'True'
Test-Case 'P4: ...with the value on it' { (Get-SbStableCount $abiRow 'menu-items').Value } '55'
# ⛔ THE DISAGREEMENT FORM IS A READING, NOT A PARSE FAILURE. The shell writes
# `55!=57` when the menubar it counted twice differed; a reader accepting only
# digits would call the anti-collapse signal a malformed row and the assertion
# would go NOT RUN -- silencing the one field written to catch that defect.
$abiSplitRow = $abiRow -replace 'menu-items=55', 'menu-items=55!=57'
Test-Case 'P4: the disagreement form PARSES' { (Get-SbStableCount $abiSplitRow 'menu-items').Ok } 'True'
Test-Case 'P4: ...and reports itself NOT stable' { (Get-SbStableCount $abiSplitRow 'menu-items').Stable } 'False'
Test-Case 'P4: ...carrying both readings' { $r = Get-SbStableCount $abiSplitRow 'menu-items'; "$($r.Value)/$($r.Other)" } '55/57'
Test-Case 'CONTROL: a non-numeric count refuses' { (Get-SbStableCount ($abiRow -replace 'menu-items=55', 'menu-items=xyz') 'menu-items').Ok } 'False'

# ---------------------------------------------------------------------------
# Get-SbMenuRowReading -- P4's arithmetic
# ---------------------------------------------------------------------------
# ⛔ THE PREFIX ARM. The completion-row pattern must match a MENU row that has
# NO verdict prefix (the real shape) and one that does (a bisected build), or a
# P4 clause silently reads NOT RUN over a run that measured the menubar.
Test-Case 'P4: the completion-row pattern matches a PREFIXLESS MENU row (the real shape)' { if ($menuRow -match (Get-SbRowPattern 'MENU' ' rebuilds=')) { 'matched' } else { 'MISSED' } } 'matched'
Test-Case 'P4: ...and still matches one carrying RUSTOK (a bisected build)' { if (($menuRow -replace "`tMENU", "`tRUSTOK MENU") -match (Get-SbRowPattern 'MENU' ' rebuilds=')) { 'matched' } else { 'MISSED' } } 'matched'
Test-Case 'P4: CONTROL -- it does not match the MENU REFUSED row' { if ("09:02:31`tRUSTFAIL MENU REFUSED structure-bytes=0 state-bytes=0 cause=open" -match (Get-SbRowPattern 'MENU' ' rebuilds=')) { 'matched' } else { 'MISSED' } } 'MISSED'
Test-Case 'P4: the MENU row reads' { (Get-SbMenuRowReading $menuRow).Ok } 'True'
Test-Case 'P4: items == enabled + disabled on the real row' { $r = Get-SbMenuRowReading $menuRow; $r.Items - ($r.Enabled + $r.Disabled) } '0'
Test-Case 'P4: state-age is read (it is a constant the row keeps deliberately)' { (Get-SbMenuRowReading $menuRow).StateAge } '0'
Test-Case 'P4: missed is read' { (Get-SbMenuRowReading $menuRow).Missed } '0'
# ⛔ THE ARITHMETIC MUTANT. Without this the sum clause is satisfied by a reader
# that returned the same number three times.
Test-Case 'P4: CONTROL -- a row whose counts do not close is still READ, and its arithmetic fails' { $r = Get-SbMenuRowReading ($menuRow -replace 'disabled=12', 'disabled=11'); "$($r.Ok):$($r.Items - ($r.Enabled + $r.Disabled))" } 'True:1'
# ⭐ `shortcuts-unparsed=` -- flask's fourth finding, given a reader. The
# fixture above is kenai's VERBATIM row and PREDATES the field, so it is the
# bisected-build arm for free; `$menuRowSc` is the shape the shell writes now.
$menuRowSc = "$menuRow shortcuts-unparsed=2"
Test-Case 'P4.3: the count is read when the row carries it' { (Get-SbMenuRowReading $menuRowSc).ShortcutsUnparsed } '2'
Test-Case 'P4.3: ...and the row still reads as a whole' { (Get-SbMenuRowReading $menuRowSc).Ok } 'True'
# ⛔ ABSENT IS NOT ZERO. A reader returning 0 for a row that never carried the
# field would report "every accelerator attached" about a build that cannot
# say. `ShortcutsApply` is the same $false-means-declines rule `raised=` uses.
Test-Case 'P4.3: CONTROL -- kenai''s real row PREDATES the field and declines it' { (Get-SbMenuRowReading $menuRow).ShortcutsApply } 'False'
Test-Case 'P4.3: ...declining, NOT reporting zero' { (Get-SbMenuRowReading $menuRow).ShortcutsUnparsed } '-1'
Test-Case 'P4.3: a row reporting genuinely zero APPLIES' { (Get-SbMenuRowReading "$menuRow shortcuts-unparsed=0").ShortcutsApply } 'True'
Test-Case 'P4.3: CONTROL -- a malformed count declines rather than reading' { (Get-SbMenuRowReading "$menuRow shortcuts-unparsed=xyz").ShortcutsApply } 'False'
Test-Case 'P4: CONTROL -- a MENU row missing a field REFUSES rather than reading -1' { (Get-SbMenuRowReading ($menuRow -replace ' missed=0', '')).Ok } 'False'
Test-Case 'P4: ...and names the field it could not read' { if ((Get-SbMenuRowReading ($menuRow -replace ' missed=0', '')).Reason -match 'missed') { 'named' } else { 'not named' } } 'named'

# ---------------------------------------------------------------------------
# P4.2 -- A LOST MENU NOTIFICATION, READ FROM BOTH ENDS
# ---------------------------------------------------------------------------
#
# ⛔ W2-7 REDDENED P4.2 ON A RUN THAT LOST NOTHING. kenai 2026-09-16, the q6 replay:
# MENU rows `seq 1 . 2 . 6 (missed=3) . 6 . 6 . 6`. `OnMenuChanged` reads the
# NEWEST `Menu`, so one notification drew seq 6 and reported the gap, and the
# three after it re-read seq 6 -- six rows for six publications, and nothing
# lost. The old clause asserted `missed=0` on every row and could not tell that
# from a loss. And the loss it exists for, a LAST notification that never
# arrives (a stale menubar), leaves no UI-side row at all.
#
# ⛔ THESE ROWS ARE WHAT THE NEW C# FORMAT STRINGS COMPOSE, NOT VERBATIM OFF THE
# BOX: no box has run this build. The first sitting on it replaces them, and a
# reader that disagrees with a real row is this file's defect.
$p42Tids = 'ui-tid=2 render-tid=4 paint-tid=4 present-tid=4 render-has-dispatcher=false'
function New-SbP42Pub([int]$Seq, [string]$Cause) {
    return "15:02:11`tMENU PUBLISHED seq=$Seq cause=$Cause $p42Tids"
}
function New-SbP42Menu([int]$Seq, [int]$Missed, [int]$Delivered, [int]$Coalesced) {
    return ("15:02:11`tMENU rebuilds=$Seq items=55 enabled=50 disabled=5 seq=$Seq state-age=0 " +
        "missed=$Missed delivered=$Delivered coalesced=$Coalesced shortcuts-unparsed=2")
}
# W2-7's run as this build writes it: the open and startup publications, the
# replay's four (select_all, click, again, undo), and six deliveries -- the
# first of the last four drawing seq 6, the other three finding it drawn.
$p42W27 = @(
    (New-SbP42Pub 1 'open'), (New-SbP42Pub 2 'startup'),
    (New-SbP42Menu 1 0 1 0), (New-SbP42Menu 2 0 2 0),
    (New-SbP42Pub 3 'mutation'), (New-SbP42Pub 4 'panel'), (New-SbP42Pub 5 'panel'), (New-SbP42Pub 6 'mutation'),
    (New-SbP42Menu 6 3 3 0), (New-SbP42Menu 6 0 4 1), (New-SbP42Menu 6 0 5 2), (New-SbP42Menu 6 0 6 3))
# Notification 4 dropped: five deliveries, and the menubar still reaches seq 6.
$p42LostMid = @($p42W27[0..8]) + (New-SbP42Menu 6 0 4 1) + (New-SbP42Menu 6 0 5 2)
# Notification 6 dropped after 3-5 were drawn: the menubar stops at seq 5.
$p42Stale = @($p42W27[0..3]) + (New-SbP42Pub 3 'mutation') + (New-SbP42Pub 4 'panel') + (New-SbP42Pub 5 'panel') +
    (New-SbP42Menu 5 2 3 0) + (New-SbP42Menu 5 0 4 1) + (New-SbP42Menu 5 0 5 2) + (New-SbP42Pub 6 'mutation')

Test-Case 'P4.2: CONTROL -- the MENU row pattern does not match a MENU PUBLISHED row' { if ((New-SbP42Pub 1 'open') -match (Get-SbRowPattern 'MENU' ' rebuilds=')) { 'matched' } else { 'MISSED' } } 'MISSED'
Test-Case 'P4.2: the publications are read, in order' { (Get-SbMenuPublished $p42W27).Seqs -join ',' } '1,2,3,4,5,6'
Test-Case 'P4.2: CONTROL -- a MENU row is not read as a publication' { (Get-SbMenuPublished @((New-SbP42Menu 1 0 1 0))).Seqs.Count } '0'
Test-Case 'P4.2: a publication with an unreadable seq is COUNTED unreadable, never skipped' { (Get-SbMenuPublished @("15:02:11`tMENU PUBLISHED seq=x cause=open $p42Tids")).Unreadable } '1'
Test-Case 'P4.2: delivered= is read' { (Get-SbMenuRowReading (New-SbP42Menu 6 0 5 2)).Delivered } '5'
Test-Case 'P4.2: coalesced= is read' { (Get-SbMenuRowReading (New-SbP42Menu 6 0 5 2)).Coalesced } '2'
Test-Case 'P4.2: ...and the pair applies' { (Get-SbMenuRowReading (New-SbP42Menu 6 0 5 2)).DeliveryApplies } 'True'
Test-Case 'P4.2: CONTROL -- kenai''s real row PREDATES the pair, reads, and declines it' { $r = Get-SbMenuRowReading $menuRow; "$($r.Ok):$($r.DeliveryApplies):$($r.Delivered)" } 'True:False:-1'
Test-Case 'P4.2: CONTROL -- half a pair declines' { (Get-SbMenuRowReading ((New-SbP42Menu 6 0 5 2) -replace ' coalesced=2', '')).DeliveryApplies } 'False'
Test-Case 'P4.2: W2-7''s coalesce -- six deliveries of six publications -- PASSES' { (Get-SbMenuDeliveryVerdict $p42W27).Verdict } 'PASS'
Test-Case 'P4.2: CONTROL -- those same rows carry missed=3, which the OLD clause read as a loss' { $s = 0; foreach ($r in $p42W27) { $m = Get-SbMenuRowReading $r; if ($m.Ok) { $s += $m.Missed } }; $s } '3'
Test-Case 'P4.2: a notification lost MID-BURST FAILS' { (Get-SbMenuDeliveryVerdict $p42LostMid).Verdict } 'FAIL'
Test-Case 'P4.2: ...naming the count that never arrived, not a stale menubar' { $d = (Get-SbMenuDeliveryVerdict $p42LostMid).Detail; if ($d -match '^1 menu notification\(s\) never arrived' -and $d -notmatch 'STALE') { 'named' } else { $d } } 'named'
Test-Case 'P4.2: the LAST notification lost -- a STALE MENUBAR -- FAILS' { (Get-SbMenuDeliveryVerdict $p42Stale).Verdict } 'FAIL'
Test-Case 'P4.2: ...and says STALE, naming both seqs' { $d = (Get-SbMenuDeliveryVerdict $p42Stale).Detail; if ($d -match '^STALE MENUBAR' -and $d -match 'seq 6' -and $d -match 'seq 5') { 'named' } else { $d } } 'named'
Test-Case 'P4.2: CONTROL -- the stale run''s last row delivered all it saw, so only the published seq catches it' { $r = Get-SbMenuRowReading $p42Stale[-2]; "$($r.Seq):$($r.Delivered)" } '5:5'
Test-Case 'P4.2: publications and NO MENU row FAIL -- once the producer speaks, absent is not zero' { (Get-SbMenuDeliveryVerdict @($p42W27[0], $p42W27[1])).Verdict } 'FAIL'
Test-Case 'P4.2: CONTROL -- kenai''s pre-producer row alone is NOT RUN, and says why' { $v = Get-SbMenuDeliveryVerdict @($menuRow); if ($v.Verdict -eq 'NOT RUN' -and $v.Detail -match 'predates') { 'declined' } else { "$($v.Verdict): $($v.Detail)" } } 'declined'
Test-Case 'P4.2: a run with no menu at all is NOT RUN' { (Get-SbMenuDeliveryVerdict @($abiRow)).Verdict } 'NOT RUN'
Test-Case 'P4.2: publications beside an older build''s MENU rows are NOT RUN, never compared with a default' { (Get-SbMenuDeliveryVerdict @($p42W27[0], $p42W27[1], $menuRow)).Verdict } 'NOT RUN'
Test-Case 'P4.2: two processes in one slice (seq 1,2,1,2) are NOT RUN, never compared' { $v = Get-SbMenuDeliveryVerdict (@($p42W27[0..3]) + @($p42W27[0..3])); if ($v.Verdict -eq 'NOT RUN' -and $v.Detail -match '1,2,1,2') { 'declined' } else { "$($v.Verdict): $($v.Detail)" } } 'declined'
Test-Case 'P4.2: more deliveries than publications FAIL as the instrument''s own defect' { $v = Get-SbMenuDeliveryVerdict (@($p42W27) + (New-SbP42Menu 6 0 7 4)); if ($v.Verdict -eq 'FAIL' -and $v.Detail -match 'instrument') { 'named' } else { "$($v.Verdict): $($v.Detail)" } } 'named'
Test-Case 'P4.2: every verdict above carries a detail and the P4.2 key' { $bad = 0; foreach ($x in @($p42W27, $p42LostMid, $p42Stale, @($menuRow), @($abiRow))) { $v = Get-SbMenuDeliveryVerdict $x; if ([string]::IsNullOrWhiteSpace($v.Detail) -or ($v.Name -split ' ')[0] -ne 'P4.2') { $bad++ } }; $bad } '0'
Test-Case 'P4.2 wait: the delivered W2-7 run is settled' { Test-SbMenuSettled $p42W27 } 'True'
Test-Case 'P4.2 wait: the same run read BEFORE its last delivery is not' { Test-SbMenuSettled $p42W27[0..10] } 'False'
Test-Case 'P4.2 wait: publications with no MENU row yet are not settled' { Test-SbMenuSettled @($p42W27[0], $p42W27[1]) } 'False'
Test-Case 'P4.2 wait: a run that published nothing owes no wait' { Test-SbMenuSettled @($abiRow) } 'True'
Test-Case 'P4.2 wait: CONTROL -- an early read of W2-7 judges it STALE, which is why the wait exists' { (Get-SbMenuDeliveryVerdict $p42W27[0..7]).Detail -match '^STALE' } 'True'

# ---------------------------------------------------------------------------
# `Get-SbSceneRefusals` -- THE READER TWO WAITS INSIDE A RUN NOW DEPEND ON
# ---------------------------------------------------------------------------
#
# ⛔ IT SHIPPED WITH NO ARM AT ALL, AND THE MUTANT IS THE ARGUMENT FOR THESE
# CASES. Make the function `return @()` unconditionally and BOTH inside-run
# waits silently revert to burning their full 90 s -- while this file stays at
# its full count, `check_scene_tables` stays OK and CI stays green, because the
# only consumers are two `Wait-SbRow` calls that need a desktop to reach. A
# producer needs a consumer that can RED.
#
# ⭐ AND THE CASES BELOW ARE BEHAVIOURAL, NOT SHAPE CHECKS. `RUSTFAIL RETAINED `
# was prescribed in a routed ruling on 2026-09-09 on the strength of its nine
# sibling scenes, and at that moment it matched NOTHING that scene could print.
# A pattern is only worth what it matches, so every case here drives it against
# a row.

# ⛔ `@(...)` AROUND THE CALL BEFORE `[0]`, AND IT IS NOT DECORATION. A
# one-element array leaves a function as a SCALAR, and `'RUSTFAIL RETAINED '[0]`
# is the CHARACTER 'R' -- which matches every row on this page, so the positive
# arm would pass for the wrong reason and the control would fail.
$refusalRow = "02:03:01`tRUSTFAIL RETAINED FAILED: no swapchain ui-tid=0 render-tid=0"
$refusalOther = "02:03:01`tRUSTFAIL POINTER FAILED: no swapchain ui-tid=0 render-tid=0"
$successRow = "02:03:01`tRUSTOK RETAINED 'tiger.svg' (1024 bytes) in the HELD engine; loads(shell)=1"

Test-Case 'REFUSALS: a declared scene yields its class pattern' { (Get-SbSceneRefusals 'retained') -join '|' } 'RUSTFAIL RETAINED '
Test-Case 'REFUSALS: the pattern MATCHES that scene''s refusal row' { if ($refusalRow -match @(Get-SbSceneRefusals 'retained')[0]) { 'matched' } else { 'MISSED' } } 'matched'
# ⛔ THE ARM THAT STOPS A WAIT ENDING EARLY. `Done` and `Refused` answer
# different questions precisely because a success pattern here would end a wait
# on a row saying nothing about its own subject.
Test-Case 'REFUSALS: CONTROL -- it does NOT match that scene''s SUCCESS row' { if ($successRow -match @(Get-SbSceneRefusals 'retained')[0]) { 'matched' } else { 'MISSED' } } 'MISSED'
Test-Case 'REFUSALS: CONTROL -- it does NOT match another scene''s refusal row' { if ($refusalOther -match @(Get-SbSceneRefusals 'retained')[0]) { 'matched' } else { 'MISSED' } } 'MISSED'
# ⛔⛔ THE PAIR BELOW IS THE ONE WORTH READING, AND IT IS A DEFECT #145 SHIPPED.
# `+` is NOT safe against this reader. A PowerShell function whose output
# stream is empty evaluates to `$null` in a parenthesised call, so
# `@('DUMP ...') + (Get-SbSceneRefusals $Scene)` was a TWO-element list for
# every scene with no `Refused` key -- and `[string[]]` then turned the second
# element into `''`, a pattern that matches EVERY row. A wait built that way
# ends at 0s on the last unrelated line and reports it as its subject.
# `Get-SbWaitPatterns` is the fix and these are its arms.
Test-Case 'PATTERNS: a declared scene contributes its refusal beside the caller''s own' { (Get-SbWaitPatterns @('DUMP sb-doc-before\.json bytes=') 'retained') -join '|' } 'DUMP sb-doc-before\.json bytes=|RUSTFAIL RETAINED '
Test-Case 'PATTERNS: an unknown scene leaves the caller''s list EXACTLY as it was' { (Get-SbWaitPatterns @('DUMP sb-doc-before\.json bytes=') 'no-such-scene') -join '|' } 'DUMP sb-doc-before\.json bytes='
Test-Case 'PATTERNS: ...and contributes NO empty pattern -- the defect itself' { $p = Get-SbWaitPatterns @('DUMP sb-doc-before\.json bytes=') 'no-such-scene'; @($p | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count } '0'
# ⛔ AND THE BACKSTOP, WHICH CLOSES THE CLASS RATHER THAN THE INSTANCE: any
# caller that reaches the row reader with an empty pattern is REFUSED BY NAME.
# `'' -match ''` is true for every row, so the silent version of this returns a
# confident answer about the wrong line.
Test-Case 'PATTERNS: CONTROL -- an empty pattern REFUSES rather than matching every row' { try { Select-SbRow @('a','b') ''; 'matched' } catch { if ("$($_.Exception.Message)" -match 'refusing to match every row') { 'refused' } else { 'wrong refusal' } } } 'refused'
Test-Case 'PATTERNS: CONTROL -- a real pattern still selects' { Select-SbRow @('alpha','beta') 'be' } 'beta'
# ⛔ THE ANTI-VACUITY ARM, AND IT IS THE ONE THAT KILLS THE `return @()` MUTANT.
# Every case above names ONE scene; a reader that answered only for `retained`
# would pass all of them. This one asks the whole table, and it reds for a
# neutered reader AND for an entry that loses its key.
# ⭐ `scripts/check_scene_refusal_labels.py` is the other half: it holds the C#
# side, that every refusal a scene can return begins with the prefix these
# patterns anchor on. Neither half is checkable from where the other lives.
Test-Case 'REFUSALS: EVERY scene in the table yields a non-empty pattern list' {
    $missing = @()
    foreach ($s in $sceneSpec.Keys) { if ((Get-SbSceneRefusals $s).Count -lt 1) { $missing += $s } }
    if ($missing.Count -eq 0) { "all $($sceneSpec.Keys.Count)" } else { "MISSING: $($missing -join ',')" }
} "all $($sceneSpec.Keys.Count)"
Test-Case 'REFUSALS: CONTROL -- the table is not empty, so the case above is not vacuous' { if ($sceneSpec.Keys.Count -ge 8) { 'populated' } else { "only $($sceneSpec.Keys.Count)" } } 'populated'

# ---------------------------------------------------------------------------
# `Get-SbSceneVerdict` -- THE COMPLETION LINE CLASSIFIES, IT DOES NOT COMPLETE
# ---------------------------------------------------------------------------
#
# ⛔ THE CASE THAT MATTERS IS `refusedAndDone`, AND IT IS THE MEASURED DEFECT,
# NOT A HYPOTHETICAL. On kenai 2026-09-09 a `retained` run on a bad document
# refused in under a second AND had its `A'` row written anyway, because the
# `SB_RESIZE` walk runs independently of the scene's return value. The verdict
# line read `ok  : scene 'retained' completed` over a hash of a blank white
# surface. Both rows are in the region; the refusal must win.
#
# ⭐ AND THE ORDER OF THE ROWS IS DELIBERATELY WRONG-WAY-ROUND IN THAT FIXTURE:
# `A'` comes AFTER the refusal. The whole point of the ruling is that arrival
# order stops being an input, so the fixture is built to fail a reader that
# takes "whichever came last".

$refusedRow  = "02:03:01`tRUSTFAIL RETAINED NOT RUN: uncalibrated SVG 'x.svg' -- O1 compares hashes"
$aPrimeRow   = "02:03:02`tA' surface=1000x600 hash=deadbeef"
$retainedOk  = "02:03:02`tRUSTOK RETAINED 'tiger.svg' (1024 bytes) in the HELD engine"
$refusedAndDone = @($refusedRow, $aPrimeRow)

Test-Case 'VERDICT: a clean run with a Done row reads DONE' { (Get-SbSceneVerdict @($retainedOk, $aPrimeRow) 'retained' $aPrimeRow).Verdict } 'DONE'
Test-Case 'VERDICT: no Done row and no refusal reads TIMEOUT' { (Get-SbSceneVerdict @($retainedOk) 'retained' $null).Verdict } 'TIMEOUT'
# ⛔⛔ THE MEASURED DEFECT. Before the classifier this returned "completed".
Test-Case 'VERDICT: a refusal WITH a Done row reads REFUSED, not DONE' { (Get-SbSceneVerdict $refusedAndDone 'retained' $aPrimeRow).Verdict } 'REFUSED'
Test-Case 'VERDICT: ...and it quotes the SCENE''s row, not the row that ended the wait' { (Get-SbSceneVerdict $refusedAndDone 'retained' $aPrimeRow).Row.Trim() } $refusedRow.Trim()
# ⭐ ORDER IS NOT AN INPUT: the same two rows the other way round, same verdict.
Test-Case 'VERDICT: CONTROL -- reversing the row order changes nothing' { (Get-SbSceneVerdict @($aPrimeRow, $refusedRow) 'retained' $aPrimeRow).Verdict } 'REFUSED'
# ⛔ A REFUSAL WITH NO Done ROW IS STILL REFUSED, NEVER TIMEOUT. The two have
# different remedies and a timeout's sentence tells the reader nothing.
Test-Case 'VERDICT: a refusal with NO Done row is REFUSED, not TIMEOUT' { (Get-SbSceneVerdict @($refusedRow) 'retained' $null).Verdict } 'REFUSED'
# ⛔ CROSS-SCENE CONTROL, AND IT IS THE ARM THAT MAKES STEP (0) LOAD-BEARING:
# another scene's refusal must NOT convict this one. Before every refusal path
# carried its scene's prefix, this is the arm that could not have been written.
Test-Case 'VERDICT: CONTROL -- another scene''s refusal does not convict this one' { (Get-SbSceneVerdict @("02:03:01`tRUSTFAIL POINTER FAILED: no swapchain", $aPrimeRow) 'retained' $aPrimeRow).Verdict } 'DONE'
# ⭐ AND THE SUCCESS ROW OF THE SAME SCENE IS NOT A REFUSAL -- `RUSTOK` vs
# `RUSTFAIL` is the whole discriminator, and a pattern missing the verdict
# prefix would convict every healthy run.
Test-Case 'VERDICT: CONTROL -- the scene''s own SUCCESS row is not a refusal' { (Get-SbSceneVerdict @($retainedOk, $aPrimeRow) 'retained' $aPrimeRow).Verdict } 'DONE'
Test-Case 'VERDICT: an unknown scene has no refusals, so a Done row still reads DONE' { (Get-SbSceneVerdict @($refusedRow) 'no-such-scene' $aPrimeRow).Verdict } 'DONE'

# ---------------------------------------------------------------------------
# THE O4 ARM SUMMARY LINE (STATUS-flask section 72, jas) -- `Format-SbArmSummary`
# ---------------------------------------------------------------------------
#
# ⛔ WHY IT IS A PURE FUNCTION AND WHY ITS ARMS LIVE HERE. The line it builds is
# the one a reader parses to tell "the whole arm ran" from "one key is missing",
# and it is emitted by `verify_window.ps1`, which cannot run without a Windows
# desktop. CI runs THIS file on Windows with no app. Same argument as the chooser.
#
# ⛔⛔ AND IT DOES NOT COUNT BY THE ANCHORED PREFIX ALONE, WHICH IS WHAT THE
# COMMISSION ASKED FOR. `^<prefix>(\.| )` is right for `O4.C2` and WRONG for the
# bare `O4`: the `:768` loop DECLARES `O4.C1 gesture` and `O4.C2 gesture` as
# NOT RUN in every run, and both of those anchor-match `^O4(\.| )`. A run whose
# arm is `O4` would have counted its two scoped-OUT siblings as its own keys and
# reported 13 where the arm is 11 -- the section 66 lesson (`O4.` hides inside
# `O4.C2.`) firing one level further up than the commission spotted it.
# ⇒ A KEY BELONGS TO THE **LONGEST DECLARED ARM** THAT ANCHOR-MATCHES IT. That
# rule subsumes the anchored rule, gives the same answer for `O4.C2`, and is the
# only one that is correct for all three arms. Arms A7/A7b are that case.
function New-SbArmFixture([string[]]$Spec) {
    $l = New-Object System.Collections.Generic.List[object]
    foreach ($s in $Spec) {
        $p = $s -split '\|'
        $l.Add([pscustomobject]@{ Name = $p[0]; Verdict = $p[1]; Detail = ''; Row = '' })
    }
    ,$l
}
$ARMS3 = @('O4', 'O4.C1', 'O4.C2')

# A1 -- THE COMMISSION'S OWN CASE: `O4.C2.1` and `O4.C21.x` must count ONE.
$fxAnchor = Get-SbFixture { New-SbArmFixture @('O4.C2.1|PASS', 'O4.C21.x|PASS') }
Test-Case 'ARM: anchored -- O4.C21.x does NOT count under O4.C2' `
    { (Format-SbArmSummary $fxAnchor 'O4.C2' '' $ARMS3).Split(':')[1].Trim().Split(' ')[0] } '1'
# A1b -- MUTATION CONTROL: the fixture is not vacuous. An UNANCHORED `StartsWith`
#        count over the same two rows is 2, so A1 is discriminating, not decorative.
Test-Case 'ARM: MUTATION CONTROL -- an unanchored count over that fixture would be 2' `
    { @($fxAnchor | Where-Object { $_.Name.StartsWith('O4.C2') }).Count } '2'

# A2 -- AN ARM THAT SELECTED NOTHING PRINTS `0 key(s)`. It must never omit the line:
#       an absent line and a zero are the two states this whole file exists to separate.
$fxNone = Get-SbFixture { New-SbArmFixture @('O9.1|PASS') }
Test-Case 'ARM: an arm that selected nothing still prints its line, with 0 key(s)' `
    { if ((Format-SbArmSummary $fxNone 'O4.C2' '' $ARMS3) -match '(\d+) key\(s\)') { $Matches[1] } else { 'NO LINE' } } '0'

# A3 -- THE THREE VERDICTS SPLIT, and NOT RUN is counted as itself.
$fxMixed = Get-SbFixture { New-SbArmFixture @('O4.C2 gesture|NOT RUN', 'O4.C2.1|PASS', 'O4.C2.2|FAIL', 'O4.C2.3|PASS') }
Test-Case 'ARM: the split reads 2 PASS, 1 FAIL, 1 NOT RUN' `
    { if ((Format-SbArmSummary $fxMixed 'O4.C2' '' $ARMS3) -match '\((\d+) PASS, (\d+) FAIL, (\d+) NOT RUN\)') { "$($Matches[1])/$($Matches[2])/$($Matches[3])" } else { 'NO MATCH' } } '2/1/1'
# A3b -- and the total is the sum, i.e. the line CLOSES, same law as the summary above it.
Test-Case 'ARM: the key count equals PASS+FAIL+NOT RUN (the line closes)' `
    { if ((Format-SbArmSummary $fxMixed 'O4.C2' '' $ARMS3) -match '(\d+) key\(s\) verdicted under it \((\d+) PASS, (\d+) FAIL, (\d+) NOT RUN\)') { [int]$Matches[1] - ([int]$Matches[2] + [int]$Matches[3] + [int]$Matches[4]) } else { 'NO MATCH' } } '0'

# A4 -- A SPACE SUFFIX IS A SUFFIX. `O4.C2 gesture` is the key the whole arm hangs on.
Test-Case 'ARM: the space-separated suffix (O4.C2 gesture) is counted' `
    { $f = New-SbArmFixture @('O4.C2 gesture|PASS'); (Format-SbArmSummary $f 'O4.C2' '' $ARMS3) -match '1 key\(s\)' } 'True'
# A4b -- CONTROL: the BARE prefix with no suffix at all is NOT a key of the arm.
Test-Case 'ARM: CONTROL -- a bare "O4.C2" with no suffix is not counted' `
    { $f = New-SbArmFixture @('O4.C2|PASS'); (Format-SbArmSummary $f 'O4.C2' '' $ARMS3) -match '0 key\(s\)' } 'True'

# A5 -- THE UNSELECTED ARMS ARE DECLARED, in the order the :768 loop declares them.
Test-Case 'ARM: the unselected arms are named' `
    { if ((Format-SbArmSummary $fxMixed 'O4.C2' '' $ARMS3) -match 'unselected arms declared: (.+) ---$') { $Matches[1] } else { 'NO MATCH' } } 'O4, O4.C1'

# A6 -- THE WHOLE LINE, BYTE FOR BYTE, IN THE SHAPE THE COMMISSION SPECIFIED.
#       11 keys is the FULL arm on a gesture run (12 suffixes, the gesture verdicts the other 11).
$fx11 = Get-SbFixture {
    New-SbArmFixture (@('O4.C2 gesture|PASS') + (1..10 | ForEach-Object { "O4.C2.$_|PASS" }) +
                      @('O4 gesture|NOT RUN', 'O4.C1 gesture|NOT RUN'))
}
Test-Case 'ARM: the full line, exactly as section 72 specified it' `
    { Format-SbArmSummary $fx11 'O4.C2' ' [SB_SYNTH_DRAG seam control]' $ARMS3 } `
    "  --- O4 arm 'O4.C2' [SB_SYNTH_DRAG seam control]: 11 key(s) verdicted under it (11 PASS, 0 FAIL, 0 NOT RUN); unselected arms declared: O4, O4.C1 ---"

# A7 -- ⛔ THE CORRECTION. Same fixture, but the run's arm is the BARE `O4`. Its own
#       own key is `O4 gesture` and nothing else: the two DECLARED siblings, and every
#       key hanging off them, belong to THEM. Anchored-only reads 13 here; the arm is 1.
Test-Case 'ARM: the bare O4 owns ONLY its own key, never its declared siblings' `
    { if ((Format-SbArmSummary $fx11 'O4' '' $ARMS3) -match '(\d+) key\(s\)') { $Matches[1] } else { 'NO MATCH' } } '1'
# A7b -- MUTATION CONTROL: anchored-only over that same fixture annexes 13, so A7
#        is pinning a real difference and not restating A2.
Test-Case 'ARM: MUTATION CONTROL -- anchored-only would have annexed all 13 to O4' `
    { @($fx11 | Where-Object { $_.Name -match '^O4(\.| )' }).Count } '13'
# A7c -- and the bare O4 DOES own its own suffixes when they are present.
Test-Case 'ARM: CONTROL -- the bare O4 still owns O4.1 and O4 gesture' `
    { $f = New-SbArmFixture @('O4 gesture|PASS', 'O4.1|PASS', 'O4.C2.1|PASS')
      if ((Format-SbArmSummary $f 'O4' '' $ARMS3) -match '(\d+) key\(s\)') { $Matches[1] } else { 'NO MATCH' } } '2'

# A8 -- A REGEX METACHARACTER IN AN ARM NAME IS A NAME, NOT A PATTERN.
Test-Case 'ARM: a prefix is escaped, never used as a pattern' `
    { $f = New-SbArmFixture @('O4xC2.1|PASS'); (Format-SbArmSummary $f 'O4.C2' '' @('O4.C2')) -match '0 key\(s\)' } 'True'

# ---------------------------------------------------------------------------
# Q6 -- THE ALIGN PANE, READ OFF ITS OWN ROWS (W2-6)
# ---------------------------------------------------------------------------
#
# ⛔ NO BOX HAS RUN W2-5 OR W2-6, SO THESE ROWS ARE NOT VERBATIM OFF kenai. Each
# is the literal its C# format string composes -- `Canvas.ApplyPanelOpen`,
# `ApplyPanelClick`, `ApplyPanelSynth`, `ApplyOp`, the hash row in
# `RepaintOnce`; `MainWindow.BuildPane`, `ReportPaneIcons`, `DrawPane` -- filled
# with what the real Align plan carries at 228 on this sitting's document
# (22 leaves: 4 text, 17 icon buttons, 1 input; 17 icons; height 168; 10960
# bytes; measured through `jas_panel_plan`). W2-7's first sitting is what
# replaces them with the box's own lines, and a reader that disagrees with a
# real row is this file's defect, not the app's.
function New-SbQ6Row([string]$Status) {
    return "15:02:11`tSB_MODE=(default:offscreen)`tSB_SIZE=(window)`tSB_FRAMES=(default:60)`t" + $Status
}
$q6Tids = 'ui-tid=2 render-tid=4 paint-tid=4 present-tid=4 render-has-dispatcher=false'
$q6Who = 'panel=align_panel_content widget=align_left_button'
function New-SbQ6Channel([string]$Class) {
    return '{"panel_event":"' + $Class + '","detail":"align_left_button"}'
}
function New-SbQ6Hash([string]$Label, [string]$Hex, [string]$Surface = '2502x1350') {
    return "RUSTOK $Label surface=$Surface hash=$Hex engines-created=1 engines-freed=0 loads(shell)=1 $q6Tids"
}
$q6HashA = '1' * 64
$q6HashS = '2' * 64
$q6HashM = '3' * 64
$q6DocA = 'a' * 16
$q6DocS = 'b' * 16
$q6DocM = 'c' * 16
function New-SbQ6Done([string]$Docs, [string]$Selected = '4') {
    return "PANEL SYNTH DONE $q6Who selected=$Selected doc-sha=$Docs $q6Tids"
}

# The whole run, in the order the shell writes it. `$Over` replaces a step by
# key, and a `$null` value DELETES it, so every variant below is a one-key
# mutation of the healthy run and nothing else.
function New-SbQ6Fixture([hashtable]$Over = @{}) {
    $steps = [ordered]@{
        open    = "PANEL OPEN panel=align_panel_content avail-w=228 leaves=22 chrome=0 containers=0 unjoined=0 withheld=0 icons=17 icons-missing=0 height=168 crossings=2 bytes=10960 plan-bytes=10960 seq=1 $q6Tids"
        built   = 'PANEL BUILT panel=align_panel_content build=1 leaves=22 texts=4 buttons=17 inputs=1 unmaterialized=0 unaddressable=0 icon-loads=17 icon-text=0'
        repaint = "RUSTOK REPAINT events_total=3 distinct_sizes=1 arrivals=none frames=1 cause=hash resizes-in-drain=0 surface=2502x1350 paint=1.20ms present=0.40ms occluded=0 loads(shell)=1 $q6Tids"
        h0      = (New-SbQ6Hash 'SYNTH-H0' $q6HashA)
        c0      = "PANEL CLICK REFUSED $q6Who via=synth:no-selection channel=$(New-SbQ6Channel 'Disabled') $q6Tids"
        h0b     = (New-SbQ6Hash 'SYNTH-H0B' $q6HashA)
        select  = "RUSTOK SYNTH-SELECT-ALL applied=0 can-undo=false can-redo=false $q6Tids"
        hs      = (New-SbQ6Hash 'SYNTH-HS' $q6HashS)
        c1      = "PANEL CLICK $q6Who via=synth:click outcome=changed changed-rows=0 doc-changed=true delta-mismatch=0 channel=(clear) $q6Tids"
        h1      = (New-SbQ6Hash 'SYNTH-H1' $q6HashM)
        c2      = "PANEL CLICK $q6Who via=synth:again outcome=unchanged changed-rows=0 doc-changed=false delta-mismatch=0 channel=$(New-SbQ6Channel 'Unchanged') $q6Tids"
        h1b     = (New-SbQ6Hash 'SYNTH-H1B' $q6HashM)
        undo    = "RUSTOK SYNTH-UNDO applied=1 can-undo=false can-redo=true $q6Tids"
        h2      = (New-SbQ6Hash 'SYNTH-H2' $q6HashS)
        done    = (New-SbQ6Done "$q6DocA/$q6DocA/$q6DocS/$q6DocM/$q6DocM/$q6DocS")
        icons   = 'PANEL ICONS panel=align_panel_content build=1 svg=17 text=0 failed=0 icon=SVG'
        drawn   = 'PANEL DRAWN panel=align_panel_content seq=1 cause=open missed=0 rebuilt=true controls=22 disabled=15 checked=1 hidden=0 pane-dips=236x1350 canvas-dips=1668x900'
    }
    foreach ($k in $Over.Keys) {
        if (-not $steps.Contains($k)) { throw "New-SbQ6Fixture: no step '$k'" }
        $steps[$k] = $Over[$k]
    }
    $out = @()
    foreach ($k in $steps.Keys) {
        if ($null -ne $steps[$k]) { $out += (New-SbQ6Row $steps[$k]) }
    }
    return $out
}
$q6NoSynth = @{ h0 = $null; c0 = $null; h0b = $null; select = $null; hs = $null; c1 = $null
                h1 = $null; c2 = $null; h1b = $null; undo = $null; h2 = $null; done = $null }

# `Q6.1=PASS Q6.2=PASS ...`, in the order the reader emits them.
function Format-SbQ6($Verdicts) {
    return (@($Verdicts) | ForEach-Object { "$(($_.Name -split ' ')[0])=$($_.Verdict)" }) -join ' '
}
function Get-SbQ6Summary([hashtable]$Over = @{}, [string]$Scene = 'app', [string]$Synth = 'align_left_button') {
    return Format-SbQ6 (Get-SbPaneVerdicts (New-SbQ6Fixture $Over) $Scene $Synth)
}
# Does ANY of a wait's patterns select a row? The wait's own question, asked the
# wait's own way (`Wait-SbRow` ends on the first pattern that selects).
function Test-SbQ6WaitEnds($Wait, $Rows) {
    foreach ($p in $Wait.Patterns) { if ($null -ne (Select-SbRow $Rows $p)) { return 'ENDS' } }
    return 'WAITS'
}
$q6AllPass = 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=PASS Q6.5=PASS Q6.C1=PASS Q6.C2=PASS'

# ---- the waits: which rows a run must wait for after its completion row ----
# `app`'s completion row is written BEFORE the pane opens, so a reader of the
# rows snapshotted at `Done` would find no pane at all.
Test-Case 'Q6 WAIT: a scene that opens no pane waits for nothing' `
    { @(Get-SbPaneWaits 'retained' 'align_left_button').Count } '0'
Test-Case 'Q6 WAIT: app without the replay waits for the drawn pane only' `
    { (@(Get-SbPaneWaits 'app' '') | ForEach-Object { $_.Label }) -join ' | ' } 'the PANEL DRAWN row'
Test-Case 'Q6 WAIT: app with the replay waits for the replay first, then the pane' `
    { (@(Get-SbPaneWaits 'app' 'align_left_button') | ForEach-Object { $_.Label }) -join ' | ' } 'the PANEL SYNTH DONE row | the PANEL DRAWN row'
# ⛔ THE SHELL'S PREDICATE, NOT A NEARBY ONE: whitespace is UNSET there
# (`string.IsNullOrWhiteSpace`), so a harness waiting on a replay the shell
# never queued would burn its whole timeout on every such run.
Test-Case 'Q6 WAIT: a whitespace knob is unset, exactly as the shell reads it' `
    { @(Get-SbPaneWaits 'app' '   ').Count } '1'
Test-Case 'Q6 WAIT: the pane wait ends on the drawn row' `
    { Test-SbQ6WaitEnds (@(Get-SbPaneWaits 'app' '')[0]) (New-SbQ6Fixture $q6NoSynth) } 'ENDS'
# ⛔ AND IT DOES NOT END ON A CLICK'S RED: a delta mismatch says nothing about
# whether the pane has been drawn, and ending there reads a drawn pane as absent.
Test-Case 'Q6 WAIT: the pane wait does not end on a click row''s RUSTFAIL' `
    { Test-SbQ6WaitEnds (@(Get-SbPaneWaits 'app' '')[0]) @(New-SbQ6Row "RUSTFAIL PANEL CLICK $q6Who via=synth:click outcome=changed changed-rows=1 doc-changed=true delta-mismatch=1 channel=(clear) $q6Tids") } 'WAITS'
Test-Case 'Q6 WAIT: the pane wait ends on the plan''s own refusal' `
    { Test-SbQ6WaitEnds (@(Get-SbPaneWaits 'app' '')[0]) @(New-SbQ6Row "RUSTFAIL PANEL REFUSED panel=align_panel_content cause=open -- jas_panel_plan returned the empty span $q6Tids") } 'ENDS'
Test-Case 'Q6 WAIT: the replay wait ends on the replay''s own refusal' `
    { Test-SbQ6WaitEnds (@(Get-SbPaneWaits 'app' 'x')[0]) @(New-SbQ6Row "RUSTFAIL PANEL SYNTH REFUSED panel=align_panel_content widget=x -- no leaf of the open plan has that id; it has 1: align_left_button $q6Tids") } 'ENDS'
Test-Case 'Q6 WAIT: the replay wait does not end on everything before its last row' `
    { Test-SbQ6WaitEnds (@(Get-SbPaneWaits 'app' 'align_left_button')[0]) (New-SbQ6Fixture @{ done = $null }) } 'WAITS'
Test-Case 'Q6 WAIT: CONTROL -- the replay wait ends on the healthy run' `
    { Test-SbQ6WaitEnds (@(Get-SbPaneWaits 'app' 'align_left_button')[0]) (New-SbQ6Fixture) } 'ENDS'

# ---- the verdicts -----------------------------------------------------------
Test-Case 'Q6: the healthy run passes every clause' { Get-SbQ6Summary } $q6AllPass
Test-Case 'Q6: a scene that opens no pane reads NOT RUN on every clause' `
    { Get-SbQ6Summary $q6NoSynth 'retained' '' } 'Q6.1=NOT RUN Q6.2=NOT RUN Q6.3=NOT RUN Q6.4=NOT RUN Q6.5=NOT RUN Q6.C1=NOT RUN Q6.C2=NOT RUN'
Test-Case 'Q6: app without the replay asserts the open and names the replay NOT RUN' `
    { Get-SbQ6Summary $q6NoSynth 'app' '' } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=NOT RUN Q6.5=NOT RUN Q6.C1=NOT RUN Q6.C2=NOT RUN'
# ⛔ THE KNOB ON A SCENE WITH NO PANE IS A FAILURE, NEVER A QUIET NOT RUN: the
# run was asked for a replay and the shell refused it.
Test-Case 'Q6: the replay asked on a scene with no pane FAILS Q6.4' `
    { Get-SbQ6Summary @{} 'retained' 'align_left_button' } 'Q6.1=NOT RUN Q6.2=NOT RUN Q6.3=NOT RUN Q6.4=FAIL Q6.5=NOT RUN Q6.C1=NOT RUN Q6.C2=NOT RUN'

# The open.
Test-Case 'Q6.1: no open row under app FAILS, and what reads it is NOT RUN' `
    { Get-SbQ6Summary @{ open = $null } } 'Q6.1=FAIL Q6.2=NOT RUN Q6.3=NOT RUN Q6.4=PASS Q6.5=PASS Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6.1: the plan''s own refusal FAILS and is quoted' `
    { $v = @(Get-SbPaneVerdicts (New-SbQ6Fixture @{ open = "RUSTFAIL PANEL REFUSED panel=align_panel_content cause=open -- jas_panel_plan returned the empty span $q6Tids" }) 'app' '')
      "$($v[0].Verdict) $($v[0].Row -match 'PANEL REFUSED')" } 'FAIL True'
Test-Case 'Q6.1: an unparseable plan FAILS' `
    { Get-SbQ6Summary @{ open = "PANEL OPEN panel=align_panel_content avail-w=228 plan=UNPARSEABLE(JsonException) crossings=2 bytes=10960 plan-bytes=10960 seq=1 $q6Tids" } } 'Q6.1=FAIL Q6.2=PASS Q6.3=NOT RUN Q6.4=PASS Q6.5=PASS Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6.1: a bound row the layout never placed FAILS' `
    { Get-SbQ6Summary @{ open = "PANEL OPEN panel=align_panel_content avail-w=228 leaves=22 chrome=0 containers=0 unjoined=1 withheld=0 icons=17 icons-missing=0 height=168 crossings=2 bytes=10960 plan-bytes=10960 seq=1 $q6Tids" } } 'Q6.1=FAIL Q6.2=PASS Q6.3=PASS Q6.4=PASS Q6.5=PASS Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6.2: three crossings FAIL' `
    { Get-SbQ6Summary @{ open = "PANEL OPEN panel=align_panel_content avail-w=228 leaves=22 chrome=0 containers=0 unjoined=0 withheld=0 icons=17 icons-missing=0 height=168 crossings=3 bytes=10960 plan-bytes=10960 seq=1 $q6Tids" } } 'Q6.1=PASS Q6.2=FAIL Q6.3=PASS Q6.4=PASS Q6.5=PASS Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6.2: an unreadable counter dump is NOT RUN, never a count' `
    { Get-SbQ6Summary @{ open = "PANEL OPEN panel=align_panel_content avail-w=228 leaves=22 chrome=0 containers=0 unjoined=0 withheld=0 icons=17 icons-missing=0 height=168 crossings=UNREADABLE bytes=UNREADABLE plan-bytes=10960 seq=1 $q6Tids" } } 'Q6.1=PASS Q6.2=NOT RUN Q6.3=PASS Q6.4=PASS Q6.5=PASS Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6.3: a drawn pane short of one control FAILS' `
    { Get-SbQ6Summary @{ drawn = 'PANEL DRAWN panel=align_panel_content seq=1 cause=open missed=0 rebuilt=true controls=21 disabled=15 checked=1 hidden=0 pane-dips=236x1350 canvas-dips=1668x900' } } 'Q6.1=PASS Q6.2=PASS Q6.3=FAIL Q6.4=PASS Q6.5=PASS Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6.3: a build short of one leaf FAILS' `
    { Get-SbQ6Summary @{ built = 'PANEL BUILT panel=align_panel_content build=1 leaves=21 texts=4 buttons=17 inputs=0 unmaterialized=0 unaddressable=0 icon-loads=17 icon-text=0' } } 'Q6.1=PASS Q6.2=PASS Q6.3=FAIL Q6.4=PASS Q6.5=PASS Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6.3: a pane never drawn FAILS' `
    { Get-SbQ6Summary @{ drawn = $null } } 'Q6.1=PASS Q6.2=PASS Q6.3=FAIL Q6.4=PASS Q6.5=PASS Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6.3: a draw that threw FAILS' `
    { Get-SbQ6Summary @{ drawn = 'RUSTFAIL PANEL DRAW threw KeyNotFoundException: The given key was not present in the dictionary.' } } 'Q6.1=PASS Q6.2=PASS Q6.3=FAIL Q6.4=PASS Q6.5=PASS Q6.C1=PASS Q6.C2=PASS'

# The replay.
Test-Case 'Q6: a replay that never finished reads NOT RUN, never PASS' `
    { Get-SbQ6Summary @{ done = $null } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=NOT RUN Q6.5=NOT RUN Q6.C1=NOT RUN Q6.C2=NOT RUN'
Test-Case 'Q6: a refused replay FAILS Q6.4 and quotes the refusal' `
    { $v = @(Get-SbPaneVerdicts (New-SbQ6Fixture @{ done = "RUSTFAIL PANEL SYNTH REFUSED $q6Who -- the open panel is '(none)' $q6Tids" }) 'app' 'align_left_button')
      "$(Format-SbQ6 $v) $($v[3].Row -match 'SYNTH REFUSED')" } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=FAIL Q6.5=NOT RUN Q6.C1=NOT RUN Q6.C2=NOT RUN True'
Test-Case 'Q6: a replay that threw FAILS Q6.4' `
    { Get-SbQ6Summary @{ done = "RUSTFAIL PANEL SYNTH THREW $q6Who InvalidOperationException: boom $q6Tids" } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=FAIL Q6.5=NOT RUN Q6.C1=NOT RUN Q6.C2=NOT RUN'
# ⛔ THE ANTI-VACUITY ARMS. An "unchanged" clause is an EQUALITY, and a hash
# that returns a constant satisfies every equality there is. So each equality
# needs its own instrument to have read at least two distinct values somewhere
# in this run, and Q6.5 needs the click to have moved something to restore.
Test-Case 'Q6.4: a click that did not move the canvas FAILS, and there is nothing for Q6.5 to restore' `
    { Get-SbQ6Summary @{ h1 = (New-SbQ6Hash 'SYNTH-H1' $q6HashS); h1b = (New-SbQ6Hash 'SYNTH-H1B' $q6HashS) } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=FAIL Q6.5=NOT RUN Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6: a canvas hash that never varies makes every canvas equality NOT RUN' `
    { Get-SbQ6Summary @{ hs = (New-SbQ6Hash 'SYNTH-HS' $q6HashA); h1 = (New-SbQ6Hash 'SYNTH-H1' $q6HashA)
                         h1b = (New-SbQ6Hash 'SYNTH-H1B' $q6HashA); h2 = (New-SbQ6Hash 'SYNTH-H2' $q6HashA) } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=FAIL Q6.5=NOT RUN Q6.C1=NOT RUN Q6.C2=NOT RUN'
Test-Case 'Q6: a document digest that never varies makes every document equality NOT RUN' `
    { Get-SbQ6Summary @{ done = (New-SbQ6Done "$q6DocA/$q6DocA/$q6DocA/$q6DocA/$q6DocA/$q6DocA") } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=FAIL Q6.5=NOT RUN Q6.C1=NOT RUN Q6.C2=NOT RUN'
Test-Case 'Q6.4: a click the core says moved nothing FAILS' `
    { Get-SbQ6Summary @{ c1 = "PANEL CLICK $q6Who via=synth:click outcome=unchanged changed-rows=0 doc-changed=false delta-mismatch=0 channel=$(New-SbQ6Channel 'Unchanged') $q6Tids" } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=FAIL Q6.5=PASS Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6.4: a click whose rows disagree with the plan FAILS' `
    { Get-SbQ6Summary @{ c1 = "RUSTFAIL PANEL CLICK $q6Who via=synth:click outcome=changed changed-rows=1 doc-changed=true delta-mismatch=1 channel=(clear) $q6Tids" } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=FAIL Q6.5=PASS Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6.4: a document the core did not re-serialize differently FAILS' `
    { Get-SbQ6Summary @{ done = (New-SbQ6Done "$q6DocA/$q6DocA/$q6DocS/$q6DocS/$q6DocS/$q6DocS") } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=FAIL Q6.5=NOT RUN Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6.4: fewer than two selected is NOT RUN -- Align has nothing to do' `
    { Get-SbQ6Summary @{ done = (New-SbQ6Done "$q6DocA/$q6DocA/$q6DocS/$q6DocM/$q6DocM/$q6DocS" '1') } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=NOT RUN Q6.5=PASS Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6.4: hashes taken at two surfaces are NOT RUN, never a difference' `
    { Get-SbQ6Summary @{ h1 = (New-SbQ6Hash 'SYNTH-H1' $q6HashM '1000x600') } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=NOT RUN Q6.5=NOT RUN Q6.C1=PASS Q6.C2=NOT RUN'
# The two ways a hash row is unreadable, one arm each so neither check can be
# dropped unseen: the shell's own RUSTFAIL over a well-formed hash, and a
# RUSTOK row whose hash is not 64 hex digits.
Test-Case 'Q6.4: a hash row the shell marked RUSTFAIL is NOT RUN, whatever it carries' `
    { Get-SbQ6Summary @{ h1 = "RUSTFAIL SYNTH-H1 surface=2502x1350 hash=$q6HashM engines-created=1 engines-freed=0 loads(shell)=1 $q6Tids" } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=NOT RUN Q6.5=NOT RUN Q6.C1=PASS Q6.C2=NOT RUN'
Test-Case 'Q6.4: a hash that is not 64 hex digits is NOT RUN' `
    { Get-SbQ6Summary @{ h1 = "RUSTOK SYNTH-H1 surface=2502x1350 hash=n/a engines-created=1 engines-freed=0 loads(shell)=1 $q6Tids" } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=NOT RUN Q6.5=NOT RUN Q6.C1=PASS Q6.C2=NOT RUN'
Test-Case 'Q6.5: an undo that did not restore the canvas FAILS' `
    { Get-SbQ6Summary @{ h2 = (New-SbQ6Hash 'SYNTH-H2' ('4' * 64)) } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=PASS Q6.5=FAIL Q6.C1=PASS Q6.C2=PASS'
# ⛔ THE SECOND METHOD ON THE SAME CLAIM: identical pixels over a different
# document is a defect the pixel hash alone would pass.
Test-Case 'Q6.5: an undo that restored the pixels and not the document FAILS' `
    { Get-SbQ6Summary @{ done = (New-SbQ6Done "$q6DocA/$q6DocA/$q6DocS/$q6DocM/$q6DocM/$('d' * 16)") } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=PASS Q6.5=FAIL Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6.5: an undo the core says applied nothing FAILS' `
    { Get-SbQ6Summary @{ undo = "RUSTOK SYNTH-UNDO applied=0 can-undo=true can-redo=false $q6Tids" } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=PASS Q6.5=FAIL Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6.5: an undo the core refused FAILS' `
    { Get-SbQ6Summary @{ undo = "RUSTFAIL SYNTH-UNDO status=2 (UNKNOWN) detail= $q6Tids" } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=PASS Q6.5=FAIL Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6.C1: a no-selection click answered Unchanged instead of Disabled FAILS' `
    { Get-SbQ6Summary @{ c0 = "PANEL CLICK REFUSED $q6Who via=synth:no-selection channel=$(New-SbQ6Channel 'Unchanged') $q6Tids" } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=PASS Q6.5=PASS Q6.C1=FAIL Q6.C2=PASS'
Test-Case 'Q6.C1: a no-selection click that RAN FAILS' `
    { Get-SbQ6Summary @{ c0 = "PANEL CLICK $q6Who via=synth:no-selection outcome=changed changed-rows=0 doc-changed=true delta-mismatch=0 channel=(clear) $q6Tids" } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=PASS Q6.5=PASS Q6.C1=FAIL Q6.C2=PASS'
Test-Case 'Q6.C1: a refused click that still moved the canvas FAILS' `
    { Get-SbQ6Summary @{ h0b = (New-SbQ6Hash 'SYNTH-H0B' ('5' * 64)) } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=PASS Q6.5=PASS Q6.C1=FAIL Q6.C2=PASS'
Test-Case 'Q6.C1: a missing hash row is NOT RUN, never an equality' `
    { Get-SbQ6Summary @{ h0b = $null } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=PASS Q6.5=PASS Q6.C1=NOT RUN Q6.C2=PASS'
Test-Case 'Q6.C1: a missing click row FAILS' `
    { Get-SbQ6Summary @{ c0 = $null } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=PASS Q6.5=PASS Q6.C1=FAIL Q6.C2=PASS'
Test-Case 'Q6.C2: an aligned selection that moved again FAILS' `
    { Get-SbQ6Summary @{ c2 = "PANEL CLICK $q6Who via=synth:again outcome=changed changed-rows=0 doc-changed=true delta-mismatch=0 channel=(clear) $q6Tids" } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=PASS Q6.5=PASS Q6.C1=PASS Q6.C2=FAIL'
Test-Case 'Q6.C2: a second click that moved the document FAILS' `
    { Get-SbQ6Summary @{ done = (New-SbQ6Done "$q6DocA/$q6DocA/$q6DocS/$q6DocM/$('e' * 16)/$q6DocS") } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=PASS Q6.5=PASS Q6.C1=PASS Q6.C2=FAIL'
Test-Case 'Q6: a doc-sha with the wrong number of parts is NOT RUN on every document claim' `
    { Get-SbQ6Summary @{ done = (New-SbQ6Done "$q6DocA/$q6DocA/$q6DocS/$q6DocM/$q6DocM") } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=NOT RUN Q6.5=NOT RUN Q6.C1=NOT RUN Q6.C2=NOT RUN'
# ⛔ A ROW FROM A HAND IS NOT A ROW FROM THE REPLAY. Provenance is on the row,
# and a reader that ignored it would convict the replay of a person's click.
Test-Case 'Q6: a HAND click is never read as a replay step' `
    { Get-SbQ6Summary @{ c1 = "PANEL CLICK $q6Who via=hand outcome=changed changed-rows=0 doc-changed=true delta-mismatch=0 channel=(clear) $q6Tids" } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=FAIL Q6.5=PASS Q6.C1=PASS Q6.C2=PASS'

# ---- one arm per decision the cases above leave unwitnessed ----------------
# No pwsh in the authoring seat, so no mutation pass over these readers ran.
# In its place every decision in `Get-SbPaneVerdicts` was walked by hand and
# given an arm that fails if that decision alone flips; these are the ones the
# cases above did not already reach.
Test-Case 'Q6.1: a plan with no leaves FAILS' `
    { Get-SbQ6Summary @{ open = "PANEL OPEN panel=align_panel_content avail-w=228 leaves=0 chrome=0 containers=0 unjoined=0 withheld=0 icons=0 icons-missing=0 height=0 crossings=2 bytes=40 plan-bytes=40 seq=1 $q6Tids" } } 'Q6.1=FAIL Q6.2=PASS Q6.3=FAIL Q6.4=PASS Q6.5=PASS Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6.3: a pane that never built FAILS' `
    { Get-SbQ6Summary @{ built = $null } } 'Q6.1=PASS Q6.2=PASS Q6.3=FAIL Q6.4=PASS Q6.5=PASS Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6: a digest the core could not give is NOT RUN on every document claim' `
    { Get-SbQ6Summary @{ done = (New-SbQ6Done "$q6DocA/EMPTY/$q6DocS/$q6DocM/$q6DocM/$q6DocS") } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=NOT RUN Q6.5=NOT RUN Q6.C1=NOT RUN Q6.C2=NOT RUN'
Test-Case 'Q6.4: a change the core says left the document alone FAILS' `
    { Get-SbQ6Summary @{ c1 = "PANEL CLICK $q6Who via=synth:click outcome=changed changed-rows=0 doc-changed=false delta-mismatch=0 channel=(clear) $q6Tids" } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=FAIL Q6.5=PASS Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6.4: a delta mismatch FAILS even on a row that lost its RUSTFAIL' `
    { Get-SbQ6Summary @{ c1 = "PANEL CLICK $q6Who via=synth:click outcome=changed changed-rows=1 doc-changed=true delta-mismatch=1 channel=(clear) $q6Tids" } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=FAIL Q6.5=PASS Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6.5: a replay with no undo row FAILS' `
    { Get-SbQ6Summary @{ undo = $null } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=PASS Q6.5=FAIL Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6.5: a missing after-undo hash is NOT RUN' `
    { Get-SbQ6Summary @{ h2 = $null } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=PASS Q6.5=NOT RUN Q6.C1=PASS Q6.C2=PASS'
Test-Case 'Q6.C1: a refused click that moved the document FAILS' `
    { Get-SbQ6Summary @{ done = (New-SbQ6Done "$q6DocA/$('f' * 16)/$q6DocS/$q6DocM/$q6DocM/$q6DocS") } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=PASS Q6.5=PASS Q6.C1=FAIL Q6.C2=PASS'
Test-Case 'Q6.C2: a missing second click FAILS' `
    { Get-SbQ6Summary @{ c2 = $null } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=PASS Q6.5=PASS Q6.C1=PASS Q6.C2=FAIL'
Test-Case 'Q6.C2: Unchanged over a document the core says changed FAILS' `
    { Get-SbQ6Summary @{ c2 = "PANEL CLICK $q6Who via=synth:again outcome=unchanged changed-rows=0 doc-changed=true delta-mismatch=0 channel=$(New-SbQ6Channel 'Unchanged') $q6Tids" } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=PASS Q6.5=PASS Q6.C1=PASS Q6.C2=FAIL'
Test-Case 'Q6.C2: an unchanged click with a clear channel FAILS -- the core must SAY so' `
    { Get-SbQ6Summary @{ c2 = "PANEL CLICK $q6Who via=synth:again outcome=unchanged changed-rows=0 doc-changed=false delta-mismatch=0 channel=(clear) $q6Tids" } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=PASS Q6.5=PASS Q6.C1=PASS Q6.C2=FAIL'
Test-Case 'Q6.C2: a second click the shell marked RUSTFAIL FAILS' `
    { Get-SbQ6Summary @{ c2 = "RUSTFAIL PANEL CLICK $q6Who via=synth:again outcome=unchanged changed-rows=0 doc-changed=false delta-mismatch=UNREADABLE(JsonException) channel=$(New-SbQ6Channel 'Unchanged') $q6Tids" } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=PASS Q6.5=PASS Q6.C1=PASS Q6.C2=FAIL'
Test-Case 'Q6.C2: a second click that moved the canvas FAILS' `
    { Get-SbQ6Summary @{ h1b = (New-SbQ6Hash 'SYNTH-H1B' ('6' * 64)) } } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=PASS Q6.5=PASS Q6.C1=PASS Q6.C2=FAIL'

# ⛔ EVERY CLAUSE ON EVERY PATH, EXACTLY ONCE. P4.3 vanished on one branch while
# its three siblings said NOT RUN; this is that defect's census, run over every
# variant above rather than over the healthy run alone.
Test-Case 'Q6: every path names all seven clauses exactly once' {
    $variants = @(
        @(@{}, 'app', 'align_left_button'), @($q6NoSynth, 'retained', ''), @($q6NoSynth, 'app', ''),
        @(@{}, 'retained', 'align_left_button'), @(@{ open = $null }, 'app', 'align_left_button'),
        @(@{ done = $null }, 'app', 'align_left_button'),
        @(@{ done = "RUSTFAIL PANEL SYNTH REFUSED $q6Who -- x $q6Tids" }, 'app', 'align_left_button'),
        @(@{ h1 = (New-SbQ6Hash 'SYNTH-H1' $q6HashS) }, 'app', 'align_left_button'),
        @(@{ done = (New-SbQ6Done 'x/y') }, 'app', 'align_left_button'))
    $bad = @()
    foreach ($x in $variants) {
        $names = @(@(Get-SbPaneVerdicts (New-SbQ6Fixture $x[0]) $x[1] $x[2]) | ForEach-Object { ($_.Name -split ' ')[0] })
        $want = 'Q6.1 Q6.2 Q6.3 Q6.4 Q6.5 Q6.C1 Q6.C2'
        if (($names -join ' ') -ne $want) { $bad += "[$($x[1])/$($x[2])] $($names -join ' ')" }
    }
    if ($bad.Count -eq 0) { "all $($variants.Count)" } else { $bad -join '; ' }
} 'all 9'
# ⛔ AND EVERY VERDICT CARRIES A DETAIL: a verdict with no evidence cannot be
# re-adjudicated by the person reading the sitting.
Test-Case 'Q6: every verdict on the healthy run carries a detail' `
    { @(@(Get-SbPaneVerdicts (New-SbQ6Fixture) 'app' 'align_left_button') | Where-Object { [string]::IsNullOrWhiteSpace($_.Detail) }).Count } '0'
# MUTATION CONTROL on the fixture itself: its hashes really are the shapes the
# cases above rely on, so a healthy PASS is not three identical strings.
Test-Case 'Q6: CONTROL -- the healthy fixture''s three canvases are distinct' `
    { @($q6HashA, $q6HashS, $q6HashM | Sort-Object -Unique).Count } '3'

# ---------------------------------------------------------------------------
# Q6.S5 -- FREEZE STOP 5, RE-AIMED (v1.7): OPENING THE PANE RESIZED NOTHING
# ---------------------------------------------------------------------------
#
# ⛔ STOP 5 AS FIRST WRITTEN COULD NOT GO RED. It predicted one resize per pane
# open. W2-5 puts the pane in the FIRST layout, so no route resizes the canvas,
# and kenai read 0 against 7 live REPAINT rows (flask). The stop is re-aimed at
# that zero, and it reads `events_total` because `cause=` is last-writer-wins
# inside a drain: a pointer or a click after a resize overwrites it, while
# `events_total` counts the ARRIVAL.
function New-SbS5Repaint([string]$Total, [string]$Cause, [string]$Head = 'RUSTOK REPAINT') {
    return ("$Head events_total=$Total distinct_sizes=1 arrivals=none frames=1 cause=$Cause resizes-in-drain=0 " +
        "surface=2502x1350 paint=1.20ms present=0.40ms occluded=0 loads(shell)=1 $q6Tids")
}
$s5Calm = @{ repaint = (New-SbS5Repaint '0' 'hash') }
function Get-SbS5([hashtable]$Over, [string]$Scene = 'app', [string]$Synth = 'align_left_button') {
    $o = @{}
    foreach ($k in $s5Calm.Keys) { $o[$k] = $s5Calm[$k] }
    foreach ($k in $Over.Keys) { $o[$k] = $Over[$k] }
    return (Get-SbPaneResizeVerdict (New-SbQ6Fixture $o) $Scene $Synth)
}

Test-Case 'Q6.S5: the q6 run with no resize PASSES' { (Get-SbS5 @{}).Verdict } 'PASS'
Test-Case 'Q6.S5: a resize that ARRIVED, its cause overwritten by a later command, FAILS' { (Get-SbS5 @{ repaint = (New-SbS5Repaint '1' 'pointer') }).Verdict } 'FAIL'
Test-Case 'Q6.S5: CONTROL -- that row carries no cause=resize, so a cause-only reading would pass it' { if ((New-SbS5Repaint '1' 'pointer') -match 'cause=resize') { 'resize' } else { 'no resize cause' } } 'no resize cause'
Test-Case 'Q6.S5: a resize that repainted as cause=resize FAILS' { (Get-SbS5 @{ repaint = (New-SbS5Repaint '1' 'resize') }).Verdict } 'FAIL'
Test-Case 'Q6.S5: ...and the detail names both readings' { $d = (Get-SbS5 @{ repaint = (New-SbS5Repaint '1' 'resize') }).Detail; if ($d -match 'events_total=1 ' -and $d -match 'cause=resize on 1 ') { 'named' } else { $d } } 'named'
Test-Case 'Q6.S5: a cause=resize row beside events_total=0 FAILS rather than trusting either' { (Get-SbS5 @{ repaint = (New-SbS5Repaint '0' 'resize') }).Verdict } 'FAIL'
Test-Case 'Q6.S5: events_total=3 FAILS -- the W2-6 fixture composed that value, and the box has not read it' { (Get-SbS5 @{ repaint = (New-SbS5Repaint '3' 'hash') }).Verdict } 'FAIL'
Test-Case 'Q6.S5: the LAST REPAINT row is the one read -- events_total is a running total' { $rows = @(New-SbQ6Fixture $s5Calm) + (New-SbQ6Row (New-SbS5Repaint '1' 'pointer')); (Get-SbPaneResizeVerdict $rows 'app' 'align_left_button').Verdict } 'FAIL'
Test-Case 'Q6.S5: a REPAINT-FAILED row is still read' { (Get-SbS5 @{ repaint = (New-SbS5Repaint '1' 'hash' 'RUSTFAIL REPAINT-FAILED') }).Verdict } 'FAIL'
Test-Case 'Q6.S5: CONTROL -- ...and a calm one PASSES, so the FAIL above is the total' { (Get-SbS5 @{ repaint = (New-SbS5Repaint '0' 'hash' 'RUSTFAIL REPAINT-FAILED') }).Verdict } 'PASS'
Test-Case 'Q6.S5: NOT RUN on a scene with no pane' { (Get-SbS5 @{} 'retained').Verdict } 'NOT RUN'
Test-Case 'Q6.S5: NOT RUN on an app run with no replay -- a hand may resize that window' { (Get-SbS5 @{} 'app' '').Verdict } 'NOT RUN'
Test-Case 'Q6.S5: CONTROL -- a whitespace knob is unset, as the shell reads it' { (Get-SbS5 @{} 'app' '  ').Verdict } 'NOT RUN'
Test-Case 'Q6.S5: NOT RUN when the pane never opened' { (Get-SbS5 @{ open = $null }).Verdict } 'NOT RUN'
Test-Case 'Q6.S5: NOT RUN with no REPAINT row -- a zero from an instrument that never ran is not a measurement' { $v = Get-SbS5 @{ repaint = $null }; if ($v.Verdict -eq 'NOT RUN' -and $v.Detail -match 'did not run') { 'declined' } else { "$($v.Verdict): $($v.Detail)" } } 'declined'
Test-Case 'Q6.S5: NOT RUN on an unreadable total' { (Get-SbS5 @{ repaint = (New-SbS5Repaint 'x' 'hash') }).Verdict } 'NOT RUN'
Test-Case 'Q6.S5: every path carries the Q6.S5 key and a detail' { $bad = 0; foreach ($v in @((Get-SbS5 @{}), (Get-SbS5 @{} 'retained'), (Get-SbS5 @{ open = $null }), (Get-SbS5 @{ repaint = $null }), (Get-SbS5 @{ repaint = (New-SbS5Repaint '1' 'resize') }))) { if ([string]::IsNullOrWhiteSpace($v.Detail) -or ($v.Name -split ' ')[0] -ne 'Q6.S5') { $bad++ } }; $bad } '0'

# ---------------------------------------------------------------------------
# V1-V6 -- THE MAGIC WAND VALUE REPLAY, READ OFF ITS OWN ROWS (W2b-3)
# ---------------------------------------------------------------------------
#
# ⛔ NO BOX HAS RUN W2b-3, SO THESE ROWS ARE NOT VERBATIM OFF kenai. Each is the
# literal its C# format string composes, copied from the C# and not from the Q6
# fixture above: `MainWindow.Report`'s log line, `Canvas.Tids()`,
# `Canvas.ApplyPanelOpen` (with `PlanReading`), `ClickHead` and the REFUSED /
# SILENT / ran forms of `ApplyPanelClick`, `ApplyMenuRefresh`,
# `ApplyPanelValueSynth` (DONE, REFUSED, THREW), `MainWindow.QueueValueSynth`,
# the SB_PANEL refusal in `StartFirstLayout`, `BuildPane` and `DrawPane`. The
# values are what the engine answers on the sitting's route
# (`panel_behavior_the_value_replay_on_the_sittings_panel`, and a probe of
# `jas_panel_plan` at 228: 13 leaves -- 5 toggles, 4 inputs, 4 texts -- 0 chrome,
# 0 containers, 0 unjoined, 0 withheld, 0 icons, height 164, 2102 bytes; the
# commit's reply carries one changed row and each press's two; the refusal's
# channel is `{"panel_event":"BadValue","detail":"mwp_fill_tolerance"}`). The
# menu `seq` and the tids are fill. A reader that disagrees with a real row is
# this file's defect, not the app's.
#
# ⚠️ WRITTEN RED-FIRST AGAINST STUBS THAT RETURN NOTHING (W2-6's shape). An arm
# whose expected answer IS "nothing" (`0`, `(null)`, `WAITS`, `[]`) passes on the
# stub; every other arm is red until the readers land.
function New-SbMwRow([string]$Status) {
    return "09:14:03`tSB_MODE=(default:offscreen)`tSB_SIZE=(window)`tSB_FRAMES=(default:60)`t" + $Status
}
$mwTids = 'ui-tid=2 render-tid=5 paint-tid=5 present-tid=5 render-has-dispatcher=false'
$mwPanel = 'magic_wand_panel_content'
$mwCommit = 'mwp_fill_tolerance'
$mwPress = 'mwp_fill_color'
$mwIds = 'mwp_blending_mode,mwp_fill_color,mwp_fill_tolerance,mwp_opacity,mwp_opacity_tolerance,mwp_stroke_color,mwp_stroke_tolerance,mwp_stroke_weight,mwp_stroke_weight_tolerance'

# `ClickHead`: panel= widget= via= event= value= (value is `PanelWire.RowValue`).
function New-SbMwHead([string]$Widget, [string]$Via, [string]$EventName, [string]$Value) {
    return "panel=$mwPanel widget=$Widget via=$Via event=$EventName value=$Value"
}
function New-SbMwChannel([string]$Class, [string]$Detail) {
    return '{"panel_event":"' + $Class + '","detail":"' + $Detail + '"}'
}
# A click that ran: `PANEL CLICK {head} outcome= changed-rows= doc-changed=
# delta-mismatch= channel= {tids}`, with `RUSTFAIL ` in front when the
# mismatch is not `0` -- the shell's own rule.
function New-SbMwRan([string]$Widget, [string]$Via, [string]$EventName, [string]$Value, [string]$Changed,
                     [string]$Outcome = 'changed', [string]$Mismatch = '0', [string]$Channel = '(clear)') {
    $head = New-SbMwHead $Widget $Via $EventName $Value
    $row = "PANEL CLICK $head outcome=$Outcome changed-rows=$Changed doc-changed=false delta-mismatch=$Mismatch channel=$Channel $mwTids"
    if ($Mismatch -ne '0') { return "RUSTFAIL $row" }
    return $row
}
function New-SbMwRefused([string]$Widget, [string]$Via, [string]$EventName, [string]$Value, [string]$Class) {
    $head = New-SbMwHead $Widget $Via $EventName $Value
    $channel = New-SbMwChannel $Class $Widget
    return "PANEL CLICK REFUSED $head channel=$channel $mwTids"
}
function New-SbMwDone([string]$Value = '32/32/40/40/40', [string]$Disabled = 'false/false/false/true/false',
                      [string]$Checked = 'true/true/true/false/true', [string]$Commit = 'mwp_fill_tolerance',
                      [string]$Press = 'mwp_fill_color', [string]$Panel = 'magic_wand_panel_content') {
    return "PANEL VALUE SYNTH DONE panel=$Panel commit=$Commit text=`"40`" press=$Press value=$Value disabled=$Disabled checked=$Checked $mwTids"
}
function New-SbMwOpen([string]$Panel = 'magic_wand_panel_content', [string]$Via = 'app', [string]$Reading = 'leaves=13 chrome=0 containers=0 unjoined=0 withheld=0 icons=0 icons-missing=0 height=164') {
    return "PANEL OPEN panel=$Panel via=$Via avail-w=228 $Reading crossings=2 bytes=2102 plan-bytes=2102 seq=1 $mwTids"
}
$mwRefusedDone = "RUSTFAIL PANEL VALUE SYNTH REFUSED panel=$mwPanel commit=$mwCommit text=`"40`" press=mwp_fill_colour -- 'mwp_fill_colour': no leaf of the open plan has that id; it has 9: $mwIds $mwTids"
$mwThrewDone = "RUSTFAIL PANEL VALUE SYNTH THREW panel=$mwPanel commit=$mwCommit text=`"40`" press=$mwPress InvalidOperationException: boom $mwTids"
$mwKnobRefusal = "RUSTFAIL PANEL VALUE SYNTH REFUSED panel=$mwPanel commit-knob=- press-knob=`"mwp_fill_color`" -- SB_PANEL_PRESS is set and SB_PANEL_COMMIT is not; the replay needs both"
$mwSceneRefusal = "RUSTFAIL PANEL VALUE SYNTH REFUSED panel=align_panel_content commit-knob=`"mwp_fill_tolerance:40`" press-knob=`"mwp_fill_color`" -- the value replay needs SB_SCENE=app, the one scene that opens the pane; this run is 'retained'"
$mwFirstRefusal = "RUSTFAIL PANEL FIRST REFUSED panel=`"magic_wand_panel_content`" -- SB_PANEL needs SB_SCENE=app, the one scene that opens the pane; this run is 'retained'"
# Heads and rows the arms below splice into a longer row, built here so no arm
# nests a quoted argument inside a string's subexpression.
$mwBadHead = New-SbMwHead 'mwp_fill_tolerance' 'synth:bad' 'commit' '"abc"'
$mwCommitHead = New-SbMwHead 'mwp_fill_tolerance' 'synth:commit' 'commit' '"40"'
$mwCleanCommit = New-SbMwRan 'mwp_fill_tolerance' 'synth:commit' 'commit' '"40"' '1'

# The whole run, in the order the shell writes it. `$Over` replaces a step by
# key and a `$null` value DELETES it, as Q6's fixture does, so each variant
# below is a named mutation of the healthy run.
function New-SbMwFixture([hashtable]$Over = @{}) {
    $steps = [ordered]@{
        open    = (New-SbMwOpen)
        built   = 'PANEL BUILT panel=magic_wand_panel_content build=1 leaves=13 texts=4 buttons=0 inputs=4 toggles=5 unmaterialized=0 unaddressable=0 icon-loads=0 icon-text=0'
        drawn   = 'PANEL DRAWN panel=magic_wand_panel_content seq=1 cause=open missed=0 rebuilt=true controls=13 disabled=0 checked=4 hidden=0 editing=0 pane-dips=237x1350 canvas-dips=1668x900'
        bad     = (New-SbMwRefused 'mwp_fill_tolerance' 'synth:bad' 'commit' '"abc"' 'BadValue')
        menu1   = "MENU PUBLISHED seq=3 cause=panel $mwTids"
        commit  = (New-SbMwRan 'mwp_fill_tolerance' 'synth:commit' 'commit' '"40"' '1')
        menu2   = "MENU PUBLISHED seq=4 cause=panel $mwTids"
        press   = (New-SbMwRan 'mwp_fill_color' 'synth:press' 'click' '-' '2')
        menu3   = "MENU PUBLISHED seq=5 cause=panel $mwTids"
        again   = (New-SbMwRan 'mwp_fill_color' 'synth:press-again' 'click' '-' '2')
        done    = (New-SbMwDone)
        done2   = $null
        drawn2  = 'PANEL DRAWN panel=magic_wand_panel_content seq=6 cause=synth missed=4 rebuilt=false controls=13 disabled=0 checked=4 hidden=0 editing=0 pane-dips=237x1350 canvas-dips=1668x900'
    }
    foreach ($k in $Over.Keys) {
        if (-not $steps.Contains($k)) { throw "New-SbMwFixture: no step '$k'" }
        $steps[$k] = $Over[$k]
    }
    $out = @()
    foreach ($k in $steps.Keys) {
        if ($null -ne $steps[$k]) { $out += (New-SbMwRow $steps[$k]) }
    }
    return $out
}
$mwNoReplay = @{ bad = $null; menu1 = $null; commit = $null; menu2 = $null; press = $null; menu3 = $null
                 again = $null; done = $null; drawn2 = $null }

# `V1=PASS V2=PASS ...`, in the order the reader emits them.
function Format-SbV($Verdicts) {
    return (@($Verdicts) | ForEach-Object { "$(($_.Name -split ' ')[0])=$($_.Verdict)" }) -join ' '
}
function Get-SbVRun([hashtable]$Over = @{}, [string]$Scene = 'app', [string]$Commit = 'mwp_fill_tolerance:40',
                    [string]$Press = 'mwp_fill_color', [string]$Panel = 'magic_wand_panel_content') {
    return @(Get-SbValueVerdicts (New-SbMwFixture $Over) $Scene $Commit $Press $Panel)
}
function Get-SbVSummary([hashtable]$Over = @{}, [string]$Scene = 'app', [string]$Commit = 'mwp_fill_tolerance:40',
                        [string]$Press = 'mwp_fill_color', [string]$Panel = 'magic_wand_panel_content') {
    return Format-SbV (Get-SbVRun $Over $Scene $Commit $Press $Panel)
}
function Show-SbSplit($Split) {
    if ($null -eq $Split) { return '(null)' }
    return "$($Split.Widget)|$($Split.Text)"
}
$vAllPass = 'V1=PASS V2=PASS V3=PASS V4=PASS V5=PASS V6=PASS'
$vAllNotRun = 'V1=NOT RUN V2=NOT RUN V3=NOT RUN V4=NOT RUN V5=NOT RUN V6=NOT RUN'
$vReplayRefused = 'V1=PASS V2=FAIL V3=NOT RUN V4=NOT RUN V5=NOT RUN V6=NOT RUN'
$vNoReadings = 'V1=PASS V2=NOT RUN V3=NOT RUN V4=NOT RUN V5=NOT RUN V6=FAIL'

# ---- the knob, split by the shell's rule (PanelWire.SplitCommitKnob) --------
Test-Case 'V KNOB: the commit knob splits at the first colon' { Show-SbSplit (Split-SbCommitKnob 'mwp_fill_tolerance:40') } 'mwp_fill_tolerance|40'
Test-Case 'V KNOB: a colon after the first stays in the text' { Show-SbSplit (Split-SbCommitKnob 'w:a:b') } 'w|a:b'
Test-Case 'V KNOB: the text is kept verbatim, spaces and all' { Show-SbSplit (Split-SbCommitKnob 'w: 4 0 ') } 'w| 4 0 '
Test-Case 'V KNOB: an empty text is a text' { Show-SbSplit (Split-SbCommitKnob 'w:') } 'w|'
Test-Case 'V KNOB: a knob with no colon is refused' { Show-SbSplit (Split-SbCommitKnob 'mwp_fill_tolerance') } '(null)'
Test-Case 'V KNOB: an empty widget is refused' { Show-SbSplit (Split-SbCommitKnob ':40') } '(null)'
Test-Case 'V KNOB: a whitespace widget is refused, the knob''s own unset predicate' { Show-SbSplit (Split-SbCommitKnob '  :40') } '(null)'
Test-Case 'V KNOB: an empty knob is refused' { Show-SbSplit (Split-SbCommitKnob '') } '(null)'
Test-Case 'V ASKED: either value knob alone is asked' { "$(Test-SbValueAsked 'w:1' '') $(Test-SbValueAsked '' 'p')" } 'True True'
Test-Case 'V ASKED: whitespace knobs are unset' { "$(Test-SbValueAsked ' ' '  ')" } 'False'
Test-Case 'P4.4 REPLAY: Q6''s knob alone runs a replay' { "$(Test-SbPaneReplayAsked 'align_left_button' '' '')" } 'True'
Test-Case 'P4.4 REPLAY: both value knobs run a replay' { "$(Test-SbPaneReplayAsked '' 'w:1' 'p')" } 'True'
Test-Case 'P4.4 REPLAY: one value knob alone runs none -- the shell refuses it' { "$(Test-SbPaneReplayAsked '' 'w:1' '') $(Test-SbPaneReplayAsked '' '' 'p')" } 'False False'
Test-Case 'P4.4 REPLAY: no knob runs none, and whitespace is unset' { "$(Test-SbPaneReplayAsked ' ' ' ' ' ')" } 'False'

# ---- V3's grammar: which texts the core writes back byte for byte -----------
Test-Case 'V3 GRAMMAR: an integer is canonical' { "$(Test-SbCanonicalNumber '40')" } 'True'
Test-Case 'V3 GRAMMAR: zero is canonical' { "$(Test-SbCanonicalNumber '0')" } 'True'
Test-Case 'V3 GRAMMAR: a negative decimal is canonical' { "$(Test-SbCanonicalNumber '-2.5')" } 'True'
Test-Case 'V3 GRAMMAR: a zero before the point is not a leading zero' { "$(Test-SbCanonicalNumber '0.5')" } 'True'
Test-Case 'V3 GRAMMAR: a leading zero is not canonical' { "$(Test-SbCanonicalNumber '040')" } 'False'
Test-Case 'V3 GRAMMAR: a trailing .0 is not canonical' { "$(Test-SbCanonicalNumber '5.0')" } 'False'
Test-Case 'V3 GRAMMAR: a trailing zero after the point is not canonical' { "$(Test-SbCanonicalNumber '1.50')" } 'False'
Test-Case 'V3 GRAMMAR: minus zero is not canonical' { "$(Test-SbCanonicalNumber '-0')" } 'False'
Test-Case 'V3 GRAMMAR: letters are outside the grammar' { "$(Test-SbCanonicalNumber 'abc')" } 'False'
Test-Case 'V3 GRAMMAR: the empty text is outside the grammar' { "$(Test-SbCanonicalNumber '')" } 'False'
Test-Case 'V3 GRAMMAR: a leading plus is outside the grammar' { "$(Test-SbCanonicalNumber '+40')" } 'False'
Test-Case 'V3 GRAMMAR: surrounding spaces are outside the grammar' { "$(Test-SbCanonicalNumber ' 40')" } 'False'
Test-Case 'V3 GRAMMAR: a bare trailing point is outside the grammar' { "$(Test-SbCanonicalNumber '40.')" } 'False'
# ⛔ .NET's `$` ALSO MATCHES BEFORE A FINAL NEWLINE, so a `^...$` grammar would
# take "40`n" as 40. The reader anchors with `\z`.
Test-Case 'V3 GRAMMAR: a trailing newline is outside the grammar' { $t = "40`n"; "$(Test-SbCanonicalNumber $t)" } 'False'
Test-Case 'V3 GRAMMAR: a non-ASCII digit is outside the grammar' { $t = [string][char]0x0664 + '0'; "$(Test-SbCanonicalNumber $t)" } 'False'

# ---- the waits ----------------------------------------------------------------
Test-Case 'V WAIT: a scene that opens no pane waits for no value row' { @(Get-SbValueWaits 'retained' 'mwp_fill_tolerance:40' 'mwp_fill_color').Count } '0'
Test-Case 'V WAIT: app with no value knob waits for no value row' { @(Get-SbValueWaits 'app' '' '').Count } '0'
Test-Case 'V WAIT: whitespace knobs are unset, exactly as the shell reads them' { @(Get-SbValueWaits 'app' '  ' ' ').Count } '0'
Test-Case 'V WAIT: app with the value knobs waits for the done row' { (@(Get-SbValueWaits 'app' 'mwp_fill_tolerance:40' 'mwp_fill_color') | ForEach-Object { $_.Label }) -join ' | ' } 'the PANEL VALUE SYNTH DONE row'
Test-Case 'V WAIT: the done wait ends on the healthy run' { Test-SbQ6WaitEnds (@(Get-SbValueWaits 'app' 'mwp_fill_tolerance:40' 'mwp_fill_color')[0]) (New-SbMwFixture) } 'ENDS'
Test-Case 'V WAIT: the done wait does not end on the rows before the done row' { Test-SbQ6WaitEnds (@(Get-SbValueWaits 'app' 'mwp_fill_tolerance:40' 'mwp_fill_color')[0]) (New-SbMwFixture @{ done = $null; drawn2 = $null }) } 'WAITS'
Test-Case 'V WAIT: one knob alone still waits, and ends on the shell''s refusal' { Test-SbQ6WaitEnds (@(Get-SbValueWaits 'app' '' 'mwp_fill_color')[0]) @(New-SbMwRow $mwKnobRefusal) } 'ENDS'
Test-Case 'V WAIT: the done wait ends on the render thread''s refusal' { Test-SbQ6WaitEnds (@(Get-SbValueWaits 'app' 'mwp_fill_tolerance:40' 'mwp_fill_colour')[0]) @(New-SbMwRow $mwRefusedDone) } 'ENDS'
Test-Case 'V WAIT: the done wait ends on the replay''s throw' { Test-SbQ6WaitEnds (@(Get-SbValueWaits 'app' 'mwp_fill_tolerance:40' 'mwp_fill_color')[0]) @(New-SbMwRow $mwThrewDone) } 'ENDS'
# ⛔ AND ON NOTHING ELSE: a plan refusal or a click's red can arrive mid-replay,
# and a wait that ended there would snapshot the rows before the done row.
Test-Case 'V WAIT: the done wait does not end on a click row''s RUSTFAIL' { Test-SbQ6WaitEnds (@(Get-SbValueWaits 'app' 'mwp_fill_tolerance:40' 'mwp_fill_color')[0]) @(New-SbMwRow (New-SbMwRan 'mwp_fill_tolerance' 'synth:commit' 'commit' '"40"' '1' 'changed' '1')) } 'WAITS'
Test-Case 'V WAIT: the done wait does not end on a plan refusal' { Test-SbQ6WaitEnds (@(Get-SbValueWaits 'app' 'mwp_fill_tolerance:40' 'mwp_fill_color')[0]) @(New-SbMwRow "RUSTFAIL PANEL REFUSED panel=$mwPanel cause=synth -- jas_panel_plan returned the empty span $mwTids") } 'WAITS'
Test-Case 'V WAIT: the done wait does not end on Q6''s done row' { Test-SbQ6WaitEnds (@(Get-SbValueWaits 'app' 'mwp_fill_tolerance:40' 'mwp_fill_color')[0]) @(New-SbQ6Row (New-SbQ6Done "$q6DocA/$q6DocA/$q6DocS/$q6DocM/$q6DocM/$q6DocS")) } 'WAITS'
# CONTROLS the other way: Q6's wait is not ended by the value replay's rows.
Test-Case 'V WAIT: CONTROL -- Q6''s replay wait does not end on the value done row' { Test-SbQ6WaitEnds (@(Get-SbPaneWaits 'app' 'align_left_button')[0]) @(New-SbMwRow (New-SbMwDone)) } 'WAITS'
Test-Case 'V WAIT: CONTROL -- Q6''s replay wait does not end on the value refusal' { Test-SbQ6WaitEnds (@(Get-SbPaneWaits 'app' 'align_left_button')[0]) @(New-SbMwRow $mwRefusedDone) } 'WAITS'
Test-Case 'V WAIT: CONTROL -- the pane wait does not end on the SB_PANEL refusal' { Test-SbQ6WaitEnds (@(Get-SbPaneWaits 'app' '')[0]) @(New-SbMwRow $mwFirstRefusal) } 'WAITS'

# ---- the verdicts: which knobs ask for what -----------------------------------
Test-Case 'V: the healthy replay passes every clause' { Get-SbVSummary } $vAllPass
Test-Case 'V: a scene with no pane and no knob reads NOT RUN on every clause' { Get-SbVSummary $mwNoReplay 'retained' '' '' '' } $vAllNotRun
Test-Case 'V: app with no knob reads NOT RUN on every clause' { Get-SbVSummary $mwNoReplay 'app' '' '' '' } $vAllNotRun
Test-Case 'V: whitespace knobs are unset, exactly as the shell reads them' { Get-SbVSummary $mwNoReplay 'app' ' ' '  ' ' ' } $vAllNotRun
Test-Case 'V: app with SB_PANEL alone asserts the open and names the replay NOT RUN' { Get-SbVSummary $mwNoReplay 'app' '' '' 'magic_wand_panel_content' } 'V1=PASS V2=NOT RUN V3=NOT RUN V4=NOT RUN V5=NOT RUN V6=NOT RUN'
# ⛔ A KNOB ON A SCENE WITH NO PANE IS A FAILURE, NEVER A QUIET NOT RUN (Q6's rule).
Test-Case 'V: SB_PANEL on a scene with no pane FAILS V1' { Get-SbVSummary @{ open = $mwFirstRefusal } 'retained' '' '' 'magic_wand_panel_content' } 'V1=FAIL V2=NOT RUN V3=NOT RUN V4=NOT RUN V5=NOT RUN V6=NOT RUN'
Test-Case 'V: ...and V1 quotes the shell''s refusal' { $v = Get-SbVRun @{ open = $mwFirstRefusal } 'retained' '' '' 'magic_wand_panel_content'; "$($v[0].Verdict) $($v[0].Row -match 'PANEL FIRST REFUSED')" } 'FAIL True'
Test-Case 'V: ...and says so when the shell wrote no refusal' { $v = Get-SbVRun $mwNoReplay 'retained' '' '' 'magic_wand_panel_content'; if ($v[0].Verdict -eq 'FAIL' -and $v[0].Detail -match 'wrote NO refusal') { 'named' } else { "$($v[0].Verdict): $($v[0].Detail)" } } 'named'
Test-Case 'V: the value knobs on a scene with no pane FAIL V2' { Get-SbVSummary @{ done = $mwSceneRefusal } 'retained' 'mwp_fill_tolerance:40' 'mwp_fill_color' '' } 'V1=NOT RUN V2=FAIL V3=NOT RUN V4=NOT RUN V5=NOT RUN V6=NOT RUN'
Test-Case 'V: ...and V2 quotes the shell''s refusal' { $v = Get-SbVRun @{ done = $mwSceneRefusal } 'retained' 'mwp_fill_tolerance:40' 'mwp_fill_color' ''; "$($v[1].Verdict) $($v[1].Row -match 'VALUE SYNTH REFUSED')" } 'FAIL True'
Test-Case 'V: ...and says so when the shell wrote no refusal' { $v = Get-SbVRun $mwNoReplay 'retained' 'mwp_fill_tolerance:40' 'mwp_fill_color' ''; if ($v[1].Verdict -eq 'FAIL' -and $v[1].Detail -match 'wrote NO refusal') { 'named' } else { "$($v[1].Verdict): $($v[1].Detail)" } } 'named'
Test-Case 'V: both kinds of knob on a scene with no pane FAIL V1 and V2' { Get-SbVSummary $mwNoReplay 'retained' 'mwp_fill_tolerance:40' 'mwp_fill_color' 'magic_wand_panel_content' } 'V1=FAIL V2=FAIL V3=NOT RUN V4=NOT RUN V5=NOT RUN V6=NOT RUN'

# ---- V1: the open -----------------------------------------------------------------
Test-Case 'V1: no open row FAILS' { Get-SbVSummary @{ open = $null } } 'V1=FAIL V2=PASS V3=PASS V4=PASS V5=PASS V6=PASS'
Test-Case 'V1: the core''s refusal of the plan FAILS and is quoted' { $v = Get-SbVRun @{ open = "RUSTFAIL PANEL REFUSED panel=$mwPanel cause=open -- jas_panel_plan returned the empty span $mwTids" }; "$(Format-SbV $v) $($v[0].Row -match 'PANEL REFUSED')" } 'V1=FAIL V2=PASS V3=PASS V4=PASS V5=PASS V6=PASS True'
Test-Case 'V1: an open of another panel than SB_PANEL FAILS' { Get-SbVSummary @{ open = (New-SbMwOpen 'align_panel_content') } } 'V1=FAIL V2=PASS V3=PASS V4=PASS V5=PASS V6=PASS'
Test-Case 'V1: the panel id compares ordinally, so a case change is another panel' { Get-SbVSummary @{ open = (New-SbMwOpen 'Magic_Wand_Panel_Content') } } 'V1=FAIL V2=PASS V3=PASS V4=PASS V5=PASS V6=PASS'
Test-Case 'V1: a hand''s open is not the app''s open' { Get-SbVSummary @{ open = (New-SbMwOpen 'magic_wand_panel_content' 'hand') } } 'V1=FAIL V2=PASS V3=PASS V4=PASS V5=PASS V6=PASS'
Test-Case 'V1: an open with no leaves FAILS' { Get-SbVSummary @{ open = (New-SbMwOpen 'magic_wand_panel_content' 'app' 'leaves=0 chrome=0 containers=0 unjoined=0 withheld=0 icons=0 icons-missing=0 height=0') } } 'V1=FAIL V2=PASS V3=PASS V4=PASS V5=PASS V6=PASS'
Test-Case 'V1: an open with a bound row the layout never placed FAILS' { Get-SbVSummary @{ open = (New-SbMwOpen 'magic_wand_panel_content' 'app' 'leaves=13 chrome=0 containers=0 unjoined=1 withheld=0 icons=0 icons-missing=0 height=164') } } 'V1=FAIL V2=PASS V3=PASS V4=PASS V5=PASS V6=PASS'
Test-Case 'V1: an open whose plan did not parse FAILS' { Get-SbVSummary @{ open = (New-SbMwOpen 'magic_wand_panel_content' 'app' 'plan=UNPARSEABLE(JsonException)') } } 'V1=FAIL V2=PASS V3=PASS V4=PASS V5=PASS V6=PASS'
Test-Case 'V1: with SB_PANEL unset, the panel the app opened is judged' { Get-SbVSummary @{ open = (New-SbMwOpen 'align_panel_content'); done = (New-SbMwDone -Panel 'align_panel_content') } 'app' 'mwp_fill_tolerance:40' 'mwp_fill_color' '' } $vAllPass
Test-Case 'V1: ...and the detail says SB_PANEL is unset' { $v = Get-SbVRun @{} 'app' 'mwp_fill_tolerance:40' 'mwp_fill_color' ''; if ($v[0].Verdict -eq 'PASS' -and $v[0].Detail -match 'SB_PANEL is unset') { 'named' } else { "$($v[0].Verdict): $($v[0].Detail)" } } 'named'
Test-Case 'V1: ...and an unset SB_PANEL still FAILS an open with no leaves' { Get-SbVSummary @{ open = (New-SbMwOpen 'magic_wand_panel_content' 'app' 'leaves=0 chrome=0 containers=0 unjoined=0 withheld=0 icons=0 icons-missing=0 height=0') } 'app' 'mwp_fill_tolerance:40' 'mwp_fill_color' '' } 'V1=FAIL V2=PASS V3=PASS V4=PASS V5=PASS V6=PASS'

# ---- V2: the refused commit ---------------------------------------------------------
Test-Case 'V2: abc accepted FAILS' { Get-SbVSummary @{ bad = (New-SbMwRan 'mwp_fill_tolerance' 'synth:bad' 'commit' '"abc"' '1') } } 'V1=PASS V2=FAIL V3=PASS V4=PASS V5=PASS V6=PASS'
Test-Case 'V2: abc refused with another class FAILS' { Get-SbVSummary @{ bad = (New-SbMwRefused 'mwp_fill_tolerance' 'synth:bad' 'commit' '"abc"' 'MissingValue') } } 'V1=PASS V2=FAIL V3=PASS V4=PASS V5=PASS V6=PASS'
Test-Case 'V2: abc refused Disabled FAILS -- the class is the claim' { Get-SbVSummary @{ bad = (New-SbMwRefused 'mwp_fill_tolerance' 'synth:bad' 'commit' '"abc"' 'Disabled') } } 'V1=PASS V2=FAIL V3=PASS V4=PASS V5=PASS V6=PASS'
Test-Case 'V2: a silent bad step FAILS' { Get-SbVSummary @{ bad = "RUSTFAIL PANEL CLICK SILENT $mwBadHead -- an empty reply and an empty error channel $mwTids" } } 'V1=PASS V2=FAIL V3=PASS V4=PASS V5=PASS V6=PASS'
Test-Case 'V2: a missing bad row FAILS' { Get-SbVSummary @{ bad = $null } } 'V1=PASS V2=FAIL V3=PASS V4=PASS V5=PASS V6=PASS'
Test-Case 'V2: a bad row on another widget FAILS' { Get-SbVSummary @{ bad = (New-SbMwRefused 'mwp_stroke_tolerance' 'synth:bad' 'commit' '"abc"' 'BadValue') } } 'V1=PASS V2=FAIL V3=PASS V4=PASS V5=PASS V6=PASS'
Test-Case 'V2: a HAND commit is never read as the bad step' { Get-SbVSummary @{ bad = (New-SbMwRefused 'mwp_fill_tolerance' 'hand' 'commit' '"abc"' 'BadValue') } } 'V1=PASS V2=FAIL V3=PASS V4=PASS V5=PASS V6=PASS'
Test-Case 'V2: a refused commit that moved the value FAILS' { Get-SbVSummary @{ done = (New-SbMwDone -Value '32/33/40/40/40') } } 'V1=PASS V2=FAIL V3=PASS V4=PASS V5=PASS V6=PASS'
Test-Case 'V2: a refused commit that moved disabled FAILS' { Get-SbVSummary @{ done = (New-SbMwDone -Disabled 'false/true/false/true/false') } } 'V1=PASS V2=FAIL V3=PASS V4=PASS V5=PASS V6=PASS'
Test-Case 'V2: a refused commit that moved checked FAILS' { Get-SbVSummary @{ done = (New-SbMwDone -Checked 'true/false/true/false/true') } } 'V1=PASS V2=FAIL V3=PASS V4=PASS V5=PASS V6=PASS'
Test-Case 'V2: ...and the detail quotes both readings' { $d = (Get-SbVRun @{ done = (New-SbMwDone -Value '32/33/40/40/40') })[1].Detail; if ($d -match 'value=32/33') { 'quoted' } else { $d } } 'quoted'
Test-Case 'V2: a replay the render thread refused FAILS V2 and quotes it' { $v = Get-SbVRun @{ done = $mwRefusedDone }; "$(Format-SbV $v) $($v[1].Row -match 'VALUE SYNTH REFUSED')" } "$vReplayRefused True"
Test-Case 'V2: a replay that threw FAILS V2' { Get-SbVSummary @{ done = $mwThrewDone } } $vReplayRefused
Test-Case 'V2: a press knob without a commit knob FAILS V2' { Get-SbVSummary @{ done = $mwKnobRefusal } 'app' '' 'mwp_fill_color' } $vReplayRefused
Test-Case 'V2: a commit knob without a press knob FAILS V2' { Get-SbVSummary @{ done = $mwKnobRefusal } 'app' 'mwp_fill_tolerance:40' '' } $vReplayRefused
Test-Case 'V2: a commit knob with no colon FAILS V2' { Get-SbVSummary @{ done = $mwKnobRefusal } 'app' 'mwp_fill_tolerance' 'mwp_fill_color' } $vReplayRefused
Test-Case 'V2: a commit knob with an empty widget FAILS V2' { Get-SbVSummary @{ done = $mwKnobRefusal } 'app' ':40' 'mwp_fill_color' } $vReplayRefused
# ⛔ THE KNOBS ARE JUDGED BY THE SHELL'S RULES, NOT BY WHAT THE SHELL WROTE: a
# pair the shell must refuse is a FAIL even beside a done row.
Test-Case 'V2: a knob pair the shell must refuse FAILS even when a done row arrived' { $v = Get-SbVRun @{} 'app' 'mwp_fill_tolerance:40' ''; if ((Format-SbV $v) -eq $vReplayRefused -and $v[1].Detail -match 'wrote NO refusal') { 'named' } else { "$(Format-SbV $v): $($v[1].Detail)" } } 'named'

# ---- V3: the commit ------------------------------------------------------------------
Test-Case 'V3: a commit that did not reach the text FAILS' { Get-SbVSummary @{ done = (New-SbMwDone -Value '32/32/41/41/41') } } 'V1=PASS V2=PASS V3=FAIL V4=PASS V5=PASS V6=PASS'
Test-Case 'V3: ...and the detail quotes the value and the text' { $d = (Get-SbVRun @{ done = (New-SbMwDone -Value '32/32/41/41/41') })[2].Detail; if ($d -match '41' -and $d -match "'40'") { 'quoted' } else { $d } } 'quoted'
Test-Case 'V3: a commit the core answered Unchanged FAILS' { Get-SbVSummary @{ commit = (New-SbMwRan 'mwp_fill_tolerance' 'synth:commit' 'commit' '"40"' '0' 'unchanged' '0' (New-SbMwChannel 'Unchanged' 'mwp_fill_tolerance')) } } 'V1=PASS V2=PASS V3=FAIL V4=PASS V5=PASS V6=PASS'
Test-Case 'V3: a commit whose rows disagree with the plan FAILS' { Get-SbVSummary @{ commit = (New-SbMwRan 'mwp_fill_tolerance' 'synth:commit' 'commit' '"40"' '1' 'changed' '1') } } 'V1=PASS V2=PASS V3=FAIL V4=PASS V5=PASS V6=PASS'
Test-Case 'V3: a delta mismatch FAILS even on a row that lost its RUSTFAIL' { Get-SbVSummary @{ commit = "PANEL CLICK $mwCommitHead outcome=changed changed-rows=1 doc-changed=false delta-mismatch=1 channel=(clear) $mwTids" } } 'V1=PASS V2=PASS V3=FAIL V4=PASS V5=PASS V6=PASS'
Test-Case 'V3: an unchecked delta FAILS' { Get-SbVSummary @{ commit = (New-SbMwRan 'mwp_fill_tolerance' 'synth:commit' 'commit' '"40"' '1' 'changed' 'UNCHECKED') } } 'V1=PASS V2=PASS V3=FAIL V4=PASS V5=PASS V6=PASS'
Test-Case 'V3: a row the shell marked RUSTFAIL FAILS, whatever it carries' { Get-SbVSummary @{ commit = "RUSTFAIL $mwCleanCommit" } } 'V1=PASS V2=PASS V3=FAIL V4=PASS V5=PASS V6=PASS'
Test-Case 'V3: a commit refused by the core FAILS' { Get-SbVSummary @{ commit = (New-SbMwRefused 'mwp_fill_tolerance' 'synth:commit' 'commit' '"40"' 'BadValue') } } 'V1=PASS V2=PASS V3=FAIL V4=PASS V5=PASS V6=PASS'
Test-Case 'V3: a missing commit row FAILS' { Get-SbVSummary @{ commit = $null } } 'V1=PASS V2=PASS V3=FAIL V4=PASS V5=PASS V6=PASS'
Test-Case 'V3: a commit row on another widget FAILS' { Get-SbVSummary @{ commit = (New-SbMwRan 'mwp_stroke_tolerance' 'synth:commit' 'commit' '"40"' '1') } } 'V1=PASS V2=PASS V3=FAIL V4=PASS V5=PASS V6=PASS'
Test-Case 'V3: a HAND commit is never read as the commit step' { Get-SbVSummary @{ commit = (New-SbMwRan 'mwp_fill_tolerance' 'hand' 'commit' '"40"' '1') } } 'V1=PASS V2=PASS V3=FAIL V4=PASS V5=PASS V6=PASS'
Test-Case 'V3: a text the value already holds is NOT RUN -- the commit could not be seen' { Get-SbVSummary @{} 'app' 'mwp_fill_tolerance:32' } 'V1=PASS V2=PASS V3=NOT RUN V4=PASS V5=PASS V6=PASS'
Test-Case 'V3: a text with a leading zero is NOT RUN' { Get-SbVSummary @{} 'app' 'mwp_fill_tolerance:040' } 'V1=PASS V2=PASS V3=NOT RUN V4=PASS V5=PASS V6=PASS'
Test-Case 'V3: a text with a trailing .0 is NOT RUN' { Get-SbVSummary @{} 'app' 'mwp_fill_tolerance:40.0' } 'V1=PASS V2=PASS V3=NOT RUN V4=PASS V5=PASS V6=PASS'
Test-Case 'V3: a text outside the grammar is NOT RUN' { Get-SbVSummary @{} 'app' 'mwp_fill_tolerance:forty' } 'V1=PASS V2=PASS V3=NOT RUN V4=PASS V5=PASS V6=PASS'
Test-Case 'V3: ...and the detail names the text' { $d = (Get-SbVRun @{} 'app' 'mwp_fill_tolerance:forty')[2].Detail; if ($d -match "'forty'") { 'named' } else { $d } } 'named'
Test-Case 'V3: the text is the one after the FIRST colon' { Get-SbVSummary @{} 'app' 'mwp_fill_tolerance:40:1' } 'V1=PASS V2=PASS V3=NOT RUN V4=PASS V5=PASS V6=PASS'

# ---- V4: the press -------------------------------------------------------------------
# One reading changed per arm. Where the change leaves an instrument reading a
# single value across the run, V5's equality has nothing to prove and says so --
# that second move is the anti-vacuity rule, and the arm names both.
Test-Case 'V4: a press that did not flip checked FAILS, and V5 has nothing to restore' { Get-SbVSummary @{ done = (New-SbMwDone -Checked 'true/true/true/true/true') } } 'V1=PASS V2=NOT RUN V3=PASS V4=FAIL V5=NOT RUN V6=PASS'
Test-Case 'V4: ...and alone, with checked varying elsewhere, only V4 moves' { Get-SbVSummary @{ done = (New-SbMwDone -Checked 'false/false/true/true/true') } } 'V1=PASS V2=PASS V3=PASS V4=FAIL V5=PASS V6=PASS'
Test-Case 'V4: a press that flipped checked and not disabled FAILS' { Get-SbVSummary @{ done = (New-SbMwDone -Disabled 'true/true/false/false/false') } } 'V1=PASS V2=PASS V3=PASS V4=FAIL V5=PASS V6=PASS'
Test-Case 'V4: a press that moved the value FAILS' { Get-SbVSummary @{ done = (New-SbMwDone -Value '32/32/40/41/40') } } 'V1=PASS V2=PASS V3=PASS V4=FAIL V5=PASS V6=PASS'
Test-Case 'V4: a press the core answered Unchanged FAILS' { Get-SbVSummary @{ press = (New-SbMwRan 'mwp_fill_color' 'synth:press' 'click' '-' '0' 'unchanged' '0' (New-SbMwChannel 'Unchanged' 'mwp_fill_color')) } } 'V1=PASS V2=PASS V3=PASS V4=FAIL V5=PASS V6=PASS'
Test-Case 'V4: a press the core refused FAILS' { Get-SbVSummary @{ press = (New-SbMwRefused 'mwp_fill_color' 'synth:press' 'click' '-' 'Disabled') } } 'V1=PASS V2=PASS V3=PASS V4=FAIL V5=PASS V6=PASS'
Test-Case 'V4: a press with a delta mismatch FAILS' { Get-SbVSummary @{ press = (New-SbMwRan 'mwp_fill_color' 'synth:press' 'click' '-' '2' 'changed' '1') } } 'V1=PASS V2=PASS V3=PASS V4=FAIL V5=PASS V6=PASS'
Test-Case 'V4: a press row on another widget FAILS' { Get-SbVSummary @{ press = (New-SbMwRan 'mwp_stroke_color' 'synth:press' 'click' '-' '2') } } 'V1=PASS V2=PASS V3=PASS V4=FAIL V5=PASS V6=PASS'
Test-Case 'V4: a missing press row FAILS -- it is never read off the press-again row' { Get-SbVSummary @{ press = $null } } 'V1=PASS V2=PASS V3=PASS V4=FAIL V5=PASS V6=PASS'
Test-Case 'V4: a HAND press is never read as the press step' { Get-SbVSummary @{ press = (New-SbMwRan 'mwp_fill_color' 'hand' 'click' '-' '2') } } 'V1=PASS V2=PASS V3=PASS V4=FAIL V5=PASS V6=PASS'
# ⛔ THE ANTI-VACUITY ARM. An equality proves nothing from an instrument that
# reads one value throughout, so a value that never moved leaves every value
# equality NOT RUN -- the shape a stubbed or dead reader would produce.
Test-Case 'V: a value that never varied makes every value equality NOT RUN' { Get-SbVSummary @{ done = (New-SbMwDone -Value '40/40/40/40/40') } } 'V1=PASS V2=NOT RUN V3=NOT RUN V4=NOT RUN V5=NOT RUN V6=PASS'
Test-Case 'V: STUB readings are values to V6, and V3 and V4 catch them' { Get-SbVSummary @{ done = (New-SbMwDone -Value 'STUB/STUB/STUB/STUB/STUB' -Disabled 'STUB/STUB/STUB/STUB/STUB' -Checked 'STUB/STUB/STUB/STUB/STUB') } } 'V1=PASS V2=NOT RUN V3=FAIL V4=FAIL V5=NOT RUN V6=PASS'

# ---- V5: the second press ------------------------------------------------------------
Test-Case 'V5: a second press that did not restore checked FAILS' { Get-SbVSummary @{ done = (New-SbMwDone -Checked 'true/true/true/false/false') } } 'V1=PASS V2=PASS V3=PASS V4=PASS V5=FAIL V6=PASS'
Test-Case 'V5: a second press that did not restore disabled FAILS' { Get-SbVSummary @{ done = (New-SbMwDone -Disabled 'false/false/false/true/true') } } 'V1=PASS V2=PASS V3=PASS V4=PASS V5=FAIL V6=PASS'
Test-Case 'V5: a second press that moved the value FAILS' { Get-SbVSummary @{ done = (New-SbMwDone -Value '32/32/40/40/41') } } 'V1=PASS V2=PASS V3=PASS V4=PASS V5=FAIL V6=PASS'
Test-Case 'V5: ...and the detail quotes all three readings' { $d = (Get-SbVRun @{ done = (New-SbMwDone -Value '32/32/40/40/41') })[4].Detail; if ($d -match '41' -and $d -match 'checked=' -and $d -match 'disabled=') { 'quoted' } else { $d } } 'quoted'
Test-Case 'V5: a second press the core answered Unchanged FAILS' { Get-SbVSummary @{ again = (New-SbMwRan 'mwp_fill_color' 'synth:press-again' 'click' '-' '0' 'unchanged' '0' (New-SbMwChannel 'Unchanged' 'mwp_fill_color')) } } 'V1=PASS V2=PASS V3=PASS V4=PASS V5=FAIL V6=PASS'
Test-Case 'V5: a second press with a delta mismatch FAILS' { Get-SbVSummary @{ again = (New-SbMwRan 'mwp_fill_color' 'synth:press-again' 'click' '-' '2' 'changed' '1') } } 'V1=PASS V2=PASS V3=PASS V4=PASS V5=FAIL V6=PASS'
Test-Case 'V5: a second press on another widget FAILS' { Get-SbVSummary @{ again = (New-SbMwRan 'mwp_stroke_color' 'synth:press-again' 'click' '-' '2') } } 'V1=PASS V2=PASS V3=PASS V4=PASS V5=FAIL V6=PASS'
Test-Case 'V5: a missing second press row FAILS' { Get-SbVSummary @{ again = $null } } 'V1=PASS V2=PASS V3=PASS V4=PASS V5=FAIL V6=PASS'
Test-Case 'V5: a disabled reading that never varied is NOT RUN, never an equality' { Get-SbVSummary @{ done = (New-SbMwDone -Disabled 'false/false/false/false/false') } } 'V1=PASS V2=NOT RUN V3=PASS V4=FAIL V5=NOT RUN V6=PASS'

# ---- V6: the done row ----------------------------------------------------------------
Test-Case 'V6: no done row FAILS, and every reading clause is NOT RUN' { Get-SbVSummary @{ done = $null } } $vNoReadings
Test-Case 'V6: two done rows FAIL' { Get-SbVSummary @{ done2 = (New-SbMwDone) } } $vNoReadings
Test-Case 'V6: an ABSENT reading FAILS' { Get-SbVSummary @{ done = (New-SbMwDone -Value '32/32/40/40/ABSENT') } } $vNoReadings
Test-Case 'V6: an UNREADABLE reading FAILS' { Get-SbVSummary @{ done = (New-SbMwDone -Checked 'UNREADABLE/true/true/false/true') } } $vNoReadings
Test-Case 'V6: ...and the detail names the field' { $d = (Get-SbVRun @{ done = (New-SbMwDone -Checked 'UNREADABLE/true/true/false/true') })[5].Detail; if ($d -match 'checked=UNREADABLE') { 'named' } else { $d } } 'named'
Test-Case 'V6: a field with four readings FAILS' { Get-SbVSummary @{ done = (New-SbMwDone -Disabled 'false/false/true/false') } } $vNoReadings
Test-Case 'V6: a reading broken by whitespace FAILS by its part count' { Get-SbVSummary @{ done = (New-SbMwDone -Value '32/32/4 0/40/40') } } $vNoReadings
Test-Case 'V6: a done row with no value field FAILS' { Get-SbVSummary @{ done = "PANEL VALUE SYNTH DONE panel=$mwPanel commit=$mwCommit text=`"40`" press=$mwPress disabled=false/false/false/true/false checked=true/true/true/false/true $mwTids" } } $vNoReadings
Test-Case 'V6: a done row naming another commit widget FAILS' { Get-SbVSummary @{ done = (New-SbMwDone -Commit 'mwp_stroke_tolerance') } } $vNoReadings
Test-Case 'V6: a done row naming another press widget FAILS' { Get-SbVSummary @{ done = (New-SbMwDone -Press 'mwp_stroke_color') } } $vNoReadings
Test-Case 'V6: a done row naming another panel than SB_PANEL FAILS' { Get-SbVSummary @{ done = (New-SbMwDone -Panel 'align_panel_content') } } $vNoReadings
Test-Case 'V6: with SB_PANEL unset, a done row naming another panel than the open FAILS' { Get-SbVSummary @{ done = (New-SbMwDone -Panel 'align_panel_content') } 'app' 'mwp_fill_tolerance:40' 'mwp_fill_color' '' } $vNoReadings
Test-Case 'V6: the done row is matched by its own label, never by Q6''s' { Get-SbVSummary @{ done = (New-SbQ6Done "$q6DocA/$q6DocA/$q6DocS/$q6DocM/$q6DocM/$q6DocS") } } $vNoReadings

# ---- the census, the details, and the controls ---------------------------------------
# ⛔ EVERY CLAUSE ON EVERY PATH, EXACTLY ONCE (Q6's census, for V).
Test-Case 'V: every path names all six clauses exactly once' {
    $variants = @(
        @(@{}, 'app', 'mwp_fill_tolerance:40', 'mwp_fill_color', 'magic_wand_panel_content'),
        @($mwNoReplay, 'retained', '', '', ''), @($mwNoReplay, 'app', '', '', ''),
        @($mwNoReplay, 'app', '', '', 'magic_wand_panel_content'),
        @($mwNoReplay, 'retained', 'mwp_fill_tolerance:40', 'mwp_fill_color', 'magic_wand_panel_content'),
        @(@{ open = $null }, 'app', 'mwp_fill_tolerance:40', 'mwp_fill_color', 'magic_wand_panel_content'),
        @(@{ done = $mwRefusedDone }, 'app', 'mwp_fill_tolerance:40', 'mwp_fill_color', 'magic_wand_panel_content'),
        @(@{}, 'app', 'mwp_fill_tolerance:40', '', 'magic_wand_panel_content'),
        @(@{ done = $null }, 'app', 'mwp_fill_tolerance:40', 'mwp_fill_color', 'magic_wand_panel_content'),
        @(@{ done = (New-SbMwDone -Value '40/40/40/40/40') }, 'app', 'mwp_fill_tolerance:40', 'mwp_fill_color', ''),
        @(@{}, 'app', 'mwp_fill_tolerance:forty', 'mwp_fill_color', 'magic_wand_panel_content'))
    $bad = @()
    foreach ($x in $variants) {
        $names = @(@(Get-SbValueVerdicts (New-SbMwFixture $x[0]) $x[1] $x[2] $x[3] $x[4]) | ForEach-Object { ($_.Name -split ' ')[0] })
        if (($names -join ' ') -ne 'V1 V2 V3 V4 V5 V6') { $bad += "[$($x[1])/$($x[2])/$($x[3])] $($names -join ' ')" }
    }
    if ($bad.Count -eq 0) { "all $($variants.Count)" } else { $bad -join '; ' }
} 'all 11'
# ⛔ AND EVERY VERDICT CARRIES A DETAIL, IN ASCII: the Windows console is cp1252.
Test-Case 'V: every verdict on every census path carries an ASCII detail' {
    $bad = 0
    foreach ($r in @((Get-SbVRun), (Get-SbVRun $mwNoReplay 'retained' '' '' ''), (Get-SbVRun @{ open = $null }),
                     (Get-SbVRun @{ done = $null }), (Get-SbVRun @{} 'app' 'mwp_fill_tolerance:forty'),
                     (Get-SbVRun $mwNoReplay 'retained' 'mwp_fill_tolerance:40' 'mwp_fill_color' 'magic_wand_panel_content'))) {
        foreach ($v in @($r)) {
            if ([string]::IsNullOrWhiteSpace($v.Detail) -or ("$($v.Name)$($v.Detail)" -match '[^\x20-\x7E]')) { $bad++ }
        }
    }
    $bad
} '0'
Test-Case 'V: the clause names are V1 to V6, in order' { (@($SbValueNames.Values) | ForEach-Object { ($_ -split ' ')[0] }) -join ' ' } 'V1 V2 V3 V4 V5 V6'
# MUTATION CONTROL on the fixture itself: each instrument in the healthy done
# row really reads two values, so the healthy PASS is not an equality of constants.
Test-Case 'V: CONTROL -- the healthy done row''s readings each take two values' {
    $done = New-SbMwDone
    (@('value', 'disabled', 'checked') | ForEach-Object { @((Get-SbField $done $_) -split '/' | Sort-Object -Unique).Count }) -join ' '
} '2 2 2'
# The value run is read by Q6 too, and neither family may misread the other.
Test-Case 'V: CONTROL -- Q6 reads the value run''s pane and names its own replay NOT RUN' { Format-SbQ6 (Get-SbPaneVerdicts (New-SbMwFixture) 'app' '') } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=NOT RUN Q6.5=NOT RUN Q6.C1=NOT RUN Q6.C2=NOT RUN'
Test-Case 'V: CONTROL -- the value replay''s rows are never read as Q6''s replay' { Format-SbQ6 (Get-SbPaneVerdicts (New-SbMwFixture) 'app' 'align_left_button') } 'Q6.1=PASS Q6.2=PASS Q6.3=PASS Q6.4=NOT RUN Q6.5=NOT RUN Q6.C1=NOT RUN Q6.C2=NOT RUN'

# ---------------------------------------------------------------------------
Write-Host ""
$cases | ForEach-Object { Write-Host $_ }
Write-Host ""
Write-Host ("--- $pass passed, $fail failed, of {0} case(s) ---" -f ($pass + $fail))
if ($fail -gt 0) { exit 1 }
exit 0
