# Gradient

The Gradient panel edits the gradient value of the active fill or stroke.
This document is the requirements description from which
`workspace/panels/gradient.yaml` is generated.

## Overview

The Gradient panel is one tab in a tabbed panel group; the tabbed-group
container is specified elsewhere. This document covers only the Gradient
tab.

The panel edits whichever of the fill or stroke is "on top" (per the
shared `state.fill_on_top` flag, also used by the fill/stroke widget in
the Tools panel). Changing any control updates the selected elements'
fill or stroke attribute.

Three gradient types are supported: linear, radial, and freeform. A
gradient is specified as an ordered list of color stops (linear and
radial) or as a set of colored nodes placed in 2-D (freeform). Each
adjacent pair of stops has a midpoint that controls where the
interpolation is visually centered.

Entry points into the panel:

- Clicking the Gradient tab.
- Clicking the Gradient mode button in the fill/stroke widget.
- Selecting the Gradient tool on the canvas (see `GRADIENT_TOOL.md`).

The panel is fully active when a document is open. When the active
attribute is solid or none, the panel shows a seeded default gradient
preview; the first panel edit implicitly promotes the active attribute
to a gradient (see Fill-type coupling).

Gradients can be saved to document-scoped and bundled libraries, and
browsed through the preset tile strip at the top of the panel.

The single source of truth is the gradient object on `element.fill` /
`element.stroke`. Both the panel and the on-canvas Gradient tool read
from and write to this value; no synchronization protocol is needed.

## Controls

- `DOCUMENT_LIBRARY_DROPDOWN` — `select` that switches which gradient
  library populates the tile strip. Single-select: exactly one library
  is active at a time. Opens a list of discovered libraries (see
  Document libraries). Always enabled when a document is open.

- `DOCUMENT_LIBRARY_SIZE_DROPDOWN` — `select` that chooses how library
  tiles are rendered: Small / Medium / Large Thumbnail View, plus
  Small / Large List View. The two list-view items carry
  `status: pending_renderer` until the list-row render path lands.

- `GRADIENT_TILE` — a gradient `color_swatch`-equivalent tile rendered
  once per gradient in the active library. Single-click applies the
  tile's gradient value to the active attribute of the selected
  elements (copying the value per the template-store model).

- `FILL_STROKE_WIDGET` — the shared fill/stroke widget template. Same
  visual behaviour as the toolbar widget, except single-click only
  (no double-click to open the modal picker).

- `LINEAR_BUTTON`, `RADIAL_BUTTON`, `FREEFORM_BUTTON` — three mutually
  exclusive `icon_button`s selecting the gradient type. Exactly one is
  checked. Default `LINEAR_BUTTON`. `FREEFORM_BUTTON` carries
  `status: pending_renderer` until the freeform renderer lands.

- `STROKE_WITHIN_BUTTON`, `STROKE_ALONG_BUTTON`, `STROKE_ACROSS_BUTTON`
  — three mutually exclusive `icon_button`s selecting the stroke
  sub-mode (how a gradient maps onto the stroke). Default
  `STROKE_WITHIN_BUTTON`. See Stroke sub-modes. `STROKE_ALONG_BUTTON`
  and `STROKE_ACROSS_BUTTON` carry `status: pending_renderer`. The
  entire row is disabled when `fill_on_top == fill`, when the active
  attribute is not a gradient, or when `type == freeform`.

- `ANGLE_COMBO` — `combo_box` for the gradient angle in degrees.
  Display range −180..+180°; values wrap on commit (entering 370° is
  stored as 10°). Presets: −135, −90, −45, 0, 45, 90, 135, 180. Free
  numeric entry allowed. Default 0°. Disabled when `type == freeform`.

- `ASPECT_RATIO_COMBO` — `combo_box` for the gradient aspect ratio as
  a percentage. 100% = isotropic (circle for radial). Presets: 25, 50,
  75, 100, 150, 200, 400. Free numeric entry allowed, range 1–1000%.
  Default 100%. Disabled when `type == freeform`.

- `METHOD_DROPDOWN` — `select` whose options depend on the active
  type. See Method.

- `DITHER_CHECKBOX` — `checkbox` enabling sub-pixel dithering of the
  rendered gradient to reduce visible banding. Default off. Carries
  `status: pending_renderer` in all four apps.

- `ADD_TO_SWATCHES_BUTTON` — `icon_button`. Appends the current
  gradient to the document-scoped library with an auto-generated name
  (`Gradient 1`, `Gradient 2`, …). No prompt. Disabled when the active
  attribute is solid or none.

- `GRADIENT_SLIDER` — the color-stops editor. See Color stops.

- `TRASH_BUTTON` — `icon_button` that deletes the currently-selected
  stop. Disabled when no stop is selected or when only two stops
  remain (minimum floor).

- `EYEDROPPER_BUTTON` — `icon_button` that picks a color from the
  document and applies it to the currently-selected stop (or, for
  freeform, the currently-selected node). Disabled when nothing is
  selected in the slider.

- `STOP_OPACITY_COMBO` — `combo_box` for the selected stop's opacity
  as a percentage, 0–100%. Presets 0, 25, 50, 75, 100. Default 100%.
  When `type == freeform` the label binds to "Opacity:" with the same
  semantics (per-node opacity). Disabled when nothing is selected.

- `STOP_LOCATION_COMBO` — `combo_box` for the selected stop's
  location. For linear/radial: the stop's position 0–100% along the
  gradient strip; display shows the absolute location. For a selected
  midpoint: the midpoint's absolute location, clamped between the two
  neighbor stops. For `type == freeform`: the label re-binds to
  "Spread:" and the combo edits the selected node's spread radius
  (percentage of bounding-box diagonal). Disabled when nothing is
  selected.

## Layout

Strings in quotes are literal labels. Bare identifiers are widget IDs.
`GRADIENT_TILE` is a template that repeats once per gradient in the
active library.

```yaml
panel:
- .row:                                          # preset browser
  - "Presets:"
  - DOCUMENT_LIBRARY_DROPDOWN
  - DOCUMENT_LIBRARY_SIZE_DROPDOWN
- .row:                                          # tile strip
  # foreach gradient in active library
  - GRADIENT_TILE
  - GRADIENT_TILE
  - …
- .hr
- .row:                                          # fill/stroke + type/method block
  - .col-3: FILL_STROKE_WIDGET
  - .col-9:
    - .row:
      - .col-3: "Type:"
      - .col-9: LINEAR_BUTTON RADIAL_BUTTON FREEFORM_BUTTON
    - .row:
      - .col-3: "Stroke:"
      - .col-9: STROKE_WITHIN_BUTTON STROKE_ALONG_BUTTON STROKE_ACROSS_BUTTON
    - .row:
      - .col-3: "∠"
      - .col-9: ANGLE_COMBO
    - .row:
      - .col-3: "↕"
      - .col-9: ASPECT_RATIO_COMBO
    - .row:
      - .col-3: "Method:"
      - .col-9: METHOD_DROPDOWN
    - .row:
      - .col-3: ""
      - .col-9: DITHER_CHECKBOX
- .row:                                          # stops editor
  - .col-2: ADD_TO_SWATCHES_BUTTON
  - .col-8: GRADIENT_SLIDER
  - .col-2: TRASH_BUTTON
- .row:                                          # selected-stop properties
  - .col-2: EYEDROPPER_BUTTON
  - .col-10:
    - .row:
      - .col-3: "Opacity:"
      - .col-9: STOP_OPACITY_COMBO
    - .row:
      - .col-3: "Location:"                      # "Spread:" when type == freeform
      - .col-9: STOP_LOCATION_COMBO
```

## Panel menu

Items are grouped, with a divider between groups. Labels are resolved
through the i18n layer using the key `gradient_menu.<id>`.

```yaml
PANEL_MENU:
  groups:
    - - {id: reverse_gradient,      kind: action, enabled_when: "selection_has_gradient && type != freeform"}
      - {id: distribute_stops,      kind: action, enabled_when: "selection_has_gradient && type != freeform && stop_count > 2"}
      - {id: reset_midpoints,       kind: action, enabled_when: "selection_has_gradient && type != freeform"}
    - - {id: open_gradient_library, kind: submenu}
      - {id: save_gradient_library, kind: action, enabled_when: "document_open"}
    - - {id: close_gradient,        kind: action}
```

- **Reverse Gradient** — flip stops end-to-end: each stop's location
  becomes `100 − location`, stops reorder by new location, midpoints
  swap neighbors appropriately. No-op for freeform.
- **Distribute Stops Evenly** — space all stops at equal intervals
  from 0% to 100%. First stop → 0, last → 100, intermediate stops
  uniformly. Midpoints reset to 50%.
- **Reset Midpoints** — all midpoint percentages back to 50%. Stop
  locations unchanged.
- **Open Gradient Library** — dynamic submenu listing every
  `workspace/gradients/*.json` file. Selecting one switches the active
  library in `DOCUMENT_LIBRARY_DROPDOWN`. Already-open libraries get a
  checkmark (the current selection, under the single-select model).
- **Save Gradient Library** — opens a Save Gradient Library dialog
  that prompts for a library name. The document's library gradients
  are written to `workspace/gradients/<name>.json`.
- **Close Gradient** — dispatches `close_panel` with
  `params: { panel: gradient }`, hiding the Gradient tab.

## Gradient types

Three types, selected via `LINEAR_BUTTON` / `RADIAL_BUTTON` /
`FREEFORM_BUTTON`:

- **Linear**: colors interpolate along a 1-D vector whose direction is
  given by `angle` and whose extent can be stretched via
  `aspect_ratio`. The vector is defined within the element's bounding
  box by default, or manipulated directly via the Gradient tool.
- **Radial**: colors interpolate from a center outward.
  `aspect_ratio` ≠ 100% makes the gradient elliptical, and `angle`
  rotates the ellipse.
- **Freeform**: colors radiate from each of N nodes placed in 2-D on
  the element. `method` selects between *points* (radial falloff from
  each node) and *lines* (perpendicular falloff from line segments
  joining pairs of nodes). Freeform nodes are placed and manipulated
  on the canvas via the Gradient tool; the panel edits the selected
  node's color, opacity, and spread radius.

## Color stops

The `GRADIENT_SLIDER` widget is the color-stops editor for linear and
radial gradients. (It is disabled when `type == freeform`.)

### Anatomy

- A horizontal bar filled with the current gradient preview.
- For each stop: a round marker rendered below the bar, filled with the
  stop color at 100% opacity, with a hollow outline.
- The currently-selected stop has an additional 2 px accent ring.
- For each adjacent pair of stops: a small diamond marker rendered
  above the bar at the midpoint position.

### Selection model

Single-select: one stop or one midpoint is selected at a time.

`STOP_OPACITY_COMBO` and `STOP_LOCATION_COMBO` bind to the selected
element. When a midpoint is selected, `STOP_OPACITY_COMBO` is disabled
(midpoints have no color / opacity) and `STOP_LOCATION_COMBO` shows the
midpoint's absolute location (computed from its stored
percentage-between value).

Selected-stop index is shared state (`state.selected_gradient_stop_index`),
so the on-canvas Gradient tool can highlight the same stop. Clamp to 0
when the gradient is replaced by a shorter one.

### Midpoint storage

Each adjacent pair of stops has a midpoint stored as a
**percentage-between** value (0–100, where 50 = halfway). Stored as
`stops[i].midpoint_to_next` on the left stop of each pair. Absolute
location is computed at render/display time from the two neighbor stops
and the percentage.

### Interactions

- **Click on empty bar area** (between stops on the filled gradient
  strip) → add a stop at that location, with color interpolated from
  the existing gradient at that point. Newly-added stop becomes
  selected.
- **Click on a stop marker** → select that stop.
- **Click on a midpoint marker** → select that midpoint.
- **Horizontal drag on a stop** → move the stop's location; clamp to
  `[0, 100]`. Preview updates live; commit on pointer-up.
- **Drag a stop off the bar** (vertical distance > 20 px from bar
  center on pointer-up) → delete the stop. Blocked if it would drop
  below the 2-stop minimum.
- **Horizontal drag on a midpoint** → move the midpoint's
  percentage-between within its neighbor-pair bounds.
- **Drag a stop past another stop** → the `stops[]` array re-sorts to
  stay in location order. Midpoints involved in the swap reset to 50%.
  Selected-stop index follows the moved stop.
- **Double-click a stop** → opens the shared
  `workspace/dialogs/color_picker.yaml` dialog, seeded with the stop's
  color. OK writes the new color to the stop; Cancel discards.

### Endpoints

First and last stops are **not anchored** — they can sit anywhere in
`[0, 100]`. Area outside the outermost stops extends with that stop's
color. This lets users start or end the gradient partway through the
element.

### Stop count

Minimum 2 stops (enforced by `TRASH_BUTTON` and drag-off-bar
disablement). No maximum.

### Combo-driven reorder

Typing a value into `STOP_LOCATION_COMBO` that crosses a neighbor stop
re-sorts `stops[]` on commit; midpoints involved in the reorder reset
to 50%. The selected-stop index follows the moved stop.

### Keyboard (when `GRADIENT_SLIDER` has focus and a stop or midpoint is selected)

| Input | Action |
|---|---|
| `Left` / `Right` | Nudge selected position by ±1% (stop location, or midpoint percentage-between). |
| `Shift + Left/Right` | Nudge by ±10%. |
| `Home` / `End` | Move selected stop to 0% / 100%. Midpoint: 0% / 100% within the pair. |
| `Delete` / `Backspace` | Delete the selected stop (blocked by 2-stop floor). Midpoints cannot be deleted. |

## Stroke sub-modes

`STROKE_WITHIN_BUTTON` / `STROKE_ALONG_BUTTON` / `STROKE_ACROSS_BUTTON`
define how a gradient maps onto a stroke. Exactly one is checked.

| Button | Semantics | Gradient parameter `t` |
|---|---|---|
| `STROKE_WITHIN_BUTTON` | Gradient is applied relative to the whole stroked element's bounding box (as if it were a fill). The stroke "cuts through" the gradient. Default. | 2-D coordinate within the element's bounding box |
| `STROKE_ALONG_BUTTON` | Gradient runs along the path's length. | Arc-length-normalized position on the path (0 at start, 1 at end) |
| `STROKE_ACROSS_BUTTON` | Gradient runs perpendicular to the path, from one stroke edge to the other. | Normalized distance across the stroke width (0 at one edge, 1 at the other) |

`STROKE_WITHIN_BUTTON` renders natively — standard SVG
`stroke="url(#g1)"` behavior. `STROKE_ALONG_BUTTON` and
`STROKE_ACROSS_BUTTON` have no native SVG equivalent and carry
`status: pending_renderer` until the path-parameterized paint path
lands.

## Method

`METHOD_DROPDOWN` values depend on the active type.

**Linear / Radial:**

| Value | Meaning |
|---|---|
| `classic` | Linear sRGB interpolation between stops. Default. Universally supported. |
| `smooth` | Perceptual interpolation (OKLab or similar). Smoother through hue changes. `status: pending_renderer`. |

**Freeform:**

| Value | Meaning |
|---|---|
| `points` | Each freeform node is a colored point; color diffuses radially with inverse-distance falloff. Default. |
| `lines` | Freeform nodes form line segments; color diffuses perpendicular to each line. |

The dropdown repopulates on `type` change; committing a new type
carries over an equivalent default (`classic` ↔ `points`,
`smooth` ↔ `lines` by position) when possible, else falls back to the
type's default.

## Dither

`DITHER_CHECKBOX` enables sub-pixel dithering to reduce visible banding
on subtle gradients. Stored as `gradient.dither: bool` on the active
gradient; per-element, not document-level. Default off.

Mathematically, the renderer adds sub-pixel noise of amplitude ≈ 1/256
per channel, computed via a deterministic dither pattern (blue-noise or
ordered matrix) so repeated renders produce identical output. Flagged
`status: pending_renderer` in all four apps.

## Document libraries

Libraries are JSON files under `workspace/gradients/`. Each file
contains:

```json
{
  "name": "Foliage",
  "description": "Nature-inspired green gradients",
  "gradients": [
    {
      "name": "Leaf",
      "type": "linear",
      "stops": [
        { "color": "#002200", "opacity": 100, "location": 0, "midpoint_to_next": 50 },
        { "color": "#00aa00", "opacity": 100, "location": 100 }
      ],
      "angle": 90,
      "aspect_ratio": 100,
      "method": "classic",
      "dither": false
    }
  ]
}
```

Each entry is a full gradient value — exactly the shape `element.fill`
uses when its type is a gradient (see Document model). "Applying" a
library entry copies this value to the selected element's fill or
stroke (per `state.fill_on_top`).

The library id used in panel state is the filename stem
(`foliage.json` → id `"foliage"`).

Bundled libraries ship in `workspace/gradients/`. The initial seed is
a small set (`neutrals`, `spectrums`, `simple_radial`) sufficient to
exercise the loading and browsing path; filling out the full catalog
(Foliage, Skintones, Sky, Earthtones, Vignettes, Water, Wood, Tints
and Shades, Gems and Jewels, Stone and Brick, Color Harmonies, Metals,
Fades, Seasons, Pastels, etc.) is scheduled separately as content
work.

The **Document Library** is a per-document library, always present,
always writable, and always visible in `DOCUMENT_LIBRARY_DROPDOWN`. It
is stored on the document itself — not as a bundled file — and travels
with document save/load. New documents start with an empty Document
Library. `ADD_TO_SWATCHES_BUTTON` appends to the Document Library.

## Fill-type coupling

`element.fill` (and `element.stroke`) is a discriminated union: a
color string (`"#rrggbb"` or `"none"`), or a gradient object. The three
mode buttons on the fill/stroke widget are shortcuts that ensure the
active attribute's type:

- **Color button** → ensure the active attribute is a color string.
- **Gradient button** → ensure the active attribute is a gradient
  object.
- **None button** → ensure the active attribute is `"none"`.

### Promotion to gradient

Triggered by any of:

1. Clicking the Gradient mode button on the fill/stroke widget.
2. Any interaction with the Gradient panel when the active attribute
   is solid or none (first panel edit = implicit promotion).
3. Clicking a `GRADIENT_TILE` preset.

Default seed gradient used on promotion:

| From | Seed stops | Type, params |
|---|---|---|
| Solid color `C` | `[{ color: C, location: 0, opacity: 100 }, { color: "#ffffff", location: 100, opacity: 100 }]` | linear, angle 0°, aspect 100%, classic, no dither |
| None | `[{ color: "#000000", … }, { color: "#ffffff", … }]` | same |

### Demotion to solid

Triggered only by the fill/stroke widget's Color button. The Gradient
panel has no demote action (`TRASH_BUTTON` deletes stops, not the
whole gradient).

New solid color = `gradient.stops[0].color` (the first stop). The
gradient value is discarded; no restore-last-gradient functionality in
v1.

### None

Triggered by the fill/stroke widget's None button. Current value is
discarded.

### Preview state

When the active attribute is solid/none and the Gradient panel is
open, the panel renders the default seed as a preview in
`GRADIENT_SLIDER`. An unobtrusive visual indicator (e.g. a dimmed
border or a "Not applied" subtitle) distinguishes preview from applied
state. First edit commits and removes the indicator.

## Document model

Every element carries these fields; defaults apply when the field is
unset.

| Field             | Type                                | Default    |
|-------------------|-------------------------------------|------------|
| `element.fill`    | color string or gradient object     | `"#000000"`|
| `element.stroke`  | color string or gradient object     | `"none"`   |

When the value is a gradient object:

| Field                      | Type                     | Required / default        |
|----------------------------|--------------------------|---------------------------|
| `gradient.type`            | `linear` / `radial` / `freeform` | required          |
| `gradient.angle`           | number (−180..+180)      | `0` (linear/radial only)  |
| `gradient.aspect_ratio`    | number (1–1000, percent) | `100` (linear/radial only)|
| `gradient.method`          | `classic` / `smooth` / `points` / `lines` | per-type default |
| `gradient.dither`          | boolean                  | `false`                   |
| `gradient.stroke_sub_mode` | `within` / `along` / `across` | `within` (stroke only) |
| `gradient.stops`           | list of stops            | required for linear/radial, absent for freeform |
| `gradient.nodes`           | list of freeform nodes   | required for freeform, absent for linear/radial |

Stop fields:

| Field              | Type                      | Required / default |
|--------------------|---------------------------|--------------------|
| `stop.color`       | hex string (`#rrggbb`)    | required           |
| `stop.opacity`     | number 0–100              | `100`              |
| `stop.location`    | number 0–100              | required           |
| `stop.midpoint_to_next` | number 0–100         | `50` (absent on last stop) |

Freeform node fields:

| Field            | Type                   | Required / default |
|------------------|------------------------|--------------------|
| `node.x`         | number (bounding-box-normalized) | required |
| `node.y`         | number (bounding-box-normalized) | required |
| `node.color`     | hex string (`#rrggbb`) | required           |
| `node.opacity`   | number 0–100           | `100`              |
| `node.spread`    | number 0–100           | `25`               |

Shared state (read/written by this panel and others):

| Field                               | Purpose                                    |
|-------------------------------------|--------------------------------------------|
| `state.fill_on_top`                 | Which attribute the panel edits            |
| `state.selected_gradient_stop_index`| Selected stop index, shared with the canvas Gradient tool |

## Multi-selection

Each control is evaluated independently against the current selection.
The panel is fully editable for mixed selections; any edit applies to
every element in the selection.

| Control | Uniform selection | Mixed selection |
|---|---|---|
| `LINEAR` / `RADIAL` / `FREEFORM_BUTTON` | Shared type checked | None checked; click forces that type on all |
| Stroke sub-mode buttons | Shared sub-mode checked | None checked; click applies to all |
| `ANGLE_COMBO` | Shared value | Blank (`—`); commit applies to all |
| `ASPECT_RATIO_COMBO` | Shared value | Blank (`—`); commit applies to all |
| `METHOD_DROPDOWN` | Shared value | Blank; picking applies to all |
| `DITHER_CHECKBOX` | Shared state | Indeterminate tri-state; click sets all to `true` first, then toggles |
| `GRADIENT_SLIDER` | Shared stops | First element's stops shown; edits apply to all (other elements' stops overwritten on commit) |
| `STOP_OPACITY_COMBO` / `STOP_LOCATION_COMBO` | Shared value | First element's selected stop's value; edits apply to all |
| Document Library tiles | Enabled; click applies to all | Enabled; click applies to all |
| `ADD_TO_SWATCHES_BUTTON` | Enabled | Disabled (no single gradient to save) |
| `TRASH_BUTTON` | Per Q9 rules | Disabled (stop index means different things across elements) |

**Fill-type mixed** (some elements have gradient on the active
attribute, others have solid/none): treated as mixed-gradient. The
seeded default gradient (per Fill-type coupling) is shown; any edit
applies to all selected elements, promoting the non-gradient ones to
gradient in the process.

**Type-mixed in a multi-selection** (some linear, some radial, some
freeform): type buttons show none checked. Clicking a type button
forces all to that type; non-conforming elements get a default seed
for the new type (a two-stop linear/radial gradient with current
colors, or a single-node freeform at the bounding-box center).

Evaluation is independent per control: a selection uniform on angle
but mixed on method shows the angle and a blank method — do not
collapse into a single panel-wide "mixed" flag.

## Enablement

**Full-panel disablement:**

- No document open — every control greyed.
- Selection is an element type that cannot hold a gradient (reserved;
  all visible element types are gradient-capable in v1).

**Panel-level state when a document exists:**

| Scenario | Panel state |
|---|---|
| No selection | Active in defaults mode — edits update the session default gradient used for future draws. |
| Selection has a gradient on the active attribute | Fully active. |
| Selection has solid / none on the active attribute | Fully active; first edit implicitly promotes (see Fill-type coupling). |
| Mixed selection | Fully active; per Multi-selection. |

**Per-control disabled-when** is summarized under each control in the
Controls section.

## Canvas editing

A Gradient tool provides on-canvas geometric editing of the active
gradient: drag handles for linear start/end points, radial
center/radius/focal-point handles, and node placement/manipulation for
freeform. See `GRADIENT_TOOL.md` for the full tool design.

The single source of truth remains the gradient object on
`element.fill` / `element.stroke`. The panel and the on-canvas tool
are two views of the same data; both read and write the same fields
with no synchronization protocol needed. The shared selected-stop
index (`state.selected_gradient_stop_index`) keeps the two UIs visually
coordinated on which stop is active.

## SVG attribute mapping

Gradients are stored inline on `element.fill` / `element.stroke`. On
export, the renderer synthesizes a `<defs>` block with generated ids;
on import, referenced gradients are inlined into each referring
element's fill/stroke value.

| Gradient component | SVG output |
|---|---|
| `type = linear` | `<linearGradient>` in `<defs>`, referenced via `fill="url(#gN)"` |
| `type = radial` | `<radialGradient>` in `<defs>`, referenced via `fill="url(#gN)"` |
| `type = freeform` | No SVG equivalent — custom compositing (`pending_renderer`) |
| `angle` (linear) | Computed into `x1` / `y1` / `x2` / `y2` on `<linearGradient>` |
| `angle` (radial) | `gradientTransform="rotate(...)"` |
| `aspect_ratio` (linear ≠ 100%) | `gradientTransform="scale(...)"` on the gradient coord system |
| `aspect_ratio` (radial ≠ 100%) | `gradientTransform="scale(sx, sy)"` |
| `stops[i].color`, `stops[i].opacity` | `<stop stop-color="..." stop-opacity="..."/>` |
| `stops[i].location` | `offset="<location/100>"` (SVG uses 0–1) |
| `stops[i].midpoint_to_next ≠ 50` | Synthesized as an additional intermediate stop between i and i+1; see Round-trip loss |
| `method = classic` | Default SVG interpolation (sRGB) — no attribute emitted |
| `method = smooth` | `color-interpolation: "linearRGB"`, or custom renderer path for OKLab (`pending_renderer`) |
| `dither = true` | Custom renderer pass (`pending_renderer`); no SVG equivalent |
| Gradient on fill | `fill="url(#gN)"` |
| Gradient on stroke, `within` | `stroke="url(#gN)"` — native |
| Gradient on stroke, `along` | No SVG equivalent (`pending_renderer`) |
| Gradient on stroke, `across` | No SVG equivalent (`pending_renderer`) |

**Identity-value rule.** When a field equals its default, the
corresponding SVG attribute is omitted from the output:

- `angle == 0` → omit rotation from `gradientTransform`.
- `aspect_ratio == 100` → omit scaling.
- `method == classic` → omit interpolation attribute.
- `dither == false` → omit.
- `midpoint_to_next == 50` → no intermediate stop synthesized; direct
  stop-to-stop interpolation.

**Id stability.** Generated ids are not stable across exports — each
export synthesizes fresh ids (`g0`, `g1`, …). Reimporting an exported
file inlines the gradients back into elements per the Document model,
so id churn has no effect on document identity.

**Round-trip loss.** Three features do not round-trip through standard
SVG:

- Midpoint positions ≠ 50% — encoded as extra stops on export; on
  re-import, these appear as ordinary stops and the midpoint concept
  is lost.
- `method = smooth` with perceptual (OKLab) interpolation —
  `linearRGB` is the closest standard SVG value but isn't a
  perceptual space.
- `dither = true` — purely a render-time effect; not serialized.

For full fidelity on jas→jas round-trips, these three are additionally
serialized as `jas:*` custom attributes
(`jas:stop-midpoint`, `jas:gradient-method`, `jas:gradient-dither`).
jas→standard-SVG→jas round-trips lose the custom attributes and thus
lose the extra fidelity.

## Keyboard shortcuts

Shortcuts for Gradient panel actions (menu items, stop nudging,
delete-selected-stop, etc.) are defined in `workspace/shortcuts.yaml`
rather than here.

## Panel-to-selection wiring status

Not yet implemented in any app. Flask (the generic app) is the target
for the initial implementation; propagation to the four native apps
follows per `CLAUDE.md`.

- **Flask** (`jas_flask`): pending.
- **Rust** (`jas_dioxus`): pending.
- **Swift** (`JasSwift`): pending.
- **OCaml** (`jas_ocaml`): pending.
- **Python** (`jas`): pending.

Open follow-ups:

- Renderer work flagged `pending_renderer`: smooth interpolation
  method, dither, stroke along / across, freeform compositing.
- On-canvas editing per `GRADIENT_TOOL.md` (separate spec).

## Deferred additions

- **List-view tile rendering** — `DOCUMENT_LIBRARY_SIZE_DROPDOWN` has
  two list-view items carrying `status: pending_renderer`. The row
  render path (thumbnail + name column) is not yet implemented;
  thumbnail views ship in v1.

- **Full bundled library catalog** — v1 ships 2–3 seed libraries;
  filling out Foliage, Skintones, Sky, Earthtones, Vignettes, Water,
  Wood, Tints and Shades, Gems and Jewels, Stone and Brick, Color
  Harmonies, Metals, Fades, Seasons, Pastels, etc. is scheduled as
  content authoring work.

- **Unified gradient + color libraries** — in v1 gradient libraries
  live in `workspace/gradients/` and color swatch libraries live in
  `workspace/swatches/`. A unified format with a `color_type` field
  would require changes to the swatches data model; deferred.

- **Copy / paste gradient** — not v1.

- **Alt-drag to duplicate a stop** — useful power-feature; defer from
  v1 to keep the slider interaction model simple.

- **Restore-last-gradient on demote** — demoting gradient → solid
  discards the gradient value; no restore path in v1.

- **Perceptual-space interpolation (OKLab) for `method = smooth`** —
  requires per-app shader or software path for non-sRGB interpolation;
  flagged `status: pending_renderer`.

- **Dither renderer pass** — flagged `status: pending_renderer` in all
  four apps; requires blue-noise or ordered-matrix sampling during
  gradient rasterization.

- **Along-stroke and across-stroke rendering** — requires path
  arc-length parameterization and perpendicular-distance
  parameterization respectively; flagged `status: pending_renderer`.

- **Freeform renderer** — flagged `status: pending_renderer`; requires
  2-D scattered-point or line-segment compositing.

- **Drag handles and canvas overlay** — full on-canvas gradient
  manipulation lives in `GRADIENT_TOOL.md`; deferred here.
