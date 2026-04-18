# Paragraph

The Paragraph panel sets properties of paragraphs — spans of text
across which alignment, indentation, spacing, bullets/numbering, and
hyphenation are uniform. This document is the requirements
description from which `workspace/panels/paragraph.yaml` will be
generated.

## Overview

The Paragraph panel is one tab in a tabbed panel group (alongside
Character and OpenType); the tabbed-group container is specified
elsewhere. This document covers only the Paragraph tab.

A **paragraph** is a wrapper `<tspan jas:role="paragraph">` inside a
`<text>` element. Paragraph-level attributes — alignment,
indentation, space-before / space-after, bullets, hyphenate, hanging
punctuation — live on this wrapper tspan. Character-level tspans
(see `CHARACTER.md`) nest inside the paragraph wrapper.

The panel operates on **paragraph sets**:

- Caret with no range → the enclosing paragraph.
- Range selection → every paragraph the range touches, even by one
  character. Paragraph is the atomic unit for paragraph attributes;
  a partial-range write applies to the whole paragraph.
- Whole text element selected as an object → every paragraph in it.
- Multiple text elements selected → every paragraph in every
  element.
- No text element selected → the panel is fully disabled.

Widget ID suffix conventions used in this document:

- `_BUTTON` — `icon_toggle`.
- `_DROPDOWN` — `enum_dropdown` or `numeric_combo` depending on the
  per-control description.
- `_CHECKBOX` — boolean toggle.
- `_VALUE` — plain `numeric_input` (used in dialogs).
- `_SLIDER` — discrete-step slider.

## Controls

- `ALIGN_LEFT_BUTTON`, `ALIGN_CENTER_BUTTON`, `ALIGN_RIGHT_BUTTON`,
  `JUSTIFY_LEFT_BUTTON`, `JUSTIFY_CENTER_BUTTON`,
  `JUSTIFY_RIGHT_BUTTON`, `JUSTIFY_ALL_BUTTON` — `icon_toggle`
  buttons forming a single **radio group**: exactly one is active
  at a time. Default: `ALIGN_LEFT_BUTTON`. `ALIGN_LEFT` aligns each
  line to the left boundary with a ragged right; `ALIGN_CENTER`
  centers each line; `ALIGN_RIGHT` aligns each line to the right
  boundary with a ragged left. The four `JUSTIFY_*` variants
  justify the body of the paragraph to both margins and differ only
  in the treatment of the final line: `JUSTIFY_LEFT` leaves the
  last line left-aligned, `JUSTIFY_CENTER` centers it,
  `JUSTIFY_RIGHT` right-aligns it, and `JUSTIFY_ALL` forces the
  last line to justify like the rest.

- `BULLETS_DROPDOWN` — `enum_dropdown` listing bullet marker styles.
  Entries render with their glyph inline (e.g., `•   Disc`,
  `○   Open Circle`). See §Bullets and numbered lists for the full
  enumeration.

- `NUMBERED_LIST_DROPDOWN` — `enum_dropdown` listing numbered-list
  styles (decimal, alpha, roman). Entries render with their
  numbering inline (e.g., `1.   Decimal`, `a.   Lower Alpha`). See
  §Bullets and numbered lists. Mutually exclusive with
  `BULLETS_DROPDOWN` by virtue of sharing a single backing
  attribute.

- `LEFT_INDENT_DROPDOWN` — `numeric_combo`. Unit: pt. Range
  0–1296 pt. Default 0, shown in parentheses `(0 pt)`. Presets: 0,
  9, 18, 27, 36, 72.

- `RIGHT_INDENT_DROPDOWN` — `numeric_combo`. Unit: pt. Range
  0–1296 pt. Default 0, shown in parentheses. Presets: 0, 9, 18,
  27, 36, 72.

- `FIRST_LINE_INDENT_DROPDOWN` — `numeric_combo`. Unit: pt. Range
  −1296 – +1296 pt (**signed** — negative values produce hanging
  indents, where the first line starts to the left of subsequent
  lines). Default 0, shown in parentheses. Presets: −36, −18, 0, 9,
  18, 27, 36.

- `SPACE_BEFORE_DROPDOWN` — `numeric_combo`. Unit: pt. Range
  0–1296 pt. Default 0, shown in parentheses. Presets: 0, 3, 6, 9,
  12, 18, 24. Adds vertical space above each paragraph; omitted
  before the first paragraph in a text element.

- `SPACE_AFTER_DROPDOWN` — `numeric_combo`. Unit: pt. Range
  0–1296 pt. Default 0, shown in parentheses. Presets: 0, 3, 6, 9,
  12, 18, 24. Adds vertical space below each paragraph.

- `HYPHENATE_CHECKBOX` — boolean toggle (tri-state when the
  selection disagrees). When on, line breaking within each paragraph
  may use hyphenation. The fine-grained parameters governing
  hyphenation behavior live in the Hyphenation dialog; this control
  is the master on/off. The hyphenation language is inherited from
  the character-level `xml:lang` (see `LANGUAGE_DROPDOWN` in
  `CHARACTER.md`).

## Layout

Strings in quotes (`"left indent icon"`, etc.) are literal labels
or icon references. Bare identifiers (`ALIGN_LEFT_BUTTON`, etc.)
are widget IDs.

```yaml
panel:
- .row:
  - .col-1: ALIGN_LEFT_BUTTON
  - .col-1: ALIGN_CENTER_BUTTON
  - .col-1: ALIGN_RIGHT_BUTTON
  - .col-1: JUSTIFY_LEFT_BUTTON
  - .col-1: JUSTIFY_CENTER_BUTTON
  - .col-1: JUSTIFY_RIGHT_BUTTON
  - .col-1: JUSTIFY_ALL_BUTTON
  # 5-column right-padding is intentional
- .row:
  - .col-6: BULLETS_DROPDOWN
  - .col-6: NUMBERED_LIST_DROPDOWN
- .row:
  - .col-1: "left indent icon"
  - .col-5: LEFT_INDENT_DROPDOWN
  - .col-1: "right indent icon"
  - .col-5: RIGHT_INDENT_DROPDOWN
- .row:
  - .col-1: "first line indent icon"
  - .col-5: FIRST_LINE_INDENT_DROPDOWN
  # 6-column right-padding is intentional
- .row:
  - .col-1: "space before icon"
  - .col-5: SPACE_BEFORE_DROPDOWN
  - .col-1: "space after icon"
  - .col-5: SPACE_AFTER_DROPDOWN
- .row:
  - .col-3: HYPHENATE_CHECKBOX
  # 9-column right-padding is intentional
```

## Panel menu

- **Hanging Punctuation** (checkmark if active) — toggles
  `jas:hanging-punctuation` on every paragraph in the selection
  set. Checkmark mirrors the current selection per §Selection model
  and editing rules rule 4; tri-state when paragraphs disagree.
- ----
- **Justification…** — opens the Justification dialog (see
  §Justification Dialog).
- **Hyphenation…** — opens the Hyphenation dialog (see §Hyphenation
  Dialog).
- ----
- **Reset Panel** — see §Reset Panel.

## Selection model and editing rules

1. The panel operates on paragraph sets as defined in §Overview.
2. For dropdown and numeric fields, a control shows the single
   concrete value iff every paragraph in the set agrees; otherwise
   the field is blank.
3. For the alignment radio group, a button is lit iff every
   paragraph agrees; otherwise all seven buttons render off (this
   encodes the mixed state for a radio group).
4. For `HYPHENATE_CHECKBOX` and the **Hanging Punctuation** menu
   item, a tri-state indicator shows on / off / mixed.
5. Writing to a blank, mixed, or all-off control applies the new
   value to every paragraph in the set (overwriting variation).
   Leaving a blank field untouched preserves each paragraph's
   existing value.
6. A newly-created paragraph (user presses Enter) inherits its
   attributes from the paragraph whose end produced it. Deleting a
   paragraph break (user presses Backspace at paragraph start)
   keeps the surviving paragraph's attributes and discards the
   merged one's.
7. Paragraph wrappers are never split mid-paragraph by panel
   writes: the paragraph is the atomic unit for paragraph
   attributes, even if the user's range covered only part of it.

## Text-kind gating

Some controls require area text (a wrapping frame):

| Control | Point text | Text on path | Area text |
|---|---|---|---|
| `ALIGN_LEFT/CENTER/RIGHT_BUTTON` | ✓ | ✓ | ✓ |
| `JUSTIFY_*_BUTTON` (4 buttons) | — | — | ✓ |
| `LEFT_INDENT_DROPDOWN`, `RIGHT_INDENT_DROPDOWN` | — | — | ✓ |
| `FIRST_LINE_INDENT_DROPDOWN` | — | — | ✓ |
| `SPACE_BEFORE_DROPDOWN`, `SPACE_AFTER_DROPDOWN` | ✓ | ✓ | ✓ |
| `BULLETS_DROPDOWN`, `NUMBERED_LIST_DROPDOWN` | ✓ | ✓ | ✓ |
| `HYPHENATE_CHECKBOX` | — | — | ✓ |
| Hanging Punctuation (menu) | — | — | ✓ |

When the selection mixes kinds, a control is enabled iff every
selected text element supports it.

Default alignment (`ALIGN_LEFT_BUTTON`) assumes LTR; RTL handling
is deferred to the language-direction subsystem.

## Bullets and numbered lists

### Enumerations

`BULLETS_DROPDOWN` entries (6 styles + None):

| Label | `jas:list-style` value | Glyph |
|---|---|---|
| None | (omitted) | — |
| Disc | `bullet-disc` | • |
| Open Circle | `bullet-open-circle` | ○ |
| Square | `bullet-square` | ■ |
| Open Square | `bullet-open-square` | □ |
| Dash | `bullet-dash` | – |
| Check | `bullet-check` | ✓ |

`NUMBERED_LIST_DROPDOWN` entries (5 styles + None):

| Label | `jas:list-style` value | Example |
|---|---|---|
| None | (omitted) | — |
| Decimal | `num-decimal` | 1. 2. 3. |
| Lower Alpha | `num-lower-alpha` | a. b. c. |
| Upper Alpha | `num-upper-alpha` | A. B. C. |
| Lower Roman | `num-lower-roman` | i. ii. iii. |
| Upper Roman | `num-upper-roman` | I. II. III. |

### Mutual exclusion

Bullets and numbered lists share one backing attribute
(`jas:list-style`), so they are inherently mutually exclusive:

- Selecting a bullet style writes the corresponding `bullet-*`
  value, clearing any numbered style.
- Selecting a numbered style writes `num-*`, clearing any bullet
  style.
- Each dropdown shows the current value if it matches its kind, or
  "None" if the current value is the other kind (or absent).
- Selecting "None" in either dropdown clears `jas:list-style`
  entirely.

### Counter semantics for numbered lists

Counters are implicit — derived from paragraph order at render
time, not stored in SVG.

**Run rule:** consecutive paragraphs with the same `jas:list-style`
value count together as one list. A paragraph with a different
value (or absent `jas:list-style`) **breaks the run** and resets
the counter for any subsequent list of the same style.

```
[num-decimal]     1. First item
[num-decimal]     2. Second item
[bullet-disc]     • Interrupting bullet (breaks the run)
[num-decimal]     1. Counter reset — new list starts at 1
[num-decimal]     2. Second item of new list
[num-lower-alpha] a. Different style → its own counter
[num-decimal]     1. Back to decimal, counter reset again
```

Starting number cannot be overridden by the user in V1. See §Out
of scope for V1 for future continuation / override attributes.

### Marker rendering

For any paragraph with a non-absent `jas:list-style`:

- The **marker** (bullet glyph or number + period) sits at
  `x = left-indent`.
- The **text** starts at `x = left-indent + marker-gap`, where
  `marker-gap` is a fixed constant `12pt` for V1.
- Continuation lines (second and later lines of a wrapped
  paragraph) start at `x = left-indent + marker-gap` — aligned with
  the first line's text, not with the marker. This produces the
  standard hanging-indent effect.
- `FIRST_LINE_INDENT_DROPDOWN` is **ignored** for paragraphs with
  an active marker (it has no useful interpretation when the marker
  already occupies the first-line position). The panel leaves the
  control enabled so the user's setting is preserved across toggles
  of list style, but applies no effect while the list is active.
- **Marker font, size, and color** inherit from the first character
  of the paragraph's text (i.e., the first nested character-level
  tspan's Character attributes).
- **Marker language:** numeric markers render with Latin digits in
  V1, regardless of the paragraph's `xml:lang`. Native digit
  rendering (e.g., Arabic-Indic for `ar`) is deferred.

## Hanging Punctuation

Hanging punctuation (also called optical margin alignment) pushes
certain punctuation characters slightly outside the paragraph's
margins so the text block presents a visually straighter edge.

**Scope.** Paragraph attribute. Stored on the paragraph wrapper
tspan as `jas:hanging-punctuation` (boolean). Default: off. Omitted
when false per the identity-value rule.

**UI.** Exposed as the **Hanging Punctuation** panel-menu entry
with a checkmark. Checkmark state mirrors the current selection:
checked if every selected paragraph is on, unchecked if every
paragraph is off, tri-state dash if they disagree. Toggling the
menu entry writes to every selected paragraph.

**Hanging characters.** When the attribute is on, the following
characters hang when they fall at the very start or very end of a
rendered line; they never hang mid-line.

| Class | Characters | Hangs into |
|---|---|---|
| Open quotes | " ' " ' « ‹ | left margin |
| Open brackets | ( [ { | left margin |
| Periods / commas | . , | right margin |
| Close quotes | " ' " ' » › | right margin |
| Close brackets | ) ] } | right margin |
| Hyphens / dashes | - – — | right margin (end-of-line only) |

**Hang amount.** The character hangs by its own full advance
width — the first/last non-punctuation glyph of the line meets the
paragraph edge, and the punctuation glyph sits entirely in the
margin.

**Alignment interaction.**

- Left-aligned: left-hanging characters hang at line start only.
- Right-aligned: right-hanging characters hang at line end only.
- Justified: both sides hang; the hang offset is excluded from the
  justified width so interior spacing is unchanged.
- Centered: both sides hang; centering is measured from the
  non-hanging portion of each line.

**Edge semantics.** "Margin" means the effective paragraph edge
after accounting for `jas:left-indent`, `jas:right-indent`,
`text-indent` (first line only), and marker-gap (list-styled
paragraphs only). The hanging glyph sits outside that effective
edge — not outside the document page.

**Bullet / list-marker interaction.** Bullet and numbered-list
markers always hang by virtue of the marker-rendering rules in
§Bullets and numbered lists (marker at `left-indent`, text at
`left-indent + marker-gap`). This is independent of
`jas:hanging-punctuation`; list markers hang whether or not the
flag is on.

**CSS equivalent (informational).** The closest CSS property is
`hanging-punctuation: first allow-end`. SVG-in-browser renderers
support this unevenly; our layout subsystem implements the table
above directly rather than relying on CSS.

## Composer (V1)

Paragraphs are laid out using an **every-line composer** modelled
on Knuth-Plass (1981). The algorithm searches globally across
paragraph break candidates to minimise total spacing penalty,
subject to the Min/Max constraints defined in the Justification
dialog. All four apps (Rust, Swift, OCaml, Python) implement the
same algorithm with the same penalty weights so paragraph layouts
are identical across languages.

The Word Spacing, Letter Spacing, and Glyph Scaling min / desired /
max values from the Justification dialog act as soft constraints on
the optimiser: the composer targets Desired on every line but may
stretch or shrink within [Min, Max] to find the globally-best
line-break configuration. Glyph scaling is a last-resort adjustment
applied only when word and letter spacing alone cannot keep a line
within range.

The Hyphenation dialog's Bias slider (`jas:hyphenate-bias`) wires
directly into the composer's hyphen penalty: 0 (Better Spacing)
makes hyphens cheap so the composer picks them freely to improve
spacing; 6 (Fewer Hyphens) makes hyphens expensive so the composer
avoids them unless spacing gets severely out of range.

The composer-algorithm choice (every-line vs. single-line) is not
exposed as a user-facing toggle in V1. See §Out of scope for V1.

## Justification Dialog

Opened from the panel-menu entry **Justification…**. The dialog
operates on every paragraph in the current selection set.

Dialog layout uses the same bootstrap-style row/col grammar as
panels, plus the `.hr` (horizontal rule) and `.footer` (button row)
primitives specified in the YAML interpreter.

**Layout**

```yaml
dialog:
  title: Justification
- .row:
  - .col-3: ""
  - .col-3: "Minimum"
  - .col-3: "Desired"
  - .col-3: "Maximum"
- .row:
  - .col-3: "Word Spacing:"
  - .col-3: WORD_SPACING_MIN_VALUE
  - .col-3: WORD_SPACING_DESIRED_VALUE
  - .col-3: WORD_SPACING_MAX_VALUE
- .row:
  - .col-3: "Letter Spacing:"
  - .col-3: LETTER_SPACING_MIN_VALUE
  - .col-3: LETTER_SPACING_DESIRED_VALUE
  - .col-3: LETTER_SPACING_MAX_VALUE
- .row:
  - .col-3: "Glyph Scaling:"
  - .col-3: GLYPH_SCALING_MIN_VALUE
  - .col-3: GLYPH_SCALING_DESIRED_VALUE
  - .col-3: GLYPH_SCALING_MAX_VALUE
- .hr
- .row:
  - .col-6: "Auto Leading:"
  - .col-3: AUTO_LEADING_VALUE
- .row:
  - .col-6: "Single Word Justification:"
  - .col-4: SINGLE_WORD_JUSTIFY_DROPDOWN
- .footer:
  - .col-4: JUSTIFICATION_PREVIEW_CHECKBOX
  - .col-4: JUSTIFICATION_CANCEL_BUTTON
  - .col-4: JUSTIFICATION_OK_BUTTON
```

**Fields**

| Field | Type | Unit | Range | Default | Storage |
|---|---|---|---|---|---|
| `WORD_SPACING_MIN_VALUE` | numeric_input | % | 0–1000 | 80 | `jas:word-spacing-min` |
| `WORD_SPACING_DESIRED_VALUE` | numeric_input | % | 0–1000 | 100 | `jas:word-spacing-desired` |
| `WORD_SPACING_MAX_VALUE` | numeric_input | % | 0–1000 | 133 | `jas:word-spacing-max` |
| `LETTER_SPACING_MIN_VALUE` | numeric_input | % | −100–500 | 0 | `jas:letter-spacing-min` |
| `LETTER_SPACING_DESIRED_VALUE` | numeric_input | % | −100–500 | 0 | `jas:letter-spacing-desired` |
| `LETTER_SPACING_MAX_VALUE` | numeric_input | % | −100–500 | 0 | `jas:letter-spacing-max` |
| `GLYPH_SCALING_MIN_VALUE` | numeric_input | % | 50–200 | 100 | `jas:glyph-scaling-min` |
| `GLYPH_SCALING_DESIRED_VALUE` | numeric_input | % | 50–200 | 100 | `jas:glyph-scaling-desired` |
| `GLYPH_SCALING_MAX_VALUE` | numeric_input | % | 50–200 | 100 | `jas:glyph-scaling-max` |
| `AUTO_LEADING_VALUE` | numeric_input | % | 0–500 | 120 | `jas:auto-leading` |
| `SINGLE_WORD_JUSTIFY_DROPDOWN` | enum_dropdown | — | see below | Full Justify | `jas:single-word-justify` |

**`SINGLE_WORD_JUSTIFY_DROPDOWN` values:**

| Label | Storage value |
|---|---|
| Full Justify | `justify` |
| Align Left | `left` |
| Align Center | `center` |
| Align Right | `right` |

**Field meanings**

- **Word / Letter / Glyph Spacing (min / desired / max)** — see
  §Composer (V1) for how the optimiser consumes these.
- **Auto Leading** — percentage of font size used when a character
  has Auto leading in the Character panel. Overrides the global
  120% default on the paragraphs in the current selection.
- **Single Word Justification** — how to render a justified line
  containing only one word: stretch it across the full width
  (`justify`), or fall back to `left` / `center` / `right`
  alignment.

**OK / Cancel**

- **OK** commits every field value to every paragraph in the
  selection and closes the dialog.
- **Cancel** (or **Esc**) discards changes and closes the dialog.
- **Mixed selection**: each field opens showing the shared value if
  every selected paragraph agrees, blank otherwise. Untouched blank
  fields do not write anything on OK (paragraphs retain their
  varying values); edited fields write to all.
- **Preview checkbox** is dialog-session state (not persisted);
  when on, every edit applies live to the selected paragraphs.
  Cancel still rolls back — opening the dialog snapshots
  `jas:word-spacing-*`, `jas:letter-spacing-*`, `jas:glyph-scaling-*`,
  `jas:auto-leading`, and `jas:single-word-justify` on every
  selected paragraph, and Cancel restores from the snapshot.

## Hyphenation Dialog

Opened from the panel-menu entry **Hyphenation…**.

**Layout**

```yaml
dialog:
  title: Hyphenation
- .row:
  - .col-12: HYPHENATE_MASTER_CHECKBOX          # label "Hyphenation"
- .row:
  - .col-6: "Words Longer Than:"
  - .col-3: HYPHENATE_MIN_WORD_VALUE
  - .col-3: "letters"
- .row:
  - .col-6: "After First:"
  - .col-3: HYPHENATE_MIN_BEFORE_VALUE
  - .col-3: "letters"
- .row:
  - .col-6: "Before Last:"
  - .col-3: HYPHENATE_MIN_AFTER_VALUE
  - .col-3: "letters"
- .row:
  - .col-6: "Hyphen Limit:"
  - .col-3: HYPHENATE_LIMIT_VALUE
  - .col-3: "hyphens"
- .row:
  - .col-6: "Hyphenation Zone:"
  - .col-3: HYPHENATE_ZONE_VALUE
- .row:
  - .col-12: HYPHENATE_BIAS_SLIDER              # 7-step discrete
- .row:
  - .col-6: "Better Spacing"                    # slider endpoint labels
  - .col-6: "Fewer Hyphens"
- .row:
  - .col-12: HYPHENATE_CAPITALIZED_CHECKBOX     # label "Hyphenate Capitalized Words"
- .footer:
  - .col-4: HYPHENATION_PREVIEW_CHECKBOX
  - .col-4: HYPHENATION_CANCEL_BUTTON
  - .col-4: HYPHENATION_OK_BUTTON
```

**Fields**

| Field | Type | Unit | Range | Default | Storage |
|---|---|---|---|---|---|
| `HYPHENATE_MASTER_CHECKBOX` | checkbox | — | bool | false | `jas:hyphenate` (shared with `HYPHENATE_CHECKBOX` on the main panel) |
| `HYPHENATE_MIN_WORD_VALUE` | numeric_input | letters | 2–25 | 3 | `jas:hyphenate-min-word` |
| `HYPHENATE_MIN_BEFORE_VALUE` | numeric_input | letters | 1–10 | 1 | `jas:hyphenate-min-before` |
| `HYPHENATE_MIN_AFTER_VALUE` | numeric_input | letters | 1–10 | 1 | `jas:hyphenate-min-after` |
| `HYPHENATE_LIMIT_VALUE` | numeric_input | hyphens | 0–25 (0 = unlimited) | 0 | `jas:hyphenate-limit` |
| `HYPHENATE_ZONE_VALUE` | numeric_input | pt | 0–1296 | 0 | `jas:hyphenate-zone` |
| `HYPHENATE_BIAS_SLIDER` | slider | — | 7-step discrete (0–6) | 0 | `jas:hyphenate-bias` |
| `HYPHENATE_CAPITALIZED_CHECKBOX` | checkbox | — | bool | false | `jas:hyphenate-capitalized` |

**Field meanings**

- **Words Longer Than N letters** — don't hyphenate any word
  shorter than N.
- **After First N letters** — at least N letters must appear before
  the hyphen.
- **Before Last N letters** — at least N letters must appear after
  the hyphen.
- **Hyphen Limit** — max consecutive line endings that may be
  hyphens (0 = unlimited).
- **Hyphenation Zone** — pt distance from the right margin within
  which hyphenation is considered (non-justified paragraphs only).
- **Bias slider** — discrete 7-step (0 = Better Spacing / cheap
  hyphens, 6 = Fewer Hyphens / expensive hyphens). Wires into the
  composer's hyphen penalty; see §Composer (V1).
- **Capitalized checkbox** — whether to hyphenate words starting
  with a capital letter.

**Master-checkbox interaction**

`HYPHENATE_CHECKBOX` (main panel) and `HYPHENATE_MASTER_CHECKBOX`
(dialog) are two UI surfaces on the same `jas:hyphenate` boolean —
toggling either mirrors the other. When the master is off, the
remaining seven controls in the dialog render
dimmed/non-interactive. Their stored values are preserved; toggling
master back on restores full interactivity with the saved values.

**Language**

Hyphenation dictionaries are language-specific. The language for
each paragraph comes from the character-level `xml:lang` (set via
`LANGUAGE_DROPDOWN` in `CHARACTER.md`). The Paragraph panel has no
language control of its own. Packaging of per-language hyphenation
dictionaries is tracked separately; until a dictionary ships for a
given language, `HYPHENATE_CHECKBOX` can be toggled and dialog
parameters stored, but no hyphens appear in rendered output.

**OK / Cancel / Preview** — identical to the Justification dialog,
with the snapshot scoped to `jas:hyphenate` and `jas:hyphenate-*`
attributes.

## Reset Panel

**Reset Panel** clears every Paragraph attribute on the current
selection (the paragraph set defined in §Selection model and
editing rules) back to its default:

- **Panel controls:** alignment → `ALIGN_LEFT_BUTTON`;
  left / right / first-line indent → 0 pt;
  space-before / space-after → 0 pt; bullets and numbered list →
  None; hyphenate → off; hanging punctuation → off.
- **Justification dialog:** word spacing → 80 / 100 / 133 %; letter
  spacing → 0 / 0 / 0 %; glyph scaling → 100 / 100 / 100 %; auto
  leading → 120 %; single word justification → Full Justify.
- **Hyphenation dialog:** words longer than → 3; after first → 1;
  before last → 1; hyphen limit → 0; hyphenation zone → 0 pt;
  bias → Better Spacing (leftmost, `0`); hyphenate capitalized
  words → off.

Per the identity-value rule, resetting removes the corresponding
attributes from the paragraph wrapper tspan rather than writing
explicit default values. Numeric combo fields return to their
parenthesised default display (e.g., `(0 pt)`, `(100 %)`).

## Out of scope for V1

The following features exist in industry paragraph panels but are
not specified here. The `jas:*` attribute shapes above are chosen
to be forward-compatible; adding any of these later will not
require renaming or restructuring existing attributes.

- **Drop caps** — oversized first character spanning multiple
  lines.
- **Tab stops / tab ruler** — explicit tab positions for column
  alignment within paragraphs. Until specified, `\t` in text
  content falls back to a default tab width.
- **Paragraph Styles** — saved reusable attribute bundles applied
  by name. A later Styles panel will likely span Character +
  Paragraph jointly.
- **Composer algorithm choice (user-facing toggle)** — V1 uses the
  every-line composer (Knuth-Plass style) for all paragraphs with
  no UI to switch to single-line. Future additive attribute:
  `jas:composer`, with default value `every-line` matching V1
  behavior.
- **Continue numbering** — explicit continuation of a numbered list
  across intervening non-list paragraphs, overriding the auto-reset
  rule in §Bullets and numbered lists. Future attributes:
  `jas:list-continue` or `jas:list-start`.
- **CJK-specific layout** — hanging punctuation for CJK punctuation
  classes, vertical-writing paragraph rules, per-language digit
  rendering for numbered lists.

## Panel state

The Paragraph panel has no panel-local state and no shared state.
All paragraph attributes listed in §SVG attribute mapping are
stored on the paragraph wrapper tspan (or on the parent text
element when every paragraph in it agrees on a value), not in any
panel- or app-level state store.

The Preview checkbox inside the Justification and Hyphenation
dialogs is dialog-session state: it resets to off each time the
dialog opens and is not persisted across dialog invocations.

The **Hanging Punctuation** panel-menu entry's checkmark is derived
from the current selection's `jas:hanging-punctuation` value — it
is not stored panel state.

## SVG attribute mapping

All paragraph attributes live on the **paragraph wrapper tspan**
(`<tspan jas:role="paragraph">`), or are lifted to the parent
`<text>` element when every paragraph in the element agrees on a
value.

| Control / state | Storage | Notes |
|---|---|---|
| Alignment (area text) | `text-align` + `text-align-last` | see sub-mapping below |
| Alignment (point text, text-on-path) | `text-anchor` on the `<text>` element | `start` / `middle` / `end`; paragraph wrapper not used for anchor |
| `LEFT_INDENT_DROPDOWN` | `jas:left-indent` | pt, unsigned |
| `RIGHT_INDENT_DROPDOWN` | `jas:right-indent` | pt, unsigned |
| `FIRST_LINE_INDENT_DROPDOWN` | `text-indent` | CSS, pt, **signed** (negatives = hanging indent) |
| `SPACE_BEFORE_DROPDOWN` | `jas:space-before` | pt, unsigned |
| `SPACE_AFTER_DROPDOWN` | `jas:space-after` | pt, unsigned |
| `BULLETS_DROPDOWN` / `NUMBERED_LIST_DROPDOWN` | `jas:list-style` | single attribute; values in §Bullets and numbered lists |
| `HYPHENATE_CHECKBOX` | `jas:hyphenate` | boolean; hyphenation language inherited from character-level `xml:lang` |
| Hanging Punctuation (menu) | `jas:hanging-punctuation` | boolean |
| Justification dialog (11 fields) | `jas:word-spacing-{min,desired,max}`, `jas:letter-spacing-{min,desired,max}`, `jas:glyph-scaling-{min,desired,max}`, `jas:auto-leading`, `jas:single-word-justify` | see §Justification Dialog |
| Hyphenation dialog (7 fields) | `jas:hyphenate`, `jas:hyphenate-{min-word,min-before,min-after,limit,zone,bias,capitalized}` | see §Hyphenation Dialog |

**Alignment sub-mapping (area text):**

| Button | `text-align` | `text-align-last` |
|---|---|---|
| `ALIGN_LEFT_BUTTON` | `left` | omit |
| `ALIGN_CENTER_BUTTON` | `center` | omit |
| `ALIGN_RIGHT_BUTTON` | `right` | omit |
| `JUSTIFY_LEFT_BUTTON` | `justify` | `left` |
| `JUSTIFY_CENTER_BUTTON` | `justify` | `center` |
| `JUSTIFY_RIGHT_BUTTON` | `justify` | `right` |
| `JUSTIFY_ALL_BUTTON` | `justify` | `justify` |

`text-align-last` is written explicitly for every `JUSTIFY_*`
variant (including `JUSTIFY_LEFT`) so the paragraph's alignment
round-trips unambiguously regardless of document language
direction.

**Alignment sub-mapping (point text / text-on-path):**

| Button | `text-anchor` |
|---|---|
| `ALIGN_LEFT_BUTTON` | `start` |
| `ALIGN_CENTER_BUTTON` | `middle` |
| `ALIGN_RIGHT_BUTTON` | `end` |

Point text with multiple paragraphs shares one `text-anchor` value
(on the `<text>` element, not on the wrapper tspan). Per-paragraph
alignment in point text is not supported; users who need it
convert to area text.

**Identity-value rule.** When an attribute equals its default
(`text-align: left`, `text-anchor: start`, `jas:*-indent: 0`,
`jas:list-style` absent, `jas:hyphenate: false`, all Justification
and Hyphenation dialog defaults, etc.), the attribute is **omitted**
from the output rather than written. Defaults appear as absence.

## Keyboard shortcuts

Shortcuts for Paragraph panel actions (alignment toggles,
bullets / numbered list cycling, Reset Panel) are defined in
`workspace/shortcuts.yaml` rather than here.
