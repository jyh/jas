# Coordinate Reconcile + New Effects — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. This is a **cross-cutting
regression pass**, not a per-component suite: it targets the two changes
landed on branch `testing-strategy` that the cross-language corpora cannot
see —

- **`ad79310b`** — Scale / Rotate / Shear reconciled to document space
  (YAML `event.x/y → event.doc_x/doc_y` for press, cursor, the move
  threshold, the apply args, and `transform_reference_point`; the
  `reference_point_cross` and `bbox_ghost` overlays now map doc→screen at
  draw time). Spec: `workspace/tools/{scale,rotate,shear}.yaml`.
- **`84d2de5d`** — two effects implemented in all 4 apps:
  `doc.snapshot.restore` (Escape-cancel for the transform tools) and
  `doc.blob_brush.sweep_sample` (Blob Brush dab accumulation along a drag).
  Spec: `workspace/tools/{scale,rotate,shear,blob_brush}.yaml`.

The canonical per-tool suites are `SCALE_TOOL_TESTS.md`,
`ROTATE_TOOL_TESTS.md`, `SHEAR_TOOL_TESTS.md`, `BLOB_BRUSH_TOOL_TESTS.md`.
**Those run at the default (identity) view, where document space and screen
space coincide — so they pass even on the pre-fix code.** This file adds the
one dimension they omit: a canvas that is **both panned and zoomed**. The
non-identity variants below should eventually fold back into the per-tool
suites; until then run this pass after any change near tool coordinate
handling.

Primary platform for manual runs: **Rust (jas_dioxus)**. Swift / OCaml /
Python covered in the Session E parity sweep. Flask is N/A (no canvas
subsystem).

---

## Known broken

_Last reviewed: 2026-06-24_

_None known. All four apps build + pass their cross-language corpora; each
app's reconcile was adversarially verified. These behaviors are manual-floor
(corpus-invisible) and unconfirmed in a live GUI — that is what this pass
exists to close._

---

## Automation coverage

_Last synced: 2026-06-24_

The cross-language gesture / action / key corpora gate all apps in CI, but
they drive the tools at the **default view (zoom = 1, view_offset = 0)**,
where `event.doc_x == event.x`. The doc-space reconcile is **identity-neutral
by construction** — so the corpora stayed green through the change and, by
the same token, **cannot detect a regression in it.** Likewise the two new
effects are live-tool behaviors with no corpus entry.

Net: there is **zero automated coverage** of (a) any transform at a
non-identity view, (b) Escape-cancel rollback, (c) Blob Brush path-following.
Everything in this file is the only gate on those.

---

## Default setup — the load-bearing precondition

Unless a test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document. Appearance: **Dark**.
3. Draw **two rectangles** a little apart, so the selection has an obvious,
   off-center bounding box. Select both (Selection tool, marquee).
4. **Move the view off the identity transform — this is the whole point:**
   - **Pan** so the artwork sits well away from the canvas origin
     (Hand tool, or hold Space and drag).
   - **Zoom to ~300 %** (Zoom tool click, or ⌘+ a few times).
   Now `view_offset ≠ 0` **and** `zoom ≠ 1`. A run at 100 % / no pan tests
   nothing here — it would pass on the old code too.

**Drift tell-tale.** The pre-fix failure mode is a *large* displacement
(tens to hundreds of px) that scales with how far you panned / how deep you
zoomed — a crosshair parked near the origin, a ghost that lags the cursor by
your pan amount, or a committed transform whose pivot is in the wrong place.
A sub-pixel jitter is not this bug.

---

## Tier definitions

- **P0 — existential.** The overlay/commit is grossly mislocated at a
  non-identity view (the regression this pass guards), Escape does nothing,
  or the Blob Brush collapses a curve to a straight band.
- **P1 — core.** Pivot correctness for a custom reference point, commit
  matches preview, no stray undo entry after Escape, parity across apps.
- **P2 — edge & polish.** Identity-view sanity guard, fixed-pixel overlay
  sizing under zoom, dab spacing.

---

## Session table of contents

| Session | Topic                                                | Est.  | IDs        |
|---------|------------------------------------------------------|-------|------------|
| A       | `reference_point_cross` at non-identity              | ~6m   | 001–009    |
| B       | `bbox_ghost` preview + commit at non-identity        | ~10m  | 010–029    |
| C       | Escape-cancel (`doc.snapshot.restore`)               | ~5m   | 030–039    |
| D       | Blob Brush path-follow (`doc.blob_brush.sweep_sample`)| ~5m   | 040–049    |
| E       | Cross-app parity (Rust / Swift / OCaml / Python)     | ~12m  | 200–219    |

Full pass: ~38 min.

---

## Session A — `reference_point_cross` at non-identity (~6 min)

Selection of two rects; view panned + zoomed per Default setup.

- [x] **CR-001** [wired] **P0.** Crosshair tracks the selection center.
      Do: with the selection live, activate **Scale** (`S`); do not drag.
      Expect: a 12 px cyan (`#4A9EFF`) crosshair with a 2 px center dot sits
      on the selection's *visual* bbox center on screen — glued to the
      shapes, not parked near the canvas origin or offset by your pan amount.
      _PASS — Swift, 2026-06-24, via the Quartz synthetic-gesture harness:
      crosshair centered on the rect at identity AND after 4× zoom (the rect
      shifted toward the top, crosshair followed its center)._

- [x] **CR-002** [wired] **P2.** Crosshair is fixed screen-size under zoom.
      Do: with Scale active + selection, zoom from ~300 % to ~600 %.
      Expect: the crosshair stays ~12 px on screen (it does **not** grow with
      zoom) while remaining centered on the now-larger selection.
      _PASS — Swift, 2026-06-24: after 4× zoom the rect grew 4× but the
      crosshair stayed the same small size._

- [ ] **CR-003** [wired] **P0.** Custom clicked reference lands under the
      cursor. Do: plain-click a distinct point well away from the selection.
      Expect: the crosshair jumps to exactly under the click (within a px)
      and re-anchors there through further pan/zoom (it is now a fixed
      document point, not a screen point).

- [ ] **CR-004** [wired] **P1.** Reference resets on selection change.
      Do: deselect (click empty canvas), then select a different element.
      Expect: crosshair hidden with no selection; reappears at the new
      selection's center (the custom ref from CR-003 is cleared).

---

## Session B — `bbox_ghost` preview + commit at non-identity (~10 min)

- [x] **CR-010** [wired] **P0.** Scale ghost tracks the cursor.
      Do: Scale tool, selection live, drag outward starting near a bbox
      corner. Expect: a dashed (4/2) ghost quad grows from the reference
      point and its dragged edge follows the cursor exactly — no lag or drift
      proportional to the pan/zoom; dash thickness constant.
      _PASS — Swift, 2026-06-24, via the Quartz harness (split begin/hold drag
      captured mid-gesture): the dashed ghost quad rendered around the
      reference center, scaled by the drag._

- [ ] **CR-011** [wired] **P0.** Commit equals preview.
      Do: release the drag. Expect: the shapes land exactly where the ghost
      previewed; final bbox matches the last ghost frame.

- [ ] **CR-012** [wired] **P0.** Custom-reference pivot correctness (the deep
      bug). Do: plain-click a custom reference point, then drag-scale.
      Expect: scaling pivots about that exact document point — the point under
      the crosshair stays fixed on screen throughout the drag **and** after
      commit. (Pre-fix this pivot was displaced, because a clicked ref stored
      *screen* coords into a field the apply reads as *document* coords.)
      _Geometric substance now automated in Swift:
      `JasTests…ToolInteractionTests.scaleCustomRefPivotsAboutDocPointAtNonIdentityView`
      drives this gesture at zoom=2/offset=(10,20) and asserts the pivot is
      doc (0,0). Verified non-vacuous (fails on the pre-fix ref line). This
      manual test remains for the visual "crosshair stays put" confirmation and
      for Rust/OCaml/Python._

- [ ] **CR-013** [wired] **P1.** Shift uniform-aspect still pivots correctly.
      Do: Shift+drag a scale. Expect: uniform aspect, still anchored at the
      reference point.

- [ ] **CR-014** [wired] **P1.** Rotate ghost + commit.
      Do: Rotate tool, drag. Expect: ghost rotates about the crosshair, angle
      follows the cursor, commit matches the ghost.

- [ ] **CR-015** [wired] **P1.** Shear ghost + commit.
      Do: Shear tool, drag. Expect: ghost shears about the crosshair / axis,
      commit matches the ghost.

- [ ] **CR-016** [wired] **P2.** Identity-view regression guard.
      Do: reset to 100 % and no pan; repeat CR-010 / CR-011.
      Expect: unchanged behavior — confirms the doc-space conversion did not
      break the common case.

---

## Session C — Escape-cancel `doc.snapshot.restore` (~5 min)

This is the behavior the new effect enables — pre-implementation Escape
no-op'd. (Complements `SCL-015` / `ROT-014` / `SHR-015`, which now actually
exercise the implemented rollback.)

- [x] **CR-030** [wired] **P0.** Escape mid scale-drag reverts.
      Do: begin a scale drag (ghost showing), press **Escape** before
      releasing. Expect: the selection snaps back to its original size and
      position; the ghost clears; the tool returns to idle.
      _Was a REAL BUG (user-confirmed: "esc is rejected"), not a harness limit.
      Root cause: Swift CanvasSubwindow.keyDown routed Escape to mask-handling /
      super and NEVER to the active tool's on_keydown (onKeyEvent was gated
      behind capturesKeyboard(), true only for type tools) — so Escape-cancel
      was dead for EVERY tool (scale/rotate/shear, pen, rect, lasso, ...). Fixed:
      Escape now gives the active tool's on_keydown first crack. PASS via the
      harness 2026-06-24: ghost clears on Escape mid-drag and the release no
      longer commits._

- [ ] **CR-031** [wired] **P1.** No stray undo entry after Escape.
      Do: after CR-030, open the undo history / press ⌘Z once.
      Expect: Undo does **not** reveal a phantom scale op — the begin-txn was
      rolled back, not committed. ⌘Z acts on the pre-drag state.

- [ ] **CR-032** [wired] **P1.** Escape mid rotate-drag reverts (+ no stray
      undo). Do: as CR-030/031 with the Rotate tool.

- [ ] **CR-033** [wired] **P1.** Escape mid shear-drag reverts (+ no stray
      undo). Do: as CR-030/031 with the Shear tool.

---

## Session D — Blob Brush path-follow `doc.blob_brush.sweep_sample` (~5 min)

- [ ] **CR-040** [wired] **P0.** Curved drag follows the path.
      Do: Blob Brush, drag a clear S-curve or loop in one continuous gesture.
      Expect: the committed shape traces the **whole curve** (a ribbon along
      the path) — **not** a single straight band from the press point to the
      release point. (Pre-fix the buffer held only press + release.)
      _Harness-BLOCKED (2026-06-24): the Blob Brush is a long-press flyout
      alternate of the Paintbrush and its `Shift+B` shortcut did not switch
      tools via synthetic keyboard, so the curve never painted (selection tool
      stayed active). Needs a HUMAN, or harness work to drive the long-press
      flyout. The `doc.blob_brush.sweep_sample` code (84d2de5d) + algorithm are
      in place; only the visual is unconfirmed. (Possible side-finding: Shift+
      letter tool shortcuts may not route via synthetic keyboard — unconfirmed
      whether harness or app.)_

- [ ] **CR-041** [wired] **P1.** Dab spacing is continuous.
      Do: drag slowly, then quickly. Expect: continuous coverage along the
      path in both — no gaps from under-sampling, no degenerate single
      segment.

- [ ] **CR-042** [wired] **P1.** Blob paints under the cursor at non-identity.
      Do: at ~300 % + panned, draw a curve. Expect: the oval cursor and the
      painted ribbon sit under the cursor along the whole path (position
      correct at pan/zoom; ties to the earlier blob doc-space fix).

---

## Session E — Cross-app parity (~12 min)

Run this load-bearing subset on each native app, at a panned + zoomed view.
**Flask: N/A** (no canvas subsystem — not an interactive-parity target).

Subset: **CR-001** (crosshair tracks center) · **CR-011** (commit = ghost) ·
**CR-012** (custom-ref pivot) · **CR-030** (Escape reverts scale) ·
**CR-040** (blob curved-drag follows path).

### Rust (jas_dioxus)
- [ ] **CR-200** CR-001 · [ ] **CR-201** CR-011 · [ ] **CR-202** CR-012 ·
      [ ] **CR-203** CR-030 · [ ] **CR-204** CR-040

### Swift (JasSwift)
- [ ] **CR-205** CR-001 · [ ] **CR-206** CR-011 · [ ] **CR-207** CR-012 ·
      [ ] **CR-208** CR-030 · [ ] **CR-209** CR-040

### OCaml (jas_ocaml)
- [ ] **CR-210** CR-001 · [ ] **CR-211** CR-011 · [ ] **CR-212** CR-012 ·
      [ ] **CR-213** CR-030 · [ ] **CR-214** CR-040

### Python (jas)
- [ ] **CR-215** CR-001 · [ ] **CR-216** CR-011 · [ ] **CR-217** CR-012 ·
      [ ] **CR-218** CR-030 · [ ] **CR-219** CR-040

---

## Graveyard

_None._

---

## Enhancements

- **CR-E1.** Fold the non-identity variants (CR-001/011/012, CR-030,
  CR-040/042) into the per-tool suites as a standing "panned + zoomed" sub
  session, so a future tool change re-tests them in place rather than via
  this regression doc.
- **CR-E2.** A gesture-corpus entry that drives a transform tool at a
  non-identity view (non-zero `view_offset`, `zoom ≠ 1`) would move CR-011 /
  CR-012 from manual-floor to *cross-language* CI-gated. Blocked on the
  gesture corpus carrying view state at the CanvasTool seam. _Partial:
  CR-012's geometry is now a Swift unit test (see CR-012); mirroring it to
  Rust / OCaml / Python would guard all four pending the corpus work._
