# Boolean Panel — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/panels/boolean.yaml`, `workspace/dialogs/boolean_options.yaml`.
Design doc: `transcripts/BOOLEAN.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other platforms
covered in Session M parity sweep.

---

## Known broken

_Last reviewed: 2026-04-20_

- **BO-500** [deferred: BOOLEAN.md §Terminology — OUTLINE] The bottom
  row's rightmost button slot is intentionally empty; OUTLINE ships once
  the DCEL / planar-graph primitive lands. Tracked in memory
  `project_boolean_deferrals`.
- **BO-501** [deferred: BOOLEAN.md §Terminology — Trap] The hamburger
  menu does not include a "Trap…" entry. Trap requires a physical
  printing model (spot colors, separations, press pipeline) not yet in
  the app.
- **BO-502** [known-broken: jas (python) Alt+click UI] The Python
  yaml_renderer does not yet inject `event.alt` into click condition
  expressions. Alt+click compound variants only fire via direct
  Controller calls, not real button clicks, in the Python app. Tracked
  in `project_boolean_panel`.
- **BO-503** [known-broken: JasSwift canvas render] Canvas rendering of
  `.live` compound shapes is still the Phase 1 stub — draws each operand
  directly rather than the evaluated polygon set. Visual output matches
  the source artwork, not the boolean result. Fixed in jas_dioxus;
  OCaml and Python have no canvas render of `.live` at all.

---

## Automation coverage

_Last synced: 2026-04-20_

**Python — `jas/panels/boolean_apply_test.py` (33 tests), `jas/geometry/live_test.py` (9 tests)**
- Compound shape lifecycle: Make / Release / Expand; sibling
  precondition; <2 selection noop; selection points to the new compound.
- Nine destructive ops: per-op output count on overlapping / disjoint
  fixtures; unknown-op noop.
- Compound-creating variants: one per op + unknown-op noop.
- BooleanOptions threading: `collapse_collinear_points` drops collinear
  midpoints / preserves triangle corners; `divide_remove_unpainted`
  drops unfilled fragments; `remove_redundant_points=False` preserves
  vertex count.
- `apply_repeat_boolean_operation` routes destructive vs `_compound`
  suffix; None / empty-string noop.
- `element_to_polygon_set`, `apply_operation`, `evaluate` round-trips.

**Swift — `JasSwift/Tests/Document/CompoundShapeControllerTests.swift`
(30 tests), `JasSwift/Tests/Interpreter/AlignApplyTests.swift`
(platform-effects registry)**
- Mirror of the Python suite: compound lifecycle, nine destructive ops,
  four compound-creating variants, BooleanOptions collapse / options
  threading, Repeat dispatch.
- Platform-effects registry covers all 9 destructive ops + 4 compound
  variants + Make / Release / Expand + Repeat + Reset.

**OCaml — `jas_ocaml/test/panels/boolean_apply_test.ml` (25 Alcotest
cases across 4 suites)**
- Compound shape lifecycle + nine destructive ops + four compound-
  creating variants + BooleanOptions threading + Repeat dispatch.
- `jas_ocaml/test/geometry/live_test.ml` covers evaluate / bounds /
  expand / release primitives.

**Rust — `jas_dioxus/src/document/controller.rs` (inline
#[cfg(test)], ~40 cases), `jas_dioxus/src/geometry/live.rs` (12 cases),
`jas_dioxus/src/workspace/app_state.rs` (Boolean panel state + Repeat
dispatch)**
- Reference implementation. Full coverage of the nine destructive ops,
  four compound-creating variants, Make / Release / Expand, Repeat,
  BooleanOptions threading, `fills_merge_equal` predicate,
  `collapse_collinear_points` algorithm.

**Flask — `jas_flask/tests/test_renderer.py` (39 cases).** Panel
renders with 9 operation buttons + Expand; Boolean Options dialog
loads with correct defaults; every boolean-category action is
registered. Flask has no canvas subsystem so destructive-op /
compound-shape behavior is not exercised (per spec).

The manual suite below covers what auto-tests cannot reach: widget
rendering, icon states, canvas visual feedback on compound-shape
evaluate, Alt/Option+click modifier routing, dialog interaction,
keyboard navigation, appearance theming, dock / float, selection-
change feedback, and undo granularity.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default workspace with no document loaded.
3. Open the Boolean panel via Window → Boolean (or the default
   layout's docked location — paired with Align in group 1).
4. Appearance: **Dark** (`workspace/appearances/`).

Fixtures referenced by tests:

- **Two-overlap fixture**: Rect tool → draw one 100×100 rect at
  (0,0), then a second 100×100 rect at (50,0). Selection tool →
  Ctrl/Cmd-A.
- **Three-overlap fixture**: three 100×100 rects at (0,0), (50,0),
  (100,0). All three selected.
- **Disjoint fixture**: two 50×50 rects at (0,0) and (200,0). Both
  selected.
- **Nested fixture**: outer 200×200 rect at (0,0); inner 100×100
  rect at (50,50). Both selected.
- **Painted fixture**: two-overlap fixture, front rect red
  (`#ff0000`), back rect blue (`#0000ff`).
- **Matching-paint fixture**: two-overlap fixture, both rects red
  (`#ff0000`).
- **Mixed-type fixture**: one Rect, one Ellipse, one Polygon, one
  Path. All overlap around a common center. All selected.

---

## Tier definitions

- **P0 — existential.** If this fails, the panel is broken. Crash,
  layout collapse, complete non-function. 5-minute smoke confidence.
- **P1 — core.** Operation does its primary job (nine destructive
  ops, four compound variants, Make/Release/Expand, Repeat).
- **P2 — edge & polish.** Boolean Options threading, keyboard-only
  paths, focus / tab order, appearance variants, icon states,
  modifier routing.

---

## Session table of contents

| Session | Topic                                                  | Est.  | IDs        |
|---------|--------------------------------------------------------|-------|------------|
| A       | Smoke & lifecycle                                      | ~5m   | 001–009    |
| B       | Shape Modes row — UNION / SUBTRACT_FRONT / ...         | ~10m  | 010–039    |
| C       | Pathfinders row — DIVIDE / TRIM / MERGE / CROP / SB    | ~12m  | 040–079    |
| D       | Paint inheritance rules                                | ~10m  | 080–109    |
| E       | Alt/Option+click → compound shape                      | ~10m  | 110–139    |
| F       | Compound shape lifecycle (Make/Release/Expand)         | ~10m  | 140–169    |
| G       | Boolean Options dialog                                 | ~10m  | 170–199    |
| H       | Repeat Boolean Operation                               | ~8m   | 200–219    |
| I       | Reset Panel                                            | ~3m   | 220–229    |
| J       | Enable / disable rules                                 | ~8m   | 230–259    |
| K       | Undo / redo                                            | ~5m   | 260–279    |
| L       | Appearance theming + keyboard nav                      | ~8m   | 280–299    |
| M       | Cross-app parity                                       | ~20m  | 400–429    |

Full pass: ~120 min. Partial runs are useful — each session stands
alone; A gates the rest.

---

## Session A — Smoke & lifecycle (~5 min)

If any P0 here fails, stop and flag.

- [ ] **BO-001** [wired] Panel opens via Window menu.
      Do: Select Window → Boolean.
      Expect: Boolean panel appears in the dock or as a floating
              panel; no console error; no visual glitch.
      — last: —

- [ ] **BO-002** [wired] All panel controls render without layout
  collapse.
      Do: Visually scan the open Boolean panel.
      Expect: Three rows top-to-bottom — "Shape Modes:" label row;
              4 Shape-Mode icons + Expand button row; 5 Pathfinder
              icons + 1 reserved empty slot. No overlapping controls,
              no truncated icons. Reserved slot is visually empty
              but occupies the grid cell.
      — last: —

- [ ] **BO-003** [wired] Panel collapses and re-expands.
      Do: Click the panel header to collapse; click again to expand.
      Expect: Content hides / reveals; header stays visible; no
              crash.
      — last: —

- [ ] **BO-004** [wired] Panel closes via context menu.
      Do: Right-click header → Close Boolean.
      Expect: Panel disappears; Window → Boolean now toggles it back
              on.
      — last: —

- [ ] **BO-005** [wired] Panel floats out of the dock.
      Do: Drag the panel header out of the dock.
      Expect: Panel becomes a floating window at cursor; content
              still interactive; returns to dock on drag back.
      — last: —

- [ ] **BO-006** [wired] Defaults on empty state.
      Setup: No document, no selection.
      Do: Open the panel.
      Expect: All 9 operation buttons disabled; Expand disabled;
              hamburger menu's Repeat / Release / Expand Compound
              Shape entries disabled; Make Compound Shape disabled;
              Boolean Options / Reset / Close always enabled.
      — last: —

- [ ] **BO-007** [wired] Panel appears in Default workspace paired
  with Align.
      Setup: Reset to Default workspace layout.
      Do: Inspect dock group ordering.
      Expect: Group 1 (second from top) contains [Align, Boolean].
              Other groups match the 5-group default (Color+Swatches,
              Align+Boolean, Character+Paragraph, Stroke+Properties,
              Artboards+Layers).
      — last: —

---

## Session B — Shape Modes (~10 min)

**P0**

- [ ] **BO-010** [wired] UNION on two overlapping rects produces one
  merged polygon.
      Setup: Two-overlap fixture.
      Do: Click UNION.
      Expect: Selection collapses to a single Polygon element tracing
              the outer boundary of the two rects' union. The two
              original rects are removed. New polygon is selected.
      — last: —

- [ ] **BO-011** [wired] SUBTRACT_FRONT removes the frontmost from
  back survivors.
      Setup: Two-overlap fixture (front rect at (50,0), back at
             (0,0)).
      Do: Click SUBTRACT_FRONT.
      Expect: Frontmost rect disappears. Backmost becomes an
              L-shaped polygon (its right half removed). Only the
              survivor is selected.
      — last: —

- [ ] **BO-012** [wired] INTERSECTION produces the overlap region.
      Setup: Two-overlap fixture.
      Do: Click INTERSECTION.
      Expect: One polygon remains — the 50×100 rectangle of overlap.
              Both original rects removed. New polygon is selected.
      — last: —

- [ ] **BO-013** [wired] EXCLUDE produces symmetric difference.
      Setup: Two-overlap fixture.
      Do: Click EXCLUDE.
      Expect: Two polygons remain — the left-only and right-only
              regions (overlap removed). Both original rects are
              removed. Both new polygons are selected.
      — last: —

**P1**

- [ ] **BO-014** [wired] UNION on disjoint operands keeps both.
      Setup: Disjoint fixture.
      Do: Click UNION.
      Expect: Output has two separate polygons matching the originals
              (a multi-ring polygon in algorithms that support it; or
              two Polygon elements if not).
      — last: —

- [ ] **BO-015** [wired] INTERSECTION on disjoint operands produces
  nothing.
      Setup: Disjoint fixture.
      Do: Click INTERSECTION.
      Expect: Layer children count drops by 2 with zero replacements
              — intersection is empty. Selection becomes empty.
      — last: —

- [ ] **BO-016** [wired] UNION on nested operands equals the outer
  rect.
      Setup: Nested fixture.
      Do: Click UNION.
      Expect: One polygon whose bbox matches the outer rect.
      — last: —

- [ ] **BO-017** [wired] INTERSECTION on nested operands equals the
  inner rect.
      Setup: Nested fixture.
      Do: Click INTERSECTION.
      Expect: One polygon whose bbox matches the inner rect.
      — last: —

**P2**

- [ ] **BO-018** [wired] Shape Mode buttons are one-shot (no sticky
  pressed state).
      Setup: Two-overlap fixture.
      Do: Click UNION.
      Expect: Button returns to unpressed state immediately;
              operation fires once.
      — last: —

- [ ] **BO-019** [wired] Mixed-element-type UNION.
      Setup: Mixed-type fixture (Rect + Ellipse + Polygon + Path).
      Do: Click UNION.
      Expect: One polygon element tracing the union of all four
              flattened boundaries; paint carries the frontmost
              (Path) operand's fill/stroke.
      — last: —

- [ ] **BO-020** [wired] Edge-touching operands without overlap.
      Setup: Two 100×100 rects at (0,0) and (100,0) sharing a single
             vertical edge.
      Do: Click UNION.
      Expect: One 200×100 polygon; no self-intersecting seam visible
              in the output geometry.
      — last: —

---

## Session C — Pathfinders (~12 min)

**P0**

- [ ] **BO-040** [wired] DIVIDE on two-overlap produces three
  fragments.
      Setup: Two-overlap fixture.
      Do: Click DIVIDE.
      Expect: Three polygon elements: back-only region, overlap
              region, front-only region. All three selected.
      — last: —

- [ ] **BO-041** [wired] TRIM on two-overlap keeps the front and
  trims the back.
      Setup: Two-overlap fixture.
      Do: Click TRIM.
      Expect: Two polygons — back's L-shaped trimmed region +
              frontmost unchanged.
      — last: —

- [ ] **BO-042** [wired] MERGE on matching-fill selection reduces to
  one union.
      Setup: Matching-paint fixture (both rects `#ff0000`).
      Do: Click MERGE.
      Expect: One red polygon matching the union boundary.
      — last: —

- [ ] **BO-043** [wired] CROP frontmost as mask.
      Setup: Two-overlap fixture.
      Do: Click CROP.
      Expect: One polygon — the back operand clipped to the front
              rect's interior (the overlap region, keeping back's
              paint).
      — last: —

- [ ] **BO-044** [wired] SUBTRACT_BACK removes backmost from front
  survivors.
      Setup: Two-overlap fixture.
      Do: Click SUBTRACT_BACK.
      Expect: Backmost disappears; frontmost becomes an L-shape (its
              left half removed where the back rect used to overlap).
              Only survivor selected.
      — last: —

**P1**

- [ ] **BO-045** [wired] DIVIDE on disjoint operands keeps both.
      Setup: Disjoint fixture.
      Do: Click DIVIDE.
      Expect: Two fragments, one per original rect; no spurious
              third fragment.
      — last: —

- [ ] **BO-046** [wired] DIVIDE on three-overlap partitions the
  union into distinct fragments.
      Setup: Three-overlap fixture.
      Do: Click DIVIDE.
      Expect: Five fragments — left-only, mid-left overlap, center
              triple-overlap, mid-right overlap, right-only. Each
              inherits the paint of the frontmost operand that
              covered its area.
      — last: —

- [ ] **BO-047** [wired] TRIM with fully-covered back drops the back.
      Setup: Outer 200×200 back rect fully covered by a 250×250 front
             rect.
      Do: Click TRIM.
      Expect: One polygon remains — the frontmost (back's trimmed
              region is empty and therefore dropped).
      — last: —

- [ ] **BO-048** [wired] MERGE with mismatched fills keeps them
  separate.
      Setup: Painted fixture (front red, back blue).
      Do: Click MERGE.
      Expect: Two polygons — back's L-shaped trimmed region (blue) +
              front (red). No merge occurs.
      — last: —

- [ ] **BO-049** [wired] MERGE with None fills never merges (strict
  predicate).
      Setup: Two-overlap fixture with no fill on either rect.
      Do: Click MERGE.
      Expect: Two polygons remain — TRIM output kept separate because
              None / None is not a match.
      — last: —

**P2**

- [ ] **BO-050** [wired] MERGE predicate: named swatches resolve to
  color before comparison.
      Setup: Two overlapping rects; both filled with a named swatch
             "Red" whose color is `#ff0000`.
      Do: Click MERGE.
      Expect: One merged polygon (swatches resolve to hex; equal hex
              → merges).
      — last: —

- [ ] **BO-051** [wired] MERGE predicate: gradient fills never match.
      Setup: Two overlapping rects; both filled with the same linear
             gradient.
      Do: Click MERGE.
      Expect: Two polygons — gradients never match the predicate
              even against themselves (BOOLEAN.md §MERGE predicate).
      — last: —

- [ ] **BO-052** [wired] MERGE predicate: near-matching hex is still
  distinct.
      Setup: Two overlapping rects, one `#ff0000` and one `#ff0001`.
      Do: Click MERGE.
      Expect: Two polygons — near-matches are strict.
      — last: —

- [ ] **BO-053** [wired] CROP discards survivor content outside the
  mask.
      Setup: Three-overlap fixture.
      Do: Click CROP.
      Expect: Two polygons — each non-front operand clipped to the
              frontmost (right-most) rect's interior.
      — last: —

---

## Session D — Paint inheritance (~10 min)

**P1**

- [ ] **BO-080** [wired] UNION carries the frontmost operand's fill.
      Setup: Painted fixture (front red, back blue).
      Do: Click UNION.
      Expect: One polygon with fill `#ff0000` (frontmost = red).
      — last: —

- [ ] **BO-081** [wired] INTERSECTION carries the frontmost operand's
  paint.
      Setup: Painted fixture.
      Do: Click INTERSECTION.
      Expect: One red polygon in the overlap region.
      — last: —

- [ ] **BO-082** [wired] EXCLUDE carries the frontmost operand's
  paint on every output.
      Setup: Painted fixture.
      Do: Click EXCLUDE.
      Expect: Two polygons, both filled red (frontmost paint).
      — last: —

- [ ] **BO-083** [wired] SUBTRACT_FRONT: each survivor keeps its own
  paint.
      Setup: Three-overlap fixture with back=blue, middle=green,
             front=red.
      Do: Click SUBTRACT_FRONT.
      Expect: Two L-shaped polygons; back polygon is blue, middle
              polygon is green. Red (cutter) is consumed.
      — last: —

- [ ] **BO-084** [wired] CROP: each survivor keeps its own paint.
      Setup: Three-overlap fixture (back=blue, middle=green,
             front=red).
      Do: Click CROP.
      Expect: Two polygons — back clipped to front's interior (blue),
              middle clipped to front's interior (green). Front
              consumed.
      — last: —

- [ ] **BO-085** [wired] DIVIDE: each fragment inherits the paint of
  the frontmost covering operand.
      Setup: Three-overlap fixture (back=blue, middle=green,
             front=red).
      Do: Click DIVIDE.
      Expect: Five fragments with paint mapping:
              left-only → blue, mid-left → green, center → red,
              mid-right → red, right-only → red.
      — last: —

**P2**

- [ ] **BO-086** [wired] Stroke inheritance on UNION.
      Setup: Two-overlap fixture; back rect stroke 5pt black; front
             rect stroke 2pt red.
      Do: Click UNION.
      Expect: Resulting polygon has the frontmost's stroke (2pt red).
      — last: —

- [ ] **BO-087** [wired] MERGE uses the frontmost contributor's
  stroke on the merged output.
      Setup: Three rects at x=0/40/80, all filled `#ff0000`. Back has
             no stroke; middle has 3pt black; front has 6pt white.
      Do: Click MERGE.
      Expect: One merged red polygon with the 6pt white stroke
              (frontmost in the merged cluster wins).
      — last: —

- [ ] **BO-088** [wired] Opacity inheritance on UNION.
      Setup: Two-overlap fixture; back rect opacity 0.3; front opacity
             0.8.
      Do: Click UNION.
      Expect: Result polygon opacity 0.8 (frontmost).
      — last: —

- [ ] **BO-089** [wired] Compound shape at creation inherits the
  frontmost's paint.
      Setup: Painted fixture.
      Do: Alt/Option+click UNION.
      Expect: New compound shape has fill red (frontmost); operands
              retain their own paints within the compound tree.
      — last: —

---

## Session E — Alt+click compound variants (~10 min)

**P0**

- [ ] **BO-110** [wired] Alt+click UNION creates a live UNION compound
  shape.
      Setup: Two-overlap fixture.
      Do: Hold Alt/Option, click UNION.
      Expect: A single CompoundShape element replaces the two rects.
              Canvas shows the union geometry (evaluated). Operands
              remain inside the compound. Selection is the new
              compound.
      — last: —

- [ ] **BO-111** [wired] Alt+click INTERSECTION creates a live
  INTERSECTION compound shape.
      Setup: Two-overlap fixture.
      Do: Alt+click INTERSECTION.
      Expect: One CompoundShape rendering the overlap region only.
      — last: —

- [ ] **BO-112** [wired] Alt+click SUBTRACT_FRONT creates a live
  SUBTRACT_FRONT compound shape.
      Setup: Two-overlap fixture.
      Do: Alt+click SUBTRACT_FRONT.
      Expect: One CompoundShape rendering the back minus the front.
      — last: —

- [ ] **BO-113** [wired] Alt+click EXCLUDE creates a live EXCLUDE
  compound shape.
      Setup: Two-overlap fixture.
      Do: Alt+click EXCLUDE.
      Expect: One CompoundShape rendering the symmetric difference.
      — last: —

**P1**

- [ ] **BO-114** [wired] Compound shape re-evaluates when an operand
  is edited.
      Setup: Compound from BO-110.
      Do: Enter isolation mode (double-click compound); select the
          back rect; drag it 100pt to the right; exit isolation.
      Expect: Canvas updates to show the new union geometry. No stale
              pixels; re-render is automatic.
      — last: —

- [ ] **BO-115** [wired] Plain (non-Alt) click on Shape Mode buttons
  stays destructive.
      Setup: Two-overlap fixture.
      Do: Click UNION without modifier.
      Expect: Destructive UNION fires (BO-010 outcome), not a compound
              shape.
      — last: —

- [ ] **BO-116** [wired] DIVIDE / TRIM / MERGE / CROP / SUBTRACT_BACK
  do not have compound variants.
      Setup: Two-overlap fixture.
      Do: Alt+click DIVIDE.
      Expect: Destructive DIVIDE fires (no compound created). Same
              for TRIM / MERGE / CROP / SUBTRACT_BACK.
      — last: —

**P2**

- [ ] **BO-117** [wired] Alt+click updates `last_boolean_op` with the
  `_compound` suffix.
      Setup: Fresh document.
      Do: Alt+click INTERSECTION.
      Expect: Subsequent Repeat Boolean Operation creates an
              INTERSECTION compound (not a destructive one).
      — last: —

- [ ] **BO-118** [wired] Alt+click enable rule matches destructive
  click.
      Setup: Select 1 element.
      Do: Alt+click UNION.
      Expect: Button disabled; no-op (selection_count < 2 gate).
      — last: —

---

## Session F — Compound shape lifecycle (~10 min)

**P0**

- [ ] **BO-140** [wired] Make Compound Shape (menu) wraps selection
  as UNION compound.
      Setup: Two-overlap fixture.
      Do: Panel menu → Make Compound Shape.
      Expect: Same outcome as Alt+click UNION — one CompoundShape
              element replaces the selection. Operation = UNION.
      — last: —

- [ ] **BO-141** [wired] Release Compound Shape restores operands.
      Setup: Compound from BO-140.
      Do: Menu → Release Compound Shape.
      Expect: The compound dissolves into its original operands
              (both rects), each with its own paint. Released
              operands become the new selection.
      — last: —

- [ ] **BO-142** [wired] Expand Compound Shape flattens to polygons.
      Setup: Compound from BO-140.
      Do: Menu → Expand Compound Shape (or Expand button).
      Expect: One static Polygon replaces the compound, matching the
              evaluated union geometry. Polygon carries the compound's
              own paint (not per-operand).
      — last: —

**P1**

- [ ] **BO-143** [wired] Expand button on the panel is equivalent to
  the menu entry.
      Setup: Compound selected.
      Do: Click the Expand button (top-right of the Shape Modes row).
      Expect: Same outcome as BO-142.
      — last: —

- [ ] **BO-144** [wired] Release on an unrelated selection is a
  no-op.
      Setup: Two-overlap fixture selected (no compound shape).
      Do: Menu → Release Compound Shape.
      Expect: Menu item is disabled; clicking has no effect.
      — last: —

- [ ] **BO-145** [wired] Expand on mixed selection affects only the
  compound shapes.
      Setup: Two separate compound shapes plus one plain rect, all
             selected.
      Do: Click Expand.
      Expect: Two compounds become polygons; the plain rect is
              untouched. New selection is the two expanded polygons.
      — last: —

- [ ] **BO-146** [wired] Compound shape re-styling.
      Setup: Compound from BO-140.
      Do: With the compound selected, set fill to green via the Color
          panel.
      Expect: Compound carries green fill; after Expand the resulting
              polygon also shows green.
      — last: —

**P2**

- [ ] **BO-147** [wired] Release preserves operand z-order.
      Setup: Compound of three rects (z-order: back=blue,
             middle=green, front=red).
      Do: Release.
      Expect: Three released rects match the original z-order —
              blue at the bottom, red at the top.
      — last: —

- [ ] **BO-148** [wired] Save / reload round-trip of a compound
  shape.
      Setup: Compound from BO-140; save document; reopen.
      Do: Inspect the canvas.
      Expect: Compound renders identically. Operand tree preserved;
              cached geometry recomputed from operands.
      — last: —

- [ ] **BO-149** [wired] Nested compound shapes (compound containing
  a compound).
      Setup: Two compounds A and B on the canvas; select both.
      Do: Menu → Make Compound Shape.
      Expect: A single outer CompoundShape wraps both compounds as
              its operands. Evaluates correctly.
      — last: —

---

## Session G — Boolean Options dialog (~10 min)

**P1**

- [ ] **BO-170** [wired] Dialog opens with defaults.
      Setup: Fresh document.
      Do: Menu → Boolean Options…
      Expect: Modal dialog titled "Boolean Options". Three fields:
              Precision = `0.0283`, Remove Redundant Points
              unchecked, Divide-Remove-Unpainted unchecked. Three
              buttons: Defaults, Cancel, OK.
      — last: —

- [ ] **BO-171** [wired] Cancel discards changes.
      Setup: Dialog open.
      Do: Change Precision to `0.1`, check Remove Redundant Points;
          click Cancel.
      Expect: Dialog closes; state values unchanged (re-open to
              verify).
      — last: —

- [ ] **BO-172** [wired] OK commits changes to document state.
      Setup: Dialog open.
      Do: Change Precision to `0.5`, check Divide-Remove-Unpainted;
          click OK.
      Expect: Dialog closes; `state.boolean_precision` = 0.5;
              `state.boolean_divide_remove_unpainted` = true.
      — last: —

- [ ] **BO-173** [wired] Remove Redundant Points affects output.
      Setup: Two overlapping regular polygons with collinear interior
             vertices. Remove Redundant Points = off.
      Do: UNION; note output vertex count; Undo; set Remove Redundant
          Points on via dialog; UNION again.
      Expect: Second output has strictly fewer vertices.
      — last: —

- [ ] **BO-174** [wired] Divide-Remove-Unpainted drops unpainted
  fragments.
      Setup: Two-overlap fixture; both rects have no fill and no
             stroke. Set Divide-Remove-Unpainted = on.
      Do: Click DIVIDE.
      Expect: Zero polygons result (all three DIVIDE fragments are
              unpainted → dropped). With the flag off, three
              fragments would be kept.
      — last: —

- [ ] **BO-175** [wired] Precision threading into curve flattening.
      Setup: Two overlapping Circles. Precision default.
      Do: UNION; note output vertex count. Undo; set Precision = 1.0;
          UNION again.
      Expect: Second output has strictly fewer vertices (coarser
              flattening).
      — last: —

**P2**

- [ ] **BO-176** [wired] Defaults button resets dialog fields only.
      Setup: Dialog open with non-default values.
      Do: Click Defaults.
      Expect: Fields revert to 0.0283 / unchecked / unchecked. Dialog
              stays open. State values are unchanged until OK is
              clicked.
      — last: —

- [ ] **BO-177** [wired] Precision clamping on commit.
      Setup: Dialog open.
      Do: Type `0` into Precision; click OK.
      Expect: Value clamps to the yaml-configured minimum (e.g.
              0.001). Or the field rejects 0 with a visible feedback
              before OK fires.
      — last: —

- [ ] **BO-178** [wired] Dialog does not close on OK if validation
  fails.
      Setup: Dialog open.
      Do: Type garbage text into Precision; click OK.
      Expect: Dialog stays open; field shows invalid state; no state
              write.
      — last: —

- [ ] **BO-179** [wired] Dialog values persist with the document.
      Setup: Set non-default options; save; close; reopen.
      Do: Re-open Boolean Options.
      Expect: Fields show the saved non-default values.
      — last: —

---

## Session H — Repeat Boolean Operation (~8 min)

**P1**

- [ ] **BO-200** [wired] Repeat replays the last destructive op on a
  new selection.
      Setup: Two-overlap fixture A; click UNION (→ one polygon).
             Two-overlap fixture B at a different location; select
             both rects of B.
      Do: Menu → Repeat Boolean Operation.
      Expect: UNION fires on fixture B — one merged polygon results.
      — last: —

- [ ] **BO-201** [wired] Repeat replays the last compound-creating
  op.
      Setup: Alt+click INTERSECTION on fixture A; make a fresh
             fixture B; select both rects of B.
      Do: Menu → Repeat.
      Expect: A new INTERSECTION compound shape is created on B (not
              a destructive INTERSECTION).
      — last: —

- [ ] **BO-202** [wired] Repeat is disabled when no op has run.
      Setup: Fresh document, new selection.
      Do: Open the panel menu.
      Expect: Repeat Boolean Operation entry is dim / unclickable
              (`last_boolean_op == null`).
      — last: —

- [ ] **BO-203** [wired] Repeat is disabled when selection can't
  satisfy the op's gate.
      Setup: After BO-200, select just one element.
      Do: Open the panel menu.
      Expect: Repeat is disabled (`selection_count < 2` fails the
              op's gate).
      — last: —

**P2**

- [ ] **BO-204** [wired] Make Compound Shape does not update
  last_boolean_op.
      Setup: Click UNION (destructive) → Make Compound Shape on a
             different pair. Inspect `state.last_boolean_op`.
      Expect: Field still reads `"union"` — Make deliberately does
              not write (per BOOLEAN.md §Repeat state). Repeat fires
              destructive UNION.
      — last: —

- [ ] **BO-205** [wired] Release / Expand Compound Shape do not
  update last_boolean_op.
      Setup: Compound selected; click Release.
      Expect: `last_boolean_op` retains its previous value; Repeat
              is unaffected.
      — last: —

- [ ] **BO-206** [wired] Repeat survives document save/load.
      Setup: Apply UNION; save; reopen document; make a fresh
             two-overlap selection.
      Do: Menu → Repeat.
      Expect: UNION replays.
      — last: —

- [ ] **BO-207** [wired] Repeat shares the op's undo granularity.
      Setup: Apply UNION via Repeat after BO-200.
      Do: Ctrl/Cmd-Z.
      Expect: Single undo reverses the Repeated op (same as a direct
              button click).
      — last: —

---

## Session I — Reset Panel (~3 min)

**P2**

- [ ] **BO-220** [wired] Reset Panel clears last_boolean_op only.
      Setup: After BO-200 (last_boolean_op = "union"); Boolean
             Options values at non-defaults.
      Do: Menu → Reset Panel.
      Expect: `last_boolean_op` = null; Repeat entry becomes
              disabled. Boolean Options values (precision,
              remove_redundant_points, divide_remove_unpainted) are
              NOT touched.
      — last: —

- [ ] **BO-221** [wired] Reset Panel is always enabled.
      Setup: Any state.
      Do: Open menu.
      Expect: Reset Panel entry is enabled (even when last_op is
              already null).
      — last: —

- [ ] **BO-222** [wired] Reset on null last_op is a safe no-op.
      Setup: Fresh document (last_op = null).
      Do: Menu → Reset Panel.
      Expect: No crash; state unchanged; menu reopens cleanly.
      — last: —

---

## Session J — Enable / disable rules (~8 min)

**P1**

- [ ] **BO-230** [wired] All 9 operation buttons disable with 0 or 1
  selected.
      Setup: 1 rect selected.
      Do: Visually scan the button grid.
      Expect: All 9 buttons (UNION, SUBTRACT_FRONT, INTERSECTION,
              EXCLUDE, DIVIDE, TRIM, MERGE, CROP, SUBTRACT_BACK) dim
              / unclickable.
      — last: —

- [ ] **BO-231** [wired] All 9 operation buttons enable with ≥ 2
  selected.
      Setup: 2 rects selected.
      Do: Inspect button states.
      Expect: All 9 enabled; Expand still disabled (no compound).
      — last: —

- [ ] **BO-232** [wired] Expand button gates on compound-shape
  presence.
      Setup: 3 rects (no compound) selected.
      Do: Inspect Expand button state.
      Expect: Disabled.
              Now add a compound shape to the selection → Expand
              enables.
      — last: —

- [ ] **BO-233** [wired] Make Compound Shape menu gates on
  selection_count ≥ 2.
      Setup: 1 rect selected.
      Do: Open menu.
      Expect: Make Compound Shape disabled.
              Add another rect → enables.
      — last: —

- [ ] **BO-234** [wired] Release / Expand Compound Shape menu gate on
  compound presence.
      Setup: 2 rects (no compound).
      Do: Open menu.
      Expect: Release / Expand entries disabled.
              Replace selection with a compound → both enable.
      — last: —

**P2**

- [ ] **BO-235** [wired] Non-geometric elements in selection are
  skipped silently.
      Setup: 2 rects + 1 image element (if available) all selected.
      Do: Click UNION.
      Expect: UNION runs on the rects; image is skipped with a
              status-bar message per BOOLEAN.md §Enable / disable
              rules. If fewer than 2 geometric operands remain,
              overall op is a no-op.
      — last: —

- [ ] **BO-236** [wired] Siblings-only: non-sibling selection is a
  no-op.
      Setup: Select one rect at the top level and one rect inside a
             group.
      Do: Click UNION.
      Expect: No change — siblings precondition fails. Status message
              (if any) explains.
      — last: —

- [ ] **BO-237** [wired] Selection count updates propagate within one
  frame.
      Setup: Rapid shift-click to add / remove elements.
      Do: Watch button states.
      Expect: No flicker; no stale disabled state.
      — last: —

---

## Session K — Undo / redo (~5 min)

**P1**

- [ ] **BO-260** [wired] A single UNION is one undo step.
      Setup: Two-overlap fixture.
      Do: UNION; Ctrl/Cmd-Z.
      Expect: Both rects restored in their original positions;
              single undo covers the whole op.
      — last: —

- [ ] **BO-261** [wired] Redo reapplies the op.
      Setup: Continue from BO-260.
      Do: Ctrl/Cmd-Shift-Z.
      Expect: Unioned polygon returns.
      — last: —

- [ ] **BO-262** [wired] Make Compound Shape is one undo step.
      Setup: Two-overlap fixture; Menu → Make Compound Shape.
      Do: Undo.
      Expect: Two rects restored; no dangling compound reference.
      — last: —

- [ ] **BO-263** [wired] Release is one undo step.
      Setup: Compound from BO-140; Release.
      Do: Undo.
      Expect: Compound restored in place; operands gone from the
              layer tree.
      — last: —

- [ ] **BO-264** [wired] Expand is one undo step.
      Setup: Compound from BO-140; Expand.
      Do: Undo.
      Expect: Compound restored; polygon output removed.
      — last: —

**P2**

- [ ] **BO-265** [wired] Boolean Options OK is an undoable edit.
      Setup: Dialog open; change Precision to 0.5; OK.
      Do: Ctrl/Cmd-Z.
      Expect: Precision reverts to previous value. (If Options-dialog
              edits are intentionally excluded from undo stack per
              document policy, note that and mark this P2 as
              skipped.)
      — last: —

---

## Session L — Appearance + keyboard (~8 min)

**P2 — theming**

- [ ] **BO-280** [wired] Dark appearance — icons and Expand button
  readable.
      Setup: Appearance = Dark.
      Expect: 9 operation icons contrast against panel background;
              Expand button label readable; disabled states dim but
              distinguishable; reserved empty slot does not leak a
              visual glyph.
      — last: —

- [ ] **BO-281** [wired] Medium Gray appearance.
      Expect: Same readability as Dark.
      — last: —

- [ ] **BO-282** [wired] Light Gray appearance.
      Expect: Icons invert / retint as needed; no black-on-black
              regressions.
      — last: —

**P2 — keyboard**

- [ ] **BO-283** [wired] Tab cycles through operation buttons.
      Setup: Panel docked; focus on panel content.
      Do: Tab repeatedly.
      Expect: Focus cycles in document order: 4 Shape Mode buttons →
              Expand → 5 Pathfinder buttons (plus reserved slot
              skipped). Visible focus ring per theme.
      — last: —

- [ ] **BO-284** [wired] Enter / Space on focused button fires the
  op.
      Setup: Two-overlap fixture; Tab to UNION button.
      Do: Press Enter.
      Expect: UNION fires as if clicked.
      — last: —

- [ ] **BO-285** [wired] Alt+Enter on a focused Shape Mode button
  creates a compound shape.
      Setup: Two-overlap fixture; Tab to UNION.
      Do: Alt/Option+Enter (or platform equivalent).
      Expect: Compound shape created (same as Alt+click).
      — last: —

- [ ] **BO-286** [wired] Hamburger menu accessible via keyboard.
      Setup: Focus in panel.
      Do: Use the panel-menu keyboard shortcut (platform convention).
      Expect: Menu opens; Arrow keys navigate; Enter fires selected
              item.
      — last: —

---

## Cross-app parity — Session M (~20 min)

~10 load-bearing tests. Batch by app: one full pass per app.

- **BO-400** [wired] UNION on the two-overlap fixture produces the
  same polygon across apps.
      Do: Two 100×100 rects at (0,0) and (50,0); UNION.
      Expect: One polygon with outer boundary (0,0)-(150,0)-
              (150,100)-(0,100)-(0,0). Identical vertex set (order-
              independent compare) across apps.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **BO-401** [wired] DIVIDE on two-overlap yields three fragments.
      Do: Two-overlap fixture; DIVIDE.
      Expect: Three polygons; back-only, overlap, front-only in that
              order.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **BO-402** [wired] MERGE with matching fills unions.
      Do: Matching-paint fixture; MERGE.
      Expect: One polygon; fill = `#ff0000`.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **BO-403** [wired] MERGE with None fills produces two polygons.
      Do: Two-overlap fixture, no fills; MERGE.
      Expect: TRIM output kept separate — two polygons.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **BO-404** [wired] Make Compound Shape produces identical compound
  tree.
      Do: Two-overlap fixture; Menu → Make Compound Shape.
      Expect: One CompoundShape element; operation = UNION; two
              operands preserved in z-order.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **BO-405** [wired] Release Compound Shape restores identical
  operands.
      Do: Compound from BO-404; Release.
      Expect: Two rects restored in original z-order with original
              paints.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **BO-406** [wired] Expand Compound Shape produces the same polygon
  as destructive UNION.
      Do: Alt+click UNION on two-overlap fixture; Expand.
      Expect: Resulting polygon matches BO-400 output byte-for-byte.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **BO-407** [wired] Divide-Remove-Unpainted drops unpainted DIVIDE
  fragments identically.
      Do: Two rects with no fill/stroke; Boolean Options → Divide-
          Remove-Unpainted on; DIVIDE.
      Expect: Zero polygons in all apps.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **BO-408** [wired] Remove Redundant Points collapses collinear
  output vertices.
      Do: UNION of two axis-aligned overlapping rects with Remove
          Redundant Points on.
      Expect: Output polygon has exactly 4 vertices (rectangle
              corners), no collinear extras, in all apps.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **BO-409** [wired] Repeat replays destructive vs compound by
  suffix.
      Do: Alt+click INTERSECTION; fresh two-overlap selection;
          Repeat.
      Expect: New INTERSECTION compound shape (not destructive) in
              all apps.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

---

## Graveyard

_No retired tests yet._

---

## Enhancements

_No outstanding enhancement ideas. Append `ENH-NNN` entries here when
manual testing surfaces non-blocking follow-ups._
