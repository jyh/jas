# Selection tools

Three related tools manage which elements and parts of elements
are selected. They share a cursor, a visual vocabulary (marquee,
selection bounds, control points), and a set of mouse gestures;
what differs is how hit-testing descends into the document and
what granularity of selection a marquee produces.

| Tool                | Shortcut | Hit-test                    | Marquee granularity       |
|---------------------|----------|-----------------------------|---------------------------|
| Selection           | V        | Top-level layer children    | Whole elements            |
| Interior Selection  | —        | Recurses into groups        | Whole elements            |
| Partial Selection   | A        | Handles + control points    | Control points            |

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
tool in Illustrator.

Useful for editing one object inside a nested group without
having to ungroup first.

## Partial Selection tool (Direct Selection)

Hits Bezier handles and individual control points rather than
whole elements. This is the tool for fine-tuning a shape after
it's been drawn.

**Hit-test priority on mousedown:**

1. **Bezier handle on a selected Path** — latches the handle for
   dragging. Moves that handle independently of its opposite
   handle (the "cusp" operation).
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
- Dragging a latched handle updates only that side's tangent —
  neither mirror nor opposite adjustments. Threshold for a
  handle drag is 0.5 px (tighter than the CP-move threshold).

**Overlay:** always on while the tool is active. Shows anchor
squares and in/out handle bars on every selected Path, plus the
dashed marquee rect when actively rubber-banding.

## Relationship to the Anchor Point tools

The Anchor Point tool (see `ANCHOR_POINT_TOOLS.md`) *converts*
between smooth and corner anchors and adjusts individual handles
independently. Partial Selection *moves* existing anchors and
handles along their current vector. The two tools are
complementary.
