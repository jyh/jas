# Brushes

The Brushes panel curates a set of named brushes organised into
libraries, and applies a selected brush to the stroke of the current
canvas selection. This document is the requirements description from
which `workspace/panels/brushes.yaml` is generated.

## Overview

The Brushes panel is one tab in a tabbed panel group; the tabbed-group
container is specified elsewhere. This document covers only the
Brushes tab.

A brush is an alternative stroke style — when applied to a path, it
replaces the path's native stroke rendering with brush-driven
geometry. Five brush types are supported: **Calligraphic**,
**Scatter**, **Art**, **Pattern**, and **Bristle**. The five types
share a single library / panel infrastructure but carry per-type
parameters (see Brush types).

Brushes live in libraries on disk: each library is a directory under
`workspace/brushes/<library_slug>/` containing `library.json` (the
manifest) plus the artwork SVG files for Art / Scatter / Pattern
brushes. Any number of libraries can be open at once; each renders as
a collapsible disclosure section in the panel body.

A brush reference on a path is the string `<library_slug>/<brush_slug>`
written to the path's `jas:stroke-brush` attribute. Per-instance
parameter overrides (the user editing one stroke's brush parameters
without touching the master brush) live in
`jas:stroke-brush-overrides` as a partial parameter dict.

When no document is open, the panel is fully disabled.

The active brush is consumed by two canvas tools — see Canvas tools.

## Controls

### Bottom toolbar (left to right)

- `BRUSH_LIBRARIES_MENU_BUTTON` — `icon_button` (icon
  `brush_libraries_menu`). Opens the **Open Brush Library** dynamic
  submenu. Always enabled when a document is open.

- `REMOVE_BRUSH_STROKE_BUTTON` — `icon_button` (icon
  `remove_brush_stroke`). Writes `state.stroke_brush = null`, clears
  `state.stroke_brush_overrides`, and strips both attributes from
  every selected path. Disabled when the canvas selection contains no
  brushed stroke.

- `BRUSH_OPTIONS_FOR_SELECTION_BUTTON` — `icon_button` (icon
  `brush_options_for_selection`). Opens the Brush Options dialog in
  *instance edit* mode (writes to `state.stroke_brush_overrides`).
  Disabled unless exactly one brushed stroke is selected on the canvas.

- `NEW_BRUSH_BUTTON` — `icon_button` (icon `new_brush`). Opens the
  Brush Options dialog in *create* mode, type picker defaulting to
  Art. The selection's geometry is pre-filled as the new brush's
  artwork. Disabled unless a vector element is selected on the canvas.

- `DELETE_BRUSH_BUTTON` — `icon_button` (icon `delete_brush`). Removes
  every brush whose slug is in `panel.selected_brushes` from
  `panel.selected_library`. Disabled when `panel.selected_brushes` is
  empty.

### Panel body

- `BRUSH_TILES_AREA` — the scrollable body. Renders one
  `BRUSH_LIBRARY_SECTION` per entry in `panel.open_libraries` via a
  `foreach`.

- `BRUSH_LIBRARY_SECTION` — template. A `disclosure`:

  - A disclosure triangle (click to expand / collapse, mirrored to
    `panel.open_libraries[i].collapsed`).
  - The library's name label, read from
    `data.brush_libraries[lib.id].name`.
  - When expanded: a container of `BRUSH_TILE`s iterating
    `data.brush_libraries[lib.id].brushes`, filtered by
    `panel.category_filter`.

- `BRUSH_TILE` — template. One per visible brush. Two render modes
  controlled by `panel.view_mode`:

  - **Thumbnail view** — a raster preview of the brush applied to a
    short demo stroke. Tile size depends on `panel.thumbnail_size`:

    | Size   | Pixels (W × H) |
    |--------|----------------|
    | small  | 48 × 16        |
    | medium | 72 × 24        |
    | large  | 96 × 32        |

    1:3 aspect (wider than tall) reads stroke-shaped previews better
    than square tiles.

  - **List view** — `[16 × 16 type-indicator icon] [name text, flex]
    [optional badge]` row. Icon size is fixed regardless of
    `panel.thumbnail_size` (the size radio is disabled in list view).

  Tile decorators in either mode: a small type-indicator glyph in the
  corner — `brush_type_calligraphic`, `brush_type_scatter`,
  `brush_type_art`, `brush_type_pattern`, `brush_type_bristle`.
  Bristle tiles additionally render with reduced thumbnail opacity to
  flag the heavier render cost.

  Click model — see Selection model.

## Layout

Strings in quotes are literal labels. Bare identifiers are widget IDs.
`BRUSH_LIBRARY_SECTION` and `BRUSH_TILE` are templates that repeat;
the bottom toolbar is laid out as a single row of icon buttons.

```yaml
panel:
- BRUSH_TILES_AREA:
  # foreach library in panel.open_libraries
  - BRUSH_LIBRARY_SECTION (triangle + name):
    # foreach brush in library.brushes (filtered by category_filter)
    - BRUSH_TILE
    - BRUSH_TILE
    - …
- .row:                                          # bottom toolbar
  - BRUSH_LIBRARIES_MENU_BUTTON
  - REMOVE_BRUSH_STROKE_BUTTON
  - BRUSH_OPTIONS_FOR_SELECTION_BUTTON
  - NEW_BRUSH_BUTTON
  - DELETE_BRUSH_BUTTON
```

## Panel menu

- **New Brush** (enabled iff a canvas element is selected) — equivalent
  to clicking `NEW_BRUSH_BUTTON`. Opens Brush Options in `create`
  mode, type picker defaulting to Art.
- **Duplicate Brush** (enabled iff `|selected_brushes| ≥ 1`) — for
  each selected brush, create a copy immediately after it with
  `" copy"` appended to the name and a fresh slug. The copies become
  the selection.
- **Delete Brush** (enabled iff `|selected_brushes| ≥ 1`) — equivalent
  to clicking `DELETE_BRUSH_BUTTON`. Removes the selected brushes from
  `selected_library`. Any element with `jas:stroke-brush` referencing a
  deleted brush re-renders as a plain stroke (null-on-missing
  fallback).
- **Brush Options…** (enabled iff `|selected_brushes| ≥ 1`) — open the
  Brush Options dialog in `library_edit` mode for the *first* selected
  brush. OK prompts the Apply to Strokes confirm dialog.
- ----
- **Select All Unused** — replace `panel.selected_brushes` with every
  brush in the panel whose slug does not appear as `jas:stroke-brush`
  on any element in the document. Helpful before **Delete Brush**.
- ----
- **Sort by Name** (enabled iff `selected_library != null`) —
  permanently reorder `selected_library`'s brushes alphabetically
  (case-sensitive, lexicographic). Slugs unchanged; selection
  preserved (since selection is slug-keyed). Modifies the in-memory
  library data; persisted on the next **Save Brush Library**.
- ----
- **Thumbnail View** (checkmark if active) — sets
  `panel.view_mode = thumbnail`.
- **List View** (checkmark if active) — sets `panel.view_mode = list`.
  The two view-mode items form a radio group.
- ----
- **Small Thumbnail View** (checkmark if active; disabled iff
  `view_mode == list`) — sets `panel.thumbnail_size = small`.
- **Medium Thumbnail View** (checkmark if active; disabled iff
  `view_mode == list`) — sets `panel.thumbnail_size = medium`.
- **Large Thumbnail View** (checkmark if active; disabled iff
  `view_mode == list`) — sets `panel.thumbnail_size = large`.
  The three size items form a radio group; exactly one is always
  checked even when disabled.
- ----
- **Show Calligraphic Brushes** (checkbox; checkmark iff `calligraphic`
  is in `panel.category_filter`) — toggle membership.
- **Show Scatter Brushes** — toggle `scatter`.
- **Show Art Brushes** — toggle `art`.
- **Show Pattern Brushes** — toggle `pattern`.
- **Show Bristle Brushes** — toggle `bristle`.
  Unchecking all five renders the panel body empty with a hint label
  `"No brushes match current filter"`. Filter is panel-local state,
  re-initialised to "all enabled" on each panel open.
- ----
- **Make Persistent** (checkbox; checkmark iff `selected_library`'s
  slug is in `preferences.brushes_persistent_libraries`) — toggle the
  selected library's presence in the user-preferences list. Persistent
  libraries auto-open on app launch.
- **Open Brush Library** — dynamic submenu listing every library
  discovered under `workspace/brushes/*/library.json`. Selecting an
  unopened library appends it to `panel.open_libraries` with
  `collapsed: false`; selecting an already-open library (checkmark
  shown) removes it from `open_libraries` (close-library equivalent).
- **Save Brush Library** (enabled iff `selected_library != null`) —
  open the Save Brush Library dialog, which prompts for a library
  name. The selected library's manifest and artwork files are written
  to `workspace/brushes/<new_slug>/`.
- ----
- **Close Brushes** — dispatches `close_panel` with
  `params: { panel: brushes }`, hiding the Brushes tab.

The same menu in YAML form, suitable for the panel-menu YAML migration:

```yaml
menu:
  groups:
    - - {id: new_brush,           kind: action,   enabled_when: "canvas_selection_non_empty"}
      - {id: duplicate_brush,     kind: action,   enabled_when: "selected_brushes_non_empty"}
      - {id: delete_brush,        kind: action,   enabled_when: "selected_brushes_non_empty"}
      - {id: brush_options,       kind: action,   enabled_when: "selected_brushes_non_empty"}
    - - {id: select_all_unused,   kind: action}
    - - {id: sort_by_name,        kind: action,   enabled_when: "library_selected"}
    - - {id: view_thumbnail,      kind: radio,    group: view_mode,      value: thumbnail}
      - {id: view_list,           kind: radio,    group: view_mode,      value: list}
    - - {id: size_small,          kind: radio,    group: thumbnail_size, value: small,  enabled_when: "view_mode == thumbnail"}
      - {id: size_medium,         kind: radio,    group: thumbnail_size, value: medium, enabled_when: "view_mode == thumbnail"}
      - {id: size_large,          kind: radio,    group: thumbnail_size, value: large,  enabled_when: "view_mode == thumbnail"}
    - - {id: show_calligraphic,   kind: checkbox, writes: "panel.category_filter contains calligraphic"}
      - {id: show_scatter,        kind: checkbox, writes: "panel.category_filter contains scatter"}
      - {id: show_art,            kind: checkbox, writes: "panel.category_filter contains art"}
      - {id: show_pattern,        kind: checkbox, writes: "panel.category_filter contains pattern"}
      - {id: show_bristle,        kind: checkbox, writes: "panel.category_filter contains bristle"}
    - - {id: make_persistent,     kind: checkbox, writes: "preferences.brushes_persistent_libraries contains selected_library"}
      - {id: open_brush_library,  kind: submenu}
      - {id: save_brush_library,  kind: action,   enabled_when: "library_selected"}
    - - {id: close_brushes,       kind: action}
```

Labels resolve through the i18n layer with keys `brushes_menu.<id>`.

## Selection model

Brush selection is per-library and stored as a list of slugs (not
indices), so library-mutating operations like Sort by Name and
Duplicate Brush do not scramble the selection.

- `panel.selected_library` — the library slug owning the current
  selection. Changing libraries clears the selection.
- `panel.selected_brushes` — a list of brush slugs within
  `selected_library`.

Click modifiers (the generic `select` effect with `mode: auto`):

- **Plain click** — replace the selection with the clicked brush. If
  the clicked brush belongs to a different library than
  `panel.selected_library`, switch `panel.selected_library` first.
- **Shift + click** — extend a contiguous range, in current rendering
  order within the library, from the anchor brush to the clicked
  brush. Cross-library shift-click degrades to plain click. Range
  selection across collapsed sections is not supported; the anchor
  resets if its section is collapsed.
- **Cmd / Ctrl + click** — toggle the clicked brush's slug in the
  list. Cross-library cmd-click degrades to plain click.

Selection feedback is the shared `jas-selected` CSS class (a 2 px
accent outline) applied to each selected `BRUSH_TILE` via the
`selected_in: panel.selected_brushes` binding.

On a plain click that resolves to a single brush, the click also:

1. Writes `state.stroke_brush = "<library_slug>/<brush_slug>"`.
2. Clears `state.stroke_brush_overrides`.
3. If the canvas selection is non-empty, sets `jas:stroke-brush` on
   each selected path element (and strips `jas:stroke-brush-overrides`
   from each).

Selection-and-apply is one user action sharing a single undo
transaction. Shift / Cmd clicks that resolve to multi-selection do
*not* fire the active-brush write (which of the N selected brushes
would become active is ambiguous).

On **double-click** of a `BRUSH_TILE`, the Brush Options dialog opens
in `library_edit` mode. Double-click does not change the panel
selection.

When `Delete Brush` removes the brush currently referenced by
`state.stroke_brush`, the reference is nulled out; canvas elements
referencing the deleted slug fall back to plain stroke rendering at
the next paint.

## Brush types

The five types share a `type` field and per-type parameter sets.

### Calligraphic

An oval pen tip whose dimensions and orientation can vary along the
stroke. Produces a width-varying continuous stroke. No embedded
artwork.

| Field             | Type    | Default | Notes |
|-------------------|---------|---------|-------|
| `angle`           | degrees | 0       | tip orientation |
| `roundness`       | percent | 100     | 100 = circular, < 100 = elongated perpendicular to angle |
| `size`            | pt      | 5       | major-axis length |
| `angle_variation` | variation | `fixed` | `fixed` / `random` / `pressure` / `tilt` / `bearing` / `rotation` |
| `roundness_variation` | variation | `fixed` | as above |
| `size_variation`  | variation | `fixed` | as above |

### Scatter

Stamps a single vector artwork along the path at intervals. Discrete
stamps, not a continuous stroke.

| Field             | Type     | Default | Notes |
|-------------------|----------|---------|-------|
| `artwork`         | SVG path | required | filename relative to library directory |
| `size`            | percent  | 100     | stamp size as % of artwork natural size |
| `spacing`         | percent  | 100     | gap between stamps as % of stamp width |
| `scatter`         | percent  | 0       | perpendicular offset, 0 = on path |
| `rotation`        | degrees  | 0       | per-stamp rotation |
| `size_variation`  | variation | `fixed` | with `min` / `max` for `random` |
| `spacing_variation` | variation | `fixed` | as above |
| `scatter_variation` | variation | `fixed` | as above |
| `rotation_variation` | variation | `fixed` | as above |
| `colorization`    | enum     | `none`  | see Colorization |
| `key_color`       | hex      | `#000000` | only consulted when `colorization == hue_shift` |

### Art

Stretches one vector artwork along the full path length. One
continuous stretched artwork per stroke.

| Field           | Type     | Default | Notes |
|-----------------|----------|---------|-------|
| `artwork`       | SVG path | required | filename relative to library directory |
| `direction`     | enum     | `along` | `along` / `across` (artwork orientation along path) |
| `scale_mode`    | enum     | `proportional` | `proportional` / `fixed` |
| `scale`         | percent  | 100     | base scale; multiplied by `stroke_weight / 1pt` |
| `flip_across`   | boolean  | false   | mirror artwork across path |
| `flip_along`    | boolean  | false   | mirror artwork along path |
| `overlap`       | enum     | `prevent` | `prevent` / `allow` (overlap on path corners) |
| `colorization`  | enum     | `none`  | see Colorization |
| `key_color`     | hex      | `#000000` | only consulted when `colorization == hue_shift` |

### Pattern

Tiles repeated artwork along the path with special tiles for caps and
corners.

| Field           | Type      | Default | Notes |
|-----------------|-----------|---------|-------|
| `tiles.side`    | SVG path  | required | the only mandatory tile |
| `tiles.start`   | SVG path or null | null | start-cap tile |
| `tiles.end`     | SVG path or null | null | end-cap tile |
| `tiles.outer_corner` | SVG path or null | null | outer-corner tile |
| `tiles.inner_corner` | SVG path or null | null | inner-corner tile |
| `scale`         | percent   | 100     | tile scale; multiplied by `stroke_weight / 1pt` |
| `spacing`       | percent   | 0       | gap between side tiles, 0 = abutting |
| `flip_across`   | boolean   | false   | mirror tiles across path |
| `flip_along`    | boolean   | false   | mirror tiles along path |
| `fit`           | enum      | `stretch` | `stretch` / `add_space` / `approximate` |
| `colorization`  | enum      | `none`  | see Colorization |
| `key_color`     | hex       | `#000000` | only consulted when `colorization == hue_shift` |

Corner-tile selection requires path-corner classification (sharp vs
smooth). Open paths with cusps are the subtle case; see Wiring status.

### Bristle

Simulates a bristle brush with transparency and overlap. Produces
natural-media strokes painted in stroke colour.

| Field        | Type    | Default | Notes |
|--------------|---------|---------|-------|
| `shape`      | enum    | `round` | one of ten shape presets (round, flat, fan, angle, point, blunt, curve, etc. — final list TBD) |
| `size`       | pt      | 3       | overall brush diameter at 1 pt stroke; multiplied by `stroke_weight` |
| `length`     | percent | 100     | bristle length |
| `density`    | percent | 50      | bristles per area |
| `thickness`  | percent | 30      | per-bristle thickness |
| `opacity`    | percent | 30      | per-bristle paint opacity |
| `stiffness`  | percent | 50      | bristle bend resistance |

Bristle ignores `state.stroke_opacity` (uses the brush's own
`opacity`). Colorization not applicable; bristles paint in the stroke
colour directly.

### Variation widget

Each `+ variation` field is rendered as a composite widget — a
`combo_box` for the base value plus a `select` for the variation mode.
When the mode is `random`, two extra combos appear for `min` / `max`
bounds. When the mode is `pressure` / `tilt` / `bearing` / `rotation`,
the base combo is inert (the live input drives the value at stroke
time).

Defined as a workspace template `variation_widget` under
`workspace/templates/`, alongside `fill_stroke_widget`.

**Phase 1 note.** The `pressure`, `tilt`, and `bearing` modes
currently render live only in the Brush Options preview strip.
Canvas tools (Paintbrush, Blob Brush) synthesize a fixed mid-range
value (`0.5`) at stroke time — these modes are effectively inert on
committed paths until Phase 2 plumbing extends the point buffer,
`fit_curve`, and renderer to carry per-anchor samples. See
`PAINTBRUSH_TOOL.md` § Phase 1 / Phase 2 split for the rollout plan.
`random` and `rotation` modes are unaffected and work end-to-end in
Phase 1.

## Colorization

Applies to Scatter, Art, and Pattern brushes (Calligraphic and Bristle
ignore the field). Determines how the stroke colour interacts with the
artwork's own colours at render time.

- `none` — render the artwork in its original colours.
- `tints` — black in the artwork maps to the stroke colour; other
  colours tint toward it. Whites preserved.
- `tints_and_shades` — stroke colour replaces neutrals; shadows
  preserved.
- `hue_shift` — the artwork's `key_color` maps to the stroke colour;
  other colours rotate in HSB space by the same delta.

## Brush Options dialog

Specified in `transcripts/BRUSH_OPTIONS_DIALOG.md` and implemented as
`workspace/dialogs/brush_options.yaml`. Three modes and their entry
points:

| Mode            | Entry point                                  | Writes to                       |
|-----------------|----------------------------------------------|---------------------------------|
| `create`        | `NEW_BRUSH_BUTTON`; **New Brush** menu item; drag-in to empty area | new library brush |
| `library_edit`  | double-click a tile; **Brush Options…** menu item | master library brush; prompts Apply to Strokes confirm |
| `instance_edit` | `BRUSH_OPTIONS_FOR_SELECTION_BUTTON`         | `state.stroke_brush_overrides`  |

## Brush libraries

Each library is a directory:

```
workspace/brushes/<library_slug>/
  library.json             # manifest: name, description, brushes[]
  <brush_slug>.svg         # artwork for Art / Scatter brushes
  <brush_slug>_side.svg    # Pattern brush tile artwork
  <brush_slug>_outer.svg
  <brush_slug>_inner.svg
  <brush_slug>_start.svg
  <brush_slug>_end.svg
  …
```

`library.json` shape:

```json
{
  "name": "Default Brushes",
  "description": "Starter set shipped with the application",
  "brushes": [
    {
      "name": "5 pt. Oval",
      "slug": "oval_5pt",
      "type": "calligraphic",
      "angle": 0, "roundness": 100, "size": 5,
      "angle_variation": {"mode": "fixed"},
      "roundness_variation": {"mode": "fixed"},
      "size_variation": {"mode": "fixed"}
    },
    {
      "name": "Charcoal — Feather",
      "slug": "charcoal_feather",
      "type": "art",
      "artwork": "charcoal_feather.svg",
      "direction": "along",
      "scale_mode": "proportional",
      "scale": 100,
      "flip_across": false, "flip_along": false,
      "overlap": "prevent",
      "colorization": "tints",
      "key_color": "#000000"
    }
  ]
}
```

The library slug is the directory name. The brush slug is stable
across reordering and renames; it is the canonical identity used in
`jas:stroke-brush` references. The `name` field is the user-facing
display string and may differ from the slug.

All discovered libraries appear in the **Open Brush Library** submenu.
On startup, every library slug listed in
`preferences.brushes_persistent_libraries` is appended to
`panel.open_libraries`; if that preference list is empty, the
`default_brushes` library is opened by default.

## Drag and drop

### Drag IN — from canvas to panel

Source: one or more vector elements selected on the canvas. Drag
gesture starts when the pointer moves > 4 px from pointer-down while
over the canvas with a non-empty selection.

| Drop target                        | Outcome |
|------------------------------------|---------|
| `BRUSH_TILES_AREA` empty space     | Brush Options in `create`, type defaulting to Art, artwork pre-filled. Target library = `selected_library`. |
| `BRUSH_LIBRARY_SECTION` header     | Same, target library = the dropped-on library. |
| `NEW_BRUSH_BUTTON`                 | Same as drop on empty area. |
| `BRUSH_TILE` of type Art / Scatter | Brush Options in `library_edit` for that brush; artwork replaced. |
| `BRUSH_TILE` of type Pattern       | Same; dragged content lands in the `side` tile slot. Other slots unchanged. |
| `BRUSH_TILE` of type Calligraphic / Bristle | Invalid drop (red "not allowed" cursor); no action. |

Artwork extraction: a single-path source is the artwork verbatim;
multi-element / group sources are flattened into a single SVG artwork
preserving relative positions and paints.

Visual feedback during drag: 2 px accent highlight on valid targets;
red "not allowed" cursor on invalid; ghosted bounding-box outline of
the source follows the pointer.

Undo: drop-into-panel is one transaction. Create-new undoes by
removing the brush; replace-artwork undoes by restoring prior artwork
and prior stroke renders.

### Drag OUT — from panel to canvas

Source: pointer-down on a `BRUSH_TILE` followed by > 4 px movement off
the tile. Distinct from plain click (applies brush) and double-click
(opens Brush Options); the drag supersedes both once the movement
threshold is crossed.

| Brush type    | Drop outcome |
|---------------|--------------|
| Art           | Artwork SVG placed at the drop point as an editable path or group. |
| Scatter       | Artwork SVG placed at the drop point. |
| Pattern       | All five tile slots placed at the drop point arranged horizontally (start → side → inner-corner → outer-corner → end; nulls omitted). Grouped. |
| Calligraphic  | No-op. |
| Bristle       | No-op. |

Drag preview: ghosted thumbnail of the brush tile follows the pointer.

No live link back to the library — dropped artwork becomes ordinary
editable elements. To push edits back into the brush, re-select and
drag IN, or use the Brush Options dialog's **Choose Artwork…** button.

Undo: drop-onto-canvas is one element-creation transaction.

### Click vs. double-click vs. drag disambiguation

Pointer-down on a `BRUSH_TILE` with no movement before pointer-up:

- Release within double-click interval (≤ ~350 ms) of a prior
  pointer-up on the same tile → double-click → open Brush Options.
- Otherwise → single click → select + set active brush + apply.

Pointer-down followed by > 4 px movement before release → drag-out.
Neither click nor double-click fires.

## Canvas tools

Two canvas tools consume `state.stroke_brush`:

- **Paintbrush** (see `PAINTBRUSH_TOOL.md`) — freehand path tool that
  draws with the active brush. Writes a standard path element with
  `jas:stroke-brush` set. When `state.stroke_brush == null`, behaves as
  a plain freehand path tool using the native stroke values.
- **Blob Brush** (see `BLOB_BRUSH_TOOL.md`) — paints filled regions by
  unioning brush-swept areas. Produces closed-path *fill* elements,
  not strokes; does not set `jas:stroke-brush` on the result.

## Stroke styling interaction

When `state.stroke_brush != null`, the brush consumes some of the
existing flat-stroke fields (`state.stroke_*`) and overrides others.
Per-type breakdown:

| Stroke field                | Calligraphic | Scatter | Art | Pattern | Bristle |
|-----------------------------|--------------|---------|-----|---------|---------|
| `stroke_width` (weight)     | base size    | ignored | scale multiplier (× ref 1 pt) | scale multiplier | overall size |
| `stroke_color`              | paint        | colorization input | colorization input | colorization input | paint |
| `stroke_opacity`            | applied      | ignored | ignored | ignored | overridden by brush `opacity` |
| `stroke_align`              | applied      | n/a — disabled | n/a — disabled | n/a — disabled | applied |
| `stroke_cap`                | n/a — disabled | n/a — disabled | n/a — disabled | n/a — disabled | n/a — disabled |
| `stroke_join` + miter limit | n/a — disabled | n/a — disabled | n/a — disabled | n/a — disabled | n/a — disabled |
| `stroke_dashed` + pattern   | n/a — disabled | n/a — disabled | n/a — disabled | n/a — disabled | n/a — disabled |
| arrowheads + scale + align  | n/a — disabled | n/a — disabled | n/a — disabled | n/a — disabled | n/a — disabled |
| profile + flip              | n/a — disabled (brush IS the profile) | n/a — disabled | n/a — disabled | n/a — disabled | n/a — disabled |

Disabled fields persist their values; on `REMOVE_BRUSH_STROKE_BUTTON`
they reappear as the active stroke style.

`reference_weight` for the scale multiplier is the constant **1 pt**.
A 5 pt stroke applied to an Art brush with `scale = 100%` renders at
5× the reference. Brush authors tune `scale` against a 1 pt reference.

## Panel state

Panel-local state (re-initialised on each panel open):

| Panel key                  | Source state key                | Type                          | Default |
|----------------------------|---------------------------------|-------------------------------|---------|
| `panel.selected_library`   | `state.brushes_selected_library` | string (library slug)         | `"default_brushes"` |
| `panel.selected_brushes`   | `state.brushes_selected_brushes` | list of brush slugs           | `[]` |
| `panel.open_libraries`     | `state.brushes_open_libraries`  | list of `{ id, collapsed }`   | computed from `preferences.brushes_persistent_libraries`, falling back to `[{id:"default_brushes",collapsed:false}]` |
| `panel.view_mode`          | `state.brushes_view_mode`       | enum (`thumbnail` / `list`)   | `thumbnail` |
| `panel.thumbnail_size`     | `state.brushes_thumbnail_size`  | enum (`small` / `medium` / `large`) | `small` |
| `panel.category_filter`    | `state.brushes_category_filter` | list of type names            | `["calligraphic","scatter","art","pattern","bristle"]` |

Every widget commit fires two effects: a `set_panel_state` for the
mirror key and a `set` for the corresponding `state.brushes_*` key —
the same dual-write pattern other panels use.

Document / shared state (persisted per-document):

| Key                              | Type                                    | Default | Used by |
|----------------------------------|-----------------------------------------|---------|---------|
| `state.stroke_brush`             | string `<library_slug>/<brush_slug>` or null | null   | Brushes panel; canvas tools; native stroke pipeline (disable rules) |
| `state.stroke_brush_overrides`   | partial dict of brush params, or null   | null    | per-instance Model A overrides |

External data (loaded at startup, panel reads only):

| Key                       | Shape                                                      | Source |
|---------------------------|------------------------------------------------------------|--------|
| `data.brush_libraries`    | map of `library_slug` → `{name, description, brushes[]}`   | `workspace/brushes/<slug>/library.json` per-library |

User preferences:

| Key                                           | Type                  | Default                |
|-----------------------------------------------|-----------------------|------------------------|
| `preferences.brushes_persistent_libraries`    | list of library slugs | `["default_brushes"]`  |

## SVG attribute mapping

The panel writes brush-related attributes onto selected path elements
via the shared `state.stroke_*` pipeline:

| Control                           | SVG / `jas:` attribute |
|-----------------------------------|------------------------|
| `state.stroke_brush`              | `jas:stroke-brush="<library_slug>/<brush_slug>"` |
| `state.stroke_brush_overrides`    | `jas:stroke-brush-overrides="<compact JSON>"` |

Existing flat-stroke attributes (`stroke-width`, `stroke`,
`stroke-opacity`, `paint-order`) continue to map through the existing
stroke pipeline; brush rendering consumes those at render time per the
Stroke styling interaction table.

**Identity-value rule.** When `state.stroke_brush` is null,
`jas:stroke-brush` is omitted entirely. When
`state.stroke_brush_overrides` is null or empty,
`jas:stroke-brush-overrides` is omitted. Defaults appear as absence.

## Undo semantics

The following operations each produce exactly one undoable
transaction. A single Cmd-Z / Ctrl-Z reverts the entire effect.

- **New Brush** — undo removes the brush and any artwork files it
  added.
- **Duplicate Brush** — undo removes the copies and restores the prior
  selection.
- **Delete Brush** — undo restores the brushes, the selection, and any
  canvas elements whose `jas:stroke-brush` was nulled out.
- **Sort by Name** — undo restores the prior order.
- **Brush Options… → library_edit → Apply** — undo restores the prior
  brush parameters and prior renders for every element that referenced
  the brush. (Cancel produces no undo entry.)
- **Single-click a tile** (active-brush + apply-to-selection) — undo
  reverts `state.stroke_brush`, clears `state.stroke_brush_overrides`,
  and strips the attributes from the selected paths.
- **REMOVE_BRUSH_STROKE_BUTTON** — undo restores both
  `state.stroke_brush` and `state.stroke_brush_overrides` and the
  attributes on selected paths.
- **BRUSH_OPTIONS_FOR_SELECTION_BUTTON → OK** — undo restores prior
  `state.stroke_brush_overrides`.
- **Drag-in** — same transaction shape as New Brush (create-new) or as
  library_edit → Apply (replace-artwork).
- **Drag-out** — one element-creation transaction.

The following are **not** undoable, consistent with the panel-state
exclusion rule used elsewhere in the workspace:

- Selection-only clicks (shift / cmd click on tiles, no active-brush
  write).
- Disclosure expand / collapse.
- Open / close Brush Library (via submenu checkmark toggle).
- Thumbnail / List view toggle.
- Small / Medium / Large thumbnail size radio.
- Show X Brushes category-filter checkboxes.
- **Make Persistent** toggle (writes user preferences, not the
  document).
- **Save Brush Library** (writes disk; beyond the app's undo model).

This policy diverges from the Swatches Delete Swatch rule (which is
non-undoable). The rationale: deleting a brush re-renders every canvas
element referencing it, which is a substantial document mutation
deserving an undo entry.

Standard LIFO redo stack; an undo followed by any new undoable action
drops the redo stack.

## Keyboard shortcuts

Shortcuts for Brushes actions are defined in
`workspace/shortcuts.yaml` rather than here.

## Panel-to-selection wiring status

Greenfield — not yet implemented in any app. Implementation order per
`CLAUDE.md` is Flask first, then Rust → Swift → OCaml → Python.

Per-app status:

- **Flask** (`jas_flask`): not started. Renderer integration for
  brush-driven SVG output is the bulk of the Flask work; the existing
  `renderer.py` has no concept of brushes.
- **Rust** (`jas_dioxus`): not started. YamlTool runtime already
  complete, so Paintbrush Tool can be YAML-driven from day one.
- **Swift** (`JasSwift`): not started. YamlTool runtime complete.
- **OCaml** (`jas_ocaml`): not started. YamlTool runtime complete. New
  `.ml` files require accompanying `.mli` per `CLAUDE.md`; concrete
  tool implementations in `lib/tools/*.ml` are excepted.
- **Python** (`jas`): not started. YamlTool runtime complete.

Initial release ships Calligraphic only, to de-risk the Flask
implementation; Scatter → Art → Pattern → Bristle follow.

Open follow-ups:

- **Bristle renderer** — data model lands across all five apps; the
  width-varying-with-overlap-transparency renderer is per-app work.
  Same deferral precedent as `taper_*` / `bulge` / `pinch` strokes
  elsewhere.
- **Pattern corner-tile geometry** — requires path-corner
  classification (sharp vs smooth) to pick inner-corner vs
  outer-corner tiles. Open paths with cusps are the subtle case.
- **Variation modes beyond `fixed` / `random`** — `pressure`, `tilt`,
  `bearing`, `rotation` all require stylus input plumbing. Until that
  exists in a given app, these modes degrade to `fixed` at render
  time.
- **Library-as-directory on-disk layout** — new filesystem pattern
  that no existing workspace asset uses. Each app's startup loader
  needs to walk directories, not just files.
- **`variation_widget` template** — new composite widget not yet in
  any app's widget catalogue.
- **Sibling tool docs** — `PAINTBRUSH_TOOL.md` and
  `BLOB_BRUSH_TOOL.md` are stubbed; full drafts pending.
- **Undo for library mutations** — diverges from the Swatches
  precedent; each app's undo wiring may need extension to cover the
  Brushes operations listed under Undo semantics.
