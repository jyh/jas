# Rotate Tool — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/rotate.yaml` and `workspace/dialogs/rotate_options.yaml`.
Design doc: `transcripts/ROTATE_TOOL.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other
platforms covered in Session F parity sweep.

---

## Known broken

_Last reviewed: 2026-04-25_

- None at the time of writing.

---

## Automation coverage

_Last synced: 2026-04-25_

Shares `algorithms/transform_apply` coverage with Scale and
Shear (see `SCALE_TOOL_TESTS.md` Automation coverage). Rotation-
specific assertions in those unit tests: 0° identity, 90° around
origin maps (1, 0) → (0, 1), 180° around (50, 50) preserves the
reference and mirrors offsets.

`doc.rotate.apply` exercised via lib-test paths. No isolated
effect-level integration tests yet.

---

## Preconditions (assumed for every session)

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document with one or more selectable
   elements (default fixture: a 100×80 red rect at (200, 200)).
3. Appearance: **Dark**.
4. Selection tool active; the test rect is selected.

---

## Tier definitions

- **P0 — existential.** Tool doesn't activate, drag doesn't
  rotate, dialog crashes.
- **P1 — core.** Drag rotates around the reference point; click
  sets a custom reference; dialog Angle field rotates by the
  typed degrees on OK; Cancel reverts.
- **P2 — edge & polish.** Shift snaps to 45° ticks, sign of
  rotation, Alt-click opens the dialog and seeds the reference,
  Escape mid-drag, Copy duplicates, multi-element rotation
  around the union bounds center.

---

## Session table of contents

| Session | Topic                                       | Est.  | IDs        |
|---------|---------------------------------------------|-------|------------|
| A       | Smoke & lifecycle                           | ~5m   | 001–009    |
| B       | Drag gesture (interactive rotation)         | ~6m   | 010–029    |
| C       | Reference point (plain click + Alt-click)   | ~4m   | 040–059    |
| D       | Rotate Options dialog                       | ~6m   | 060–089    |
| E       | Live Preview + Copy + Reset                 | ~6m   | 090–119    |
| F       | Cross-app parity                            | ~8m   | 200–229    |

Full pass: ~35 min.

---

## Session A — Smoke & lifecycle (~5 min)

- [ ] **ROT-001** [wired] **P0.** Rotate Tool activates via
      keyboard.
      Do: Press `R`.
      Expect: Rotate Tool active; toolbar Rotate icon (270° arc
      with arrowhead) is highlighted; cursor is the crosshair.
      — last: —

- [ ] **ROT-002** [wired] **P0.** Rotate Tool activates via
      toolbar click.
      Do: Click the Rotate icon in row 4 col 1 of the toolbar.
      Expect: Rotate active; no long-press indicator (Rotate
      has its own slot — no alternates).
      — last: —

- [ ] **ROT-003** [wired] **P1.** Reference-point cross renders
      for the selection.
      Do: With a selection visible, switch to Rotate.
      Expect: 12 px cyan-blue (#4A9EFF) crosshair + 2 px center
      dot at the selection's bounding-box center.
      — last: —

- [ ] **ROT-004** [wired] **P1.** Cross hides when selection
      cleared.
      Do: Clear the selection.
      Expect: Cross overlay no longer drawn.
      — last: —

---

## Session B — Drag gesture (~6 min)

- [ ] **ROT-010** [wired] **P0.** Drag rotates the selection
      around the reference point.
      Do: With Rotate active, click-drag from one position to
      another that traces a noticeable arc around the cross.
      Expect: bbox-ghost (dashed parallelogram) tracks the
      post-rotation outline live; on release, the rect is
      committed at the new orientation.
      — last: —

- [ ] **ROT-011** [wired] **P1.** Press point anchors — does not
      relocate the reference.
      Do: Note the cross position; click-drag from a point that
      is not at the cross.
      Expect: Cross stays put; rotation is around the cross,
      not around the press point.
      — last: —

- [ ] **ROT-012** [wired] **P1.** Shift snaps to 45° ticks.
      Do: Hold Shift and slowly drag in a circle.
      Expect: Ghost angle snaps to 0°, 45°, 90°, …; release at
      a snap angle commits exactly that.
      — last: —

- [ ] **ROT-013** [wired] **P1.** Counter-clockwise vs
      clockwise drag direction.
      Do: Drag from a point to another, then back through the
      starting angle.
      Expect: The committed orientation is determined by the
      net cursor angle change, not the path. Crossing back to
      0° commits 0°.
      — last: —

- [ ] **ROT-014** [wired] **P2.** Escape during drag cancels.
      Do: Start a drag, press Escape before releasing.
      Expect: Ghost vanishes, document unchanged.
      — last: —

- [ ] **ROT-015** [wired] **P2.** Multi-element rotation around
      the union bounds center.
      Do: Select two elements; switch to Rotate; drag.
      Expect: Cross at union bbox center; both elements rotate
      together about the same pivot.
      — last: —

---

## Session C — Reference point (~4 min)

- [ ] **ROT-040** [wired] **P0.** Plain click sets a custom
      reference.
      Do: Click (no drag) at an empty canvas coordinate.
      Expect: Cross moves to click coordinate; selection
      unchanged.
      — last: —

- [ ] **ROT-041** [wired] **P1.** Subsequent drag pivots around
      the new reference.
      Do: After ROT-040, drag.
      Expect: Rotation is around the custom point, not the
      bounds center.
      — last: —

- [ ] **ROT-042** [wired] **P2.** Selection change resets the
      reference.
      Do: Set custom reference; change the selection (e.g., via
      Selection tool); switch back to Rotate.
      Expect: Cross is at the new selection's bounds center.
      — last: —

- [ ] **ROT-043** [wired] **P2.** Reference shared with Scale
      and Shear.
      Do: Set custom reference under Rotate; switch to Scale.
      Expect: Cross stays at the same custom point.
      — last: —

---

## Session D — Rotate Options dialog (~6 min)

- [ ] **ROT-060** [wired] **P0.** Dblclick on Rotate icon opens
      the dialog.
      Do: Double-click the Rotate icon.
      Expect: Modal dialog "Rotate" with Angle field focused.
      — last: —

- [ ] **ROT-061** [wired] **P1.** Alt-click opens the dialog
      and seeds the reference.
      Do: Alt-click on canvas.
      Expect: Cross moves to the click coordinate; dialog
      opens.
      — last: —

- [ ] **ROT-062** [wired] **P0.** OK with positive angle
      rotates CCW.
      Do: Open dialog; enter 90; OK.
      Expect: Selection rotates 90° counter-clockwise around
      the current reference.
      — last: —

- [ ] **ROT-063** [wired] **P1.** Negative angle rotates CW.
      Do: Open dialog; enter -45; OK.
      Expect: 45° clockwise rotation.
      — last: —

- [ ] **ROT-064** [wired] **P1.** Cancel discards changes.
      Do: Open dialog; enter 90; click Cancel.
      Expect: Document unchanged.
      — last: —

- [ ] **ROT-065** [wired] **P2.** Reopening shows last-entered
      angle (state.rotate_angle).
      Do: Apply 90° via OK. Reopen the dialog.
      Expect: Angle field shows 90 (not the default 0).
      — last: —

---

## Session E — Live Preview + Copy + Reset (~6 min)

- [ ] **ROT-090** [wired] **P0.** Typing the angle previews
      live.
      Do: Open dialog; type into Angle (e.g. 30, 60, 90).
      Expect: Canvas re-renders at the typed angle in real
      time without closing the dialog.
      — last: —

- [ ] **ROT-091** [wired] **P1.** Cancel reverts the preview.
      Do: After live preview, click Cancel.
      Expect: Document returns to pre-dialog orientation.
      — last: —

- [ ] **ROT-092** [wired] **P1.** OK keeps the previewed
      result.
      Do: After live preview at 60°, click OK.
      Expect: Final orientation = 60°; one undo entry pushed.
      — last: —

- [ ] **ROT-093** [wired] **P1.** Copy duplicates rotated.
      Do: Dialog 90°; Copy.
      Expect: Duplicate at 90° appears; original unchanged;
      selection moves to the duplicate.
      — last: —

- [ ] **ROT-094** [wired] **P2.** Reset returns Angle to 0
      without committing.
      Do: Open dialog; type 90; click Reset.
      Expect: Angle = 0 in the field; dialog stays open.
      — last: —

- [ ] **ROT-095** [wired] **P2.** Multiple preview rounds don't
      compound.
      Do: Type 90 → -90 → 45 → OK.
      Expect: Final orientation is 45° from the original (not
      the cumulative sum).
      — last: —

---

## Session F — Cross-app parity (~8 min)

- **ROT-200** [wired] Drag rotation around bounds center.
      Do: Select a rect; press R; drag from one side around the
      center to roughly 90°; release.
      Expect: Rect rotated ≈ 90° about the bounds center.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **ROT-201** [wired] Shift snaps to 45° ticks.
      Do: Press R; drag with Shift held.
      Expect: Final rotation is exactly 0°, 45°, 90°, etc.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **ROT-202** [wired] Click sets a custom reference; drag
      pivots around it.
      Do: Press R; click empty canvas at (50, 50); drag from
      far away.
      Expect: Cross at (50, 50); rotation pivots around (50, 50).
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **ROT-203** [wired] Dialog OK applies; Cancel reverts.
      Do: Dblclick Rotate icon; enter 90; OK. Repeat with
      Cancel.
      Expect: OK rotates 90°; Cancel leaves it unchanged.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **ROT-204** [wired] Live Preview during dialog typing.
      Do: Dblclick Rotate icon; type 60 in Angle.
      Expect: Canvas rotates live to 60°.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **ROT-205** [wired] Copy duplicates rotated.
      Do: Dialog 90°; Copy.
      Expect: Duplicate appears rotated; original unchanged.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

---

## Graveyard

_(Empty.)_

---

## Enhancements

_(Empty.)_
