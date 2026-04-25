# Hand Tool

The **Hand Tool** pans the canvas by click-and-drag, sliding the
view across the document without modifying any content. It modifies
view state only: `active_document.view_offset_x` and
`view_offset_y`. Pan is unbounded (no clamp). Hand is one half of
the navigation tool pair; the other is Zoom.

**Shortcut:** `H`

**Tool icon:** A stylized hand glyph — open palm with four extended
fingers and a thumb. Authored as inline SVG path data in
`workspace/icons.yaml` under `hand:` (Rust and Swift consume this
directly; OCaml and Python re-implement the same geometry in their
respective toolbar drawing modules).

**Toolbar slot:** Row 4, Col 0 of the tool grid, shared with the
Zoom tool. Hand is the slot's **primary** tool (the icon shown on
the toolbar by default); long-press (250ms) opens the Navigation
Tools flyout listing Hand and Zoom. The slot's checked state lights
up when either tool is active. This spec owns the slot's workspace
artifacts:

- `btn_hand_slot` in `workspace/layout.yaml` row 4 col 0.
- `hand_alternates` flyout in `workspace/dialogs/tool_alternates.yaml`,
  listing Hand and Zoom.

The Zoom tool spec (ZOOM_TOOL.md) references these without
redeclaring them.

**Double-click toolbar icon:** invokes `fit_active_artboard` (zooms
+ pans so the current artboard fits the viewport with the standard
fit margin). Distinct from the Zoom-icon dblclick, which invokes
`zoom_to_actual_size`.

## Gestures

### Drag — pan

Mousedown anchors `(mouse_x_0, mouse_y_0)` (cursor position in
viewport-local pixels) and `(offset_x_0, offset_y_0)` (current
`view_offset_x` / `view_offset_y`). On each mousemove with
`(mouse_x, mouse_y)`:

```text
view_offset_x = offset_x_0 + (mouse_x - mouse_x_0)
view_offset_y = offset_y_0 + (mouse_y - mouse_y_0)
```

This keeps the document point that was under the cursor at
mousedown stuck under the cursor for the entire drag. Mouseup
commits — there is no "release" semantic distinct from "stop
moving"; the final state at mouseup is the new pan.

Pan is unbounded: there is no min / max for `view_offset_x` /
`view_offset_y`. Users can pan the canvas to any position, including
far past the artboard or document content edges. The canvas
background fills any region that has no element.

The drag continues even if the cursor leaves the canvas pane
(standard mouse-capture behavior). Mouseup outside the canvas pane
still commits.

### Plain click (no drag)

No-op. Clicking with the Hand tool without dragging does nothing.

### Modifier keys

None in Phase 1. Hand has no Alt / Shift / Cmd modifiers — a drag
is a drag regardless of modifier state. (Modifier-aware
constraints — e.g. Shift-during-drag to lock to horizontal or
vertical — are deferred to Phase 2.)

### Cancel

Escape during the drag aborts. Pan reverts to its mousedown values
(`offset_x_0`, `offset_y_0`).

## Cursor states

| Condition         | Cursor                  |
|-------------------|-------------------------|
| Idle (Hand active)| Open hand (palm visible)|
| During drag       | Closed hand / grab      |
| During Space-held pass-through | Same as if Hand were active (open / closed by drag state) |

The cursor change between open and closed happens on mousedown /
mouseup, not on mousemove. The closed hand persists for the
duration of the drag.

Cursor images are 32×32 raster, single foreground color. Same
authoring path as the toolbar icon — see `workspace/icons.yaml`.

## Spacebar pass-through

Holding Space while another tool is active temporarily switches to
Hand for the duration of the hold. This is the in-flow navigation
gesture referenced by the canvas-pane description in
`workspace/layout.yaml`.

### Mechanics

- **Space-down (KeyDown event):** if `state.active_tool != "hand"`,
  save the prior tool to per-app session state and set
  `state.active_tool = "hand"`. The cursor changes to the open hand
  immediately (synchronously, without requiring a mouse move — same
  rule as Zoom's modifier-driven cursor refresh).
- **While Space is held:** Hand-tool gestures apply normally. The
  user can drag-to-pan, click (no-op), etc.
- **Space-up (KeyUp event):** restore the prior tool from session
  state. The cursor reverts on the next mouse event.

If the user is in the middle of a Hand drag when Space is released,
the drag completes naturally (mouseup is processed before the
tool-restore on Space-up). The pan committed by that mouseup is
preserved.

### Suppression while text input has focus

Spacebar pass-through is suppressed when a text input has keyboard
focus — the user is typing a literal space character into a Layers
panel rename, an Artboard Options name field, etc. Detection is
per-app (each toolkit has its own focus-tracking primitive); the
contract is that Space is not consumed as a tool-switch when the
focused widget is a text-editing widget.

### Edge cases

- **Space pressed while Hand is already active:** no-op (no save /
  restore needed; the pass-through is only meaningful from
  non-Hand tools).
- **Other tool shortcut pressed during a Space-held Hand session:**
  ignored until Space is released. The simplification: only one
  pending "prior tool" is tracked, and Space is the only key that
  pushes onto / pops off that single slot. Pressing Z or V or
  another tool letter during Space-held Hand is a no-op.
- **Space-up while another keyboard modifier is held:** still
  restores the prior tool. The pass-through is governed by Space
  alone.
- **Application loses focus while Space is held:** restore the
  prior tool when focus is lost. Without this, releasing Space
  outside the application would leave the user stuck in Hand.

## Document-open behavior

Inherited from the shared view-state initialization (also referenced
by ZOOM_TOOL.md §Document-open behavior):

```text
zoom_level = 1.0
if current_artboard fits in the viewport at zoom_level == 1.0:
    view_offset_x = (viewport_w - artboard.width)  / 2 - artboard.x
    view_offset_y = (viewport_h - artboard.height) / 2 - artboard.y
else:
    apply fit_active_artboard
```

The Hand tool itself doesn't run this — it's the canvas widget's
on-open routine. Documented here because the Hand tool reads
`view_offset_x` / `view_offset_y` and users expect a sensible
initial pan.

## State persistence

Hand reads and writes:

| Key                                | Tier            | Type   | Default | Notes                          |
|------------------------------------|-----------------|--------|---------|--------------------------------|
| `active_document.view_offset_x`    | runtime context | number | `0.0`   | Per-document; not serialized   |
| `active_document.view_offset_y`    | runtime context | number | `0.0`   | Per-document; not serialized   |

No new state keys are introduced by Hand specifically — these are
the same keys declared by ZOOM_TOOL.md §State persistence (whichever
spec is implemented first owns the runtime-context declaration).

The prior-tool slot used by spacebar pass-through is per-app session
state (not per-document), and not surfaced through the runtime
context system.

## Cross-app artifacts

- `workspace/tools/hand.yaml` — new tool spec (id `hand`, cursor
  `open_hand`, gesture handlers for drag-to-pan and Escape-cancel,
  shortcut `H`).
- `workspace/icons.yaml` — new `hand:` entry with the open-hand SVG.
- `workspace/layout.yaml` — new `btn_hand_slot` at row 4 col 0,
  with long-press timer wiring to open `hand_alternates`. Click =
  select Hand. Double-click invokes `fit_active_artboard`.
- `workspace/dialogs/tool_alternates.yaml` — new `hand_alternates`
  flyout listing Hand and Zoom.
- `workspace/shortcuts.yaml` — `H` binding for `select_tool` with
  `tool: hand`.
- `workspace/runtime_contexts.yaml` — `view_offset_x` and
  `view_offset_y` declarations under `active_document` (shared
  with ZOOM_TOOL.md).
- Spacebar pass-through is implemented in each app's keyboard
  handler — it's a tool-modal behavior, not a workspace-level
  shortcut. The contract (above, in §Spacebar pass-through) is
  the shared spec; the implementation is per-app.

## Phase 1 / Phase 2 split

### Phase 1 (this spec)

- Drag-to-pan with mousedown-anchor semantics.
- Spacebar pass-through (with text-input suppression and edge-case
  handling).
- Open / closed hand cursor states.
- Toolbar slot (row 4 col 0, Hand primary; long-press alternates
  with Zoom).
- Double-click toolbar icon → `fit_active_artboard`.
- `H` shortcut for direct tool selection.
- Escape cancels an in-progress drag.
- Per-app implementation order: Rust → Swift → OCaml → Python.

### Phase 2 (deferred)

- **Inertia / kinetic pan.** Continued motion after drag release
  with deceleration. Polish; requires per-frame animation
  scheduling.
- **Two-finger trackpad pan.** Native gesture support varies
  across the four UI toolkits; not a Phase 1 requirement.
- **Modifier-locked drag.** Shift-during-drag to constrain pan to
  horizontal or vertical axis only. Useful but rare.
- **Print Tiling Tool.** A long-press alternate for adjusting
  page-tile origin (per the convention from comparable vector
  illustration applications). Bound to the printing implementation
  (printing itself is forward-referenced in ARTBOARDS.md
  §Printing); not part of Phase 1.
- **Rotate View Tool.** A `Shift+H` alternate for canvas rotation
  (per the convention from comparable vector illustration
  applications). A separate spec when prioritized; introduces a
  view-rotation field that Phase 1 doesn't carry.

## Related tools

- **Zoom Tool** — shares the toolbar slot (row 4 col 0). Zoom
  handles zoom (and pan, on marquee or fit); Hand handles pan only.
  Hand-via-spacebar is the recommended in-flow pan gesture; Zoom
  has no equivalent in Phase 1.
- **Artboards** — `fit_active_artboard` (invoked by the Hand-icon
  dblclick) reads `current_artboard` per
  `transcripts/ARTBOARDS.md` §Selection semantics. The
  at-least-one-artboard invariant guarantees a target always exists.
- **View menu** — keyboard shortcuts for zoom and fit operations
  (defined in ZOOM_TOOL.md §Keyboard shortcuts and actions) work
  regardless of which tool is active, including during a
  Space-held Hand pass-through.
