# Document, Layers, and Elements

This document describes the immutable document model, its tree structure,
element types, and supporting types (colors, strokes, fills, transforms,
path commands).

---

## Document

A **Document** is an immutable value consisting of:

```
Document
  layers:          [Layer, ...]           ordered back-to-front
  selected_layer:  int                    index of active layer for new elements
  selection:       Selection              current selection state
```

Documents are never mutated in place. Every edit produces a new Document by
cloning the tree and replacing only the affected spine. Unchanged subtrees
are shared structurally.

### Operations

| Method | Description |
|--------|-------------|
| `get_element(path)` | Traverse the tree, return the element at the given path |
| `replace_element(path, elem)` | Return a new Document with one element swapped |
| `insert_element_after(path, elem)` | Return a new Document with an element inserted after the path |
| `delete_element(path)` | Return a new Document with one element removed |
| `delete_selection()` | Remove all selected elements, clear selection |
| `bounds()` | Bounding box of all layers combined |

Deletions sort paths in reverse order so that removing later siblings does
not shift the indices of earlier ones.

---

## Element Paths

Elements are addressed by **position**, not identity. An **ElementPath** is
a tuple of integer indices tracing the route from the document root through
the tree:

```
(0,)        layers[0]                          a Layer
(0, 2)      layers[0].children[2]              a top-level element
(0, 2, 1)   layers[0].children[2].children[1]  inside a Group
(1,)        layers[1]                          a second Layer
```

This eliminates the need for unique element IDs. Paths are recalculated
after structural changes (insertions, deletions, reordering).

---

## Selection

A **Selection** is a set of **ElementSelection** entries. Each entry
pairs an element path with a **SelectionKind**:

```
ElementSelection
  path:  ElementPath
  kind:  SelectionKind

SelectionKind = All
              | Partial(SortedCps)
```

Equality and hashing are by **path only** — the selection set behaves
as a path-keyed map where each element can appear at most once.

The two `SelectionKind` cases capture two distinct user intents:

- **`All`** — the element is selected as a whole. Drag-move translates
  the primitive in place; Rect stays a Rect, Circle stays a Circle.
  This is what the Selection and Group Selection tools produce.
- **`Partial(SortedCps)`** — only the listed control points are
  selected (Direct Selection). Drag-move drags only those CPs and may
  convert Rect/Circle/Ellipse to a Polygon when the resulting shape is
  no longer axis-aligned. `SortedCps` is sorted, de-duplicated, and
  small (`u16`-wide indices).

`Partial(empty)` is a legal, retained state — "element selected,
zero CPs individually highlighted". The Direct Selection marquee
produces it when it crosses an element's body without catching any
CPs, and shift-click produces it when the last selected CP is
toggled off. Move/drag on `Partial(empty)` is a no-op. `All` XOR
`All` still drops the element (the element-level deselect gesture).

### Three selection modes

| Mode | Behavior |
|------|----------|
| **Selection** | Marquee selects elements whose bounding box intersects. Groups are selected as a whole. Result: `kind = All`. |
| **Group Selection** | Traverses into groups; selects individual elements. Result: `kind = All`. |
| **Direct Selection** | Selects individual control points that fall within the marquee. Result: `kind = Partial(...)`, or `kind = All` when the marquee crosses the body but no CPs. |

Shift-click or Shift-marquee XORs the new selection against the
existing selection per element: two `All`s cancel out; two `Partial`s
XOR their CP sets via `SortedCps.symmetric_difference`; mixed
All/Partial collapses to `All`.

---

## Layers

A **Layer** is a named container of elements. It extends Group with a name:

```
Layer
  name:       string            display name (e.g. "Layer 1")
  children:   [Element, ...]    ordered back-to-front
  opacity:    float             0.0 to 1.0
  transform:  Transform | nil   optional affine transform
  locked:     bool              if true, children cannot be selected
```

The document always contains at least one layer. New elements are added to
the `selected_layer`. Layers can be added, removed, and reordered through
the Controller.

---

## Elements

All elements are **immutable value types**. Each corresponds to an SVG
element type. The complete hierarchy:

```
Element (abstract)
  Line
  Rect
  Circle
  Ellipse
  Polyline
  Polygon
  Path
  Text
  TextPath
  Group
    Layer
```

### Common properties

Every element carries these properties:

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `opacity` | float | 1.0 | Opacity from 0.0 (transparent) to 1.0 (opaque) |
| `transform` | Transform or nil | nil | Optional 2D affine transform |
| `locked` | bool | false | If true, the element cannot be selected or edited |

---

### Line

SVG `<line>`. A straight segment between two endpoints.

```
Line
  x1, y1:    float       start point
  x2, y2:    float       end point
  stroke:    Stroke?     stroke style
```

**Control points:** 2 -- the start `(x1, y1)` and end `(x2, y2)`.

**Bounds:** min/max of endpoints, inflated by half-stroke-width.

---

### Rect

SVG `<rect>`. An axis-aligned rectangle with optional corner rounding.

```
Rect
  x, y:          float       top-left corner
  width, height: float       dimensions
  rx, ry:        float       corner radii (0 = sharp corners)
  fill:          Fill?        fill color
  stroke:        Stroke?      stroke style
```

**Control points:** 4 -- the corners `(x,y)`, `(x+w,y)`, `(x+w,y+h)`, `(x,y+h)`.

When all 4 CPs are moved together, the rect translates. When individual
corners are moved, the rect converts to a Polygon.

**Bounds:** `(x, y, width, height)` inflated by half-stroke-width.

---

### Circle

SVG `<circle>`. A circle defined by center and radius.

```
Circle
  cx, cy:    float       center
  r:         float       radius
  fill:      Fill?        fill color
  stroke:    Stroke?      stroke style
```

**Control points:** 4 -- the cardinal points: top `(cx, cy-r)`,
right `(cx+r, cy)`, bottom `(cx, cy+r)`, left `(cx-r, cy)`.

Moving all 4 translates the circle. Moving individual CPs recomputes the
center and radius to best fit the new cardinal positions.

**Bounds:** `(cx-r, cy-r, 2r, 2r)` inflated by half-stroke-width.

---

### Ellipse

SVG `<ellipse>`. An axis-aligned ellipse.

```
Ellipse
  cx, cy:    float       center
  rx, ry:    float       horizontal and vertical radii
  fill:      Fill?        fill color
  stroke:    Stroke?      stroke style
```

**Control points:** 4 -- the cardinal points: top `(cx, cy-ry)`,
right `(cx+rx, cy)`, bottom `(cx, cy+ry)`, left `(cx-rx, cy)`.

Moving individual CPs recomputes center and radii.

**Bounds:** `(cx-rx, cy-ry, 2rx, 2ry)` inflated by half-stroke-width.

---

### Polyline

SVG `<polyline>`. An open shape made of straight line segments.

```
Polyline
  points:    [(x, y), ...]     ordered vertex list
  fill:      Fill?              fill color
  stroke:    Stroke?            stroke style
```

**Control points:** one per vertex.

**Bounds:** min/max of all vertex coordinates, inflated by half-stroke-width.

---

### Polygon

SVG `<polygon>`. A closed shape made of straight line segments.

```
Polygon
  points:    [(x, y), ...]     ordered vertex list (implicitly closed)
  fill:      Fill?              fill color
  stroke:    Stroke?            stroke style
```

**Control points:** one per vertex.

**Bounds:** min/max of all vertex coordinates, inflated by half-stroke-width.

The Polygon tool creates regular polygons (default 5 sides) where the first
edge is defined by the press-drag vector and the remaining vertices are
computed from the circumscribed circle.

---

### Path

SVG `<path>`. A general shape defined by a sequence of path commands.

```
Path
  d:         [PathCommand, ...]    SVG path command sequence
  fill:      Fill?                  fill color
  stroke:    Stroke?                stroke style
```

**Control points:** one per anchor point (each non-ClosePath command
contributes one anchor). Cubic Bezier handles are manipulated separately
via `move_path_handle`.

**Bounds:** computed by finding Bezier curve extrema via derivative
root-finding (cubic and quadratic), then taking the min/max envelope.

See [Path Commands](#path-commands) below for the command types.

---

### Text

SVG `<text>`. A text element placed at a point or within a rectangular area.

```
Text
  x, y:              float       top-left of the layout box
  content:           string      the text content
  font_family:       string      e.g. "sans-serif", "serif", "monospace"
  font_size:         float       in points
  font_weight:       string      "normal" or "bold"
  font_style:        string      "normal" or "italic"
  text_decoration:   string      "none", "underline", "line-through"
  width, height:     float       area text dimensions (0 = point text)
  fill:              Fill?        text color
  stroke:            Stroke?      text outline
```

`(x, y)` is the *top* of the layout box. The first line's baseline
is at `y + 0.8 * font_size` (the ascent used by `text_layout`). On
SVG export the baseline-relative `y` attribute is computed as
`y + 0.8 * font_size`; on import the ascent is subtracted so files
round-trip stably.

**Point text** (`width = 0, height = 0`): single-line text starting at
`(x, y)`. Hard newlines (`\n`) wrap to additional lines.
**Area text** (`width > 0, height > 0`): text word-wraps within the
rectangle `(x, y, width, height)`.

**Control points:** 4 -- bounding box corners.

**Bounds:** for area text, the specified rectangle `(x, y, width,
height)`. For point text, the height is `lines * font_size` and the
width is the widest line measured with the platform font measurer
(NSAttributedString / Cairo / QFontMetricsF / canvas measureText).
The selection bounding box hugs the rendered glyphs.

---

### TextPath

SVG `<text><textPath>`. Text that flows along a Bezier path.

```
TextPath
  d:                 [PathCommand, ...]   the path to follow
  content:           string               the text content
  start_offset:      float                offset (0.0 to 1.0) along path
  font_family:       string
  font_size:         float
  font_weight:       string
  font_style:        string
  text_decoration:   string
  fill:              Fill?
  stroke:            Stroke?
```

**Control points:** one per anchor point in the path commands (same as Path).

**Bounds:** approximated from the path bounds.

Characters are placed along the path using arc-length parameterization:
the path is flattened to a polyline, cumulative arc lengths computed, and
each character positioned at the appropriate offset with its baseline
tangent to the curve.

---

### Group

SVG `<g>`. A container for other elements.

```
Group
  children:   [Element, ...]     ordered back-to-front
  opacity:    float
  transform:  Transform?
  locked:     bool
```

Groups allow elements to be transformed, selected, and manipulated as a
unit. The Selection tool selects entire groups; the Group Selection and
Direct Selection tools reach inside groups.

**Control points:** 4 -- bounding box corners of the combined children.

**Bounds:** union of all children's bounding boxes.

---

## Presentation Types

### Color

RGBA color with each component in `[0.0, 1.0]`:

```
Color
  r, g, b:  float     red, green, blue
  a:        float     alpha (default 1.0, fully opaque)
```

### Fill

A fill style, or nil for no fill (`fill="none"` in SVG):

```
Fill
  color:  Color
```

### Stroke

Stroke styling attributes:

```
Stroke
  color:     Color
  width:     float         line width in points (default 1.0)
  linecap:   LineCap       butt | round | square (default butt)
  linejoin:  LineJoin      miter | round | bevel (default miter)
```

### Transform

A 2D affine transformation matrix `[a b c d e f]` representing:

```
| a  c  e |
| b  d  f |
| 0  0  1 |
```

Default is the identity matrix `[1 0 0 1 0 0]`.

Convenience constructors:

| Constructor | Matrix |
|-------------|--------|
| `translate(tx, ty)` | `[1 0 0 1 tx ty]` |
| `scale(sx, sy)` | `[sx 0 0 sy 0 0]` |
| `rotate(angle_deg)` | `[cos sin -sin cos 0 0]` |

---

## Path Commands

Path elements and TextPath elements store their shape as a sequence of
SVG path commands. Each command corresponds to an SVG path data letter:

| Command | SVG | Parameters | Description |
|---------|-----|------------|-------------|
| `MoveTo` | M | `x, y` | Move the current point (starts a new subpath) |
| `LineTo` | L | `x, y` | Draw a straight line to the point |
| `CurveTo` | C | `x1, y1, x2, y2, x, y` | Cubic Bezier curve with two control points |
| `SmoothCurveTo` | S | `x2, y2, x, y` | Cubic Bezier with first control point reflected from previous curve |
| `QuadTo` | Q | `x1, y1, x, y` | Quadratic Bezier curve with one control point |
| `SmoothQuadTo` | T | `x, y` | Quadratic Bezier with control point reflected from previous curve |
| `ArcTo` | A | `rx, ry, x_rotation, large_arc, sweep, x, y` | Elliptical arc |
| `ClosePath` | Z | (none) | Close the current subpath (line back to last MoveTo) |

### Cubic Bezier (CurveTo)

A cubic Bezier curve from the current point to `(x, y)` with control points
`(x1, y1)` and `(x2, y2)`:

```
B(t) = (1-t)^3 * P0 + 3(1-t)^2*t * P1 + 3(1-t)*t^2 * P2 + t^3 * P3
```

where P0 is the current point, P1 = `(x1,y1)`, P2 = `(x2,y2)`, P3 = `(x,y)`.

- `(x1, y1)` is the **outgoing handle** of the previous anchor
- `(x2, y2)` is the **incoming handle** of the destination anchor

### Smooth Bezier (SmoothCurveTo)

Same as CurveTo but the first control point is the reflection of the
previous curve's `(x2, y2)` through the current point. This ensures
G1 continuity (smooth join) between consecutive curves.

### Handle manipulation

Bezier handles can be moved independently via `move_path_handle(path, anchor_idx, handle_type, dx, dy)` where `handle_type` is `"in"` (incoming) or
`"out"` (outgoing). Moving one handle automatically rotates the opposite
handle to maintain collinearity while preserving its original distance from
the anchor (smooth constraint).

---

## Control Points

Control points are the draggable handles that define an element's geometry.
Each element type exposes a fixed number of CPs:

| Element | CP count | Positions |
|---------|----------|-----------|
| Line | 2 | Start, end |
| Rect | 4 | Corners: TL, TR, BR, BL |
| Circle | 4 | Cardinal: top, right, bottom, left |
| Ellipse | 4 | Cardinal: top, right, bottom, left |
| Polyline | N | One per vertex |
| Polygon | N | One per vertex |
| Path | N | One per anchor point (non-ClosePath command) |
| Text | 4 | Bounding box corners |
| TextPath | N | One per anchor point in the path |
| Group | 4 | Bounding box corners |

Functions:

- `control_point_count(elem)` -- number of CPs
- `control_points(elem)` -- list of `(x, y)` positions
- `move_control_points(elem, kind, dx, dy)` -- return a new element with the CPs covered by `kind` translated. `SelectionKind::All` translates the primitive in place; `Partial(s)` may convert Rect/Circle/Ellipse to a Polygon.

When all CPs of a shape are moved together, the element translates rigidly.
When a subset of CPs are moved on shapes like Rect or Circle, the element
reshapes (a Rect may convert to a Polygon; a Circle recomputes its radius).

---

## Bounds Computation

Every element computes its axis-aligned bounding box as `(x, y, width, height)`.

**Stroke inflation:** if the element has a stroke, the bounding box is
expanded by `stroke.width / 2` on all four sides.

**Bezier bounds:** Path elements compute tight bounds by finding curve
extrema. For a cubic Bezier, the derivative is a quadratic
`at^2 + bt + c` with:

```
a = -3*P0 + 9*P1 - 9*P2 + 3*P3
b =  6*P0 - 12*P1 + 6*P2
c = -3*P0 + 3*P1
```

Roots of this quadratic in `(0, 1)` give the parameter values where the
curve reaches local extrema. Evaluating the curve at these t-values plus
the endpoints gives the tight axis-aligned bounds.

**Group/Layer bounds:** union of all children's bounding boxes.

**Text bounds:** area text uses its specified rectangle. Point text
measures the widest `\n`-separated line with the platform font
measurer (the same one the renderer and the in-place editor use), and
the height is `lines * font_size`.

---

## Path Geometry Utilities

These functions operate on path command sequences:

| Function | Description |
|----------|-------------|
| `flatten_path_commands(d)` | Convert curves to a polyline (20 segments per Bezier) |
| `path_point_at_offset(d, t)` | Point at fraction t along the path (arc-length parameterized) |
| `path_closest_offset(d, px, py)` | Offset of the closest point on the path to a given point |
| `path_distance_to_point(d, px, py)` | Minimum distance from a point to the path curve |
| `path_handle_positions(d, anchor_idx)` | Return (in_handle, out_handle) positions for an anchor |

Flattening samples Bezier curves at a fixed step count (`FLATTEN_STEPS = 20`)
and produces a list of `(x, y)` points. Arc-length queries compute
cumulative segment lengths over the flattened polyline.
