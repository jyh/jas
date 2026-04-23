# Pen tool

The Pen tool constructs an open or closed Bezier path by
placing anchors one click at a time. Click-to-place drops a
corner anchor; click-and-drag drops a smooth anchor and lets
the user set the out-handle interactively. Clicking near the
first anchor closes the path; pressing Escape, Enter, or
double-clicking commits the path open.

**Shortcut:** P.

**Cursor:** crosshair.

## State machine

- **idle** — no anchors placed; next mousedown starts a new path
  by pushing the first anchor and entering `dragging`.
- **placing** — ≥ 1 anchor placed; the preview curve stretches
  from the last anchor to the cursor. Next mousedown drops the
  next anchor.
- **dragging** — the user has mousedown-ed to place an anchor
  and is currently dragging to set its out-handle. Mouseup
  returns to `placing`.

## Gestures

- **Click** (press + release near same point) — adds a corner
  anchor at the cursor.
- **Click and drag** — adds a smooth anchor at the press
  position; the drag sets the out-handle. The in-handle of the
  smooth anchor is mirrored through the anchor position, giving
  tangent-continuous curves.
- **Click near the first anchor** (once the buffer has ≥ 2
  anchors, within 8 px of the first) — closes the path: a
  final CurveTo back to the first anchor plus a ClosePath, then
  clears the buffer and returns to idle.
- **Escape / Enter** — commits the current in-progress path as
  open and returns to idle. Requires ≥ 2 anchors or the path
  is discarded.
- **Double-click** — pops the just-placed anchor (the second
  mousedown of the double-click already placed one) and commits
  the remainder as an open path.
- **Tool deactivation** (switching to another tool) — auto-commits
  any in-progress path before leaving.

## Anchor data

Each anchor carries:

- `(x, y)` — anchor position.
- `(hx_in, hy_in)` — incoming control handle.
- `(hx_out, hy_out)` — outgoing control handle.
- `smooth` flag — true if the out-handle was explicitly dragged;
  determines whether the in-handle is mirrored through the
  anchor on subsequent edits.

On `anchor.push`, all three handle pairs collapse to the anchor
position (corner). On `anchor.set_last_out`, the out-handle is
set explicitly and the in-handle is mirrored through the anchor
(2x − hx, 2y − hy), marking the anchor smooth.

Anchors live in the thread-local "pen" anchor buffer (see
`anchor_buffers` in every port) keyed by buffer name. The buffer
is created on the first mousedown and cleared on commit / cancel.

## Commit path geometry

On commit, the anchor buffer is walked pairwise to emit path
commands:

- First command: `MoveTo(anchors[0].x, anchors[0].y)`.
- For each adjacent pair `(prev, curr)`:
  `CurveTo(prev.hx_out, prev.hy_out,
          curr.hx_in,  curr.hy_in,
          curr.x,       curr.y)`.
- If closing: a final `CurveTo` back to `anchors[0]` plus
  `ClosePath`.

Fill and stroke come from `model.default_fill` /
`model.default_stroke` at commit time.

## Overlay

The `pen_overlay` renderer draws:

- The committed curve through all placed anchors (MoveTo + the
  same CurveTo chain that will land on commit).
- A small filled dot at each anchor position.
- A handle bar (line from anchor to out-handle, plus a dot at
  the out-handle) for the most recent smooth anchor.
- A dashed preview curve from the last anchor to the current
  cursor while in `placing` mode.
- An orange close-hit indicator circle on the first anchor
  when the cursor is within `close_radius` (8 px) and the
  buffer has ≥ 2 anchors.

Style: 1 px blue (`rgb(0, 120, 215)`) for the main geometry,
dashed for the preview curve.

## Known gaps

- **Alt-drag to break handles** — Illustrator's Pen tool uses
  Alt to break the in/out mirror on a smooth anchor during
  placement. The current Pen tool doesn't wire Alt; the
  follow-up Anchor Point tool handles the corner/smooth toggle.
- **Shift-constrained 45° segments** — Illustrator constrains
  path segments to multiples of 45° when Shift is held. Not
  wired.
- **Rubber-banding a previous-anchor handle** — Illustrator
  allows dragging a previously-placed anchor's handle during
  the same drawing session (via the tool's click-back-on-anchor
  gesture). Not wired today.

## Related tools

- **Anchor Point tool** converts between corner and smooth
  anchors after the path is committed.
- **Add Anchor Point / Delete Anchor Point** modify anchor
  count on committed paths.
- **Pencil / Smooth** are freehand alternatives for when
  click-based placement isn't the right mental model.
