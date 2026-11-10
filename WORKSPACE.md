# Workspace System

The workspace system manages the application window layout: pane positions,
dock panels, snap constraints, and persistence. It is implemented identically
across four projects — Rust (jas\_dioxus), Swift (JasSwift), OCaml
(jas\_ocaml), and Python (jas) — with language-appropriate idioms.

## Architecture Overview

The workspace has two layers:

1. **Pane layout** — three top-level panes (Toolbar, Canvas, Dock) positioned
   in the window with snap constraints that keep edges aligned.
2. **Dock layout** — anchored and floating docks, each containing a vertical
   stack of panel groups with tabbed panels.

A `WorkspaceLayout` combines both layers into a single persistable unit.

```
+----------+-----------------------------+------------+
|          |                             |            |
| Toolbar  |          Canvas             |    Dock    |
|  (fixed  |          (flex)             | (resizable)|
|   72px)  |                             |            |
|          |                             | [Layers  ] |
|  tools   |                             | [Color   ] |
|  icons   |                             | [Stroke  ] |
|          |                             | [Props   ] |
+----------+-----------------------------+------------+
     ^               ^                        ^
     |               |                        |
   Pane 0          Pane 1                   Pane 2
```

## Core Types

### Pane Layer

| Type | Description |
|------|-------------|
| `PaneId` | Stable numeric identifier for a pane. |
| `PaneKind` | `Toolbar`, `Canvas`, or `Dock`. |
| `PaneConfig` | Per-pane behavior: label, min width/height, fixed width, collapsed width, double-click action. |
| `Pane` | A positioned rectangle: id, kind, config, x, y, width, height. |
| `EdgeSide` | `Left`, `Right`, `Top`, `Bottom`. |
| `SnapTarget` | What an edge snaps to — `Window(edge)` or `Pane(id, edge)`. |
| `SnapConstraint` | A binding: pane + edge + target. Maintained during resize and drag. |
| `PaneLayout` | The three panes, their snap constraints, z-order, hidden state, and viewport dimensions. |

**Default pane configs:**

| Pane | Width | Behavior |
|------|-------|----------|
| Toolbar | 72px fixed | Not collapsible. |
| Canvas | Flex (fills remaining space) | Double-click to maximize. |
| Dock | 240px default, 150px min | Collapsible to 36px. Double-click to redock. |

### Dock Layer

| Type | Description |
|------|-------------|
| `DockId` | Stable numeric identifier for a dock. |
| `DockEdge` | `Left`, `Right`, or `Bottom` — which window edge an anchored dock attaches to. |
| `PanelKind` | `Layers`, `Color`, `Stroke`, `Properties`. |
| `PanelGroup` | A stack of tabbed panels with an active index, collapsed state, and optional fixed height. |
| `Dock` | A vertical stack of panel groups: id, groups, collapsed, auto\_hide, width, min\_width. |
| `FloatingDock` | A `Dock` plus x/y screen position. |
| `GroupAddr` | Address of a group: dock\_id + group index. |
| `PanelAddr` | Address of a panel: group address + panel index within the group. |

### WorkspaceLayout

The top-level layout structure combining both layers:

| Field | Type | Description |
|-------|------|-------------|
| `version` | int | Format version (currently 3). Mismatched versions are rejected on load. |
| `name` | string | Layout name. Always `"Workspace"` for the working copy. |
| `anchored` | list of (DockEdge, Dock) | Docks snapped to window edges. |
| `floating` | list of FloatingDock | Free-floating docks with screen positions. |
| `hidden_panels` | list of PanelKind | Panels not currently visible. |
| `z_order` | list of DockId | Z-order for floating docks, back to front. |
| `focused_panel` | optional PanelAddr | Currently focused panel. |
| `pane_layout` | optional PaneLayout | Top-level pane positions. `None` for legacy layouts. |
| `next_id` | int | Counter for generating new dock IDs. |

Generation tracking fields (not serialized):

| Field | Description |
|-------|-------------|
| `generation` | Incremented on every mutation via `bump()`. |
| `saved_generation` | Set to `generation` after each save via `mark_saved()`. |
| `needs_save()` | True when `generation != saved_generation`. |

## Working-Copy Save Pattern

The workspace uses a **working-copy pattern** inspired by version control:

- **"Workspace"** is the system working copy. It is always the live layout
  and is auto-saved on every change. It does not appear in the workspace menu.
- **Named layouts** (e.g., "Default", "Wide", "Minimal") are immutable
  snapshots. They are created via "Save As..." and loaded via the menu.
- **`active_layout`** in AppConfig tracks which named layout was last
  loaded or saved. It is purely informational — saves always go to
  "Workspace".

### Operations

**Startup:**
1. Load "Workspace" from storage.
2. If not found, migrate from the current `active_layout`.
3. If neither found, use factory defaults.
4. Persist to "Workspace" key (ensures it exists for next startup).

**Auto-save (on every mutation):**
1. Call `bump()` to increment generation.
2. Serialize the layout to JSON.
3. Write to the "Workspace" storage key.
4. Call `mark_saved()`.

**Load a named layout:**
1. Save the current working copy to "Workspace".
2. Load the named layout from storage.
3. Set its name to "Workspace" (it becomes the new working copy).
4. Set `active_layout` to the named layout.
5. Persist to "Workspace" key.

**Save As:**
1. Temporarily rename the working copy to the target name.
2. Serialize and write to the named layout's storage key.
3. Restore the name to "Workspace".
4. Register the name in `saved_layouts` and set `active_layout`.

**Revert to Saved:**
1. Reload the layout named by `active_layout` from storage.
2. Set its name to "Workspace".
3. Persist to "Workspace" key.
4. Only enabled when `active_layout` is not "Workspace".

**Reset to Default:**
1. Create a fresh factory-default layout named "Workspace".
2. Set `active_layout` to "Workspace" (clears the selection).
3. Persist both AppConfig and the layout.

### Storage

| Platform | Mechanism | Layout key | Config key |
|----------|-----------|------------|------------|
| Rust (WASM) | `localStorage` | `jas_layout:{name}` | `jas_app_config` |
| Swift | `UserDefaults` | `jas_layout:{name}` | `jas_app_config` |
| OCaml | `~/.config/jas/{name}.json` | File per layout | `app_config.json` |
| Python | `~/.config/jas/{name}.json` | File per layout | `app_config.json` |

### AppConfig

Stored separately from layouts:

| Field | Description |
|-------|-------------|
| `active_layout` | Name of the last loaded/saved layout. "Workspace" when no named layout is selected. |
| `saved_layouts` | Ordered list of all named layout names for display in the menu. |

## Workspace Menu

The Workspace submenu under the Window menu:

1. **Named layouts** — listed with a checkmark on the active one. Clicking
   loads that layout (see "Load a named layout" above). "Workspace" is
   filtered from this list.
2. **Save As...** — opens a dialog pre-filled with the active layout name.
   Validates: rejects "Workspace" (reserved), confirms before overwriting
   existing names.
3. **Reset to Default** — returns to factory defaults.
4. **Revert to Saved** — reloads from the active layout's snapshot. Disabled
   when no named layout is selected.

## Snap System

Panes stay aligned through snap constraints. Each constraint binds one edge
of a pane to either a window edge or another pane's edge:

```
SnapConstraint {
    pane: PaneId,           // Which pane
    edge: EdgeSide,         // Which of its edges (Left/Right/Top/Bottom)
    target: SnapTarget,     // Window(edge) or Pane(id, edge)
}
```

**Default snap configuration (tiled):**

```
Toolbar.Left   → Window.Left
Toolbar.Top    → Window.Top
Toolbar.Bottom → Window.Bottom
Toolbar.Right  → Canvas.Left

Canvas.Top     → Window.Top
Canvas.Bottom  → Window.Bottom
Canvas.Right   → Dock.Left

Dock.Right     → Window.Right
Dock.Top       → Window.Top
Dock.Bottom    → Window.Bottom
```

When a pane is resized or the window is resized, snap constraints propagate
position changes to maintain alignment. Panes can be undocked (losing snaps)
and re-snapped by dragging near an edge.

## Anchored Docks by Edge

`anchored` holds at most one dock per `DockEdge`: `Right`, `Left` or
`Bottom`. There is no `Top` dock. This section states where each one is
drawn. Every app draws every non-empty anchored dock. An app that draws only
the `Right` dock loses the panels of a dock snapped to the left or bottom
edge: they leave the floating layer and appear nowhere.

### Snapping onto an edge

A floating dock dropped within `SNAP_DISTANCE` of a window edge snaps to that
edge (`snap_to_edge`). The edge is chosen in this order: left
(`x <= SNAP_DISTANCE`), then right (`x >= viewport_w - SNAP_DISTANCE`), then
bottom (`y >= viewport_h - SNAP_DISTANCE`). So a drop in the bottom-left
corner snaps left. If the edge has no dock yet, the floating dock becomes its
anchored dock, keeping its id and width. If the edge already holds a dock, the
floating dock's groups are appended after that dock's groups, in order, and
the floating dock is removed. The existing dock keeps its id, width and
collapsed state. `redock` is `snap_to_edge` onto the `Right` edge.
(Conformance: `panel_ops.json` `snap_to_edge_left`; engine arms
`snap_to_left_edge`, `snap_creates_anchored_dock` and
`a_detach_dropped_near_an_edge_snaps_there`.)

### Where each edge dock is drawn

The `Right` dock is the `Dock` pane of the pane layout and is drawn in that
pane's rectangle, as before. The pane layout has no pane for the other two
edges. They are cut from the **canvas pane's rectangle**, so no snap
constraint, toolbar or Right-dock position changes:

1. **Thickness.** A dock's `width` is its extent across its edge: the column
   width of a `Left` dock and the row height of a `Bottom` dock. It is clamped
   to the dock's `min_width`..`MAX_DOCK_WIDTH`, as `set_dock_width` clamps it.
   A collapsed edge dock is 36px thick.
2. **Left column.** It runs down the canvas pane's left side, at the canvas
   pane's full height, with thickness *t_L*.
3. **Bottom row.** It runs along the canvas pane's bottom, with thickness
   *t_B*. It starts at the left column's right side, or at the canvas pane's
   left side when there is no left column, and ends at the canvas pane's right
   side. **The bottom-left corner belongs to the left column.**
4. **The canvas** is drawn in what remains: the canvas pane's rectangle less
   the left column and the bottom row. The document view's origin and visible
   area are measured in that remaining rectangle.
5. **An empty or missing edge takes no space.** An edge with no anchored dock,
   or with a dock that has no groups, is not drawn, and the canvas keeps that
   strip.
6. **Group order.** A `Left` dock stacks its groups top to bottom, as the
   `Right` dock does. A `Bottom` dock lays its groups out left to right in
   equal shares of the row. A group's `height` does not apply in a row.
7. **Drawing order.** Edge docks are drawn above the canvas and below every
   floating dock.
8. **Canvas maximized.** The canvas takes the whole viewport, and the edge
   docks are drawn over it at the viewport's left and bottom edges by the same
   rules, as the `Right` dock is drawn over a maximized canvas.

Worked example: viewport 1200×800, the default panes (toolbar 72px, Right dock
240px, so the canvas pane is x 72..960, y 0..800), a `Left` dock of width 200
and a `Bottom` dock of width 180:

| region | x | y | w | h |
|---|---|---|---|---|
| left column | 72 | 0 | 200 | 800 |
| bottom row | 272 | 620 | 688 | 180 |
| canvas | 272 | 0 | 688 | 620 |

If the canvas pane is too small to hold the edge docks and `MIN_CANVAS_WIDTH`,
the edge docks are drawn at their stated thickness anyway, and the canvas may
be narrower than `MIN_CANVAS_WIDTH`. This section does not add a reflow rule.
**Known difference:** a collapsed `Right` dock is drawn 36px wide inside its
unchanged pane, so the canvas does not grow, whereas a collapsed `Left` or
`Bottom` dock returns the rest of its strip to the canvas. Making the `Right`
dock behave the same way is a separate question and is not decided here.

## Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `LAYOUT_VERSION` | 3 | Current serialization format version. |
| `MIN_DOCK_WIDTH` | 150px | Minimum dock pane width. |
| `MAX_DOCK_WIDTH` | 500px | Maximum dock pane width. |
| `DEFAULT_DOCK_WIDTH` | 240px | Default dock pane width. |
| `DEFAULT_FLOATING_WIDTH` | 220px | Default floating dock width. |
| `MIN_GROUP_HEIGHT` | 40px | Minimum panel group height. |
| `MIN_CANVAS_WIDTH` | 200px | Minimum canvas pane width. |
| `SNAP_DISTANCE` | 20px | Edge detection distance for snapping. |

## File Structure

| Language | Layout file | Panel UI | Pane file | Menu |
|----------|-------------|----------|-----------|------|
| Rust | `jas_dioxus/src/workspace/workspace.rs` | (inline in app.rs) | `pane.rs` | `menu.rs` + `app.rs` |
| Swift | `JasSwift/Sources/Workspace/WorkspaceLayout.swift` | `DockPanelView.swift` | `Pane.swift` | `JasCommands.swift` |
| OCaml | `jas_ocaml/lib/workspace/workspace_layout.ml` | `dock_panel.ml` | `pane.ml` | `menubar.ml` |
| Python | `jas/workspace/workspace_layout.py` | `dock_panel.py` | `pane.py` | `menu/menu.py` |

## Tests

Each project has workspace layout tests covering: default layout structure,
panel operations (add, close, move, detach), dock operations (float, redock,
collapse), generation tracking, JSON serialization round-trips, version
validation, storage keys, AppConfig registration, and pane layout integration.

| Language | Test file |
|----------|-----------|
| Rust | `jas_dioxus/src/workspace/workspace.rs` (`#[cfg(test)]` module) |
| Swift | `JasSwift/Tests/Workspace/DockTests.swift` |
| OCaml | `jas_ocaml/test/workspace/workspace_layout_test.ml` |
| Python | `jas/workspace/workspace_layout_test.py` |
