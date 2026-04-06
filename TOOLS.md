# Toolbar and Tools

This document describes the toolbar layout, the CanvasTool interface, the
ToolContext facade, and each of the thirteen tools.

---

## Toolbar

The toolbar is a vertical 2-column grid of tool buttons. Seven slots are
visible; four alternate tools are hidden behind shared slots and accessed
via long-press menus.

### Grid layout

```
 Row 0:  [ Selection (V)    ] [ Direct Selection (A)  ]
 Row 1:  [ Pen (P)          ] [ Pencil (N)            ]
 Row 2:  [ Text (T)         ] [ Line (L)              ]
 Row 3:  [ Rect (M)         ]
```

### Shared slots

Four toolbar positions are shared between alternate tools. Long-pressing
the button (500 ms) opens a popup menu to switch:

| Slot | Default | Alternates | Position |
|------|---------|------------|----------|
| Arrow slot | Direct Selection | Group Selection | Row 0, Col 1 |
| Pen slot | Pen | Add Anchor Point, Delete Anchor Point, Anchor Point | Row 1, Col 0 |
| Text slot | Text | Text on Path | Row 2, Col 0 |
| Shape slot | Rect | Polygon | Row 3, Col 0 |

When an alternate is selected from the menu, that tool replaces the default
in the slot. A small triangle indicator on the button signals that
alternates are available.

### Keyboard shortcuts

| Key | Tool |
|-----|------|
| V | Selection |
| A | Direct Selection |
| P | Pen |
| + / = | Add Anchor Point |
| - | Delete Anchor Point |
| Shift+C | Anchor Point |
| N | Pencil |
| T | Text |
| L | Line |
| M | Rect |

Group Selection, Text on Path, and Polygon have no keyboard shortcuts --
they are accessed through the long-press menus.

---

## CanvasTool Interface

Every tool implements this interface. The canvas dispatches mouse and
keyboard events to the active tool.

```
CanvasTool
  on_press(ctx, x, y, shift, alt)       # mouse button down
  on_move(ctx, x, y, shift, dragging)   # mouse move (dragging = button held)
  on_release(ctx, x, y, shift, alt)     # mouse button up
  on_double_click(ctx, x, y)            # double-click (optional)
  on_key(ctx, key) -> bool              # key press; return true if handled
  draw_overlay(ctx, painter)            # draw tool-specific overlay
  activate(ctx)                         # called when tool becomes active
  deactivate(ctx)                       # called when switching away
```

`on_press`, `on_move`, `on_release`, and `draw_overlay` are required.
The others have default no-op implementations.

---

## ToolContext

Tools do not access the Model, Controller, or canvas directly. The canvas
constructs a **ToolContext** facade for each event dispatch:

```
ToolContext
  model                  Model reference (read document state)
  controller             Controller reference (issue mutations)
  document               shortcut for model.document
  snapshot()             shortcut for model.snapshot()
  hit_test_selection     (x, y) -> bool
  hit_test_handle        (x, y) -> (path, anchor_idx, handle_type)?
  hit_test_text          (x, y) -> (path, text_element)?
  hit_test_path_curve    (x, y) -> (path, element)?
  request_update()       schedule a canvas repaint
  start_text_edit        (path, element) -> begin text editing
  commit_text_edit       () -> finalize text editing
```

This decouples tools from the UI framework and makes tools testable with
mock contexts.

### Shared constants

```
HIT_RADIUS          = 8.0 px     click detection radius for handles
HANDLE_DRAW_SIZE    = 10.0 px    diameter of drawn control point handles
DRAG_THRESHOLD      = 4.0 px     movement before a click becomes a drag
PASTE_OFFSET        = 24.0 pt    translation applied when pasting
LONG_PRESS_MS       = 500 ms     long-press detection for toolbar alternates
POLYGON_SIDES       = 5          default number of sides for polygon tool
```

---

## Selection Tool

**Shortcut:** V

Selects elements by clicking or dragging a marquee rectangle. Groups are
treated as atomic units.

### States

```
IDLE ──press on selection──> MOVING
  │                             │ release: move_selection or copy_selection
  │                             v
  │ press elsewhere          IDLE
  v
MARQUEE ──release──> IDLE (calls select_rect)
```

### Behavior

| Action | Result |
|--------|--------|
| Click on element | Select it (with all CPs). If parent is a Group, select the whole Group. |
| Click on empty space | Clear selection |
| Drag from empty space | Draw marquee; on release, select all elements whose bounds intersect |
| Click on selected element, then drag | Move selection |
| Shift-click | Toggle element in/out of selection |
| Shift-marquee | Toggle intersected elements (symmetric difference) |
| Alt-drag | Copy selection with offset instead of moving |
| Shift-drag | Constrain movement to 45-degree angles |

### Overlay

- **Marquee:** dashed gray rectangle from press point to cursor.
- **Moving:** dashed blue outlines of selected elements at their
  preview positions.

---

## Group Selection Tool

**Shortcut:** none (long-press on Direct Selection slot)

Like the Selection Tool but traverses **into** groups. Selects individual
elements within groups rather than selecting the group as a whole. Each
selected element gets all its control points.

Same states and interaction model as the Selection Tool. The only difference
is the Controller method called: `group_select_rect` instead of
`select_rect`.

---

## Direct Selection Tool

**Shortcut:** A

Selects individual **control points** within a marquee. Traverses into
groups. Only the CPs that fall inside the marquee are selected, enabling
partial manipulation of an element's geometry.

### Additional capability: handle dragging

When a Bezier path is selected, its anchor points and handles are visible.
Clicking on a handle enters a handle-drag mode:

1. `hit_test_handle(x, y)` returns `(path, anchor_idx, handle_type)`.
2. Dragging moves the handle.
3. On release, `move_path_handle(path, anchor_idx, handle_type, dx, dy)`
   is called.
4. Moving one handle automatically rotates the opposite handle to maintain
   smooth (G1) continuity, preserving the opposite handle's distance.

### Overlay

Same as Selection Tool, plus:
- Handle drag preview showing the path with the handle in its new position.

---

## Pen Tool

**Shortcut:** P
**Shared slot:** Pen slot (long-press to switch to Add/Delete/Anchor Point)

Creates Bezier paths by clicking anchor points and dragging handles.

### States

```
IDLE ──press──> DRAGGING ──release──> PLACING ──press──> DRAGGING ...
                                         │
                            double-click / Escape / Enter
                                         v
                                    IDLE (path finalized)
```

### Interaction

| Action | Result |
|--------|--------|
| Click | Place a corner anchor point (handles at anchor position) |
| Click and drag | Place a smooth anchor with symmetric handles |
| Click near first point | Close the path (if 3+ points exist) |
| Double-click | Finalize the open path (removes last point) |
| Escape / Enter | Finalize the open path |
| Switch to another tool | Finalize the path (via `deactivate`) |

### Point model

Each `PenPoint` stores:
- `(x, y)` -- anchor position
- `(hx_in, hy_in)` -- incoming Bezier handle
- `(hx_out, hy_out)` -- outgoing Bezier handle
- `smooth` -- whether handles are symmetric (dragged vs. clicked)

A **corner point** is created by clicking without dragging: both handles
remain at the anchor position, producing a sharp angle at that vertex.

A **smooth point** is created by click-and-drag: the outgoing handle
follows the cursor and the incoming handle is reflected through the anchor,
guaranteeing G1 continuity (tangent continuity):

```
hx_in = 2 * x - hx_out
hy_in = 2 * y - hy_out
```

The distance from anchor to cursor determines the handle length, which
controls the "weight" of the curve on each side. Longer handles produce
broader arcs; handles at the anchor produce straight segments.

### Path construction

On finalization, the tool converts its point list to path commands:
- `MoveTo(p0.x, p0.y)` for the first point.
- `CurveTo(prev.hx_out, prev.hy_out, curr.hx_in, curr.hy_in, curr.x, curr.y)`
  for each subsequent point.
- If closing: an additional `CurveTo` back to the first point, followed by
  `ClosePath`.

Close detection: if the last point is within `HIT_RADIUS` (8 px) of the
first point, the path is closed. When closing, the duplicate final point
is removed so that the close segment connects from the last distinct point
back to the first.

A path must have at least 2 points to be finalized. Single-point paths
are discarded.

### Overlay

- Black curve segments for the committed portion of the path.
- Dashed gray preview curve from the last anchor to the current cursor.
  If the cursor is near the first point (within close radius), the preview
  curves to the first point instead of the cursor.
- Blue handle lines connecting incoming and outgoing handles through smooth
  anchor points.
- White-filled blue circles for handle endpoints.
- Blue filled squares for anchor points.

---

## Add Anchor Point Tool

**Shortcut:** + / =
**Shared slot:** Pen slot (long-press on the Pen button)

Inserts new anchor points into existing paths. The tool has three modes:
click to insert, click-and-drag to insert and adjust handles, and
Alt+click to toggle smooth/corner on an existing anchor.

### Hit detection

The tool finds the nearest path element within `HIT_RADIUS + 2` px of the
click. For each segment (CurveTo or LineTo) in the path, it computes the
closest point and parameter `t`:

- **CurveTo segments**: coarse sampling (50 steps) followed by ternary
  search refinement (20 iterations) on the cubic Bezier.
- **LineTo segments**: perpendicular projection onto the line segment,
  clamped to [0, 1].

### Mode 1: Click to insert

Clicking on a path splits the nearest segment at parameter `t` using
de Casteljau subdivision, inserting a new anchor point that lies exactly
on the original curve.

**CurveTo splitting:** A single `CurveTo(x1, y1, x2, y2, x, y)` is
replaced by two CurveTos whose control points are computed by the
de Casteljau algorithm at parameter `t`:

```
Given cubic P0, P1, P2, P3 and parameter t:

Level 1:  A1 = lerp(P0, P1, t)    A2 = lerp(P1, P2, t)    A3 = lerp(P2, P3, t)
Level 2:  B1 = lerp(A1, A2, t)    B2 = lerp(A2, A3, t)
Level 3:  M  = lerp(B1, B2, t)     ← new anchor point

First half:  CurveTo(A1, B1, M)
Second half: CurveTo(B2, A3, P3)
```

This preserves the original curve shape exactly -- the path before and
after insertion traces the same geometric curve.

**LineTo splitting:** A single `LineTo(x, y)` is replaced by two LineTos
with the midpoint at `lerp(start, end, t)`.

### Mode 2: Click-and-drag to insert and adjust handles

When the split produces two CurveTo segments, dragging after the click
adjusts the handles of the newly inserted anchor:

- **Outgoing handle** (`x1, y1` of the second CurveTo): set to the drag
  position.
- **Incoming handle** (`x2, y2` of the first CurveTo): by default,
  mirrored through the anchor for smooth (G1) continuity:

```
incoming = 2 * anchor - outgoing
```

Holding **Alt/Option during drag** creates a **cusp point** instead: only
the outgoing handle moves, while the incoming handle stays at its
de Casteljau position. This breaks tangent continuity, allowing an abrupt
change of direction at the anchor.

### Mode 3: Alt+click to toggle smooth/corner

Alt+clicking on an existing anchor point (within `HIT_RADIUS`) toggles
between smooth and corner:

**Corner → Smooth:** The handles are extended along the direction from the
previous anchor to the next anchor. The incoming handle extends backward
at 1/3 the distance to the previous anchor; the outgoing handle extends
forward at 1/3 the distance to the next anchor.

```
direction = normalize(next_anchor - prev_anchor)
incoming_handle  = anchor - direction * dist_to_prev / 3
outgoing_handle  = anchor + direction * dist_to_next / 3
```

**Smooth → Corner:** Both handles are collapsed to the anchor position,
producing a sharp angle.

Detection: a point is considered a corner if both its incoming handle
(`x2, y2`) and outgoing handle (`x1, y1` of the next command) are within
0.5 px of the anchor position.

### States

```
             on_press (click on path)
    IDLE ────────────────────────────> DRAGGING (if CurveTo pair)
      │                                    │
      │  on_press (Alt+click on anchor)    │ on_move: update handles
      │  → toggle smooth/corner, stay IDLE │   (Alt held → cusp mode)
      │                                    │
      │  on_press (miss)                   │ on_release
      │  → no-op                           v
      └───────────────────────────────── IDLE
```

### Overlay (during drag)

- **Smooth point:** a single blue line through the anchor, connecting the
  incoming and outgoing handles.
- **Cusp point:** two separate blue lines, each connecting the anchor to
  one handle independently.
- White-filled blue circles at handle endpoints.
- Blue filled square at the anchor point.

Cusp detection uses the cross product and dot product of the two handle
vectors from the anchor. A point is a cusp if the handles are not
collinear (`|cross| > max_len * 0.01`) or point in the same direction
(`dot > 0`).

---

## Delete Anchor Point Tool

**Shortcut:** -
**Shared slot:** Pen slot (long-press on the Pen button)

Removes anchor points from existing paths. When an anchor is deleted, the
adjacent segments are merged into a single segment that preserves the outer
control handles.

### Hit detection

The tool finds an anchor point within `HIT_RADIUS` (8 px) of the click on
any path element in the document, including paths inside unlocked groups.

### Deletion algorithm

The tool handles three cases depending on the position of the deleted anchor:

**Case 1: First anchor (MoveTo at index 0)**

The next command's endpoint is promoted to become the new MoveTo. The
original MoveTo and the command immediately after it are replaced by a
single MoveTo at the next anchor's position.

```
Before:  M(0,0) C(10,0, 20,0, 30,0) C(40,0, 50,0, 60,0)
Delete index 0:
After:   M(30,0) C(40,0, 50,0, 60,0)
```

**Case 2: Last anchor**

The path is simply truncated before the deleted anchor. If a ClosePath
followed the last anchor, it is preserved.

```
Before:  M(0,0) C(10,0, 20,0, 30,0) C(40,0, 50,0, 60,0)
Delete index 2:
After:   M(0,0) C(10,0, 20,0, 30,0)
```

**Case 3: Interior anchor**

The two adjacent segments (the one ending at the deleted anchor and the one
starting from it) are merged into a single segment. The merge keeps the
**outer control handles** -- the outgoing handle of the previous anchor and
the incoming handle of the next anchor:

| Segments | Merged result |
|----------|---------------|
| CurveTo + CurveTo | CurveTo(x1,y1 from first, x2,y2 from second, endpoint from second) |
| CurveTo + LineTo | CurveTo(x1,y1 from first, endpoint,endpoint, endpoint) |
| LineTo + CurveTo | CurveTo(prev_anchor, prev_anchor, x2,y2 from second, endpoint) |
| LineTo + LineTo | LineTo(endpoint of second) |

```
Before:  M(0,0) C(10,0, 20,0, 30,0) C(40,0, 50,0, 60,0) C(70,0, 80,0, 90,0)
Delete index 2 (anchor at 60,0):
After:   M(0,0) C(10,0, 20,0, 30,0) C(40,0, 80,0, 90,0)
                                       ^^^^   ^^^^
                                       outer handles preserved
```

### Minimum path size

If the path would have fewer than 2 anchor points after deletion, the
entire path element is removed from the document.

### Selection after deletion

After a successful deletion, all remaining control points of the modified
path are selected.

### States

```
    IDLE ──press on anchor──> delete anchor, return to IDLE
      │
      │ press (miss)
      └──> no-op
```

The tool has no drag behavior. All work happens in `on_press`.

### Overlay

None.

---

## Anchor Point Tool (Convert Anchor Point)

**Shortcut:** Shift+C
**Shared slot:** Pen slot (long-press on the Pen button)

Converts anchor points between corner, smooth, and cusp types. This is the
primary tool for reshaping curves by changing the relationship between an
anchor's incoming and outgoing control handles.

### Point types

| Type | Description | Handle behavior |
|------|-------------|-----------------|
| Corner | Sharp angle at the anchor | Both handles collapsed to anchor position (or absent) |
| Smooth | Tangent-continuous (G1) | Handles are collinear through the anchor, reflected symmetrically |
| Cusp | Abrupt direction change | Handles exist but point in independent directions |

### Interaction

The tool provides three distinct interactions:

**1. Drag on a corner point → convert to smooth**

Dragging from a corner point pulls out symmetric control handles. The
outgoing handle follows the cursor; the incoming handle is reflected
through the anchor:

```
outgoing_handle = cursor_position
incoming_handle = 2 * anchor - cursor_position
```

If the anchor was previously a LineTo, it is promoted to a CurveTo. The
adjacent segments are also converted to CurveTo if necessary to accommodate
the new handles.

| Action | Result |
|--------|--------|
| Press on corner anchor | Begin handle pull |
| Drag | Live preview: handles extend symmetrically from anchor toward cursor |
| Release | Commit the conversion; select all remaining CPs |

**2. Click on a smooth point → convert to corner**

Clicking (without dragging) on a smooth point collapses both handles to
the anchor position, converting it to a corner:

```
incoming_handle (x2,y2) = anchor position
outgoing_handle (x1,y1 of next cmd) = anchor position
```

The CurveTo commands are preserved (not converted back to LineTo) so that
the adjacent segments retain their other handles. Only the handles touching
this anchor are collapsed.

| Action | Result |
|--------|--------|
| Click on smooth anchor | Collapse both handles to anchor; select all CPs |

**3. Drag on a control handle → create cusp**

Dragging an existing control handle moves **only that handle** without
reflecting the opposite handle. This breaks the smooth (G1) continuity,
creating a cusp point where the curve changes direction abruptly.

This differs from the Direct Selection tool, which maintains smooth
continuity by rotating the opposite handle when one handle is dragged.

```
Direct Selection:  move handle → opposite handle rotates to stay collinear
Anchor Point tool: move handle → opposite handle stays fixed (independent)
```

| Action | Result |
|--------|--------|
| Press on handle | Begin independent handle drag |
| Drag | Move only the pressed handle; opposite handle unchanged |
| Release | Commit the cusp; select all CPs |

### Hit testing

The tool checks handles before anchors, so dragging a handle that overlaps
its anchor triggers cusp behavior rather than corner-to-smooth conversion.

Handles are tested on **all** path elements in the document (not just
selected ones), unlike the Direct Selection tool which only shows handles
on selected elements.

### States

```
                 press on handle
    IDLE ────────────────────────> DRAGGING_HANDLE
      │                                │
      │  press on corner anchor        │ on_move: move handle independently
      │  ──────────────────>           │ on_release: commit cusp
      │  DRAGGING_CORNER               v
      │       │                     IDLE
      │       │ on_move: update
      │       │   symmetric handles
      │       │ on_release: commit
      │       v   smooth conversion
      │     IDLE
      │
      │  press on smooth anchor
      │  ──────────────────>
      │  PRESSED_SMOOTH
      │       │
      │       │ release (no drag): convert to corner
      │       │ drag > 3px: convert to DRAGGING_CORNER
      │       v   (reset handles, then pull new ones)
      │     IDLE
      │
      │  press (miss)
      └──> no-op
```

Note: pressing on a smooth point and then dragging beyond 3 px first
collapses the handles (corner conversion), then immediately begins pulling
new handles (corner-to-smooth conversion). This allows the user to
"re-pull" handles in a different direction from a smooth point.

### Selection after conversion

All three interactions select all remaining control points of the modified
path after committing the change.

### Overlay

None. The canvas's standard handle rendering shows the updated handles
in real time during the drag.

---

## Pencil Tool

**Shortcut:** N

Freehand drawing with automatic Bezier curve fitting. The pencil tool
converts a sequence of mouse-sampled points into a smooth piecewise cubic
Bezier path.

### Cursor and icon

The cursor and toolbar icon are rendered from a detailed SVG pencil image
(`transcript/icons/pencil tool.svg`, viewBox 0 0 256 256). The pencil
points to the lower-left; the cursor hotspot is at the tip
(approximately pixel 1,23 in a 24×24 cursor image). The toolbar icon is
scaled to 28×28 using a `scale(28/256)` transform and rendered with three
fill layers:

| Layer | Color (cursor) | Color (toolbar) | Purpose |
|-------|-----------------|-----------------|---------|
| Outer outline | black | rgb(204,204,204) | Main pencil silhouette |
| Facets (×4 paths) | #5f5f5b | #3c3c3c | Body section detail |
| Tip highlight | white | white | Pencil tip accent |

### Interaction

| Action | Result |
|--------|--------|
| Press | Snapshot document; begin sampling; record press point |
| Drag | Append each mouse position to the point list; draw polyline preview |
| Release | Append release point; fit cubic Bezier curves to the sampled points; add Path element |
| Move without press | No-op (points not accumulated) |
| Release without press | No-op (no path created) |

### States

```
                 on_press
    IDLE ─────────────────> DRAWING
                               │
                            on_move: append (x, y) to points
                               │
                            on_release: append (x, y),
                               │        call finish()
                               v
                         fit_curve(points, FIT_ERROR)
                               │
                    ┌───────────┴───────────┐
                    │                       │
               segments empty          segments non-empty
               or < 2 points           │
                    │                  build MoveTo + CurveTos
                    │                  add_element(Path)
                    v                       │
                  IDLE                      v
                (no element)             IDLE
                                    (path created)
```

The `drawing` flag tracks whether a press is active. Points are cleared
after `finish()` regardless of outcome.

### Curve fitting

The tool uses the **Schneider algorithm** ("An Algorithm for Automatically
Fitting Digitized Curves", Graphics Gems I, 1990) to convert the sampled
polyline into a piecewise cubic Bezier spline.

**Algorithm parameters:**

| Parameter | Value | Description |
|-----------|-------|-------------|
| `FIT_ERROR` | 4.0 px | Maximum allowed deviation from sampled points |
| `MAX_ITERATIONS` | 4 | Newton-Raphson reparameterization iterations |

**Algorithm steps:**

1. **Compute endpoint tangents.** The left tangent at the first point is
   the direction from point 0 to point 1. The right tangent at the last
   point is the direction from the last point to the second-to-last point.

2. **Fit a single cubic Bezier** to the full point range using least-squares
   with chord-length parameterization.

3. **Check maximum error.** Walk all sampled points, compute the distance
   to the fitted curve at their parameterized positions. If the maximum
   error is within `FIT_ERROR`, accept the segment.

4. **Reparameterize.** If the error exceeds the threshold but is within
   a reasonable bound, use Newton-Raphson to refine the parameter values
   (up to `MAX_ITERATIONS` times) and re-fit. If the refined fit is
   within `FIT_ERROR`, accept.

5. **Split and recurse.** If the error still exceeds the threshold, split
   at the point of maximum error. Compute the tangent at the split point
   (using the adjacent points), then recursively fit the left and right
   halves independently.

The recursion produces a list of `BezierSegment` tuples, each containing
8 floats: `(p1x, p1y, c1x, c1y, c2x, c2y, p2x, p2y)`.

### Path construction

The fitted segments are converted to path commands:

```
cmds = [MoveTo(seg[0].p1x, seg[0].p1y)]
for each segment:
    cmds.append(CurveTo(seg.c1x, seg.c1y, seg.c2x, seg.c2y, seg.p2x, seg.p2y))
```

The resulting Path element has:
- **Stroke:** 1 px black (`Color(0, 0, 0)`, width 1.0)
- **Fill:** none

### Edge cases

| Scenario | Behavior |
|----------|----------|
| Single point (press + release at same location) | Two identical points are passed to `fit_curve`; a degenerate path is created |
| Very short drag (2-3 points) | `fit_curve` produces a single CurveTo segment |
| `fit_curve` returns empty | No path is created; points are discarded |

### Overlay

- **During drag:** black polyline connecting all sampled points in order
  (real-time visual feedback of the freehand stroke).
- **After release:** no overlay; the fitted path is added to the document
  as a normal element.

---

## Text Tool

**Shortcut:** T

Places and edits text elements.

### Interaction

| Action | Result |
|--------|--------|
| Click on empty space | Create a point text element at the click position |
| Click on existing text | Enter text editing mode for that element |
| Drag | Create an area text element with the dragged rectangle as bounds |

Point text vs. area text:
- **Point text** (`width = 0, height = 0`): single-line text at a point.
- **Area text** (`width > 0, height > 0`): text wraps within the rectangle.

The drag must exceed `DRAG_THRESHOLD` (4 px) to create area text; otherwise
it is treated as a click.

New text elements are created with the content "Lorem Ipsum", black fill,
and 16 pt sans-serif font.

### Text editing lifecycle

1. `start_text_edit(path, element)` -- canvas enters inline editing mode.
2. User types; canvas updates the text content in real time.
3. `commit_text_edit()` -- called when the tool is deactivated or another
   element is clicked, finalizing the text.

### Overlay

- Dashed gray rectangle during drag (area text preview).

---

## Text on Path Tool

**Shortcut:** none (long-press on Text slot)

Places text that flows along a Bezier curve. Supports three interaction
modes.

### Mode 1: Drag to create

Dragging creates a new TextPath element. The drag start and end define the
endpoints of a curve. During the drag, a perpendicular control point is
computed to give the curve a natural arc:

```
midpoint = (start + end) / 2
normal = perpendicular to (end - start), length = distance * 0.3
control = midpoint + normal
```

If the drag is too short (below `DRAG_THRESHOLD`), it becomes a click
(Mode 2). After creation, the element is selected and text editing begins.

### Mode 2: Click on existing path

Clicking on a Path element converts it to a TextPath, preserving the path
commands. The `start_offset` is set to the closest point on the path to the
click position. Text editing begins immediately.

Clicking on an existing TextPath enters editing mode.

### Mode 3: Drag the offset handle

When a TextPath is selected, a diamond-shaped handle appears at the
`start_offset` position along the path. Dragging this handle repositions
the text along the curve by computing the closest offset to the cursor:

```
new_offset = path_closest_offset(d, cursor_x, cursor_y)
```

### Overlay

- Dashed gray curve during drag-create.
- Orange diamond handle at the start-offset position for selected
  TextPath elements.

---

## Line Tool

**Shortcut:** L

Creates Line elements by press-drag-release.

### Interaction

| Action | Result |
|--------|--------|
| Press | Record start point, snapshot document |
| Drag | Update end point; show dashed preview line |
| Release | Create a Line element from start to end |
| Shift-drag | Constrain to 45-degree angles |

Created lines have a 1 px black stroke.

### Overlay

- Dashed gray line from press point to current cursor.

---

## Rect Tool

**Shortcut:** M

Creates Rect elements by press-drag-release.

### Interaction

| Action | Result |
|--------|--------|
| Press | Record start point, snapshot document |
| Drag | Update end point; show dashed preview rectangle |
| Release | Create a Rect element. Coordinates normalized so `x, y` is top-left and `width, height` are positive. |
| Shift-drag | Constrain to 45-degree angles |

Created rectangles have a 1 px black stroke and no fill.

### Overlay

- Dashed gray rectangle from press point to current cursor (normalized).

---

## Polygon Tool

**Shortcut:** none (long-press on Rect slot)

Creates regular polygons by press-drag-release.

### Interaction

| Action | Result |
|--------|--------|
| Press | Record start point, snapshot document |
| Drag | Update end point; show dashed preview polygon |
| Release | Create a Polygon element with `POLYGON_SIDES` (5) vertices |
| Shift-drag | Constrain the first edge to 45-degree angles |

### Polygon geometry

The press-to-release vector defines the **first edge** of the polygon. The
remaining vertices are computed from the circumscribed circle:

1. Compute midpoint `M` of the first edge.
2. Compute the perpendicular bisector direction.
3. Find the circumscribed circle center at distance
   `d = edge_length / (2 * tan(pi/n))` along the bisector.
4. Compute radius `r = edge_length / (2 * sin(pi/n))`.
5. Generate `n` vertices at equal angular intervals starting from the
   press point.

Created polygons have a 1 px black stroke and no fill.

### Overlay

- Dashed gray polygon outline.

---

## Drawing Tool Base

Line, Rect, and Polygon share a common base class that implements the
press-drag-release state machine:

```
                 on_press
    IDLE ─────────────────> DRAWING
                               │
                            on_release
                               │
                               v
                        create_element(sx, sy, ex, ey)
                        add to document
                               │
                               v
                             IDLE
```

Subclasses override:
- `create_element(sx, sy, ex, ey)` -- return the new Element or None.
- `draw_preview(painter, sx, sy, ex, ey)` -- draw the dashed overlay.

---

## Selection Tool Base

Selection, Group Selection, and Direct Selection share a common base class
with the Idle/Marquee/Moving state machine. Subclasses override:

- `select_rect(ctx, x, y, w, h, extend)` -- call the appropriate
  Controller selection method.
- `check_handle_hit(ctx, x, y)` -- return True if a handle was hit
  (Direct Selection only).

---

## Tool Lifecycle

### Activation / Deactivation

When the user switches tools:

1. `deactivate(ctx)` is called on the outgoing tool.
   - Pen tool finalizes any in-progress path.
   - Text tools commit any in-progress text edit.
2. `activate(ctx)` is called on the incoming tool.

### Shift constraint

Several tools support Shift to constrain angles. The constraint snaps the
endpoint to the nearest 45-degree increment from the start point:

```
angle = atan2(dy, dx)
snapped = round(angle / (pi/4)) * (pi/4)
result = start + distance * (cos(snapped), sin(snapped))
```

This produces constraints to horizontal, vertical, and 45-degree diagonal
directions.
