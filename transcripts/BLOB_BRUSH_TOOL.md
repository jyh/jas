# Blob Brush tool

The Blob Brush tool paints filled regions by sweeping a tip-shape
oval along a freehand drag, then unioning the swept region with any
existing Blob Brush element(s) it overlaps. The result is a single
closed filled Path — *not* a stroked path; the tool does not write
`jas:stroke-brush` on its output. A tagging attribute
`jas:tool-origin="blob_brush"` is set so future sweeps can merge
into the same shape.

The tool is always enabled. When the active brush in the Brushes
panel is **Calligraphic**, its tip-shape parameters drive Blob
Brush (with variation modes and instance overrides honored). For
any other brush type (Scatter, Art, Pattern, Bristle) — or when no
brush is active — the fallback values from this tool's options
dialog drive the tip shape instead. Either way, the committed
element is a single filled region with `state.fill_color` and no
stroke; brush-specific renderers (artwork, pattern tiles,
colorization) are not consulted.

**Shortcut:** Shift-B.

**Cursor:** the OS cursor is hidden; the overlay layer draws the
oval tip shape at the pointer position each frame — see § Overlay.

## Gestures

All point-buffer operations below target the `"blob_brush"` buffer
in the YAML runtime.

Option/Alt at `mousedown` latches the gesture mode:
- **Alt held** → `erasing` mode (§ Erase gesture).
- **Alt not held** → `painting` mode (§ Merge condition / § Multi-
  element merge).

Mode is locked at press. Alt state during the drag or at release
is ignored.

- **Press** — snapshots the document; clears the sweep buffer;
  pushes the press point as the first dab; enters `painting` or
  `erasing` mode per the Alt latch above.
- **Drag** — each `mousemove` pushes the raw pointer position into
  the sweep buffer. At commit time the buffer is arc-length
  **resampled** at `½ × min(size, size × roundness/100)` intervals,
  **interpolating between input points** so dab spacing is uniform
  regardless of input sample density. Interpolation matters: if
  the OS delivers mousemove events at ~10 pt intervals and the tip
  needs 5 pt dab spacing to avoid visible seams, naïve
  sample-at-existing-points would emit dabs every 10 pt (seams).
  The resampler inserts an interpolated sample at the right
  position on each segment.
- **Release** — always force a final dab at the release position
  (avoids a bald spot at the drag's end). Then run the
  `painting` commit (§ Fill and stroke → Commit pipeline) or the
  `erasing` commit (§ Erase gesture → Commit).
- **Escape** — cancels the sweep, discards the buffer, no
  document change.

## Tool options

Double-click the Blob Brush icon in the toolbar opens the Blob
Brush Tool Options dialog. The dialog is declared in
`workspace/dialogs/blob_brush_tool_options.yaml` (id:
`blob_brush_tool_options`) and wired via the `tool_options_dialog`
field on the tool yaml — the cross-tool convention introduced
alongside Paintbrush. See `PAINTBRUSH_TOOL.md` § Tool options for
the toolbar-dispatch rule.

### Options

| Option                               | Widget                                | Default     |
|--------------------------------------|---------------------------------------|-------------|
| `blob_brush_fidelity`                | 5-stop slider, Accurate ↔ Smooth      | 3           |
| `blob_brush_keep_selected`           | checkbox                              | false       |
| `blob_brush_merge_only_with_selection` | checkbox                            | false       |
| `blob_brush_size`                    | variation widget (pt)                 | 10 pt, `fixed` |
| `blob_brush_angle`                   | variation widget (°)                  | 0°, `fixed` |
| `blob_brush_roundness`               | variation widget (%)                  | 100%, `fixed` |

Dialog buttons: **Reset** (restores defaults above; affects dialog
state only, does not commit until OK), **Cancel** (discards edits),
**OK** (writes all six values to `state.blob_brush_*`).

### Fidelity → simplification tolerance mapping

The Fidelity slider has 5 discrete tick stops. Position maps to
the Ramer-Douglas-Peucker epsilon used when simplifying the unioned
boundary (§ Fill and stroke → Commit pipeline step 4):

| Tick | Label     | RDP `epsilon` (pt) |
|------|-----------|--------------------|
| 1    | Accurate  | 0.5                |
| 2    | —         | 2.5                |
| 3    | (default) | 5.0                |
| 4    | —         | 7.5                |
| 5    | Smooth    | 10.0               |

### Runtime tip resolution

At each dab during the drag, the effective tip shape (size, angle,
roundness) resolves from:

- **Active brush is Calligraphic** (`state.stroke_brush` refers to
  a Calligraphic library entry): the brush's `size` / `angle` /
  `roundness` fields *and* their variation modes, with
  `state.stroke_brush_overrides` layered on top. Identical
  resolution to the Brush Options dialog's instance-edit mode.
- **Any other state** (no active brush, or active brush is
  Scatter / Art / Pattern / Bristle): the `blob_brush_size` /
  `_angle` / `_roundness` values from this dialog.

The dialog's Size / Angle / Roundness rows are **disabled** (grayed
out with a "(set by active brush)" hint) whenever a Calligraphic
brush is active; switching to a non-Calligraphic brush or clearing
`state.stroke_brush` re-enables them.

Implementation note: the `disabled:` expression on each row calls
a new `brush_type_of(slug)` expression helper that looks the brush
up in `brush_libraries` and returns its `type` field. Added
alongside the dialog YAML.

### Variation mode evaluation at each dab

- `fixed` — base value.
- `random` — uniform random within the widget's min/max. New
  sample per dab.
- `pressure` / `tilt` / `bearing` — Phase 1 synthesizes `0.5` →
  base value. Phase 2 consumes the per-sample stylus channel.
- `rotation` — for `angle` only: `atan2(dy, dx)` of the pointer's
  local motion vector. Disabled in the dialog for `size` and
  `roundness` (no sensible interpretation).

### Option persistence

Option values live in `state.blob_brush_*` (per-document), aligned
with the YAML tool-runtime convention used by Paintbrush.

## Fill and stroke

Behavior at commit time for a new Path (§ Erase gesture has its
own rules for modifying existing elements):

- **`fill`** — `state.fill_color`. Null / gradient states commit
  an invisible or gradient-filled Path respectively; the merge
  condition (§ below) won't fire in those cases.
- **`stroke`** — absent (Blob Brush outputs have no stroke).
- **`jas:tool-origin`** — `"blob_brush"` (constant; enables merge
  and erase to recognize Blob Brush's own output).

### Commit pipeline

1. Discretize each buffered dab to a 16-segment polygon (ring).
2. If any qualifying existing Blob Brush element is overlapped
   (§ Merge condition), go to § Multi-element merge; otherwise
   continue with step 3 as a standalone commit.
3. Run `boolean_union` (from `algorithms/boolean`) pairwise over
   the dab rings. The module operates on a flat `PolygonSet`; see
   `algorithms/boolean` for the even-odd fill contract.
4. Simplify the boundary rings via Ramer-Douglas-Peucker at
   `epsilon` = fidelity tolerance (§ Fidelity mapping).
5. Emit as a single Path element with one `MoveTo … ClosePath`
   subpath per ring, inserted at the document's current insertion
   point.
6. If `blob_brush_keep_selected` is on, select the new element
   after commit.

### Adapter helpers

Two thin functions convert between `Element::Path` and the
algorithm module's `PolygonSet`:

- `path_to_polygon_set(d: &[PathCommand]) -> PolygonSet` —
  flattens each `MoveTo … ClosePath` subpath to a polygon ring
  via the existing `flatten_path_commands`.
- `polygon_set_to_path(ps: &PolygonSet) -> Vec<PathCommand>` —
  emits one `MoveTo` + LineTos + `ClosePath` per ring.

Both are new but each is 10–20 lines and shared with § Erase
gesture.

## Merge condition

A committed sweep in `painting` mode merges with an existing
element iff **all** of:

- The element carries `jas:tool-origin == "blob_brush"`.
- The element has a solid (non-gradient, non-null) fill whose
  sRGB hex form **and** opacity exactly match `state.fill_color`.
- The element's bounding box intersects the swept region's
  bounding box (cheap precheck; supplemented by the polygon
  intersection test in § Commit pipeline step 2).
- (If `blob_brush_merge_only_with_selection` is on) the element
  is part of the current canvas selection.

Color comparison normalizes both sides via `Color::to_hex()`
(lowercase 6-char form) plus an exact float match on opacity.
Implemented as a helper `fill_matches(a: &Fill, b: &Fill) -> bool`
shared with any future tool that gates on fill identity.

## Multi-element merge

When the swept region qualifies for merge (§ Merge condition) and
overlaps one or more existing elements, union with **all** of
them at once — not just the first hit.

### Commit (painting mode, multi-element path)

Given `matches = [M₁, …, Mₙ]` (every element satisfying § Merge
condition whose polygon set intersects the swept region's polygon
set):

1. Compute `R = boolean_union(sweptRegion, M₁, M₂, …, Mₙ)`
   pairwise (associative; order-independent).
2. Simplify `R` via RDP at the fidelity tolerance.
3. Convert `R` back to `PathCommand`s via
   `polygon_set_to_path`. Multiple rings → multiple
   `MoveTo … ClosePath` subpaths in a **single** Path element
   (one layer-tree entry, one undo unit, one future-erase
   candidate).
4. Remove every element in `matches` from the document.
5. Insert the unified Path at the **lowest z-index** among
   `matches`. The unified element inherits opacity, mask, blend
   mode, and `jas:tool-origin` from the lowest-z match; fill is
   already guaranteed equal.
6. Selection state follows `blob_brush_keep_selected`.

All of (4)–(5) happens within the single undo step opened by
`doc.snapshot` at mousedown.

### Z-order invariant

Non-blob-brush elements interleaved between matches in the
z-stack stay exactly where they were. The unified element
occupies only the lowest matching z-slot; higher-z matches are
removed without disturbing non-matching neighbors.

## Erase gesture

When Option/Alt is held at `mousedown`, the gesture enters
`erasing` mode. Swept region accumulates identically to `painting`
mode (same dab sampling, same buffer). At commit:

1. Let `S` = the swept region's polygon set.
2. Find every element with `jas:tool-origin == "blob_brush"` whose
   bounding box intersects `S`'s bounding box. Fill color is
   **not** required to match — erase is blunter than merge.
3. For each such element `M`, compute
   `R_M = boolean_subtract(path_to_polygon_set(M.d), S)`:
   - **Empty `R_M`** — `S` fully covers `M`. Remove `M` from the
     document.
   - **Non-empty `R_M`** — replace `M.d` with
     `polygon_set_to_path(simplify(R_M))`. All other attributes
     (fill, opacity, mask, `jas:tool-origin`, …) preserved. If
     `R_M` contains multiple disjoint rings, emit a single Path
     with multiple subpaths (same convention as § Multi-element
     merge).
4. All changes in one undo step.

### Why fill isn't required to match for erase

Erase's intent is geometric removal, not color-scoped cleanup.
Requiring a color match would make erase useless the moment the
user changes fill color — a common workflow. Users who want
color-scoped erase can set `state.fill_color` to the target color
and use `blob_brush_merge_only_with_selection` as a separate
filter.

### Why only blob-brush elements

`jas:tool-origin == "blob_brush"` gates erase. Regular Paths,
Rects, Type, etc. are ignored — otherwise Blob Brush silently
becomes a destructive universal eraser, scope creep into what
would be a separate Eraser tool.

### Cursor during erase hover

When Alt is held over the canvas (no drag), the oval cursor (§
Overlay → Cursor) renders with a **dashed** stroke instead of
solid to signal subtract. Same size / angle / roundness as
normal hover; just a style flip.

## Overlay

### Hover cursor

The OS cursor is hidden. The overlay renders an oval at the
current pointer position every frame:

- **Width**: `size` pt (effective value per § Runtime tip
  resolution).
- **Height**: `size × roundness / 100` pt.
- **Rotation**: `angle` degrees.
- **Stroke**: 1 px screen-space, color = `state.fill_color`; no
  fill.
- **Center crosshair**: 1 px screen-space for precision aiming.

Variation modes are **not** evaluated for the cursor — it shows
the base values. Per-dab variation is visible in the drag overlay
(below).

In `erasing` mode (Alt held during hover), the stroke switches to
dashed (e.g. `[4, 4]` pattern) to signal subtract. Same geometry.

### Drag overlay

During `painting` mode, each dab is drawn as a semi-transparent
filled oval in `state.fill_color`. Overlapping dabs composite via
alpha — no boolean union during the drag; the cumulative
coverage is visible cheaply. The precise unioned shape is
computed only on commit.

During `erasing` mode, dabs are drawn with a dashed outline in
`state.fill_color` (fill: none) — preview of the region being
subtracted.

The semi-transparent `state.fill_color` overlay is deliberate —
unlike Paintbrush's neutral-black trail, Blob Brush's preview
conveys area coverage, so the fill color is essential to avoid a
"wait, what will this fill be?" surprise on commit.

### Cross-app rendering

Rust and Swift implement a new `oval_cursor` overlay render type
plus the dab-preview shape. OCaml and Python inherit the platform
default cursor until `yaml_tool.draw_overlay` comes out of its
Phase-5a stub (tracked separately). In those apps the tool still
commits correctly; it just lacks the drag-time preview.

## YAML tool runtime fit

Handler YAML lives at `workspace/tools/blob_brush.yaml`. The state
machine (`idle` / `painting` / `erasing`) and overlay shape are
declared in YAML; the union and subtract steps call into
`algorithms/boolean` via new `doc.blob_brush.commit_painting` and
`doc.blob_brush.commit_erasing` effects (analogous to
`doc.paintbrush.edit_commit`).

The `boolean_union` / `boolean_subtract` primitives already exist
and are tested in all four native apps. The only new app-side code
is:

1. `path_to_polygon_set` / `polygon_set_to_path` adapters
   (~20 lines per app).
2. The two commit effects that wire the sweep → polygon → union /
   subtract → path pipeline.
3. The `brush_type_of(slug)` expression helper.
4. The `oval_cursor` overlay render type (Rust / Swift).

## Phase 1 / Phase 2 split

### Phase 1 (this spec)

- Dab buffer stores `(x, y)` only — no pressure / tilt / bearing.
- Variation modes `pressure` / `tilt` / `bearing` synthesize `0.5`
  at each dab → base value. Effectively inert in Phase 1.
- `fixed`, `random`, and `rotation` modes work end-to-end.

### Phase 2 (follow-up cross-app project, shared with Paintbrush)

- Extend the dab buffer to `(x, y, pressure, tilt, bearing)`.
- Evaluate `pressure` / `tilt` / `bearing` variation modes from
  the per-dab channel, not the synthesized 0.5.
- Rollout order: Swift / Rust first (richest stylus APIs), OCaml
  next (GDK axes), Python last (toolkit-dependent), Flask via
  Pointer Events API once its JS engine lands `buffer.*`.

See `PAINTBRUSH_TOOL.md` § Phase 1 / Phase 2 split — the same
cross-cutting buffer / fit_curve / renderer work covers Blob
Brush's dab buffer too.

## Related tools

- **Brushes panel** (`BRUSHES.md`) — supplies the active
  Calligraphic brush whose tip-shape parameters feed Blob Brush.
- **Paintbrush** (`PAINTBRUSH_TOOL.md`) — strokes-with-brush
  counterpart; consumes the active brush in full. Shares the
  `tool_options_dialog` convention, the Fidelity slider mapping,
  the Phase 1/2 split, and the Alt-at-press gesture-latch
  pattern.
- **Pencil** (`PENCIL_TOOL.md`) — analogous freehand gesture but
  produces an open path with a stroke, not a filled region.
- **Boolean** (`BOOLEAN.md`) — the live compound-shape feature
  uses `algorithms/boolean` too. Blob Brush bypasses compound-
  shape and consumes the destructive primitives directly; its
  output is a plain Path, not a live compound.
- **Eraser tool** (future, separate spec) — a general-purpose
  eraser that affects any element. Blob Brush's Alt-drag erase
  (§ Erase gesture) only affects elements with
  `jas:tool-origin == "blob_brush"`; a full Eraser is deliberately
  out of scope here.
