# Pencil tool

The Pencil tool produces a smoothed Bezier path from a
freehand drag. Mouse movement is sampled into a point buffer
during the drag; on release the samples are fit to a cubic
Bezier spline via the Schneider curve-fit algorithm.

**Shortcut:** N.

**Cursor:** crosshair.

## Gestures

- **Press** — snapshots the document, clears the "pencil" point
  buffer, and pushes the press point. Enters `drawing` mode.
- **Drag** — pushes each intermediate position into the buffer.
- **Release** — pushes the final position, then runs
  `fit_curve(points, FIT_ERROR)` and appends the resulting
  path to the document. FIT_ERROR is 4.0 by default.
- **Escape** — cancels the drag, clearing the buffer without
  committing.

## Fit-error parameter

`FIT_ERROR` is the maximum allowed RMS distance (in pt) between
the fitted curve and the sampled polyline. Smaller values
produce more segments that track the user's wiggles closer;
larger values produce fewer, smoother segments. 4.0 matches
the common default for vector-illustration pencil tools.

Promoting `FIT_ERROR` to a workspace state key or per-call
dialog argument would let the user tune smoothness. Today it's
hard-coded in the YAML's `doc.add_path_from_buffer` call.

## Zero-length clicks

A plain click (press and release at the same point) pushes two
identical points into the buffer. `fit_curve` on two identical
points still emits one degenerate CurveTo — the path exists
but is zero-length. The Pencil tool does *not* suppress this
(matching native Pencil), unlike the Line / Rect / etc. tools
which filter out stray clicks.

## Fill and stroke

The committed Path picks up `state.stroke_color` and no fill
(pencil strokes are open paths where a fill would generally
not apply). A Path with `fill=None` and `stroke=<default>` is
what the YAML's `add_path_from_buffer` produces when no
explicit `fill:` / `stroke:` fields are set.

## Overlay

A thin black polyline tracking the raw drag — the final
committed path is the smoothed `fit_curve` output, not this
preview. Render type: `buffer_polyline`. Style:
`stroke: black; stroke-width: 1;`.

## Known gaps

- **Alt-to-close and edit-existing-path mode** — Paintbrush
  specifies both gestures with time-disjoint Alt semantics (Alt at
  press triggers edit, Alt at release closes the new path). See
  `PAINTBRUSH_TOOL.md` §§ Gestures / Edit gesture / Overlay —
  port that design here when the Pencil counterparts land. The
  close-hint overlay and edit-splice algorithm are shared;
  Pencil's variants differ only in that there is no
  `jas:stroke-brush` to preserve.
- **Smoothness panel** — peer tools expose FIT_ERROR and related
  knobs in a "Pencil Tool Options" dialog; no equivalent panel
  exists here yet. Paintbrush defines the `tool_options_dialog`
  field pattern in `PAINTBRUSH_TOOL.md` § Tool options if a
  Pencil options dialog is added.

## Related tools

- **Smooth tool** re-fits segments of an existing selected path
  with a larger error tolerance. Useful after a jittery pencil
  drag leaves too many segments.
- **Pen tool** is the click-to-place alternative when the user
  wants explicit control over every anchor.
