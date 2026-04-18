# Color

The Color panel is an inline color editor for the active fill or stroke
color. This document is the requirements description from which
`workspace/panels/color.yaml` is generated.

## Overview

The Color panel is one tab in a tabbed panel group (alongside Swatches);
the tabbed-group container is specified elsewhere. This document covers
only the Color tab.

The panel edits whichever of the fill or stroke is "on top" (per the
shared `state.fill_on_top` flag, also used by the fill/stroke widget in
the Tools panel). Changing the color updates the selected elements'
fill or stroke attribute, and commits the color to a per-document
recent-colors list.

Five color modes are supported: Grayscale, RGB, HSB, CMYK, and Web Safe
RGB. The mode is panel-local state; switching modes re-displays the
same underlying color with a different slider set without changing the
color itself. The mode is re-initialised from the active color when the
panel first opens.

When the active attribute is `none` (fill or stroke explicitly unset
via the `NONE_SWATCH` or by other means), the sliders, hex field, and
color bar are disabled (non-interactive). Fixed and recent swatches
remain clickable — clicking any swatch implicitly un-nones the
attribute and commits the clicked color.

When no document is open at all, the panel is fully disabled.

## Controls

- `NONE_SWATCH` — `icon_button` rendering the application's
  none-indicator glyph. Sets the active attribute (fill or stroke, per
  `state.fill_on_top`) to none. Enables the none-swatch indicator on
  the fill/stroke widget.

- `BLACK_SWATCH`, `WHITE_SWATCH` — two fixed `color_swatch`es for
  `#000000` and `#ffffff`. Clicking commits the color via
  `set_active_color`.

- `SWATCH_RULE` — a 1 px vertical rule separating the fixed swatches
  from the recent-color history. Decorative; non-interactive.

- `RECENT_SWATCH_0` through `RECENT_SWATCH_9` — ten `color_swatch`
  slots holding the most recently committed colors, newest on the
  left. Per-document (not panel-local). Clicking a non-empty slot
  commits that color. Empty slots render as hollow squares with a
  solid border and are non-interactive.

- `FILL_STROKE_WIDGET` — the shared fill/stroke widget template
  (overlapping swatches + swap + reset buttons). Same visual behaviour
  as the toolbar widget, except single-click only (no double-click to
  open the modal picker).

- Mode-specific slider groups — exactly one group is visible at a
  time, selected by `panel.mode`:

  - `GRAYSCALE_SLIDERS` — single `K_SLIDER_GRAYSCALE` (0–100 %,
    percentage of black ink).
  - `HSB_SLIDERS` — `H_SLIDER` (0–359 °), `S_SLIDER` (0–100 %),
    `B_SLIDER` (0–100 %).
  - `RGB_SLIDERS` — `R_SLIDER`, `G_SLIDER`, `BLUE_SLIDER` (all
    0–255).
  - `CMYK_SLIDERS` — `C_SLIDER`, `M_SLIDER`, `Y_SLIDER`,
    `K_SLIDER_CMYK` (all 0–100 %).
  - `WEB_SAFE_SLIDERS` — `R_SLIDER_WS`, `G_SLIDER_WS`,
    `BLUE_SLIDER_WS` (0–255, step 51 — values snap to
    0/51/102/153/204/255).

  Each slider row is the shared `slider_row` template: 10 px label,
  horizontal slider filling the row, and a 64 px-wide numeric input
  on the right. Sliders commit on pointer-up; the numeric input
  commits on Enter or blur.

- `HEX_INPUT` — six-character `text_input` with a leading `#` label.
  Accepts `RRGGBB` (no `#` prefix). Editing and pressing Enter or Tab
  commits the value, updates the active color, and adds it to the
  recent-colors list. Non-hex characters are rejected. In Web Safe RGB
  mode, the entered value snaps to the nearest web-safe color on
  commit.

- `COLOR_BAR` — a 64 px tall 2-D color gradient at the bottom of the
  panel. Hue varies along the x-axis (0° at left to 360° at right).
  The y-axis is split into two halves: in the top half, saturation
  ramps from 0 % to 100 % while brightness goes from 100 % to 80 %;
  in the bottom half, saturation stays at 100 % while brightness goes
  from 80 % to 0 %. This produces a gradient that transitions from
  white/pastel at the top, through fully saturated colors in the
  middle, to black at the bottom. Clicking or dragging updates the
  active color in real time; the color is committed (added to
  recent-colors) on pointer-up.

All sliders, `HEX_INPUT`, and `COLOR_BAR` are disabled when the active
attribute is none. Clicking any swatch — fixed or recent —
implicitly un-nones the attribute and commits the clicked color.

## Layout

Strings in quotes are literal labels. Bare identifiers are widget IDs.
Mode-specific slider groups are rendered conditionally; only the group
matching `panel.mode` is visible.

```yaml
panel:
- .row:                                      # fixed swatches + recent history
  - NONE_SWATCH
  - BLACK_SWATCH
  - WHITE_SWATCH
  - SWATCH_RULE
  - RECENT_SWATCH_0
  - RECENT_SWATCH_1
  - RECENT_SWATCH_2
  - RECENT_SWATCH_3
  - RECENT_SWATCH_4
  - RECENT_SWATCH_5
  - RECENT_SWATCH_6
  - RECENT_SWATCH_7
  - RECENT_SWATCH_8
  - RECENT_SWATCH_9
- .row:                                      # fill/stroke widget + sliders
  - .col-3: FILL_STROKE_WIDGET
  - .col-9:
    - GRAYSCALE_SLIDERS                      # visible iff panel.mode == "grayscale"
    - HSB_SLIDERS                            # visible iff panel.mode == "hsb"
    - RGB_SLIDERS                            # visible iff panel.mode == "rgb"
    - CMYK_SLIDERS                           # visible iff panel.mode == "cmyk"
    - WEB_SAFE_SLIDERS                       # visible iff panel.mode == "web_safe_rgb"
- .row:                                      # hex input
  - "#"
  - HEX_INPUT
- COLOR_BAR                                  # 64 px tall, full width
```

## Panel menu

- **Grayscale** (checkmark if active) — sets `panel.mode = grayscale`.
- **RGB** (checkmark if active) — sets `panel.mode = rgb`.
- **HSB** (checkmark if active) — sets `panel.mode = hsb`.
- **CMYK** (checkmark if active) — sets `panel.mode = cmyk`.
- **Web Safe RGB** (checkmark if active) — sets `panel.mode = web_safe_rgb`.
  The five mode items are mutually exclusive; exactly one is always
  checked.
- ----
- **Invert** — replaces the active color with its channel-wise inverse
  (255−R, 255−G, 255−B). Disabled when the active attribute is none.
  Dispatches `invert_active_color`, which updates the color *and* adds
  the result to recent-colors.
- **Complement** — replaces the active color with its hue complement
  ((H + 180) mod 360, same S, same B). No-op if S = 0 (grayscale). Same
  commit rules as Invert. Disabled when the active attribute is none.
- ----
- **Create New Swatch…** — permanently disabled placeholder; will be
  enabled when the full Swatches panel lands.

## Color modes

The five modes share one underlying color; switching modes does not
change the color, only the controls used to edit it. Every mode writes
through to the same active fill or stroke color via the same
`set_active_color` action.

- **Grayscale**: single channel K (0–100 %, percentage of black ink).
  Committing K produces an achromatic color with that lightness.
- **RGB**: channels R, G, B (0–255).
- **HSB**: channels H (0–359°), S (0–100 %), B (0–100 %).
- **CMYK**: channels C, M, Y, K (0–100 % each).
- **Web Safe RGB**: same channels as RGB, step 51. Committing snaps
  each channel to the nearest value in {0, 51, 102, 153, 204, 255},
  yielding one of the 216 web-safe colors.

The mode is **panel-local state**, not persisted with the document or
across sessions. On first open, the mode defaults to HSB (per the yaml
`state.mode.default`); thereafter, the mode is re-initialised from the
active color each time the panel is re-opened (this initialisation
also re-populates `panel.h/s/b`, `panel.r/g/bl`, `panel.c/m/y/k`, and
`panel.hex` from the current active color so every mode is ready to
display).

## Recent colors

`panel.recent_colors` is a per-document list of the ten most recently
committed colors, newest first. The list is shared between fill and
stroke edits on that document.

A color is added to the front of the list on:

1. Slider pointer-up (after any drag of an HSB/RGB/CMYK/Grayscale/
   Web-Safe slider or its accompanying numeric input commit).
2. `HEX_INPUT` commit (Enter or Tab).
3. Any swatch click — including `NONE_SWATCH`, `BLACK_SWATCH`,
   `WHITE_SWATCH`, and any `RECENT_SWATCH_*`.
4. `COLOR_BAR` pointer-up.
5. `invert_active_color` / `complement_active_color` (the result is
   added via the same `set_active_color` path).

Duplicate colors move to the front of the list rather than adding a
second entry. The list is capped at 10; older entries fall off the
end. Empty slots render as hollow squares with a solid border and are
non-interactive.

## None state and disabled behaviour

When the active attribute (fill or stroke, per `state.fill_on_top`)
is `none`:

- `HEX_INPUT`, every slider in the visible slider group, and
  `COLOR_BAR` are disabled (non-interactive, visibly dimmed).
- `NONE_SWATCH`, `BLACK_SWATCH`, `WHITE_SWATCH`, and every
  non-empty `RECENT_SWATCH_*` remain clickable. Clicking any of them
  implicitly un-nones the attribute and commits the clicked color.
- Panel-menu **Invert** and **Complement** are disabled.

When no document is open, the panel is fully disabled (all controls
greyed).

## Color bar

`COLOR_BAR` is a 64 px tall 2-D gradient rendered at the bottom of the
panel. Its geometry is:

- **x-axis (width)**: hue, from 0° at the left edge to 360° at the
  right edge (360° wrapping back to 0° / red).
- **y-axis (height)**: split into an upper half and a lower half at
  mid-height.
  - **Upper half** (top to mid): saturation ramps from 0 % to 100 %;
    brightness simultaneously goes from 100 % to 80 %. Top edge is
    effectively white; mid-line is fully saturated at 80 % brightness.
  - **Lower half** (mid to bottom): saturation held at 100 %;
    brightness goes from 80 % to 0 %. Bottom edge is black.

The result is a continuous gradient that transitions from
white/pastel at the top, through fully saturated colors across the
middle, to black at the bottom.

**Behaviour:** Clicking or dragging on the bar updates hue and
saturation/brightness of the active color in real time. The color is
committed (and added to recent-colors) on pointer-up. Disabled when
the active attribute is none.

## Panel state

Panel-local state (not persisted with the document):

- `panel.mode` — active color mode (`grayscale` / `rgb` / `hsb` /
  `cmyk` / `web_safe_rgb`). Default: `hsb`.
- `panel.h`, `panel.s`, `panel.b` — working HSB channels
  (0–360 / 0–100 / 0–100).
- `panel.r`, `panel.g`, `panel.bl` — working RGB channels (0–255).
- `panel.c`, `panel.m`, `panel.y`, `panel.k` — working CMYK channels
  (0–100 each).
- `panel.hex` — working hex string (six characters, no `#` prefix).

Per-document state (persisted with the document):

- `panel.recent_colors` — list of up to 10 recently committed colors.

Shared state (read by this panel and others):

- `state.fill_on_top` — which attribute the panel edits.
- `state.fill_color`, `state.stroke_color` — the active colors the
  panel reads from and writes back to.

The channel values are redundant: they all describe the same
underlying color. On commit from any one of them, the others are
recomputed so every mode view stays in sync.

## Color attribute mapping

The active color resolves to a single `rgb(r, g, b)` triplet that
becomes the `fill` or `stroke` attribute (per `state.fill_on_top`) on
the selected elements. SVG has no native CMYK or hue-based colors, so
CMYK/HSB edits are converted to RGB on commit.

| Panel input | How it's stored |
|---|---|
| RGB / Web Safe RGB | `rgb(r, g, b)` directly |
| HSB | converted to RGB via standard HSB→RGB |
| CMYK | converted to RGB via standard CMYK→RGB |
| Grayscale K | `rgb(v, v, v)` where v = round(255 × (1 − K/100)) |
| Hex | parsed as `rgb(r, g, b)` |
| None | `fill="none"` / `stroke="none"` on the element |

**Identity-value rule.** No defaults are omitted here — fill and
stroke are explicit on elements that have them, and `none` is written
as the literal string `none`.

## Keyboard shortcuts

Shortcuts for Color panel actions (switching modes, Invert,
Complement, etc.) are defined in `workspace/shortcuts.yaml` rather
than here.

## Panel-to-selection wiring status

Fully wired in Flask (the generic app): the inline Color panel reads
and writes `state.fill_color` and `state.stroke_color`, which are
applied to the selected elements through the Flask action pipeline.
Recent colors persist per-document.

Propagation to the native apps is pending:

- **Rust** (`jas_dioxus`): scaffolding in `src/panels/color_panel.rs`;
  slider → state wiring and selection apply pipeline pending.
- **Swift** (`JasSwift`): scaffolding present; full wiring pending.
- **OCaml** (`jas_ocaml`): scaffolding present; full wiring pending.
- **Python** (`jas`): scaffolding present; full wiring pending.

Open follow-ups:

- `invert_active_color` and `complement_active_color` action handlers
  need implementations across the four native apps once the panel's
  basic read/write pipeline lands.
- Per-document `recent_colors` storage and serialisation is not yet
  wired in the native apps.
