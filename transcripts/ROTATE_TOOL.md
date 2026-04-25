# Rotate

The Rotate Tool pivots the current selection around a configurable
reference point. The rotation angle is set either by an interactive
canvas drag or by typing a degree value into the Rotate Tool
Options dialog.

**Shortcut:** `R`

**Cursor:** crosshair.

**Toolbar slot:** primary in its own slot. The Scale and Shear
Tools share a separate slot. All three transformation tools share
the reference-point and dialog-gesture conventions described
below; see `SCALE_TOOL.md` for the canonical description of the
shared infrastructure.

**Tool icon:** a curved arrow indicating circular motion. Authored
inline as SVG path data in each app's icons module (matches the
Pencil / Paintbrush / Blob Brush / Magic Wand convention). A PNG
reference at `examples/rotate.png` (when present) is a visual
baseline only — not loaded at runtime.

## Gestures

The Rotate tool operates on the current selection. Clicks set the
reference point but never modify the selection. Drag is the
interactive rotation gesture. The tool does not double as a
selection tool — clicking on a non-selected element does not
select it.

- **Plain click on canvas** (mousedown + mouseup with no movement).
  Sets `state.transform_reference_point` to the click coordinate
  in document space. The reference-point cross moves there. No
  transform applied.
- **Alt/Option click on canvas** (no movement). Sets the reference
  point AND opens the Rotate Options dialog. Driven by the
  `tool_options_dialog_on_alt_click` field on the tool yaml
  (introduced by the Scale spec).
- **Drag** (press → move → release). The press point anchors the
  drag — it does NOT relocate the reference point. Per-frame
  rotation angle is computed as

  ```text
  θ = atan2(cursor.y − ref.y, cursor.x − ref.x)
    − atan2(press.y  − ref.y, press.x  − ref.x)
  ```

  When **Shift** is held, θ is rounded to the nearest 45° tick.
  On release, `doc.rotate.apply` commits the transformation.
- **Escape during drag.** Cancels the in-progress rotation; the
  document reverts to its pre-drag state. Reference point is
  unchanged.
- **Double-click toolbar icon.** Opens the Rotate Options dialog
  via the existing `tool_options_dialog` field. Reference point
  is not modified.

### Selection-state matrix

| State                            | Plain click          | Alt-click                                                | Drag                            |
|----------------------------------|----------------------|----------------------------------------------------------|---------------------------------|
| No selection                     | No-op                | Dialog opens, OK greyed; reference point stays `null`    | No-op (no target)               |
| Selection exists, click anywhere | Sets reference point | Sets reference point + opens dialog                      | Rotates the existing selection  |

## Reference point

The reference point is the pivot around which the selection
rotates. It is **shared across the transform-tool family** (Scale,
Rotate, Shear) via `state.transform_reference_point`.

- **Default** (key is `null` AND a selection exists): the union
  bounding-box center of the selection.
- **Custom**: set by a click on canvas (plain or Alt) per
  § Gestures. Stored in absolute document coordinates.
- **Lifetime**: resets to `null` on any selection change. Tool
  deactivation does not reset.
- **Visibility**: rendered only when (a) the active tool is Scale,
  Rotate, or Shear AND (b) a selection exists.

The reference-point cross overlay (render type
`reference_point_cross`) is described in `SCALE_TOOL.md` §
Reference-point cross overlay.

## Tool Options dialog

The Rotate Options dialog is summoned by:

- Double-clicking the Rotate icon in the toolbar.
- Alt/Option clicking on canvas (also sets the reference point at
  the click coordinate per § Gestures).

Declared in `workspace/dialogs/rotate_options.yaml`
(id: `rotate_options`). The dialog is modal.

### Options

| Field    | Widget       | State key                | Default |
|----------|--------------|--------------------------|---------|
| Angle    | numeric (°)  | `state.rotate_angle`     | `0.0`   |
| Preview  | checkbox     | `state.rotate_preview`   | `true`  |

### Layout

```yaml
dialog:
- .row: ["Angle:", ROTATE_ANGLE]
- .row: ROTATE_PREVIEW_CHECKBOX
- .row.buttons: [RESET, COPY, CANCEL, OK]
```

### Buttons

- **Reset**: restores the two `state.rotate_*` values to their
  defaults above. Affects dialog state only; does not commit until
  OK.
- **Copy**: applies the rotation to a *duplicate* of the selection
  (placed in the same parent immediately above the original in
  z-order). Original is untouched. Selection moves to the
  duplicate. Closes the dialog.
- **Cancel**: discards dialog edits and any preview overlay. The
  reference point is **not** reverted.
- **OK**: writes the dialog values to state, runs `doc.rotate.apply`
  on the selection, closes the dialog.

### Preview

While the dialog is open with **Preview** checked, the canvas
re-renders the selection live with the dialog's current angle
applied around the current reference point. Implementation: a
per-element transform-matrix override returned by
`doc.rotate.preview_render` and consumed by the renderer. No
document mutation occurs until OK.

## Apply behavior

`doc.rotate.preview_render` (returns matrices) and
`doc.rotate.apply` (mutates the document) consume:

- The current selection.
- `θ` — rotation angle in degrees, derived from the dialog or
  the drag.
- `state.transform_reference_point` (or default = selection-bounds
  center).
- A `copy: bool` flag (true when invoked via the Copy button).

For each element in the selection (deduplicated by tree-path
identity per `project_element_identity_paths.md`), every coordinate
in the element's path commands or shape parameters is mapped via
the affine rotation by `θ` around the reference point.

Rotation is rigid: stroke widths, corner radii, and other scalar
attributes are unchanged. There is no Scale Strokes or Scale
Corners option for Rotate.

Some shape primitives may need conversion when their representation
cannot encode arbitrary rotation (e.g., an axis-aligned `rect`
becomes a generic Path under non-axis-aligned rotation; an
axis-aligned `ellipse` similarly). Implementations may convert to
Path or extend primitives with a rotation field; the spec's
contract is that rendered output is identical.

When `copy` is true, a duplicate of the selection is created in
the same parent (immediately above the original in z-order); the
rotation is applied to the duplicate; the original is unmodified.
The active selection moves to the duplicate.

### LiveElement / CompoundShape

A CompoundShape is rotated by recursing into its source operands
and applying the rotation there; the boolean op then re-evaluates
on the new operands. Live-ness is preserved. Selection
deduplication (above) prevents an operand also present in the
selection from being double-rotated. Identical mechanics to the
Scale spec's LiveElement section.

## Overlay

Two overlay render types are active during interaction:

- **`reference_point_cross`** — described in `SCALE_TOOL.md`.
  Drawn whenever the tool is active and a selection exists.
- **`bbox_ghost`** — a 1 px dashed rectangle outlining the
  selection's *post-rotation* union bounding box, rendered live
  during the drag. Style: `stroke: #4A9EFF; stroke-width: 1;
  stroke-dasharray: 4 2; fill: none`. The render type accepts a
  2×3 affine transform matrix; for Rotate the matrix is the
  rotation around the reference point. Removed on release.

## State persistence

Per-document state keys (`workspace/state.yaml`):

| State key                          | Type     | Default |
|------------------------------------|----------|---------|
| `state.transform_reference_point`  | point?   | `null`  |
| `state.rotate_angle`               | float    | `0.0`   |
| `state.rotate_preview`             | bool     | `true`  |

`state.transform_reference_point` is shared with Scale and Shear.
The two `rotate_*` keys are Rotate-specific.

## Cross-app artifacts

- `workspace/tools/rotate.yaml` — tool spec (id `rotate`, cursor,
  shortcut `R`, gesture handlers, `tool_options_dialog: rotate_options`,
  `tool_options_dialog_on_alt_click: true`).
- `workspace/dialogs/rotate_options.yaml` — dialog layout, state-key
  bindings, button actions.
- `workspace/state.yaml` — declares the two `rotate_*` keys; the
  shared `state.transform_reference_point` key is declared by the
  Scale spec.
- `workspace/actions.yaml` — action wiring for OK / Cancel / Copy /
  Reset.
- The `tool_options_dialog_on_alt_click` field and the
  `reference_point_cross` / `bbox_ghost` overlay render types are
  introduced by the Scale spec; Rotate consumes them.
- New effects **`doc.rotate.preview_render`** and
  **`doc.rotate.apply`** added to all four native apps.
- The shared transform math in `algorithms/transform_apply` gains
  a `rotate_apply` entry alongside `scale_apply`.

## Phase 1 / Phase 2 split

### Phase 1 (this spec)

- Five-cell gesture set: plain click, Alt-click, drag, escape,
  dblclick on icon.
- Reference point shared with Scale / Shear via
  `state.transform_reference_point`.
- Rotate Options dialog: Angle, Preview, Copy, OK, Cancel, Reset.
- Apply effect with rigid rotation (no stroke or corner options).
- LiveElement (CompoundShape) handled via source-operand recursion
  with selection-deduplication.
- Reuses `reference_point_cross` and `bbox_ghost` overlay render
  types introduced by Scale.
- Per-app implementation in CLAUDE.md propagation order:
  Rust → Swift → OCaml → Python.

### Phase 2 (deferred)

- **Transform Again** (`Cmd/Ctrl + D`) — repeat the most recent
  transformation. Cross-tool with Scale and Shear.
- **Transform Each** — per-object multi-selection rotation around
  individual centers. Memory:
  `project_transform_each_deferred.md`.
- **Transform Patterns / Transform Objects** — pair of dialog
  options that let the user transform fill patterns independently
  of geometry. Deferred until pattern fills exist in the model.
  Memory: `project_transform_patterns_deferred.md`.
- **9-position reference-point widget** — UI affordance to pick a
  corner / midpoint / center of the selection's bounding box as
  the reference point.
- **Alt-during-drag = Copy mode** — holding Alt at release commits
  the rotation to a duplicate of the selection.

## Related tools

- **Scale Tool (`S`)** — same toolbar family, same reference
  point, same dialog gesture (dblclick icon or Alt-click canvas).
  Resizes rather than rotates. Canonical description of shared
  transform-family infrastructure.
- **Shear Tool** — toolbar alternate of Scale (long-press the
  Scale slot to expose). Same reference point, same dialog
  gesture. Slants rather than rotates.
- **Selection Tool (`V`)** — bounding-box rotation handle (just
  outside the corner handles) provides quick freeform rotation
  without an explicit reference point.
- **Magic Wand Tool (`Y`)** / **Paintbrush** / **Blob Brush** —
  share the dblclick-icon-opens-options pattern.
