# Align Panel — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/panels/align.yaml`. Design doc: `transcripts/ALIGN.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other platforms covered
in Session L parity sweep.

---

## Known broken

_Last reviewed: 2026-04-20_

- **AL-072** [known-broken: ALIGN.md §Align To target — Artboard deferred] Align
  To Artboard falls back to selection bounds until the document model grows
  artboards. Tracked in memory `project_align_artboard_deferred`.

---

## Automation coverage

_Last synced: 2026-04-20_

**Python — `jas/algorithms/align_test.py`, `jas/panels/align_apply_test.py`,
`jas/panels/align_state_defaults_test.py`, `jas/algorithms/align_fixture_test.py`**
(~63 tests)
- Align primitives: union_bounds, axis_extent, anchor_position, AlignReference
  variants, Element.geometric_bounds.
- 6 Align operations, 6 Distribute operations, 2 Distribute Spacing operations
  (14 total) including key-object preservation and identity-omission.
- Apply pipeline end-to-end: reset_align_panel, apply_align_operation,
  try_designate_align_key_object (hit / toggle / outside), sync-on-selection.
- Panel state defaults loaded from workspace.json.
- Cross-language fixture runner (15 shared vectors).

**Swift — `JasSwift/Tests/Algorithms/AlignTests.swift`,
`JasSwift/Tests/Interpreter/AlignApplyTests.swift`,
`JasSwift/Tests/Panels/AlignPanelStateTests.swift`,
`JasSwift/Tests/Algorithms/AlignFixtureTests.swift`**
- Mirror of the Python algorithm tests (primitives + 14 ops).
- Apply pipeline end-to-end + canvas-click intercept.
- Panel state defaults + fixture runner.

**OCaml — `jas_ocaml/test/algorithms/align_test.ml`,
`jas_ocaml/test/algorithms/align_fixture_test.ml`,
`jas_ocaml/test/interpreter/align_apply_test.ml`,
`jas_ocaml/test/interpreter/align_panel_state_test.ml`**
- Mirror of the Python / Swift suites.

**Rust — `jas_dioxus/src/algorithms/align.rs` (#[cfg(test)]),
`jas_dioxus/src/workspace/app_state.rs` Align-panel tests,
`jas_dioxus/src/interpreter/renderer.rs` Align-effect arm tests**
- Reference implementation; inline #[test] coverage of primitives + ops + apply
  pipeline + fixture runner. Cross-lang harness (`scripts/cross_language_algorithms.py
  --algo align`) reports 45 / 45 passing as of 2026-04-20 (15 vectors × Rust vs
  Swift / OCaml / Python).

**Flask — no coverage.** Align panel is a native-apps-only feature for the
current phase; see memory `project_flask_tspan_deferred` for the parallel
reasoning behind deferring heavy-canvas features.

The manual suite below covers what auto-tests cannot reach: widget rendering,
radio / toggle visual state, canvas click intercept in practice, keyboard
navigation, appearance theming, dock / float, selection-change feedback.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default workspace with no document loaded.
3. Open the Align panel via Window → Align (or the default layout's docked
   location).
4. Appearance: **Dark** (`workspace/appearances/`).

Tests that need a specific canvas fixture state the delta in their `Setup:`
line. When a test calls for a **3-rect fixture** the default is: Rect tool →
draw three non-overlapping rectangles of roughly different sizes → Selection
tool → Ctrl/Cmd-A.

---

## Tier definitions

- **P0 — existential.** If this fails, the panel is broken. Crash, layout
  collapse, complete non-function. 5-minute smoke confidence.
- **P1 — core.** Control does its primary job (click / drag / enter / select
  / toggle).
- **P2 — edge & polish.** Bounds, keyboard-only paths, focus / tab order,
  appearance variants, mutual-exclusion display, icon states.

---

## Session table of contents

| Session | Topic                                 | Est.  | IDs        |
|---------|---------------------------------------|-------|------------|
| A       | Smoke & lifecycle                     | ~5m   | 001–009    |
| B       | Align Objects — 6 buttons             | ~10m  | 010–039    |
| C       | Distribute Objects — 6 buttons        | ~10m  | 040–069    |
| D       | Align To — 3 toggles                  | ~8m   | 070–089    |
| E       | Key Object designation (canvas click) | ~10m  | 090–119    |
| F       | Distribute Spacing — 2 buttons + pt   | ~10m  | 120–149    |
| G       | Enable / disable rules                | ~8m   | 150–179    |
| H       | Panel menu — Preview Bounds / Reset   | ~5m   | 180–199    |
| I       | Undo / redo                           | ~5m   | 200–219    |
| J       | Appearance theming                    | ~5m   | 220–239    |
| K       | Keyboard navigation                   | ~5m   | 240–259    |
| L       | Cross-app parity                      | ~15m  | 300–329    |

Full pass: ~100 min. Partial runs are useful — each session stands alone; A
gates the rest.

---

## Session A — Smoke & lifecycle (~5 min)

If any P0 here fails, stop and flag.

- [ ] **AL-001** [wired] Panel opens via Window menu.
      Do: Select Window → Align.
      Expect: Align panel appears in the dock or as a floating panel; no
              console error; no visual glitch.
      — last: —

- [ ] **AL-002** [wired] All panel controls render without layout collapse.
      Do: Visually scan the open Align panel.
      Expect: Three sections top-to-bottom — "Align Objects:" row with 6 icons,
              "Distribute Objects:" row with 6 icons, combined "Distribute
              Spacing:" + "Align To:" row with 2 spacing icons + pt input on
              the left and 3 toggles on the right. No overlapping controls,
              no truncated labels.
      — last: —

- [ ] **AL-003** [wired] Panel collapses and re-expands.
      Do: Click the panel header to collapse; click again to expand.
      Expect: Content hides / reveals; header stays visible; no crash.
      — last: —

- [ ] **AL-004** [wired] Panel closes via context menu.
      Do: Right-click header → Close Align.
      Expect: Panel disappears; Window → Align now toggles it back on.
      — last: —

- [ ] **AL-005** [wired] Panel floats out of the dock.
      Do: Drag the panel header out of the dock.
      Expect: Panel becomes a floating window at cursor; content still
              interactive; returns to dock on drag back.
      — last: —

- [ ] **AL-006** [wired] Defaults on empty state.
      Setup: No document, no selection.
      Do: Open the panel.
      Expect: Align To = Selection is checked (other two unchecked);
              Distribute Spacing pt input shows 0 and is disabled; all 14
              operation buttons are disabled.
      — last: —

---

## Session B — Align Objects (~10 min)

**P0**

- [ ] **AL-010** [wired] Align Left moves selection left edges to flush.
      Setup: 3-rect fixture (rectangles at varying x positions).
      Do: Click Align Left.
      Expect: All three rectangles snap so their left edges coincide with the
              leftmost rect; widths unchanged.
      — last: —

- [ ] **AL-011** [wired] Align Right moves right edges to flush.
      Setup: 3-rect fixture.
      Do: Click Align Right.
      Expect: All three rectangles snap so their right edges coincide with the
              rightmost rect; widths unchanged.
      — last: —

- [ ] **AL-012** [wired] Align Horizontal Center moves midpoints to the
  selection-bbox midline.
      Setup: 3-rect fixture.
      Do: Click Align Horizontal Center.
      Expect: All three rectangles share the same horizontal center; bbox
              widths unchanged; only x shifts.
      — last: —

**P1**

- [ ] **AL-013** [wired] Align Top moves top edges to flush.
      Setup: 3-rect fixture with varying y positions.
      Do: Click Align Top.
      Expect: All three top edges coincide with the topmost rect; heights
              unchanged.
      — last: —

- [ ] **AL-014** [wired] Align Vertical Center aligns midpoints vertically.
      Setup: 3-rect fixture.
      Do: Click Align Vertical Center.
      Expect: All three rectangles share the same vertical center; heights
              unchanged.
      — last: —

- [ ] **AL-015** [wired] Align Bottom moves bottom edges to flush.
      Setup: 3-rect fixture.
      Do: Click Align Bottom.
      Expect: All three bottom edges coincide with the bottommost rect;
              heights unchanged.
      — last: —

- [ ] **AL-016** [wired] Align buttons are one-shot (no persistent checked
  state).
      Setup: 3-rect fixture.
      Do: Click Align Left.
      Expect: Operation fires; the button returns to unchecked immediately —
              no filled / highlighted state sticks.
      — last: —

**P2**

- [ ] **AL-017** [wired] Already-aligned selection yields zero motion.
      Setup: Three rectangles whose left edges are already equal.
      Do: Click Align Left.
      Expect: Nothing moves; undo stack is unchanged or adds a no-op entry per
              ALIGN.md §Undo semantics.
      — last: —

- [ ] **AL-018** [wired] Align operation preserves rotation / scale in
  transform.
      Setup: Select two rectangles, rotate one via the Transform panel by
             30° then add both to the selection.
      Do: Click Align Left.
      Expect: The rotated rect's bounding box left edge aligns; its rotation
              angle is unchanged (only the translate slot shifts).
      — last: —

- [ ] **AL-019** [wired] Mixed element types align by bbox.
      Setup: Select one Rect, one Ellipse, one Path.
      Do: Click Align Horizontal Center.
      Expect: All three bbox centers coincide horizontally; each element's
              intrinsic geometry is unchanged.
      — last: —

---

## Session C — Distribute Objects (~10 min)

**P0**

- [ ] **AL-040** [wired] Distribute Left evenly spaces left edges.
      Setup: 3-rect fixture.
      Do: Click Distribute Left.
      Expect: The middle rect's left edge sits exactly at the midpoint of the
              leftmost and rightmost left edges; extremal rects do not move.
      — last: —

- [ ] **AL-041** [wired] Distribute Horizontal Center evenly spaces centers.
      Setup: 3-rect fixture.
      Do: Click Distribute Horizontal Center.
      Expect: Middle rect's horizontal center equidistant from the other two
              centers along the horizontal axis; extremals do not move.
      — last: —

- [ ] **AL-042** [wired] Distribute Top evenly spaces top edges.
      Setup: 3 rects at y = 0, 40, 120.
      Do: Click Distribute Top.
      Expect: Middle rect's top edge moves to y = 60 (midpoint); others
              unchanged.
      — last: —

**P1**

- [ ] **AL-043** [wired] Distribute Right evenly spaces right edges.
      Setup: 3-rect fixture.
      Do: Click Distribute Right.
      Expect: Middle rect's right edge at the midpoint of extremal right
              edges; extremals unchanged.
      — last: —

- [ ] **AL-044** [wired] Distribute Vertical Center evenly spaces vertical
  centers.
      Setup: 3-rect fixture vertically spread.
      Do: Click Distribute Vertical Center.
      Expect: Middle vertical center equidistant from the other two.
      — last: —

- [ ] **AL-045** [wired] Distribute Bottom evenly spaces bottom edges.
      Setup: 3-rect fixture vertically spread.
      Do: Click Distribute Bottom.
      Expect: Middle bottom edge at the midpoint of extremal bottoms.
      — last: —

**P2**

- [ ] **AL-046** [wired] Distribute with an unsorted selection order still
  works.
      Setup: Click-select rects in right-to-left order.
      Do: Click Distribute Left.
      Expect: Result matches AL-040 — operation sorts internally by position,
              not selection order.
      — last: —

- [ ] **AL-047** [wired] Distribute on already-evenly-spaced selection is a
  no-op.
      Setup: Three rects with equal left-edge spacing.
      Do: Click Distribute Left.
      Expect: No motion; no undo entry or a clean no-op entry.
      — last: —

- [ ] **AL-048** [wired] Distribute with 5+ elements remains monotonic.
      Setup: Five rects at random x.
      Do: Click Distribute Horizontal Center.
      Expect: Final centers equidistant — the interior three shift so the
              five centers form an arithmetic progression between extremals.
      — last: —

---

## Session D — Align To toggles (~8 min)

**P0**

- [ ] **AL-070** [wired] Align To Selection is the default.
      Setup: Fresh session.
      Do: Open the panel.
      Expect: Selection toggle is checked; Artboard and Key Object are not.
      — last: —

- [ ] **AL-071** [wired] Clicking Align To Selection selects the selection
  target.
      Setup: Artboard or Key Object currently active.
      Do: Click Align To Selection.
      Expect: Selection toggle becomes checked; other two uncheck; subsequent
              Align Left uses selection bounds.
      — last: —

- [ ] **AL-072** [wired] [known-broken: ALIGN.md §Align To target — Artboard
  deferred] Align To Artboard switches reference.
      Setup: 3-rect fixture; no artboard concept yet.
      Do: Click Align To Artboard, then Align Left.
      Expect (target): Operation uses the active artboard rect as reference.
      Expect (current): Artboard falls back to selection bounds; same result
              as Align To Selection.
      — last: —

- [ ] **AL-073** [wired] Clicking Align To Key Object enters key mode.
      Setup: 3-rect fixture, selection active.
      Do: Click Align To Key Object.
      Expect: Key Object toggle becomes checked; all operation buttons
              disable until a key is designated; see AL-090 for designation.
      — last: —

**P1**

- [ ] **AL-074** [wired] Align To toggles are mutually exclusive.
      Do: Rapidly click Selection → Key Object → Artboard.
      Expect: At every step exactly one toggle is checked.
      — last: —

- [ ] **AL-075** [wired] Align To persists per session.
      Setup: Set Align To Key Object + designate a key.
      Do: Float the panel and re-dock it.
      Expect: Key Object remains checked; designated key retained.
      — last: —

**P2**

- [ ] **AL-076** [wired] Align To icons render at 20px per yaml.
      Do: Inspect icon sizes (browser DevTools).
      Expect: Each toggle renders at 20×20 px; icon group aligned center
              within the right-half column.
      — last: —

---

## Session E — Key Object designation (~10 min)

**P0**

- [ ] **AL-090** [wired] Canvas click on a selected element designates it as
  key.
      Setup: 3-rect fixture; Align To Key Object active; no key yet.
      Do: On the canvas, click one of the selected rectangles.
      Expect: Panel's key-object indicator updates (icon tinted or badge on
              the rect per ALIGN.md §Align To target); all operation buttons
              re-enable.
      — last: —

- [ ] **AL-091** [wired] Align Left with key object pins the key.
      Setup: 3 rects at x = 10 / 30 / 60; key designated = middle rect.
      Do: Click Align Left.
      Expect: Middle rect does not move; other two align to x = 30 (the
              key's left edge).
      — last: —

- [ ] **AL-092** [wired] Clicking the current key clears it.
      Setup: AL-090 state — key designated.
      Do: Click the key rect on the canvas again.
      Expect: Key is cleared; all operation buttons disable; panel key
              indicator resets.
      — last: —

**P1**

- [ ] **AL-093** [wired] Clicking outside the selection clears the key.
      Setup: Key designated.
      Do: Click an empty area of the canvas (not on any selected element).
      Expect: Key is cleared; canvas selection remains unchanged (the intercept
              does not deselect).
      — last: —

- [ ] **AL-094** [wired] Clicking a non-selected element does not designate it.
      Setup: Three rectangles drawn; only two selected; Align To Key Object;
             no key.
      Do: Click the unselected third rectangle on the canvas.
      Expect: Intercept treats this as "outside selection" — key stays None;
              the click does not change the selection either (consumed, per
              ALIGN.md §Align To target).
      — last: —

- [ ] **AL-095** [wired] Deselecting the key clears the key (selection-change
  sync).
      Setup: Key designated on the middle of three selected rects.
      Do: Shift-click the key rect to remove it from the selection.
      Expect: Panel key indicator resets; operation buttons reflect new
              selection count.
      — last: —

- [ ] **AL-096** [wired] Changing Align To away from Key Object preserves the
  path but hides the indicator.
      Setup: Key designated.
      Do: Click Align To Selection.
      Expect: Selection mode becomes active; operation buttons use selection
              bounds. If the user clicks Align To Key Object again with the
              same selection, the key is still designated (per ALIGN.md
              §Panel state).
      — last: —

**P2**

- [ ] **AL-097** [wired] Intercept does not fire when Align To ≠ Key Object.
      Setup: 3-rect fixture; Align To Selection active.
      Do: Click a selected rect on the canvas.
      Expect: The click reaches the active tool (Selection Tool behavior —
              click-through to move / reselect); Align state is untouched.
      — last: —

- [ ] **AL-098** [wired] Key indicator updates when panel is floating.
      Setup: Panel floating, key mode, no key.
      Do: Designate a key via canvas click.
      Expect: Floating panel indicator updates in sync with the dock behavior.
      — last: —

---

## Session F — Distribute Spacing (~10 min)

**P0**

- [ ] **AL-120** [wired] Distribute Horizontal Spacing in average mode
  equalises gaps.
      Setup: Three rects at x = 0 / 20 / 90; no key object; Align To
             Selection.
      Do: Click Distribute Horizontal Spacing.
      Expect: Rects move to x = 0 / 45 / 90 — leftmost and rightmost hold;
              gaps between consecutive rects become equal.
      — last: —

- [ ] **AL-121** [wired] Distribute Vertical Spacing in average mode equalises
  gaps.
      Setup: Three rects at y = 0 / 20 / 90.
      Do: Click Distribute Vertical Spacing.
      Expect: Rects move to y = 0 / 45 / 90.
      — last: —

**P1**

- [ ] **AL-122** [wired] pt input accepts numeric entry.
      Setup: Align To Key Object + key designated.
      Do: Click the pt input, type 20, press Enter.
      Expect: Input shows 20; subsequent Distribute Horizontal Spacing applies
              a 20pt gap between consecutive bboxes (walking outward from the
              key).
      — last: —

- [ ] **AL-123** [wired] Explicit-gap Distribute Horizontal Spacing pins the
  key.
      Setup: 3 rects at x = 0 / 100 / 200; key = middle; pt = 20.
      Do: Click Distribute Horizontal Spacing.
      Expect: Middle rect does not move; left rect moves to x = 70 (= 100 −
              20 − 10); right rect moves to x = 130.
      — last: —

- [ ] **AL-124** [wired] Explicit-gap mode with no key returns no-op.
      Setup: Align To Selection; pt shown but disabled.
      Do: Attempt to use the pt input value to influence Distribute Spacing.
      Expect: Button enabled only when 3+ selected; clicking uses average
              mode, ignoring the pt value.
      — last: —

**P2**

- [ ] **AL-125** [wired] pt input clamps to [0, 1296].
      Setup: Align To Key Object + key designated.
      Do: Type 9999 into the pt input.
      Expect: Value clamps to 1296 on commit per yaml min/max.
      — last: —

- [ ] **AL-126** [wired] pt = 0 makes elements touch.
      Setup: Key designated; three rects.
      Do: Set pt to 0, click Distribute Horizontal Spacing.
      Expect: Non-key rects move so consecutive bboxes are flush (zero gap).
      — last: —

- [ ] **AL-127** [wired] pt input disables when not in key-object mode.
      Setup: Align To Selection or Artboard.
      Do: Look at the pt input.
      Expect: Input rendered dim / disabled; typing has no effect.
      — last: —

---

## Session G — Enable / disable rules (~8 min)

**P1**

- [ ] **AL-150** [wired] All 14 operation buttons disable with 0 selected.
      Setup: No selection.
      Do: Visually scan all operation buttons.
      Expect: Every Align / Distribute / Distribute Spacing button is dim /
              unclickable.
      — last: —

- [ ] **AL-151** [wired] Align buttons enable with 2 selected; Distribute
  buttons stay disabled.
      Setup: Select exactly 2 rectangles.
      Do: Inspect button states.
      Expect: Six Align buttons enabled; six Distribute and two Distribute
              Spacing buttons disabled (require ≥ 3).
      — last: —

- [ ] **AL-152** [wired] All 14 buttons enable with 3+ selected (selection
  mode).
      Setup: Select 3 rectangles; Align To Selection.
      Do: Inspect button states.
      Expect: All 14 operation buttons enabled.
      — last: —

- [ ] **AL-153** [wired] Key Object mode without a key disables every button.
      Setup: 3 rectangles selected; Align To Key Object; no key.
      Do: Inspect button states.
      Expect: All 14 buttons disabled; Align To toggles still clickable.
      — last: —

- [ ] **AL-154** [wired] Key Object mode with a key enables the buttons.
      Setup: AL-153 state → designate a key.
      Do: Inspect button states.
      Expect: All 14 operation buttons enabled.
      — last: —

**P2**

- [ ] **AL-155** [wired] Deselecting down to 2 while in key mode re-disables
  Distribute buttons.
      Setup: 3 rects, key-object mode, key designated.
      Do: Shift-click a non-key rect to deselect it.
      Expect: Distribute and Distribute Spacing disable; 6 Align buttons
              remain enabled; key is preserved (since its rect is still
              selected) per AL-095 semantics.
      — last: —

- [ ] **AL-156** [wired] Selection count updates propagate within one frame.
      Setup: Rapid-fire shift-click to add / remove elements.
      Do: Watch button states.
      Expect: No flicker, no stale disabled state — reactive.
      — last: —

---

## Session H — Panel menu (~5 min)

**P1**

- [ ] **AL-180** [wired] Panel menu shows three entries.
      Do: Right-click or click the panel context-menu affordance.
      Expect: Menu items — "Use Preview Bounds" (checkbox), "Reset Panel",
              "Close Align". Exactly two separators between them.
      — last: —

- [ ] **AL-181** [wired] Use Preview Bounds toggles panel state.
      Setup: Menu open.
      Do: Click Use Preview Bounds.
      Expect: Checkmark appears; menu closes. Re-opening the menu shows the
              toggle checked. Re-click toggles off.
      — last: —

- [ ] **AL-182** [wired] Use Preview Bounds affects a subsequent Align Right
  with stroked elements.
      Setup: Two rects, one with a 10pt stroke; Align To Selection.
      Do: With Use Preview Bounds off → Align Right; note positions. Undo;
           toggle Use Preview Bounds on → Align Right again.
      Expect: The stroked rect's x position differs between runs — with
              Preview Bounds on, the stroke's outer edge aligns; with it off,
              the geometric edge does.
      — last: —

**P2**

- [ ] **AL-183** [wired] Reset Panel restores defaults.
      Setup: Set Align To Key Object; designate a key; pt = 20; Use Preview
             Bounds on.
      Do: Menu → Reset Panel.
      Expect: Align To → Selection; key cleared; pt → 0; Use Preview Bounds →
              off.
      — last: —

- [ ] **AL-184** [wired] Close Align hides the panel.
      Do: Menu → Close Align.
      Expect: Same outcome as Session A panel-close test; Window → Align
              toggles it back on.
      — last: —

---

## Session I — Undo / redo (~5 min)

**P1**

- [ ] **AL-200** [wired] A single Align Left is one undo step.
      Setup: 3-rect fixture.
      Do: Align Left, then Ctrl/Cmd-Z.
      Expect: Rects return to their original x positions; one undo covers all
              three translations (ALIGN.md §Undo semantics — per-op not
              per-element).
      — last: —

- [ ] **AL-201** [wired] Redo reapplies the alignment.
      Setup: Continue from AL-200 undo.
      Do: Ctrl/Cmd-Shift-Z (or Ctrl-Y).
      Expect: Rects return to the aligned state.
      — last: —

**P2**

- [ ] **AL-202** [wired] Distribute is one undo step even with many elements.
      Setup: Five rects.
      Do: Distribute Horizontal Center, then Ctrl/Cmd-Z.
      Expect: Single undo reverses all interior translations.
      — last: —

- [ ] **AL-203** [wired] No-op Align emits a clean no-op entry or no entry.
      Setup: Already-aligned fixture.
      Do: Align Left, then Ctrl/Cmd-Z.
      Expect: No change, or a trivial no-op undo — not a partial revert.
      — last: —

---

## Session J — Appearance theming (~5 min)

**P2**

- [ ] **AL-220** [wired] Dark appearance — icons contrast, toggles readable.
      Setup: Appearance = Dark.
      Do: Open Align panel with varied states (some buttons disabled, Align
           To toggle checked).
      Expect: Disabled icons dim but recognisable; checked toggle has a
              clearly distinguishable fill; no unreadable icon-on-background
              combinations.
      — last: —

- [ ] **AL-221** [wired] Medium Gray appearance.
      Do: Switch appearance to Medium Gray.
      Expect: Same readability properties as Dark.
      — last: —

- [ ] **AL-222** [wired] Light Gray appearance.
      Do: Switch appearance to Light Gray.
      Expect: Icons invert / retint as needed; no black-on-black regressions.
      — last: —

---

## Session K — Keyboard navigation (~5 min)

**P2**

- [ ] **AL-240** [wired] Tab moves focus through operation buttons.
      Setup: Panel docked; focus on panel content.
      Do: Press Tab repeatedly.
      Expect: Focus cycles through the 6 Align → 6 Distribute → 2 Spacing →
              pt input → 3 Align To toggles in document order, with a visible
              focus ring per theme.
      — last: —

- [ ] **AL-241** [wired] Enter / Space on focused button fires the op.
      Setup: 3-rect fixture; focus on Align Left via Tab.
      Do: Press Enter (or Space).
      Expect: Rects align left as if clicked; focus stays on the button.
      — last: —

- [ ] **AL-242** [wired] pt input accepts arrow-key increments.
      Setup: Align To Key Object + key designated; focus in pt input.
      Do: Press Up arrow 3×.
      Expect: pt value increments by 1 each press (or by the yaml-configured
              step); clamping at max still applies.
      — last: —

---

## Cross-app parity — Session L (~15 min)

~8 load-bearing tests. Batch by app: one full pass per app.

- **AL-300** [wired] Align Left on the 3-rect fixture produces the same
  translations across apps.
      Do: 3-rect fixture at x = 10 / 30 / 60, click Align Left.
      Expect: Middle rect shifts by −20; right rect shifts by −50; first rect
              does not move (fixture row `align_left_selection` in
              `test_fixtures/algorithms/align.json`).
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **AL-301** [wired] Distribute Horizontal Center monotonicity.
      Do: 5 rects at random x, click Distribute Horizontal Center.
      Expect: Centers of middle three form an arithmetic progression; no
              apparent order reshuffle.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **AL-302** [wired] Key object pins under Align Left.
      Do: 3 rects; Align To Key Object; designate middle rect; Align Left.
      Expect: Middle rect does not move; left / right move to its left edge
              (Δ +20 and Δ −30 for the x = 10 / 30 / 60 fixture).
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **AL-303** [wired] Distribute Horizontal Spacing explicit gap applies
  exactly.
      Do: 3 rects at x = 0 / 100 / 200; Align To Key Object; key = middle;
          pt = 20; Distribute Horizontal Spacing.
      Expect: Left → x = 70 (Δ +70); right → x = 130 (Δ −70); middle pinned
              (fixture row `distribute_horizontal_spacing_explicit`).
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **AL-304** [wired] Canvas click intercept: hit designates, repeat clears.
      Do: Align To Key Object; click a selected rect (designate); click same
          rect again.
      Expect: Second click clears the key; intermediate states match across
              apps.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **AL-305** [wired] Selection-change sync drops a dangling key.
      Do: Designate a key; shift-click to remove it from the selection.
      Expect: Key resets to None in all apps.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **AL-306** [wired] Reset Panel restores the four state keys identically.
      Do: Set Align To Key Object + key + pt = 20 + Use Preview Bounds on;
          Reset Panel.
      Expect: All four state keys back to their defaults.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **AL-307** [wired] Use Preview Bounds changes stroke-inclusive alignment.
      Do: Two rects, one with a 10pt stroke; Align Right with Use Preview
          Bounds off, undo, then with it on.
      Expect: Difference in the stroked rect's final x is exactly half the
              stroke width in all apps.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

---

## Graveyard

_No retired tests yet._

---

## Enhancements

_No outstanding enhancement ideas. Append `ENH-NNN` entries here when manual
testing surfaces non-blocking follow-ups._
