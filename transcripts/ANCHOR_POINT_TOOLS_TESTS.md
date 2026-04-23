# Anchor Point Tools — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec sources:
`workspace/tools/add_anchor_point.yaml`,
`workspace/tools/delete_anchor_point.yaml`,
`workspace/tools/anchor_point.yaml`. Design doc:
`transcripts/ANCHOR_POINT_TOOLS.md`.

Covers **Add Anchor Point**, **Delete Anchor Point**, and the
**Anchor Point (Convert)** tools — three related tools that edit
anchors of already-drawn Path elements.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other platforms
covered in Session J parity sweep.

---

## Known broken

_Last reviewed: 2026-04-23_

- **APT-200** [known-broken: ANCHOR_POINT_TOOLS.md §Anchor Point
  tool — no live preview] Convert tool has no live preview during
  drag; the commit is computed on mouseup. Matches the MVP design
  but is a UX gap vs native anchor-point tools.

- **APT-201** [deferred: ANCHOR_POINT_TOOLS.md §Add Anchor Point —
  partial-CP preservation] Inserting an anchor into a path that
  currently has specific CPs selected in the selection drops back
  to `.all`-compatible semantics. Preserving specific-CP selections
  across insertion is deferred.

---

## Automation coverage

_Last synced: 2026-04-23_

**Python — `jas/geometry/path_ops_test.py`** (~10 tests)
- `TestInsert` — `insert_point_in_path` for line and curve
  segments; InsertAnchorResult shape.
- `TestDelete` — `delete_anchor_from_path` interior / first /
  last + two-anchor degenerate case.
- `TestProjection` — `closest_segment_and_t` used by Add tool.

**Swift — `JasSwift/Tests/Geometry/PathOpsTests.swift`**
- Mirror of the Python kernel tests + convert-anchor helpers
  (convert_to_corner / convert_to_smooth,
  move_path_handle_independent).

**OCaml — `jas_ocaml/test/geometry/path_ops_test.ml`**
- Mirror of Python / Swift path-ops coverage.

**Rust — `jas_dioxus/src/geometry/path_ops.rs` (#[cfg(test)])**
- Reference kernel implementation. Also each app's YamlTool
  dispatch test covers the anchor-point YAML handlers.

**Flask — no coverage.**

The manual suite below covers 8 px hit tolerance in practice, multi-
path disambiguation, group recursion, no-preview mouseup semantics,
and cross-app vertex math parity.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document.
3. Appearance: **Dark**.
4. Draw a **4-anchor path** fixture: Pen tool → corner click (100,100)
   → corner click (300,100) → corner click (300,300) → corner click
   (100,300) → Esc. This gives an open 4-anchor path.
5. Activate the target anchor-point tool (`=`, `-`, or `C`).

`hit_radius = 8 px` for all three tools. Convert tool handle tolerance
is 8 px; CP-drag threshold is 1 px; handle-drag threshold is 0.5 px.

---

## Tier definitions

- **P0 — existential.** Tool doesn't activate; doesn't
  insert/delete/convert; crashes.
- **P1 — core.** Primary action (insert / delete / toggle) correctly
  modifies the path.
- **P2 — edge & polish.** 8 px tolerance boundary, multi-path
  disambiguation, group recursion, no-op cases, cross-tool
  handoff, appearance theming.

---

## Session table of contents

| Session | Topic                                         | Est.  | IDs      |
|---------|-----------------------------------------------|-------|----------|
| A       | Smoke & lifecycle                             | ~5m   | 001–009  |
| B       | Add Anchor Point — line segment               | ~6m   | 010–029  |
| C       | Add Anchor Point — curve segment              | ~6m   | 030–049  |
| D       | Delete Anchor Point — interior / first / last | ~8m   | 050–079  |
| E       | Delete — path below 2 anchors                 | ~4m   | 080–089  |
| F       | Convert — corner → smooth                     | ~6m   | 100–119  |
| G       | Convert — smooth → corner                     | ~5m   | 120–139  |
| H       | Convert — handle-drag (cusp)                  | ~6m   | 140–159  |
| I       | Group recursion / multi-path                  | ~5m   | 160–179  |
| J       | Cross-app parity                              | ~15m  | 200–229  |

Full pass: ~65 min.

---

## Session A — Smoke & lifecycle (~5 min)

- [ ] **APT-001** [wired] Add Anchor Point activates via `=`.
      Do: Press =.
      Expect: Add Anchor Point tool active; pen-plus cursor
              (or tool-specific crosshair variant).
      — last: —

- [ ] **APT-002** [wired] Delete Anchor Point activates via `-`.
      Do: Press -.
      Expect: Delete Anchor Point tool active.
      — last: —

- [ ] **APT-003** [wired] Convert activates via `C`.
      Do: Press C.
      Expect: Anchor Point (Convert) tool active.
      — last: —

- [ ] **APT-004** [wired] All three tools activate via toolbox icons.
      Do: Click each icon in turn.
      Expect: Each activates; active state cycles.
      — last: —

---

## Session B — Add Anchor Point on a line segment (~6 min)

**P0**

- [ ] **APT-010** [wired] Click on the middle of a line segment
  inserts an anchor.
      Setup: 4-anchor fixture; Add tool.
      Do: Click at (200,100) — midpoint of the top segment.
      Expect: A new anchor appears at (200,100); path now has 5
              anchors; the two halves remain straight lines.
      — last: —

- [ ] **APT-011** [wired] Click further than 8 px from any segment is
  a no-op.
      Setup: 4-anchor fixture; Add tool.
      Do: Click at (500,500) (far from the path).
      Expect: Path unchanged; no undo entry; no visible change.
      — last: —

**P1**

- [ ] **APT-012** [wired] Click near the exact midpoint produces
  identical anchor position.
      Setup: 4-anchor fixture; Add tool.
      Do: Click at (200.3, 100.3) (within 8 px of (200,100) on the
          top segment).
      Expect: New anchor inserted near (200.3,100.3) — the projection
              onto the segment, not the exact click point.
      — last: —

**P2**

- [ ] **APT-013** [wired] 8 px tolerance boundary.
      Setup: 4-anchor fixture; Add tool.
      Do: Click exactly 7 px off the segment.
      Expect: Anchor inserted.
      Do: Click exactly 9 px off the segment.
      Expect: No-op.
      — last: —

- [ ] **APT-014** [wired] Inserted anchor preserves .all selection.
      Setup: Select the path (.all).
      Do: Add an anchor.
      Expect: Selection remains .all — the new anchor is implicitly
              part of the selection.
      — last: —

---

## Session C — Add Anchor Point on a curve segment (~6 min)

**P1**

- [ ] **APT-030** [wired] Click mid-curve inserts via De Casteljau.
      Setup: Draw a curved path with Pen (click (100,200);
             drag-smooth to (200,100) by pressing and dragging to
             (250,100); click (300,200); Esc).
      Do: Click near the middle of the curve.
      Expect: New anchor inserted; the two sub-curves trace the same
              path as the original (visually unchanged overall
              shape).
      — last: —

**P2**

- [ ] **APT-031** [wired] Curve subdivision preserves tangent
  continuity at insertion.
      Setup: Smooth curve; insert an anchor at t=0.5.
      Do: Inspect new anchor's in/out handles.
      Expect: In-handle and out-handle are mirrored through the
              anchor (smooth); tangent is the curve tangent at
              that t.
      — last: —

- [ ] **APT-032** [wired] Inserting into a closed path preserves the
  ClosePath command.
      Setup: Pen → draw a closed 4-anchor path.
      Do: Click mid-segment to insert.
      Expect: Path still closed after insertion; anchor count
              increases by 1.
      — last: —

---

## Session D — Delete Anchor Point interior / first / last (~8 min)

**P0**

- [ ] **APT-050** [wired] Click on an interior anchor removes it and
  merges segments.
      Setup: 4-anchor fixture; Delete tool.
      Do: Click exactly on the anchor at (300,100).
      Expect: That anchor is removed; path now has 3 anchors; the
              adjacent segments merge into a single line from
              (100,100) to (300,300).
      — last: —

- [ ] **APT-051** [wired] Click > 8 px from any anchor is a no-op.
      Setup: 4-anchor fixture; Delete tool.
      Do: Click at (500,500).
      Expect: Path unchanged.
      — last: —

**P1**

- [ ] **APT-052** [wired] Deleting the first anchor promotes the
  second to MoveTo.
      Setup: 4-anchor fixture.
      Do: Click the first anchor at (100,100).
      Expect: Path now has 3 anchors; new MoveTo is at (300,100)
              (the former second anchor).
      — last: —

- [ ] **APT-053** [wired] Deleting the last anchor trims the final
  segment.
      Setup: 4-anchor fixture.
      Do: Click the last anchor at (100,300).
      Expect: Path has 3 anchors ending at (300,300); no trailing
              ClosePath introduced.
      — last: —

**P2**

- [ ] **APT-054** [wired] Deleting a smooth-anchor interior merges
  curves preserving outer handles.
      Setup: Curved path with 4 smooth anchors.
      Do: Delete the 2nd anchor.
      Expect: Outer handles of the kept 1st and 3rd anchors
              preserved; merged segment is a curve (not a line).
      — last: —

- [ ] **APT-055** [wired] Delete tool hit radius is 8 px.
      Setup: 4-anchor fixture.
      Do: Click 7 px from an anchor — deletes. Click 9 px from any
          anchor — no-op.
      Expect: 8 px tolerance boundary.
      — last: —

---

## Session E — Delete brings path below 2 anchors (~4 min)

**P1**

- [ ] **APT-080** [wired] Deleting one of two remaining anchors
  removes the whole path.
      Setup: Pen → draw a 2-anchor line → Esc.
      Do: Delete tool → click one of the two anchors.
      Expect: The entire Path element is removed from the document
              (instead of replaced with a 1-anchor degenerate path).
      — last: —

- [ ] **APT-081** [wired] Deleting to 1 anchor of an originally
  3-anchor path succeeds once.
      Setup: 3-anchor path.
      Do: Delete anchor #2 (valid; path becomes 2 anchors). Then
          delete anchor #1 (would leave 1 anchor; path is removed).
      Expect: First delete leaves 2 anchors; second delete removes
              the whole path.
      — last: —

---

## Session F — Convert — corner → smooth (~6 min)

**P1**

- [ ] **APT-100** [wired] Click-and-drag on a corner anchor converts
  to smooth.
      Setup: 4-anchor fixture (all corners); Convert tool.
      Do: Press on the anchor at (300,100); drag 40 px right;
          release.
      Expect: That anchor becomes smooth; out-handle sits at the
              mouseup position ((340,100)); in-handle mirrored
              through the anchor ((260,100)); adjacent curves
              visibly rounded.
      — last: —

- [ ] **APT-101** [wired] Plain click (< 1 px drag) on a corner is a
  no-op.
      Setup: 4-anchor fixture; Convert tool.
      Do: Click precisely on the anchor (no drag) and release.
      Expect: Anchor remains corner; no conversion.
      — last: —

**P2**

- [ ] **APT-102** [wired] Sub-1-pixel drag treated as no-op.
      Setup: 4-anchor fixture; Convert.
      Do: Press on a corner; drag 0.5 px; release.
      Expect: No conversion.
      — last: —

---

## Session G — Convert — smooth → corner (~5 min)

**P1**

- [ ] **APT-120** [wired] Click on a smooth anchor collapses it to
  corner.
      Setup: Create a smooth anchor via APT-100, then press C again
             (re-enter Convert tool).
      Do: Click (no drag) on the smooth anchor.
      Expect: Anchor becomes corner; both handles coincide with the
              anchor position; adjacent segments revert to lines.
      — last: —

**P2**

- [ ] **APT-121** [wired] Drag on smooth-anchor body is still a
  smooth→corner conversion.
      Setup: Smooth anchor; Convert.
      Do: Press on the anchor body; drag; release.
      Expect: Anchor collapses to corner (priority 2 wins over
              priority 1 handle-drag because drag was on the body,
              not a handle endpoint).
      — last: —

---

## Session H — Convert — handle-drag (cusp) (~6 min)

**P1**

- [ ] **APT-140** [wired] Drag on an out-handle endpoint moves only
  that handle.
      Setup: Smooth anchor (via APT-100); overlay showing in/out
             handle bars.
      Do: Press on the out-handle endpoint; drag 30 px; release.
      Expect: Out-handle moves by 30 px; in-handle stays put (cusp
              behavior — no longer mirrored).
      — last: —

- [ ] **APT-141** [wired] Drag on an in-handle endpoint moves only
  that handle.
      Setup: Smooth anchor.
      Do: Press on the in-handle endpoint; drag 30 px; release.
      Expect: In-handle moves; out-handle stays put.
      — last: —

**P2**

- [ ] **APT-142** [wired] Sub-0.5-pixel handle drag treated as no-op.
      Setup: Smooth anchor.
      Do: Press on a handle endpoint; drag 0.3 px; release.
      Expect: No change.
      — last: —

- [ ] **APT-143** [wired] Handle priority wins over body hit.
      Setup: Anchor with handle endpoint very near the anchor body.
      Do: Press at a position 2 px from the handle endpoint (also
          within 8 px of the anchor body).
      Expect: Handle-drag mode engages (priority 1), not
              body-conversion.
      — last: —

---

## Session I — Group recursion / multi-path (~5 min)

**P2**

- [ ] **APT-160** [wired] Add / Delete / Convert walk one level of
  group nesting.
      Setup: Group fixture with a path inside; relevant tool active.
      Do: Click a segment / anchor of the grouped path.
      Expect: The tool operates on the inner path, same as on a
              top-level path.
      — last: —

- [ ] **APT-161** [wired] Among overlapping paths, the closest hit
  wins.
      Setup: Two paths whose segments are near each other.
      Do: Add tool → click in the region where both are within 8 px.
      Expect: The globally closest (path, segment, t) is chosen;
              anchor inserted on the closest path only.
      — last: —

- [ ] **APT-162** [wired] Locked paths are ignored.
      Setup: Lock the 4-anchor path via the Layers panel.
      Do: Click any anchor / segment with any of the three tools.
      Expect: No-op; path unchanged.
      — last: —

---

## Cross-app parity — Session J (~15 min)

~8 load-bearing tests.

- **APT-200** [wired] Add tool insert-on-line produces same anchor
  position.
      Do: 4-anchor fixture; Add tool; click (200,100).
      Expect: New anchor at (200,100) in every app; path has 5
              anchors.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **APT-201** [wired] Add tool 8 px tolerance boundary identical.
      Do: Click 9 px off the segment.
      Expect: No-op in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **APT-202** [wired] Delete tool interior merge produces same
  geometry.
      Do: 4-anchor fixture; Delete anchor 2.
      Expect: 3-anchor path in every app with identical geometry.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **APT-203** [wired] Delete below 2 anchors removes the Path element.
      Do: 2-anchor path; Delete one anchor.
      Expect: Path element removed from document in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **APT-204** [wired] Convert corner → smooth drag produces mirrored
  handles.
      Do: Corner anchor; Convert; drag out-handle.
      Expect: In-handle mirrored through anchor position in every
              app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **APT-205** [wired] Convert smooth → corner click collapses handles.
      Do: Smooth anchor; Convert click (no drag).
      Expect: Both handles coincide with anchor position in every
              app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **APT-206** [wired] Handle-drag cusp semantics — only one handle
  moves.
      Do: Smooth anchor; drag an out-handle 30 px.
      Expect: Out-handle moves in every app; in-handle unchanged.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **APT-207** [wired] Group recursion walks one level down.
      Do: Grouped path; use any of the three tools on the inner
          path.
      Expect: Inner path modified identically in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

---

## Graveyard

_No retired tests yet._

---

## Enhancements

- **ENH-001** Live preview during Convert drag — show the rearranged
  handles interactively rather than only on mouseup. _Raised during
  APT-100 on 2026-04-23._

- **ENH-002** Preserve specific-CP selections across Add — see
  APT-201 known-broken. _Raised during APT-014 on 2026-04-23._

- **ENH-003** Space+drag-reposition on Add — after inserting an
  anchor, allow space+drag to fine-tune its position without
  switching tools. _Raised during APT-010 on 2026-04-23._
