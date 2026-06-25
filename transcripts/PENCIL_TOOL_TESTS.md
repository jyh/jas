# Pencil Tool — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/pencil.yaml`. Design doc:
`transcripts/PENCIL_TOOL.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other platforms
covered in Session F parity sweep.

---

## Known broken

_Last reviewed: 2026-04-23_

_No known-broken tests._ Alt-to-close, edit-existing-path mode, and
Smoothness panel are **not-yet-implemented** (ENH entries).

---

## Automation coverage

_Last synced: 2026-06-25._ **Correction (2026-06-25):** the prior entries for
Swift / OCaml / Python claimed dedicated pencil test files that did NOT exist
(pencil behavior was effectively RUST-ONLY). The dedicated files were created
2026-06-25 — each ports the five Rust `pencil_parity_*` gesture-seam tests
(freehand-draw→smoothed Path, zero-length→degenerate Path, stroke-but-no-fill
defaults, release-without-press noop, path-starts-at-press-point) + a
loader-sanity case, driving the PRODUCTION pencil tool loaded from the bundle.
Adversarially verified at parity with the Rust twins, mutation-proven non-vacuous.
Extended 2026-06-25 with Esc-during-drag-cancel (PNC-052/202) and undo/redo
round-trip (PNC-053/203) cases in all four apps (Esc via `on_key_event`, the
non-capturing-tool shell entry; undo/redo via the Model API).

**Swift — `JasSwift/Tests/Tools/YamlToolPencilTests.swift`** (NEW) — 6/6 green.

**OCaml — `jas_ocaml/test/tools/yaml_tool_pencil_test.ml`** (NEW, registered in
`test/tools/dune` + `@runtest`) — 6/6 green.

**Python — `jas/tools/yaml_tool_pencil_test.py`** (NEW) — 6 passed (previously
the pencil was covered only INDIRECTLY via shared dispatch).

**Rust — `jas_dioxus/src/tools/yaml_tool.rs` (#[cfg(test)])**
- Reference implementation; pencil pipeline inline.

**Flask — `jas_flask/tests/js/test_canvas.mjs`,
`tests/js/test_phase12.mjs`** (~5 tests across files)
- buffer_polyline overlay rendering (live polyline tracking the
  drag, no-op when buffer empty or guard false).
- doc.add_path_from_buffer fit + Path commit, applies state
  fill/stroke defaults; Pencil-specific fill=null (a freehand
  hairline shouldn't trap a fill).

The manual suite below covers overlay rendering (buffer_polyline
preview), fit smoothness intuition, cross-tool interaction, undo, and
appearance theming.

**Overlay note (2026-06-25).** Unlike the pen tool (whose `pen_overlay` colors
were hardcoded per-renderer and had to be canonicalized into the spec — see
PEN_TOOL_TESTS.md), the pencil preview's `buffer_polyline` is ALREADY
spec-driven: `pencil.yaml` carries `style: "stroke: black; stroke-width: 1;"`
and all four native renderers read+apply that `style` param (Rust
`draw_buffer_polyline_overlay`, Swift `drawBufferPolylineOverlay`, OCaml
`draw_buffer_polyline_overlay`, Python `_draw_buffer_polyline_overlay`). So the
PNC-070 preview (1 px black polyline) is consistent across apps by construction —
no divergence. GUI-confirmed on the native Swift app via the Quartz harness: a
button-held pencil drag renders the thin black `buffer_polyline` preview.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document.
3. Appearance: **Dark**.
4. Pencil tool active (press `N`).

FIT_ERROR = 4.0. Point buffer name = `"pencil"`.

---

## Tier definitions

- **P0 — existential.** Tool doesn't activate or doesn't commit.
- **P1 — core.** Press / drag / release commits a smoothed Path.
- **P2 — edge & polish.** Overlay styling, cursor, default stroke
  wiring, undo, appearance theming.

---

## Session table of contents

| Session | Topic                             | Est.  | IDs      |
|---------|-----------------------------------|-------|----------|
| A       | Smoke & lifecycle                 | ~4m   | 001–009  |
| B       | Draw a freehand curve             | ~6m   | 010–029  |
| C       | Fit smoothness & zero-length      | ~6m   | 030–049  |
| D       | Stroke / fill / undo / Esc        | ~5m   | 050–069  |
| E       | Overlay & appearance              | ~5m   | 070–089  |
| F       | Cross-app parity                  | ~10m  | 200–219  |

Full pass: ~35 min.

---

## Session A — Smoke & lifecycle (~4 min)

- [ ] **PNC-001** [wired] Pencil tool activates via `N` shortcut.
      Do: Press N.
      Expect: Pencil tool active; crosshair cursor.
      — last: —

- [ ] **PNC-002** [wired] Pencil tool activates via toolbox icon.
      Do: Click the Pencil icon.
      Expect: Active state; crosshair.
      — last: —

---

## Session B — Draw a freehand curve (~6 min)

**P0**

- [ ] **PNC-010** [wired] Press-drag-release commits a smoothed Path.
      Do: Press at (100,100); drag through several positions; release
          at (400,200).
      Expect: A new Path element appears on the canvas tracing a
              smoothed approximation of the drag. The preview
              polyline vanishes; the committed path is a cubic
              spline.
      — last: —

- [ ] **PNC-011** [wired] A zero-length click commits (matches native
  Pencil).
      Do: Press and release without moving.
      Expect: A Path element with two identical points and a
              degenerate CurveTo is committed. Visually near-
              invisible.
      — last: —

**P1**

- [ ] **PNC-012** [wired] Fast, jittery drags still smooth visibly.
      Do: Draw a visibly wobbly curve fast.
      Expect: The committed path is visibly smoother than the
              preview polyline — high-frequency jitter is suppressed
              by the cubic fit.
      — last: —

- [ ] **PNC-013** [wired] Long, deliberate drag commits a multi-segment
  path.
      Do: Slowly draw an S-curve across the canvas.
      Expect: Commit produces a Path with multiple CurveTo segments.
      — last: —

---

## Session C — Fit smoothness & zero-length (~6 min)

**P1**

- [ ] **PNC-030** [wired] FIT_ERROR = 4.0 default produces
  medium-smooth paths.
      Do: Draw a mildly wobbly 300 px curve.
      Expect: Resulting path has a small number of segments (say
              < 10), visibly smoothing out tiny wobbles.
      — last: —

**P2**

- [ ] **PNC-031** [wired] Successive pencil strokes accumulate as
  separate paths.
      Do: Draw three separate curves in different locations.
      Expect: Three distinct Path elements in the document.
      — last: —

- [ ] **PNC-032** [wired] Zero-length click deposits a near-invisible
  degenerate path.
      Setup: PNC-011.
      Do: Selection tool → select all.
      Expect: The degenerate path appears in the selection; its bbox
              is collapsed but it is present.
      — last: —

---

## Session D — Stroke / fill / undo / Esc (~5 min)

**P1**

- [ ] **PNC-050** [wired] Path picks up `model.default_stroke`.
      Setup: Stroke = red 3 pt.
      Do: Draw a freehand curve.
      Expect: The new path renders red at 3 pt.
      — last: —

- [ ] **PNC-051** [wired] Path has no fill by default.
      Do: Draw a curve; inspect its fill.
      Expect: Fill is None (open paths don't get fills by default).
      — last: —

- [ ] **PNC-052** [wired] Esc during drag cancels without committing.
      Do: Begin a drag; press Esc while pressed; release.
      Expect: No Path committed; point buffer cleared.
      — last: —

- [ ] **PNC-053** [wired] Undo removes the last pencil path.
      Do: Draw; Ctrl/Cmd-Z.
      Expect: Path removed; redo restores.
      — last: —

---

## Session E — Overlay & appearance (~5 min)

**P2**

- [ ] **PNC-070** [wired] Overlay is a thin black polyline (preview).
      Do: Begin a drag.
      Expect: Raw-drag preview renders as a 1 px black polyline
              tracking each mousemove.
      — last: —

- [ ] **PNC-071** [wired] Preview shows raw samples, commit shows
  smoothed curve.
      Do: Draw a wobbly stroke; compare preview (during drag) with
          committed path.
      Expect: Preview is jagged following the cursor exactly;
              committed path is visibly smoother.
      — last: —

- [ ] **PNC-072** [wired] Preview visible on all three appearance
  themes.
      Do: Switch theme; begin a drag in each.
      Expect: 1 px polyline readable on Dark / Medium / Light.
      — last: —

---

## Cross-app parity — Session F (~10 min)

- **PNC-200** [wired] Press-drag-release commits a Path in every app.
      Do: Press (100,100); drag to (200,150) then to (300,100);
          release.
      Expect: One new Path element with CurveTo(s) in each app;
              FIT_ERROR=4.0 applied.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [x] Flask      last: 2026-04-27

- **PNC-201** [wired] FIT_ERROR = 4.0 identical across apps.
      Do: Inspect the yaml `doc.add_path_from_buffer` call.
      Expect: `fit_error: 4.0` in every app's YAML runtime.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [x] Flask      last: 2026-04-27  · pencil.yaml has `fit_error: "4"` (string-typed numeric 4); Flask's effects.mjs evaluates → Number(4) = 4.0.

- **PNC-202** [wired] Esc during drag leaves document unchanged.
      Do: Begin a drag; press Esc.
      Expect: No element added in any app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [x] Flask      last: 2026-04-27

- **PNC-203** [wired] Undo removes the last pencil path in every app.
      Do: Draw curve; Ctrl/Cmd-Z.
      Expect: Element count returns to pre-draw in every app.
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

- **ENH-001** Alt-to-close — close the path when Alt is held at
  release. Native Pencil tools do this. _Raised during PNC-010 on
  2026-04-23._

- **ENH-002** Edit-existing-path mode — allow redrawing a section of
  a selected path. _Raised during PNC-010 on 2026-04-23._

- **ENH-003** Pencil Tool Options dialog — surface FIT_ERROR and
  related knobs in a dialog. _Raised during PNC-030 on 2026-04-23._
