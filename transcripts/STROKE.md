# Stroke

The Stroke panel edits the stroke attributes of the selected path(s).
This document is the requirements description from which
`workspace/panels/stroke.yaml` is generated.

## Overview

The Stroke panel is one tab in a tabbed panel group (alongside
Properties); the tabbed-group container is specified elsewhere. This
document covers only the Stroke tab.

The panel edits stroke attributes on the selected elements: weight,
cap style, join style with miter limit, stroke alignment, dash
pattern, arrowheads with per-end shape and scale, arrow alignment,
and a variable-width profile. All ten controls read from and write to
the flat `state.stroke_*` surface, which is the single source of
truth; the panel's own `panel.*` fields mirror `state.*` for
binding convenience and are re-initialised from `state.*` each time
the panel opens.

When no path is selected, the panel still binds the defaults — edits
become the new-path defaults for future draws. When a path (or paths)
is selected, edits apply immediately to the selection. Selection-
independent controls (like the profile dropdown) always behave the
same.

Several fields are conditionally disabled:

- The miter-limit input is disabled when the join style is round or
  bevel.
- All six dash / gap inputs are disabled while the Dashed Line
  checkbox is off. Their values persist and reappear when
  re-enabled.

## Controls

- `WEIGHT_INPUT` — `number_input`. Stroke weight in points;
  non-negative, decimals allowed. Committed on Enter or blur. Paired
  with a literal `"pt"` unit suffix.

- `CAP_BUTT`, `CAP_ROUND`, `CAP_SQUARE` — three mutually exclusive
  `icon_button`s for line cap style. Exactly one is checked. Icons
  are `cap_butt`, `cap_round`, `cap_square`. Default `CAP_BUTT`.

- `JOIN_MITER`, `JOIN_ROUND`, `JOIN_BEVEL` — three mutually
  exclusive `icon_button`s for line join style. Exactly one is
  checked. Icons are `join_miter`, `join_round`, `join_bevel`.
  Default `JOIN_MITER`.

- `MITER_LIMIT_INPUT` — `number_input`. Miter length / stroke width
  ratio. When the ratio of a miter join exceeds this value, the join
  auto-converts to bevel. Range ≥ 1. Disabled when `panel.join` is
  not `miter`.

- `ALIGN_CENTER`, `ALIGN_INSIDE`, `ALIGN_OUTSIDE` — three mutually
  exclusive `icon_button`s for stroke alignment relative to the
  path. `ALIGN_INSIDE` and `ALIGN_OUTSIDE` behave identically to
  `ALIGN_CENTER` on open paths. Default `ALIGN_CENTER`.

- `DASHED_CHECKBOX` — `checkbox` enabling the dash pattern.

- `EVEN_DASH_PRESET` — `icon_button` that turns dashing on and sets
  pair 1 to dash=12 gap=12, pairs 2/3 null.

- `DASH_DOT_PRESET` — `icon_button` that turns dashing on and sets
  pair 1 to dash=12 gap=6, pair 2 to dash=0 gap=6 (a dot with
  round caps), pair 3 null.

- `DASH_1`, `GAP_1`, `DASH_2`, `GAP_2`, `DASH_3`, `GAP_3` — six
  `number_input`s arranged as three dash/gap pairs under small
  literal labels ("dash" / "gap"). Pair 1 defaults to 12 / 12;
  pairs 2 and 3 default to null (blank, meaning unused). All six
  are disabled while `DASHED_CHECKBOX` is unchecked; values persist.

- `START_ARROWHEAD`, `END_ARROWHEAD` — two `select`s over the same
  list of 15 arrowhead shapes (see Arrowhead shapes below).

- `SWAP_ARROWHEADS_BUTTON` — `icon_button` that exchanges the start
  and end arrowhead selections, swapping both the shape and the
  scale value.

- `START_SCALE`, `END_SCALE` — two `combo_box`es for arrowhead
  scale as a percentage of stroke weight. Presets: 50, 75, 100, 150,
  200, 300, 400. Free numeric entry is allowed, minimum 1 %.
  Default 100 %.

- `LINK_SCALES_TOGGLE` — `icon_button` (chain icon). When active,
  changing either `START_SCALE` or `END_SCALE` updates both to the
  same value. Default off.

- `ARROW_TIP_AT_END`, `ARROW_CENTER_AT_END` — two mutually exclusive
  `icon_button`s for arrow alignment mode (see `panel.arrow_align`).
  Default `ARROW_TIP_AT_END`.

- `PROFILE_DROPDOWN` — `select` over six variable-width profile
  options (see Stroke profile below). Default `uniform`.

- `FLIP_PROFILE_BUTTON` — `icon_button` that toggles
  `panel.profile_flipped`. Only visually meaningful for asymmetric
  profiles (`taper_start`, `taper_end`).

- `RESET_PROFILE_BUTTON` — `icon_button` that restores `profile =
  uniform` and `profile_flipped = false` in one click.

## Layout

Strings in quotes are literal labels. Bare identifiers are widget IDs.

```yaml
panel:
- .row:                                          # weight
  - "Weight"
  - WEIGHT_INPUT
  - "pt"
- .row:                                          # cap style
  - "Cap"
  - CAP_BUTT
  - CAP_ROUND
  - CAP_SQUARE
- .row:                                          # join style + miter limit
  - "Corner"
  - JOIN_MITER
  - JOIN_ROUND
  - JOIN_BEVEL
  - "Limit"
  - MITER_LIMIT_INPUT
- .row:                                          # alignment
  - "Align Stroke"
  - ALIGN_CENTER
  - ALIGN_INSIDE
  - ALIGN_OUTSIDE
- .row:                                          # dashed line + presets
  - DASHED_CHECKBOX
  - EVEN_DASH_PRESET
  - DASH_DOT_PRESET
- .row:                                          # dash/gap pattern (3 pairs)
  - DASH_1 (under "dash")
  - GAP_1  (under "gap")
  - DASH_2 (under "dash")
  - GAP_2  (under "gap")
  - DASH_3 (under "dash")
  - GAP_3  (under "gap")
- .row:                                          # arrowheads (start / end / swap)
  - "Arrowheads"
  - START_ARROWHEAD
  - END_ARROWHEAD
  - SWAP_ARROWHEADS_BUTTON
- .row:                                          # scale (start / end / link)
  - "Scale"
  - START_SCALE
  - END_SCALE
  - LINK_SCALES_TOGGLE
- .row:                                          # arrow align
  - "Align"
  - ARROW_TIP_AT_END
  - ARROW_CENTER_AT_END
- .row:                                          # profile (dropdown + flip + reset)
  - "Profile"
  - PROFILE_DROPDOWN
  - FLIP_PROFILE_BUTTON
  - RESET_PROFILE_BUTTON
```

## Panel menu

- **Butt Cap** (checkmark if active) — sets `panel.cap = butt`.
- **Round Cap** (checkmark if active) — sets `panel.cap = round`.
- **Square Cap** (checkmark if active) — sets `panel.cap = square`.
  The three cap items form a radio group mirroring
  `CAP_BUTT` / `CAP_ROUND` / `CAP_SQUARE`.
- ----
- **Miter Join** (checkmark if active) — sets `panel.join = miter`.
- **Round Join** (checkmark if active) — sets `panel.join = round`.
- **Bevel Join** (checkmark if active) — sets `panel.join = bevel`.
  The three join items form a radio group mirroring
  `JOIN_MITER` / `JOIN_ROUND` / `JOIN_BEVEL`.
- ----
- **Close Stroke** — dispatches `close_panel` with
  `params: { panel: stroke }`, hiding the Stroke tab.

## Dashed line and the dash pattern

The dash pattern is six numeric values arranged as three consecutive
dash/gap pairs. The effective SVG `stroke-dasharray` is built left to
right from the non-null pairs only: if pairs 2 and 3 are null, only
pair 1 contributes. A zero-length dash produces a dot that is visible
when the cap style is `round` or `square` (and invisible when the cap
is `butt`, which is the source of the dot-dash preset's reliance on
round caps).

`DASHED_CHECKBOX` acts as the master switch:

- When unchecked, `stroke-dasharray` is omitted from the element and
  all six dash/gap inputs are disabled. The values are preserved in
  `panel.dash_1…gap_3` so the previous pattern reappears on
  re-check.
- When checked, the six inputs are enabled and the dash pattern is
  applied.

Pair 1 always has numeric defaults (12 / 12); pairs 2 and 3 default
to null. A blank input in pair 2 or 3 means the pair does not
contribute to the dash array. Pair 1 cannot be blank — clearing
`DASH_1` or `GAP_1` falls back to its default.

The two preset buttons (`EVEN_DASH_PRESET`, `DASH_DOT_PRESET`)
enable dashing and overwrite the dash/gap values in a single click:

| Preset    | pair 1    | pair 2    | pair 3 |
|-----------|-----------|-----------|--------|
| Even dash | 12 / 12   | null      | null   |
| Dash-dot  | 12 / 6    | 0 / 6     | null   |

## Arrowhead shapes

The 15 shapes (identical option list for both `START_ARROWHEAD` and
`END_ARROWHEAD`):

| Shape                | Appearance |
|----------------------|------------|
| `none`               | no arrowhead (default) |
| `simple_arrow`       | filled triangle |
| `open_arrow`         | unfilled triangle |
| `closed_arrow`       | filled triangle with bar at base |
| `stealth_arrow`      | sharp swept-back chevron, filled |
| `barbed_arrow`       | curved swept-back, filled |
| `half_arrow_upper`   | upper half of filled triangle |
| `half_arrow_lower`   | lower half of filled triangle |
| `circle`             | filled disk |
| `open_circle`        | outline circle |
| `square`             | filled square |
| `open_square`        | outline square |
| `diamond`            | filled rhombus |
| `open_diamond`       | outline rhombus |
| `slash`              | perpendicular line across the path |

The renderer flips shapes so they point outward from each end — the
same shape value, selected for start vs end, produces a mirrored
rendering as appropriate.

`SWAP_ARROWHEADS_BUTTON` exchanges both the shape selections and the
scale values between the two ends; it does not toggle
`LINK_SCALES_TOGGLE`.

Arrow alignment (`panel.arrow_align`) governs where the arrowhead
sits relative to the path endpoint:

- `tip_at_end` (default) — arrowhead tip is at the endpoint; body
  extends inward along the path.
- `center_at_end` — arrowhead center is at the endpoint; tip
  extends beyond.

## Stroke profile

`PROFILE_DROPDOWN` selects a variable-width profile applied along
the path's length:

| Profile       | Shape |
|---------------|-------|
| `uniform`     | constant width (default) |
| `taper_both`  | tapers at both ends |
| `taper_start` | tapers at the start end |
| `taper_end`   | tapers at the end end |
| `bulge`       | wider in the middle |
| `pinch`       | narrower in the middle |

`FLIP_PROFILE_BUTTON` toggles `panel.profile_flipped`, mirroring
the profile along the path. Only asymmetric profiles
(`taper_start`, `taper_end`) render differently when flipped.

`RESET_PROFILE_BUTTON` sets `profile = uniform` and
`profile_flipped = false` in a single click.

## Panel state

All panel state mirrors the `state.stroke_*` surface and is
re-initialised from it on panel open (see `init:` in the yaml):

| Panel key                | Source state key                 |
|--------------------------|----------------------------------|
| `panel.weight`           | `state.stroke_width`             |
| `panel.cap`              | `state.stroke_cap`               |
| `panel.join`             | `state.stroke_join`              |
| `panel.miter_limit`      | `state.stroke_miter_limit`       |
| `panel.align_stroke`     | `state.stroke_align`             |
| `panel.dashed`           | `state.stroke_dashed`            |
| `panel.dash_1…gap_3`     | `state.stroke_dash_1…gap_3`      |
| `panel.start_arrowhead`  | `state.stroke_start_arrowhead`   |
| `panel.end_arrowhead`    | `state.stroke_end_arrowhead`     |
| `panel.start_arrowhead_scale` | `state.stroke_start_arrowhead_scale` |
| `panel.end_arrowhead_scale`   | `state.stroke_end_arrowhead_scale`   |
| `panel.link_arrowhead_scale`  | `state.stroke_link_arrowhead_scale`  |
| `panel.arrow_align`      | `state.stroke_arrow_align`       |
| `panel.profile`          | `state.stroke_profile`           |
| `panel.profile_flipped`  | `state.stroke_profile_flipped`   |

Every widget commit fires two effects: a `set_panel_state` for the
mirror key and a `set` for the corresponding `state.stroke_*` key.
This dual-write keeps the panel's immediate visual state and the
document's authoritative state in sync without round-tripping through
a re-init.

## SVG attribute mapping

Attributes are written onto the selected path element:

| Control                 | SVG / CSS |
|-------------------------|-----------|
| Weight                  | `stroke-width` |
| Cap (butt / round / square) | `stroke-linecap` |
| Join (miter / round / bevel) | `stroke-linejoin` |
| Miter limit             | `stroke-miterlimit` (omit when join ≠ miter) |
| Dashed + pattern        | `stroke-dasharray` = the non-null dash/gap pairs, flattened left-to-right; omit when dashed=false |
| Align stroke            | `paint-order` / custom — SVG has no native inside/outside stroke, so inside/outside are approximated via path offset; center = native |
| Start / End arrowhead   | custom marker references (`marker-start`, `marker-end`) resolving to per-shape markers |
| Arrowhead scale         | marker `markerWidth` / `markerHeight` scaled against stroke weight |
| Arrow align             | determines whether the marker reference uses its `tip` or `center` alignment variant |
| Profile                 | custom attribute (`jas:stroke-profile`); applied at render time to vary stroke width along the path |

**Identity-value rule.** When an attribute equals its default
(weight = 1, miter limit = 10, `none` arrowhead, `uniform` profile,
etc.), the attribute is **omitted** from the output rather than
written, so defaults appear as absence.

## Keyboard shortcuts

Shortcuts for Stroke panel actions are defined in
`workspace/shortcuts.yaml` rather than here.

## Panel-to-selection wiring status

The panel binds directly to the flat `state.stroke_*` surface via
the dual-write pattern above: every commit updates both the panel
mirror and the `state.*` key, and on each subsequent panel open the
mirrors are re-initialised from `state.*`. This means Stroke panel
writes propagate through each app's `apply_stroke_panel_to_selection`
pipeline (same shape as Character's `apply_character_panel_to_selection`).

Per-app entry points (see the corresponding files for details —
the names and locations mirror the Character panel wiring):

- **Rust** (`jas_dioxus`): `apply_stroke_panel_to_selection` in
  `src/workspace/app_state.rs`; widget dispatch via the generic
  `render_*` helpers in `src/interpreter/renderer.rs` keyed on the
  enclosing `panel_kind`.
- **Swift** (`JasSwift`): `applyStrokePanelToSelection` in
  `Sources/Interpreter/Effects.swift`, subscribed through the
  notify-panel-state-changed dispatcher.
- **OCaml** (`jas_ocaml`): `subscribe_stroke_panel` in
  `lib/interpreter/effects.ml`.
- **Python** (`jas`): the stroke-panel subscription in
  `jas/panels/`.

Open follow-ups:

- Inside / outside stroke alignment on closed paths requires a
  geometric offset at render time; canvases currently approximate it
  with center alignment.
- Variable-width profile rendering (`taper_*`, `bulge`, `pinch`) is
  data-model only for some canvases; the full width-varying renderer
  is a separate task.
- The 15 arrowhead shapes exist as marker references; the full
  per-shape SVG marker set needs to land before every shape renders
  on every canvas.
