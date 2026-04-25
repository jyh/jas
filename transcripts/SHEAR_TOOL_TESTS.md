# Shear Tool — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/shear.yaml` and `workspace/dialogs/shear_options.yaml`.
Design doc: `transcripts/SHEAR_TOOL.md`.

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
Rotate (see `SCALE_TOOL_TESTS.md` Automation coverage). Shear-
specific assertions in those unit tests: 0° identity,
horizontal 45° at origin maps (0, 10) → (10, 10), vertical 45°
maps (10, 0) → (10, 10), custom-axis at axis_angle = 0
matches horizontal, unknown axis returns identity.

`doc.shear.apply` exercised via lib-test paths. No isolated
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
  produce a slant, dialog crashes.
- **P1 — core.** Drag perpendicular to the press → reference
  axis shears the selection along that axis; dialog applies the
  typed angle along the chosen axis on OK; Cancel reverts;
  Horizontal / Vertical / Custom axis radios work.
- **P2 — edge & polish.** Shift constrains the axis to
  horizontal / vertical, Alt-click opens the dialog and seeds
  the reference, Escape mid-drag, Copy duplicates, multi-
  element shear around the union bounds center, Custom Angle
  field disables when Custom radio is not selected.

---

## Session table of contents

| Session | Topic                                       | Est.  | IDs        |
|---------|---------------------------------------------|-------|------------|
| A       | Smoke & lifecycle                           | ~5m   | 001–009    |
| B       | Drag gesture (interactive shear)            | ~7m   | 010–029    |
| C       | Reference point (plain click + Alt-click)   | ~4m   | 040–059    |
| D       | Shear Options dialog (Angle + Axis)         | ~7m   | 060–089    |
| E       | Live Preview + Copy + Reset                 | ~5m   | 090–119    |
| F       | Cross-app parity                            | ~8m   | 200–229    |

Full pass: ~36 min.

---

## Session A — Smoke & lifecycle (~5 min)

- [ ] **SHR-001** [wired] **P0.** Shear Tool activates from
      the Scale slot's long-press.
      Do: Long-press the Scale toolbar icon; select Shear from
      the flyout / menu.
      Expect: Shear Tool active; the slot icon swaps to the
      parallelogram glyph.
      — last: —

- [ ] **SHR-002** [wired] **P0.** Shear has no default
      keyboard shortcut.
      Do: Press `S` with the Selection tool active.
      Expect: Scale activates (not Shear). Shear remains
      reachable only via long-press of the Scale slot.
      — last: —

- [ ] **SHR-003** [wired] **P1.** Reference-point cross renders
      for the selection.
      Do: With a selection, switch to Shear.
      Expect: 12 px cyan-blue (#4A9EFF) crosshair + 2 px center
      dot at the selection's bounds center.
      — last: —

- [ ] **SHR-004** [wired] **P1.** Cross hides when selection
      cleared.
      Do: Clear the selection.
      Expect: Cross overlay disappears.
      — last: —

---

## Session B — Drag gesture (~7 min)

- [ ] **SHR-010** [wired] **P0.** Drag perpendicular to the
      ref → press axis shears.
      Do: With Shear active, click-drag from a point near the
      selection. Move the cursor in a direction perpendicular
      to the line from the cross to the press point.
      Expect: bbox-ghost (dashed parallelogram) tracks the
      sheared outline; on release, the rect is committed as a
      sheared parallelogram.
      — last: —

- [ ] **SHR-011** [wired] **P1.** Press point anchors — does
      not relocate the reference.
      Do: Note cross position; drag from a non-cross press
      point.
      Expect: Cross stays put; the ghost shears around the
      cross.
      — last: —

- [ ] **SHR-012** [wired] **P1.** Shift constrains the axis to
      horizontal.
      Do: Hold Shift; drag predominantly horizontally.
      Expect: Ghost shears only along the document's x-axis;
      committed result is a horizontally-sheared parallelogram
      with vertical sides preserved.
      — last: —

- [ ] **SHR-013** [wired] **P1.** Shift constrains the axis to
      vertical.
      Do: Hold Shift; drag predominantly vertically.
      Expect: Vertical shear; horizontal sides preserved.
      — last: —

- [ ] **SHR-014** [wired] **P2.** Custom-axis shear (no Shift)
      slants along the press → ref vector.
      Do: Click somewhere off the axis you want; release;
      then drag from a different press point so the ref → press
      vector is at, say, 30° from horizontal.
      Expect: Ghost slants in a direction perpendicular to that
      30° axis.
      — last: —

- [ ] **SHR-015** [wired] **P2.** Escape during drag cancels.
      Do: Start a drag, press Escape before release.
      Expect: Ghost vanishes; document unchanged.
      — last: —

- [ ] **SHR-016** [wired] **P2.** Multi-element shear around
      union bounds center.
      Do: Select two elements; switch to Shear; drag.
      Expect: Both elements shear together about the same
      reference.
      — last: —

---

## Session C — Reference point (~4 min)

- [ ] **SHR-040** [wired] **P0.** Plain click sets a custom
      reference.
      Do: Click (no drag) at an empty canvas coordinate.
      Expect: Cross moves to click coordinate; selection
      unchanged.
      — last: —

- [ ] **SHR-041** [wired] **P1.** Subsequent drag pivots around
      the new reference.
      Do: After SHR-040, drag.
      Expect: Shear is around the custom point.
      — last: —

- [ ] **SHR-042** [wired] **P2.** Selection change resets the
      reference.
      Do: Set custom ref; change selection; switch back to
      Shear.
      Expect: Cross at the new selection's bounds center.
      — last: —

- [ ] **SHR-043** [wired] **P2.** Reference shared with Scale
      and Rotate.
      Do: Set custom ref under Shear; switch to Rotate.
      Expect: Cross stays at the same custom point.
      — last: —

---

## Session D — Shear Options dialog (~7 min)

- [ ] **SHR-060** [wired] **P0.** Dblclick on Shear icon opens
      the dialog.
      Do: Double-click the Shear icon (long-press the Scale
      slot first if Scale is the visible slot tool).
      Expect: Modal dialog "Shear" with Shear Angle field
      focused.
      — last: —

- [ ] **SHR-061** [wired] **P1.** Alt-click opens the dialog
      and seeds the reference.
      Do: Alt-click on canvas while Shear is active.
      Expect: Cross moves; dialog opens.
      — last: —

- [ ] **SHR-062** [wired] **P0.** OK with horizontal axis +
      30° applies.
      Do: Open dialog; enter 30 in Shear Angle; ensure
      Horizontal radio selected; OK.
      Expect: Selection sheared 30° horizontally around the
      reference.
      — last: —

- [ ] **SHR-063** [wired] **P1.** Vertical axis radio.
      Do: Open dialog; enter 30; choose Vertical; OK.
      Expect: Vertical shear (top/bottom edges shift relative
      to each other on the y-axis).
      — last: —

- [ ] **SHR-064** [wired] **P1.** Custom axis with axis_angle
      = 45°.
      Do: Open dialog; enter 30; choose Custom; enter 45° in
      the axis-angle field; OK.
      Expect: Shear along a 45°-rotated axis (diagonal slant).
      — last: —

- [ ] **SHR-065** [wired] **P2.** Custom axis_angle field
      disables when Horizontal or Vertical is selected.
      Do: Switch radio between Horizontal / Vertical / Custom.
      Expect: The axis_angle input is enabled only under
      Custom; greyed out otherwise.
      — last: —

- [ ] **SHR-066** [wired] **P1.** Cancel discards changes.
      Do: Open dialog; enter 30; Cancel.
      Expect: Document unchanged.
      — last: —

- [ ] **SHR-067** [wired] **P2.** Reopening preserves last
      values (state.shear_*).
      Do: Apply 30° horizontal via OK. Reopen the dialog.
      Expect: Angle 30, axis Horizontal pre-filled.
      — last: —

---

## Session E — Live Preview + Copy + Reset (~5 min)

- [ ] **SHR-090** [wired] **P0.** Typing previews live.
      Do: Open dialog; type 10, 20, 30 into Shear Angle.
      Expect: Canvas re-renders the shear live as values change.
      — last: —

- [ ] **SHR-091** [wired] **P1.** Cancel reverts the preview.
      Do: After preview, Cancel.
      Expect: Document returns to pre-dialog state.
      — last: —

- [ ] **SHR-092** [wired] **P1.** OK keeps the previewed
      result.
      Do: After preview at 30°, OK.
      Expect: Final shear committed at 30°.
      — last: —

- [ ] **SHR-093** [wired] **P1.** Copy duplicates sheared.
      Do: Dialog 30° horizontal; Copy.
      Expect: Duplicate sheared; original unchanged.
      — last: —

- [ ] **SHR-094** [wired] **P2.** Reset returns to defaults
      without committing.
      Do: Open dialog; type 30, choose Vertical; click Reset.
      Expect: Angle 0, axis Horizontal, custom angle 0; dialog
      stays open.
      — last: —

- [ ] **SHR-095** [wired] **P2.** Switching axis radios mid-
      preview re-renders the canvas.
      Do: With Preview on, type 30; switch from Horizontal to
      Vertical.
      Expect: Canvas re-renders with vertical shear (preview
      not stuck on the prior axis).
      — last: —

---

## Session F — Cross-app parity (~8 min)

- **SHR-200** [wired] Drag horizontal shear around bounds
      center.
      Do: Select a rect; long-press Scale slot → Shear; drag
      with Shift held horizontally.
      Expect: Horizontal shear; rect becomes a parallelogram
      with horizontal top/bottom edges.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **SHR-201** [wired] Drag vertical shear (Shift constraint).
      Do: Press Shear; drag with Shift held vertically.
      Expect: Vertical shear; rect's left/right edges remain
      vertical, top/bottom slant.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **SHR-202** [wired] Dialog horizontal 30° apply.
      Do: Dblclick Shear icon; enter 30; choose Horizontal; OK.
      Expect: Selection sheared 30° horizontally about the
      bounds center.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **SHR-203** [wired] Dialog Cancel reverts.
      Do: Dblclick Shear icon; enter 30; Cancel.
      Expect: Document unchanged.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **SHR-204** [wired] Live Preview during dialog typing.
      Do: Dblclick Shear icon; type 20.
      Expect: Canvas re-renders live at 20° shear.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **SHR-205** [wired] Copy duplicates sheared.
      Do: Dialog 30°; Copy.
      Expect: Duplicate appears sheared; original unchanged.
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
