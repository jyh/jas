# Align

## Overview

The Align panel performs three families of operations on the
current selection:

- **Aligning** — move elements so their edges or centers coincide
  along an axis.
- **Distributing** — move elements so a chosen edge or center is
  evenly spaced along an axis.
- **Distributing spacing** — move elements so the gaps between
  them are uniform along an axis.

All three families share a single **Align To** target, which
determines the fixed reference used for the operation: the
selection bounding box, the artboard, or a designated key object.

When fewer than two elements are selected, Align operations are
disabled; when fewer than three are selected, Distribute and
Distribute Spacing operations are disabled.

Alignment:
- The ALIGN_LEFT_BUTTON finds the leftmost bounding box of all the elements in the selection, and moves all elements horizontally to have the same left position
- The ALIGN_HORIZONTAL_CENTER_BUTTON finds the mid-point of all the elements in the selection, and moves all elements horizontally to have the same midpoint
- The ALIGN_RIGHT_BUTTON finds the rightmost bounding box of all the elements in the selection, and moves all elements horizontally to have the same right position
- ALIGN_TOP_BUTTON, ALIGN_VERTICAL_CENTER_BUTTON, ALIGN_BOTTOM_BUTTON do the same, but in the vertical dimension

Distribute tries to ensure that the _spacing_ of elements is uniform.
- The DISTRIBUTE_LEFT_BUTTON moves the elements in the selection horizontally so that the left coordinates of their bounding boxes are evenly spaced
- DISTRIBUTE_HORIZONTAL_CENTER_BUTTON does the same, with the midpoints
- DISTRIBUTE_RIGHT_BUTTON does the same, with the right coordinates
- DISTRIBUTE_TOP_BUTTON, DISTRIBUTE_VERTICAL_CENTER_BUTTON, and DISTRIBUTE_BOTTOM_BUTTON do the same, but moving element vertically to ensure an even vertical distribution

The spacing tools look at the spacing between elements and try to ensure even spacing.
- DISTRIBUTE_VERTICAL_SPACING_BUTTON moves elements vertically to ensure that the spacing between the elements is the same
- DISTRIBUTE_HORIZONTAL_SPACING_BUTTON moves elements horizontally to ensure that the spacing between the elements is the same
- DISTRIBUTE_SPACING_VALUE is a numeric_combo specifying an
  explicit gap. Unit: pt. Range 0–1296 pt. Default 0. Presets:
  0, 6, 12, 18, 24, 36, 72. The input is enabled only when
  ALIGN_TO_KEY_OBJECT_BUTTON is the active target and a key
  object has been designated; disabled otherwise.

The behavior of the two spacing buttons depends on whether
DISTRIBUTE_SPACING_VALUE is enabled:

- When enabled, the buttons apply exactly the input's value as
  the gap, anchored on the key object; all non-key elements
  move so every interior gap along the chosen axis equals that
  value.
- When disabled, the buttons average the existing gaps — the
  two extremal elements along the axis hold position, and
  interior gaps average evenly between them.

## Widget types

- ALIGN_* buttons (6 total), DISTRIBUTE_* buttons (6 total),
  and DISTRIBUTE_*_SPACING_BUTTON (2 total) — each is an
  icon_button. Clicking fires the operation; there is no
  persistent checked state because the result is a one-shot
  move, not a mode.

- ALIGN_TO_ARTBOARD_BUTTON, ALIGN_TO_SELECTION_BUTTON, and
  ALIGN_TO_KEY_OBJECT_BUTTON — each is an icon_toggle. The
  three form a mutually-exclusive radio group mirroring
  panel.align_to; exactly one is checked. Default
  ALIGN_TO_SELECTION_BUTTON.

- DISTRIBUTE_SPACING_VALUE — numeric_combo (already described
  under Distribute Spacing above).

## Icon names

Each icon button references an SVG icon asset by name. The 17
icon names used by this panel are:

- Alignment buttons: `align_left`, `align_horizontal_center`,
  `align_right`, `align_top`, `align_vertical_center`,
  `align_bottom`.
- Distribute buttons: `distribute_left`,
  `distribute_horizontal_center`, `distribute_right`,
  `distribute_top`, `distribute_vertical_center`,
  `distribute_bottom`.
- Distribute Spacing buttons: `distribute_spacing_vertical`,
  `distribute_spacing_horizontal`.
- Align To buttons: `align_to_artboard`, `align_to_selection`,
  `align_to_key_object`.

Icon asset files ship under `workspace/icons/` with these stem
names; the tabbed panel-group renderer resolves each icon_button
reference via its `icon:` key in the generated yaml.

## Align To target

"Align To" is the fixed reference every Align and Distribute
operation reads. Three mutually exclusive icon_buttons form a
radio group; exactly one is active at a time.

- ALIGN_TO_SELECTION_BUTTON (default) — the reference is the
  bounding box of the current selection. Align moves all
  elements relative to the selection bbox; Distribute holds the
  two extremal elements along the axis and redistributes
  interior ones between them.

- ALIGN_TO_ARTBOARD_BUTTON — the reference is the active
  artboard's rectangle. Align moves each element to the
  corresponding artboard edge or center; Distribute spreads
  elements across the artboard extent along the axis.

- ALIGN_TO_KEY_OBJECT_BUTTON — one designated element within
  the selection is the reference. The key object never moves;
  other selected elements move relative to it.

Key-object designation:

- Activating ALIGN_TO_KEY_OBJECT_BUTTON enters key-object mode.
  The first subsequent click on an already-selected element
  designates that element as the key.
- Clicking the designated key again, or clicking outside the
  selection, clears the designation; the target falls back to
  ALIGN_TO_SELECTION_BUTTON.
- Changing the selection so the key is no longer part of it
  also clears the designation automatically.
- Only one key object exists at a time.

## Enable and disable rules

Selection-count thresholds:

- Align operations require at least 2 elements selected; they
  are disabled otherwise.
- Distribute operations require at least 3 elements selected;
  they are disabled otherwise.
- Distribute Spacing operations require at least 3 elements
  selected; they are disabled otherwise.

Locked and hidden elements in the selection do not move and do
not contribute to the bounding-box math. They count as selected
for the threshold check but are treated as fixed reference
points.

Groups move as single units: a selected group's outer bounding
box is the value used for all operations. To align a group's
children independently, enter isolation mode and select the
children there.

When the target is ALIGN_TO_ARTBOARD_BUTTON, the reference is
the active artboard's rectangle regardless of which artboards
the selection spans.

When the target is ALIGN_TO_KEY_OBJECT_BUTTON but no key has
been designated, all Align and Distribute buttons disable; the
button row re-enables when the user designates a key by
clicking an already-selected element.

## Bounding box selection

All Align, Distribute, and Distribute Spacing operations read
element bounding boxes to compute their moves. Two bounding-box
variants are available, and the choice applies uniformly to
every operation in the panel:

- **Geometric bounds** — the bounding box of the path geometry
  alone, ignoring stroke width and any fill bleed.
- **Preview bounds** — the bounding box of the rendered
  appearance, including stroke width and visible fill effects.

The **Use Preview Bounds** panel-menu entry toggles between the
two. When checked, every operation consults preview bounds.
When unchecked (default), every operation consults geometric
bounds. The choice persists across panel opens.

"Bounding box" in the Alignment, Distribute, and Distribute
Spacing descriptions always refers to whichever variant the
menu currently selects.

Here is the layout described in bootstrap form.

```yaml
panel:
- .row:
  - .col-12: "Align Objects:"
- .row:
  - .col-6:
    - .row:
      - .col-4: ALIGN_LEFT_BUTTON
      - .col-4: ALIGN_HORIZONTAL_CENTER_BUTTON
      - .col-4: ALIGN_RIGHT_BUTTON
  - .col-6:
    - .row:
      - .col-4: ALIGN_TOP_BUTTON
      - .col-4: ALIGN_VERTICAL_CENTER_BUTTON
      - .col-4: ALIGN_BOTTOM_BUTTON
- .row:
  - .col-12: "Distribute Objects:"
- .row:
  - .col-6:
    - .row:
      - .col-4: DISTRIBUTE_LEFT_BUTTON
      - .col-4: DISTRIBUTE_HORIZONTAL_CENTER_BUTTON
      - .col-4: DISTRIBUTE_RIGHT_BUTTON
  - .col-6:
    - .row:
      - .col-4: DISTRIBUTE_TOP_BUTTON
      - .col-4: DISTRIBUTE_VERTICAL_CENTER_BUTTON
      - .col-4: DISTRIBUTE_BOTTOM_BUTTON
- .row:
  - .col-6:
    - .row:
      - .col-12: "Distribute Spacing:"
    - .row:
      - .col-3: DISTRIBUTE_VERTICAL_SPACING_BUTTON
      - .col-3: DISTRIBUTE_HORIZONTAL_SPACING_BUTTON
      - .col-6: DISTRIBUTE_SPACING_VALUE
  - .col-6:
    - .row:
      - .col-12: "Align To:"
    - .row:
      - .col-4: ALIGN_TO_ARTBOARD_BUTTON
      - .col-4: ALIGN_TO_SELECTION_BUTTON
      - .col-4: ALIGN_TO_KEY_OBJECT_BUTTON
```

## Panel menu

- **Use Preview Bounds** (checkmark if active) — toggles
  `panel.use_preview_bounds`. When checked, every Align,
  Distribute, and Distribute Spacing operation consults preview
  bounds; when unchecked, geometric bounds (see §Bounding box
  selection).
- ----
- **Reset Panel** — resets `panel.align_to` to
  `ALIGN_TO_SELECTION_BUTTON`, clears any designated key
  object, clears `panel.distribute_spacing_value`, and sets
  `panel.use_preview_bounds` to false.
- ----
- **Close Align** — dispatches `close_panel` with
  `params: { panel: align }`, hiding the Align tab.

## Panel state

All panel state mirrors the `state.align_*` surface and is
re-initialised from it on panel open (see `init:` in the yaml):

| Panel key                        | Source state key                  | Type    | Default                  |
|----------------------------------|-----------------------------------|---------|--------------------------|
| `panel.align_to`                 | `state.align_to`                  | enum    | `selection`              |
| `panel.key_object_id`            | `state.align_key_object_id`       | element ID or null | null          |
| `panel.distribute_spacing_value` | `state.align_distribute_spacing`  | pt      | 0                        |
| `panel.use_preview_bounds`       | `state.align_use_preview_bounds`  | boolean | false                    |

The twelve Align / Distribute action buttons and the two
Distribute Spacing buttons have no persistent state of their
own — each click is a one-shot operation that reads the four
keys above and mutates the selected elements' positions
directly. Consequently the panel has no per-button mirror keys.

Every panel-state commit fires two effects: a
`set_panel_state` for the mirror key and a `set` for the
corresponding `state.align_*` key. This dual-write keeps the
panel's immediate visual state and the document's authoritative
state in sync without round-tripping through a re-init — same
pattern the other panels use.

`panel.key_object_id` is cleared automatically (written to
null) when any of the following conditions hold:

- `panel.align_to` changes away from `key_object`.
- The selection changes and the previously-designated key is
  no longer among the selected elements.
- The user clicks the designated key while in key-object mode
  (explicit un-designation).
- The user clicks outside the current selection while in
  key-object mode.

## SVG attribute mapping

The Align panel does not introduce any new SVG or `jas:*`
attributes on the selected elements. Every Align, Distribute,
and Distribute Spacing operation mutates element positions by
updating the translation component of each moved element's
`transform` attribute (or inserting a `transform="translate(…)"`
when the element previously had none).

The "Align To" target, "Use Preview Bounds" flag, the
designated key object ID, and the Distribute Spacing value all
live in panel / shared state (see §Panel state), not on the
document. None of them are persisted in the saved SVG.

**Identity-value rule.** Consistent with peer panels, when an
operation's computed translation is zero (the element was
already in the target position) the move is a no-op and no
`transform` mutation is written.

## Keyboard shortcuts

Shortcuts for Align panel actions are defined in
`workspace/shortcuts.yaml` rather than here. Typical bindings
(subject to the shortcuts file): alignment buttons have no
default accelerators; Distribute and Distribute Spacing likewise
unbound by default. The Align To selector mode is unbound.

## Undo semantics

Every Align, Distribute, or Distribute Spacing button press
produces exactly one undoable transaction covering all element
moves triggered by that press, regardless of how many elements
moved. A single Cmd-Z / Ctrl-Z reverts the entire operation;
one Cmd-Z / Ctrl-Z per moved element is not correct behavior.

Designating or clearing a key object (entering or leaving
key-object mode, clicking the designated key) is panel-state
only and does not produce an undo entry; key-object designation
is not part of the document.

Toggling **Use Preview Bounds** from the panel menu likewise
does not produce an undo entry; it is panel state, not
document state.
