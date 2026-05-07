# Layout

## Overview

The workspace YAML describes UI layout in a Bootstrap-flavored
12-column grid model. The Rust port renders this directly via
Bootstrap CSS in the browser; the other ports (Swift, OCaml,
Python) implement an equivalent model in their native widget
toolkits. The intent is that the same panel YAML produces visually
matching layout (column widths, row spacing, wrap behavior) across
every port.

This document pins down the YAML primitives, the style properties,
and the disambiguation rules that the renderers must agree on. The
Rust port is the canonical reference: any divergence is a bug in
the non-Rust port.

## Layout primitives

A renderer encounters layout via the element's `type` field. Five
primitives carry layout meaning:

- **`container`** — Generic block. Default direction is column
  (children stack vertically, top to bottom). With `layout: row`
  the children stack horizontally instead. Honors all layout style
  properties below.

- **`row`** — Shorthand for a container with `layout: row` plus the
  Bootstrap `row` class. Children that are `col` elements participate
  in the 12-column grid (see below). Children that are not `col`
  elements lay out as plain horizontal flex children.

- **`col`** — A column slot inside a `row`. The `col: N` field
  gives the span (1–12). With no `col:` field, the column auto-sizes
  to its content. A `col` outside a `row` behaves like a plain
  vertical container.

- **`spacer`** — A flex-grow filler. Renders as an empty element
  with `flex: 1`. Used to push siblings to opposite ends of a row.

- **`separator`** — A 1px line. With `orientation: horizontal` (the
  default) it is a horizontal rule across the parent's width; with
  `orientation: vertical` it is a vertical rule that stretches to
  the parent's height.

A sixth primitive, **`grid`**, exists for non-row/column 2-D
layout (e.g. swatch tiles). It declares `cols: N` and lays out
children left-to-right, top-to-bottom in a uniform N-column grid
with `gap` spacing between cells. It does not participate in
the 12-column system.

## Style properties

Layout properties live under the element's `style:` map. The
following keys are layout-bearing and every renderer must honor
them with the documented semantics:

- **`gap`** (number, px) — Spacing inserted between sibling
  children of a container. Does not apply outside the first or
  last child. Default: 0.

- **`padding`** (number or shorthand) — Inset between the
  container's border and its children. Accepts the CSS shorthand
  (`"4 6"` is `top/bottom: 4 left/right: 6`; `"4 6 8 10"` is
  `top right bottom left`).

- **`margin`** (number or shorthand) — Outset around the element
  itself. Same shorthand parsing as `padding`.

- **`alignment`** (enum) — Cross-axis alignment of children.
  Values: `start`, `center`, `end`, `stretch`. Default: `stretch`
  (children fill the cross axis). Maps to CSS `align-items`.

- **`justify`** (enum) — Main-axis distribution of children.
  Values: `start`, `center`, `end`, `between`. Default: `start`.
  Maps to CSS `justify-content`.

- **`flex`** (number) — Grow factor along the main axis. `flex: 1`
  expands to fill available space; multiple flex children share
  proportionally. Default: 0 (no growth).

- **`width` / `height`** (number, px) — Fixed dimension. Overrides
  growth and the 12-column span if both are set.

- **`min_width` / `min_height` / `max_width` / `max_height`** —
  Bounds on the dimension; honored even when `flex` or a 12-col
  span would otherwise size the child.

- **`overflow`** (enum) — `visible`, `hidden`, `auto`. `overflow_y`
  / `overflow_x` constrain to one axis. Default: `visible`.

Non-layout style keys (`background`, `color`, `font_size`,
`border`, `border_radius`, etc.) are documented elsewhere — they
do not affect box geometry.

## Bootstrap 12-column semantics

A `row` is a 12-column grid. Each `col` child claims a span via
its `col: N` field where N is 1..12. The renderer must:

1. Compute the row's content width (parent width minus padding).
2. Subtract horizontal `gap * (visible_cols - 1)` from the content
   width to get the usable column width budget.
3. Each `col: N` child gets width `budget * N / 12`.
4. Children without `col:` (e.g. raw widgets, spacers) flex to
   fill remaining space and do not consume the 12-col budget.

If `col` spans sum to more than 12, the row wraps — the overflow
columns continue on a new line below, sharing the same width
budget. This matches Bootstrap's default behavior.

If the row is constrained narrower than the sum of column min-
widths, all columns shrink proportionally — they do not overflow
horizontally. Honor `min_width` per child.

## Edge cases and disambiguation

These cases are common sources of cross-port drift; pin them
down here once.

**`flex: 1` alongside `col: N`.** A row may contain a mix of
explicit-span columns and flex-grow children (typical pattern: a
fixed-width label column plus a flex-grow input). The renderer
allocates `col: N` widths first, then distributes the remaining
horizontal space to flex children proportionally to their `flex`
values.

**`col: N` with `width: ...` set.** The fixed `width` wins. The
column does not participate in the 12-col budget; its slot is
treated as flex-shrink content for the purpose of fitting.

**Sum of `col: N` < 12.** The remaining grid tracks are blank
space at the end of the row (left-aligned). To fill the row,
add a `spacer` (flex:1) or use `justify: between`.

**Sum of `col: N` > 12.** Row wraps onto a new line, repeating
the 12-col layout for the overflow.

**Gap on a container with one child.** No gap drawn (gap only
applies between siblings).

**Padding-vs-gap precedence.** `padding` is the container's
inner inset; `gap` is sibling separation. Both apply: the first
child sits at `padding`, subsequent children sit at
`padding + previous_right + gap`.

**Default alignment in a `row`.** Children align center on the
cross-axis (`alignment: center`) when not otherwise specified.
This matches the visual idiom most panel YAMLs assume; setting
`alignment: stretch` on the row overrides.

**Default alignment in a `container`.** Children stretch on the
cross-axis (`alignment: stretch`). A `container` of icon buttons
typically wants `alignment: start` to keep buttons left-edged.

**`spacer` outside a `row`.** A `spacer` in a vertical container
flex-grows along the vertical axis, pushing later children to the
bottom.

**Visibility (`bind.visible`).** A hidden child does not
participate in layout (treated as `display: none`, not
`visibility: hidden`). Its column slot collapses; siblings reflow
to fill the gap.

## Conformance testing

The repo's `tests/layout-conformance/` directory contains layout
fixtures, each a pair of files:

- `<name>.yaml` — a single layout snippet wrapped in a
  fixed-size container (typically 600×400). Uses only the
  primitives and properties defined above.
- `<name>.expected.json` — the ground-truth bounding boxes:

  ```
  {
    "container_size": { "width": 600, "height": 400 },
    "boxes": [
      { "id": "header",  "x": 0,   "y": 0,   "width": 600, "height": 40 },
      { "id": "sidebar", "x": 0,   "y": 40,  "width": 200, "height": 360 },
      ...
    ]
  }
  ```

Each port has a measure-only renderer mode that takes a YAML
snippet and emits the boxes as JSON. The Rust port generates the
ground-truth values by rendering in a headless browser and reading
`getBoundingClientRect`. Other ports' renderers must produce the
same boxes within ±1 px tolerance (font-metric drift is allowed
inside text widgets but not in the container layout).

A new layout fixture is added whenever a port's layout drifts; the
fixture both reproduces the drift and pins the canonical answer.
