# Scale

The Scale Tool resizes the current selection around a configurable
reference point. The scale factor is set either by an interactive
canvas drag or by typing percentages into the Scale Tool Options
dialog. Scaling can optionally include stroke widths and rounded-
rectangle corner radii.

**Shortcut:** `S`

**Cursor:** crosshair.

**Toolbar slot:** primary in a slot with the **Shear Tool** as
alternate. Long-press the slot exposes both. The Rotate Tool lives
in its own slot but shares the same reference-point and dialog-
gesture conventions.

**Tool icon:** a small square being extruded into a larger one
(classic resize iconography). Authored inline as SVG path data in
each app's icons module (matches the Pencil / Paintbrush / Blob
Brush / Magic Wand convention). The PNG reference
`examples/scale.png` is a visual baseline only — not loaded at
runtime.

## Gestures

The Scale tool operates on the current selection. Clicks set the
reference point but never modify the selection. Drag is the
interactive scale gesture. The tool does not double as a selection
tool — clicking on a non-selected element does not select it.

- **Plain click on canvas** (mousedown + mouseup with no movement).
  Sets `state.transform_reference_point` to the click coordinate
  in document space. The reference-point cross moves there. No
  transform applied.
- **Alt/Option click on canvas** (mousedown + mouseup with no
  movement). Sets the reference point AND opens the Scale Options
  dialog. Driven by the new `tool_options_dialog_on_alt_click`
  field on the tool yaml.
- **Drag** (press → move → release). The press point anchors the
  drag — it does NOT relocate the reference point. Per-frame scale
  factors are computed as

  ```text
  sx = (cursor.x − ref.x) / (press.x − ref.x)
  sy = (cursor.y − ref.y) / (press.y − ref.y)
  ```

  with sign preserved (dragging the cursor through the reference
  point on an axis flips the selection on that axis). When **Shift**
  is held, the factors are forced uniform: both axes take the
  signed geometric mean `sign · √(|sx · sy|)`. On release,
  `doc.scale.apply` commits the transformation.
- **Escape during drag.** Cancels the in-progress scale; the
  document reverts to its pre-drag state. Reference point is
  unchanged.
- **Double-click toolbar icon.** Opens the Scale Options dialog
  via the existing `tool_options_dialog` field. Reference point is
  not modified.

### Selection-state matrix

| State                              | Plain click               | Alt-click                                                 | Drag                            |
|------------------------------------|---------------------------|-----------------------------------------------------------|---------------------------------|
| No selection                       | No-op                     | Dialog opens, OK greyed; reference point stays `null`     | No-op (no target)               |
| Selection exists, click anywhere   | Sets reference point      | Sets reference point + opens dialog                       | Scales the existing selection   |

"Click anywhere" means: empty canvas, on the selection itself, or
on an unselected element. The Scale tool treats them identically —
the click is purely about positioning the reference point.

## Reference point

The reference point is the origin around which the transformation
pivots. It is **shared across the transform-tool family** (Scale,
Rotate, Shear) via `state.transform_reference_point` so a user
who switches between them keeps the same custom origin.

- **Default position** (key is `null` AND a selection exists): the
  union bounding-box center of the selection.
- **Custom position**: set by a click on canvas (plain or Alt) per
  § Gestures. Stored in absolute document coordinates.
- **Lifetime**: resets to `null` on any selection change. Tool
  deactivation does not reset.
- **Visibility**: rendered only when (a) the active tool is Scale,
  Rotate, or Shear AND (b) a selection exists. Hidden whenever
  there is no selection.

### Reference-point cross overlay

Render type: **`reference_point_cross`**. Geometry: a 12 px
crosshair (two perpendicular line segments) plus a 2 px center
dot. Style: `stroke: #4A9EFF; stroke-width: 1; fill: #4A9EFF`
(dot only). Drawn above the selection in z-order. Coordinates are
document-space, so the cross survives zoom and pan.

## Tool Options dialog

The Scale Options dialog is summoned by:

- Double-clicking the Scale icon in the toolbar.
- Alt/Option clicking on canvas (also sets the reference point at
  the click coordinate per § Gestures).

Declared in `workspace/dialogs/scale_options.yaml`
(id: `scale_options`). The dialog is modal.

### Options

| Field                       | Widget                                | State key                       | Default |
|-----------------------------|---------------------------------------|---------------------------------|---------|
| Scale mode                  | radio (Uniform / Non-Uniform)         | `state.scale_uniform`           | `true`  |
| Uniform percentage          | numeric (%)                           | `state.scale_uniform_pct`       | `100.0` |
| Horizontal percentage       | numeric (%)                           | `state.scale_horizontal_pct`    | `100.0` |
| Vertical percentage         | numeric (%)                           | `state.scale_vertical_pct`      | `100.0` |
| Scale Strokes               | checkbox                              | `state.scale_strokes`           | `true`  |
| Scale Corners               | checkbox                              | `state.scale_corners`           | `false` |
| Preview                     | checkbox                              | `state.scale_preview`           | `true`  |

When the **Uniform** radio is selected, the Horizontal and Vertical
fields are disabled and the Uniform percentage drives the
transformation. When **Non-Uniform** is selected, the Uniform field
is disabled and the Horizontal / Vertical fields are independently
editable.

### Layout

Two grouped sections plus a button row:

```yaml
dialog:
- .group "Scale":
    - .row: [SCALE_UNIFORM_RADIO, "Uniform:", SCALE_UNIFORM_PCT]
    - .row: SCALE_NONUNIFORM_RADIO
    - .row.indent: ["Horizontal:", SCALE_HORIZONTAL_PCT]
    - .row.indent: ["Vertical:", SCALE_VERTICAL_PCT]
- .group "Options":
    - .row: SCALE_STROKES_CHECKBOX
    - .row: SCALE_CORNERS_CHECKBOX
- .row: SCALE_PREVIEW_CHECKBOX
- .row.buttons: [RESET, COPY, CANCEL, OK]
```

### Buttons

- **Reset**: restores the seven `state.scale_*` values to their
  defaults above. Affects dialog state only; does not commit until
  OK.
- **Copy**: applies the transformation to a *duplicate* of the
  selection (placed in the same parent immediately above the
  original in z-order). Original is untouched. Selection moves to
  the duplicate. Closes the dialog.
- **Cancel**: discards dialog edits and any preview overlay. The
  reference point is **not** reverted — the canvas click that
  opened the dialog already committed it.
- **OK**: writes the dialog values to state, runs `doc.scale.apply`
  on the selection, closes the dialog.

### Preview

While the dialog is open with **Preview** checked, the canvas
re-renders the selection live with the dialog's current values
applied. Implementation: a per-element transform-matrix override
returned by `doc.scale.preview_render` and consumed by the
renderer. No document mutation occurs until OK.

The preview honors all dialog options: scale factors, current
reference point, `scale_strokes` (stroke widths in the preview
update accordingly), and `scale_corners` (rounded-rect corner
radii in the preview update accordingly). Toggling Preview off
removes the override and the canvas reverts to the pre-dialog
rendering.

## Apply behavior

Both `doc.scale.preview_render` (returns matrices for the renderer
overlay) and `doc.scale.apply` (mutates the document) consume:

- The current selection.
- `(sx, sy)` — scale factors derived from the dialog or the drag.
- `state.transform_reference_point` (or default = selection-bounds
  center).
- `state.scale_strokes`.
- `state.scale_corners`.
- A `copy: bool` flag (true when invoked via the Copy button).

For each element in the selection (deduplicated by tree-path
identity per `project_element_identity_paths.md`):

1. **Geometry.** Every coordinate in the element's path commands
   or shape parameters is mapped via the affine transform centered
   at the reference point with factors `(sx, sy)`.
2. **Stroke width.** When `state.scale_strokes` is true, the
   element's `stroke-width` is multiplied by the unsigned
   geometric mean `√(|sx · sy|)`. When false, `stroke-width` is
   preserved. For elements with `jas:stroke-brush` set, the
   per-instance `size` override (or, in its absence, the brush's
   nominal size) is scaled by the same factor.
3. **Rounded corners.** When `state.scale_corners` is true and the
   element is a `rounded_rect`: `rx ← rx · |sx|` and
   `ry ← ry · |sy|`. Other element types: no-op. When
   `state.scale_corners` is false: `rx` / `ry` are preserved.

When `copy` is true, a duplicate of the selection is created in
the same parent (immediately above the original in z-order); the
transformation is applied to the duplicate; the original is
unmodified. The active selection moves to the duplicate.

### LiveElement / CompoundShape

A CompoundShape (the first conformer of the LiveElement framework
per `project_live_element_framework.md`) is scaled by recursing
into its source operands and applying the transform there. The
boolean op then re-evaluates on the new operands; live-ness is
preserved.

If the user's selection contains both a CompoundShape and one of
its operands, the deduplication pass (above) collapses them so the
operand is not double-scaled.

## Overlay

Two overlay render types are active during interaction:

- **`reference_point_cross`** — described in § Reference point
  cross overlay. Drawn whenever the tool is active and a selection
  exists.
- **`bbox_ghost`** — a 1 px dashed rectangle outlining the
  selection's *post-transform* union bounding box, rendered live
  during the drag. Style: `stroke: #4A9EFF; stroke-width: 1;
  stroke-dasharray: 4 2; fill: none`. Removed on release.

Both are added to all four native apps' YAML overlay runtimes,
which were brought to feature parity on the `overlay-phase-5b`
baseline (see `project_yaml_tool_overlay_stubs.md`).

## State persistence

Per-document state keys (`workspace/state.yaml`):

| State key                          | Type     | Default |
|------------------------------------|----------|---------|
| `state.transform_reference_point`  | point?   | `null`  |
| `state.scale_uniform`              | bool     | `true`  |
| `state.scale_uniform_pct`          | float    | `100.0` |
| `state.scale_horizontal_pct`       | float    | `100.0` |
| `state.scale_vertical_pct`         | float    | `100.0` |
| `state.scale_strokes`              | bool     | `true`  |
| `state.scale_corners`              | bool     | `false` |
| `state.scale_preview`              | bool     | `true`  |

`state.transform_reference_point` lives in the transform-family
namespace (not under `scale_*`) because Rotate and Shear share it.
The four `scale_*_pct` keys persist the most-recent dialog values
so re-opening the dialog (after Cancel or after a previous OK)
shows the last entered values.

## Cross-app artifacts

- `workspace/tools/scale.yaml` — tool spec (id `scale`, cursor,
  shortcut `S`, gesture handlers, `tool_options_dialog: scale_options`,
  `tool_options_dialog_on_alt_click: true`).
- `workspace/dialogs/scale_options.yaml` — dialog layout, state-key
  bindings, button actions.
- `workspace/state.yaml` — declares the eight state keys above.
- `workspace/actions.yaml` — action wiring for OK / Cancel / Copy /
  Reset.
- A new **`tool_options_dialog_on_alt_click`** boolean field on
  tool yaml, parallel to the existing `tool_options_dialog`. The
  YAML tool runtime's canvas-click dispatcher checks this field on
  Alt-click; when truthy, it writes `state.transform_reference_point`
  to the click coordinate and dispatches `open_dialog` with the
  configured dialog id.
- New overlay render types **`reference_point_cross`** and
  **`bbox_ghost`** added to the overlay runtime in all four
  native apps (Rust, Swift, OCaml, Python).
- New effects **`doc.scale.preview_render`** (returns per-element
  matrices for the renderer) and **`doc.scale.apply`** (mutates
  the document).
- Shared transform math (affine transformation around a reference
  point with `(sx, sy)` factors, plus the stroke and corner rules)
  lives in `algorithms/transform_apply` so Rotate and Shear can
  reuse the framework. Cross-language parity is mechanical; no
  new geometry primitives are required.

## Phase 1 / Phase 2 split

### Phase 1 (this spec)

- Five-cell gesture set: plain click, Alt-click, drag, escape,
  dblclick on icon.
- Reference point with cyan-blue crosshair overlay, shared across
  Scale / Rotate / Shear via `state.transform_reference_point`.
- Scale Options dialog: Uniform / Non-Uniform mode, Scale Strokes,
  Scale Corners, Preview, Copy, OK, Cancel, Reset.
- Apply effect with strokes (geometric mean for non-uniform) and
  corners (axis-independent for non-uniform).
- LiveElement (CompoundShape) handled via source-operand recursion
  with selection-deduplication.
- Overlay render types `reference_point_cross` and `bbox_ghost`.
- Per-app implementation in CLAUDE.md propagation order:
  Rust → Swift → OCaml → Python.

### Phase 2 (deferred)

- **Transform Each** — per-object multi-selection scaling around
  individual centers. Will surface as `Object > Transform > Transform
  Each` covering Scale / Rotate / Shear together. Memory:
  `project_transform_each_deferred.md`.
- **Transform Patterns / Transform Objects** — pair of dialog
  options that let the user transform fill patterns independently
  of geometry. Deferred until pattern fills exist in the document
  model. Memory: `project_transform_patterns_deferred.md`.
- **Live effects** — when a live-effects model exists, Scale
  Strokes' label extends to "Scale Strokes & Effects" and the
  apply effect grows to scale effect parameters proportionally.
- **Per-anchor live corners** — when arbitrary paths grow per-anchor
  corner radii, Scale Corners extends to cover them. Memory:
  `project_live_corners_deferred.md`.
- **9-position reference-point widget** — UI affordance to pick a
  corner / midpoint / center of the selection's bounding box as
  the reference point, instead of clicking on canvas.
- **Alt-during-drag = Copy mode** — holding Alt at release commits
  the scale to a duplicate of the selection, mirroring the dialog's
  Copy button.

## Related tools

- **Rotate Tool (`R`)** — same toolbar family, same reference
  point, same dialog gesture (dblclick icon or Alt-click canvas).
  Pivots rather than scales.
- **Shear Tool** — toolbar alternate of Scale (long-press the
  slot). Same reference point, same dialog gesture. Slants rather
  than scales.
- **Selection Tool (`V`)** — bounding-box-handle drag scales
  without an explicit reference point; cheaper for quick freeform
  resize. Uses the bounding box's opposite handle as an implicit
  origin.
- **Magic Wand Tool (`Y`)** — co-introduces the dblclick-icon-
  opens-options pattern (in panel form rather than dialog form).
- **Paintbrush / Blob Brush** — share the dblclick-icon convention
  for tool-options dialog.
