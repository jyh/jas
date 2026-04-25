# Shear

The Shear Tool slants the current selection along a configurable
axis, around a configurable reference point. The shear angle and
axis are set either by an interactive canvas drag or by typing
values into the Shear Tool Options dialog.

**Shortcut:** none — accessed as the toolbar alternate of the
Scale Tool (long-press the Scale slot to expose).

**Cursor:** crosshair.

**Toolbar slot:** alternate in the Scale slot. The Rotate Tool
lives in its own slot. All three transformation tools share the
reference-point and dialog-gesture conventions described below;
see `SCALE_TOOL.md` for the canonical description of the shared
infrastructure.

**Tool icon:** a square slanted into a parallelogram. Authored
inline as SVG path data in each app's icons module. A PNG
reference at `examples/shear.png` (when present) is a visual
baseline only — not loaded at runtime.

## Gestures

The Shear tool operates on the current selection. Clicks set the
reference point but never modify the selection. Drag is the
interactive shear gesture. The tool does not double as a selection
tool.

- **Plain click on canvas** (mousedown + mouseup with no movement).
  Sets `state.transform_reference_point` to the click coordinate
  in document space. The reference-point cross moves there. No
  transform applied.
- **Alt/Option click on canvas** (no movement). Sets the reference
  point AND opens the Shear Options dialog. Driven by the
  `tool_options_dialog_on_alt_click` field on the tool yaml
  (introduced by the Scale spec).
- **Drag** (press → move → release). The press point anchors the
  drag and, together with the reference point, defines the
  **shear axis** — the line from reference point to press point.
  Drag perpendicular to that axis shears the selection along it.

  Per-frame shear factor:

  ```text
  axis_unit = normalize(press − ref)
  axis_perp = perpendicular(axis_unit)         (rotated +90°)
  axis_len  = length(press − ref)
  k         = ((cursor − press) · axis_perp) / axis_len
  ```

  The selection is sheared along `axis_unit` by factor `k`, with
  `ref` as the un-sheared origin. When **Shift** is held, the
  shear axis is constrained to the document's horizontal or
  vertical axis (whichever the press → cursor motion is closer
  to); the shear factor is computed in that constrained frame.
- **Escape during drag.** Cancels the in-progress shear; the
  document reverts to its pre-drag state. Reference point is
  unchanged.
- **Double-click toolbar icon.** Opens the Shear Options dialog
  via the existing `tool_options_dialog` field. Reference point
  is not modified.

### Selection-state matrix

| State                            | Plain click          | Alt-click                                                | Drag                            |
|----------------------------------|----------------------|----------------------------------------------------------|---------------------------------|
| No selection                     | No-op                | Dialog opens, OK greyed; reference point stays `null`    | No-op (no target)               |
| Selection exists, click anywhere | Sets reference point | Sets reference point + opens dialog                      | Shears the existing selection   |

## Reference point

The reference point is the un-sheared origin (points lying on the
shear axis through the reference point are unmoved by the shear).
It is **shared across the transform-tool family** (Scale, Rotate,
Shear) via `state.transform_reference_point`.

Defaults, lifetime, and visibility are identical to Scale and
Rotate. See `SCALE_TOOL.md` § Reference point for the canonical
description.

## Tool Options dialog

The Shear Options dialog is summoned by:

- Double-clicking the Shear icon in the toolbar.
- Alt/Option clicking on canvas (also sets the reference point at
  the click coordinate per § Gestures).

Declared in `workspace/dialogs/shear_options.yaml`
(id: `shear_options`). The dialog is modal.

### Options

| Field             | Widget                                            | State key                  | Default        |
|-------------------|---------------------------------------------------|----------------------------|----------------|
| Shear Angle       | numeric (°)                                       | `state.shear_angle`        | `0.0`          |
| Axis              | radio (Horizontal / Vertical / Custom)            | `state.shear_axis`         | `"horizontal"` |
| Custom axis angle | numeric (°), enabled only when Axis = Custom      | `state.shear_axis_angle`   | `0.0`          |
| Preview           | checkbox                                          | `state.shear_preview`      | `true`         |

The **Shear Angle** is the slant angle in degrees; positive values
shear the selection in the `+axis_perp` direction. The **Axis**
picks the direction along which points slide (horizontal: x-axis
is fixed, points above the reference slide right with positive
angle; vertical: y-axis is fixed, points right of the reference
slide up with positive angle; custom: user-specified angle in
degrees from horizontal).

### Layout

```yaml
dialog:
- .row: ["Shear Angle:", SHEAR_ANGLE]
- .group "Axis":
    - .row: SHEAR_AXIS_HORIZONTAL_RADIO
    - .row: SHEAR_AXIS_VERTICAL_RADIO
    - .row:
        - SHEAR_AXIS_CUSTOM_RADIO
        - ["Angle:", SHEAR_AXIS_ANGLE]
- .row: SHEAR_PREVIEW_CHECKBOX
- .row.buttons: [RESET, COPY, CANCEL, OK]
```

### Buttons

- **Reset**: restores the four `state.shear_*` values to their
  defaults above. Affects dialog state only; does not commit until
  OK.
- **Copy**: applies the shear to a duplicate. Selection moves to
  the duplicate. Closes the dialog.
- **Cancel**: discards dialog edits and any preview overlay. The
  reference point is **not** reverted.
- **OK**: writes the dialog values to state, runs `doc.shear.apply`
  on the selection, closes the dialog.

### Preview

While the dialog is open with **Preview** checked, the canvas
re-renders the selection live with the dialog's current angle and
axis applied around the current reference point. Implementation:
per-element transform-matrix override returned by
`doc.shear.preview_render` and consumed by the renderer. No
document mutation occurs until OK.

## Apply behavior

`doc.shear.preview_render` (returns matrices) and
`doc.shear.apply` (mutates the document) consume:

- The current selection.
- Shear angle (degrees) and axis unit-vector, derived from the
  dialog or the drag.
- `state.transform_reference_point` (or default = selection-bounds
  center).
- A `copy: bool` flag (true when invoked via the Copy button).

For each element in the selection (deduplicated by tree-path
identity per `project_element_identity_paths.md`), every coordinate
in the element's path commands or shape parameters is mapped via
the affine shear with the given angle and axis around the
reference point.

Pure shear has determinant 1 — areas are preserved — so stroke
widths are unchanged and there is no Scale Strokes equivalent in
this dialog.

Shape primitives whose representation cannot encode arbitrary
shear (e.g., `circle`, `ellipse`, `rounded_rect`, `rect`) are
converted to a generic Path on apply; the geometry is accurate
post-shear. Lines, polylines, polygons, and stars transform their
vertices in place and remain in their primitive types.

When `copy` is true, a duplicate of the selection is created in
the same parent (immediately above the original in z-order); the
shear is applied to the duplicate; the original is unmodified.
The active selection moves to the duplicate.

### LiveElement / CompoundShape

A CompoundShape is sheared by recursing into its source operands
and applying the shear there; the boolean op then re-evaluates on
the new operands. Live-ness is preserved. Selection deduplication
prevents an operand also present in the selection from being
double-sheared. Identical mechanics to the Scale spec's LiveElement
section.

## Overlay

Two overlay render types are active during interaction:

- **`reference_point_cross`** — described in `SCALE_TOOL.md`.
  Drawn whenever the tool is active and a selection exists.
- **`bbox_ghost`** — a 1 px dashed parallelogram outlining the
  selection's *post-shear* union bounding box, rendered live
  during the drag. Style: `stroke: #4A9EFF; stroke-width: 1;
  stroke-dasharray: 4 2; fill: none`. The render type accepts a
  2×3 affine transform matrix; for Shear the matrix is the shear
  around the reference point. Removed on release.

## State persistence

Per-document state keys (`workspace/state.yaml`):

| State key                          | Type     | Default        |
|------------------------------------|----------|----------------|
| `state.transform_reference_point`  | point?   | `null`         |
| `state.shear_angle`                | float    | `0.0`          |
| `state.shear_axis`                 | enum     | `"horizontal"` |
| `state.shear_axis_angle`           | float    | `0.0`          |
| `state.shear_preview`              | bool     | `true`         |

`state.transform_reference_point` is shared with Scale and Rotate.
The four `shear_*` keys are Shear-specific.

## Cross-app artifacts

- `workspace/tools/shear.yaml` — tool spec (id `shear`, cursor, no
  shortcut, gesture handlers, `tool_options_dialog: shear_options`,
  `tool_options_dialog_on_alt_click: true`, declared as the
  toolbar alternate of `scale`).
- `workspace/dialogs/shear_options.yaml` — dialog layout, state-key
  bindings, button actions.
- `workspace/state.yaml` — declares the four `shear_*` keys; the
  shared `state.transform_reference_point` key is declared by the
  Scale spec.
- `workspace/actions.yaml` — action wiring.
- `workspace/dialogs/tool_alternates.yaml` — declares Shear as the
  alternate of Scale in the toolbar.
- The `tool_options_dialog_on_alt_click` field and the
  `reference_point_cross` / `bbox_ghost` overlay render types are
  introduced by the Scale spec; Shear consumes them.
- New effects **`doc.shear.preview_render`** and
  **`doc.shear.apply`** added to all four native apps.
- The shared transform math in `algorithms/transform_apply` gains
  a `shear_apply` entry alongside `scale_apply` and
  `rotate_apply`.

## Phase 1 / Phase 2 split

### Phase 1 (this spec)

- Five-cell gesture set: plain click, Alt-click, drag, escape,
  dblclick on icon.
- Reference point shared with Scale / Rotate via
  `state.transform_reference_point`.
- Shear Options dialog: Shear Angle, Axis (Horizontal / Vertical
  / Custom Angle), Preview, Copy, OK, Cancel, Reset.
- Apply effect with axis-aligned and custom-axis shear. Primitive
  → Path conversion for circles, ellipses, rects, rounded rects.
- LiveElement (CompoundShape) handled via source-operand
  recursion with selection-deduplication.
- Reuses `reference_point_cross` and `bbox_ghost` overlay render
  types introduced by Scale.
- Per-app implementation in CLAUDE.md propagation order:
  Rust → Swift → OCaml → Python.

### Phase 2 (deferred)

- **Transform Again** (`Cmd/Ctrl + D`) — repeat the most recent
  transformation. Cross-tool with Scale and Rotate.
- **Transform Each** — per-object multi-selection shear around
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
  the shear to a duplicate of the selection.

## Related tools

- **Scale Tool (`S`)** — primary in the same toolbar slot (Shear
  is the alternate). Same reference point, same dialog gesture.
  Canonical description of shared transform-family infrastructure.
- **Rotate Tool (`R`)** — same transformation family, separate
  toolbar slot. Same reference point, same dialog gesture. Pivots
  rather than slants.
- **Selection Tool (`V`)** — does not provide a freeform shear
  affordance; bounding-box manipulation is for resize and rotate
  only.
- **Magic Wand Tool (`Y`)** / **Paintbrush** / **Blob Brush** —
  share the dblclick-icon-opens-options pattern.
