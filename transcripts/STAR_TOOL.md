# Star tool

The Star tool draws an N-pointed star inscribed in the
axis-aligned bounding box defined by the press point and the
release point. The star has `points` outer vertices and
`points` inner vertices alternating around a common center;
default point count is 5, the first outer vertex sits at
top-center.

**Shortcut:** none by default; invoked from the toolbar.

**Cursor:** crosshair.

## Gestures

- **Press** — records the first bounding-box corner
  `(start_x, start_y)` and seeds the current corner.
- **Drag** — the preview shows a star inscribed in the
  current bounding box. The box normalizes negative drags.
- **Release** — if the bounding box has non-zero dimensions,
  snapshots the document and appends a Polygon element whose
  points are the computed star vertices (outer/inner
  alternating).
- **Escape** — cancels the in-progress drag.

## Vertex geometry

The shared `star_points` kernel computes the `2 * points`
vertices:

- Outer vertices sit on the bounding-box-inscribed ellipse at
  radius `(rx_outer, ry_outer) = box / 2`.
- Inner vertices sit on the inner ellipse at radius
  `(rx_inner, ry_inner) = rx_outer * STAR_INNER_RATIO`, where
  `STAR_INNER_RATIO = 0.4` (the shared constant in every
  port's geometry module).
- Angles step by `π / points` starting from `-π/2` (top-center).

## Star sharpness

`STAR_INNER_RATIO` controls how "pointy" the star looks — smaller
values produce thinner spikes; larger values produce a softer,
star-fruit profile. The constant lives in the geometry kernel
module in each app and is not user-controllable via the tool
today. Promoting it to a workspace state key (`state.star_inner_ratio`?)
or a per-star attribute on the committed Polygon would be a
reasonable follow-up.

## Default point count

Hard-coded at 5 in the YAML (`points: 5` in `doc.add_element`).
Changing the point count today requires editing the workspace
constant — Illustrator's toolbar has a modal dialog for this
that's out of scope for the current tool.

## Overlay

A dashed preview star tracking the cursor. Style:
`stroke: rgba(0,0,0,0.5); stroke-width: 1;
stroke-dasharray: 4 4; fill: none;`. The preview uses the same
`star_points` kernel as the commit path.

## Known gaps

- **Shift-constrained upright orientation** — Illustrator keeps
  the star upright (first outer vertex at top-center)
  regardless of drag direction when Shift is held; the current
  tool always inscribes the star in the axis-aligned bbox so
  dragging in unusual directions just grows / flips the bbox,
  not rotates the star.
- **Arrow-key point-count / inner-radius tuning** — Illustrator
  adjusts the star's point count and inner-to-outer ratio with
  arrow keys and Ctrl during the drag. Out of scope today.
