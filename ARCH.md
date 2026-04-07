# Jas Architecture

Jas is a vector drawing application with four parallel implementations sharing
the same architecture:

| Implementation | UI Framework | Directory      |
|----------------|-------------|----------------|
| Python         | Qt/PySide6  | `jas/`         |
| OCaml          | GTK/lablgtk | `jas_ocaml/`   |
| Rust           | Dioxus/WASM | `jas_dioxus/`  |
| Swift          | AppKit      | `JasSwift/`    |

All four follow an MVC pattern built around an **immutable document model**.

---

## MVC Overview

```
  ┌──────────┐     events      ┌──────────┐
  │  Canvas   │ ──────────────> │   Tool   │
  │  (View)   │ <────────────── │          │
  └──────────┘   draw_overlay   └────┬─────┘
       │                             │
       │ renders                     │ mutations via
       │                             │ ToolContext
       v                             v
  ┌──────────┐               ┌──────────────┐
  │  Model   │ <──────────── │  Controller  │
  │          │  set_document  │              │
  └────┬─────┘               └──────────────┘
       │
       │ notifies listeners
       v
    [Views, Menus, Title bar, ...]
```

**Model** holds the current Document and undo/redo stacks.
**Controller** produces new Documents from user actions.
**Canvas** renders the document and dispatches mouse/key events to the active Tool.
**Tools** implement interaction state machines (press/move/release) and call Controller methods through a ToolContext facade.

---

## Document

A Document is an immutable value consisting of an ordered list of Layers, an
active layer index, and a selection state.

```
Document
  layers:          [Layer, ...]     # ordered back-to-front
  selected_layer:  int              # index of active layer for new elements
  selection:       Selection        # set of ElementSelection entries
```

### Element paths

Elements are addressed by position, not by identity. An **ElementPath** is a
tuple of integer indices tracing the route through the tree:

```
(0,)      -> layers[0]                     (a Layer)
(0, 2)    -> layers[0].children[2]         (an element)
(0, 2, 1) -> layers[0].children[2].children[1]  (inside a Group)
```

This avoids the need for element IDs and enables cheap structural operations.

### Selection

A **Selection** is a set of **ElementSelection** entries, each pairing a path
with a set of selected control point indices. Equality and hashing are by path
only, so the collection behaves as a path-keyed map.

```
ElementSelection
  path:            ElementPath
  control_points:  set of int    # which CPs are selected (empty = whole element)
```

Language-specific representations:

| Language | Selection type | ElementSelection equality |
|----------|---------------|--------------------------|
| Python   | `frozenset[ElementSelection]` | path-only `__eq__`/`__hash__` |
| OCaml    | `PathMap` (map keyed by path) | structural |
| Rust     | `Vec<ElementSelection>` (ordered) | path-only `PartialEq`/`Hash` |
| Swift    | `Set<ElementSelection>` | path-only `Hashable` |

### Immutable operations

Documents are never mutated in place. Every change produces a new Document:

- `get_element(path)` -- traverse the tree to find an element
- `replace_element(path, elem)` -- return a new Document with one element swapped
- `insert_element_after(path, elem)` -- return a new Document with an insertion
- `delete_element(path)` -- return a new Document with one element removed
- `delete_selection()` -- remove all selected elements

These delegate to recursive helpers that rebuild only the affected spine of the
tree (structural sharing for unchanged subtrees).

---

## Elements

Elements are immutable value types forming a closed union:

```
Line        x1, y1, x2, y2
Rect        x, y, width, height, rx, ry
Circle      cx, cy, r
Ellipse     cx, cy, rx, ry
Polyline    points: [(x, y), ...]
Polygon     points: [(x, y), ...]
Path        d: [PathCommand, ...]
Text        x, y, content, font_family, font_size, ...
TextPath    d: [PathCommand, ...], content, start_offset, font_family, ...
Group       children: [Element, ...]
Layer       name, children: [Element, ...]    (extends Group)
```

### Common properties

Every element carries:

- **opacity** (0.0--1.0)
- **transform** (optional 2D affine matrix `[a b c d e f]`)
- **locked** (if true, element cannot be selected or edited)

### Presentation attributes

- **Fill**: color
- **Stroke**: color, width, linecap, linejoin
- **Color**: RGBA with components in [0.0, 1.0]
- **Transform**: 2D affine matrix with constructors `translate`, `scale`, `rotate`

### Path commands

Path elements use an SVG-compatible command sequence:

```
MoveTo(x, y)                                    M
LineTo(x, y)                                    L
CurveTo(x1, y1, x2, y2, x, y)                  C  (cubic Bezier)
SmoothCurveTo(x2, y2, x, y)                     S
QuadTo(x1, y1, x, y)                            Q  (quadratic Bezier)
SmoothQuadTo(x, y)                              T
ArcTo(rx, ry, rotation, large_arc, sweep, x, y) A
ClosePath                                        Z
```

### Control points

Each element type exposes a fixed number of **control points** -- the
draggable handles that define its geometry. Functions:

- `control_point_count(elem)` -- how many CPs the element has
- `control_points(elem)` -- list of (x, y) positions
- `move_control_points(elem, cp_indices, dx, dy)` -- return new element with CPs moved

For Path elements, additional handle manipulation:

- `move_path_handle(path, anchor_idx, handle_type, dx, dy)` -- move a Bezier in/out handle

### Bounds

Every element computes its axis-aligned bounding box via `bounds()`,
returning `(x, y, width, height)`. Bezier curves use derivative root-finding
(`cubic_extrema`, `quadratic_extremum`) for tight bounds. Stroke width
inflates the bounding box by half the stroke width on all sides.

---

## Model

The Model holds the current Document and provides undo/redo through an
immutable-snapshot mechanism.

```
Model
  document:        Document         # current state
  saved_document:  Document         # last-saved state (for is_modified)
  filename:        string
  undo_stack:      [Document, ...]  # max 100 entries
  redo_stack:      [Document, ...]
```

### Undo/redo protocol

1. Before a mutation, call `model.snapshot()` -- pushes the current document
   onto the undo stack and clears the redo stack.
2. The Controller produces a new Document and calls `model.set_document(new_doc)`.
3. `model.undo()` pops from the undo stack, pushes current to redo, restores.
4. `model.redo()` pops from the redo stack, pushes current to undo, restores.

### Observation

Views register callbacks with `on_document_changed(callback)` and
`on_filename_changed(callback)`. Every call to `set_document` or
`undo`/`redo` fires the document-changed listeners, triggering a canvas
repaint and UI update.

Rust uses a generation counter instead of reference equality for `is_modified`.

---

## Controller

The Controller is the command dispatcher. It receives high-level operations
(select, move, add element, group, etc.), snapshots the model, computes a new
Document, and updates the model.

### Selection operations

Three selection modes correspond to the three selection tools:

| Operation | Tool | Behavior |
|-----------|------|----------|
| `select_rect` | Selection | Select elements whose bounds intersect rect. Groups selected as a whole. |
| `group_select_rect` | Group Selection | Traverse into groups; select individual elements with all CPs. |
| `direct_select_rect` | Direct Selection | Select only the control points that fall within rect. |

All three accept an `extend` flag (Shift key) that toggles selection at the
control-point level using symmetric difference.

### Element mutations

- `add_element(elem)` -- append to active layer
- `move_selection(dx, dy)` -- translate all selected control points
- `copy_selection(dx, dy)` -- duplicate selected elements with offset
- `lock_selection()` / `unlock_all()`
- `group_selection()` / `ungroup_selection()`
- `move_path_handle(path, anchor_idx, handle_type, dx, dy)`

### Clipboard

- `copy()` / `cut()` / `paste()` -- internal clipboard of element lists
- Paste applies a `PASTE_OFFSET` translation to distinguish from original

---

## Canvas and Rendering

The Canvas is the view component. It:

1. **Renders** all layers and elements using the platform's 2D graphics API
   (QPainter, Cairo, CanvasRenderingContext2d, CGContext).
2. **Draws selection overlays** -- bounding boxes, control point handles
   (circles at `HANDLE_DRAW_SIZE = 10` px), Bezier handle lines.
3. **Dispatches mouse and key events** to the active Tool via the ToolContext.
4. **Provides hit-testing callbacks** to tools for querying what's under the cursor.

---

## Tools

Tools implement the `CanvasTool` interface -- a state machine driven by
mouse and keyboard events:

```
CanvasTool
  on_press(ctx, x, y, shift, alt)
  on_move(ctx, x, y, shift, dragging)
  on_release(ctx, x, y, shift, alt)
  on_double_click(ctx, x, y)
  on_key(ctx, key) -> bool
  draw_overlay(ctx, painter)
  activate(ctx)
  deactivate(ctx)
```

### ToolContext

Tools do not access the Model or Controller directly. Instead, the canvas
constructs a **ToolContext** facade that bundles:

- `model` / `controller` -- references for reading state and issuing commands
- `hit_test_selection(x, y)` -- is the point over a selected element?
- `hit_test_handle(x, y)` -- is the point over a Bezier handle?
- `hit_test_text(x, y)` -- is the point over a text element?
- `hit_test_path_curve(x, y)` -- is the point over a path curve?
- `request_update()` -- schedule a canvas repaint
- `start_text_edit(path, elem)` / `commit_text_edit()` -- text editing lifecycle

This decouples tools from the UI framework.

### Tool constants

```
HIT_RADIUS          = 8.0 px    click detection radius for control points
HANDLE_DRAW_SIZE    = 10.0 px   diameter of drawn control point handles
DRAG_THRESHOLD      = 4.0 px    movement before a click becomes a drag
PASTE_OFFSET        = 24.0 pt   translation applied when pasting
LONG_PRESS_MS       = 500 ms    long-press detection threshold
POLYGON_SIDES       = 5         default sides for polygon tool
```

### Tool inventory

| Tool | Description |
|------|-------------|
| **Selection** | Marquee select (bounds intersection), drag-to-move, Alt+drag to copy. Groups selected as a unit. |
| **Group Selection** | Like Selection but traverses into groups to select individual children. |
| **Direct Selection** | Select individual control points within a marquee. Drag Bezier handles directly. |
| **Pen** | Click to place anchor points, drag to create Bezier handles. Builds a Path element. Double-click or Escape to finish. |
| **Pencil** | Freehand drawing: samples mouse points during drag, fits Bezier curves to the stroke. |
| **Text** | Click to place a text element. Double-click existing text to edit. |
| **Type on a Path** | Like Pen, but attaches editable text that flows along the resulting path. |
| **Line** | Press-drag-release to create a Line element. |
| **Rect** | Press-drag-release to create a Rect element. Coordinates normalized for any drag direction. |
| **Polygon** | Press-drag-release to create a regular polygon. First edge defined by drag vector. |

Drawing tools (Line, Rect, Polygon) share a common base that handles the
press/move/release state machine and overlay drawing. Subclasses override
`create_element()` and `draw_preview()`.

Selection tools share a common base with states `Idle`, `Marquee`, and
`Moving`. Subclasses override `select_rect()` to call the appropriate
Controller method.

---

## Hit Testing

The `geometry/hit_test` module provides pure functions for geometric queries
used by selection tools and the canvas hit-test callbacks:

- `point_in_rect` -- point containment
- `segments_intersect` -- 2D line segment intersection via cross products
- `segment_intersects_rect` -- segment vs. rectangle edges
- `rects_intersect` -- axis-aligned rectangle overlap
- `circle_intersects_rect` / `ellipse_intersects_rect` -- shape vs. rectangle
- `segments_of_element` -- flatten an element to its visible line segments
- `element_intersects_rect` -- does an element's visible geometry overlap a rectangle?
- `all_cps` -- return the full set of control point indices for an element

Filled shapes use bounding-box intersection. Stroked shapes check whether
individual drawn segments cross the selection rectangle. Paths and polylines
are flattened to line segments before testing.

---

## SVG Import/Export

The `geometry/svg` module handles reading and writing SVG files:

- **Export**: walks the document tree, emitting SVG XML. Colors, strokes, fills,
  transforms, and path data are converted to SVG attribute format.
- **Import**: parses SVG XML, reconstructing the element tree. Path `d`
  attributes are parsed into PathCommand sequences. Numeric values are
  validated with safe parsing (non-finite values replaced with 0.0).
- **Unit conversion**: `PT_TO_PX = 96/72` (CSS pixels per point at 96 DPI).

---

## Menu System

Menus are defined as declarative data structures (lists of items with labels,
keyboard shortcuts, and command identifiers). Each command maps to a function
that typically:

1. Calls `model.snapshot()`
2. Computes a new Document via Controller methods
3. Calls `model.set_document(new_doc)`

Menu commands include: New, Open, Save, Save As, Export SVG, Undo, Redo,
Cut, Copy, Paste, Delete, Select All, Group, Ungroup, Lock, Unlock All.

---

## Directory Layout

Each implementation mirrors this structure:

```
document/
  document     # Document, ElementPath, ElementSelection, Selection
  model        # Model with undo/redo stacks
  controller   # Controller with selection and mutation operations
geometry/
  element      # Element types, PathCommand, bounds, control points
  hit_test     # Pure geometric query functions
  svg          # SVG import/export
  measure      # Unit types and text-on-path measurement
tools/
  tool         # CanvasTool interface, ToolContext, constants
  selection    # Selection, Group Selection, Direct Selection tools
  drawing      # Line, Rect, Polygon tools
  pen          # Pen tool (Bezier path creation)
  pencil       # Pencil tool (freehand with curve fitting)
  text         # Text tool
  type_on_path # Type on a Path tool
canvas/
  canvas       # Canvas view, rendering, hit-test callbacks, tool dispatch
  toolbar      # Tool selection UI
menu/
  menubar      # Menu definitions and command dispatch
```
