# Stroke Panel — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/panels/stroke.yaml`. Design doc: `transcripts/STROKE.md`.
No companion dialogs — the surface is wholly contained in the panel.

Primary platform for manual runs: **Flask (jas_flask)** — most fully wired
panel today. Native apps run the YAML interpreter to render the panel and
have the apply / sync pipelines wired (Rust `apply_stroke_panel_to_selection`,
OCaml `subscribe_stroke_panel`); see Session N parity for per-app reach.

---

## Known broken

_Last reviewed: 2026-04-19_

- STR-051 — Stroke alignment Inside / Outside on closed paths approximates
  with center alignment in the canvas renderers; geometric path offset
  is pending. since 2026-04-19. STROKE.md §Stroke alignment.
- STR-202 — Variable-width stroke profile rendering (`taper_*`, `bulge`,
  `pinch`) lands the width-points array but the canvas does not yet draw a
  varying outline — uniform width is rendered. since 2026-04-19. STROKE.md
  §Stroke profile.

---

## Automation coverage

_Last synced: 2026-04-19_

**OCaml — `jas_ocaml/test/interpreter/effects_test.ml`** (~2 stroke-subscribe tests)
- `subscribe_stroke_panel` writes fire `apply_stroke_panel_to_selection`;
  non-stroke keys do not. Wiring level only — no widget rendering or full
  state-space coverage.

**Rust — `jas_dioxus/src/workspace/app_state.rs`** (no automated stroke tests)
- `apply_stroke_panel_to_selection` (line 698) — reads panel, builds Stroke
  struct, parses dash array (6 slots), arrowhead enum, profile → width-
  point conversion.
- `sync_stroke_panel_from_selection` (line 786) — selection → panel sync.
- Both pipelines exist; no auto-tests exercise them.

**Swift — `JasSwift/Sources/Panels/StrokePanel.swift`** (scaffolding ~20 lines)
- No dedicated stroke-panel tests. Model-level fill/stroke covered in
  `Tests/Tools/FillStrokeTests.swift` (color, not panel widgets).

**Python — `jas/`** (no dedicated stroke panel tests)

**Flask — `jas_flask/tests/test_renderer.py`** (no stroke-panel tests)
- Generic panel-renderer fixtures but no stroke-specific cases.

The manual suite below covers what auto-tests don't: actual widget
rendering, mutual-exclusion display (cap / join / align / arrow-align),
icon button states, dash-pattern input interactions (pair-1 non-null,
pairs 2–3 nullable, master-checkbox enable/disable), scale-link toggle,
profile flip + reset, arrowhead swap, miter-limit conditional disable,
identity-omission output, theming, selection-sync round-trip.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_flask` for sessions A–M; per-app for N).
2. Open a default workspace.
3. Open the Stroke panel via Window → Stroke (or the default layout's
   docked location).
4. Appearance: **Dark** (`workspace/appearances/`).

Tests that need a selection use this default fixture: Rectangle tool →
drag a 200×120 rect → fill `#ff6600`, stroke `#000000`, weight 1pt.

---

## Tier definitions

- **P0 — existential.** If this fails, the panel is broken. Crash, layout
  collapse, complete non-function. 5-minute smoke confidence.
- **P1 — core.** Control does its primary job (input / toggle / select).
- **P2 — edge & polish.** Bounds, keyboard-only paths, focus / tab order,
  appearance variants, mutual-exclusion display, icon states.

---

## Session table of contents

| Session | Topic                                | Est.  | IDs        |
|---------|--------------------------------------|-------|------------|
| A       | Smoke & lifecycle                    | ~5m   | 001–009    |
| B       | Weight & cap                         | ~6m   | 010–029    |
| C       | Join & miter limit                   | ~6m   | 030–049    |
| D       | Stroke alignment                     | ~5m   | 050–069    |
| E       | Dashed checkbox + presets            | ~6m   | 070–089    |
| F       | Dash / gap pattern                   | ~10m  | 090–119    |
| G       | Arrowheads — shapes + swap           | ~8m   | 120–149    |
| H       | Arrowhead scale + link               | ~6m   | 150–179    |
| I       | Arrow alignment                      | ~4m   | 180–199    |
| J       | Profile + flip + reset               | ~6m   | 200–219    |
| K       | Menu — cap / join / close            | ~4m   | 220–239    |
| L       | Selection sync + identity-omission   | ~6m   | 240–259    |
| M       | Appearance theming                   | ~5m   | 260–279    |
| N       | Cross-app parity                     | ~15m  | 300–329    |

Full pass: ~100 min. A gates the rest; otherwise sessions stand alone.

---

## Session A — Smoke & lifecycle (~5 min)

If any P0 here fails, stop and flag.

- [ ] **STR-001** [wired] Panel opens via Window menu.
      Do: Select Window → Stroke.
      Expect: Stroke panel appears in the dock or floating; no console error.
      — last: —

- [ ] **STR-002** [wired] All panel rows render without layout collapse.
      Do: Visually scan the open panel.
      Expect: Row 1: Weight + cap×3. Row 2: join×3 + miter limit. Row 3:
              align×3. Row 4: Dashed checkbox + 2 preset buttons. Rows
              5–7: 6 dash/gap inputs (pair 1 with values, pairs 2–3
              empty). Row 8: arrowhead start + end + swap. Row 9: scale
              start + end + link. Row 10: arrow-align×2. Row 11: profile
              + flip + reset. No truncated labels, no overlaps.
      — last: —

- [ ] **STR-003** [wired] Panel collapses and re-expands.
      Do: Click the panel header to collapse; click again to expand.
      Expect: Content hides / reveals; header stays visible; no crash.
      — last: —

- [ ] **STR-004** [wired] Panel closes via context menu / X button.
      Do: Right-click header → Close, or click the close affordance.
      Expect: Panel disappears; Window → Stroke reopens it.
      — last: —

- [ ] **STR-005** [wired] Panel floats out of the dock.
      Do: Drag the panel header out of the dock.
      Expect: Panel becomes a floating window; controls remain interactive;
              returns to dock on drag back.
      — last: —

---

## Session B — Weight & cap (~6 min)

**P0**

- [ ] **STR-010** [wired] Default weight is 1pt on a fresh workspace.
      Setup: No prior selection.
      Expect: `stk_weight` shows `1` with literal "pt" unit label.
      — last: —

- [ ] **STR-011** [wired] Default cap is Butt.
      Expect: `stk_cap_butt` rendered active; round / square inactive.
      — last: —

**P1**

- [ ] **STR-012** [wired] Editing weight commits on Enter.
      Setup: Selection with stroke.
      Do: Click `stk_weight`, type "4", press Enter.
      Expect: Stroke widens to 4pt; SVG attr `stroke-width="4"`.
      — last: —

- [ ] **STR-013** [wired] Decimal weights accepted.
      Do: Enter "0.5".
      Expect: Field accepts; stroke renders as a fine line.
      — last: —

- [ ] **STR-014** [wired] Click Round Cap activates round, deactivates butt.
      Do: Click `stk_cap_round`.
      Expect: Round cap icon highlighted; butt unhighlights; SVG
              `stroke-linecap="round"`; line endpoints become semicircular
              on canvas.
      — last: —

- [ ] **STR-015** [wired] Click Square Cap activates square.
      Do: Click `stk_cap_square`.
      Expect: Square cap active; SVG `stroke-linecap="square"`;
              endpoints extend by half the stroke width.
      — last: —

- [ ] **STR-016** [wired] Click active cap is a no-op.
      Setup: Round Cap active.
      Do: Click `stk_cap_round` again.
      Expect: Stays active; no flicker; no document write.
      — last: —

**P2**

- [ ] **STR-020** [wired] Weight upper bound 1000 enforced.
      Do: Enter "5000".
      Expect: Clamps to 1000 or rejects; no crash.
      — last: —

- [ ] **STR-021** [wired] Negative weight is rejected.
      Do: Enter "-3".
      Expect: Field rejects or clamps to 0; no crash.
      — last: —

- [ ] **STR-022** [wired] Cap mutual-exclusion shows in icon state.
      Setup: Cycle through butt → round → square.
      Expect: Exactly one icon active at all times; no overlapping
              highlights.
      — last: —

---

## Session C — Join & miter limit (~6 min)

- [ ] **STR-030** [wired] Default join is Miter.
      Expect: `stk_join_miter` active; round / bevel inactive.
      — last: —

- [ ] **STR-031** [wired] Default miter limit is 10.
      Expect: `stk_miter_limit` shows `10`.
      — last: —

- [ ] **STR-032** [wired] Click Round Join activates round.
      Do: Click `stk_join_round`.
      Expect: Round active; SVG `stroke-linejoin="round"`; corners on a
              polygon become circular arcs.
      — last: —

- [ ] **STR-033** [wired] Click Bevel Join activates bevel.
      Do: Click `stk_join_bevel`.
      Expect: Bevel active; corners become flat diagonals.
      — last: —

- [ ] **STR-034** [wired] Miter limit input disabled when join ≠ miter.
      Setup: Round Join active.
      Expect: `stk_miter_limit` rendered dimmed / non-interactive.
      — last: —

- [ ] **STR-035** [wired] Miter limit input re-enables when miter join restored.
      Setup: Round active, then click `stk_join_miter`.
      Expect: Miter limit field re-interactive; previous value preserved.
      — last: —

- [ ] **STR-036** [wired] Editing miter limit affects sharp corners.
      Setup: Polygon with sharp corners, miter join.
      Do: Set miter limit to 1.
      Expect: Sharp corners visibly bevel-clip (limit kicks in).
      — last: —

- [ ] **STR-037** [wired] Miter limit upper bound 500 enforced.
      Do: Enter "9999".
      Expect: Clamps to 500 or rejects.
      — last: —

- [ ] **STR-038** [wired] Miter limit min 1 enforced.
      Do: Enter "0.5".
      Expect: Clamps to 1 or rejects.
      — last: —

---

## Session D — Stroke alignment (~5 min)

- [ ] **STR-050** [wired] Default alignment is Center.
      Expect: `stk_align_stroke_center` active.
      — last: —

- [ ] **STR-051** [known-broken: canvas approximation] Inside alignment on a
      closed path renders fully inside.
      Setup: Closed rectangle, weight 8.
      Do: Click `stk_align_stroke_inside`.
      Expect: (Target) stroke is fully inside the path bounds. (Current)
              renders centered as a known limitation; document.
      — last: —

- [ ] **STR-052** [wired] Outside alignment on a closed path renders fully outside.
      Setup: Closed rectangle, weight 8.
      Do: Click `stk_align_stroke_outside`.
      Expect: (Target) stroke is fully outside the path bounds. Same
              limitation as STR-051 may apply.
      — last: —

- [ ] **STR-053** [wired] Inside / Outside on an open path behave as Center.
      Setup: An open polyline.
      Do: Click `stk_align_stroke_inside`.
      Expect: Stroke straddles the path (no inside/outside meaning on an
              open path).
      — last: —

- [ ] **STR-054** [wired] Mutual-exclusion across the three align icons.
      Setup: Cycle center → inside → outside → center.
      Expect: Exactly one active at all times.
      — last: —

---

## Session E — Dashed checkbox + presets (~6 min)

- [ ] **STR-070** [wired] Default Dashed is unchecked.
      Expect: `stk_dashed` unchecked; stroke renders as a solid line.
      — last: —

- [ ] **STR-071** [wired] All six dash/gap inputs render dimmed when Dashed off.
      Do: Inspect rows 5–7.
      Expect: All dash/gap inputs are non-interactive.
      — last: —

- [ ] **STR-072** [wired] Toggling Dashed on enables pair-1 inputs.
      Do: Check `stk_dashed`.
      Expect: `stk_dash_1` and `stk_gap_1` become interactive (showing 12 /
              12 defaults); pairs 2–3 also enabled but empty.
      — last: —

- [ ] **STR-073** [wired] Dashed preset Even Dash applies 12 / 12 in one click.
      Setup: Dashed unchecked.
      Do: Click `stk_preset_even_dash`.
      Expect: Dashed becomes checked; pair 1 = 12 / 12; pairs 2–3 cleared
              (null); canvas shows even dashes.
      — last: —

- [ ] **STR-074** [wired] Dashed preset Dash-Dot applies 12 / 6 / 0 / 6.
      Setup: Dashed unchecked.
      Do: Click `stk_preset_dash_dot`.
      Expect: Dashed becomes checked; values dash₁=12, gap₁=6, dash₂=0,
              gap₂=6; pair 3 cleared.
      — last: —

- [ ] **STR-075** [wired] Dot from dash=0 renders only with round / square caps.
      Setup: Dash-dot preset, Round Cap.
      Expect: The 0-length dashes render as visible dots at the round cap
              radius. Switch cap to Butt → dots disappear (zero-length
              with butt cap is invisible).
      — last: —

- [ ] **STR-076** [wired] Toggling Dashed off preserves the input values.
      Setup: Dashed on, custom values entered (e.g. 4 / 8).
      Do: Uncheck `stk_dashed`. Re-check.
      Expect: 4 / 8 (and any other entered values) still present in the
              fields after re-check.
      — last: —

---

## Session F — Dash / gap pattern (~10 min)

- [ ] **STR-090** [wired] Pair 1 default values are 12 / 12 (non-null).
      Setup: Dashed off, never edited.
      Do: Check Dashed.
      Expect: `stk_dash_1` = 12, `stk_gap_1` = 12.
      — last: —

- [ ] **STR-091** [wired] Pair 1 cannot be cleared to blank — falls back to default.
      Setup: Dashed on, pair 1 = 4 / 4.
      Do: Clear `stk_dash_1` to empty; press Enter.
      Expect: Field reverts to its default (12) or to the previous valid
              value; SVG `stroke-dasharray` always carries pair 1.
      — last: —

- [ ] **STR-092** [wired] Pair 2 / 3 default to null (unused).
      Expect: `stk_dash_2`, `stk_gap_2`, `stk_dash_3`, `stk_gap_3` all
              empty.
      — last: —

- [ ] **STR-093** [wired] Pair 2 and / or 3 enter the SVG dasharray when set.
      Setup: Dashed on. Enter dash₂=4, gap₂=2.
      Do: Inspect SVG.
      Expect: `stroke-dasharray="12 12 4 2"` (4-element array).
      — last: —

- [ ] **STR-094** [wired] Clearing a pair-2 / 3 value drops it from the dasharray.
      Setup: Pair 1 = 12/12, pair 2 = 4/2.
      Do: Clear `stk_dash_2`.
      Expect: `stroke-dasharray="12 12"` again (pair-2 entries removed).
      — last: —

- [ ] **STR-095** [wired] Pair 3 with pair 2 unset is allowed and renders.
      Do: Pair 1 = 12/12, pair 2 cleared, pair 3 = 6/6.
      Expect: `stroke-dasharray="12 12 6 6"` (pair-2 absence collapsed in
              left-to-right flatten).
      — last: —

- [ ] **STR-096** [wired] Negative dash / gap values are rejected.
      Do: Enter "-1" into any dash field.
      Expect: Field rejects or clamps to 0; no crash.
      — last: —

- [ ] **STR-097** [wired] Very large dash values render as expected.
      Do: dash₁ = 500.
      Expect: Stroke renders one giant dash followed by a 12pt gap.
      — last: —

---

## Session G — Arrowheads — shapes + swap (~8 min)

- [ ] **STR-120** [wired] Default start arrowhead is None.
      Expect: `stk_start_arrowhead` shows "None".
      — last: —

- [ ] **STR-121** [wired] Default end arrowhead is None.
      Expect: `stk_end_arrowhead` shows "None".
      — last: —

- [ ] **STR-122** [wired] Start arrowhead select offers 15 shapes.
      Do: Open `stk_start_arrowhead`.
      Expect: Options: None, Simple Arrow, Open Arrow, Closed Arrow,
              Stealth Arrow, Barbed Arrow, Half Arrow Upper, Half Arrow
              Lower, Circle, Open Circle, Square, Open Square, Diamond,
              Open Diamond, Slash. (15 total.)
      — last: —

- [ ] **STR-123** [wired] End arrowhead select offers same 15 shapes.
      Do: Open `stk_end_arrowhead`.
      Expect: Identical option list.
      — last: —

- [ ] **STR-124** [wired] Selecting Simple Arrow at end renders an arrow.
      Setup: An open polyline.
      Do: End → Simple Arrow.
      Expect: Arrowhead appears at the line's end-point.
      — last: —

- [ ] **STR-125** [wired] Renderer mirrors the same shape on start vs end.
      Setup: Polyline with start = Simple Arrow, end = Simple Arrow.
      Expect: Both arrows point outward from their respective ends.
      — last: —

- [ ] **STR-126** [wired] Swap exchanges shapes AND scale.
      Setup: Start = Closed Arrow at 75%; End = Diamond at 200%.
      Do: Click `stk_swap_arrowheads`.
      Expect: Start = Diamond at 200%; End = Closed Arrow at 75%.
      — last: —

- [ ] **STR-127** [wired] Swap does NOT toggle the link state.
      Setup: Link off; swap.
      Expect: Link still off after swap.
      — last: —

- [ ] **STR-128** [wired] Setting end to None removes the end arrowhead.
      Setup: End = Simple Arrow.
      Do: End → None.
      Expect: Arrowhead disappears from canvas; SVG attribute absent
              (identity-omission).
      — last: —

---

## Session H — Arrowhead scale + link (~6 min)

- [ ] **STR-150** [wired] Default scales are 100 / 100 (%).
      Expect: `stk_start_arrowhead_scale` and `stk_end_arrowhead_scale`
              both show `100`.
      — last: —

- [ ] **STR-151** [wired] Combo box presets list 50 / 75 / 100 / 150 / 200 / 300 / 400.
      Do: Open the start scale combo.
      Expect: Seven preset percentages visible.
      — last: —

- [ ] **STR-152** [wired] Custom scale entry accepted (free entry).
      Do: Type "275" into start scale.
      Expect: Field accepts; arrowhead scales to 275% of stroke weight.
      — last: —

- [ ] **STR-153** [wired] Scale min 1 enforced.
      Do: Enter "0".
      Expect: Clamps to 1 or rejects.
      — last: —

- [ ] **STR-154** [wired] Default link state is off (unlinked).
      Expect: `stk_link_arrowhead_scale` icon inactive.
      — last: —

- [ ] **STR-155** [wired] With link off, editing start scale doesn't change end.
      Setup: Both at 100, link off.
      Do: Start scale → 200.
      Expect: End scale still 100.
      — last: —

- [ ] **STR-156** [wired] Toggling link on syncs start to end on next edit.
      Setup: Start 100, end 200, link off.
      Do: Toggle link on; edit start to 50.
      Expect: End also becomes 50 (or remains 200 — document the actual
              link semantics; STROKE.md says "editing either updates
              both").
      — last: —

- [ ] **STR-157** [wired] Toggling link off detaches the inputs.
      Setup: Link on, both at 50.
      Do: Toggle link off; edit start to 100.
      Expect: End stays at 50.
      — last: —

---

## Session I — Arrow alignment (~4 min)

- [ ] **STR-180** [wired] Default arrow alignment is Tip at End.
      Expect: `stk_arrow_tip_at_end` icon active.
      — last: —

- [ ] **STR-181** [wired] Tip at End places the tip on the path endpoint.
      Setup: Polyline with end arrowhead.
      Do: Confirm `stk_arrow_tip_at_end` active.
      Expect: Arrowhead's tip sits exactly at the path's endpoint
              coordinate; the body extends back along the path.
      — last: —

- [ ] **STR-182** [wired] Center at End places the arrow center on the endpoint.
      Setup: Polyline with end arrowhead.
      Do: Click `stk_arrow_center_at_end`.
      Expect: Arrow's center sits at the endpoint; the tip extends past
              the endpoint outward.
      — last: —

- [ ] **STR-183** [wired] Mutual-exclusion across the two icons.
      Do: Cycle the pair.
      Expect: Exactly one active at all times.
      — last: —

---

## Session J — Profile + flip + reset (~6 min)

- [ ] **STR-200** [wired] Default profile is Uniform.
      Expect: `stk_profile` shows "Uniform"; canvas stroke is constant
              width.
      — last: —

- [ ] **STR-201** [wired] Profile select offers 6 options.
      Do: Open `stk_profile`.
      Expect: Uniform, Taper Both, Taper Start, Taper End, Bulge, Pinch.
      — last: —

- [ ] **STR-202** [known-broken: canvas not yet rendering varying width]
      Selecting Taper Start renders a tapered stroke.
      Setup: Polyline.
      Do: Profile → Taper Start.
      Expect: (Target) stroke begins narrow and widens to full width along
              the path. (Current) renders uniform width as documented in
              the known-broken summary.
      — last: —

- [ ] **STR-203** [wired] Flip toggles the `profile_flipped` state.
      Setup: Profile = Taper Start.
      Do: Click `stk_flip_profile`.
      Expect: Internal `profile_flipped` becomes true; visually
              equivalent to Taper End once rendering lands (STR-202).
      — last: —

- [ ] **STR-204** [wired] Flip on Uniform profile is a visual no-op.
      Setup: Profile = Uniform.
      Do: Click `stk_flip_profile`.
      Expect: Flag toggles in state; canvas appearance unchanged
              (uniform is symmetric).
      — last: —

- [ ] **STR-205** [wired] Reset returns profile to Uniform and clears flip.
      Setup: Profile = Bulge, flip on.
      Do: Click `stk_reset_profile`.
      Expect: `stk_profile` = Uniform; flip flag cleared.
      — last: —

---

## Session K — Menu — cap / join / close (~4 min)

- [ ] **STR-220** [wired] Menu shows cap × 3, separator, join × 3, separator, close.
      Do: Open the panel menu.
      Expect: Butt Cap, Round Cap, Square Cap, ─, Miter Join, Round Join,
              Bevel Join, ─, Close Stroke.
      — last: —

- [ ] **STR-221** [wired] Active cap shows checkmark in menu.
      Setup: Cap = Round.
      Do: Open menu.
      Expect: Round Cap has a checkmark; Butt and Square do not.
      — last: —

- [ ] **STR-222** [wired] Active join shows checkmark in menu.
      Setup: Join = Bevel.
      Do: Open menu.
      Expect: Bevel Join checkmarked.
      — last: —

- [ ] **STR-223** [wired] Selecting a menu cap matches clicking the icon.
      Setup: Cap = Butt.
      Do: Menu → Square Cap.
      Expect: `stk_cap_square` icon becomes active; SVG attr updates.
      — last: —

- [ ] **STR-224** [wired] Close Stroke closes the panel.
      Do: Menu → Close Stroke.
      Expect: Panel disappears; reopen via Window → Stroke.
      — last: —

---

## Session L — Selection sync + identity-omission (~6 min)

- [ ] **STR-240** [wired] Selecting an element with stroke syncs panel.
      Setup: Select a stroked rectangle (weight 4, round cap, dashed
             12/12).
      Expect: Panel shows weight 4, Round Cap active, Dashed checked,
              dash 1 = 12 / 12.
      — last: —

- [ ] **STR-241** [wired] Selection change updates panel state.
      Setup: Two strokes with different attrs. Select A → panel reflects
             A.
      Do: Select B.
      Expect: Panel updates to reflect B's attrs.
      — last: —

- [ ] **STR-242** [wired] Editing the panel commits to the selection.
      Setup: Selection with weight 1.
      Do: Set weight to 6.
      Expect: SVG `stroke-width="6"` on the selected element.
      — last: —

- [ ] **STR-243** [wired] Setting weight to default 1 omits the attribute.
      Setup: Element with `stroke-width="6"`.
      Do: Set weight to 1.
      Expect: Element no longer carries `stroke-width` (identity-omission).
      — last: —

- [ ] **STR-244** [wired] Setting cap to Butt omits `stroke-linecap`.
      Setup: Element with `stroke-linecap="round"`.
      Do: Click `stk_cap_butt`.
      Expect: Attribute removed.
      — last: —

- [ ] **STR-245** [wired] Setting join back to Miter (default) omits
      `stroke-linejoin`.
      Setup: Element with `stroke-linejoin="bevel"`.
      Do: Click `stk_join_miter`.
      Expect: Attribute removed.
      — last: —

- [ ] **STR-246** [wired] Miter limit at default 10 is omitted.
      Setup: Element has `stroke-miterlimit="20"`.
      Do: Set miter limit to 10.
      Expect: Attribute removed.
      — last: —

- [ ] **STR-247** [wired] Arrowhead None at both ends omits the attrs.
      Setup: Element with start + end arrowheads.
      Do: Set both selects to None.
      Expect: Both arrowhead attrs absent from output.
      — last: —

---

## Session M — Appearance theming (~5 min)

- [ ] **STR-260** [wired] Dark appearance: every icon legible.
      Setup: Dark active.
      Expect: All cap / join / align / arrow / profile icons render
              against panel bg with adequate contrast.
      — last: —

- [ ] **STR-261** [wired] Medium Gray appearance mirrors Dark.
      Do: Switch appearance → Medium Gray.
      Expect: Panel re-skins; icons readable; selected icon active state
              still distinguishable.
      — last: —

- [ ] **STR-262** [wired] Light Gray appearance mirrors Dark.
      Do: Switch to Light Gray.
      Expect: Same as above.
      — last: —

- [ ] **STR-263** [wired] Active mutual-exclusion icons distinguishable in every appearance.
      Do: In each appearance, cycle cap and join.
      Expect: Active icon visually distinct via theme tokens (background,
              outline, or glow).
      — last: —

- [ ] **STR-264** [wired] Disabled inputs (e.g. miter limit when join≠miter) styled consistently.
      Setup: Round Join active.
      Do: Inspect `stk_miter_limit` across appearances.
      Expect: Disabled style is consistent (dimmed text, non-interactive
              cursor).
      — last: —

---

## Session N — Cross-app parity (~15 min)

~5–8 load-bearing `[wired]` tests where cross-language drift produces
user-visible bugs. Batch by app: run a full column at a time.

- **STR-300** [wired] Editing weight commits via `apply_stroke_panel_to_selection`.
      Setup: Selection with weight 1. Do: Enter "5".
      Expect: SVG `stroke-width="5"` on element.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **STR-301** [wired] Cap change to Round writes `stroke-linecap="round"`.
      Do: Click `stk_cap_round`.
      Expect: SVG attr present on element; default Butt → omitted on
              return.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **STR-302** [wired] Dashed preset Dash-Dot writes the 4-element array.
      Setup: Dashed off.
      Do: Click `stk_preset_dash_dot`.
      Expect: SVG `stroke-dasharray="12 6 0 6"`.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **STR-303** [wired] Setting miter limit on a Round Join is gracefully ignored.
      Setup: Round Join active.
      Do: Try to interact with `stk_miter_limit`.
      Expect: Field disabled in every app; no spurious attr writes.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **STR-304** [wired] Swap arrowheads exchanges shape + scale.
      Setup: Start = Closed Arrow at 75%, End = Diamond at 200%.
      Do: Click `stk_swap_arrowheads`.
      Expect: Start = Diamond at 200%, End = Closed Arrow at 75%; same
              behavior in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **STR-305** [wired] Selection sync round-trip.
      Setup: Select element A with cap=round, weight=4. Verify panel
             shows Round + 4. Select B with butt + 1.
      Expect: Panel updates to reflect B in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **STR-306** [wired] Identity-omission on weight default.
      Setup: Element with `stroke-width="5"`.
      Do: Set weight to 1.
      Expect: Element no longer carries `stroke-width` in any app's
              serialized output.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

---

## Graveyard

_No retired or won't-fix tests yet._

---

## Enhancements

_No non-blocking follow-ups raised yet. Manual testing surfaces ideas here
with `ENH-NNN` prefix and italicized trailer noting the test + date._
