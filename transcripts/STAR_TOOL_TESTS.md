# Star Tool — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/star.yaml`. Design doc: `transcripts/STAR_TOOL.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other platforms
covered in Session E parity sweep.

---

## Known broken

_Last reviewed: 2026-04-23_

_No known-broken tests._ Shift-to-upright and arrow-key point
adjustment are **not-yet-implemented** (ENH entries).

---

## Automation coverage

_Last synced: 2026-04-23_

**Python — `jas/geometry/path_ops_test.py::TestRegularShapes`** (~2 tests)
- `star_points` first-outer-at-top + STAR_INNER_RATIO=0.4 sanity.

**Swift — `JasSwift/Tests/Geometry/RegularShapesTests.swift`**
- Mirror of Python star_points tests.

**OCaml — `jas_ocaml/test/geometry/regular_shapes_test.ml`**
- Mirror of Python / Swift star tests.

**Rust — `jas_dioxus/src/geometry/regular_shapes.rs` (#[cfg(test)])**
- Reference kernel; star_points inline #[test] coverage.

Each app's YamlTool dispatch test suite also covers star commit through
the shared drawing-tool validation flow.

**Flask — no coverage.**

The manual suite below covers overlay appearance, star sharpness
intuition, default fill / stroke wiring, and cross-app vertex geometry
parity.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document.
3. Appearance: **Dark**.
4. Star tool active (select from toolbox — no default shortcut).

Defaults: 5 points; STAR_INNER_RATIO = 0.4.

---

## Tier definitions

- **P0 — existential.** Tool doesn't activate or doesn't commit.
- **P1 — core.** Press / drag / release produces the expected Star;
  10-vertex geometry correct.
- **P2 — edge & polish.** Overlay styling, cursor, tolerance, undo,
  appearance theming.

---

## Session table of contents

| Session | Topic                             | Est.  | IDs      |
|---------|-----------------------------------|-------|----------|
| A       | Smoke & lifecycle                 | ~4m   | 001–009  |
| B       | Draw a star                       | ~6m   | 010–029  |
| C       | Star geometry                     | ~6m   | 030–049  |
| D       | Fill / stroke / undo / overlay    | ~5m   | 050–079  |
| E       | Cross-app parity                  | ~10m  | 200–219  |

Full pass: ~30 min.

---

## Session A — Smoke & lifecycle (~4 min)

- [ ] **STR-001** [wired] Star tool activates via toolbox icon.
      Do: Click the Star icon in the toolbox.
      Expect: Icon active; crosshair cursor over canvas.
      — last: —

- [ ] **STR-002** [wired] Switching away and back preserves state.
      Do: Press V, then reselect Star.
      Expect: Tool clean; next drag commits a star.
      — last: —

---

## Session B — Draw a star (~6 min)

**P0**

- [ ] **STR-010** [wired] Press-drag-release commits a Star (stored as
  Polygon element).
      Do: Press at (100,100); drag to (300,300); release.
      Expect: A new Polygon element with 10 vertices (5 outer + 5
              inner alternating).
      — last: —

- [ ] **STR-011** [wired] Zero-size drag is suppressed.
      Do: Press and release without moving.
      Expect: No element created.
      — last: —

**P1**

- [ ] **STR-012** [wired] First outer vertex sits at top-center.
      Do: Draw a star inscribed in any axis-aligned box.
      Expect: The topmost vertex is an outer (long) point; it sits on
              the vertical midline of the bbox.
      — last: —

- [ ] **STR-013** [wired] Outer / inner vertices alternate.
      Setup: STR-010 result.
      Do: Count vertices in order around the star.
      Expect: Sequence alternates outer-inner-outer-inner…; total 10.
      — last: —

- [ ] **STR-014** [wired] Dragging up-and-left normalizes the bbox.
      Do: Press at (300,300); drag to (100,100); release.
      Expect: Star inscribed in the normalized bbox (100,100)–(300,300);
              orientation unchanged (first outer at top).
      — last: —

---

## Session C — Star geometry (~6 min)

**P1**

- [ ] **STR-030** [wired] Inner vertices sit at 0.4× the outer radius.
      Setup: Square bbox (100,100)–(300,300) — outer radius 100.
      Do: Eyeball inner-vertex distances from the centroid.
      Expect: Inner points about 40 px from center; outers about 100 px.
              Ratio looks like 0.4.
      — last: —

- [ ] **STR-031** [wired] Elongated bbox yields elongated star (not
  scaled).
      Setup: Draw a star in a wide rectangular bbox.
      Do: Eyeball the result.
      Expect: Star is elongated horizontally; outer points lie on an
              ellipse, not a circle.
      — last: —

**P2**

- [ ] **STR-032** [wired] Preview uses the same star_points kernel.
      Do: Drag slowly and watch the preview.
      Expect: Preview vertices track the cursor exactly; release
              produces the same shape.
      — last: —

- [ ] **STR-033** [wired] Vertical-axis-only drag makes a degenerate
  star (zero-width).
      Do: Press (200,100); drag to (200,300); release.
      Expect: Either no commit (dimensions < 1 pt width), or a
              zero-area star that's effectively invisible. No crash.
      — last: —

---

## Session D — Fill / stroke / undo / overlay (~5 min)

**P1**

- [ ] **STR-050** [wired] Star picks up default fill.
      Setup: Fill = orange.
      Do: Draw a star.
      Expect: Orange-filled star.
      — last: —

- [ ] **STR-051** [wired] Star picks up default stroke.
      Setup: Stroke = 3 pt black.
      Do: Draw a star.
      Expect: 3 pt black stroke around the shape.
      — last: —

- [ ] **STR-052** [wired] Esc during drag cancels.
      Do: Begin a drag; press Esc.
      Expect: No element created.
      — last: —

- [ ] **STR-053** [wired] Undo removes the last star.
      Do: Draw star; Ctrl/Cmd-Z.
      Expect: Star removed; redo restores.
      — last: —

**P2**

- [ ] **STR-054** [wired] Overlay is a dashed star preview.
      Do: Begin a drag.
      Expect: Dashed preview star (rgba(0,0,0,0.5), 1 px, 4/4 dash,
              no fill).
      — last: —

- [ ] **STR-055** [wired] Preview updates live as the cursor moves.
      Do: Drag in a wide arc.
      Expect: Preview star grows and shrinks within the changing bbox.
      — last: —

- [ ] **STR-056** [wired] Preview visible on all appearances.
      Do: Switch theme; begin drag in each.
      Expect: Preview readable on Dark / Medium / Light.
      — last: —

---

## Cross-app parity — Session E (~10 min)

- **STR-200** [wired] Star commit produces matching 10 vertices across
  apps.
      Do: Press (0,0); drag to (100,100); release (unit square bbox).
      Expect: Same 10 vertices in every app; first outer at
              (50,0) within 1e-6 tol.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **STR-201** [wired] STAR_INNER_RATIO = 0.4 in every app.
      Do: Inspect the geometry kernel constant.
      Expect: `STAR_INNER_RATIO == 0.4` in all four apps' regular-shapes
              module.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **STR-202** [wired] Zero-size drag is suppressed in every app.
      Do: Press and release at same point.
      Expect: No element in any app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **STR-203** [wired] Overlay previews in every app.
      Do: Begin a star drag.
      Expect: Dashed star preview visible in all four apps.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

---

## Graveyard

_No retired tests yet._

---

## Enhancements

- **ENH-001** Shift-to-upright — keep star upright regardless of drag
  direction when Shift is held. Native gap. _Raised during STR-012
  on 2026-04-23._

- **ENH-002** Arrow-key point-count adjustment — increment points
  with Up, decrement with Down mid-drag. _Raised during STR-032 on
  2026-04-23._

- **ENH-003** Ctrl-adjust inner ratio mid-drag — fine-tune
  STAR_INNER_RATIO live during the drag. _Raised during STR-030 on
  2026-04-23._

- **ENH-004** Star Tool Options dialog — surface point count and
  STAR_INNER_RATIO in a dialog like native Star tools. _Raised during
  STR-030 on 2026-04-23._
