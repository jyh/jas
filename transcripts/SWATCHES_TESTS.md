# Swatches Panel — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/panels/swatches.yaml`, plus `workspace/dialogs/swatch_options.yaml`
and `workspace/dialogs/swatch_library_save.yaml`.
Design doc: `transcripts/SWATCHES.md`.

Primary platform for manual runs: **Flask (jas_flask)** — most fully wired
panel today. Native apps (Rust / Swift / OCaml / Python) ship scaffolding
only; covered in Session M parity sweep with per-app gaps noted.

---

## Known broken

_Last reviewed: 2026-04-19_

- SWP-181 — `global` swatch flag is recorded in the file format but does not
  propagate edits to elements using the swatch. since 2026-04-19.
  SWATCHES.md §Open follow-ups.
- SWP-122 — Delete Swatch is permanent; no undo. since 2026-04-19. Same
  source.
- SWP-301 — Native apps (Rust / Swift / OCaml / Python) currently ship
  scaffolding only — no library load, swatch grid, or menu wiring beyond a
  stub Close item. since 2026-04-19. Spec §Panel-to-selection wiring status.

---

## Automation coverage

_Last synced: 2026-04-19_

**Flask — `jas_flask/tests/test_renderer.py`** (~5 swatch-related tests)
- `test_create_swatch_menu_item`: New Swatch menu item presence.
- `test_swatch_separator`: CSS class `jas-swatch-rule`.
- Color swatch rendering helper coverage. (Most cover the Color panel's
  fixed swatches rather than the Swatches panel's library grid; the panel
  itself is interpreted directly from yaml.)

**Python — `jas/panels/yaml_menu.py`, `jas/panels/yaml_renderer.py`**
- `PanelKind.SWATCHES → "swatches_panel_content"` mapping;
  `_render_color_swatch` widget renderer. No dedicated Swatches panel test
  file.

**Rust — `jas_dioxus/src/panels/swatches_panel.rs`** (~32 lines)
- Scaffolding only: a stub Close menu, no library / swatch behavior. No
  tests.

**Swift — `JasSwift/Sources/Panels/SwatchesPanel.swift`**
- Scaffolding only. `JasSwift/Tests/Panels/` has no Swatches test file.

**OCaml — no dedicated Swatches panel auto-tests.**
Generic panel-menu coverage in `jas_ocaml/test/panels/panel_menu_test.ml`
exercises the menu system at large but not Swatches specifically.

The manual suite below covers what auto-tests don't: actual swatch grid
rendering, library disclosure / collapse, single- vs double-click
behaviour, multi-select via Shift / Cmd, view-mode tile resizing, menu
actions (New / Duplicate / Delete / Sort / Select All Unused / Add Used
Colors), modal dialog flow (Swatch Options + Library Save), library file
load / save, theming, cross-panel regressions.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_flask` for sessions A–L; per-app for M).
2. Open a default workspace with an empty document loaded (the panel is
   gated on a document being open).
3. Open the Swatches panel via Window → Swatches (or the default layout's
   docked location).
4. Appearance: **Dark** (`workspace/appearances/`).

The default workspace ships `workspace/swatches/web_colors.json` with 216
web-safe swatches; this library should appear open in the panel on first
launch.

Tests that need a non-default selection or library state add a `Setup:`
line.

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
| B       | Recent colors row                    | ~5m   | 010–019    |
| C       | Default Web Colors library           | ~5m   | 020–029    |
| D       | Library disclosure / collapse        | ~5m   | 030–049    |
| E       | Swatch click + selection             | ~8m   | 050–079    |
| F       | View modes (small / medium / large)  | ~5m   | 080–099    |
| G       | Menu — New / Duplicate / Delete      | ~10m  | 100–129    |
| H       | Menu — Select Unused / Add Used / Sort | ~10m | 130–159  |
| I       | Open / Save Library                  | ~10m  | 160–179    |
| J       | Swatch Options dialog                | ~12m  | 180–219    |
| K       | Library Save dialog                  | ~5m   | 220–239    |
| L       | Appearance theming                   | ~5m   | 240–259    |
| M       | Cross-app parity                     | ~15m  | 300–329    |

Full pass: ~100 min. A gates the rest; otherwise sessions stand alone.

---

## Session A — Smoke & lifecycle (~5 min)

If any P0 here fails, stop and flag.

- [ ] **SWP-001** [wired] Panel opens via Window menu.
      Do: Select Window → Swatches.
      Expect: Swatches panel appears in dock or floating; no console error.
      — last: —

- [ ] **SWP-002** [wired] All panel rows render without layout collapse.
      Do: Visually scan the open panel.
      Expect: Header with Fill/Stroke widget; "Recent Colors" label + 10
              swatch slots row; library disclosure with name + triangle;
              swatch grid below the disclosure. No overlapping controls,
              no truncated labels.
      — last: —

- [ ] **SWP-003** [wired] Panel collapses and re-expands.
      Do: Click the panel header to collapse; click again to expand.
      Expect: Content hides / reveals; header stays visible; no crash.
      — last: —

- [ ] **SWP-004** [wired] Panel closes via context menu / X button.
      Do: Right-click header → Close, or click the close affordance.
      Expect: Panel disappears; Window → Swatches reopens it.
      — last: —

- [ ] **SWP-005** [wired] Panel floats out of the dock.
      Do: Drag the panel header out of the dock.
      Expect: Panel becomes a floating window; controls stay interactive;
              returns to dock on drag back.
      — last: —

---

## Session B — Recent colors row (~5 min)

The Recent Colors row mirrors the Color panel's recent list (same backing
state); see `COLOR_TESTS.md` Session H for full coverage. Tests here
verify the Swatches-panel surface only.

- [ ] **SWP-010** [wired] Recent row renders 10 swatch slots.
      Do: Visually inspect.
      Expect: 10 16×16 squares left-to-right; empty slots render hollow.
      — last: —

- [ ] **SWP-011** [wired] Single-click on a recent swatch sets active color.
      Setup: At least one recent color present (e.g. via Color panel).
      Do: Click `sp_recent_0`.
      Expect: Selection's active fill (or stroke per `state.fill_on_top`)
              becomes that color.
      — last: —

- [ ] **SWP-012** [wired] Double-click on a recent swatch opens Swatch Options
      dialog in create mode.
      Setup: At least one recent color.
      Do: Double-click `sp_recent_0`.
      Expect: Modal Swatch Options dialog opens; name field empty; color
              preview shows the recent color.
      — last: —

- [ ] **SWP-013** [wired] Recent row stays in sync with the Color panel.
      Setup: Color panel + Swatches panel both visible.
      Do: Commit a new color via the Color panel hex field.
      Expect: Same color now appears at slot 0 of both panels' recent rows.
      — last: —

---

## Session C — Default Web Colors library (~5 min)

- [ ] **SWP-020** [wired] Web Colors library opens by default on first launch.
      Setup: Fresh workspace, never opened Swatches before.
      Do: Open the Swatches panel.
      Expect: Library disclosure shows "Web Colors"; triangle expanded;
              216 swatch tiles rendered below.
      — last: —

- [ ] **SWP-021** [wired] Web Colors library has 216 swatches.
      Do: Count rendered swatches under the Web Colors disclosure.
      Expect: 216 (6×6×6 web-safe RGB cube).
      — last: —

- [ ] **SWP-022** [wired] Each Web Colors swatch is web-safe.
      Setup: Web Colors library expanded.
      Do: Hover or click any swatch; check the resulting color via the
          Color panel.
      Expect: Each channel value is in {0, 51, 102, 153, 204, 255}.
      — last: —

- [ ] **SWP-023** [wired] Default library name matches its file's `name` field.
      Do: Inspect the disclosure label vs `workspace/swatches/web_colors.json`.
      Expect: Disclosure shows "Web Colors" (the file's `name` field, not
              the file stem `web_colors`).
      — last: —

---

## Session D — Library disclosure / collapse (~5 min)

- [ ] **SWP-030** [wired] Disclosure triangle starts in expanded state.
      Setup: Fresh open of the panel.
      Expect: Triangle pointing down (▾); swatch grid visible.
      — last: —

- [ ] **SWP-031** [wired] Click triangle collapses the library.
      Do: Click the disclosure triangle.
      Expect: Triangle rotates to collapsed (▸); swatch grid hides; library
              name still visible.
      — last: —

- [ ] **SWP-032** [wired] Click again expands.
      Do: Click the collapsed triangle.
      Expect: Triangle returns to ▾; grid re-renders.
      — last: —

- [ ] **SWP-033** [wired] Collapse state is panel-local (persists per session).
      Setup: Library collapsed.
      Do: Close the Swatches panel; reopen via Window → Swatches.
      Expect: Library still collapsed (or returns to expanded — document
              actual; SWATCHES.md does not yet specify persistence).
      — last: —

- [ ] **SWP-034** [wired] Multiple open libraries each have independent collapse.
      Setup: Two libraries open via Open Swatch Library.
      Do: Collapse the first; leave the second.
      Expect: Each library's triangle reflects its own state; the other
              library's grid stays visible.
      — last: —

---

## Session E — Swatch click + selection (~8 min)

**P0**

- [ ] **SWP-050** [wired] Single-click on a swatch sets the active fill color.
      Setup: Rectangle selected, fill = `#000000`, `state.fill_on_top=true`.
      Do: Click a red swatch in the Web Colors grid.
      Expect: Rectangle fill becomes that red; the swatch gains a 2px
              accent outline (`jas-selected`); recent-colors row picks up
              the new color.
      — last: —

- [ ] **SWP-051** [wired] Single-click on a swatch sets stroke when stroke is on top.
      Setup: `state.fill_on_top=false` (stroke active).
      Do: Click a swatch.
      Expect: Selection's stroke becomes the swatch color; fill unchanged.
      — last: —

**P1**

- [ ] **SWP-052** [wired] Click an already-selected swatch is a no-op for color.
      Setup: Swatch already selected; selection's fill = its color.
      Do: Click the same swatch again.
      Expect: No change; recent-colors does not duplicate.
      — last: —

- [ ] **SWP-053** [wired] Shift-click extends the selection.
      Setup: Swatch A selected.
      Do: Shift+click swatch B (in the same library).
      Expect: Both A and B carry the `jas-selected` outline; active color
              follows the most recently clicked.
      — last: —

- [ ] **SWP-054** [wired] Cmd / Ctrl-click toggles a swatch in the selection.
      Setup: A and B selected.
      Do: Cmd/Ctrl-click A.
      Expect: A deselects (outline removed); B remains selected.
      — last: —

- [ ] **SWP-055** [wired] Plain click on a different swatch replaces selection.
      Setup: A and B selected.
      Do: Click swatch C.
      Expect: Only C is selected; A and B lose their outlines.
      — last: —

- [ ] **SWP-056** [wired] Double-click on a swatch opens Swatch Options in edit mode.
      Setup: A swatch present (default library).
      Do: Double-click any swatch.
      Expect: Modal Swatch Options dialog opens; name field shows that
              swatch's name; color preview matches.
      — last: —

**P2**

- [ ] **SWP-057** [wired] Selection is per-library (selecting in B doesn't clear A).
      Setup: Library A and Library B both open; one swatch selected in A.
      Do: Click a swatch in B.
      Expect: B's swatch selected; A's selection persists (per-library
              `selected_swatches`).
      — last: —

- [ ] **SWP-058** [wired] Selection visual is a 2px accent outline.
      Do: Select any swatch; inspect.
      Expect: 2px outline in the appearance's accent color around the tile.
      — last: —

---

## Session F — View modes (small / medium / large) (~5 min)

- [ ] **SWP-080** [wired] Default thumbnail size is Small.
      Setup: Fresh workspace.
      Expect: Tiles render at 16px; menu shows checkmark on Small Thumbnail.
      — last: —

- [ ] **SWP-081** [wired] Switching to Medium re-renders at 32px.
      Do: Menu → Medium Thumbnail View.
      Expect: All swatch tiles grow to 32px; checkmark moves to Medium.
      — last: —

- [ ] **SWP-082** [wired] Switching to Large re-renders at 64px.
      Do: Menu → Large Thumbnail View.
      Expect: Tiles grow to 64px.
      — last: —

- [ ] **SWP-083** [wired] Switching back to Small returns to 16px.
      Do: Menu → Small Thumbnail View.
      Expect: Tiles shrink to 16px.
      — last: —

- [ ] **SWP-084** [wired] View mode does not affect Recent Colors row.
      Setup: Large Thumbnail View active.
      Expect: Recent Colors row still 16px (recent row size is independent
              of view mode).
      — last: —

- [ ] **SWP-085** [wired] View mode is panel-local (not persisted with document).
      Setup: Medium active.
      Do: Close the document; create a new one.
      Expect: View mode either persists app-wide (preferred) or reverts to
              Small. Document either; SWATCHES.md says "panel-local, not
              per-document".
      — last: —

---

## Session G — Menu: New / Duplicate / Delete (~10 min)

- [ ] **SWP-100** [wired] New Swatch appends current active color.
      Setup: Active color = `#ff6600`.
      Do: Menu → New Swatch.
      Expect: A new swatch with that color appears at the end of the
              currently selected library; Swatch Options dialog opens in
              create mode with the color preview matching.
      — last: —

- [ ] **SWP-101** [wired] New Swatch dialog Cancel discards.
      Setup: As SWP-100, dialog open.
      Do: Click Cancel.
      Expect: No new swatch persisted (the appended swatch is discarded).
      — last: —

- [ ] **SWP-102** [wired] New Swatch dialog OK names + persists.
      Setup: As SWP-100; dialog open.
      Do: Enter name "Brand Orange" → OK.
      Expect: New swatch persists in the selected library with the entered
              name; library file gains the entry.
      — last: —

- [ ] **SWP-110** [wired] Duplicate Swatch enabled only when ≥1 swatch selected.
      Setup: No swatch selected.
      Expect: Menu → Duplicate Swatch is dimmed.
      — last: —

- [ ] **SWP-111** [wired] Duplicate inserts a copy after the original.
      Setup: Swatch "Red" selected (color `#ff0000`).
      Do: Menu → Duplicate Swatch.
      Expect: A new swatch "Red copy" appears immediately after; selection
              moves to the copy; original keeps its position.
      — last: —

- [ ] **SWP-112** [wired] Duplicate of a multi-selection inserts copies for each.
      Setup: Two swatches A, B selected.
      Do: Menu → Duplicate Swatch.
      Expect: "A copy" inserted after A, "B copy" after B; the two copies
              become the new selection.
      — last: —

- [ ] **SWP-120** [wired] Delete Swatch enabled only when ≥1 swatch selected.
      Setup: No selection.
      Expect: Menu → Delete Swatch is dimmed.
      — last: —

- [ ] **SWP-121** [wired] Delete removes the selected swatches.
      Setup: One swatch selected.
      Do: Menu → Delete Swatch.
      Expect: Swatch removed from the library; selection cleared; library
              file (when next saved) reflects the removal.
      — last: —

- [ ] **SWP-122** [known-broken: no undo] Cmd+Z does not restore deleted swatches.
      Setup: Delete a swatch.
      Do: Cmd+Z (Undo).
      Expect: (Target) deleted swatch restored. (Current) deletion is
              permanent; document the regression here.
      — last: —

---

## Session H — Menu: Select Unused / Add Used / Sort (~10 min)

- [ ] **SWP-130** [wired] Select All Unused selects every library swatch
      not present in the document.
      Setup: Document with 2 elements using `#ff0000` and `#0000ff` only;
             selected library has 10 swatches including those.
      Do: Menu → Select All Unused.
      Expect: 8 of 10 swatches selected (the ones not red or blue); the
              two used colors are NOT selected.
      — last: —

- [ ] **SWP-131** [wired] Select All Unused on an empty document selects every swatch.
      Setup: Empty document.
      Do: Menu → Select All Unused.
      Expect: Every swatch in the selected library selected.
      — last: —

- [ ] **SWP-140** [wired] Add Used Colors creates swatches for new colors only.
      Setup: Document with elements colored `#ff0000`, `#00ff00`, `#0000ff`;
             selected library already contains red.
      Do: Menu → Add Used Colors.
      Expect: Two new swatches appended ("R=0 G=255 B=0", "R=0 G=0 B=255");
              red is NOT duplicated (compared by hex).
      — last: —

- [ ] **SWP-141** [wired] Add Used Colors with all-already-present is a no-op.
      Setup: Document colors all already present in selected library.
      Do: Menu → Add Used Colors.
      Expect: No new swatches; library unchanged.
      — last: —

- [ ] **SWP-150** [wired] Sort by Name reorders the selected library alphabetically.
      Setup: Library with swatches in arbitrary order: "Zinc", "Apple",
             "Bronze".
      Do: Menu → Sort by Name.
      Expect: Order becomes Apple, Bronze, Zinc (case-sensitive ASCII).
      — last: —

- [ ] **SWP-151** [wired] Sort by Name is permanent (persists on save).
      Setup: Sort applied.
      Do: Menu → Save Swatch Library → name "test" → Save.
      Expect: Saved JSON contains swatches in the new alphabetical order.
      — last: —

---

## Session I — Open / Save Library (~10 min)

- [ ] **SWP-160** [wired] Open Swatch Library submenu lists every JSON in
      `workspace/swatches/`.
      Do: Menu → Open Swatch Library.
      Expect: Submenu shows one item per `*.json` file in the directory;
              already-open libraries carry a checkmark.
      — last: —

- [ ] **SWP-161** [wired] Selecting a library adds it to `panel.open_libraries`.
      Setup: Only Web Colors open.
      Do: Submenu → another library (e.g. add a second JSON file in advance).
      Expect: Library appears below Web Colors; disclosure expanded;
              swatch grid renders the new library's swatches.
      — last: —

- [ ] **SWP-162** [wired] Selecting an already-open library is a no-op (or focuses).
      Setup: Web Colors already open.
      Do: Submenu → Web Colors.
      Expect: No second copy added; checkmark behavior consistent (toggle
              vs persistent — document the actual).
      — last: —

- [ ] **SWP-170** [wired] Save Swatch Library opens the Save dialog.
      Do: Menu → Save Swatch Library.
      Expect: Modal dialog opens with name input and Save / Cancel buttons.
      — last: —

- [ ] **SWP-171** [wired] Save with empty name is disabled.
      Setup: Save dialog open, name input empty.
      Expect: Save button dimmed.
      — last: —

- [ ] **SWP-172** [wired] Save with valid name writes JSON to workspace/swatches/.
      Setup: Save dialog open, currently-selected library has its swatches.
      Do: Enter "my_palette" → Save.
      Expect: File `workspace/swatches/my_palette.json` exists; contains
              the expected swatches.
      — last: —

- [ ] **SWP-173** [wired] Saving a library with the same name as an existing
      one overwrites or warns.
      Setup: `web_colors.json` exists.
      Do: Save dialog → "web_colors" → Save.
      Expect: Either overwrites silently or shows a confirm. Document the
              actual; either is acceptable.
      — last: —

---

## Session J — Swatch Options dialog (~12 min)

**P0**

- [ ] **SWP-180** [wired] Dialog opens at 300px wide with all expected fields.
      Do: Double-click any swatch.
      Expect: Modal dialog 300px wide; Name input, Color Type dropdown
              (disabled "Process Color"), Global toggle (disabled), Color
              Mode dropdown, color preview swatch (40px), slider group for
              the active mode, Hex input, Preview toggle, Cancel + OK.
      — last: —

- [ ] **SWP-181** [known-broken: global flag not propagated] Global toggle is
      currently a no-op.
      Setup: Dialog open in edit mode.
      Do: Toggle Global on → OK.
      Expect: (Target) edits to this swatch later propagate to all elements
              using it. (Current) flag stored but ignored at edit time.
      — last: —

**P1**

- [ ] **SWP-190** [wired] Dialog edit mode pre-fills the swatch's current values.
      Setup: Swatch "Brand Red" `#ff0000` HSB-saved.
      Do: Double-click → dialog opens.
      Expect: Name = "Brand Red"; preview = red; mode = HSB; H/S/B sliders
              show 0/100/100; hex = ff0000.
      — last: —

- [ ] **SWP-191** [wired] Changing color in dialog updates the preview live.
      Setup: Dialog open.
      Do: Drag the H slider.
      Expect: Color preview updates as the slider moves; underlying swatch
              not yet updated (until OK).
      — last: —

- [ ] **SWP-192** [wired] Mode switch within the dialog swaps the slider group.
      Setup: Dialog mode = HSB.
      Do: Color Mode dropdown → RGB.
      Expect: H/S/B sliders hide; R/G/B sliders show with current color's
              RGB values.
      — last: —

- [ ] **SWP-193** [wired] Hex field commits on Enter / Tab.
      Setup: Dialog open.
      Do: Type `00ff00` into Hex; Enter.
      Expect: Preview becomes green; sliders update to match.
      — last: —

- [ ] **SWP-194** [wired] OK persists name + color to the swatch.
      Setup: Dialog open, name changed to "Lime", color changed.
      Do: Click OK.
      Expect: Dialog closes; swatch's tile in the grid now reflects the
              new color; hovering shows the new name.
      — last: —

- [ ] **SWP-195** [wired] Cancel discards all edits.
      Setup: Dialog open, name and color edited.
      Do: Click Cancel.
      Expect: Dialog closes; swatch unchanged.
      — last: —

- [ ] **SWP-196** [wired] Create-mode dialog has empty name placeholder.
      Setup: Menu → New Swatch.
      Expect: Dialog opens with the active color in preview, but Name
              field empty (or showing a placeholder).
      — last: —

**P2**

- [ ] **SWP-200** [wired] Web Safe RGB mode snaps the color on commit.
      Setup: Dialog open, color = `#abcdef`.
      Do: Color Mode → Web Safe RGB → OK.
      Expect: Saved swatch color snaps to nearest web-safe value.
      — last: —

- [ ] **SWP-201** [wired] Color Type dropdown is disabled (always Process).
      Do: Try to change Color Type.
      Expect: Dropdown is non-interactive; locked to "Process Color".
      — last: —

- [ ] **SWP-202** [wired] Preview toggle on previews into the document live.
      Setup: Dialog open, an element selected in the document. Toggle
             Preview on.
      Do: Drag a slider.
      Expect: (Future) Selected element's color updates live as you drag.
              Currently a placeholder — document behavior.
      — last: —

---

## Session K — Library Save dialog (~5 min)

- [ ] **SWP-220** [wired] Save dialog opens with empty name input.
      Do: Menu → Save Swatch Library.
      Expect: Dialog opens; Name input empty; placeholder "My Swatches".
      — last: —

- [ ] **SWP-221** [wired] Save button disabled when name is empty.
      Expect: Save button dimmed; cannot click.
      — last: —

- [ ] **SWP-222** [wired] Typing a name enables Save.
      Do: Type a non-empty string.
      Expect: Save button becomes interactive.
      — last: —

- [ ] **SWP-223** [wired] Save writes to `workspace/swatches/<name>.json`.
      Do: Type "session_test" → Save.
      Expect: File `workspace/swatches/session_test.json` exists; well-
              formed JSON containing the currently-selected library's
              swatches.
      — last: —

- [ ] **SWP-224** [wired] Cancel closes without writing.
      Do: Open dialog → type a name → Cancel.
      Expect: No file created; dialog closes.
      — last: —

- [ ] **SWP-225** [wired] Names with path separators are rejected or sanitized.
      Do: Type "../bad" → Save.
      Expect: Either rejected with an error or sanitized to a safe stem;
              no file written outside `workspace/swatches/`.
      — last: —

---

## Session L — Appearance theming (~5 min)

- [ ] **SWP-240** [wired] Dark appearance: every swatch tile readable.
      Setup: Dark appearance active.
      Expect: Tile borders distinguishable from panel bg; light swatches
              (e.g. white) visible against panel.
      — last: —

- [ ] **SWP-241** [wired] Medium Gray appearance mirrors Dark.
      Do: Switch appearance → Medium Gray.
      Expect: Panel re-skins; tile and label tokens read correctly.
      — last: —

- [ ] **SWP-242** [wired] Light Gray appearance: dark swatches still visible.
      Do: Switch to Light Gray.
      Expect: Black / dark swatches don't blend into the bg; tile borders
              visible.
      — last: —

- [ ] **SWP-243** [wired] Selected-tile accent outline visible in every appearance.
      Do: In each appearance, select a swatch.
      Expect: 2px outline distinguishable from the unselected state.
      — last: —

- [ ] **SWP-244** [wired] "Recent Colors" label uses `theme.colors.text_dim`.
      Do: Visually inspect the label across appearances.
      Expect: Label color follows the appearance's text-dim token.
      — last: —

---

## Session M — Cross-app parity (~15 min)

~5–8 load-bearing `[wired]` tests where cross-language drift produces
user-visible bugs. Batch by app: run a full column at a time.

Currently most native apps ship Swatches as scaffolding only (per SWP-301
known-broken); the parity column documents the expected target behavior
and which apps reach it.

- **SWP-300** [wired] Web Colors library opens by default with 216 swatches.
      Do: Fresh workspace → open Swatches.
      Expect: Disclosure shows "Web Colors" with 216 tiles.
      - [ ] Rust       last: — (per SWP-301: scaffolding only)
      - [ ] Swift      last: — (same)
      - [ ] OCaml      last: — (same)
      - [ ] Python     last: — (same)
      - [ ] Flask      last: —

- **SWP-301** [wired] Single-click on a swatch sets the active fill.
      Setup: Selection with explicit fill.
      Do: Click a red swatch.
      Expect: Selection's fill becomes that red.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **SWP-302** [wired] Double-click on a swatch opens Swatch Options in edit mode.
      Do: Double-click a tile.
      Expect: Modal dialog opens with the swatch's name + color pre-filled.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **SWP-303** [wired] New Swatch from active color appends + opens dialog.
      Setup: Active color = `#ff6600`.
      Do: Menu → New Swatch → name "Brand" → OK.
      Expect: Library gains a "Brand" swatch with `#ff6600`.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **SWP-304** [wired] View mode change resizes every tile in the panel.
      Do: Menu → Large Thumbnail View.
      Expect: All library tiles grow to 64px; recent row stays 16px.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **SWP-305** [wired] Sort by Name reorders alphabetically + persists.
      Setup: Library with mixed-order names, save it first.
      Do: Sort by Name → Save Swatch Library → same name → Save.
      Expect: Saved JSON contains alphabetical order.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **SWP-306** [wired] Add Used Colors creates new swatches only for unique
      hex values.
      Setup: Document with a few colors, library missing some of them.
      Do: Menu → Add Used Colors.
      Expect: New swatches created for unique-to-document colors only;
              compared by hex (no near-duplicates).
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
