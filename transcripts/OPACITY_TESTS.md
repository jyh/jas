# Opacity Panel — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/panels/opacity.yaml`. Design doc: `transcripts/OPACITY.md`.

Primary platform for manual runs: **Rust (jas_dioxus)** — the reference
implementation for canvas compositing (luminance masks, mask isolation),
tool routing, and modifier-click shortcuts. Other native apps and Flask
covered in Session N parity sweep with gaps noted per app.

---

## Known broken

_Last reviewed: 2026-04-22_

- **OP-500** [deferred: OPACITY.md §Deferred additions — drag]
  Dragging from OPACITY_PREVIEW onto MASK_PREVIEW to copy the element's
  artwork into the mask subtree is not implemented. Deferred behind
  cross-platform DnD scaffolding; a menu action may ship first.
- **OP-501** [deferred: OPACITY.md §Deferred additions — luminance
  parity] Luminance-weighted mask compositing ships only on jas_dioxus
  and only for the `ClipIn` plan (`clip: true, invert: false`). Swift /
  OCaml / Python and the `ClipOut` / `RevealOutsideBbox` plans still use
  raw alpha — a black-opaque mask will read as opaque where the spec
  wants it transparent. Tests in Session I annotate which path currently
  exercises luminance vs alpha.
- **OP-502** [deferred: OPACITY.md §Deferred additions — inside-mask
  path encoding] After a mask-routed `add_element`, the selection
  points at the masked element, not the new element inside the mask
  subtree. Deleting the just-drawn mask shape therefore deletes the
  outer element instead. Workaround: click the shape on canvas (once
  MASK_PREVIEW thumbnails exist this may not be routine).
- **OP-503** [deferred: OPACITY.md §Deferred additions — SVG icons]
  The `op_link_indicator` widget shows the word "Link mask transform"
  in JasSwift and jas (python) because their `icon_button` renderers
  don't parse the SVG strings from `workspace/icons.yaml`. Rust and
  Flask render the chain / broken-chain glyph correctly.
- **OP-504** [deferred: OPACITY.md §Deferred additions — preview
  thumbnails] OPACITY_PREVIEW and MASK_PREVIEW render as literal
  `[placeholder]` text rather than thumbnails of the selection / mask
  subtree. Highlight outline, click behavior, and modifier shortcuts
  are wired — only the thumbnail rendering is missing.
- **OP-505** [deferred: OPACITY.md §Panel menu — pending_renderer]
  `toggle_page_isolated_blending` / `toggle_page_knockout_group` menu
  entries are always disabled. Clears when the renderer supports
  isolated-blending / knockout-group compositing for the document root
  group.

---

## Automation coverage

_Last synced: 2026-04-22_

**Flask — `jas_flask/tests/test_opacity_panel.py`** (37 tests)
- Panel spec: state block (blend_mode enum, opacity, thumbnails_hidden,
  options_shown, new_masks_clipping / new_masks_inverted with
  `per_document: true`), content scaffolding.
- Panel menu: all ten spec items + Close, three separators, enabled_when
  expressions on mask-lifecycle entries, checked_when on the four
  panel-local toggles, `status: pending_renderer` on the two page-level
  items.
- Mode dropdown: sixteen options with five separators grouping into six
  sections; `value` bound to `panel.blend_mode`.
- Opacity input: range 0–100, suffix `%`, bound to `panel.opacity`.
- Preview row: `visible: "!panel.thumbnails_hidden"`.
- Make / Clip / Invert widgets: `label` / `disabled` / `checked` bindings
  against the `selection_*` predicates.
- LINK_INDICATOR: `bind.icon` expression flips between `link_linked` /
  `link_unlinked`, `disabled: "!selection_has_mask"`.
- Theming: no hardcoded colors in the content tree.

**Rust — `jas_dioxus/src/panels/opacity_panel.rs`** (11 tests)
- Menu shape: ten spec items in order, four toggles, four mask-lifecycle
  actions in correct order.
- Dispatch: toggle_new_masks_clipping / toggle_new_masks_inverted flip
  the stored panel bool from spec defaults.
- Controller integration: make / release / disable / unlink opacity mask
  actions mutate `element.mask`, don't touch panel-local state.
- Selection-has-mask semantics: mixed selection counts as no-mask.

**Rust — `jas_dioxus/src/document/controller.rs`** (16 tests in the
mask lifecycle + add_element mask-routing groups)
- `first_mask` / `selection_has_mask` helpers — default true on the
  linked predicate when the selection has no mask.
- `make_mask_on_selection` — creates masks, honors clip/invert args,
  idempotent, selection points at the masked element.
- `release_mask_on_selection` / `set_mask_clip` / `set_mask_invert` /
  `toggle_mask_disabled` / `toggle_mask_linked` including
  `unlink_transform` capture.
- `add_element` routing: mask-mode adds to the mask subtree's Group
  children, falls back to layer on missing mask or non-Group subtree,
  content-mode ignores editing_target.

**Rust — `jas_dioxus/src/canvas/render.rs`** (17 tests)
- `mask_plan` dispatch (ClipIn / ClipOut / RevealOutsideBbox / None).
- `effective_mask_transform` linked / unlinked with Some / None
  transforms.
- `promote_bytes_to_luminance` (8 cases): white-opaque keeps alpha,
  black-opaque drops to 0, mid-gray halves, transparent stays
  transparent, source alpha respected, BT.601 per-channel weights.

**Rust — `jas_dioxus/src/workspace/app_state.rs`** (~4 tests)
- `TabState` / `Model` defaults: `editing_target == Content`,
  `mask_isolation_path == None`, both round-trip through Mask /
  Some(path).

**Rust — `jas_dioxus/src/workspace/dock_panel.rs`** (indirect)
- `build_selection_predicates` emits `selection_has_mask /
  _mask_clip / _mask_invert / _mask_linked / editing_target_is_mask`
  at top-level of the yaml eval context.

**Swift — `JasSwift/Tests/Panels/OpacityPanelTests.swift`** (19 tests)
- State defaults and round-trips for all OpacityPanelState fields.
- Menu dispatch for the four panel-local toggles, four mask-lifecycle
  actions. `isChecked` reflects `layout.opacityPanel` state.
- `dispatchMakeUsesDocumentDefaultsForClipInvert`: make_opacity_mask
  reads live `newMasksClipping` / `newMasksInverted`.
- Disable / unlink toggle element.mask fields; release clears.

**Swift — `JasSwift/Tests/Document/ControllerTests.swift`** (mask
lifecycle + editor group)
- `selectionHasMask` / `firstMask` helpers; mixed selection = no mask.
- Make / release / set_clip / set_invert / toggle_disabled /
  toggle_linked on selections of 1 and 2, including unlink_transform
  capture.
- addElement mask-mode routing: new child lands in subtree, fall-back
  on no-mask, content-mode ignores editingTarget.

**Swift — `JasSwift/Tests/Canvas/CanvasTests.swift`** (mask group)
- `maskPlan` — ClipIn / ClipOut / RevealOutsideBbox / nil for disabled.
- `effectiveMaskTransform` linked / unlinked / None permutations.
- `cgBlendMode` mapping for all 16 BlendMode variants.

**Swift — `JasSwift/Tests/Document/ModelTests.swift`** (mask UI state)
- `editingTarget` / `maskIsolationPath` defaults and round-trips.

**OCaml — `jas_ocaml/test/panels/panel_menu_test.ml`** (31 tests in
panel menu group, ~6 opacity-specific)
- Menu shape + dispatch parity with Rust and Swift.
- Toggle flips state store; `make_opacity_mask` reads live store-based
  `new_masks_clipping` / `new_masks_inverted`.

**OCaml — `jas_ocaml/test/document/controller_test.ml`** (12 tests in
mask_lifecycle group)
- Mask lifecycle parity with Rust / Swift.
- `add_element` mask-mode routing + fall-back + content-mode.

**OCaml — `jas_ocaml/test/canvas/opacity_mask_test.ml`** (9 tests)
- `mask_plan` dispatch + `effective_mask_transform` parity.

**OCaml — `jas_ocaml/test/document/model_test.ml`** (4 mask-state
tests)
- `editing_target` / `mask_isolation_path` defaults and round-trips.

**Python — `jas/document/controller_test.py`** (mask lifecycle class,
~13 tests)
- Mask lifecycle parity with Rust / Swift / OCaml.
- `add_element` mask-mode routing + fall-back + content-mode.

**Python — `jas/panels/panel_menu_test.py`** (~6 opacity tests)
- Panel label, menu shape (ten spec items + close, four toggles,
  mask-lifecycle actions in order), `toggle_new_masks_clipping` flips
  store, `make_opacity_mask` reads live store flags.

**Python — `jas/canvas/canvas_test.py`** (MaskPlanTest + mask-routing
paintEvent)
- `_mask_plan` dispatch + `_effective_mask_transform` parity.

**Python — `jas/document/model_test.py`** (EditingTargetTest, 4 tests)
- `editing_target` / `mask_isolation_path` defaults and round-trips.

The manual suite below covers what auto-tests don't: real widget
rendering, dropdown interaction, keyboard entry, hamburger menu UX,
preview click / modifier-click flows, Escape-key handling, visual mask
compositing output, mask-isolation rendering, cross-panel regressions,
and appearance theming.

---

## Default setup

Unless a session or test says otherwise:

1. Launch `jas_dioxus` (`cargo run --features web --bin jas_dioxus`).
2. Open a default workspace with no document loaded.
3. Open the Opacity panel via Window → Opacity (or the default docked
   location).
4. Appearance: **Dark Gray**.

Tests that require a selection use this fixture unless overridden:
Rectangle tool → drag a 300×200 rect → fill default (`#ff6600`), stroke
default (`#000000`). Call this "the orange rect".

Tests that require a mask use the fixture above plus: click MAKE_MASK
with the orange rect selected → `mask` field present with an empty
Group subtree. Call this "the masked orange rect".

Tests that require mask contents use the masked orange rect plus:
click MASK_PREVIEW to enter mask-editing mode → draw a white rect
fully inside the orange rect → click OPACITY_PREVIEW to return to
content-mode. The painted region is visible; the rest of the orange
rect is clipped away (luminance-based, `clip: true`). Call this "the
masked orange rect with inner mask".

---

## Tier definitions

- **P0 — existential.** If this fails, the panel is broken. Crash,
  layout collapse, complete non-function. 5-minute smoke confidence.
- **P1 — core.** Control does its primary job (click / drag / enter /
  select / toggle).
- **P2 — edge & polish.** Bounds, keyboard-only paths, focus / tab
  order, appearance variants, modifier-click shortcuts, icon states,
  mask compositing edge cases.

---

## Session table of contents

| Session | Topic                                   | Est.  | IDs       |
|---------|-----------------------------------------|-------|-----------|
| A       | Smoke & lifecycle                       | ~5m   | 001–009   |
| B       | Blend mode dropdown                     | ~8m   | 010–039   |
| C       | Opacity numeric input + disclosure      | ~6m   | 040–059   |
| D       | Make / Release button                   | ~5m   | 060–079   |
| E       | Clip / Invert Mask checkboxes           | ~5m   | 080–099   |
| F       | LINK_INDICATOR                          | ~5m   | 100–119   |
| G       | Preview clicks + modifier shortcuts     | ~10m  | 120–159   |
| H       | Hamburger menu                          | ~8m   | 160–199   |
| I       | Canvas mask compositing                 | ~15m  | 200–249   |
| J       | Mask editor UI                          | ~10m  | 250–279   |
| K       | Appearance theming                      | ~5m   | 280–299   |
| L       | Cross-panel regressions                 | ~5m   | 300–319   |
| M       | State persistence (per_document)        | ~5m   | 320–339   |
| N       | Cross-app parity                        | ~15m  | 400–429   |

Full pass: ~105 min. A gates the rest; otherwise sessions stand alone.

---

## Session A — Smoke & lifecycle (~5 min)

If any P0 here fails, stop and flag.

- [ ] **OP-001** [wired] Panel opens via Window menu.
      Do: Select Window → Opacity.
      Expect: Opacity panel appears in the dock (or floating) with no
      console error; hamburger button visible top-right of the panel
      body.
      — last: —

- [ ] **OP-002** [wired] Panel renders with empty selection.
      Do: Dismiss any selection (click empty canvas), observe panel.
      Expect: BlendMode shows "Normal"; opacity numeric reads 100;
      preview row visible; MAKE_MASK button reads "Make Mask"; CLIP
      and INVERT_MASK checkboxes greyed out; LINK_INDICATOR greyed
      out; OPACITY_PREVIEW highlighted with blue 2pt outline.
      — last: —

- [ ] **OP-003** [wired] Panel survives dock → float → redock.
      Do: Drag the Opacity tab off the dock, then drag it back to the
      original group.
      Expect: All controls render identically before and after; no
      state loss.
      — last: —

- [ ] **OP-004** [wired] Close via hamburger "Close Opacity".
      Do: Open hamburger → Close Opacity.
      Expect: Panel disappears from the dock; Window → Opacity remains
      available to reopen.
      — last: —

---

## Session B — Blend mode dropdown (~8 min)

### P0

- [ ] **OP-010** [wired] Dropdown opens and shows all 16 modes.
      Do: Click BlendMode (top-left). Count entries (ignoring
      separators).
      Expect: 16 entries in order: Normal · Darken · Multiply · Color
      Burn · Lighten · Screen · Color Dodge · Overlay · Soft Light ·
      Hard Light · Difference · Exclusion · Hue · Saturation · Color ·
      Luminosity.
      — last: —

### P1

- [ ] **OP-011** [wired] Five separators split the 16 modes into six
      groups.
      Do: Click BlendMode and inspect divider lines between groups.
      Expect: Visual separators between Normal→Darken, Color Burn→
      Lighten, Color Dodge→Overlay, Hard Light→Difference, Exclusion→
      Hue (five separators; six groups).
      — last: —

- [ ] **OP-012** [wired] Selecting a non-Normal mode updates
      `panel.blend_mode`.
      Do: Select the orange rect; pick "Multiply" from the dropdown.
      Expect: Dropdown closes showing "Multiply"; panel.blend_mode
      state now "multiply". Canvas visual unchanged pending Phase B
      selection-apply (see OPACITY.md §Panel-to-selection wiring).
      — last: —

- [ ] **OP-013** [wired] Selecting Normal from a non-Normal state
      resets.
      Do: Continue from OP-012; pick "Normal" from the dropdown.
      Expect: Dropdown closes showing "Normal"; panel.blend_mode is
      "normal".
      — last: —

### P2

- [ ] **OP-014** [wired] Keyboard navigation opens the dropdown.
      Do: Tab focus to BlendMode; press Space.
      Expect: Dropdown opens; Up/Down walks entries; Enter commits.
      — last: —

- [ ] **OP-015** [wired] BlendMode occupies exactly 4 columns of the
      row.
      Do: Inspect panel layout.
      Expect: Dropdown width matches the `col: 4` grid allocation; no
      overlap with the "Opacity:" label.
      — last: —

- [ ] **OP-016** [wired] All 16 labels resolve to localized strings.
      Do: Open the dropdown; read each label.
      Expect: No raw ids showing (e.g. no "color_burn" — shows "Color
      Burn"). Phase-1 app may not use the i18n layer yet — verify
      labels match OPACITY.md §Mode values table.
      — last: —

---

## Session C — Opacity numeric input + disclosure (~6 min)

### P1

- [ ] **OP-040** [wired] Typing a value commits to panel.opacity.
      Do: Click into the opacity spinbox; type `37`; press Enter.
      Expect: Display reads "37%"; panel.opacity state is 37.
      — last: —

- [ ] **OP-041** [wired] Up/Down arrows step by 1.
      Do: Focus the spinbox (value 100); press Down four times.
      Expect: Value reads 96%; state is 96.
      — last: —

- [ ] **OP-042** [wired] Range is clamped to 0..100.
      Do: Enter `150`; press Enter. Enter `-20`; press Enter.
      Expect: Upper commit clamps to 100; lower commit clamps to 0.
      — last: —

- [ ] **OP-043** [wired] Disclosure chevron opens the slider popover.
      Do: Click the `>` icon to the right of the opacity field.
      Expect: A popover appears containing a horizontal slider; the
      slider's value matches panel.opacity; dragging it updates the
      spinbox live.
      — last: —

### P2

- [ ] **OP-044** [wired] Slider popover dismisses on outside click.
      Do: Open the disclosure popover; click outside.
      Expect: Popover closes; opacity keeps its last value.
      — last: —

- [ ] **OP-045** [wired] "%" suffix is not part of the editable string.
      Do: Click into the spinbox and type over the contents.
      Expect: Cursor sits before the `%`; the `%` suffix is read-only.
      — last: —

---

## Session D — Make / Release button (~5 min)

### P0

- [ ] **OP-060** [wired] "Make Mask" appears when no mask.
      Do: Select the orange rect (no prior mask).
      Expect: Button shows the text "Make Mask". Clip / Invert Mask
      checkboxes are greyed out.
      — last: —

- [ ] **OP-061** [wired] Click "Make Mask" creates a mask.
      Do: Continue; click "Make Mask".
      Expect: Button label flips to "Release". Clip / Invert Mask
      checkboxes enable (Clip checked per default
      `new_masks_clipping: true`). LINK_INDICATOR ungreys.
      — last: —

### P1

- [ ] **OP-062** [wired] Click "Release" removes the mask.
      Do: Continue from OP-061 with a mask on the selection; click
      "Release".
      Expect: Button reads "Make Mask" again; Clip / Invert Mask grey
      out; LINK_INDICATOR greys out.
      — last: —

- [ ] **OP-063** [wired] Make on a mixed selection of masked+unmasked.
      Do: Create two rects; mask only the first. Select both; observe
      the button label; click it.
      Expect: Label reads "Make Mask" (mixed = no-mask per spec). Click
      creates a mask on the second rect. Now both have masks; label
      flips to "Release".
      — last: —

### P2

- [ ] **OP-064** [wired] Button disabled on empty selection.
      Do: Deselect; observe the button.
      Expect: Button greyed out or a no-op click — still shows "Make
      Mask" since `selection_has_mask` is false for empty selection.
      — last: —

---

## Session E — Clip / Invert Mask checkboxes (~5 min)

### P1

- [ ] **OP-080** [wired] Clip defaults to checked on a fresh mask.
      Do: Create a fresh masked orange rect (default
      `new_masks_clipping: true`).
      Expect: Clip checkbox is checked and enabled.
      — last: —

- [ ] **OP-081** [wired] Clicking Clip toggles `mask.clip`.
      Do: On the masked orange rect, click Clip (check → uncheck).
      Expect: Checkbox unchecks; the canvas re-renders with the
      `RevealOutsideBbox` plan (see OP-210).
      — last: —

- [ ] **OP-082** [wired] Invert Mask defaults to unchecked.
      Do: Fresh masked orange rect.
      Expect: Invert Mask checkbox is unchecked and enabled.
      — last: —

- [ ] **OP-083** [wired] Clicking Invert Mask toggles `mask.invert`.
      Do: Click Invert Mask (uncheck → check).
      Expect: Checkbox checks; canvas re-renders with the `ClipOut`
      plan (inverted).
      — last: —

### P2

- [ ] **OP-084** [wired] Checkbox bindings reflect first-selected
      element in a mixed selection.
      Do: Create two rects, mask both, uncheck Clip on the first.
      Select both (first-selected order preserved).
      Expect: Clip checkbox shows unchecked (first wins per OPACITY.md
      §States).
      — last: —

- [ ] **OP-085** [wired] Checkboxes grey out when selection has no
      mask.
      Do: Deselect or select an unmasked rect.
      Expect: Both checkboxes visibly disabled; clicking has no
      effect.
      — last: —

---

## Session F — LINK_INDICATOR (~5 min)

### P1

- [ ] **OP-100** [wired] Linked glyph shows by default.
      Do: Fresh masked orange rect.
      Expect: The icon between OPACITY_PREVIEW and MASK_PREVIEW is the
      connected-chain glyph (`link_linked`). Hover shows "Link mask
      transform".
      — last: —

- [ ] **OP-101** [wired] Click flips to unlinked and captures
      transform.
      Do: Click LINK_INDICATOR.
      Expect: Glyph flips to the broken-chain (`link_unlinked`).
      `mask.linked` becomes false; `mask.unlink_transform` captures the
      element's transform at click time (identity if the rect has no
      transform).
      — last: —

- [ ] **OP-102** [wired] Click again relinks and clears captured
      transform.
      Do: Click LINK_INDICATOR again.
      Expect: Glyph flips back to connected-chain; `mask.linked` true;
      `mask.unlink_transform` is None.
      — last: —

### P2

- [ ] **OP-103** [wired] Greyed out when selection has no mask.
      Do: Deselect, or select an unmasked element.
      Expect: LINK_INDICATOR visibly disabled (opacity ~0.35); clicks
      are no-ops.
      — last: —

- [ ] **OP-104** [known-broken: OP-503] Swift and Python render a
      text label instead of the SVG glyph.
      Do: In JasSwift or jas (python), open the Opacity panel and
      find the LINK_INDICATOR cell.
      Expect: Instead of a chain icon, the button shows the string
      "Link mask transform". Function is correct (click still flips
      `mask.linked`).
      — last: —

---

## Session G — Preview clicks + modifier shortcuts (~10 min)

### P0

- [ ] **OP-120** [wired] Both previews render as bracketed placeholder
      text.
      Do: Observe OPACITY_PREVIEW and MASK_PREVIEW on an empty
      selection.
      Expect: Both show `[Opacity preview]` / `[Mask preview]` text.
      OPACITY_PREVIEW has a blue 2pt outline; MASK_PREVIEW does not.
      — last: —

- [ ] **OP-121** [known-broken: OP-504] Previews are placeholders,
      not thumbnails.
      Do: Create the masked orange rect with inner mask.
      Expect: Previews still show placeholder text rather than the
      actual thumbnail or the empty-mask glyph. Highlight and click
      behavior work correctly.
      — last: —

### P1

- [ ] **OP-122** [wired] Plain click on MASK_PREVIEW enters mask-mode.
      Do: Masked orange rect selected. Click MASK_PREVIEW.
      Expect: Blue outline moves from OPACITY_PREVIEW to MASK_PREVIEW.
      `model.editing_target` becomes `Mask(path_of_orange_rect)`.
      — last: —

- [ ] **OP-123** [wired] Plain click on OPACITY_PREVIEW exits
      mask-mode.
      Do: In mask-mode (from OP-122), click OPACITY_PREVIEW.
      Expect: Blue outline moves back to OPACITY_PREVIEW.
      `model.editing_target` becomes `Content`.
      — last: —

- [ ] **OP-124** [wired] MASK_PREVIEW click is a no-op without mask.
      Do: Select an unmasked rect; click MASK_PREVIEW.
      Expect: Nothing changes; outline stays on OPACITY_PREVIEW.
      — last: —

### P2

- [ ] **OP-125** [wired] Shift-click MASK_PREVIEW toggles
      `mask.disabled`.
      Do: Masked orange rect. Shift-click MASK_PREVIEW.
      Expect: `mask.disabled` becomes true; the canvas renders the
      element as if no mask were attached (full orange rect). Shift-
      click again reverses.
      — last: —

- [ ] **OP-126** [wired] Alt-click MASK_PREVIEW toggles mask
      isolation.
      Do: Masked orange rect with inner mask. Alt-click MASK_PREVIEW.
      Expect: Canvas shows only the mask subtree's artwork (the white
      rect drawn inside); the rest of the document is hidden. Alt-
      click again restores normal rendering.
      — last: —

- [ ] **OP-127** [wired] Escape exits mask isolation first.
      Do: In mask isolation (from OP-126) and mask-mode, press Escape.
      Expect: Isolation clears; document renders normally. Editing
      target still Mask(path). A second Escape returns to content-
      editing mode.
      — last: —

- [ ] **OP-128** [wired] Escape exits mask-mode when isolation is
      off.
      Do: In mask-mode but not in isolation, press Escape.
      Expect: `editing_target` flips to Content; outline returns to
      OPACITY_PREVIEW.
      — last: —

- [ ] **OP-129** [wired] Shift-click without a mask is a no-op.
      Do: Select an unmasked rect; Shift-click MASK_PREVIEW.
      Expect: Nothing changes. No mask is created; no state mutation.
      — last: —

---

## Session H — Hamburger menu (~8 min)

### P0

- [ ] **OP-160** [wired] Menu opens with all ten spec items.
      Do: Click the hamburger icon.
      Expect: Menu contains, in order: Hide Thumbnails · Show Options
      · Make Opacity Mask · Release Opacity Mask · Disable Opacity
      Mask · Unlink Opacity Mask · New Opacity Masks Are Clipping ·
      New Opacity Masks Are Inverted · Page Isolated Blending · Page
      Knockout Group · Close Opacity. Four separators divide the four
      spec groups + Close.
      — last: —

### P1

- [ ] **OP-161** [wired] Hide Thumbnails toggles
      `panel.thumbnails_hidden` and collapses the preview row.
      Do: Open menu → Hide Thumbnails.
      Expect: Preview row disappears (`bind.visible` uses
      `!panel.thumbnails_hidden`). Reopen menu: Hide Thumbnails now
      shows a checkmark.
      — last: —

- [ ] **OP-162** [wired] Make / Release / Disable / Unlink Opacity
      Mask dispatch through Controller.
      Do: Select the orange rect. Make. Then Release. Then Make →
      Disable. Then Unlink. Between each click, reopen the menu and
      observe which items are enabled.
      Expect: Make is enabled only when `!selection_has_mask`; the
      other three enabled only when `selection_has_mask`. After
      Disable, canvas renders unmasked but `mask` field still
      present; after Unlink, `mask.linked` is false.
      — last: —

- [ ] **OP-163** [wired] New Opacity Masks Are Clipping / Inverted
      toggle the document preferences.
      Do: Open menu → "New Opacity Masks Are Clipping" (should start
      checked). Uncheck. Open menu → "New Opacity Masks Are Inverted"
      (should start unchecked). Check. Select a rect and click
      MAKE_MASK.
      Expect: The new mask starts with `clip: false, invert: true`.
      Clip checkbox unchecks; Invert Mask checkbox checks.
      — last: —

### P2

- [ ] **OP-164** [known-broken: OP-505] Page Isolated Blending / Page
      Knockout Group are greyed out.
      Do: Open the menu and try the two page-level items.
      Expect: Both entries rendered greyed / unresponsive.
      — last: —

- [ ] **OP-165** [wired] Show Options toggle flips
      `panel.options_shown`.
      Do: Menu → Show Options. Reopen menu.
      Expect: Checkmark appears next to the item. (Phase-1: no inline
      control for this toggle yet; parity-with-checkmark only.)
      — last: —

---

## Session I — Canvas mask compositing (~15 min)

Primary platform is jas_dioxus (luminance-enabled on `ClipIn`). Note
per test where alpha-based compositing differs.

### P0

- [ ] **OP-200** [wired] `clip=true, invert=false`, white opaque mask
      shape reveals the element.
      Setup: The masked orange rect with an inner white rect drawn into
      the mask subtree (see "masked orange rect with inner mask" in
      default setup).
      Do: Observe the canvas.
      Expect: The orange rect is visible only inside the inner white
      rect; outside the inner rect, the canvas shows empty/white
      background.
      — last: —

- [ ] **OP-201** [wired] `clip=true, invert=false`, **black** opaque
      mask shape hides the element.
      Setup: Like OP-200 but draw a BLACK rect into the mask subtree
      (not white).
      Do: Observe.
      Expect (jas_dioxus, luminance): Orange rect is HIDDEN under the
      black shape — black luminance = 0, element fully transparent.
      Expect (Swift / OCaml / Python, alpha-based): Orange rect is
      VISIBLE under the black shape because raw alpha = 255. This
      divergence is OP-501.
      — last: —

### P1

- [ ] **OP-210** [wired] `clip=false, invert=false` — element visible
      outside the mask bbox.
      Setup: Masked orange rect with inner white mask rect. Uncheck
      Clip.
      Do: Observe.
      Expect: The entire orange rect is visible (outside the inner
      rect's bbox the element renders at full opacity; inside the
      bbox the element composites against the mask).
      — last: —

- [ ] **OP-211** [wired] `clip=true, invert=true` — element visible
      outside the mask shape only.
      Setup: Masked orange rect with inner white mask rect. Check
      Invert Mask.
      Do: Observe.
      Expect: Orange rect is visible everywhere EXCEPT inside the
      inner white rect.
      — last: —

- [ ] **OP-212** [wired] Disabling the mask renders the element fully.
      Setup: Masked orange rect with inner white mask rect.
      Do: Open hamburger → Disable Opacity Mask.
      Expect: Whole orange rect becomes visible — disabled mask
      composites as if absent.
      — last: —

### P2

- [ ] **OP-220** [wired] Alt-click MASK_PREVIEW enters isolation.
      Setup: Masked orange rect with inner white mask rect.
      Do: Alt-click MASK_PREVIEW.
      Expect: Canvas shows only the white inner rect on an otherwise
      empty (white) background.
      — last: —

- [ ] **OP-221** [wired] Linked mask follows the element's transform.
      Setup: Masked orange rect with inner white mask rect; link state
      == linked.
      Do: Select the orange rect and drag it ~100px.
      Expect: The mask moves with the element; the visible clipped
      region remains inside the inner rect's (original-local) bounds
      relative to the element.
      — last: —

- [ ] **OP-222** [wired] Unlinked mask stays put while the element
      moves.
      Setup: Continue from OP-221; click LINK_INDICATOR to unlink.
      Do: Drag the element another ~100px.
      Expect: The mask stays where it was; the element moves past the
      mask region.
      — last: —

- [ ] **OP-223** [wired] Relink restores following.
      Setup: Continue from OP-222 with the element translated off the
      mask.
      Do: Click LINK_INDICATOR again to relink.
      Expect: The mask jumps back to track the element's current
      transform.
      — last: —

- [ ] **OP-224** [wired] Gray mask shape (jas_dioxus only).
      Setup: Masked orange rect. Enter mask-mode. Set fill to mid-
      gray (`#808080`). Draw a rect into the subtree.
      Do: Exit mask-mode. Observe.
      Expect (jas_dioxus, luminance): Inside the gray rect, the orange
      element is ~50% opaque. Other apps: 100% opaque (alpha-based).
      — last: —

- [ ] **OP-225** [wired] Empty mask renders invisible (clip=true).
      Setup: Masked orange rect with no mask subtree contents.
      Do: Observe.
      Expect: Orange rect is fully hidden (nothing to keep via
      `destination-in`). `clip=false` would reveal the element.
      — last: —

---

## Session J — Mask editor UI (~10 min)

### P0

- [ ] **OP-250** [wired] MASK_PREVIEW click enters mask-mode.
      Do: Masked orange rect. Click MASK_PREVIEW.
      Expect: Blue outline on MASK_PREVIEW; subsequent tool drawing
      will add to `element.mask.subtree` (tested below).
      — last: —

### P1

- [ ] **OP-251** [wired] Tool draws into mask subtree while in
      mask-mode.
      Setup: Masked orange rect. Click MASK_PREVIEW (mask-mode on).
      Do: Select the Rect tool; drag a small rect on top of the
      orange rect.
      Expect: The new rect is not added to the selected layer (top-
      level children count unchanged). The new rect appears as a
      child of the orange rect's `mask.subtree` (inspect via menu or
      canvas rendering).
      — last: —

- [ ] **OP-252** [wired] Tool draws into layer when in content-mode.
      Setup: Like OP-251 but click OPACITY_PREVIEW first to exit
      mask-mode.
      Do: Drag a rect.
      Expect: The new rect is a sibling of the orange rect in the
      layer.
      — last: —

- [ ] **OP-253** [wired] Escape exits mask-mode and restores content
      drawing.
      Setup: Masked orange rect in mask-mode.
      Do: Press Escape; draw a rect with the Rect tool.
      Expect: Outline flips to OPACITY_PREVIEW on Escape; new rect
      becomes a layer child, not a mask child.
      — last: —

### P2

- [ ] **OP-254** [wired] Mask-mode fallback when subtree root isn't a
      Group.
      Setup: Hand-craft a mask whose subtree root is a Rect (e.g.,
      via SVG import or JSON edit). Click MASK_PREVIEW.
      Do: Draw a new shape.
      Expect: Shape lands on the layer (fallback), not the mask. The
      fallback is intentional — we don't silently lose the stroke.
      — last: —

- [ ] **OP-255** [known-broken: OP-502] Selection after mask-routed
      add.
      Do: Continue from OP-251 with a just-drawn shape in the mask
      subtree.
      Expect: Selection points at the mask-target element (outer
      orange rect), not the new shape inside the subtree. Pressing
      Delete would delete the outer rect.
      — last: —

- [ ] **OP-256** [wired] Escape also exits mask isolation when
      active.
      Setup: Mask-mode + mask isolation both active.
      Do: Press Escape once, then again.
      Expect: First Escape clears isolation only; second clears
      mask-mode.
      — last: —

---

## Session K — Appearance theming (~5 min)

- [ ] **OP-280** [wired] Dark Gray appearance.
      Do: Appearance → Dark Gray. Observe the panel.
      Expect: No hardcoded light colors visible; preview outlines stay
      visible against the dark background; menu and chevron legible.
      — last: —

- [ ] **OP-281** [wired] Medium Gray appearance.
      Do: Switch to Medium Gray.
      Expect: Panel re-skins cleanly; no cut-off text; highlight
      accent remains distinguishable.
      — last: —

- [ ] **OP-282** [wired] Light Gray appearance.
      Do: Switch to Light Gray.
      Expect: Dark text on light background; blue accent outline
      still visible.
      — last: —

- [ ] **OP-283** [wired] Theme switch preserves panel state.
      Setup: Set blend mode Multiply, opacity 42, make a mask.
      Do: Switch appearance.
      Expect: Panel values unchanged post-switch.
      — last: —

---

## Session L — Cross-panel regressions (~5 min)

- [ ] **OP-300** [wired] Layers panel reflects mask on element.
      Setup: The masked orange rect.
      Do: Open the Layers panel.
      Expect: The rect row still renders normally (the mask field
      doesn't change layer-tree visuals in the current build — see
      OPACITY.md §Deferred additions for the eventual mask-preview
      column).
      — last: —

- [ ] **OP-301** [wired] Color panel doesn't leak blend_mode key.
      Do: Change opacity panel's BlendMode to Multiply. Open the
      Color panel.
      Expect: Color panel's own `mode` state (HSB / RGB / CMYK /
      grayscale / websafe_rgb) is independent — `blend_mode` / `mode`
      are separate keys per OPACITY.md design note.
      — last: —

- [ ] **OP-302** [wired] Align panel works normally with masked
      element selected.
      Setup: The masked orange rect + a second unmasked rect.
      Do: Select both. Align → Align Horizontal Center.
      Expect: Both rects align; the mask follows the first rect
      (linked mode).
      — last: —

---

## Session M — State persistence (per_document) (~5 min)

- [ ] **OP-320** [wired] `new_masks_clipping` survives within a
      session.
      Do: Menu → uncheck "New Opacity Masks Are Clipping". Create and
      release a mask. Reopen menu.
      Expect: "New Opacity Masks Are Clipping" still unchecked.
      — last: —

- [ ] **OP-321** [wired] `new_masks_inverted` survives within a
      session.
      Do: Menu → check "New Opacity Masks Are Inverted". Create a
      fresh mask.
      Expect: New mask's `invert` is true; Invert Mask checkbox
      checked.
      — last: —

- [ ] **OP-322** [wired] Document switch keeps per-session toggles per
      tab.
      Setup: Two docs open in tabs, both with distinct
      `new_masks_*` states.
      Do: Switch tabs; observe the Opacity panel menu.
      Expect: Each tab's menu reflects its own flags (per_document
      means per-document, not global).
      — last: —

---

## Session N — Cross-app parity (~15 min)

Run each parity test on all five apps. Batch by app (one full pass per
platform, not per test). Flask is generic; JasSwift / jas_ocaml / jas
(python) each have the native panel.

- **OP-400** [wired] Panel loads and the control row renders.
      Do: Open Opacity panel.
      Expect: BlendMode, "Opacity:" label, opacity input, disclosure
      chevron all visible in one row.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **OP-401** [wired] Make Mask + Release Mask round-trip.
      Do: Select a rect; click Make Mask; click Release.
      Expect: Mask is created then removed; button label flips
      correctly each time; CLIP / INVERT_MASK / LINK_INDICATOR
      enable on Make and disable on Release.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **OP-402** [wired] LINK_INDICATOR toggles `mask.linked`.
      Do: Masked rect. Click LINK_INDICATOR twice.
      Expect: Stored `mask.linked` flips true → false → true. Glyph
      flips on each click (Rust / Flask); Swift and Python show
      "Link mask transform" text either way (OP-503 / OP-104).
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **OP-403** [wired] MASK_PREVIEW plain click enters mask-mode.
      Do: Masked rect. Click MASK_PREVIEW.
      Expect: Blue outline moves from OPACITY_PREVIEW to
      MASK_PREVIEW; model.editing_target flips to Mask(path).
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      n/a (no canvas rendering surface)

- **OP-404** [wired] Escape exits mask-mode.
      Do: In mask-mode, press Escape.
      Expect: Outline returns to OPACITY_PREVIEW;
      model.editing_target becomes Content.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      n/a

- **OP-405** [wired] Tool routes into mask subtree when in mask-mode.
      Do: Masked rect in mask-mode. Draw a new rect with the Rect
      tool.
      Expect: Layer children count unchanged; mask subtree gains one
      Group child (the new rect).
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      n/a

- **OP-406** [wired] `clip=true` white mask reveals the element.
      Do: Masked rect with inner white rect in the mask subtree.
      Expect: Element visible only inside the white rect's bounds.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      n/a

- **OP-407** [wired] `disabled` mask is treated as absent.
      Do: Continue; Disable Opacity Mask from the menu.
      Expect: Whole element becomes visible; menu checkmark (if any)
      reflects the disabled state.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      n/a

---

## Graveyard

_(empty — nothing retired yet)_

---

## Enhancements

_(empty — no non-blocking ideas raised yet)_
