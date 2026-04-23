# Ellipse Tool — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/ellipse.yaml`. Design doc:
`transcripts/ELLIPSE_TOOL.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other platforms
covered in Session D parity sweep — **all currently deferred** pending
wiring.

---

## Known broken

_Last reviewed: 2026-04-23_

- **ELL-001** [known-broken: ELLIPSE_TOOL.md §Status — not yet wired]
  The Ellipse tool is specified in `workspace/tools/ellipse.yaml` but
  the `ELLIPSE` enum variant is absent from the Toolbar in all four
  native apps (Rust / Swift / OCaml / Python). The tool cannot be
  invoked; every test in this suite is blocked on toolbar wiring + an
  `ellipse` overlay render-type registration.

- **ELL-050** [known-broken: ELLIPSE_TOOL.md §Known gaps — no ellipse
  overlay] Even with the Toolbar entry, the overlay renderer registry
  lacks an `ellipse` case — preview would render nothing. Adding it is
  straightforward per design doc but not yet done.

---

## Automation coverage

_Last synced: 2026-04-23_

**Python — none.** No `yaml_tool_test.py` cases reference ellipse
because the tool isn't registered.

**Swift — none.**

**OCaml — none.**

**Rust — none.**

**Flask — no coverage.**

The yaml spec itself is validated by workspace loader tests in every
app. The tool semantics would borrow the rect validation flow once
wired — rect's press / drag / release / threshold pattern applies
unchanged.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document.
3. Appearance: **Dark**.
4. Ellipse tool active (press `L`).

**Every test below is [placeholder] — activation itself is blocked per
ELL-001.** When the tool is wired, flip the tags from `[placeholder]`
to `[wired]` and retest.

---

## Tier definitions

- **P0 — existential.** Tool doesn't activate, draws nothing, crashes.
- **P1 — core.** Press / drag / release produces the expected Ellipse
  with correct cx/cy/rx/ry.
- **P2 — edge & polish.** Overlay styling, cursor, tolerance, undo,
  appearance theming.

---

## Session table of contents

| Session | Topic                             | Est.  | IDs      |
|---------|-----------------------------------|-------|----------|
| A       | Smoke & lifecycle                 | ~5m   | 001–009  |
| B       | Draw an ellipse                   | ~6m   | 010–029  |
| C       | Fill / stroke / undo / overlay    | ~6m   | 030–059  |
| D       | Cross-app parity                  | ~10m  | 200–219  |

Full pass: ~25 min once wired.

---

## Session A — Smoke & lifecycle (~5 min)

- [ ] **ELL-001** [placeholder] [known-broken: not yet wired] Ellipse
  tool activates via `L` shortcut.
      Do: Press L.
      Expect (target): Ellipse tool becomes active; cursor crosshair.
      Expect (current): Shortcut is unbound or bound to a different
              tool; nothing happens (or another tool activates).
      — last: —

- [ ] **ELL-002** [placeholder] Ellipse tool activates via toolbox icon.
      Do: Click the Ellipse icon.
      Expect (target): Active state on icon; crosshair.
      Expect (current): No Ellipse icon present in the toolbox.
      — last: —

---

## Session B — Draw an ellipse (~6 min)

**P0**

- [ ] **ELL-010** [placeholder] Press-drag-release commits an Ellipse.
      Do: Press at (100,100); drag to (300,200); release.
      Expect (target): Ellipse with cx=200, cy=150, rx=100, ry=50.
      — last: —

- [ ] **ELL-011** [placeholder] Zero-size click is suppressed.
      Do: Press and release at the same point.
      Expect (target): No element created.
      — last: —

**P1**

- [ ] **ELL-012** [placeholder] Sub-1-pt bounding box is suppressed.
      Do: Press at (100,100); drag to (100.5,100.5).
      Expect (target): No element created.
      — last: —

- [ ] **ELL-013** [placeholder] Up-and-left drag normalizes.
      Do: Press (300,250); drag to (100,100); release.
      Expect (target): Ellipse with cx=200, cy=175, rx=100, ry=75.
      — last: —

- [ ] **ELL-014** [placeholder] Successive ellipses accumulate.
      Do: Draw three ellipses in different positions.
      Expect (target): All three present.
      — last: —

---

## Session C — Fill / stroke / undo / overlay (~6 min)

**P1**

- [ ] **ELL-030** [placeholder] Ellipse picks up default fill at commit.
      Setup: Fill panel = orange.
      Do: Draw any ellipse.
      Expect (target): Orange fill on the new ellipse.
      — last: —

- [ ] **ELL-031** [placeholder] Ellipse picks up default stroke.
      Setup: Stroke panel = 4 pt black.
      Do: Draw any ellipse.
      Expect (target): 4 pt black stroke.
      — last: —

- [ ] **ELL-032** [placeholder] Esc during drag cancels.
      Do: Begin a drag; press Esc.
      Expect (target): No element created.
      — last: —

- [ ] **ELL-033** [placeholder] Undo removes the last ellipse.
      Do: Draw ellipse; Ctrl/Cmd-Z.
      Expect (target): Ellipse removed; redo restores.
      — last: —

**P2**

- [ ] **ELL-050** [placeholder] [known-broken: no ellipse overlay render
  type] Overlay previews the ellipse shape during drag.
      Do: Begin a drag.
      Expect (target): Dashed ellipse preview inscribed in the current
              bbox; style matches Rect preview otherwise.
      Expect (current): No preview renders because `ellipse` isn't in
              the overlay-renderer registry.
      — last: —

- [ ] **ELL-051** [placeholder] Cursor is crosshair over canvas.
      Do: Observe cursor.
      Expect (target): Crosshair.
      — last: —

---

## Cross-app parity — Session D (~10 min)

All blocked until wiring lands. Retain IDs for post-wire regression.

- **ELL-200** [placeholder] Ellipse commit produces matching cx / cy /
  rx / ry across apps.
      Do: Press (100,100); drag to (300,200); release.
      Expect (target): Same ellipse geometry in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **ELL-201** [placeholder] Overlay previews in every app.
      Do: Begin a drag.
      Expect (target): Dashed ellipse preview in all four apps with
              matching style.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

---

## Graveyard

_No retired tests yet._

---

## Enhancements

- **ENH-001** Wire the Ellipse tool — add `ELLIPSE` Toolbar variant +
  toolbox icon in all four native apps; register `ellipse` in the
  overlay renderer registry in each app's `yaml_tool.<ext>`. Once
  done, flip every `[placeholder]` in this doc to `[wired]`. _Raised
  during initial suite authoring on 2026-04-23._

- **ENH-002** Shift-to-circle — constrain to a circle when Shift is
  held. _Raised during initial suite authoring on 2026-04-23._

- **ENH-003** Alt-from-center draw — draw centered on the press point
  when Alt is held. _Raised during initial suite authoring on
  2026-04-23._
