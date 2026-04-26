# Pen Tool — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/pen.yaml`. Design doc: `transcripts/PEN_TOOL.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other platforms
covered in Session H parity sweep.

---

## Known broken

_Last reviewed: 2026-04-23_

_No known-broken tests._ Alt-break, Shift-constrained segments, and
rubber-banding previous-anchor handles are **not-yet-implemented**
(ENH entries).

---

## Automation coverage

_Last synced: 2026-04-23_

**Python — `jas/tools/yaml_tool_test.py`** + anchor-buffer primitives
in `workspace_interpreter/anchor_buffers_test.py` (if present).
- YamlTool pipeline covers pen state machine indirectly via the
  shared dispatch test cases.
- Anchor-buffer primitives (push, set_last_out_handle, close_hit,
  pop) covered at unit level.

**Swift — `JasSwift/Tests/Tools/YamlToolPenTests.swift`**
- idle → dragging → placing transitions; click-to-place corner anchor;
  click-and-drag smooth anchor; close-path near first anchor; Esc
  commits if ≥ 2 anchors.

**OCaml — `jas_ocaml/test/tools/yaml_tool_pen_test.ml`**
- Mirror of Python / Swift coverage.

**Rust — `jas_dioxus/src/tools/yaml_tool.rs` (#[cfg(test)])**
- Reference implementation; pen state machine + anchor-buffer +
  close-hit tests inline.

**Flask — `jas_flask/tests/js/test_anchor_buffers.mjs`,
`tests/js/test_phase12.mjs`, `tests/js/test_canvas.mjs`** (~14 tests
spread across files)
- anchor_buffers module: push corner anchor, set_last_out mirroring,
  pop, clear, closeHit semantics.
- anchor.* effects (push / pop / clear / set_last_out) plus the
  anchor_buffer_length / anchor_buffer_close_hit primitives.
- doc.add_path_from_anchor_buffer (open + closed paths, M / C / Z
  output).
- pen_overlay rendering (path-so-far, anchor squares, close-hit ring).

The manual suite below covers overlay rendering (pen_overlay render
type with close-hit indicator, handle bars, preview curve), tool
lifecycle, double-click commit, cross-tool interaction, undo, and
appearance theming.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document.
3. Appearance: **Dark**.
4. Pen tool active (press `P`).

`close_radius = 8 px`. Anchor buffer name = `"pen"`.

---

## Tier definitions

- **P0 — existential.** Tool doesn't activate or doesn't commit any
  path.
- **P1 — core.** Corner click, smooth drag, close-path, Esc / Enter /
  double-click commit all work as specified.
- **P2 — edge & polish.** Overlay styling (pen_overlay render, close
  indicator, handle bar), cursor, default fill / stroke wiring,
  cross-tool switches, appearance theming.

---

## Session table of contents

| Session | Topic                                 | Est.  | IDs      |
|---------|---------------------------------------|-------|----------|
| A       | Smoke & lifecycle                     | ~5m   | 001–009  |
| B       | Click-to-place corner anchors         | ~6m   | 010–029  |
| C       | Click-and-drag smooth anchors         | ~8m   | 030–049  |
| D       | Close path via first-anchor hit       | ~6m   | 050–069  |
| E       | Esc / Enter / double-click commit     | ~6m   | 070–089  |
| F       | Tool deactivation auto-commit         | ~5m   | 090–099  |
| G       | Overlay & handle bar                  | ~6m   | 100–119  |
| H       | Cross-app parity                      | ~12m  | 200–229  |

Full pass: ~55 min.

---

## Session A — Smoke & lifecycle (~5 min)

- [ ] **PEN-001** [wired] Pen tool activates via `P` shortcut.
      Do: Press P.
      Expect: Pen tool active; crosshair cursor over canvas; state is
              `idle`.
      — last: —

- [ ] **PEN-002** [wired] Pen tool activates via toolbox icon.
      Do: Click the Pen icon.
      Expect: Active state; crosshair.
      — last: —

- [ ] **PEN-003** [wired] First mousedown on empty canvas transitions
  idle → dragging.
      Do: Press (no release).
      Expect: The press point becomes the first anchor (visible as
              a small dot); state is `dragging` (drag would set the
              out-handle).
      — last: —

---

## Session B — Click-to-place corner anchors (~6 min)

**P0**

- [ ] **PEN-010** [wired] Click places a corner anchor.
      Do: Click at (100,100); then click at (200,100); then click at
          (200,200); press Esc.
      Expect: A 3-anchor open path commits: MoveTo → LineTo → LineTo
              (all three anchors are corners with zero handles).
      — last: —

- [ ] **PEN-011** [wired] Successive clicks extend the preview curve.
      Setup: Pen idle; click at (100,100).
      Do: Move mouse away without clicking; then click at (200,100).
      Expect: Before the second click, a dashed preview extends from
              the first anchor to the cursor. After the click, two
              anchors are placed; preview restarts from the second.
      — last: —

**P1**

- [ ] **PEN-012** [wired] Single anchor + Esc discards the path.
      Setup: Click at (100,100); state = placing with 1 anchor.
      Do: Press Esc.
      Expect: No element committed; state returns to idle.
      — last: —

- [ ] **PEN-013** [wired] First anchor indicator visible.
      Setup: Place the first anchor.
      Do: Observe.
      Expect: The first anchor is rendered as a filled dot
              (or distinguishable marker) in the pen_overlay blue.
      — last: —

---

## Session C — Click-and-drag smooth anchors (~8 min)

**P0**

- [ ] **PEN-030** [wired] Click-and-drag places a smooth anchor.
      Do: Press at (100,100) and drag to (150,100) before releasing
          (out-handle set).
      Expect: Anchor at (100,100) created with out-handle at (150,100);
              in-handle mirrored to (50,100). Anchor marked smooth.
      — last: —

- [ ] **PEN-031** [wired] Subsequent anchors chain with smooth
  connection.
      Setup: PEN-030 state (1 smooth anchor with handles).
      Do: Click at (300,300) (corner).
      Expect: A second anchor at (300,300); preview curve from
              (100,100) to (300,300) uses the in-handle of the second
              as a mirror when committed — for now the second anchor
              is corner so its in-handle is (300,300) itself.
      — last: —

**P1**

- [ ] **PEN-032** [wired] Drag updates the out-handle live while held.
      Setup: Press anchor down.
      Do: Move mouse around while still pressed.
      Expect: Preview curve's out-handle follows the cursor in real
              time; mouseup commits the final position.
      — last: —

- [ ] **PEN-033** [wired] Release returns to placing state.
      Setup: Mid-drag after placing smooth anchor.
      Do: Release the mouse.
      Expect: State returns to `placing`; next click drops the next
              anchor.
      — last: —

**P2**

- [ ] **PEN-034** [wired] Handle bar visible for most recent smooth
  anchor.
      Setup: One smooth anchor placed.
      Do: Observe the overlay near that anchor.
      Expect: A line from the anchor to its out-handle, with a dot at
              the handle endpoint (1 px blue per design).
      — last: —

---

## Session D — Close path (~6 min)

**P0**

- [ ] **PEN-050** [wired] Clicking within 8 px of the first anchor
  closes.
      Setup: Place 3 corner anchors forming a triangle (e.g.
             (100,100), (200,100), (150,200)).
      Do: Click at (103,103) (within 8 px of first anchor).
      Expect: Path commits closed — a final CurveTo back to the first
              anchor + ClosePath; buffer clears; state returns to
              idle.
      — last: —

- [ ] **PEN-051** [wired] Close-hit requires ≥ 2 anchors.
      Setup: Place 1 anchor only.
      Do: Click close to that anchor again.
      Expect: The click treats the press as adding another anchor (or
              starts a new path), NOT as a close. Exact behavior per
              yaml: second click replaces the buffer or places a
              near-duplicate — verify against design doc.
      — last: —

**P1**

- [ ] **PEN-052** [wired] Close-hit indicator appears when near the
  first anchor.
      Setup: 2+ anchors placed; move cursor near the first.
      Do: Hover within 8 px of the first anchor (no click).
      Expect: An orange circle indicator appears around the first
              anchor signaling "this click will close".
      — last: —

- [ ] **PEN-053** [wired] Cursor farther than 8 px shows no close
  indicator.
      Setup: 2+ anchors placed; cursor > 8 px from first anchor.
      Do: Observe.
      Expect: No orange close-hit circle.
      — last: —

---

## Session E — Esc / Enter / double-click commit (~6 min)

**P1**

- [ ] **PEN-070** [wired] Esc with ≥ 2 anchors commits open path.
      Setup: Place 3 corner anchors.
      Do: Press Esc.
      Expect: An open path element with 3 anchors commits; buffer
              clears; state returns to idle.
      — last: —

- [ ] **PEN-071** [wired] Enter with ≥ 2 anchors commits open path.
      Setup: Place 3 corner anchors.
      Do: Press Enter.
      Expect: Same outcome as PEN-070.
      — last: —

- [ ] **PEN-072** [wired] Esc with 1 anchor discards.
      Setup: Place 1 anchor.
      Do: Press Esc.
      Expect: No element created; buffer clears.
      — last: —

- [ ] **PEN-073** [wired] Double-click pops the just-placed anchor and
  commits.
      Setup: Place 3 anchors; then double-click at (500,500).
      Do: Observe.
      Expect: The second click of the double-click is popped (so the
              path has 3 anchors, not 4); path commits as open;
              state → idle.
      — last: —

**P2**

- [ ] **PEN-074** [wired] Commit with exactly 2 anchors succeeds.
      Setup: Place 2 corner anchors.
      Do: Press Esc.
      Expect: Open path with 2 anchors (a single line segment if both
              corners).
      — last: —

---

## Session F — Tool deactivation auto-commit (~5 min)

**P1**

- [ ] **PEN-090** [wired] Switching tools mid-path auto-commits.
      Setup: Place 3 anchors with the Pen tool.
      Do: Press V (Selection).
      Expect: Path commits as open (as if Esc was pressed); Selection
              tool becomes active; buffer clears.
      — last: —

- [ ] **PEN-091** [wired] Single-anchor deactivation discards.
      Setup: Place 1 anchor.
      Do: Press V.
      Expect: No element committed; tool switches cleanly.
      — last: —

---

## Session G — Overlay & handle bar (~6 min)

**P2**

- [ ] **PEN-100** [wired] Pen overlay uses 1 px blue primary geometry.
      Setup: Place 2+ anchors.
      Do: Observe overlay.
      Expect: Main curve + anchor dots render in a blue
              (rgb(0,120,215)) at 1 px.
      — last: —

- [ ] **PEN-101** [wired] Preview curve from last anchor to cursor is
  dashed.
      Setup: Place ≥ 1 anchor; move cursor away.
      Do: Observe.
      Expect: Dashed line (or curve if last anchor has an out-handle)
              from last anchor to the cursor.
      — last: —

- [ ] **PEN-102** [wired] Handle bar only on most recent smooth
  anchor.
      Setup: Place smooth anchor #1; place smooth anchor #2.
      Do: Observe.
      Expect: Handle bar visible on anchor #2 only; anchor #1 shows
              anchor dot but no handle bar.
      — last: —

- [ ] **PEN-103** [wired] Appearance theming — overlay readable on all
  three themes.
      Setup: Place 2 anchors.
      Do: Switch Dark / Medium / Light.
      Expect: Blue overlay remains visible in all three; close-hit
              orange visible in all three.
      — last: —

---

## Cross-app parity — Session H (~12 min)

- **PEN-200** [wired] Corner click places an anchor with zero handles.
      Do: Click at (100,100).
      Expect: Anchor in buffer with (x,y)=(100,100) and all handles
              collapsed to anchor position; smooth=false.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **PEN-201** [wired] Click-and-drag places a smooth anchor with
  mirrored in-handle.
      Do: Press (100,100); drag to (150,100); release.
      Expect: Anchor at (100,100); out=(150,100); in=(50,100);
              smooth=true.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **PEN-202** [wired] Close-hit triggers when within 8 px of first
  anchor.
      Do: Place 3 anchors; click at (103,103) with first at (100,100).
      Expect: Path closes in every app; 4 commands (Move, Curve×2,
              Curve+Close) or equivalent.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **PEN-203** [wired] Esc discards a 1-anchor path.
      Do: Place 1 anchor; Esc.
      Expect: Document unchanged in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **PEN-204** [wired] Esc commits a 2-anchor path.
      Do: Place 2 anchors; Esc.
      Expect: Path element added in every app with the 2 anchors.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **PEN-205** [wired] Double-click pops the last anchor then commits.
      Do: Place 3 anchors; double-click at a 4th location.
      Expect: Committed path has 3 anchors (4th popped); matches in
              every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **PEN-206** [wired] Tool deactivation auto-commits.
      Do: Place 3 anchors; press V.
      Expect: Open path committed in every app; buffer cleared.
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

- **ENH-001** Alt-drag to break handles — break the in/out mirror on
  a smooth anchor during placement. Native Pen tools use Alt for this.
  _Raised during PEN-030 on 2026-04-23._

- **ENH-002** Shift-constrained 45° segments — snap path segments to
  multiples of 45° when Shift is held. _Raised during PEN-010 on
  2026-04-23._

- **ENH-003** Rubber-band previous-anchor handle — allow dragging a
  prior anchor's handle during the same session by clicking back on
  it. _Raised during PEN-034 on 2026-04-23._
