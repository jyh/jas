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
# It is a test of six string readers and it must never be read as more.
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

# ---------------------------------------------------------------------------
Write-Host ""
$cases | ForEach-Object { Write-Host $_ }
Write-Host ""
Write-Host ("--- $pass passed, $fail failed, of {0} case(s) ---" -f ($pass + $fail))
if ($fail -gt 0) { exit 1 }
exit 0
