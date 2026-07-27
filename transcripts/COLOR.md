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

Every one of those disabled / enabled states is a `state.fill_color ==
null` (or `state.stroke_color == null`) test, so an app's panel-render
`state` scope must be able to SAY null. Publishing a colour or omitting
the key is not enough: the scope starts from the `workspace/state.yaml`
defaults, where `fill_color` is `#ffffff`, so an omitted key leaves white
standing and the comparison can never be true. The three outcomes are
distinct and all three must be expressible — a colour, an explicit null
for "none", and *absent* for a MIXED selection, where absent correctly
means "leave the caller's value alone" and the controls stay live because
a colour edit applies to the whole selection. Both active ports got this
wrong once (CPTRIAGE); it is now pinned cross-language by the
`fill_stroke_none` action-corpus case's `expected_panel_state` block, and
the per-widget triage record is in COLOR_TESTS.md.

The SWATCH follows the same rule. Both active ports mark a none with the
red-diagonal no-paint indicator over a white face, and both decide
none-from-an-empty-slot by the BIND's own declaration rather than by the
value: a null from a bind naming a nullable `state` colour means "no
paint", while a null from `panel.recent_colors.3` means "that slot is
empty" and draws a hollow placeholder. An empty string carries the "no
paint" meaning too (a dialog's hex field cleared). Swift used to render
every non-colour as a transparent square, making an explicit none and an
empty slot identical; closed by COLORTIERS. An explicit none takes the
same SOLID border a painted swatch does — it is a real answer about the
paint — while an empty slot keeps the dashed placeholder border; Rust
derived that from "has no colour" alone and so wore the dashed border for
a none, converged in the COLORTIERS repair. The hollow ring's width still
differs (6px Rust, 3px Swift) and is banked in COLOR_TESTS.md.

Where the DEFAULT colours live is settled too: fill and stroke defaults
are WORKSPACE state, not document state, so File > New carries the
colour the user is mid-flow with rather than reseeding.

The tiers are selection → document default → app default. Which readers
resolve all three is listed below rather than counted: four rounds of this
wave shipped a count, and each one was wrong in a different way (a "six"
whose sixth item was called "a seventh", a "seven" in the report, a "nine"
implied by the sibling file, and a "two do not follow the rule" that was
missing at least four). **No total is claimed here, and none should be
added without the census that produces it.** The list is maintained by
hand; re-derive the candidate set with

    grep -rn 'defaultFill\|defaultStroke\|appDefaultFill\|appDefaultStroke' JasSwift/Sources/
    grep -rn 'default_fill\|default_stroke\|app_default_fill\|app_default_stroke' jas_dioxus/src/

and classify each surviving read by which tiers its enclosing function
consults. It is not certified exhaustive.

**Resolve all three tiers, and are converged across the ports:** the
panel-render `state` scope; the action-dispatch scope; the three
dialog-seeding sites, all of which now bottom out in `liveFillStrokeValues`
(`openToolbarColorPicker` and `openYamlDialogFromMenu` through
`dialogStateScope`; the `fill_stroke_widget` double-click →
`open_color_picker` through `colorPickerSeedContext`, which layers on
`dialogStateScope`); the toolbar
squares; the Color panel's SLIDERS; the Color panel's channel WRITE path,
which is not the same code as the sliders that display it; and the Color
panel's mode-switch SEED. Every one after the first two was caught
answering the question its own way; the record of which, and of what each
answered instead, is in COLOR_TESTS.md.

**Stop at the two DEFAULT tiers on purpose, identically in both ports:**
the panel menu's **Invert** and **Complement**, and their enabled state,
operate on the default paint and do not consult the selection. Whether
they SHOULD is an open question, banked in COLOR_TESTS.md.

Resolving the same tiers is only half of "one fact, one answer": the
readers have to DERIVE the same numbers from the colour they resolve, and
the law there is **quantise first, convert second**. Round the float colour
to three 8-bit values, then read hue / saturation / brightness, CMYK and
hex off those integers — never off the float colour, and never off a
`Color`'s stored h/s/b, which for an HSB-constructed colour is a triple the
8-bit grid was never applied to. The two derivations differ by up to a
whole unit in each channel, and because the panel's write path recomputes
the channels the user did NOT edit from this same derivation, the
difference reaches the committed colour and not just the display. One
function per port owns it (`color_util::panel_channels`,
`panelChannels(rf:gf:bf:)`), gated by
`test_fixtures/algorithms/color_convert.json`.

**Read ONE tier, and are not converged — each banked in COLOR_TESTS.md
rather than fixed:** Swift's NATIVE toolbar "C" / "/" mode buttons, which
predate the ruling and write the tab tier by hand (which is why no
user-level check can confirm the action-scope half in Swift yet); both
ports' NATIVE None buttons, which clear the document tier only and so
produce a "none" that every three-tier reader still sees as the app tier's
colour; and Rust's `get_app_state_field`, which serves the YAML `swap:`
effect from the APP tier while the other path to the same swap
(`AppState::swap_fill_stroke`, the X key) reads the DOCUMENT tier.

**Read ONE tier in BOTH ports, symmetrically, so they are not parity
breaks — but they are single-tier readers and the wave's premise says to
say so:** newly drawn elements take their paint from the document tier
alone (`buildElement` / `makePathFromCommands` in Swift, the same
`model.default_*` reads in `yaml_tool.rs`), with no app fallback, so after
File > New the panel shows a colour while a new rect draws with no fill;
the fill/stroke swap (`Controller.swapFillStrokeColors`,
`AppState::swap_fill_stroke`); the defaults RESET
(`reset_fill_stroke_defaults` and its `CanvasSubwindow` / `ContentView`
twins). All banked in COLOR_TESTS.md.

`AppState::active_color()` used to belong to that last group and no longer
does: it carries `.or_else(app_default_*)`, so Invert and Complement stay
available after File > New. Gated by
`colortiers_invert_stays_available_after_a_new_document` and Swift's
`colorPanelInvertStaysAvailableAfterFileNew` — both green. It is named here
because round 4's brief still listed it as an open single-tier reader; it
is not one.

And an ACTION's `state.fill_color` is read with the SELECTION in view —
clicking Solid with a shape selected asks whether THAT shape's fill is
none, not whether the app default is. Both that and the tier order are
pinned cross-language by
`test_fixtures/actions/fill_stroke_action_scope.json`.

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
