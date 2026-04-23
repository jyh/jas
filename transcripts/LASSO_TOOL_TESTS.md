# Lasso Tool — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/lasso.yaml`. Design doc:
`transcripts/LASSO_TOOL.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other platforms
covered in Session E parity sweep.

---

## Known broken

_Last reviewed: 2026-04-23_

_No known-broken tests._ Interior-Lasso and sub-group recursion are
**not-yet-implemented** (ENH entries).

---

## Automation coverage

_Last synced: 2026-04-23_

**Python — `workspace_interpreter/point_buffers_test.py`** (if present)
+ `jas/tools/yaml_tool_test.py` dispatch.
- Point buffer push / clear primitives for the `lasso` buffer.
- Dispatch covers the lasso handler YAML through the shared
  validation flow.
- `Controller.select_polygon` hit-test covered in
  `jas/document/controller_test.py` (if present) or
  `jas/document/document_test.py`.

**Swift — `JasSwift/Tests/Tools/YamlToolLassoTests.swift`**
- Press / drag / release → polygon accumulation → selection
  dispatch; Shift-at-press additive semantics; tiny-buffer
  click-to-clear.

**OCaml — `jas_ocaml/test/tools/yaml_tool_lasso_test.ml`**
- Mirror of Python / Swift coverage.

**Rust — `jas_dioxus/src/tools/yaml_tool.rs` (#[cfg(test)])**
- Reference implementation; lasso pipeline inline.

**Flask — no coverage.**

The manual suite below covers overlay appearance (buffer_polygon
render, 0.8-alpha stroke + 0.1-alpha fill), bbox-intersection
intuition, Shift-at-press additive semantics, click-to-clear
edge case, cross-tool interaction, undo.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document.
3. Appearance: **Dark**.
4. Lasso tool active (press `Q`).

Point buffer name = `"lasso"`.

When a test calls for a **3-rect fixture**: same as SELECTION —
rectangles at (50,50,40×40), (150,100,60×40), (260,60,40×60).

---

## Tier definitions

- **P0 — existential.** Tool doesn't activate or doesn't select.
- **P1 — core.** Freehand polygon → releases → selection replaces or
  unions with the prior state.
- **P2 — edge & polish.** Overlay styling, tiny-buffer click-to-clear,
  bbox-crossing vs enclosed, cross-tool handoff, appearance
  theming, undo.

---

## Session table of contents

| Session | Topic                                 | Est.  | IDs      |
|---------|---------------------------------------|-------|----------|
| A       | Smoke & lifecycle                     | ~4m   | 001–009  |
| B       | Lasso a single element                | ~6m   | 010–029  |
| C       | Lasso multiple elements               | ~5m   | 030–049  |
| D       | Shift-at-press additive               | ~5m   | 050–069  |
| E       | Cross-app parity                      | ~10m  | 200–219  |

Full pass: ~30 min.

---

## Session A — Smoke & lifecycle (~4 min)

- [ ] **LAS-001** [wired] Lasso activates via `Q` shortcut.
      Do: Press Q.
      Expect: Lasso active; crosshair cursor.
      — last: —

- [ ] **LAS-002** [wired] Lasso activates via toolbox icon.
      Do: Click Lasso icon.
      Expect: Active; crosshair.
      — last: —

---

## Session B — Lasso a single element (~6 min)

**P0**

- [ ] **LAS-010** [wired] Drag enclosing an element selects it.
      Setup: 3-rect fixture; nothing selected.
      Do: Press somewhere above the left rect; drag around it back
          to the start; release.
      Expect: The left rect becomes selected; other two aren't.
              Overlay polygon disappears on release.
      — last: —

- [ ] **LAS-011** [wired] Polygon crossing a rect's bbox still selects
  it.
      Setup: 3-rect fixture.
      Do: Drag a polygon that cuts through (but doesn't fully
          enclose) the middle rect.
      Expect: Middle rect selects — crossing is sufficient per the
              bbox-intersection hit-test.
      — last: —

- [ ] **LAS-012** [wired] Click (tiny buffer) without Shift clears
  the selection.
      Setup: Left rect selected.
      Do: Click empty canvas with Lasso (press and release without
          drag).
      Expect: Selection clears — tiny buffer + no Shift = click-in-
              empty semantics.
      — last: —

**P1**

- [ ] **LAS-013** [wired] Drag with < 3 total points treated as click.
      Setup: Left rect selected.
      Do: Press, move 1-2 px, release.
      Expect: Treated as click-clear (LAS-012 semantics).
      — last: —

- [ ] **LAS-014** [wired] Release with ≥ 3 points commits selection.
      Setup: No selection.
      Do: Drag a triangle-sized polygon around an element.
      Expect: Element selects.
      — last: —

---

## Session C — Lasso multiple elements (~5 min)

**P1**

- [ ] **LAS-030** [wired] Enclosing multiple rects selects all of
  them.
      Setup: 3-rect fixture.
      Do: Drag a big polygon around all three rects; release.
      Expect: All three rects select.
      — last: —

- [ ] **LAS-031** [wired] Non-additive lasso replaces the prior
  selection.
      Setup: Middle rect selected.
      Do: Lasso around the right rect (no Shift).
      Expect: Middle deselects; right rect selects alone.
      — last: —

**P2**

- [ ] **LAS-032** [wired] Concave lasso shape still selects correctly.
      Setup: 3-rect fixture.
      Do: Draw a concave U-shaped polygon that encloses the left and
          right rects but not the middle.
      Expect: Only the left and right rects select.
      — last: —

---

## Session D — Shift-at-press additive (~5 min)

**P1**

- [ ] **LAS-050** [wired] Shift-at-press adds to the prior selection.
      Setup: Middle rect selected.
      Do: Hold Shift; press empty space; drag around the right rect;
          release.
      Expect: Middle AND right rects selected (union).
      — last: —

- [ ] **LAS-051** [wired] Shift captured at press; release Shift
  mid-drag doesn't change it.
      Setup: Middle rect selected.
      Do: Shift-press; release Shift keys; drag around the right
          rect; release.
      Expect: Still additive — Middle AND right selected.
      — last: —

- [ ] **LAS-052** [wired] Shift-click (tiny buffer) leaves selection
  unchanged.
      Setup: Middle rect selected.
      Do: Shift-press and release empty space without drag.
      Expect: Selection unchanged.
      — last: —

**P2**

- [ ] **LAS-053** [wired] Non-Shift click clears even when prior
  selection is non-empty.
      Setup: Middle rect selected.
      Do: Press-and-release empty space (no drag, no Shift).
      Expect: Selection cleared.
      — last: —

---

## Cross-app parity — Session E (~10 min)

- **LAS-200** [wired] Lasso around an element selects exactly it.
      Do: 3-rect fixture; lasso around the left rect.
      Expect: Selection size 1, path points at the left rect, in
              every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **LAS-201** [wired] Crossing lasso still selects (not-fully-
  enclosed).
      Do: Drag a polygon that cuts through the middle rect's bbox.
      Expect: Middle rect selects in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **LAS-202** [wired] Tiny buffer (<3 pts) without Shift clears.
      Do: Click empty space with Lasso.
      Expect: Selection cleared in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **LAS-203** [wired] Shift-at-press additive; released Shift
  mid-drag stays additive.
      Do: Shift-press; release Shift mid-drag; lasso around.
      Expect: Additive in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **LAS-204** [wired] Buffer_polygon overlay visible during drag.
      Do: Begin a lasso drag.
      Expect: Outlined filled polygon overlay visible in all four
              apps.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

---

## Graveyard

_No retired tests yet._

---

## Enhancements

- **ENH-001** Interior-Lasso — freehand counterpart of Interior
  Selection; selects individual control points rather than whole
  elements. _Raised during LAS-010 on 2026-04-23._

- **ENH-002** Sub-group recursion — lasso recurses into Groups, like
  Interior Selection does. Today it walks only top-level layer
  children. _Raised during LAS-010 on 2026-04-23._

- **ENH-003** Minimum-distance vertex filter — densely-sampled drags
  produce huge buffers; a 1 pt inter-sample filter would reduce
  memory and downstream hit-test cost with no visible quality loss.
  _Raised during LAS-014 on 2026-04-23._
