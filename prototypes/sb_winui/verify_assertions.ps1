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
$paintOnUi = ($env:SB_PAINT_ON_UI -eq '1')
$uiStallMs = Get-KnobMs 'SB_UI_STALL_MS'
$renderStallMs = Get-KnobMs 'SB_RENDER_STALL_MS'
$synthAsked = -not [string]::IsNullOrWhiteSpace($env:SB_SYNTH_DRAG)

function Get-SbHashRow([string]$label) {
    return Select-SbRow $rows ("`t" + [regex]::Escape($label) + " surface=")
}

# ===========================================================================
# O3 -- RESIDENCY BY TIDS, LIVENESS BY `Responding`
# Asserted on EVERY scene, because the claim is about every row.
# ===========================================================================

if ($tidRows.Count -eq 0) {
    Add-NotRun 'O3.1 paint-tid == present-tid == render-tid != ui-tid' `
        "this run wrote no row carrying the tid tail -- there is nothing to assert residency over"
    Add-NotRun 'O3.2 render-has-dispatcher=false' `
        "this run wrote no row carrying the tid tail"
} else {
    $tidBad = @()
    foreach ($r in $tidRows) {
        $ui = Get-SbField $r 'ui-tid'
        $rt = Get-SbField $r 'render-tid'
        $pt = Get-SbField $r 'paint-tid'
        $st = Get-SbField $r 'present-tid'
        if ($null -eq $ui -or $null -eq $rt -or $null -eq $pt -or $null -eq $st) { continue }
        if (-not ($pt -eq $st -and $st -eq $rt -and $rt -ne $ui)) { $tidBad += $r }
    }
    if ($paintOnUi) {
        # ⛔ THE DESIGN-RED CONTROL. Under SB_PAINT_ON_UI=1 the paint and the
        # present are marshalled through the dispatcher, so `present-tid ==
        # ui-tid` BY CONSTRUCTION. A tid assertion that PASSES here has not been
        # shown capable of failing anywhere, and that is itself the failure --
        # this is the arm that makes every other green mean something.
        if ($tidBad.Count -gt 0) {
            Add-Assert -Name 'O3.C2 SB_PAINT_ON_UI=1 design-red control' -Verdict 'PASS' `
                -Detail "the tid assertion FAILED on $($tidBad.Count) of $($tidRows.Count) rows, as it must under this knob" `
                -Row $tidBad[0]
        } else {
            Add-Assert -Name 'O3.C2 SB_PAINT_ON_UI=1 design-red control' -Verdict 'FAIL' `
                -Detail "the tid assertion PASSED on all $($tidRows.Count) rows under SB_PAINT_ON_UI=1. A passing residency assertion under the knob that exists to break it means the assertion cannot fail -- so every green it has ever produced is uninterpretable" `
                -Row $tidRows[-1]
        }
        Add-NotRun 'O3.1 paint-tid == present-tid == render-tid != ui-tid' `
            'SB_PAINT_ON_UI=1 is set: this run is the design-red control, not a residency measurement'
    } else {
        if ($tidBad.Count -eq 0) {
            Add-Assert -Name 'O3.1 paint-tid == present-tid == render-tid != ui-tid' -Verdict 'PASS' `
                -Detail "all $($tidRows.Count) rows of this run" -Row $tidRows[-1]
        } else {
            Add-Assert -Name 'O3.1 paint-tid == present-tid == render-tid != ui-tid' -Verdict 'FAIL' `
                -Detail "$($tidBad.Count) of $($tidRows.Count) rows do not hold it" -Row $tidBad[0]
        }
    }

    $dispBad = @($tidRows | Where-Object { (Get-SbField $_ 'render-has-dispatcher') -ne 'false' })
    if ($dispBad.Count -eq 0) {
        Add-Assert -Name 'O3.2 render-has-dispatcher=false' -Verdict 'PASS' `
            -Detail "all $($tidRows.Count) rows" -Row $tidRows[-1]
    } else {
        Add-Assert -Name 'O3.2 render-has-dispatcher=false' -Verdict 'FAIL' `
            -Detail "$($dispBad.Count) of $($tidRows.Count) rows report a dispatcher on the render thread" -Row $dispBad[0]
    }
}

# ---- liveness, sampled DURING the scene's own wait -------------------------
# ⛔ `@(2, 5, 10 | ForEach-Object {...})` PIPES ONLY THE 10. The pipeline binds
# tighter than the comma, so that spelling would have reported one sample and
# called it three -- a summary that silently under-counts its own evidence.
$samples = @(@(2, 5, 10) | ForEach-Object { "t=$($_)s:$(if ($respond.ContainsKey($_)) { $respond[$_] } else { 'not sampled' })" })
$sampleText = $samples -join ' '
if ($Scene -ne 'stall') {
    Add-NotRun 'O3.3 Responding at t=2,5,10' "this run is scene '$Scene'; the liveness claim is about the stall (samples taken anyway: $sampleText)"
} elseif ($respond.Count -lt 3) {
    Add-NotRun 'O3.3 Responding at t=2,5,10' "the scene finished before all three samples were taken ($sampleText)"
} elseif ($uiStallMs -gt 0) {
    # ⛔ THE ORACLE-LIVENESS CONTROL. `SB_UI_STALL_MS` sleeps the XAML thread, so
    # `Responding` MUST read False. An oracle that cannot say False says nothing
    # when it says True -- this arm is what makes the True x3 above evidence.
    $falses = @(@(2, 5, 10) | Where-Object { $respond[$_] -eq 'False' })
    if ($falses.Count -ge 1) {
        Add-Assert -Name 'O3.C1 SB_UI_STALL_MS oracle-liveness control' -Verdict 'PASS' `
            -Detail "Responding read False at $($falses.Count) of 3 samples -- the oracle can say False: $sampleText"
    } else {
        Add-Assert -Name 'O3.C1 SB_UI_STALL_MS oracle-liveness control' -Verdict 'FAIL' `
            -Detail "Responding never read False under a $($uiStallMs)ms UI-thread sleep: $sampleText. The oracle cannot convict, so its True readings are uninterpretable"
    }
    Add-NotRun 'O3.3 Responding at t=2,5,10' 'SB_UI_STALL_MS is set: this run is the oracle-liveness control, not the liveness measurement'
} else {
    $trues = @(@(2, 5, 10) | Where-Object { $respond[$_] -eq 'True' })
    if ($trues.Count -eq 3) {
        Add-Assert -Name 'O3.3 Responding at t=2,5,10' -Verdict 'PASS' `
            -Detail "True x3 while the render thread slept $($renderStallMs)ms: $sampleText"
    } else {
        Add-Assert -Name 'O3.3 Responding at t=2,5,10' -Verdict 'FAIL' `
            -Detail "expected True x3, read: $sampleText"
    }
}

# ---- the post-stall backlog yields EXACTLY ONE row -------------------------
if ($Scene -eq 'stall') {
    $stallRow = Select-SbRow $rows "`tSTALL render-stall="
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
    $beforeText = "before: $beforeVal ms on the OFFSCREEN+copy route (supplied via -Before '$Before'). $routeText"
}

if ($resizeRepaints.Count -eq 0) {
    Add-NotRun 'O2.1 one REPAINT cause=resize row per drain, frames=1' `
        "this run wrote no REPAINT row with cause=resize (SB_RESIZE unset, or no resize arrived). $beforeText"
    Add-NotRun 'O2.2 repaint(paint+present) <= 2 x present-mean of the same run' `
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

    # THE BAND IS A MULTIPLE OF THE SAME RUN'S OWN PRESENT, never a millisecond
    # constant: a constant would be a claim about this box, and the claim is that
    # a drain costs ONE FRAME.
    $presents = @()
    foreach ($r in $repaints) {
        $p = Get-SbField $r 'present'
        if ($null -ne $p) { $presents += [double]($p -replace 'ms$', '') }
    }
    if ($presents.Count -eq 0) {
        Add-NotRun 'O2.2 repaint(paint+present) <= 2 x present-mean of the same run' `
            'no REPAINT row carried a readable present= figure'
    } else {
        $presentMean = ($presents | Measure-Object -Average).Average
        $row = $resizeRepaints[-1]
        $paintMs = [double]((Get-SbField $row 'paint') -replace 'ms$', '')
        $presentMs = [double]((Get-SbField $row 'present') -replace 'ms$', '')
        $cost = $paintMs + $presentMs
        $band = 2.0 * $presentMean
        $detail = ("repaint(paint {0:N2} + present {1:N2}) = {2:N2} ms against 2 x present-mean {3:N2} = {4:N2} ms band, at surface {5}. {6}" -f
                   $paintMs, $presentMs, $cost, $presentMean, $band, (Get-SbField $row 'surface'), $beforeText)
        if ($cost -le $band) {
            Add-Assert -Name 'O2.2 repaint(paint+present) <= 2 x present-mean of the same run' -Verdict 'PASS' -Detail $detail -Row $row
        } else {
            Add-Assert -Name 'O2.2 repaint(paint+present) <= 2 x present-mean of the same run' -Verdict 'FAIL' -Detail $detail -Row $row
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
    if ($null -eq $handAsked) {
        Add-NotRun 'O1.2 the harness-chosen element moved by the asked delta' `
            'no gesture was driven by this harness (-Hand not given and -SynthFromDump not used), so there is no asked delta to check the dump against'
    } elseif (-not (Test-Path $afterDump)) {
        Add-NotRun 'O1.2 the harness-chosen element moved by the asked delta' `
            "sb-doc-after.json was not written -- the gesture never closed"
    } else {
        $beforeEl = Get-SbElementByPath $beforeDump $handTarget.Path
        $afterEl = Get-SbElementByPath $afterDump $handTarget.Path
        if ($null -eq $beforeEl -or $null -eq $afterEl) {
            Add-NotRun 'O1.2 the harness-chosen element moved by the asked delta' `
                "the chosen element ($($handTarget.Path)) is not at the same path in both dumps -- the harness will not match elements by guessing"
        } else {
            $bJson = ($beforeEl | ConvertTo-Json -Depth 20 -Compress)
            $aJson = ($afterEl | ConvertTo-Json -Depth 20 -Compress)
            if ($bJson -eq $aJson) {
                Add-Assert -Name 'O1.2a the chosen element CHANGED between the dumps' -Verdict 'FAIL' `
                    -Detail "$($handTarget.Type) id='$($handTarget.Id)' at $($handTarget.Path) is byte-identical before and after a gesture that asked it to move by ($($handAsked.Dx),$($handAsked.Dy))"
            } else {
                Add-Assert -Name 'O1.2a the chosen element CHANGED between the dumps' -Verdict 'PASS' `
                    -Detail "$($handTarget.Type) id='$($handTarget.Id)' at $($handTarget.Path) differs before -> after"
            }
            # THE DELTA ARM, AND IT IS SEPARATE. The tool may express a move as a
            # coordinate change or as a transform; only the first is readable as a
            # number here, and the second is a NAMED gap rather than a pass.
            $bx = $null; $ax = $null; $by = $null; $ay = $null
            foreach ($pair in @(@('x', 'y'), @('cx', 'cy'))) {
                $px = $pair[0]; $py = $pair[1]
                if (($beforeEl.PSObject.Properties.Name -contains $px) -and
                    ($afterEl.PSObject.Properties.Name -contains $px)) {
                    $bx = [double]$beforeEl.$px; $ax = [double]$afterEl.$px
                    $by = [double]$beforeEl.$py; $ay = [double]$afterEl.$py
                    break
                }
            }
            if ($null -eq $bx) {
                Add-NotRun 'O1.2b the delta in the dump equals the asked delta' `
                    "the chosen element carries no x/y or cx/cy pair to read -- the delta arm cannot read this element's move"
            } elseif ([math]::Abs(($ax - $bx) - $handAsked.Dx) -le 1.0 -and
                      [math]::Abs(($ay - $by) - $handAsked.Dy) -le 1.0) {
                Add-Assert -Name 'O1.2b the delta in the dump equals the asked delta' -Verdict 'PASS' `
                    -Detail ("moved ({0},{1}) against the asked ({2},{3}), within 1 document unit" -f ($ax - $bx), ($ay - $by), $handAsked.Dx, $handAsked.Dy)
            } elseif (($ax -eq $bx) -and ($ay -eq $by)) {
                $bt = if ($beforeEl.PSObject.Properties.Name -contains 'transform') { [string]$beforeEl.transform } else { '(absent)' }
                $at = if ($afterEl.PSObject.Properties.Name -contains 'transform') { [string]$afterEl.transform } else { '(absent)' }
                if ($bt -ne $at) {
                    Add-NotRun 'O1.2b the delta in the dump equals the asked delta' `
                        "the element's x/y did not change; its transform did ($bt -> $at). The move is real (O1.2a passed) but this arm reads COORDINATES and cannot price a transform -- a NAMED gap, not a pass"
                } else {
                    Add-Assert -Name 'O1.2b the delta in the dump equals the asked delta' -Verdict 'FAIL' `
                        -Detail "neither the coordinates nor the transform moved, yet the element's JSON differs -- the change is somewhere this arm does not read"
                }
            } else {
                Add-Assert -Name 'O1.2b the delta in the dump equals the asked delta' -Verdict 'FAIL' `
                    -Detail ("moved ({0},{1}) against the asked ({2},{3})" -f ($ax - $bx), ($ay - $by), $handAsked.Dx, $handAsked.Dy)
            }
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
    Add-HashCompare 'O1.6 A != A-MUT (the mutation has a pixel witness)' $rowA $rowAM 'A' 'A-MUT' $false

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
    if ($move -eq [string]$wantK) {
        Add-Assert -Name "$o4Prefix.4 move == k" -Verdict 'PASS' -Detail "k=$wantK asked, move=$move reported (press=$press release=$release)" -Row $gestureRow
    } else {
        Add-Assert -Name "$o4Prefix.4 move == k" -Verdict 'FAIL' -Detail "k=$wantK asked, move=$move reported. A hardwired gesture cannot follow a varied k; a coalesced one reports fewer" -Row $gestureRow
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
    if ($null -eq $handAsked) {
        Add-NotRun "$o4Prefix.6 (release@ - press@)/scale == the asked delta" `
            'this harness did not choose the delta for this run, so there is nothing to compare the observed one to'
    } elseif ($null -eq $pressAt -or $null -eq $releaseAt -or $null -eq $rowScale) {
        Add-NotRun "$o4Prefix.6 (release@ - press@)/scale == the asked delta" `
            'the row did not carry a readable press@/release@/scale triple'
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
} elseif ($null -eq $refuseRow) {
    Add-Assert -Name 'O6.1 RESIZE REFUSED WxH through the REAL link (policy=EVENT)' -Verdict 'FAIL' `
        -Detail 'SB_SQUEEZE=1 was set and no `RESIZE REFUSED <W>x0 ... policy=EVENT` row was written -- either the squeeze did not reach the panel or the policy accepted a zero'
} else {
    Add-Assert -Name 'O6.1 RESIZE REFUSED WxH through the REAL link (policy=EVENT)' -Verdict 'PASS' `
        -Detail 'a zero height arrived through the window manager and the policy refused it, keeping the last good surface' -Row $refuseRow

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

# ⛔ THE HASH EQUALITY IS READ **TOGETHER WITH** THE ACCEPT ARM, AND ALONE IT IS
# VACUOUS: a surface nobody touched is trivially equal to itself. So this arm
# refuses unless the same run showed the policy is capable of accepting.
if ($squeezeAsked) {
    $sqHashes = @($rows | Where-Object { $_ -match 'hash=[0-9a-f]{64}' })
    if ($sqHashes.Count -lt 2) {
        Add-NotRun 'O6.4 the surface (and its hash) is unchanged across a refused squeeze' `
            "this run wrote $($sqHashes.Count) hash row(s); the equality needs one before the squeeze and one after"
    } elseif ($null -eq $acceptRow) {
        Add-NotRun 'O6.4 the surface (and its hash) is unchanged across a refused squeeze' `
            'REFUSED: no accept arm ran in this run. A hash that did not change across a resize nobody performed is trivially equal, and reading it alone would be a pass with no failure mode. Re-run with SB_SURFACE_PROBE=1000x600 set alongside SB_SQUEEZE=1'
    } else {
        $h0 = Get-SbField $sqHashes[0] 'hash'
        $h1 = Get-SbField $sqHashes[-1] 'hash'
        if ($h0 -eq $h1) {
            Add-Assert -Name 'O6.4 the surface (and its hash) is unchanged across a refused squeeze' -Verdict 'PASS' `
                -Detail "first=$h0 last=$h1, read together with the accept arm that proves the policy can change a surface" -Row $sqHashes[-1]
        } else {
            Add-Assert -Name 'O6.4 the surface (and its hash) is unchanged across a refused squeeze' -Verdict 'FAIL' `
                -Detail "first=$h0 last=$h1 -- something repainted differently across a refusal" -Row $sqHashes[-1]
        }
    }
}
