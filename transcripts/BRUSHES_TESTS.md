# Brushes Panel — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/panels/brushes.yaml`, plus `workspace/dialogs/brush_options.yaml`
and `workspace/dialogs/apply_to_strokes_confirm.yaml`.
Design docs: `transcripts/BRUSHES.md`, `transcripts/BRUSH_OPTIONS_DIALOG.md`,
`transcripts/PAINTBRUSH_TOOL.md`.

Primary platform for manual runs: any of the four native apps
(`jas_dioxus`, `JasSwift`, `jas_ocaml`, `jas`) — Brushes reaches
end-to-end Calligraphic in all four. Flask covers panel + library
mutations + render path; brush.options_confirm dialog write-back
is JS-stub-only (per BRP-103). Cross-app parity covered in
Session M.

---

## Known broken

_Last reviewed: 2026-04-24_

- BRP-101 — Brush types beyond Calligraphic are not implemented.
  The five type-radio buttons exist in Brush Options but only
  Calligraphic is selectable; other types fall back to plain native
  stroke at render time. since 2026-04-24. BRUSHES.md §Wiring
  status open follow-ups.
- BRP-102 — Brush Options `library_edit` mode commits unconditionally
  rather than prompting via the Apply-to-Strokes confirm sub-dialog.
  The sub-dialog YAML exists at
  `workspace/dialogs/apply_to_strokes_confirm.yaml` but isn't
  invoked between assembly and commit. since 2026-04-24.
  Phase 7.4-7.6 commit message.
- BRP-103 — Flask JS `brush.options_confirm` is a log+close stub.
  Flask uses HTML modals, which differ from the native apps' YAML
  dialog flow. since 2026-04-24. Phase 7.6.
- BRP-104 — Server-side panel re-render in Flask after data
  mutation. Library mutations (Delete / Duplicate / etc.) update
  the JS-side store and canvas registry but the server-rendered
  panel HTML does not refresh until the next page load. since
  2026-04-24. Same source.
- BRP-105 — Bristle, Scatter, Art, Pattern brush data models exist
  but their renderers are not implemented. Paths with non-
  Calligraphic `stroke_brush` fall back to plain native stroke.
  since 2026-04-24. BRUSHES.md §Brush types.
- BRP-106 — Variation modes beyond `fixed` (random, pressure, tilt,
  bearing, rotation) defined in `variation_widget` template but
  degrade to `fixed` at render time. Stylus input plumbing is a
  separate, larger initiative. since 2026-04-24. Same source.

---

## Automation coverage

_Last synced: 2026-04-24_

**Algorithm — `algorithms/calligraphic_outline.{js,rs,swift,ml,py}`**
- 7 unit tests across each app's calligraphic_outline test suite:
  empty input, single-MoveTo, horizontal-line circular brush,
  brush-angle parallel-to-path uses minor axis, brush-angle
  perpendicular uses major axis, circular brush is direction-
  independent, cubic curve sampled and outlined.

**Workspace loader — `workspace_interpreter/tests/test_loader.py`**
- `test_load_brush_libraries`: brush_libraries map keyed by slug,
  default_brushes seed present.
- `test_load_includes_paintbrush_tool`: paintbrush.yaml shortcut +
  on_mouseup threads `state.stroke_brush` into
  `doc.add_path_from_buffer`.
- `test_load_includes_panels`: brushes_panel_content present.
- `test_brushes_panel_state_defaults`: 6 panel-mirror keys present
  with the spec defaults.
- `test_brush_options_dialog_loaded`: modal flag + 3-mode enum +
  Calligraphic state keys.
- `test_apply_to_strokes_confirm_dialog_loaded`: modal flag +
  brush_name / library / brush_slug params.
- `test_all_brushes_panel_actions_exist`: every action referenced
  by panel YAML is registered in `actions.yaml`.

**JS engine — `jas_flask/tests/js/`**
- `test_document.mjs`: `mkPath` carries stroke_brush /
  stroke_brush_overrides through clone + JSON round-trip.
- `test_renderer.mjs`: 7 brushed-path tests (registry round-trip,
  unknown-slug fallback, plain path no-brush, unknown-brush-type
  fallback, degenerate input, happy-path attributes).
- `test_doc_effects.mjs`: 4 doc.set_attr_on_selection tests, 4
  buffer.* / doc.add_path_from_buffer tests, 7 data.* tests,
  7 brush.* tests.

**Rust — `jas_dioxus/src/algorithms/calligraphic_outline.rs`**
- 7 unit tests as above.
- Effects: data.* and brush.* exercised via the JS suite above
  conceptually; Rust-side end-to-end tests rely on the lib test
  pass (1616 tests).

**Swift / OCaml / Python** — calligraphic_outline tests as above
(7 each in Swift/OCaml not yet authored as test files; Python has
`jas/algorithms/calligraphic_outline_test.py` with 7 tests).

Manual coverage below targets:
panel layout / disclosure / tile click / view-mode resizing /
menu actions (New / Duplicate / Delete / Sort / Select Unused /
Persistent / Open Library / Save Library) / Paintbrush integration /
Brush Options dialog modes / Apply-to-Strokes confirm /
canvas brushed-stroke render / theming / cross-app parity.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (one of the 4 native apps; Flask covers
   panel + libraries but stops at brush.options_confirm).
2. Open a default workspace with an empty document loaded.
3. Open the Brushes panel via Window → Brushes (or the docked
   location in the Default layout — same group as Color and
   Swatches).
4. Appearance: **Dark** (`workspace/appearances/`).

The default workspace ships
`workspace/brushes/default_brushes/library.json` containing one
Calligraphic brush ("5 pt. Oval", slug `oval_5pt`); this library
should appear open in the panel on first launch.

Tests that need a non-default selection or library state add a
`Setup:` line.

---

## Tier definitions

- **P0 — existential.** If this fails, the panel is broken. Crash,
  layout collapse, complete non-function. 5-minute smoke confidence.
- **P1 — core.** Control does its primary job (click / drag / enter /
  select / toggle).
- **P2 — edge & polish.** Bounds, keyboard-only paths, focus / tab
  order, appearance variants, mutual-exclusion display, icon states.

---

## Session table of contents

| Session | Topic                                  | Est.  | IDs       |
|---------|----------------------------------------|-------|-----------|
| A       | Smoke & lifecycle                      | ~5m   | 001–009   |
| B       | Default library + tile rendering       | ~5m   | 010–029   |
| C       | Library disclosure / collapse          | ~5m   | 030–049   |
| D       | Tile click + apply to selection        | ~8m   | 050–079   |
| E       | View modes & thumbnail size            | ~5m   | 080–099   |
| F       | Menu — New / Duplicate / Delete        | ~10m  | 100–129   |
| G       | Menu — Sort / Filter / Persistent      | ~8m   | 130–159   |
| H       | Menu — Open / Save Library             | ~8m   | 160–179   |
| I       | Brush Options dialog — create mode     | ~8m   | 180–199   |
| J       | Brush Options — library_edit + instance| ~10m  | 200–229   |
| K       | Apply-to-Strokes confirm sub-dialog    | ~5m   | 230–249   |
| L       | Paintbrush tool integration            | ~10m  | 250–279   |
| M       | Remove Brush Stroke + canvas render    | ~5m   | 280–299   |
| N       | Cross-app parity                       | ~15m  | 300–329   |
| O       | Appearance theming                     | ~5m   | 330–349   |

Full pass: ~110 min. A gates the rest; otherwise sessions stand
alone.

---

## Session A — Smoke & lifecycle (~5 min)

If any P0 here fails, stop and flag.

- [ ] **BRP-001** [wired] Panel opens via Window menu.
      Do: Select Window → Brushes.
      Expect: Brushes panel appears in dock or floating; no console
              error.
      — last: —

- [ ] **BRP-002** [wired] All panel rows render without layout collapse.
      Do: Visually scan the open panel.
      Expect: Library disclosure with name + triangle; brush tiles
              below the disclosure (1:3 aspect at small size); bottom
              toolbar with five icon buttons (libraries menu, remove
              brush, options for selection, new brush, delete brush).
              No overlapping controls, no truncated labels.
      — last: —

- [ ] **BRP-003** [wired] Panel collapses and re-expands.
      Do: Click the panel header to collapse; click again to expand.
      Expect: Content hides / reveals; header stays visible; no
              crash.
      — last: —

- [ ] **BRP-004** [wired] Panel closes via context menu / X button.
      Do: Right-click header → Close, or click the close affordance.
      Expect: Panel disappears; Window → Brushes reopens it.
      — last: —

- [ ] **BRP-005** [wired] Panel floats out of the dock.
      Do: Drag the panel header out of the dock.
      Expect: Panel becomes a floating window; controls stay
              interactive; returns to dock on drag back.
      — last: —

- [ ] **BRP-006** [wired] Default layout places Brushes alongside Color +
      Swatches.
      Setup: Default layout active.
      Expect: Brushes is a tab in the same group as Color and
              Swatches (panels: [color, swatches, brushes]).
      — last: —

---

## Session B — Default library + tile rendering (~5 min)

- [ ] **BRP-010** [wired] Default Brushes library opens by default on first launch.
      Setup: Fresh workspace, never opened Brushes before.
      Do: Open the Brushes panel.
      Expect: Library disclosure shows "Default Brushes"; triangle
              expanded; one brush tile rendered ("5 pt. Oval").
      — last: —

- [ ] **BRP-011** [wired] Default library has 1 Calligraphic brush.
      Do: Count rendered tiles under the Default Brushes disclosure.
      Expect: 1 tile (Phase 1 seed). Hover shows "5 pt. Oval".
      — last: —

- [ ] **BRP-012** [wired] Brush tile thumbnail rendering shape.
      Setup: Default library expanded, Small Thumbnail View (default).
      Expect: Tile is 48×16 pixels (1:3 aspect); shows a stroke
              preview applied to a short demo S-curve, painted in a
              neutral color.
      — last: —

- [ ] **BRP-013** [wired] Default library name matches its file's `name` field.
      Do: Inspect the disclosure label vs
          `workspace/brushes/default_brushes/library.json`.
      Expect: Disclosure shows "Default Brushes" (the file's `name`
              field, not the directory stem `default_brushes`).
      — last: —

- [ ] **BRP-014** [wired] Brush tile carries a type-indicator decorator.
      Do: Visually inspect a Calligraphic brush tile.
      Expect: Small `brush_type_calligraphic` glyph in the tile
              corner — the oval pen-tip icon (per BRUSHES.md §Controls).
      — last: —

---

## Session C — Library disclosure / collapse (~5 min)

- [ ] **BRP-030** [wired] Disclosure triangle starts in expanded state.
      Setup: Fresh open of the panel.
      Expect: Triangle pointing down (▾); brush tiles visible.
      — last: —

- [ ] **BRP-031** [wired] Click triangle collapses the library.
      Do: Click the disclosure triangle.
      Expect: Triangle rotates to collapsed (▸); tiles hide; library
              name still visible.
      — last: —

- [ ] **BRP-032** [wired] Click again expands.
      Do: Click the collapsed triangle.
      Expect: Triangle returns to ▾; tiles re-render.
      — last: —

- [ ] **BRP-033** [wired] Collapse state stored in `panel.open_libraries[i].collapsed`.
      Setup: Library collapsed.
      Do: Inspect panel state (debug overlay or YAML re-init).
      Expect: `panel.open_libraries[0].collapsed = true`.
      — last: —

- [ ] **BRP-034** [wired] Multiple open libraries each have independent collapse.
      Setup: Two libraries open via Open Brush Library.
      Do: Collapse the first; leave the second.
      Expect: Each library's triangle reflects its own state.
      — last: —

---

## Session D — Tile click + apply to selection (~8 min)

**P0**

- [ ] **BRP-050** [wired] Single-click on a tile sets `state.stroke_brush`.
      Setup: A path element selected on the canvas.
      Do: Click the "5 pt. Oval" tile.
      Expect: `state.stroke_brush` becomes
              `"default_brushes/oval_5pt"`; tile gains 2px accent
              outline (`jas-selected`); the selected path now carries
              `jas:stroke-brush` and renders as a brushed stroke.
      — last: —

- [ ] **BRP-051** [wired] Single-click sets active brush even with no canvas selection.
      Setup: Empty canvas selection.
      Do: Click a brush tile.
      Expect: `state.stroke_brush` set; tile carries selected
              outline; nothing applied to canvas (no selection); next
              Paintbrush draw uses this brush.
      — last: —

**P1**

- [ ] **BRP-052** [wired] Plain click on a different tile replaces selection.
      Setup: Tile A selected.
      Do: Click tile B in the same library.
      Expect: B selected; A loses outline; `state.stroke_brush`
              points to B.
      — last: —

- [ ] **BRP-053** [wired] Shift-click extends the selection.
      Setup: Tile A selected.
      Do: Shift+click tile B (in the same library).
      Expect: Both A and B carry `jas-selected`. (Selection
              shorthand for menu-item enablement; only a single brush
              can be the active one — most-recently-clicked wins.)
      — last: —

- [ ] **BRP-054** [wired] Cmd / Ctrl-click toggles a tile in the selection.
      Setup: A and B selected.
      Do: Cmd/Ctrl-click A.
      Expect: A deselects; B remains selected.
      — last: —

- [ ] **BRP-055** [wired] Double-click on a tile opens Brush Options in library_edit.
      Setup: Default library tile present.
      Do: Double-click the tile.
      Expect: Modal Brush Options dialog opens; Name field shows
              "5 pt. Oval"; type radio shows Calligraphic checked +
              disabled; angle/roundness/size fields populated from
              the brush.
      — last: —

**P2**

- [ ] **BRP-056** [wired] Selection is per-library — clicking in B doesn't clear A.
      Setup: Library A and Library B both open; one tile selected in A.
      Do: Click a tile in B.
      Expect: B's tile selected; A's selection persists (per-library
              `selected_brushes`).
      — last: —

- [ ] **BRP-057** [wired] Single-click also applies the brush to canvas selection.
      Setup: Two paths selected on the canvas.
      Do: Click a tile.
      Expect: Both selected paths gain `jas:stroke-brush`; both
              re-render as brushed strokes.
      — last: —

- [ ] **BRP-058** [wired] Cross-library shift/cmd click degrades to plain click.
      Setup: Tile A in library X selected.
      Do: Shift-click a tile in library Y.
      Expect: Y's tile becomes the (single) selection; A's selection
              cleared.
      — last: —

---

## Session E — View modes & thumbnail size (~5 min)

- [ ] **BRP-080** [wired] Default thumbnail size is Small (48×16).
      Setup: Fresh workspace.
      Expect: Tiles render at 48×16; menu shows checkmark on Small.
      — last: —

- [ ] **BRP-081** [wired] Switching to Medium re-renders at 72×24.
      Do: Menu → Medium Thumbnail View.
      Expect: All brush tiles grow to 72×24; checkmark moves to
              Medium.
      — last: —

- [ ] **BRP-082** [wired] Switching to Large re-renders at 96×32.
      Do: Menu → Large Thumbnail View.
      Expect: Tiles grow to 96×32.
      — last: —

- [ ] **BRP-083** [wired] List View switches to icon + name rows.
      Do: Menu → List View.
      Expect: Each row shows `[16×16 type-indicator icon] [name text,
              flex] [optional badge]`; thumbnail-size radio dimmed
              (disabled when view_mode == list).
      — last: —

- [ ] **BRP-084** [wired] Switching back to Thumbnail View restores tiles.
      Setup: List View active.
      Do: Menu → Thumbnail View.
      Expect: Tiles return at the last-active thumbnail size.
      — last: —

- [ ] **BRP-085** [wired] View mode is panel-local (re-initialised on panel open).
      Setup: Medium active.
      Do: Close the panel; reopen.
      Expect: Returns to Small (per BRUSHES.md §Panel state — re-
              initialised on each panel open).
      — last: —

---

## Session F — Menu: New / Duplicate / Delete (~10 min)

- [ ] **BRP-100** [wired] New Brush enabled only when canvas selection non-empty.
      Setup: Empty canvas selection.
      Expect: Menu → New Brush is dimmed; tooltip indicates "select
              an element first".
      — last: —

- [ ] **BRP-101** [wired] New Brush opens dialog in create mode with type Art.
      Setup: A vector element selected on canvas.
      Do: Menu → New Brush.
      Expect: Brush Options dialog opens; type radio defaults to
              Art (per BRUSHES.md §Controls); type radio editable
              (only in create mode).
      — last: —

- [ ] **BRP-102** [known-broken: BRP-101 only Calligraphic body] Selecting Art
      shows the placeholder body.
      Setup: Dialog open in create mode, type radio set to Art.
      Expect: (Target) Art-specific body fields render. (Current)
              Placeholder hint "Body for this brush type is not yet
              available." Cmd-click on Art is functional but body is
              empty.
      — last: —

- [ ] **BRP-103** [wired] New Brush → switch type to Calligraphic → name → OK
      appends to library.
      Setup: Dialog open in create mode.
      Do: Type radio → Calligraphic; Name "Test"; angle 45;
          roundness 50; size 8; OK.
      Expect: Dialog closes; new tile "Test" appears at the end of
              `default_brushes`; tile renders the new brush
              parameters.
      — last: —

- [ ] **BRP-110** [wired] Duplicate Brush enabled only when ≥1 brush selected.
      Setup: No tile selected.
      Expect: Menu → Duplicate Brush is dimmed.
      — last: —

- [ ] **BRP-111** [wired] Duplicate inserts a copy after the original.
      Setup: Tile "5 pt. Oval" selected.
      Do: Menu → Duplicate Brush.
      Expect: A new tile "5 pt. Oval copy" appears immediately after
              with slug `oval_5pt_copy`; selection moves to the copy;
              original keeps its position.
      — last: —

- [ ] **BRP-112** [wired] Duplicate twice generates unique slugs.
      Setup: "5 pt. Oval" selected.
      Do: Menu → Duplicate Brush twice.
      Expect: Slugs `oval_5pt_copy` and `oval_5pt_copy_2`.
      — last: —

- [ ] **BRP-120** [wired] Delete Brush enabled only when ≥1 brush selected.
      Setup: No selection.
      Expect: Menu → Delete Brush is dimmed.
      — last: —

- [ ] **BRP-121** [wired] Delete removes the selected brushes.
      Setup: One tile selected.
      Do: Menu → Delete Brush.
      Expect: Tile removed from the library; selection cleared;
              canvas elements that referenced the deleted brush slug
              re-render as plain native strokes.
      — last: —

- [ ] **BRP-122** [wired] Delete in document with brushed elements falls back gracefully.
      Setup: Two paths in the document use the seed brush; delete the
             brush.
      Do: Menu → Delete Brush.
      Expect: Both paths re-render with the native stroke pipeline;
              `jas:stroke-brush` attribute remains on the elements
              but resolves to null at lookup time.
      — last: —

---

## Session G — Menu: Sort / Filter / Persistent (~8 min)

- [ ] **BRP-130** [wired] Sort by Name reorders alphabetically (case-sensitive).
      Setup: Library with mixed-order names: "Zebra", "Apple",
             "Mango".
      Do: Menu → Sort by Name.
      Expect: Order becomes Apple, Mango, Zebra.
      — last: —

- [ ] **BRP-131** [wired] Sort by Name preserves selection (slug-keyed).
      Setup: "Mango" tile selected.
      Do: Menu → Sort by Name.
      Expect: Tile order changes; "Mango" still selected after sort
              (selection is by slug, not index).
      — last: —

- [ ] **BRP-132** [wired] Sort by Name persists on save.
      Setup: Sort applied.
      Do: Menu → Save Brush Library → name "test" → Save.
      Expect: Saved JSON contains brushes in alphabetical order.
      — last: —

- [ ] **BRP-140** [wired] Show Calligraphic Brushes filter is checked by default.
      Setup: Default workspace.
      Do: Open panel menu.
      Expect: All five "Show X Brushes" items show checkmarks.
      — last: —

- [ ] **BRP-141** [wired] Unchecking a category hides those brush tiles.
      Setup: Library has at least one Calligraphic and one Art brush.
      Do: Menu → Show Art Brushes (uncheck).
      Expect: Art tiles hide from the panel body; Calligraphic
              tiles remain.
      — last: —

- [ ] **BRP-142** [wired] Unchecking all five categories shows hint label.
      Do: Uncheck all five Show X Brushes items.
      Expect: Panel body empty with hint label
              "No brushes match current filter".
      — last: —

- [ ] **BRP-143** [wired] Category filter is panel-local (resets on panel open).
      Setup: Hide Calligraphic.
      Do: Close panel; reopen.
      Expect: Filter reset; Calligraphic visible again.
      — last: —

- [ ] **BRP-150** [wired] Make Persistent toggles for the selected library.
      Setup: `default_brushes` selected.
      Do: Menu → Make Persistent (currently unchecked).
      Expect: Checkmark appears; library slug appended to
              `preferences.brushes.persistent_libraries` in
              user-preferences storage.
      — last: —

- [ ] **BRP-151** [wired] Persistent libraries auto-open at app launch.
      Setup: Library marked Persistent.
      Do: Quit and relaunch the app.
      Expect: Library opens automatically (per BRUSHES.md §Brush
              libraries).
      — last: —

---

## Session H — Menu: Open / Save Library (~8 min)

- [ ] **BRP-160** [wired] Open Brush Library submenu lists every directory in `workspace/brushes/`.
      Do: Menu → Open Brush Library.
      Expect: Submenu shows one item per `<slug>/library.json` file
              under `workspace/brushes/`; already-open libraries
              carry a checkmark.
      — last: —

- [ ] **BRP-161** [wired] Selecting an unopened library appends to `panel.open_libraries`.
      Setup: Only `default_brushes` open; create another library
             under `workspace/brushes/test_lib/library.json` in
             advance.
      Do: Submenu → "Test Lib".
      Expect: Library appears below Default Brushes; disclosure
              expanded.
      — last: —

- [ ] **BRP-162** [wired] Selecting an already-open library closes it (toggle).
      Setup: `default_brushes` already open (checkmark shown).
      Do: Submenu → Default Brushes.
      Expect: Library removed from `panel.open_libraries`;
              checkmark cleared.
      — last: —

- [ ] **BRP-170** [wired] Save Brush Library opens the Save dialog.
      Do: Menu → Save Brush Library.
      Expect: Modal dialog opens with name input and Save / Cancel
              buttons.
      — last: —

- [ ] **BRP-171** [wired] Save with empty name is disabled.
      Setup: Save dialog open, name input empty.
      Expect: Save button dimmed.
      — last: —

- [ ] **BRP-172** [wired] Save with valid name writes to `workspace/brushes/<slug>/`.
      Setup: Save dialog open, currently-selected library has its
             brushes.
      Do: Enter "my_brushes" → Save.
      Expect: Directory `workspace/brushes/my_brushes/` exists with
              `library.json` containing the expected brushes plus
              any artwork SVGs (none for Phase 1 Calligraphic).
      — last: —

- [ ] **BRP-173** [wired] Saving a library with the existing name overwrites or warns.
      Setup: `default_brushes/` exists.
      Do: Save dialog → "default_brushes" → Save.
      Expect: Either overwrites silently or shows a confirm. Document
              the actual; either is acceptable.
      — last: —

---

## Session I — Brush Options dialog: create mode (~8 min)

**P0**

- [ ] **BRP-180** [wired] Create-mode dialog opens at 360px wide with all expected fields.
      Setup: Canvas element selected.
      Do: Menu → New Brush.
      Expect: Modal dialog 360px wide. BRUSH_TYPE_RADIO at top with
              5 type icon-toggles (Calligraphic enabled; others
              dimmed per BRP-101). Below: Name input. Below: per-type
              body (Calligraphic shows three variation_widget
              instances for angle/roundness/size). Below: PREVIEW_STRIP
              (S-curve demo). Below: Cancel + OK.
      — last: —

**P1**

- [ ] **BRP-181** [wired] Default name is "<Type> Brush <N>".
      Setup: Create-mode dialog open.
      Expect: Name field starts with a default like "Art Brush 1"
              (next free integer in target library).
      — last: —

- [ ] **BRP-182** [wired] Type picker enabled in create mode.
      Setup: Dialog in create mode.
      Do: Click another type icon-toggle.
      Expect: BRUSH_TYPE_RADIO updates; per-type body switches.
              (Most types show the placeholder hint per BRP-102.)
      — last: —

- [ ] **BRP-183** [wired] Calligraphic body has three variation_widget rows.
      Setup: Dialog with type=Calligraphic.
      Expect: Three rows each with a base combo + mode select
              (Fixed / Random / Pressure / Tilt / Bearing / Rotation).
              Pressure / Tilt / Bearing / Rotation marked
              `pending_stylus`.
      — last: —

- [ ] **BRP-184** [wired] Random mode reveals min/max combos.
      Setup: Dialog with Calligraphic body. Set angle's variation
             mode to Random.
      Expect: Two extra combos appear inline for min / max bounds.
      — last: —

- [ ] **BRP-185** [wired] OK with empty name is disabled.
      Setup: Dialog open; clear Name field.
      Expect: OK button dimmed.
      — last: —

- [ ] **BRP-186** [wired] OK appends new brush to selected library.
      Setup: Dialog open in create mode with valid name and Calligraphic
             params.
      Do: Click OK.
      Expect: Dialog closes; new tile appears at end of
              `panel.selected_library`; slug generated from name
              (lowercased, non-alphanum → `_`); selection updates.
      — last: —

- [ ] **BRP-187** [wired] Cancel discards.
      Setup: Dialog open with edits.
      Do: Click Cancel.
      Expect: Dialog closes; library unchanged.
      — last: —

**P2**

- [ ] **BRP-188** [wired] Slug collision generates a unique slug.
      Setup: Library has a brush "Test" with slug `test`.
      Do: Create another brush with name "Test".
      Expect: New brush gets slug `test_2`.
      — last: —

- [ ] **BRP-189** [wired] Preview strip updates live as Calligraphic params change.
      Setup: Dialog open.
      Do: Drag the size combo's value up.
      Expect: PREVIEW_STRIP redraws the demo S-curve at the new size.
      — last: —

---

## Session J — Brush Options: library_edit + instance_edit (~10 min)

- [ ] **BRP-200** [wired] Double-click a tile opens dialog in library_edit mode.
      Do: Double-click "5 pt. Oval".
      Expect: Title shows "5 pt. Oval Options"; BRUSH_TYPE_RADIO
              dimmed; fields pre-filled from the master brush.
      — last: —

- [ ] **BRP-201** [wired] library_edit OK updates the master brush in place.
      Setup: Dialog open in library_edit; change angle to 45.
      Do: Click OK.
      Expect: Dialog closes; the brush's master angle updates;
              canvas elements referencing this brush re-render with
              the new angle on the next paint.
      — last: —

- [ ] **BRP-202** [known-broken: BRP-102] library_edit OK should prompt
      Apply-to-Strokes confirm.
      Setup: Dialog open in library_edit; change a param.
      Do: Click OK.
      Expect: (Target) Apply-to-Strokes confirm sub-dialog opens
              with brush_name pre-filled. (Current) Patch commits
              unconditionally; sub-dialog not invoked. See
              `workspace/dialogs/apply_to_strokes_confirm.yaml`.
      — last: —

- [ ] **BRP-203** [wired] library_edit Cancel discards.
      Setup: Dialog open in library_edit with edits.
      Do: Cancel.
      Expect: Master brush unchanged.
      — last: —

- [ ] **BRP-210** [wired] BRUSH_OPTIONS_FOR_SELECTION_BUTTON enabled
      only with one brushed-stroke selected.
      Setup: No canvas selection.
      Expect: Button dimmed.
      — last: —

- [ ] **BRP-211** [wired] BRUSH_OPTIONS_FOR_SELECTION_BUTTON opens dialog
      in instance_edit mode.
      Setup: One path with `stroke_brush` set on the canvas, selected.
      Do: Click `bp_options_for_selection_btn`.
      Expect: Dialog opens; title "<Brush Name> Options — This Stroke
              Only"; fields pre-filled from the brush plus any
              existing overrides.
      — last: —

- [ ] **BRP-212** [wired] instance_edit OK writes overrides on selected element.
      Setup: instance_edit dialog open; change size.
      Do: Click OK.
      Expect: Dialog closes; selected element's
              `jas:stroke-brush-overrides` attribute becomes
              compact JSON containing the changed fields.
      — last: —

- [ ] **BRP-213** [wired] instance_edit doesn't mutate master brush.
      Setup: As BRP-212.
      Do: Click OK; double-click the same brush tile.
      Expect: Master brush's params unchanged from before
              instance_edit.
      — last: —

- [ ] **BRP-220** [wired] Choose Artwork canvas-pick mode (Art / Scatter /
      Pattern bodies).
      Setup: Dialog with one of these types — placeholder per BRP-102
             so the button itself shows in stub form.
      Do: Click "Choose Artwork…" (when present).
      Expect: (Target) Dialog dims; cursor becomes a target reticle;
              status bar prompts; canvas click captures geometry as
              brush artwork. (Current) Stub.
      — last: —

---

## Session K — Apply-to-Strokes confirm sub-dialog (~5 min)

Per BRP-102, the sub-dialog YAML exists but is not wired. These
tests cover the YAML loadability and the eventual flow.

- [ ] **BRP-230** [wired] `apply_to_strokes_confirm` dialog YAML loads with
      modal flag + 3 params.
      Do: Inspect `data.dialogs.apply_to_strokes_confirm`.
      Expect: `modal: true`; params include `brush_name`, `library`,
              `brush_slug`.
      — last: —

- [ ] **BRP-231** [known-broken: BRP-102] Triggering the dialog from
      library_edit OK is not yet wired.
      Setup: Brush Options open in library_edit.
      Do: Change a param; OK.
      Expect: (Target) Apply-to-Strokes confirm dialog opens with
              "Apply" / "Cancel" buttons. (Current) Patch commits
              directly; sub-dialog never appears.
      — last: —

- [ ] **BRP-232** [wired] Apply commits + closes both dialogs.
      Setup: (Once BRP-231 wired.) Sub-dialog open.
      Do: Click Apply.
      Expect: brush.update fires; canvas elements re-render with the
              new params; both dialogs close.
      — last: —

- [ ] **BRP-233** [wired] Cancel keeps parent dialog open.
      Setup: (Once BRP-231 wired.) Sub-dialog open.
      Do: Click Cancel.
      Expect: Sub-dialog closes; library mutation discarded; parent
              Brush Options dialog stays open with the user's edits
              still pending.
      — last: —

---

## Session L — Paintbrush tool integration (~10 min)

- [ ] **BRP-250** [wired] Paintbrush tool selectable via shortcut B.
      Do: Press B (or click the Paintbrush in the toolbar).
      Expect: Cursor becomes crosshair; status bar / tool indicator
              shows Paintbrush.
      — last: —

- [ ] **BRP-251** [wired] Paintbrush draws a path with stroke_brush set.
      Setup: Paintbrush active; "5 pt. Oval" set as the active brush.
      Do: Click-drag across the canvas.
      Expect: A new Path element is appended; `jas:stroke-brush =
              "default_brushes/oval_5pt"`; the path renders as a
              brushed Calligraphic outline (filled polygon, not a
              native stroke).
      — last: —

- [ ] **BRP-252** [wired] Paintbrush with no active brush draws plain stroke.
      Setup: Paintbrush active; click `REMOVE_BRUSH_STROKE_BUTTON`
             first to clear `state.stroke_brush`.
      Do: Click-drag across the canvas.
      Expect: Path renders with the native stroke pipeline (no
              brush outline).
      — last: —

- [ ] **BRP-253** [wired] Switching brushes mid-drawing affects subsequent strokes only.
      Setup: Draw stroke A with brush A.
      Do: Click brush B in panel; draw stroke B.
      Expect: Stroke A keeps brush A; stroke B uses brush B; both
              render with their respective brush params.
      — last: —

- [ ] **BRP-254** [wired] Paintbrush stroke supports all standard pencil gestures.
      Do: Press / drag / release to draw; press Escape mid-drag.
      Expect: Press creates path stub; drag accumulates; release
              commits with curve-fit smoothing; Escape cancels.
      — last: —

- [ ] **BRP-260** [known-broken: BRP-105] Drawing with a Scatter / Art /
      Pattern / Bristle brush falls back to plain stroke.
      Setup: Active brush is non-Calligraphic (force via `state.set`).
      Do: Draw with Paintbrush.
      Expect: Path commits with that `stroke_brush` slug, but
              renders with the native stroke pipeline (no brush
              outline) until the per-type renderer lands.
      — last: —

---

## Session M — Remove Brush Stroke + canvas render (~5 min)

- [ ] **BRP-280** [wired] REMOVE_BRUSH_STROKE_BUTTON enabled when selection
      contains a brushed stroke.
      Setup: A brushed path selected.
      Expect: `bp_remove_brush_stroke_btn` enabled; click affordance.
      — last: —

- [ ] **BRP-281** [wired] REMOVE_BRUSH_STROKE_BUTTON disabled when no
      brushed strokes in selection.
      Setup: Empty selection or only plain-stroke paths.
      Expect: Button dimmed.
      — last: —

- [ ] **BRP-282** [wired] Click strips `stroke_brush` from selected paths.
      Setup: Brushed path selected.
      Do: Click `bp_remove_brush_stroke_btn`.
      Expect: Path's `jas:stroke-brush` attribute cleared;
              `jas:stroke-brush-overrides` cleared; path re-renders
              with the native stroke pipeline.
      — last: —

- [ ] **BRP-283** [wired] Calligraphic brushed render is filled (no stroke).
      Setup: Brushed Calligraphic path on the canvas.
      Do: Inspect the rendered SVG / Canvas2D path element.
      Expect: Single closed-path element filled with the stroke
              colour; no `stroke=…` attribute (per BRUSHES.md §SVG
              attribute mapping — variable-width outline is filled,
              not stroked).
      — last: —

- [ ] **BRP-284** [wired] Brush angle is screen-fixed (not path-relative).
      Setup: Two strokes of different directions, same brush (angle 0°,
             roundness 50%).
      Do: Compare visual width.
      Expect: Horizontal stroke is wider than vertical (chisel-pen
              effect; the brush angle stays fixed in screen
              coordinates as the path direction changes).
      — last: —

---

## Session N — Cross-app parity (~15 min)

~5–8 load-bearing `[wired]` tests where cross-language drift
produces user-visible bugs. Batch by app.

- **BRP-300** [wired] Default Brushes library opens by default with one
      Calligraphic seed.
      Do: Fresh workspace → open Brushes panel.
      Expect: "Default Brushes" disclosure shows one tile
              ("5 pt. Oval").
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **BRP-301** [wired] Single-click on a tile sets active brush + applies.
      Setup: Path selected on canvas.
      Do: Click the seed tile.
      Expect: Selected path's `jas:stroke-brush` becomes
              `"default_brushes/oval_5pt"`; canvas re-renders the
              path as a Calligraphic outline.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **BRP-302** [wired] Paintbrush with active brush commits brushed path.
      Setup: Paintbrush selected; brush set.
      Do: Click-drag.
      Expect: New Path with `jas:stroke-brush` set; renders as
              Calligraphic outline.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: — (Paintbrush requires JS engine
                                 buffer + fit_curve effects per
                                 Phase 1.11)

- **BRP-303** [wired] Delete Brush removes from library + falls back on canvas.
      Setup: Tile selected; another path uses the brush.
      Do: Menu → Delete Brush.
      Expect: Tile gone; path re-renders with native stroke.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **BRP-304** [wired] Sort by Name reorders alphabetically + persists.
      Setup: Library with mixed-order names; save it first.
      Do: Sort by Name → Save Brush Library → same name → Save.
      Expect: Saved JSON contains alphabetical order.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **BRP-305** [wired] Brush Options create-mode OK appends a unique-slug brush.
      Setup: Empty canvas selection; library has one Calligraphic
             brush.
      Do: Menu → New Brush → name "Test" → fill in Calligraphic
          params → OK.
      Expect: Library gains a "Test" brush with slug `test`; canvas
              registry re-syncs.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: — (BRP-103: brush.options_confirm
                                 stub-only in JS)

- **BRP-306** [wired] Calligraphic outliner produces identical points
      across apps for the same input.
      Setup: Hand-craft a Path with `d = M 0 0 L 10 0` and brush
             `(angle: 0, roundness: 100, size: 4)` in each app.
      Do: Inspect the outline points.
      Expect: Same (x, y) sequence (within floating-point tolerance,
              ε ≈ 1e-3 pt) across all 5 apps. The 7 unit tests in each
              app's calligraphic_outline test file already prove the
              math agrees.
      - [ ] Rust       last: — (unit tests pass)
      - [ ] Swift      last: — (unit tests not yet authored)
      - [ ] OCaml      last: — (unit tests not yet authored)
      - [ ] Python     last: — (unit tests pass)
      - [ ] Flask      last: — (unit tests pass — JS engine)

---

## Session O — Appearance theming (~5 min)

- [ ] **BRP-330** [wired] Dark appearance: every tile and toolbar icon readable.
      Setup: Dark appearance active.
      Expect: Tile borders distinguishable from panel bg; thumbnail
              previews readable; icon buttons in the bottom toolbar
              not muddied against the bg.
      — last: —

- [ ] **BRP-331** [wired] Medium Gray appearance mirrors Dark.
      Do: Switch appearance → Medium Gray.
      Expect: Panel re-skins; tile and label tokens read correctly.
      — last: —

- [ ] **BRP-332** [wired] Light Gray appearance: dark thumbnails still visible.
      Do: Switch to Light Gray.
      Expect: Black brush thumbnails don't blend into the bg; tile
              borders visible.
      — last: —

- [ ] **BRP-333** [wired] Selected-tile accent outline visible in every appearance.
      Do: In each appearance, select a tile.
      Expect: 2px outline distinguishable from the unselected state.
      — last: —

- [ ] **BRP-334** [wired] Type-indicator decorator glyph reads against tile bg.
      Do: Inspect a Calligraphic tile in each appearance.
      Expect: `brush_type_calligraphic` glyph visible in the tile
              corner; not lost against any appearance.
      — last: —

---

## Graveyard

_No retired or won't-fix tests yet._

---

## Enhancements

_No non-blocking follow-ups raised yet. Manual testing surfaces
ideas here with `ENH-NNN` prefix and italicized trailer noting the
test + date._
