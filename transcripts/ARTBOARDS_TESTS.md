# Artboards Panel — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/panels/artboards.yaml` (not yet created),
`workspace/dialogs/artboard_options.yaml` (not yet created),
`workspace/dialogs/rearrange_artboards.yaml` (phase 2, not yet created).
Design doc: `transcripts/ARTBOARDS.md`.

Primary platform for manual runs: **Flask (jas_flask)** — target of the
phase-1 implementation. Native apps (Rust / Swift / OCaml / Python) pick up
the feature in the order Rust → Swift → OCaml → Python per the project
rule, and are covered in Session P parity.

This suite is defined **before implementation** per the test-first rule in
`CLAUDE.md`. Every P0/P1 item starts `[unwired]`; items flip to `[wired]`
as the Flask pass lands, then to `[parity]` as native apps catch up.

---

## Known broken

_Last reviewed: 2026-04-20_

- **ART-900** [deferred: ARTBOARDS.md §Phase-1 deferrals — Artboard Tool]
  No canvas-side create / click-to-activate / drag-to-move / drag-to-resize.
  Users interact with artboards only through the panel in phase 1.
- **ART-901** [deferred: ARTBOARDS.md §Phase-1 deferrals — Convert to
  Artboards] Menu and context-menu entries present but grayed with
  `Coming soon` tooltip.
- **ART-902** [deferred: ARTBOARDS.md §Phase-1 deferrals — Rearrange
  Dialogue] Menu entry `Rearrange…` and footer `REARRANGE_BUTTON` grayed
  with `Coming soon` tooltip. Blue-dot accent on the footer button begins
  firing on the first list change; since the Dialogue never opens in
  phase 1, the dot stays lit.
- **ART-903** [deferred: ARTBOARDS.md §Canvas appearance —
  `update_while_dragging`] Toggle persists through save/load but has no
  observable effect (no canvas artboard drag exists yet).
- **ART-904** [deferred: ARTBOARDS.md §Canvas appearance —
  `video_ruler_pixel_aspect_ratio`] Value persists and round-trips
  through the Dialogue; no non-square-pixel distortion applied to canvas
  rendering.
- **ART-905** [deferred: ARTBOARDS.md §Printing] All print-related
  behavior. Fill-as-page-background, per-artboard display toggles being
  screen-only, and LAYERS.md `LAYER_PRINT` interaction are pinned in the
  spec but not implemented.

---

## Automation coverage

_Last synced: 2026-04-20_

**None.** No implementation yet; this suite defines the acceptance
criteria for the first Flask pass. Automation will be added alongside
each session's wiring:

- Flask (`jas_flask/tests/…`): panel rendering + action dispatch +
  Dialogue commit via the generic YAML interpreter, per the existing
  Layers / Boolean pattern.
- Python (`jas/…`): data-model invariants (at-least-one, positional
  numbering, stable id, naming rules).
- Rust / Swift / OCaml: parity suites when those apps pick up the
  feature.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_flask` for sessions A–O; per-app for P).
2. Open the default workspace with a fresh document. The default fixture
   contains exactly one artboard: `Artboard 1`, top-left `(0, 0)`,
   `612 × 792 pt`, transparent fill, all display toggles off, fresh `id`.
3. Open the Artboards Panel via Window → Artboards (or the default
   layout's docked location).
4. Appearance: **Dark** (`workspace/appearances/`).

Tests that need a richer fixture build it inline (New Artboard repeated;
Rectangle tool draws shapes; Object → Group) or state the delta on a
`Setup:` line.

---

## Tier definitions

- **P0 — existential.** If this fails, the panel is broken. Crash, layout
  collapse, complete non-function. 5-minute smoke confidence.
- **P1 — core.** Control does its primary job (click / drag / enter /
  select / toggle).
- **P2 — edge & polish.** Bounds, keyboard-only paths, focus / tab
  order, appearance variants, hit-target precision, invariant enforcement.

---

## Session table of contents

| Session | Topic                                         | Est.  | IDs        |
|---------|-----------------------------------------------|-------|------------|
| A       | Smoke & lifecycle                             | ~5m   | 001–009    |
| B       | Panel row rendering + hit targets             | ~6m   | 010–029    |
| C       | New / Delete / Duplicate                      | ~8m   | 030–059    |
| D       | Rename flow                                   | ~5m   | 060–079    |
| E       | Delete Empty Artboards                        | ~5m   | 080–099    |
| F       | Reordering (drag / buttons / keyboard)        | ~8m   | 100–129    |
| G       | Canvas rendering                              | ~10m  | 130–169    |
| H       | Fade overlay + global toggles                 | ~5m   | 170–189    |
| I       | Artboard Options Dialogue                     | ~15m  | 190–239    |
| J       | Menu + right-click context menu               | ~6m   | 240–269    |
| K       | Keyboard shortcuts + Tab order                | ~5m   | 270–289    |
| L       | At-least-one invariant                        | ~5m   | 290–309    |
| M       | Coordinates + reference-point widget          | ~5m   | 310–329    |
| N       | Phase-1 deferrals (grayed verification)       | ~4m   | 330–349    |
| O       | Appearance theming                            | ~3m   | 350–369    |
| P       | Cross-app parity                              | ~10m  | 400–449    |

Full pass: ~105 min. A gates the rest; otherwise sessions stand alone.

---

## Session A — Smoke & lifecycle (~5 min)

If any P0 here fails, stop and flag.

- [ ] **ART-001** [unwired] Panel opens via Window menu.
      Do: Window → Artboards.
      Expect: Artboards Panel appears in dock or floating; default
              "Artboard 1" row is visible; no console error.
      — last: —

- [ ] **ART-002** [unwired] All panel sections render without collapse.
      Do: Visually scan the open panel.
      Expect: Row body with at least one row; footer button row shows
              five buttons (Rearrange left-cluster; Move Up / Move Down /
              New / Delete right-cluster). No overlapping controls, no
              truncated names.
      — last: —

- [ ] **ART-003** [unwired] Panel collapses and re-expands.
      Do: Click the panel header to collapse; click again to expand.
      Expect: Content hides / reveals; header stays visible; no crash.
      — last: —

- [ ] **ART-004** [unwired] Panel closes via context menu / X button.
      Do: Right-click panel header → Close, or click the close
          affordance.
      Expect: Panel disappears; Window → Artboards reopens it.
      — last: —

- [ ] **ART-005** [unwired] Panel floats out of the dock.
      Do: Drag the panel header out of the dock.
      Expect: Becomes a floating window; controls remain interactive;
              returns to dock on drag back.
      — last: —

- [ ] **ART-006** [unwired] Default document has exactly one Artboard 1.
      Setup: Fresh document.
      Expect: Row body shows one row with `ARTBOARD_NUMBER = 1` and
              `ARTBOARD_NAME = "Artboard 1"`. Canvas shows one
              white-bordered rectangle labeled `1  Artboard 1`.
      — last: —

---

## Session B — Panel row rendering + hit targets (~6 min)

**P0**

- [ ] **ART-010** [unwired] Each row renders three cells in order.
      Setup: Default Artboard 1.
      Do: Inspect the row.
      Expect: `ARTBOARD_NUMBER` (narrow, 1-wide col), `ARTBOARD_NAME`
              (wide, 10-wide col), `ARTBOARD_OPTIONS_BUTTON` (narrow,
              1-wide col). No truncation at panel default width.
      — last: —

**P1**

- [ ] **ART-011** [unwired] Hovering a row paints the theme hover tint.
      Do: Mouse over a row.
      Expect: Background tint appears; leaves on mouse-out. Panel
              selection background, if any, is preserved.
      — last: —

- [ ] **ART-012** [unwired] Click on `ARTBOARD_NAME` panel-selects the row.
      Setup: 3 artboards, none panel-selected.
      Do: Click the name cell of row 2.
      Expect: Row 2 gains the selection background; rows 1 and 3 do not.
      — last: —

- [ ] **ART-013** [unwired] Click on `ARTBOARD_NUMBER` makes that row
      the sole panel-selected row.
      Setup: 3 artboards, rows 1 and 3 panel-selected.
      Do: Click the number cell of row 2.
      Expect: Row 2 is panel-selected; rows 1 and 3 are no longer
              selected. Same effect as a plain row click, but the hit
              target is the number cell specifically.
      — last: —

- [ ] **ART-014** [unwired] Click on `ARTBOARD_OPTIONS_BUTTON` opens
      the Dialogue for that row regardless of selection.
      Setup: 3 artboards, only row 3 panel-selected.
      Do: Click the options button on row 2.
      Expect: Artboard Options Dialogue opens for row 2. Panel-selection
              is unchanged (row 3 still selected after Cancel).
      — last: —

**P2**

- [ ] **ART-015** [unwired] Long names truncate with ellipsis.
      Setup: Rename `Artboard 1` to a 120-char name.
      Expect: The name cell shows the start of the name followed by `…`;
              hover tooltip shows the full name.
      — last: —

- [ ] **ART-016** [unwired] Number column stays 1..N with no gaps after
      a delete.
      Setup: 5 artboards.
      Do: Delete artboard at position 3.
      Expect: Column shows `1, 2, 3, 4` immediately — no `1, 2, _, 4, 5`
              transient; the previous position 4 becomes position 3,
              previous position 5 becomes position 4.
      — last: —

---

## Session C — New / Delete / Duplicate (~8 min)

**P0**

- [ ] **ART-030** [unwired] `New Artboard` button creates silently.
      Setup: Fresh document (1 artboard).
      Do: Click the `NEW_ARTBOARD_BUTTON` in the footer.
      Expect: A second row appears at the top of the list (above row 1);
              no Dialogue opens; canvas shows a new artboard offset by
              `(20, 20)` pt from the prior top-left; name is
              `"Artboard 2"`.
      — last: —

- [ ] **ART-031** [unwired] `New Artboard` inherits size from topmost
      existing artboard.
      Setup: Resize Artboard 1 to 400 × 300 pt via Dialogue.
      Do: New Artboard.
      Expect: The new artboard is 400 × 300 pt, not Letter.
      — last: —

- [ ] **ART-032** [unwired] `Delete Artboards` via trash footer button.
      Setup: 3 artboards, row 2 panel-selected.
      Do: Click `DELETE_ARTBOARD_BUTTON`.
      Expect: Row 2 is removed; list shows `Artboard 1` and
              `Artboard 3`, now at positions 1 and 2; canvas redraws to
              show two remaining artboards.
      — last: —

**P1**

- [ ] **ART-033** [unwired] `Duplicate Artboards` copies the source.
      Setup: 2 artboards, row 1 panel-selected.
      Do: Panel menu → Duplicate Artboards.
      Expect: A new row appears; the duplicate has a fresh
              `"Artboard N"` name (not `"Artboard 1 copy"`); its bounds
              are offset by `(20, 20)` pt from the source.
      — last: —

- [ ] **ART-034** [unwired] Duplicate copies contained elements.
      Setup: Draw a red rectangle fully within Artboard 1.
      Do: Panel-select Artboard 1; Duplicate Artboards.
      Expect: A duplicate rectangle appears fully within the duplicated
              artboard, offset by `(20, 20)` pt from the original.
      — last: —

- [ ] **ART-035** [unwired] Duplicate skips elements partially outside.
      Setup: Rectangle straddles Artboard 1's right edge.
      Do: Duplicate Artboard 1.
      Expect: The straddling rectangle is **not** duplicated. Only fully
              contained elements are copied.
      — last: —

- [ ] **ART-036** [unwired] Delete via Delete / Backspace key.
      Setup: Row 2 panel-selected, panel focused.
      Do: Press Delete.
      Expect: Same result as the trash button.
      — last: —

- [ ] **ART-037** [unwired] Undo restores a deleted artboard at its prior
      position with its prior id.
      Setup: 3 artboards, note the name and position of the row 2
             artboard.
      Do: Delete it; Cmd-Z.
      Expect: Row 2 reappears at position 2 with the original name.
              Panel-selection state restored.
      — last: —

**P2**

- [ ] **ART-038** [unwired] New Artboard default placement with no
      panel-selection.
      Setup: Fresh document; no panel-selection.
      Do: New Artboard.
      Expect: The new artboard appears at the **end** of the list
              (position 2), not above nothing. Offset `(20, 20)` pt
              from the default artboard's top-left.
      — last: —

- [ ] **ART-039** [unwired] Fresh name skips used numbers.
      Setup: Rename Artboard 1 to "Cover"; create a New Artboard; delete
             Artboard 2; rename Artboard 1 back to "Artboard 1"; now
             create New Artboard.
      Expect: The new artboard is named `"Artboard 2"` (smallest unused
              N is 2, since "Artboard 1" is now taken).
      — last: —

---

## Session D — Rename flow (~5 min)

**P0**

- [ ] **ART-060** [unwired] Click-and-wait on the name cell enters
      inline rename.
      Setup: Row 1 panel-selected.
      Do: Click `ARTBOARD_NAME`; hold ~500ms.
      Expect: Inline text field replaces the cell; the prior name is
              pre-selected.
      — last: —

**P1**

- [ ] **ART-061** [unwired] F2 enters rename on a single selection.
      Setup: Row 1 panel-selected, panel focused.
      Do: Press F2.
      Expect: Same rename mode as ART-060.
      — last: —

- [ ] **ART-062** [unwired] Enter commits; Escape cancels.
      Setup: In rename mode with buffer `"Cover"`.
      Do: Press Enter.
      Expect: Name column now shows `"Cover"`. Repeat with Escape:
              prior name restored.
      — last: —

- [ ] **ART-063** [unwired] Empty rename reverts silently.
      Setup: In rename mode; clear the buffer; press Enter.
      Expect: Prior name restored; no error dialog or toast.
      — last: —

- [ ] **ART-064** [unwired] Whitespace-only rename reverts silently.
      Setup: In rename mode; type `"   "`; press Enter.
      Expect: Prior name restored.
      — last: —

- [ ] **ART-065** [unwired] Trim on commit.
      Setup: Rename to `"  Cover  "`; press Enter.
      Expect: Stored and displayed name is `"Cover"` (no surrounding
              whitespace).
      — last: —

**P2**

- [ ] **ART-066** [unwired] Rename menu entry enabled only on single
      selection.
      Setup: Rows 1 and 2 panel-selected.
      Expect: Panel menu `Rename` is grayed.
      — last: —

- [ ] **ART-067** [unwired] 256-char truncation.
      Setup: Paste a 400-char string into the rename field; press Enter.
      Expect: Stored name is exactly 256 characters.
      — last: —

- [ ] **ART-068** [unwired] Duplicate names allowed.
      Setup: Rename row 1 to `"Cover"`; rename row 2 also to `"Cover"`.
      Expect: Both rows show `"Cover"`. Number column distinguishes them.
      — last: —

---

## Session E — Delete Empty Artboards (~5 min)

**P1**

- [ ] **ART-080** [unwired] Sweeps all empty artboards in one undo op.
      Setup: 4 artboards. Place a shape so it intersects only
             artboards 1 and 3. Artboards 2 and 4 are empty.
      Do: Panel menu → Delete Empty Artboards.
      Expect: Artboards 2 and 4 removed in one op. List shows two rows
              (prior 1 and prior 3), now at positions 1 and 2. Cmd-Z
              restores both.
      — last: —

- [ ] **ART-081** [unwired] Preserves position 1 when all are empty.
      Setup: 3 artboards; no elements.
      Do: Delete Empty Artboards.
      Expect: Only the artboard at position 1 remains. List length == 1.
      — last: —

- [ ] **ART-082** [unwired] Menu entry grayed when no empty artboards.
      Setup: Every artboard intersects some element.
      Expect: Panel menu `Delete Empty Artboards` is grayed.
      — last: —

- [ ] **ART-083** [unwired] Menu entry grayed at N=1 when the lone
      artboard is empty.
      Setup: Fresh document (1 empty artboard).
      Expect: `Delete Empty Artboards` is grayed (preserving position 1
              means no deletion would occur).
      — last: —

**P2**

- [ ] **ART-084** [unwired] Hidden elements count as non-empty.
      Setup: Rectangle inside Artboard 1; set the containing layer to
             invisible.
      Do: Delete Empty Artboards.
      Expect: Artboard 1 is **not** deleted. The hidden element still
              counts.
      — last: —

- [ ] **ART-085** [unwired] Locked elements count as non-empty.
      Setup: Rectangle inside Artboard 1; lock the element.
      Do: Delete Empty Artboards.
      Expect: Artboard 1 is **not** deleted.
      — last: —

- [ ] **ART-086** [unwired] Intersect, not contain.
      Setup: Rectangle partially overlapping Artboard 2's edge but
             mostly outside.
      Do: Delete Empty Artboards.
      Expect: Artboard 2 is **not** deleted — any intersection counts.
      — last: —

---

## Session F — Reordering (drag / buttons / keyboard) (~8 min)

**P1**

- [ ] **ART-100** [unwired] Drag row 3 above row 1.
      Setup: 5 artboards.
      Do: Drag row 3 above row 1, drop.
      Expect: List order is now `[3, 1, 2, 4, 5]`; number column
              renumbers to `1..5`; the dragged artboard now shows as
              `ARTBOARD_NUMBER = 1`.
      — last: —

- [ ] **ART-101** [unwired] Horizontal insertion line during drag.
      Setup: 3 artboards.
      Do: Start dragging row 1; hover between rows 2 and 3 without
          dropping.
      Expect: A horizontal line appears between rows 2 and 3; no row
              commitment until drop.
      — last: —

- [ ] **ART-102** [unwired] Move Up button moves a contiguous selection.
      Setup: 5 artboards; rows 3 and 4 panel-selected.
      Do: Click `MOVE_UP_BUTTON`.
      Expect: List order now `[1, 3, 4, 2, 5]`.
      — last: —

- [ ] **ART-103** [unwired] Move Up with discontiguous selection uses
      swap-skip-selected rule.
      Setup: 5 artboards; rows 1, 3, 5 panel-selected.
      Do: Move Up.
      Expect: List order now `[1, 3, 2, 5, 4]`. Row 1 stays (already at
              top); row 3 swaps with row 2; row 5 swaps with row 4.
      — last: —

- [ ] **ART-104** [unwired] Move Down is symmetric.
      Setup: 5 artboards; rows 1, 3 panel-selected.
      Do: Move Down.
      Expect: List order now `[2, 1, 4, 3, 5]`. Row 1 swaps with row 2;
              row 3 swaps with row 4.
      — last: —

- [ ] **ART-105** [unwired] Option+Up / Option+Down keyboard parity.
      Setup: Same as ART-102.
      Do: Press Option+Up.
      Expect: Same result as Move Up button.
      — last: —

- [ ] **ART-106** [unwired] Move Up button disabled at top.
      Setup: Row 1 panel-selected.
      Expect: `MOVE_UP_BUTTON` grayed.
      — last: —

- [ ] **ART-107** [unwired] Panel-selection follows the moved artboard.
      Setup: 5 artboards; row 3 panel-selected.
      Do: Move Up twice.
      Expect: The panel-selected artboard is now at position 1, and the
              selection background is visibly on position 1 — the
              selection tracked by `id`, not by index.
      — last: —

**P2**

- [ ] **ART-108** [unwired] Single reorder is one undo op.
      Setup: Post-reorder from ART-100.
      Do: Cmd-Z once.
      Expect: Entire reorder reverts in one step (not per-swap).
      — last: —

---

## Session G — Canvas rendering (~10 min)

**P0**

- [ ] **ART-130** [unwired] Default artboard paints a white-bordered
      rectangle on gray canvas.
      Setup: Fresh document.
      Expect: A rectangle with a 1px screen-space dark border; fill is
              canvas gray (transparent default, canvas shows through).
      — last: —

- [ ] **ART-131** [unwired] Label `N  Name` appears above the top-left.
      Expect: `1  Artboard 1` visible just above the top-left corner,
              left-aligned, screen-pixel size.
      — last: —

**P1**

- [ ] **ART-132** [unwired] Transparent fill shows canvas gray.
      Setup: Fill set to Transparent.
      Expect: No paint inside the border; canvas gray visible.
      — last: —

- [ ] **ART-133** [unwired] White fill paints the rectangle.
      Setup: Fill set to White.
      Expect: Rectangle is solid white; canvas gray no longer visible
              inside.
      — last: —

- [ ] **ART-134** [unwired] Arbitrary color fill paints the rectangle.
      Setup: Fill set via Custom… color picker to `#FFCC00`.
      Expect: Rectangle paints solid `#FFCC00`.
      — last: —

- [ ] **ART-135** [unwired] Accent border on panel-selected.
      Setup: 2 artboards. Panel-select row 2.
      Expect: Row 2's canvas artboard shows a second border (2px outside
              the 1px default, theme accent color; total visual
              thickness 3px). Row 1 shows only the default 1px border.
      — last: —

- [ ] **ART-136** [unwired] Accent border tracks panel-selection
      changes.
      Setup: 2 artboards.
      Do: Panel-select row 1; then row 2; then Cmd-click row 1 to
          extend; then click row 1 alone.
      Expect: Accent border moves and extends accordingly.
      — last: —

- [ ] **ART-137** [unwired] Overlapping artboards: later fill wins.
      Setup: Artboard 2 overlaps Artboard 1 and has fill `#FF0000`;
             Artboard 1 has white fill.
      Expect: In the overlap region, red is visible (Artboard 2 is
              later in the list, so paints over Artboard 1).
      — last: —

**P2**

- [ ] **ART-138** [unwired] Show Center Mark.
      Setup: Enable `show_center_mark` on Artboard 1.
      Expect: A small cross appears at the geometric center; screen-
              pixel size, theme muted-foreground.
      — last: —

- [ ] **ART-139** [unwired] Show Cross Hairs.
      Setup: Enable `show_cross_hairs`.
      Expect: A horizontal line at vertical-center and a vertical line
              at horizontal-center, each spanning artboard bounds.
      — last: —

- [ ] **ART-140** [unwired] Show Video Safe Areas.
      Setup: Enable `show_video_safe_areas`.
      Expect: Two nested rectangles centered on the artboard at 90% and
              80% of width/height, theme muted-foreground.
      — last: —

- [ ] **ART-141** [unwired] Video Pixel Aspect Ratio persists but has
      no visual effect.
      Setup: Dialogue, set Video Ruler Pixel Aspect Ratio to 2.0.
      Expect: Value is stored and reappears on reopen. Canvas render is
              unchanged (phase-1 deferral ART-904).
      — last: —

- [ ] **ART-142** [unwired] Labels may overlap when artboards are
      close.
      Setup: Two artboards with near-touching top edges.
      Expect: Both labels render; they may overlap each other; no
              collision avoidance applied.
      — last: —

- [ ] **ART-143** [unwired] Border is zoom-independent.
      Setup: Zoom from 25% to 400%.
      Expect: Border thickness stays 1px screen-space at every zoom.
      — last: —

- [ ] **ART-144** [unwired] Label is zoom-independent.
      Expect: Label text size is constant across zooms; only its
              position relative to the artboard scales.
      — last: —

---

## Session H — Fade overlay + global toggles (~5 min)

**P1**

- [ ] **ART-170** [unwired] Fade overlay on (default) dims elements
      outside artboards.
      Setup: Rectangle entirely outside any artboard; Fade Region On.
      Expect: The rectangle renders at ~50% opacity; canvas gray
              beneath it is unchanged.
      — last: —

- [ ] **ART-171** [unwired] Fade off restores full opacity.
      Setup: Dialogue, uncheck `FADE_REGION_CHECKBOX`, OK.
      Expect: The off-artboard rectangle now renders at full opacity.
      — last: —

- [ ] **ART-172** [unwired] Fade is global — affects all artboards.
      Setup: Open the Dialogue for Artboard 2, uncheck Fade Region, OK.
      Expect: Fade is also off for Artboard 1 (single document flag,
              not per-artboard).
      — last: —

- [ ] **ART-173** [unwired] Update While Dragging persists but is
      no-op in phase 1.
      Setup: Toggle `UPDATE_WHILE_DRAGGING_CHECKBOX`; OK; reopen
             Dialogue.
      Expect: Checkbox state preserved. No observable canvas effect
              (ART-903).
      — last: —

**P2**

- [ ] **ART-174** [unwired] Update-while-dragging disabled when fade is
      off.
      Setup: Uncheck Fade Region.
      Expect: `UPDATE_WHILE_DRAGGING_CHECKBOX` becomes disabled
              (grayed), preserving any prior checked state for when
              Fade Region is re-enabled.
      — last: —

---

## Session I — Artboard Options Dialogue (~15 min)

**P0**

- [ ] **ART-190** [unwired] Dialogue opens via row button.
      Do: Click `ARTBOARD_OPTIONS_BUTTON` on row 1.
      Expect: Dialogue opens with Name pre-selected; all fields show
              current artboard values.
      — last: —

- [ ] **ART-191** [unwired] Dialogue opens via panel menu → Artboard
      Options….
      Setup: Row 2 panel-selected.
      Expect: Dialogue opens for row 2 (topmost panel-selected).
      — last: —

**P1**

- [ ] **ART-192** [unwired] Name commit on OK.
      Do: Type `"Cover"` into Name; OK.
      Expect: Row 1's name is now `"Cover"` in the panel and on the
              canvas label.
      — last: —

- [ ] **ART-193** [unwired] Preset sets Width and Height only.
      Setup: Dialogue open for an artboard at non-default position.
      Do: Pick `A4` preset; OK.
      Expect: Width = 595.28, Height = 841.89. X and Y unchanged.
      — last: —

- [ ] **ART-194** [unwired] Custom appears when W/H doesn't match any
      preset.
      Setup: Width 500, Height 500.
      Expect: Preset dropdown shows `Custom` (non-selectable).
      — last: —

- [ ] **ART-195** [unwired] Width / Height direct edit.
      Do: Edit Width to 800; OK.
      Expect: Canvas artboard is 800 pt wide. Reference-point anchor
              stays fixed on screen.
      — last: —

- [ ] **ART-196** [unwired] Chain-link proportional resize.
      Do: Engage `CHAIN_LINK_BUTTON`; edit Width; observe Height.
      Expect: Height scales to maintain the ratio captured at engage.
              Engaging, editing, disengaging, and re-engaging captures
              a fresh ratio each time.
      — last: —

- [ ] **ART-197** [unwired] Chain-link resets on Dialogue re-open.
      Do: Engage chain; OK. Reopen Dialogue.
      Expect: Chain is off (default state; session-only).
      — last: —

- [ ] **ART-198** [unwired] Reference-point default is center and
      persists across Dialogue opens.
      Setup: Default artboard at (0,0,612,792).
      Expect: First Dialogue open shows `X: 306, Y: 396` (center
              anchor). Change anchor to top-left; OK. Reopen Dialogue
              on a different artboard; top-left anchor is preselected.
      — last: —

- [ ] **ART-199** [unwired] Reference-point widget changes X/Y display,
      not storage.
      Setup: Dialogue for artboard at `(x=0, y=0, w=612, h=792)`.
      Do: Change anchor from center to top-left.
      Expect: X/Y fields now show `0, 0`. OK. Reopen: with anchor still
              top-left, shows `0, 0`. Canvas artboard has not moved.
      — last: —

- [ ] **ART-200** [unwired] Orientation toggle swaps W/H around anchor.
      Setup: Dialogue, anchor = center. W=612, H=792. X=306, Y=396.
      Do: Click the landscape icon.
      Expect: W becomes 792, H becomes 612. X stays 306, Y stays 396.
              Canvas: artboard rotates around its center.
      — last: —

- [ ] **ART-201** [unwired] Fill dropdown → White paints white.
      Do: Fill dropdown → White; OK.
      Expect: Canvas artboard fills white; swatch indicator shows
              white.
      — last: —

- [ ] **ART-202** [unwired] Fill dropdown → Custom… opens color picker.
      Do: Fill dropdown → Custom….
      Expect: Free-color picker opens; chosen color becomes fill; swatch
              indicator updates.
      — last: —

- [ ] **ART-203** [unwired] Fill → Transparent drops the fill.
      Do: Fill → Transparent; OK.
      Expect: Canvas shows gray through the border; swatch indicator
              shows the transparent red-slash.
      — last: —

- [ ] **ART-204** [unwired] Display toggles map 1:1 to fields.
      Do: Toggle each display checkbox; OK. Reopen Dialogue.
      Expect: Each state persisted.
      — last: —

- [ ] **ART-205** [unwired] Artboards count info reflects current N.
      Setup: 4 artboards.
      Expect: Dialogue info section shows `Artboards: 4`.
      — last: —

- [ ] **ART-206** [unwired] Delete button deletes this artboard and
      closes Dialogue.
      Setup: 3 artboards; Dialogue open for row 2.
      Do: Click Delete.
      Expect: Dialogue closes; list shows 2 rows (prior 1 and prior 3);
              row 2's artboard is gone.
      — last: —

- [ ] **ART-207** [unwired] Cancel discards all edits.
      Do: Change Name, Width, Fill; Cancel.
      Expect: No document changes; panel and canvas unchanged.
      — last: —

- [ ] **ART-208** [unwired] OK commits as a single undo op.
      Do: Change 5 fields; OK; Cmd-Z.
      Expect: All 5 changes revert in one undo step.
      — last: —

**P2**

- [ ] **ART-209** [unwired] Name empty-on-OK reverts.
      Do: Clear Name; OK.
      Expect: Name field silently reverts to the prior name on OK;
              Dialogue commits other changes.
      — last: —

- [ ] **ART-210** [unwired] Min Width/Height is 1.
      Do: Try Width 0; OK.
      Expect: Value clamps to 1, or OK is blocked with a validation
              indicator. Either is acceptable; behavior is consistent
              across ports.
      — last: —

- [ ] **ART-211** [unwired] Delete button grayed at N=1.
      Setup: Fresh document; open Dialogue for Artboard 1.
      Expect: Delete button is grayed; tooltip `At least one artboard
              must remain.`
      — last: —

---

## Session J — Menu + right-click context menu (~6 min)

**P0**

- [ ] **ART-240** [unwired] Panel hamburger menu opens with all 10
      entries (plus separators).
      Expect: New Artboard, Duplicate Artboards, Delete Artboards,
              Rename, ───, Delete Empty Artboards, ───, Convert to
              Artboards, Artboard Options…, Rearrange…, ───, Reset
              Panel. Convert and Rearrange grayed; Reset Panel always
              enabled.
      — last: —

**P1**

- [ ] **ART-241** [unwired] Right-click a non-selected row replaces
      panel-selection.
      Setup: Row 1 panel-selected.
      Do: Right-click row 2.
      Expect: Panel-selection becomes just row 2; context menu opens.
      — last: —

- [ ] **ART-242** [unwired] Right-click an already-selected row
      preserves the selection.
      Setup: Rows 1, 2, 3 panel-selected.
      Do: Right-click row 2.
      Expect: Rows 1, 2, 3 stay selected; context menu opens.
      — last: —

- [ ] **ART-243** [unwired] Context menu entries mirror panel menu.
      Expect: Artboard Options…, Rename, Duplicate Artboards, Delete
              Artboards, ───, Convert to Artboards (grayed). Enable
              rules match panel-menu counterparts.
      — last: —

- [ ] **ART-244** [unwired] Right-click empty panel area opens nothing.
      Setup: Click below the last row.
      Do: Right-click in the empty area.
      Expect: No menu appears.
      — last: —

**P2**

- [ ] **ART-245** [unwired] Cmd-held right-click does not toggle.
      Setup: Rows 1, 2 panel-selected.
      Do: Cmd-right-click row 1.
      Expect: Rows 1, 2 stay selected (not `{2}` alone); context menu
              opens.
      — last: —

- [ ] **ART-246** [unwired] Reset Panel leaves document data unchanged.
      Setup: Rename an artboard; scroll panel.
      Do: Panel menu → Reset Panel.
      Expect: Panel scroll returns to top; column widths reset if they
              were changed; artboard names and data unchanged.
      — last: —

---

## Session K — Keyboard shortcuts + Tab order (~5 min)

**P1**

- [ ] **ART-270** [unwired] Up / Down moves focus one row.
      Setup: 4 artboards; panel focused; row 1 focused.
      Do: Press Down.
      Expect: Focus on row 2; panel-selection is just row 2.
      — last: —

- [ ] **ART-271** [unwired] Shift+Up/Down extends range selection.
      Setup: Row 2 panel-selected (anchor).
      Do: Press Shift+Down twice.
      Expect: Rows 2, 3, 4 all panel-selected; anchor still row 2.
      — last: —

- [ ] **ART-272** [unwired] Cmd+A selects all artboards.
      Expect: Every row gains panel-selection background.
      — last: —

- [ ] **ART-273** [unwired] Escape during rename cancels.
      Setup: In inline rename mode.
      Do: Escape.
      Expect: Prior name restored; rename field closes.
      — last: —

- [ ] **ART-274** [unwired] Escape outside rename is no-op.
      Setup: 3 rows panel-selected.
      Do: Escape.
      Expect: Selection unchanged; no state visible state change.
      — last: —

**P2**

- [ ] **ART-275** [unwired] Tab enters panel at first row.
      Setup: Focus outside the panel.
      Do: Tab into the panel.
      Expect: Focus lands on the first (or most-recently-focused) row.
      — last: —

- [ ] **ART-276** [unwired] Tab order continues through footer buttons.
      Setup: Row focused.
      Do: Tab.
      Expect: Focus steps through `REARRANGE_BUTTON`, `MOVE_UP_BUTTON`,
              `MOVE_DOWN_BUTTON`, `NEW_ARTBOARD_BUTTON`,
              `DELETE_ARTBOARD_BUTTON` in order, then leaves the panel.
      — last: —

- [ ] **ART-277** [unwired] Tab does not step between rows.
      Setup: Row 1 focused.
      Do: Tab.
      Expect: Focus moves to the first footer button, not row 2.
              (Up/Down is the row navigator.)
      — last: —

---

## Session L — At-least-one invariant (~5 min)

**P1**

- [ ] **ART-290** [unwired] Delete Artboards grayed when selection
      spans all.
      Setup: 2 artboards; Cmd+A.
      Expect: `Delete Artboards` menu entry grayed; `DELETE_ARTBOARD_BUTTON`
              grayed; tooltip `At least one artboard must remain.`
      — last: —

- [ ] **ART-291** [unwired] Delete key no-op when selection spans all.
      Setup: Same as ART-290.
      Do: Press Delete.
      Expect: No deletion; no beep chaos; state unchanged.
      — last: —

- [ ] **ART-292** [unwired] Dialogue Delete button grayed at N=1.
      Setup: Fresh document; Dialogue open.
      Expect: Delete button grayed; tooltip present.
      — last: —

- [ ] **ART-293** [unwired] Empty artboards file loads with default
      inserted.
      Setup: Load a YAML with `artboards: []`.
      Expect: Document opens with exactly one default `Artboard 1` at
              origin. App log contains
              `Document had no artboards; inserted default.`
      — last: —

- [ ] **ART-294** [unwired] Missing artboards key loads same as empty.
      Setup: Load a YAML with no `artboards:` key at all.
      Expect: Same as ART-293.
      — last: —

**P2**

- [ ] **ART-295** [unwired] Can't delete past 1 via partial deletes.
      Setup: 3 artboards.
      Do: Delete all three one by one (the last delete should refuse).
      Expect: After two deletes, the third `DELETE_ARTBOARD_BUTTON` is
              grayed; one artboard remains.
      — last: —

---

## Session M — Coordinates + reference-point widget (~5 min)

**P1**

- [ ] **ART-310** [unwired] Default anchor center reports `(306, 396)`.
      Setup: Default document; Dialogue open for Artboard 1.
      Expect: X=306, Y=396 with center anchor selected.
      — last: —

- [ ] **ART-311** [unwired] Top-left anchor reports `(0, 0)`.
      Setup: Same artboard.
      Do: Click top-left anchor on the reference-point widget.
      Expect: X/Y fields update to `0, 0` without any document change.
      — last: —

- [ ] **ART-312** [unwired] Edit X under center anchor moves the
      artboard.
      Setup: Anchor = center; X = 306.
      Do: Change X to 500; OK.
      Expect: Artboard's top-left becomes `500 - 306 = 194`. Canvas
              artboard moves right by 194 pt.
      — last: —

- [ ] **ART-313** [unwired] Y-down convention: Y=50 moves the artboard
      down, not up.
      Setup: Anchor = top-left; Y = 0.
      Do: Change Y to 50; OK.
      Expect: Artboard moves downward by 50 pt on canvas (toward the
              bottom of the screen).
      — last: —

**P2**

- [ ] **ART-314** [unwired] Anchor preference persists across
      Dialogue opens but not across document save/load.
      Do: Change anchor; OK; reopen Dialogue on a different artboard.
      Expect: Same anchor preselected. Close app; reopen; behavior may
              reset to center (it's a panel preference, not a document
              field — implementation may or may not persist it across
              sessions; either is acceptable, but consistent across
              ports).
      — last: —

- [ ] **ART-315** [unwired] Anchor preference is not per-document.
      Setup: Change anchor; open a different document in a new tab/
             window if supported.
      Expect: The other document's Dialogue shows the same anchor
              preference.
      — last: —

---

## Session N — Phase-1 deferrals (grayed verification) (~4 min)

These tests exist specifically to confirm deferred features stay
deferred and display the expected affordances.

**P2**

- [ ] **ART-330** [unwired] `Convert to Artboards` grayed in panel menu.
      Setup: Draw a rectangle; select it as element-selection.
      Expect: Panel menu `Convert to Artboards` grayed with tooltip
              `Coming soon`.
      — last: —

- [ ] **ART-331** [unwired] `Convert to Artboards` grayed in context
      menu.
      Expect: Same grayed state and tooltip.
      — last: —

- [ ] **ART-332** [unwired] `Rearrange…` menu entry grayed.
      Setup: 2 artboards.
      Expect: Panel menu `Rearrange…` grayed with tooltip `Coming soon`.
      — last: —

- [ ] **ART-333** [unwired] `REARRANGE_BUTTON` grayed.
      Expect: Footer Rearrange button grayed with tooltip `Coming soon`.
      — last: —

- [ ] **ART-334** [unwired] Blue-dot accent appears on first list
      change.
      Setup: 1 artboard; note the footer Rearrange button.
      Do: New Artboard (first change).
      Expect: Blue dot accent appears on `REARRANGE_BUTTON`. Because
              the Dialogue never opens in phase 1, the dot remains lit
              for the rest of the session (ART-902).
      — last: —

- [ ] **ART-335** [unwired] Artboard Tool does not exist yet.
      Setup: Scan the toolbar / tools panel.
      Expect: No Artboard Tool entry. Click-to-move / drag-to-resize
              on canvas artboards does nothing (ART-900).
      — last: —

- [ ] **ART-336** [unwired] Print menu items or shortcuts do nothing
      artboard-specific.
      Expect: Any print-related UI is absent or no-op; the spec's
              print semantics are forward-reference only (ART-905).
      — last: —

---

## Session O — Appearance theming (~3 min)

**P2**

- [ ] **ART-350** [unwired] Dark appearance: panel readable.
      Setup: Appearance → Dark.
      Expect: Row text, button glyphs, and borders are visible against
              the dark panel background; no low-contrast surprises.
      — last: —

- [ ] **ART-351** [unwired] Medium Gray appearance: panel readable.
      Expect: Same visibility.
      — last: —

- [ ] **ART-352** [unwired] Light appearance: panel readable.
      Expect: Same visibility.
      — last: —

- [ ] **ART-353** [unwired] Canvas artboard border visible across all
      appearances.
      Expect: 1px border readable on Dark/Medium/Light canvas gray.
      — last: —

- [ ] **ART-354** [unwired] Accent border color tracks theme.
      Expect: Panel-selected artboard's accent border uses the current
              appearance's accent, not a hardcoded color.
      — last: —

---

## Session P — Cross-app parity (~10 min)

Run once each native app lands the feature. Order per CLAUDE.md:
Flask → Rust → Swift → OCaml → Python.

**P1**

- [ ] **ART-400** [unwired] Flask parity pass.
      Run Sessions A–O inline in the Flask app. Every P0/P1 item passes;
      P2 items documented where they fail.
      — last: —

- [ ] **ART-410** [unwired] Rust (jas_dioxus) parity pass.
      — last: —

- [ ] **ART-420** [unwired] Swift (JasSwift) parity pass.
      — last: —

- [ ] **ART-430** [unwired] OCaml (jas_ocaml) parity pass.
      — last: —

- [ ] **ART-440** [unwired] Python (jas) parity pass.
      — last: —

**P2**

- [ ] **ART-441** [unwired] YAML round-trip across apps.
      Save a multi-artboard document in one app; open in each of the
      other four.
      Expect: Identical panel state, canvas rendering, and Dialogue
              values everywhere. Stable `id`s preserved; derived
              `number`s identical; no fields lost or reformatted.
      — last: —

- [ ] **ART-442** [unwired] At-least-one invariant enforced in every
      app.
      Run ART-290 through ART-295 in each app.
      Expect: Same gray-out behavior; same load-time repair; same log
              line on malformed load.
      — last: —
