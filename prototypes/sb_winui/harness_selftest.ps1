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
Write-Host ""
$cases | ForEach-Object { Write-Host $_ }
Write-Host ""
Write-Host ("--- $pass passed, $fail failed, of {0} case(s) ---" -f ($pass + $fail))
if ($fail -gt 0) { exit 1 }
exit 0
