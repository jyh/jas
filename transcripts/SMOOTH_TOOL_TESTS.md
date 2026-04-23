# Smooth Tool — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/smooth.yaml`. Design doc:
`transcripts/SMOOTH_TOOL.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other platforms
covered in Session E parity sweep.

---

## Known broken

_Last reviewed: 2026-04-23_

- **SMT-060** [known-broken: SMOOTH_TOOL.md §Known gaps — no cursor
  ring] The tool has no visible circle around the cursor showing
  `SMOOTH_SIZE` (100 px). The underlying `SMOOTH_SIZE` constant is
  available; adding an overlay renderer for it is a follow-up.

---

## Automation coverage

_Last synced: 2026-04-23_

**Python — `jas/geometry/path_ops_test.py`** (~4 tests)
- `TestFlatten` — `flatten_with_cmd_map` line / curve segments and
  the parallel cmap used by the smooth algorithm.

**Swift — `JasSwift/Tests/Geometry/PathOpsTests.swift`**
- Mirror of the Python flatten coverage. Also
  `doc.path.smooth_at_cursor` effect coverage in the interpreter
  tests.

**OCaml — `jas_ocaml/test/geometry/path_ops_test.ml`**
- Mirror of Python / Swift.

**Rust — `jas_dioxus/src/geometry/path_ops.rs` (#[cfg(test)])**
- Reference kernel implementation with flatten + fit-curve coverage.

Each app's YamlTool dispatch test also exercises the smooth handler.

**Flask — no coverage.**

The manual suite below covers selection-requirement semantics,
progressive smoothing over a drag, no-op behavior on already-smooth
paths, cross-tool interaction, undo, and appearance theming.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document.
3. Appearance: **Dark**.
4. Smooth tool active (select from toolbox — no default shortcut).

`SMOOTH_SIZE = 100` px, `SMOOTH_ERROR = 8.0`, `FLATTEN_STEPS = 20`.

When a test calls for a **jittery-path fixture**: Pencil tool → draw
a deliberately wobbly curve across the canvas (many wiggles of
amplitude ~5–10 px) → Selection tool → click the new path so it's
selected. Return to Smooth.

When a test calls for an **already-smooth fixture**: Pen tool → 3
smooth anchors defining a gentle S-curve → Esc → select it.

---

## Tier definitions

- **P0 — existential.** Tool doesn't activate or doesn't smooth.
- **P1 — core.** Smoothing drag visibly simplifies the selected path.
- **P2 — edge & polish.** No-selection no-op, progressive drag,
  already-smooth no-op guard, cross-tool handoff, appearance.

---

## Session table of contents

| Session | Topic                                 | Est.  | IDs      |
|---------|---------------------------------------|-------|----------|
| A       | Smoke & lifecycle                     | ~4m   | 001–009  |
| B       | Smooth a selected jittery path        | ~6m   | 010–029  |
| C       | Selection requirement                 | ~5m   | 030–049  |
| D       | Edge cases (already-smooth, Esc)      | ~5m   | 050–069  |
| E       | Cross-app parity                      | ~10m  | 200–219  |

Full pass: ~30 min.

---

## Session A — Smoke & lifecycle (~4 min)

- [ ] **SMT-001** [wired] Smooth tool activates via toolbox icon.
      Do: Click the Smooth icon in the toolbox.
      Expect: Active state; crosshair cursor.
      — last: —

- [ ] **SMT-002** [wired] Switching away and back preserves state.
      Do: Press V; reselect Smooth.
      Expect: Tool is clean; next drag on a selected path smooths it.
      — last: —

---

## Session B — Smooth a selected jittery path (~6 min)

**P0**

- [ ] **SMT-010** [wired] Press on a selected path mid-drag smooths
  the nearby region.
      Setup: Jittery-path fixture; path selected.
      Do: Press on the path; without releasing, drag along it.
      Expect: The path visibly simplifies under the cursor as you
              drag; wobbles within ~100 px of the cursor disappear.
      — last: —

- [ ] **SMT-011** [wired] Release ends the gesture without a final
  commit step.
      Setup: SMT-010 state.
      Do: Release the mouse.
      Expect: Tool returns to idle; the path state at release is
              what was left by the last smooth pass during the drag.
      — last: —

**P1**

- [ ] **SMT-012** [wired] Initial press smooths immediately at press
  point.
      Setup: Jittery path selected.
      Do: Press (don't drag); release.
      Expect: A smooth pass happens at the press location; the
              path region within 100 px of that point is simplified.
      — last: —

- [ ] **SMT-013** [wired] Progressive dragging accumulates
  smoothing.
      Setup: Jittery-path fixture selected.
      Do: Drag slowly along the entire path from start to end.
      Expect: The whole path becomes progressively smoother as the
              cursor passes over each region.
      — last: —

---

## Session C — Selection requirement (~5 min)

**P1**

- [ ] **SMT-030** [wired] With no selection, Smooth does nothing.
      Setup: Jittery-path fixture, but click empty space to clear
             the selection.
      Do: Drag across the path with Smooth active.
      Expect: No change to the path; no undo entry.
      — last: —

- [ ] **SMT-031** [wired] Only the selected path(s) are smoothed.
      Setup: Two jittery paths. Select one.
      Do: Drag across both with Smooth.
      Expect: Only the selected path is simplified; the other is
              unchanged.
      — last: —

**P2**

- [ ] **SMT-032** [wired] Multiple selected paths all smooth.
      Setup: Two jittery paths; Ctrl/Cmd-A.
      Do: Drag through both.
      Expect: Both simplify as the cursor passes.
      — last: —

- [ ] **SMT-033** [wired] Locked selected paths are skipped.
      Setup: Select + lock a jittery path.
      Do: Drag across it.
      Expect: Locked path unchanged; other unlocked selected paths
              (if any) still smooth.
      — last: —

---

## Session D — Edge cases (~5 min)

**P1**

- [ ] **SMT-050** [wired] Already-smooth path doesn't reduce below
  its command count.
      Setup: Already-smooth fixture selected.
      Do: Drag across it.
      Expect: Command count unchanged after each pass — the
              algorithm aborts the per-element update if the fit
              didn't actually reduce segments. Path may still be
              visibly unchanged.
      — last: —

- [ ] **SMT-051** [wired] Esc during drag ends the gesture.
      Setup: Jittery path; begin a smooth drag.
      Do: Press Esc.
      Expect: Gesture ends; mutations already applied during the
              drag stay (one undo reverses them).
      — last: —

- [ ] **SMT-052** [wired] Undo reverts the whole smooth session.
      Setup: Smooth a path via a drag.
      Do: Ctrl/Cmd-Z.
      Expect: Path returns to pre-drag state in a single undo step
              (the snapshot was taken on press).
      — last: —

**P2**

- [ ] **SMT-060** [known-broken: no cursor ring overlay] Smooth
  radius is not visually indicated.
      Do: Observe cursor.
      Expect (target): A circle of radius ~100 px around the cursor.
      Expect (current): No circle; cursor is only the crosshair.
      — last: —

---

## Cross-app parity — Session E (~10 min)

- **SMT-200** [wired] Smooth drag reduces command count on jittery
  path.
      Do: Jittery path selected; drag across it.
      Expect: Resulting path has fewer CurveTo commands than the
              original in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **SMT-201** [wired] No-selection drag is a no-op.
      Do: Clear selection; drag over a path.
      Expect: Path unchanged in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **SMT-202** [wired] Undo reverts to pre-drag state in one step.
      Do: Smooth; Ctrl/Cmd-Z.
      Expect: Path restored in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **SMT-203** [wired] SMOOTH_ERROR = 8.0, SMOOTH_SIZE = 100 identical.
      Do: Inspect the `doc.path.smooth_at_cursor` yaml effect in each
          app's runtime.
      Expect: Same parameter values across Rust / Swift / OCaml /
              Python.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

---

## Graveyard

_No retired tests yet._

---

## Enhancements

- **ENH-001** Cursor ring — draw a circle of radius SMOOTH_SIZE at
  the cursor. The constant is already available. _Raised during
  SMT-060 on 2026-04-23._

- **ENH-002** Smooth Tool Options dialog — surface SMOOTH_SIZE and
  SMOOTH_ERROR in a UI control rather than yaml constants. _Raised
  during SMT-050 on 2026-04-23._
