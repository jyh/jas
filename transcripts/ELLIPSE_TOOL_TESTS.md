# Ellipse Tool — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/ellipse.yaml`. Design doc:
`transcripts/ELLIPSE_TOOL.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other platforms
covered in Session D parity sweep — auto-tests landed in all 5 apps;
manual sweep across Swift / OCaml / Python / Flask still pending.

---

## Known broken

_Last reviewed: 2026-04-30_

_None remaining — both prior wiring blockers resolved by commit
00567b5 (`ellipse-tool-spec` branch):_

- ~~**ELL-001** Ellipse tool not wired into any toolbar.~~ Resolved:
  Ellipse variant + toolbar slot + factory entry added in Rust /
  Swift / OCaml / Python; Flask reads workspace.tools generically.
- ~~**ELL-050** No `ellipse` overlay renderer registered.~~ Resolved:
  `draw_ellipse_overlay` added to each app's `yaml_tool` overlay
  dispatch.

---

## Automation coverage

_Last synced: 2026-04-30_

**Python — `tools/yaml_tool_test.py::TestEllipseTool`** covers
draw / zero-size / negative-drag against the workspace-loaded spec.

**Swift — `JasSwift/Tests/Canvas/CanvasTests.swift`**:
`ellipseToolCreatesEllipseElement`, `ellipseToolZeroSizeClickSuppressed`.

**OCaml — `jas_ocaml/test/tools/tool_interaction_test.ml`** has an
"ellipse tool" suite parallel to the rect suite (draw, zero-size,
negative drag).

**Rust — `jas_dioxus/src/tools/yaml_tool.rs::tests`**: three
`ellipse_parity_*` cases mirroring the rect parity tests.

**Flask — `jas_flask/tests/js/test_ellipse.mjs`**: 6 cases covering
end-to-end commit, zero-size suppression, negative drag, undo, and
Escape during drag.

The yaml spec itself is validated by workspace loader tests in every
app. The press / drag / release / threshold pattern is shared with
rect.yaml unchanged.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document.
3. Appearance: **Dark**.
4. Ellipse tool active (press `L`).

**All tests below are [wired]** as of 2026-04-30 commit 00567b5
(ellipse-tool-spec branch). Run the suite end-to-end before merging.

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

- [ ] **ELL-001** [wired] Ellipse tool activates via `L` shortcut.
      Do: Press L.
      Expect: Ellipse tool becomes active; cursor crosshair.
              (Line moved to `\\` per its yaml.)
      — last: —

- [ ] **ELL-002** [wired] Ellipse tool activates via toolbox icon.
      Do: Long-press the shape slot; pick Ellipse from the alternates
          menu (slots are Rect / RoundedRect / Ellipse / Polygon /
          Star).
      Expect: Ellipse becomes the visible alternate; active state on
              icon; crosshair.
      — last: —

---

## Session B — Draw an ellipse (~6 min)

**P0**

- [ ] **ELL-010** [wired] Press-drag-release commits an Ellipse.
      Do: Press at (100,100); drag to (300,200); release.
      Expect (target): Ellipse with cx=200, cy=150, rx=100, ry=50.
      — last: —

- [ ] **ELL-011** [wired] Zero-size click is suppressed.
      Do: Press and release at the same point.
      Expect (target): No element created.
      — last: —

**P1**

- [ ] **ELL-012** [wired] Sub-1-pt bounding box is suppressed.
      Do: Press at (100,100); drag to (100.5,100.5).
      Expect (target): No element created.
      — last: —

- [ ] **ELL-013** [wired] Up-and-left drag normalizes.
      Do: Press (300,250); drag to (100,100); release.
      Expect (target): Ellipse with cx=200, cy=175, rx=100, ry=75.
      — last: —

- [ ] **ELL-014** [wired] Successive ellipses accumulate.
      Do: Draw three ellipses in different positions.
      Expect (target): All three present.
      — last: —

---

## Session C — Fill / stroke / undo / overlay (~6 min)

**P1**

- [ ] **ELL-030** [wired] Ellipse picks up default fill at commit.
      Setup: Fill panel = orange.
      Do: Draw any ellipse.
      Expect (target): Orange fill on the new ellipse.
      — last: —

- [ ] **ELL-031** [wired] Ellipse picks up default stroke.
      Setup: Stroke panel = 4 pt black.
      Do: Draw any ellipse.
      Expect (target): 4 pt black stroke.
      — last: —

- [ ] **ELL-032** [wired] Esc during drag cancels.
      Do: Begin a drag; press Esc.
      Expect (target): No element created.
      — last: —

- [ ] **ELL-033** [wired] Undo removes the last ellipse.
      Do: Draw ellipse; Ctrl/Cmd-Z.
      Expect (target): Ellipse removed; redo restores.
      — last: —

**P2**

- [ ] **ELL-050** [wired] Overlay previews the ellipse shape during drag.
      Do: Begin a drag.
      Expect: Dashed ellipse preview inscribed in the current bbox;
              style matches Rect preview otherwise (1-px black at 50%
              opacity, 4/4 dash, no fill).
      — last: —

- [ ] **ELL-051** [wired] Cursor is crosshair over canvas.
      Do: Observe cursor.
      Expect (target): Crosshair.
      — last: —

---

## Cross-app parity — Session D (~10 min)

All blocked until wiring lands. Retain IDs for post-wire regression.

- **ELL-200** [wired] Ellipse commit produces matching cx / cy /
  rx / ry across apps.
      Do: Press (100,100); drag to (300,200); release.
      Expect (target): Same ellipse geometry in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [x] Flask      last: 2026-04-27  · note: Ellipse newly surfaced via shape-toolbar alternates; surfaced + fixed hardcoded `#d94ad9` magenta fill in ellipse.yaml — now uses state.fill_color / stroke_color via doc.add_element shape defaults.

- **ELL-201** [wired] Overlay previews in every app.
      Do: Begin a drag.
      Expect (target): Dashed ellipse preview in all four apps with
              matching style.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [x] Flask      last: 2026-04-27  · note: Flask uses ellipse.yaml's live-edit pattern (real element grows during drag), not the overlay-then-commit pattern Rect uses. Visual feedback present; "dashed preview" semantics don't apply.

---

## Graveyard

_No retired tests yet._

---

## Enhancements

- **ENH-001** Wire the Ellipse tool — add `ELLIPSE` Toolbar variant +
  toolbox icon in all four native apps; register `ellipse` in the
  overlay renderer registry in each app's `yaml_tool.<ext>`. Once
  done, flip every `[wired]` in this doc to `[wired]`. _Raised
  during initial suite authoring on 2026-04-23._

- **ENH-002** Shift-to-circle — constrain to a circle when Shift is
  held. _Raised during initial suite authoring on 2026-04-23._

- **ENH-003** Alt-from-center draw — draw centered on the press point
  when Alt is held. _Raised during initial suite authoring on
  2026-04-23._
