# Color Panel — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/panels/color.yaml`, plus `workspace/dialogs/color_picker.yaml`.
Design doc: `transcripts/COLOR.md`.

Primary platform for manual runs: **Flask (jas_flask)** — most fully wired
panel surface today. Native apps (Rust / Swift / OCaml / Python) covered in
Session M parity sweep with the gaps noted per app.

---

## Known broken

_Last reviewed: 2026-04-19_

- CLR-181 — `invert_active_color` action: handler is a placeholder in the
  native apps. since 2026-04-19. COLOR.md §Pending actions.
- CLR-182 — `complement_active_color` action: handler is a placeholder in the
  native apps. since 2026-04-19. Same source.
- CLR-303 — Per-document `recent_colors` storage not yet persisted in
  Rust / Swift / OCaml / Python. since 2026-04-19. COLOR.md §Panel-to-
  selection wiring status.

---

## Automation coverage

_Last synced: 2026-04-19_

**Flask — `jas_flask/tests/test_renderer.py`** (~8 color-bar widget tests in
`TestColorBar`, plus a full `TestColorPanelSpec` block)
- Color-bar canvas rendering: dimensions, height, cursor placement, id binding.
- Full panel spec: yaml interpretation, mode buttons, swatch rendering.

**Python — `jas/workspace_interpreter/tests/test_state_store.py`** (~44 tests)
- Panel state initialization, mode switching, recent-colors list updates.

**Python — `jas/workspace_interpreter/tests/test_effects.py`** (~36 tests)
- Generic state writes; one color-specific test (`test_set_color`) for
  `fill_color` write.

**Rust — `jas_dioxus/src/panels/color_panel.rs`** (4 unit tests)
- Menu structure: all 5 modes present, Invert + Complement present, dispatch
  handler updates mode, `is_checked` predicate matches active mode. View
  rendering and widget wiring not covered.

**Swift — no dedicated Color panel auto-tests.**
ColorPanel scaffolding present in `JasSwift/Sources/Panels/ColorPanel.swift`
but no tests exercise it. State management covered transitively in
`StateStoreTests.swift`.

**OCaml — no dedicated Color panel auto-tests.**
Color conversion utilities defined (`lib/interpreter/color_util.ml`/`.mli`)
without isolated test coverage; panel transitively exercised by workspace
layout tests.

The manual suite below covers what auto-tests don't: actual widget
rendering, slider drag / commit, hex field validation, color-bar
click/drag, mode-switch UI changes, fill/stroke widget interaction, recent-
colors behavior, modal dialog flow, theming, cross-panel regressions.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_flask` for sessions A–L; per-app for L).
2. Open a default workspace with no document loaded.
3. Open the Color panel via Window → Color (or the default layout's docked
   location).
4. Appearance: **Dark** (`workspace/appearances/`).

Tests that require a non-empty selection use the default setup unless
overridden: Rectangle tool → drag a 200×120 rect → fill default
(`#ff6600`), stroke default (`#000000`).

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

| Session | Topic                               | Est.  | IDs        |
|---------|-------------------------------------|-------|------------|
| A       | Smoke & lifecycle                   | ~5m   | 001–009    |
| B       | Fixed swatches (None/Black/White)   | ~5m   | 010–019    |
| C       | Mode switching                      | ~10m  | 020–049    |
| D       | Sliders per mode                    | ~12m  | 050–099    |
| E       | Hex field                           | ~5m   | 100–119    |
| F       | Color bar                           | ~8m   | 120–139    |
| G       | Fill/Stroke widget                  | ~5m   | 140–159    |
| H       | Recent colors                       | ~8m   | 160–179    |
| I       | Menu — Invert / Complement          | ~5m   | 180–199    |
| J       | Color picker dialog                 | ~12m  | 200–239    |
| K       | None-state gating                   | ~5m   | 240–259    |
| L       | Appearance theming                  | ~5m   | 260–279    |
| M       | Cross-app parity                    | ~15m  | 300–329    |

Full pass: ~100 min. A gates the rest; otherwise sessions stand alone.

---

## Session A — Smoke & lifecycle (~5 min)

If any P0 here fails, stop and flag.

- [ ] **CLR-001** [wired] Panel opens via Window menu.
      Do: Select Window → Color.
      Expect: Color panel appears in dock or floating; no console error.
      — last: —

- [ ] **CLR-002** [wired] All panel rows render without layout collapse.
      Do: Visually scan the open Color panel.
      Expect: Row 1: None + Black + White + 10 recent slots. Row 2:
              fill/stroke widget + 3–4 mode-specific sliders. Row 3: Hex
              input (6 chars). Row 4: 64px color bar. No overlapping
              controls, no truncated labels.
      — last: —

- [ ] **CLR-003** [wired] Panel collapses and re-expands.
      Do: Click the panel header to collapse; click again to expand.
      Expect: Content hides / reveals; header stays visible; no crash.
      — last: —

- [ ] **CLR-004** [wired] Panel closes via context menu / X button.
      Do: Right-click header → Close, or click the close affordance.
      Expect: Panel disappears; Window → Color reopens it.
      — last: —

- [ ] **CLR-005** [wired] Panel floats out of the dock.
      Do: Drag the panel header out of the dock.
      Expect: Panel becomes a floating window at cursor; controls remain
              interactive; returns to dock on drag back.
      — last: —

---

## Session B — Fixed swatches (~5 min)

- [ ] **CLR-010** [wired] None swatch sets active attribute to none.
      Setup: Rectangle selected with fill = `#ff6600`.
      Do: Click `cp_none_swatch`.
      Expect: Rectangle fill renders as none (transparent / outline only);
              SVG attribute reads `fill="none"`.
      — last: —

- [ ] **CLR-011** [wired] None swatch is a no-op when already none.
      Setup: Fill already none.
      Do: Click `cp_none_swatch`.
      Expect: No change; recent-colors list unchanged.
      — last: —

- [ ] **CLR-012** [wired] Black swatch commits #000000.
      Setup: Fill = anything other than black.
      Do: Click `cp_black_swatch`.
      Expect: Fill becomes black; sliders / hex update; black added to recent.
      — last: —

- [ ] **CLR-013** [wired] White swatch commits #ffffff.
      Setup: Fill = anything other than white.
      Do: Click `cp_white_swatch`.
      Expect: Fill becomes white; sliders / hex update; white added to recent.
      — last: —

- [ ] **CLR-014** [wired] Vertical rule renders between fixed and recent.
      Do: Visually inspect.
      Expect: 1px vertical separator between cp_white_swatch and cp_recent_0.
      — last: —

---

## Session C — Mode switching (~10 min)

**P0**

- [ ] **CLR-020** [wired] Default mode is HSB on first panel open.
      Setup: Fresh workspace, panel never opened.
      Do: Open the Color panel.
      Expect: Sliders shown are H / S / B (Hue / Saturation / Brightness).
      — last: —

- [ ] **CLR-021** [wired] Mode menu shows all 5 modes with checkmark on active.
      Do: Open the panel menu.
      Expect: Items Grayscale, RGB, HSB, CMYK, Web Safe RGB; checkmark on
              the currently active mode (HSB by default).
      — last: —

**P1**

- [ ] **CLR-022** [wired] Switching to Grayscale shows K slider only.
      Do: Menu → Grayscale.
      Expect: Slider row collapses to a single K slider 0–100%.
      — last: —

- [ ] **CLR-023** [wired] Switching to RGB shows R / G / B sliders.
      Do: Menu → RGB.
      Expect: Three sliders R / G / B 0–255.
      — last: —

- [ ] **CLR-024** [wired] Switching to HSB shows H / S / B sliders.
      Do: Menu → HSB.
      Expect: Three sliders H 0–359, S 0–100, B 0–100.
      — last: —

- [ ] **CLR-025** [wired] Switching to CMYK shows C / M / Y / K sliders.
      Do: Menu → CMYK.
      Expect: Four sliders C / M / Y / K 0–100.
      — last: —

- [ ] **CLR-026** [wired] Switching to Web Safe RGB shows stepped R / G / B.
      Do: Menu → Web Safe RGB.
      Expect: Three sliders snap to 0 / 51 / 102 / 153 / 204 / 255.
      — last: —

- [ ] **CLR-027** [wired] Mode switch preserves the underlying color.
      Setup: Fill = `#ff6600` in HSB mode (H=24, S=100, B=100).
      Do: Switch to RGB.
      Expect: Sliders show R=255, G=102, B=0; canvas fill unchanged.
      — last: —

**P2**

- [ ] **CLR-028** [wired] Mode is panel-local; not persisted across reopens.
      Setup: Active mode = CMYK.
      Do: Close the Color panel; reopen it.
      Expect: Mode resets to default (HSB) or re-derives from active color
              per the §Panel initialization rule. Document state unchanged.
      — last: —

- [ ] **CLR-029** [wired] Switching modes does not write the document.
      Setup: Fill = `#ff6600`.
      Do: Cycle through every mode.
      Expect: Document fill attribute remains `#ff6600` throughout.
      — last: —

---

## Session D — Sliders per mode (~12 min)

**P1**

- [ ] **CLR-050** [wired] Drag H slider updates hue continuously.
      Setup: HSB mode, fill = `#ff0000` (H=0, S=100, B=100).
      Do: Drag H slider to 120.
      Expect: Fill animates from red to green; final fill = `#00ff00`;
              recent-colors gets `#00ff00` on pointer-up.
      — last: —

- [ ] **CLR-051** [wired] H slider bounds are 0–359.
      Do: Drag H past either end.
      Expect: Clamps to 0 / 359; no wraparound.
      — last: —

- [ ] **CLR-052** [wired] S slider 0 → 100 desaturates / saturates.
      Setup: HSB mode, H=120, S=100, B=100.
      Do: Drag S to 0.
      Expect: Fill becomes white-ish (B=100, S=0 → white); back to green at
              S=100.
      — last: —

- [ ] **CLR-053** [wired] B slider 0 → 100 darkens / lightens.
      Setup: HSB mode, H=120, S=100, B=100.
      Do: Drag B to 0.
      Expect: Fill becomes black; back to bright green at B=100.
      — last: —

- [ ] **CLR-054** [wired] R slider in RGB mode.
      Setup: RGB mode, fill = `#000000`.
      Do: Drag R to 255.
      Expect: Fill becomes red `#ff0000`.
      — last: —

- [ ] **CLR-055** [wired] G slider in RGB mode.
      Do: Drag G to 255.
      Expect: Channel updates; fill turns green / yellow per other channels.
      — last: —

- [ ] **CLR-056** [wired] B slider in RGB mode.
      Do: Drag B to 255.
      Expect: Channel updates; fill turns blue / cyan / etc.
      — last: —

- [ ] **CLR-057** [wired] CMYK K slider darkens.
      Setup: CMYK mode, C=0, M=0, Y=0, K=0 (white).
      Do: Drag K to 100.
      Expect: Fill becomes black `#000000`.
      — last: —

- [ ] **CLR-058** [wired] CMYK C / M / Y sliders mix subtractive primaries.
      Setup: CMYK mode, K=0.
      Do: Drag C=100.
      Expect: Fill becomes cyan-ish; combine with M=100 → blue, Y=100 →
              green, etc.
      — last: —

- [ ] **CLR-059** [wired] Grayscale K slider produces gray ramp.
      Setup: Grayscale mode, K=0.
      Do: Drag K to 50.
      Expect: Fill becomes mid-gray `#808080` (within 1 unit).
      — last: —

- [ ] **CLR-060** [wired] Web Safe R/G/B sliders snap to nearest step of 51.
      Setup: Web Safe RGB mode, fill = `#7f7f7f` (mid-gray, not a web step).
      Do: Drag R slightly.
      Expect: R snaps to nearest of 0/51/102/153/204/255; visible as a jump.
      — last: —

**P2**

- [ ] **CLR-070** [wired] Slider commit is on pointer-up, not on every drag tick.
      Setup: Fill = arbitrary color.
      Do: Drag a slider continuously without releasing.
      Expect: Recent-colors list does NOT add an entry on every tick; only
              on pointer-up.
      — last: —

- [ ] **CLR-071** [wired] Sliders disabled when active attribute is none.
      Setup: Fill = none.
      Expect: All slider row controls render dimmed / non-interactive.
      — last: —

- [ ] **CLR-072** [wired] Numeric value box edits commit on Enter / Tab.
      Setup: HSB mode, focus on H value box.
      Do: Type "180" + Enter.
      Expect: H slider jumps to 180; fill turns cyan; recent-colors entry
              added.
      — last: —

- [ ] **CLR-073** [wired] Out-of-range numeric input is clamped.
      Do: Type "500" into a 0–255 channel.
      Expect: Clamps to 255 (or rejects); no crash.
      — last: —

---

## Session E — Hex field (~5 min)

- [ ] **CLR-100** [wired] Hex shows current fill on selection.
      Setup: Fill = `#ff6600`.
      Expect: `cp_hex` shows `ff6600` (no `#` per yaml description).
      — last: —

- [ ] **CLR-101** [wired] Typing valid 6-char hex commits on Enter.
      Setup: Selection with fill.
      Do: Click into hex field, type "00ff00", press Enter.
      Expect: Fill becomes `#00ff00`; sliders update; recent-colors gets
              `#00ff00`.
      — last: —

- [ ] **CLR-102** [wired] Tab away from hex field commits.
      Do: Type "0000ff", press Tab.
      Expect: Same behavior as Enter — commit and recent-colors update.
      — last: —

- [ ] **CLR-103** [wired] Non-hex characters rejected.
      Do: Type "ZZZZZZ" into the hex field.
      Expect: Field rejects input or commit fails silently; fill unchanged.
      — last: —

- [ ] **CLR-104** [wired] Short hex (< 6 chars) on commit reverts or pads.
      Do: Type "ff", press Enter.
      Expect: Either reverts to previous value or pads with zeros to
              `ff0000`. Either is acceptable; document the actual behavior.
      — last: —

- [ ] **CLR-105** [wired] Web Safe mode snaps hex to nearest web-safe.
      Setup: Web Safe RGB mode, fill = anything.
      Do: Type "abcdef", Enter.
      Expect: Fill snaps to nearest web-safe color (multiples of 51 per
              channel), e.g. `99ccff`.
      — last: —

- [ ] **CLR-106** [wired] Hex disabled when fill is none.
      Setup: Fill = none.
      Expect: Hex input dimmed / non-interactive.
      — last: —

---

## Session F — Color bar (~8 min)

- [ ] **CLR-120** [wired] Color bar renders 64px tall.
      Do: Visually inspect.
      Expect: 2D gradient fills the row at 64px height; hue runs left → right
              (red → yellow → green → cyan → blue → magenta → red).
      — last: —

- [ ] **CLR-121** [wired] Top half ramps S 0 → 100, B 100 → 80.
      Do: Click center-top of bar.
      Expect: Resulting color is mid-light, mid-saturation hue at click x.
      — last: —

- [ ] **CLR-122** [wired] Bottom half ramps B 80 → 0 at full saturation.
      Do: Click center-bottom of bar.
      Expect: Resulting color is dark, fully saturated hue at click x.
      — last: —

- [ ] **CLR-123** [wired] Click commits on pointer-up.
      Do: Click+release a single point on the color bar.
      Expect: Fill updates; recent-colors gets an entry.
      — last: —

- [ ] **CLR-124** [wired] Drag updates fill in real time.
      Do: Press and drag horizontally across the color bar.
      Expect: Fill cycles through hues live; one recent-colors entry on
              pointer-up.
      — last: —

- [ ] **CLR-125** [wired] Click outside bar bounds doesn't crash.
      Do: Press inside, drag outside the bar's vertical range, release.
      Expect: Behavior clamps to bar bounds; no crash; one or zero recent
              entries (define expected).
      — last: —

- [ ] **CLR-126** [wired] Color bar disabled when fill is none.
      Setup: Fill = none.
      Expect: Bar renders dimmed; click is a no-op (or auto-un-nones — pick
              actual behavior).
      — last: —

---

## Session G — Fill/Stroke widget (~5 min)

- [ ] **CLR-140** [wired] Fill/Stroke widget renders 48px with both swatches.
      Do: Visually inspect.
      Expect: Two overlapping color swatches (fill on top by default), plus
              a swap affordance and a reset (default-colors) affordance.
      — last: —

- [ ] **CLR-141** [wired] Clicking the fill swatch makes fill the active target.
      Setup: Stroke target active.
      Do: Click the fill swatch in the widget.
      Expect: Sliders / hex / color bar now reflect the fill color; future
              edits write to fill.
      — last: —

- [ ] **CLR-142** [wired] Clicking the stroke swatch makes stroke the active target.
      Setup: Fill target active.
      Do: Click the stroke swatch.
      Expect: Sliders / hex / color bar now reflect stroke; edits write to
              stroke.
      — last: —

- [ ] **CLR-143** [wired] Swap exchanges fill and stroke.
      Setup: Fill = `#ff0000`, stroke = `#000000`.
      Do: Click swap.
      Expect: Fill = `#000000`, stroke = `#ff0000`.
      — last: —

- [ ] **CLR-144** [wired] Reset returns to default fill / stroke (`#000000` / `none` or workspace defaults).
      Setup: Fill / stroke set to non-defaults.
      Do: Click reset.
      Expect: Fill returns to default black, stroke to default none (or
              workspace-defined defaults; document).
      — last: —

- [ ] **CLR-145** [wired] Single click only — no double-click picker launch.
      Do: Double-click the fill swatch quickly.
      Expect: Two single-click events register (target switch + target
              switch); no modal color picker dialog opens.
      — last: —

---

## Session H — Recent colors (~8 min)

- [ ] **CLR-160** [wired] Recent slots render as 10 squares left-to-right.
      Do: Open a fresh workspace; observe `cp_recent_0` … `cp_recent_9`.
      Expect: 10 16px squares; empty ones render as hollow with solid borders.
      — last: —

- [ ] **CLR-161** [wired] Empty recent slots are non-interactive.
      Setup: Fresh workspace, no recent colors yet.
      Do: Click an empty `cp_recent_N`.
      Expect: No-op; cursor doesn't change to a click affordance.
      — last: —

- [ ] **CLR-162** [wired] First commit lands in `cp_recent_0`.
      Setup: Empty recent list.
      Do: Type `00ff00` + Enter into hex.
      Expect: `cp_recent_0` now shows green; rest still empty.
      — last: —

- [ ] **CLR-163** [wired] Newest entries push older ones rightward.
      Setup: Recent slot 0 = green.
      Do: Type `0000ff` + Enter.
      Expect: Slot 0 = blue, slot 1 = green; rest empty.
      — last: —

- [ ] **CLR-164** [wired] Clicking a recent swatch commits it as the active color.
      Setup: Slot 0 = `#0000ff`.
      Do: Click `cp_recent_0`.
      Expect: Active fill becomes `#0000ff`; sliders / hex update; slot 0
              stays where it is (already at front).
      — last: —

- [ ] **CLR-165** [wired] Duplicate color moves to front, doesn't duplicate.
      Setup: Recent list = [red, blue, green].
      Do: Type `00ff00` + Enter (re-commit green).
      Expect: List becomes [green, red, blue] — only one green entry.
      — last: —

- [ ] **CLR-166** [wired] Recent list caps at 10 entries.
      Setup: Recent list at 10 distinct colors.
      Do: Commit an 11th distinct color.
      Expect: New color enters at slot 0; oldest (slot 9) falls off.
      — last: —

- [ ] **CLR-167** [wired] None / Black / White swatch commits also enter recent.
      Setup: Empty recent list.
      Do: Click Black.
      Expect: `cp_recent_0` = black.
      — last: —

- [ ] **CLR-168** [wired] Recent list is per-document.
      Setup: Document A with recent [red, green]; create new document B.
      Expect: In document B the recent slots are empty.
      Switch back to document A: recents return.
      — last: —
      Note: CLR-303 — native apps may not yet persist recents per document;
            document divergence here.

---

## Session I — Menu — Invert / Complement (~5 min)

- [ ] **CLR-180** [wired] Menu shows Invert + Complement entries.
      Do: Open the panel menu.
      Expect: After the modes block (separator), Invert and Complement.
      — last: —

- [ ] **CLR-181** [known-broken: native handler placeholder] Invert flips
      every channel.
      Setup: Fill = `#ff0000` (255, 0, 0).
      Do: Menu → Invert.
      Expect: Fill becomes `#00ffff` (cyan, channel-wise 255−R/G/B); recent
              gets cyan. (Currently a no-op in the native apps — documented
              as known-broken.)
      — last: —

- [ ] **CLR-182** [known-broken: native handler placeholder] Complement
      rotates hue 180°.
      Setup: Fill = `#ff0000` (H=0, S=100, B=100).
      Do: Menu → Complement.
      Expect: Fill becomes `#00ffff` (H=180); recent gets cyan.
      — last: —

- [ ] **CLR-183** [wired] Invert / Complement disabled when fill is none.
      Setup: Fill = none.
      Expect: Menu items dimmed.
      — last: —

- [ ] **CLR-184** [wired] Complement on grayscale (S=0) is a no-op.
      Setup: Fill = `#808080` (S=0).
      Do: Menu → Complement.
      Expect: No change; complement of zero-sat is itself.
      — last: —

---

## Session J — Color picker dialog (~12 min)

**P0**

- [ ] **CLR-200** [wired] Dialog opens (when wired) and shows the full layout.
      Do: Wherever the picker is launched (per spec — placeholder action in
          panel, may be triggered via swatch double-click on some platforms).
      Expect: Modal dialog with eyedropper, large 2D gradient, vertical hue
              bar, "Only Web Colors" toggle, 50×50 preview swatch,
              HSB / RGB radio + numeric rows, Hex field, read-only CMYK
              display, OK + Cancel + Color Swatches buttons.
      — last: —

- [ ] **CLR-201** [wired] Cancel closes without committing.
      Setup: Dialog open, fields edited.
      Do: Click Cancel.
      Expect: Dialog closes; target attribute unchanged.
      — last: —

**P1**

- [ ] **CLR-210** [wired] Click in the 2D gradient updates two channel values.
      Setup: HSB H selected as the colorbar axis (default radio).
      Do: Click in the gradient.
      Expect: S + B move to the click position; preview swatch updates;
              numeric H/S/B fields and Hex update.
      — last: —

- [ ] **CLR-211** [wired] Drag in the gradient tracks live.
      Do: Press and drag inside the gradient.
      Expect: Preview swatch follows pointer; circle indicator follows; no
              commit until OK.
      — last: —

- [ ] **CLR-212** [wired] Drag the hue bar updates hue.
      Do: Drag the vertical hue bar.
      Expect: Gradient body re-tints to new hue; preview updates; numeric H
              updates.
      — last: —

- [ ] **CLR-213** [wired] Radio button selects which channel maps to the bar.
      Setup: Default is H.
      Do: Click the R radio.
      Expect: Vertical bar becomes a red ramp 0–255; gradient axes rebind
              to G (x) and B (y); preview unchanged.
      — last: —

- [ ] **CLR-214** [wired] Hex field commits on Enter inside the dialog.
      Do: Type `ff00ff` into the dialog Hex field; press Enter.
      Expect: Preview becomes magenta; numeric H/S/B and R/G/B update;
              CMYK readout updates.
      — last: —

- [ ] **CLR-215** [wired] Only Web Colors toggle snaps current value.
      Setup: Picker showing color `#abcdef`.
      Do: Toggle "Only Web Colors" on.
      Expect: Color snaps to nearest web-safe value (e.g. `99ccff`); fields
              update accordingly.
      — last: —

- [ ] **CLR-216** [wired] Eyedropper button activates canvas sampling.
      Do: Click the eyedropper.
      Expect: Cursor changes to crosshair / eyedropper; clicking a point on
              the canvas adopts that pixel's color into the picker.
      — last: —

- [ ] **CLR-217** [wired] CMYK fields are read-only.
      Do: Try to type into a CMYK field.
      Expect: Field rejects edits; values change only when the underlying
              color changes.
      — last: —

- [ ] **CLR-218** [wired] OK applies to the target (fill or stroke).
      Setup: Picker opened with `target=fill`.
      Do: Pick a color; click OK.
      Expect: Selection's fill becomes the picked color; stroke unchanged;
              dialog closes; recent-colors gets the entry.
      — last: —

**P2**

- [ ] **CLR-230** [wired] OK with `target=stroke` writes stroke.
      Setup: Picker opened with `target=stroke`.
      Do: Pick a color; click OK.
      Expect: Selection's stroke becomes the picked color; fill unchanged.
      — last: —

- [ ] **CLR-231** [wired] Color Swatches button is disabled (placeholder).
      Do: Inspect the Color Swatches button.
      Expect: Renders dimmed / non-interactive (per yaml placeholder).
      — last: —

---

## Session K — None-state gating (~5 min)

- [ ] **CLR-240** [wired] Sliders dim when active attribute is none.
      Setup: Fill = none.
      Expect: All slider controls in the current mode render dimmed / non-
              interactive.
      — last: —

- [ ] **CLR-241** [wired] Hex dims when none.
      Setup: Fill = none.
      Expect: Hex input dimmed.
      — last: —

- [ ] **CLR-242** [wired] Color bar dims when none.
      Setup: Fill = none.
      Expect: Color bar dimmed; click does not commit (or auto-un-nones —
              document the actual behavior).
      — last: —

- [ ] **CLR-243** [wired] Fixed swatches stay clickable when none.
      Setup: Fill = none.
      Expect: None / Black / White / recent swatches all clickable.
      — last: —

- [ ] **CLR-244** [wired] Clicking Black / White / recent un-nones the attribute.
      Setup: Fill = none.
      Do: Click White.
      Expect: Fill becomes `#ffffff`; sliders / hex / bar re-enable.
      — last: —

---

## Session L — Appearance theming (~5 min)

- [ ] **CLR-260** [wired] Dark appearance: readable contrast on all controls.
      Setup: Dark appearance active.
      Expect: Slider tracks visible; swatch borders distinguishable from
              panel bg; hex text legible; menu glyphs visible.
      — last: —

- [ ] **CLR-261** [wired] Medium Gray appearance mirrors Dark.
      Do: Switch appearance → Medium Gray.
      Expect: Panel re-skins with Medium-Gray tokens; everything readable;
              no Dark hardcoded colors leak through.
      — last: —

- [ ] **CLR-262** [wired] Light Gray appearance mirrors Dark.
      Do: Switch to Light Gray.
      Expect: Same as above; black / white swatches readable against the
              new bg.
      — last: —

- [ ] **CLR-263** [wired] Active mode menu checkmark visible in every appearance.
      Do: In each appearance, open the panel menu.
      Expect: Checkmark on the active mode is visually distinct from the
              other modes.
      — last: —

---

## Session M — Cross-app parity (~15 min)

~5–8 load-bearing `[wired]` tests for behaviors where cross-language drift
produces user-visible bugs. Batch by app: run a full column at a time.

- **CLR-300** [wired] Hex `00ff00` Enter commits green to the active selection.
      Do: Active selection's fill = anything. Type `00ff00` + Enter.
      Expect: Fill becomes `#00ff00`.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [x] Flask      last: 2026-04-27  · note: surfaced + fixed: the generic panel-input listener parseFloat'd every keystroke into the hex field, immediately overwriting it via updateBindings — text inputs now skip that path and commit only via the dedicated keydown-Enter handler.

- **CLR-301** [wired] Mode switch from HSB → RGB preserves the underlying color.
      Do: HSB → set fill `#ff6600` → menu RGB.
      Expect: Sliders show R=255, G=102, B=0; canvas fill unchanged.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [x] Flask      last: 2026-04-27

- **CLR-302** [wired] None swatch sets `fill="none"` on selection.
      Do: Selection with explicit fill → click `cp_none_swatch`.
      Expect: Document SVG attribute reads `fill="none"`.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [x] Flask      last: 2026-04-27

- **CLR-303** [wired] Recent-colors list grows on commit, dedupes to front.
      Do: Commit `#ff0000`, `#00ff00`, `#ff0000` in that order.
      Expect: Recent list = [red, green]; red moved to front (no
              duplicate).
      - [ ] Rust       last: — (per CLR-303 known-broken: per-doc storage
              not yet wired)
      - [ ] Swift      last: — (same)
      - [ ] OCaml      last: — (same)
      - [ ] Python     last: — (same)
      - [x] Flask      last: 2026-04-27  · note: passes on Flask while natives are still known-broken (per-doc storage not yet wired there).

- **CLR-304** [wired] Color bar click commits a color from the gradient.
      Do: Click the rightmost-top of the color bar.
      Expect: Fill becomes a magenta-ish color (high hue, top-half S/B
              ramp).
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [x] Flask      last: 2026-04-27

- **CLR-305** [wired] Web Safe RGB mode snaps a non-web hex on commit.
      Do: Web Safe RGB mode → type `abcdef` + Enter into hex.
      Expect: Fill snaps to nearest web-safe color (channels in
              0/51/102/153/204/255).
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [x] Flask      last: 2026-04-27  · note: surfaced + fixed: hex-Enter handler always took the typed value verbatim — now snaps when panelState.mode is web_safe_rgb. Also added a Flask-specific QoL: switching mode to web_safe_rgb snaps the current fill/stroke colors so off-grid leftovers don't survive the view change.

- **CLR-306** [wired] Fill/Stroke widget swap exchanges values.
      Setup: Fill = `#ff0000`, stroke = `#000000`.
      Do: Click swap.
      Expect: Fill = `#000000`, stroke = `#ff0000`.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [x] Flask      last: 2026-04-27

---

## Graveyard

_No retired or won't-fix tests yet._

---

## Enhancements

_No non-blocking follow-ups raised yet. Manual testing surfaces ideas here
with `ENH-NNN` prefix and italicized trailer noting the test + date._
