# Unit-aware Length Inputs

## Motivation

Numeric panel fields that hold **lengths** — stroke weight, dash and gap
sizes, font size, leading, indents, artboard width and height — store
the canonical value as a number in points (pt). The current rendering
uses `number_input`, which the browser draws with native increment /
decrement spinners. Three problems compounded once the dash / gap row
landed:

1. **Crowding.** Six narrow inputs in one row share their width with the
   spinner gutter on every renderer that paints one (Flask / Bootstrap,
   Dioxus, Swift). The numeric area shrinks below readable.
2. **Unit blindness.** A user who works in mm / px / inches has to
   convert in their head before typing. Pasting "5 mm" today is just
   discarded by the number parser.
3. **Asymmetric editing.** Read-back always shows pt regardless of how
   the value was entered, so a value typed as "5 mm" reads back as the
   pt equivalent next time the panel renders.

The first two are the load-bearing complaints; the third is a v2
"sticky display" enhancement (see §Out of scope).

## Scope (v1)

A new widget type `length_input` that:

- Renders as a single text entry with no spinner gutter.
- Reads the bound numeric state field (in pt) and displays it formatted
  with the field's declared display unit, e.g. `"12 pt"`.
- Parses entries that include any supported unit suffix: `pt`, `px`,
  `mm`, `cm`, `in`, `pc`. A bare number is interpreted as the field's
  declared unit.
- Converts the parsed value to pt before commit, so the state field
  remains canonical and SVG output is unchanged.
- Validates against the field's `min:` / `max:` (interpreted in pt) and
  rejects out-of-range entries by reverting to the prior value.
- Honors the bound state field's nullability: an empty / whitespace-
  only entry on a nullable field commits `null`; on a non-nullable
  field it reverts.

Out of scope for v1:

- **Sticky display unit.** Display always uses the field's declared
  unit; what the user typed is not remembered across reads.
- **Percentages and angles.** `length_input` is for length values only;
  percent / degree fields stay on `number_input` until a parallel
  `percent_input` / `angle_input` is spec'd.
- **Computed em / %.** `em` and `%` units depend on context (font size,
  parent width); deferred until the contextual machinery exists.

Initial application: `workspace/panels/stroke.yaml` `stk_dash_1..3`,
`stk_gap_1..3`, `stk_weight`. Other panels (Character, Paragraph,
Opacity, Artboard dialogs, …) migrate in a follow-up.

## Schema additions

```yaml
- id: <id>
  type: length_input
  unit: <pt | px | mm | cm | in | pc>     # required; canonical / display unit
  bind:
    value: <state-or-panel-path>          # number, in canonical pt
    disabled: <expr>                      # optional
  min: <number>                           # optional, in pt
  max: <number>                           # optional, in pt
  precision: <integer>                    # optional, default 2
  placeholder: <string>                   # optional, e.g. "0 pt"
  style: { width: <number> }              # optional
```

The state field bound by `value` must be of `type: number` (with
`nullable: true` when an empty entry should write `null`). The display
unit declared on the widget is independent of the bound field's type.

## Parser

```
input := whitespace? value whitespace? unit? whitespace?
value := "-"? digit+ ("." digit*)? | "-"? "." digit+
unit  := "pt" | "px" | "mm" | "cm" | "in" | "pc"   (case-insensitive)
```

Behavior:

- **Bare value.** No unit ⇒ assume the widget's `unit:`.
- **Match.** Unit recognised ⇒ convert value to pt via the table below.
- **Unknown unit.** Any letter sequence not in the supported set ⇒
  reject (revert).
- **Empty / whitespace.** Nullable field ⇒ commit `null`. Non-nullable
  ⇒ reject.
- **Out of range.** `min` / `max` violated after conversion to pt ⇒
  reject.
- **Reject behavior.** Restore the displayed value from the bound
  state; do not commit.

## Conversion table (canonical = pt)

| unit | pt per unit                    | derivation                          |
|------|--------------------------------|-------------------------------------|
| pt   | 1                              | identity                            |
| px   | 0.75                           | 1 px = 1/96 in, 1 pt = 1/72 in     |
| in   | 72                             | 1 in = 72 pt                        |
| mm   | 72 / 25.4 ≈ 2.834645669       | 1 in = 25.4 mm                      |
| cm   | 720 / 25.4 ≈ 28.34645669      | 10 mm = 1 cm                        |
| pc   | 12                             | 1 pica = 12 pt                      |

`px` follows the CSS reference 96 dpi convention. Apps that need a
different dpi map (printer drivers, e.g.) override at the renderer
layer.

## Display formatting

`format(pt, unit, precision)`:

1. Convert `pt` to the target `unit`: `value = pt / pt_per_unit[unit]`.
2. Round to `precision` decimal places.
3. Trim trailing zeros and a trailing decimal point.
4. Concatenate with `" " + unit`.

Examples (precision = 2):

| pt    | unit | output      |
|-------|------|-------------|
| 12    | pt   | `12 pt`     |
| 12.5  | pt   | `12.5 pt`   |
| 12    | mm   | `4.23 mm`   |
| 14.17 | mm   | `5 mm`      |
| 0.75  | px   | `1 px`      |

`null` ⇒ empty string `""`.

## Edge cases

| input        | widget unit | result           | note                       |
|--------------|-------------|------------------|----------------------------|
| `"12"`       | pt          | 12 pt            | bare number ⇒ widget unit  |
| `"12 pt"`    | pt          | 12 pt            | space optional             |
| `"12pt"`     | pt          | 12 pt            | no space                   |
| `"12 PT"`    | pt          | 12 pt            | case-insensitive           |
| `"-3 pt"`    | pt          | -3 pt or reject  | depends on `min:`          |
| `".5 mm"`    | pt          | 1.4173… pt       | leading-dot decimal        |
| `"5."`       | pt          | 5 pt             | trailing-dot decimal       |
| `""`         | pt          | null or revert   | nullability                |
| `"   "`      | pt          | null or revert   | whitespace = empty         |
| `"5 mm pt"`  | pt          | revert           | extra tokens               |
| `"pt"`       | pt          | revert           | no number                  |
| `"5 dpi"`    | pt          | revert           | unknown unit               |
| `"5 mm 3"`   | pt          | revert           | extra tokens               |

## Per-app implementation notes

Each app provides:

- `parse_length(s: string, default_unit: string) -> number | null`
- `format_length(pt: number, unit: string, precision: integer) -> string`

Wired into the panel renderer's commit path:

- **Flask.** `jas_flask/static/js/app.js` exports `parseLength` /
  `formatLength`; the renderer (`renderer.py`) emits `length_input`
  as a text input with `data-length-unit="<unit>"`,
  `data-length-precision="<n>"`, and the formatted current value;
  the input commit handler in `app.js` reads the data attributes,
  parses the entered string, and routes the pt value through
  `setState`.
- **Rust.** `jas_dioxus/src/interpreter/length.rs` houses the
  parser and formatter; `interpreter/renderer.rs` adds a
  `length_input` arm next to `text_input` / `number_input`.
- **Swift / OCaml / Python.** Mirror the Rust module: a small
  `length` helper next to the existing `parse_pt` / similar.

Floating-point precision (rounding mode, comparison tolerance) is left
to each language's standard library — round-half-away-from-zero is
acceptable across all five.

## Migration plan

1. Spec lands here; no app changes yet.
2. Flask: parser + formatter + renderer + app.js commit path; tests in
   `tests/test_renderer.py`.
3. Stroke YAML: migrate `stk_weight`, `stk_dash_1..3`, `stk_gap_1..3`
   from `number_input` to `length_input` with `unit: pt`.
4. Manual verify in Flask.
5. Rust: same machinery, exercise via the rust-stroke-parity testing
   path.
6. Swift, OCaml, Python: in their CLAUDE.md propagation order.
7. Follow-up commits migrate other length fields (Character font size /
   leading, Paragraph indents, Artboard dimensions, Opacity / shear
   distance fields, …).

## Examples

Migrated stroke field:

```yaml
- id: stk_weight
  type: length_input
  unit: pt
  min: 0
  bind:
    value: "panel.weight"
  style: { width: 56 }
```

Nullable dash slot:

```yaml
- id: stk_dash_2
  type: length_input
  unit: pt
  min: 0
  placeholder: ""                    # blank when state.stroke_dash_2 is null
  bind:
    value: "panel.dash_2"
    disabled: "not panel.dashed or state.stroke_brush != null"
  style: { width: 44 }
```

Hypothetical Character-panel migration (illustrative — not in v1):

```yaml
- id: char_font_size
  type: length_input
  unit: pt
  min: 1
  max: 1296                          # 18 in
  bind:
    value: "panel.font_size"
  style: { width: 60 }
```
