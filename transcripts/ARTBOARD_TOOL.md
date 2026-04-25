# Artboard Tool

The **Artboard Tool** edits artboards on the canvas: create, activate,
move, resize, and duplicate. It writes to the document's
`document.artboards` list and to the panel-selection state defined in
ARTBOARDS.md §Selection semantics. It does not edit document elements
except via the Move/Copy Artwork rule below; clicks and drags on the
tool never modify element geometry directly.

The Artboards Panel, the Artboard Options Dialogue, the at-least-one
invariant, the per-artboard data model, the canvas Z-order, and the
naming/numbering rules all live in `transcripts/ARTBOARDS.md` and are
referenced rather than restated here. Tool specs focus on canvas-side
gestures and tool-state; panel/Dialogue/data-model concerns are owned
by ARTBOARDS.md.

**Shortcut:** `Shift+O` canonical, `O` aliased. Both bind to
`select_tool { tool: artboard }` in `workspace/shortcuts.yaml`.

**Tool icon:** A small artboard glyph — a page rectangle with one
corner folded forward, suggesting "boundary, not content." Authored as
inline SVG path data in `workspace/icons.yaml` under `artboard:` (Rust
and Swift consume this directly; OCaml and Python re-implement the
same geometry in their respective toolbar drawing modules — visual
parity is verified by eye, matching the existing per-app icon
convention).

**Toolbar slot:** Row 4, Col 1 of the tool grid. Standalone — no
long-press alternates flyout in phase 1. The slot's checked state
lights up when the Artboard Tool is active.

**Double-click toolbar icon:** invokes `fit_all_artboards` (zooms +
pans so the union of all artboard rectangles fits the viewport with
the standard fit margin). Distinct from Hand-icon dblclick
(`fit_active_artboard`) and Zoom-icon dblclick (`zoom_to_actual_size`).

## Gestures

### Common rules

All artboard-tool gestures share these conventions:

- **Drag threshold:** 4 px in either dimension. ≤ 4 px on mouseup →
  click; > 4 px → drag. Matches ZOOM_TOOL.md §Click-vs-drag threshold.
- **Mouse capture:** drag continues if the cursor leaves the canvas
  pane; mouseup outside the pane still commits. Matches HAND_TOOL.md
  §Drag — pan.
- **Cursor refresh:** Alt press / release refreshes the cursor
  synchronously, no mouse movement required. See §Cursor states.
- **Coordinate convention:** the cursor's document point is captured
  at mousedown and held invariant for the gesture (the document point
  under the cursor at mousedown stays under the cursor for the entire
  drag), same model Hand and Zoom-scrubby use.
- **Integer-pt rounding at commit:** all gesture commits round
  bounds to the nearest integer pt. Multi-select drag-to-move rounds
  the displacement vector once and applies it uniformly (preserves
  relative spacing); single-artboard gestures round their own bounds.
  The Dialogue (`X_INPUT`/`Y_INPUT`/`WIDTH_INPUT`/`HEIGHT_INPUT`)
  still accepts fractional pt values; drag is the lossy path.
- **Cancel:** Escape during any drag aborts. Bounds revert to their
  mousedown values; nothing is committed.

### Mousedown disambiguation order

At mousedown, hit-test in this order and stop at the first match:

1. **Resize handle of the panel-selected artboard** (only when
   exactly one artboard is panel-selected, since handles render only
   for single-selection — see §Drag-to-resize). Match → resize gesture.
2. **Artboard interior** — when multiple interiors overlap at the
   cursor, the artboard whose fill paints on top wins (= highest
   position in `document.artboards` order; matches ARTBOARDS.md
   §Canvas appearance fill-stacking rule). Match:
   - Alt held → duplicate gesture (Alt sampled at mousedown).
   - No Alt → move-or-click (resolves at mouseup: past threshold =
     move, sub-threshold = click-to-activate).
3. **Empty canvas** (neither handle nor interior) → create-or-deselect
   (resolves at mouseup: past threshold = drag-to-create,
   sub-threshold = empty-canvas single-click).

This order is what makes Alt-drag-on-a-handle a resize, not a
duplicate — handles win against interior regardless of modifier.

### Drag-to-create

- **Trigger:** mousedown on empty canvas + drag past the threshold.
- **During drag:** an overlay rectangle is painted from the mousedown
  point to the current cursor. The fade-region overlay treats this
  in-flight rectangle as part of the artboard union when
  `update_while_dragging` is on (see §Update while dragging).
- **Mouseup:** create a new artboard with bounds = the drag rect,
  rounded to integer pt and clamped to 1 × 1 pt minimum. Defaults
  inherit from ARTBOARDS.md §Numbering and naming for the name; `fill
  = "transparent"`, all per-artboard display toggles off, fresh `id`.
  Insert at the end of `document.artboards` (so the new artboard's
  `ARTBOARD_NUMBER = N + 1` and it becomes the visually-on-top
  artboard for any overlap region). Panel-selection becomes
  `{new artboard}`; `current_artboard` derives accordingly.
- **Below threshold:** treated as an empty-canvas single-click, no
  artboard created.
- **Modifiers:** none in phase 1. Shift = constrain to square and Alt
  = anchor at center are phase-2 candidates.
- **Cancel:** Escape during the drag aborts; no artboard created.

### Click-to-activate

- **Trigger:** mousedown + mouseup on an existing artboard's interior
  (or on its label region — see §Label hit region) with total drag
  ≤ threshold and Alt not held.
- **Effect:** writes panel-selection per the click rules from
  ARTBOARDS.md §Selection semantics:
  - **Plain click** → `panel_selection = {clicked artboard}`, anchor
    becomes the clicked artboard.
  - **Shift-click** → range from the panel-selection anchor to the
    clicked artboard (anchor unchanged).
  - **Cmd-click** → toggle the clicked artboard in/out of
    panel-selection (anchor unchanged).
- `current_artboard` derives from panel-selection per ARTBOARDS.md;
  the tool never writes `current_artboard` directly.

### Drag-to-move

- **Trigger:** mousedown on artboard interior (not on a handle) +
  drag past threshold + Alt not held.
- **Anchor:** the artboard's `(x, y)` and the cursor's document point
  are captured at mousedown. On each mousemove,
  `new (x, y) = original + (cursor_doc - cursor_doc_at_mousedown)`.
- **Multi-select move:** when multiple artboards are panel-selected
  and the user grabs any of them, all panel-selected artboards
  translate by the same delta. The artboard under the cursor is the
  anchor for the displacement math; non-selected artboards stay.
- **Move/Copy Artwork:** translates contained elements per the rule
  in §Move/Copy Artwork.
- **Modifiers:**
  - **Shift** = constrain to dominant axis (horizontal or vertical,
    switchable as the drag passes 45°). Constraint applies to the
    displacement vector; multi-select still translates uniformly.
- **Live update:** gated by `update_while_dragging` per §Update while
  dragging.
- **Cancel:** Escape reverts to mousedown values.
- **Mouseup:** commits as a single undoable op covering all moved
  artboards (and translated elements, if Move/Copy Artwork is on).
  Displacement vector is rounded to integer pt before commit.

### Drag-to-resize

- **Trigger:** mousedown on a resize handle of the (single)
  panel-selected artboard + drag.
- **Handles:** 8 handles total — 4 corners (NW, NE, SE, SW) and 4
  edge midpoints (N, E, S, W). Rendered in the tool-overlay Z-band
  (above all artboard fills), only when exactly one artboard is
  panel-selected. Multi-select shows no handles; resize is
  single-target only in phase 1.
- **Anchor:** the opposite handle stays fixed by default. Drag the
  right edge → the left edge stays put. Drag the NE corner → the SW
  corner stays put.
- **Modifiers:**
  - **Shift** = lock proportion to the W/H ratio captured at
    mousedown (matches the `CHAIN_LINK_BUTTON` semantics in the
    Dialogue per ARTBOARDS.md §Artboard Options Dialogue).
  - **Alt** = resize from center; the artboard's geometric center
    stays fixed instead of the opposite handle.
  - **Shift+Alt** = both: locked-proportion-from-center.
- **Min size:** hard clamp at 1 pt per dimension; further drag past
  the clamp is ignored until the user drags back the other way. No
  flip-during-drag in phase 1 (crossing the opposite handle is
  blocked at the 1 pt clamp).
- **Live update:** gated by `update_while_dragging` per §Update while
  dragging.
- **Move/Copy Artwork:** does **not** transform contained elements
  even when the toggle is on. Resize is about artboard bounds, not
  artwork transformation. Elements stay at their absolute positions
  and may stick out of shrunken bounds (per ARTBOARDS.md "artboards
  are boundaries, not containers").
- **Cancel:** Escape reverts to mousedown values.
- **Mouseup:** commits as a single undoable op. Final bounds are
  rounded to integer pt.

### Alt-drag duplicate

- **Trigger:** mousedown on artboard interior + Alt held + drag past
  threshold.
- **Effect:** the *original* artboard stays at its `(x, y)`; a new
  artboard is created (deep copy: fresh `id`, fresh `Artboard N` name
  per ARTBOARDS.md §Numbering and naming, all other fields copied)
  and follows the cursor as in drag-to-move. The duplicate appends to
  the end of `document.artboards`.
- **Alt sampled at mousedown** (not continuous). Releasing Alt
  mid-drag does *not* convert the duplicate back into a move — the
  duplicate-in-progress is too consequential a document mutation to
  flip mid-gesture. This intentionally diverges from the
  continuous-modifier convention used by Zoom-scrubby
  (ZOOM_TOOL.md §Drag — scrubby zoom).
- **Move/Copy Artwork:** when on (phase 1 hard-coded on), elements
  fully contained in the source artboard are deep-copied and
  translated to the duplicate's destination per the containment rule
  in §Move/Copy Artwork. Matches the menu Duplicate Artboards
  behavior in ARTBOARDS.md §Menu.
- **Live update:** the duplicate's render obeys
  `update_while_dragging`; the original artboard always renders fully
  at its committed position.
- **Cancel:** Escape reverts; no duplicate created.
- **Mouseup:** commits as a single undoable op including the new
  artboard, the deep-copied elements (if Move/Copy Artwork is on),
  and the duplicate's destination position rounded to integer pt.

### Canvas double-click

- **Trigger:** double-click on an artboard interior or label region.
- **Effect:** opens the Artboard Options Dialogue (per ARTBOARDS.md
  §Artboard Options Dialogue) for the double-clicked artboard. No
  panel-selection side-effect beyond the prior single-click that
  initiated the dblclick sequence.
- **Single-zone:** label and interior both dispatch to the Dialogue.
  Inline rename on canvas is deferred to phase 2 (would require a
  canvas-rendered text-input primitive).
- **On a resize handle:** no-op. Handles respond to drag, not to
  clicks of any count; both clicks of the dblclick sequence are
  sub-threshold mousedown-mouseups.
- **On overlap region:** the topmost-in-stacking artboard (highest
  position in `document.artboards`) wins, mirroring the
  click-to-activate rule.
- **On empty canvas:** no-op (no target). Two empty-canvas
  single-clicks each clear panel-selection; net effect is "cleared."

### Empty-canvas single-click

- **Trigger:** mousedown + mouseup on empty canvas with total drag
  ≤ threshold.
- **Effect:** `panel_selection = {}`, anchor cleared.
  `current_artboard` falls back to the artboard at position 1 per
  ARTBOARDS.md §Selection semantics.

## Hit-test rules

### Overlapping artboards

Per ARTBOARDS.md §Canvas appearance, artboard fills paint in list
order — later artboards paint on top of earlier ones in overlap
regions. Hit-test follows the same rule: when multiple artboard
interiors overlap at the cursor, the artboard whose fill paints on
top wins (= highest position in `document.artboards`). The visually
on-top artboard receives the click, matching user intent.

Resize handles render in the tool-overlay Z-band (above all artboard
fills) and always win against any artboard interior at the same
cursor position (per the disambiguation order). When artboard A is
panel-selected and artboard B's fill paints on top of A, A's handles
still hit-test first; visually they appear on top of B's fill.

Fully nested artboards (one entirely inside another) are reachable
only via the panel: clicking inside the visually-on-top artboard
selects it; the underlying artboard is unreachable on canvas. Use the
Artboards Panel to select it instead.

Drag-to-create requires starting on empty canvas. The rubber-band
rectangle may sweep across existing artboards, and the new artboard's
bounds may overlap them. The new artboard appends to the end of the
list, becoming the visually on-top artboard in any overlap. Cmd-drag
or other modifiers to create-from-inside-an-existing-artboard are
phase-2 candidates if the case surfaces.

### Label hit region

ARTBOARDS.md §Canvas appearance specifies that labels are
non-interactive in phase 1. The Artboard Tool overrides this for its
own hit-test: the label region is treated as part of the parent
artboard's hit shape. Click on a label = click on its parent
artboard; double-click on a label = open Dialogue for the parent;
Alt-drag on a label = duplicate the parent.

The label override is tool-local. Outside of the Artboard Tool
(during Selection, Pen, etc.), labels remain non-interactive.

## Cursor states

| Condition                                              | Cursor                            |
|--------------------------------------------------------|-----------------------------------|
| Idle, hovering empty canvas                            | `crosshair`                       |
| Idle, hovering artboard interior                       | `move` (4-way)                    |
| Idle, hovering a resize handle (single-selected only)  | matching directional resize cursor (table below) |
| Alt held, hovering artboard interior                   | `copy` (move + plus glyph)        |
| Alt held, hovering a resize handle                     | matching directional resize cursor (Alt = resize-from-center) |
| Alt held, hovering empty canvas                        | `crosshair` (Alt has no effect on create-drag in phase 1) |
| During drag-to-create                                  | `crosshair`                       |
| During drag-to-move                                    | `move`                            |
| During drag-to-resize                                  | matching directional resize cursor |
| During Alt-drag duplicate                              | `copy`                            |
| Hovering label region (override above)                 | same as parent artboard interior  |

**Resize handle direction map:**

| Handle position | Cursor          |
|-----------------|-----------------|
| NW corner       | `nwse-resize`   |
| N edge midpoint | `ns-resize`     |
| NE corner       | `nesw-resize`   |
| E edge midpoint | `ew-resize`     |
| SE corner       | `nwse-resize`   |
| S edge midpoint | `ns-resize`     |
| SW corner       | `nesw-resize`   |
| W edge midpoint | `ew-resize`     |

These are CSS-standard cursor names that map to system stocks across
all four toolkits. No custom cursor authoring is required for resize.
The `move` and `copy` cursors are likewise system stocks in macOS,
Web, and Rust toolkits.

**Synchronous Alt refresh.** Alt press and release update the cursor
immediately, no mouse movement required. Required so the user sees
the gesture they're about to perform — same rule Zoom uses
(ZOOM_TOOL.md §Cursor states).

**No grayed/blocked cursor variants in phase 1.** Gestures hard-stop
at limits (resize clamped at 1 pt, Delete blocked by the at-least-one
invariant) without surfacing a cursor change. Symmetric to Hand
(HAND_TOOL.md has no clamp variants either).

**Python tkinter caveat.** The `copy` cursor isn't a tkinter system
stock; Python may fall back to a platform-stock cursor (often `move`)
with a one-line note. Custom-cursor authoring in tkinter is
constrained — flagged as Phase 2 polish if it surfaces. Same caveat
ZOOM_TOOL.md §Cursor states already carries.

## Selection coupling

Per ARTBOARDS.md §Selection semantics, panel-selection is a 0..N set
of artboards tracked by stable `id`, and `current_artboard` derives
as "topmost panel-selected artboard, else artboard at position 1."
The Artboard Tool never writes `current_artboard` directly — every
canvas-side selection effect goes through panel-selection writes:

- Click-to-activate writes panel-selection per the click rules
  (plain / Shift / Cmd) from ARTBOARDS.md §Selection semantics. The
  panel-selection anchor lives in panel-state, not at the click site,
  so a panel click followed by a canvas Shift-click correctly ranges
  across them.
- Empty-canvas single-click clears panel-selection.
- Drag-to-create sets panel-selection to the new artboard.
- Alt-drag duplicate sets panel-selection to the new artboard.
- Drag-to-move and drag-to-resize don't touch panel-selection.

**Resize handles render around the panel-selected artboard, not
around `current_artboard`.** When panel-selection is empty, no
handles render — even though `current_artboard` is non-null via the
position-1 fallback. Multi-select on canvas paints the existing
accent border treatment (per ARTBOARDS.md §Canvas appearance) on each
selected artboard; only single-select adds resize handles on top.

**Mid-drag external panel mutation aborts the drag.** If
panel-selection changes during an active drag (e.g., the user undoes
mid-drag), the active drag aborts and reverts to mousedown values.
Same as Escape-cancel; cleaner than retargeting.

## Move/Copy Artwork

Phase 1 hard-codes Move/Copy Artwork to **on** for both drag-to-move
and Alt-drag duplicate. The toggle UI is deferred to phase 2 (will
land on a shared tool-options-strip primitive when it arrives,
defaulting to on, per-tool-session persistence).

| Gesture            | Gated by Move/Copy Artwork | Behavior in phase 1 |
|--------------------|---------------------------|----------------------|
| Drag-to-move       | Yes                       | Contained elements translate with each moved artboard |
| Alt-drag duplicate | Yes                       | Contained elements deep-copied to the duplicate |
| Drag-to-resize     | **No**                    | Elements never transform during resize, regardless of toggle |
| Click-to-activate  | No                        | No mutation                              |
| Drag-to-create     | No                        | New artboard has no contained elements   |

**Containment rule.** Reuses ARTBOARDS.md §Rearrange Dialogue
"Move-artwork semantics" verbatim — for each leaf element whose
pre-op bounds are fully contained in exactly one artboard's pre-op
bounds, translate (or copy + translate, for duplicate) by that
artboard's displacement. Elements contained in zero or > 1 artboards
don't move. Groups/layers translate as a whole if their combined
bounds are fully contained in one artboard; otherwise the rule
recurses to leaves. Elements in locked layers still translate (lock
prevents editing, not transform).

**Multi-select move:** each panel-selected artboard pulls its own
contained elements per the containment rule. An element fully
contained in one selected artboard moves with it; an element
overlapping two selected artboards stays put (the "exactly one"
clause).

**Asymmetry with menu Duplicate Artboards.** Per ARTBOARDS.md §Menu,
the menu Duplicate Artboards always copies contained elements (no
toggle). Canvas Alt-drag obeys the toggle (when phase 2 lands). In
phase 1 both behave the same way (toggle hard-coded on); the
asymmetry surfaces only when the phase-2 toggle UI arrives.

## Update while dragging

ARTBOARDS.md §Canvas appearance declares `update_while_dragging` as a
per-document flag (default on) with phase-1 no-op behavior pending
this tool. The Artboard Tool activates the flag; the rendering
contract is:

| `update_while_dragging` | Render during drag                                                                       | Document state writes |
|-------------------------|-------------------------------------------------------------------------------------------|----------------------|
| **On** (default)        | Full live re-render at every mousemove: artboard fill, border, label, marks, contained elements (per Move/Copy Artwork), and fade region all paint at the in-flight position. | Continuously — every mousemove writes the new bounds. |
| **Off**                 | Original artboard keeps painting at its committed bounds. A 1-px screen-space outline rectangle (theme accent color, matching ARTBOARDS.md §Canvas appearance accent border) previews the in-flight position. Contained elements don't move. Fade region stays at the pre-drag union. | Only on mouseup — bounds writes happen once at commit. |

**Gestures gated by the toggle:**

| Gesture            | Gated? | Notes |
|--------------------|--------|-------|
| Drag-to-move       | Yes    |       |
| Drag-to-resize     | Yes    | Outline preview tracks in-flight `(x, y, w, h)`; resize handles render on the outline so the user has something to "hold" visually. |
| Alt-drag duplicate | Yes    | The duplicate's render obeys the toggle; the original always renders fully. |
| Drag-to-create     | **No** | No "original" exists; the in-flight rectangle is the only thing to render regardless of toggle. |
| Click-to-activate  | No     | No drag.    |

**Fade-region re-mask** (per ARTBOARDS.md §Canvas appearance for the
steady-state behavior): tied to `update_while_dragging`. When on, the
union of artboard bounds is recomputed every mousemove using
**in-flight** bounds (move's new `(x, y)`, resize's new `(x, y, w,
h)`, the create-drag rectangle, the duplicate's destination). When
off, the union freezes at pre-drag bounds and the fade snaps to the
new union on mouseup. When `fade_region_outside_artboard` is itself
off entirely, this section is a no-op regardless of
`update_while_dragging`.

**Performance note.** Fade re-masking and contained-element
re-rendering are the most expensive parts of the per-frame loop.
Users on heavy documents (many elements per artboard, large viewport)
benefit from setting `update_while_dragging` to off in the
Dialogue — outline-only preview drops per-frame work to a single
overlay rect and snaps the rest at mouseup.

## Delete behavior

While the Artboard Tool has the canvas-pane focus context,
`Delete` and `Backspace` follow a fall-through rule:

1. If panel-selection is non-empty → delete the panel-selected
   artboards. Subject to the at-least-one invariant per ARTBOARDS.md
   §At-least-one-artboard invariant: blocked when panel-selection
   spans all existing artboards, with the standard tooltip
   `At least one artboard must remain.` The block is surfaced (no
   silent swallow); fall-through to `delete_selection` does **not**
   apply when blocked.
2. Else (panel-selection empty) → fall through to the global
   `delete_selection` action (deletes element-selection).

Other delete-invariant edges are already covered by existing rules
and need no special handling here:

| Edge | Why safe |
|------|----------|
| Drag-to-create then immediate undo | Count drops from N+1 back to N where N ≥ 1 (invariant guaranteed N before create). |
| Drag-to-create then Escape         | No artboard created; count unchanged. |
| Drag-to-move dropping artboard off-viewport | Artboard still exists at off-screen coordinates; reachable via panel or `fit_all_artboards`. |
| Drag-to-resize clamped at 1 × 1 pt | Artboard still exists at minimum size. |
| Alt-drag duplicate `id` collision  | `id` is 8-char base36 random; collision probability negligible. |

## State persistence

The Artboard Tool reads and writes:

| Key                                       | Tier            | Type   | Default | Notes |
|-------------------------------------------|-----------------|--------|---------|-------|
| `document.artboards[*]`                   | document        | list   | per ARTBOARDS.md | Each entry per ARTBOARDS.md §Artboard data model. Tool creates, mutates, and deletes entries. |
| `document.artboard_options.update_while_dragging` | document  | bool   | `true`  | Activated by this tool (no longer phase-1 no-op). See §Update while dragging. |
| `document.artboard_options.fade_region_outside_artboard` | document | bool | `true` | Read by this tool during drag for fade-region behavior. Field semantics owned by ARTBOARDS.md. |
| `panel.artboards.selection`               | runtime context | list of `id` | `[]` | Tool writes per §Selection coupling. |
| `panel.artboards.anchor`                  | runtime context | `id` or null | null | Tool updates on plain click; preserved on Shift / Cmd click. |

The tool introduces no new state keys. All tool behavior derives from
existing fields declared by ARTBOARDS.md.

## Cross-spec edits

The Artboard Tool spec landing must come with these edits to
`transcripts/ARTBOARDS.md`, in the same PR:

1. **§Canvas appearance, `update_while_dragging` paragraph.** Strike
   the "phase-1 no-op (no canvas artboard drag exists yet). Persisted
   for the Artboard Tool." parenthetical. New wording: cross-reference
   ARTBOARD_TOOL.md §Update while dragging for the per-state rendering
   contract.
2. **§Phase-1 deferrals summary.** Remove the
   `update_while_dragging` deferral entry (the deferral is resolved).
3. **§Phase-1 deferrals summary, Artboard Tool entry.** Strike the
   "Artboard Tool — canvas-side create, click-to-activate,
   drag-to-move, drag-to-resize." entry (deferral is resolved). Note
   that Convert to Artboards and the Rearrange Dialogue remain
   deferred per their existing entries.

## Cross-app artifacts

- `workspace/tools/artboard.yaml` — new tool spec (id `artboard`,
  cursor set per §Cursor states, gesture handlers per §Gestures,
  shortcut `Shift+O` with `O` alias, keyboard handler intercepting
  `Delete` / `Backspace` per §Delete behavior, commit-time integer-pt
  rounding annotation).
- `workspace/icons.yaml` — new `artboard:` entry with the artboard
  glyph SVG.
- `workspace/layout.yaml` — new `btn_artboard_slot` at row 4 col 1.
  Click = select Artboard. Double-click invokes `fit_all_artboards`.
  No long-press timer (no alternates flyout in phase 1).
- `workspace/shortcuts.yaml` — `Shift+O` and `O` (alias) bindings for
  `select_tool` with `tool: artboard`.
- `workspace/cursors.yaml` — references to standard cursor names
  (`move`, `copy`, `crosshair`, `ns-resize`, `ew-resize`,
  `nesw-resize`, `nwse-resize`). No new SVG cursor authoring.
- `workspace/runtime_contexts.yaml` — no new context state. Tool
  reads/writes `document.artboards` and `panel.artboards.selection`,
  both already declared.
- `algorithms/artboard_drag_apply` — new shared algorithm primitive
  housing the in-flight bounds math (move, resize with anchor +
  modifier rules, duplicate displacement). Shape:
  `(artboard, gesture_kind, mousedown_state, cursor_doc, modifiers)
  → new_bounds`. Integer-pt rounding applied at commit. Same
  per-language sharing pattern `algorithms/zoom_apply` uses
  (ZOOM_TOOL.md §Cross-app artifacts).
- New effects:
  - `doc.artboard.create { rect, defaults }` → new artboard (used by
    drag-to-create commit).
  - `doc.artboard.set_bounds { id, x, y, w, h }` → mutate bounds (used
    by move and resize commit; multi-select expands to N effects in a
    single undo entry).
  - `doc.artboard.duplicate { id, dx, dy, copy_elements }` → new
    artboard from a source plus optional element deep-copy + translate
    (used by Alt-drag duplicate commit).
  - `doc.artboard.delete { ids }` already exists for the panel delete
    path; reused for the canvas Delete/Backspace fall-through.

## Phase 1 / Phase 2 split

### Phase 1 (this spec)

- Drag-to-create from empty canvas (rubber-band rect, 4 px threshold,
  Escape cancel, integer-pt rounding at commit, no modifiers).
- Click-to-activate (plain / Shift / Cmd click on artboard or label
  region; click on empty canvas clears panel-selection).
- Drag-to-move (interior drag; multi-select moves all selected;
  Shift = constrain to dominant axis; displacement-rounded to integer
  pt at commit).
- Drag-to-resize (handle drag, single-select only — handles hidden
  for multi-select; 8 handles; Shift = lock proportion; Alt = resize
  from center; Shift+Alt = both; clamp at 1 pt min).
- Alt-drag duplicate (Alt sampled at mousedown, not continuous;
  contained elements deep-copied per the containment rule;
  integer-pt rounding at commit).
- Mousedown disambiguation order: handle > artboard interior > empty
  canvas. Highest position in `document.artboards` wins on overlap.
- Move/Copy Artwork hard-coded "on" — drag-to-move translates
  contained elements; Alt-drag duplicate copies them; drag-to-resize
  never transforms elements; toggle UI deferred.
- Shortcut: `Shift+O` canonical, `O` alias.
- Toolbar slot: row 4 col 1, standalone (no alternates flyout).
- Toolbar dblclick → `fit_all_artboards`.
- Canvas dblclick on artboard → open Artboard Options Dialogue
  (single-zone; label region treated as parent artboard).
- `update_while_dragging` activated: live mode re-renders artboard +
  contained elements + fade region every mousemove; preview mode
  shows outline-only and snaps to new geometry on commit.
- Fade-region re-mask gated by `update_while_dragging`; in-flight
  bounds count for the union when in live mode (including
  drag-to-create's in-flight rectangle).
- Cursor states: 11-state table per §Cursor states; standard CSS
  cursor names (system stocks); synchronous Alt refresh. No grayed /
  blocked variants — gestures hard-stop at limits.
- `Delete` / `Backspace` within tool's focus context: panel-selection
  non-empty → delete panel-selected artboards (subject to
  at-least-one invariant with standard tooltip); else fall through to
  `delete_selection`.
- Cross-spec edits in same PR per §Cross-spec edits.
- Per-app implementation order: Rust → Swift → OCaml → Python.

### Phase 2 (deferred)

- **Move/Copy Artwork toggle UI.** Per-tool-session checkbox on a
  shared tool-options-strip primitive that doesn't yet exist. Default
  on. Toggle off lets users move artboards without translating
  contained elements.
- **Inline rename on canvas.** Dblclick on the label region opens an
  inline text editor instead of the Options Dialogue. Awaits a shared
  canvas-rendered text-input primitive that nothing else needs in
  phase 1.
- **Multi-select resize.** Handles render only when exactly one
  artboard is panel-selected in phase 1; multi-resize requires an
  anchor-and-modifier design that's worth its own pass.
- **Modifiers during drag-to-create.** Shift = constrain to square,
  Alt = anchor at center. Standard in comparable applications.
- **Flip-during-resize-drag.** Crossing the opposite handle flips the
  artboard's logical orientation. Phase 1 hard-stops at the 1 pt min
  clamp instead.
- **Tab-key cycling between artboards while tool is active.** Adds a
  focus model the canvas doesn't otherwise carry.
- **Dimensional readout HUD during drag.** A cursor-following tooltip
  showing live `X / Y / W / H` values in pt.
- **Alignment snapping to other artboards' edges / centers.**
  Requires a shared snap primitive that no other tool yet needs;
  build coordinated, not per-tool.
- **Snap to grid.** Awaits the grid feature itself.
- **Snap to guides.** Awaits the guides feature itself.
- **Snap-line visual indicators during drag.** Coupled with the snap
  primitive.
- **Modifier to suppress snap / allow sub-pt drag.** Bundled with the
  snap primitive's modifier semantic.
- **Cmd-drag (or similar modifier) to create-from-inside-an-existing-artboard.**
  Phase 1 requires the drag to start on empty canvas.
- **Long-press alternates flyout at row 4 col 1.** If a Print Tiling
  Tool ever lands (per HAND_TOOL.md §Phase 2 deferred), it could
  share the Artboard slot via the same long-press pattern Hand+Zoom
  use. Phase 1 keeps the slot standalone.

Two items already specified in ARTBOARDS.md as deferred remain so and
are not re-listed here:

- **Convert to Artboards** — see ARTBOARDS.md §Menu.
- **Rearrange Dialogue** — see ARTBOARDS.md §Rearrange Dialogue
  (deferred).

## Related

- **Artboards Panel** — the panel side of artboards. Owns
  panel-selection rules (which the tool writes via §Selection
  coupling), per-artboard data model, the Artboard Options Dialogue
  (which the tool opens on canvas dblclick), the at-least-one
  invariant, naming/numbering, and the Z-ordered canvas appearance
  rules. See `transcripts/ARTBOARDS.md`.
- **Hand Tool** — shares the bottom-row navigation neighborhood
  (row 4 col 0). The Hand-via-spacebar pass-through still works while
  the Artboard Tool is active. See `transcripts/HAND_TOOL.md`.
- **Zoom Tool** — alternate in the row 4 col 0 slot. The
  `fit_all_artboards`, `fit_active_artboard`, and
  `zoom_to_actual_size` actions added by Zoom are reused by this
  tool's toolbar dblclick. See `transcripts/ZOOM_TOOL.md`.
- **View menu** — `fit_all_artboards`, `fit_active_artboard`, and
  `zoom_to_actual_size` (defined in ZOOM_TOOL.md §Keyboard shortcuts
  and actions) work regardless of which tool is active.
