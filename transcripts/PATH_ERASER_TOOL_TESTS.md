# Path Eraser Tool — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/path_eraser.yaml`. Design doc:
`transcripts/PATH_ERASER_TOOL.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other platforms
covered in Session F parity sweep.

---

## Known broken

_Last reviewed: 2026-04-23_

- **PER-070** [known-broken: PATH_ERASER_TOOL.md §Overlay — not yet
  wired] No `path_eraser_overlay` render type is registered. The
  cursor does not draw the red eraser-radius circle during the drag.
  Adding it is a small follow-up.

- **PER-080** [deferred: PATH_ERASER_TOOL.md §Limitations — closed
  path unwrap] Erasing through a closed path "unwraps" it into an
  open path. The result may lose the visual distinction between
  "closed region" and "open shape around the hole". Users who want
  to preserve closed-region semantics should use Boolean
  subtraction instead.

---

## Automation coverage

_Last synced: 2026-04-23_

**Python — `jas/geometry/path_ops_test.py`** (~8 tests)
- `TestLiangBarsky` — `line_segment_intersects_rect`, t_min / t_max
  entry / exit parameters.
- `TestSplit` — `split_cubic`, `split_cubic_cmd_at` endpoint
  preservation and midpoint math.

**Swift — `JasSwift/Tests/Geometry/PathOpsTests.swift`**
- Mirror of the Python Liang-Barsky + split tests +
  `find_eraser_hit` + `split_path_at_eraser` pipeline.

**OCaml — `jas_ocaml/test/geometry/path_ops_test.ml`**
- Mirror of Python / Swift coverage.

**Rust — `jas_dioxus/src/geometry/path_ops.rs` (#[cfg(test)])**
- Reference kernel implementation with full eraser coverage.

Each app's YamlTool dispatch test also exercises path_eraser handlers
for the press / drag / release pipeline.

**Flask — no coverage.**

The manual suite below covers sweep rectangle intuition, multi-path
behavior, whole-path-fits-inside deletion, curve preservation during
split, selection side-effects, cross-app parity.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document.
3. Appearance: **Dark**.
4. Path Eraser active (press `E` — note shared binding with Rounded
   Rect; resolve per workspace YAML).

`eraser_size = 2` (half-extent of the sweep rectangle).

When a test calls for a **long-path fixture**: Pen tool → draw an
8-anchor horizontal path across the canvas (corners at x=50, 150,
250, 350, 450, 550, 650, 750, all y=200) → Esc.

When a test calls for a **closed-rect fixture**: Rect tool → draw
a single 400×300 rectangle at (100,100).

When a test calls for a **tiny-path fixture**: Pen → draw a
small 2-anchor line at (100,100)–(105,100) (well within 4 px
eraser bbox).

---

## Tier definitions

- **P0 — existential.** Tool doesn't activate or doesn't erase;
  crashes.
- **P1 — core.** Sweep path through an element → split or delete
  as specified.
- **P2 — edge & polish.** Whole-path-fits deletion, multi-path
  sweep, curve preservation, selection side-effects, eraser-size
  tolerance, appearance theming.

---

## Session table of contents

| Session | Topic                                 | Est.  | IDs      |
|---------|---------------------------------------|-------|----------|
| A       | Smoke & lifecycle                     | ~4m   | 001–009  |
| B       | Erase through an open path            | ~8m   | 010–029  |
| C       | Erase a whole path (bbox fits)        | ~5m   | 030–049  |
| D       | Multi-path sweep                      | ~5m   | 050–069  |
| E       | Curve preservation + closed paths     | ~6m   | 070–089  |
| F       | Cross-app parity                      | ~10m  | 200–219  |

Full pass: ~40 min.

---

## Session A — Smoke & lifecycle (~4 min)

- [ ] **PER-001** [wired] Path Eraser activates via toolbox icon.
      Do: Click the Path Eraser icon.
      Expect: Active state; crosshair cursor.
      — last: —

- [ ] **PER-002** [wired] Press-only with no drag commits at press
  point.
      Setup: Long-path fixture.
      Do: Press on the path; release immediately.
      Expect: If within `eraser_size` of the path, a degenerate
              sweep happens and the path may split; if far from
              any path, no change.
      — last: —

---

## Session B — Erase through an open path (~8 min)

**P0**

- [ ] **PER-010** [wired] Sweep through the middle of a long path
  splits it into two.
      Setup: Long-path fixture.
      Do: Press at (400,195); drag to (400,205); release.
      Expect: The path is split into two separate Path elements —
              one covering the left half (x ≤ ~400), one the right
              half (x ≥ ~400); the sweep region has a gap.
      — last: —

- [ ] **PER-011** [wired] Sweep off the path does nothing.
      Setup: Long-path fixture.
      Do: Press at (100,100); drag to (200,100) (well above the
          path at y=200).
      Expect: Document unchanged.
      — last: —

**P1**

- [ ] **PER-012** [wired] Erasing near path-start trims rather than
  splits.
      Setup: Long-path fixture.
      Do: Sweep through the first segment only (near x=50).
      Expect: Path becomes one shorter Path element starting further
              in; no left-half remnant.
      — last: —

- [ ] **PER-013** [wired] Erasing near path-end trims trailing portion.
      Setup: Long-path fixture.
      Do: Sweep through the last segment only (near x=750).
      Expect: Path becomes one shorter Path element ending earlier.
      — last: —

**P2**

- [ ] **PER-014** [wired] Drag through multiple segments produces
  continuous erase.
      Setup: Long-path fixture.
      Do: Drag slowly across most of the path.
      Expect: The entire swept region is removed; if one end
              survives, a single Path remains; if both ends, two
              Paths.
      — last: —

- [ ] **PER-015** [wired] Selection clears as a side effect when any
  path changes.
      Setup: Long-path fixture selected.
      Do: Erase through the middle.
      Expect: Previously-selected path references may no longer
              exist; selection is empty after the erase.
      — last: —

---

## Session C — Erase a whole path (bbox fits) (~5 min)

**P1**

- [ ] **PER-030** [wired] Tiny path fully inside eraser is deleted.
      Setup: Tiny-path fixture.
      Do: Press on it; release.
      Expect: The whole Path element is deleted (bbox ≤ 2×eraser_size
              in both dimensions).
      — last: —

**P2**

- [ ] **PER-031** [wired] Small square at exact bbox threshold is
  deleted.
      Setup: Draw a 4×4 rect (exactly at the threshold).
      Do: Press inside it.
      Expect: Whole rect deleted.
      — last: —

- [ ] **PER-032** [wired] Large path bbox triggers split, not whole
  delete.
      Setup: Long-path fixture (bbox far exceeds 4 px).
      Do: Sweep a small region in the middle.
      Expect: Path splits; is NOT deleted as a whole.
      — last: —

---

## Session D — Multi-path sweep (~5 min)

**P1**

- [ ] **PER-050** [wired] A single drag affects every path it
  crosses.
      Setup: Long-path fixture + another separate small line at
             (400,195)–(400,210).
      Do: Sweep horizontally through both at y=200.
      Expect: Both paths change — long-path splits; small line is
              deleted (bbox fits) or trimmed (if large enough).
      — last: —

**P2**

- [ ] **PER-051** [wired] Locked paths are ignored.
      Setup: Lock a path via the Layers panel.
      Do: Sweep through it.
      Expect: Locked path unchanged; other unlocked paths in the
              sweep are affected normally.
      — last: —

- [ ] **PER-052** [wired] Sweep on empty canvas is a no-op.
      Setup: Empty canvas.
      Do: Drag anywhere.
      Expect: No crash; no change; one undo entry (from the
              snapshot-on-press) — or no entry.
      — last: —

---

## Session E — Curve preservation + closed paths (~6 min)

**P1**

- [ ] **PER-070** [known-broken: no path_eraser_overlay render type]
  No eraser-radius circle at cursor during drag.
      Setup: Long-path fixture.
      Do: Begin a drag; observe the cursor.
      Expect (target): Red outlined circle of radius `eraser_size`
              follows the cursor.
      Expect (current): No circle; cursor is only the crosshair.
      — last: —

- [ ] **PER-071** [wired] Erasing through a cubic-Bezier segment
  preserves the remaining curve shape.
      Setup: Pen → 2 anchors with a drag-smooth middle → Esc.
      Do: Erase near one end.
      Expect: Surviving portion traces the same curve as the
              original (split via De Casteljau — no re-flattening).
      — last: —

**P2**

- [ ] **PER-080** [known-broken: closed-path unwrap limitation]
  Erasing through a closed path produces a single open path around
  the remainder.
      Setup: Closed-rect fixture.
      Do: Sweep through one side.
      Expect (target): Single open Path tracing 3 sides of the rect.
      Expect (current): Result is open but may not read as "rect with
              a gap" visually; fill disappears.
      — last: —

- [ ] **PER-081** [wired] Sweep preserves fill of the resulting split
  paths.
      Setup: A filled closed path.
      Do: Erase through.
      Expect: Resulting split paths retain the original's fill
              (up to the closed-vs-open caveat in PER-080).
      — last: —

---

## Cross-app parity — Session F (~10 min)

- **PER-200** [wired] Split-by-sweep produces matching number of
  resulting paths.
      Do: Long-path fixture; sweep through the middle.
      Expect: 2 Path elements in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **PER-201** [wired] Whole-path-fits deletion triggers consistently.
      Do: Tiny-path fixture; press on it.
      Expect: Path removed in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **PER-202** [wired] Sweep off any path is a no-op in every app.
      Do: Drag far from any element.
      Expect: No change in any app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **PER-203** [wired] Locked paths are untouched in every app.
      Do: Lock; sweep through.
      Expect: Unchanged in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **PER-204** [wired] Selection clears side-effect consistent.
      Do: Select path; sweep.
      Expect: Selection cleared in every app after the erase.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

---

## Graveyard

_No retired tests yet._

---

## Enhancements

- **ENH-001** Wire the `path_eraser_overlay` render type — show a red
  outline circle at cursor of radius `eraser_size`. _Raised during
  PER-070 on 2026-04-23._

- **ENH-002** Closed-path retention — preserve "closed region with
  hole" semantics rather than unwrapping to open paths. Likely
  requires integration with Boolean primitives. _Raised during
  PER-080 on 2026-04-23._

- **ENH-003** Circular eraser shape — non-rectangular sweep, matching
  native Eraser variants. _Raised during PER-010 on 2026-04-23._

- **ENH-004** Pressure-sensitive eraser — `eraser_size` varies with
  tablet pressure. Out of scope for the current tool. _Raised during
  PER-010 on 2026-04-23._

- **ENH-005** Stroked-path thickness awareness — currently the
  algorithm flattens `d` commands, not the rendered stroke extent.
  Very thick strokes aren't fully covered by cursor hits near the
  outer edge. _Raised during PER-014 on 2026-04-23._
