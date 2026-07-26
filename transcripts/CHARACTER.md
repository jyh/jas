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
  displayed in parentheses, e.g. `(14.4 pt)`. The 120% default is
  per-paragraph overridable via the Justification dialog's
  AUTO_LEADING_VALUE field (see PARAGRAPH.md §Justification
  Dialog) — when the wrapping paragraph carries `jas:auto-leading`
  and Character leading is Auto, that percentage replaces the 120%
  default for that paragraph.

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

## The field-scoped apply law

**A Character-panel edit names the field the user just committed, and
writes only what that field owns.** Every other character attribute is
preserved from the element being edited, per element. An edit to a
field that owns no element attribute writes nothing at all — not even
an undo step.

This is the law because the panel is not a picture of the selection.
An apply that rebuilt the whole attribute set imposed values the user
never chose on every control they did not touch, and over thirty-plus
fields there is no such thing as a small clobber: nudging Tracking on
a 30pt bold italic underlined Georgia run in French with a 4pt
baseline shift, a 40pt leading, Crisp anti-aliasing, 15° rotation,
120/90 glyph scales and Optical kerning reset all sixteen attributes
to the panel's 12pt sans-serif defaults. This is the same defect
class the Stroke panel had (STROKE.md "The field-scoped apply law",
JYH 2026-07-24), found while that one was being fixed and banked in
its follow-ups; it is fixed here the same way, off one shared corpus.
(CHARPANEL, 2026-07-25.)

The two ports had also drifted, which is the second half of the
stone. Swift's panel view pushed its live selection mirror into panel
state *before* the edit landed, so an edit arriving through a panel
widget mostly survived; Rust had no such sync, so the same edit
clobbered. A view-layer mirror is not a field-scoped apply: it does
nothing for the per-range route, nothing for a caller that applies
without going through the view, and it makes the two ports disagree
about what an apply means. Both ports now implement ONE law with no
port-specific preservation semantics.

The attribute **groups** — a group is the set of attributes one field
owns, and is a single attribute except where that is impossible:

| Panel field | Writes |
| --- | --- |
| `font_family` | `font-family` |
| `style_name` | the `font-weight` + `font-style` PAIR. Necessarily wide: the Style dropdown's entries (Regular / Italic / Bold / Bold Italic) each name a weight and a style together, and no control moves one without the other. An **unrecognised** style name writes NEITHER — leaving half the pair guessed is worse than leaving both alone. |
| `font_size` | `font-size` **only** — never `line-height`. Auto leading is an ABSENT `line-height`, so preserving the attribute bit-for-bit keeps Auto alive and lets it re-derive against the new size. |
| `leading` | `line-height`, empty when the committed leading equals the **element's** `font-size × 1.2` (the Auto value). |
| `kerning` | the `kerning` attribute |
| `tracking` | `letter-spacing` |
| `vertical_scale` | the vertical glyph scale, and **only** the vertical |
| `horizontal_scale` | the horizontal glyph scale, and **only** the horizontal |
| `baseline_shift`, `superscript`, `subscript` | the one `baseline-shift` attribute, with the toggles taking precedence over the number (see §Selection model's mutual exclusion). Three fields sharing a single-attribute group is not a wide group. |
| `character_rotation` | `rotate` |
| `all_caps`, `small_caps` | the `text-transform` + `font-variant` PAIR. Necessarily wide: the two toggles are mutually exclusive, and turning All Caps ON has to clear a small-caps `font-variant` — which a one-attribute write cannot do. |
| `underline`, `strikethrough` | the whole `text-decoration` token list. Necessarily wide for the same reason a dash array is: a CSS token list cannot be written a token at a time, so any decoration edit re-derives the list from both flags (alphabetical, so equality never depends on which toggle the user hit first). |
| `language` | `xml:lang` |
| `anti_aliasing` | the anti-alias mode, empty at the `Sharp` identity |
| `snap_to_glyph_visible`, the six `snap_*` category flags, `touch_type_enabled`, `show_font_height_options`, `in_menu_font_previews` | nothing. These are UI-only state (§Panel state); toggling one must not push an undo step that changes nothing. |

The two glyph scales are deliberately **separate** groups, for the
reason the Stroke law's two arrowhead scales are: they are two
independent inputs, so a shared group would let an edit of one stamp
the panel's value for the other onto the element.

**The Auto test reads the ELEMENT's font size, not the panel's.** The
whole-rebuild law compared the committed leading against the *panel's*
`font_size × 1.2`, which was harmless only because it rewrote the size
in the same breath. Under the field-scoped law a leading edit must not
consult a font-size field the user did not touch: a 30pt element with
a leading of 36 is at its Auto ratio and goes back to an empty
`line-height`, whatever the panel's own size field happens to say.
The same ruling retires the Auto-leading **post-write hook** from the
apply path — it stays as a display concern (keeping the Leading field
tracking a committed size) but the apply no longer needs it, because
`font_size` owning only the size means an absent `line-height`
survives on its own.

**Clearing the Leading field is Auto**, and the three implementations
reach that one outcome from two different shapes. Swift and the
reference hold the panel's leading as an OPTIONAL, so an absent
leading is Auto directly. Rust holds a plain number and cannot
represent absence, so its nullable-clear path materialises the
ELEMENT's Auto value (its own `font-size × 1.2`) — which the law then
recognises as Auto and writes as the empty attribute. Materialising
from the element rather than from the panel's size field is what makes
the two shapes agree: with a stale 12pt panel over a 30pt element, the
panel-derived value (14.4) would have been written out as an explicit
`14.4pt` while the other ports wrote nothing.

The law governs both routes that write the document. The
**whole-element** route lifts each selected element's own sixteen
attributes, overwrites the edited group, and writes back — per
element, so a mixed selection keeps each element's values. The
**per-range** route (an active edit session with a character range)
builds the same panel override template and then clears every field
outside the group, so `merge_tspan_overrides` leaves the range's other
attributes alone; groups with no tspan-level representation (the glyph
scales, kerning) write nothing rather than stamping the panel's other
attributes instead. The **caret** route primes the edit session's
pending next-typed-character override and touches no document, so its
replace-the-whole-template semantics are unchanged and remain banked
with the display-vs-apply sync question.

The law is stated in the live reference
(`workspace_interpreter/character_law.py`: `CHARACTER_EDIT_GROUPS` is
the field → group table, `character_with_group` the law) and pinned
across all three live implementations by
`test_fixtures/character_apply/panel_edit.json`, whose `expected` is a
DELTA so "everything else is preserved" is stated directly. The
reference arm additionally asserts the corpus REJECTS the
whole-rebuild law it replaced, so the gate cannot pass vacuously.

## Panel-to-selection wiring status

Fully wired in Rust, Swift, OCaml, and Python. Editing a Character-
panel control (Size, Leading, a Caps toggle, Baseline Shift, …)
updates the panel scope in the app's state store and then pushes the
edited field's attribute group onto the selected Text / TextPath
elements via each app's `apply_character_panel_to_selection` pipeline
(see §The field-scoped apply law — the FROZEN OCaml and Python ports
still carry the pre-CHARPANEL whole-rebuild behaviour, per POLICY.md
§1). The inverse direction — panel widgets reflect the selected
element's current attributes — lands through live overrides built on
each render.

Per-app entry points:

- **Reference** (`workspace_interpreter`): `character_law.py` states the
  field → group table (`CHARACTER_EDIT_GROUPS`), the group → attribute
  table (`CHARACTER_GROUP_ATTRS`), the panel-default fallbacks
  (`CHARACTER_PANEL_FIELDS`, machine-checked against the generated
  workspace bundle) and the law itself (`character_with_group`).
- **Rust** (`jas_dioxus`): `apply_character_panel_to_selection(edited)`
  in `src/workspace/app_state.rs`, over the pure `character_with_group`
  + `CharacterEditGroup` in the same file. Panel-to-widget overrides
  are built in
  `src/workspace/dock_panel.rs::build_live_panel_overrides`. The
  widget dispatch refactor (Layer 1 below) lives in the generic
  `render_select / render_toggle / render_number_input /
  render_text_input` helpers in `src/interpreter/renderer.rs`,
  switched by the enclosing panel's `panel_kind`; each of those eight
  commit sites passes the field key it just wrote.
- **Swift** (`JasSwift`): `applyCharacterPanelToSelection(edited:)` and
  the `notifyPanelStateChanged` dispatcher in
  `Sources/Interpreter/Effects.swift`; the law
  (`CharacterEditGroup` / `CharacterAttrs` / `characterWithGroup` /
  `characterAttrsForGroup`) and the live overrides both in
  `Sources/Interpreter/CharacterPanelSync.swift`. Widget write-backs
  flow through `YamlElementView.commitPanelWrite` and the per-panel
  state scope lives on `Model.stateStore`.
- **OCaml** (`jas_ocaml`): `apply_character_panel_to_selection` in
  `lib/interpreter/effects.ml` with the `State_store.subscribe_panel`
  hook. GTK widget callbacks in `lib/interpreter/yaml_panel_view.ml`
  commit via `_write_back_bind`.
- **Python** (`jas`): `apply_character_panel_to_selection` in
  `jas/panels/character_panel_state.py`, subscribed through the
  store's panel notifier.

All four apps' canvases also honor the 11 character attributes
directly when rendering text (see the SVG attribute mapping above).

No remaining polish items on the Character panel itself. Open
follow-ups live with the Tspan sequence (TSPAN.md): multi-value
`rotate` (per-glyph different angles) requires tspan-per-glyph
splitting at serialization time; the uniform single-value case
(every glyph rotated by the same angle) already renders correctly
on all four canvases.
