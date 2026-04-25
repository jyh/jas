# Artboards

The Artboards Panel sets properties of artboards. Every document has at least
one artboard, which is an area intended for printing. When the document is
printed, its contents are clipped to the artboards, and one artboard is printed
per page. In the default layout, the Artboards Panel is a sibling of the Layers
Panel.

Artboards are resizable with an Artboard Tool that we will design later.
Artboards may overlap.

When a new document is created, by default it starts with a single artboard of
size 612 × 792 pt (US Letter). This default is intentional rather than
locale-driven. Subsequent artboards in a document inherit dimensions from the
topmost existing artboard, so a user whose preferred size differs from Letter
changes the first artboard once and all further New Artboard actions pick up
the chosen size. A workspace-level override may be added later if a concrete
need arises.

**Printing (deferred).** When printing is implemented, each artboard produces
one page, in the order they appear in `document.artboards` (i.e., by
`ARTBOARD_NUMBER`). The artboard's `fill` determines the page background:
`"transparent"` prints as paper white; a color prints as a solid colored page.
Per-artboard display toggles (`show_center_mark`, `show_cross_hairs`,
`show_video_safe_areas`, and the associated `video_ruler_pixel_aspect_ratio`)
are screen-only and are not rendered on printed pages. Layer-level print
exclusion (LAYERS.md `LAYER_PRINT`) applies as specified there. Printing itself
is not yet implemented; this paragraph is the forward-reference for what the
already-specified artboard fields will mean once it lands.

## Canvas appearance

An artboard displays on the canvas as a rectangle. The canvas background is
gray, determined by the theme.

Canvas Z-order, back to front:

1. Canvas background (theme gray).
2. Artboard fills, painted in list order (later wins in overlaps).
3. Document element tree.
4. Fade overlay (if `fade_region_outside_artboard` is on) — applied to elements
   outside the union of all artboard bounds.
5. Artboard borders (thin, 1px screen-space).
6. Accent borders for panel-selected artboards (2px outside the default border,
   theme accent color; total visual thickness 3px).
7. Artboard labels (`N  Name`, above top-left of each artboard).
8. Per-artboard display marks: center mark, cross hairs, video safe areas.
9. Selection handles, marquees, tool overlays.

Artboard fills live behind elements; borders, labels, and marks live above
elements so they are never occluded.

**Fill.** When `fill = "transparent"`, no fill is painted and the canvas gray
shows through. When `fill` is a color, the rectangle is painted with that color
(alpha respected). Fill affects display only; print semantics are in the
Printing forward-reference above.

**Border.** 1px, screen-space (zoom-independent), theme neutral. Drawn for
every artboard always.

**Accent border (panel-selected).** 2px outside the default border, theme
accent color. Combined visual thickness 3px.

**Label.** `N  Name` — positional number, two-space gap, artboard name.
Rendered in screen-pixel body-text size (zoom-independent), theme foreground.
Left-aligned just above the artboard's top-left corner. Truncated with ellipsis
if longer than the artboard is wide. Labels of nearby artboards may overlap
each other; no collision avoidance. Labels are **not interactive in phase 1** —
no hover state, no click target.

**Overlap semantics.** Fills stack in list order; later artboards paint over
earlier ones. Transparent fills contribute nothing, so earlier content shows
through. Borders, labels, and marks render for every artboard regardless of
overlap.

**Per-artboard display marks** (each toggled by its Dialogue checkbox):

- `show_center_mark` — a small cross at the geometric center of the artboard,
  screen-pixel size, theme muted-foreground.
- `show_cross_hairs` — one horizontal line at the artboard's vertical center
  and one vertical line at its horizontal center, each spanning the artboard's
  bounds. Same color as the center mark.
- `show_video_safe_areas` — two nested rectangles centered on the artboard:
  action-safe at 90% of width/height, title-safe at 80%. Thin strokes, same
  color as the center mark.

`video_ruler_pixel_aspect_ratio` is stored and round-trips through the
Dialogue, but its visual effect on canvas rendering (non-square pixel
distortion) is phase-1 deferred.

**Document-global display toggles.**

- `fade_region_outside_artboard` (default on) — when on, a 50%-opacity mask of
  the theme canvas color is painted over every region not inside the union of
  artboard bounds. Elements outside render faded; the canvas background is
  unchanged underneath. When off, elements render at full opacity everywhere.
- `update_while_dragging` (default on) — when on, the Artboard Tool re-renders
  the dragged artboard, any contained elements (per the Move/Copy Artwork
  rule), and the fade region continuously during a drag. When off, only an
  outline-preview rectangle updates and the artboard snaps to its new
  geometry on mouseup. See ARTBOARD_TOOL.md §Update while dragging for the
  per-state rendering contract.

Elements' visibility modes (preview / outline / invisible) and layer lock state
are orthogonal to artboards and don't affect artboard rendering.

## Panel layout

panel:
- .row: (per artboard)
  - .col-1: ARTBOARD_NUMBER
  - .col-10: ARTBOARD_NAME
  - .col-1: ARTBOARD_OPTIONS_BUTTON
- .footer:
  - REARRANGE_BUTTON
  - MOVE_UP_BUTTON
  - MOVE_DOWN_BUTTON
  - NEW_ARTBOARD_BUTTON
  - DELETE_ARTBOARD_BUTTON

**Row elements.**

- `ARTBOARD_NUMBER` — positional 1-based index of the row in the list.
- `ARTBOARD_NAME` — the artboard's name. Every artboard has a non-empty name.
- `ARTBOARD_OPTIONS_BUTTON` — opens the Artboard Options Dialogue for this
  row's artboard.

**Footer placement.** `REARRANGE_BUTTON` sits at the bottom-left of the footer,
visually separated. The remaining buttons sit in the bottom-right cluster in
the order: `MOVE_UP_BUTTON`, `MOVE_DOWN_BUTTON`, `NEW_ARTBOARD_BUTTON`,
`DELETE_ARTBOARD_BUTTON`.

**Footer buttons.**

- `REARRANGE_BUTTON` — opens the Rearrange Dialogue. Phase-1 deferred, grayed
  with tooltip `Coming soon`. An accent dot appears on the button when the
  artboards list has changed since the Dialogue was last opened; the dot clears
  on Dialogue open. Since the Dialogue is deferred in phase 1, the dot appears
  on the first list change and remains until the Dialogue feature lands. When
  implemented, enabled only when `artboards.length ≥ 2`.
- `MOVE_UP_BUTTON` (up arrow) — moves each panel-selected artboard one position
  earlier in the list using the swap-with-neighbor-skipping-selected-neighbors
  rule (see Reordering). Preserves relative order within the selection. Single
  undo op. Enabled when panel-selection is non-empty and the topmost selected
  row is not already at position 1.
- `MOVE_DOWN_BUTTON` (down arrow) — symmetric to Move Up. Enabled when
  panel-selection is non-empty and the bottommost selected row is not already
  last.
- `NEW_ARTBOARD_BUTTON` — identical to menu `New Artboard`. Always enabled.
- `DELETE_ARTBOARD_BUTTON` (trash icon) — identical to menu `Delete Artboards`.
  No confirmation dialog; undo is the safety net. Enabled when panel-selection
  is non-empty and deletion would not leave zero artboards.

## Menu

- New Artboard
- Duplicate Artboards
- Delete Artboards
- Rename
- ----
- Delete Empty Artboards
- ----
- Convert to Artboards
- Artboard Options...
- Rearrange...
- ----
- Reset Panel

**Menu items.**

- **New Artboard** — creates a new artboard silently (no Dialogue). Inserted
  above the topmost panel-selected artboard, or at the end of the list if
  nothing is panel-selected. Default size inherits from the topmost existing
  artboard, else 612 × 792 pt (Letter). Default position: top-left offset by
  `(20, 20)` pt from the topmost panel-selected artboard's top-left, else
  `(0, 0)`. Default `fill = "transparent"`, all display toggles off. Name is
  `"Artboard N"` with the smallest unused N (see Numbering and Naming). Always
  enabled.
- **Duplicate Artboards** — deep-copies each panel-selected artboard and any
  element whose bounds are fully contained in that artboard. Copies are offset
  by `(20, 20)` pt from their sources and auto-numbered. Grayed when
  panel-selection is empty.
- **Delete Artboards** — deletes panel-selected artboards. Elements inside them
  remain in the document — artboards are boundaries, not containers. Grayed
  when panel-selection is empty or deletion would leave zero artboards (see
  Invariant). Tooltip when grayed due to the invariant:
  `At least one artboard must remain.`
- **Rename** — enters inline editing on `ARTBOARD_NAME` of the single
  panel-selected artboard. Grayed unless exactly one artboard is
  panel-selected.
- **Delete Empty Artboards** — sweeps the document-wide list; deletes every
  artboard whose bounds don't intersect any element's bounds. Hidden and locked
  elements count as non-empty. If every artboard is empty, preserves the
  artboard at position 1. Single undo op. Grayed when no deletion would occur.
- **Convert to Artboards** — acts on **element-selection**, not panel-selection.
  For each top-level element in the selection with non-zero bounds that is not
  in a locked ancestor, creates an artboard matching the element's visual
  bounding box and deletes the original element. New artboards append to the
  end of `document.artboards` in bottom-up stacking order (lowest-in-layers
  first becomes the lowest new `ARTBOARD_NUMBER`). Element-selection becomes
  empty after the op; panel-selection becomes the newly created artboards.
  Phase-1 deferred, grayed with tooltip `Coming soon`.
- **Artboard Options...** — opens the Artboard Options Dialogue for the
  topmost panel-selected artboard. Grayed when panel-selection is empty.
- **Rearrange...** — opens the Rearrange Dialogue. Phase-1 deferred, grayed
  with tooltip `Coming soon`. When implemented, enabled only when
  `artboards.length ≥ 2`.
- **Reset Panel** — resets panel UI state (column widths, scroll,
  reference-point widget preference). Does not modify document data.

## Right-click context menu

Right-click on any artboard row. Pre-menu selection: if the right-clicked row
isn't already panel-selected, replace panel-selection with just that row; if it
is already panel-selected, preserve the selection unchanged. Cmd-held
right-click does not toggle; the preservation rule still applies.

- Artboard Options...
- Rename
- Duplicate Artboards
- Delete Artboards
- ----
- Convert to Artboards   (phase-1 deferred, grayed)

Each entry's enable rule and behavior mirrors its panel-menu counterpart.

Right-click in empty panel area (below the last row) produces no menu.

## Keyboard shortcuts

When the Artboards Panel has focus:

- **Up / Down** — move focus one row, replacing panel-selection with the
  newly-focused row.
- **Shift + Up / Shift + Down** — extend range selection from the anchor.
- **Option + Up / Option + Down** — Move Up / Move Down on panel-selected
  artboards (footer parity).
- **Delete / Backspace** — Delete Artboards on panel-selected (blocked when it
  would leave zero).
- **F2** or **Enter** — enter inline rename on the single panel-selected
  artboard.
- **Escape** — during inline rename, cancel and restore the prior name.
  Outside of inline rename, Escape is a no-op.
- **Cmd + A** — select all artboards.

Hovering a row paints a subtle theme hover tint. Keyboard-focused rows show
the theme focus ring in addition to any panel-selection background.

Tab order entering the panel from outside: the first (or most-recently-focused)
row, then footer buttons in visible order (`REARRANGE_BUTTON`, `MOVE_UP_BUTTON`,
`MOVE_DOWN_BUTTON`, `NEW_ARTBOARD_BUTTON`, `DELETE_ARTBOARD_BUTTON`), then Tab
leaves the panel. Tab does not step between rows — Up/Down is the row
navigator.

## Selection semantics

Two concepts:

- **Panel-selection** — a set of 0..N artboards. Drives menu targets, drag
  reorder, delete, rename. Tracked by stable artboard `id` so it survives
  reorders.
- **Current artboard** — exactly one artboard, always. Derived:
  `current = topmost panel-selected artboard, else artboard at position 1`.
  Not stored; never null (the invariant guarantees position 1 exists).

Current is the subject of `ALIGN_TO_ARTBOARD_BUTTON` and any future
fit-to-artboard or zoom-to-artboard commands. There is no canvas indicator for
current — it's a tiebreaker for commands, not a UI state.

**Panel-selection rules** (mirror LAYERS.md):

- **Click** a row: replace panel-selection with that row (anchor becomes that
  row).
- **Shift-click**: range-select from the anchor to the clicked row.
- **Cmd-click**: toggle the clicked row in/out of the selection.
- Clicking in empty panel area (below the last row): no-op.

**Row hit targets.**

- `ARTBOARD_NUMBER` — click makes that row the sole panel-selected row (a
  shortcut for "make current this artboard").
- `ARTBOARD_NAME` — panel-select using the click/shift/cmd rules above.
  Click-and-wait enters inline rename.
- `ARTBOARD_OPTIONS_BUTTON` — opens Artboard Options for that row's artboard
  regardless of panel-selection. No selection side effects.

**Canvas → panel.** In phase 1 the Selection tool does not touch artboard
panel-selection; clicking empty canvas space deselects elements only. Artboard
interaction on canvas (click-to-activate, drag-to-move, drag-to-resize) is the
Artboard Tool's job and is deferred.

## Reordering

Ways to reorder:

- Drag panel-selected rows to a new position in the panel. A horizontal
  insertion line indicates the drop point. Single undo op.
- `MOVE_UP_BUTTON` / `MOVE_DOWN_BUTTON` in the footer.
- `Option + Up` / `Option + Down` keyboard shortcuts.

**Swap-with-neighbor rule for discontiguous selection.** For Move Up, iterate
the selected rows in top-to-bottom order; each swaps with the row above it,
skipping rows that are themselves selected or already at position 1. Move Down
is symmetric. Example: with selection `{1, 3, 5}` and Move Up, row 1 stays
(already at top), row 3 swaps with row 2, row 5 swaps with row 4. Final list
order: `1, 3, 2, 5, 4`.

Each reorder is a single undoable op. Panel-selection tracks artboards by
`id`, so it follows the moved rows.

## Artboard data model

**Per-artboard, stored:**

| Field | Type | Default | Notes |
|---|---|---|---|
| `id` | string | fresh | Stable internal identifier (8-char base36). Unique within the document. Never shown to users. |
| `name` | string | `Artboard N` | Non-empty. Not required unique. |
| `x` | number (pt) | 0 | Document X of the top-left corner. |
| `y` | number (pt) | 0 | Document Y of the top-left corner. Y increases downward. |
| `width` | number (pt) | 612 | Positive. Min 1. |
| `height` | number (pt) | 792 | Positive. Min 1. |
| `fill` | `"transparent"` \| Color | `"transparent"` | Free color; not swatch-bound. |
| `show_center_mark` | bool | false | |
| `show_cross_hairs` | bool | false | |
| `show_video_safe_areas` | bool | false | |
| `video_ruler_pixel_aspect_ratio` | number | 1.0 | Stored regardless of `show_video_safe_areas`. Visual effect phase-1 deferred. |

**Per-artboard, derived (not stored):**

- `number` — 1-based position in the artboards list.
- `orientation` — `portrait` when `height ≥ width`, `landscape` when
  `width > height`.

**Per-document, stored (the Dialogue's Global section):**

- `fade_region_outside_artboard` — bool, default true.
- `update_while_dragging` — bool, default true. Phase-1 no-op.

**Per-panel, UI-only (not in the document):**

- `reference_point` — panel preference for which of the nine anchor points
  `X`/`Y` refer to in the Dialogue. Defaults to center. Persists across
  Dialogue opens.

**YAML sketch (illustrative):**

document:
  artboard_options:
    fade_region_outside_artboard: true
    update_while_dragging: true
  artboards:
    - id: abc12345
      name: Artboard 1
      x: 0
      y: 0
      width: 612
      height: 792
      fill: transparent
      show_center_mark: false
      show_cross_hairs: false
      show_video_safe_areas: false
      video_ruler_pixel_aspect_ratio: 1.0
  elements:
    - ...

## Coordinates and units

Artboard `x` and `y` are stored as the document-coordinate position of the
artboard's **top-left corner**, with Y increasing downward. The Artboard
Options Dialogue's reference-point widget (see Dialogue) changes which of the
nine anchor points `X` and `Y` represent when displayed or entered in that
Dialogue, but the stored fields always represent top-left.

The default artboard at `(x: 0, y: 0, w: 612, h: 792)` therefore shows in the
Dialogue as `X: 306, Y: 396` when the reference-point widget is set to center.

Document coordinates are in points (`pt`) in phase 1. Multi-unit input (in,
mm, cm, px) is out of scope here and would come from a document-level unit
preference, not from the artboard schema itself.

## Numbering and naming

**Numbering (positional, derived).** `ARTBOARD_NUMBER` is always `1..N` with
no gaps — it's the 1-based list position, not a stored identifier. Delete,
reorder, and undo all renumber automatically. The visible column stays dense
across all operations.

**Stable id.** Each artboard carries a stored `id` (8-char base36).
Panel-selection state, undo entries, and any future cross-feature references
key on `id` — never on `number` — so reorder and delete don't invalidate
persisted state. `id` values are hidden from the user.

**Default name on create.** Pick the smallest positive integer `N` such that
no existing artboard's name matches the regex `^Artboard \d+$` with that `N`.
Assign `"Artboard N"`. Freeing a name by renaming releases its number for
reuse.

**Default name on duplicate.** Each duplicate gets a fresh `"Artboard N"` name
by the same rule — the source's original name is not preserved or suffixed.

**Default-pattern detection is case-sensitive** with exactly one space between
`Artboard` and the digits. Strings like `"Artboard  3"` (two spaces) or
`"artboard 3"` are treated as custom names and don't block `"Artboard 3"`
from being picked.

**Name and number are independent.** An artboard at position 3 may be named
`"Cover"` or `"Artboard 7"`; the panel shows `3  Cover` or `3  Artboard 7`
respectively. Divergence is intentional — the number column is ordinal, the
name column is a label — and is not flagged in the UI.

## Rename

Triggers for inline rename: click-and-wait on `ARTBOARD_NAME`, F2, Enter, or
the menu `Rename` entry. All four enter the same mode: an inline text field
replaces the cell with the pre-existing name pre-selected. Enter or focus-loss
commits; Escape cancels.

Commit rules:

1. Trim leading and trailing whitespace.
2. If the trimmed result is empty, revert to the prior name (silent).
3. If >256 characters after trim, truncate to 256.
4. Duplicate names across artboards are allowed; no uniqueness check.

The same rules apply to `NAME_INPUT` in the Artboard Options Dialogue on
commit.

## At-least-one-artboard invariant

At every observable state, `document.artboards.length ≥ 1`.

**Enforcement.**

1. `Delete Artboards` (menu, footer, Delete/Backspace) is grayed when
   panel-selection spans all existing artboards; tooltip
   `At least one artboard must remain.`
2. `Delete Empty Artboards` preserves the artboard at position 1 when every
   artboard is empty.
3. `DELETE_BUTTON` in the Artboard Options Dialogue is grayed when only one
   artboard exists.
4. File load: if the loaded document has `artboards: []` or the key is missing,
   the loader inserts a default artboard (Letter, origin, fresh id,
   `"Artboard 1"`, transparent fill, all display toggles off) and logs
   `Document had no artboards; inserted default.`
5. Normal undo chains cannot drive the count below 1 because (1) blocks the
   only operation that could.

## Artboard Options Dialogue

Modal dialog for a single artboard. Batched commit: edits don't apply until
OK; Cancel discards; a single undo entry records the OK.

**Layout.**

dialog:
- .row:
  - .col-3: "Name:"
  - .col-9: NAME_INPUT
- .row:
  - .col-3: "Preset:"
  - .col-9: PRESET_DROPDOWN
- .row:
  - .col-3: "Width:"
  - .col-3: WIDTH_INPUT
  - .col-1: CHAIN_LINK_BUTTON
  - .col-1: REFERENCE_POINT_WIDGET
  - .col-1: "X:"
  - .col-3: X_INPUT
- .row:
  - .col-3: "Height:"
  - .col-3: HEIGHT_INPUT
  - .col-2:
  - .col-1: "Y:"
  - .col-3: Y_INPUT
- .row:
  - .col-3: "Orientation:"
  - .col-3: ORIENTATION_BUTTON
  - .col-2:
  - .col-1: "Fill:"
  - .col-2: FILL_DROPDOWN
  - .col-1: FILL_SWATCH
- .section "Display":
  - .row: SHOW_CENTER_MARK_CHECKBOX
  - .row: SHOW_CROSS_HAIRS_CHECKBOX
  - .row: SHOW_VIDEO_SAFE_AREAS_CHECKBOX
  - .row:
    - .col-6: "Video Ruler Pixel Aspect Ratio:"
    - .col-6: VIDEO_RULER_PIXEL_ASPECT_RATIO_INPUT
- .section "Global":
  - .row: FADE_REGION_CHECKBOX
  - .row: UPDATE_WHILE_DRAGGING_CHECKBOX   (indented under the above)
- .section info:
  - .row: ARTBOARDS_COUNT_INFO
- .footer:
  - DELETE_BUTTON  CANCEL_BUTTON  OK_BUTTON

**Fields.**

- `NAME_INPUT` — text; pre-selected on open; bound to `name`. Trim-on-commit,
  empty reverts, 256-char truncation.
- `PRESET_DROPDOWN` — lists named (w, h) presets. Selecting sets `WIDTH_INPUT`
  and `HEIGHT_INPUT`; does not touch X/Y or name. Shows `Custom`
  (non-selectable) when the current W/H doesn't match any preset. Default
  preset list:
  - Letter (612 × 792)
  - Legal (612 × 1008)
  - Tabloid (792 × 1224)
  - A4 (595.28 × 841.89)
  - A3 (841.89 × 1190.55)
  - 1080p Full HD (1920 × 1080)
  - 720p HD (1280 × 720)
  - iPhone (1179 × 2556)
  - iPad Pro 11 (1668 × 2388)
  - Square (1000 × 1000)

  A workspace YAML may override this list.
- `WIDTH_INPUT` / `HEIGHT_INPUT` — number inputs in pt. Min 1. When
  `CHAIN_LINK_BUTTON` is engaged, edits scale the other proportionally against
  the ratio captured at engage time. Resize anchors at the currently selected
  `REFERENCE_POINT_WIDGET` anchor.
- `CHAIN_LINK_BUTTON` — dialog-session toggle. Default off on open, not
  persisted.
- `REFERENCE_POINT_WIDGET` — 3×3 grid; exactly one anchor active. Affects X/Y
  display and the resize/orientation anchor. Underlying storage is always
  top-left. Default anchor persists as a panel preference; not stored in the
  document.
- `X_INPUT` / `Y_INPUT` — number inputs in pt. Document coordinates of the
  reference-point anchor. On OK the Dialogue computes top-left from (anchor,
  w, h) and writes `x`, `y`.
- `ORIENTATION_BUTTON` — pair of icon buttons (portrait, landscape); exactly
  one active. Derived from the current width/height. Clicking the inactive
  orientation swaps `WIDTH_INPUT` and `HEIGHT_INPUT` around the current
  reference-point anchor.
- `FILL_DROPDOWN` / `FILL_SWATCH` — dropdown options: `Transparent`, `White`,
  `Black`, `Custom…`. `Custom…` opens the free-color picker. `FILL_SWATCH` is
  a visual indicator; clicking it opens the same picker as `Custom…`. Bound to
  `fill`.
- `SHOW_CENTER_MARK_CHECKBOX` / `SHOW_CROSS_HAIRS_CHECKBOX` /
  `SHOW_VIDEO_SAFE_AREAS_CHECKBOX` — 1:1 bindings to their fields.
- `VIDEO_RULER_PIXEL_ASPECT_RATIO_INPUT` — number, default 1.0. Always editable
  regardless of the Video Safe Areas checkbox. Phase-1 has no visual effect.
- `FADE_REGION_CHECKBOX` — bound to document `fade_region_outside_artboard`.
  Affects every artboard in the document.
- `UPDATE_WHILE_DRAGGING_CHECKBOX` — bound to document `update_while_dragging`.
  Indented under `FADE_REGION_CHECKBOX`; disabled when the parent is off.
  Phase-1 no-op.
- `ARTBOARDS_COUNT_INFO` — read-only text `Artboards: N`.
- `DELETE_BUTTON` — deletes the artboard this Dialogue was opened for; closes.
  Grayed when `N == 1` (invariant).
- `CANCEL_BUTTON` — discards; closes.
- `OK_BUTTON` — commits; closes. Default button (Enter activates).

**Cross-field rules.**

- `PRESET_DROPDOWN` writes W, H only.
- `CHAIN_LINK_BUTTON` constrains W↔H edits this Dialogue session.
- `REFERENCE_POINT_WIDGET` affects X/Y display and the anchor for W/H and
  orientation edits.
- `ORIENTATION_BUTTON` swaps W↔H around the anchor.
- `FADE_REGION_CHECKBOX` enables/disables `UPDATE_WHILE_DRAGGING_CHECKBOX`.

## Rearrange Dialogue (deferred)

Phase-2 Dialogue for batch-repositioning artboards into a grid. Behavior
specified here so the unfreeze is mechanical. Menu `Rearrange…` and footer
`REARRANGE_BUTTON` remain grayed with `Coming soon` tooltip until this lands.

**Layout.**

dialog: "Rearrange All Artboards"
- .row:
  - .col-4: "Layout:"
  - .col-8: LAYOUT_MODE_BUTTONS   (four icon-buttons, exactly one active)
- .row:
  - .col-4: "Columns:"
  - .col-4: COLUMNS_INPUT
  - .col-4:
- .row:
  - .col-4: "Direction:"
  - .col-8: DIRECTION_BUTTON       (LTR | RTL toggle)
- .row:
  - .col-4: "Spacing:"
  - .col-4: SPACING_INPUT
  - .col-4:
- .row:
  - .col-12: MOVE_ARTWORK_CHECKBOX  "Move Artwork with Artboard"
- .footer:
  - CANCEL_BUTTON  OK_BUTTON

**Fields.**

- `LAYOUT_MODE_BUTTONS` — four mutually exclusive modes:
  - **Grid by Row** — grid filled row-by-row (default).
  - **Grid by Column** — grid filled column-by-column.
  - **Arrange by Row** — one horizontal row; `COLUMNS_INPUT` ignored.
  - **Arrange by Column** — one vertical column; `COLUMNS_INPUT` ignored.
- `COLUMNS_INPUT` — positive integer. Default `ceil(sqrt(N))`. Disabled for
  the two `Arrange by …` modes.
- `DIRECTION_BUTTON` — LTR | RTL toggle, default LTR. LTR fills left-to-right
  then top-to-bottom (for row modes). RTL mirrors horizontally.
- `SPACING_INPUT` — single number in pt; applied both horizontally and
  vertically. Default 20.
- `MOVE_ARTWORK_CHECKBOX` — default on. When on, elements follow their
  containing artboard; when off, only artboards move.

**Source sequence.** The current `document.artboards` list order is the
grid-fill sequence. Position 1 goes top-left (or top-right under RTL).

**Anchor.** The top-left of the position-1 artboard stays fixed. The grid
originates from there.

**Cell size.** Per column (or row, for Grid by Column), the cell width (or
height) is the maximum among the artboards assigned to that column (or row).
Each artboard is placed at the cell's top-left. This handles non-uniform
artboard sizes without overlap.

**Move-artwork semantics.** When `MOVE_ARTWORK_CHECKBOX` is on, for each leaf
element whose pre-op bounds are fully contained in exactly one artboard's
pre-op bounds, translate by that artboard's displacement. Elements contained
in zero or >1 artboards don't move. Groups/layers translate as a whole if the
group's combined bounds are fully contained in one artboard; otherwise the
rule recurses to leaves. Elements in locked layers still translate under Move
Artwork (lock prevents editing, not transform).

When `MOVE_ARTWORK_CHECKBOX` is off, only artboards move; all elements stay.

**Commit.** Single undoable op. All artboards reposition atomically; elements
move if the box is checked. Cancel discards. Opening the Dialogue clears the
blue-dot flag on `REARRANGE_BUTTON`.

**Enablement.** Menu `Rearrange…` and footer `REARRANGE_BUTTON` enabled only
when `N ≥ 2`. Phase-1 grayed regardless.

**Out of scope** (even for phase 2): non-uniform spacing (two inputs), grid
alignment modes, Rearrange-based list reordering.

## Phase-1 deferrals summary

- **Convert to Artboards** — menu and context-menu entry grayed with
  `Coming soon` tooltip.
- **Rearrange Dialogue** — menu entry and footer `REARRANGE_BUTTON` grayed
  with `Coming soon` tooltip. The blue-dot flag begins firing on first list
  change; since the Dialogue never opens in phase 1, the dot remains lit.
- **`video_ruler_pixel_aspect_ratio` visual effect** — value persists and
  round-trips; no non-square-pixel distortion in canvas rendering.
- **Printing** — semantics pinned in the Printing forward-reference
  paragraph; no implementation.

Please read and understand these requirements. Analyze them for inconsistencies
and completeness. Make suggestions for improvements, ranking them in priority
from high to low, and giving each a number. What are the benefits? What are the
downsides? Be ready for a deep dive into any of the suggestions.
