# Selection / Interior Selection / Partial Selection — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/selection.yaml`, `workspace/tools/interior_selection.yaml`,
`workspace/tools/partial_selection.yaml`. Design doc:
`transcripts/SELECTION_TOOL.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other platforms
covered in Session L parity sweep.

---

## Known broken

_Last reviewed: 2026-04-23_

_No known-broken tests._

---

## Automation coverage

_Last synced: 2026-04-23_

**Python — `jas/tools/yaml_tool_test.py::TestSelectionValidation`** (~8 tests)
- Loads selection YAML from `workspace/workspace.json`.
- Click-on-element / click-on-empty / Shift-click toggle / drag-to-move /
  marquee / Alt-drag copy / Escape-idle state transitions.
- Also covers ToolSpec / Dispatch classes that exercise YAML parsing used by
  all three selection tools.

**Swift — `JasSwift/Tests/Tools/YamlToolSelectionTests.swift`** (~12 tests)
- Mirror of the Python suite plus Interior-Selection recursion tests and
  Partial-Selection handle-hit priority tests.

**OCaml — `jas_ocaml/test/tools/yaml_tool_selection_test.ml`** (~10 Alcotest
cases)
- Mirror of the Python / Swift suites. Interior-Selection group recursion
  and Partial-Selection CP-marquee covered.

**Rust — `jas_dioxus/src/tools/yaml_tool.rs` (#[cfg(test)])**
- Reference implementation. Full selection / interior / partial coverage:
  hit-test priority, marquee, drag-move, Alt-drag copy, Escape-cancel,
  Shift-click toggle, CP-marquee (partial), handle-drag (partial).

**Flask — `jas_flask/tests/js/test_phase9.mjs`,
`tests/js/test_phase12.mjs`, `tests/js/test_canvas.mjs`** (~20 tests
spread across files)
- doc.translate_selection incl. partial-CP path anchor moves;
  doc.copy_selection (alt-drag).
- doc.path.probe_partial_hit (CP hits, handle hits, miss → marquee);
  doc.path.commit_partial_marquee (replace + additive); doc.move_path_handle
  (smooth-anchor reflection).
- Selection HUD render (bbox + handles, partial-CP fill state).

The manual suite below covers what auto-tests cannot reach: marquee
overlay appearance, cursor switching, keyboard focus, appearance theming,
cross-panel interaction (Align / Boolean / Layers reflecting changes),
undo / redo visible on canvas, and the visual distinction between the
three tools' overlays.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document (one layer, no elements).
3. Appearance: **Dark**.
4. Toolbox visible; Selection tool active.

When a test calls for a **3-rect fixture** the default is: Rect tool →
draw three non-overlapping rectangles — roughly at (50,50,40×40),
(150,100,60×40), (260,60,40×60) — → Selection tool → Ctrl/Cmd-A.

When a test calls for a **group fixture**: draw 2 rects, Ctrl/Cmd-A,
Object → Group. Then draw a third rect outside the group.

When a test calls for a **curved path**: Pen tool → click 3 corner
anchors → click-and-drag the 4th to make a smooth anchor → Esc.

---

## Tier definitions

- **P0 — existential.** If this fails, the tool is broken. Crash, layout
  collapse, nothing selects. 5-minute smoke confidence.
- **P1 — core.** Tool does its primary job (click, drag, marquee, Shift,
  Alt, Esc).
- **P2 — edge & polish.** Overlay styling, cursor, tolerance, focus,
  keyboard nav, theming, cross-panel reflection.

---

## Session table of contents

| Session | Topic                                               | Est.  | IDs        |
|---------|-----------------------------------------------------|-------|------------|
| A       | Smoke & lifecycle                                   | ~5m   | 001–009    |
| B       | Selection — click / shift-click / empty            | ~8m   | 010–029    |
| C       | Selection — marquee                                 | ~8m   | 030–049    |
| D       | Selection — drag-to-move & Alt-drag copy            | ~8m   | 050–069    |
| E       | Selection — Esc and tool deactivation               | ~5m   | 070–079    |
| F       | Interior Selection — group recursion                | ~8m   | 080–099    |
| G       | Partial Selection — CP hit-test priority            | ~10m  | 100–129    |
| H       | Partial Selection — handle / CP drag                | ~8m   | 130–149    |
| I       | Overlay & cursor                                    | ~5m   | 150–169    |
| J       | Undo / redo                                         | ~5m   | 170–189    |
| K       | Appearance theming                                  | ~5m   | 190–199    |
| L       | Cross-app parity                                    | ~15m  | 300–329    |

Full pass: ~90 min. Partial runs are useful — each session stands alone;
A gates the rest.

---

## Session A — Smoke & lifecycle (~5 min)

If any P0 here fails, stop and flag.

- [x] **SEL-001** [wired] Selection tool activates via toolbox icon.
      Do: Click the Selection (arrow) icon in the toolbox.
      Expect: Icon shows active state; cursor becomes arrow over the canvas.
      — last: 2026-04-30 (Rust)

- [x] **SEL-002** [wired] Selection tool activates via V shortcut.
      Do: Press V.
      Expect: Selection tool becomes active regardless of previously-active
              tool.
      — last: 2026-04-30 (Rust)

- [x] **SEL-003** [wired] Partial Selection activates via A shortcut.
      Do: Press A.
      Expect: Partial Selection tool (white arrow) becomes active.
      — last: 2026-04-30 (Rust). Required hollow_arrow cursor in
        4829eea.

- [x] **SEL-004** [wired] Interior Selection activates via toolbox icon.
      Do: Click the Interior Selection icon (if present) or long-press
          Selection.
      Expect: Interior Selection tool becomes active with its own icon
              state.
      — last: 2026-04-30 (Rust). Required hollow_arrow_plus cursor
        in 045887e.

- [x] **SEL-005** [wired] Switching tools mid-gesture commits or cancels
  cleanly.
      Setup: 3-rect fixture.
      Do: Start a Selection drag on empty space; while still dragging, press
          L (another tool).
      Expect: No crash; marquee overlay disappears; the new tool becomes
              active.
      — last: 2026-04-30 (Rust). Required Q-to-Lasso shortcut in
        07e1e73 + lasso doc-coord fix in fbf5811.

---

## Session B — Selection click / shift-click / empty (~8 min)

**P0**

- [x] **SEL-010** [wired] Click on an element replaces the selection.
      Setup: 3-rect fixture; nothing selected.
      Do: Click the middle rect.
      Expect: Only the middle rect is selected; selection bounds visible
              around it.
      — last: 2026-04-30 (Rust)

- [x] **SEL-011** [wired] Click on another element replaces again.
      Setup: SEL-010 state.
      Do: Click the right rect.
      Expect: Middle rect deselects; right rect alone is selected.
      — last: 2026-04-30 (Rust)

- [x] **SEL-012** [wired] Click on empty space clears the selection.
      Setup: 3-rect fixture; one rect selected.
      Do: Click far from any element.
      Expect: Selection cleared; no selection bounds visible.
      — last: 2026-04-30 (Rust)

**P1**

- [x] **SEL-013** [wired] Shift-click adds a non-selected element to the
  selection.
      Setup: Left rect selected.
      Do: Shift-click the middle rect.
      Expect: Both left and middle are selected.
      — last: 2026-04-30 (Rust)

- [x] **SEL-014** [wired] Shift-click on a selected element removes it.
      Setup: SEL-013 state (two rects selected).
      Do: Shift-click the left rect.
      Expect: Only the middle rect remains selected.
      — last: 2026-04-30 (Rust)

- [x] **SEL-015** [wired] Shift-click in empty space does NOT clear.
      Setup: Middle rect selected.
      Do: Shift-click far from any element.
      Expect: Selection unchanged — middle rect still selected.
      — last: 2026-04-30 (Rust)

**P2**

- [x] **SEL-016** [wired] Click on overlapping elements picks the topmost.
      Setup: Two rects stacked, second-drawn on top.
      Do: Click the overlap region.
      Expect: The second-drawn rect selects (top of the z-order).
      — last: 2026-04-30 (Rust)

- [x] **SEL-017** [wired] Click on a locked element is ignored.
      Setup: Lock the left rect via the Layers panel.
      Do: Click the left rect.
      Expect: Selection does NOT include the locked rect; selection goes
              to whatever is below (or clears).
      — last: 2026-04-30 (Rust)

---

## Session C — Selection marquee (~8 min)

**P0**

- [x] **SEL-030** [wired] Drag from empty space draws marquee and selects
  overlaps.
      Setup: 3-rect fixture; nothing selected.
      Do: Press on empty space to the upper-left; drag through all three
          rects; release.
      Expect: Marquee rectangle visible during drag; on release all three
              rects become selected.
      — last: 2026-04-30 (Rust)

- [x] **SEL-031** [wired] Marquee selects any element whose bbox intersects
  the rectangle.
      Setup: 3-rect fixture; nothing selected.
      Do: Drag a marquee that crosses only the middle rect partially.
      Expect: Middle rect alone selects — even partial overlap counts.
      — last: 2026-04-30 (Rust)

**P1**

- [x] **SEL-032** [wired] Marquee replaces the prior selection (no Shift).
      Setup: Left rect selected.
      Do: Drag a marquee over the middle rect only.
      Expect: Left deselects, middle selects.
      — last: 2026-04-30 (Rust)

- [x] **SEL-033** [wired] Shift+marquee adds to the selection.
      Setup: Left rect selected.
      Do: Hold Shift and marquee over the middle rect.
      Expect: Both left and middle selected.
      — last: 2026-04-30 (Rust)

- [x] **SEL-034** [wired] Dragging up-and-left still draws a valid marquee.
      Setup: Nothing selected.
      Do: Start a drag below-right of the rects; drag up-and-left through
          them.
      Expect: Marquee rect visible with correct normalization; rects select
              on release.
      — last: 2026-04-30 (Rust)

**P2**

- [x] **SEL-035** [wired] Marquee on empty space with no overlap clears.
      Setup: Left rect selected.
      Do: Drag a marquee far from any element.
      Expect: Selection cleared (0 elements match).
      — last: 2026-04-30 (Rust)

- [x] **SEL-036** [wired] Tiny marquee (<1px) on empty space clears.
      Setup: Left rect selected.
      Do: Press and release without moving on empty space.
      Expect: Selection cleared (matches SEL-012).
      — last: 2026-04-30 (Rust)

---

## Session D — Drag-to-move & Alt-drag copy (~8 min)

**P0**

- [x] **SEL-050** [wired] Drag a selected element translates it.
      Setup: 3-rect fixture; select the middle rect.
      Do: Press on the middle rect; drag 50 px to the right; release.
      Expect: Middle rect visibly shifts right by the drag delta; other
              two don't move.
      — last: 2026-04-30 (Rust)

- [x] **SEL-051** [wired] Multi-element drag translates the whole
  selection.
      Setup: 3-rect fixture; Ctrl/Cmd-A to select all.
      Do: Drag one of the rects 50 px right.
      Expect: All three rects shift by the same delta.
      — last: 2026-04-30 (Rust). Required selection-contains check
        in 19f763a (don't drop other selected items when clicking
        on an already-selected one).

**P1**

- [x] **SEL-052** [wired] Alt+drag duplicates then translates the copies.
      Setup: 3-rect fixture; middle rect selected.
      Do: Alt-press on the middle rect; drag 50 px right; release.
      Expect: Original middle rect stays; a new rect appears at the drag
              endpoint; the new rect is the active selection.
      — last: 2026-04-30 (Rust)

- [x] **SEL-053** [wired] Alt released mid-drag doesn't flip copy to move.
      Setup: Middle rect selected.
      Do: Alt-press, start dragging, release Alt keys (keep mouse
          pressed), continue drag, release.
      Expect: Still a copy — the Alt-at-press modifier is frozen for the
              gesture. Original stays; new copy at drag end.
      — last: 2026-04-30 (Rust)

- [x] **SEL-054** [wired] Drag records one undo step.
      Setup: Middle rect at x=150.
      Do: Drag it to x=250; then Ctrl/Cmd-Z.
      Expect: Rect returns to x=150; a single undo reverses the whole
              drag.
      — last: 2026-04-30 (Rust)

**P2**

- [x] **SEL-055** [wired] Drag on a locked element is a no-op.
      Setup: Select a locked rect (via Layers panel lock, then canvas
             click while partial-selection or interior rendering of
             "locked but selected").
      Do: Try to drag.
      Expect: No movement; no undo entry created.
      — last: 2026-04-30 (Rust)

- [x] **SEL-056** [wired] Alt+click without drag is treated as normal
  click.
      Setup: 3-rect fixture; nothing selected.
      Do: Alt-click the middle rect and release without moving.
      Expect: Middle rect selects; no duplicate is created.
      — last: 2026-04-30 (Rust)

## Enhancements raised in Session D

- **ENH-001** Mid-drag Alt-toggle live preview: SEL-052/053 follow-up
  on 2026-04-30 added a dashed outline at the would-be copy position
  while Alt is held mid-drag, with the original snapped back to the
  press point via doc.preview.restore. Releasing Alt resumes the
  move; releasing the mouse with Alt held commits a real copy.
  _Superseded 2026-05-01 by ENH-002 — the ghost overlay was replaced
  with a real moving copy for visual parity with the at-press copy
  path; selection_translate_ghost overlay type retired._

---

## Session E — Esc & tool deactivation (~5 min)

**P1**

- [x] **SEL-070** [wired] Esc during marquee cancels.
      Setup: Begin a marquee drag from empty space.
      Do: Press Esc while still dragging.
      Expect: Marquee overlay disappears; selection unchanged from pre-
              drag state.
      — last: 2026-04-30 (Rust)

- [x] **SEL-071** [wired] Esc during drag-move cancels.
      Setup: Begin dragging a selected rect.
      Do: Press Esc while still dragging.
      Expect: Rect returns to its pre-drag position; selection unchanged.
      — last: 2026-04-30 (Rust). Required preview.restore on Esc
        in b250ec1.

- [x] **SEL-072** [wired] Switching tools mid-drag doesn't corrupt state.
      Setup: Begin dragging a selected rect.
      Do: Press V / P / L without releasing the mouse; then release.
      Expect: Rect either commits at current position or snaps back; no
              ghost element; no crash.
      — last: 2026-04-30 (Rust). on_leave snaps back via
        preview.restore (b250ec1).

---

## Session F — Interior Selection group recursion (~8 min)

**P1**

- [x] **SEL-080** [wired] Interior click into a group selects the leaf.
      Setup: Group fixture.
      Do: With Interior Selection active, click the child rect inside
          the group.
      Expect: Just that child rect is selected (NOT the whole group).
              Selection bounds trace the child rect only.
      — last: 2026-04-30 (Rust)

- [x] **SEL-081** [wired] Selection tool on the same click selects the
  whole group.
      Setup: Group fixture; nothing selected.
      Do: With plain Selection active, click the child rect inside.
      Expect: The whole group is selected (group bounds, not child bounds).
      — last: 2026-04-30 (Rust)

- [x] **SEL-082** [wired] Interior marquee selects individual CPs.
      Setup: Group fixture with a path inside.
      Do: With Interior Selection active, marquee over some anchors of
          the path.
      Expect: On release, the enclosed control points become the
              selection (partial-selection semantics).
      — last: 2026-04-30 (Rust)

**P2**

- [x] **SEL-083** [wired] Interior drag moves the leaf, not the group.
      Setup: SEL-080 state — child rect selected via Interior Selection.
      Do: Drag the child rect 50 px right.
      Expect: Only the child moves; its sibling in the group stays put.
              The group bounds update to reflect the new child position.
      — last: 2026-04-30 (Rust)

- [ ] **SEL-084** [wired] Interior Selection on an empty Group falls
  through.
      Setup: Create an empty Group, then draw a rect outside it.
      Do: Click on the empty Group's region (there's nothing to hit).
      Expect: Selection clears — nothing leaf-level under the cursor.
      — last: — · regression: Rust 2026-04-30 — can't construct an
        empty Group via the UI (Object → Group requires a non-empty
        selection). Test bypass would need a fixture file or a
        canvas-side "make empty group" action. Out of Tier-0 scope.

---

## Session G — Partial Selection CP hit-test priority (~10 min)

**P0**

- [x] **SEL-100** [wired] Click on an anchor selects the single CP.
      Setup: Curved path fixture; Partial Selection active; path's CPs
             visible.
      Do: Click directly on one anchor square.
      Expect: Just that anchor is selected (highlighted/filled); other
              anchors on the path are unfilled.
      — last: 2026-04-30 (Rust). Required handle-overlay
        viewport-transform fix in 97dbbb9 (handles were
        rendering in raw doc coords, off-canvas).

- [x] **SEL-101** [wired] Click on empty space clears the CP selection.
      Setup: SEL-100 state; one CP selected.
      Do: Click on empty canvas.
      Expect: CP selection clears; anchors all return to the unselected
              look; element remains "on canvas" with its anchors shown.
      — last: 2026-04-30 (Rust)

**P1**

- [x] **SEL-102** [wired] Priority 1: handle-hit on a selected Path wins
  over CP.
      Setup: Select a curved path with its smooth anchor's handle near a
             control point.
      Do: Click on the handle endpoint.
      Expect: The handle latches (not the CP); subsequent drag moves just
              that handle.
      — last: 2026-04-30 (Rust)

- [x] **SEL-103** [wired] Priority 2: CP click designates the CP.
      Setup: Partial Selection active; curved path visible; no prior CP
             selection.
      Do: Click on an anchor.
      Expect: That anchor CP becomes the selection (handles under
              cursor aren't hit because no path was "selected" for the
              handle-priority rule yet).
      — last: 2026-04-30 (Rust)

- [x] **SEL-104** [wired] Shift+click on a CP toggles it in the selection.
      Setup: One anchor already selected.
      Do: Shift-click a second anchor; then Shift-click the first one
          again.
      Expect: After first Shift-click, both anchors selected. After
              second Shift-click, only the second remains.
      — last: 2026-04-30 (Rust)

**P2**

- [x] **SEL-105** [wired] Marquee selects CPs inside the rect.
      Setup: Partial Selection active; curved path with ≥ 4 anchors.
      Do: Marquee over 2 adjacent anchors on the path.
      Expect: Only those 2 anchors become selected CPs.
      — last: 2026-04-30 (Rust)

- [x] **SEL-106** [wired] Empty-ish marquee (<1px²) without Shift clears.
      Setup: One CP selected.
      Do: Partial-selection press-and-release on empty space.
      Expect: CP selection clears.
      — last: 2026-04-30 (Rust)

- [x] **SEL-107** [wired] Click hit radius for CP matches the design spec.
      Setup: Curved path.
      Do: Click 7 px from an anchor, then 9 px from it.
      Expect: 7 px hit designates the CP; 9 px misses (8 px is the
              tolerance).
      — last: 2026-04-30 (Rust)

---

## Session H — Partial Selection handle / CP drag (~8 min)

**P1**

- [x] **SEL-130** [wired] Dragging a selected CP translates just that CP.
      Setup: One anchor selected (SEL-100 state).
      Do: Drag the anchor 50 px right.
      Expect: Only that anchor moves; its neighbors remain; the two
              adjacent segments re-shape to accommodate the moved
              anchor.
      — last: 2026-05-01 (Rust)

- [x] **SEL-131** [wired] Dragging a latched handle moves only the
  single handle (cusp).
      Setup: SEL-102 state — handle latched.
      Do: Drag 40 px perpendicular to the tangent.
      Expect: The dragged handle moves; the opposite handle of the same
              anchor stays put (not mirrored). Curve shape changes on
              just one side.
      — last: 2026-05-01 (Rust)

- [x] **SEL-132** [wired] Alt+drag on a CP duplicates the path.
      Setup: Select all CPs of a path (Ctrl/Cmd-A while Partial
             Selection active).
      Do: Alt-drag one of the anchors 80 px right.
      Expect: A copy of the path is created translated by the drag
              delta; original stays.
      — last: 2026-05-01 (Rust)

**P2**

- [x] **SEL-133** [wired] CP drag threshold is 4 px (DRAG_THRESHOLD).
      Setup: Press on an anchor.
      Do: Move the mouse 3 px while pressed, then release.
      Expect: Treated as a click (CP selects); no move is committed.
      — last: 2026-05-01 (Rust)

- [x] **SEL-134** [wired] Handle drag threshold is 0.5 px.
      Setup: Press on a handle endpoint.
      Do: Move 0.4 px, then release.
      Expect: Treated as a click (no handle move committed).
      — last: 2026-05-01 (Rust)

- [x] **SEL-135** [wired] Dragging past threshold snapshots once.
      Setup: Start a CP drag past the 4 px threshold.
      Do: Drag across the canvas; release. Then Ctrl/Cmd-Z.
      Expect: One undo reverses the full translation.
      — last: 2026-05-01 (Rust)

- [x] **SEL-136** [wired] Mid-drag Alt on a CP commits a copy of the
  path on release (mirrors SEL-053 for Selection tool).
      Setup: Select all CPs of a path.
      Do: Press on an anchor WITHOUT Alt; drag past threshold; press
          Alt mid-drag; release with Alt still held.
      Expect: A copy is committed at the cursor's release position;
              the original stays at its press position
              (preview-restored on the alt-press transition). During
              the preview phase the copy is a real rendered element
              moving with the cursor (not a ghost outline).
      — last: 2026-05-01 (Rust)

## Enhancements raised in Session H

- **ENH-002** Mid-drag Alt copy on Partial Selection + visual parity:
  SEL-132 follow-up added the mid-drag-Alt live preview pattern on
  partial_selection.yaml mirroring Selection's SEL-053. The preview
  is a REAL moving copy of the selection (created via doc.copy_selection
  on the alt-press transition, rolled back via doc.preview.restore on
  alt-release), not a wireframe bounding-box ghost — visual parity
  with the at-press copy path. Selection's earlier ghost overlay
  (ENH-001) was retired for the same reason; the
  selection_translate_ghost overlay type was removed. Same fix landed
  on selection.yaml for a latent exit-preview double-translate bug
  (sibling-if branches were reading freshly-mutated state on the same
  frame). _Raised during SEL-132 follow-up on 2026-05-01._

---

## Session I — Overlay & cursor (~5 min)

**P2**

- [x] **SEL-150** [wired] Selection marquee overlay is dashed blue with
  8% fill.
      Do: Begin a marquee drag; observe the rectangle styling.
      Expect: Stroke reads as the design's `#4a90d9` dashed line; fill
              is a light blue tint; no solid-color fill.
      — last: 2026-05-01 (Rust)

- [x] **SEL-151** [wired] Partial Selection overlay shows anchors and
  handles.
      Setup: Select a curved path.
      Do: Observe the selected path's decorations.
      Expect: Anchor squares at each CP, handle bars for smooth
              anchors, handle dots at handle endpoints. Selected CP
              differs in fill vs unselected.
      — last: 2026-05-01 (Rust)

- [x] **SEL-152** [wired] Cursor is arrow for Selection, hollow-arrow
  for Partial, hollow-arrow-plus for Interior.
      Do: Switch between V / A / Y and observe the canvas cursor.
      Expect: V → solid arrow; A → hollow arrow; Y → hollow arrow with
              a plus glyph. No crosshair (those belong to drawing
              tools).
      — last: 2026-05-01 (Rust)
      regression: cursor mapping updated 2026-04-30 — Partial Selection
        switched to hollow_arrow and Interior to hollow_arrow_plus per
        user request; SVG cursors translated by yaml_cursor_to_css in
        app.rs.

- [x] **SEL-153** [wired] Switching tools hides the prior tool's
  overlay immediately.
      Setup: Partial Selection active with CP overlay visible.
      Do: Press V.
      Expect: CP / handle decorations disappear; selection bounds for
              the path appear instead.
      — last: 2026-05-01 (Rust)

---

## Session J — Undo / redo (~5 min)

**P1**

- [x] **SEL-170** [wired] Drag-move is one undo step.
      Covered by SEL-054. Redo restores the moved position.
      — last: 2026-05-01 (Rust)

- [x] **SEL-171** [wired] Alt-drag copy is one undo step.
      Setup: SEL-052 state (one copy created).
      Do: Ctrl/Cmd-Z.
      Expect: Copy is removed; original rect unchanged; selection
              reverts to the original.
      — last: 2026-05-01 (Rust)

- [x] **SEL-172** [wired] CP drag is one undo step.
      Setup: SEL-130 state (one CP moved).
      Do: Ctrl/Cmd-Z.
      Expect: Anchor returns to prior position.
      — last: 2026-05-01 (Rust)

**P2**

- [x] **SEL-173** [wired] Handle drag is one undo step.
      Setup: SEL-131 state.
      Do: Ctrl/Cmd-Z.
      Expect: Handle returns; curve shape restored on the affected side.
      — last: 2026-05-01 (Rust)

- [x] **SEL-174** [wired] Click-drag a new element preserves the new
  selection on undo (does not revert to the prior selection).
      Setup: Element A selected via prior gesture.
      Do: With Selection tool, click and drag a different element B
          to a new position. Then Ctrl/Cmd-Z.
      Expect: B returns to its original position AND B (not A)
              remains the selection.
      — last: 2026-05-01 (Rust)
      regression: doc.snapshot was taken in on_mousedown BEFORE
        set_selection, so undo restored the stale selection. Fix
        defers snapshot+preview.capture to the first mousemove of
        the drag (mirrors partial_selection.yaml's pattern); a
        bonus benefit is that pure clicks no longer push a no-op
        undo entry.

---

## Session K — Appearance theming (~5 min)

**P2**

- [x] **SEL-190** [wired] Marquee overlay contrasts on Dark appearance.
      Setup: Dark theme.
      Do: Begin a marquee drag.
      Expect: Blue dashed rectangle is clearly visible against dark
              canvas background.
      — last: 2026-05-01 (Rust)
      regression: appearance menu was empty (assets/index.html ignored
        by dx); now bootstrapped from app.rs. Pasteboard background was
        hardcoded "#3c3c3c"; now reads --jas-pane-bg via theme::css_var_value
        so it tracks the active appearance.

- [x] **SEL-191** [wired] CP overlay readable on Medium Gray.
      Setup: Switch to Medium Gray.
      Do: Select a curved path with Partial Selection.
      Expect: Anchor squares and handle bars remain visible; no
              unreadable same-color-on-same-color regressions.
      — last: 2026-05-01 (Rust)

- [x] **SEL-192** [wired] CP overlay readable on Light Gray.
      Setup: Switch to Light Gray.
      Do: Select a curved path with Partial Selection.
      Expect: Same readability; selected-vs-unselected anchor
              distinction still clear.
      — last: 2026-05-01 (Rust)

---

## Cross-app parity — Session L (~15 min)

~8 load-bearing tests. Batch by app: one full pass per app.

- **SEL-300** [wired] Click on a rect selects exactly one element.
      Do: 3-rect fixture; click the middle rect.
      Expect: `len(model.document.selection) == 1`, path is the middle
              rect.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [x] Flask      last: 2026-04-26

- **SEL-301** [wired] Shift-click toggles selection identically across
  apps.
      Do: Shift-click the left rect, Shift-click the middle, Shift-click
          the left again.
      Expect: Final selection is just the middle rect; intermediate
              sizes match.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [x] Flask      last: 2026-04-26

- **SEL-302** [wired] Marquee result matches across apps.
      Do: Drag a marquee from (-5,-5) to (12,12) on 3-rect fixture.
      Expect: Only the first rect (at origin) is selected in every
              app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [x] Flask      last: 2026-04-26  · note: fixture's rect A is at (50,50), not origin; ran with marquee (40,40)→(95,95)

- **SEL-303** [wired] Drag-move produces same final coordinates.
      Do: Select middle rect (at 150,100); drag by (+30, +40).
      Expect: Final position (180,140) in every app; undo returns to
              (150,100).
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [x] Flask      last: 2026-04-26

- **SEL-304** [wired] Alt-drag produces identical copy count.
      Do: Select middle rect; Alt-drag by 100 px right.
      Expect: `len(model.document.layers[0].children) == 4` (3 +
              1 copy) in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [x] Flask      last: 2026-04-26

- **SEL-305** [wired] Interior Selection picks the leaf inside a
  group.
      Do: Group fixture; Interior Selection; click the child rect.
      Expect: Selection path reaches into the group (length-2 path),
              not the length-1 group path.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [x] Flask      last: 2026-04-27  · note: implemented Group / Ungroup actions (JAS.groupSelection / ungroupSelection routed through app.js dispatch), split hit_test into a flat layer-children variant + recursive hit_test_deep, and dispatched doc.partial_select_in_rect for the marquee. Interior Selection tool has no shortcut binding; set `state.active_tool='interior_selection'` via devtools.

- **SEL-306** [wired] Partial Selection handle-drag cusp semantics.
      Do: Curved path; Partial Selection; drag a smooth anchor's
          out-handle.
      Expect: Out-handle moves, in-handle stays put (cusp behavior) in
              every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [x] Flask      last: 2026-04-27  · note: Flask + Rust both implement smooth-symmetric reflection (geometry::move_path_handle), not cusp; spec text and wiring disagree across all apps. Surfaced cubic/quadratic-Bezier-extrema gap in path bounds (fixed); selection HUD now draws Bezier handle indicators for partial-selected anchors.

- **SEL-307** [wired] Escape during marquee leaves selection
  untouched.
      Do: Select middle rect; begin a marquee drag; press Esc.
      Expect: Middle rect remains selected; no marquee artifact left.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [x] Flask      last: 2026-04-27

---

## Graveyard

_No retired tests yet._

---

## Enhancements

- **ENH-001** Alt-drag-copy should respond to Alt **at any point during the
  drag**, not only when Alt was held at mousedown. Today
  `selection.yaml::on_mousedown` latches `tool.selection.alt_held =
  event.modifiers.alt`; on_mousemove checks the latched value and never
  re-reads `event.modifiers.alt`. So pressing Alt after the drag begins
  does nothing. The user's natural workflow is "start dragging, then decide
  to copy" — should fire the same `doc.copy_selection` if Alt is held when
  the next mousemove fires (and `copied == false`). Same gap exists in
  `partial_selection.yaml`. Cross-cutting yaml change; behaviour applies
  to all 5 apps.
  _Raised during SEL-304 on 2026-04-26._
