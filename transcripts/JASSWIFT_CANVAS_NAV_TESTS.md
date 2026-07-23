# JasSwift Canvas Navigation & Render Hygiene — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. This suite is **Swift-only**
(the flagship-hygiene rung): AppKit trackpad gestures, the canvas context
menu, and the dirty-rect / repaint-scoping render work have no yaml spec and
no cross-language corpus — they are framework-fused and live entirely on the
manual floor. Spec touchpoints: `workspace/tools/hand.yaml` (pan write path),
`workspace/tools/zoom.yaml` (zoom anchor + clamp), `workspace/menubar.yaml`
(Edit predicates the context menu mirrors).

Primary platform: **Swift (JasSwift)**. Not a cross-app parity suite — these
gestures are intentionally Mac-native and do not exist on the other ports.

Run: `swift run Jas --title JasSwift`, then a document with a few shapes and
at least one artboard. A trackpad is required for Sessions A and B (pinch /
two-finger tap).

---

## Automation coverage

Gated below this manual floor — do **not** re-verify here:

- pan math / scroll-adapter (delta → offset, precise-vs-line, zoom-independence),
  pinch anchor math (anchor invariant + both zoom clamps) — `CanvasNavGestureTests`.
- context-menu item set / titles / enabled predicates, and the shared
  `EditClipboard` cut/copy/paste on a private pasteboard — `CanvasContextMenuTests`.
- the cull predicate (inside/outside/straddle/margin, translate/scale/rotate),
  plus an offscreen-render invariance check — `CanvasCullTests`, `CanvasCullRenderTests`.
- the repaint-signature gate (every trigger flips it; irrelevant churn does not;
  model-identity disambiguation) — `CanvasRenderSignatureTests`.

What remains below is the irreducible floor: real trackpad events, cursor-anchored
feel, live enabled/disabled rendering, and visual correctness of the paint.

---

## Session A — navigation gestures (trackpad)

**P0**

- [ ] **SWNAV-001** [wired] Two-finger scroll pans the canvas.
      Do: With any tool active, two-finger scroll up / down / left / right on the canvas.
      Expect: The artboard + shapes pan smoothly in all four directions; no tool gesture fires, nothing is selected or drawn.
      — last: —

- [ ] **SWNAV-002** [wired] Pan direction is natural (content follows fingers).
      Do: Two-finger swipe the fingers to the right, then down.
      Expect: Canvas content moves right, then down — the "grab the paper" direction (matches dragging with the Hand tool).
      — last: —

- [ ] **SWNAV-003** [wired] Momentum scrolling feels right.
      Do: Flick two fingers and lift off.
      Expect: The canvas keeps gliding and eases to a stop; no jump, stutter, or snap-back at the end of momentum.
      — last: —

- [ ] **SWNAV-004** [wired] Pinch zooms about the cursor.
      Do: Rest the cursor over a distinctive point (e.g. a shape corner) and pinch open, then closed.
      Expect: Zoom in/out happens smoothly and the point under the fingers stays put (does not drift toward center).
      Pass if: the anchored point is still under the cursor after the gesture.
      — last: —

**P1**

- [ ] **SWNAV-005** [wired] Zoom clamps hold with the anchor glued.
      Do: Pinch open hard past maximum zoom, then pinch closed hard past minimum.
      Expect: Zoom stops at the app's max/min; the anchor point stays under the cursor at the boundary (no lurch).
      — last: —

- [ ] **SWNAV-006** [wired] Pan + pinch compose without a fight.
      Do: Alternate a two-finger scroll and a pinch a few times.
      Expect: Pan and zoom stay consistent; no coordinate jump when switching between them.
      — last: —

- [ ] **SWNAV-007** [wired] Mouse wheel still pans (non-trackpad).
      Setup: A plain scroll wheel or Magic Mouse.
      Do: Scroll the wheel with the pointer over the canvas.
      Expect: The canvas pans by a comparable amount per notch; direction matches the trackpad.
      — last: —

---

## Session B — canvas context menu

**P0**

- [ ] **SWCTX-001** [wired] Right-click / two-finger tap opens the edit menu.
      Do: Right-click (or two-finger tap) on the canvas.
      Expect: A menu appears with Cut, Copy, Paste, a divider, Delete, a divider, Select All — titles exactly as written.
      — last: —

- [ ] **SWCTX-002** [wired] Enabled states mirror the Edit menu (no selection).
      Setup: Nothing selected.
      Do: Open the context menu.
      Expect: Cut, Copy, Delete are disabled (grey); Paste and Select All are enabled.
      — last: —

- [ ] **SWCTX-003** [wired] Enabled states with a selection.
      Setup: Select one shape.
      Do: Open the context menu.
      Expect: Cut, Copy, Delete are now enabled; Paste and Select All remain enabled.
      — last: —

**P1**

- [ ] **SWCTX-004** [wired] Context Copy/Paste matches the Edit menu.
      Do: Select a shape → context Copy → context Paste.
      Expect: A duplicate appears offset from the original and is selected — identical to Edit▸Copy then Edit▸Paste.
      — last: —

- [ ] **SWCTX-005** [wired] Context Cut then Paste round-trips.
      Do: Select a shape → context Cut → context Paste.
      Expect: The shape disappears on Cut and reappears on Paste; a single Undo restores the pre-Cut state, a second Undo the pre-Paste state (matches keyboard Cut).
      — last: —

- [ ] **SWCTX-006** [wired] Context Delete equals keyboard Delete.
      Do: Select a shape → context Delete. Repeat with a shape that has live references pointing at it.
      Expect: The shape is deleted in one undo step; for a referenced target, the same warn-then-orphan confirm dialog appears as pressing Delete on the keyboard.
      — last: —

- [ ] **SWCTX-007** [wired] Context Select All.
      Do: Context menu ▸ Select All.
      Expect: Every element is selected — identical to Cmd+A.
      — last: —

---

## Session C — render hygiene (culling + repaint scoping)

**P0**

- [ ] **SWREN-001** [wired] No missing/clipped content while panning + zooming.
      Do: At each of ~4 zoom levels (fit, 100%, ~400%, near-max) pan the canvas around a busy area.
      Expect: Every shape that should be visible draws fully; nothing pops in late, blanks out, or shows a hard rectangular seam as it enters the viewport.
      — last: —

- [ ] **SWREN-002** [wired] No artifacts while editing at high zoom.
      Setup: Zoom to ~400% on a shape near the viewport edge.
      Do: Drag it partly off-screen and back; nudge it with arrow keys.
      Expect: The shape and its selection handles/outline render correctly throughout; no stale ghost, no half-drawn stroke, no trail.
      — last: —

- [ ] **SWREN-003** [wired] Elements straddling the viewport edge draw whole.
      Do: Pan so a large stroked shape (thick stroke or arrowhead) is half inside the viewport.
      Expect: The visible half — including the full stroke width and any arrowhead — draws; no clipping short of the true edge.
      — last: —

**P1**

- [ ] **SWREN-004** [wired] Legitimate repaint triggers still repaint.
      Do: In turn — edit a shape from a panel; change selection from the Layers panel; toggle mask isolation; run a menu zoom/fit.
      Expect: The canvas updates immediately for each; nothing requires a nudge (pan/click) to refresh.
      — last: —

- [ ] **SWREN-005** [wired] Panel-only churn does not disturb the canvas.
      Do: Interact with panels that don't change document/view state (open a panel menu, pick a recent color swatch, hover the toolbar).
      Expect: The canvas image is steady — no flicker or full-frame flash from unrelated panel updates. (This is the redundant-repaint the scoping removed; hard to see directly — watch for the absence of flicker.)
      — last: —

- [ ] **SWREN-006** [wired] Appearance / theme switch repaints affected chrome.
      Do: Switch appearance (Dark / Medium / Light Gray).
      Expect: Panels and window chrome retheme immediately. The canvas pasteboard color is theme-independent today, so the canvas body itself need not change — confirm it is not left in a visibly wrong state.
      Pass if: no stale half-themed frame persists.
      — last: —

- [ ] **SWREN-007** [wired] Caret blink is unaffected by the repaint scoping.
      Setup: Type tool active with a text caret showing.
      Do: Watch the caret; then interact with an unrelated panel.
      Expect: The caret keeps blinking at its normal cadence; the repaint gate does not stall or double-trigger it, and unrelated panel activity does not freeze the blink.
      — last: —

---

## Enhancements / follow-ups

- **Scroll-pan on frozen ports** — this is a Swift-only affordance; the Rust
  port keeps its modifier-wheel scheme (`app.rs` on_wheel). No parity expected.
- **Cull scope** — culling is limited to simple geometry leaves (rect / circle /
  ellipse / polyline / polygon / path). Lines with arrowheads, text, textPath,
  and live elements draw unconditionally; extending the cull to text is a future
  perf item once its ink bounds are proven.
- **Theme-aware canvas** — if the canvas body ever reads appearance colors, add
  a theme id to `CanvasRenderSignature` and re-verify SWREN-006.

## Session log

- **2026-07-23 (JYH, trackpad + mouse):** Sessions A/B/C PASS.
  SWNAV-001..005, -007 clean; SWNAV-006 pass-with-note — trackpad
  gestures resolve to pan OR zoom at gesture-begin (standard AppKit
  idiom); interleaved pan-during-pinch banked as polish. Session B all
  green (an early "missing Delete" report was the menu-BAR Edit menu,
  which has no Delete row by shared menubar.yaml design — the context
  menu was to spec all along). Session C surfaced the one real catch:
  the canvas painted OVER the dock panels — macOS 14+ defaults
  clipsToBounds to false and the canvas never clipped; masked
  previously by whole-canvas repaints, unmasked by SH-5's scoped
  invalidation. Fixed (clipsToBounds = true in makeNSView), re-verified
  live same session. Wacom quick-pass deferred to a future session.
