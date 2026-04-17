# Cross-Language Testing

This document describes the cross-language behavioral equivalence testing
strategy for the four JAS implementations.

---

## Goal

Show that all four implementations are behaviorally equivalent: given the
same input, they produce the same output. Rather than testing each app in
isolation, we define shared test fixtures that all four consume, and
compare results via a canonical interchange format.

---

## Canonical Test JSON

The central problem in cross-language equivalence testing is that
semantically equivalent values can have many syntactic representations.
Two implementations might produce the same document but serialize it
differently (different float formatting, different attribute ordering,
different SVG path notation).

We solve this by defining a **Canonical Test JSON** format: a JSON
encoding of the document model where each semantic value has exactly one
string representation. If two documents are semantically equal, their
canonical JSON is byte-for-byte identical.

Each implementation provides a function:

```
document_to_test_json(doc: Document) -> String
```

### Normalization rules

1. **Keys**: sorted alphabetically at every nesting level.
2. **Floats**: rounded to 4 decimal places, always written with the
   decimal point (e.g., `1.0`, `0.0`, `3.1416`). No trailing zeros
   beyond the decimal point except to fill 4 places when needed for
   precision. Use standard JSON number formatting: `1.0` not `1.0000`.
   Values that round to integers still include the decimal: `1.0`.
3. **Null**: used for absent optional values (`transform`, `fill`,
   `stroke`). Never omit a key -- always include it with `null`.
4. **Booleans**: JSON `true`/`false`.
5. **Strings**: JSON strings with standard escaping.
6. **Arrays**: preserve element ordering (layers, children, points,
   path commands are ordered sequences).
7. **Selection**: entries sorted lexicographically by path (comparing
   integer lists element-wise).
8. **Enums**: lowercase string representation (`"butt"`, `"round"`,
   `"miter"`, `"bevel"`, `"square"`, `"preview"`, `"outline"`,
   `"invisible"`).
9. **Indentation**: none. Compact single-line JSON for comparison.
   Pretty-printed only for debugging.

### Document schema

```json
{
  "layers": [<layer>, ...],
  "selected_layer": 0,
  "selection": [<element_selection>, ...]
}
```

### Element selection

```json
{"kind": "all", "path": [0, 1]}
{"kind": {"partial": [0, 2, 4]}, "path": [0, 1]}
```

### Element schemas

Every element is a JSON object with a `"type"` field and all properties
listed explicitly (no omissions for defaults).

**Line** (no fill -- lines are stroke-only):
```json
{
  "type": "line",
  "x1": 0.0, "y1": 0.0, "x2": 72.0, "y2": 36.0,
  "stroke": {"color": {"r": 0.0, "g": 0.0, "b": 0.0, "a": 1.0}, "width": 1.0, "linecap": "butt", "linejoin": "miter"},
  "opacity": 1.0,
  "transform": null,
  "locked": false,
  "visibility": "preview"
}
```

**Rect:**
```json
{
  "type": "rect",
  "x": 0.0, "y": 0.0, "width": 100.0, "height": 50.0,
  "rx": 0.0, "ry": 0.0,
  "fill": {"color": {"r": 1.0, "g": 0.0, "b": 0.0, "a": 1.0}},
  "stroke": null,
  "opacity": 1.0,
  "transform": null,
  "locked": false,
  "visibility": "preview"
}
```

**Circle:**
```json
{
  "type": "circle",
  "cx": 50.0, "cy": 50.0, "r": 25.0,
  "fill": null, "stroke": null,
  "opacity": 1.0, "transform": null, "locked": false, "visibility": "preview"
}
```

**Ellipse:**
```json
{
  "type": "ellipse",
  "cx": 50.0, "cy": 50.0, "rx": 30.0, "ry": 20.0,
  "fill": null, "stroke": null,
  "opacity": 1.0, "transform": null, "locked": false, "visibility": "preview"
}
```

**Polyline:**
```json
{
  "type": "polyline",
  "points": [[0.0, 0.0], [10.0, 20.0], [30.0, 10.0]],
  "fill": null, "stroke": null,
  "opacity": 1.0, "transform": null, "locked": false, "visibility": "preview"
}
```

**Polygon:**
```json
{
  "type": "polygon",
  "points": [[0.0, 0.0], [10.0, 0.0], [10.0, 10.0], [0.0, 10.0]],
  "fill": null, "stroke": null,
  "opacity": 1.0, "transform": null, "locked": false, "visibility": "preview"
}
```

**Path:**
```json
{
  "type": "path",
  "d": [
    {"cmd": "M", "x": 0.0, "y": 0.0},
    {"cmd": "L", "x": 50.0, "y": 50.0},
    {"cmd": "C", "x": 100.0, "y": 50.0, "x1": 60.0, "y1": 0.0, "x2": 90.0, "y2": 20.0},
    {"cmd": "S", "x": 150.0, "y": 0.0, "x2": 140.0, "y2": 0.0},
    {"cmd": "Q", "x": 200.0, "y": 50.0, "x1": 175.0, "y1": 0.0},
    {"cmd": "T", "x": 250.0, "y": 0.0},
    {"cmd": "A", "large_arc": false, "rx": 25.0, "ry": 25.0, "sweep": true, "x": 300.0, "x_rotation": 0.0, "y": 0.0},
    {"cmd": "Z"}
  ],
  "fill": null, "stroke": null,
  "opacity": 1.0, "transform": null, "locked": false, "visibility": "preview"
}
```

Note: path command keys are sorted alphabetically like all other keys.

**Text:**
```json
{
  "baseline_shift": null,
  "dx": null,
  "fill": null,
  "font_family": "sans-serif",
  "font_size": 16.0,
  "font_style": "normal",
  "font_variant": null,
  "font_weight": "normal",
  "height": 0.0,
  "jas_aa_mode": null,
  "jas_fractional_widths": null,
  "jas_kerning_mode": null,
  "jas_no_break": null,
  "letter_spacing": null,
  "line_height": null,
  "locked": false,
  "opacity": 1.0,
  "rotate": null,
  "stroke": null,
  "style_name": null,
  "text_decoration": [],
  "text_rendering": null,
  "text_transform": null,
  "transform": null,
  "tspans": [<Tspan>, ...],
  "type": "text",
  "visibility": "preview",
  "width": 0.0,
  "x": 10.0,
  "xml_lang": null,
  "y": 20.0
}
```

Notes on the Text shape:

- `content` is **not** an emitted key — it's a derived accessor on
  `Text`, equivalent to concatenating every tspan's `content`. The
  canonical JSON carries `tspans` instead; tools that need the full
  string compute it at read time.
- Extended attribute slots (`baseline_shift`, `dx`, `letter_spacing`,
  `line_height`, `rotate`, `font_variant`, `text_transform`,
  `xml_lang`, `text_rendering`, `style_name`, `jas_aa_mode`,
  `jas_kerning_mode`, `jas_fractional_widths`, `jas_no_break`) are
  element-wide defaults. `null` means no element-wide default — the
  global default applies. See `TSPAN.md`.
- `text_decoration` is a **sorted array** with members drawn from
  `{"underline", "line-through"}`. An empty array means no
  decoration. Canonical ordering: alphabetical (`"line-through"`
  precedes `"underline"`).
- `tspans` is a non-empty array. The empty-content case is a single
  default tspan.

**TextPath:**
```json
{
  "baseline_shift": null,
  "d": [{"cmd": "M", "x": 0.0, "y": 0.0}, {"cmd": "L", "x": 100.0, "y": 0.0}],
  "dx": null,
  "fill": null,
  "font_family": "sans-serif",
  "font_size": 16.0,
  "font_style": "normal",
  "font_variant": null,
  "font_weight": "normal",
  "jas_aa_mode": null,
  "jas_fractional_widths": null,
  "jas_kerning_mode": null,
  "jas_no_break": null,
  "letter_spacing": null,
  "line_height": null,
  "locked": false,
  "opacity": 1.0,
  "rotate": null,
  "start_offset": 0.0,
  "stroke": null,
  "style_name": null,
  "text_decoration": [],
  "text_rendering": null,
  "text_transform": null,
  "transform": null,
  "tspans": [<Tspan>, ...],
  "type": "text_path",
  "visibility": "preview",
  "xml_lang": null
}
```

`TextPath` has full tspan parity with `Text` (see TSPAN.md Open
Question #1 resolution).

**Tspan:**
```json
{
  "baseline_shift": null,
  "content": "Hello",
  "dx": null,
  "font_family": null,
  "font_size": null,
  "font_style": null,
  "font_variant": null,
  "font_weight": null,
  "id": 0,
  "jas_aa_mode": null,
  "jas_fractional_widths": null,
  "jas_kerning_mode": null,
  "jas_no_break": null,
  "letter_spacing": null,
  "line_height": null,
  "rotate": null,
  "style_name": null,
  "text_decoration": null,
  "text_rendering": null,
  "text_transform": null,
  "transform": null,
  "xml_lang": null
}
```

Notes on the Tspan shape:

- `id` is the in-memory stable id (monotonic `u32`, unique within
  the parent `Text` or `TextPath`). Starts at `0` for the initial
  tspan; each split that creates a right fragment bumps it above
  the current max.
- `content` is the tspan's substring of its parent's text. Always
  present, even when empty (`""`).
- Every other key is an override slot; `null` means "inherit from
  the parent element's effective value". A non-null override
  substitutes for the parent, except `transform` which composes
  (see TSPAN.md's Attribute Inheritance section).
- `text_decoration` override is either `null` (inherit) or a
  sorted-array set (same domain as on Text).
- Tspan objects never appear outside a parent's `tspans` array.

**Group:**
```json
{
  "type": "group",
  "children": [<element>, ...],
  "opacity": 1.0, "transform": null, "locked": false, "visibility": "preview"
}
```

**Layer:**
```json
{
  "type": "layer",
  "name": "Layer 1",
  "children": [<element>, ...],
  "opacity": 1.0, "transform": null, "locked": false, "visibility": "preview"
}
```

### Transform

```json
{"a": 1.0, "b": 0.0, "c": 0.0, "d": 1.0, "e": 10.0, "f": 20.0}
```

---

## Test Types

### 1. Parse equivalence

All four implementations parse the same SVG and produce the same
canonical JSON.

```
            parse_A          to_test_json
   SVG ──────────────> Doc_A ──────────────> JSON_A
    |                                           ||
    |  parse_B          to_test_json            ||
    +──────────────> Doc_B ──────────────> JSON_B

   Assert: JSON_A = JSON_B
```

Test fixture: an SVG file plus the expected canonical JSON. Each
implementation parses the SVG, emits canonical JSON, and asserts
equality with the expected value. If all four pass, they agree.

### 2. Serialize-parse commutativity

Serializing in language A and parsing in language B preserves the
document.

```
            to_svg_A          parse_B          to_test_json
   Doc ──────────────> SVG_A ──────────────> Doc' ──────────────> JSON'
    |                                                                ||
    |  to_test_json                                                  ||
    +──────────────────────────────────────────────────────────> JSON

   Assert: JSON = JSON'   (for all 16 language pairs)
```

Test fixture: a canonical JSON document. Each implementation:
1. Constructs the document from the canonical JSON.
2. Emits canonical JSON and checks it matches the input (round-trip).
3. Serializes to SVG and writes to a file.

A cross-language orchestrator then:
4. For each pair (A, B): feeds A's SVG to B's parser.
5. B emits canonical JSON.
6. Asserts it matches the original.

### 3. Operation equivalence

Applying the same operation in each language produces the same result.

```
            op_A            to_test_json
   Doc ──────────> Doc_A' ──────────────> JSON_A'
    |                                        ||
    |  op_B            to_test_json           ||
    +──────────> Doc_B' ──────────────> JSON_B'

   Assert: JSON_A' = JSON_B'
```

Test fixture: a starting document (as canonical JSON or SVG) plus a
sequence of operations (as JSON). Each implementation loads the
document, applies the operations, and emits canonical JSON.

Operation format:
```json
{
  "name": "move selected rectangle",
  "setup_svg": "two_rects.svg",
  "ops": [
    {"op": "select_rect", "x": 0, "y": 0, "width": 200, "height": 200, "extend": false},
    {"op": "move_selection", "dx": 10, "dy": 20}
  ],
  "expected_json": "two_rects_moved.json"
}
```

### 4. Algorithm test vectors

Pure functions tested with shared input/output pairs.

```json
[
  {"name": "interior", "function": "point_in_rect",
   "args": [5.0, 5.0, 0.0, 0.0, 10.0, 10.0], "expected": true},
  {"name": "crossing", "function": "segments_intersect",
   "args": [0.0, 0.0, 10.0, 10.0, 0.0, 10.0, 10.0, 0.0], "expected": true}
]
```

### 5. Undo/redo algebraic laws

Special case of operation equivalence. These identities must hold in
every implementation:

```
snapshot -> op -> undo                    =  identity
snapshot -> op -> undo -> redo            =  op
snapshot -> op1 -> snapshot -> op2 -> undo  =  op1
```

Tested by asserting canonical JSON equality at each step.

---

## Directory Structure

```
test_fixtures/
  svg/
    line_basic.svg
    rect_basic.svg
    rect_with_stroke.svg
    circle_basic.svg
    ellipse_basic.svg
    polyline_basic.svg
    polygon_basic.svg
    path_all_commands.svg
    text_basic.svg
    text_path_basic.svg
    group_nested.svg
    transform_translate.svg
    transform_rotate.svg
    multi_layer.svg
    complex_document.svg
  expected/
    line_basic.json
    rect_basic.json
    ...                     (one per SVG, canonical JSON after parsing)
  operations/
    select_and_move.json
    copy_selection.json
    undo_redo.json
    ...
  algorithms/
    hit_test.json
    measure.json
    element_bounds.json
```

Each language's test harness reads from `test_fixtures/` using a
relative path from its own test directory.

---

## Implementation per language

Each implementation adds:

1. `document_to_test_json(doc) -> String` -- canonical JSON serializer.
2. `test_json_to_document(json) -> Document` -- canonical JSON parser
   (needed for operation tests that start from JSON).
3. A test file that reads fixtures and runs assertions.

| Language | Serializer location | Test file |
|----------|-------------------|-----------|
| Rust | `jas_dioxus/src/geometry/test_json.rs` | `jas_dioxus/tests/cross_language_test.rs` |
| Swift | `JasSwift/Sources/Geometry/TestJson.swift` | `JasSwift/Tests/CrossLanguageTests.swift` |
| OCaml | `jas_ocaml/lib/geometry/test_json.ml` | `jas_ocaml/test/cross_language_test.ml` |
| Python | `jas/geometry/test_json.py` | `jas/cross_language_test.py` |

---

## Float precision

Canonical JSON rounds floats to 4 decimal places. This provides
0.0001-point precision (~0.00014 px), well below visual threshold.

If two implementations compute slightly different floats due to
evaluation order (e.g., `10.00005` vs `10.00004`), rounding may
diverge at the boundary. When this happens, investigate whether the
implementations are computing the same thing. Persistent boundary
cases indicate a real algorithmic difference worth fixing.
