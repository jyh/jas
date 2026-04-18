# Paragraph Panel — Implementation Plan

Scope: implement the Paragraph panel specified in `PARAGRAPH.md`
across all five apps (`jas_flask`, `jas_dioxus`, `JasSwift`,
`jas_ocaml`, `jas`), on branch `paragraph-panel`.

The phases below each produce something observable so progress is
reviewable and model mistakes surface early.

## Phases

### Phase 0 — YAML interpreter primitives

Unblocks every later phase that touches dialogs. Self-contained
within the interpreter; no text/canvas work.

**Scope**

- `.hr` horizontal-rule layout primitive.
- `.footer` button-row layout primitive.
- `dialog:` top-level container (distinct from `panel:`).
- Panel-menu `…` suffix triggers dialog open.
- Dialog OK / Cancel / Esc handlers.
- Preview-checkbox snapshot/restore harness.
- `enabled-when` attribute gating.

**Apps:** `jas_flask` first, then `jas_dioxus`, `JasSwift`,
`jas_ocaml`, `jas` (per `CLAUDE.md` sequencing).

**Deliverable:** a minimal `test-dialog.yaml` opens from a panel
menu, displays `.hr` and `.footer`, Preview snapshot/restore works,
and a master checkbox with `enabled-when` gates its siblings.

### Phase 1 — Paragraph wrapper tspan model

Split into two halves so the foundation lands quickly and the
mechanical attribute work defers until it has a real consumer.

**Phase 1a** — `jas_role` round-trip only (foundation).

- Add `jas_role: Option<String>` to the Tspan struct (or equivalent
  per language) — values: `None` for content tspans, `Some("paragraph")`
  for wrappers.
- SVG parser recognises `jas:role` attribute on `<tspan>`.
- SVG serialiser emits `jas:role` when set.
- Round-trip test: `<tspan jas:role="paragraph">` parses and
  serialises back unchanged.

Wrapper tspans live in the existing flat tspan list (Option A++
from the design discussion); subsequent content tspans implicitly
group under the most recent wrapper. No paragraph attribute fields
are added in 1a; round-trip preserves the role marker only.

**Phase 1b** — full paragraph attributes + edit primitives
(deferred to the Phase 4 timeframe, when the panel actually writes
these values).

- Add the ~30 paragraph-level Optional fields (alignment, indents,
  space-before/after, list-style, hyphenate, hanging-punctuation,
  Justification dialog attrs, Hyphenation dialog attrs).
- SVG parse/serialise the new attributes with the identity-value
  rule.
- Enter creates a new paragraph wrapper inheriting parent attrs.
- Backspace at paragraph start removes the wrapper, discarding its
  attrs (per §Selection rule 6 of `PARAGRAPH.md`).

**Apps:** 4 native (`jas_dioxus`, `JasSwift`, `jas_ocaml`, `jas`).
`jas_flask` is skipped — per `project_flask_tspan_deferred.md`,
flask has no canvas / SVG document model and does not parse or
serialise text elements.

**Deliverable (1a):** SVGs with `jas:role="paragraph"` wrapper
tspans round-trip across all four native apps.

### Phase 2 — Static panel + dialog UI

**Scope**

- Generate `workspace/panels/paragraph.yaml` from `PARAGRAPH.md`.
- Generate `workspace/dialogs/justification.yaml` and
  `workspace/dialogs/hyphenation.yaml`.
- All controls render at correct positions.
- No selection wiring yet.

**Apps:** all 5.

**Deliverable:** Paragraph tab shows up; all controls visible; menu
opens both dialogs.

### Phase 3 — Selection → panel (reads)

**Scope**

- Populate control values from the selection's paragraph attrs.
- Mixed-state rendering (blank for combos, all-off for the
  alignment radio group, tri-state for checkboxes).
- Text-kind gating per §Text-kind gating.

**Apps:** 4 native. `jas_flask` skipped — no canvas.

**Deliverable:** selecting paragraphs shows correct values; mixed
shows blank/off.

### Phase 4 — Panel → selection (writes; non-rendered attrs)

**Scope**

- Alignment → `text-align` / `text-align-last` / `text-anchor`.
- Indent → `jas:left-indent`, `jas:right-indent`, `text-indent`.
- Space → `jas:space-before`, `jas:space-after`.
- `HYPHENATE_CHECKBOX` → `jas:hyphenate` (flag only; no rendering).
- Hanging Punctuation toggle → `jas:hanging-punctuation` (flag only).
- Reset Panel → defaults per §Reset Panel, obeying the
  identity-value rule.

**Apps:** 4 native.

**Deliverable:** panel writes commit to SVG; round-trip works;
Reset clears all attrs (verified via identity-value assertion that
attributes are removed, not set to defaults).

### Phase 5 — Basic rendering: align / indent / space

**Scope**

- Left / center / right alignment (no justify yet).
- Left / right indent adjusts wrapping width.
- First-line indent offsets first-line start.
- Space-before / after inserts paragraph gaps.

**Apps:** 4 native.

**Deliverable:** paragraphs render with correct alignment, indents,
and inter-paragraph spacing.

### Phase 6 — Bullets and numbered lists

**Scope**

- Bullet glyph rendering per §Bullets and numbered lists
  enumeration.
- Counter run rule.
- Marker at `left-indent`, text at `left-indent + 12pt marker-gap`.
- `FIRST_LINE_INDENT_DROPDOWN` ignored when list is active.
- `BULLETS_DROPDOWN` and `NUMBERED_LIST_DROPDOWN` mutual exclusion
  via the single `jas:list-style` attribute.

**Apps:** 4 native + `jas_flask` (YAML-level mutual exclusion only).

**Deliverable:** bulleted and numbered paragraphs render correctly;
dropdowns reflect mutual exclusion.

### Phase 7 — Hanging punctuation rendering

**Scope**

- Character-class table from §Hanging Punctuation.
- Offset hanging characters outside the effective edge (indent- and
  marker-adjusted).
- Justified interaction: hang offset excluded from justified width.

**Apps:** 4 native.

**Deliverable:** paragraphs with `jas:hanging-punctuation=true`
show punctuation hanging outside the edge.

### Phase 8 — Justification dialog wiring

**Scope**

- 11 fields commit to their `jas:*` attributes.
- Preview checkbox snapshots and restores on Cancel.
- Mixed-selection semantics per §Justification Dialog.
- Auto Leading override of Character's 120% default.
- One-line edit to `CHARACTER.md` noting the per-paragraph
  override.

**Apps:** `jas_flask` + 4 native.

**Deliverable:** dialog opens, edits, OK commits, Cancel rolls back.

### Phase 9 — Hyphenation dialog + basic hyphenator

**Scope**

- 7 fields commit to `jas:hyphenate-*`.
- Master checkbox syncs with `HYPHENATE_CHECKBOX` on the main
  panel.
- `enabled-when` dims siblings when master is off.
- Package en-US hyphenation dictionary (TeX hyphen patterns).
- Naive hyphenator (no composer interaction yet) — marks word-break
  candidates per dictionary plus Words-Longer-Than / Before / After
  constraints.

**Apps:** `jas_flask` + 4 native.

**Deliverable:** hyphenation dialog functional; when on and
`xml:lang=en-US` is set, en-US words can hyphenate.

### Phase 10 — Every-line composer (Knuth-Plass)

**Scope**

- Dynamic-programming line-break algorithm × 4 native apps.
- Soft constraints from Min / Desired / Max in Justification
  dialog.
- Hyphen penalty wired from the bias slider.
- Justify rendering (area text only).
- Cross-language parity test harness: corpus of ~15 paragraphs, all
  four apps must produce identical line breaks.

**Apps:** 4 native. `jas_flask` skipped.

**Deliverable:** justified paragraphs look the same across all four
native apps; interior spacing respects [Min, Max].

**Biggest phase by far.** Estimate ~300-500 LOC per language plus
tuning. Budget 2-3 weeks total if done sequentially; parallelisable
across languages after the Rust reference implementation lands.

### Phase 11 — Cross-language parity + polish

**Scope**

- Test corpus exercising every attribute from `PARAGRAPH.md`.
- Parity harness assertions across all four native apps.
- Fix any divergences surfaced.
- Manual-testing pass per `transcripts/MANUAL_TESTING.md` pattern.

**Apps:** all 5.

**Deliverable:** panel feature-complete and consistent across apps.

## Conventions

**Commits:** one per phase. The spec rewrite (`PARAGRAPH.md`)
lands first as its own commit before Phase 0.

**Per-app sequencing within each phase:** flask → Rust → Swift →
OCaml → Python (`CLAUDE.md` convention). Phases that skip flask
skip it entirely, not partially.

**Testing:** write tests before code (per `CLAUDE.md`).
SVG-attribute assertions for storage layer; layout-position
assertions for rendering; break-position assertions for composer;
parity assertions in Phase 11.

**Branch:** `paragraph-panel`. Do not merge to `main` until Phase
11 passes across all apps.

## Spec amendments expected during implementation

`PARAGRAPH.md` may need tightening as the work surfaces gaps.
Anticipated amendments:

- Exact `.hr` / `.footer` / `enabled-when` YAML syntax, once
  chosen in Phase 0.
- One-liner in `CHARACTER.md` about `jas:auto-leading` override
  from the Justification dialog (Phase 8).
- Any unexpected gaps found while generating YAML from the spec
  (Phase 2).

Amendments happen on this branch and ride in with the phase that
surfaces them.

## Spec → YAML translation conventions

`PARAGRAPH.md` (and other spec docs) use a compact bootstrap-style
notation. The flask YAML interpreter does not understand this
notation directly; the panel/dialog YAMLs that get generated in
Phase 2 use the verbose `type:` form. The fixed translations are:

| Spec notation | Generated YAML | Source |
|---|---|---|
| `.row: …` | `{ type: row, children: [...] }` | existing |
| `.col-N: X` | `{ type: col, col: N, children: [X] }` | existing |
| `.hr` | `{ type: separator }` | existing renderer entry |
| `.footer: …` | `{ type: container, layout: row, style: { gap: 8, alignment: center, justify: end }, children: [...] }` (the bottom Preview / Cancel / OK row of a dialog) | convention only — no new primitive |
| `enabled-when: X` (on a control) | `bind: { disabled: "not X" }` | existing `bind.disabled` mechanism (`app.js:469-473`) |
| `Preview` checkbox in dialog | `state.preview: { type: bool, default: false }` plus dialog-level `preview_targets:` mapping `dialog.<key>` to document state path | `preview_targets` lands in Phase 0; live-apply lands in Phase 8/9 |

`preview_targets` is the only YAML schema slot added in Phase 0.
The interpreter emits it as `data-dialog-preview-targets` on the
modal element (`renderer.py:render_dialogs`); JS captures the
snapshot of each target on dialog open and restores on
`close_dialog` unless first cleared by the `clear_dialog_snapshot`
effect (used by OK actions in later phases).

The Preview checkbox itself is just a normal `state.preview`
boolean. Phase 8/9 adds the per-edit "if `dialog.preview` is on,
write live to the target" binding pattern at the per-control level
(via `behavior` blocks); Phase 0 only establishes the snapshot
plumbing.
