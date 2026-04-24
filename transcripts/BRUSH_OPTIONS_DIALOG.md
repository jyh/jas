# Brush Options dialog

The Brush Options dialog edits a brush's parameters. It is the entry
point for creating new brushes, editing existing library brushes, and
overriding brush parameters on a single stroke. This document is the
requirements description from which
`workspace/dialogs/brush_options.yaml` is generated.

The Brushes panel (see `BRUSHES.md`) is the primary launcher for this
dialog.

## Modes

The dialog has three modes. Mode is set by the launcher and affects
title, the type picker's editability, the OK side-effect, and whether
the Apply to Strokes confirm dialog fires.

| Mode            | Entry point                                                    | Title                                | Writes to                          | OK side-effect                                       |
|-----------------|----------------------------------------------------------------|--------------------------------------|------------------------------------|------------------------------------------------------|
| `create`        | `NEW_BRUSH_BUTTON`; **New Brush** menu item; drag-in to empty area or `BRUSH_LIBRARY_SECTION` header | "New Brush — `<Type>`" | new library brush appended to `panel.selected_library` | brush appended; selection updated to the new slug |
| `library_edit`  | double-click a `BRUSH_TILE`; **Brush Options…** menu item      | "`<Brush Name>` Options"             | master library brush in place      | library mutated; **Apply to Strokes** confirm fires  |
| `instance_edit` | `BRUSH_OPTIONS_FOR_SELECTION_BUTTON`                           | "`<Brush Name>` Options — This Stroke Only" | `state.stroke_brush_overrides` on selected paths | overrides written; no confirm dialog |

Type picker editability:

- `create` — `BRUSH_TYPE_RADIO` enabled. Switching type discards
  per-type fields and re-seeds defaults.
- `library_edit` and `instance_edit` — `BRUSH_TYPE_RADIO` disabled.
  Conversion between types is not supported (parameter sets are too
  divergent to round-trip).

## Controls

Shared across modes:

- `BRUSH_TYPE_RADIO` — five mutually-exclusive `icon_toggle` buttons:
  Calligraphic, Scatter, Art, Pattern, Bristle. Each shows the
  corresponding `brush_type_*` glyph from the workspace icon set.
  Default `art` in `create`; matches the brush's current type
  otherwise.
- `NAME_INPUT` — `text_input` for the brush's display name. Required
  (cannot be empty when OK is clicked). In `create`, defaults to
  `"<Type> Brush <N>"` where N is the next free integer in the target
  library.
- `PREVIEW_STRIP` — a non-interactive render area showing the brush
  applied to a fixed S-curve demo stroke. Updates live as parameter
  values change. Roughly 240 × 60 pixels.
- `OK_BUTTON` — primary `button`. Disabled while `NAME_INPUT` is empty
  or any required artwork is missing.
- `CANCEL_BUTTON` — secondary `button`. Discards all changes.

The dialog body between `NAME_INPUT` and `PREVIEW_STRIP` renders one
of five per-type parameter forms, controlled by the active type.

## Per-type body widget IDs

Each row is a control in the dialog body. `—` means the row is not
present for that type. `+ variation` indicates a composite variation
widget (see Variation widget below).

| Parameter        | Calligraphic              | Scatter                         | Art                          | Pattern                                       | Bristle                  |
|------------------|---------------------------|---------------------------------|------------------------------|-----------------------------------------------|--------------------------|
| Angle            | `CAL_ANGLE_COMBO` + variation | —                           | —                            | —                                             | —                        |
| Roundness        | `CAL_ROUNDNESS_COMBO` + variation | —                       | —                            | —                                             | —                        |
| Size             | `CAL_SIZE_COMBO` + variation | `SCAT_SIZE_COMBO` + variation | —                            | —                                             | `BRI_SIZE_COMBO`         |
| Spacing          | —                         | `SCAT_SPACING_COMBO` + variation | —                          | `PAT_SPACING_COMBO`                           | —                        |
| Scatter          | —                         | `SCAT_SCATTER_COMBO` + variation | —                          | —                                             | —                        |
| Rotation         | —                         | `SCAT_ROTATION_COMBO` + variation | —                         | —                                             | —                        |
| Artwork preview  | —                         | `SCAT_ARTWORK_PREVIEW`          | `ART_ARTWORK_PREVIEW`        | `PAT_TILE_STRIP` (5 slots: side, start, end, outer, inner) | —                |
| Choose Artwork…  | —                         | `SCAT_CHOOSE_ARTWORK_BUTTON`    | `ART_CHOOSE_ARTWORK_BUTTON`  | `PAT_CHOOSE_ARTWORK_BUTTON` (operates on selected slot) | —                |
| Direction        | —                         | —                               | `ART_DIRECTION_RADIO` (along / across) | —                                  | —                        |
| Scale mode       | —                         | —                               | `ART_SCALE_MODE_RADIO` (proportional / fixed) | —                           | —                        |
| Scale            | —                         | —                               | `ART_SCALE_COMBO`            | `PAT_SCALE_COMBO`                             | —                        |
| Flip across      | —                         | —                               | `ART_FLIP_ACROSS_CHECK`      | `PAT_FLIP_ACROSS_CHECK`                       | —                        |
| Flip along       | —                         | —                               | `ART_FLIP_ALONG_CHECK`       | `PAT_FLIP_ALONG_CHECK`                        | —                        |
| Fit              | —                         | —                               | —                            | `PAT_FIT_RADIO` (stretch / add-space / approximate) | —                  |
| Overlap          | —                         | —                               | `ART_OVERLAP_RADIO` (prevent / allow) | —                                    | —                        |
| Colorization     | —                         | `SCAT_COLORIZATION_SELECT`      | `ART_COLORIZATION_SELECT`    | `PAT_COLORIZATION_SELECT`                     | —                        |
| Key color        | —                         | `SCAT_KEY_COLOR_SWATCH`         | `ART_KEY_COLOR_SWATCH`       | `PAT_KEY_COLOR_SWATCH`                        | —                        |
| Shape            | —                         | —                               | —                            | —                                             | `BRI_SHAPE_SELECT` (10 presets) |
| Length           | —                         | —                               | —                            | —                                             | `BRI_LENGTH_COMBO`       |
| Density          | —                         | —                               | —                            | —                                             | `BRI_DENSITY_COMBO`      |
| Thickness        | —                         | —                               | —                            | —                                             | `BRI_THICKNESS_COMBO`    |
| Opacity          | —                         | —                               | —                            | —                                             | `BRI_OPACITY_COMBO`      |
| Stiffness        | —                         | —                               | —                            | —                                             | `BRI_STIFFNESS_COMBO`    |

Default values for every field are listed in `BRUSHES.md` § Brush
types.

The colorization rows (`*_KEY_COLOR_SWATCH`) are disabled unless the
corresponding `*_COLORIZATION_SELECT` is `hue_shift`.

## Variation widget

`variation_widget` is a workspace-level template defined in
`workspace/templates/`, used for every parameter row tagged
"+ variation" above. Its anatomy:

- A `combo_box` for the base value (the parameter's nominal value).
- A `select` for the variation mode: `fixed`, `random`, `pressure`,
  `tilt`, `bearing`, `rotation`.
- When mode is `random`, two extra `combo_box`es appear inline for
  `min` and `max` percentage bounds (relative to the base value).
- When mode is one of `pressure` / `tilt` / `bearing` / `rotation`, the
  base combo is inert (the live input drives the value at stroke
  time); the field still stores its prior base value for round-tripping
  to and from `fixed` mode.

Stored as a sub-object on the brush:

```json
"angle_variation": { "mode": "random", "min": 80, "max": 120 }
```

For `fixed` mode, the object is `{ "mode": "fixed" }`; the combo's
base value lives on the parent parameter (e.g., `angle`).

## Layout

```
┌─────────────────────────────────────────────────┐
│ BRUSH_TYPE_RADIO                                │  (disabled in non-create modes)
│   [Cal] [Scat] [Art] [Pat] [Bristle]            │
├─────────────────────────────────────────────────┤
│ Name: NAME_INPUT                                │
├─────────────────────────────────────────────────┤
│                                                 │
│   Per-type body                                 │
│   (one of five forms based on type)             │
│                                                 │
├─────────────────────────────────────────────────┤
│ PREVIEW_STRIP                                   │
├─────────────────────────────────────────────────┤
│                       OK_BUTTON  CANCEL_BUTTON  │
└─────────────────────────────────────────────────┘
```

Bootstrap-style yaml:

```yaml
dialog:
- .row: BRUSH_TYPE_RADIO
- .row:
  - .col-3: "Name:"
  - .col-9: NAME_INPUT
- .body:                                          # per-type form (see § Per-type body)
- .row: PREVIEW_STRIP
- .row.justify-end:
  - OK_BUTTON
  - CANCEL_BUTTON
```

The `.body:` section's content is conditional on `BRUSH_TYPE_RADIO`
value; the yaml lists five `.body_when:` blocks (one per type) and the
renderer picks the matching one.

## Choose Artwork mode

`*_CHOOSE_ARTWORK_BUTTON` (Art / Scatter / Pattern bodies) opens a
canvas-pick mode rather than a file picker:

1. The dialog hides (or dims to background) without closing.
2. The cursor changes to a target reticle. The status bar reads
   "Click an element on the canvas to use as artwork. Esc to cancel."
3. The user clicks (or marquees) elements on the canvas.
4. The selected geometry is captured as the new artwork (single-path
   verbatim; multi-element flattened into a single SVG preserving
   relative positions and paints).
5. The dialog re-appears with `*_ARTWORK_PREVIEW` showing the captured
   artwork. For Pattern, the captured artwork lands in the slot that
   was selected before Choose Artwork was triggered (default `side`).
6. Esc cancels and restores the prior artwork (or no artwork if none
   was set).

While in Choose Artwork mode, the canvas selection state is
temporarily saved and restored on exit; the user's prior canvas
selection is preserved.

## Apply to Strokes confirm dialog

Fires only when the parent dialog is in `library_edit` mode and the
user clicks `OK_BUTTON`. Title: "Brush Change". Body:

> The brush "<Brush Name>" has been modified. Apply changes to existing
> strokes using this brush?
>
>     [ Apply ]   [ Cancel ]

Two-way:

- **Apply** — library mutation commits; every element with
  `jas:stroke-brush` referencing this brush is re-rendered. The parent
  dialog closes. One undo transaction wraps the library mutation and
  the canvas re-renders together.
- **Cancel** — library mutation is discarded; parent dialog stays
  open with the user's edits still pending. Closing the parent dialog
  via Cancel discards the edits entirely.

No third "Leave Strokes" option; existing strokes either reflect the
new brush or revert with a Cancel.

## Validation

OK is disabled when any of the following hold:

- `NAME_INPUT` is empty.
- The active type is Scatter or Art and `*_ARTWORK_PREVIEW` is empty.
- The active type is Pattern and `tiles.side` is empty (other tile
  slots are optional).

Other fields have no required-validation; numeric combos clamp on blur
to their defined ranges (see `BRUSHES.md` § Brush types).

## Keyboard

- **Enter** in any text or numeric field commits the field and, if OK
  is enabled, fires `OK_BUTTON`.
- **Esc** fires `CANCEL_BUTTON`.
- **Tab** / **Shift-Tab** cycles focus through the visible controls.

While in Choose Artwork mode, **Esc** cancels the canvas pick rather
than the parent dialog.

## Wiring status

Greenfield. Implementation order matches the Brushes panel: Flask
first, then Rust → Swift → OCaml → Python.

The dialog can ship in two passes:

1. **Pass 1** — Calligraphic and Bristle bodies only (no artwork
   ingestion). Lets the panel ship with two brush types.
2. **Pass 2** — Scatter, Art, Pattern bodies, plus Choose Artwork
   canvas-pick mode and the drag-in artwork pre-fill path.
