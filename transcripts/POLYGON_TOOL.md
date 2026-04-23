# Polygon tool

The Polygon tool draws a regular N-gon whose first edge runs
from the press point to the release point. The polygon has a
fixed number of sides (default 5, controlled by the workspace
`POLYGON_SIDES` constant).

**Shortcut:** none by default; invoked from the toolbar.

**Cursor:** crosshair.

## Gestures

- **Press** — records `(start_x, start_y)` as the first vertex.
- **Drag** — the preview shows the polygon that would be
  committed: the first edge runs from the press point to the
  current cursor, and the remaining N–2 vertices are placed
  counterclockwise on the circumscribed circle.
- **Release** — if the edge is non-degenerate (start ≠ end),
  snapshots the document and appends a Polygon element with the
  computed vertex list and the model's default fill and stroke.
  Zero-length drags produce nothing.
- **Escape** — cancels the in-progress drag.

## Vertex geometry

The shared `regular_polygon_points` kernel (see geometry/path_ops
in each app) computes the N vertices given `(x1, y1)`, `(x2, y2)`,
and a side count. The computation:

1. The first edge runs from `(x1, y1)` to `(x2, y2)`.
2. The centroid sits on the perpendicular bisector at distance
   `s / (2 * tan(π/n))` where `s` is the edge length.
3. The remaining vertices are placed every `2π/n` radians around
   the centroid, starting from the first-edge angle.

Rotating the polygon by 180° is achieved by dragging in the
opposite direction — the tool has no explicit rotation handle.

## Side count

`POLYGON_SIDES = 5` is the workspace default. The Polygon tool
YAML threads this through `doc.add_element` as the `sides` field.
Changing the side count today requires editing the workspace
constant — there is no panel control. A "Polygon options" dialog
(like Illustrator's double-click-the-toolbar-button modal) is a
reasonable follow-up.

## Overlay

A dashed preview polygon following the cursor. Style:
`stroke: rgba(0,0,0,0.5); stroke-width: 1;
stroke-dasharray: 4 4; fill: none;`. The preview uses the same
`regular_polygon_points` kernel as the commit path, so what you
see is exactly what you get.

## Known gaps

- **Shift-constrained horizontal first edge** — Illustrator
  constrains the first edge to 0/45/90° when Shift is held.
  Not currently wired.
- **Arrow-key side-count change during drag** — Illustrator
  increments / decrements the polygon side count with the Up
  / Down arrow keys mid-drag. Out of scope for the current
  tool; the workspace YAML has no plumbing for per-drag side
  adjustment.
