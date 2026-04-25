# Magic Wand Tool — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/magic_wand.yaml`. Design doc:
`transcripts/MAGIC_WAND_TOOL.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other
platforms covered in Session H parity sweep.

---

## Known broken

_Last reviewed: 2026-04-25_

- **OCaml toolbar dblclick → panel summon** — the OCaml
  `Toolbar.create` signature lacks a `workspace_layout` reference,
  so double-clicking the Magic Wand icon does not open the panel
  on OCaml. Workaround: open via the Window menu (Window → Magic
  Wand). Rust / Swift / Python all wire the dblclick path. See
  `project_magic_wand_spec.md`.
- **Flask** — tool not implemented. The wand requires document
  hit-testing + a selection model, neither of which the Flask app
  has.

---

## Automation coverage

_Last synced: 2026-04-25_

**Predicate (`algorithms/magic_wand`)** — 9 unit tests on
`magic_wand_match` per language: all-disabled returns false,
identical-default matches, fill within / outside tolerance,
None-fill semantics, stroke-weight pt delta, opacity %-pt delta,
blend-mode exact match, AND-fails-on-one-criterion. Files:
`jas_dioxus/src/algorithms/magic_wand.rs` (#[cfg(test)]),
`JasSwift/Tests/Algorithms/MagicWandTests.swift`,
`jas_ocaml/test/algorithms/magic_wand_test.ml`,
`jas/algorithms/magic_wand_test.py`.

**Effect (`doc.magic_wand.apply`)** — 4 integration tests per
language on a red/red/blue 3-rect fixture: replace selects all
matching reds, add extends an existing selection, subtract
removes only matches from an existing selection, the eligibility
filter skips locked + hidden elements. Files:
`jas_dioxus/src/interpreter/effects.rs` (#[cfg(test)]),
`JasSwift/Tests/Tools/YamlToolEffectsTests.swift`,
`jas_ocaml/test/tools/yaml_tool_effects_test.ml`,
`jas/tools/yaml_tool_effects_test.py`.

**Panel + menu plumbing** — `PanelKind.MagicWand` is exercised by
the existing `panel_kind_all_count` / `contains_all_variants` /
cross-language `menu_structure` fixture tests, all of which
include the new variant.

---

## Preconditions (assumed for every session)

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document.
3. Appearance: **Dark**.
4. Magic Wand tool active (long-press the arrow slot → Magic
   Wand, or press `Y`).
5. Default state: all four "obvious" criteria on (Fill Color,
   Stroke Color, Stroke Weight, Opacity), Blending Mode off.
   Tolerances 32 / 32 / 5.0 / 5 / —.

---

## Tier definitions

- **P0 — existential.** Tool doesn't activate, click on an
  element doesn't change the selection, or the panel doesn't
  open.
- **P1 — core.** Replace / add / subtract gestures behave per
  spec; the five criteria each gate matches; the eligibility
  filter excludes locked / hidden / containers.
- **P2 — edge & polish.** Color / weight edge cases (None-on-one-
  side, gradient, pattern), Reset menu item, dblclick-summon, the
  no-criteria-enabled fallback to Selection-tool semantics, panel
  state persistence.

---

## Session table of contents

| Session | Topic                                     | Est.  | IDs        |
|---------|-------------------------------------------|-------|------------|
| A       | Smoke & lifecycle                         | ~4m   | 001–009    |
| B       | Replace gesture (plain click)             | ~6m   | 010–029    |
| C       | Add / subtract gestures                   | ~5m   | 030–049    |
| D       | Per-criterion match semantics             | ~10m  | 050–089    |
| E       | Color edge cases (None / gradient / etc.) | ~5m   | 090–109    |
| F       | Eligibility filter                        | ~5m   | 110–129    |
| G       | Panel + Reset                             | ~6m   | 130–159    |
| H       | Cross-app parity                          | ~10m  | 200–229    |

Full pass: ~51 min.

---

## Session A — Smoke & lifecycle (~4 min)

- [ ] **MW-001** [wired] **P0.** Magic Wand activates from the
      toolbox.
      Do: Long-press the arrow slot, choose Magic Wand from the
      popup. (Or press `Y`.)
      Expect: Magic Wand tool active; the arrow slot's icon swaps
      to the wand glyph (handle line + sparkle + small accent
      star).
      — last: —

- [ ] **MW-002** [wired] Tool icon is visibly distinct from the
      Selection / Partial / Interior arrows.
      Do: Compare the four arrow-slot alternates in the long-press
      menu.
      Expect: Selection = solid black arrow, Partial = white arrow,
      Interior = white arrow + plus badge, Magic Wand = wand with
      a sparkle at the tip — no arrow shape.
      — last: —

- [ ] **MW-003** [wired] Switching away from Magic Wand to another
      tool leaves selection intact.
      Do: Magic Wand, plain-click an element to populate a
      selection, then switch to Selection (V).
      Expect: Selection unchanged after the tool switch.
      — last: —

- [ ] **MW-004** [wired] No drag, no marquee.
      Do: Magic Wand, press-and-drag across empty space.
      Expect: No marquee overlay drawn; on release, selection
      clears (matches "click on empty canvas" — see MW-016).
      — last: —

---

## Session B — Replace gesture (plain click) (~6 min)

- [ ] **MW-010** [wired] **P0.** Plain click on an element
      replaces the selection with the wand result.
      Do: Place three same-fill rects (red / red / blue). Plain-
      click one red rect.
      Expect: Both red rects are selected; the blue rect is not.
      — last: —

- [ ] **MW-011** [wired] **P0.** The seed itself is always part of
      the result, even when its own values fail the criterion.
      Do: Set Fill Color tolerance to 0. Place an unfilled rect
      and a red rect. Plain-click the unfilled rect.
      Expect: The unfilled rect is selected (it's the seed). The
      red rect is not.
      — last: —

- [ ] **MW-012** [wired] **P1.** Plain click replaces an existing
      selection.
      Do: Marquee-select the blue rect with the Selection tool.
      Switch to Magic Wand and plain-click a red rect.
      Expect: Selection is now {red rects}; the previously-
      selected blue is no longer selected.
      — last: —

- [ ] **MW-013** [wired] Plain click resolves to the innermost
      element when clicking inside a Group.
      Do: Group two rects. Plain-click one of them through the
      group.
      Expect: The clicked leaf rect is the seed; the wand walks
      the document, not the group.
      — last: —

- [ ] **MW-014** [wired] Plain click on a Layer container
      resolves to the innermost child under the cursor.
      Do: Click on a leaf inside the active Layer.
      Expect: Same as MW-013 — the leaf is the seed, not the
      Layer.
      — last: —

- [ ] **MW-015** [wired] Clicking the seed twice keeps the
      selection stable (idempotent).
      Do: Plain-click a red rect, then plain-click the same rect
      again.
      Expect: Both reds remain selected; no change between the
      two clicks.
      — last: —

- [ ] **MW-016** [wired] **P1.** Plain click on empty canvas
      clears the selection.
      Do: With reds selected, click on empty canvas.
      Expect: Selection empty.
      — last: —

---

## Session C — Add / subtract gestures (~5 min)

- [ ] **MW-030** [wired] **P0.** Shift+click unions the wand
      result with the existing selection.
      Do: Place red / red / blue / blue. Plain-click a red, then
      shift-click a blue.
      Expect: All four selected.
      — last: —

- [ ] **MW-031** [wired] **P1.** Shift+click leaves untouched
      elements selected.
      Do: Place red / red / blue / green. Plain-click a red.
      Shift-click the blue.
      Expect: Both reds + the blue are selected; the green is
      not. Reds were not deselected by the shift+click.
      — last: —

- [ ] **MW-032** [wired] **P0.** Alt+click subtracts the wand
      result from the existing selection.
      Do: Place red / red / blue / blue. Marquee-select all four
      with Selection. Switch to Magic Wand and alt-click a red.
      Expect: Both blues remain selected; both reds are
      deselected.
      — last: —

- [ ] **MW-033** [wired] Alt+click on an element not currently in
      the selection still subtracts matching elements that are.
      Do: Marquee-select all four (red / red / blue / blue).
      Alt-click a red that wasn't part of the marquee (e.g. add a
      fifth red, alt-click *that* one).
      Expect: Both originals reds are deselected; the alt-clicked
      red is also not in the selection. Blues remain.
      — last: —

- [ ] **MW-034** [wired] Shift+click on empty canvas leaves the
      selection unchanged.
      Do: Selection contains both reds. Shift-click empty canvas.
      Expect: Selection still contains both reds (no clear-on-
      empty under Shift).
      — last: —

---

## Session D — Per-criterion match semantics (~10 min)

- [ ] **MW-050** [wired] **P1.** Fill Color within tolerance
      matches.
      Do: Defaults. Place two rects with fills `#ff0000` and
      `#f00a0a` (Δ ≈ 22 in 0–255). Plain-click the first.
      Expect: Both selected.
      — last: —

- [ ] **MW-051** [wired] **P1.** Fill Color outside tolerance
      misses.
      Do: Set Fill Tolerance = 10. Place fills `#ff0000` and
      `#c80000` (Δ = 55). Plain-click the first.
      Expect: Only the first is selected.
      — last: —

- [ ] **MW-052** [wired] Fill Color tolerance 0 requires exact
      RGB match.
      Do: Set Fill Tolerance = 0. Place fills `#ff0000` and
      `#fe0000`. Plain-click the first.
      Expect: Only the first selected (Δ = 1, but tolerance 0).
      — last: —

- [ ] **MW-053** [wired] Disabling Fill Color drops the criterion
      from the AND.
      Do: Uncheck Fill Color. Place a red rect and a blue rect
      with the same stroke / opacity / weight. Plain-click red.
      Expect: Both selected (stroke / weight / opacity match,
      fill is now ignored).
      — last: —

- [ ] **MW-054** [wired] Stroke Color matches identically to
      Fill Color, on the stroke side.
      Do: Defaults; uncheck Fill Color so it doesn't gate.
      Place rects with the same fill but stroke colors `#000000`
      vs `#0a0a0a` vs `#404040`. Plain-click the first.
      Expect: First two selected (Δ ≈ 17 within 32); third missed
      (Δ = 64).
      — last: —

- [ ] **MW-055** [wired] **P1.** Stroke Weight within pt
      tolerance matches.
      Do: Uncheck Fill / Stroke / Opacity so only Stroke Weight
      gates. Default tolerance 5.0 pt. Place strokes 2 pt and 4 pt.
      Plain-click the 2 pt.
      Expect: Both selected (Δ = 2 ≤ 5).
      — last: —

- [ ] **MW-056** [wired] Stroke Weight outside pt tolerance
      misses.
      Do: Set Stroke Weight Tolerance = 1.0 pt. Strokes 2 pt and
      4 pt. Plain-click the 2 pt.
      Expect: Only the first selected (Δ = 2 > 1).
      — last: —

- [ ] **MW-057** [wired] **P1.** Opacity within %-pt tolerance
      matches.
      Do: Only Opacity enabled. Tolerance = 5. Opacity values 1.0
      and 0.97. Plain-click the first.
      Expect: Both selected (|Δ|·100 = 3 ≤ 5).
      — last: —

- [ ] **MW-058** [wired] Opacity outside %-pt tolerance misses.
      Do: Only Opacity enabled. Tolerance = 5. Values 1.0 and 0.80.
      Plain-click the first.
      Expect: Only the first selected (|Δ|·100 = 20 > 5).
      — last: —

- [ ] **MW-059** [wired] **P1.** Blending Mode is exact-match.
      Do: Only Blending Mode enabled. Place rects with blend modes
      Normal, Normal, Multiply. Plain-click the first.
      Expect: First two selected; Multiply rect missed.
      — last: —

- [ ] **MW-060** [wired] **P1.** AND across criteria — one
      failing criterion misses.
      Do: Defaults (all four obvious criteria on). Place rect A
      with red fill + 2 pt stroke; rect B with red fill + 5 pt
      stroke. Set Stroke Weight Tolerance = 1.0. Plain-click A.
      Expect: Only A selected — fill matches, stroke weight Δ = 3
      > 1 fails the AND.
      — last: —

- [ ] **MW-061** [wired] All-disabled fallback: plain click acts
      like Selection-tool plain click.
      Do: Uncheck all five criterion checkboxes. Plain-click a
      rect.
      Expect: Selection = {clicked rect} only — same as Selection
      tool. Other matching rects are not pulled in.
      — last: —

---

## Session E — Color edge cases (None / gradient / etc.) (~5 min)

- [ ] **MW-090** [wired] **P2.** None + None fill matches under
      Fill Color regardless of tolerance.
      Do: Only Fill Color enabled. Tolerance = 0. Two rects with
      `fill = none`. Plain-click one.
      Expect: Both selected.
      — last: —

- [ ] **MW-091** [wired] None + Solid (or vice versa) under Fill
      Color does NOT match.
      Do: Only Fill Color enabled. One rect `fill = none`, one
      with red fill. Plain-click the unfilled one.
      Expect: Only the seed selected (the red rect fails the
      None-vs-Solid edge case).
      — last: —

- [ ] **MW-092** [pending] **P2.** Gradient + anything never
      matches under Fill Color.
      Do: One rect with a linear gradient fill, one with a solid
      red fill. Plain-click the gradient.
      Expect: Only the gradient selected. (Phase 2 will define
      gradient similarity; Phase 1 says never match.)
      — last: —

- [ ] **MW-093** [wired] None + None stroke matches under Stroke
      Color, weight, etc.
      Do: Defaults. Two rects with `stroke = none`, both red
      fill. Plain-click one.
      Expect: Both selected — stroke criteria don't fail when
      both are None.
      — last: —

- [ ] **MW-094** [wired] None vs Some stroke under Stroke Weight
      misses.
      Do: Only Stroke Weight enabled. One rect with no stroke,
      one with a 2 pt stroke. Plain-click the unstroked.
      Expect: Only the seed selected.
      — last: —

---

## Session F — Eligibility filter (~5 min)

- [ ] **MW-110** [wired] **P1.** Locked elements are excluded
      from candidates.
      Do: Place red rects A, B, C. Lock B. Plain-click A.
      Expect: A and C selected; B is not.
      — last: —

- [ ] **MW-111** [wired] **P1.** Hidden (`visibility = invisible`)
      elements are excluded.
      Do: Place red rects A, B, C. Hide B. Plain-click A.
      Expect: A and C selected; B is not.
      — last: —

- [ ] **MW-112** [wired] Outline-mode elements are still
      candidates (color match uses model fill).
      Do: Place red rects A, B. Set B to Outline visibility (not
      Invisible). Plain-click A.
      Expect: Both selected — Outline doesn't affect candidacy,
      and the underlying fill still matches.
      — last: —

- [ ] **MW-113** [wired] Group / Layer containers are not
      candidates themselves.
      Do: Group two red rects A and B. Plain-click a red rect C
      outside the group.
      Expect: A, B, and C all selected (the wand recurses into
      the group's leaves). The Group itself is not in the
      selection.
      — last: —

- [ ] **MW-114** [wired] Click on a Group resolves to the
      innermost leaf, not the group.
      Do: (Same fixture as MW-113.) Click on rect A through the
      group.
      Expect: Same as MW-113 — A is the seed; the wand walks the
      document; A, B, C selected.
      — last: —

---

## Session G — Panel + Reset (~6 min)

- [ ] **MW-130** [wired] **P0.** Double-click the Magic Wand icon
      opens the Magic Wand Panel.
      Do: Double-click the wand icon in the toolbar.
      Expect: Magic Wand Panel becomes visible (docked or
      floating per workspace layout).
      — last: —

- [ ] **MW-131** [wired] Window menu has a Magic Wand toggle.
      Do: Window → Magic Wand.
      Expect: Toggles the panel's visibility.
      — last: —

- [ ] **MW-132** [wired] Panel layout matches spec.
      Do: Open the panel.
      Expect: Five rows — Fill Color (checkbox + tolerance),
      Stroke Color (checkbox + tolerance), Stroke Weight
      (checkbox + tolerance pt), spacer, Opacity (checkbox +
      tolerance %), Blending Mode (checkbox only). The spacer
      separates the appearance group from the compositing group.
      — last: —

- [ ] **MW-133** [wired] Edits in the panel write to
      `state.magic_wand_*`.
      Do: Toggle Blending Mode on. Set Fill Tolerance = 64. Inspect
      state.
      Expect: `state.magic_wand_blending_mode == true`,
      `state.magic_wand_fill_tolerance == 64`.
      — last: —

- [ ] **MW-134** [wired] Panel state persists across tool changes.
      Do: Edit several panel values. Switch to Selection. Switch
      back to Magic Wand. Reopen the panel.
      Expect: Edited values still present.
      — last: —

- [ ] **MW-135** [wired] **P2.** Reset menu item restores spec
      defaults.
      Do: Edit several values. Open the panel's hamburger menu →
      Reset Magic Wand.
      Expect: Fill / Stroke / Stroke Weight / Opacity all on
      (true), Blending Mode off, tolerances 32 / 32 / 5.0 / 5,
      and `state.magic_wand_*` written to those defaults.
      — last: —

- [ ] **MW-136** [wired] Closing the panel does not reset state.
      Do: Edit values, close the panel, reopen via Window → Magic
      Wand.
      Expect: Edited values still present.
      — last: —

---

## Session H — Cross-app parity (~10 min)

Re-run a core subset (MW-001, MW-010, MW-012, MW-016, MW-030,
MW-032, MW-050, MW-060, MW-061, MW-091, MW-110, MW-130, MW-135)
on each of:

| Platform | Notes                                                    |
|----------|----------------------------------------------------------|
| Rust     | Reference. Full coverage above.                          |
| Swift    | All sessions in scope.                                   |
| OCaml    | All sessions in scope; MW-130 (dblclick→panel) currently fails — Window menu summon (MW-131) works. |
| Python   | All sessions in scope.                                   |
| Flask    | Tool not implemented; skip entire suite.                 |

- [ ] **MW-200 .. 229** — per-platform parity results, one entry
      per (platform × core-subset test). Mark [wired] when
      confirmed.
      — last: —

---

## Coverage matrix (tier × session)

|              | A | B | C | D | E | F | G | H |
|--------------|---|---|---|---|---|---|---|---|
| P0           | 1 | 2 | 2 | — | — | — | 1 | — |
| P1           | — | 3 | 1 | 6 | — | 2 | — | — |
| P2           | — | — | — | — | 1 | — | 1 | — |

---

## Observed bugs (append only)

_None yet._
