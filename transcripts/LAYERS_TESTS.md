# Layers Panel — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/panels/layers.yaml` plus `workspace/dialogs/layer_options.yaml`.
Design doc: `transcripts/LAYERS.md`.

Primary platform for manual runs: **Flask (jas_flask)** — most fully wired
panel surface today. Native apps (Rust / Swift / OCaml / Python) have menu +
action dispatch wiring; UI rendering / drag-drop / search / cascades vary
by app and are covered in Session N parity.

---

## Known broken

_Last reviewed: 2026-04-19_

_No known-broken items. Native apps surface coverage gaps rather than
regressions; gaps are documented per-app in Session N._

---

## Automation coverage

_Last synced: 2026-04-19_

**Python — `jas/workspace_interpreter/tests/test_phase3_semantics.py`** (~86 tests)
- Action dispatch: New Layer (with / without selection), New Group wraps
  panel selection, Delete Selection, Duplicate, Collect in New Layer,
  Flatten Artwork, Enter / Exit Isolation Mode.
- Layer Options dialog: edit-mode update of an existing layer, create-mode
  append.

**Python — `jas/workspace_interpreter/tests/test_state_store.py`** (~44)
- Generic state-store coverage; panel_selection / isolation_stack init and
  update transitions.

**Rust — `jas_dioxus/src/panels/layers_panel.rs`** (~10 unit tests)
- Menu structure: New Layer, New Group, visibility / outline / lock toggles,
  Isolation Enter / Exit, Flatten + Collect, Close are all present.
- Dispatch: Close removes the panel.

**Swift — `JasSwift/Tests/Panels/LayersPanelTests.swift`** (~15 tests)
- YAML action dispatch: toggle-all visibility / outline / lock; New Layer
  no-selection vs above-selection; Delete + Duplicate selection; New Group
  wraps selection; Flatten preserves siblings; Collect in New Layer; Enter
  + Exit Isolation Mode.

**OCaml — `jas_ocaml/test/panels/panel_menu_test.ml`**
- Menu structure mirrors Rust + Swift; dispatch wiring transitively
  exercised. No Layers-specific deep coverage.

**Flask — no dedicated layers tests.** Panel rendered by the generic YAML
interpreter; the test suite covers the framework but not Layers-specific
behavior.

The manual suite below covers what auto-tests don't: actual tree
rendering, eye / lock / twirl button clicks, inline rename flow, search
+ filter, drag-and-drop constraints, visibility / lock cascade, solo
state machine, isolation breadcrumb navigation, color-label cycling,
Layer Options dialog interaction, theming, keyboard navigation, cross-
panel regressions.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_flask` for sessions A–M; per-app for N).
2. Open a default workspace with a fresh document (default fixture: one
   "Layer 1" with no children, color = Light Blue).
3. Open the Layers panel via Window → Layers (or the default layout's
   docked location).
4. Appearance: **Dark** (`workspace/appearances/`).

Tests that need a richer tree fixture build it inline (Rectangle tool
draws a few shapes; Object → Group; etc.) or state the delta on a
`Setup:` line.

---

## Tier definitions

- **P0 — existential.** If this fails, the panel is broken. Crash, layout
  collapse, complete non-function. 5-minute smoke confidence.
- **P1 — core.** Control does its primary job (click / drag / enter / select
  / toggle).
- **P2 — edge & polish.** Bounds, keyboard-only paths, focus / tab order,
  appearance variants, mutual-exclusion display, icon states.

---

## Session table of contents

| Session | Topic                                | Est.  | IDs        |
|---------|--------------------------------------|-------|------------|
| A       | Smoke & lifecycle                    | ~5m   | 001–009    |
| B       | Tree row controls                    | ~8m   | 010–029    |
| C       | Visibility cycle + solo              | ~8m   | 030–049    |
| D       | Lock cascade                         | ~6m   | 050–069    |
| E       | Inline rename + keyboard nav         | ~5m   | 070–089    |
| F       | Search + type filter                 | ~8m   | 090–119    |
| G       | Drag-and-drop reordering             | ~10m  | 120–149    |
| H       | Menu — New Layer / Group / All       | ~8m   | 150–179    |
| I       | Isolation mode + breadcrumb          | ~10m  | 180–209    |
| J       | Context menu                         | ~5m   | 210–229    |
| K       | Layer Options dialog                 | ~12m  | 230–269    |
| L       | Color label cycling                  | ~5m   | 270–289    |
| M       | Appearance theming                   | ~5m   | 290–309    |
| N       | Cross-app parity                     | ~15m  | 400–429    |

Full pass: ~110 min. A gates the rest; otherwise sessions stand alone.

---

## Session A — Smoke & lifecycle (~5 min)

If any P0 here fails, stop and flag.

- [x] **LYR-001** [wired] Panel opens via Window menu.
      Do: Select Window → Layers.
      Expect: Layers panel appears in dock or floating; default "Layer 1"
              row is visible; no console error.
      — last: 2026-05-01 (Rust)

- [x] **LYR-002** [wired] All panel sections render without layout collapse.
      Do: Visually scan the open panel.
      Expect: Search input + filter dropdown header; tree body with at
              least one row; footer button row. No overlapping controls,
              no truncated names.
      — last: 2026-05-01 (Rust)

- [x] **LYR-003** [wired] Panel collapses and re-expands.
      Do: Click the panel header to collapse; click again to expand.
      Expect: Content hides / reveals; header stays visible; no crash.
      — last: 2026-05-01 (Rust)

- [x] **LYR-004** [wired] Panel closes via context menu / X button.
      Do: Right-click header → Close, or click the close affordance.
      Expect: Panel disappears; Window → Layers reopens it.
      — last: 2026-05-01 (Rust)

- [x] **LYR-005** [wired] Panel floats out of the dock.
      Do: Drag the panel header out of the dock.
      Expect: Becomes a floating window; controls remain interactive;
              returns to dock on drag back.
      — last: 2026-05-01 (Rust)

- [x] **LYR-006** [wired] Default document has exactly one Layer 1.
      Setup: Fresh document.
      Expect: Tree body shows one row labeled "Layer 1"; color square
              shows Light Blue (`#4a90d9`).
      — last: 2026-05-01 (Rust)

---

## Session B — Tree row controls (~8 min)

**P0**

- [x] **LYR-010** [wired] Each row renders 7 controls in expected order.
      Setup: Default Layer 1 + a Rectangle child.
      Do: Inspect a row.
      Expect: Eye, lock, twirl, 32px preview thumbnail, name label,
              selection square (12px). No truncation; consistent column
              widths.
      — last: 2026-05-01 (Rust)

- [x] **LYR-011** [wired] Twirl is hidden but space preserved on a leaf row.
      Setup: A leaf rectangle row.
      Expect: No twirl glyph rendered; the row still aligns vertically
              with parent rows that DO have twirls.
      — last: 2026-05-01 (Rust)

**P1**

- [x] **LYR-012** [wired] Click a row updates panel selection (not canvas
  selection).
      Setup: Layer 1 with one Rectangle.
      Do: Click the Rectangle row.
      Expect: Row gains the panel-selection highlight (background fills
              with the layer color). Canvas selection is NOT changed —
              menu operations referring to "selected" items act on
              panel selection, per layers.yaml description. Resize
              handles only appear if canvas-selection separately
              follows (e.g., via LYR-013 reverse direction).
      — last: 2026-05-01 (Rust)
      regression: original spec conflated panel selection with canvas
        selection; corrected 2026-05-01 to match layers.yaml.

- [x] **LYR-013** [wired] Selecting on canvas highlights the row.
      Setup: Multiple rows.
      Do: Click a shape directly on canvas.
      Expect: Its row gains a selection highlight; row scrolls into view
              if off-screen; ancestor groups auto-expand.
      — last: 2026-05-01 (Rust)

- [x] **LYR-014** [wired] Shift-click extends panel selection (range).
      Setup: 4 elements in one layer.
      Do: Click row 1; Shift-click row 4.
      Expect: Rows 1–4 all highlighted in the panel.
      — last: 2026-05-01 (Rust)

- [x] **LYR-015** [wired] Cmd / Ctrl-click toggles individual rows.
      Setup: Multi-selection across non-contiguous rows.
      Do: Cmd/Ctrl-click an already-selected row.
      Expect: That row deselects; others remain.
      — last: 2026-05-01 (Rust)
      regression: Cmd-click on an already-selected row used to invoke
        the drag-and-drop reorder path because on_mousedown set
        layers_drag_target unconditionally and on_mouseup treated any
        non-None target as a completed drop. Added layers_drag_source
        field; on_mouseup now bails when target == source (no
        mouseenter on a different row → no drag).

**P2**

- [x] **LYR-020** [wired] Plain click clears multi-selection.
      Setup: 3 rows selected.
      Do: Plain click a 4th row.
      Expect: Only the 4th row remains selected.
      — last: 2026-05-01 (Rust)

- [x] **LYR-021** [wired] Element preview is a 32px thumbnail with white bg.
      Setup: A colored rectangle child.
      Do: Inspect the preview cell.
      Expect: Roughly 32px raster preview of the element on a white
              background.
      — last: 2026-05-01 (Rust)
      regression: viewBox in tree_preview_svg used raw bounds; inner
        geometry from element_svg is multiplied by pt-to-px (96/72), so
        the rendered shape was 1.333x larger than the viewBox and the
        SVG viewport clipped it to the upper-left of the container.
        Fix scales the viewBox by the same factor.

- [x] **LYR-022** [wired] Empty / unnamed elements display `<Type>` as a fallback.
      Setup: A path with no name attribute.
      Expect: Row label shows "<Path>" (or similar bracket type fallback).
      — last: 2026-05-01 (Rust)

---

## Session C — Visibility cycle + solo (~8 min)

**P1**

- [x] **LYR-030** [wired] Eye click cycles preview → outline → invisible → preview.
      Setup: Element row, default visibility (preview).
      Do: Click eye three times.
      Expect: After 1st click: outline (canvas wireframe). After 2nd:
              invisible. After 3rd: back to preview.
      — last: 2026-05-01 (Rust)

- [x] **LYR-031** [wired] Outline mode renders a wireframe on canvas.
      Setup: Filled rectangle visible.
      Do: Cycle to outline.
      Expect: Fill disappears; only the path outline shows on canvas.
      — last: 2026-05-01 (Rust)

- [x] **LYR-032** [wired] Invisible mode hides the element on canvas.
      Setup: Element visible.
      Do: Cycle to invisible.
      Expect: Element disappears from canvas; row still in panel.
      — last: 2026-05-01 (Rust)

- [x] **LYR-033** [wired] Visibility cascade: container change applies to descendants.
      Setup: A Group containing 3 rectangles, all visible.
      Do: Click the group's eye to invisible.
      Expect: All 3 rectangles disappear from canvas; their row eyes
              reflect inherited invisibility.
      — last: 2026-05-01 (Rust)
      regression: descendant row eyes used child.visibility() directly
        instead of cascaded effective visibility, so the canvas hid
        the children but the row eyes still showed preview. Fix passes
        an inherited_visibility down through tree_flatten_rc_children.

- [x] **LYR-034** [wired] Alt-click eye solos the row's siblings.
      Setup: 3 visible siblings.
      Do: Alt-click the second row's eye.
      Expect: Sibling 1 + 3 become invisible; previous visibility states
              saved internally for restore.
      — last: 2026-05-01 (Rust)

- [x] **LYR-035** [wired] Second Alt-click on the same row unsolos siblings.
      Setup: From LYR-034, sibling 1 + 3 solo-hidden.
      Do: Alt-click sibling 2's eye again.
      Expect: Siblings 1 + 3 restored to their pre-solo visibility.
      — last: 2026-05-01 (Rust)

- [x] **LYR-036** [wired] Manual visibility change during solo prevents auto-restore.
      Setup: From LYR-034, sibling 1 + 3 solo-hidden.
      Do: Click sibling 1's eye to visible. Then Alt-click sibling 2 again.
      Expect: Sibling 1 stays visible (manual change wins); sibling 3
              restores to its pre-solo state.
      — last: 2026-05-01 (Rust)

**P2**

- [x] **LYR-040** [wired] Cycle works on group rows with cascade.
      Setup: A group at preview.
      Do: Click group eye.
      Expect: Group → outline; descendants render in outline; cycle
              continues normally.
      — last: —

---

## Session D — Lock cascade (~6 min)

- [x] **LYR-050** [wired] Lock toggle locks an element.
      Setup: Unlocked rectangle.
      Do: Click lock icon.
      Expect: Lock icon shows locked state; clicking the rectangle on
              canvas no longer selects / drags it.
      — last: 2026-05-01 (Rust)

- [x] **LYR-051** [wired] Locked element remains visible.
      Setup: Locked rectangle.
      Expect: Element still drawn on canvas.
      — last: 2026-05-01 (Rust)

- [x] **LYR-052** [wired] Locking a container cascades to all direct children.
      Setup: A group with 3 unlocked children.
      Do: Click group lock icon.
      Expect: Group + all 3 children show locked icons; per-child state
              saved internally for restore.
      — last: 2026-05-01 (Rust)

- [x] **LYR-053** [wired] Unlocking a container restores per-child saved state.
      Setup: From LYR-052, then manually unlock child 2 only.
      Do: Click group lock icon to unlock.
      Expect: Children 1 and 3 unlock; child 2 was already unlocked,
              stays so. (Restore from saved state, not blanket unlock.)
      — last: 2026-05-01 (Rust)

- [x] **LYR-054** [wired] Locked elements remain draggable in the panel.
      Setup: Locked rectangle.
      Do: Drag the row up or down within its layer.
      Expect: Reorder succeeds (lock protects content edits, not
              positioning).
      — last: 2026-05-01 (Rust)

- [x] **LYR-055** [wired] Drop into a locked container is rejected.
      Setup: Layer A unlocked, Layer B locked.
      Do: Drag a row from A to B.
      Expect: Drop is refused (cursor / outline shows reject); row stays
              in A.
      — last: 2026-05-01 (Rust)
      regression: drop validation only checked target's parent for
        locked state; dragging onto a locked layer's own row passed
        because target_parent was the doc root. Added a target_unlocked
        check. Also: New Layer from the panel hamburger menu was a
        stub — wired layers_panel::dispatch to call dispatch_action
        for action commands so the LYR-055 fixture could be built.

---

## Session E — Inline rename + keyboard nav (~5 min)

- [x] **LYR-070** [wired] Double-click name starts inline rename.
      Setup: Layer row.
      Do: Double-click the name label.
      Expect: Label transforms to a text_input pre-filled with the
              current name; cursor active; selection on the text.
      — last: 2026-05-01 (Rust)

- [x] **LYR-071** [wired] Enter confirms the rename.
      Setup: Inline rename active, "Layer 1".
      Do: Type "Backgrounds", press Enter.
      Expect: Row label becomes "Backgrounds"; element name attr updates.
      — last: 2026-05-01 (Rust)

- [x] **LYR-072** [wired] Escape cancels the rename without committing.
      Setup: Rename active, type "Trash".
      Do: Press Escape.
      Expect: Label reverts to original; element unchanged.
      — last: 2026-05-01 (Rust)

- [x] **LYR-073** [wired] Blur (click elsewhere) confirms.
      Setup: Rename active, type "Foreground".
      Do: Click outside the input.
      Expect: Same as Enter — name updates.
      — last: 2026-05-01 (Rust)
      regression: rename input had no onblur handler — clicking outside
        left the input visible without committing. Added onblur that
        reads the input value by id and commits like Enter.

- [x] **LYR-074** [wired] Empty rename reverts.
      Setup: Rename active.
      Do: Clear text, press Enter.
      Expect: Label reverts to the original (or to `<Type>` for unnamed
              elements).
      — last: 2026-05-01 (Rust)

- [x] **LYR-075** [wired] F2 starts rename on the focused row.
      Setup: A row focused.
      Do: Press F2.
      Expect: Inline rename starts.
      — last: 2026-05-01 (Rust)
      regression: F2 had no handler — added a case that picks the last
        panel-selected row (treated as the active row) and starts
        rename when it is a layer.

- [x] **LYR-076** [wired] Arrow Up / Down navigates rows.
      Setup: Multi-row tree, one row focused.
      Do: Arrow Down twice.
      Expect: Focus moves down two rows.
      — last: 2026-05-01 (Rust)
      regression: arrow keys had no handler — added handlers that
        rebuild the visible-row path list and shift the panel
        selection by ±1.

- [x] **LYR-077** [wired] Delete key removes panel selection.
      Setup: A row selected.
      Do: Press Delete.
      Expect: Element removed from document and panel (subject to
              "≥ 1 layer" guard for top-level).
      — last: 2026-05-01 (Rust)

---

## Session F — Search + type filter (~8 min)

- [x] **LYR-090** [wired] Search input filters rows by case-insensitive name.
      Setup: Layers named "Background", "Foreground", "BG-Effects".
      Do: Type "bg" into the search input.
      Expect: Rows whose name contains "bg" (case-insensitive) stay; the
              other rows hide.
      — last: 2026-05-01 (Rust)

- [ ] **LYR-091** [wired] Ancestors of matches render dimmed.
      Setup: Group "FG" containing "fg-rect"; search "fg-rect".
      Expect: "fg-rect" highlighted; parent "FG" rendered dimmed; other
              top-level layers hidden.
      — last: —
      regression: deferred 2026-05-01 — only Layers are renameable in
        the current UI, so we can't construct a named non-layer
        descendant inside a non-matching container. Revisit when
        Group/element names land.

- [x] **LYR-092** [wired] Clearing the search restores the full tree.
      Setup: Search active.
      Do: Clear the input.
      Expect: All rows re-appear; dimming removed.
      — last: 2026-05-01 (Rust)

- [x] **LYR-100** [wired] Type filter dropdown lists 11 togglable types.
      Do: Open `lp_filter_button`.
      Expect: Checkbox per: Layer, Group, Path, Rectangle, Circle,
              Ellipse, Polyline, Polygon, Text, Text Path, Line. All
              checked by default.
      — last: 2026-05-01 (Rust)

- [x] **LYR-101** [wired] Unchecking a type hides all matching rows.
      Setup: Tree with rectangles + circles. Filter dropdown open.
      Do: Uncheck Rectangle.
      Expect: Rectangle rows hide; circles remain.
      — last: 2026-05-01 (Rust)

- [x] **LYR-102** [wired] Type filter composes with search.
      Setup: Search "blue", filter excludes Rectangle.
      Expect: Only non-Rectangle rows whose name contains "blue" show.
      — last: 2026-05-01 (Rust)

- [x] **LYR-103** [wired] Drag-drop disabled while search is active.
      Setup: Search active.
      Do: Try to drag a row.
      Expect: Drag refused or no-op; cursor doesn't show drop affordance.
      — last: 2026-05-01 (Rust)
      regression: drop logic ignored search state and reordered rows
        regardless. Added an early-bail in on_mouseup when
        layers_search_query is non-empty.

---

## Session G — Drag-and-drop reordering (~10 min)

**P0**

- [ ] **LYR-120** [wired] Layer drops onto Layer (sibling reorder).
      Setup: Two top-level layers A, B.
      Do: Drag A onto / past B.
      Expect: Order swaps; canvas re-renders accordingly.
      — last: —

**P1**

- [ ] **LYR-121** [wired] Element / Group drops into a Layer.
      Setup: Group inside Layer A; Layer B empty.
      Do: Drag group onto Layer B.
      Expect: Group reparents into Layer B; Layer A loses it.
      — last: —

- [ ] **LYR-122** [wired] Layer cannot drop into a Group (constraint).
      Setup: Top-level layer + a top-level group.
      Do: Drag layer onto group.
      Expect: Drop refused (cursor reject icon); no reparenting.
      — last: —

- [ ] **LYR-123** [wired] Layer cannot drop into a Layer (no nesting layers).
      Setup: Two top-level layers.
      Do: Drag layer A INTO layer B (drop on B body, not between
          siblings).
      Expect: Drop refused.
      — last: —

- [ ] **LYR-124** [wired] Drop into self / descendant is refused.
      Setup: Group with children.
      Do: Drag the group onto one of its own children.
      Expect: Drop refused; no recursive structure created.
      — last: —

- [ ] **LYR-125** [wired] Drop into a locked container is refused.
      Setup: Locked layer + an unlocked element.
      Do: Drag element onto locked layer.
      Expect: Drop refused.
      — last: —

- [ ] **LYR-126** [wired] Multi-select drag preserves relative order.
      Setup: Select rows 1, 3, 5 (non-contiguous).
      Do: Drag the multi-selection to a new layer.
      Expect: All three move; their relative order preserved
              (1 before 3 before 5) at the destination.
      — last: —

**P2**

- [ ] **LYR-130** [wired] 500ms hover over a collapsed group auto-expands.
      Setup: Collapsed group target.
      Do: Drag a row over the group; pause 500ms without releasing.
      Expect: Group auto-expands; you can now drop into it.
      — last: —

- [ ] **LYR-131** [wired] Cancel drag with Escape leaves tree unchanged.
      Setup: Drag in progress.
      Do: Press Escape mid-drag.
      Expect: Drop indicator disappears; row stays at original position.
      — last: —

---

## Session H — Menu — New Layer / Group / All (~8 min)

- [ ] **LYR-150** [wired] Menu shows the full item list.
      Do: Open the panel menu.
      Expect: New Layer…, New Group, ─, Hide All / Show All Layers,
              Outline All / Preview All Layers, Lock All / Unlock All
              Layers, ─, Enter / Exit Isolation Mode, Flatten Artwork,
              Collect in New Layer, ─, Close Layers.
      — last: —

- [ ] **LYR-151** [wired] New Layer with no selection appends a new top-level layer.
      Setup: Tree = [Layer 1]; nothing selected.
      Do: Menu → New Layer…
      Expect: Layer Options dialog opens in create mode with default
              name "Layer 2"; on OK, new layer appears at the bottom (or
              top, per spec) of the tree with the next color in cycle.
      — last: —

- [ ] **LYR-152** [wired] New Layer with a selected element inserts above selection.
      Setup: Layer 1 selected.
      Do: Menu → New Layer… → OK with default name.
      Expect: New layer inserted immediately above Layer 1.
      — last: —

- [ ] **LYR-153** [wired] New Group disabled when nothing selected.
      Setup: No selection.
      Expect: Menu → New Group is dimmed.
      — last: —

- [ ] **LYR-154** [wired] New Group wraps the panel selection.
      Setup: Two top-level rectangles selected.
      Do: Menu → New Group.
      Expect: Both rectangles become children of a new Group; Group is
              selected; original layer count reduces by the moved
              elements.
      — last: —

- [ ] **LYR-155** [wired] Hide All Layers / Show All Layers toggles cycle.
      Setup: All layers visible.
      Do: Menu → Hide All Layers.
      Expect: Every layer (and descendants) becomes invisible; menu label
              flips to "Show All Layers"; canvas blank.
      Do: Menu → Show All Layers.
      Expect: Original visibilities restored; menu label flips back.
      — last: —

- [ ] **LYR-156** [wired] Outline All / Preview All Layers toggles cycle.
      Do: Menu → Outline All Layers.
      Expect: Every layer renders as outline only; menu label flips.
      Do: Menu → Preview All Layers.
      Expect: Restored to preview.
      — last: —

- [ ] **LYR-157** [wired] Lock All / Unlock All Layers toggles cycle.
      Do: Menu → Lock All Layers.
      Expect: Every layer locked; menu flips. Unlock restores.
      — last: —

---

## Session I — Isolation mode + breadcrumb (~10 min)

**P0**

- [ ] **LYR-180** [wired] Enter Isolation Mode requires single container selection.
      Setup: No selection (or non-container selected).
      Expect: Menu → Enter Isolation Mode is dimmed.
      Setup: Select a single Layer or Group.
      Expect: Menu item enabled.
      — last: —

- [ ] **LYR-181** [wired] Enter pushes the container onto the isolation stack.
      Setup: A Group selected.
      Do: Menu → Enter Isolation Mode.
      Expect: Breadcrumb bar appears at the panel header showing the
              isolated path; non-isolated content is dimmed (~10%
              opacity) on canvas.
      — last: —

- [ ] **LYR-182** [wired] Double-click container row also enters.
      Setup: A Layer row.
      Do: Double-click outside the name (e.g. on the row body).
      Expect: Same effect as menu Enter.
      — last: —

**P1**

- [ ] **LYR-183** [wired] Nested double-click stacks levels.
      Setup: Isolated into Layer 1; a Group inside.
      Do: Double-click the Group.
      Expect: Breadcrumb extends with the Group; isolation stack length
              becomes 2.
      — last: —

- [ ] **LYR-184** [wired] Breadcrumb shows the full path to current isolation.
      Setup: Isolated into Layer 1 → Group A → Group B.
      Expect: Breadcrumb reads "Layer 1 > Group A > Group B".
      — last: —

- [ ] **LYR-185** [wired] Click breadcrumb segment exits to that level.
      Setup: Isolated 3 levels deep.
      Do: Click "Layer 1" in the breadcrumb.
      Expect: Pops to Layer 1 isolation only; breadcrumb shrinks; deeper
              dimming removed.
      — last: —

- [ ] **LYR-186** [wired] Escape pops one level.
      Setup: Isolated 2 levels deep.
      Do: Press Escape.
      Expect: Pops one level; breadcrumb shortens.
      — last: —

- [ ] **LYR-187** [wired] Exit Isolation Mode pops via menu.
      Setup: Isolated.
      Do: Menu → Exit Isolation Mode.
      Expect: Pops one level (or fully exits; document the actual).
      — last: —

- [ ] **LYR-188** [wired] Selection / drag / edit confined to isolated subtree.
      Setup: Isolated into Group A.
      Do: Click a non-isolated element on canvas.
      Expect: No selection; dimmed content is non-interactive.
      — last: —

- [ ] **LYR-189** [wired] Visibility changes during isolation persist after exit.
      Setup: Isolated into Group A; click a child eye → invisible.
      Do: Exit Isolation Mode.
      Expect: Child remains invisible after exit.
      — last: —

**P2**

- [ ] **LYR-190** [wired] New Layer disabled inside isolation.
      Setup: Isolated.
      Expect: Menu → New Layer… dimmed; new top-level layers can't be
              created from inside an isolated container.
      — last: —

- [ ] **LYR-191** [wired] New Group works inside isolation (creates within).
      Setup: Isolated into a Group, with selection.
      Do: Menu → New Group.
      Expect: New Group created inside the isolated parent.
      — last: —

---

## Session J — Context menu (~5 min)

- [ ] **LYR-210** [wired] Right-click a row opens the context menu.
      Do: Right-click any row.
      Expect: Menu appears with Options for Layer…, Duplicate, Delete
              Selection, Enter / Exit Isolation Mode, Flatten Artwork,
              Collect in New Layer.
      — last: —

- [ ] **LYR-211** [wired] "Options for Layer…" enabled only on Layer rows.
      Setup: Right-click a Group or Path row.
      Expect: Item dimmed.
      — last: —

- [ ] **LYR-212** [wired] Duplicate clones panel selection in place.
      Setup: A Rectangle selected.
      Do: Context → Duplicate.
      Expect: A copy appears immediately after; copy becomes the new
              selection.
      — last: —

- [ ] **LYR-213** [wired] Delete Selection removes the selected rows.
      Setup: 2 rows selected.
      Do: Context → Delete Selection.
      Expect: Both rows + descendants removed from document.
      — last: —

- [ ] **LYR-214** [wired] Flatten Artwork enabled when selection has a Group.
      Setup: A Group selected.
      Expect: Item enabled.
      Setup: Only paths selected.
      Expect: Item dimmed.
      — last: —

- [ ] **LYR-215** [wired] Collect in New Layer disabled inside isolation.
      Setup: Isolated.
      Expect: Item dimmed.
      — last: —

---

## Session K — Layer Options dialog (~12 min)

**P0**

- [ ] **LYR-230** [wired] Edit-mode dialog pre-fills layer's current values.
      Setup: A layer "Backgrounds", color = Red, locked, hidden.
      Do: Right-click row → Options for Layer…
      Expect: Dialog opens with Name = "Backgrounds", color preset = Red,
              swatch = `#cc0000` (or red token), Lock checked, Show
              unchecked, Preview disabled.
      — last: —

- [ ] **LYR-231** [wired] Create-mode dialog defaults to "Layer N", next color in cycle.
      Setup: Tree has 2 layers (cycle index = 2).
      Do: Menu → New Layer…
      Expect: Dialog opens with Name = "Layer 3", preset = Green (3rd in
              cycle), Show + Preview checked.
      — last: —

**P1**

- [ ] **LYR-240** [wired] Color preset dropdown lists 9 names + Custom.
      Do: Open `lo_color_preset`.
      Expect: Items: Light Blue, Red, Green, Blue, Yellow, Magenta, Cyan,
              Light Gray, Dark Green, Custom.
      — last: —

- [ ] **LYR-241** [wired] Selecting a preset cascades to the swatch.
      Do: Pick Magenta from the preset.
      Expect: Swatch updates to magenta.
      — last: —

- [ ] **LYR-242** [wired] Clicking the swatch opens the Color Picker.
      Do: Click `lo_color_swatch`.
      Expect: Modal Color Picker dialog opens; pick a custom color → OK.
      Expect: Preset dropdown shows "Custom"; swatch shows the new color.
      — last: —

- [ ] **LYR-243** [wired] Show off disables Preview toggle.
      Setup: Show checked, Preview checked.
      Do: Uncheck Show.
      Expect: Preview becomes dimmed / non-interactive.
      — last: —

- [ ] **LYR-244** [wired] Show off + OK results in invisible visibility.
      Setup: Dialog → Show unchecked → OK.
      Expect: Layer's eye state becomes invisible.
      — last: —

- [ ] **LYR-245** [wired] Show on + Preview off → outline visibility.
      Setup: Dialog → Show on, Preview off → OK.
      Expect: Layer's eye state becomes outline.
      — last: —

- [ ] **LYR-246** [wired] Show on + Preview on → preview visibility.
      Expect: Layer renders normally.
      — last: —

- [ ] **LYR-247** [wired] Lock toggle persists.
      Setup: Dialog → Lock on → OK.
      Expect: Layer locked in panel.
      — last: —

- [ ] **LYR-248** [wired] Dim Images toggle enables percent input.
      Setup: Dim Images unchecked, percent dimmed.
      Do: Check Dim Images.
      Expect: `lo_dim_percentage` becomes interactive (0–100, default 50%
              or per spec).
      — last: —

- [ ] **LYR-249** [wired] OK persists changes.
      Setup: Edit dialog with several changes.
      Do: Click OK.
      Expect: Dialog closes; row reflects all changes (color square,
              eye state, lock).
      — last: —

- [ ] **LYR-250** [wired] Cancel discards changes.
      Setup: Edit dialog with changes.
      Do: Click Cancel.
      Expect: Dialog closes; layer unchanged.
      — last: —

**P2**

- [ ] **LYR-260** [wired] Template toggle is disabled (not implemented).
      Do: Try to toggle `lo_template`.
      Expect: Disabled.
      — last: —

- [ ] **LYR-261** [wired] Print toggle is disabled (not implemented).
      Do: Try to toggle `lo_print`.
      Expect: Disabled.
      — last: —

---

## Session L — Color label cycling (~5 min)

- [ ] **LYR-270** [wired] First layer in a fresh doc gets Light Blue.
      Setup: Brand new document.
      Expect: "Layer 1" color square = `#4a90d9` (or the Light Blue
              token); preset dropdown reads "Light Blue".
      — last: —

- [ ] **LYR-271** [wired] Subsequent New Layers cycle through 9 presets.
      Setup: Add 9 more layers via Menu → New Layer… (accept default
             color each time).
      Expect: Colors cycle through Light Blue, Red, Green, Blue, Yellow,
              Magenta, Cyan, Light Gray, Dark Green; the 11th layer wraps
              back to Light Blue.
      — last: —

- [ ] **LYR-272** [wired] Selection square inherits ancestor layer color.
      Setup: A Rectangle inside Red Layer.
      Do: Select the Rectangle.
      Expect: Selection square (12px) fills with Red.
      — last: —

- [ ] **LYR-273** [wired] Custom color shows "Custom" in preset dropdown.
      Setup: Layer with a custom color via Color Picker.
      Do: Open Layer Options.
      Expect: Preset dropdown reads "Custom" (display-only); swatch
              shows the custom color.
      — last: —

---

## Session M — Appearance theming (~5 min)

- [ ] **LYR-290** [wired] Dark appearance: tree readable.
      Setup: Dark active.
      Expect: Row text legible; eye / lock / twirl icons visible against
              panel bg; selection highlight distinct.
      — last: —

- [ ] **LYR-291** [wired] Medium Gray appearance mirrors Dark.
      Do: Switch to Medium Gray.
      Expect: Panel re-skins; controls still readable; layer color
              squares unaffected by theme.
      — last: —

- [ ] **LYR-292** [wired] Light Gray appearance mirrors Dark.
      Do: Switch to Light Gray.
      Expect: Same as above.
      — last: —

- [ ] **LYR-293** [wired] Search input placeholder readable in every theme.
      Setup: Empty search.
      Expect: Placeholder text uses a theme-appropriate dim color.
      — last: —

- [ ] **LYR-294** [wired] Dimmed-in-search rows use `theme.colors.text_dim`.
      Setup: Search active, ancestors dimmed.
      Expect: Dimmed text contrasts against background per theme tokens.
      — last: —

---

## Session N — Cross-app parity (~15 min)

~5–8 load-bearing `[wired]` tests where cross-language drift produces
user-visible bugs. Batch by app: run a full column at a time.

- **LYR-400** [wired] Default fresh doc has exactly one Layer 1.
      Do: New document.
      Expect: Tree = single "Layer 1", color Light Blue.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **LYR-401** [wired] New Layer with selection inserts above the selection.
      Setup: Layer 1 selected.
      Do: Menu → New Layer… → OK with default.
      Expect: New layer immediately above Layer 1.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **LYR-402** [wired] New Group wraps the panel selection.
      Setup: Two rectangles selected.
      Do: Menu → New Group.
      Expect: Both rectangles become Group children; Group is selected.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **LYR-403** [wired] Hide All / Show All round-trips state.
      Setup: Two layers, one previously invisible.
      Do: Menu → Hide All Layers → Menu → Show All Layers.
      Expect: Originally-invisible layer is restored to invisible (not
              forced visible).
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **LYR-404** [wired] Enter Isolation Mode pushes selection onto the stack.
      Setup: A Group selected.
      Do: Menu → Enter Isolation Mode.
      Expect: Isolation stack length = 1; non-isolated content dim on
              canvas.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **LYR-405** [wired] Flatten Artwork unpacks a single group.
      Setup: A Group containing 3 paths.
      Do: Select Group; menu → Flatten Artwork.
      Expect: 3 paths now siblings of the (deleted) group; Group gone.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **LYR-406** [wired] Layer Options edit mode persists name + color + lock.
      Setup: Layer "Old Name", color Light Blue, unlocked.
      Do: Options → name "New Name", color Magenta, Lock on → OK.
      Expect: Row shows "New Name"; color square magenta; lock active.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

---

## Graveyard

_No retired or won't-fix tests yet._

---

## Enhancements

_No non-blocking follow-ups raised yet. Manual testing surfaces ideas here
with `ENH-NNN` prefix and italicized trailer noting the test + date._
