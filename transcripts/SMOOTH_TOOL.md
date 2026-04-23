# Smooth tool

The Smooth tool re-fits a segment range of the *selected*
paths through a smoother curve. Drag across a path and the
portion of the path within the influence circle is replaced
with a cubic Bezier spline fitted with a larger error
tolerance (more forgiving than the Pencil tool's default).

**Shortcut:** none by default; invoked from the toolbar.

**Cursor:** crosshair.

## Gestures

- **Press** — snapshots the document. The first smooth pass
  happens immediately at the press location.
- **Drag** — each mousemove re-runs the smooth pass at the
  current cursor position. Continuous dragging incrementally
  refits overlapping regions.
- **Release** — returns to idle; no extra commit needed (the
  drag has been mutating the document in place).
- **Escape** — ends the gesture without undoing. (To undo the
  smoothing, use the app's Undo command — the snapshot from
  mousedown makes this one Undo step.)

## Algorithm

For each selected unlocked Path element:

1. Flatten the path's commands into a polyline with
   `flatten_with_cmd_map` — one flat point per LineTo,
   `FLATTEN_STEPS` (20) samples per CurveTo / QuadTo.
2. Find the contiguous range of flat points within
   `SMOOTH_SIZE` (default 100 px) of the cursor.
3. Map the first / last flat indices back to command indices
   via the parallel cmap.
4. Collect the flat points of the affected command range,
   prepended with the start-point of the first affected
   command so the refit curve connects seamlessly with the
   prefix.
5. Run `fit_curve(points, SMOOTH_ERROR)`. SMOOTH_ERROR is 8.0
   (twice the Pencil default — Smooth is about simplification,
   not faithful reproduction).
6. Replace the affected range of commands with the CurveTo
   chain the fit produced. Abort the per-element update if the
   refit didn't actually reduce the command count (avoids
   infinite "smoothing" loops on already-smooth paths).

The smooth radius and fit error are both exposed as YAML
parameters so a future panel could wire them to sliders.

## Selection requirement

Smooth only affects paths in the current selection. With no
selection, the tool does nothing — matching Illustrator. This
makes Smooth a targeted tool rather than a "smooth everything
the cursor crosses" free-for-all.

## No overlay

Smooth has no overlay render: the effect is applied directly
to the document so the user sees the geometry update live.

## Known gaps

- **Cursor ring** — Illustrator draws a visible circle around
  the cursor showing the smooth radius. Not currently wired,
  though the workspace state already has `SMOOTH_SIZE` available.
- **Smoothness parameter UI** — SMOOTH_SIZE / SMOOTH_ERROR are
  hard-coded in the YAML's `doc.path.smooth_at_cursor` call.
  A Smooth Tool Options dialog (like the Pencil's) is the
  natural UX but not specified yet.
