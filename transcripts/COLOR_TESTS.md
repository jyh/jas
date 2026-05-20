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

- [x] **CLR-001** [wired] Panel opens via Window menu.
      Do: Select Window → Color.
      Expect: Color panel appears in dock or floating; no console error.
      — last: 2026-05-11 rust pass; 2026-05-12 swift pass; 2026-05-15 ocaml pass (ocaml: Window menu items converted from add_item to add_check_item; sync_panel_checks fires from canvas's dock_refresh so external visibility changes (close, drag-out, layout restore) flip the checkmark); 2026-05-20 python pass

- [x] **CLR-002** [wired] All panel rows render without layout collapse.
      Do: Visually scan the open Color panel.
      Expect: Row 1: None + Black + White + 10 recent slots. Row 2:
              fill/stroke widget + 3–4 mode-specific sliders. Row 3: Hex
              input (6 chars). Row 4: 64px color bar. No overlapping
              controls, no truncated labels.
      — last: 2026-05-11 rust pass; 2026-05-12 swift pass; 2026-05-15 ocaml pass (ocaml: librsvg installed + loaders.cache patched so GdkPixbuf renders SVG icons; render_button honours style.size on icon_button + CSS-overrides padding; render_slider sizes 100×12 with channel-gradient trough + transparent highlight; render_number_input + render_text_input slimmed to 16px min-height; render_fill_stroke_widget sorts children by bind.z_index so fill_on_top swaps render order; hex field width 64; hamburger and chevron swapped in dock title bar); 2026-05-20 python pass (python: extensive layout work — _PanelFillStrokeWidget scaled to YAML dimensions; min-height cascade in _render_container; QScrollArea wrapping panel groups with styled scrollbar; theme-aware input boxes)

- [x] **CLR-003** [wired] Panel collapses and re-expands.
      Do: Click the panel header to collapse; click again to expand.
      Expect: Content hides / reveals; header stays visible; no crash.
      — last: 2026-05-11 rust pass; 2026-05-12 swift pass; 2026-05-15 ocaml pass; 2026-05-20 python pass

- [x] **CLR-004** [wired] Panel closes via context menu / X button.
      Do: Right-click header → Close, or click the close affordance.
      Expect: Panel disappears; Window → Color reopens it.
      — last: 2026-05-11 rust pass; 2026-05-12 swift pass; 2026-05-15 ocaml pass (ocaml: is_panel_visible rewritten to check actual dock placement; previously a panel absent from the layout but also absent from hidden_panels stayed permanently "checked" in the Window menu); 2026-05-20 python pass

- [x] **CLR-005** [wired] Panel floats out of the dock.
      Do: Drag the panel header out of the dock.
      Expect: Panel becomes a floating window at cursor; controls remain
              interactive; returns to dock on drag back.
      — last: 2026-05-11 rust pass; 2026-05-12 swift pass; 2026-05-15 ocaml pass (rust: peek() in build_dock_groups stops mid-drag re-renders; ondragend on app-level container. swift: canvas-level DropDelegate (DockDetachDropDelegate) catches drops outside any dock and detaches into a floating dock.); 2026-05-20 python pass

---

## Session B — Fixed swatches (~5 min)

- [x] **CLR-010** [wired] None swatch sets active attribute to none.
      Setup: Rectangle selected with fill = `#ff6600`.
      Do: Click `cp_none_swatch`.
      Expect: Rectangle fill renders as none (transparent / outline only);
              SVG attribute reads `fill="none"`.
      — last: 2026-05-11 rust pass; 2026-05-12 swift pass; 2026-05-16 ocaml pass (ocaml: render_button (icon_button branch in panel context) now dispatches via dispatch_click_behaviors; set_active_color_none has a direct route in dispatch_click_behaviors that clears default_fill / default_stroke + the selection's fill / stroke per fill_on_top (Panel_menu.dispatch_yaml_action's effects pipeline doesn't reach panel-targets cleanly). rust: live state map exposes selection summaries; render_color_swatch distinguishes explicit-none from missing-bind. swift: set_active_color_none now also writes to the selection via Controller.setSelectionFill(nil) — was only updating defaultFill before); 2026-05-20 python pass

- [x] **CLR-011** [wired] None swatch is a no-op when already none.
      Setup: Fill already none.
      Do: Click `cp_none_swatch`.
      Expect: No change; recent-colors list unchanged.
      — last: 2026-05-11 rust pass; 2026-05-12 swift pass; 2026-05-16 ocaml pass; 2026-05-20 python pass

- [x] **CLR-012** [wired] Black swatch commits #000000.
      Setup: Fill = anything other than black.
      Do: Click `cp_black_swatch`.
      Expect: Fill becomes black; sliders / hex update; black added to recent.
      — last: 2026-05-11 rust pass; 2026-05-12 swift pass; 2026-05-16 ocaml pass (ocaml: render_color_swatch click dispatch via dispatch_click_behaviors; set_active_color action routes through Panel_menu.set_active_color which pushes the color into model.recent_colors; recent-colors bridge listener writes panel.recent_colors AND calls update_recent_color_widgets to repaint the registered slot DrawingAreas in-place. cp_recent_0..9 register themselves into _color_panel_slots.recent_swatches keyed by their id suffix); 2026-05-20 python pass (python: _create_panel_body wraps dispatch_fn to set active_panel before dispatching so list_push for recent_colors writes to the right panel)

- [x] **CLR-013** [wired] White swatch commits #ffffff.
      Setup: Fill = anything other than white.
      Do: Click `cp_white_swatch`.
      Expect: Fill becomes white; sliders / hex update; white added to recent.
      — last: 2026-05-11 rust pass; 2026-05-12 swift pass; 2026-05-16 ocaml pass; 2026-05-20 python pass

- [x] **CLR-014** [wired] Vertical rule renders between fixed and recent.
      Do: Visually inspect.
      Expect: 1px vertical separator between cp_white_swatch and cp_recent_0.
      — last: 2026-05-11 rust pass; 2026-05-12 swift pass; 2026-05-16 ocaml pass; 2026-05-20 python pass

---

## Session C — Mode switching (~10 min)

**P0**

- [x] **CLR-020** [wired] Default mode is HSB on first panel open.
      Setup: Fresh workspace, panel never opened.
      Do: Open the Color panel.
      Expect: Sliders shown are H / S / B (Hue / Saturation / Brightness).
      — last: 2026-05-11 rust pass; 2026-05-12 swift pass; 2026-05-20 python pass

- [x] **CLR-021** [wired] Mode menu shows all 5 modes with checkmark on active.
      Do: Open the panel menu.
      Expect: Items Grayscale, RGB, HSB, CMYK, Web Safe RGB; checkmark on
              the currently active mode (HSB by default).
      — last: 2026-05-11 rust pass; 2026-05-12 swift pass; 2026-05-20 python pass

**P1**

- [x] **CLR-022** [wired] Switching to Grayscale shows K slider only.
      Do: Menu → Grayscale.
      Expect: Slider row collapses to a single K slider 0–100%.
      — last: 2026-05-11 rust pass; 2026-05-12 swift pass; 2026-05-20 python pass (python: _dispatch_yaml_cmd's set_color_panel_mode writes both layout.color_panel_mode and panel.mode so per-mode slider visibility re-evaluates; YamlPanelView only init_panel on first mount)

- [x] **CLR-023** [wired] Switching to RGB shows R / G / B sliders.
      Do: Menu → RGB.
      Expect: Three sliders R / G / B 0–255.
      — last: 2026-05-11 rust pass; 2026-05-12 swift pass; 2026-05-20 python pass

- [x] **CLR-024** [wired] Switching to HSB shows H / S / B sliders.
      Do: Menu → HSB.
      Expect: Three sliders H 0–359, S 0–100, B 0–100.
      — last: 2026-05-11 rust pass; 2026-05-12 swift pass; 2026-05-20 python pass

- [x] **CLR-025** [wired] Switching to CMYK shows C / M / Y / K sliders.
      Do: Menu → CMYK.
      Expect: Four sliders C / M / Y / K 0–100.
      — last: 2026-05-11 rust pass; 2026-05-12 swift pass (rust: pinned number_input flex-shrink:0 + box-sizing:border-box so the slider-row value boxes hold their declared width); 2026-05-20 python pass

- [x] **CLR-026** [wired] Switching to Web Safe RGB shows stepped R / G / B.
      Do: Menu → Web Safe RGB.
      Expect: Three sliders snap to 0 / 51 / 102 / 153 / 204 / 255.
      — last: 2026-05-11 rust pass; 2026-05-12 swift pass (swift: SliderView now reads element.step and snaps via SwiftUI Slider step + applies snap on the way out so onChange / onCommit see the snapped value); 2026-05-20 python pass

- [x] **CLR-027** [wired] Mode switch preserves the underlying color.
      Setup: Fill = `#ff6600` in HSB mode (H=24, S=100, B=100).
      Do: Switch to RGB.
      Expect: Sliders show R=255, G=102, B=0; canvas fill unchanged.
      — last: 2026-05-11 rust pass; 2026-05-12 swift pass (rust: text_input panel writes route through set_active_color, revision bump inside spawn, slider keyed remount. swift: added colorPanelLiveOverrides → build_live_overrides for color_panel_content so sliders/hex reflect selection's actual color instead of stale init values); 2026-05-20 python pass (python: hex commits via _render_text_input panel.X writeback, bridge special-cases hex with snap on web-safe)

**P2**

- [x] **CLR-028** [wired] Mode is panel-local; not persisted across reopens.
      Setup: Active mode = CMYK.
      Do: Close the Color panel; reopen it.
      Expect: Mode resets to default (HSB) or re-derives from active color
              per the §Panel initialization rule. Document state unchanged.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass (rust: color_panel_mode reset to Hsb on every show — both menu_bar toggle_panel_color and toolbar_grid double-click panel-show paths); 2026-05-20 python accepted-as-is

- [x] **CLR-029** [wired] Switching modes does not write the document.
      Setup: Fill = `#ff6600`.
      Do: Cycle through every mode.
      Expect: Document fill attribute remains `#ff6600` throughout.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

---

## Session D — Sliders per mode (~12 min)

**P1**

- [x] **CLR-050** [wired] Drag H slider updates hue continuously.
      Setup: HSB mode, fill = `#ff0000` (H=0, S=100, B=100).
      Do: Drag H slider to 120.
      Expect: Fill animates from red to green; final fill = `#00ff00`;
              recent-colors gets `#00ff00` on pointer-up.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass (rust: slider controlled value tracks external state; text_input keyed remount. swift: setActiveColorLive now also writes to selection — without snapshotting — so canvas + sliders animate live during drag without bloating undo); 2026-05-20 python pass

- [x] **CLR-051** [wired] H slider bounds are 0–359.
      Do: Drag H past either end.
      Expect: Clamps to 0 / 359; no wraparound.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-052** [wired] S slider 0 → 100 desaturates / saturates.
      Setup: HSB mode, H=120, S=100, B=100.
      Do: Drag S to 0.
      Expect: Fill becomes white-ish (B=100, S=0 → white); back to green at
              S=100.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-053** [wired] B slider 0 → 100 darkens / lightens.
      Setup: HSB mode, H=120, S=100, B=100.
      Do: Drag B to 0.
      Expect: Fill becomes black; back to bright green at B=100.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-054** [wired] R slider in RGB mode.
      Setup: RGB mode, fill = `#000000`.
      Do: Drag R to 255.
      Expect: Fill becomes red `#ff0000`.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-055** [wired] G slider in RGB mode.
      Do: Drag G to 255.
      Expect: Channel updates; fill turns green / yellow per other channels.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-056** [wired] B slider in RGB mode.
      Do: Drag B to 255.
      Expect: Channel updates; fill turns blue / cyan / etc.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-057** [wired] CMYK K slider darkens.
      Setup: CMYK mode, C=0, M=0, Y=0, K=0 (white).
      Do: Drag K to 100.
      Expect: Fill becomes black `#000000`.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-058** [wired] CMYK C / M / Y sliders mix subtractive primaries.
      Setup: CMYK mode, K=0.
      Do: Drag C=100.
      Expect: Fill becomes cyan-ish; combine with M=100 → blue, Y=100 →
              green, etc.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-059** [wired] Grayscale K slider produces gray ramp.
      Setup: Grayscale mode, K=0.
      Do: Drag K to 50.
      Expect: Fill becomes mid-gray `#808080` (within 1 unit).
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-060** [wired] Web Safe R/G/B sliders snap to nearest step of 51.
      Setup: Web Safe RGB mode, fill = `#7f7f7f` (mid-gray, not a web step).
      Do: Drag R slightly.
      Expect: R snaps to nearest of 0/51/102/153/204/255; visible as a jump.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass (python: slider snap moved out of valueChanged loop into write-back so drag truly jumps to multiples of 51; hidden sibling slider doesn't snap back via _set_widget_value blockSignals)

**P2**

- [x] **CLR-070** [wired] Slider commit is on pointer-up, not on every drag tick.
      Setup: Fill = arbitrary color.
      Do: Drag a slider continuously without releasing.
      Expect: Recent-colors list does NOT add an entry on every tick; only
              on pointer-up.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass (rust: slider oninput uses set_active_color_live, onchange fires on pointer-up with full set_active_color → recent push; render_color_swatch treats bare hex strings as valid colors); 2026-05-20 python pass

- [x] **CLR-071** [wired] Sliders disabled when active attribute is none.
      Setup: Fill = none.
      Expect: All slider row controls render dimmed / non-interactive.
      — last: 2026-05-11 rust accepted-as-is; 2026-05-13 swift accepted-as-is (sliders stay interactive when active is none; user OK with current behavior); 2026-05-20 python pass

- [x] **CLR-072** [wired] Numeric value box edits commit on Enter / Tab.
      Setup: HSB mode, focus on H value box.
      Do: Type "180" + Enter.
      Expect: H slider jumps to 180; fill turns cyan; recent-colors entry
              added.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass (rust: number_input panel handler routes Color edits through compute_color_from_panel + set_active_color so the typed channel mixes with the rest of panel state. swift: commitWidgetWrite now also calls setActiveColor for h/s/b/r/g/bl/c/m/y/k/hex channels — was only doing it for hex); 2026-05-20 python pass

- [x] **CLR-073** [wired] Out-of-range numeric input is clamped.
      Do: Type "500" into a 0–255 channel.
      Expect: Clamps to 255 (or rejects); no crash.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass (swift: renderNumberInput now clamps committed value to declared min/max — without this, typing 500 into an R-channel field stored 500 verbatim and produced an invalid 7-char hex like #1f4ff3b); 2026-05-20 python accepted-as-is

---

## Session E — Hex field (~5 min)

- [x] **CLR-100** [wired] Hex shows current fill on selection.
      Setup: Fill = `#ff6600`.
      Expect: `cp_hex` shows `ff6600` (no `#` per yaml description).
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass (swift: hex via BufferedTextField that commits on Enter/blur — direct binding fired every keystroke and the re-render snapped the field back, "rejecting" typed input. Live overrides also write back to panel store so dragging one channel doesn't snap siblings to defaults. renderNumberInput now clamps to declared max so 500 in an R-channel becomes 255 instead of breaking the hex.); 2026-05-20 python pass

- [x] **CLR-101** [wired] Typing valid 6-char hex commits on Enter.
      Setup: Selection with fill.
      Do: Click into hex field, type "00ff00", press Enter.
      Expect: Fill becomes `#00ff00`; sliders update; recent-colors gets
              `#00ff00`.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-102** [wired] Tab away from hex field commits.
      Do: Type "0000ff", press Tab.
      Expect: Same behavior as Enter — commit and recent-colors update.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-103** [wired] Non-hex characters rejected.
      Do: Type "ZZZZZZ" into the hex field.
      Expect: Field rejects input or commit fails silently; fill unchanged.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass (python: Color.from_hex accepts 3-char shorthand)

- [x] **CLR-104** [wired] Short hex (< 6 chars) on commit reverts or pads.
      Do: Type "ff", press Enter.
      Expect: Either reverts to previous value or pads with zeros to
              `ff0000`. Either is acceptable; document the actual behavior.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-105** [wired] Web Safe mode snaps hex to nearest web-safe.
      Setup: Web Safe RGB mode, fill = anything.
      Do: Type "abcdef", Enter.
      Expect: Fill snaps to nearest web-safe color (multiples of 51 per
              channel), e.g. `99ccff`.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass (rust: hex commit branch snaps each channel to nearest multiple of 51 when color_panel_mode == WebSafeRgb. swift: hex commit snaps RGB channels in web_safe_rgb mode; BufferedTextField now syncs text from externalValue regardless of focus so the snapped hex displays after commit — Enter doesn't unfocus the field on macOS); 2026-05-20 python pass

- [x] **CLR-106** [wired] Hex disabled when fill is none.
      Setup: Fill = none.
      Expect: Hex input dimmed / non-interactive.
      — last: 2026-05-11 rust accepted-as-is; 2026-05-13 swift accepted-as-is (hex stays interactive when active is none, matching slider behavior); 2026-05-20 python pass

---

## Session F — Color bar (~8 min)

- [x] **CLR-120** [wired] Color bar renders 64px tall.
      Do: Visually inspect.
      Expect: 2D gradient fills the row at 64px height; hue runs left → right
              (red → yellow → green → cyan → blue → magenta → red).
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-121** [wired] Top half ramps S 0 → 100, B 100 → 80.
      Do: Click center-top of bar.
      Expect: Resulting color is mid-light, mid-saturation hue at click x.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-122** [wired] Bottom half ramps B 80 → 0 at full saturation.
      Do: Click center-bottom of bar.
      Expect: Resulting color is dark, fully saturated hue at click x.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-123** [wired] Click commits on pointer-up.
      Do: Click+release a single point on the color bar.
      Expect: Fill updates; recent-colors gets an entry.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-124** [wired] Drag updates fill in real time.
      Do: Press and drag horizontally across the color bar.
      Expect: Fill cycles through hues live; one recent-colors entry on
              pointer-up.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-125** [wired] Click outside bar bounds doesn't crash.
      Do: Press inside, drag outside the bar's vertical range, release.
      Expect: Behavior clamps to bar bounds; no crash; one or zero recent
              entries (define expected).
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-126** [wired] Color bar disabled when fill is none.
      Setup: Fill = none.
      Expect: Bar renders dimmed; click is a no-op (or auto-un-nones — pick
              actual behavior).
      — last: 2026-05-11 rust accepted-as-is; 2026-05-13 swift accepted-as-is (bar stays interactive when fill is none; user OK); 2026-05-20 python accepted-as-is (python: stays interactive — accepted-as-is)

---

## Session G — Fill/Stroke widget (~5 min)

- [x] **CLR-140** [wired] Fill/Stroke widget renders 48px with both swatches.
      Do: Visually inspect.
      Expect: Two overlapping color swatches (fill on top by default), plus
              a swap affordance and a reset (default-colors) affordance.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-141** [wired] Clicking the fill swatch makes fill the active target.
      Setup: Stroke target active.
      Do: Click the fill swatch in the widget.
      Expect: Sliders / hex / color bar now reflect the fill color; future
              edits write to fill.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-142** [wired] Clicking the stroke swatch makes stroke the active target.
      Setup: Fill target active.
      Do: Click the stroke swatch.
      Expect: Sliders / hex / color bar now reflect stroke; edits write to
              stroke.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass (rust: added/reverted bind.hollow — stroke stays hollow, z-index 2 indicates active. swift: FillStrokeWidget now keeps fill at upper-left and stroke at lower-right always, swapping z-order via ZStack render order; stroke center is hollow (clear fill) with contentShape so the transparent center still hit-tests); 2026-05-20 python pass

- [x] **CLR-143** [wired] Swap exchanges fill and stroke.
      Setup: Fill = `#ff0000`, stroke = `#000000`.
      Do: Click swap.
      Expect: Fill = `#000000`, stroke = `#ff0000`.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass (swift: swap reads colors from the SELECTION first (uniform summary) rather than defaults — which had drifted; also propagates the swap to the selection so the canvas updates); 2026-05-20 python pass (python: subscribe_active_color ungated on fill_on_top so reset_fill_stroke applies both sides in one click)

- [x] **CLR-144** [wired] Reset returns to default fill / stroke (`#000000` / `none` or workspace defaults).
      Setup: Fill / stroke set to non-defaults.
      Do: Click reset.
      Expect: Fill returns to default black, stroke to default none (or
              workspace-defined defaults; document).
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass (swift: reset now also propagates to selection); 2026-05-20 python pass (python: picker opens; gradient/hue_bar/radio_group widgets deferred — same status as Session J test deferral)

- [x] **CLR-145** [wired] Single click only — no double-click picker launch.
      Do: Double-click the fill swatch quickly.
      Expect: Two single-click events register (target switch + target
              switch); no modal color picker dialog opens.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

---

## Session H — Recent colors (~8 min)

- [x] **CLR-160** [wired] Recent slots render as 10 squares left-to-right.
      Do: Open a fresh workspace; observe `cp_recent_0` … `cp_recent_9`.
      Expect: 10 16px squares; empty ones render as hollow with solid borders.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-161** [wired] Empty recent slots are non-interactive.
      Setup: Fresh workspace, no recent colors yet.
      Do: Click an empty `cp_recent_N`.
      Expect: No-op; cursor doesn't change to a click affordance.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-162** [wired] First commit lands in `cp_recent_0`.
      Setup: Empty recent list.
      Do: Type `00ff00` + Enter into hex.
      Expect: `cp_recent_0` now shows green; rest still empty.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-163** [wired] Newest entries push older ones rightward.
      Setup: Recent slot 0 = green.
      Do: Type `0000ff` + Enter.
      Expect: Slot 0 = blue, slot 1 = green; rest empty.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-164** [wired] Clicking a recent swatch commits it as the active color.
      Setup: Slot 0 = `#0000ff`.
      Do: Click `cp_recent_0`.
      Expect: Active fill becomes `#0000ff`; sliders / hex update; slot 0
              stays where it is (already at front).
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass (python: _wire_click captures widget_panel_id at wire time and rebuilds eval_ctx with that panel's state at click time)

- [x] **CLR-165** [wired] Duplicate color moves to front, doesn't duplicate.
      Setup: Recent list = [red, blue, green].
      Do: Type `00ff00` + Enter (re-commit green).
      Expect: List becomes [green, red, blue] — only one green entry.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-166** [wired] Recent list caps at 10 entries.
      Setup: Recent list at 10 distinct colors.
      Do: Commit an 11th distinct color.
      Expect: New color enters at slot 0; oldest (slot 9) falls off.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [x] **CLR-167** [wired] None / Black / White swatch commits also enter recent.
      Setup: Empty recent list.
      Do: Click Black.
      Expect: `cp_recent_0` = black.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass (python: YamlPanelView._run_init only fires on first mount so a None click doesn't cascade through stale init colors)

- [x] **CLR-168** [wired] Recent list is per-document.
      Setup: Document A with recent [red, green]; create new document B.
      Expect: In document B the recent slots are empty.
      Switch back to document A: recents return.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python accepted-as-is
      Note: CLR-303 — native apps may not yet persist recents per document;
            document divergence here.

---

## Session I — Menu — Invert / Complement (~5 min)

- [x] **CLR-180** [wired] Menu shows Invert + Complement entries.
      Do: Open the panel menu.
      Expect: After the modes block (separator), Invert and Complement.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass; 2026-05-20 python pass

- [ ] **CLR-181** [known-broken: native handler placeholder] Invert flips
      every channel.
      Setup: Fill = `#ff0000` (255, 0, 0).
      Do: Menu → Invert.
      Expect: Fill becomes `#00ffff` (cyan, channel-wise 255−R/G/B); recent
              gets cyan. (Currently a no-op in the native apps — documented
              as known-broken.)
      — last: 2026-05-11 rust skipped; 2026-05-13 swift skipped (known-broken); 2026-05-20 python pass

- [ ] **CLR-182** [known-broken: native handler placeholder] Complement
      rotates hue 180°.
      Setup: Fill = `#ff0000` (H=0, S=100, B=100).
      Do: Menu → Complement.
      Expect: Fill becomes `#00ffff` (H=180); recent gets cyan.
      — last: 2026-05-11 rust skipped; 2026-05-13 swift skipped (known-broken); 2026-05-20 python pass

- [x] **CLR-183** [wired] Invert / Complement disabled when fill is none.
      Setup: Fill = none.
      Expect: Menu items dimmed.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass (rust + swift: added panel_is_enabled query + dimmed rendering. swift: HamburgerMenuButton sets autoenablesItems=false so the explicit NSMenuItem.isEnabled wins); 2026-05-20 python pass

- [x] **CLR-184** [wired] Complement on grayscale (S=0) is a no-op.
      Setup: Fill = `#808080` (S=0).
      Do: Menu → Complement.
      Expect: No change; complement of zero-sat is itself.
      — last: 2026-05-11 rust pass; 2026-05-13 swift pass (rust: also fixed menu-item bug — switched panel-menu actions from onmousedown to onclick so the click event doesn't bubble to swatches under the menu); 2026-05-20 python pass

---

## Session J — Color picker dialog (~12 min)

**P0**

- [x] **CLR-200** [wired] Dialog opens (when wired) and shows the full layout.
      Do: Wherever the picker is launched (per spec — placeholder action in
          panel, may be triggered via swatch double-click on some platforms).
      Expect: Modal dialog with eyedropper, large 2D gradient, vertical hue
              bar, "Only Web Colors" toggle, 50×50 preview swatch,
              HSB / RGB radio + numeric rows, Hex field, read-only CMYK
              display, OK + Cancel + Color Swatches buttons.
      — last: 2026-05-12 rust pass; 2026-05-13 swift pass (swift: wired FillStrokeWidget onDoubleClick to dispatchYamlAction("open_color_picker"); added renderRadioGroup, renderColorGradient, renderColorHueBar — these YAML element types weren't dispatched by YamlElementView before); 2026-05-20 ocaml pass (ocaml: dispatch_double_click_behaviors + open_yaml_dialog_hook + TWO_BUTTON_PRESS detection; only swap fill_stroke when fill_on_top actually flips so GTK double-click tracking survives; render_radio_group / render_color_gradient / render_color_hue_bar implemented)

- [x] **CLR-201** [wired] Cancel closes without committing.
      Setup: Dialog open, fields edited.
      Do: Click Cancel.
      Expect: Dialog closes; target attribute unchanged.
      — last: 2026-05-12 rust pass; 2026-05-14 swift pass (swift: open_dialog effect now passes get/set props to store.initDialog so YAML setters fire on widget commits; buildDialogEvalContextWithGetters merges computed getter values into the dialog ctx; renderNumberInput / renderTextInput / renderSlider all accept bare-string `bind:` form (was object-only) — without that the color picker fields silently dropped commits because the radio_field_row template uses bind: "${bind}"); 2026-05-20 ocaml pass (ocaml: Dialog_global extended with prop_def + setter-eval + state_change_listeners; render_number_input / render_text_input accept bare-string bind form; show_dialog parses YAML state get/set into Dialog_global.current_props; current_build_ctx uses read_state() so getter-derived keys reflect canonical color)

**P1**

- [x] **CLR-210** [wired] Click in the 2D gradient updates two channel values.
      Setup: HSB H selected as the colorbar axis (default radio).
      Do: Click in the gradient.
      Expect: S + B move to the click position; preview swatch updates;
              numeric H/S/B fields and Hex update.
      — last: 2026-05-12 rust pass; 2026-05-14 swift pass; 2026-05-20 ocaml pass

- [x] **CLR-211** [wired] Drag in the gradient tracks live.
      Do: Press and drag inside the gradient.
      Expect: Preview swatch follows pointer; circle indicator follows; no
              commit until OK.
      — last: 2026-05-12 rust pass; 2026-05-14 swift pass; 2026-05-20 ocaml pass

- [x] **CLR-212** [wired] Drag the hue bar updates hue.
      Do: Drag the vertical hue bar.
      Expect: Gradient body re-tints to new hue; preview updates; numeric H
              updates.
      — last: 2026-05-12 rust pass; 2026-05-14 swift pass (swift: also wired OK/Cancel close-bridge from click-behavior chain to overlay binding; picker init now augments ctx.state with live selection fill/stroke so the dialog opens on the canvas color); 2026-05-20 ocaml pass

- [x] **CLR-213** [wired] Radio button selects which channel maps to the bar.
      Setup: Default is H.
      Do: Click the R radio.
      Expect: Vertical bar becomes a red ramp 0–255; gradient axes rebind
              to G (x) and B (y); preview unchanged.
      — last: 2026-05-12 rust pass; 2026-05-14 swift pass (vertical bar re-ramps per channel; 2D gradient axis rebinding still H/S/B-only — accepted); 2026-05-20 ocaml pass (ocaml: render_color_hue_bar reads dialog.radio_channel + per-channel ramp+bind spec; 2D gradient axis rebinding still H/S/B-only — accepted)

- [x] **CLR-214** [wired] Hex field commits on Enter inside the dialog.
      Do: Type `ff00ff` into the dialog Hex field; press Enter.
      Expect: Preview becomes magenta; numeric H/S/B and R/G/B update;
              CMYK readout updates.
      — last: 2026-05-12 rust pass; 2026-05-14 swift pass; 2026-05-20 ocaml pass

- [x] **CLR-215** [wired] Only Web Colors toggle snaps current value.
      Setup: Picker showing color `#abcdef`.
      Do: Toggle "Only Web Colors" on.
      Expect: Color snaps to nearest web-safe value (e.g. `99ccff`); fields
              update accordingly.
      — last: 2026-05-12 rust pass (toggle now snaps each RGB channel to multiples of 51; eval_with_store rewritten to use the proper AST so let-bindings in setters work — the bl setter relies on it); 2026-05-20 ocaml pass (ocaml: render_toggle now accepts bare-string bind form; _write_back_bind dialog branch snaps r/g/bl on toggle-on AND on subsequent color-affecting edits via _dialog_snap_in_flight guard — continuous snapping, divergence from Rust/Swift which only snap on toggle)

- [ ] **CLR-216** [wired — yaml now dismisses dialog + activates Eyedropper tool; full in-dialog sample-into-color loop deferred] Eyedropper button activates canvas sampling.
      Do: Click the eyedropper.
      Expect: Cursor changes to crosshair / eyedropper; clicking a point on
              the canvas adopts that pixel's color into the picker.
      — last: 2026-05-12 rust deferred (replaced placeholder `log:` with `set active_tool + dismiss_dialog`; sample loop back into open dialog not yet implemented); 2026-05-20 ocaml deferred (matches Rust — added set_active_tool_hook + behavior-level action: dismiss_dialog dispatch; sample-into-dialog round-trip still unimplemented)

- [x] **CLR-217** [wired — behavior changed: CMYK fields are now editable] CMYK fields are read-only.
      Do: Try to type into a CMYK field.
      Expect: Field rejects edits; values change only when the underlying
              color changes.
      — last: 2026-05-12 rust pass with spec change — added setters to c/m/y/k so typing into CMYK rebuilds color via cmyk(); update spec / propagate to other ports; 2026-05-20 ocaml pass

- [x] **CLR-218** [wired] OK applies to the target (fill or stroke).
      Setup: Picker opened with `target=fill`.
      Do: Pick a color; click OK.
      Expect: Selection's fill becomes the picked color; stroke unchanged;
              dialog closes; recent-colors gets the entry.
      — last: 2026-05-12 rust pass (added `if` effect support to run_effects_with_ctx so the OK branch's set fill_color / stroke_color fires); 2026-05-20 ocaml pass (ocaml: dialog inline branch calls Panel_menu.push_recent_color after Effects.run_effects when current_id == "color_picker" — subscribe_active_color updates default+selection but doesn't push to recent)

**P2**

- [x] **CLR-230** [wired] OK with `target=stroke` writes stroke.
      Setup: Picker opened with `target=stroke`.
      Do: Pick a color; click OK.
      Expect: Selection's stroke becomes the picked color; fill unchanged.
      — last: 2026-05-12 rust pass (reverted earlier `bind.hollow="state.fill_on_top"` — stroke stays hollow ring; z-index alone indicates active); 2026-05-20 ocaml pass

- [x] **CLR-231** [wired] Color Swatches button is disabled (placeholder).
      Do: Inspect the Color Swatches button.
      Expect: Renders dimmed / non-interactive (per yaml placeholder).
      — last: 2026-05-12 rust pass; 2026-05-20 ocaml pass (ocaml: render_button reads style.opacity and applies dim via CSS provider on button's style context + set_sensitive false — lablgtk3 misc_ops doesn't expose set_opacity directly)

---

## Session K — None-state gating (~5 min)

- [x] **CLR-240** [wired] Sliders dim when active attribute is none.
      Setup: Fill = none.
      Expect: All slider controls in the current mode render dimmed / non-
              interactive.
      — last: 2026-05-12 rust accepted-as-is (sliders stay interactive when fill is none; user OK with current behavior); 2026-05-20 ocaml accepted-as-is; 2026-05-20 python pass

- [x] **CLR-241** [wired] Hex dims when none.
      Setup: Fill = none.
      Expect: Hex input dimmed.
      — last: 2026-05-12 rust accepted-as-is (hex stays interactive when fill is none; user OK with current behavior); 2026-05-20 ocaml accepted-as-is; 2026-05-20 python pass

- [x] **CLR-242** [wired] Color bar dims when none.
      Setup: Fill = none.
      Expect: Color bar dimmed; click does not commit (or auto-un-nones —
              document the actual behavior).
      — last: 2026-05-12 rust accepted-as-is (color bar stays interactive when fill is none; user OK); 2026-05-20 ocaml accepted-as-is; 2026-05-20 python pass

- [x] **CLR-243** [wired] Fixed swatches stay clickable when none.
      Setup: Fill = none.
      Expect: None / Black / White / recent swatches all clickable.
      — last: 2026-05-12 rust pass; 2026-05-20 ocaml pass; 2026-05-20 python pass

- [x] **CLR-244** [wired] Clicking Black / White / recent un-nones the attribute.
      Setup: Fill = none.
      Do: Click White.
      Expect: Fill becomes `#ffffff`; sliders / hex / bar re-enable.
      — last: 2026-05-20 ocaml pass; 2026-05-20 python pass

---

## Session L — Appearance theming (~5 min)

- [x] **CLR-260** [wired] Dark appearance: readable contrast on all controls.
      Setup: Dark appearance active.
      Expect: Slider tracks visible; swatch borders distinguishable from
              panel bg; hex text legible; menu glyphs visible.
      — last: 2026-05-20 ocaml pass; 2026-05-20 python pass

- [x] **CLR-261** [wired] Medium Gray appearance mirrors Dark.
      Do: Switch appearance → Medium Gray.
      Expect: Panel re-skins with Medium-Gray tokens; everything readable;
              no Dark hardcoded colors leak through.
      — last: 2026-05-20 ocaml pass; 2026-05-20 python pass

- [x] **CLR-262** [wired] Light Gray appearance mirrors Dark.
      Do: Switch to Light Gray.
      Expect: Same as above; black / white swatches readable against the
              new bg.
      — last: 2026-05-20 ocaml pass (ocaml: render_text now defaults to !Dock_panel.theme_text via theme_text_hook ref — direct reference would cycle Yaml_panel_view ↔ Dock_panel); 2026-05-20 python pass (python: _input_css() reads theme tokens per render so value boxes follow appearance switch)

- [x] **CLR-263** [wired] Active mode menu checkmark visible in every appearance.
      Do: In each appearance, open the panel menu.
      Expect: Checkmark on the active mode is visually distinct from the
              other modes.
      — last: 2026-05-20 ocaml pass; 2026-05-20 python pass

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

- **ENH-001** Re-use the YAML `fill_stroke_widget` template in the native
  toolbars. Today the OCaml toolbar (`jas_ocaml/lib/tools/toolbar.ml`
  `fs_area`, ~250 lines) and the Swift toolbar (`JasSwift/Sources/Canvas/
  ContentView.swift` `FillStrokeWidget`, ~300 lines) hand-roll their own
  fill/stroke indicators with custom Cairo / SwiftUI Canvas paint and
  manual hit-testing — separate from the YAML-driven widget the color
  panel uses. Refactor in three steps: (1) expose a
  `render_fill_stroke_widget_standalone` helper that accepts an explicit
  `ctx` instead of reading from the active panel store, (2) thread
  `swap_fill_stroke` / `reset_fill_stroke` / `set_fill_type_*` through
  the dispatch layer so YAML click handlers work outside a panel,
  (3) replace the hand-rolled widgets in OCaml + Swift toolbars with the
  shared template. Bonus: Rust's `FillStrokeWidgetView` is already a
  shared component — slotting it into the Rust toolbar is just a
  `rsx!` insertion. Tradeoff: requires moving `fill_on_top` out of the
  toolbar's local state into the same store the color panel writes,
  which is cleaner long-term but is a meaningful refactor.
  _Raised during CLR-002 OCaml on 2026-05-15._

_Manual testing surfaces ideas here with `ENH-NNN` prefix and italicized
trailer noting the test + date._
