# Blob Brush tool

The Blob Brush tool paints filled regions by sweeping the active
brush's tip shape along a freehand drag, then unioning the swept
region with any existing Blob Brush shape it overlaps. The result is
a single closed filled element — *not* a stroked path; the tool does
not write `jas:stroke-brush` on its output.

When the active brush is Calligraphic, the swept tip is the brush's
oval. For other brush types, the brush degrades to its size /
bounding-shape only — colorization, artwork, and pattern tiles are
not consulted (a Blob Brush stroke is a solid fill).

The tool is always enabled regardless of brush type, but a hint label
on the cursor flags the degradation when the active brush is not
Calligraphic.

**Status:** stub. Full design is a follow-up; the panel spec
(`BRUSHES.md`) is authored first.

**Shortcut:** Shift-B.

**Cursor:** filled-circle outline sized by the active brush's tip
diameter at the current canvas zoom.

## Gestures

- **Press** — snapshots the document, starts a new sweep buffer.
- **Drag** — sweeps the brush tip along the pointer path,
  accumulating the swept region.
- **Release** — closes the swept region. If the result overlaps an
  existing Blob Brush shape on the canvas (and the merge condition
  below holds), unions with that shape; otherwise commits as a new
  closed-path element.
- **Escape** — cancels the sweep, discarding the buffer.

## Merge condition

A new sweep merges with an existing element on the canvas iff:

- The element is a closed-path Blob Brush output (carries the
  `jas:tool-origin="blob_brush"` attribute), and
- The element's fill exactly equals `state.fill_color`, and
- (If `blob_brush_merge_with_selection_only` is on) the element is
  part of the current canvas selection.

Otherwise the sweep commits as a new independent element.

## Tool options

Double-click the tool icon → Blob Brush Tool Options dialog. Stub
list:

- `blob_brush_fidelity` — pixels; sweep-path smoothing tolerance.
- `blob_brush_smoothness` — percent; post-union smoothing pass on
  the resulting boundary.
- `blob_brush_size` — pt; tip diameter override (independent of any
  brush's `size` field, since Blob Brush ignores brush type).
- `blob_brush_angle` — degrees; tip orientation (Calligraphic-style).
- `blob_brush_roundness` — percent; tip aspect.
- `blob_brush_merge_with_selection_only` — boolean; if on, merges
  only with currently-selected Blob Brush elements.

The four shape parameters (`size`, `angle`, `roundness`, plus a
fourth shape parameter TBD) are populated from the active brush at
tool-select time when the brush is Calligraphic; otherwise the user
sets them directly in the options dialog.

Full dialog spec deferred to a follow-up.

## Boolean union at commit

The merge step uses each app's existing `algorithms/boolean` module
(referenced in `BOOLEAN.md`), running a `union` over the swept region
and the existing element's geometry. This dependency makes the tool
borderline-yamlable: the union itself is a runtime primitive, but the
state-machine wrapper is straightforward YAML.

## Fill and stroke

The committed element picks up `state.fill_color` and no stroke. The
`jas:tool-origin="blob_brush"` attribute is set to enable the merge
condition above.

## Overlay

A live preview of the accumulated swept region in
`state.fill_color`, semi-transparent, rendered above the canvas
during the drag.

## YAML tool runtime fit

Handler YAML lives at `workspace/tools/blob_brush.yaml`. The state
machine and overlay are declared in YAML; the union step calls into
the native `algorithms/boolean` module via an effect.

## Known gaps

This entire doc is a stub. Items to flesh out before implementation:

- The fourth tip-shape parameter (beyond `size` / `angle` /
  `roundness`) — placeholder; matches the Calligraphic parameter set
  if pressure-driven; revisit.
- Pressure / tilt mapping during the sweep (only meaningful with a
  stylus).
- Behavior when overlapping multiple existing Blob Brush elements
  with the same fill — union all into one, or only the first hit?
- Erase mode — Option/Alt-drag to subtract from existing Blob Brush
  shapes rather than add. Open question.

## Related tools

- **Brushes panel** (`BRUSHES.md`) — supplies the active brush whose
  tip shape parameters seed this tool when Calligraphic.
- **Paintbrush** (`PAINTBRUSH_TOOL.md`) — strokes-with-brush
  counterpart; consumes the active brush in full.
- **Pencil** (`PENCIL_TOOL.md`) — analogous freehand gesture but
  produces an open path with a stroke, not a filled region.
