# Polygon Tool — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/polygon.yaml`. Design doc:
`transcripts/POLYGON_TOOL.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other platforms
covered in Session E parity sweep.

---

## Known broken

_Last reviewed: 2026-04-23_

_No known-broken tests._ Shift-constrained first edge and arrow-key
sides are **not-yet-implemented** (ENH entries).

---

## Automation coverage

_Last synced: 2026-04-23_

**Python — `jas/geometry/path_ops_test.py::TestRegularShapes`** (~2 tests)
- `regular_polygon_points` for a triangle and the degenerate same-
  point case.

**Swift — `JasSwift/Tests/Geometry/RegularShapesTests.swift`**
- Mirror of the Python kernel tests.

**OCaml — `jas_ocaml/test/geometry/regular_shapes_test.ml`**
- Mirror of the Python / Swift kernel tests.

**Rust — `jas_dioxus/src/geometry/regular_shapes.rs` (#[cfg(test)])**
- Reference kernel implementation with inline #[test] coverage.

Each app's YamlTool dispatch test suite also covers the polygon commit
path through the shared drawing-tool validation code.

**Flask — no coverage.**

The manual suite below covers overlay appearance, vertex placement
intuition, default fill / stroke wiring, tool lifecycle, and cross-app
vertex geometry parity.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document.
3. Appearance: **Dark**.
4. Polygon tool active (select from toolbox — no default shortcut).

Default `POLYGON_SIDES = 5` (pentagon).

---

## Tier definitions

- **P0 — existential.** Tool doesn't activate or doesn't commit.
- **P1 — core.** Press / drag / release produces the expected Polygon;
  vertex geometry correct.
- **P2 — edge & polish.** Overlay styling, cursor, tolerance, undo,
  appearance theming.

---

## Session table of contents

| Session | Topic                             | Est.  | IDs      |
|---------|-----------------------------------|-------|----------|
| A       | Smoke & lifecycle                 | ~4m   | 001–009  |
| B       | Draw a polygon                    | ~6m   | 010–029  |
| C       | Vertex geometry                   | ~6m   | 030–049  |
| D       | Fill / stroke / undo / overlay    | ~5m   | 050–079  |
| E       | Cross-app parity                  | ~10m  | 200–219  |

Full pass: ~30 min.

---

## Session A — Smoke & lifecycle (~4 min)

- [ ] **POL-001** [wired] Polygon tool activates via toolbox icon.
      Do: Click the Polygon icon in the toolbox.
      Expect: Icon active; crosshair cursor over canvas.
      — last: —

- [ ] **POL-002** [wired] Switching away and back preserves state.
      Do: Press V, then reselect Polygon.
      Expect: Tool is clean; a subsequent drag commits a polygon.
      — last: —

---

## Session B — Draw a polygon (~6 min)

**P0**

- [ ] **POL-010** [wired] Press-drag-release commits a Polygon element.
      Do: Press at (200,200); drag to (300,200); release.
      Expect: A new Polygon element with 5 vertices appears; first
              edge from (200,200) to (300,200).
      — last: —

- [ ] **POL-011** [wired] Zero-length drag is suppressed.
      Do: Press and release at the same point.
      Expect: No Polygon element created.
      — last: —

**P1**

- [ ] **POL-012** [wired] Default side count is 5 (pentagon).
      Do: Draw any polygon.
      Expect: The committed Polygon has exactly 5 vertices (inspect
              via Partial Selection or element panel).
      — last: —

- [ ] **POL-013** [wired] Dragging upward rotates the polygon 90° left.
      Do: Press at (200,200); drag to (200,100); release.
      Expect: First edge runs vertically upward; remaining vertices
              arranged counterclockwise from that edge.
      — last: —

- [ ] **POL-014** [wired] Dragging at 45° places vertices rotated.
      Do: Press at (200,200); drag to (300,100); release.
      Expect: First edge is 45° up-right; polygon tilts to match.
      — last: —

---

## Session C — Vertex geometry (~6 min)

**P1**

- [ ] **POL-030** [wired] Pentagon is regular (all edges equal).
      Setup: POL-010 result.
      Do: Inspect the polygon's computed edge lengths (via a dev tool
          or by selecting + Partial Selection to eyeball equal
          segments).
      Expect: All 5 edges appear equal length.
      — last: —

- [ ] **POL-031** [wired] Centroid lies on perpendicular bisector of
  first edge.
      Setup: Horizontal first edge (POL-010).
      Do: Eyeball the polygon's center relative to the first edge's
          midpoint.
      Expect: Centroid sits directly above (or below) the midpoint,
              perpendicular to the first edge.
      — last: —

**P2**

- [ ] **POL-032** [wired] Triangle variant — if POLYGON_SIDES set to 3
  in workspace, commits a triangle.
      Setup: Edit workspace constant to 3 sides; restart if needed.
      Do: Draw any polygon.
      Expect: 3 vertices; equilateral triangle.
      — last: —

- [ ] **POL-033** [wired] Preview uses the same regular_polygon_points
  kernel as commit.
      Do: Drag slowly and watch the preview.
      Expect: Preview vertex positions track the cursor exactly;
              release produces the same shape.
      — last: —

---

## Session D — Fill / stroke / undo / overlay (~5 min)

**P1**

- [ ] **POL-050** [wired] Polygon picks up default fill.
      Setup: Fill = orange.
      Do: Draw a polygon.
      Expect: Orange-filled polygon.
      — last: —

- [ ] **POL-051** [wired] Polygon picks up default stroke.
      Setup: Stroke = 3 pt black.
      Do: Draw a polygon.
      Expect: 3 pt black stroke around the shape.
      — last: —

- [ ] **POL-052** [wired] Esc during drag cancels.
      Do: Begin a drag; press Esc.
      Expect: No element created.
      — last: —

- [ ] **POL-053** [wired] Undo removes the last polygon.
      Do: Draw a polygon; Ctrl/Cmd-Z.
      Expect: Polygon removed; redo restores.
      — last: —

**P2**

- [ ] **POL-054** [wired] Overlay is a dashed polygon preview.
      Do: Begin a drag.
      Expect: Dashed preview polygon (rgba(0,0,0,0.5), 1 px, 4/4
              dash, no fill) following the cursor.
      — last: —

- [ ] **POL-055** [wired] Preview updates live as the cursor moves.
      Do: Drag in a circular motion.
      Expect: Preview pentagon rotates smoothly to match first-edge
              direction.
      — last: —

- [ ] **POL-056** [wired] Preview visible on all three appearance
  themes.
      Do: Switch appearance and begin a drag in each.
      Expect: Preview readable on Dark / Medium / Light.
      — last: —

---

## Cross-app parity — Session E (~10 min)

- **POL-200** [wired] Polygon commit produces matching vertex list
  across apps.
      Do: Press (0,0); drag to (100,0); release (horizontal first
          edge, pentagon).
      Expect: Same 5 vertices in every app — first at (0,0), second
              at (100,0), remaining three identical within 1e-6 tol.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **POL-201** [wired] Zero-length drag is suppressed in every app.
      Do: Press and release at same point.
      Expect: No element in any app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **POL-202** [wired] Overlay previews in every app during drag.
      Do: Begin a polygon drag.
      Expect: Same dashed polygon preview visible in all four apps.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **POL-203** [wired] Undo removes one polygon in every app.
      Do: Draw polygon; Ctrl/Cmd-Z.
      Expect: Element count returns to pre-draw in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

---

## Graveyard

_No retired tests yet._

---

## Enhancements

- **ENH-001** Shift-constrained first edge — snap first-edge angle to
  0 / 45 / 90° when Shift is held. Native gap per
  `transcripts/POLYGON_TOOL.md`. _Raised during POL-013 on 2026-04-23._

- **ENH-002** Arrow-key side-count change during drag — increment /
  decrement `sides` with Up / Down keys mid-drag. _Raised during
  POL-032 on 2026-04-23._

- **ENH-003** Polygon Options dialog — surface `POLYGON_SIDES` in a
  UI control rather than a workspace constant. _Raised during
  POL-032 on 2026-04-23._
