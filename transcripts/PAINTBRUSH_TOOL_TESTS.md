# Paintbrush Tool — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/paintbrush.yaml`. Design doc:
`transcripts/PAINTBRUSH_TOOL.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other platforms
covered in Session H parity sweep.

---

## Known broken

_Last reviewed: 2026-04-24_

- **Close-at-release hint overlay** (spec § Overlay → Close-at-release
  hint) — the dashed line from cursor to press-point is not rendered.
  Close-at-release itself (Alt held at release → committed path is
  closed) does work; only the visual preview is missing. Tracked in
  PAINTBRUSH_TOOL.md as a tool-overlay-system gap.
- **Tool-options dialog double-click** — only Rust wires the
  `tool_options_dialog` field to an `open_dialog` dispatch on icon
  double-click. Swift / OCaml / Python register the dialog artifact
  but don't trigger it via double-click yet.
- **Pressure / tilt / bearing variation** — synthesizes a fixed 0.5
  at stroke time. Calligraphic brushes with these variation modes
  render at their base size / angle / roundness. Phase 2.
- **Flask** — paintbrush is spec-only; requires `buffer.*` primitives
  in the JS engine.

---

## Automation coverage

_Last synced: 2026-04-24_

**Rust — `jas_dioxus/src/interpreter/effects.rs` (#[cfg(test)])**
- 10 unit tests for `doc.add_path_from_buffer` extensions
  (`fill_new_strokes`, close, stroke-width rule with brush lookup
  and overrides, stroke_brush_overrides passthrough).
- 6 unit tests for `doc.paintbrush.edit_start` / `edit_commit`
  (target-selection within/out-of-range, splice-with-brush-
  preservation, exit-too-far abort, commit-without-start no-op).

**Swift / OCaml / Python** — port coverage is currently implicit
(existing `yaml_tool_test.py` / equivalents exercise the pencil
handler through the shared dispatch path). Paintbrush-specific unit
tests are a follow-up.

---

## Preconditions (assumed for every session)

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document.
3. Appearance: **Dark**.
4. Paintbrush tool active (long-press Pencil slot → Paintbrush, or
   press `B`).
5. A Calligraphic brush selected in the Brushes panel (e.g. the
   library's default). `state.stroke_brush` non-null.

Point buffer name = `"paintbrush"`. Default Fidelity = tick 3,
FIT_ERROR = 5.0. Default `paintbrush_edit_within` = 12 px.

---

## Tier definitions

- **P0 — existential.** Tool doesn't activate, doesn't commit a path,
  or `jas:stroke-brush` is missing on the committed element.
- **P1 — core.** Drawing commits a shaped brush stroke at the right
  color + width. Edit gesture and close-at-release behave per spec.
- **P2 — edge & polish.** Option controls, fidelity mapping,
  stroke-width fallbacks, undo, overlay, appearance theming.

---

## Session table of contents

| Session | Topic                                | Est.  | IDs       |
|---------|--------------------------------------|-------|-----------|
| A       | Smoke & lifecycle                    | ~4m   | 001–009   |
| B       | Draw a brushed stroke                | ~6m   | 010–029   |
| C       | Fidelity slider                      | ~5m   | 030–049   |
| D       | Fill / stroke-width rule             | ~6m   | 050–069   |
| E       | Edit-existing-path gesture           | ~8m   | 070–099   |
| F       | Close-at-release                     | ~3m   | 100–109   |
| G       | Options dialog & state persistence   | ~5m   | 110–129   |
| H       | Cross-app parity                     | ~12m  | 200–229   |

Full pass: ~50 min.

---

## Session A — Smoke & lifecycle (~4 min)

- [ ] **PBR-001** [wired] Paintbrush tool activates via `B`.
      Do: Press B.
      Expect: Paintbrush tool active; crosshair cursor.
      — last: —

- [ ] **PBR-002** [wired] Paintbrush tool activates via toolbox icon.
      Do: Long-press Pencil slot, choose Paintbrush from popup.
      Expect: Active state; icon swaps to the paintbrush glyph.
      — last: —

- [ ] **PBR-003** [wired] Switching away clears any drag buffer.
      Do: Paintbrush, press-and-hold, then switch to Selection (V)
      mid-drag without releasing.
      Expect: No ghost overlay; no phantom path committed.
      — last: —

- [ ] **PBR-004** [wired] Escape mid-drag discards the gesture.
      Do: Start a drag, hit Esc before release.
      Expect: Overlay clears, no path added, no undo entry pushed.
      — last: —

---

## Session B — Draw a brushed stroke (~6 min)

- [ ] **PBR-010** [wired] P0. Basic press/drag/release commits a
      Path with `jas:stroke-brush` set.
      Do: Drag a freehand stroke.
      Expect: One Path element appended; inspecting its attributes
      shows `jas:stroke-brush = "<library>/<brush-slug>"`.
      — last: —

- [ ] **PBR-011** [wired] Commit renders as a shaped brush outline,
      not the preview polyline.
      Do: Drag a curve. Look at committed vs preview.
      Expect: Preview is a 1px thin line; commit renders with the
      brush's shape (oval sweep for Calligraphic).
      — last: —

- [ ] **PBR-012** [wired] Selection-free draw works.
      Do: Click in empty space to clear selection, then draw.
      Expect: New path committed.
      — last: —

- [ ] **PBR-013** [wired] Degrade to pencil when `state.stroke_brush`
      is null.
      Do: In Brushes panel: "Remove Brush Stroke" (clears
      `state.stroke_brush`). Draw.
      Expect: Commit produces a plain-stroke path (no brush
      outline); `jas:stroke-brush` attribute absent.
      — last: —

---

## Session C — Fidelity slider (~5m)

- [ ] **PBR-030** [wired] Default Fidelity = tick 3 → fit_error 5.0.
      Do: Verify `state.paintbrush_fidelity == 3` on a fresh load.
      Expect: Value is 3.
      — last: —

- [ ] **PBR-031** [wired] Tick 1 (Accurate) preserves jitter.
      Do: Set `paintbrush_fidelity = 1`. Draw a jittery curve.
      Expect: Committed path has many segments that track jitter
      closely. `fit_error = 0.5`.
      — last: —

- [ ] **PBR-032** [wired] Tick 5 (Smooth) simplifies.
      Do: Set `paintbrush_fidelity = 5`. Draw the same jittery curve.
      Expect: Fewer segments, smoother overall shape.
      `fit_error = 10.0`.
      — last: —

- [ ] **PBR-033** [wired] Tick 2 / 4 intermediate values are active.
      Do: Set fidelity to 2, draw; set to 4, draw.
      Expect: Visually distinguishable smoothness differences.
      — last: —

---

## Session D — Fill & stroke-width rule (~6m)

- [ ] **PBR-050** [wired] P0. Default `fill_new_strokes = false`:
      commit has no fill.
      Do: Draw a closed-looking path.
      Expect: Path's `fill` attribute absent / none.
      — last: —

- [ ] **PBR-051** [wired] Toggling `fill_new_strokes = true` sets
      `fill = state.fill_color` on commits.
      Do: Set fill color to a distinct hue. Set
      `paintbrush_fill_new_strokes = true`. Draw.
      Expect: New path's `fill` is the chosen color.
      — last: —

- [ ] **PBR-052** [wired] Stroke-width = brush.size when brush has
      `size`.
      Do: Draw with a Calligraphic brush whose `size = 8`.
      Expect: Committed path's `stroke-width = 8`.
      — last: —

- [ ] **PBR-053** [wired] Stroke-width = state.stroke_width when
      no brush (Pencil-equivalent).
      Do: Clear `state.stroke_brush`. Set `state.stroke_width = 3.5`.
      Draw.
      Expect: Committed path's `stroke-width = 3.5`.
      — last: —

- [ ] **PBR-054** [wired] Art / Pattern brush (no `size`) falls back
      to `state.stroke_width`.
      Do: Switch to an Art brush (has no `size`). Set
      `state.stroke_width = 2.25`. Draw.
      Expect: Committed path's `stroke-width = 2.25`.
      — last: —

- [ ] **PBR-055** [wired] `state.stroke_brush_overrides.size` wins
      over brush.size.
      Do: Set `state.stroke_brush_overrides = {"size": 12}` on a
      Calligraphic brush with `size = 4`. Draw.
      Expect: Committed path's `stroke-width = 12`.
      — last: —

- [ ] **PBR-056** [wired] Stroke color = `state.stroke_color`.
      Do: Pick a distinct stroke color. Draw.
      Expect: Committed path's `stroke` color matches.
      — last: —

---

## Session E — Edit-existing-path gesture (~8m)

- [ ] **PBR-070** [wired] P1. Alt-drag near a selected Path edits it
      in place.
      Do: Draw a stroke, select it. Alt-press on the middle of the
      path, drag perpendicularly, release back on the path.
      Expect: Original path deformed; no new path added;
      `jas:stroke-brush` preserved.
      — last: —

- [ ] **PBR-071** [wired] `paintbrush_edit_selected_paths = false`
      disables the gesture.
      Do: Set the option off. Alt-drag on a selected path.
      Expect: A new path is drawn instead of editing the existing.
      — last: —

- [ ] **PBR-072** [wired] Press > `paintbrush_edit_within` from all
      selected paths falls through to new-path mode.
      Do: Alt-press far from any selected path (default threshold
      12 px). Drag.
      Expect: New path committed; selected path untouched.
      — last: —

- [ ] **PBR-073** [wired] Release > within from target aborts the
      splice.
      Do: Alt-press on a selected path, drag away, release beyond
      12 px from the target.
      Expect: Target unchanged; no new path committed.
      — last: —

- [ ] **PBR-074** [wired] Brush-reference preserved even when
      `state.stroke_brush` changes mid-session.
      Do: Edit path A (brush X). Switch to brush Y. Edit path A
      again.
      Expect: Path A still carries brush X's slug; brush Y ignored.
      — last: —

- [ ] **PBR-075** [wired] `paintbrush_edit_within` threshold
      configurable.
      Do: Set to 50. Alt-press within 30 px of a selected path.
      Expect: Edit engages (was out-of-range at default 12).
      — last: —

- [ ] **PBR-076** [wired] No selection → Alt has no effect.
      Do: Clear selection. Alt-drag anywhere.
      Expect: Normal new-path drawing (Alt ignored at press).
      — last: —

- [ ] **PBR-077** [wired] Degenerate entry == exit aborts.
      Do: Alt-press on a selected path, drag 2 px away, release
      back at entry.
      Expect: No change to target; no new path.
      — last: —

---

## Session F — Close-at-release (~3m)

- [ ] **PBR-100** [wired] Alt held at release in drawing mode closes
      the path.
      Do: Draw without Alt. At release, hold Alt, then release
      mouse.
      Expect: Committed path ends with ClosePath (fill region if
      `fill_new_strokes` on).
      — last: —

- [ ] **PBR-101** [wired] No Alt at release → open path.
      Do: Same gesture without Alt held at release.
      Expect: No ClosePath command.
      — last: —

- [ ] **PBR-102** [wired] Alt at release in edit mode is ignored.
      Do: Alt-drag to trigger edit, hold Alt through release.
      Expect: Target path remains un-closed (the splice doesn't
      add ClosePath); Alt-at-release is not consulted in edit mode.
      — last: —

---

## Session G — Options dialog & state persistence (~5m)

_Rust only until Swift / OCaml / Python wire the dblclick trigger._

- [ ] **PBR-110** [partial] Double-click Paintbrush icon opens
      Paintbrush Tool Options dialog.
      Do: Double-click tool icon.
      Expect: Dialog shows Fidelity slider (5-stop), Fill new
      brush strokes checkbox, Keep Selected checkbox, Edit Selected
      Paths checkbox, Within slider + numeric, and Reset / Cancel
      / OK buttons.
      — last: —

- [ ] **PBR-111** [wired] OK writes dialog values to
      `state.paintbrush_*`.
      Do: Change Fidelity to 5, click OK. Inspect state.
      Expect: `state.paintbrush_fidelity == 5`.
      — last: —

- [ ] **PBR-112** [wired] Cancel discards edits.
      Do: Change values, click Cancel.
      Expect: `state.paintbrush_*` unchanged.
      — last: —

- [ ] **PBR-113** [wired] Reset restores defaults without committing.
      Do: Change several values, click Reset.
      Expect: Dialog shows default values (fidelity=3,
      fill_new_strokes=false, keep_selected=true,
      edit_selected_paths=true, within=12); state unchanged until
      OK.
      — last: —

---

## Session H — Cross-app parity (~12m)

Re-run a core subset (PBR-010, 030, 050–054, 070, 100) on each of:

| Platform | Notes                                               |
|----------|-----------------------------------------------------|
| Rust     | Reference. Full coverage above.                    |
| Swift    | Dblclick options dialog not wired; skip PBR-110-113 |
| OCaml    | Dblclick options dialog not wired; skip PBR-110-113 |
| Python   | Dblclick options dialog not wired; skip PBR-110-113 |
| Flask    | Tool not implemented; skip entire suite.            |

- [ ] **PBR-200 .. 229** — per-platform parity results, one entry
      per (platform × tier-1 test). Mark [wired] when confirmed.
      — last: —

---

## Coverage matrix (tier × session)

|              | A | B | C | D | E | F | G | H |
|--------------|---|---|---|---|---|---|---|---|
| P0           | 1 | 1 | — | 1 | — | — | — | — |
| P1           | 3 | 3 | 4 | 6 | 7 | 2 | — | — |
| P2           | — | — | — | — | 1 | 1 | 4 | — |

---

## Observed bugs (append only)

_None yet._
