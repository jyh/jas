# Zoom Tool

The **Zoom Tool** changes the canvas zoom level via click, marquee
drag, scrubby drag, or mouse wheel, and provides keyboard shortcuts
for fit-to-artboard, fit-all-artboards, fit-window, and actual-size
operations. It modifies view state only: `active_document.zoom_level`
and `active_document.view_offset_x` / `view_offset_y`. No document
content is changed.

**Shortcut:** `Z`

**Tool icon:** A magnifying glass — circular lens (stroked, not
filled) with a short ~45° handle exiting at lower-right. No interior
glyph; the plus / minus symbols are rendered at cursor time, not
baked into the toolbar icon. Authored as inline SVG path data in
`workspace/icons.yaml` under `zoom:` (Rust and Swift consume this
directly; OCaml and Python re-implement the same geometry in their
respective toolbar drawing modules — visual parity is verified by
eye, matching the existing per-app icon convention).

**Toolbar slot:** Row 4, Col 0 of the tool grid, shared with the Hand
tool. Hand is the slot's primary; long-press (250ms) opens the
Navigation Tools flyout listing Hand and Zoom. The slot's checked
state lights up when either tool is active. The slot's workspace
artifacts (`btn_hand_slot` in `workspace/layout.yaml`,
`hand_alternates` in `workspace/dialogs/tool_alternates.yaml`) are
owned by HAND_TOOL.md; this spec only adds the Zoom entry to the
existing alternates list and references the slot.

**Double-click toolbar icon:** invokes `zoom_to_actual_size` (jumps
to 100% zoom, pan unchanged). Distinct from the Hand-icon dblclick,
which invokes `fit_active_artboard`.

## Gestures

All zoom operations clamp `zoom_level` to `[preferences.viewport.min_zoom,
preferences.viewport.max_zoom]`. The applied factor is the post-clamp
factor; anchor recomputation uses the post-clamp value so the cursor
stays glued to its anchor at the boundary.

The shared anchor-and-clamp math lives in a primitive named
`algorithms/zoom_apply` so all four apps converge on the same
behavior. See `## Anchor and clamp math` below.

The drag disambiguation between scrubby and marquee is selected by a
preference, not by modifier:

- `preferences.viewport.scrubby_zoom == true` (default): drag = scrubby.
- `preferences.viewport.scrubby_zoom == false`: drag = marquee.

Below the drag threshold (4 px in either dimension), mouseup is
treated as a click regardless of the preference.

### Plain click — zoom in

Mouseup with no Alt held and total drag distance ≤ 4 px. Zoom in by
`preferences.viewport.zoom_step`, anchored on the cursor position at
mousedown. Pan recomputes so the document point under the cursor at
mousedown stays under the cursor after the zoom.

At `zoom_level == max_zoom`, the click is a silent no-op (the cursor
already shows the clamped state — see `## Cursor states`).

### Alt-click — zoom out

Same as plain click but the factor is `1 / preferences.viewport.zoom_step`
and clamping is against `min_zoom`.

### Drag — scrubby zoom

When `preferences.viewport.scrubby_zoom == true` and total drag distance
> 4 px in any direction:

- **Anchor:** cursor position at mousedown, in viewport-local pixels.
  The document point under that pixel stays under that pixel for the
  duration of the drag.
- **Gain:** the applied zoom factor is `exp(dx_px /
  preferences.viewport.scrubby_zoom_gain)`, where `dx_px` is the signed
  horizontal drag distance from mousedown. Default
  `scrubby_zoom_gain` is 144, so 100 px right ≈ 2.0× zoom in,
  100 px left ≈ 0.5× zoom out.
- **Vertical drag:** ignored. Only horizontal X contributes to the
  factor.
- **Alt held during scrubby:** flips direction. Drag right with Alt
  held = zoom out. Modifier state is read continuously, not just
  sampled at mousedown.
- **Clamp behavior:** hard-stop at `min_zoom` / `max_zoom`. Further
  drag past the clamp is ignored until drag back in the other
  direction releases it. The cursor reflects the clamped state.
- **Continuous redraw:** `zoom_level` and `view_offset_x` /
  `view_offset_y` are written on every mousemove so the viewport
  redraws continuously during the drag.
- **Cancel:** Escape during the drag aborts. Zoom and pan revert to
  their mousedown values.

### Drag — marquee zoom

When `preferences.viewport.scrubby_zoom == false` and total drag distance
> 4 px in any direction:

- During the drag, an overlay rectangle is painted from the mousedown
  point to the current cursor.
- On mouseup, the new zoom level fits the marquee rectangle
  **inside** the viewport (letterbox): new zoom =
  `min(viewport_w / marquee_w, viewport_h / marquee_h)`, clamped to
  `[min_zoom, max_zoom]`. No margin (exact fit — see `## Anchor and
  clamp math` for the contrast with `fit_*` actions).
- Pan recomputes so the marquee's center in document coordinates
  lands at the viewport center.
- **Minimum marquee size:** if either dimension < 10 px on mouseup,
  treat as a click (scrubby semantics if `scrubby_zoom` would
  normally apply, otherwise plain click semantics for the prevailing
  modifier). Zero-area marquees fall under the same rule.
- **At-clamp marquee:** if fit-inside would exceed `max_zoom`,
  `zoom_level` is set to `max_zoom` and pan still centers on the
  marquee.
- **Cancel:** Escape during the drag aborts. The overlay disappears
  and zoom / pan are unchanged.

### Mouse wheel zoom

`Ctrl+wheel` (or `Cmd+wheel` on macOS) steps zoom up or down by
`preferences.viewport.zoom_step` per wheel notch, anchored on the cursor
position. No acceleration; one notch = one step. Plain wheel (no
modifier) is reserved for canvas pan and is not handled by this tool.

### Click-vs-drag threshold

A drag distance of 4 px in either dimension is the boundary. ≤ 4 px
on mouseup → click; > 4 px → drag (scrubby or marquee per the
preference). The threshold is intentionally smaller than the marquee
minimum-size threshold (10 px) so that very short marquees don't
become accidental zoom-ins; instead they remain ambiguous-drag and
fall back to click semantics.

### Click on empty area

There is no special-case for "empty canvas" — Zoom operates on the
viewport, not on document elements. Any click inside the canvas pane
zooms (or no-ops at the clamp boundary).

## Cursor states

| Condition                                  | Cursor                       |
|--------------------------------------------|------------------------------|
| Idle, no Alt                               | Magnifier with `+`           |
| Idle, Alt held                             | Magnifier with `−`           |
| Idle, no Alt, `zoom_level == max_zoom`     | Magnifier with grayed `+`    |
| Idle, Alt held, `zoom_level == min_zoom`   | Magnifier with grayed `−`    |
| During scrubby drag                        | Same as idle direction       |
| During marquee drag (after threshold)      | Crosshair                    |

Cursor refreshes synchronously on Alt press / release; no mouse
movement required. At-clamp grayed cursors plus a silent no-op on
click — the click does not produce a zoom change.

Cursor images are 32×32 raster, single foreground color
(theme-driven). Rust and Swift render from the canonical SVG in
`workspace/icons.yaml`; OCaml and Python re-implement the same
geometry. Python may fall back to platform stock cursors if tkinter's
custom-cursor pathway is constrained on a given platform — flagged as
Phase 2 polish if it surfaces.

## Anchor and clamp math

Given anchor `(ax, ay)` in viewport-local pixels (origin = top-left
of the canvas widget), current `zoom_level` `z`, requested factor
`f`, current `view_offset_x` / `view_offset_y` `(px, py)`:

```text
# Document point under the anchor at the current zoom
doc_ax = (ax - px) / z
doc_ay = (ay - py) / z

# Apply factor with clamp; use the actually-applied factor for the
# pan recomputation so the anchor stays stable at the boundary.
z_new = clamp(z * f, min_zoom, max_zoom)

# Pan so doc_ax / doc_ay stays under (ax, ay)
px_new = ax - doc_ax * z_new
py_new = ay - doc_ay * z_new
```

Coordinate / unit conventions, fixed across all four apps:

- `zoom_level` is a multiplicative factor; `1.0 == 100%`.
- `view_offset_x` / `view_offset_y` is the **screen-space pixel
  coordinate of the document origin** within the canvas widget.
  Positive offsets move the document `(0, 0)` rightward / downward
  on screen.
- Anchor coordinates passed to `doc.zoom.apply` are in
  **viewport-local** pixel space.

`fit_*` actions (and marquee zoom) use a separate primitive
`algorithms/zoom_fit_rect` that takes a target rect in document
coordinates plus a margin in screen-space pixels and returns the new
`(zoom_level, view_offset_x, view_offset_y)`. Marquee zoom calls
with `margin = 0` (exact fit). The three fit actions call with
`margin = preferences.viewport.fit_padding_px` (default 20).

## Keyboard shortcuts and actions

The Zoom tool's behaviors are also reachable through keyboard
shortcuts that work regardless of which tool is active. These reuse
or add View-menu actions:

| Shortcut       | Action                  | Centering          | Status         |
|----------------|-------------------------|--------------------|----------------|
| `Ctrl+=`       | `zoom_in`               | Viewport center    | Existing stub  |
| `Ctrl+-`       | `zoom_out`              | Viewport center    | Existing stub  |
| `Ctrl+0`       | `fit_active_artboard`   | n/a (fit recompute)| New            |
| `Ctrl+Alt+0`   | `fit_all_artboards`     | n/a (fit recompute)| New            |
| `Ctrl+1`       | `zoom_to_actual_size`   | Pan unchanged      | New            |

Existing `fit_in_window` (which fits all elements, not artboards)
keeps its current semantics and gains no new keyboard binding in
this spec — it remains menu-only.

`zoom_in` and `zoom_out` are extended with optional `anchor_x` /
`anchor_y` parameters. Keyboard callers pass nothing → defaults to
viewport center (preserving the existing action description). The
Zoom tool's click and wheel handlers pass cursor coordinates →
anchor on the cursor. Same action, callsite-dependent anchor.

`fit_active_artboard` reads `active_document.current_artboard.x`,
`y`, `width`, `height` directly. The at-least-one-artboard invariant
(per ARTBOARDS.md §At-least-one-artboard invariant) guarantees a
target exists; no fallback path is needed.

`fit_all_artboards` uses the union of all artboard rectangles in
`active_document.artboards`. Computed at action-dispatch time; not
memoized.

`zoom_to_actual_size` sets `zoom_level = 1.0` and leaves
`view_offset_x` / `view_offset_y` unchanged.

## Document-open behavior

When a document is opened (new or loaded from disk), the canvas's
view state is initialized:

```text
zoom_level = 1.0
if current_artboard fits in the viewport at zoom_level == 1.0:
    view_offset_x = (viewport_w - artboard.width)  / 2 - artboard.x
    view_offset_y = (viewport_h - artboard.height) / 2 - artboard.y
else:
    apply fit_active_artboard
```

`current_artboard` always exists per the at-least-one invariant. The
fall-through to `fit_active_artboard` handles documents whose default
artboard is larger than the available canvas widget (e.g. a 1080p
artboard in a small window).

## State persistence

| Key                                    | Tier            | Type        | Default | Notes                                      |
|----------------------------------------|-----------------|-------------|---------|--------------------------------------------|
| `active_document.zoom_level`           | runtime context | number      | `1.0`   | Per-document; not serialized               |
| `active_document.view_offset_x`        | runtime context | number      | `0.0`   | Per-document; not serialized; px           |
| `active_document.view_offset_y`        | runtime context | number      | `0.0`   | Per-document; not serialized; px           |
| `preferences.viewport.zoom_step`           | preferences     | number      | `1.2`   | Existing                                   |
| `preferences.viewport.min_zoom`            | preferences     | number      | `0.1`   | Existing                                   |
| `preferences.viewport.max_zoom`            | preferences     | number      | `64.0`  | Existing                                   |
| `preferences.viewport.fit_padding_px`      | preferences     | number      | `20`    | Existing; screen-space padding for `fit_*` |
| `preferences.viewport.scrubby_zoom`        | preferences     | bool        | `true`  | New; drag = scrubby (true) or marquee      |
| `preferences.viewport.scrubby_zoom_gain`   | preferences     | number      | `144`   | New; px of horizontal drag per e-fold      |

The Zoom tool has no `state.zoom_*` keys. View state lives on
`active_document.*`; tuning lives in `preferences.*`. Per-document
view state persists across tab switches within a session but resets
when a document is reopened from disk.

## Cross-app artifacts

- `workspace/tools/zoom.yaml` — new tool spec (id, cursor, gesture
  handlers calling `doc.zoom.apply` and `doc.zoom.fit_rect`,
  shortcut `Z`).
- `workspace/icons.yaml` — new `zoom:` entry with the magnifier SVG.
- `workspace/runtime_contexts.yaml` — adds `view_offset_x`,
  `view_offset_y` declarations under `active_document`. Updates
  `zoom_level` description to note "per-document; not serialized."
- `workspace/preferences.yaml` — adds `viewport.scrubby_zoom`,
  `viewport.scrubby_zoom_gain` under the existing `viewport:` block.
  `viewport.fit_padding_px` is already declared and reused as-is.
- `workspace/actions.yaml` — fills in the existing log-only stubs
  for `zoom_in`, `zoom_out` (adds optional anchor params) and
  `fit_in_window` (cleans up the "artboard origin" phrasing to
  "document origin"). Adds `fit_active_artboard`,
  `fit_all_artboards`, `zoom_to_actual_size`.
- `workspace/shortcuts.yaml` — adds `Ctrl+0`, `Ctrl+Alt+0`,
  `Ctrl+1` bindings.
- `workspace/menubar.yaml` — adds `View > Fit Artboard in Window`,
  `View > Fit All in Window`, `View > Actual Size`.
- New shared algorithm primitives (per the `algorithms/<name>`
  pattern used by Magic Wand): `algorithms/zoom_apply`
  (`(zoom, offset_x, offset_y, anchor_x, anchor_y, factor) → new
  zoom + offsets`) and `algorithms/zoom_fit_rect` (`(viewport_w,
  viewport_h, rect, margin) → new zoom + offsets`). Both clamp to
  `[min_zoom, max_zoom]`.
- New effects: `doc.zoom.apply` (anchor + factor), `doc.zoom.fit_rect`
  (rect + margin), `doc.zoom.set` (absolute level, used by
  `zoom_to_actual_size`).
- Toolbar slot wiring (`btn_hand_slot` in `workspace/layout.yaml` row
  4 col 0, `hand_alternates` in `workspace/dialogs/tool_alternates.yaml`)
  is owned by HAND_TOOL.md. This spec only appends the Zoom entry to
  the existing `hand_alternates` list; it does not redeclare the slot.

## Phase 1 / Phase 2 split

### Phase 1 (this spec)

- Step zoom in / out (click, Alt+click), cursor-centered.
- Marquee zoom (drag a rect, fit-inside on mouseup, exact fit).
- Scrubby zoom (drag-to-zoom-continuously, anchor at mousedown,
  Alt-flip during drag). Mode selected by
  `preferences.viewport.scrubby_zoom` (default `true`).
- Mouse wheel zoom: `Ctrl+wheel` = step zoom, cursor-centered, no
  acceleration.
- Keyboard shortcuts: `Ctrl+=`, `Ctrl+-`, `Ctrl+0`, `Ctrl+Alt+0`,
  `Ctrl+1`. Existing `Ctrl+=` / `Ctrl+-` stubs filled in.
- Toolbar slot (row 4 col 0, shared with Hand). Long-press
  alternates; double-click icon → `zoom_to_actual_size`.
- Cursor states: plus / minus / grayed plus / grayed minus /
  crosshair-during-marquee. Synchronous on Alt press / release.
- Document-open: `current_artboard` at 100% if it fits, else
  `fit_active_artboard`.
- State: `view_offset_x` / `view_offset_y` on `active_document`; not
  serialized.
- Per-app implementation order: Rust → Swift → OCaml → Python.

### Phase 2 (deferred)

- **Trackpad pinch zoom.** Native gesture support varies across the
  four UI toolkits.
- **Animated zoom-step transitions.** Visual interpolation between
  discrete zoom levels rather than instant jumps. Polish.
- **Temporary-zoom modifier.** A held-key chord that switches to
  Zoom for the duration of the hold, then snaps back. Awaits a
  generic temporary-tool-override mechanism that would also benefit
  other tools. Plain `Space` → temporary Hand is unaffected and
  remains the recommended in-flow navigation pattern.
- **Marquee modifier variants.** Shift-during-marquee to constrain
  to square; Alt-during-marquee to flip fit-inside vs fit-outside.
- **Zoom-to-selection.** A View-menu action that fits the selection's
  bounding box. Lives in the same neighborhood but isn't a Zoom-tool
  feature per se.
- **Per-document view-state persistence.** Opt-in serialization of
  `zoom_level` and `view_offset_*`, behind a preference toggle.
  Phase 1 keeps view state per-session.

## Related tools

- **Hand tool** — shares the toolbar slot (row 4 col 0). Hand handles
  pan; Zoom handles zoom (and pan, on marquee or fit). The
  Hand-via-spacebar temporary-tool gesture covers in-flow pan; Zoom
  has no equivalent in Phase 1 (see Phase 2 deferrals).
- **Artboards** — `fit_active_artboard` reads `current_artboard`
  per `transcripts/ARTBOARDS.md` §Selection semantics. The
  at-least-one-artboard invariant guarantees a target always exists.
- **View menu** — the keyboard shortcuts and menu items added by
  this spec (`zoom_in`, `zoom_out`, `zoom_to_actual_size`,
  `fit_active_artboard`, `fit_all_artboards`, `fit_in_window`)
  collectively form the View > Zoom group. The tool is the
  canvas-side input pathway; the menu is the keyboard pathway. Both
  call into the same `doc.zoom.*` effects.
