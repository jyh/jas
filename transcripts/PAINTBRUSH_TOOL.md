# Paintbrush tool

The Paintbrush tool draws a freehand Bezier path with the active
brush applied. Mouse movement is sampled into a point buffer during
the drag; on release the samples are fit to a cubic Bezier spline,
and the resulting path is committed with `jas:stroke-brush` set to
`state.stroke_brush`.

When `state.stroke_brush == null`, the tool degrades to a plain
freehand path tool driven by the native stroke values — equivalent to
the Pencil tool with no brush applied.

**Shortcut:** B.

**Cursor:** crosshair.

## Gestures

All point-buffer operations below target the `"paintbrush"` buffer in
the YAML runtime (`buffer.push` / `buffer.clear`).

Option/Alt is evaluated twice, at different events (time-disjoint):
at `mousedown` it may trigger `edit` mode (see § Edit gesture); at
`mouseup` in `drawing` mode it closes the new path. In `edit` mode,
Alt at release is ignored.

- **Press** — snapshots the document, clears the paintbrush point
  buffer, pushes the press point. If Option/Alt is held, there is a
  non-empty selection, `paintbrush_edit_selected_paths` is on, and
  the press is within `paintbrush_edit_within` px of a selected
  Path, enters `edit` mode with that Path as the target. Otherwise
  enters `drawing` mode.
- **Drag** — pushes each intermediate position into the buffer.
- **Release** —
  - In `drawing` mode: pushes the final position. If Option/Alt is
    held at release, the committed path is closed (last command is
    `Z`). Runs `fit_curve(points, fit_error)` where `fit_error`
    derives from `paintbrush_fidelity` (see § Tool options). Appends
    the resulting Path to the document per § Fill and stroke.
  - In `edit` mode: runs the splice per § Edit gesture. Alt at
    release is ignored.
- **Escape** — cancels the drag, clearing the buffer without
  committing. Applies in both modes.

## Tool options

Double-click the Paintbrush icon in the toolbar opens the Paintbrush
Tool Options dialog. The dialog is declared in
`workspace/dialogs/paintbrush_tool_options.yaml`
(id: `paintbrush_tool_options`) and wired via a new
`tool_options_dialog` field on the tool yaml. The toolbar dispatches
`dialog.open` with that id on icon double-click.
`BLOB_BRUSH_TOOL.md` co-introduces the same `tool_options_dialog`
pattern.

### Options

| Option                           | Widget                             | Default |
|----------------------------------|------------------------------------|---------|
| `paintbrush_fidelity`            | 5-stop slider, Accurate ↔ Smooth   | 3       |
| `paintbrush_fill_new_strokes`    | checkbox                           | false   |
| `paintbrush_keep_selected`       | checkbox                           | true    |
| `paintbrush_edit_selected_paths` | checkbox                           | true    |
| `paintbrush_edit_within`         | slider + numeric (pixels), 1–50    | 12      |

Dialog buttons: **Reset** (restores defaults above; affects dialog
state only, does not commit until OK), **Cancel** (discards edits),
**OK** (writes all five values to `state.paintbrush_*`).

### Fidelity → fit_error mapping

The Fidelity slider has 5 discrete tick stops. Position maps to
`fit_curve` tolerance (pt):

| Tick | Label     | `fit_error` |
|------|-----------|-------------|
| 1    | Accurate  | 0.5         |
| 2    | —         | 2.5         |
| 3    | (default) | 5.0         |
| 4    | —         | 7.5         |
| 5    | Smooth    | 10.0        |

### Option persistence

Option values live in `state.paintbrush_*` (per-document), aligned
with the existing YAML tool-runtime convention. A future migration
to a dedicated preference namespace is out of scope.

## Fill and stroke

Behavior at commit time for a **new** Path (the § Edit gesture has
its own preservation rules):

- **`fill`** — when `paintbrush_fill_new_strokes` is off, `fill =
  none`. When on, `fill = state.fill_color`.
- **`stroke`** — `stroke = state.stroke_color`.
- **`stroke-width`** —
  - When `state.stroke_brush == null`: `state.stroke_width`.
  - When the brush has a `size` parameter (Calligraphic, Scatter,
    Bristle): effective `size` (post-override nominal base value;
    variation is not pre-evaluated).
  - When the brush has no `size` parameter (Art, Pattern):
    `state.stroke_width`.
- **`jas:stroke-brush`** — written when `state.stroke_brush` is
  non-null; absent otherwise.

The brush renderer ignores `stroke-width` when `jas:stroke-brush` is
set; the committed value exists as a fallback for brush removal,
cross-tool export, and non-jas-aware SVG consumers.

## Edit gesture

When the Alt-drag edit is triggered (see § Gestures), the drag is
committed as a splice into the target Path rather than a new
element.

### Target selection at `on_mousedown`

1. For each selected Path element, flatten its commands and find
   the closest point on the polyline to the press location.
2. Pick the Path with the smallest such distance. If that distance
   is ≤ `paintbrush_edit_within`, enter `edit` mode with this Path
   as `target`; record the flat-point index as `entry_idx`.
   Otherwise fall through to `drawing` mode.

### Splice at `on_mouseup`

1. On the target's flattened polyline, find the flat point closest
   to the final drag position. If distance >
   `paintbrush_edit_within`, abort (no commit). Record as
   `exit_idx`.
2. Flatten target's commands with a parallel `cmd_map` (same helper
   the Smooth tool uses — `flatten_with_cmd_map`).
3. Map `[min(entry_idx, exit_idx), max(entry_idx, exit_idx)]` back
   to a command range `[c0..c1]` via `cmd_map`.
4. Prepend `target.commands[c0]`'s start-point to the drag buffer
   (seamless splice; mirrors Smooth § Algorithm step 4).
5. Run `fit_curve(buffer, fit_error)` using the
   `paintbrush_fidelity`-derived `fit_error`.
6. Replace `target.commands[c0..c1]` with the fit output.

### Preservation rules

| Attribute                        | On edit commit                                 |
|----------------------------------|------------------------------------------------|
| `jas:stroke-brush`               | preserved                                      |
| `jas:stroke-brush-overrides`     | preserved                                      |
| `stroke`, `stroke-width`, `fill` | preserved                                      |
| `d`                              | `[c0..c1]` replaced; outside verbatim          |
| Selection                        | target stays selected (independent of `paintbrush_keep_selected`, which governs new-path commits) |

Tool-state values (`state.stroke_brush`, `state.stroke_color`,
`state.fill_color`, `paintbrush_fill_new_strokes`) are **not
consulted** during an edit. Active brush context applies only to
new paths. To rebrush an existing path, use the Brushes panel.

### Edge cases

- **Closed target path, drag crossing the seam.** Flat indices
  wrap; replace the *shorter* of the two possible arcs.
- **Drag returning near the entry point** (`entry_idx ≈
  exit_idx`). Replacement range is a single point; fit-output
  degenerate. Abort and commit nothing.
- **No selection under press.** Alt has no effect; gesture
  degrades silently to normal draw mode.
- **Alt released mid-drag in `edit` mode.** Mode was locked in at
  press; releasing Alt does not exit edit. Only Escape aborts.
- **Alt held throughout, edit didn't trigger (nothing in range).**
  Drawing mode proceeds; if Alt is still held at release, the new
  path closes. The dashed close-hint overlay (see § Overlay) makes
  the closing intent visible during the drag.

## Overlay

A thin black polyline tracking the raw drag. The final committed
path is the smoothed `fit_curve` output outlined by the active
brush at render time, not this preview.

Render type: `buffer_polyline`. Style: `stroke: black; stroke-width: 1;`.

### Close-at-release hint

While in `drawing` mode with Option/Alt held, the overlay
additionally renders a 1 px dashed black line from the current
cursor position back to the press point, indicating
close-at-release. The hint appears or disappears live as Alt is
pressed or released during the drag.

## YAML tool runtime fit

This tool belongs under the YamlTool runtime (per the existing
tool-runtime migration in all four native apps). Handler YAML
lives at `workspace/tools/paintbrush.yaml`. State machine, gesture
set, and overlay shape are declared in YAML; the brush-aware
commit step references the same `add_path_from_buffer` effect used
by Pencil, extended to forward `state.stroke_brush` into the new
path's attributes and to honour `paintbrush_fill_new_strokes`.

## Phase 1 / Phase 2 split

### Phase 1 (this spec)

- Point buffer stores `(x, y)` only — no pressure, tilt, or
  bearing.
- Brush `pressure`, `tilt`, `bearing` variation modes synthesize
  `0.5` (mid-range) at stroke time; these modes are effectively
  inert on canvas commits.
- Plain-path `fill` honours `paintbrush_fill_new_strokes`
  end-to-end.

### Phase 2 (follow-up cross-app project)

- Extend the point buffer to `(x, y, pressure, tilt, bearing)`.
- Extend `fit_curve` to emit a parallel per-anchor sample array.
- Commit stores the samples as `jas:stroke-pressure`,
  `jas:stroke-tilt`, `jas:stroke-bearing` (compact arrays) on the
  Path element.
- Brush renderer consumes the arrays for `pressure` / `tilt` /
  `bearing` variation modes.
- Rollout order: Swift/Rust first (richest stylus APIs), OCaml
  next (GDK axes), Python last (toolkit-dependent — may ship
  inert), Flask via Pointer Events API.

See `BRUSHES.md` § Variation widget for the panel-side note on the
current Phase 1 inertness of these modes on canvas commits.

## Related tools

- **Brushes panel** (`BRUSHES.md`) — sets `state.stroke_brush` and
  defines the per-brush rendering rules this tool consumes.
- **Brush Options dialog** (`BRUSH_OPTIONS_DIALOG.md`) — edits the
  *brush itself* (library parameters, per-instance overrides).
  Distinct from this tool's options dialog, which edits the
  *tool's behavior*.
- **Blob Brush** (`BLOB_BRUSH_TOOL.md`) — paints filled regions
  rather than strokes; uses the active brush's size / shape only.
  Co-introduces the `tool_options_dialog` convention.
- **Pencil** (`PENCIL_TOOL.md`) — analogous freehand gesture
  without brush coupling. Once Pencil inherits the edit gesture
  (cross-referenced from its Known-gaps entry), both tools share
  the same Alt semantics.
- **Smooth** (`SMOOTH_TOOL.md`) — re-fits an existing path with a
  larger error tolerance; useful after a jittery Paintbrush drag.
  Shares the `flatten_with_cmd_map` splice primitive used in §
  Edit gesture.
