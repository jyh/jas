# Tspan

Sub-structure of a `Text` element that carries per-character-range
formatting. Every `Text` element owns an ordered list of tspans; the
concatenation of their contents is the text of the element. Tspans
are the unit that the Character panel (see `CHARACTER.md`) reads and
writes, and the unit that the Touch Type tool (see `TOOLS.md`)
splits per glyph.

This document is the language-agnostic specification. Per-app
implementation notes are in the Cross-language checklist at the end.

Where the spec says `Text`, the corresponding language-local name
applies: `Text` in Python, Swift, and OCaml; `TextElem` in Rust.
Likewise `TextPath` → `TextPathElem` in Rust.

## Overview

Today, a `Text` element is flat — one content string and one set of
font attributes. That is enough for whole-element formatting but
cannot express a document with (say) part of a word in bold or one
letter rotated. Tspans add per-range formatting without changing the
element's bounding box or layout model.

A `Text` element gains an ordered, non-empty list of tspans. Each
tspan holds its own substring of the element's content plus a
(possibly empty) set of overrides of the parent element's
attributes. Omitted attributes inherit from the parent `Text`.

The design goal is **minimal change when the feature is unused**: a
text element with one tspan that overrides nothing is visually and
semantically identical to a pre-Tspan text element.

## Data model

```
Tspan
  id:              TspanId                in-memory stable id, unique within the parent Text
  content:         string                 substring of the parent Text's content
  font_family:     string?                overrides Text.font_family
  font_size:       float?                 overrides Text.font_size (pt)
  font_weight:     string?                "normal" or "bold"
  font_style:      string?                "normal" or "italic"
  style_name:      string?                verbatim style-name sidecar for round-trip fidelity (e.g. "Condensed Display Bold SC")
  text_decoration: set<string>?           members: "underline", "line-through" (empty set = none)
  baseline_shift:  float?                 pt, signed, + = up
  letter_spacing:  float?                 em, signed (tracking)
  line_height:     float?                 multiplier; Text inherits 1.2 (leading)
  rotate:          float?                 degrees, signed, + = clockwise; uniform for the tspan (per-glyph uses solo tspans)
  dx:              float?                 em, signed; per-tspan leading-edge horizontal nudge (Touch Type)
  transform:       Transform?             any SVG transform-list applied to the tspan's glyphs (the Character panel's vertical/horizontal scale writes a scale(h, v) here)
  text_transform:  string?                "none" | "uppercase"
  font_variant:    string?                "normal" | "small-caps"
  xml_lang:        string?                ISO 639-1
  text_rendering:  string?                "auto" | "optimizeSpeed" | "optimizeLegibility" | "geometricPrecision"
  jas_kerning_mode: string?               "auto" | "optical" | "metrics" | "numeric"
  jas_aa_mode:     string?                "none" | "sharp" | "crisp" | "strong" | "smooth"
  jas_fractional_widths: bool?            default on (absence = on)
  jas_no_break:    bool?                  default off
```

All attributes are optional. Missing = inherit from parent `Text`.
For attributes that have no natural slot on `Text` today
(baseline_shift, rotate, dx, jas_kerning_mode, jas_aa_mode, etc.),
the parent holds the element-wide default; the tspan can override.

`rotate` is the schema name for what the Character panel surfaces as
`CHARACTER_ROTATION_DROPDOWN` (see `CHARACTER.md`). The naming diverges
intentionally — the schema tracks the SVG attribute name, while the
panel tracks the UX label. The value is always a single degrees
number applied uniformly to every glyph in the tspan; per-glyph
rotation is achieved by splitting into one solo tspan per glyph
(see Touch Type cross-reference).

The parent `Text` element gains the **full** extended attribute
set: every tspan attribute except `id` (which is tspan-local) and
`content` (which is the tspan's substring) also exists as an
optional slot on `Text`. This lets a user set an element-wide
default for any attribute and override it per-tspan where needed.
The `Text` slot holds the same type as the tspan slot; a `null`
slot means "no element-wide default — fall back to the global
default".

The added `Text`-level attribute slots are:

```
Text (additions)
  baseline_shift:  float?                 pt, signed, + = up
  letter_spacing:  float?                 em, signed (tracking)
  line_height:     float?                 multiplier (leading)
  rotate:          float?                 degrees, signed, + = clockwise
  dx:              float?                 em, signed; per-element leading-edge horizontal nudge
  transform:       Transform?             already exists on Text; tspans compose with it
  text_transform:  string?                "none" | "uppercase"
  font_variant:    string?                "normal" | "small-caps"
  xml_lang:        string?                ISO 639-1
  text_rendering:  string?                SVG text-rendering value
  jas_kerning_mode:   string?             "auto" | "optical" | "metrics" | "numeric"
  jas_aa_mode:        string?             "none" | "sharp" | "crisp" | "strong" | "smooth"
  jas_fractional_widths: bool?            default on (absence = on)
  jas_no_break:       bool?               default off
```

`font_family`, `font_size`, `font_weight`, `font_style`, and
`text_decoration` already exist on `Text` today; they retain their
semantics and serve as the element-wide defaults for tspans. A
`style_name` slot is added to `Text` with the same semantics as
the tspan slot (see below).

**`style_name` is a display-only sidecar.** `font_weight` and
`font_style` remain the primary fields — they are what rendering
and CSS/SVG export use. `style_name` stores the original string
from the Style dropdown (e.g. `"Condensed Display Bold SC"` or
`"Semibold Italic Oblique"`) so that fonts with many named faces
round-trip without loss. When the Style dropdown changes,
`font_weight`, `font_style`, and `style_name` are updated together
as one commit. On export, `style_name` serializes as
`jas:style-name="…"` only when set; a tspan with no `style_name`
(the common case) emits no such attribute. Inheritance follows the
normal substitution rule: a tspan's `style_name` override
substitutes for the parent's, never composes.

**Tspan is not an `Element`.** It does not inherit from `Element`,
has no `id`, is not addressable by an element-path, is not
selectable as a canvas object (only the parent `Text` is), is not
independently locked or hidden, and is not present in the layer
tree. The only way to reach a tspan is through its parent `Text`'s
tspan list. Operations that take element references (move to
layer, group, align, distribute, …) never receive a tspan.

## Invariants

1. Every `Text` element has at least one tspan. An empty `Text`
   element has exactly one tspan whose `content` is the empty
   string.
2. `Text.content` is **derived**: it is the concatenation of every
   tspan's `content` in order. Writers compute it; readers should
   not assume the field is independently mutable. (See Migration
   below.)
3. Adjacent tspans with identical full, resolved attribute sets
   (i.e. post-inheritance) are collapsed by the merge primitive on
   every commit.
4. No tspan is nested inside another tspan. The tree is one level
   deep: `Text → [Tspan, Tspan, …]`. SVG inputs with nested tspans
   are flattened on import.
5. A tspan's `content` is an arbitrary substring — it may be empty
   (useful transiently during edits) but should be merged away on
   commit.
6. **Tspan ids are unique within a single `Text` element.** Ids are
   a monotonic `u32` scoped to the parent `Text`; `0` is reserved
   for the initial tspan of a freshly created or freshly imported
   `Text`. Ids are **in-memory only** — they are not written to
   SVG. On import, each imported tspan gets a fresh id. On save,
   ids are dropped.
7. Ids survive `split` (preserved on the left fragment, a fresh id
   given to the right) and survive `merge` (preserved on the
   surviving left tspan; the right tspan's id is dropped). Ids
   never collide within a single `Text` — the next id is always
   strictly greater than the current max, even after merges leave
   gaps in the sequence.

## Attribute inheritance

The **effective** value of an attribute for a tspan is:

1. If the tspan has a non-null override, use it.
2. Otherwise use the parent `Text`'s value (for attributes the
   `Text` stores).
3. Otherwise use the global default (Sans Serif 16 pt, etc.).

Writers follow the identity-omission rule (same as `CHARACTER.md`'s
SVG attribute mapping section): on commit, any tspan override that
equals the parent's effective value is set to null on that tspan, so
inherited-equal attributes are not serialized as overrides.

**`transform` composes rather than substitutes.** When both the
parent `Text` and a tspan set `transform`, the tspan's transform is
applied in addition to the parent's (matrix product in SVG's
ancestor order), matching SVG's intrinsic behavior. A tspan with no
`transform` override behaves as if it has an identity transform —
the parent's transform still applies to the whole element. This is
the only attribute with composition semantics; every other
attribute uses the substitution rule above.

## SVG serialization

Each tspan maps to an SVG `<tspan>` child of the parent `<text>`
(or `<textPath>`). The parent always carries `xml:space="preserve"`
and tspan children are written with **no** inter-tspan whitespace
so round-trips are byte-stable:

```svg
<text x="10" y="20" font-family="Arial" font-size="12" xml:space="preserve"><tspan>Hello </tspan><tspan font-weight="bold" fill="red">world</tspan></text>
```

- Omitted overrides are not written as attributes (identity rule).
- The parent `<text>` / `<textPath>` is always written with
  `xml:space="preserve"`, and tspan children are emitted with no
  inter-tspan text nodes (no newlines or indentation between
  `</tspan>` and the next `<tspan>`). On import, `xml:space`'s
  value is respected: when `"preserve"`, every character-data
  node is part of the content; when `"default"` (the SVG default),
  consecutive whitespace between tspans is collapsed per SVG
  rules. jas-written SVG is always the former case.
- Custom attributes use the `jas:` namespace declared on the root
  `<svg>` as `xmlns:jas="urn:jas:1"`. The URN is non-resolving and
  versioned; bumping the trailing digit would signal a breaking
  schema change for `jas:`-prefixed attributes.
- On import, nested tspans are flattened into the parent's tspan
  list; attribute inheritance is resolved at the nearest enclosing
  tspan's level before flattening.
- `Text.content` is not serialized directly — it is reconstructed
  from the tspan children on import.
- A tspan's `rotate` serializes as SVG's `rotate="θ"` attribute (a
  single-value list). On import, if the SVG `rotate` attribute is a
  multi-value list, the tspan is split into one solo tspan per
  covered character so each gets its own uniform `rotate`.
- Text elements with a single tspan that overrides nothing round-
  trip to SVG without a `<tspan>` element, so pre-Tspan documents
  serialize identically.

## Primitives

All primitives are **pure functions**. They take a `Text` value and
return a new `Text` value; the input is never mutated. This matches
the value-type representation of `Text` in every app (Python frozen
dataclass, Rust `struct` updated via `..e.clone()`, Swift `struct`,
OCaml record). Per-app idioms (`evolve`, `with`, record-update, etc.)
are implementation details; the spec describes inputs and outputs.

### Create a default tspan

`default_tspan() → Tspan` returns a tspan with empty `content`, no
overrides, and id `0`. Used by the Type Tool when it creates a new
`Text` element; the resulting `Text` holds a one-element tspan list
containing this value.

### Split at offset

`split(text, tspan_idx, offset) → (text', left_idx, right_idx)`

- Pre: `0 ≤ offset ≤ tspan.content.length`.
- `left_idx` and `right_idx` are each either a tspan index or
  nullable / absent when out of range (`None` in Rust/OCaml,
  `nil` in Swift, `None` in Python, `null` in test fixtures).
- If `offset == 0`: `text' == text`; `left_idx = tspan_idx - 1` or
  absent when `tspan_idx == 0`, `right_idx = tspan_idx`.
- If `offset == tspan.content.length`: `text' == text`;
  `left_idx = tspan_idx`, `right_idx = tspan_idx + 1` or absent
  when `tspan_idx` is the last index.
- Otherwise `text'` is a new `Text` whose tspan list equals
  `text`'s except that the tspan at `tspan_idx` is replaced by two
  tspans `left` and `right` sharing the original's attribute
  overrides, with `left.content == tspan.content[0:offset]` and
  `right.content == tspan.content[offset:]`. `left.id` equals the
  original's id; `right.id` is a fresh id (strictly greater than
  every id currently in `text`).

Split never triggers merge; callers that need both call both.

### Split across a range

`split_range(text, char_start, char_end) → (text', first_idx, last_idx)`

Returns a new `Text` whose tspan list exactly covers the character
range `[char_start, char_end)` of the input's concatenated content
with a contiguous run of tspans. Splits at each endpoint if needed.
`first_idx` and `last_idx` are indices into `text'`'s tspan list
(inclusive) when the range is non-empty; both are absent (null /
`None` / `nil`) when `char_start == char_end`.

### Merge adjacent equal

`merge(text) → text'`

Returns a new `Text` in which, for each adjacent pair of tspans
with identical full resolved attribute sets, the pair has been
replaced by a single tspan whose `content` is the concatenation.
The surviving (left) tspan keeps its id; the right tspan's id is
dropped. Empty-content tspans are merged away unconditionally
(their attributes cannot be observed without content).

After `merge`, `text'` still satisfies the "at least one tspan"
invariant: a `text` whose concatenated content is empty returns a
`text'` with exactly one empty-content tspan.

### Concatenate contents

`concat_content(text) → string` returns the `Text`'s derived
content string: the concatenation of each tspan's `content` in
order. Pure; no `Text` is produced.

### Resolve an id to an index

`resolve_id(text, tspan_id) → int?` returns the current index of
the tspan with the given id, or `None` if no such tspan exists
(e.g. because it was dropped by `merge`). Callers that hold a
`TspanId` across edits use this to refresh their index before
other operations. O(n) in the tspan count; callers that care about
repeated lookups can cache.

## Selection

The existing selection model (see `SELECTION.md`) distinguishes
"object selected" from "inside a text-edit session". Both now
interact with tspans:

- **Object selection.** When a `Text` element is selected as an
  object (not in edit mode), the Character panel treats it as
  equivalent to a character-range selection covering every
  character. Writes apply uniformly.
- **Character-range selection** (inside a text-edit session). The
  selection is a `(char_start, char_end)` pair over the Text's
  concatenated content. Reads/writes use `split_range` + `merge` to
  operate on contiguous tspans.
- **Caret only** (`char_start == char_end`). The Character panel is
  enabled; writes go to the text-edit session's
  next-typed-character state (see below), not to the document.

## Hit testing

`hit_test(text, x, y) → (tspan_idx, offset)?` returns the character
closest to the point `(x, y)` in the element's local coordinates,
expressed as a `(tspan_idx, offset)` pair. Uses the platform font
measurer (Qt / Cairo / NSAttributedString / canvas). Returns `None`
outside the element's bounding box.

`tspan_fragments(text, tspan_idx) → list<rect>` returns one
bounding rect per rendered line fragment of the tspan. For point
text, or for an area-text tspan that fits entirely on one visual
line, the list has one entry. For an area-text tspan that wraps,
the list has one rect per visual line the tspan occupies, in
reading order. Rects are in the element's local coordinates.

Callers that need a single bounding box take the union themselves.
The Touch Type tool operates on single-glyph tspans, which never
wrap, so it consumes the first (and only) fragment directly.

`hit_test` uses the layout produced by the rendering algorithm
below; both must agree so the character the user clicks matches
the character that was rendered.

## Rendering

`text_layout` (and its per-app equivalents in Rust, Swift, OCaml)
becomes a **segmented measurer**: instead of measuring a single
string with a single font, it walks the tspan list in reading
order, measuring each tspan with its effective attributes.

This is a real subsystem change, not a data-model tweak. All four
native apps' text-layout modules must be extended or rewritten to
honor per-tspan attributes.

### Segmented measurement

The platform measurer is parameterised by the tspan's effective
attributes instead of being a fixed closure:

- Old signature: `measure(s: string) -> float`
- New signature: `measure(tspan: Tspan, s: string) -> advance` where
  `advance` carries the horizontal run length, ascent, and
  descent for the measured substring using the tspan's effective
  `font_family`, `font_size`, `font_weight`, `font_style`,
  `letter_spacing`, `jas_kerning_mode`, and
  `jas_fractional_widths`.

Per-app, this is backed by `QFontMetricsF` (Qt / Python), `Cairo`
(Rust), `NSAttributedString` (Swift), or the platform canvas
measurer (OCaml), each selected with a per-call font descriptor.

### Line metrics

For each visual line, the layout records:

- `ascent` = max of the measured ascent of every tspan fragment on
  the line.
- `descent` = max of measured descents.
- `line_height` = `(ascent + descent) * text.line_height_multiplier`
  where the multiplier is the tspan's effective `line_height` or
  the Text-level default (1.2 if neither is set).

Lines are positioned with baselines at cumulative `line_height`
offsets from the element's top-left layout origin; the first
line's baseline is at `top + ascent_of_line_0`.

### Horizontal advance within a line

The cursor starts at the line's left edge (x = 0 for point text,
x = 0 within the area rectangle for area text). For each tspan
fragment on the line:

1. Add the tspan's `dx` override, if any, to the cursor (a one-time
   nudge at the tspan's leading edge).
2. For each character, place its glyph at the current cursor,
   advance the cursor by the measured character advance (which
   already includes `letter_spacing`).
3. If the tspan has a non-identity `transform`, the glyphs render
   through that transform in local coordinates, but the cursor
   continues to advance as if the transform were identity (SVG
   semantics — transform on a tspan does not push following
   tspans).

### Rotation

A tspan's `rotate: θ` rotates each glyph around its own origin
point (baseline start of the glyph cell). The cursor advances in
the un-rotated direction, matching SVG's `rotate` attribute
semantics. This is distinct from `transform: rotate(...)`, which
applies the rotation to the tspan as a whole.

### Wrapping (area text only)

Word-wrap uses the same whitespace-run break model as today. The
wrap point is computed using segmented widths — a word spanning a
tspan boundary uses each side's effective advance. Tspan
boundaries themselves are not preferred break points.

A tspan with `jas_no_break = true` is treated as atomic: if the
whole tspan's content does not fit on the remaining line, the
layout breaks before the tspan and places it on the next line. If
the tspan still doesn't fit on a fresh line, it overflows rather
than break at character boundaries.

A tspan with `jas_no_break` unset whose content alone exceeds the
area width breaks at character boundaries as a last resort, same
as today.

### TextPath

`TextPath` gains full tspan parity: a non-empty `tspans: list<Tspan>`
field (with the same migration rules as `Text` — string factory,
`content` accessor, default-tspan normalization), the full set of
element-wide extended attribute slots, and the same `style_name`
sidecar. Glyphs laid out along the path are measured with their
tspan's effective attributes via the segmented measurer; the path's
arc-length parameterisation is unchanged, but each glyph's advance
now comes from the per-tspan measurer rather than a single font.

Touch Type remains inert on TextPath in v1 (see `TOOLS.md`) — this
is a separate scope decision orthogonal to the data model. The
data model is ready; Touch Type simply does not target TextPath
glyphs yet.

Primitives (`split`, `split_range`, `merge`, `resolve_id`,
`concat_content`, `tspan_fragments`, `hit_test`) all apply to
TextPath as they do to Text, with their signatures taking
`TextPath` values instead.

## Text-edit session integration

The existing `TextEditSession` (see `TOOLS.md` → Type Tool) holds
the caret and selection as character offsets into `Text.content`.
It is extended as follows:

- Caret becomes a `(tspan_idx, offset_within_tspan)` pair
  internally; external APIs accept and return the equivalent
  character offset for compatibility.
- **Typing at a caret.** The inserted character(s) are appended
  into the tspan containing the caret (to the left of the caret if
  the caret is on a boundary; i.e. new text inherits the attributes
  of the previous character). If the caret is at the very start of
  the element (index 0 of tspan 0), the next-typed-character state
  is consulted.
- **Next-typed-character state.** The session tracks a pending
  attribute override carried forward from the last panel write
  with zero-width selection. It is consumed on the next insertion,
  which creates a new tspan if needed. This state lives only in
  the in-memory `TextEditSession`; it is **not** persisted to the
  document. An empty-content tspan is never used to carry it —
  empty tspans are merged away on every commit per Invariant #5.
  Saving a document with a pending next-typed-character state
  drops that state; on reload, the caret (and the pending state
  with it) are gone, and the user starts fresh.
- **Deletion across a tspan boundary.** After deletion, run `merge`
  to collapse now-adjacent equal tspans.
- **Cut / copy.** The clipboard carries the selection in three
  formats simultaneously so each paste target can pick the form it
  understands:
  - `application/x-jas-tspans` — a JSON object
    `{"tspans": [Tspan, …]}` carrying the selected tspan sub-list
    verbatim (with `id` stripped, since ids are per-Text and don't
    cross elements). Preferred by jas apps.
  - `image/svg+xml` — an SVG fragment `<text><tspan>…</tspan>…</text>`
    with the same tspans serialized per the SVG serialization
    rules. Preferred by other SVG-aware apps.
  - `text/plain` — the concatenated `content` of the selected
    range. Used as a last resort by unrelated text editors.
- **Paste.** On paste, the session reads the clipboard in
  preference order: `application/x-jas-tspans` > `image/svg+xml` >
  `text/plain`. A `jas:tspans` paste inserts the tspan list at the
  caret, splitting the host tspan if needed; fresh ids are
  assigned to the pasted tspans (they come from a different `Text`
  element). An SVG paste parses the fragment, flattens nested
  tspans, and inserts as above. A plain-text paste inserts the
  text into the host tspan inheriting its attributes.
- **Undo.** One undo unit per commit (same as today); splits /
  merges performed within a commit are part of the same unit.

## Character attribute writes (from panels)

Algorithm for applying an attribute `a = v` to a character range
`[char_start, char_end)` in a `Text`:

1. `text = split_range(text, char_start, char_end)` — now the
   targeted tspans are contiguous and exactly cover the range.
2. For each targeted tspan, set `tspan.a = v` (override).
3. Apply the identity-omission rule: if any targeted tspan's new
   override now equals the parent's effective value, set it to
   null.
4. `text = merge(text)` — collapse newly-equal adjacent tspans.
5. Emit an undo unit.

This algorithm is the same for every Character-panel write. The
panel does not need special cases per attribute.

## Touch Type tool (cross-reference)

Touch Type (see `TOOLS.md`) uses tspans to persist per-glyph
transforms:

- Tap selects one glyph inside the currently selected `Text`
  element. Selection is stored as `(tspan_id, offset_within_tspan)`
  identifying the glyph's left edge — the stable id form so the
  selection survives edits that renumber tspan indices elsewhere
  in the element. The glyph itself is the single character at that
  offset. Callers resolve the id to a current index via
  `resolve_id` before each operation; if `resolve_id` returns
  `None`, the selection is cleared.
- On first transform commit (pointer-up of a gesture that changes
  any attribute), `split_range` is used to isolate the glyph into
  its own solo tspan, preserving all surrounding attribute values.
- Attribute writes (baseline_shift, rotate, scales, dx) go through
  the per-range algorithm above on the glyph's one-character range.
- When all touch-type attributes on a solo tspan have returned to
  identity, the next commit's `merge` collapses it back into its
  neighbours.

## Migration

**Field change.** `Text` loses its `content: string` field and gains
`tspans: list<Tspan>` (ordered, non-empty).

| App | Representation |
|-----|----------------|
| Python | `tspans: tuple[Tspan, ...]` on the frozen dataclass |
| Rust   | `pub tspans: Vec<Tspan>` on `TextElem` |
| Swift  | `let tspans: [Tspan]` on `struct Text` |
| OCaml  | `tspans : tspan list` in the record |

**Read accessor.** Every app exposes a read-only `content` accessor
that returns the derived concatenation (`concat_content(text)`):

| App | Surface |
|-----|---------|
| Python | `@property` `content -> str` on `Text` |
| Rust   | `pub fn content(&self) -> String` on `TextElem` |
| Swift  | `var content: String { get }` computed property |
| OCaml  | `val content : text -> string` |

Read call sites (`text.content`, `t.content`, `content t`, etc.)
keep working unchanged.

**Constructor invariant.** The `Text` constructor accepts `tspans`;
if an empty list is supplied, it is normalized to
`[default_tspan()]` (one empty-content tspan with id `0`) so the
"at least one tspan" invariant always holds at runtime. A non-
empty list is stored verbatim.

**Convenience factory.** Every app provides a string-based factory
that creates a `Text` with exactly one tspan holding the given
string:

| App | Factory |
|-----|---------|
| Python | `Text.from_string(content, ...)` classmethod |
| Rust   | `TextElem::from_string(content, ...)` associated fn |
| Swift  | `Text(content: String, ...)` convenience init |
| OCaml  | `Text.of_string : string -> ... -> text` |

The factory builds the tspan via `default_tspan()` and sets its
`content`. SVG import uses the factory whenever the source `<text>`
has no `<tspan>` children (so textually flat inputs produce a
textually flat internal representation). Legacy call sites that
construct with a bare content string migrate to this factory.

**Call-site migration.** Callers that wrote `Text(content="Hi", ...)`
become `Text.from_string("Hi", ...)` — a mechanical rename the
compiler catches in typed languages and the test suite catches in
Python. Callers that **read** `text.content` need no change.

**SVG round-trip.** Pre-Tspan documents (`<text>Hello</text>` with
no `<tspan>` children) load to a `Text` with one default tspan whose
`content = "Hello"` and zero overrides. On export, a `Text` whose
sole tspan has zero overrides emits `<text>…</text>` without a
`<tspan>` wrapper. Net effect: on-disk SVG is textually unchanged
after a round-trip of a pre-Tspan document.

**`text_decoration` type widening.** The existing `Text.text_decoration`
field is widened from `string` to `set<string>` for parity with the
tspan slot (so inheritance resolves consistently). On import, a
legacy string value parses to a set: `"none"` → `{}`, `"underline"`
→ `{"underline"}`, `"underline line-through"` →
`{"underline", "line-through"}`. On export, the set serializes to a
space-separated string (`""`, `"underline"`, `"underline line-through"`);
an empty set serializes as the attribute being omitted (equivalent
to the CSS default of `none`). Legacy call sites that passed
`text_decoration="underline"` as a string migrate to passing the
one-element set; the compiler / type checker catches this in typed
languages.

## Cross-language implementation checklist

The CLAUDE.md language order is Rust → Swift → OCaml → Python.
Flask does not render canvas text today and is out of scope for
the Tspan B.3-B.6 sequence; it reappears in Phase 3 when the
Character panel is wired up.

Per app:

- [ ] **Data model.** Add the `Tspan` type. Extend both `Text` and
  `TextPath` with the new attribute slots and an ordered tspan
  list (non-empty invariant).
- [ ] **Serialization.** SVG read/write of the tspan list, the
  `jas:` namespace, identity-omission rule, pre-Tspan round-trip.
- [ ] **Primitives.** `default_tspan`, `split`, `split_range`,
  `merge`, `concat_content`, `tspan_bounds`, `hit_test`.
- [ ] **Layout and rendering.** Rewrite the app's `text_layout`
  module into a segmented measurer per the Rendering section:
  per-tspan effective-attribute measurement, line ascent/descent
  from the max over tspan fragments on each line, `dx`/`transform`/
  `rotate` handled per-tspan, wrapping with `jas_no_break`. Canvas
  draws tspans with their effective attributes; transforms and
  rotations apply in local coordinates.
- [ ] **Text-edit session.** Caret as `(tspan_idx, offset)`
  internally; typing / deletion / cut / copy / paste behave per the
  session section above; next-typed-character state.
- [ ] **Undo.** Tspan splits and merges are part of the enclosing
  commit's undo unit.
- [ ] **Tests.** The cross-language fixtures in
  `workspace/tests/tspan/` must pass.

## Open questions

_None remain at the time of writing — all initial strawmen have
been resolved. Add new questions here as they arise during the
per-app implementation (B.3-B.6)._
