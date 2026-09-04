# verify_assertions.ps1 -- the canvas freeze's observables, asserted against the
# rows one run wrote. DOT-SOURCED by `verify_window.ps1`, which owns the run.
#
# ⛔ EVERY ASSERTION HERE HAS THREE POSSIBLE VERDICTS AND `NOT RUN` IS A FIRST-
# CLASS ONE. An assertion whose precondition is absent -- a row the scene never
# wrote, a control run nobody supplied, a knob nobody set -- says so BY NAME and
# is counted separately. It never passes by default, because a check that
# examines nothing returns success and looks exactly like a measurement.
#
# ⛔ AND EVERY ASSERTION PRINTS THE ROW IT READ. A verdict without its evidence
# cannot be re-adjudicated by the person reading the PR, which is the only
# adjudication that happens for a measurement taken on somebody else's box.
#
# WHAT IS AND IS NOT DECIDED HERE: the numbers are the shell's; this file only
# compares them. Where a comparison needs a figure from OUTSIDE the run (O2's
# "before", O1's probe-frame capture, O1's `document` control) the figure is a
# PARAMETER and its absence is a `NOT RUN`, never a default.

# ---------------------------------------------------------------------------
# Shared readings
# ---------------------------------------------------------------------------
$tidRows = @($rows | Where-Object { $_ -match 'ui-tid=[0-9]+' })

# ⛔ THE RESIDENCY CLAUSE IS ABOUT ROWS THAT PAINTED, AND NOT EVERY ROW CARRYING
# THE TID TAIL PAINTED. Measured on kenai 2026-09-03 (PR #110): `DUMP` rows carry
# the tail with `paint-tid=0` -- there was no paint, so there is no painting
# thread to report -- and asserting `paint-tid == present-tid == render-tid` over
# them prices a frame that does not exist. It happened to hold there; on a run
# where it does not, the red would name a thread that never ran.
#
# So the subject of O3.1 is rows with a NON-ZERO `paint-tid`, and THE COUNT IS
# PRINTED. A count is the one thing this assertion cannot do without: a check that
# examines nothing returns success and looks exactly like a measurement, so zero
# painting rows is `NOT RUN`, never a pass.
#
# ⛔ AND THE SUBJECT OF BOTH O3 CLAUSES IS THE ROWS THE RENDER THREAD WROTE.
# This is F-A, and it was 8 of the second sitting's 11 FAILs -- one row, repeated
# once per run. `STARTUP` is written at first layout ON THE UI THREAD, before the
# render thread exists, so it carried `render-tid=0 paint-tid=0 present-tid=0
# render-has-dispatcher=true` and O3.2 convicted the render thread of a flag
# describing the XAML one. PR #115 deliberately left O3.2 "over every row
# carrying the tail" because that clause is about the THREAD and holds on a row
# that painted nothing -- TRUE of every row the shell wrote AT THE TIME, and the
# shell wave then added one that carries the tail from the UI thread. The same
# wave-boundary failure mode one row further on.
#
# The shell now prints `n/a` on such a row; `Test-SbRenderThreadRow` requires a
# NON-ZERO INTEGER, so `n/a` and the pre-repair `0` are both excluded and this
# harness reads a bisected build correctly. THE COUNT IS PRINTED and zero is
# `NOT RUN`, because a check that examines nothing returns success.
$renderRows = @($tidRows | Where-Object { Test-SbRenderThreadRow $_ })
$paintingRows = @($renderRows | Where-Object {
    $pt = Get-SbField $_ 'paint-tid'
    ($null -ne $pt) -and ($pt -ne '0')
})
$paintOnUi = ($env:SB_PAINT_ON_UI -eq '1')
$uiStallMs = Get-KnobMs 'SB_UI_STALL_MS'
$renderStallMs = Get-KnobMs 'SB_RENDER_STALL_MS'
$synthAsked = -not [string]::IsNullOrWhiteSpace($env:SB_SYNTH_DRAG)

# The hash rows carry the completion-row verdict prefix since this PR; the
# pattern is built by `Get-SbRowPattern` (harness_common.ps1) so the waits and
# the readers share one definition of what a completion row looks like.
function Get-SbHashRow([string]$label) {
    return Select-SbRow $rows (Get-SbRowPattern $label ' surface=')
}

# ===========================================================================
# O3 -- RESIDENCY BY TIDS, LIVENESS BY `Responding`
# Asserted on EVERY scene, because the claim is about every row.
# ===========================================================================

$renderScope = "$($renderRows.Count) of this run's $($tidRows.Count) tid row(s) were written by the render thread (render-tid is a non-zero integer) and are the subject; the other $($tidRows.Count - $renderRows.Count) read render-tid=n/a or render-tid=0 and were written before the render thread existed"

if ($tidRows.Count -eq 0) {
    Add-NotRun 'O3.1 paint-tid == present-tid == render-tid != ui-tid (rows that PAINTED)' `
        "this run wrote no row carrying the tid tail -- there is nothing to assert residency over"
    Add-NotRun 'O3.2 render-has-dispatcher=false (rows the RENDER THREAD wrote)' `
        "this run wrote no row carrying the tid tail"
} elseif ($renderRows.Count -eq 0) {
    # ⛔ NOT A PASS. Zero examined rows is the shape that returns success and
    # looks exactly like a measurement.
    Add-NotRun 'O3.1 paint-tid == present-tid == render-tid != ui-tid (rows that PAINTED)' `
        "NOT RUN: no row of this run was written by the render thread. $renderScope"
    Add-NotRun 'O3.2 render-has-dispatcher=false (rows the RENDER THREAD wrote)' `
        "NOT RUN: no row of this run was written by the render thread, so there is no thread to make the claim about. $renderScope" -Row $tidRows[-1]
} elseif ($paintingRows.Count -eq 0) {
    Add-NotRun 'O3.1 paint-tid == present-tid == render-tid != ui-tid (rows that PAINTED)' `
        "the render thread wrote $($renderRows.Count) row(s) and NONE of them painted (every one reads paint-tid=0, as a DUMP row does). Residency is a claim about a painted frame, and there is no painted frame here to make it about. $renderScope"
    if ($paintOnUi) {
        Add-NotRun 'O3.C2 SB_PAINT_ON_UI=1 design-red control' `
            "the control needs a row that PAINTED to break, and this run wrote none ($($renderRows.Count) render-thread row(s), all paint-tid=0)"
    }
    $dispBad = @($renderRows | Where-Object { (Get-SbField $_ 'render-has-dispatcher') -ne 'false' })
    if ($dispBad.Count -eq 0) {
        Add-Assert -Name 'O3.2 render-has-dispatcher=false (rows the RENDER THREAD wrote)' -Verdict 'PASS' `
            -Detail "all $($renderRows.Count) rows the render thread wrote (this clause is about the THREAD and holds on a row that painted nothing, which is why it is not restricted to painting rows). $renderScope" -Row $renderRows[-1]
    } else {
        Add-Assert -Name 'O3.2 render-has-dispatcher=false (rows the RENDER THREAD wrote)' -Verdict 'FAIL' `
            -Detail "$($dispBad.Count) of $($renderRows.Count) rows the render thread wrote report a dispatcher on it. $renderScope" -Row $dispBad[0]
    }
} else {
    $tidBad = @()
    foreach ($r in $paintingRows) {
        $ui = Get-SbField $r 'ui-tid'
        $rt = Get-SbField $r 'render-tid'
        $pt = Get-SbField $r 'paint-tid'
        $st = Get-SbField $r 'present-tid'
        if ($null -eq $ui -or $null -eq $rt -or $null -eq $pt -or $null -eq $st) { continue }
        if (-not ($pt -eq $st -and $st -eq $rt -and $rt -ne $ui)) { $tidBad += $r }
    }
    $tidScope = "$($paintingRows.Count) of the $($renderRows.Count) row(s) the render thread wrote painted (paint-tid != 0) and are the subject; the other $($renderRows.Count - $paintingRows.Count) carry paint-tid=0. $renderScope"
    if ($paintOnUi) {
        # ⛔ THE DESIGN-RED CONTROL. Under SB_PAINT_ON_UI=1 the paint and the
        # present are marshalled through the dispatcher, so `present-tid ==
        # ui-tid` BY CONSTRUCTION. A tid assertion that PASSES here has not been
        # shown capable of failing anywhere, and that is itself the failure --
        # this is the arm that makes every other green mean something.
        if ($tidBad.Count -gt 0) {
            Add-Assert -Name 'O3.C2 SB_PAINT_ON_UI=1 design-red control' -Verdict 'PASS' `
                -Detail "the tid assertion FAILED on $($tidBad.Count) of $($paintingRows.Count) PAINTING rows, as it must under this knob. $tidScope" `
                -Row $tidBad[0]
        } else {
            Add-Assert -Name 'O3.C2 SB_PAINT_ON_UI=1 design-red control' -Verdict 'FAIL' `
                -Detail "the tid assertion PASSED on all $($paintingRows.Count) PAINTING rows under SB_PAINT_ON_UI=1. A passing residency assertion under the knob that exists to break it means the assertion cannot fail -- so every green it has ever produced is uninterpretable. $tidScope" `
                -Row $paintingRows[-1]
        }
        Add-NotRun 'O3.1 paint-tid == present-tid == render-tid != ui-tid (rows that PAINTED)' `
            'SB_PAINT_ON_UI=1 is set: this run is the design-red control, not a residency measurement'
    } else {
        if ($tidBad.Count -eq 0) {
            Add-Assert -Name 'O3.1 paint-tid == present-tid == render-tid != ui-tid (rows that PAINTED)' -Verdict 'PASS' `
                -Detail "all $($paintingRows.Count) painting rows of this run. $tidScope" -Row $paintingRows[-1]
        } else {
            Add-Assert -Name 'O3.1 paint-tid == present-tid == render-tid != ui-tid (rows that PAINTED)' -Verdict 'FAIL' `
                -Detail "$($tidBad.Count) of $($paintingRows.Count) painting rows do not hold it. $tidScope" -Row $tidBad[0]
        }
    }

    $dispBad = @($renderRows | Where-Object { (Get-SbField $_ 'render-has-dispatcher') -ne 'false' })
    if ($dispBad.Count -eq 0) {
        Add-Assert -Name 'O3.2 render-has-dispatcher=false (rows the RENDER THREAD wrote)' -Verdict 'PASS' `
            -Detail "all $($renderRows.Count) rows the render thread wrote. $renderScope" -Row $renderRows[-1]
    } else {
        Add-Assert -Name 'O3.2 render-has-dispatcher=false (rows the RENDER THREAD wrote)' -Verdict 'FAIL' `
            -Detail "$($dispBad.Count) of $($renderRows.Count) rows the render thread wrote report a dispatcher on it. $renderScope" -Row $dispBad[0]
    }
}

# ---- liveness, sampled IN SESSION 1, during the stall -----------------------
#
# ⛔ THE SESSION-0 READING IS A NOTE AND NOTHING ELSE. PR #110 measured it
# VACUOUS: `MainWindowHandle` is 0 across the session boundary, and
# `Process.Responding` returns True whenever the handle is 0 -- proved by a
# positive control (the reading shell, which has no window at all, also read
# True). It is still printed beside the session-1 samples because two arms side by
# side are the evidence for retiring it; no assertion reads it.
#
# ⛔ `@(2, 5, 10 | ForEach-Object {...})` PIPES ONLY THE 10. The pipeline binds
# tighter than the comma, so that spelling would have reported one sample and
# called it three -- a summary that silently under-counts its own evidence.
$samples = @(@(2, 5, 10) | ForEach-Object { "t=$($_)s:$(if ($respond.ContainsKey($_)) { $respond[$_] } else { 'not sampled' })" })
$sampleText = 'session-0 (VACUOUS, note only): ' + ($samples -join ' ')

$liveSamples = @(@(2, 5, 10) | ForEach-Object {
    if ($live.ContainsKey($_)) { "t=$($_)s:handle=$($live[$_].Handle),responding=$($live[$_].Responding)" }
    else { "t=$($_)s:not sampled" }
})
$liveText2 = 'session-1: ' + ($liveSamples -join ' ')
$bothText = "$liveText2 || $sampleText"

# ⛔ THE PRECONDITION IS ASSERTED, NOT ASSUMED. A `Responding` reading taken
# against a ZERO window handle is the vacuous reading this repair exists to
# retire, and it must not be able to come back merely because the sampler ran in
# the right session. Every sample must carry a non-zero handle, or the clause is
# NOT RUN by name.
$liveHandlesOk = ($live.Count -eq 3) -and (@(@(2, 5, 10) | Where-Object {
    $live.ContainsKey($_) -and $live[$_].Handle -ne '0' -and $live[$_].Handle -ne 'GONE'
}).Count -eq 3)

if ($Scene -ne 'stall') {
    Add-NotRun 'O3.3 Responding at t=2,5,10 (session 1)' "this run is scene '$Scene'; the liveness claim is about the stall (samples taken anyway: $bothText)"
} elseif ($live.Count -lt 3) {
    $why = if (-not $liveDispatched) { 'the session-1 sampler was never dispatched (no STALL ARMED row)' } else { "the session-1 sampler wrote $($live.Count) of 3 samples" }
    if ($uiStallMs -gt 0) {
        Add-NotRun 'O3.C1 SB_UI_STALL_MS oracle-liveness control' "$why. $bothText"
        Add-NotRun 'O3.3 Responding at t=2,5,10 (session 1)' 'SB_UI_STALL_MS is set: this run is the oracle-liveness control, not the liveness measurement'
    } else {
        Add-NotRun 'O3.3 Responding at t=2,5,10 (session 1)' "$why. $bothText"
    }
} elseif (-not $liveHandlesOk) {
    # `if` is a STATEMENT in argument position; assigned to a variable first, it
    # is an expression. The other spelling parses on some hosts and not others,
    # and this harness's only Mac-side gate is a parser.
    $preName = if ($uiStallMs -gt 0) { 'O3.C1 SB_UI_STALL_MS oracle-liveness control' } else { 'O3.3 Responding at t=2,5,10 (session 1)' }
    Add-NotRun $preName `
        "NOT RUN: no window handle in session 1 -- at least one sample read MainWindowHandle=0 or GONE, and Responding against a zero handle is documented to return True whatever the app is doing. $bothText"
    if ($uiStallMs -gt 0) {
        Add-NotRun 'O3.3 Responding at t=2,5,10 (session 1)' 'SB_UI_STALL_MS is set: this run is the oracle-liveness control, not the liveness measurement'
    }
} elseif ($uiStallMs -gt 0) {
    # ⛔ THE ORACLE-LIVENESS CONTROL, AND IT CAN NOW READ FALSE. `SB_UI_STALL_MS`
    # sleeps the XAML thread, so `Responding` -- a SendMessageTimeout against that
    # very thread, read from a session that can see the window -- MUST read False.
    # An oracle that cannot say False says nothing when it says True.
    #
    # ⚠️ If this still reads True x3 with the handles non-zero, that is a FINDING
    # about the app or about the knob, NOT a pass: the instrument has been
    # repaired, so the reading is now interpretable and it convicts.
    # ⛔ AND THE STIMULUS IS WITNESSED BEFORE A `True x3` CONVICTS ANYTHING. The
    # shell wave (PR #113) writes `UI-STALL DONE ui-stall=<n>ms stall-tid=<tid>`
    # from the sleep's own continuation, on the thread that slept -- the only row
    # that says the XAML thread actually slept rather than that a knob was set.
    # A False is evidence whatever wrote it; a True is a finding ONLY if the sleep
    # happened, so the missing witness refuses the FAIL direction and not the
    # PASS one. Asymmetric on purpose: the two directions rest on different facts.
    $uiDoneRow = Select-SbRow $rows 'UI-STALL DONE ui-stall='
    $stimText = if ($null -eq $uiDoneRow) {
        'the shell wrote no UI-STALL DONE row, so the sleep itself is unwitnessed'
    } else {
        "witnessed by: $uiDoneRow"
    }
    $falses = @(@(2, 5, 10) | Where-Object { $live[$_].Responding -eq 'False' })
    if ($falses.Count -ge 1) {
        Add-Assert -Name 'O3.C1 SB_UI_STALL_MS oracle-liveness control' -Verdict 'PASS' `
            -Detail "Responding read False at $($falses.Count) of 3 session-1 samples, every one against a real window handle -- the oracle can say False. $bothText. $stimText"
    } elseif ($null -eq $uiDoneRow) {
        Add-NotRun 'O3.C1 SB_UI_STALL_MS oracle-liveness control' `
            "Responding never read False, and $stimText -- so this run cannot tell an oracle that will not convict from a sleep that never happened. Both are possible and they are different findings. $bothText"
    } else {
        Add-Assert -Name 'O3.C1 SB_UI_STALL_MS oracle-liveness control' -Verdict 'FAIL' `
            -Detail "Responding never read False under a $($uiStallMs)ms UI-thread sleep that the shell's own row witnesses, sampled IN SESSION 1 with a non-zero window handle at every sample. The session-0 vacuity is repaired and the stimulus is proved, so this reading is now a finding about the run and not about the instrument. $bothText. $stimText"
    }
    Add-NotRun 'O3.3 Responding at t=2,5,10 (session 1)' 'SB_UI_STALL_MS is set: this run is the oracle-liveness control, not the liveness measurement'
} else {
    $trues = @(@(2, 5, 10) | Where-Object { $live[$_].Responding -eq 'True' })
    if ($trues.Count -eq 3) {
        Add-Assert -Name 'O3.3 Responding at t=2,5,10 (session 1)' -Verdict 'PASS' `
            -Detail "True x3 in session 1, against a non-zero window handle at every sample, while the render thread slept $($renderStallMs)ms. $bothText"
    } else {
        Add-Assert -Name 'O3.3 Responding at t=2,5,10 (session 1)' -Verdict 'FAIL' `
            -Detail "expected True x3, read: $bothText"
    }
}

# ---- the post-stall backlog yields EXACTLY ONE row -------------------------
if ($Scene -eq 'stall') {
    $stallRow = Select-SbRow $rows (Get-SbRowPattern 'STALL' ' render-stall=')
    $armedRow = Select-SbRow $rows 'STALL ARMED render-stall='
    if ($null -eq $stallRow -or $null -eq $armedRow) {
        Add-NotRun 'O3.4 exactly ONE cause=resize row after the stall, at the LATEST size' `
            "the STALL row and/or the STALL ARMED row was not written; there is no interval to count within"
    } else {
        # `$a[(n+1)..(count-1)]` COUNTS DOWN when n+1 > count-1, yielding rows in
        # reverse instead of none. Guarded, not trusted.
        $armedIdx = [array]::IndexOf($rows, $armedRow)
        $after = if ($armedIdx -ge 0 -and $armedIdx -lt ($rows.Count - 1)) { @($rows[($armedIdx + 1)..($rows.Count - 1)]) } else { @() }
        $resizeRows = @($after | Where-Object { $_ -match 'REPAINT events_total=' -and $_ -match 'cause=resize' })
        $painted = Get-SbField $stallRow 'painted-after-stall'
        $requested = Get-SbField $stallRow 'resize-during-stall'
        if ($resizeRows.Count -eq 1) {
            $surf = Get-SbField $resizeRows[0] 'surface'
            if ($surf -eq $painted) {
                Add-Assert -Name 'O3.4 exactly ONE cause=resize row after the stall, at the LATEST size' -Verdict 'PASS' `
                    -Detail "one row, surface=$surf, matching painted-after-stall=$painted (requested during the stall: $requested)" `
                    -Row $resizeRows[0]
            } else {
                Add-Assert -Name 'O3.4 exactly ONE cause=resize row after the stall, at the LATEST size' -Verdict 'FAIL' `
                    -Detail "one row but at surface=$surf, while the STALL row reports painted-after-stall=$painted" `
                    -Row $resizeRows[0]
            }
        } elseif ($resizeRows.Count -eq 0 -and $requested -eq 'none') {
            Add-NotRun 'O3.4 exactly ONE cause=resize row after the stall, at the LATEST size' `
                "the STALL row reads resize-during-stall=none -- nothing was posted during the sleep, so there is no backlog to collapse"
        } else {
            Add-Assert -Name 'O3.4 exactly ONE cause=resize row after the stall, at the LATEST size' -Verdict 'FAIL' `
                -Detail "$($resizeRows.Count) cause=resize rows after the stall (expected exactly 1); requested during the stall: $requested" `
                -Row $stallRow
        }
    }
}

# ===========================================================================
# O2 -- THE REPAINT / BENCHMARK SPLIT
# ===========================================================================

$repaints = @($rows | Where-Object { $_ -match 'REPAINT events_total=' })
$resizeRepaints = @($repaints | Where-Object { $_ -match 'cause=resize' })

# The "before" is a PARAMETER. ⛔ NOT HARDCODED: the N0b figure (363 ms per
# SizeChanged event at 984x526) belongs to a measurement with a date and a
# surface, and a constant pasted here would be inherited by every comparison
# forever without anyone re-reading it.
#
# ⛔ AND THE COMPARISON NAMES ITS AXES. `SB_MODE` is honoured ONLY by
# `Benchmark()` -- `OffscreenMode` is read at the offscreen-target creation and
# inside the benchmark loop, and NOWHERE ELSE -- so `Repaint()` always paints the
# back buffer directly. Every REPAINT row below is therefore a DIRECT-route row
# whatever `SB_MODE` says, and the row's own `SB_MODE=` prefix is about the
# process, not about this frame. The "before" figure was taken on the
# OFFSCREEN+copy route. Two routes, and a reader who is not told compares them as
# if they were one; the present cost was measured route-independent
# (4.84-5.06 ms), which is what makes the comparison legitimate rather than what
# makes it unnecessary to state.
$routeText = 'this run''s REPAINT rows: route=DIRECT (Repaint always paints the back buffer; SB_MODE is honoured only by Benchmark, so the row prefix SB_MODE= describes the process, not this frame)'
$beforeText = "before: not supplied. $routeText"
if (-not [string]::IsNullOrWhiteSpace($Before)) {
    $beforeVal = $Before
    if (Test-Path $Before) {
        $raw = Get-Content $Before -Raw
        $m = [regex]::Match($raw, '([0-9]+(\.[0-9]+)?)')
        if ($m.Success) { $beforeVal = $m.Groups[1].Value }
    }
    $beforeText = "before: $beforeVal ms on the OFFSCREEN+copy route (supplied via -Before '$Before'). NOTE: THE SURFACE LABEL CHANGED CONVENTION: before the shell wave the reported surface was sized in DIPs (a default window read 1904x941, and the EVENT route's 1000x600 read 984x526); it is derived in PHYSICAL pixels now, so the same window reports a different number and a 'before' quoted with an old label is not comparable BY LABEL. $routeText"
}

if ($resizeRepaints.Count -eq 0) {
    Add-NotRun 'O2.1 one REPAINT cause=resize row per drain, frames=1' `
        "this run wrote no REPAINT row with cause=resize (SB_RESIZE unset, or no resize arrived). $beforeText"
    Add-NotRun 'O2.2 event_total <= 2 x one benchmark frame (same sitting, same route, same surface)' `
        "no cause=resize REPAINT row to price. $beforeText"
    Add-NotRun 'O2.3 event_total < before / 10' `
        "no cause=resize REPAINT row to price. $beforeText"
} else {
    $badFrames = @($resizeRepaints | Where-Object { (Get-SbField $_ 'frames') -ne '1' })
    if ($badFrames.Count -eq 0) {
        Add-Assert -Name 'O2.1 one REPAINT cause=resize row per drain, frames=1' -Verdict 'PASS' `
            -Detail "$($resizeRepaints.Count) resize-caused row(s), every one frames=1. $beforeText" `
            -Row $resizeRepaints[-1]
    } else {
        Add-Assert -Name 'O2.1 one REPAINT cause=resize row per drain, frames=1' -Verdict 'FAIL' `
            -Detail "$($badFrames.Count) of $($resizeRepaints.Count) resize rows do not read frames=1. $beforeText" `
            -Row $badFrames[0]
    }

    # ⭐ THE BAND IS ONE FRAME, AND THE OLD BAND WAS THE DEFECT.
    #
    # `2 x present-mean` asserted that PAINT COSTS NO MORE THAN PRESENT. On this
    # hardware present is 0.29-1.20 ms and paint is 1.0-4.3 ms, so the band redded
    # in every one of PR #110's four runs while the subject it prices improved
    # 110-275x. The claim O2 makes is not "paint is cheap"; it is "A RESIZE DRAIN
    # COSTS ONE FRAME". So the band is one frame, measured by this box, in this
    # sitting, on the same route, at the same surface -- and where any of those
    # three does not hold it is `NOT RUN` by name, never a red and never a
    # substitution.
    $eventRow = $resizeRepaints[-1]
    $eventPaint = [double]((Get-SbField $eventRow 'paint') -replace 'ms$', '')
    $eventPresent = [double]((Get-SbField $eventRow 'present') -replace 'ms$', '')
    $eventTotal = $eventPaint + $eventPresent
    $eventSurface = Get-SbField $eventRow 'surface'

    if ($null -eq $benchFrame) {
        Add-NotRun 'O2.2 event_total <= 2 x one benchmark frame (same sitting, same route, same surface)' `
            "$benchFrameReason. Drive the 'benchmark' scene with SB_MODE=direct in the same sitting (sitting.ps1 does), or pass -BenchmarkFrameMs. This run's event_total was $([math]::Round($eventTotal,2)) ms at surface $eventSurface. $routeText"
    } elseif ($benchFrame.Route -ne 'DIRECT' -and $benchFrame.Route -ne 'UNSTATED') {
        Add-NotRun 'O2.2 event_total <= 2 x one benchmark frame (same sitting, same route, same surface)' `
            "the band source was measured on route $($benchFrame.Route) and every REPAINT row is DIRECT. Two routes, no comparison -- re-run the benchmark with SB_MODE=direct. This run's event_total was $([math]::Round($eventTotal,2)) ms at surface $eventSurface. $routeText"
    } else {
        # ⛔ AND THE ROW IS CHOSEN TO MATCH THE BAND'S SURFACE, not taken as
        # whichever came last. A paint cost is a function of the surface: pricing
        # a 984x526 drain against a 1904x941 frame is the same class of error as
        # comparing two hashes taken at two surfaces, which O1.0 already refuses.
        $sameSurface = @($resizeRepaints | Where-Object { (Get-SbField $_ 'surface') -eq $benchFrame.Surface })
        if ($benchFrame.Surface -eq 'UNSTATED') { $sameSurface = @($eventRow) }
        if ($sameSurface.Count -eq 0) {
            $seen = (@($resizeRepaints | ForEach-Object { Get-SbField $_ 'surface' }) | Sort-Object -Unique) -join ', '
            Add-NotRun 'O2.2 event_total <= 2 x one benchmark frame (same sitting, same route, same surface)' `
                "the band was measured at surface $($benchFrame.Surface) and this run's resize-caused rows are at $seen. A paint cost is a function of the surface, so this is refused rather than scaled. event_total at $eventSurface was $([math]::Round($eventTotal,2)) ms against a band of $([math]::Round(2.0 * $benchFrame.FrameMs,2)) ms. $routeText"
        } else {
            $row2 = $sameSurface[-1]
            $p2 = [double]((Get-SbField $row2 'paint') -replace 'ms$', '')
            $q2 = [double]((Get-SbField $row2 'present') -replace 'ms$', '')
            $cost2 = $p2 + $q2
            $band2 = 2.0 * $benchFrame.FrameMs
            $detail2 = ("event_total(paint {0:N2} + present {1:N2}) = {2:N2} ms at surface {3}, against 2 x one benchmark frame ({4:N2} ms) = {5:N2} ms band. Band source: {6}. {7}" -f
                        $p2, $q2, $cost2, (Get-SbField $row2 'surface'), $benchFrame.FrameMs, $band2, $benchFrameSource, $routeText)
            if ($cost2 -le $band2) {
                Add-Assert -Name 'O2.2 event_total <= 2 x one benchmark frame (same sitting, same route, same surface)' -Verdict 'PASS' -Detail $detail2 -Row $row2
            } else {
                Add-Assert -Name 'O2.2 event_total <= 2 x one benchmark frame (same sitting, same route, same surface)' -Verdict 'FAIL' -Detail $detail2 -Row $row2
            }
        }
    }

    # ⭐ O2.3 -- THE ORDER-OF-MAGNITUDE CLAUSE, AND ITS "BEFORE" IS A PARAMETER.
    # The freeze's claim against the old shell is a factor, not a millisecond
    # count, and the factor is where the evidence is: 363 ms per resize event on
    # the OFFSCREEN+copy route against a few ms on DIRECT. It is `NOT RUN` with
    # nothing supplied, because a hardcoded before is a number nobody re-measures.
    if ([string]::IsNullOrWhiteSpace($Before)) {
        Add-NotRun 'O2.3 event_total < before / 10' `
            "before: not supplied. This run's event_total was $([math]::Round($eventTotal,2)) ms at surface $eventSurface. Supply the old shell's per-resize-event cost with -Before <ms|path>, and state the surface and route it was taken at when you quote the result. $routeText"
    } else {
        $beforeMs = 0.0
        $bm = [regex]::Match($beforeText, 'before: ([0-9]+(\.[0-9]+)?) ms')
        if ($bm.Success) { $beforeMs = [double]$bm.Groups[1].Value }
        if ($beforeMs -le 0) {
            Add-NotRun 'O2.3 event_total < before / 10' `
                "-Before '$Before' carried no readable millisecond figure. $routeText"
        } else {
            $factor = if ($eventTotal -gt 0) { $beforeMs / $eventTotal } else { 0 }
            $detail3 = ("event_total {0:N2} ms at surface {1} (route DIRECT) against before/10 = {2:N2} ms; the measured factor is {3:N0}x. {4}" -f
                        $eventTotal, $eventSurface, ($beforeMs / 10.0), $factor, $beforeText)
            if ($eventTotal -lt ($beforeMs / 10.0)) {
                Add-Assert -Name 'O2.3 event_total < before / 10' -Verdict 'PASS' -Detail $detail3 -Row $eventRow
            } else {
                Add-Assert -Name 'O2.3 event_total < before / 10' -Verdict 'FAIL' -Detail $detail3 -Row $eventRow
            }
        }
    }
}

# ===========================================================================
# O1 -- THE RETAINED DOCUMENT: identity, mutation, golden, round trip
# ===========================================================================

if ($Scene -ne 'retained') {
    Add-NotRun 'O1 (all clauses)' "this run is scene '$Scene'; O1's four hash rows are written only by 'retained'"
} else {
    $rowA = Get-SbHashRow 'A'
    $rowAM = Get-SbHashRow 'A-MUT'
    $rowH1 = Get-SbHashRow 'H1'
    $rowA2 = Get-SbHashRow "A'"

    # ---- O1.0: THE REFUSAL, FIRST -----------------------------------------
    # A mismatch here is not a red. Two hashes taken at two different surfaces
    # are not a comparison at all, and calling that a failure would convict the
    # shell of something nobody measured.
    $surfacesAgree = $false
    if ($null -eq $rowA -or $null -eq $rowA2) {
        $missingLabel = if ($null -eq $rowA) { 'A' } else { 'A-prime' }
        Add-NotRun 'O1.0 surface(A) == surface(A-prime)' `
            "the $missingLabel row was not written -- the walk did not reach both stops"
    } else {
        $sA = Get-SbField $rowA 'surface'
        $sA2 = Get-SbField $rowA2 'surface'
        if ($sA -eq $sA2) {
            $surfacesAgree = $true
            Add-Assert -Name 'O1.0 surface(A) == surface(A-prime)' -Verdict 'PASS' `
                -Detail "both at $sA -- the round trip returned to the surface it left" -Row $rowA2
        } else {
            Add-NotRun 'O1.0 surface(A) == surface(A-prime)' `
                "NOT RUN: surface mismatch -- A at $sA, A' at $sA2. A hash comparison across two surfaces is not a comparison, so every hash clause below is refused rather than failed"
        }
    }

    # ---- O1.1: IDENTITY, from the CORE's counters ---------------------------
    $hashRows = @()
    foreach ($r in @($rowA, $rowAM, $rowH1, $rowA2)) { if ($null -ne $r) { $hashRows += $r } }
    if ($hashRows.Count -eq 0) {
        Add-NotRun 'O1.1 engines-created == 1 && engines-freed == 0 on every retained hash row' `
            'the retained scene wrote no hash row at all'
    } else {
        $badId = @($hashRows | Where-Object {
            (Get-SbField $_ 'engines-created') -ne '1' -or (Get-SbField $_ 'engines-freed') -ne '0'
        })
        if ($badId.Count -eq 0) {
            Add-Assert -Name 'O1.1 engines-created == 1 && engines-freed == 0 on every retained hash row' -Verdict 'PASS' `
                -Detail "$($hashRows.Count) of the 4 hash rows present, every one 1/0 (the counters are the CORE's, read as the LAST core call before the row)" `
                -Row $hashRows[-1]
        } else {
            Add-Assert -Name 'O1.1 engines-created == 1 && engines-freed == 0 on every retained hash row' -Verdict 'FAIL' `
                -Detail "$($badId.Count) of $($hashRows.Count) hash rows report a second engine or a free -- a reload-per-resize shell" `
                -Row $badId[0]
        }
        if ($hashRows.Count -lt 4) {
            Add-NotRun 'O1.1b all four hash rows (A, A-MUT, H1, A-prime) present' `
                "only $($hashRows.Count) of the 4 were written; a walk that did not complete cannot be read as a round trip"
        } else {
            Add-Assert -Name 'O1.1b all four hash rows (A, A-MUT, H1, A-prime) present' -Verdict 'PASS' `
                -Detail 'A, A-MUT, H1 and A-prime were all written'
        }
    }

    # ---- O1.2: THE MUTATION, in the shell's own dumps -----------------------
    #
    # ⛔ A ROUND TRIP WITH NO GESTURE IS NOT A FAILED MUTATION. PR #110 measured
    # that `retained` without a hand waits out its gesture deadline and never
    # completes the round trip at all; once the shell wave lands, `A-MUT` carries
    # `mutation=NONE` and the walk runs anyway. In that shape O1.2a and O1.2b have
    # no asked delta to check -- there was no gesture -- and O1.4 (`A-MUT == A'`,
    # the RETENTION clause) is the assertion that still has teeth. A `FAIL` here
    # would convict the shell of not moving an element nobody asked it to move.
    #
    # ⚠️ WRITTEN FOR BOTH ROW SHAPES: an ABSENT `mutation=` field is today's
    # shell, and today's behaviour is kept exactly.
    $mutField = if ($null -ne $rowAM) { Get-SbField $rowAM 'mutation' } else { $null }
    if ($mutField -eq 'NONE') {
        Add-NotRun 'O1.2a the SELECTED element CHANGED between the dumps' `
            "NOT RUN: no gesture -- the A-MUT row reads mutation=NONE, so the retained walk ran with no hand and there is no asked delta to check. O1.4 (A-MUT == A-prime) still asserts, and it is the clause that carries the retention claim" -Row $rowAM
        Add-NotRun 'O1.2b the SELECTED element moved by the asked delta' `
            'NOT RUN: no gesture (A-MUT reads mutation=NONE)' -Row $rowAM
        Add-NotRun 'O1.2c the app''s selected path == the harness-chosen target path' `
            'NOT RUN: no gesture (A-MUT reads mutation=NONE), so the app selected nothing to compare the chooser against' -Row $rowAM
    } elseif ($null -eq $handAsked) {
        Add-NotRun 'O1.2 the SELECTED element moved by the asked delta' `
            'no gesture was driven by this harness (-Hand not given and -SynthFromDump not used), so there is no asked delta to check the dump against'
        Add-NotRun 'O1.2c the app''s selected path == the harness-chosen target path' `
            'no gesture was driven by this harness, so there is no chosen target and no selection to compare'
    } elseif (-not (Test-Path $afterDump)) {
        Add-NotRun 'O1.2 the SELECTED element moved by the asked delta' `
            "sb-doc-after.json was not written -- the gesture never closed"
        Add-NotRun 'O1.2c the app''s selected path == the harness-chosen target path' `
            'sb-doc-after.json was not written, so the app''s own answer was never recorded'
    } else {
        # ⭐ F-B: THE SUBJECT IS THE ELEMENT THE APP SELECTED, NOT THE ONE THE
        # HARNESS AIMED AT. Measured on kenai 2026-09-04, on a run in which
        # EVERYTHING WORKED: the chooser aimed at the centre of the largest
        # filled shape (`$.layers[0].children[0]`, a 72x72 rect) and asserted
        # against it, while the app's hit test returned the TOPMOST shape over
        # that point (`$.layers[0].children[2]`) and moved it by exactly the
        # asked delta -- `(36.666664, 22.666668)` against the asked `(37,23)` at
        # scale 1.5. Two reds landed on a perfect gesture, and O1.2b's FAIL
        # branch printed a sentence about the element that was false of it.
        #
        # ⛔ THE REPAIR WAS ALREADY IN THE RECEIPT. The after-dump carries
        # `selection[0].path` -- the APP's own answer to "which element did the
        # gesture take" -- so O1.2a/b read THAT, and the disagreement between it
        # and the chooser becomes its own clause (O1.2c) instead of being
        # silently charged to the app. The chooser is repaired too (it mirrors
        # the reference interpreter's hit test now), so O1.2c is expected to
        # PASS; it exists because a chooser that agrees by luck and a chooser
        # that agrees by rule are indistinguishable without it.
        $appSelPath = Get-SbSelectionPath $afterDump
        $readPath = $appSelPath
        $pathSource = "read at the after-dump's selection[0].path -- the APP's own answer to which element the gesture took"
        if ($null -eq $appSelPath) {
            $readPath = $handTarget.Path
            $pathSource = "read at the HARNESS-CHOSEN path: this after-dump carries no selection[0].path (the older dump shape), so the app's own answer is not available. NAMED, because this is exactly the reading that was wrong when the two disagree"
        }
        $beforeEl = Get-SbElementByPath $beforeDump $readPath
        $afterEl = Get-SbElementByPath $afterDump $readPath
        if ($null -eq $beforeEl -or $null -eq $afterEl) {
            Add-NotRun 'O1.2 the SELECTED element moved by the asked delta' `
                "the element at $readPath is not at the same path in both dumps ($pathSource) -- the harness will not match elements by guessing"
        } else {
            $bJson = ($beforeEl | ConvertTo-Json -Depth 20 -Compress)
            $aJson = ($afterEl | ConvertTo-Json -Depth 20 -Compress)
            if ($bJson -eq $aJson) {
                Add-Assert -Name 'O1.2a the SELECTED element CHANGED between the dumps' -Verdict 'FAIL' `
                    -Detail "the element at $readPath is byte-identical before and after a gesture that asked it to move by ($($handAsked.Dx),$($handAsked.Dy)) -- $pathSource"
            } else {
                Add-Assert -Name 'O1.2a the SELECTED element CHANGED between the dumps' -Verdict 'PASS' `
                    -Detail "the element at $readPath differs before -> after -- $pathSource"
            }
            # THE DELTA ARM, AND IT IS SEPARATE. The element the app selects may
            # be a CONTAINER whose child carries the coordinates (the kenai run's
            # `[0,2]` is a group holding a line), so the origin is read by the
            # SAME RULE on both dumps and the rule is printed: `x/y`, `cx/cy`, or
            # the origin of the subtree's bounding box. Two readings taken by
            # different rules are not a delta.
            $bo = Get-SbElementOrigin $beforeEl
            $ao = Get-SbElementOrigin $afterEl
            # ⛔ THE TOLERANCE IS 1/scale DIP, THE SAME ONE O4.6 PASSES ON. The
            # hand is aimed in physical pixels and the document is in DIPs, so
            # one pixel of rounding is 1/scale of a document unit -- a fixed
            # 1.0 was looser than the measurement at scale 1.5 and would be
            # tighter than it at scale 0.5.
            $s1 = [double]$Scale
            if ($s1 -le 0) { $s1 = 1.0 }
            $tolD = 1.0 / $s1
            if ($null -eq $bo -or $null -eq $ao) {
                Add-NotRun 'O1.2b the SELECTED element moved by the asked delta' `
                    "the element at $readPath carries no readable position -- no x/y, no cx/cy, and nothing under it with coordinates -- so this arm cannot price its move"
            } elseif ($bo.How -ne $ao.How) {
                Add-NotRun 'O1.2b the SELECTED element moved by the asked delta' `
                    "the two dumps' positions were read by DIFFERENT rules (before: $($bo.How); after: $($ao.How)). Two readings taken by different rules are not a delta"
            } elseif ([math]::Abs(($ao.X - $bo.X) - $handAsked.Dx) -le $tolD -and
                      [math]::Abs(($ao.Y - $bo.Y) - $handAsked.Dy) -le $tolD) {
                Add-Assert -Name 'O1.2b the SELECTED element moved by the asked delta' -Verdict 'PASS' `
                    -Detail ("moved ({0:N2},{1:N2}) against the asked ({2},{3}), tolerance +-{4:N3} DIP (1/scale, scale={5}), reading {6} at {7} -- {8}" -f
                             ($ao.X - $bo.X), ($ao.Y - $bo.Y), $handAsked.Dx, $handAsked.Dy, $tolD, $s1, $bo.How, $readPath, $pathSource)
            } elseif (($ao.X -eq $bo.X) -and ($ao.Y -eq $bo.Y)) {
                $bt = if ($beforeEl.PSObject.Properties.Name -contains 'transform') { [string]$beforeEl.transform } else { '(absent)' }
                $at = if ($afterEl.PSObject.Properties.Name -contains 'transform') { [string]$afterEl.transform } else { '(absent)' }
                if ($bt -ne $at) {
                    Add-NotRun 'O1.2b the SELECTED element moved by the asked delta' `
                        "the element's position did not change; its transform did ($bt -> $at). The move is real (O1.2a passed) but this arm reads COORDINATES and cannot price a transform -- a NAMED gap, not a pass"
                } else {
                    Add-Assert -Name 'O1.2b the SELECTED element moved by the asked delta' -Verdict 'FAIL' `
                        -Detail "neither the position ($($bo.How)) nor the transform moved, yet the element's JSON differs -- the change is somewhere this arm does not read"
                }
            } else {
                Add-Assert -Name 'O1.2b the SELECTED element moved by the asked delta' -Verdict 'FAIL' `
                    -Detail ("moved ({0:N2},{1:N2}) against the asked ({2},{3}), tolerance +-{4:N3} DIP (1/scale, scale={5}), reading {6} at {7}" -f
                             ($ao.X - $bo.X), ($ao.Y - $bo.Y), $handAsked.Dx, $handAsked.Dy, $tolD, $s1, $bo.How, $readPath)
            }
        }

        # ---- O1.2c: THE CHOOSER, AGAINST THE APP -----------------------------
        # ⛔ A MISMATCH HERE IS A FINDING ABOUT THE HARNESS, NOT ABOUT THE APP,
        # and it says so in the detail. It is the clause that would have named
        # F-B in one line instead of producing two reds about an element the
        # gesture never touched.
        if ($null -eq $appSelPath) {
            Add-NotRun 'O1.2c the app''s selected path == the harness-chosen target path' `
                'the after-dump carries no selection[0].path, so the app made no statement for the chooser to be compared against (the older dump shape)'
        } elseif ($null -eq $handTarget) {
            Add-NotRun 'O1.2c the app''s selected path == the harness-chosen target path' `
                "the app selected $appSelPath and this harness chose no target for this run"
        } elseif ($appSelPath -eq $handTarget.Path) {
            Add-Assert -Name 'O1.2c the app''s selected path == the harness-chosen target path' -Verdict 'PASS' `
                -Detail "both $appSelPath. The chooser aimed at ($($handAsked.X),$($handAsked.Y)) DIP, the centre of $($handTarget.AimPath), and resolved the target by $($handTarget.Rule)"
        } else {
            Add-Assert -Name 'O1.2c the app''s selected path == the harness-chosen target path' -Verdict 'FAIL' `
                -Detail "the app selected $appSelPath and this harness chose $($handTarget.Path). ⛔ THIS IS A FINDING ABOUT THE CHOOSER, NOT ABOUT THE APP: the app's hit test is the authority on which element a press takes, and O1.2a/b were read against ITS answer. The chooser aimed at ($($handAsked.X),$($handAsked.Y)) DIP, the centre of $($handTarget.AimPath), and resolved by $($handTarget.Rule)"
        }
    }

    # ---- O1.3: THE GOLDEN CLAUSE, hash(A) == hash(D) ------------------------
    # D is the `document` control -- the SAME svg at the SAME observed surface
    # through the FRESH-ENGINE one-shot path. It is normally an earlier run, so
    # the log's history is read deliberately and the row is printed.
    $docRow = Select-SbRow $rows "RUSTOK DOCUMENT '"
    if ($null -eq $docRow) {
        $docRow = Select-SbRow (Read-SbRowsBefore $log $logMark) "RUSTOK DOCUMENT '"
    }
    if ($null -eq $rowA) {
        Add-NotRun 'O1.3 hash(A) == hash(D), the golden clause' 'the A row was not written'
    } elseif ($null -eq $docRow) {
        Add-NotRun 'O1.3 hash(A) == hash(D), the golden clause' `
            'this log holds no RUSTOK DOCUMENT row -- run the `document` control scene against the same svg at the same surface first'
    } else {
        $sA = Get-SbField $rowA 'surface'
        $sD = Get-SbField $docRow 'surface'
        if ($sA -ne $sD) {
            Add-NotRun 'O1.3 hash(A) == hash(D), the golden clause' `
                "REFUSED: the control ran at surface $sD and A was hashed at $sA. Two surfaces, no comparison" -Row $docRow
        } else {
            $hA = Get-SbField $rowA 'hash'
            $hD = Get-SbField $docRow 'hash'
            if ($hA -eq $hD) {
                Add-Assert -Name 'O1.3 hash(A) == hash(D), the golden clause' -Verdict 'PASS' `
                    -Detail "both $hA at surface $sA -- the retained engine's frame is byte-identical to the fresh-engine one-shot's" -Row $docRow
            } else {
                Add-Assert -Name 'O1.3 hash(A) == hash(D), the golden clause' -Verdict 'FAIL' `
                    -Detail "A=$hA D=$hD at surface $sA" -Row $docRow
            }
        }
    }

    # ---- O1.4 / O1.5 / O1.6: the round trip and its two discriminators ------
    function Add-HashCompare([string]$name, $left, $right, [string]$leftLabel, [string]$rightLabel, [bool]$wantEqual) {
        if ($null -eq $left -or $null -eq $right) {
            Add-NotRun $name "the $(if ($null -eq $left) { $leftLabel } else { $rightLabel }) row was not written"
            return
        }
        if (-not $surfacesAgree) {
            Add-NotRun $name 'NOT RUN: surface mismatch (O1.0 refused; a hash comparison across two surfaces is not a comparison)'
            return
        }
        $hl = Get-SbField $left 'hash'
        $hr = Get-SbField $right 'hash'
        $equal = ($hl -eq $hr)
        if ($equal -eq $wantEqual) {
            Add-Assert -Name $name -Verdict 'PASS' -Detail "$leftLabel=$hl $rightLabel=$hr" -Row $right
        } else {
            Add-Assert -Name $name -Verdict 'FAIL' -Detail "$leftLabel=$hl $rightLabel=$hr" -Row $right
        }
    }

    Add-HashCompare 'O1.4 A-MUT == A-prime (RETENTION across the round trip)' $rowAM $rowA2 'A-MUT' "A'" $true
    Add-HashCompare 'O1.5 H1 != A-MUT (the hash reads the buffer)' $rowH1 $rowAM 'H1' 'A-MUT' $false
    # ⛔ O1.6 IS REFUSED UNDER `mutation=NONE`, NOT FAILED, AND THE SHELL WAVE
    # SAYS SO IN AS MANY WORDS (PR #113): with no gesture, `A-MUT == A` is a
    # CONSTRUCTION and not a finding. Read as a FAIL it would convict the pointer
    # seam of a run that never drove it. `mutation=REAL` or `mutation=SYNTHETIC`
    # is what licenses asserting it.
    if ($mutField -eq 'NONE') {
        Add-NotRun 'O1.6 A != A-MUT (the mutation has a pixel witness)' `
            'NOT RUN: no gesture -- A-MUT reads mutation=NONE, so A == A-MUT is a construction and not a finding. O1.4 (A-MUT == A-prime) and O1.5 (H1 != A-MUT) still assert' -Row $rowAM
    } else {
        Add-HashCompare 'O1.6 A != A-MUT (the mutation has a pixel witness)' $rowA $rowAM 'A' 'A-MUT' $false
    }

    # ---- O1.7: THE PROBE-COLOUR ARM, one row, through the DXGI eye ----------
    # ⛔ ABSENCE ALONE IS VACUOUS. "PROBE_FG is not in the retained frame" is
    # satisfied by a camera that cannot see PROBE_FG anywhere -- which is exactly
    # the GDI eye's measured defect. So the POSITIVE half is required: a capture
    # of a frame that DOES hold PROBE_FG, taken by the same eye.
    $probeFg = '255,0,255'   # ffi_paint.rs PROBE_FG
    $probeBg = '0,96,96'     # ffi_paint.rs PROBE_BG
    $docColour = '100,149,237'  # complex_document.svg's rect fill, rgb(100,149,237)
    if (-not (Test-Path $dxgiPng)) {
        Add-NotRun 'O1.7 probe colours absent from the retained frame, present in a probe frame' `
            'the DXGI eye produced no capture this run -- the GDI eye cannot see a hardware-composed swapchain and is not allowed to decide this'
    } elseif ([string]::IsNullOrWhiteSpace($ProbeCapture)) {
        $seen = Measure-SbColors $dxgiPng @($probeFg, $probeBg, $docColour)
        Add-NotRun 'O1.7 probe colours absent from the retained frame, present in a probe frame' `
            "no -ProbeCapture supplied. The absence half alone cannot convict or acquit: a camera blind to PROBE_FG reports the same zero. Read this run anyway: PROBE_FG=$($seen[$probeFg]) PROBE_BG=$($seen[$probeBg]) document-fill=$($seen[$docColour]) sampled pixels"
    } elseif (-not (Test-Path $ProbeCapture)) {
        Add-NotRun 'O1.7 probe colours absent from the retained frame, present in a probe frame' `
            "-ProbeCapture '$ProbeCapture' does not exist"
    } else {
        $inProbe = Measure-SbColors $ProbeCapture @($probeFg, $probeBg)
        $inRetained = Measure-SbColors $dxgiPng @($probeFg, $probeBg, $docColour)
        $posOk = ($inProbe[$probeFg] -ge 50)
        $negOk = ($inRetained[$probeFg] -lt 50 -and $inRetained[$probeBg] -lt 50)
        $docOk = ($inRetained[$docColour] -ge 50)
        $detail = ("probe frame: PROBE_FG=$($inProbe[$probeFg]) PROBE_BG=$($inProbe[$probeBg]) | retained frame: PROBE_FG=$($inRetained[$probeFg]) PROBE_BG=$($inRetained[$probeBg]) document-fill($docColour)=$($inRetained[$docColour])")
        if (-not $posOk) {
            Add-NotRun 'O1.7 probe colours absent from the retained frame, present in a probe frame' `
                "the POSITIVE half failed: this eye found no PROBE_FG in the supplied probe capture either, so its zero on the retained frame measures the camera and not the paint. $detail"
        } elseif ($negOk -and $docOk) {
            Add-Assert -Name 'O1.7 probe colours absent from the retained frame, present in a probe frame' -Verdict 'PASS' `
                -Detail $detail
        } else {
            Add-Assert -Name 'O1.7 probe colours absent from the retained frame, present in a probe frame' -Verdict 'FAIL' `
                -Detail $detail
        }
    }
}

# ===========================================================================
# O4 -- REAL INPUT
# ===========================================================================

$gestureRow = Select-SbRow $rows 'POINTER (REAL|SYNTHETIC) press='
$refusedRow = Select-SbRow $rows 'NOT RUN: hand refused'
$wantProvenance = if ($synthAsked -and -not $Hand) { 'SYNTHETIC' } else { 'REAL' }
# ⛔ THE ARM IS A SHORT PREFIX AND A SUFFIX ON THE DETAIL, NOT A SENTENCE INSIDE
# THE NAME. `O4.C1 empty-canvas control.1 pointer=REAL` reads as a typo; a name
# a reader distrusts is a name they do not quote back, and quoting rows back is
# the whole protocol here.
$o4Prefix = if ($HandEmpty) { 'O4.C1' } elseif ($wantProvenance -eq 'SYNTHETIC') { 'O4.C2' } else { 'O4' }
$o4Arm = if ($HandEmpty) { ' [empty-canvas control]' } elseif ($wantProvenance -eq 'SYNTHETIC') { ' [SB_SYNTH_DRAG seam control]' } else { '' }

if ($Scene -ne 'pointer' -and $Scene -ne 'retained') {
    Add-NotRun "$o4Prefix gesture" "this run is scene '$Scene'; only 'pointer' and 'retained' carry a gesture"
} elseif ($null -eq $gestureRow) {
    if ($null -ne $refusedRow) {
        Add-NotRun "$o4Prefix gesture" "NOT RUN: hand refused -- the shell wrote its own refusal and never a receipt. UIPI failure is undetectable at the injector, so a zero here is never a pass" -Row $refusedRow
    } else {
        Add-NotRun "$o4Prefix gesture" 'no POINTER row and no refusal row: the scene neither received a gesture nor timed out within this harness''s wait'
    }
} else {
    $prov = Get-SbField $gestureRow 'pointer'
    $doc = Get-SbField $gestureRow 'doc'
    $loads = Get-SbField $gestureRow 'loads(shell)'
    $press = Get-SbField $gestureRow 'press'
    $move = Get-SbField $gestureRow 'move'
    $release = Get-SbField $gestureRow 'release'
    $selected = Get-SbField $gestureRow 'selected'
    $rowScale = Get-SbField $gestureRow 'scale'
    $pressAt = Get-SbPoint $gestureRow 'press@'
    $releaseAt = Get-SbPoint $gestureRow 'release@'

    if ($prov -eq $wantProvenance) {
        Add-Assert -Name "$o4Prefix.1 pointer=$wantProvenance" -Verdict 'PASS' -Detail "the row's provenance field reads $prov$o4Arm" -Row $gestureRow
    } else {
        Add-Assert -Name "$o4Prefix.1 pointer=$wantProvenance" -Verdict 'FAIL' -Detail "the row reads pointer=$prov$o4Arm; a receipt never wears a provenance its counters did not come from" -Row $gestureRow
    }

    # ⛔ doc=HELD IS WHAT MAKES A ZERO READABLE. An empty-held-engine `selected=0`
    # is byte-identical to the empty-canvas control's `selected=0` and means the
    # opposite thing; without this field neither can be measured.
    if ($doc -eq 'HELD') {
        Add-Assert -Name "$o4Prefix.2 doc=HELD" -Verdict 'PASS' -Detail 'the gesture drove the HELD engine, so a selection figure is readable' -Row $gestureRow
    } else {
        Add-Assert -Name "$o4Prefix.2 doc=HELD" -Verdict 'FAIL' -Detail "the row reads doc=$doc -- the gesture drove an engine with no document, and every selection figure below is uninterpretable" -Row $gestureRow
    }

    if ($null -ne $loads -and [int]$loads -ge 1) {
        Add-Assert -Name "$o4Prefix.3 loads(shell) >= 1" -Verdict 'PASS' -Detail "loads(shell)=$loads (a SHELL count; there is no load crossing in the core, so it is not the identity oracle)" -Row $gestureRow
    } else {
        Add-Assert -Name "$o4Prefix.3 loads(shell) >= 1" -Verdict 'FAIL' -Detail "loads(shell)=$loads" -Row $gestureRow
    }

    # On the synth arm k is SB_SYNTH_DRAG's fifth field, which the operator may
    # have set directly; -HandMoves is only the hand's own k. Reading the wrong
    # one would compare the row against a number nobody asked for.
    $wantK = $HandMoves
    if ($wantProvenance -eq 'SYNTHETIC' -and $synthAsked) {
        $synthParts = @($env:SB_SYNTH_DRAG -split ',')
        if ($synthParts.Count -ge 5) { $wantK = [int]$synthParts[4] } else { $wantK = 2 }
    }
    # ⭐ `move != k` IS THE DRAG'S DURATION, NOT ITS STEP COUNT -- F-C, and the
    # ruling on it. PR #110 measured `move=8` at k=7 and blamed the injector; PR
    # #115 removed the positioned button events and k=7 read 8 again. The second
    # sitting varied `-HandSettleMs`, which is the arm that breaks the confound
    # (at a fixed 40 ms pause the step count and the elapsed time are perfectly
    # correlated), and 13 configurations settle it:
    #
    #   k=7 @ 10 ms (70 ms drag)  -> 7, 7      the exact config that always read 8
    #   k=4 @ 40 ms (160 ms)      -> 4         and k=4 @ 100 ms (400 ms) -> 5
    #   k=1 @ 300 ms (300 ms)     -> 2         one step, one extra: not about k
    #   k=2 @ 400 ms (800 ms)     -> 4         TWO extras: periodic, not one-shot
    #
    # ⚠️ THE SOURCE IS CHARACTERISED, NOT IDENTIFIED. One arrival per few hundred
    # ms while the button is held fits every reading on record; the mechanism is a
    # NAMED OPEN FINDING in the README and is not claimed here.
    #
    # ⛔ SO O4.4 IS `move >= k` WITH THE EXTRAS PRICED, AND ITS BUDGET IS LOOSE
    # ON PURPOSE -- which is why it is not the only arm. `O4.4x` drives the same
    # oracle UNDER the boundary, where the answer must be exactly k, and that is
    # the arm that can still convict the app of miscounting. `sitting.ps1` runs a
    # THIRD `pointer` run at `-HandSettleMs 10` (the second one driving a real
    # hand) so both arms land in one sitting.
    $handNote = ''
    $postPressMs = 0
    $postPressKnown = $true
    $postPressSource = "no injector receipt for this run: the SYNTHETIC arm is replayed inside the shell and never crosses a real pointer stream, so the post-press drag is 0 ms, the extras budget is 0 and an EXACT reading is required"
    if ($Hand -and (Test-Path $handReceipt)) {
        $rcTxt = (Get-Content $handReceipt) -join ' | '
        $mPost = [regex]::Match($rcTxt, 'post-press-moves=([0-9]+)')
        $mColl = [regex]::Match($rcTxt, 'normalized-collisions=([0-9]+)')
        $mMs = [regex]::Match($rcTxt, 'post-press-ms=([0-9]+)')
        if ($mPost.Success) {
            $handNote = " The injector sent post-press-moves=$($mPost.Groups[1].Value)" +
                        $(if ($mColl.Success) { " with normalized-collisions=$($mColl.Groups[1].Value)" } else { '' }) +
                        ", and its button events carry no position."
        }
        if ($mMs.Success) {
            $postPressMs = [int]$mMs.Groups[1].Value
            # ⛔ FIRST-POST-PRESS-MOVE TO RELEASE, WHICH IS THE COLUMN THE
            # BOUNDARY WAS CALIBRATED ON (k x settle). The receipt also carries
            # `button-held-ms`, one settle longer; quoting that one here would
            # move the budget by a step against a boundary measured on the other.
            $postPressSource = "the injector's own receipt: post-press-ms=$postPressMs (its first post-press move to its release, measured by the hand that sent them)"
        } else {
            $postPressKnown = $false
            $postPressSource = "the injector's receipt carries no post-press-ms= field (an older send_hand.ps1), and the extras can only be priced against the drag's DURATION"
        }
    } elseif ($Hand) {
        $postPressKnown = $false
        $postPressSource = "the hand was dispatched and wrote no receipt, so this run has no post-press duration to price the extras against"
    }

    if ($null -eq $move) {
        Add-NotRun "$o4Prefix.4 move >= k, extras priced against the drag's duration" `
            "the gesture row carries no readable move= field" -Row $gestureRow
        Add-NotRun "$o4Prefix.4x move == k EXACTLY (under the 160ms boundary)" `
            "the gesture row carries no readable move= field" -Row $gestureRow
    } elseif (-not $postPressKnown) {
        Add-NotRun "$o4Prefix.4 move >= k, extras priced against the drag's duration" `
            "$postPressSource. Read anyway: k=$wantK asked, move=$move reported (press=$press release=$release).$handNote" -Row $gestureRow
        Add-NotRun "$o4Prefix.4x move == k EXACTLY (under the 160ms boundary)" `
            "$postPressSource, so this run cannot be shown to be under the boundary. Read anyway: k=$wantK asked, move=$move reported" -Row $gestureRow
    } else {
        $mc = Test-SbMoveCount -Move ([int]$move) -K $wantK -PostPressMs $postPressMs
        if ($mc.Ok) {
            Add-Assert -Name "$o4Prefix.4 move >= k, extras priced against the drag's duration" -Verdict 'PASS' `
                -Detail "$($mc.Text) (press=$press release=$release). The budget is one arrival per 160 ms of post-press drag, rounded up -- the boundary measured on kenai 2026-09-04, where the source is a periodic system arrival while the button is held: CHARACTERISED, NOT IDENTIFIED. Duration source: $postPressSource.$handNote" -Row $gestureRow
        } elseif ($mc.Extras -lt 0) {
            Add-Assert -Name "$o4Prefix.4 move >= k, extras priced against the drag's duration" -Verdict 'FAIL' `
                -Detail "$($mc.Text) -- move < k: coalescence, a UIPI-discarded event, or two steps landing on one normalized grid point (the receipt's normalized-collisions says which). Duration source: $postPressSource.$handNote" -Row $gestureRow
        } else {
            Add-Assert -Name "$o4Prefix.4 move >= k, extras priced against the drag's duration" -Verdict 'FAIL' `
                -Detail "$($mc.Text) -- MORE extras than a $($postPressMs)ms drag can account for at one arrival per 160 ms. That is outside the characterisation, so it is a finding about this run rather than the known periodic arrival. Duration source: $postPressSource.$handNote" -Row $gestureRow
        }

        $ex = Test-SbMoveExact -Move ([int]$move) -K $wantK -PostPressMs $postPressMs
        if (-not $ex.Applies -and $postPressMs -le 0) {
            # NOT the boundary case, and saying so: with no real pointer stream
            # there is no drag to be under the boundary. O4.4's budget is 0 here,
            # so the exact count is already what it required.
            Add-NotRun "$o4Prefix.4x move == k EXACTLY (under the 160ms boundary)" `
                "$($ex.Text) -- this run drove no real pointer stream (post-press=0ms), so there is no held-button drag for a periodic arrival to occur during. O4.4's budget is 0 for exactly that reason and has already required the exact count. Duration source: $postPressSource" -Row $gestureRow
        } elseif (-not $ex.Applies) {
            Add-NotRun "$o4Prefix.4x move == k EXACTLY (under the 160ms boundary)" `
                "$($ex.Text) -- this run's post-press drag is past the 160-180 ms boundary, where one extra arrival is EXPECTED and an exact assertion would red on a run behaving as characterised. The exact arm is driven by the sitting's -HandSettleMs 10 pointer run. Duration source: $postPressSource" -Row $gestureRow
        } elseif ($ex.Ok) {
            Add-Assert -Name "$o4Prefix.4x move == k EXACTLY (under the 160ms boundary)" -Verdict 'PASS' `
                -Detail "$($ex.Text) -- under the boundary the window sees exactly what the injector sent, so this is the arm that can convict the app of miscounting. Duration source: $postPressSource.$handNote" -Row $gestureRow
        } else {
            Add-Assert -Name "$o4Prefix.4x move == k EXACTLY (under the 160ms boundary)" -Verdict 'FAIL' `
                -Detail "$($ex.Text) -- the drag was short enough that no periodic arrival is expected, and the count still differs. Duration source: $postPressSource.$handNote" -Row $gestureRow
        }
    }

    if ($HandEmpty) {
        # THE ZERO IS THE POINT, and it is only readable because doc=HELD.
        if ($selected -eq '0' -and $press -eq '1' -and [int]$move -ge 1 -and $release -eq '1' -and $doc -eq 'HELD') {
            Add-Assert -Name 'O4.C1 empty canvas: press=1 move>=1 release=1 selected=0 with doc=HELD' -Verdict 'PASS' `
                -Detail 'the counters prove ARRIVAL; the zero proves the MISS, and doc=HELD is what proves the subject was loaded' -Row $gestureRow
        } else {
            Add-Assert -Name 'O4.C1 empty canvas: press=1 move>=1 release=1 selected=0 with doc=HELD' -Verdict 'FAIL' `
                -Detail "press=$press move=$move release=$release selected=$selected doc=$doc" -Row $gestureRow
        }
    } else {
        if ($selected -eq '1') {
            Add-Assert -Name "$o4Prefix.5 selected == 1" -Verdict 'PASS' -Detail 'exactly the harness-chosen element is selected' -Row $gestureRow
        } else {
            Add-Assert -Name "$o4Prefix.5 selected == 1" -Verdict 'FAIL' -Detail "selected=$selected (doc=$doc)" -Row $gestureRow
        }
    }

    # ---- the coordinate arm ------------------------------------------------
    #
    # ⛔ THE SCALE IS THE SHELL'S, AND THE AWARENESS CONTEXT DECIDES WHETHER IT
    # MEANS ANYTHING. `-Scale` is gone: PR #110 measured that it reached nothing
    # (the injector has no such parameter and derives the factor from
    # `GetDpiForWindow`), so the only scale in play is the one the shell reports on
    # its own row -- and on a DPI-UNAWARE process that number is TRUE FROM INSIDE
    # A VIRTUALISED VIEW and false about the screen. Four independent numbers put
    # kenai's panel at 3840x2160 at 150%, the client at 2856x1464 against a
    # 1904x941 surface (exactly 1.5), and the gesture landed at 2/3 of the asked
    # point -- three times, at three different points.
    #
    # So these two arms assert ONLY when the shell reports a per-monitor awareness
    # context. Otherwise they are `NOT RUN` BY NAME -- and they PRINT THE NUMBERS
    # ANYWAY, because the reading is evidence about the manifest even when it
    # cannot be a verdict about the seam. Convicting the injector of the shell's
    # missing manifest would be the wrong repair aimed at the wrong file.
    #
    # ⚠️ BOTH ROW SHAPES: an ABSENT `dpi-awareness=` field is the pre-shell-wave
    # shell, whose awareness is UNKNOWN to this harness -- and unknown is not
    # per-monitor.
    # ⛔ THE AWARENESS AND THE DPI ARE ASSERTED TOGETHER, AND THAT IS THE SHELL
    # WAVE'S OWN RULING (PR #113). `GetAwarenessFromDpiAwarenessContext` CANNOT
    # distinguish PerMonitorV2 from PerMonitor(v1) -- both answer
    # `DPI_AWARENESS_PER_MONITOR_AWARE` -- so the awareness alone is weaker than it
    # looks. The pair (`PER_MONITOR_AWARE`, `dpi-for-window=144` on a 150% panel)
    # is the evidence, and `composition-scale=` is the third number that has to
    # agree with the second: an aware window whose DPI and whose composition scale
    # disagree is not a window whose coordinates this harness can price.
    $startupRow = Select-SbRow $rows 'STARTUP dpi-awareness='
    $aware = Get-SbField $startupRow 'dpi-awareness'
    $dpiFor = Get-SbField $startupRow 'dpi-for-window'
    $compScale = Get-SbField $startupRow 'composition-scale'
    $clientDips = Get-SbField $startupRow 'client-dips'
    $surfReq = Get-SbField $startupRow 'surface-request'
    $compX = $null
    if ($null -ne $compScale -and $compScale -match '^([0-9.]+)x([0-9.]+)$') { $compX = [double]$Matches[1] }
    $dpiScale = $null
    if ($null -ne $dpiFor -and [double]$dpiFor -gt 0) { $dpiScale = [double]$dpiFor / 96.0 }
    $awareOk = ($null -ne $aware) -and ($aware -match '(?i)PER_MONITOR_AWARE') -and
               ($null -ne $dpiScale) -and ($null -ne $compX) -and
               ([math]::Abs($dpiScale - $compX) -le 0.01)
    $awareText = if ($null -eq $startupRow) {
        'the shell wrote no STARTUP dpi-awareness= row (pre-shell-wave row shape): this harness cannot tell whether the window is DPI-virtualised'
    } elseif ($null -eq $dpiFor -or $null -eq $compScale) {
        "the STARTUP row reads dpi-awareness=$aware but carries no readable dpi-for-window=/composition-scale= pair, and the awareness alone cannot separate PerMonitorV2 from v1"
    } elseif (-not $awareOk) {
        "the STARTUP row reads dpi-awareness=$aware dpi-for-window=$dpiFor composition-scale=$compScale client-dips=$clientDips surface-request=$surfReq -- the awareness is not PER_MONITOR_AWARE, or dpi-for-window/96 and the composition scale disagree"
    } else {
        "the STARTUP row reads dpi-awareness=$aware dpi-for-window=$dpiFor composition-scale=$compScale client-dips=$clientDips surface-request=$surfReq, and dpi-for-window/96 agrees with the composition scale"
    }

    if ($null -eq $handAsked) {
        Add-NotRun "$o4Prefix.6 (release@ - press@)/scale == the asked delta" `
            'this harness did not choose the delta for this run, so there is nothing to compare the observed one to'
    } elseif ($null -eq $pressAt -or $null -eq $releaseAt -or $null -eq $rowScale) {
        Add-NotRun "$o4Prefix.6 (release@ - press@)/scale == the asked delta" `
            'the row did not carry a readable press@/release@/scale triple'
    } elseif (-not $awareOk) {
        $s0 = [double]$rowScale
        if ($s0 -le 0) { $s0 = 1.0 }
        $od = ("observed ({0:N2},{1:N2}) DIP against the asked ({2},{3}) at the shell's reported scale={4}" -f
               (($releaseAt.X - $pressAt.X) / $s0), (($releaseAt.Y - $pressAt.Y) / $s0), $handAsked.Dx, $handAsked.Dy, $s0)
        $op = ("press@ ({0:N1},{1:N1}) px against the asked ({2:N1},{3:N1}) px -- offset {4:N1} px" -f
               $pressAt.X, $pressAt.Y, ($handAsked.X * $s0), ($handAsked.Y * $s0),
               [math]::Sqrt([math]::Pow($pressAt.X - ($handAsked.X * $s0), 2) + [math]::Pow($pressAt.Y - ($handAsked.Y * $s0), 2)))
        Add-NotRun "$o4Prefix.6 (release@ - press@)/scale == the asked delta" `
            "$awareText, so its scale= describes a view that may be virtualised and a coordinate verdict would price the manifest, not the seam. Read anyway: $od" -Row $gestureRow
        Add-NotRun "$o4Prefix.7 the observed press point is within 2 px of the asked one" `
            "$awareText. Read anyway: $op" -Row $gestureRow
    } else {
        $s = [double]$rowScale
        if ($s -le 0) { $s = 1.0 }
        $obsDx = ($releaseAt.X - $pressAt.X) / $s
        $obsDy = ($releaseAt.Y - $pressAt.Y) / $s
        $tol = 1.0 / $s
        $okD = ([math]::Abs($obsDx - $handAsked.Dx) -le $tol) -and ([math]::Abs($obsDy - $handAsked.Dy) -le $tol)
        $detail = ("observed ({0:N2},{1:N2}) DIP against the asked ({2},{3}), tolerance +-{4:N3} DIP (1/scale, scale={5})" -f
                   $obsDx, $obsDy, $handAsked.Dx, $handAsked.Dy, $tol, $s)
        if ($okD) {
            Add-Assert -Name "$o4Prefix.6 (release@ - press@)/scale == the asked delta" -Verdict 'PASS' -Detail $detail -Row $gestureRow
        } else {
            Add-Assert -Name "$o4Prefix.6 (release@ - press@)/scale == the asked delta" -Verdict 'FAIL' -Detail $detail -Row $gestureRow
        }

        # AND THE SECOND, INDEPENDENT ARM: the observed press point against the
        # point the harness asked for, in pixels. It catches an offset the delta
        # arm is blind to -- a drag of the right shape in the wrong place.
        $askPx = $handAsked.X * $s
        $askPy = $handAsked.Y * $s
        $off = [math]::Sqrt([math]::Pow($pressAt.X - $askPx, 2) + [math]::Pow($pressAt.Y - $askPy, 2))
        $detail2 = ("press@ ({0:N1},{1:N1}) px against the asked ({2:N1},{3:N1}) px -- offset {4:N1} px" -f
                    $pressAt.X, $pressAt.Y, $askPx, $askPy, $off)
        if ($off -le 2.0) {
            Add-Assert -Name "$o4Prefix.7 the observed press point is within 2 px of the asked one" -Verdict 'PASS' -Detail $detail2 -Row $gestureRow
        } else {
            Add-Assert -Name "$o4Prefix.7 the observed press point is within 2 px of the asked one" -Verdict 'FAIL' -Detail $detail2 -Row $gestureRow
        }
    }

    # ---- O4.8: the two numbers that catch a virtualised window --------------
    #
    # ⭐ THE HARNESS CAN MEASURE THE VIRTUALISATION ITSELF, TODAY, WITHOUT THE
    # SHELL'S NEW FIELD. The injector reports the window's CLIENT size in physical
    # pixels (`client=2856x1464` on kenai) and the row reports the SURFACE in DIPs
    # (`surface=1904x941`); their ratio is the true physical-per-DIP factor
    # (exactly 1.5), and the shell reported `scale=1`. That disagreement IS the
    # defect, and it was sitting in the harness's own receipt the whole time --
    # printed as a note nobody could fail.
    #
    # ⛔ THIS IS THE ARM THAT KEEPS TEETH WHILE O4.6/O4.7 ARE REFUSED. Without it,
    # a shell with no manifest would produce a run in which every coordinate
    # clause reads NOT RUN and nothing at all convicts.
    #
    # DECIDED WITHOUT AN OPERATOR: it is a full assertion rather than a note,
    # because a note has no failure mode and this comparison does.
    if (-not $Hand) {
        Add-NotRun "$o4Prefix.8 the injector's client/surface ratio agrees with the shell's reported scale" `
            'no session-1 hand ran, so there is no client= measurement to compare the row against'
    } elseif (-not (Test-Path $handReceipt)) {
        Add-NotRun "$o4Prefix.8 the injector's client/surface ratio agrees with the shell's reported scale" `
            'the injector wrote no receipt, so there is no client= measurement to compare the row against'
    } else {
        $rcAll = (Get-Content $handReceipt) -join ' | '
        $mCl = [regex]::Match($rcAll, 'client=([0-9]+)x([0-9]+)')
        $surfField = Get-SbField $gestureRow 'surface'
        if (-not $mCl.Success -or $null -eq $surfField -or $null -eq $rowScale) {
            Add-NotRun "$o4Prefix.8 the injector's client/surface ratio agrees with the shell's reported scale" `
                "the receipt carried no client=WxH, or the row carried no surface=/scale= (client match: $($mCl.Success), surface: $surfField, scale: $rowScale)"
        } else {
            $clientW = [double]$mCl.Groups[1].Value
            $surfW = [double](($surfField -split 'x')[0])
            if ($surfW -le 0) {
                Add-NotRun "$o4Prefix.8 the injector's client/surface ratio agrees with the shell's reported scale" `
                    "the row's surface width is $surfW"
            } else {
                # ⛔ THE EXPECTED RATIO CHANGED WITH THE SHELL WAVE, AND READING
                # THE OLD ONE WOULD NOW RED ON A CORRECT SHELL. Before PR #113
                # the surface was sized in DIPs while the injector's client rect
                # is physical, so the ratio WAS the scale (1.5 measured, against a
                # reported scale=1 -- the defect). Since #113 the surface is
                # derived in physical pixels, so the two numbers are the same
                # measurement and the ratio must be 1.0. The `STARTUP` row is what
                # says which shell wrote these rows; it is not guessed.
                $ratio = $clientW / $surfW
                $rs = [double]$rowScale
                $newShell = ($null -ne $startupRow)
                $want = if ($newShell) { 1.0 } else { $rs }
                $wantText = if ($newShell) {
                    "1.0 (since the shell wave the surface is derived in PHYSICAL pixels, so the injector's client rect and the surface are the same measurement; the shell reports scale=$rs separately)"
                } else {
                    "the shell's reported scale=$rs (pre-shell-wave: the surface was sized in DIPs, so the ratio IS the scale)"
                }
                $d8 = ("client {0} / surface {1} = {2:N3}, against the expected {3}" -f
                       $mCl.Groups[0].Value.Substring(7), $surfField, $ratio, $wantText)
                if ([math]::Abs($ratio - $want) -le 0.01) {
                    Add-Assert -Name "$o4Prefix.8 the injector's client rect and the shell's surface are the same measurement" -Verdict 'PASS' `
                        -Detail "$d8 -- the window is not being bitmap-virtualised. $awareText" -Row $gestureRow
                } else {
                    Add-Assert -Name "$o4Prefix.8 the injector's client rect and the shell's surface are the same measurement" -Verdict 'FAIL' `
                        -Detail "$d8 -- they disagree, which is what a DPI-virtualised window looks like from outside: the shell's number is true of its own view and false of the screen, and every gesture lands at ratio/scale of the asked point. $awareText" -Row $gestureRow
                }
            }
        }
    }

    # ⛔ A NOTE, NOT AN ASSERTION. The injector's receipt records what was SENT;
    # `SendInput` returns success even when UIPI discards the events, so nothing
    # in it can fail and an assertion over it would be a count with no failure
    # mode. It is printed because it explains a miss, not because it proves a hit.
    if ($Hand -and (Test-Path $handReceipt)) {
        $verdicts += ("note: session-1 injector receipt -- " + ((Get-Content $handReceipt) -join ' | '))
    }
}

# ===========================================================================
# O5 -- RUN AND STAY (the parts a single verify run can see)
# ===========================================================================

if ($Scene -eq 'stay') {
    $stayRow = Select-SbRow $rows 'RUSTOK STAY pid='
    if ($null -eq $stayRow) {
        Add-NotRun 'O5.1 the STAY pid row names this run''s process' 'the stay scene wrote no STAY row'
    } else {
        $rowPid = Get-SbField $stayRow 'pid'
        if ($rowPid -eq [string]$appPid) {
            Add-Assert -Name 'O5.1 the STAY pid row names this run''s process' -Verdict 'PASS' `
                -Detail "the app reported pid=$rowPid and this harness launched pid $appPid -- two independent identifications agreeing" -Row $stayRow
        } else {
            Add-Assert -Name 'O5.1 the STAY pid row names this run''s process' -Verdict 'FAIL' `
                -Detail "the app reported pid=$rowPid but this harness launched pid $appPid" -Row $stayRow
        }
    }
}

# ===========================================================================
# O6 -- 0xH REFUSED THROUGH THE REAL LINK, AND THE ACCEPT ARM BESIDE IT
# ===========================================================================

$squeezeAsked = ($env:SB_SQUEEZE -eq '1')
$probeAsked = $env:SB_SURFACE_PROBE
$refuseRow = Select-SbRow $rows 'RESIZE REFUSED [0-9]+x0 .* policy=EVENT'
$acceptRow = Select-SbRow $rows 'RESIZE ACCEPTED [0-9]+x[0-9]+ policy=PROBE'
$probeRefuseRow = Select-SbRow $rows 'RESIZE REFUSED [0-9]+x[0-9]+ .* policy=PROBE'

if (-not $squeezeAsked) {
    Add-NotRun 'O6.1 RESIZE REFUSED WxH through the REAL link (policy=EVENT)' `
        'SB_SQUEEZE is not 1: the real-link arm was not driven this run'
} else {
    # ⛔ THE DELIVERY ROW IS THE SUBJECT NOW, AND IT SEPARATES THREE OUTCOMES A
    # SILENCE COULD NOT. PR #110: `SB_SQUEEZE=1` set, no refusal row written at
    # all, twice -- and the log could not say whether the zero never reached the
    # panel or the policy accepted it. The shell wave (PR #113) writes EXACTLY ONE
    # `SQUEEZE delivered` row per squeeze, always, so its absence is now a shell
    # defect rather than an ambiguity, and its own `policy=` field says which of
    # the three happened.
    #
    # ⛔ `policy=` IS READ WITH AN ANCHORED PATTERN, NOT WITH THE FIELD READER.
    # The row carries `min-height policy=<m>` BEFORE the verdict's own
    # `policy=<Refuse|Defer|Accept>`, and a first-occurrence `policy=` reader would
    # return the min-height number and call it the decision.
    $deliveredRows = @($rows | Where-Object { $_ -match 'SQUEEZE delivered ' })
    $deliveredRow = if ($deliveredRows.Count -gt 0) { $deliveredRows[-1] } else { $null }
    $delivered = ''
    $delH = -1
    $delPolicy = ''
    if ($null -ne $deliveredRow) {
        $md = [regex]::Match($deliveredRow, 'SQUEEZE delivered (\S+)')
        if ($md.Success) { $delivered = $md.Groups[1].Value }
        $mh = [regex]::Match($delivered, '^([0-9]+)x([0-9]+)$')
        if ($mh.Success) { $delH = [int]$mh.Groups[2].Value }
        $mp = [regex]::Match($deliveredRow, '\)\s+policy=(\S+)')
        if ($mp.Success) { $delPolicy = $mp.Groups[1].Value }
    }

    if ($deliveredRows.Count -eq 0) {
        Add-Assert -Name 'O6.1 RESIZE REFUSED WxH through the REAL link (policy=EVENT)' -Verdict 'FAIL' `
            -Detail 'SB_SQUEEZE=1 was set and the shell wrote NO SQUEEZE delivered row. Since the shell wave exactly one is written per squeeze in every outcome, so its absence is a shell defect and not an ambiguity'
    } elseif ($deliveredRows.Count -gt 1) {
        Add-Assert -Name 'O6.1 RESIZE REFUSED WxH through the REAL link (policy=EVENT)' -Verdict 'FAIL' `
            -Detail "$($deliveredRows.Count) SQUEEZE delivered rows in one run; exactly one is written per squeeze, so this run's receipt cannot be read as one decision" -Row $deliveredRows[-1]
    } elseif ($delivered -eq 'NONE') {
        # ⛔ THE READING IS "NOT REACHABLE ON THIS WINDOW MANAGER", AND IT IS A
        # MEASUREMENT, NOT AN ABSENCE. Kenai 2026-09-04, Windows 11 26200:
        # `PreferredMinimumHeight = 1` was ACCEPTED (the presenter is not the
        # floor), the request was `AppWindow.Resize(w, 35)` -- a squeeze of the
        # CLIENT area to zero through a 35-px WINDOW -- and the manager delivered
        # NO SizeChanged at all within the 2 s deadline. The accept arm (O6.3, at
        # 1000x600) proves the machinery works, so `SurfacePolicy`'s zero-height
        # branch is unexercised because NOTHING ARRIVES, not because it declined.
        # The reason text says which of those two it is, and quotes the row.
        Add-NotRun 'O6.1 RESIZE REFUSED WxH through the REAL link (policy=EVENT)' `
            "NOT RUN: not reachable on this window manager -- the receipt reads '$deliveredRow'. The squeeze was delivered NONE: no SizeChanged arrived within the deadline, so the zero-height condition was never produced and the policy was never asked. That is a third finding, distinguishable at last, and it is not a verdict on the policy; O6.3's PROBE arm is the control that proves the policy can accept" -Row $deliveredRow
    } elseif ($delivered -eq 'THREW') {
        Add-NotRun 'O6.1 RESIZE REFUSED WxH through the REAL link (policy=EVENT)' `
            'the squeeze request THREW, so the zero-height condition was never produced' -Row $deliveredRow
    } elseif ($delH -gt 0) {
        Add-NotRun 'O6.1 RESIZE REFUSED WxH through the REAL link (policy=EVENT)' `
            "the window manager delivered $delivered -- a NON-ZERO height (policy=$delPolicy). The manager clamped at its minimum and the zero never arrived, so the condition this assertion is about was never produced. The delivered height is the evidence; a silence would have read as a bug in the panel" -Row $deliveredRow
    } elseif ($delH -eq 0 -and $delPolicy -eq 'Accept') {
        Add-Assert -Name 'O6.1 RESIZE REFUSED WxH through the REAL link (policy=EVENT)' -Verdict 'FAIL' `
            -Detail "the window manager delivered $delivered -- a ZERO height -- and the policy ACCEPTED it. That is a real defect in SurfacePolicy, not a harness reading" -Row $deliveredRow
    } elseif ($delH -eq 0 -and $null -eq $refuseRow) {
        Add-Assert -Name 'O6.1 RESIZE REFUSED WxH through the REAL link (policy=EVENT)' -Verdict 'FAIL' `
            -Detail "the delivered row says $delivered policy=$delPolicy and NO 'RESIZE REFUSED <W>x0 ... policy=EVENT' row accompanies it -- the receipt and the row disagree about the same decision" -Row $deliveredRow
    } elseif ($null -eq $refuseRow) {
        Add-NotRun 'O6.1 RESIZE REFUSED WxH through the REAL link (policy=EVENT)' `
            "the delivered row reads '$delivered' policy=$delPolicy, which this harness does not know how to price against the missing refusal row" -Row $deliveredRow
    } else {
        Add-Assert -Name 'O6.1 RESIZE REFUSED WxH through the REAL link (policy=EVENT)' -Verdict 'PASS' `
            -Detail "a zero height arrived through the window manager (delivered $delivered, policy=$delPolicy) and the policy refused it, keeping the last good surface" -Row $refuseRow
    }
}

if ($squeezeAsked -and $null -ne $refuseRow) {
    # ⛔ AND NOTHING MAY HAVE BEEN RESIZED FOR IT. A refusal that still resized
    # the swapchain would be a receipt about a decision the code did not take.
    $refuseIdx = [array]::IndexOf($rows, $refuseRow)
    $tail = if ($refuseIdx -ge 0 -and $refuseIdx -lt ($rows.Count - 1)) { @($rows[($refuseIdx + 1)..($rows.Count - 1)]) } else { @() }
    $resizeAfter = @($tail | Where-Object { $_ -match 'REPAINT events_total=' -and $_ -match 'cause=resize' })
    $rebuild = @($tail | Where-Object { $_ -match 'ResizeBuffers' })
    if ($resizeAfter.Count -eq 0 -and $rebuild.Count -eq 0) {
        Add-Assert -Name 'O6.2 no ResizeBuffers and no REPAINT cause=resize for the refused size' -Verdict 'PASS' `
            -Detail 'no resize-caused REPAINT row follows the refusal. NAMED WEAKNESS: the shell writes no explicit ResizeBuffers row, so that half of this assertion can only ever read zero; the REPAINT half is the one with teeth, because a swapchain that was resized would have been repainted' -Row $refuseRow
    } else {
        Add-Assert -Name 'O6.2 no ResizeBuffers and no REPAINT cause=resize for the refused size' -Verdict 'FAIL' `
            -Detail "$($resizeAfter.Count) resize-caused repaint row(s) and $($rebuild.Count) ResizeBuffers mention(s) follow the refusal" `
            -Row $(if ($resizeAfter.Count) { $resizeAfter[0] } else { $rebuild[0] })
    }
}

# THE ACCEPT ARM. A refusal arm alone is satisfied by a function that refuses
# everything, so this is not optional decoration.
if ([string]::IsNullOrWhiteSpace($probeAsked)) {
    Add-NotRun 'O6.3 SB_SURFACE_PROBE=1000x600 accepts (policy=PROBE) and resizes' `
        'SB_SURFACE_PROBE is not set: the policy function''s accept arm was not driven this run'
} elseif ($probeAsked -match '^0x0$') {
    if ($null -ne $probeRefuseRow) {
        Add-Assert -Name 'O6.3b SB_SURFACE_PROBE=0x0 refuses (policy=PROBE)' -Verdict 'PASS' `
            -Detail 'the policy function refused a zero fed straight to it, with no window manager involved' -Row $probeRefuseRow
    } else {
        Add-Assert -Name 'O6.3b SB_SURFACE_PROBE=0x0 refuses (policy=PROBE)' -Verdict 'FAIL' `
            -Detail 'SB_SURFACE_PROBE=0x0 was set and no policy=PROBE refusal row was written'
    }
} elseif ($null -eq $acceptRow) {
    Add-Assert -Name 'O6.3 SB_SURFACE_PROBE accepts (policy=PROBE) and resizes' -Verdict 'FAIL' `
        -Detail "SB_SURFACE_PROBE='$probeAsked' was set and no RESIZE ACCEPTED ... policy=PROBE row was written -- a policy that only ever refuses is not a three-valued policy"
} else {
    $acceptIdx = [array]::IndexOf($rows, $acceptRow)
    $tail2 = if ($acceptIdx -ge 0 -and $acceptIdx -lt ($rows.Count - 1)) { @($rows[($acceptIdx + 1)..($rows.Count - 1)]) } else { @() }
    $resizedAfter = @($tail2 | Where-Object { $_ -match 'REPAINT events_total=' -and $_ -match 'cause=resize' })
    if ($resizedAfter.Count -ge 1) {
        Add-Assert -Name 'O6.3 SB_SURFACE_PROBE accepts (policy=PROBE) and resizes' -Verdict 'PASS' `
            -Detail "accepted, and $($resizedAfter.Count) resize-caused repaint row(s) followed at surface $(Get-SbField $resizedAfter[0] 'surface')" -Row $acceptRow
    } else {
        Add-Assert -Name 'O6.3 SB_SURFACE_PROBE accepts (policy=PROBE) and resizes' -Verdict 'FAIL' `
            -Detail 'the row says ACCEPTED and no resize-caused repaint followed it' -Row $acceptRow
    }
}

# ===========================================================================
# O6.4 -- SPLIT INTO TWO RUNS, BECAUSE ONE RUN CANNOT HOLD BOTH ARMS
# ===========================================================================
#
# ⛔ THE OLD CLAUSE WAS STRUCTURALLY UNRUNNABLE, AND PR #110 MEASURED IT. It
# demanded `SB_SQUEEZE=1` AND `SB_SURFACE_PROBE=1000x600` in ONE `retained` run --
# but the probe moves the surface PERMANENTLY to 1000x600, so the round trip never
# returns to 1904x941, `A'` is never written, and `surface(A) == surface(A')` can
# never hold. Measured both ways: 1 of 4 hash rows without the hand, 2 of 4 with
# it. The clause and the scene were in contradiction, and no reading of either
# could have shown it -- only running it could.
#
# So it is TWO RUNS and the arms travel by receipt:
#
#   * THE SQUEEZE RUN (`SB_SQUEEZE=1`, no probe) writes O6.4a -- the hash and the
#     surface BRACKETING the refusal row -- and its receipt.
#   * THE PROBE RUN (`SB_SURFACE_PROBE=1000x600`, no squeeze) writes O6.3, the
#     accept arm, and its receipt.
#   * O6.4 is read by whichever run can see BOTH receipts from the SAME sitting.
#
# ⛔ AND NOTHING IS COMPARED ACROSS THE TWO ROUTES. PR #110: `SB_RESIZE=1000x600`
# through the EVENT route reports a 984x526 client while `SB_SURFACE_PROBE=1000x600`
# reports 1000x600 exactly -- the same asked size, two different reported surfaces,
# because one is a WINDOW size and the other a SURFACE size. The probe run
# contributes ONE FACT ONLY -- that the policy is capable of accepting -- and never
# a number the squeeze run's equality is measured against.
if ($squeezeAsked -and [string]::IsNullOrWhiteSpace($probeAsked)) {
    # ---- O6.4a: the bracket, inside the squeeze run ------------------------
    # The two hash rows STRADDLING the refusal, not the first and last of the run:
    # a `retained` walk deliberately resizes, so first-vs-last would be measuring
    # the walk. And the bracket is refused when a gesture or a driven resize lies
    # inside it, because then the inequality would be about that instead.
    $sqHashes = @($rows | Where-Object { $_ -match 'hash=[0-9a-f]{64}' })
    $sqHashes = @($rows | Where-Object { $_ -match 'hash=[0-9a-f]{64}' })
    $refIdx = if ($null -ne $refuseRow) { [array]::IndexOf($rows, $refuseRow) } else { -1 }
    $before6 = $null; $after6 = $null
    if ($refIdx -ge 0) {
        foreach ($h in $sqHashes) {
            $hi = [array]::IndexOf($rows, $h)
            if ($hi -lt $refIdx) { $before6 = $h }
            elseif ($hi -gt $refIdx -and $null -eq $after6) { $after6 = $h }
        }
    }
    if ($refIdx -lt 0) {
        Add-NotRun 'O6.4a the surface and its hash are unchanged across the refused squeeze' `
            'no policy=EVENT refusal row in this run, so there is nothing to bracket (O6.1 says why)'
    } elseif ($null -eq $before6 -or $null -eq $after6) {
        Add-NotRun 'O6.4a the surface and its hash are unchanged across the refused squeeze' `
            "the refusal is not bracketed by two hash rows (before: $(if ($null -eq $before6) { 'none' } else { 'present' }), after: $(if ($null -eq $after6) { 'none' } else { 'present' }); $($sqHashes.Count) hash row(s) in the run). Drive the squeeze on a scene that hashes on both sides of it"
    } else {
        $bIdx = [array]::IndexOf($rows, $before6)
        $aIdx = [array]::IndexOf($rows, $after6)
        # `$a[(n+1)..(m-1)]` COUNTS DOWN when the two rows are ADJACENT, yielding
        # two bogus rows instead of none -- the same trap O3.4 already carries a
        # guard for. An adjacent pair is exactly the good case here (nothing
        # between the bracket), so the unguarded spelling would refuse the very
        # reading it exists to take.
        $between = @()
        if (($aIdx - 1) -ge ($bIdx + 1)) { $between = @($rows[($bIdx + 1)..($aIdx - 1)]) }
        $inBetweenResize = @($between | Where-Object { $_ -match 'REPAINT events_total=' -and $_ -match 'cause=resize' })
        $inBetweenGesture = @($between | Where-Object { $_ -match 'POINTER (REAL|SYNTHETIC) press=' })
        $hb = Get-SbField $before6 'hash'
        $ha = Get-SbField $after6 'hash'
        $sb2 = Get-SbField $before6 'surface'
        $sa2 = Get-SbField $after6 'surface'
        $o6aDetail = "before=$hb at $sb2, after=$ha at $sa2, bracketing the refusal row"
        if ($inBetweenResize.Count -gt 0 -or $inBetweenGesture.Count -gt 0) {
            Add-NotRun 'O6.4a the surface and its hash are unchanged across the refused squeeze' `
                "$($inBetweenResize.Count) driven resize(s) and $($inBetweenGesture.Count) gesture(s) lie between the two bracketing hash rows -- an inequality here would be about those and not about the squeeze. $o6aDetail" -Row $refuseRow
            Write-SbReceipt -Path $o6SqueezeReceipt -Data @{ verdict = 'NOT RUN'; detail = $o6aDetail; hash_before = $hb; hash_after = $ha; surface_before = $sb2; surface_after = $sa2 }
        } elseif ($hb -eq $ha -and $sb2 -eq $sa2) {
            Add-Assert -Name 'O6.4a the surface and its hash are unchanged across the refused squeeze' -Verdict 'PASS' `
                -Detail "$o6aDetail, with no driven resize and no gesture between them" -Row $refuseRow
            Write-SbReceipt -Path $o6SqueezeReceipt -Data @{ verdict = 'PASS'; detail = $o6aDetail; hash_before = $hb; hash_after = $ha; surface_before = $sb2; surface_after = $sa2 }
        } else {
            Add-Assert -Name 'O6.4a the surface and its hash are unchanged across the refused squeeze' -Verdict 'FAIL' `
                -Detail "$o6aDetail -- something changed across a refusal" -Row $refuseRow
            Write-SbReceipt -Path $o6SqueezeReceipt -Data @{ verdict = 'FAIL'; detail = $o6aDetail; hash_before = $hb; hash_after = $ha; surface_before = $sb2; surface_after = $sa2 }
        }
    }
}

# ---- the probe run's receipt: ONE FACT, the policy can accept ---------------
if ((-not $squeezeAsked) -and (-not [string]::IsNullOrWhiteSpace($probeAsked)) -and ($probeAsked -notmatch '^0x0$')) {
    $accepted = ($null -ne $acceptRow)
    Write-SbReceipt -Path $o6ProbeReceipt -Data @{
        accepted = $accepted
        asked = [string]$probeAsked
        surface_after = $(if ($accepted) { Get-SbField $acceptRow 'surface' } else { '' })
        row = [string]$acceptRow
    }
}

# ---- O6.4: the two runs, read together --------------------------------------
#
# ⛔ THE EQUALITY ALONE IS STILL VACUOUS. A surface nobody touched is trivially
# equal to itself, so the squeeze run's PASS means something only beside a run
# that showed the policy CAN change a surface. That has not become less true; it
# has stopped being something one run can satisfy.
if ($squeezeAsked -or (-not [string]::IsNullOrWhiteSpace($probeAsked))) {
    $sqR = Read-SbReceipt $o6SqueezeReceipt 'O6 squeeze-run'
    $prR = Read-SbReceipt $o6ProbeReceipt 'O6 probe-run'
    if (-not $sqR.Ok) {
        Add-NotRun 'O6.4 the refused squeeze changed nothing, read together with a probe run that proves the policy can accept' $sqR.Reason
    } elseif (-not $prR.Ok) {
        Add-NotRun 'O6.4 the refused squeeze changed nothing, read together with a probe run that proves the policy can accept' $prR.Reason
    } elseif (-not $prR.Data.accepted) {
        Add-NotRun 'O6.4 the refused squeeze changed nothing, read together with a probe run that proves the policy can accept' `
            "the probe run asked $($prR.Data.asked) and the policy did not accept it, so this sitting has not shown the policy capable of changing a surface. The equality is refused rather than read"
    } elseif ([string]$sqR.Data.verdict -ne 'PASS') {
        Add-NotRun 'O6.4 the refused squeeze changed nothing, read together with a probe run that proves the policy can accept' `
            "the squeeze run's O6.4a read $($sqR.Data.verdict): $($sqR.Data.detail)"
    } else {
        Add-Assert -Name 'O6.4 the refused squeeze changed nothing, read together with a probe run that proves the policy can accept' -Verdict 'PASS' `
            -Detail "squeeze run: $($sqR.Data.detail). Probe run: asked $($prR.Data.asked), ACCEPTED, surface after $($prR.Data.surface_after). The two surfaces are NOT compared with each other -- the EVENT route reports a window's client area and the PROBE route a surface, and the same asked size reads differently on each"
    }
}
