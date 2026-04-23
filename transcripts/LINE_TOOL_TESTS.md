# Line Tool — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/line.yaml`. Design doc: `transcripts/LINE_TOOL.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other platforms
covered in Session E parity sweep.

---

## Known broken

_Last reviewed: 2026-04-23_

_No known-broken tests._ Shift-constrained angles and create-time arrowheads
are **not-yet-implemented** (tracked as ENH entries, not regressions).

---

## Automation coverage

_Last synced: 2026-04-23_

**Python — `jas/tools/yaml_tool_test.py::TestDispatch`** (~11 tests)
- ToolSpec parsing + dispatch pipeline; the Line handler-YAML exercises
  the same path (mousedown → drag → mouseup with `doc.add_element`).
- Hypot > 2 guard is covered generically by the drawing-tool validation
  block.

**Swift — `JasSwift/Tests/Tools/YamlToolLineTests.swift`**
- Press / drag / release creates a Line; zero-length suppression; default
  stroke applied; Escape cancels.

**OCaml — `jas_ocaml/test/tools/yaml_tool_line_test.ml`**
- Mirror of the Python / Swift flow; Alcotest cases covering non-zero-length
  commit + hypot suppression.

**Rust — `jas_dioxus/src/tools/yaml_tool.rs` (#[cfg(test)])**
- Reference implementation. Line handler exercised by inline cases for
  press/drag/release pipeline and zero-length suppression.

**Flask — no coverage.** Canvas tool runtime is native-apps-only.

The manual suite below covers what auto-tests cannot reach: overlay
appearance, cursor glyph, stroke default picked up live, cross-tool
interactions, undo visible on canvas, appearance theming.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document.
3. Appearance: **Dark**.
4. Line tool active (press `\`).

When a test calls for a **default stroke**: ensure the Stroke panel reads
1 pt, opaque black. If the workspace default differs, prefer observed
values over specific numbers in Expect lines.

---

## Tier definitions

- **P0 — existential.** Tool doesn't draw, crashes, or ghosts. 5-minute
  smoke confidence.
- **P1 — core.** Press / drag / release produces the expected Line.
- **P2 — edge & polish.** Overlay styling, cursor, tolerance, undo,
  appearance theming.

---

## Session table of contents

| Session | Topic                             | Est.  | IDs      |
|---------|-----------------------------------|-------|----------|
| A       | Smoke & lifecycle                 | ~5m   | 001–009  |
| B       | Draw a line                       | ~6m   | 010–029  |
| C       | Stroke / fill wiring              | ~5m   | 030–049  |
| D       | Escape, cancel, undo              | ~5m   | 050–069  |
| E       | Overlay, cursor, theming          | ~5m   | 070–089  |
| F       | Cross-app parity                  | ~10m  | 200–219  |

Full pass: ~35 min.

---

## Session A — Smoke & lifecycle (~5 min)

If any P0 here fails, stop and flag.

- [ ] **LIN-001** [wired] Line tool activates via `\` shortcut.
      Do: Press `\`.
      Expect: Line tool becomes active; cursor becomes crosshair over
              the canvas.
      — last: —

- [ ] **LIN-002** [wired] Line tool activates via toolbox icon.
      Do: Click the Line icon in the toolbox.
      Expect: Active state on the icon; canvas cursor crosshair.
      — last: —

- [ ] **LIN-003** [wired] Switching away and back preserves tool
  functionality.
      Do: Press V, then press `\` again.
      Expect: Line tool is clean; a subsequent press-drag-release on
              the canvas creates a line.
      — last: —

---

## Session B — Draw a line (~6 min)

**P0**

- [ ] **LIN-010** [wired] Press-drag-release commits a Line element.
      Do: Press at (100,100); drag to (300,200); release.
      Expect: A new Line element appears on the canvas from (100,100)
              to (300,200); the overlay preview vanishes.
      — last: —

- [ ] **LIN-011** [wired] Zero-length click does not deposit a line.
      Do: Press and release at the same point without moving.
      Expect: No Line element is created; no stray zero-length line in
              the document.
      — last: —

- [ ] **LIN-012** [wired] Lines shorter than the hypot=2 guard are
  suppressed.
      Do: Press at (100,100); drag to (101,101) (hypot ≈ 1.4); release.
      Expect: No Line element created.
      — last: —

**P1**

- [ ] **LIN-013** [wired] Lines just above the hypot=2 guard commit.
      Do: Press at (100,100); drag to (103,103) (hypot ≈ 4.2); release.
      Expect: A Line element is created (just above threshold).
      — last: —

- [ ] **LIN-014** [wired] Dragging up-and-left commits correctly.
      Do: Press at (300,300); drag to (100,100); release.
      Expect: Line endpoints honor the drag direction (start at 300,300;
              end at 100,100). Visual segment is unchanged by order.
      — last: —

- [ ] **LIN-015** [wired] Successive lines accumulate on the canvas.
      Do: Draw three distinct lines in sequence.
      Expect: All three remain on the canvas; each creation was its own
              commit.
      — last: —

---

## Session C — Stroke / fill wiring (~5 min)

**P1**

- [ ] **LIN-030** [wired] New Line picks up `model.default_stroke`.
      Setup: Set Stroke panel to red 3 pt.
      Do: Draw any line.
      Expect: The new line renders red at 3 pt width.
      — last: —

- [ ] **LIN-031** [wired] Line elements carry no fill.
      Do: Draw a line; open the Fill panel with the line selected.
      Expect: Fill is None / N-A for the line (per design — line
              elements only carry stroke).
      — last: —

**P2**

- [ ] **LIN-032** [wired] Default stroke change between lines takes
  effect.
      Setup: Set stroke to black; draw line #1. Set stroke to blue;
             draw line #2.
      Do: Compare the two lines.
      Expect: Line #1 is black, line #2 is blue. Each commit snapshot
              picks up the stroke at release time.
      — last: —

---

## Session D — Escape, cancel, undo (~5 min)

**P1**

- [ ] **LIN-050** [wired] Esc during drag cancels without committing.
      Do: Press at (100,100); drag to (200,200); press Esc while still
          holding the mouse; release.
      Expect: No Line element created; overlay preview disappears.
      — last: —

- [ ] **LIN-051** [wired] Undo removes the last line.
      Setup: Draw a single line.
      Do: Ctrl/Cmd-Z.
      Expect: Line is removed from the document; redo (Ctrl/Cmd-Shift-Z)
              restores it.
      — last: —

- [ ] **LIN-052** [wired] Switching tools mid-drag commits or cancels
  cleanly.
      Do: Press at (100,100); drag to (200,200); press V while still
          holding.
      Expect: No crash; no half-drawn ghost line; either the line
              commits or the gesture is abandoned, consistently.
      — last: —

---

## Session E — Overlay, cursor, theming (~5 min)

**P2**

- [ ] **LIN-070** [wired] Overlay is a thin dashed preview.
      Setup: Begin a line drag and hold.
      Expect: Preview line from start to cursor is dashed
              (stroke-dasharray 4 4), 1 px width at 50% opacity, no
              fill.
      — last: —

- [ ] **LIN-071** [wired] Cursor is crosshair over canvas during this
  tool.
      Do: Observe the cursor glyph.
      Expect: Crosshair (or the app's platform-specific crosshair
              substitute); not the arrow.
      — last: —

- [ ] **LIN-072** [wired] Preview disappears on release.
      Do: Complete any line draw.
      Expect: Dashed preview vanishes; committed line replaces it.
      — last: —

- [ ] **LIN-073** [wired] Preview visible on Medium Gray appearance.
      Setup: Medium Gray theme.
      Do: Begin a drag.
      Expect: Dashed preview still visible against the gray canvas.
      — last: —

- [ ] **LIN-074** [wired] Preview visible on Light Gray appearance.
      Setup: Light Gray theme.
      Do: Begin a drag.
      Expect: Same readability on a light canvas.
      — last: —

---

## Cross-app parity — Session F (~10 min)

~4 load-bearing tests. Batch by app.

- **LIN-200** [wired] Press-drag-release creates a Line identically in
  every app.
      Do: Press (100,100); drag to (300,200); release.
      Expect: One Line element with those exact endpoints.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **LIN-201** [wired] Zero-length click is suppressed in every app.
      Do: Press and release without moving.
      Expect: No Line element in any app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **LIN-202** [wired] Hypot-2 boundary matches in every app.
      Do: Press (100,100); drag to (101,101); release.
      Expect: No Line element (same suppression threshold in every app).
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **LIN-203** [wired] Escape during drag leaves the document unchanged.
      Do: Begin a drag; press Esc.
      Expect: No Line element; no half-open gesture state.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

---

## Graveyard

_No retired tests yet._

---

## Enhancements

- **ENH-001** Shift-constrained angles — native Line tools snap to 0 /
  45 / 90° when Shift is held. Mentioned as a known gap in
  `transcripts/LINE_TOOL.md`. _Raised during LIN-014 on 2026-04-23._

- **ENH-002** Arrowhead-on-create — Line element supports start/end
  arrowheads but the tool always creates plain-stroke lines. Arrowheads
  are currently a Stroke-panel concern post-creation. _Raised during
  LIN-031 on 2026-04-23._
