# Layers

The Layer Panel displays the elements in the document. An example is shown in examples/layers.png.

Each element has a row in the panel.
- The EYE_BUTTON indicates the element's visibility.
- The LOCK_BUTTON indicates whether the element is locked.
- The TWIRL_DOWN_BUTTON is used to display or hide the elements of Layers and Groups.
- The ELEMENT_PREVIEW gives a small 32px square visual summary of the element.
- The ELEMENT_NAME is the name of the element, if it has one. Unnamed elements display their element type in angle brackets (e.g., <Path>, <Group>,
<Rectangle>), truncated with ellipsis if the name exceeds the available space.
- The SELECT_SQUARE is filled with the color of the element's nearest ancestor layer if the element is selected, otherwise it is empty.

ELEMENT_PREVIEW is a 32px square rasterized thumbnail of the element scaled to fit, on a white background. Thumbnails are refreshed as elements change
on a best-effort basis. Elements with outline or invisible visibility modes are rendered as if in preview mode. Empty groups and layers show a blank
preview.

Layers and groups have a TWIRL_DOWN_BUTTON, open by default. Twirl state persists across sessions. Leaf elements (paths, text, images) do not have a
twirl button; a blank gap preserves alignment. Empty layers and groups still show an active twirl button.

The SPACER is used for indentation in increments of 16px. Layers are not indented. Each nesting level adds 16px: direct children of a layer are
indented 16px, children of a group within a layer are indented 32px, and so on.

Click-and-wait on the ELEMENT_NAME enters inline editing mode (same as macOS file renaming). Enter confirms the new name, Escape cancels. Any element
can be renamed, including locked elements.

Here is the layout in bootstrap-style format.

panel:
- .row:
  - .col-11: SEARCH_ALL_TEXT
  - .col-1: SEARCH_FILTER_BUTTON
- .row: (per element)
  - .col-1: EYE_BUTTON
  - .col-1: LOCK_BUTTON
  - .col-9: SPACER TWIRL_DOWN_BUTTON ELEMENT_PREVIEW ELEMENT_NAME
  - .col-1: SELECT_SQUARE
- .footer:
  - NEW_LAYER_BUTTON
  - NEW_GROUP_BUTTON
  - DELETE_SELECTION_BUTTON

SEARCH_ALL_TEXT filters the panel by element name. As the user types, only elements whose names match the search text are shown. Parent elements
(groups, layers) of matching elements are shown to preserve hierarchy, even if they don't match themselves. SEARCH_FILTER_BUTTON opens a dropdown to
filter by element kind (line, rectangle, etc.). The search and kind filter can be combined. Clearing the search text restores the full panel.

Panel-selection is preserved during search but invisible for hidden rows; it re-appears when the search is cleared. Menu items only act on visible
(matching) panel-selected elements.

Visibility

Each element has a visibility mode with three values:
- preview: the element is rendered normally. The EYE_BUTTON shows an open eye icon.
- outline: the element is rendered as outlines only (no fills, no raster content). The EYE_BUTTON shows a hollow eye icon.
- invisible: the element is not rendered on the canvas. The EYE_BUTTON shows a struck-through eye icon.

Clicking the EYE_BUTTON cycles through the modes: preview → outline → invisible → preview.

Locking

Clicking the LOCK_BUTTON toggles the element between locked and unlocked. When locked, the button shows a padlock icon. When unlocked, the button is
blank. Locking a layer or group saves each child's lock state and locks all children recursively. Unlocking restores each child's previous lock state.

Element Selection

Clicking on the SELECT_SQUARE selects that element and deselects all others. Shift-click extends the selection from the last-clicked element to the
clicked element. Command-click toggles the clicked element in or out of the current selection. Elements can be selected across layers.

Panel Selection

There is another kind of selection: each element can be panel-selected by clicking on the element's spacer, twirl-down gap, preview, or name. This has
no relation to element selection; panel-selection is local to the panel and is used for moving elements around in the panel and for menu operations.
Panel-selected elements are highlighted with the system selection color as a background on the row. The usual semantics of shift-click and
command-click apply.

Panel-selected elements can be moved within the panel by dragging. This affects the ordering of elements in the document. When a selection is moved,
the elements preserve their order, but move to the drop point, potentially changing layers. A horizontal line between rows indicates the drop insertion
 point. Hovering over a collapsed container auto-expands it after a delay. Layers can be dragged into other layers (nesting), but not into themselves.
Non-layer elements can be dragged into layers and groups. Nothing can be dragged into a locked layer.

Panel Keyboard Shortcuts

- Delete/Backspace: delete panel-selected elements
- F2 or Enter: start renaming the panel-selected element
- Command-A: select all elements in the panel
- Up/Down arrow: move between visible rows
- Right arrow: expand a collapsed container, or move to first child if already expanded
- Left arrow: collapse an expanded container, or move to parent if already collapsed or a leaf

Menu

All menu operations that refer to "selected" layers or items act on panel-selection, not element selection (SELECT_SQUARE).

- New Layer... (brings up the Layer Options dialogue to create a new layer. The layer is inserted above the topmost panel-selected layer. If nothing is
 panel-selected, the layer is inserted at the top of the layer stack. The default name is auto-generated as "Layer N", skipping numbers already in use.
 The default color cycles through the preset list so adjacent layers get different colors.)
- New Group (wraps the panel-selected elements in a new group at the position of the topmost panel-selected element. All panel-selected elements must
be in the same layer; grayed out otherwise. Grayed out when nothing is panel-selected.)
- Duplicate (deep copies the panel-selected elements and all their contents, placing the copies above the originals. Grayed out when nothing is
panel-selected.)
- Delete Selection (deletes panel-selected elements and all their contents. Grayed out when nothing is panel-selected.)
- Delete Hidden Layers (deletes layers that are not visible)
- -----
- Options for Layer... (brings up the Layer Options dialogue for the topmost panel-selected layer. Grayed out when no layer is panel-selected.)
- ----
- Enter Isolation Mode / Exit Isolation Mode (toggle. "Enter Isolation Mode" saves the current visibility state of all layers, then makes all layers
and groups invisible except the panel-selected one. Non-isolated layers and groups appear dimmed in the panel. Isolation mode can be nested: entering
isolation on a group within an already-isolated layer pushes another level. Enabled when a layer or group is panel-selected. "Exit Isolation Mode" pops
 one level of isolation, restoring the visibility state saved on the most recent entry. Enabled when in isolation mode.)
- ----
- Flatten Artwork (recursively unpacks all groups in the panel-selected items until no groups remain. Enabled when the panel-selected items contain at
least one group. Grayed out otherwise.)
- Collect in New Layer (moves all panel-selected items into a new layer placed above all existing layers. The items are removed from their original
locations and maintain their relative order. The new layer's name and color follow the same auto-generation rules as New Layer. Grayed out when nothing
 is panel-selected.)
- ----
- Hide All Layers / Show All Layers (toggle: "Hide All Layers" when any layer is visible, "Show All Layers" when all layers are invisible)
- Outline All Layers / Preview All Layers (toggle: "Outline All Layers" when any layer is in preview mode, "Preview All Layers" when all layers are in
outline mode)
- Lock All Layers / Unlock All Layers (toggle: "Lock All Layers" when any layer is unlocked, "Unlock All Layers" when all layers are locked)

Right-Click Context Menu

Right-clicking a panel row opens a context menu with:
- Options for Layer...
- Duplicate
- Delete Selection
- Enter/Exit Isolation Mode
- Flatten Artwork
- Collect in New Layer

Layer Options Dialogue

An example is shown in examples/layer-options.png.

dialog:
- .row:
  .col3: "Name:"
  .col9: NAME
- .row:
  .col3: "Color:"
  .col9: LAYER_COLOR_DROPDOWN LAYER_COLOR_SWATCH
- .row:
  .col3:
  .col3: TEMPLATE_CHECKBOX
  .col3: LOCK_CHECKBOX
- .row:
  .col3:
  .col3: SHOW_CHECKBOX
  .col3: PRINT_CHECKBOX
- .row:
  .col3:
  .col3: PREVIEW_CHECKBOX
  .col3: DIM_IMAGES_TO_CHECKBOX
- .row:
  .col6:
  .col6: CANCEL_BUTTON OK_BUTTON

Layer attributes:
- LAYER_COLOR: each layer has a color that is used to color the selection highlight.
- LAYER_PRINT: boolean, if false the layer will not be included in prints (default true, not implemented)
- LAYER_TEMPLATE: boolean, if true the layer is a template (default false, not implemented)
- LAYER_DIM_IMAGES: boolean, if true raster images in the layer are dimmed (default false)
- LAYER_DIM_IMAGES_PERCENT: number 0–100, the opacity percentage applied to raster images when dimming is enabled (default 50)

Dialogue fields:
- NAME: the layer name
- LAYER_COLOR_DROPDOWN: the dropdown lists a set of preset colors for layers (red, blue, green, light red, light blue, dark green, etc.). When a preset
 is selected, the swatch updates to match. If the current color does not match any preset, the dropdown displays "Custom." If a custom color matches a
preset, the dropdown displays that preset name.
- LAYER_COLOR_SWATCH: clicking on the swatch brings up the Color Picker to change the color of the layer.
- TEMPLATE_CHECKBOX is checked if the layer is a template (default off, to be implemented)
- LOCK_CHECKBOX is checked if the layer is locked
- SHOW_CHECKBOX is checked if the layer is not invisible. In the Layer Options dialogue, the SHOW and PREVIEW checkboxes map to the visibility state:
  - SHOW unchecked → invisible (PREVIEW is disabled)
  - SHOW checked + PREVIEW checked → preview
  - SHOW checked + PREVIEW unchecked → outline
- PRINT_CHECKBOX is checked if the layer is included in prints (default on, to be implemented)
- PREVIEW_CHECKBOX is checked if the visibility mode is "preview" (otherwise "outline"). Disabled when SHOW is unchecked.
- DIM_IMAGES_TO_CHECKBOX is checked if raster images in the layer are dimmed to the specified percentage. When checked, the percentage input is
enabled. Default off, 50%.

Please read and understand these requirements. Analyze them for inconsistencies
and completeness. Make suggestions for improvements, ranking them in priority
from high to low, and giving each a number. What are the benefits? What are the
downsides? Be ready for a deep dive into any of the suggestions.
