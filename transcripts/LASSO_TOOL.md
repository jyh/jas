# Lasso tool

The Lasso tool selects elements whose bounding boxes intersect
a freehand polygon. Drag to accumulate the polygon vertices;
on release, every element inside (or crossing) the polygon
becomes the selection.

**Shortcut:** Q.

**Cursor:** crosshair.

## Gestures

- **Press** — clears the "lasso" point buffer, pushes the
  press point, captures the Shift modifier state. Enters
  `drawing` mode.
- **Drag** — pushes each intermediate position. The overlay
  draws the growing polygon.
- **Release** —
  - If the buffer has ≥ 3 points, snapshots the document and
    calls `doc.select_polygon_from_buffer` with the `additive`
    flag set from the captured Shift state. Additive unions
    with the existing selection; non-additive replaces it.
  - If the buffer has < 3 points (a click or tiny drag): if
    Shift was NOT held, clear the selection (click-in-empty
    semantics); if Shift was held, leave the selection
    unchanged.
- **Escape** — cancels the drag and clears the buffer without
  selecting anything.

## Vertex filtering

The raw drag can produce dense buffers with hundreds of nearby
vertices. The algorithm doesn't filter duplicates — downstream
`select_polygon` hit-testing handles dense polygons fine and
the buffer is cleared on every release, so memory is bounded.
If profiling shows allocation pressure, a minimum-distance
filter (say 1 pt between consecutive samples) is the obvious
optimization.

## Hit-test semantics

`Controller.select_polygon` walks the document's top-level
layer children (not into Groups) and tests each element's
bounding box against the polygon via standard polygon-AABB
intersection. An element is selected if any corner of its
bounding box is inside the polygon OR the polygon and the
element's bounding box have any segment-segment intersection.

This matches Illustrator's Lasso behavior: the polygon need not
enclose the element entirely; crossing any part of the bounding
box is enough.

## Overlay

Render type: `buffer_polygon`. Draws the accumulated polygon
(filled outline) with:
`stroke: rgba(0,120,215,0.8); stroke-width: 1;
fill: rgba(0,120,215,0.1);`. The closed polygon reads like the
marquee rectangle Selection draws, just following a freehand
path instead of an axis-aligned box.

## Known gaps

- **Interior-selection variant** — there's no "Lasso interior"
  counterpart that marquee-selects individual control points.
  Partial Selection's rectangle marquee is the closest
  equivalent today.
- **Sub-Lasso inside groups** — the lasso doesn't recurse into
  Groups. An "Interior Lasso" that does would parallel the
  relationship between Selection and Interior Selection.

## Related tools

- **Selection / Interior Selection** — axis-aligned-rectangle
  alternatives. Easier to aim at dense layouts, worse for
  selecting oddly-shaped subsets.
- **Magic Wand** (see `MAGIC_WAND.md`) — similarity-based
  selection expansion, starting from an already-selected seed.
