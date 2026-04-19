# Paragraph Panel — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/panels/paragraph.yaml`, plus `workspace/dialogs/paragraph_justification.yaml`
and `workspace/dialogs/paragraph_hyphenation.yaml`.
Design doc: `transcripts/PARAGRAPH.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other platforms covered in
Session L parity sweep.

---

## Known broken

_Last reviewed: 2026-04-19_

_No known-broken items. Phase 11 parity harness shipped green; any regressions
surfaced here become entries._

---

## Automation coverage

_Last synced: 2026-04-19_

**Python — `jas/panels/paragraph_panel_state_test.py`** (~29 tests)
- Panel → selection: alignment radio mutual exclusion, bullets / numbered-list
  write the same `jas:list-style` attribute.
- Indent / space: left / right / first-line / space-before / space-after
  numeric writes, identity-omission.
- Hyphenate master + hanging-punctuation menu toggle.
- Phase 8 Justification dialog apply: non-default attrs write, all-defaults
  writes nothing.
- Phase 9 Hyphenation dialog apply: master mirror to panel.hyphenate, identity
  omission of default values.

**Swift — `JasSwift/Tests/Interpreter/ParagraphPanelSyncTests.swift`** (~24 tests)
- Mirror of the Python suite: selection-change sync, alignment mutual
  exclusion, list-style mutual exclusion, indent / space writes, Justification
  and Hyphenation dialog apply (incl. master mirror).

**OCaml — `jas_ocaml/test/interpreter/effects_test.ml` (paragraph section)**
- `paragraph_text_kind_tests`: selection-change toggles `text_selected` /
  `area_text_selected`.
- `paragraph_phase4_tests`: selection-change writes + mutual exclusion.
- `paragraph_phase8_tests`: Justification apply (non-default + all-default).
- `paragraph_phase9_tests`: Hyphenation apply + master mirror.

**Rust — no dedicated paragraph panel-sync auto-tests.**
Coverage lives in `jas_dioxus/src/workspace/app_state.rs` tests (selection
sync), `jas_dioxus/src/interpreter/renderer.rs` dialog apply tests, and the
cross-language parity fixture `test_fixtures/algorithms/text_layout_paragraph.json`
(24 vectors, 72 / 72 cross-lang comparisons green as of 2026-04-19).

**Flask — generic; no Paragraph-specific auto-tests.**
Paragraph panel and its two dialogs are fully specified in yaml; Flask
interprets the yaml directly, no panel-specific write path exists.

The manual suite below covers what auto-tests don't: widget rendering, radio
mutual-exclusion display, dropdown interactions, dialog modality, menu
interaction, dock/float, appearance theming, visual correctness on canvas.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default workspace with no document loaded.
3. Open the Paragraph panel via Window → Paragraph (or the default layout's
   docked location).
4. Appearance: **Dark** (`workspace/appearances/`).

Tests that need an area-text element, a specific selection, or another
appearance state the delta in their `Setup:` line. When a test calls for an
area-text fixture the default is: Type tool → drag a 400×200 frame →
type `Lorem ipsum dolor sit amet consectetur adipiscing elit` → Esc.

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

| Session | Topic                              | Est.  | IDs        |
|---------|------------------------------------|-------|------------|
| A       | Smoke & lifecycle                  | ~5m   | 001–009    |
| B       | Alignment radio group              | ~8m   | 010–029    |
| C       | Lists — bullets + numbered         | ~8m   | 030–049    |
| D       | Indents — left / right / first-line| ~10m  | 050–079    |
| E       | Spacing — space-before / after     | ~5m   | 080–099    |
| F       | Hyphenate checkbox + menu          | ~5m   | 100–119    |
| G       | Menu — Hanging Punct, Reset Panel  | ~5m   | 120–139    |
| H       | Justification dialog               | ~12m  | 140–179    |
| I       | Hyphenation dialog                 | ~12m  | 180–219    |
| J       | Text-kind gating                   | ~5m   | 220–239    |
| K       | Appearance theming                 | ~5m   | 240–259    |
| L       | Cross-app parity                   | ~15m  | 300–329    |

Full pass: ~95 min. Partial runs are useful — each session stands alone; A
gates the rest.

---

## Session A — Smoke & lifecycle (~5 min)

If any P0 here fails, stop and flag.

- [ ] **PG-001** [wired] Panel opens via Window menu.
      Do: Select Window → Paragraph.
      Expect: Paragraph panel appears in the dock or as a floating panel; no
              console error; no visual glitch.
      — last: —

- [ ] **PG-002** [wired] All panel controls render without layout collapse.
      Do: Visually scan the open Paragraph panel.
      Expect: 7 alignment icons, Bullets + Numbered List dropdowns, Left /
              Right / First-Line indent rows, Space Before / Space After row,
              Hyphenate checkbox. No overlapping controls, no truncated
              labels, padding matches PARAGRAPH.md §Layout.
      — last: —

- [ ] **PG-003** [wired] Panel collapses and re-expands.
      Do: Click the panel header to collapse; click again to expand.
      Expect: Content hides / reveals; header stays visible; no crash.
      — last: —

- [ ] **PG-004** [wired] Panel closes via context menu / X button.
      Do: Right-click header → Close, or click the close affordance.
      Expect: Panel disappears; Window → Paragraph now toggles it back on.
      — last: —

- [ ] **PG-005** [wired] Panel floats out of the dock.
      Do: Drag the panel header out of the dock.
      Expect: Panel becomes a floating window at cursor; content still
              interactive; returns to dock on drag back.
      — last: —

---

## Session B — Alignment radio group (~8 min)

**P0**

- [ ] **PG-010** [wired] Default alignment on empty state is Align Left.
      Setup: No selection.
      Do: Open the panel.
      Expect: `pg_align_left` icon is checked (filled / highlighted); the
              other six alignment buttons are unchecked.
      — last: —

- [ ] **PG-011** [wired] Click each alignment icon — exactly one stays checked.
      Setup: Area-text fixture, paragraph selected.
      Do: Click Align Center.
      Expect: Only `pg_align_center` is checked; Align Left unchecks;
              canvas reflows to center.
      — last: —

- [ ] **PG-012** [wired] Align Left re-selects from any other alignment.
      Setup: Area-text with Align Right active.
      Do: Click Align Left.
      Expect: Only `pg_align_left` checked; selection reflows left-aligned
              with ragged right edge.
      — last: —

**P1**

- [ ] **PG-013** [wired] Align Center reflows selection.
      Setup: Area text with multiple lines.
      Do: Click `pg_align_center`.
      Expect: Every line's midpoint within the wrapping frame; both edges
              ragged.
      — last: —

- [ ] **PG-014** [wired] Align Right reflows selection.
      Setup: Area text with multiple lines.
      Do: Click `pg_align_right`.
      Expect: Every line's right edge flush to the frame's right edge; left
              edge ragged.
      — last: —

- [ ] **PG-015** [wired] Justify Left stretches body lines only.
      Setup: Area text with 3+ lines.
      Do: Click `pg_justify_left`.
      Expect: All lines except the last stretch to both edges with inter-word
              spacing adjusted; last line stays left-aligned with natural
              spacing.
      — last: —

- [ ] **PG-016** [wired] Justify Center last-line behavior.
      Setup: Area text with 3+ lines.
      Do: Click `pg_justify_center`.
      Expect: Body lines fill the frame; last line is centered.
      — last: —

- [ ] **PG-017** [wired] Justify Right last-line behavior.
      Setup: Area text with 3+ lines.
      Do: Click `pg_justify_right`.
      Expect: Body lines fill the frame; last line is right-aligned.
      — last: —

- [ ] **PG-018** [wired] Justify All forces the last line too.
      Setup: Area text with 3+ lines.
      Do: Click `pg_justify_all`.
      Expect: Every line fills the frame including the last — inter-word
              spacing on the last line visibly wider than natural.
      — last: —

**P2**

- [ ] **PG-019** [wired] Switching between Justify variants updates text-align-last only.
      Setup: Justify Left active, selection justified.
      Do: Click Justify Center.
      Expect: Body lines keep their existing break points; only the last line
              visually shifts.
      — last: —

- [ ] **PG-020** [wired] Alignment buttons are 24×22 per yaml.
      Do: Inspect icon dimensions (browser DevTools or visual).
      Expect: Buttons render at 24×22 px with intended center alignment.
      — last: —

---

## Session C — Lists — bullets + numbered (~8 min)

**P0**

- [ ] **PG-030** [wired] Bullets dropdown opens and shows 7 options.
      Setup: Area text selected.
      Do: Click `pg_bullets`.
      Expect: Dropdown shows: None, •   Disc, ○   Open Circle, ■   Square,
              □   Open Square, –   Dash, ✓   Check (with glyph preview).
      — last: —

- [ ] **PG-031** [wired] Numbered List dropdown opens and shows 6 options.
      Setup: Area text selected.
      Do: Click `pg_numbered_list`.
      Expect: Dropdown shows: None, 1.   Decimal, a.   Lower Alpha,
              A.   Upper Alpha, i.   Lower Roman, I.   Upper Roman.
      — last: —

**P1**

- [ ] **PG-032** [wired] Selecting a bullet renders the marker glyph.
      Setup: Area text with 2 paragraphs selected.
      Do: Bullets → •   Disc.
      Expect: Each paragraph gains a disc marker at its left; text is pushed
              right by the 12pt marker gap.
      — last: —

- [ ] **PG-033** [wired] Selecting a numbered style renders counters.
      Setup: Three paragraphs selected.
      Do: Numbered List → 1.   Decimal.
      Expect: Paragraphs render "1." "2." "3." with the counter gap before
              each body; counter indices follow §Counter run rule.
      — last: —

- [ ] **PG-034** [wired] Bullets and Numbered List are mutually exclusive.
      Setup: Area text with Bullets → •   Disc active.
      Do: Numbered List → 1.   Decimal.
      Expect: Bullets dropdown snaps back to None; canvas markers change from
              discs to decimal counters.
      — last: —

- [ ] **PG-035** [wired] Selecting None clears the marker.
      Setup: Area text with Numbered List active.
      Do: Numbered List → None.
      Expect: Counters disappear; text reflows to the left edge without
              marker gap.
      — last: —

**P2**

- [ ] **PG-036** [wired] Counter resets when style changes mid-run.
      Setup: Four paragraphs; first three "Decimal", fourth "Lower Alpha".
      Do: Observe counters.
      Expect: "1. 2. 3." then "a." (not "d.").
      — last: —

- [ ] **PG-037** [wired] Counter continues across identical-style paragraphs.
      Setup: Three consecutive Decimal paragraphs.
      Do: Observe.
      Expect: "1. 2. 3." — no reset.
      — last: —

- [ ] **PG-038** [wired] Counter resets after a non-list paragraph breaks the run.
      Setup: Decimal paragraph, no-style paragraph, Decimal paragraph.
      Do: Observe.
      Expect: "1." then blank, then "1." (new run).
      — last: —

---

## Session D — Indents (left / right / first-line) (~10 min)

**P0**

- [ ] **PG-050** [wired] Left Indent accepts positive values only.
      Setup: Area text selected.
      Do: Enter "24" into `pg_left_indent`.
      Expect: Field accepts 24; every line of the selection shifts right by
              24pt.
      — last: —

- [ ] **PG-051** [wired] Right Indent narrows wrap width.
      Setup: Area text, one long line selected.
      Do: Enter "36" into `pg_right_indent`.
      Expect: Lines wrap 36pt before the previous right edge; text doesn't
              shift x, just wraps earlier.
      — last: —

- [ ] **PG-052** [wired] First-Line Indent shifts only the first line.
      Setup: Area text with 3+ lines.
      Do: Enter "24" into `pg_first_line_indent`.
      Expect: Line 1 starts 24pt to the right of the left-indent edge; lines
              2+ start at the normal left edge.
      — last: —

**P1**

- [ ] **PG-053** [wired] Negative First-Line Indent produces hanging indent.
      Setup: Area text, left_indent = 24, 3+ lines.
      Do: Enter "-12" into `pg_first_line_indent`.
      Expect: Line 1 starts 12pt to the left of lines 2+ (hang); no clipping.
      — last: —

- [ ] **PG-054** [wired] Indent writes commit on Enter.
      Setup: Area text selected.
      Do: Enter "36" then press Enter in `pg_left_indent`.
      Expect: Canvas reflows on Enter, not on every keystroke.
      — last: —

- [ ] **PG-055** [wired] Indent field reflects existing selection attributes.
      Setup: Select a paragraph wrapper with jas:left-indent=48.
      Do: Observe panel.
      Expect: `pg_left_indent` shows 48.
      — last: —

**P2**

- [ ] **PG-056** [wired] Upper bound 1296 enforced.
      Do: Enter "2000" into any indent field.
      Expect: Field clamps to 1296 or rejects the entry; no crash.
      — last: —

- [ ] **PG-057** [wired] Left Indent 0 removes the `jas:left-indent` attr.
      Setup: Area text with jas:left-indent=24 on wrapper.
      Do: Enter "0" into `pg_left_indent`.
      Expect: On save / re-render, the wrapper tspan no longer carries the
              attribute (identity-omission rule).
      — last: —

- [ ] **PG-058** [wired] First-line indent upper bound −1296 enforced.
      Do: Enter "-9999" into `pg_first_line_indent`.
      Expect: Field clamps to −1296 or rejects; no crash.
      — last: —

- [ ] **PG-059** [wired] Indents disabled when no area text is selected.
      Setup: Point text selected (Type tool, click without drag, type).
      Do: Observe.
      Expect: All three indent number inputs render dimmed /
              non-interactive.
      — last: —

---

## Session E — Spacing (space-before / space-after) (~5 min)

**P1**

- [ ] **PG-080** [wired] Space Before adds vertical gap above paragraph 2+.
      Setup: Area text with 2 paragraphs.
      Do: Select paragraph 2, enter "18" into `pg_space_before`.
      Expect: Vertical gap above paragraph 2 grows by 18pt; paragraph 1
              placement unchanged.
      — last: —

- [ ] **PG-081** [wired] Space Before is omitted before the first paragraph.
      Setup: Area text, first paragraph selected.
      Do: Enter "18" into `pg_space_before`.
      Expect: Attr writes to wrapper, but no visible y-offset at top (per
              PARAGRAPH.md §SVG attribute mapping first-paragraph rule).
      — last: —

- [ ] **PG-082** [wired] Space After adds gap below paragraph.
      Setup: Two paragraphs.
      Do: Select paragraph 1, enter "18" into `pg_space_after`.
      Expect: Vertical gap below paragraph 1 grows by 18pt.
      — last: —

**P2**

- [ ] **PG-083** [wired] Space Before + After accumulate.
      Setup: Three paragraphs; paragraph 1 space_after=10, paragraph 2
             space_before=14.
      Do: Observe.
      Expect: Gap between 1 and 2 = 24pt (they add, not max).
      — last: —

- [ ] **PG-084** [wired] Space upper bound 1296 enforced.
      Do: Enter "2000" into a space field.
      Expect: Clamp to 1296 or reject.
      — last: —

---

## Session F — Hyphenate checkbox (~5 min)

- [ ] **PG-100** [wired] Hyphenate checkbox defaults off.
      Setup: New empty workspace.
      Expect: `pg_hyphenate` is unchecked.
      — last: —

- [ ] **PG-101** [wired] Toggling Hyphenate writes `jas:hyphenate` on the wrapper.
      Setup: Area text selected.
      Do: Check `pg_hyphenate`.
      Expect: Wrapper tspan gains `jas:hyphenate="true"`; canvas may reflow
              if hyphen candidates exist.
      — last: —

- [ ] **PG-102** [wired] Hyphenate disabled when no area text is selected.
      Setup: Point text selected.
      Expect: `pg_hyphenate` is dimmed / non-interactive.
      — last: —

- [ ] **PG-103** [wired] Hyphenate master mirrors the dialog master.
      Setup: Area text selected, `pg_hyphenate` off.
      Do: Panel menu → Hyphenation… → check master → OK.
      Expect: After dialog closes, `pg_hyphenate` is now checked.
      — last: —

- [ ] **PG-104** [wired] Hyphenate off restores natural line breaks.
      Setup: Area text with hyphenation on and at least one hyphen rendered.
      Do: Uncheck `pg_hyphenate`.
      Expect: Hyphens disappear; lines re-break without them.
      — last: —

---

## Session G — Menu — Hanging Punctuation + Reset Panel (~5 min)

- [ ] **PG-120** [wired] Panel menu opens showing 4 items + 2 separators.
      Do: Click the panel menu affordance (hamburger / chevron).
      Expect: Items visible: Hanging Punctuation (checkbox), ─, Justification…,
              Hyphenation…, ─, Reset Panel.
      — last: —

- [ ] **PG-121** [wired] Hanging Punctuation toggles checkmark.
      Setup: Area text selected.
      Do: Menu → Hanging Punctuation.
      Expect: Checkmark appears; canvas offsets any hanger chars at line
              edges outside the effective edge.
      — last: —

- [ ] **PG-122** [wired] Hanging Punctuation menu item disabled without area text.
      Setup: No text selected.
      Expect: Menu item dimmed.
      — last: —

- [ ] **PG-123** [wired] Reset Panel clears every control to default.
      Setup: Panel with non-default values across alignment, indents, lists,
             space, hyphenate, hanging.
      Do: Menu → Reset Panel.
      Expect: Alignment returns to Align Left, indents 0, space 0, bullets
              None, numbered None, hyphenate off, hanging off; canvas removes
              the corresponding attrs per identity-omission.
      — last: —

- [ ] **PG-124** [wired] Justification… opens its dialog.
      Do: Menu → Justification…
      Expect: Modal dialog opens; rest of the app is non-interactive until
              the dialog closes.
      — last: —

- [ ] **PG-125** [wired] Hyphenation… opens its dialog.
      Do: Menu → Hyphenation…
      Expect: Modal dialog opens.
      — last: —

---

## Session H — Justification dialog (~12 min)

**P0**

- [ ] **PG-140** [wired] Dialog opens with 11 field rows + preview + OK/Cancel.
      Do: Panel menu → Justification…
      Expect: Rows for Word Spacing (min/desired/max), Letter Spacing
              (min/desired/max), Glyph Scaling (min/desired/max), Auto
              Leading, Single Word Justify; Preview checkbox + Cancel + OK
              at bottom.
      — last: —

- [ ] **PG-141** [wired] Dialog closes on Cancel without commit.
      Setup: Dialog open, word-spacing-min edited to 50.
      Do: Click Cancel.
      Expect: Dialog closes; wrapper attr unchanged; panel state unchanged.
      — last: —

**P1**

- [ ] **PG-150** [wired] Word Spacing Min/Desired/Max defaults 80 / 100 / 133.
      Do: Open dialog on a default wrapper.
      Expect: The three fields show 80, 100, 133 (as percentages).
      — last: —

- [ ] **PG-151** [wired] Letter Spacing defaults 0 / 0 / 0.
      Expect: Three fields show 0.
      — last: —

- [ ] **PG-152** [wired] Glyph Scaling defaults 100 / 100 / 100.
      Expect: Three fields show 100.
      — last: —

- [ ] **PG-153** [wired] Auto Leading defaults 120 (%).
      Expect: Field shows 120.
      — last: —

- [ ] **PG-154** [wired] Single Word Justify defaults "Full Justify".
      Expect: Dropdown shows "Full Justify".
      — last: —

- [ ] **PG-155** [wired] OK commits non-default word-spacing to wrapper attr.
      Setup: Area text with Justify Left active.
      Do: Dialog → Word Spacing Min = 60 → OK.
      Expect: Wrapper gains `jas:word-spacing-min="60"`; dialog closes;
              justified lines visibly shrink inter-word spacing further.
      — last: —

- [ ] **PG-156** [wired] OK omits default-matching fields.
      Setup: All dialog fields at their defaults.
      Do: Click OK.
      Expect: Wrapper has no `jas:word-spacing-*` / `jas:letter-spacing-*` /
              `jas:glyph-scaling-*` / `jas:auto-leading` / `jas:single-word-
              justify` attrs (identity-omission).
      — last: —

- [ ] **PG-157** [wired] Auto Leading overrides Character "Auto" leading
      per-paragraph.
      Setup: Area text, Character → Leading = Auto. Select paragraph.
      Do: Dialog → Auto Leading = 150 → OK.
      Expect: That paragraph's lines visibly gain vertical spacing (150% of
              font size vs default 120%); other paragraphs unchanged.
      — last: —

- [ ] **PG-158** [wired] Single Word Justify = "Full Justify" spreads a
      single-word line.
      Setup: Paragraph containing one long word on its own line, Justify All.
      Do: Dialog → Single Word Justify = Full Justify → OK.
      Expect: The single-word line renders with letter-spacing added to
              reach both margins.
      — last: —

**P2**

- [ ] **PG-160** [wired] Preview live-applies edits while dialog is open.
      Setup: Dialog open, Preview checked.
      Do: Type 60 into Word Spacing Min.
      Expect: Canvas reflows live; the edit visible before OK.
      — last: —

- [ ] **PG-161** [wired] Cancel after Preview rolls back (known limitation).
      Setup: Dialog open, Preview on, Word Spacing Min edited to 60.
      Do: Click Cancel.
      Expect: (Target behavior) canvas rolls back to pre-open state. (Current
              state: preview_targets harness limitation means rollback may be
              incomplete — note any regressions here.)
      — last: —

- [ ] **PG-162** [wired] Out-of-range input is clamped.
      Do: Enter "-50" into Word Spacing Desired.
      Expect: Field clamps to 0 or rejects; no crash.
      — last: —

---

## Session I — Hyphenation dialog (~12 min)

**P0**

- [ ] **PG-180** [wired] Dialog opens with master + 5 numeric rows + slider + capitalized.
      Do: Panel menu → Hyphenation…
      Expect: Master "Hyphenation" checkbox at top; numeric inputs for Words
              Longer Than / After First / Before Last / Hyphen Limit /
              Hyphenation Zone; 7-step bias slider (Better Spacing / Fewer
              Hyphens); Hyphenate Capitalized Words checkbox; Preview +
              Cancel + OK.
      — last: —

- [ ] **PG-181** [wired] Master off dims every sibling control.
      Setup: Dialog open with master off.
      Expect: All 7 sub-controls (5 numerics + slider + capitalized) render
              dimmed / non-interactive.
      — last: —

- [ ] **PG-182** [wired] Master on re-enables siblings.
      Setup: Dialog open with master off.
      Do: Check the master.
      Expect: All 7 sub-controls become interactive at their current values.
      — last: —

**P1**

- [ ] **PG-190** [wired] Defaults per spec: 3 / 1 / 1 letters, 0 / 0 pt, bias 0, capitalized off.
      Expect: Field values match.
      — last: —

- [ ] **PG-191** [wired] OK commits non-default fields.
      Setup: Area text selected, Hyphenate on.
      Do: Dialog → Words Longer Than = 6, Before Last = 3 → OK.
      Expect: Wrapper gains `jas:hyphenate-min-word="6"` and
              `jas:hyphenate-min-after="3"`; other attrs omitted.
      — last: —

- [ ] **PG-192** [wired] OK mirrors master back to panel Hyphenate.
      Setup: Panel Hyphenate off. Dialog open, master off.
      Do: Check master → OK.
      Expect: After close, `pg_hyphenate` on the main panel is checked.
      — last: —

- [ ] **PG-193** [wired] Bias slider left = Better Spacing.
      Setup: Area text with a word containing a hyphen candidate near the
             line break.
      Do: Bias slider full left (0) → OK.
      Expect: Word hyphenates; hyphen glyph visible at line break.
      — last: —

- [ ] **PG-194** [wired] Bias slider right = Fewer Hyphens.
      Setup: Same word.
      Do: Bias slider full right (6) → OK.
      Expect: Hyphen is suppressed; line wraps whole-word with wider spacing.
      — last: —

- [ ] **PG-195** [wired] Hyphenate Capitalized Words toggle.
      Setup: Paragraph with a capitalized word at line break.
      Do: Capitalized off → OK.
      Expect: Capitalized word does not hyphenate.
      Do: Reopen → Capitalized on → OK.
      Expect: Capitalized word may now hyphenate if otherwise warranted.
      — last: —

**P2**

- [ ] **PG-200** [wired] Words Longer Than clamps to minimum 2.
      Do: Enter "1" into the field.
      Expect: Clamps to 2 or rejects.
      — last: —

- [ ] **PG-201** [wired] Hyphenation Zone upper bound 1296.
      Do: Enter "5000".
      Expect: Clamps to 1296 or rejects.
      — last: —

- [ ] **PG-202** [wired] Cancel preserves master state from before the open.
      Setup: Panel Hyphenate on.
      Do: Open dialog (master shows on), toggle master off, Cancel.
      Expect: Panel Hyphenate still on; wrapper attr unchanged.
      — last: —

---

## Session J — Text-kind gating (~5 min)

- [ ] **PG-220** [wired] With no selection, indent / space / list / hyphenate / justify all disabled.
      Setup: Click an empty area of the canvas.
      Expect: Alignment buttons dim; all indent / space / dropdowns /
              hyphenate dim; Hanging Punctuation menu item dim.
      — last: —

- [ ] **PG-221** [wired] Point text selected: alignment + bullets + numbered + space enabled; indents / justify / hyphenate disabled.
      Setup: Point text (Type tool click without drag).
      Expect: `text_selected=true` controls enabled; `area_text_selected=false`
              controls disabled (4 Justify buttons, 3 indents, hyphenate,
              hanging).
      — last: —

- [ ] **PG-222** [wired] Area text selected: every control enabled.
      Setup: Area text fixture.
      Expect: All 7 alignment buttons, both dropdowns, three indent fields,
              two space fields, hyphenate, Hanging Punctuation menu all
              interactive.
      — last: —

- [ ] **PG-223** [wired] Mixed selection (point + area): area-only controls dim.
      Setup: Multi-select one point-text and one area-text element.
      Expect: Justify buttons, indents, hyphenate, hanging menu all dim
              because not every element is area text.
      — last: —

- [ ] **PG-224** [wired] Text-on-path selected: indents / justify / hyphenate disabled.
      Setup: Select a textPath element.
      Expect: Same gating as point text (no wrapping frame).
      — last: —

---

## Session K — Appearance theming (~5 min)

- [ ] **PG-240** [wired] Dark appearance: readable contrast on all controls.
      Setup: Dark appearance active.
      Expect: Icon glyphs visible against panel background; dropdown menus
              readable; number-input text legible.
      — last: —

- [ ] **PG-241** [wired] Medium Gray appearance mirrors Dark.
      Do: Switch appearance → Medium Gray.
      Expect: Panel re-skins with medium-gray tokens; all controls remain
              readable; no hardcoded Dark colors leak through.
      — last: —

- [ ] **PG-242** [wired] Light Gray appearance mirrors Dark.
      Do: Switch to Light Gray.
      Expect: Same as above.
      — last: —

- [ ] **PG-243** [wired] Alignment icon active-state visually distinct in every appearance.
      Do: In each appearance, cycle through alignment buttons.
      Expect: The selected icon is visually distinguishable from the other
              six (background, glow, or border per theme tokens).
      — last: —

---

## Session L — Cross-app parity (~15 min)

~5–8 load-bearing `[wired]` tests that must behave identically across the
four native apps (Flask has no paragraph write path — omitted). Batch by
app: run a full column at a time, not one test at a time.

- **PG-300** [wired] Clicking Align Center re-centers every line of the
      selected area text.
      Do: Area text → Align Center.
      Expect: Lines visually centered in the wrapping frame.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **PG-301** [wired] Justify All stretches the last line to both margins.
      Do: Multi-line area text → Justify All.
      Expect: Last line's final glyph aligns with the right margin.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **PG-302** [wired] Left Indent 24 shifts every line rightward by 24pt.
      Do: `pg_left_indent` = 24 on a multi-line area text.
      Expect: Every line's first glyph starts 24pt to the right of the frame
              edge; text wrap width is 24pt narrower.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **PG-303** [wired] Numbered Decimal list counts consecutive paragraphs.
      Do: Three decimal paragraphs.
      Expect: "1." "2." "3." markers, with 12pt gap before each body.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **PG-304** [wired] Hyphenation dialog master mirror to panel.
      Do: Panel Hyphenate off → Dialog → master on → OK.
      Expect: Panel Hyphenate now on.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **PG-305** [wired] Justification dialog Auto Leading override.
      Do: Character → Leading = Auto. Dialog → Auto Leading = 150 → OK.
      Expect: Selected paragraph's vertical spacing tightens vs default 120%.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **PG-306** [wired] Reset Panel clears every attr via identity-omission.
      Setup: Area text with non-default values across every panel control.
      Do: Menu → Reset Panel.
      Expect: Wrapper tspans show no `jas:*` paragraph attributes; canvas
              returns to default layout.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

---

## Graveyard

_No retired or won't-fix tests yet._

---

## Enhancements

_No non-blocking follow-ups raised yet. Manual testing surfaces ideas here
with `ENH-NNN` prefix and italicized trailer noting the test + date._
