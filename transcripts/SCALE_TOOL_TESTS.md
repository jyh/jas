# Scale Tool — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/scale.yaml` and `workspace/dialogs/scale_options.yaml`.
Design doc: `transcripts/SCALE_TOOL.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other
platforms covered in Session H parity sweep.

---

## Known broken

_Last reviewed: 2026-04-25_

- None at the time of writing.

---

## Automation coverage

_Last synced: 2026-04-25_

**Algorithm (`algorithms/transform_apply`)** — 19 unit tests per
language on `scale_matrix` / `rotate_matrix` / `shear_matrix` /
`stroke_width_factor`: identity at unit factors, around-point
invariance, sign preservation for flips, axis-frame consistency
for custom shear, matrix-multiply associativity. Files:
`jas_dioxus/src/algorithms/transform_apply.rs` (#[cfg(test)]),
`JasSwift/Tests/Algorithms/TransformApplyTests.swift`. Python +
OCaml share the same primitive set; spot-checked at the REPL but
no dedicated test files yet.

**Effect (`doc.scale.apply`)** — exercised through the full
gesture-handler test paths in each language's lib tests (Rust:
1679 lib tests pass; Swift: 1529 pass; OCaml: dune build clean;
Python: 737 pass). No isolated effect-level integration tests
yet — the manual suite below complements.

**On_change hook** — exercised indirectly: each runtime's
`take_dialog_dirty` + `is_firing_on_change` accessors land in
the existing StateStore tests, but the full open → mutate →
fire → close lifecycle is not covered by automation.

---

## Preconditions (assumed for every session)

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document with one or more selectable
   elements (default fixture: a single 100×80 red rect at
   (200, 200)).
3. Appearance: **Dark**.
4. Selection tool active; the test rect is selected (blue
   bounding box visible).

---

## Tier definitions

- **P0 — existential.** Tool doesn't activate, drag doesn't
  produce any visible change, dialog crashes, or document
  becomes unrecoverably corrupt.
- **P1 — core.** Plain-click sets the reference point; drag
  scales the selection around that point; the dialog OK applies;
  Cancel reverts; live Preview shows typing-time updates.
- **P2 — edge & polish.** Shift uniform-aspect, sign flips
  through the reference point, Scale Strokes / Scale Corners,
  Copy duplicates, Alt-click opens the dialog and seeds the
  reference point, Escape cancels mid-drag, no-selection no-op.

---

## Session table of contents

| Session | Topic                                       | Est.  | IDs        |
|---------|---------------------------------------------|-------|------------|
| A       | Smoke & lifecycle                           | ~5m   | 001–009    |
| B       | Drag gesture (interactive scale)            | ~8m   | 010–039    |
| C       | Reference point (plain click + Alt-click)   | ~5m   | 040–059    |
| D       | Scale Options dialog                        | ~8m   | 060–089    |
| E       | Scale Strokes + Scale Corners options       | ~6m   | 090–109    |
| F       | Live Preview (on_change hook)               | ~6m   | 110–129    |
| G       | Copy + Reset + Cancel                       | ~5m   | 130–149    |
| H       | Cross-app parity                            | ~10m  | 200–229    |

Full pass: ~53 min.

---

## Session A — Smoke & lifecycle (~5 min)

- [ ] **SCL-001** [wired] **P0.** Scale Tool activates via
      keyboard.
      Do: Press `S`.
      Expect: Scale Tool becomes the active tool; toolbar Scale
      icon (small + larger nested squares) is highlighted; cursor
      becomes the crosshair.
      — last: —

- [ ] **SCL-002** [wired] **P0.** Scale Tool activates via
      toolbar click.
      Do: Click the Scale icon in row 4 col 0 of the toolbar.
      Expect: Scale becomes active. Long-press triangle visible
      in the icon's lower-right (alternates flyout indicator).
      — last: —

- [ ] **SCL-003** [wired] **P1.** Reference-point cross renders
      for the selection.
      Do: With a selection visible, switch to the Scale tool.
      Expect: A 12 px cyan-blue (#4A9EFF) crosshair with a 2 px
      center dot appears at the selection's bounding-box center.
      — last: —

- [ ] **SCL-004** [wired] **P1.** Cross hides when the selection
      is cleared.
      Do: With Scale active and the cross visible, click an
      empty area with the Selection tool.
      Expect: Selection clears; on returning to Scale, the cross
      is no longer drawn.
      — last: —

- [ ] **SCL-005** [wired] **P2.** Tool deactivation clears the
      cross overlay.
      Do: Switch from Scale to Selection.
      Expect: The reference-point cross disappears; the
      selection bounding box returns to standard Selection-tool
      handles.
      — last: —

- [ ] **SCL-006** [wired] **P2.** Long-press exposes Shear
      alternate.
      Do: Long-press (~250 ms) on the Scale toolbar icon.
      Expect: A flyout / menu shows Shear as the available
      alternate; selecting it activates Shear and the slot icon
      swaps to the parallelogram glyph.
      — last: —

---

## Session B — Drag gesture (~8 min)

- [ ] **SCL-010** [wired] **P0.** Drag away from the reference
      point enlarges the selection.
      Do: With Scale active and a selected rect, click-drag from
      a point near the rect outward.
      Expect: The bbox-ghost (dashed cyan-blue parallelogram)
      tracks the post-scale outline live during the drag; on
      release, the rect's geometry has scaled outward.
      — last: —

- [ ] **SCL-011** [wired] **P1.** Drag toward the reference
      point shrinks the selection.
      Do: Click-drag from a point far from the reference, moving
      cursor toward it.
      Expect: Bbox-ghost shrinks; on release, geometry is
      smaller.
      — last: —

- [ ] **SCL-012** [wired] **P1.** Press point anchors — does
      not relocate the reference point.
      Do: Note the cross position; click-drag from a point that
      is *not* at the cross.
      Expect: The cross stays put; the drag scales around the
      cross, not around the press point.
      — last: —

- [ ] **SCL-013** [wired] **P1.** Shift constrains to uniform
      aspect.
      Do: Hold Shift and drag asymmetrically (more in x than y).
      Expect: Both axes scale by the same signed geometric mean;
      the bbox ghost stays proportionally similar to the
      original.
      — last: —

- [ ] **SCL-014** [wired] **P2.** Dragging through the reference
      point flips the geometry.
      Do: Drag from one side of the reference point to the
      opposite side.
      Expect: At the moment cursor crosses the reference, the
      ghost flips; on release, the committed geometry is mirrored
      on that axis.
      — last: —

- [ ] **SCL-015** [wired] **P2.** Escape during drag cancels.
      Do: Start a drag, press Escape before releasing.
      Expect: Bbox ghost vanishes; document unchanged; mouseup
      doesn't commit.
      — last: —

- [ ] **SCL-016** [wired] **P2.** Tiny drag-then-release keeps
      the document unchanged.
      Do: Press, move 1 px, release.
      Expect: No transform applied (movement under the threshold);
      document unchanged.
      — last: —

- [ ] **SCL-017** [wired] **P2.** Multi-element selection scales
      around the union bbox center.
      Do: Select two elements; switch to Scale; drag.
      Expect: Cross sits at the union bbox center; both elements
      scale together; their relative spacing scales with them.
      — last: —

---

## Session C — Reference point (~5 min)

- [ ] **SCL-040** [wired] **P0.** Plain click sets a custom
      reference point.
      Do: Click (without dragging) at an empty canvas
      coordinate.
      Expect: Cross moves to the click coordinate; selection is
      unchanged; no transform applied.
      — last: —

- [ ] **SCL-041** [wired] **P1.** Subsequent drag pivots around
      the new custom reference.
      Do: After SCL-040, drag from anywhere.
      Expect: Scale pivots around the custom point, not the
      bounds center.
      — last: —

- [ ] **SCL-042** [wired] **P2.** Selection change resets the
      reference to the new bounds center.
      Do: Set a custom reference (SCL-040); then with Selection
      tool, change the selection (e.g., click another element);
      switch back to Scale.
      Expect: Cross is now at the new selection's bounds center,
      not the previous custom location.
      — last: —

- [ ] **SCL-043** [wired] **P2.** Switching between Scale /
      Rotate / Shear preserves the custom reference.
      Do: Set a custom reference under Scale; switch to Rotate;
      switch back to Scale.
      Expect: Cross is at the same custom point — the reference
      is shared across the family.
      — last: —

- [ ] **SCL-044** [wired] **P2.** Click on canvas with no
      selection is a no-op.
      Do: Clear selection; switch to Scale; click anywhere.
      Expect: No cross drawn; click does not set a reference
      that would re-appear later.
      — last: —

---

## Session D — Scale Options dialog (~8 min)

- [ ] **SCL-060** [wired] **P0.** Dblclick on toolbar icon opens
      the Scale Options dialog.
      Do: Double-click the Scale icon.
      Expect: Modal dialog titled "Scale" opens; first focus is
      on the Uniform percentage field.
      — last: —

- [ ] **SCL-061** [wired] **P1.** Alt-click on canvas opens
      the dialog and sets the reference point at the click
      coordinate.
      Do: Alt-click somewhere on the canvas (not in the
      selection).
      Expect: Cross moves to the click coordinate; dialog opens.
      — last: —

- [ ] **SCL-062** [wired] **P0.** OK applies the typed
      percentage.
      Do: Open dialog; enter 200% in Uniform; click OK.
      Expect: Selection doubles in size around the reference
      point; dialog closes.
      — last: —

- [ ] **SCL-063** [wired] **P1.** Cancel discards changes.
      Do: Open dialog; enter 200%; click Cancel.
      Expect: Dialog closes; document unchanged.
      — last: —

- [ ] **SCL-064** [wired] **P1.** Non-Uniform mode applies
      independent factors.
      Do: Open dialog; choose Non-Uniform; enter 150 horizontal,
      75 vertical; OK.
      Expect: Selection grows 1.5× horizontally and shrinks to
      0.75× vertically.
      — last: —

- [ ] **SCL-065** [wired] **P2.** Non-Uniform fields disabled
      under Uniform mode (and vice versa).
      Do: Toggle between Uniform and Non-Uniform.
      Expect: The unselected mode's input(s) are visibly
      disabled / greyed.
      — last: —

- [ ] **SCL-066** [wired] **P2.** Reopening the dialog shows
      the last-entered values (per state.scale_*_pct keys).
      Do: Open dialog, set 200%, OK. Reopen the dialog.
      Expect: Uniform field shows 200% (not the default 100%).
      — last: —

- [ ] **SCL-067** [wired] **P2.** Alt-click with no selection:
      dialog opens, OK greyed.
      Do: Clear selection. Alt-click on canvas.
      Expect: Dialog opens; OK button is disabled; Cancel
      remains active.
      — last: —

---

## Session E — Scale Strokes + Scale Corners (~6 min)

- [ ] **SCL-090** [wired] **P1.** Scale Strokes ON multiplies
      stroke width by the geometric mean.
      Do: Select a 4 pt-stroked rect; open dialog; ensure Scale
      Strokes is checked; enter 200% Uniform; OK.
      Expect: Resulting stroke width ≈ 8 pt (4 × √(2·2) = 8).
      — last: —

- [ ] **SCL-091** [wired] **P1.** Scale Strokes OFF preserves
      stroke width.
      Do: Same setup as SCL-090 but uncheck Scale Strokes.
      Expect: Stroke width stays 4 pt.
      — last: —

- [ ] **SCL-092** [wired] **P2.** Non-uniform with Scale Strokes
      ON uses the geometric mean.
      Do: 4 pt-stroked rect; Non-Uniform 200/50; OK with Scale
      Strokes on.
      Expect: Stroke width ≈ 4 × √(2·0.5) = 4 (geometric mean
      preserves).
      — last: —

- [ ] **SCL-093** [wired] **P1.** Scale Corners ON scales
      rounded_rect rx/ry axis-independently.
      Do: Insert a rounded_rect with rx=10, ry=10. Select it.
      Open dialog; check Scale Corners; enter Non-Uniform
      200/100; OK.
      Expect: rx ≈ 20, ry ≈ 10 (axis-independent).
      — last: —

- [ ] **SCL-094** [wired] **P1.** Scale Corners OFF preserves
      rx/ry.
      Do: Same setup; uncheck Scale Corners.
      Expect: rx and ry stay 10 even though the rect is now
      twice as wide.
      — last: —

- [ ] **SCL-095** [wired] **P2.** Scale Corners on a non-rect
      element is a no-op.
      Do: Select a Path. Check Scale Corners; OK with 200%.
      Expect: Path scales as expected; no error; nothing
      corner-related changed.
      — last: —

---

## Session F — Live Preview (~6 min)

- [ ] **SCL-110** [wired] **P0.** Typing in the dialog updates
      the canvas live.
      Do: Open dialog with Preview checked. Type values into
      Uniform percentage (e.g. 150).
      Expect: Canvas re-renders the selection live as values
      change — without leaving the dialog.
      — last: —

- [ ] **SCL-111** [wired] **P1.** Cancel reverts to the
      pre-dialog state.
      Do: After SCL-110 type-time preview, click Cancel.
      Expect: Document reverts to the pre-dialog geometry; no
      undo entry pushed.
      — last: —

- [ ] **SCL-112** [wired] **P1.** OK keeps the previewed
      result.
      Do: After typing previews, click OK.
      Expect: Final committed geometry matches the last-typed
      preview; one undo entry recorded.
      — last: —

- [ ] **SCL-113** [wired] **P2.** Toggling values multiple
      times before OK doesn't compound the result.
      Do: Type 200 → 50 → 150 → OK.
      Expect: Final result is 150% — not 200·0.5·1.5 = 150 by
      coincidence; should be exactly 150% applied to the
      original geometry.
      — last: —

- [ ] **SCL-114** [wired] **P2.** Preview pollutes neither
      undo nor the saved-modified flag (until OK).
      Do: Open dialog; type values; observe undo state; Cancel.
      Expect: Undo button does not enable until / unless OK is
      clicked; document is not "modified" if Cancel is used.
      — last: —

---

## Session G — Copy + Reset + Cancel (~5 min)

- [ ] **SCL-130** [wired] **P1.** Copy duplicates and applies.
      Do: Open dialog; enter 200%; click Copy.
      Expect: A duplicate of the selection appears, scaled to
      200%; the original is unchanged. Selection moves to the
      duplicate.
      — last: —

- [ ] **SCL-131** [wired] **P2.** Reset restores defaults
      (without committing).
      Do: Open dialog; change values to 200%; click Reset.
      Expect: Fields return to 100% / 100% / 100% / Scale
      Strokes ON / Scale Corners OFF / Preview ON; dialog stays
      open.
      — last: —

- [ ] **SCL-132** [wired] **P2.** Reset doesn't write state
      until OK.
      Do: Reset + close dialog with Cancel; reopen.
      Expect: Last-OK values persist; the Reset was discarded.
      — last: —

---

## Session H — Cross-app parity (~10 min)

- **SCL-200** [wired] Drag scaling around the bounds center.
      Do: Select a 100×80 rect; press S; drag the cursor 100 px
      diagonally outward from the bounds center; release.
      Expect: Rect roughly doubles in each axis around the
      bounds center.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **SCL-201** [wired] Click sets reference, then drag pivots
      around it.
      Do: Press S; click empty canvas at (50, 50); drag from
      (200, 200) outward.
      Expect: Cross at (50, 50); rect scales around (50, 50),
      so its near corner stays nearer (50, 50) and far corner
      moves further.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **SCL-202** [wired] Dialog OK applies; Cancel reverts.
      Do: Dblclick Scale icon; enter 200% Uniform; OK. Repeat
      with Cancel.
      Expect: OK doubles the selection; Cancel leaves it
      unchanged.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **SCL-203** [wired] Live Preview re-renders during dialog
      typing.
      Do: Dblclick Scale icon; type 150 in Uniform; observe
      canvas before clicking anything else.
      Expect: Canvas reflects 150% scale live.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **SCL-204** [wired] Scale Strokes ON multiplies stroke width
      by the geometric mean.
      Do: 4 pt-stroked rect; dialog 200% Uniform with Scale
      Strokes on; OK.
      Expect: Stroke width 8 pt.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **SCL-205** [wired] Copy duplicates the selection.
      Do: Dialog 200%; click Copy.
      Expect: Duplicate appears scaled; original untouched.
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
