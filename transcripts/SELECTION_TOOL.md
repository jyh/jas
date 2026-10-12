# Selection tools

Three related tools manage which elements and parts of elements
are selected. They share a cursor, a visual vocabulary (marquee,
selection bounds, control points), and a set of mouse gestures;
what differs is how hit-testing descends into the document and
what granularity of selection a marquee produces.

| Tool                | Shortcut | Hit-test                    | Marquee granularity       |
|---------------------|----------|-----------------------------|---------------------------|
| Selection           | V        | Top-level layer children, painted geometry | Whole elements |
| Interior Selection  | —        | Recurses into groups, painted geometry     | Whole elements |
| Partial Selection   | A        | Handles + control points    | Control points            |

## Hit test: painted geometry

A click hits what is painted, not a bounding box. This is the rule
for `hit_test` (Selection, Magic Wand, Eyedropper) and `hit_test_deep`
(Interior Selection). In the owner's words: *"the hit is on painted
geometry, not bounding box. In normal mode, this includes fills, but
for example, clicking in the middle of an unfilled rectangle will not
select it. In outline display mode, there are no displayed fills, only
strokes and anchor points can be selected."*

The point is in document coordinates. Elements are tried topmost
first: layers in reverse order, and the children of each layer or
group in reverse order. An element that is locked, or whose effective
visibility (the minimum of its own and its ancestors') is invisible,
is never hit, and neither is anything inside it.

- **Transforms.** Each element's own transform, and every ancestor's,
  places its geometry. The point is mapped back through them before
  the tests below, so the tolerance is measured in the element's own
  coordinates.
- **Group, Layer.** Hit when any child is hit. The group's empty
  interior is not painted, so a click there passes through to what
  lies below.
- **Fill (preview mode only).** An element with a fill or a fill
  gradient is hit when the point is inside its filled area: a rect,
  circle, ellipse or polygon by its interior; a path or polyline as if
  each subpath were closed, using the path's fill rule (nonzero by
  default; even-odd leaves holes). A line has no fill.
- **Stroke (preview mode).** An element with a stroke is hit when the point is within `HIT_TOLERANCE` of the
  painted band: within `width / 2` of the outline for a centred
  stroke, within `width` for an inside or outside stroke.
- **Outline mode.** No fills and no stroke widths are displayed, so
  only the outline itself is hit: within `HIT_TOLERANCE` of it, paint
  or no paint. Anchor points lie on the outline, so they are covered.
- **Text, text on a path.** Hit by their bounding box in both modes;
  text renders as preview even in outline mode.
- **Compound shape.** Its evaluated rings stand in for its outline,
  with the compound's own fill and stroke, even-odd.
- **Reference, recorded and generated elements.** Hit by their
  bounding box. These need a resolver to know their geometry, and the
  hit test does not carry one.

`HIT_TOLERANCE` is 3 document units. Curves are flattened with the
path flattener's 20 steps per segment; ellipses and circles are tested
analytically for the fill and as a 64-sided polygon for the outline.

**Known limits** (deliberate, so a reader does not fill them in): the
rounded corners of a rect are tested as square corners; dashes, caps,
joins, arrowheads and variable-width profiles do not change the
stroke band; the tolerance is in document units, so it looks smaller
on screen when zoomed out.

## Selection tool

The default tool for working with whole shapes. Click an element
to select it, drag an empty-space rectangle to marquee-select,
drag a selected element to translate it, Alt+drag to copy and
translate.

**Interactions:**

- **Click on element** — replaces the selection with just that
  element. Shift+click toggles the element in and out of the
  current selection.
- **Click on empty space** — clears the selection (unless Shift
  is held).
- **Drag from empty space** — rubber-band marquee that selects
  any element whose bounding box intersects the rectangle on
  release.
- **Drag on selected element** — translates the selection. The
  document is snapshotted once on press so the whole drag is a
  single undoable step.
- **Alt+drag on selected element** — duplicates the selection
  and translates the duplicates. The originals stay put; the
  new copies become the selection so subsequent Alt+drag gestures
  would duplicate the copies.
- **Escape** — cancels an in-progress marquee or drag.

**State:** `idle` · `marquee` · `drag_move`. The Alt-at-press
modifier is captured when the drag starts and frozen for the rest
of the gesture, so releasing Alt mid-drag doesn't flip copy ↔ move.

**Overlay:** a dashed blue rectangle (`stroke: #4a90d9`, 4/4
dash, 8% fill) during marquee mode.

## Interior Selection tool

Same gesture set as Selection, but hit-testing *recurses into
groups* so a click lands on the leaf element under the cursor
even if it's inside a Group. A marquee release runs
`partial_select_rect` — the same rectangle that Selection
treats as "whole-element" selects individual control points
here, matching the behavior of the native Interior Selection
tool in the incumbent.

Useful for editing one object inside a nested group without
having to ungroup first.

## Partial Selection tool (Direct Selection)

Hits Bezier handles and individual control points rather than
whole elements. This is the tool for fine-tuning a shape after
it's been drawn.

**Hit-test priority on mousedown:**

1. **Bezier handle on a selected Path** — latches the handle for
   dragging. Moves that handle and reflects the opposite handle
   through the anchor (smooth-symmetric mirror), keeping the
   opposite handle's own length so the anchor stays a smooth point.
2. **Control point on any unlocked element** — makes the CP the
   selection. Plain click replaces, Shift+click toggles.
3. **Empty space** — starts a marquee that selects whatever CPs
   fall inside on release. An empty-ish marquee (< 1px square)
   without Shift clears the selection.

**Drag behavior:**

- Past the `DRAG_THRESHOLD` (4 px) from press, the press becomes
  a move. The document is snapshotted once and subsequent
  movements translate just the selected control points.
- Alt+drag mirrors Selection's Alt+drag: copies the selection on
  the first move, translates the copies on every subsequent
  move.
- Dragging a latched handle reflects the OPPOSITE handle through
  the anchor (smooth-symmetric mirror — `move_path_handle`): the
  opposite handle stays collinear through the anchor and keeps its
  own length, so the anchor remains a smooth point. Threshold for
  a handle drag is 0.5 px (tighter than the CP-move threshold).

**Overlay:** always on while the tool is active. Shows anchor
squares and in/out handle bars on every selected Path, plus the
dashed marquee rect when actively rubber-banding.

## Relationship to the Anchor Point tools

The Anchor Point tool (see `ANCHOR_POINT_TOOLS.md`) *converts*
between smooth and corner anchors and adjusts individual handles
independently. Partial Selection *moves* existing anchors and
handles along their current vector. The two tools are
complementary.
