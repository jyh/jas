# Character

The Character panel allows setting properties of text in the selection.
An example is shown in `examples/character.png`. This document is the
requirements description from which `workspace/panels/character.yaml`
will be generated.

## Overview

The Character panel is one tab in a tabbed panel group (alongside
Paragraph and OpenType); the tabbed-group container is specified
elsewhere. This document covers only the Character tab.

The panel edits per-character attributes of the text in the current
selection. It operates on **character ranges**: when a range of text
is selected for editing, each control shows the value shared by every
character in the range, or a blank if the characters disagree. When an
entire text element is selected as an object (not in text-editing
mode), the panel behaves as if every character in the element is
selected.

When the caret is placed in a text element with no range selected, the
panel is enabled and writes apply to the next-typed-character
attribute state (so the user can set up formatting before typing).

When no text element is selected at all, the panel is fully disabled
(all controls greyed).

## Controls

- `FONT_DROPDOWN` — `enum_dropdown` listing the installed fonts, with
  a checkmark next to the current font. Typing filters the list
  (typeahead). A magnifier-with-caret icon on the left is the visible
  search affordance. Uses standard virtualized scrolling. When the
  panel-menu entry **Enable in-menu font previews** is checked, each
  entry renders in its own typeface; otherwise in a neutral system
  font.

- `STYLE_DROPDOWN` — `enum_dropdown` listing the styles available for
  the current font (e.g. Regular, Italic, Bold, Bold Italic). The
  selected style name is parsed into `font-weight` and `font-style` on
  commit.

- `FONT_SIZE_DROPDOWN` — `numeric_combo`. Unit: pt. Range 1–1296 pt.
  Presets: 6, 8, 9, 10, 11, 12, 14, 18, 24, 36, 48, 60, 72. No Auto.
  Free numeric input allowed.

- `LEADING_DROPDOWN` — `numeric_combo`. Unit: pt. Range 0–1296 pt.
  Presets as for font size. Auto = 120% of the current font size;
  displayed in parentheses, e.g. `(14.4 pt)`.

- `KERNING_DROPDOWN` — `numeric_combo` with named modes `Auto`,
  `Optical`, `Metrics`, `0`. Free numeric input in 1/1000 em. When a
  named mode is active, the mode name is displayed; when the value is
  the default `0`, it appears in parentheses `(0)`.

- `TRACKING_DROPDOWN` — `numeric_combo`. Signed free numeric in
  1/1000 em; default 0, shown in parentheses. Presets: -100, -75, -50,
  -25, -10, 0, 10, 25, 50, 75, 100, 200.

- `VERTICAL_SCALE_DROPDOWN` — `numeric_combo`. Unit: %. Range
  1–10000%. Default 100%, shown in parentheses.

- `HORIZONTAL_SCALE_DROPDOWN` — `numeric_combo`. Unit: %. Range
  1–10000%. Default 100%, shown in parentheses.

- `BASELINE_SHIFT_DROPDOWN` — `numeric_combo`. Unit: pt. Signed;
  positive values shift the baseline upward. Default 0, shown in
  parentheses.

- `CHARACTER_ROTATION_DROPDOWN` — `numeric_combo`. Unit: °. Signed;
  positive values rotate clockwise (matching SVG `transform rotate`).
  Default 0°, shown in parentheses.

- `ALL_CAPS_BUTTON` — `icon_toggle` (tri-state). When on, renders the
  selection in uppercase. Mutually exclusive with `SMALL_CAPS_BUTTON`.

- `SMALL_CAPS_BUTTON` — `icon_toggle` (tri-state). Produces small
  capitals (uppercase-style glyphs sized to the x-height) for
  lowercase characters, and regular capitals for uppercase characters.
  Mutually exclusive with `ALL_CAPS_BUTTON`.

- `SUPERSCRIPT_BUTTON` — `icon_toggle` (tri-state). Positions the
  selected text above the baseline (as in the `2` in H₂O, or the
  exponent in E=mc²). Mutually exclusive with `SUBSCRIPT_BUTTON`.

- `SUBSCRIPT_BUTTON` — `icon_toggle` (tri-state). Positions the
  selected text below the baseline (as in the `2` in H₂O). Mutually
  exclusive with `SUPERSCRIPT_BUTTON`.

- `UNDERLINE_BUTTON` — `icon_toggle` (tri-state). Underlines the
  selected text.

- `STRIKETHROUGH_BUTTON` — `icon_toggle` (tri-state). Applies
  strikethrough to the selected text.

- `LANGUAGE_DROPDOWN` — `enum_dropdown` listing languages by ISO 639-1
  codes. Sets the language of the selected text (used for hyphenation
  and line-breaking).

- `ANTI_ALIASING_DROPDOWN` — `enum_dropdown` with values `None`,
  `Sharp`, `Crisp`, `Strong`, `Smooth`.

- `SNAP_TO_GLYPH_INDICATOR` — decorative icon, non-interactive.
  Tooltip: "use glyph-based guides".

- `SNAP_TO_GLYPH_INFO_BUTTON` — `icon_button`. When the feature is
  implemented, clicking will open browser-rendered documentation for
  Snap to Glyph. Currently permanently disabled and marked
  unimplemented (mirrors the `Create New Swatch…` pattern in
  `color.yaml`).

- `SNAP_BASELINE_BUTTON`, `SNAP_X_HEIGHT_BUTTON`,
  `SNAP_GLYPH_BOUNDS_BUTTON`, `SNAP_PROXIMITY_GUIDES_BUTTON`,
  `SNAP_ANGULAR_GUIDES_BUTTON`, `SNAP_ANCHOR_POINT_BUTTON` — six
  independent `icon_toggle` buttons, one per Snap to Glyph category.
  See the Snap to Glyph section.

- `TOUCH_TYPE_PANEL_BUTTON` — icon+label button that appears at the
  very top of the panel only while the panel-menu item **Touch Type
  Tool** is checked. See the Touch Type section.

All attributes operate on the selected text, which may be a tspan (or
a range of characters within a tspan) inside a text element. See the
Selection model and editing rules section for the tspan split / merge
rule.

## Layout

Strings in quotes (`"font size icon"`, `"Snap to Glyph"`, etc.) are
literal labels or icon references. Bare identifiers (`FONT_DROPDOWN`,
etc.) are widget IDs.

```yaml
panel:
- .row: TOUCH_TYPE_PANEL_BUTTON           # visible only when touch_type_enabled
- .row: FONT_DROPDOWN
- .row: STYLE_DROPDOWN
- .row:
  - .col-2: "font size icon"
  - .col-4: FONT_SIZE_DROPDOWN
  - .col-2: "leading icon"
  - .col-4: LEADING_DROPDOWN
- .row:
  - .col-2: "kerning icon"
  - .col-4: KERNING_DROPDOWN
  - .col-2: "tracking icon"
  - .col-4: TRACKING_DROPDOWN
- .row:
  - .col-2: "vertical scale icon"
  - .col-4: VERTICAL_SCALE_DROPDOWN
  - .col-2: "horizontal scale icon"
  - .col-4: HORIZONTAL_SCALE_DROPDOWN
- .row:
  - .col-2: "baseline shift icon"
  - .col-4: BASELINE_SHIFT_DROPDOWN
  - .col-2: "character rotation icon"
  - .col-4: CHARACTER_ROTATION_DROPDOWN
- .row:
  - .col-2: ALL_CAPS_BUTTON
  - .col-2: SMALL_CAPS_BUTTON
  - .col-2: SUPERSCRIPT_BUTTON
  - .col-2: SUBSCRIPT_BUTTON
  - .col-2: UNDERLINE_BUTTON
  - .col-2: STRIKETHROUGH_BUTTON
- .row:
  - .col-6: LANGUAGE_DROPDOWN
  - .col-6: ANTI_ALIASING_DROPDOWN

# Snap to Glyph section — visible only when snap_to_glyph_visible is true
- .row:
  - .col-6: "Snap to Glyph"
  - .col-2: SNAP_TO_GLYPH_INDICATOR
  - .col-1: SNAP_TO_GLYPH_INFO_BUTTON      # 3-column right-padding is intentional
- .row:
  - .col-2: SNAP_BASELINE_BUTTON
  - .col-2: SNAP_X_HEIGHT_BUTTON
  - .col-2: SNAP_GLYPH_BOUNDS_BUTTON
  - .col-2: SNAP_PROXIMITY_GUIDES_BUTTON
  - .col-2: SNAP_ANGULAR_GUIDES_BUTTON
  - .col-2: SNAP_ANCHOR_POINT_BUTTON
```

## Panel menu

- **Show Snap to Glyph Options** (checkmark if active) — toggles the
  visibility of the Snap to Glyph section in the panel (the header
  row and the six category buttons).
- ----
- **Show Font Height Options** (checkmark if active) — reserved for a
  future font-height options sub-section; no UI yet.
- ----
- **Standard Vertical Roman Alignment** (checkmark if active) —
  permanently disabled; will be enabled when the Vertical Type Tool
  ships. Intended behavior described in the Standard Vertical Roman
  Alignment section.
- ----
- **Touch Type Tool** (checkmark if active) — toggles
  `panel.touch_type_enabled`. When checked, `TOUCH_TYPE_PANEL_BUTTON`
  is visible at the top of the panel; when unchecked the button is
  hidden.
- **Enable in-menu font previews** (checkmark if active) — when on,
  each entry in `FONT_DROPDOWN` renders in its own typeface; when off,
  entries render in a neutral system font.
- ----
- **All Caps** (checkmark if active) — mirrors `ALL_CAPS_BUTTON`;
  both surfaces write the same shared attribute on the selection.
  Mutually exclusive with Small Caps.
- **Small Caps** (checkmark if active) — mirrors
  `SMALL_CAPS_BUTTON`. Mutually exclusive with All Caps.
- **Superscript** (checkmark if active) — mirrors
  `SUPERSCRIPT_BUTTON`. Mutually exclusive with Subscript.
- **Subscript** (checkmark if active) — mirrors `SUBSCRIPT_BUTTON`.
  Mutually exclusive with Superscript.
- ----
- **Fractional Widths** (checkmark if active) — when on, text uses
  varying spaces between characters for better optical flow. Turning
  it off forces whole-pixel spacing, which can make text look chunky.
  Default: on.
- ----
- **No Break** (checkmark if active) — applied to the current
  selection, prevents it from being split across two lines by
  hyphenation or text wrapping.
- ----
- **Reset Panel** — clears every Character attribute on the current
  selection back to its default (font, style, size, leading, kerning,
  tracking, scales, baseline shift, character rotation, caps / sub /
  super / underline / strike, language, anti-alias, fractional widths,
  no break). Numeric fields return to their parenthesised default
  display.

## Selection model and editing rules

1. The panel operates on **character ranges** within a text element.
   When an entire text element is selected as an object, the panel
   behaves as if every character in it is selected.
2. For enum and numeric fields, a control shows the single concrete
   value iff every character in the selection agrees; otherwise the
   field is blank.
3. For icon toggles, a button shows on iff every character has the
   attribute, off iff none do, and a mixed tri-state indicator
   otherwise.
4. Writing to a blank or mixed field applies the new value to every
   character in the selection (overwriting variation). Leaving a
   blank field untouched preserves each character's existing value.
5. On write, tspans are split at the selection boundaries so the
   selection lives in one or more tspans sharing the new attribute
   set. On commit, adjacent tspans that share identical attribute
   sets are merged back into a single tspan.
6. When the caret is placed in a text element with no range selected,
   the panel is enabled; writes set the next-typed-character
   attribute state.
7. When no text element is selected at all, the panel is fully
   disabled.

## Parenthesised defaults

Numeric fields distinguish explicit values from computed defaults:
when a field shows a computed or default value (no explicit override
on the selection), the value is rendered in parentheses — e.g.
`(14.4 pt)`, `(0)`, `(Auto)`. Editing the field commits an explicit
value and the parens are removed. Resetting the field to the computed
default restores the parenthesised display.

## Touch Type tool

The Touch Type tool provides a special editing mode in which
individual letters can be selected, rotated, moved, or scaled while
the text remains fully editable. An example of the panel with the
tool enabled is `examples/touch-type.png`; an in-canvas session is
`examples/touch-type-session.png`.

Two pieces of state govern the tool:

- `panel.touch_type_enabled` — toggled by the panel-menu entry
  **Touch Type Tool**. When true, `TOUCH_TYPE_PANEL_BUTTON` is visible
  at the top of the Character panel; when false, the button is
  hidden.
- `state.touch_type_active` — whether the tool is the currently
  selected canvas tool. For now, the only activation path is clicking
  `TOUCH_TYPE_PANEL_BUTTON`, which toggles this state on and off.
  When active, the button is highlighted and the six Snap-to-Glyph
  category buttons are non-interactive (clicks do nothing; visually
  dimmed).

When `state.touch_type_active` is true, the canvas cursor changes so
that individual letters can be selected. A single selected glyph
displays a bounding box with four corner handles, four side-middle
handles, and a rotation handle above it.

**Gesture-to-attribute mapping:**

| Gesture | Writes to |
|---|---|
| Drag letter body, vertical component | `baseline_shift` (pt) |
| Drag letter body, horizontal component | per-letter `dx` offset on the tspan (not surfaced in the Character panel) |
| Drag a corner handle | both `vertical_scale` and `horizontal_scale` (%); uniform if Shift held, free otherwise |
| Drag a side-middle handle (left / right) | `horizontal_scale` only |
| Drag a side-middle handle (top / bottom) | `vertical_scale` only |
| Drag the rotation handle | `character_rotation` (°); free, Shift constrains to 15° increments |

**Storage rule:** each touched glyph is guaranteed to live in its own
solo tspan; the parent tspan is split at the glyph boundaries if
necessary. Already-solo tspans are unaffected. On commit, if all
touch-type transforms on a solo tspan have returned to identity
(baseline shift 0, scales 100%, rotation 0°, dx 0), the tspan is
merged back into its neighbour (via the same merge rule as the
general selection model).

**Selection:** single-glyph only for the initial implementation. Tap
to select one glyph; click on empty canvas or press Esc to deselect.

**Undo:** each pointer-up is a single undo unit.

## Snap to Glyph

Snap to Glyph provides snap targets derived from the geometry of
editable text, so objects can be aligned to letter features without
converting the text to outlines. When an object is dragged near a
text element with at least one category enabled, the application
generates temporary guide lines from the glyph geometry. The six
categories are:

- **Baseline** — the invisible line letters sit on.
- **x-Height** — the top of lowercase letters (as in `x`, `a`, `e`).
- **Glyph Bounds** — the far left, right, top, or bottom edges of a
  specific letter.
- **Proximity Guides** — guides near the Baseline, x-height, and
  Glyph Bounds, based on the glyph's shape and layout. Position is
  calculated from each character's maximum width or pixel density.
- **Angular Guides** — for letters with a slant (such as the side of
  a `V` or `A`), objects can be snapped to follow that exact angle.
- **Anchor Points** — the mathematical anchor points on the curves of
  each glyph outline.

See `examples/snap-to-glyph-items.png`. A. Baseline, B. x-Height,
C. Glyph Bounds, D. Proximity Guides, E. Angular Guides, F. Anchor
Point.

**Category model.** The six category buttons are independent on/off
toggles; there is no master enable/disable. The feature is active on
the canvas iff at least one category button is on. The six buttons
are non-interactive while the Touch Type tool is active.

**Access paths.** The Snap to Glyph section can be shown from any of
the following; all share the same `panel.snap_to_glyph_visible`
state:

1. The panel-menu entry **Show Snap to Glyph Options** toggles the
   section's visibility.
2. Right-clicking selected text (see `examples/snap-to-glyph.png`)
   displays a context menu containing a **Snap to Glyph** entry that
   makes the section visible (equivalent to checking the panel-menu
   entry).
3. Programmatic visibility changes from actions.

## Standard Vertical Roman Alignment

The Vertical Type Tool, which lays out text top-to-bottom (common in
East Asian typography), is not yet implemented. The **Standard
Vertical Roman Alignment** panel-menu entry is therefore permanently
disabled until the tool ships.

When implemented, the menu entry will control how Latin (Roman)
characters and numbers are oriented in vertical-type text:

- **Checked (on):** Latin characters are rotated 90° clockwise, so
  they lie on their side and can be read by tilting the head to the
  right. This is the conventional handling of Latin text in vertical
  East Asian layouts.
- **Unchecked (off):** Latin characters stand upright, stacked one on
  top of another, like the surrounding vertical-type characters.

## Panel state

Panel-local state (not persisted with the document):

- `panel.touch_type_enabled` — whether `TOUCH_TYPE_PANEL_BUTTON` is
  shown.
- `panel.snap_to_glyph_visible` — whether the Snap to Glyph section
  is shown.
- `panel.show_font_height_options` — placeholder (no UI yet).
- `panel.in_menu_font_previews` — whether font-dropdown entries
  render in their own typeface.

Shared state (read by the canvas and other panels):

- `state.touch_type_active` — whether the Touch Type tool is the
  currently selected canvas tool.
- `state.snap_baseline`, `state.snap_x_height`,
  `state.snap_glyph_bounds`, `state.snap_proximity_guides`,
  `state.snap_angular_guides`, `state.snap_anchor_point` — six
  independent snap-category flags.

Character attributes (font, size, kerning, tracking, etc.) are not
panel state; they are written as SVG/CSS attributes on the selected
tspans. See the SVG attribute mapping section.

## SVG attribute mapping

Character attributes live on tspans (or on the parent text element
when an attribute applies uniformly to every character in the
element):

| Control | SVG / CSS | Notes |
|---|---|---|
| Font family | `font-family` | CSS string |
| Font style (Regular / Italic / Bold / …) | `font-style` + `font-weight` | parsed from the style name |
| Font size | `font-size` | stored in pt |
| Leading | `line-height` | CSS; Auto = omit (inherits 120% × font-size) |
| Kerning (Auto / Optical / Metrics / 0 / numeric) | `font-kerning` + `letter-spacing` + `jas:kerning-mode` | named modes stored in the custom attribute |
| Tracking | `letter-spacing` | em-based, e.g. `0.025em` |
| Vertical / horizontal scale | `transform: scale(h, v)` on the tspan | identity = omit |
| Baseline shift | `baseline-shift` | pt, signed; + = up |
| Character rotation | `rotate` attribute on the tspan | per-glyph degrees, SVG-native |
| All Caps | `text-transform: uppercase` | |
| Small Caps | `font-variant: small-caps` | |
| Superscript / Subscript | `baseline-shift: super` / `sub` | mutually exclusive |
| Underline / Strikethrough | `text-decoration: underline` / `line-through` | |
| Language | `xml:lang` | ISO 639-1 |
| Anti-alias | `text-rendering` + `jas:aa-mode` | named mode in the custom attribute |
| Fractional Widths | `jas:fractional-widths` | custom; no CSS equivalent |
| No Break | `jas:no-break` (or wrap in a tspan with `white-space: nowrap`) | custom |

**Identity-value rule.** When an attribute equals its default
(`scale(1,1)`, rotation `0`, baseline shift `0`, scale 100%, …), the
attribute is **omitted** from the output rather than written, so
defaults appear as absence.

## Keyboard shortcuts

Shortcuts for Character panel actions (All Caps, Underline, etc.) are
defined in `workspace/shortcuts.yaml` rather than here.
