# Hand Tool — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/hand.yaml`. Design doc:
`transcripts/HAND_TOOL.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other
platforms covered in Session E parity sweep.

---

## Known broken

_Last reviewed: 2026-04-25_

- **Document-aware tools at zoom != 1 / pan != 0** — Selection /
  Pen / Pencil / etc. receive screen-space mouse coordinates
  while their `hit_test()` expects document coordinates. Not a
  Hand-tool bug per se, but visible after using Hand to pan: the
  document tools' click targets shift relative to where elements
  appear. Cross-cutting fix is out of Phase 1 scope.
- **OCaml — visible toolbar buttons for Hand / Zoom** — keyboard
  shortcuts (`H`, Space pass-through) work; the GTK toolbar
  doesn't yet draw the Hand icon. Cairo-drawing work deferred.
- **Closed-hand cursor flip** — Rust + Swift flip Hand's cursor
  from `OpenHandCursor` to `closedHand` during a drag. OCaml +
  Python keep the open-hand cursor throughout (no tool-state
  lookup wired into the cursor resolver).
- **Flask** — tool not implemented. The Flask app has no canvas
  subsystem.

---

## Automation coverage

_Last synced: 2026-04-25_

**Effects (`doc.pan.apply`, `doc.zoom.set_full`)** — covered by
the Zoom tool's auto-test suite (see ZOOM_TOOL_TESTS.md). Hand-
specific: `doc.pan.apply` translates by the cursor-press delta and
is idempotent (recomputes from press + initial each call).

**Model centering (`Model::center_view_on_current_artboard`)** —
3 unit tests in Rust covering the fits / fits-fallback / zero-
viewport cases. Swift / OCaml / Python: covered indirectly via
Model construction smoke.

**Tool enum membership** — `Tool.HAND` asserted in each app's
tool-count tests.

---

## Preconditions (assumed for every session)

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document with a single Letter artboard.
3. Appearance: **Dark**.
4. Default tool active (Selection).
5. View state: zoom 1.0, current artboard centered.
6. Place a few content rects so pan effects are visible.

---

## Tier definitions

- **P0 — existential.** Tool doesn't activate, drag does nothing
  visible, or Space pass-through hangs the app.
- **P1 — core.** Drag-to-pan tracks the cursor; Spacebar
  pass-through saves and restores; the dblclick-icon shortcut
  fires `fit_active_artboard`.
- **P2 — edge & polish.** Cursor open / closed flip during drag,
  Escape mid-drag cancel, text-input suppression of Space
  pass-through, app-focus-loss restore.

---

## Session table of contents

| Session | Topic                                | Est.  | IDs        |
|---------|--------------------------------------|-------|------------|
| A       | Smoke & lifecycle                    | ~4m   | 001–019    |
| B       | Drag-to-pan                          | ~5m   | 020–049    |
| C       | Spacebar pass-through                | ~6m   | 050–079    |
| D       | Cursor states + dblclick-icon        | ~3m   | 080–099    |
| E       | Cross-app parity                     | ~10m  | 200–229    |

Full pass: ~28 min.

---

## Session A — Smoke & lifecycle (~4 min)

- [x] **HAND-001** [wired] **P0.** Hand tool activates from the
      keyboard.
      Do: Press `H`.
      Expect: Active tool changes to Hand. Canvas cursor flips
      to `OpenHandCursor` (Rust / Swift / Python) or
      platform-default if cursor wiring is partial.
      — last: 2026-04-30 (Rust)

- [x] **HAND-002** [wired] **P0.** Hand tool activates from the
      toolbar.
      Do: Click the navigation slot (default visible: Hand) in
      the toolbar.
      Expect: Hand becomes active.
      — last: 2026-04-30 (Rust)

- [x] **HAND-003** [wired] **P1.** Activating Hand does not
      modify document content.
      Do: Place a rect with Selection. Activate Hand.
      Expect: The rect is unchanged; selection unchanged; no
      undo entry pushed.
      — last: 2026-04-30 (Rust)

- [x] **HAND-004** [wired] **P2.** Switching back from Hand to
      Selection preserves the selection.
      Do: Activate Selection, draw a rect, leave it selected.
      Switch to Hand. Switch back to Selection.
      Expect: The rect is still selected.
      — last: 2026-04-30 (Rust)

---

## Session B — Drag-to-pan (~5 min)

- [x] **HAND-020** [wired] **P0.** Drag pans the canvas.
      Do: Activate Hand. Press at any canvas coordinate, drag
      down-right ~100 px, release.
      Expect: The document content shifts down-right by 100 px on
      screen. The artboard rectangle moves with the content.
      — last: 2026-04-30 (Rust)

- [x] **HAND-021** [wired] **P0.** Drag-to-pan keeps the
      mousedown point under the cursor.
      Do: Press exactly on a recognizable element. Drag without
      letting up.
      Expect: That element stays glued to the cursor for the
      entire drag (no slip, no acceleration).
      — last: 2026-04-30 (Rust)

- [x] **HAND-022** [wired] **P1.** Plain click without drag is a
      no-op.
      Do: Click without moving the mouse (≤ 4 px).
      Expect: View doesn't change. No selection change either.
      — last: 2026-04-30 (Rust)

- [x] **HAND-023** [wired] **P1.** Pan is unbounded.
      Do: Drag the canvas far past the artboard edge.
      Expect: View continues panning; no clamp at the edge. The
      artboard scrolls off-screen freely.
      — last: 2026-04-30 (Rust)

- [ ] **HAND-024** [wired] **P2.** Mouseup outside the canvas
      pane still commits.
      Do: Press inside the canvas, drag with the mouse leaving
      the canvas pane (over the toolbar or the dock), release.
      Expect: The drag is captured; final pan reflects total
      drag delta even though release was outside the canvas.
      — last: — · regression: Rust 2026-04-30 — canvas's onmouseup
        listener doesn't see release events outside its bounds, so
        the pan never commits and the next mouse re-entry continues
        the drag without a button held. Fix is to migrate to
        pointer events + setPointerCapture on mousedown (or attach
        a document-level mouseup fallback). Out of Tier-0 scope.

- [x] **HAND-025** [wired] **P2.** Escape during drag aborts.
      Do: Press, drag, press Escape.
      Expect: Pan reverts to the pre-drag offsets. (Note: in some
      apps Escape may also propagate to mask-isolation exit; the
      drag-revert path is checked separately.)
      — last: 2026-04-30 (Rust)

---

## Session C — Spacebar pass-through (~6 min)

- [x] **HAND-050** [wired] **P0.** Holding Space switches the
      active tool to Hand.
      Do: Activate Selection. Press and hold Space.
      Expect: Cursor flips to `OpenHandCursor`. The toolbar
      shows Hand as active (slot icon highlights).
      — last: 2026-04-30 (Rust)

- [x] **HAND-051** [wired] **P0.** Releasing Space restores the
      prior tool.
      Do: With Selection active, press and hold Space, then
      release.
      Expect: Cursor and toolbar return to the Selection state.
      — last: 2026-04-30 (Rust)

- [x] **HAND-052** [wired] **P1.** Drag during Space-held pan
      pans the canvas.
      Do: Activate Selection. Hold Space, press and drag, then
      release the mouse, then release Space.
      Expect: Canvas pans during the drag. After Space release,
      Selection is restored.
      — last: 2026-04-30 (Rust)

- [x] **HAND-053** [wired] **P1.** Pressing Space when Hand is
      already active is a no-op (no double save).
      Do: Activate Hand directly (`H`). Press and hold Space, then
      release.
      Expect: Active tool stays Hand throughout. No extra
      save / restore cycle.
      — last: 2026-04-30 (Rust)

- [x] **HAND-054** [wired] **P0.** Space pass-through is
      suppressed when a text input has focus.
      Do: Click into a Layers panel rename or any text field.
      Press and hold Space.
      Expect: A literal space character is typed into the
      field. The active tool does not change.
      — last: 2026-04-30 (Rust)

- [x] **HAND-055** [wired] **P2.** App focus loss while Space is
      held restores the prior tool.
      Do: Activate Selection. Hold Space. Cmd+Tab away to another
      app. Cmd+Tab back.
      Expect: When focus returns, Selection is the active tool
      (not Hand). Or — depending on platform — Space release on
      return restores cleanly. No stuck-in-Hand state.
      — last: 2026-04-30 (Rust)

- [x] **HAND-056** [wired] **P2.** Pressing other tool letters
      during a Space-held pass-through is ignored.
      Do: Activate Selection. Hold Space (now in Hand). Press `Z`.
      Release Space.
      Expect: After Space release, Selection is restored — not
      Zoom.
      — last: 2026-04-30 (Rust)

---

## Session D — Cursor states + dblclick-icon (~3 min)

- [x] **HAND-080** [wired] **P1.** Idle cursor is the open hand.
      Do: Activate Hand; hover canvas without pressing.
      Expect: Cursor is `OpenHandCursor` (Rust / Swift / Python).
      — last: 2026-04-30 (Rust)

- [x] **HAND-081** [wired] **P2.** Cursor flips to closed hand
      during drag.
      Do: Press and hold the mouse button on the canvas.
      Expect: Cursor flips to `closedHand` for the duration of
      the press (Rust + Swift). On Python the cursor stays
      open-hand (deferred).
      — last: 2026-04-30 (Rust)

- [ ] **HAND-082** [wired] **P0.** Double-click on the Hand
      toolbar icon fits the active artboard.
      Do: With Hand visible as the navigation slot icon,
      double-click it.
      Expect: Zoom + pan jumps to fit_active_artboard — same
      as `Cmd+0`.
      — last: — · regression: Rust 2026-04-30 — `Cmd+0`
        works (action dispatch fixed in this branch); the
        toolbar slot's dblclick path is dead. Earlier diagnosis
        of "Dioxus dblclick quirk" was wrong: the actual
        rendered toolbar comes from YamlToolbarContent →
        render_element → layout.yaml's btn_hand_slot, which has
        only `mouse_down` / `mouse_up` / `click` event handlers
        and no `dblclick`. The yaml comment notes "Double-click
        is dispatched by each app's toolbar dispatcher reading
        the active tool's tool_options_action field" but no
        such dispatcher exists in the yaml-rendered path. The
        ToolbarGrid component in toolbar_grid.rs implements
        this convention but isn't currently mounted. Same root
        cause as ZOOM-163. Out of Tier-0 scope.

---

## Session E — Cross-app parity (~10 min)

5–8 load-bearing tests run across all four native apps. Batch by
app — one full pass per app, not one pass per test.

- **HAND-200** [wired] Drag pans the canvas with mousedown-anchor
      semantics.
      Do: Activate Hand (`H`). Press on a recognizable element,
      drag, release.
      Expect: Element stays glued to cursor throughout; final
      pan reflects total drag delta.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **HAND-201** [wired] Spacebar held during another tool
      switches to Hand and restores on release.
      Do: Selection active. Press Space, drag, release the mouse,
      release Space.
      Expect: Hand pan happens during the drag; Selection is
      active after release.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **HAND-202** [wired] Spacebar pass-through is suppressed when
      a text input has focus.
      Do: Focus a Layers panel rename or similar text field. Press
      Space.
      Expect: Space inserts a character in the field; tool does
      not change.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **HAND-203** [wired] `H` activates Hand from any tool.
      Do: From Selection, press `H`.
      Expect: Active tool is Hand.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **HAND-204** [wired] Pan is unbounded.
      Do: Drag the canvas far past the artboard edge.
      Expect: View keeps panning; no clamp.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **HAND-205** [wired] Hand-icon double-click fits the active
      artboard.
      Do: Double-click the Hand button on the toolbar.
      Expect: Same result as `Cmd+0`.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —  (toolbar button deferred)
      - [ ] Python     last: —

---

## Graveyard

_(Empty — no retired tests yet.)_

---

## Enhancements

_(Empty — no enhancement candidates raised yet.)_
