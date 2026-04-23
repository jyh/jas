# Ellipse tool

The Ellipse tool drags out an ellipse inscribed in the
axis-aligned bounding box defined by the press point and the
release point. Behaviorally identical to the Rectangle tool,
but commits an Ellipse element.

**Shortcut:** L.

**Cursor:** crosshair.

**Status:** specified (`workspace/tools/ellipse.yaml`) but not
yet wired into the Toolbar enum in any of the 4 native apps.
Adding an `ELLIPSE` enum variant and a toolbar icon is the
pending work.

## Gestures

- **Press** — records `(start_x, start_y)`.
- **Drag** — the overlay previews the ellipse inscribed in the
  current bounding box.
- **Release** — if the bounding box has non-zero dimensions
  (> 1 pt threshold), snapshots the document and appends an
  Ellipse element:
  - `cx = (start_x + end_x) / 2`
  - `cy = (start_y + end_y) / 2`
  - `rx = |end_x − start_x| / 2`
  - `ry = |end_y − start_y| / 2`
- **Escape** — cancels the in-progress drag.

## Fill and stroke

Ellipse elements pick up `model.default_fill` and
`model.default_stroke` at commit time.

## Overlay

A dashed preview ellipse tracking the cursor. Style mirrors
Rect: 1 px black stroke at 50 % opacity, 4/4 dash, no fill.
Requires an `ellipse` overlay render type that the workspace
dispatcher and native overlay renderers do not currently
support — that's the other half of the "wire the Ellipse
tool" work.

## Known gaps

- **Shift-constrained circle** — Illustrator's ellipse tool
  constrains to a circle when Shift is held. Not wired.
- **Alt-from-center draw** — Illustrator draws centered on the
  press point when Alt is held. Not wired.
- **No `ellipse` overlay renderer** — the rect/line/polygon/
  star/buffer/pen/partial-selection overlay registry in
  `yaml_tool.py` (and equivalents in Rust/Swift/OCaml) doesn't
  include an ellipse case. Adding it is straightforward using
  the existing Cairo / CG ellipse primitives.
