# Rect / Rounded Rect Tool — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/rect.yaml`, `workspace/tools/rounded_rect.yaml`.
Design doc: `transcripts/RECT_TOOL.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other platforms
covered in Session F parity sweep.

---

## Known broken

_Last reviewed: 2026-04-23_

_No known-broken tests._ Shift-to-square and Alt-from-center are
**not-yet-implemented** (ENH entries, not regressions).

---

## Automation coverage

_Last synced: 2026-04-23_

**Python — `jas/tools/yaml_tool_test.py::TestDispatch`** (~11 tests)
- ToolSpec parsing + dispatch pipeline; rect handler-YAML exercised by
  `test_dispatches_doc_effects` which runs `doc.add_element` for a Rect.

**Swift — `JasSwift/Tests/Tools/YamlToolRectTests.swift`**
- Rect commit with normalized bbox; zero-size suppression; default
  fill + stroke applied; rounded variant writes rx/ry.

**OCaml — `jas_ocaml/test/tools/yaml_tool_rect_test.ml`**
- Mirror of the Python / Swift coverage.

**Rust — `jas_dioxus/src/tools/yaml_tool.rs` (#[cfg(test)])**
- Reference implementation; rect + rounded-rect committing paths inline.

**Flask — `jas_flask/tests/js/test_phase12.mjs`** (~7 tests)
- doc.add_element appends a rect, resolves expression-valued geometry,
  applies state.fill_color / stroke_color / stroke_width defaults when
  the spec omits them.
- Plus engine-level coverage of the buffer / point primitives the
  rounded-rect tool would also use (see `tests/js/test_canvas.mjs`).

The manual suite below covers overlay appearance (including rx/ry in
the preview), cursor glyph, default fill / stroke picked up live, tool
lifecycle, undo visible on canvas, appearance theming.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document.
3. Appearance: **Dark**.
4. Rect tool active (press `M`).

For rounded-rect tests, press `E` (note: path eraser currently shares
`E` — resolve per workspace YAML if conflicted).

---

## Tier definitions

- **P0 — existential.** Tool doesn't draw or crashes. 5-minute smoke
  confidence.
- **P1 — core.** Press / drag / release produces the expected Rect;
  radii correct for rounded variant.
- **P2 — edge & polish.** Overlay styling, cursor, tolerance, undo,
  appearance theming.

---

## Session table of contents

| Session | Topic                                 | Est.  | IDs      |
|---------|---------------------------------------|-------|----------|
| A       | Smoke & lifecycle                     | ~5m   | 001–009  |
| B       | Draw a rect (plain)                   | ~6m   | 010–029  |
| C       | Draw a rounded rect                   | ~5m   | 030–049  |
| D       | Fill / stroke wiring                  | ~5m   | 050–069  |
| E       | Escape, cancel, undo, overlay         | ~6m   | 070–089  |
| F       | Cross-app parity                      | ~10m  | 200–219  |

Full pass: ~40 min.

---

## Session A — Smoke & lifecycle (~5 min)

If any P0 here fails, stop and flag.

- [ ] **RCT-001** [wired] Rect tool activates via `M` shortcut.
      Do: Press M.
      Expect: Rect tool becomes active; cursor becomes crosshair over
              canvas.
      — last: —

- [ ] **RCT-002** [wired] Rounded Rect activates via `E` shortcut.
      Do: Press E.
      Expect: Rounded Rect tool active (or Path Eraser, per workspace
              conflict resolution); rounded variant works either way
              from the toolbox.
      — last: —

- [ ] **RCT-003** [wired] Rect tool icon activates via toolbox.
      Do: Click the Rect icon.
      Expect: Icon shows active; cursor crosshair.
      — last: —

- [ ] **RCT-004** [wired] Rounded Rect icon activates via toolbox.
      Do: Click the Rounded Rect icon.
      Expect: Active state; crosshair.
      — last: —

---

## Session B — Draw a rect (plain) (~6 min)

**P0**

- [ ] **RCT-010** [wired] Press-drag-release commits a Rect element.
      Do: Rect tool; press at (100,100); drag to (300,250); release.
      Expect: A new Rect element appears with x=100, y=100, w=200,
              h=150; preview disappears.
      — last: —

- [ ] **RCT-011** [wired] Zero-size click is suppressed.
      Do: Press and release at the same point.
      Expect: No Rect element created.
      — last: —

- [ ] **RCT-012** [wired] Sub-1-pt drags are suppressed.
      Do: Press at (100,100); drag to (100.5,100.5); release.
      Expect: No Rect element (fails both-dimension ≥ 1 pt threshold).
      — last: —

**P1**

- [ ] **RCT-013** [wired] Dragging up-and-left normalizes the bbox.
      Do: Press at (300,250); drag to (100,100); release.
      Expect: Rect created with x=100, y=100, w=200, h=150 — normalized
              so w and h are positive.
      — last: —

- [ ] **RCT-014** [wired] rx / ry are zero on plain-Rect commits.
      Do: Draw any rect with the plain Rect tool.
      Expect: Selecting it shows rx=0, ry=0 (sharp corners).
      — last: —

- [ ] **RCT-015** [wired] Successive rects accumulate.
      Do: Draw three rects in different regions.
      Expect: All three present on the canvas; no overwrites.
      — last: —

---

## Session C — Draw a rounded rect (~5 min)

**P0**

- [ ] **RCT-030** [wired] Press-drag-release commits a rounded Rect.
      Do: Rounded Rect tool; press at (100,100); drag to (300,250);
          release.
      Expect: A new Rect element with x=100, y=100, w=200, h=150, **and
              rx=ry=10**; visual shows rounded corners.
      — last: —

- [ ] **RCT-031** [wired] Rounded variant respects the same zero-size
  suppression.
      Do: Click without moving.
      Expect: No element created.
      — last: —

**P1**

- [ ] **RCT-032** [wired] Rounded Rect overlay previews rounded corners.
      Do: Begin a rounded-rect drag and hold.
      Expect: Preview shows a rounded rectangle (not sharp) with
              rx=ry=10 in the preview stroke.
      — last: —

---

## Session D — Fill / stroke wiring (~5 min)

**P1**

- [ ] **RCT-050** [wired] Rect picks up `model.default_fill` at commit.
      Setup: Set Fill panel to orange.
      Do: Draw a rect.
      Expect: The new rect is orange.
      — last: —

- [ ] **RCT-051** [wired] Rect picks up `model.default_stroke` at
  commit.
      Setup: Set Stroke panel to 4 pt black.
      Do: Draw a rect.
      Expect: The new rect has a 4 pt black stroke.
      — last: —

- [ ] **RCT-052** [wired] Default-color change between rects takes
  effect per commit.
      Setup: Draw red rect; set fill to blue; draw another rect.
      Expect: The first rect is red; the second is blue — each picked
              up the fill active at release time.
      — last: —

**P2**

- [ ] **RCT-053** [wired] None-fill + stroke-only also commits.
      Setup: Fill panel = None; Stroke = black.
      Do: Draw a rect.
      Expect: Outline-only rect visible; no fill interior.
      — last: —

---

## Session E — Escape, cancel, undo, overlay (~6 min)

**P1**

- [ ] **RCT-070** [wired] Esc during drag cancels.
      Do: Begin a drag; press Esc; release.
      Expect: No Rect created; preview disappears.
      — last: —

- [ ] **RCT-071** [wired] Undo removes the last rect.
      Do: Draw a rect; Ctrl/Cmd-Z.
      Expect: Rect vanishes from the document; redo restores.
      — last: —

- [ ] **RCT-072** [wired] Switching tools mid-drag doesn't crash.
      Do: Begin a drag; press V; release.
      Expect: No ghost element; no crash.
      — last: —

**P2**

- [ ] **RCT-073** [wired] Rect overlay is a dashed preview.
      Do: Begin a rect drag.
      Expect: Preview uses stroke rgba(0,0,0,0.5), 1 px, dasharray
              4 4, no fill.
      — last: —

- [ ] **RCT-074** [wired] Rect overlay normalizes on up-and-left drag.
      Do: Press at (300,250); drag to (100,100).
      Expect: Preview rectangle covers (100,100)–(300,250) with
              correct normalized dimensions; does not go negative.
      — last: —

- [ ] **RCT-075** [wired] Preview contrasts on Dark / Medium / Light.
      Do: Switch appearance and begin a drag in each.
      Expect: Dashed preview visible against each background.
      — last: —

---

## Cross-app parity — Session F (~10 min)

- **RCT-200** [wired] Rect commit produces matching (x,y,w,h) across
  apps.
      Do: Press (100,100); drag to (300,250); release.
      Expect: Rect with x=100 y=100 w=200 h=150 in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **RCT-201** [wired] Rounded Rect commit produces matching rx/ry=10.
      Do: Rounded Rect; press (0,0); drag to (100,100); release.
      Expect: Rect with x=0 y=0 w=100 h=100 rx=10 ry=10 in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **RCT-202** [wired] Zero-size click is suppressed in every app.
      Do: Press and release without moving.
      Expect: No element created anywhere.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **RCT-203** [wired] Up-and-left drag normalizes the same way across
  apps.
      Do: Press (300,250); drag to (100,100); release.
      Expect: All four apps commit (100,100,200,150) — not (300,250,
              −200,−150).
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **RCT-204** [wired] Escape during drag leaves document unchanged.
      Do: Begin a rect drag; press Esc.
      Expect: No element in any app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

---

## Graveyard

_No retired tests yet._

---

## Enhancements

- **ENH-001** Shift-to-square — constrain to a square when Shift is
  held. Native gap. _Raised during RCT-013 on 2026-04-23._

- **ENH-002** Alt-from-center — draw centered on the press point when
  Alt is held. Native gap. _Raised during RCT-013 on 2026-04-23._

- **ENH-003** Configurable rounded-rect radius — rx=ry=10 is
  hardcoded. Promote to a workspace state key or panel combo, as noted
  in `transcripts/RECT_TOOL.md`. _Raised during RCT-030 on 2026-04-23._
