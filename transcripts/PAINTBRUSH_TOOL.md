# Paintbrush tool

The Paintbrush tool draws a freehand Bezier path with the active
brush applied. Mouse movement is sampled into a point buffer during
the drag; on release the samples are fit to a cubic Bezier spline,
and the resulting path is committed with `jas:stroke-brush` set to
`state.stroke_brush`.

When `state.stroke_brush == null`, the tool degrades to a plain
freehand path tool driven by the native stroke values — equivalent to
the Pencil tool with no brush applied.

**Status:** stub. Full design is a follow-up; the panel spec
(`BRUSHES.md`) is authored first.

**Shortcut:** B.

**Cursor:** crosshair.

## Gestures

- **Press** — snapshots the document, clears the paintbrush point
  buffer, pushes the press point. Enters `drawing` mode.
- **Drag** — pushes each intermediate position into the buffer.
- **Release** — pushes the final position, runs
  `fit_curve(points, FIT_ERROR)`, appends the resulting path to the
  document with `jas:stroke-brush = state.stroke_brush` (or no
  attribute when null).
- **Option / Alt + drag near a selected path** — rewrites the
  nearest sub-segment of the selected path, reusing Pencil's
  edit-existing gesture and the same proximity threshold. The brush
  reference of the modified path is preserved.
- **Escape** — cancels the drag, clearing the buffer without
  committing.

## Tool options

Double-click the tool icon → Paintbrush Tool Options dialog. Stub
list:

- `paintbrush_fidelity` — pixels; curve-fit tolerance. Lower =
  follows wiggles closer.
- `paintbrush_smoothness` — percent; post-fit smoothing pass.
- `paintbrush_keep_selected` — boolean; if on, the new path becomes
  the canvas selection after commit.
- `paintbrush_edit_selected_paths` — boolean; if on, Option/Alt-drag
  near a selected path rewrites it (per Gestures).
- `paintbrush_within_distance` — pixels; proximity threshold for the
  rewrite gesture.

Full dialog spec deferred to a follow-up.

## Fill and stroke

The committed Path picks up `state.stroke_color` and no fill.
`jas:stroke-brush` is written when `state.stroke_brush` is non-null.

## Overlay

A thin polyline tracking the raw drag, in `state.stroke_color`. The
final committed path is the smoothed `fit_curve` output rendered with
the active brush, not this preview.

## YAML tool runtime fit

This tool belongs under the YamlTool runtime (per the existing
tool-runtime migration in all four native apps). Handler YAML lives
at `workspace/tools/paintbrush.yaml`. State machine, gesture set, and
overlay shape are declared in YAML; the brush-aware commit step
references the same `add_path_from_buffer` effect used by Pencil,
extended to forward `state.stroke_brush` into the new path's
attributes.

## Known gaps

This entire doc is a stub. Items to flesh out before implementation:

- Final FIT_ERROR / smoothness defaults and how they map to the two
  user-facing options (`fidelity`, `smoothness`).
- Pressure handling — variation modes on the active brush that
  consume pressure (Calligraphic `pressure` mode) need stylus input
  during the drag, not just at commit.
- Interaction when the active brush is Bristle — the brush is
  rendered with overlapping strokes per pen-down event; do successive
  Paintbrush strokes union into one element or stay separate?
- Closing gesture — should holding Alt at release close the path?
  Open question; matches the Pencil-tool open question.

## Related tools

- **Brushes panel** (`BRUSHES.md`) — sets `state.stroke_brush` and
  defines the per-brush rendering rules this tool consumes.
- **Blob Brush** (`BLOB_BRUSH_TOOL.md`) — paints filled regions
  rather than strokes; uses the active brush's size / shape only.
- **Pencil** (`PENCIL_TOOL.md`) — equivalent gesture set without
  brush coupling.
- **Smooth** (`SMOOTH_TOOL.md`) — re-fits an existing path with a
  larger error tolerance; useful after a jittery Paintbrush drag.
