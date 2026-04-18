# Character Panel — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source: `workspace/panels/character.yaml`.
Design doc: `transcripts/CHARACTER.md`. Holistic reference image: `examples/character.png`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other platforms covered in
Session I parity sweep.

---

## Known broken

_Last reviewed: —_

(None yet.)

---

## Automation coverage

_Last synced: 2026-04-18_

**Python — `jas/panels/character_panel_state_test.py`** (~60 tests)
- Value mapping: number formatting, text-decoration composition, caps/super/sub
  precedence, style-name → font-weight/font-style, leading/tracking/kerning,
  rotation/scale identity, language/anti-aliasing.
- Write flow: panel → selected text, caret vs range routing, subscribe/notify.
- Template building: pending-template, full-overrides, complex attrs.
- Tspan range writes: partial-word bold, empty range passthrough, adjacent merge.
- Identity omission: font-weight, line-height, end-to-end per-range writes.

**Swift — `JasSwift/Tests/Interpreter/CharacterPanelSyncTests.swift`** (~30 tests)
- Mirror of the Python suite: live overrides (empty / non-text / text / leading
  auto / textPath), notify routing, kerning named modes, applyCharacterPanel
  writes to selection, templates, pending routing, full overrides, tspan range
  writes, identity omission.

**OCaml — no dedicated Character suite.**
Character behavior covered transitively in `jas_ocaml/test/interpreter/effects_test.ml`,
`state_store_test.ml`, and `jas_ocaml/test/panels/panel_menu_test.ml`. Shallow.

**Rust — no automated Character coverage.**
Manual suite is the only gate today.

**Flask — generic; no Character-specific auto-tests.**
Character panel is fully specified in yaml; Flask interprets the yaml directly.

The manual suite below covers what auto-tests do NOT: actual widget rendering,
typeahead, focus / tab order, menu UI, appearance theming, visual correctness
of the text on canvas, panel lifecycle, cross-panel regressions.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default workspace with no document loaded.
3. Open the Character panel via Window → Character (or equivalent).
4. Appearance: **Dark** (`workspace/appearances/`).

Tests that need a text selection, multi-tspan content, or another appearance
will state the delta in their `Setup:` line.

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

| Session | Topic                          | Est.  | IDs        |
|---------|--------------------------------|-------|------------|
| A       | Smoke & lifecycle              | ~5m   | 001–009    |
| B       | Font family & style            | ~8m   | 010–029    |
| C       | Numeric inputs                 | ~15m  | 030–069    |
| D       | Character toggles              | ~6m   | 070–089    |
| E       | Language & anti-aliasing       | ~4m   | 090–099    |
| F       | Snap to Glyph                  | ~8m   | 100–129    |
| G       | Menu                           | ~6m   | 130–149    |
| H       | Appearance theming             | ~5m   | 150–169    |
| I       | Cross-app parity               | ~20m  | 200–249    |

Full pass: ~75 min. Partial runs are useful — each session stands alone.

---

## Session A — Smoke & lifecycle (~5 min)

If any P0 here fails, stop and flag. Downstream sessions will only produce noise.

- [ ] **CHR-001** [placeholder] Panel opens via Window menu.
      Do: Select Window → Character.
      Expect: Character panel appears in the dock or as a floating panel; no
              console error; no visual glitch.
      — last: —

- [ ] **CHR-002** [placeholder] All 25 controls render without layout collapse.
      Do: Visually scan the open Character panel.
      Expect: Font family + Style name dropdowns; 8 numeric fields with icons
              (size, leading, kerning, tracking, V-scale, H-scale, baseline
              shift, rotation); 6 character toggle icons; Language +
              Anti-aliasing dropdowns; Snap to Glyph header; 6 Snap toggle
              icons. No overlapping controls, no truncated labels.
      — last: —

- [ ] **CHR-003** [placeholder] Layout matches `examples/character.png`.
      Do: Compare panel to `examples/character.png` at default appearance (Dark).
      Expect: Holistic match — groupings, spacing, icon positions align with
              the reference.
      — last: —

- [ ] **CHR-004** [placeholder] Panel closes via menu.
      Do: Open panel menu; select "Close Character".
      Expect: Panel removed from dock / floating area. No error.
      — last: —

- [ ] **CHR-005** [placeholder] Opening Character doesn't break other panels.
      Setup: Open Layers and Color panels in addition to default layout.
      Do: Open Character panel.
      Expect: Layers + Color panels remain rendered and interactive;
              dock layout adjusts without collapsing any panel.
      — last: —

---

## Session B — Font family & style (~8 min)

**P1**

- [ ] **CHR-010** [placeholder] Font family dropdown lists 9 options in yaml order.
      Do: Click Font family dropdown.
      Expect: Dropdown opens with sans-serif, serif, monospace, Arial,
              Helvetica, Times New Roman, Courier New, Georgia, Verdana —
              in that order.
      — last: —

- [ ] **CHR-011** [placeholder] Font family typeahead filters the list.
      Do: Click dropdown; type "ar".
      Expect: List narrows to matching entries (Arial at minimum).
      — last: —

- [ ] **CHR-012** [placeholder] Font family selection commits via click.
      Do: Open dropdown; click "Georgia".
      Expect: Dropdown closes; field shows "Georgia" as current value.
      — last: —

- [ ] **CHR-013** [placeholder] Selection persists across panel close/reopen.
      Do: Set font to Georgia; close panel; reopen.
      Expect: Font field still shows "Georgia".
      — last: —

- [ ] **CHR-015** [placeholder] Style name dropdown lists 4 options.
      Do: Click Style name dropdown.
      Expect: Regular, Italic, Bold, Bold Italic.
      — last: —

- [ ] **CHR-016** [placeholder] Style name selection commits.
      Do: Select "Bold Italic".
      Expect: Dropdown closes; field shows "Bold Italic".
      — last: —

**P2**

- [ ] **CHR-017** [placeholder] Font dropdown keyboard navigation.
      Do: Open Font family dropdown; press ↓ three times; press Enter.
      Expect: Third option in list commits (likely "monospace").
      — last: —

- [ ] **CHR-018** [placeholder] Escape closes open dropdown without committing.
      Do: Open Font family dropdown; press Escape.
      Expect: Dropdown closes; field value unchanged from before open.
      — last: —

- [ ] **CHR-019** [placeholder] Tab moves focus between Font family and Style.
      Do: Focus Font family; press Tab.
      Expect: Focus moves to Style name dropdown.
      — last: —

---

## Session C — Numeric inputs (~15 min)

Covers 8 numeric / combo controls: size, leading, kerning, tracking, V-scale,
H-scale, baseline shift, rotation.

**P1**

- [ ] **CHR-030** [placeholder] Font size accepts valid value; commits on Enter.
      Do: Enter 24 in Font size; press Enter.
      Expect: Field shows 24.
      — last: —

- [ ] **CHR-031** [placeholder] Font size rejects out-of-range values.
      Do: Enter 0 then press Enter; then enter 1297 then Enter.
      Expect: Per yaml min: 1, max: 1296. Both rejected or clamped; field
              stays within bounds.
      — last: —

- [ ] **CHR-032** [placeholder] Leading accepts numeric, commits.
      Do: Enter 18 in Leading; press Enter.
      Expect: Field shows 18.
      — last: —

- [ ] **CHR-033** [placeholder] Leading 14.4 = Auto default per yaml.
      Do: Observe Leading field at first open (default state).
      Expect: Value is 14.4 (Auto = 120% of default 12pt font size).
              (Full spec specifies parens-wrap for Auto display — not required
              until that UX lands.)
      — last: —

- [ ] **CHR-034** [placeholder] Kerning combo_box opens and lists options.
      Do: Click Kerning control.
      Expect: Opens showing Auto, Optical, Metrics, 0, 25, 50, 100.
      — last: —

- [ ] **CHR-035** [placeholder] Kerning accepts named modes verbatim.
      Do: Select "Optical".
      Expect: Field shows "Optical" (text not converted to a number).
      — last: —

- [ ] **CHR-036** [placeholder] Kerning accepts free numeric entry.
      Do: Type "75" into Kerning and press Enter.
      Expect: Field shows 75 (or "75"); value accepted as numeric per yaml.
      — last: —

- [ ] **CHR-037** [placeholder] Tracking accepts positive value.
      Do: Enter 100 in Tracking.
      Expect: Field shows 100.
      — last: —

- [ ] **CHR-038** [placeholder] Tracking accepts negative value.
      Do: Enter -50 in Tracking.
      Expect: Field shows -50 (signed per yaml).
      — last: —

- [ ] **CHR-039** [placeholder] V-scale accepts valid percentage.
      Do: Enter 150 in Vertical scale.
      Expect: Field shows 150.
      — last: —

- [ ] **CHR-040** [placeholder] V-scale rejects out-of-range.
      Do: Enter 0 then 10001.
      Expect: Per yaml min: 1, max: 10000. Both rejected or clamped.
      — last: —

- [ ] **CHR-041** [placeholder] H-scale accepts valid percentage.
      Do: Enter 150 in Horizontal scale.
      Expect: Field shows 150.
      — last: —

- [ ] **CHR-042** [placeholder] H-scale rejects out-of-range.
      Do: Enter 0 then 10001.
      Expect: Both rejected or clamped.
      — last: —

- [ ] **CHR-043** [placeholder] Baseline shift accepts positive (up).
      Do: Enter 5 in Baseline shift.
      Expect: Field shows 5 (positive = up per SVG convention noted in yaml).
      — last: —

- [ ] **CHR-044** [placeholder] Baseline shift accepts negative (down).
      Do: Enter -5.
      Expect: Field shows -5.
      — last: —

- [ ] **CHR-045** [placeholder] Character rotation accepts positive (clockwise).
      Do: Enter 15 in Character rotation.
      Expect: Field shows 15 (positive = clockwise per yaml).
      — last: —

- [ ] **CHR-046** [placeholder] Character rotation accepts negative.
      Do: Enter -15.
      Expect: Field shows -15.
      — last: —

**P2**

- [ ] **CHR-047** [placeholder] Blur commits value (parity with Enter).
      Do: Enter 18 in Font size; click outside the field.
      Expect: Field shows 18; value committed.
      — last: —

- [ ] **CHR-048** [placeholder] Non-numeric input rejected in numeric fields.
      Do: Attempt to enter "abc" into Font size.
      Expect: Either input blocked, or value reverts on blur.
      — last: —

- [ ] **CHR-049** [placeholder] Numeric-field icons render.
      Do: Visually check the 8 icons left of each numeric field (char_size,
          char_leading, char_kerning, char_tracking, char_vertical_scale,
          char_horizontal_scale, char_baseline_shift, char_rotation).
      Expect: All 8 icons visible at 20×20 per yaml; none missing or broken.
      — last: —

---

## Session D — Character toggles (~6 min)

**P1**

- [ ] **CHR-070** [placeholder] All Caps toggles off ↔ on.
      Do: Click All Caps; click again.
      Expect: First click turns on; second click turns off. Panel state
              (visible via menu checkmark) reflects the change.
      — last: —

- [ ] **CHR-071** [placeholder] Small Caps toggles.
      Do: Click Small Caps twice.
      Expect: On → off via visible state change.
      — last: —

- [ ] **CHR-072** [placeholder] Superscript toggles.
      Do: Click Superscript twice.
      Expect: On → off.
      — last: —

- [ ] **CHR-073** [placeholder] Subscript toggles.
      Do: Click Subscript twice.
      Expect: On → off.
      — last: —

- [ ] **CHR-074** [placeholder] Underline toggles.
      Do: Click Underline twice.
      Expect: On → off.
      — last: —

- [ ] **CHR-075** [placeholder] Strikethrough toggles.
      Do: Click Strikethrough twice.
      Expect: On → off.
      — last: —

**P2**

- [ ] **CHR-076** [placeholder] Toggle-on visual state is distinct from off.
      Do: Turn All Caps on; observe control.
      Expect: Highlighted background (per CHARACTER.md icon_toggle spec) vs
              flat background when off.
      — last: —

- [ ] **CHR-077** [placeholder] All + Small Caps can both be on (mutex not enforced).
      Do: Turn on both All Caps and Small Caps.
      Expect: Both show "on" state. Per yaml, mutex is "not enforced yet"; this
              test flips to verifying mutex enforcement when the yaml updates.
      — last: —

- [ ] **CHR-078** [placeholder] Super + Sub can both be on (mutex not enforced).
      Do: Turn on both Superscript and Subscript.
      Expect: Both show "on" state. Same caveat as CHR-077.
      — last: —

- [ ] **CHR-079** [placeholder] Six toggle icons render correctly.
      Do: Visually scan the toggle row.
      Expect: 6 distinct icons (char_all_caps, char_small_caps, char_superscript,
              char_subscript, char_underline, char_strikethrough) at 28×24 per
              yaml; none missing or swapped.
      — last: —

---

## Session E — Language & anti-aliasing (~4 min)

- [ ] **CHR-090** [placeholder] Language dropdown lists 25 options including "(none)".
      Do: Click Language dropdown.
      Expect: First option is "(none)" with empty value; then 24 named
              languages per yaml (en English, fr French, ..., zh Chinese).
      — last: —

- [ ] **CHR-091** [placeholder] Language selection commits.
      Do: Select "Japanese".
      Expect: Field shows "Japanese"; internally the stored value is "ja"
              (per yaml note: dropdown shows name, value is ISO 639-1 code).
      — last: —

- [ ] **CHR-092** [placeholder] Anti-aliasing dropdown lists 5 options.
      Do: Click Anti-aliasing dropdown.
      Expect: None, Sharp, Crisp, Strong, Smooth.
      — last: —

- [ ] **CHR-093** [placeholder] Anti-aliasing selection commits.
      Do: Select "Smooth".
      Expect: Field shows "Smooth".
      — last: —

---

## Session F — Snap to Glyph (~8 min)

**P1**

- [ ] **CHR-100** [placeholder] Snap to Glyph section visible by default.
      Do: Open panel at default state.
      Expect: Snap to Glyph header + 6 snap toggles visible below the
              language/AA row (per yaml `snap_to_glyph_visible` default: true).
      — last: —

- [ ] **CHR-101** [placeholder] Snap: Baseline toggles off ↔ on.
      Do: Click Snap: Baseline twice.
      Expect: On → off.
      — last: —

- [ ] **CHR-102** [placeholder] Snap: x-Height toggles.
      Do: Click x-Height twice.
      Expect: On → off.
      — last: —

- [ ] **CHR-103** [placeholder] Snap: Glyph Bounds toggles.
      Do: Click Glyph Bounds twice.
      Expect: On → off.
      — last: —

- [ ] **CHR-104** [placeholder] Snap: Proximity Guides toggles.
      Do: Click Proximity Guides twice.
      Expect: On → off.
      — last: —

- [ ] **CHR-105** [placeholder] Snap: Angular Guides toggles.
      Do: Click Angular Guides twice.
      Expect: On → off.
      — last: —

- [ ] **CHR-106** [placeholder] Snap: Anchor Point toggles.
      Do: Click Anchor Point twice.
      Expect: On → off.
      — last: —

**P2**

- [ ] **CHR-107** [placeholder] Snap header renders label + indicator + info icon.
      Do: Visually check Snap to Glyph header row.
      Expect: "Snap to Glyph" text label (col-6), indicator icon
              (char_snap_glyph at 20×20), info icon (char_info at 18×18,
              50% opacity).
      — last: —

- [ ] **CHR-108** [placeholder] Six Snap toggle icons render correctly.
      Do: Visually scan the snap toggle row.
      Expect: 6 distinct icons (char_snap_baseline, char_snap_x_height,
              char_snap_glyph_bounds, char_snap_proximity, char_snap_angular,
              char_snap_anchor) at 28×24; none missing or swapped.
      — last: —

---

## Session G — Menu (~6 min)

**P1**

- [ ] **CHR-130** [placeholder] Panel menu opens.
      Do: Click panel menu affordance (wheel / kebab / platform-appropriate).
      Expect: Menu opens showing the 6 items + 2 separators per yaml.
      — last: —

- [ ] **CHR-131** [placeholder] "Show Snap to Glyph Options" toggles section visibility.
      Do: Open menu; click "Show Snap to Glyph Options"; reopen menu if
          closed; click again.
      Expect: First click hides the entire Snap to Glyph section in the
              panel body; second click shows it.
      — last: —

- [ ] **CHR-132** [placeholder] "Show Snap to Glyph Options" checkmark reflects panel state.
      Do: With Snap section visible, open menu; verify checkmark on
          "Show Snap to Glyph Options". Hide section; reopen; verify no
          checkmark.
      Expect: Checkmark mirrors `panel.snap_to_glyph_visible`.
      — last: —

- [ ] **CHR-133** [placeholder] "All Caps" menu item toggles panel state and shows checkmark.
      Do: Open menu; click "All Caps"; reopen menu.
      Expect: Menu shows a checkmark; in-panel All Caps toggle also shows on
              state. Click menu entry again; state and checkmark turn off.
      — last: —

- [ ] **CHR-134** [placeholder] "Small Caps" / "Superscript" / "Subscript" menu items behave same as CHR-133.
      Do: Repeat CHR-133 for each of the three remaining toggle menu items.
      Expect: Each toggles its panel state + shows a checkmark in the menu.
      — last: —

- [ ] **CHR-135** [placeholder] Menu separators render correctly.
      Do: Visually check menu structure.
      Expect: Separator between "Show Snap to Glyph Options" and the toggle
              group; separator before "Close Character".
      — last: —

- [ ] **CHR-136** [placeholder] "Close Character" closes the panel.
      Do: Open menu; click "Close Character".
      Expect: Panel closes.
      — last: —

**P2**

- [ ] **CHR-137** [placeholder] Escape closes the menu.
      Do: Open menu; press Escape.
      Expect: Menu closes; no action taken.
      — last: —

- [ ] **CHR-138** [placeholder] Clicking outside closes the menu.
      Do: Open menu; click anywhere outside the menu surface.
      Expect: Menu closes.
      — last: —

---

## Session H — Appearance theming (~5 min)

**P1**

- [ ] **CHR-150** [placeholder] Dark appearance renders correctly.
      Setup: Set appearance to Dark.
      Do: Open Character panel.
      Expect: Panel bg/fg colors match Dark tokens; all controls legible;
              icon colors reflect Dark theme.
      — last: —

- [ ] **CHR-151** [placeholder] Medium Gray appearance renders correctly.
      Setup: Switch to Medium Gray.
      Do: Open / observe Character panel.
      Expect: Panel uses Medium Gray tokens; controls legible; icons adapt.
      — last: —

- [ ] **CHR-152** [placeholder] Light Gray appearance renders correctly.
      Setup: Switch to Light Gray.
      Do: Observe panel.
      Expect: Panel uses Light Gray tokens; controls legible; icons adapt.
      — last: —

**P2**

- [ ] **CHR-153** [placeholder] Switching appearance mid-session doesn't break panel.
      Do: With panel open, cycle Dark → Medium Gray → Light Gray → Dark.
      Expect: Each transition re-themes the panel without layout reflow,
              dropped widgets, or console error.
      — last: —

- [ ] **CHR-154** [placeholder] Appearance applies to dropdown open state.
      Do: In each appearance, open Font family dropdown; observe open-state colors.
      Expect: Open-state bg/selection highlight uses appearance-specific tokens;
              consistent per-appearance.
      — last: —

- [ ] **CHR-155** [placeholder] Appearance applies to toggle highlighted state.
      Do: In each appearance, enable All Caps; observe toggle colors.
      Expect: Highlighted-toggle bg uses appearance-specific tokens; contrast
              preserved in all three.
      — last: —

---

## Session I — Cross-app parity (~20 min, optional)

Run each test on each platform. Batch by app for efficiency — open Rust, run
all 7; then Swift; etc. All tests are `[wired]`: if the yaml description
"no control is yet wired to per-tspan attributes on the selection" is still
accurate, most of these will fail today. That failure is itself informative —
it tells us whether wiring has landed.

Rust builds are user-managed; ensure a fresh build before running the Rust column.

- **CHR-200** [wired] Kerning "0" round-trips to empty element attr (identity omission).
      Setup: Select a text element.
      Do: Enter "0" in Kerning; blur.
      Expect: Panel shows "0"; element's kerning attribute becomes empty
              (not "0em"), per yaml ch_kerning description.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **CHR-201** [wired] Leading at Auto default (14.4 for 12pt) → empty element attr.
      Setup: Select a text element with font-size 12.
      Do: Ensure Leading = 14.4.
      Expect: Element line-height attr empty (default omitted per identity rule).
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **CHR-202** [wired] Text-decoration composition with alphabetical order.
      Setup: Text element selected.
      Do: Turn on both Underline and Strikethrough.
      Expect: Element text-decoration attr = "line-through underline"
              (alphabetical order, both present).
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **CHR-203** [wired] Caps precedence: All Caps wins over Small Caps.
      Setup: Text element selected.
      Do: Turn on both All Caps and Small Caps.
      Expect: Element text-transform attr = "uppercase" (All Caps), not
              "small-caps". Per TestCapsAndBaseline auto-tests.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **CHR-204** [wired] Super/sub precedence over numeric baseline-shift.
      Setup: Text element selected.
      Do: Enter 5 in Baseline shift; then turn on Superscript.
      Expect: Element baseline-shift attr represents Superscript (per
              test_baseline_shift_skipped_when_super_on); numeric 5 is
              suppressed in the pending template.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **CHR-205** [wired] Style name "Bold Italic" decomposes to weight + style.
      Setup: Text element selected.
      Do: Set Style name to "Bold Italic".
      Expect: Element font-weight = "bold" AND font-style = "italic".
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- **CHR-206** [wired] Kerning named mode "Optical" passes through verbatim.
      Setup: Text element selected.
      Do: Select "Optical" in Kerning.
      Expect: Element kerning attr = "Optical" (not serialised to a numeric
              em value), per yaml ch_kerning description.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

---

## Graveyard

Inactive tests. Categories: `[wontfix: <reason>]`, `[duplicate: <canonical-ID>]`,
`[retired: <reason>]`. Tests move here but keep their IDs forever.

### Won't fix

(None.)

### Duplicate

(None.)

### Retired

(None.)
