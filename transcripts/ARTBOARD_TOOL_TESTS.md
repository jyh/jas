# Artboard Tool — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/artboard.yaml`. Design doc:
`transcripts/ARTBOARD_TOOL.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other
platforms covered in the parity sweep once Swift / OCaml / Python
phases land per the propagation order in `CLAUDE.md`.

---

## Known broken

_Last reviewed: 2026-04-25_

- **Document-aware coordinate handling** — probe_hit, probe_hover,
  move_apply, resize_apply, and duplicate_init all treat input
  `(x, y)` as document coordinates (matching the convention
  partial_selection's helpers use). The canvas widget passes
  viewport-local pixel coordinates from the DOM event without
  conversion. At any non-identity view transform (zoom != 1 or
  view_offset != 0), gesture targeting is offset by the inverse
  transform. Rust + Swift + OCaml + Python all share this
  cross-cutting issue. Fix: event-coord conversion at the dispatch
  boundary, or making the helpers view-aware. Out of Phase 1 scope.
- **Toolbar dblclick → fit_all_artboards** — wired through
  `tool_options_action` per the toolbar dispatcher convention. Per-
  app implementation that reads tool_options_action and dispatches
  the action exists for Hand / Zoom; Artboard reuses the same path.
  Verified via the same code paths as Hand / Zoom dblclicks.
- **Group / Layer recursion under Move/Copy Artwork** — the spec's
  "groups/layers translate as a whole if their combined bounds are
  fully contained in one artboard; otherwise the rule recurses to
  leaves" rule is partially implemented. Phase 1 iterates each
  top-level layer's direct children (treating each as a top-level
  element for containment); recursion-into-nested-groups for the
  layer-spans-multiple-artboards case is a refinement.
- **at-least-one-invariant tooltip** — Delete is silently blocked
  when the panel-selection spans every artboard. The spec calls for
  a `At least one artboard must remain.` tooltip; today the block
  is silent (the wider tooltip-surface plumbing is deferred).
- **`update_while_dragging = false` outline preview** — phase 1 ships
  a simple stroked rectangle around the in-flight artboard. The
  refinements from the spec (handle previews on the outline, live
  dimension HUD) are phase 2.
- **Multi-select resize** — handles render only when exactly one
  artboard is panel-selected; multi-select shows accent borders
  but no handles per spec. Multi-resize itself is a phase-2
  deferral with its own design pass.
- **Idle-Alt cursor flip** — at idle (no drag), hovering an artboard
  interior with Alt held should immediately flip the cursor from
  `move` to `copy`. Today the cursor refreshes on the next mouse
  event. Per-app keyboard hooks needed to detect Alt independently
  of mouse events (same shape as the Zoom-tool deferral).
- **Modifiers during drag-to-create** — Shift = constrain to square,
  Alt = anchor at center. Both deferred per spec.
- **Flip-during-resize-drag** — crossing the opposite handle past
  the 1pt clamp should flip the artboard. Phase 1 hard-stops at
  clamp per spec.
- **Snapping** — alignment-snap to other artboards' edges / centers,
  to grid, to guides — all deferred per spec. Phase 1 ships
  integer-pt rounding only at commit.
- **Inline rename on canvas** — phase 1 dblclick on artboard opens
  the Artboard Options Dialogue (single-zone). Inline rename of the
  label is phase 2 (requires a canvas-rendered text-input
  primitive).
- **Tab-key cycling between artboards while tool is active** —
  phase 2 deferral.
- **Move/Copy Artwork toggle UI** — hard-coded "on" in phase 1 per
  spec. Phase 2 adds a per-tool-session checkbox on a shared tool-
  options strip (which doesn't exist yet).
- **Swift / OCaml / Python** — implementations pending per the
  propagation chain.
- **Flask** — no canvas subsystem; tool not applicable.

---

## Automation coverage

_Last synced: 2026-04-25_

**Effects (`doc.artboard.*`)** — Rust unit tests in
`jas_dioxus/src/interpreter/effects.rs` (#[cfg(test)] block):

- `doc.artboard.create_commit`: 4 tests (basic, negative drag,
  1pt min clamp, integer-pt rounding).
- `doc.artboard.move_apply`: 3 tests (single-target translate,
  idempotence over repeated calls, Shift-axis constrain) plus 1 for
  Move/Copy Artwork element translation.
- `doc.artboard.resize_apply` via `artboard_resize_compute`:
  11 helper tests (no-modifier corner / edge / clamp; Alt-center
  corner + edge; Shift-lock-proportion corner + edge; Shift+Alt
  combined).
- `doc.artboard.duplicate_init`: 2 tests (basic source-cloning +
  hit_artboard_id retarget; deep-copy of contained elements).
- `doc.artboard.probe_hit`: 4 tests (interior writes panel-
  selection; empty canvas clears; Shift no-anchor fallback;
  Cmd-toggle).
- `doc.artboard.probe_hover`: 1 test (interior / empty
  classification).
- `doc.artboard.delete_panel_selected`: 2 helper tests (partial
  delete; at-least-one invariant block).

Total: ~28 tests. Swift / OCaml / Python equivalents to be authored
when those phases run.

**Tool enum membership** — Rust
`tools::tool::tests::tool_kind_variant_count` includes
`ToolKind::Artboard`; Rust
`tools::tool::tests::artboard_label_and_shortcut` confirms label
and Shift+O shortcut.

---

## Preconditions (assumed for every session)

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document (Letter artboard at origin).
3. Appearance: **Dark**.
4. Default tool active (Selection); switch to Artboard via Shift+O
   or the toolbar at row 4 col 1 at the start of each session.
5. View transform: identity (zoom = 1.0, offset = 0). Adjust if a
   session calls for non-identity.

---

## Session A — Tool registration and toolbar slot

**A.1** Press `Shift+O`. Active tool changes to Artboard. Cursor
becomes `crosshair`. Toolbar slot at row 4 col 1 lights up with the
checked-bg.

**A.2** Press `O` (no Shift). Same activation — both shortcuts
target the Artboard tool per the alias from spec §Shortcut.

**A.3** Click the toolbar icon at row 4 col 1. Activates Artboard.

**A.4** Double-click the toolbar icon. Invokes
`fit_all_artboards`: viewport zooms + pans to fit the union of all
artboard rectangles. Distinct from Hand-icon dblclick
(`fit_active_artboard`) and Zoom-icon dblclick
(`zoom_to_actual_size`).

**A.5** With another tool active (e.g. Selection via `V`), Artboard
slot is unlit. Switching back to Artboard re-lights the slot.

---

## Session B — Click-to-activate (selection coupling)

Setup: create a second artboard via the panel's New Artboard so
there are at least 2 in document.artboards.

**B.1** Click on artboard 1's interior. Panel-selection becomes
`{artboard 1}`; the Artboards Panel shows artboard 1 highlighted.
Anchor is artboard 1.

**B.2** Click on artboard 2's interior. Panel-selection becomes
`{artboard 2}`; anchor moves to artboard 2.

**B.3** Shift-click artboard 1. Range-select from anchor (artboard
2) back to artboard 1 → both artboards selected. Anchor unchanged
(still artboard 2).

**B.4** Cmd-click artboard 2. Toggles artboard 2 OUT → only
artboard 1 selected. Anchor unchanged.

**B.5** Cmd-click artboard 2 again. Toggles back IN → both
selected.

**B.6** Click on empty canvas (away from any artboard). Panel-
selection clears (`{}`); anchor cleared. The Artboards Panel shows
no rows highlighted.

**B.7** Click on a label region (above the top-left of an artboard).
Treated as a click on the parent artboard per the label-hit-region
override. Selects the parent.

---

## Session C — Drag-to-create

**C.1** With panel-selection cleared (click empty canvas), drag from
empty canvas across the viewport. A blue marquee outline tracks the
drag. On release, a new artboard is created with bounds matching
the drag rect (rounded to integer pt). The new artboard appears in
the Artboards Panel as the last entry; panel-selection auto-updates
to the new artboard.

**C.2** Drag with cursor moving up-left of press (negative-direction
drag). Same rect — bounds use min/max of press and cursor.

**C.3** Drag and release within the 4 px threshold. No artboard
created; the canvas remains unchanged. Panel-selection stays
cleared (the empty-canvas click rule).

**C.4** Press Escape during a drag-to-create. Marquee disappears;
no artboard created.

**C.5** Drag from a region overlapping an existing artboard (start
must be on empty canvas). The new artboard's rect may overlap the
existing one; the new artboard appends to the end of the list and
becomes the visually-on-top artboard.

---

## Session D — Drag-to-move

Setup: a single artboard, panel-selected.

**D.1** Drag from the artboard's interior to a new location. The
artboard follows the cursor live (per default
`update_while_dragging = true`). On release, the artboard commits
at the displacement-rounded position.

**D.2** Press Escape during the drag. Artboard reverts to its pre-
drag position.

**D.3** Hold Shift during drag and move the cursor diagonally. The
artboard constrains to the dominant axis (horizontal or vertical).
Crossing 45° while holding Shift switches the constrained axis.

**D.4** Multi-select two artboards (panel + Cmd-click). Drag from
one of them. Both translate by the same delta (the displacement
vector is rounded once, applied uniformly — relative spacing
preserved).

**D.5** Place a small rect inside the artboard. Drag the artboard.
The rect follows the artboard (Move/Copy Artwork hard-coded on per
spec).

**D.6** Place a rect that straddles two artboards (overlap region).
Drag one artboard. The straddling rect doesn't move ("exactly one
artboard" rule fails).

**D.7** Place a rect outside any artboard. Drag any artboard. The
outside rect doesn't move ("exactly one" rule fails — count is 0).

---

## Session E — Drag-to-resize

Setup: a single artboard, panel-selected. The 8 resize handles
should render as small white squares with blue borders at the four
corners and four edge midpoints.

**E.1** Drag the SE corner outward. Width and height increase; NW
corner stays anchored.

**E.2** Drag the NW corner inward. SE corner stays anchored;
width / height shrink.

**E.3** Drag an N edge handle. Only the y / height change; x and
width unchanged.

**E.4** Drag any handle past the opposite handle. Resize hard-stops
at the 1 pt minimum (no flip per phase 1).

**E.5** Hold Shift while dragging an SE corner. Lock proportion to
the original W/H ratio. The dominant cursor axis (proportional to
orig_w / orig_h) drives the resize; the other axis follows.

**E.6** Hold Alt while dragging an SE corner. Resize from center —
the center stays fixed; both corners move equally.

**E.7** Hold Shift+Alt while dragging an SE corner. Both: center
anchored, dimensions in ratio.

**E.8** Hold Shift while dragging an E edge handle. Width follows
cursor; height adjusts to maintain ratio; vertical center stays.

**E.9** Hold Alt while dragging an E edge handle. Width expands
symmetrically around the horizontal center; height unchanged.

**E.10** Press Escape during a resize. Bounds revert to mousedown
values.

**E.11** With multiple artboards panel-selected, no handles render.
Resize is single-target per phase 1.

---

## Session F — Alt-drag duplicate

Setup: a single artboard, panel-selected, with a small rect inside
it.

**F.1** Hold Alt and drag from the artboard's interior. A duplicate
artboard appears at the source position immediately on threshold
crossing; the duplicate follows the cursor. The contained rect is
deep-copied and follows the duplicate. Source artboard and source
rect stay in place.

**F.2** Release. Duplicate commits at the displacement-rounded
position. Document now has source + duplicate artboards (and source
rect + duplicate rect, if Move/Copy Artwork applied).

**F.3** Press Escape during the drag. Duplicate and copies removed
via the preview snapshot restore.

**F.4** Release Alt mid-drag. The gesture continues as a duplicate
(Alt sampled at mousedown only per spec; duplicate too consequential
to flip mid-drag).

**F.5** Alt-drag an artboard with no contained elements. Duplicate
created with no element copies.

---

## Session G — Delete

**G.1** Single artboard panel-selected, press Delete. Artboard
deleted; panel-selection clears (or auto-targets the next artboard
per the panel rules).

**G.2** Multi-select two artboards. Press Backspace. Both deleted.

**G.3** Select all artboards (Cmd+A in panel, or panel-select
every row). Press Delete. Silent no-op (the at-least-one invariant
blocks; tooltip-surface deferred).

**G.4** No artboards panel-selected, but element-selection has a
path. Press Delete. Falls through to `delete_selection` — element
deletes; artboards untouched.

---

## Session H — Cursor states

**H.1** Hover empty canvas. Cursor is `crosshair`.

**H.2** Hover an artboard interior (not on a handle). Cursor is
`move`.

**H.3** Hover an artboard interior with Alt held (after a mouse
move). Cursor is `copy`.

**H.4** Hover each of the 8 resize handles (single panel-selected
artboard). Cursors:

- NW / SE → `nwse-resize`
- NE / SW → `nesw-resize`
- N / S   → `ns-resize`
- E / W   → `ew-resize`

**H.5** During a drag-to-move, cursor stays `move` regardless of
where the cursor is.

**H.6** During a drag-to-resize, cursor stays as the matching
directional resize cursor.

**H.7** During an Alt-drag duplicate, cursor stays `copy`.

---

## Session I — Canvas double-click

**I.1** Dblclick on an artboard interior. Opens the Artboard
Options Dialogue for that artboard.

**I.2** Dblclick on a label region. Opens the Dialogue for the
parent artboard (same path as interior dblclick).

**I.3** Dblclick on a resize handle. No-op (handles respond to
drag, not to clicks of any count).

**I.4** Dblclick on empty canvas. No-op.

**I.5** Dblclick on overlapping region (two artboards). Opens the
Dialogue for the topmost-in-list (visually-on-top) artboard.

---

## Session J — Update while dragging toggle

Setup: open Artboard Options Dialogue for any artboard. Set
`Update while dragging` = OFF. Close.

**J.1** Drag-to-move. Original artboard stays at committed position;
a thin blue outline rectangle previews the in-flight position. On
release, the artboard snaps to the new position.

**J.2** Drag-to-resize. Outline preview tracks the in-flight
bounds; original artboard's fill stays at committed bounds. On
release, snaps.

**J.3** Re-enable `Update while dragging` and verify drags are now
live (artboard fill follows cursor continuously). Confirms toggle
gates the rendering, not the underlying gesture math.

---

## Session K — Overlap and edge cases

**K.1** Two artboards overlap. Click on the overlap region. The
later-in-list artboard wins (visually-on-top per the fill-stacking
rule).

**K.2** Same overlap. Drag-to-move grabs the later-in-list artboard.

**K.3** Click on a region covered by an unselected artboard. Even
if its handles render at that position (because a different
artboard is panel-selected), handles win against interior — the
hit-test resolves to the resize gesture.

---

## Session L — Cross-app parity (deferred)

Sessions L.1–L.N to be authored when Swift, OCaml, Python
implementations land. Procedure: re-run sessions A–K against each
app, log differences, file divergence as bugs.

---

## Run logs

_To be filled in by manual-run executors. Each entry: date,
platform, sessions covered, observations, deferred-bug links._

- _(no runs yet)_
