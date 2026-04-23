# Canvas tools — index

Every canvas tool in the app has its own design doc. Tools are
grouped by purpose; follow the link for gesture set, state
machine, and known gaps.

## Selection

- **[Selection / Interior Selection / Partial Selection](SELECTION_TOOL.md)**
  — pick whole elements, recurse into groups, pick individual
  control points.
- **[Lasso](LASSO_TOOL.md)** — freehand-polygon selection.
- **[Magic Wand](MAGIC_WAND.md)** — similarity-based selection
  expansion. Panel doc only; the tool implementation is
  implicit from the panel.

## Drawing

- **[Line](LINE_TOOL.md)** — straight line segment.
- **[Rect / Rounded Rect](RECT_TOOL.md)** — axis-aligned
  rectangles, optionally with corner radii.
- **[Ellipse](ELLIPSE_TOOL.md)** — axis-aligned ellipse. Specified
  but not yet wired.
- **[Polygon](POLYGON_TOOL.md)** — regular N-gon.
- **[Star](STAR_TOOL.md)** — N-pointed star inscribed in a bbox.
- **[Pen](PEN_TOOL.md)** — click-to-place Bezier path editor.
- **[Pencil](PENCIL_TOOL.md)** — freehand drag with curve-fit
  smoothing on release.

## Path editing

- **[Add / Delete / Anchor Point (Convert)](ANCHOR_POINT_TOOLS.md)**
  — add, remove, or toggle corner/smooth on anchors of existing
  paths.
- **[Path Eraser](PATH_ERASER_TOOL.md)** — sweep-rectangle
  eraser; preserves curves via De Casteljau splitting.
- **[Smooth](SMOOTH_TOOL.md)** — re-fit a range of a selected
  path with a larger error tolerance.

## Text

- **[Type / Type on Path](TYPE_TOOL.md)** — point text, area
  text, text flowed along a path. Permanent-native per
  `NATIVE_BOUNDARY.md` §6.

## Gradient

- **[Gradient](GRADIENT_TOOL.md)** — on-canvas geometric editor
  for the active gradient. Stub doc; full design is a follow-up.

## Architecture notes

- 14 tools (all except the two text tools) are driven from
  `workspace/tools/*.yaml` — handler YAML specifies mouse /
  keyboard behavior, state-machine transitions, and the
  overlay shape. All 4 native apps share the same YAML.
- The tool runtime (`YamlTool` class in each app) lives in
  each app's `tools/` directory. See `RUST_TOOL_RUNTIME.md` /
  `SWIFT_TOOL_RUNTIME.md` / `OCAML_TOOL_RUNTIME.md` /
  `PYTHON_TOOL_RUNTIME.md` for per-language migration history.
- Type / TypeOnPath stay native because text editing needs
  native IME, font shaping, and caret timers that don't fit
  the YAML effect grammar. See `NATIVE_BOUNDARY.md` §6.
