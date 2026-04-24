# Blob Brush Tool — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/blob_brush.yaml`. Design doc:
`transcripts/BLOB_BRUSH_TOOL.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other
platforms covered in Session I parity sweep.

---

## Known broken

_Last reviewed: 2026-04-24_

- **oval_cursor overlay (hover cursor + drag preview)** — Rust and
  Swift render the oval outline at the pointer plus the
  semi-transparent filled ovals during a `painting` drag and the
  dashed outline ovals during an `erasing` drag. OCaml and Python
  `yaml_tool.draw_overlay` are still Phase-5a stubs — no tool-overlay
  rendering at all, so the user sees the platform default cursor
  and no drag preview. Commits still work end-to-end on all four
  native apps. BB-200 (commit behavior) passes everywhere;
  BB-130 / BB-131 (overlay) pass only on Rust + Swift. Tracked in
  `project_yaml_tool_overlay_stubs.md`.
- **Pressure / tilt / bearing variation** — synthesizes a fixed 0.5
  at stroke time. Calligraphic brushes with these variation modes
  render at their base size / angle / roundness. Phase 2 (shared
  with Paintbrush).
- **RDP boundary simplification at fidelity epsilon** — commit
  pipeline step 4 is not yet implemented. The committed Path is
  the raw 16-seg-per-dab polygon-union boundary. Fidelity slider
  values are read and written (BB-110) but do not affect visible
  output. Deferred to a follow-up inside Phase 1.
- **`blob_brush_keep_selected` (select new element after commit)**
  — not wired yet. Phase 1 commits leave the selection unchanged;
  the option's dialog state persists but has no runtime effect.
- **Flask** — tool is spec-only; requires `buffer.*` primitives
  in the JS engine.

---

## Automation coverage

_Last synced: 2026-04-24_

**Rust — `jas_dioxus/src/interpreter/effects.rs` (#[cfg(test)])**
- 3 unit tests on `doc.blob_brush.commit_painting` /
  `commit_erasing`: commit_painting tags the new Path with
  `jas:tool-origin="blob_brush"` and emits a fill-only closed
  shape; commit_erasing deletes a fully-covered blob-brush
  element; commit_erasing leaves non-blob-brush elements alone.

**Rust — `jas_dioxus/src/interpreter/expr_eval.rs`**
- 7 unit tests on the `brush_type_of(slug)` helper: calligraphic
  / art / scatter-in-other-library success paths; unknown slug /
  missing library / malformed slug / no `brush_libraries` null
  paths.

**Rust — `jas_dioxus/src/geometry/path_ops.rs`**
- 5 unit tests on `path_to_polygon_set` / `polygon_set_to_path`:
  single square, multi-subpath, single ring, degenerate-ring
  drop, roundtrip.

**Swift / OCaml / Python** — the same 5 + 7 + 3 tests are ported
verbatim to `JasSwift/Tests/Tools/YamlToolEffectsTests.swift` (+
`Tests/Geometry/PathOpsTests.swift` +
`Tests/Interpreter/ExprEvalPhase3Tests.swift`),
`jas_ocaml/test/tools/yaml_tool_effects_test.ml` (+
`test/geometry/path_ops_test.ml` +
`test/interpreter/expr_eval_test.ml`), and
`jas/tools/yaml_tool_effects_test.py` (+
`jas/geometry/path_ops_test.py` +
`workspace_interpreter/tests/test_expr.py`).

---

## Preconditions (assumed for every session)

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document.
3. Appearance: **Dark**.
4. Blob Brush tool active (long-press Pencil slot → Blob Brush).
5. Default state: no active brush
   (`state.stroke_brush == null`), so tip shape reads from
   `state.blob_brush_size` / `_angle` / `_roundness`.

Point buffer name = `"blob_brush"`. Default Fidelity = tick 3, RDP
`epsilon = 5.0` (reserved; not yet honored at commit — see Known
broken). Default tip: size 10 pt, angle 0°, roundness 100%.

---

## Tier definitions

- **P0 — existential.** Tool doesn't activate, doesn't commit a
  Path, or the committed Path lacks `jas:tool-origin == "blob_brush"`.
- **P1 — core.** Painting commits a filled swept region. Erase
  deletes / modifies only `jas:tool-origin == "blob_brush"`
  elements. Multi-element merge unions into a single Path at the
  lowest matching z-index.
- **P2 — edge & polish.** Option controls, runtime tip resolution
  from active Calligraphic brush, overrides, undo, overlay, dialog
  persistence, appearance theming.

---

## Session table of contents

| Session | Topic                                     | Est.  | IDs        |
|---------|-------------------------------------------|-------|------------|
| A       | Smoke & lifecycle                         | ~4m   | 001–009    |
| B       | Draw a blob stroke (painting)             | ~6m   | 010–029    |
| C       | Fidelity slider                           | ~4m   | 030–049    |
| D       | Runtime tip resolution                    | ~6m   | 050–069    |
| E       | Merge (single + multi-element)            | ~8m   | 070–099    |
| F       | Erase gesture                             | ~8m   | 100–119    |
| G       | Cursor + drag overlay                     | ~4m   | 130–149    |
| H       | Options dialog & state persistence        | ~5m   | 150–169    |
| I       | Cross-app parity                          | ~12m  | 200–229    |

Full pass: ~57 min.

---

## Session A — Smoke & lifecycle (~4 min)

- [ ] **BB-001** [wired] Blob Brush tool activates from the toolbox.
      Do: Long-press Pencil slot, choose Blob Brush from the popup.
      Expect: Blob Brush tool active; icon swaps to the blob-brush
      glyph (handle + ferrule + filled oval tip + filled blob
      trail).
      — last: —

- [ ] **BB-002** [wired] Tool icon is visibly distinct from Pencil
      and Paintbrush.
      Do: Compare Pencil, Paintbrush, Blob Brush icons side-by-side
      in the pencil slot's long-press menu.
      Expect: Pencil = sharp point, Paintbrush = bristled tip with
      white highlights, Blob Brush = filled oval tip plus wavy
      filled trail.
      — last: —

- [ ] **BB-003** [wired] Switching away clears any drag buffer.
      Do: Blob Brush, press-and-hold, drag partway, then switch to
      Selection (V) without releasing.
      Expect: No ghost overlay; no phantom path committed.
      — last: —

- [ ] **BB-004** [wired] Escape mid-drag discards the gesture.
      Do: Start a drag, hit Esc before release.
      Expect: Overlay clears, no path added, no undo entry pushed.
      — last: —

---

## Session B — Draw a blob stroke (painting) (~6 min)

- [ ] **BB-010** [wired] **P0.** Basic press/drag/release commits a
      Path with `jas:tool-origin == "blob_brush"`.
      Do: Drag a freehand stroke.
      Expect: One Path element appended; inspecting its attributes
      shows `jas:tool-origin = "blob_brush"`.
      — last: —

- [ ] **BB-011** [wired] **P0.** Commit has fill set, no stroke.
      Do: Set fill color to a distinct hue. Draw a stroke.
      Expect: Committed path has `fill = <chosen hue>`,
      `stroke = none`.
      — last: —

- [ ] **BB-012** [wired] Commit renders as a filled region, not a
      stroked polyline.
      Do: Draw a curve. Zoom in on the committed shape.
      Expect: Solid filled band whose width matches the tip size
      (10 pt by default); no visible outline; no thin-line stroke.
      — last: —

- [ ] **BB-013** [wired] Short sweeps commit a single connected
      region, not disconnected dabs.
      Do: Drag slowly across 40 pt horizontally.
      Expect: One continuous filled band — the arc-length
      subsampler interpolates between mousemove events so dabs
      never leave seams.
      — last: —

- [ ] **BB-014** [wired] Very fast sweep still commits a connected
      region.
      Do: Drag quickly across the canvas so mousemove events are
      sparse relative to the tip radius.
      Expect: Same continuous filled band — interpolation kicks in.
      — last: —

- [ ] **BB-015** [wired] Zero-length click (no drag) commits
      nothing.
      Do: Single click without dragging.
      Expect: No path added, no undo entry pushed (buffer has < 2
      points, so the commit guard rejects).
      — last: —

- [ ] **BB-016** [wired] Undo removes the committed blob.
      Do: Draw a stroke; press Cmd+Z.
      Expect: Committed Path disappears; document returns to
      pre-stroke state.
      — last: —

---

## Session C — Fidelity slider (~4 min)

_RDP boundary simplification is not yet applied at commit time (see
Known broken). These tests exercise the slider's state handling;
visual-smoothness results will become meaningful once RDP lands._

- [ ] **BB-030** [wired] Default Fidelity = tick 3.
      Do: Verify `state.blob_brush_fidelity == 3` on a fresh load.
      Expect: Value is 3. Corresponding RDP epsilon (spec) = 5.0.
      — last: —

- [ ] **BB-031** [wired] Ticks map to the five expected epsilons.
      Do: Cycle through tick 1..5 in the Options dialog; note
      the associated Accurate/Smooth label at each end.
      Expect: Tick 1 = Accurate (ε 0.5), tick 5 = Smooth (ε 10.0);
      ticks 2/3/4 untitled. The label updates as you move the
      slider.
      — last: —

- [ ] **BB-032** [pending, blocked by RDP] Tick 1 preserves more
      boundary detail than tick 5.
      Do: Draw a jittery swept path at tick 1; undo; re-draw the
      same shape at tick 5.
      Expect (post-RDP): tick-1 commit has more boundary segments
      than tick-5. Pre-RDP: no visible difference; mark as pending.
      — last: —

---

## Session D — Runtime tip resolution (~6 min)

- [ ] **BB-050** [wired] No active brush → dialog defaults drive
      the tip.
      Do: In Brushes panel: Remove Brush Stroke (clears
      `state.stroke_brush`). Draw a stroke with
      `blob_brush_size = 20`.
      Expect: Committed band is ~20 pt wide.
      — last: —

- [ ] **BB-051** [wired] Active Calligraphic brush → its size /
      angle / roundness drive the tip.
      Do: Select a Calligraphic brush with `size = 8`, `angle = 30`,
      `roundness = 50`. Draw a short horizontal sweep.
      Expect: Committed band is 8 pt wide along the tip's minor
      axis, with the oval rotated 30° from horizontal; the band's
      envelope reflects a rotated, flattened oval.
      — last: —

- [ ] **BB-052** [wired] Non-Calligraphic active brush → dialog
      defaults drive the tip.
      Do: Select an Art brush (no `size` field on the brush's
      record). Set `blob_brush_size = 14`. Draw.
      Expect: Committed band is ~14 pt wide. The Art brush's own
      thumbnail shape has no effect.
      — last: —

- [ ] **BB-053** [wired] `state.stroke_brush_overrides.size` wins
      over brush.size.
      Do: Select a Calligraphic brush with `size = 4`. Set
      `state.stroke_brush_overrides = {"size": 12}`. Draw.
      Expect: Committed band is ~12 pt wide.
      — last: —

- [ ] **BB-054** [wired] `brush_type_of(state.stroke_brush)` gates
      the dialog rows.
      Do: Open Blob Brush Tool Options. Switch the active brush
      between Calligraphic and Art via the Brushes panel, watching
      the dialog's Size / Angle / Roundness rows.
      Expect: Rows are disabled (grayed with "(set by active brush)"
      hint) when Calligraphic is active; enabled otherwise.
      — last: —

---

## Session E — Merge (single + multi-element) (~8 min)

- [ ] **BB-070** [wired] **P1.** Overlapping stroke with matching
      fill merges into existing Blob Brush element.
      Do: Draw stroke A with fill `#ff0000`. Draw stroke B with
      fill `#ff0000` overlapping A.
      Expect: Only one Path element in the layer (A + B unioned);
      `jas:tool-origin = "blob_brush"` preserved; `fill = #ff0000`.
      — last: —

- [ ] **BB-071** [wired] Non-overlapping stroke with matching fill
      does NOT merge.
      Do: Draw stroke A with fill `#ff0000`. Draw disjoint stroke
      B with fill `#ff0000` on the other side of the canvas.
      Expect: Two separate Path elements.
      — last: —

- [ ] **BB-072** [wired] Overlapping stroke with different fill
      color does NOT merge.
      Do: Draw stroke A with fill `#ff0000`. Change fill to
      `#00ff00`. Draw stroke B overlapping A.
      Expect: Two separate Path elements, each with its own fill.
      — last: —

- [ ] **BB-073** [wired] **P1.** Overlapping stroke touching N
      blob-brush elements unions all N with the sweep into one
      Path at the lowest matching z-index.
      Do: Draw A (bottom), B (above A), C (above B), all with the
      same fill `#ff0000`, positioned so they form a short chain.
      Draw D that overlaps all three.
      Expect: A, B, C removed; a single merged Path inserted at
      A's original child index (lowest); still carrying
      `jas:tool-origin = "blob_brush"`; `fill = #ff0000`.
      — last: —

- [ ] **BB-074** [wired] Non-blob-brush overlapping Path is NOT
      merged.
      Do: Draw a Pencil path with fill `#ff0000`. Draw a Blob
      Brush stroke overlapping it with fill `#ff0000`.
      Expect: Pencil path untouched. New Blob Brush Path element
      added independently.
      — last: —

- [ ] **BB-075** [wired] `blob_brush_merge_only_with_selection =
      true` scopes merge to selected blob-brush elements.
      Do: Draw strokes A and B (same fill, non-overlapping). Select
      A only. Set `blob_brush_merge_only_with_selection = true`.
      Draw a C that overlaps *both* A and B.
      Expect: A is merged with C; B is untouched. Two Path elements
      remain (A+C merged, B).
      — last: —

- [ ] **BB-076** [pending, blocked] `blob_brush_keep_selected =
      true` selects the merged element after commit.
      Do: Set the option. Draw a stroke.
      Expect (once wired): committed Path is selected. Currently:
      selection unchanged; track as pending.
      — last: —

---

## Session F — Erase gesture (~8 min)

- [ ] **BB-100** [wired] **P0.** Alt held at press enters erasing
      mode.
      Do: Hold Alt, press on a blob-brush element, drag across it,
      release.
      Expect: Swept region removed from the element. No new Path
      added.
      — last: —

- [ ] **BB-101** [wired] **P1.** Erase fully-covering a blob-brush
      element removes it.
      Do: Hold Alt, drag a sweep that fully covers an existing
      small blob-brush element.
      Expect: Element removed from the document. Layer has one
      fewer child.
      — last: —

- [ ] **BB-102** [wired] Erase partially covering splits /
      resizes the remainder in place.
      Do: Draw a wide blob. Hold Alt, drag a sweep through its
      middle.
      Expect: Original Path's `d` updated to the subtraction
      remainder; `jas:tool-origin`, fill, etc. preserved. Element
      count unchanged (one Path, one or two subpaths).
      — last: —

- [ ] **BB-103** [wired] Erase into multiple disjoint rings emits
      one Path with multiple subpaths.
      Do: Draw a wide blob. Hold Alt, drag an erase gesture
      through it that splits it into two disjoint pieces.
      Expect: Still one Path element; `d` has two
      `MoveTo … ClosePath` subpaths.
      — last: —

- [ ] **BB-104** [wired] **P1.** Erase does NOT touch non-
      blob-brush elements.
      Do: Draw a Pencil path. Hold Alt, drag an erase gesture
      covering it.
      Expect: Pencil path unchanged. No elements modified.
      — last: —

- [ ] **BB-105** [wired] Erase ignores fill color (blunter than
      merge).
      Do: Draw blob A with fill `#ff0000`. Change fill to
      `#00ff00`. Hold Alt and drag over A.
      Expect: A is subtracted-from / deleted regardless of the
      current fill color.
      — last: —

- [ ] **BB-106** [wired] Erase on empty canvas is a no-op.
      Do: Hold Alt, drag across empty space.
      Expect: No undo entry pushed; document unchanged.
      — last: —

- [ ] **BB-107** [wired] Undo reverts an erase.
      Do: Draw blob A. Erase A fully. Press Cmd+Z.
      Expect: A restored to pre-erase state.
      — last: —

---

## Session G — Cursor + drag overlay (~4 min)

_Rust + Swift only. OCaml + Python show the platform default
cursor and no drag preview (Phase-5a stub)._

- [ ] **BB-130** [wired] **P2.** Hover cursor = oval outline +
      center crosshair; OS cursor hidden.
      Do: Move the pointer over the canvas without clicking.
      Expect: 1-px-stroke oval at the pointer position matching
      the effective tip (size / angle / roundness); small
      crosshair at the center for precision aiming; system cursor
      hidden.
      — last: —

- [ ] **BB-131** [wired] Alt-held hover → dashed oval outline.
      Do: Hold Alt, move the pointer over the canvas (no drag).
      Expect: Same oval but stroked dashed (e.g. `[4, 4]`
      pattern) — erase-mode signal.
      — last: —

- [ ] **BB-132** [wired] Painting drag → semi-transparent filled
      oval at each buffered sample.
      Do: Press and drag. Watch the trail.
      Expect: Each drag sample draws as a semi-transparent filled
      oval in `state.fill_color` (alpha ~0.3); overlapping dabs
      composite; coverage visible cheaply.
      — last: —

- [ ] **BB-133** [wired] Erasing drag → dashed-outline ovals
      (fill: none).
      Do: Hold Alt, press and drag.
      Expect: Each sample draws as a dashed outline (no fill) in
      `state.fill_color`.
      — last: —

---

## Session H — Options dialog & state persistence (~5 min)

- [ ] **BB-150** [wired] Double-click the Blob Brush icon opens
      the Options dialog.
      Do: Double-click the toolbar icon.
      Expect: Dialog shows Fidelity slider (5-stop), Keep Selected
      checkbox, Merge Only With Selection checkbox, Size / Angle /
      Roundness variation widgets, and Reset / Cancel / OK
      buttons.
      — last: —

- [ ] **BB-151** [wired] Size / Angle / Roundness rows disable
      when a Calligraphic brush is active.
      Do: Select a Calligraphic brush. Open the Options dialog.
      Expect: Size / Angle / Roundness rows grayed out with
      "(set by active brush)" hint. Fidelity / Keep Selected /
      Merge Only With Selection remain enabled.
      — last: —

- [ ] **BB-152** [wired] OK writes dialog values to
      `state.blob_brush_*`.
      Do: Change Fidelity to 5, Size base to 20, click OK.
      Inspect state.
      Expect: `state.blob_brush_fidelity == 5`;
      `state.blob_brush_size == 20`.
      — last: —

- [ ] **BB-153** [wired] Cancel discards edits.
      Do: Change values, click Cancel.
      Expect: `state.blob_brush_*` unchanged.
      — last: —

- [ ] **BB-154** [wired] Reset restores spec defaults without
      committing.
      Do: Change several values, click Reset.
      Expect: Dialog shows defaults (fidelity 3, keep_selected
      false, merge_only_with_selection false, size 10, angle 0,
      roundness 100, all `fixed` variation modes); state unchanged
      until OK.
      — last: —

---

## Session I — Cross-app parity (~12 min)

Re-run a core subset (BB-010, BB-011, BB-050, BB-051, BB-070,
BB-073, BB-100, BB-101, BB-104) on each of:

| Platform | Notes                                                    |
|----------|----------------------------------------------------------|
| Rust     | Reference. Full coverage above.                          |
| Swift    | All sessions in scope.                                   |
| OCaml    | All sessions in scope **except G** (overlay stub).       |
| Python   | All sessions in scope **except G** (overlay stub).       |
| Flask    | Tool not implemented; skip entire suite.                 |

- [ ] **BB-200 .. 229** — per-platform parity results, one entry
      per (platform × core-subset test). Mark [wired] when
      confirmed.
      — last: —

---

## Coverage matrix (tier × session)

|              | A | B | C | D | E | F | G | H | I |
|--------------|---|---|---|---|---|---|---|---|---|
| P0           | — | 2 | — | — | — | 1 | — | — | — |
| P1           | 4 | 5 | 1 | 5 | 5 | 7 | — | — | — |
| P2           | — | — | 2 | — | 1 | — | 4 | 5 | — |

---

## Observed bugs (append only)

_None yet._
