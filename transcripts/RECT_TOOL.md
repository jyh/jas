# Rectangle tools

Two tools draw axis-aligned rectangles: the plain **Rectangle**
tool and the **Rounded Rectangle** tool. They share a state
machine, a preview overlay shape, and a zero-size-suppression
rule; the only difference is whether the committed element has
non-zero `rx` / `ry` corner radii.

| Tool              | Shortcut | Commits                   |
|-------------------|----------|---------------------------|
| Rectangle         | M        | Rect with rx = ry = 0     |
| Rounded Rectangle | E        | Rect with rx = ry = 10 pt |

**Cursor:** crosshair for both.

## Gestures

- **Press** — records the first corner (`start_x`, `start_y`)
  and seeds the current corner (`cur_x`, `cur_y`) to the same
  point. Enters `drawing` mode.
- **Drag** — updates the current corner. The preview rectangle
  follows the cursor and normalizes negative drags (dragging
  up-and-left works fine).
- **Release** — if the rectangle is at least 1 pt in both
  dimensions, snapshots the document and appends a new Rect
  element using the model's default fill and stroke. Shorter
  "stray click" gestures are suppressed; no invisible zero-size
  rect is deposited.
- **Escape** — returns to idle without creating anything.

## Default corner radius

The rounded-rect tool hard-codes `rx = ry = 10 pt`. Editing a
rounded rect after commit happens through the Selection / Partial
Selection tools and the general element-attribute surface — the
tool itself has no radius control. A future revision can promote
`10` to a workspace-level state key if UX calls for a sized-radius
combo.

## Overlay

A dashed preview rectangle tracking the current drag: 1 px black
stroke at 50 % opacity, 4/4 dash, no fill. Style:
`stroke: rgba(0,0,0,0.5); stroke-width: 1;
stroke-dasharray: 4 4; fill: none;`. The rounded-rect tool's
overlay includes `rx: 10, ry: 10` so the preview shows rounded
corners too.

## Fill and stroke

Rect elements pick up `model.default_fill` and
`model.default_stroke` at commit time. The drawing tools don't
override either — they rely on the Color / Stroke panels (or
other state-level defaults) being set by the user before drawing.

## Known gaps

- **Shift-constrained square** — Illustrator's rect tool
  constrains to a square when Shift is held. Not currently
  wired; a future revision can add a square-snap primitive.
- **Alt-from-center draw** — Illustrator's rect tool draws
  centered on the press point when Alt is held. Also not wired.
