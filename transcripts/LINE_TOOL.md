# Line tool

The Line tool draws a straight line segment between two points.
Press to anchor the start point, drag to position the end point,
release to commit a new `Line` element to the document.

**Shortcut:** `\` (some layouts map it to `/`; workspace YAML is
authoritative).

**Cursor:** crosshair.

## Gestures

- **Press** — records the start point (`start_x`, `start_y`) and
  seeds the overlay preview.
- **Drag** — updates the current end point. The overlay follows
  the cursor.
- **Release** — if the line is longer than 2 pt (hypot guard),
  snapshots the document and appends a Line element with the
  model's current default stroke. Shorter "stray click" gestures
  are suppressed; no invisible zero-length line is deposited.
- **Escape** — cancels the in-progress drag without creating
  anything.

## Fill and stroke

Line elements carry only a stroke, not a fill. On commit the
new element picks up the model's `default_stroke` as it stood
at release time. The line tool never touches `default_fill`.

## Overlay

A thin dashed preview from `(start_x, start_y)` to the cursor.
Style: `stroke: rgba(0,0,0,0.5); stroke-width: 1;
stroke-dasharray: 4 4; fill: none;`. Renders only while
`mode == "drawing"`.

## Known gaps

- **Shift-constrained angles** — Illustrator's Line tool
  snaps to 45° increments when Shift is held. The workspace YAML
  currently ignores Shift; a future revision can add the
  `constrain_angle` primitive pass here.
- **Arrowheads** — the native Line element supports start/end
  arrowheads, but the tool always creates plain-stroke lines.
  Arrowhead-on-create is out of scope for the drawing tool
  today and stays a Stroke-panel concern.
