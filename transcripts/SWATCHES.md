# Swatches

The Swatches panel manages named color swatches organised into
libraries. This document is the requirements description from which
`workspace/panels/swatches.yaml` is generated.

## Overview

The Swatches panel is one tab in a tabbed panel group (alongside
Color); the tabbed-group container is specified elsewhere. This
document covers only the Swatches tab.

Where the Color panel edits the active fill or stroke color by
channel, the Swatches panel curates a palette: named, persistent color
entries grouped into libraries. Libraries are JSON files under
`workspace/swatches/*.json`; the default library is "Web Colors" (216
web-safe colors). Any number of libraries can be open at once — each
renders as a collapsible disclosure section in the panel body.

The panel shares the fill/stroke model with the Color panel: clicking
a swatch sets the currently-active color (fill or stroke, per
`state.fill_on_top`) and commits it to the recent-colors list.
`panel.recent_colors` on Swatches is the same per-document list as on
Color.

When no document is open, the panel is fully disabled.

## Controls

- `FILL_STROKE_WIDGET` — the shared fill/stroke widget template
  (overlapping swatches + swap + reset buttons). Same visual
  behaviour as the toolbar widget, except single-click only (no
  double-click to open the modal picker from within the panel).

- `RECENT_COLORS_LABEL` — a small dim text label reading "Recent
  Colors". Non-interactive.

- `RECENT_SWATCH_0` through `RECENT_SWATCH_9` — ten 16 px
  `color_swatch` slots holding the most recently committed colors,
  newest on the left. The list is per-document and shared with the
  Color panel (`panel.recent_colors`). Single-click a non-empty slot
  to set the active color. Double-click opens the Swatch Options
  dialog in create mode (seeded from the clicked color). Empty slots
  render as hollow squares with a solid border and are
  non-interactive.

- `SWATCH_TILES_AREA` — the scrollable body of the panel containing
  one `LIBRARY_SECTION` per entry in `panel.open_libraries`. Uses a
  `foreach` over `panel.open_libraries` to render libraries in order.

- `LIBRARY_SECTION` — a `disclosure` for one library:

  - A disclosure triangle (click to expand/collapse).
  - The library's name label, read from
    `data.swatch_libraries[lib.id].name`.
  - When expanded: a wrapping container of
    `LIBRARY_SWATCH_TILE`s iterating
    `data.swatch_libraries[lib.id].swatches`.

  Per-library collapsed state lives in
  `panel.open_libraries[i].collapsed`.

- `LIBRARY_SWATCH_TILE` — a single `color_swatch` inside a library
  section. Tile size is controlled by `panel.thumbnail_size`:

  | Size    | Pixels  |
  |---------|---------|
  | small   | 16 × 16 |
  | medium  | 32 × 32 |
  | large   | 64 × 64 |

  Tiles wrap left-to-right, top-to-bottom inside their
  `LIBRARY_SECTION`.

## Layout

Strings in quotes are literal labels. Bare identifiers are widget IDs.
`LIBRARY_SECTION` and `LIBRARY_SWATCH_TILE` are templates that repeat:
one section per open library, one tile per swatch in that library.

```yaml
panel:
- .row: FILL_STROKE_WIDGET
- .row: "Recent Colors"                           # RECENT_COLORS_LABEL
- .row:                                           # recent-colors strip
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
- SWATCH_TILES_AREA:
  # foreach library in panel.open_libraries
  - LIBRARY_SECTION (triangle + name):
    # foreach swatch in library.swatches
    - LIBRARY_SWATCH_TILE
    - LIBRARY_SWATCH_TILE
    - …
```

## Panel menu

- **New Swatch** — append a new swatch to the selected library,
  initialised from the current active color (fill or stroke, per
  `state.fill_on_top`). Opens the Swatch Options dialog in create
  mode; the swatch lands at the end of the library.
- **Duplicate Swatch** (enabled iff at least one swatch is selected)
  — create a copy of each selected swatch immediately after its
  original, with `" copy"` appended to the name. The new copies
  become the selection.
- **Delete Swatch** (enabled iff at least one swatch is selected) —
  permanently remove the selected swatches from the selected library.
  No undo. The selection is cleared afterwards.
- ----
- **Select All Unused** — replace the current selection with every
  swatch in the panel whose color does not appear anywhere in the
  document as a fill or stroke. Helpful for finding swatches that are
  safe to delete.
- **Add Used Colors** — scan every object in the document, collect
  the set of unique fill / stroke colors, and append a new swatch for
  each color that is not already in the selected library. Names
  default to `R=N G=N B=N`. Colors are compared by hex value.
- ----
- **Sort by Name** — permanently reorder the selected library's
  swatches alphabetically (case-sensitive, lexicographic). Modifies
  the library data in place; saved out with the next Save Swatch
  Library.
- ----
- **Small Thumbnail View** (checkmark if active) — sets
  `panel.thumbnail_size = small` (16 px tiles).
- **Medium Thumbnail View** (checkmark if active) — sets
  `panel.thumbnail_size = medium` (32 px tiles).
- **Large Thumbnail View** (checkmark if active) — sets
  `panel.thumbnail_size = large` (64 px tiles).
  The three size items form a radio group; exactly one is always
  checked.
- ----
- **Swatch Options…** (enabled iff at least one swatch is selected)
  — open the Swatch Options dialog in edit mode for the first
  selected swatch (name, color type, color mode, components, hex).
  OK updates the swatch in place.
- ----
- **Open Swatch Library** — dynamic submenu listing every library
  discovered under `workspace/swatches/*.json`. Selecting a library
  adds it to `panel.open_libraries`, creating a new
  `LIBRARY_SECTION` in the panel body. Already-open libraries
  display a checkmark.
- **Save Swatch Library** — open the Save Swatch Library dialog,
  which prompts for a library name. The selected library's swatches
  are written to `workspace/swatches/<name>.json`. The saved file
  contains the library name, description, and the full swatch array.

## Selection model

Swatch selection is per-library and stored as a list of indices:

- `panel.selected_library` — the library id that the selection lives
  in. Changing libraries clears the selection.
- `panel.selected_swatches` — a list of indices into
  `data.swatch_libraries[selected_library].swatches`.

Click modifiers (the generic `select` effect with `mode: auto`):

- **Plain click** — replace the selection with the clicked swatch.
- **Shift + click** — extend a contiguous range from the anchor
  swatch to the clicked swatch.
- **Cmd / Ctrl + click** — toggle the clicked swatch in the
  selection.

Selection feedback is the shared `jas-selected` CSS class (a 2 px
accent outline) applied to each selected tile via the
`selected_in: panel.selected_swatches` binding.

On single-click (any modifier), the active fill or stroke color is
also set to the clicked swatch's color — selection and color-commit
are a single user action.

On **double-click** of a swatch, the Swatch Options dialog opens in
edit mode, passing the swatch's name, color, color_mode, library id,
and index as dialog parameters.

Multi-swatch selection enables the menu items **Duplicate Swatch**,
**Delete Swatch**, and **Swatch Options…** (the last operates on the
first selected swatch).

## Swatch libraries

Libraries are JSON files under `workspace/swatches/`. Each file
contains:

```json
{
  "name": "Web Colors",
  "description": "216 web-safe colors",
  "swatches": [
    {
      "name": "Red",
      "color": "#ff0000",
      "color_mode": "rgb",
      "color_type": "process",
      "global": false
    },
    …
  ]
}
```

All discovered libraries appear in the **Open Swatch Library**
submenu. The "Web Colors" library is open by default (see
`panel.open_libraries` default). Libraries that are not open are not
rendered; opening a library appends an entry to `panel.open_libraries`
with `collapsed: false`.

Per-swatch fields:

- **name** — display string. Used in the Swatch Options dialog, in
  **Sort by Name**, and in exported JSON.
- **color** — hex string (`#rrggbb`). The canonical value; all color
  modes are converted to RGB when saved.
- **color_mode** — one of `grayscale`, `rgb`, `hsb`, `cmyk`,
  `web_safe_rgb`. Controls which slider set the Swatch Options
  dialog defaults to. Does not affect storage.
- **color_type** — currently always `"process"`. Reserved for future
  spot-color support.
- **global** — boolean; reserved for a future feature where updating
  a global swatch propagates to every document element using it. Not
  honoured yet.

## Recent colors

`panel.recent_colors` is the same per-document list used by the Color
panel — ten entries, newest first, deduplicated. The Swatches panel
contributes to this list indirectly: clicking a library swatch commits
via `set_active_color`, which pushes the color to recent-colors.
Double-clicking a recent-color slot opens Swatch Options in create
mode with the color pre-filled.

See the Color panel document (`transcripts/COLOR.md`) for the full
recent-colors commit rules.

## Swatch Options dialog

The Swatch Options dialog is a separate component
(`workspace/dialogs/swatch_options.yaml`) opened by:

- **New Swatch** menu item (create mode).
- Double-clicking a library swatch (edit mode).
- Double-clicking a recent-color slot (create mode).
- **Swatch Options…** menu item (edit mode, first-selected swatch).

The dialog surfaces the swatch's name, color type (always "Process
Color" today), color mode, the same slider set as the Color panel,
and the hex value. Detailed behaviour for the dialog belongs in its
own document; this panel only describes the entry points.

## Panel state

Panel-local state (not persisted with the document):

- `panel.thumbnail_size` — `small` / `medium` / `large`. Default
  `small`.
- `panel.selected_library` — id of the library owning the current
  selection. Default `"web_colors"`.
- `panel.selected_swatches` — list of selected swatch indices within
  `selected_library`.
- `panel.open_libraries` — list of `{ id, collapsed }` objects. The
  default has a single entry `{ id: "web_colors", collapsed: false }`.

Per-document state (persisted with the document):

- `panel.recent_colors` — same list as the Color panel; up to 10
  entries, newest first.

External data (read by the panel, not part of panel state):

- `data.swatch_libraries` — a map of library id → library object
  (`{ name, description, swatches }`). Populated from
  `workspace/swatches/*.json` at startup.

Shared state (read by this panel and others):

- `state.fill_on_top` — which attribute (fill or stroke) a swatch
  click writes to.
- `state.fill_color`, `state.stroke_color` — the active colors the
  panel writes to on swatch click.

## Library data shape

Library files are authored by hand or produced by **Save Swatch
Library**. The file shape is:

```json
{
  "name": "<library name>",
  "description": "<optional prose>",
  "swatches": [ { "name": ..., "color": ..., "color_mode": ...,
                  "color_type": "process", "global": false }, … ]
}
```

The library id used in `panel.open_libraries` is the filename stem
(the file's basename without the `.json` extension), so
`web_colors.json` has id `"web_colors"`.

## Keyboard shortcuts

Shortcuts for Swatches actions (New Swatch, Duplicate, Delete, and
the thumbnail-size items) are defined in `workspace/shortcuts.yaml`
rather than here.

## Panel-to-selection wiring status

Fully wired in Flask (the generic app): the Swatches panel is on the
`swatches-panel` branch with library loading, recent-colors
persistence, multi-selection, and all menu actions implemented end to
end.

Propagation to the native apps is pending:

- **Rust** (`jas_dioxus`): scaffolding present; library-loading and
  swatch-click → active-color wiring pending.
- **Swift** (`JasSwift`): scaffolding present; full wiring pending.
- **OCaml** (`jas_ocaml`): scaffolding present; full wiring pending.
- **Python** (`jas`): scaffolding present; full wiring pending.

Open follow-ups:

- Global-swatch propagation (`swatch.global == true`) — update every
  document element using that swatch when the swatch color changes.
  Data model carries the flag already; no behaviour yet.
- Undo for **Delete Swatch**. Currently permanent.
- Spot-color support — `color_type` currently always `"process"`;
  spot-color semantics are reserved.
