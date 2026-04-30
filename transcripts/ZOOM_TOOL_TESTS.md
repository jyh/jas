# Zoom Tool — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/zoom.yaml`. Design doc:
`transcripts/ZOOM_TOOL.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other
platforms covered in Session H parity sweep.

---

## Known broken

_Last reviewed: 2026-04-25_

- **Document-aware tools at zoom != 1** — Selection / Pen / Pencil /
  etc. receive screen-space mouse coordinates and pass them to
  `hit_test()` which expects document coordinates. At any non-
  identity view transform, those tools' hit-testing is offset by
  the inverse zoom + pan. Zoom and Hand themselves are unaffected
  because their math is screen-space throughout. Cross-cutting fix
  (event-coord conversion at the dispatch boundary or making
  `hit_test` view-aware) is out of Phase 1 scope.
- **OCaml — visible toolbar buttons for Hand / Zoom** — the GTK
  toolbar's hand-rolled Cairo icon drawing doesn't include
  Hand / Zoom buttons. Keyboard shortcuts (`H`, `Z`, `Cmd+0`, etc.)
  work; the visible buttons require ~50 lines of Cairo per icon
  and were deferred. Workaround: use the keyboard.
- **Idle-Alt cursor flip** — the Zoom cursor flips from `zoom-in`
  to `zoom-out` only during a drag (Rust + Swift); at idle the
  cursor stays `zoom-in` even when Alt is held. Per-app keyboard
  hooks needed to detect Alt independently of mouse events.
- **Clamp-state grayed cursors** — at `min_zoom` / `max_zoom`,
  the spec calls for grayed plus / minus glyphs. Phase 1 still
  shows the active glyph; clicks silently no-op at the boundary.
- **Flask** — tool not implemented. The Flask app has no canvas
  subsystem (per `[Flask Tspan deferred]` memory).

---

## Automation coverage

_Last synced: 2026-04-25_

**Effects (`doc.zoom.*`, `doc.pan.apply`)** — 12 unit tests per
language for the core arithmetic: `doc.zoom.set` (level + clamp),
`doc.zoom.set_full` (atomic write), `doc.zoom.apply` (cursor anchor
invariant + max_zoom clamp), `doc.pan.apply` (drag delta +
idempotency), `doc.zoom.fit_rect` (math + clamp + viewport-zero
no-op), `doc.zoom.fit_marquee` (below-threshold no-op),
`doc.zoom.fit_all_artboards` (union geometry). Files:
`jas_dioxus/src/interpreter/effects.rs` (#[cfg(test)] block,
12 tests), `JasSwift/Tests/Tools/YamlToolEffectsTests.swift`
(10 tests). OCaml + Python rely on the cross-language fixture
sweep when wired; no per-language unit tests yet for the doc.zoom.*
effects.

**Model centering (Rust + Swift)** —
`Model::center_view_on_current_artboard` has 3 unit tests in Rust
(`document::model::tests`): centers Letter in default viewport,
falls back to fit when too large, no-op with zero viewport. Swift /
OCaml / Python: equivalent code path is covered indirectly via the
`Model.__init__` / `TabState::with_model` smoke path; no direct
unit tests yet.

**Tool enum membership** — 26 enum cases asserted in each app's
tool-count tests (Rust `tools::tool::tests::tool_kind_variant_count`,
Swift `toolEnumVariantCount`, Python `test_tool_count`).

---

## Preconditions (assumed for every session)

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document (Letter artboard, 612 × 792 pt at
   origin).
3. Appearance: **Dark**.
4. Default tool active (Selection).
5. Default zoom level: 1.0; current artboard centered in the
   viewport.
6. Default `preferences.viewport.scrubby_zoom`: true.

---

## Tier definitions

- **P0 — existential.** Tool doesn't activate, click on canvas
  doesn't change zoom, fit-to-artboard does nothing, or the
  canvas re-renders blank after a zoom.
- **P1 — core.** Click / Alt-click / scrubby drag / marquee drag /
  wheel each behave per spec; the keyboard shortcuts dispatch the
  matching action; cursor anchor stays glued to its document point.
- **P2 — edge & polish.** Clamp at `min_zoom` / `max_zoom`,
  Escape-during-drag cancel, marquee minimum-size threshold,
  scrubby Alt-flip mid-drag, document-open centering when artboard
  doesn't fit, tab-switch preserves view state.

---

## Session table of contents

| Session | Topic                                  | Est.  | IDs        |
|---------|----------------------------------------|-------|------------|
| A       | Smoke & lifecycle                      | ~5m   | 001–019    |
| B       | Click + Alt-click step zoom            | ~6m   | 020–049    |
| C       | Scrubby drag zoom                      | ~8m   | 050–079    |
| D       | Marquee drag zoom                      | ~7m   | 080–109    |
| E       | Mouse wheel zoom                       | ~3m   | 110–129    |
| F       | Keyboard shortcuts                     | ~6m   | 130–159    |
| G       | Cursor states + dblclick-icon          | ~4m   | 160–189    |
| H       | Cross-app parity                       | ~12m  | 200–229    |

Full pass: ~51 min.

---

## Session A — Smoke & lifecycle (~5 min)

- [x] **ZOOM-001** [wired] **P0.** Zoom tool activates from the
      keyboard.
      Do: Press `Z`.
      Expect: Active tool changes to Zoom. Canvas cursor flips to
      a magnifier-style cursor (zoom-in / crosshair depending on
      platform).
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-002** [wired] **P0.** Zoom tool activates from the
      toolbar.
      Do: Long-press the navigation slot button (Hand by default),
      choose Zoom from the popup.
      Expect: Toolbar slot icon swaps to the magnifier; active
      tool is Zoom.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-003** [wired] **P0.** Document opens with current
      artboard centered in the viewport.
      Do: Open the app from a fresh launch (or `Cmd+N` for a new
      tab).
      Expect: The artboard rectangle is visually centered in the
      canvas pane; zoom level is 100% (the artboard fits without
      shrinking).
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-004** [wired] **P0.** Switching tabs preserves each
      tab's view state.
      Do: Open two tabs (`Cmd+N`). In tab 1, press `Cmd+=` a few
      times. Switch to tab 2; press `Cmd+0`. Switch back to tab 1.
      Expect: Tab 1 is still at the zoomed-in level it was before
      the switch; tab 2 is at the freshly fit level.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-005** [wired] **P1.** Closing and reopening the
      document resets view state to defaults.
      Do: Zoom in, save the document, close it (`Cmd+W`), reopen
      it.
      Expect: Zoom = 100%, current artboard centered. View state
      is not serialized (Phase 1).
      — last: 2026-04-30 (Rust). Fixed in c37ce03
        (ensure_artboards_invariant on open) + 39ceb5f (artboard
        round-trip via inkscape:page). Spec note "View state is
        not serialized (Phase 1)" stays accurate (zoom + pan
        defaults restored on reopen); artboards now ARE
        persisted via Inkscape's namedview convention.

---

## Session B — Click + Alt-click step zoom (~6 min)

- [x] **ZOOM-020** [wired] **P0.** Plain click zooms in by
      `zoom_step`.
      Do: With Zoom active, click anywhere on the canvas.
      Expect: Zoom level multiplies by 1.2 (default `zoom_step`).
      The document point under the cursor at click time stays
      under the cursor after the zoom.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-021** [wired] **P1.** Click anchor invariant.
      Do: At zoom 1.0, place a small rect at document (200, 150).
      Switch to Zoom. Click *exactly* on the rect.
      Expect: After the zoom, the rect is still under the cursor —
      it didn't drift relative to the cursor.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-022** [wired] **P0.** Alt-click zooms out by
      `1 / zoom_step`.
      Do: Press `Cmd+1` (zoom 1.0). Hold Alt and click.
      Expect: Zoom level becomes ~0.833 (1 / 1.2). Anchor
      invariant holds.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-023** [wired] **P2.** Multiple clicks compound.
      Do: Click 5 times.
      Expect: Zoom level becomes ~2.488 (1.2^5). Each step
      anchored at the *current* click coordinate, not the first.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-024** [wired] **P2.** Click at `max_zoom` is a silent
      no-op.
      Do: Click many times until the zoom hits the cap (default
      max 64.0). Click again.
      Expect: Nothing changes — no further zoom-in, no error
      flicker, no crash.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-025** [wired] **P2.** Alt-click at `min_zoom` is a
      silent no-op.
      Do: Alt-click many times until the zoom hits 0.1. Alt-click
      again.
      Expect: Nothing changes.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-026** [wired] **P2.** Click within the click-vs-drag
      threshold (≤4 px movement) is treated as a click.
      Do: Press, move 2 px, release.
      Expect: Step zoom (1.2× factor); no marquee, no scrubby.
      — last: 2026-04-30 (Rust)

---

## Session C — Scrubby drag zoom (~8 min)

Default state: `preferences.viewport.scrubby_zoom = true`.

- [x] **ZOOM-050** [wired] **P0.** Drag-right zooms in
      continuously.
      Do: Press, drag right ~150 px, hold.
      Expect: Zoom level increases smoothly during the drag (not
      step-by-step). The document point at mousedown stays glued
      to the press position throughout.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-051** [wired] **P0.** Drag-left zooms out
      continuously.
      Do: From zoom 2.0, press and drag left ~150 px.
      Expect: Zoom level decreases smoothly; press anchor stable.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-052** [wired] **P1.** 100 px drag right doubles the
      zoom factor (default gain 144).
      Do: Note current zoom. Press, drag right exactly 100 px,
      release.
      Expect: Final zoom ≈ initial × exp(100/144) ≈ initial × 2.0
      (within rendering precision).
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-053** [wired] **P1.** Vertical drag is ignored.
      Do: Press, drag straight down 100 px without horizontal
      movement.
      Expect: Zoom level unchanged.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-054** [wired] **P1.** Alt-held during drag flips
      direction.
      Do: Press, drag right 100 px while holding Alt.
      Expect: Zooms *out* (factor 0.5), not in.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-055** [wired] **P2.** Releasing Alt mid-drag flips
      direction back.
      Do: Press, drag right 50 px, hold Alt, drag another 50 px,
      release Alt, drag another 50 px.
      Expect: First 50 zooms in, middle 50 zooms back to near
      initial, last 50 zooms in again. Net: roughly factor 2.0
      from start.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-056** [wired] **P2.** Drag past `max_zoom` clamps;
      reversing direction unclamps immediately.
      Do: Press, drag right far enough to hit max (64.0). Continue
      dragging right.
      Expect: Zoom stays at 64.0. Now drag back left.
      Expect: Zoom drops below 64.0 immediately (hard clamp; no
      rubber-band).
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-057** [wired] **P2.** Escape during scrubby drag
      reverts to pre-drag zoom + pan.
      Do: Press, drag right 100 px, press Escape.
      Expect: Zoom and pan return to their pre-mousedown values.
      Drag does not commit.
      — last: 2026-04-30 (Rust)

---

## Session D — Marquee drag zoom (~7 min)

Setup: set `preferences.viewport.scrubby_zoom = false` (preferences
edit flow varies per platform; for now flip it directly in
workspace.json or the running preferences if exposed). All tests
in this session assume marquee mode.

- [x] **ZOOM-080** [wired] **P0.** Drag draws a marquee
      rectangle.
      Do: Press, drag to a different point.
      Expect: A thin dashed gray rectangle appears between press
      and current cursor, updating as the cursor moves.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-081** [wired] **P0.** Mouseup commits a fit-inside
      zoom.
      Do: Press at one corner of a small region of artwork, drag
      diagonally to its opposite corner, release.
      Expect: Zoom level increases so the marquee region fills the
      viewport (letterboxed if aspect ratio differs). The marquee
      content is centered in the viewport.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-082** [wired] **P1.** Marquee aspect-ratio resolves
      fit-inside (letterbox).
      Do: At zoom 1.0, draw a 200 × 50 marquee in a 800 × 600
      viewport (with 0 padding for marquee — exact fit).
      Expect: Final zoom = min(800/200, 600/50) = 4.0. The marquee
      width fits exactly; there's vertical slack.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-083** [wired] **P2.** Marquee below 10 px in either
      dimension is treated as a click.
      Do: Press, drag 5 px right and 50 px down, release.
      Expect: Step zoom by `zoom_step`, not a fit. (Cursor anchored
      at the click point.)
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-084** [wired] **P2.** Zero-area marquee (pure
      vertical or horizontal) is a click.
      Do: Press, drag 0 px right and 100 px down, release.
      Expect: Same as click — step zoom.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-085** [wired] **P2.** Marquee that would exceed
      `max_zoom` clamps zoom and centers on the marquee anyway.
      Do: Draw a 1 × 1 px marquee.
      Expect: Zoom clamps to 64.0; pan centers the marquee location
      in the viewport.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-086** [wired] **P2.** Escape mid-drag aborts.
      Do: Press, drag (overlay visible), press Escape.
      Expect: Overlay disappears; zoom + pan unchanged.
      — last: 2026-04-30 (Rust)

---

## Session E — Mouse wheel navigation (~4 min)

Spec change 2026-04-30: wheel modifiers are universal canvas
navigation, not Zoom-tool-specific. They work regardless of
active tool. Supersedes ZOOM-110 / 111 / 112 (graveyarded).

- [x] **ZOOM-113** [wired] **P0.** Plain wheel pans vertically.
      Do: From any tool, spin the wheel up or down on the canvas.
      Expect: Artboard scrolls vertically (down on wheel-up,
      up on wheel-down — content "scrolls" in the conventional
      direction).
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-114** [wired] **P0.** Ctrl+wheel pans vertically
      (same as plain wheel).
      Do: Hold Ctrl, spin wheel.
      Expect: Same as plain wheel — vertical pan. Ctrl is a
      no-op modifier here; included so users with muscle memory
      from other apps don't see surprising behavior.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-115** [wired] **P0.** Cmd+wheel pans horizontally.
      Do: Hold Cmd (Meta), spin wheel.
      Expect: Artboard scrolls horizontally (right on wheel-up,
      left on wheel-down).
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-116** [wired] **P0.** Alt+wheel up zooms in,
      anchored at cursor.
      Do: Hold Alt (Option), hover over a recognizable point,
      spin wheel up.
      Expect: Zoom in by `zoom_step` per notch. The document
      point under the cursor stays under the cursor after the
      zoom.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-117** [wired] **P1.** Alt+wheel down zooms out,
      anchored at cursor.
      Do: Hold Alt, spin wheel down.
      Expect: Zoom out by `1 / zoom_step` per notch. Anchor
      invariant holds.
      — last: 2026-04-30 (Rust)

---

## Session F — Keyboard shortcuts (~6 min)

These work regardless of which tool is active.

- [x] **ZOOM-130** [wired] **P0.** `Cmd+=` (or `Ctrl+=`) zooms in.
      Do: From Selection tool, press `Cmd+=`.
      Expect: Zoom level multiplies by 1.2, anchored at viewport
      center.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-131** [wired] **P0.** `Cmd+-` zooms out.
      Do: Press `Cmd+-`.
      Expect: Zoom level divides by 1.2, anchored at viewport
      center.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-132** [wired] **P0.** `Cmd+0` fits the active
      artboard.
      Do: Zoom in to ~3x, then press `Cmd+0`.
      Expect: Artboard fills the viewport with `fit_padding_px`
      breathing room (default 20px). Centered.
      — last: 2026-04-30 (Rust)

- [x] **ZOOM-133** [wired] **P1.** `Cmd+Alt+0` fits all artboards.
      Do: Add a second artboard (Shift+O activates Artboard, drag
      a new one, switch back to Selection). Press `Cmd+Alt+0`.
      Expect: Both artboards visible; the union of their
      bounding boxes fills the viewport with padding.
      — last: 2026-04-30 (Rust). Required ~5 fixes to land:
        Artboard tool registration (787aeef), Shift+O wiring
        (7328205), viewport→doc coords on artboard effects
        (97c6076), the dispatch_action param defaults
        (456f668), and the Cmd+Alt+0 macOS "º" key fix
        (12c239f).

- [ ] **ZOOM-134** [wired] **P0.** `Cmd+1` jumps to 100%.
      Do: Zoom in to 4x, then press `Cmd+1`.
      Expect: Zoom level = 1.0; pan unchanged (so whatever was
      under the viewport center stays approximately under it).
      — last: —

- [ ] **ZOOM-135** [wired] **P2.** Shortcuts work when text input
      doesn't have focus.
      Do: Click into a Layers panel rename field. Press `Cmd+0`.
      Expect: The shortcut still fires (Cmd is global); the
      rename's text wasn't replaced.
      — last: —

---

## Session G — Cursor states + dblclick-icon (~4 min)

- [ ] **ZOOM-160** [wired] **P1.** Idle cursor is the zoom-in
      magnifier (or platform crosshair).
      Do: Activate Zoom; hover canvas without pressing.
      Expect: Cursor is `zoom-in` style on Rust + Swift; on Python
      / OCaml, may fall back to crosshair (no native magnifier
      cursor).
      — last: —

- [ ] **ZOOM-161** [wired] **P2.** Cursor flips to zoom-out
      during Alt-held drag.
      Do: Press, drag right, hold Alt while dragging.
      Expect: Cursor flips to `zoom-out` (Rust + Swift). On other
      platforms cursor may stay the same.
      — last: —

- [ ] **ZOOM-162** [wired] **P2.** Marquee cursor.
      Do: With `scrubby_zoom = false`, press and drag past the
      4px threshold.
      Expect: Cursor switches to the marquee-draw style
      (crosshair) for the duration of the drag.
      — last: —

- [ ] **ZOOM-163** [wired] **P0.** Double-click on the Zoom
      toolbar icon zooms to 100%.
      Do: Long-press the navigation slot to expose Zoom; let it
      become the slot's visible icon. Double-click that icon.
      Expect: Zoom level jumps to 1.0 immediately. Same as
      `Cmd+1`.
      — last: —

---

## Session H — Cross-app parity (~12 min)

5–8 load-bearing tests run across all four native apps. Batch by
app — one full pass per app, not one pass per test.

- **ZOOM-200** [wired] Plain click on the canvas zooms in by
      `zoom_step` anchored at the cursor.
      Do: Activate Zoom (`Z`). Click on a non-empty region of
      the canvas.
      Expect: Zoom level increases by 1.2; the document point
      under the cursor at click time stays under the cursor.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **ZOOM-201** [wired] Alt-click zooms out.
      Do: Activate Zoom. Hold Alt and click.
      Expect: Zoom level divides by 1.2.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **ZOOM-202** [wired] Scrubby drag right zooms in continuously.
      Do: Drag right ~150 px with the Zoom tool; release.
      Expect: Zoom increases smoothly; press anchor stable.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **ZOOM-203** [wired] `Cmd+0` fits the active artboard.
      Do: Zoom in to a non-fit state, press `Cmd+0`.
      Expect: Artboard fills the viewport with padding; centered.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **ZOOM-204** [wired] `Cmd+1` jumps to 100%.
      Do: From any zoom level, press `Cmd+1`.
      Expect: Zoom = 1.0.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **ZOOM-205** [wired] Document elements re-render correctly at
      zoom != 1.
      Do: Draw a few rects with the Selection tool. Zoom in to
      ~3x with `Cmd+=`. Pan around with the Hand tool.
      Expect: Rects render at the zoomed scale; their stroke
      widths scale with zoom (no crisp-screen-pixel correction in
      Phase 1); panning moves them rigidly across the viewport.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **ZOOM-206** [wired] Zoom-icon double-click → 100%.
      Do: Make Zoom the visible navigation slot icon, double-click
      it.
      Expect: Same as `Cmd+1`.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

---

## Graveyard

- **ZOOM-110** [retired: spec changed 2026-04-30 — wheel modifiers
      reworked into universal canvas-navigation gestures (see ZOOM-113
      through ZOOM-117). Original spec called for Ctrl/Cmd+wheel = zoom
      with cursor anchor. New spec moves zoom to Alt+wheel and gives
      Ctrl/Cmd to pan.]

- **ZOOM-111** [retired: spec changed 2026-04-30 — superseded by
      ZOOM-117 (Alt+wheel down = zoom out).]

- **ZOOM-112** [retired: spec changed 2026-04-30 — plain wheel is no
      longer a no-op; it pans vertically (ZOOM-113).]

---

## Enhancements

_(Empty — no enhancement candidates raised yet.)_
