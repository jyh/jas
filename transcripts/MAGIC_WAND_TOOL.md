# Magic Wand

The Magic Wand Tool selects elements that share visual properties
with a clicked seed element — fill color, stroke color, stroke
weight, opacity, and blending mode — within user-configurable
tolerances. The Magic Wand Panel is where those criteria live.

**Shortcut:** `Y`

**Tool icon:** A wand at ~45° with a sparkle / star at the tip.
Authored inline as SVG path data in each app's icons module
(matches the Pencil / Paintbrush / Blob Brush convention). The
PNG reference `examples/magic-wand.png` is a visual baseline
only — not loaded at runtime.

**Toolbar slot:** Fourth alternate in the arrow slot, alongside
Selection, Partial Selection, and Interior Selection. Long-press
the arrow slot exposes all four.

## Gestures

The wand operates on a single seed: the element under the click.
There is no drag, no marquee.

- **Plain click on element:** the clicked element becomes the
  seed. Selection is replaced with `{seed} ∪ {every other
  qualifying element in the document that matches the seed under
  the enabled criteria}`. The seed is always included regardless
  of whether it would otherwise pass its own filter (e.g.
  unfilled element + Fill Color criterion at tolerance 0).
- **Shift+click on element:** compute the wand result for the
  clicked element, *union* it with the existing selection.
- **Alt+click on element:** compute the wand result for the
  clicked element, *subtract* it from the existing selection.
- **Click on empty canvas:** clear selection (matches Selection
  tool's plain-click behavior).

When clicking on a Group or Layer, the seed is the **innermost
clicked element** (the leaf-most descendant under the cursor),
not the container. Containers don't have own fill / stroke /
opacity / blending mode — they're not viable seeds.

## Predicate

For an enabled criterion, a candidate matches iff its value is
within tolerance of the seed's value (or, for blending mode,
exactly equal). When **multiple criteria are enabled**, a
candidate must match **all** of them (AND, intersection).
Disabled criteria are skipped — they do not act as a wildcard.

If **all criteria are disabled**, the wand is a no-op: a click on
an element acts like Selection tool's plain click on that
element (replace selection with `{seed}`); Shift / Alt similarly
fall through to Selection-tool semantics.

### Eligibility filter

The wand walks the entire document tree and considers every leaf
element as a candidate, with these elements **filtered out**:

| Element kind                 | Eligible? | Notes                                   |
|------------------------------|-----------|-----------------------------------------|
| Locked element               | No        | `locked = true` filtered out            |
| Hidden (`visibility = invisible`) | No   | Filtered out                            |
| Outline-mode element         | Yes       | Color match uses the model fill, not the rendered outline color |
| Path / Rect / Circle / Ellipse / Polygon / Polyline / Line | Yes | The five criteria all apply             |
| Text / TextPath              | Yes       | Same five criteria                       |
| CompoundShape (live element) | Yes       | Has its own fill/stroke/opacity/blend  |
| Group / Layer (containers)   | No        | Recurse into children; the container itself is not a candidate |
| Mask-subtree element         | No        | These shape masks, not painted output  |
| CompoundShape operand        | No        | Operands aren't independently selectable |
| Artboard                     | No        | Not an element                           |

## Criteria

Each row in the Magic Wand Panel toggles one criterion and (when
applicable) configures its tolerance.

### Fill Color

If `FILL_COLOR_CHECKBOX` is active, a candidate matches iff its
fill color is within `FILL_TOLERANCE` of the seed's fill color,
measured as Euclidean distance in 0–255 sRGB space:

```text
distance = √((R₁−R₂)² + (G₁−G₂)² + (B₁−B₂)²)
```

A candidate matches iff `distance ≤ FILL_TOLERANCE`. No gamma
correction or perceptual transform.

Tolerance: integer 0–255, default **32**.

### Stroke Color

`STROKE_COLOR_CHECKBOX` + `STROKE_TOLERANCE` are identical to
Fill Color, applied to the stroke side. Same Euclidean / 0–255
formula. Default tolerance **32**.

### Stroke Weight

If `STROKE_WEIGHT_CHECKBOX` is active, a candidate matches iff
`|candidate.stroke_width − seed.stroke_width| ≤
STROKE_WEIGHT_TOLERANCE`. Tolerance: float, in pt, default
**5.0**.

### Opacity

If `OPACITY_CHECKBOX` is active, a candidate matches iff
`|candidate.opacity − seed.opacity| × 100 ≤ OPACITY_TOLERANCE`.
The document model stores opacity in `[0.0, 1.0]`; the predicate
multiplies by 100 so the user-facing tolerance is in percentage
points. Tolerance: integer 0–100, default **5**.

### Blending Mode

If `BLENDING_MODE_CHECKBOX` is active, a candidate matches iff
its `blend_mode` enum value is **exactly equal** to the seed's.
There is no tolerance — blend mode is categorical. The panel
row is checkbox-only, no numeric input.

## Color edge cases

The color criteria (Fill Color, Stroke Color) compare a 3-class
state per element:

| Both seed and candidate are: | Match rule                                |
|------------------------------|-------------------------------------------|
| Solid + solid                | Euclidean distance ≤ tolerance (above)    |
| None + None                  | Match (regardless of tolerance)           |
| Gradient + anything          | Never match under this criterion          |
| Pattern + anything           | Never match under this criterion          |
| Solid + None (either order)  | No match                                  |

Stroke Weight has the same None-handling: when the seed has no
stroke, the criterion matches **only candidates that also have
no stroke**.

Opacity and Blending Mode never have this problem — every
element has those.

## Magic Wand Panel

The Panel is summoned by:

- Double-clicking the Magic Wand icon in the toolbar (the
  cross-tool dblclick convention introduced alongside Paintbrush).
  The tool yaml declares `tool_options_panel: magic_wand` — a
  panel-equivalent of the existing `tool_options_dialog` field.
- Standard panel-summoning paths (panels menu, dock).

The Panel persists across tool changes; closing it does not
reset its state.

### Layout

```yaml
panel:
- .row:
  - .col-5: FILL_COLOR_CHECKBOX
  - .col-7: ["Tolerance:", FILL_TOLERANCE]
- .row:
  - .col-5: STROKE_COLOR_CHECKBOX
  - .col-7: ["Tolerance:", STROKE_TOLERANCE]
- .row:
  - .col-5: STROKE_WEIGHT_CHECKBOX
  - .col-7: ["Tolerance:", STROKE_WEIGHT_TOLERANCE (pt)]
- .row.spacer
- .row:
  - .col-5: OPACITY_CHECKBOX
  - .col-7: ["Tolerance:", OPACITY_TOLERANCE (%)]
- .row:
  - .col-5: BLENDING_MODE_CHECKBOX
```

The spacer row separates the *appearance* group (color + weight)
from the *compositing* group (opacity + blend mode), matching the
visual gap in the reference design.

### Panel chrome

The Panel uses the shared panel-frame chrome (collapse arrow,
close button, hamburger menu). The hamburger menu has one
Magic-Wand-specific item:

- **Reset** — writes the declared defaults to every
  `state.magic_wand_*` key (see below).

Other menu items (Show, Close Panel, etc.) come from the panel
framework and are not Magic-Wand-specific.

## State persistence

Option values live in `state.magic_wand_*`, per-document:

| State key                                  | Type        | Default |
|--------------------------------------------|-------------|---------|
| `state.magic_wand_fill_color`              | bool        | `true`  |
| `state.magic_wand_fill_tolerance`          | int 0–255   | `32`    |
| `state.magic_wand_stroke_color`            | bool        | `true`  |
| `state.magic_wand_stroke_tolerance`        | int 0–255   | `32`    |
| `state.magic_wand_stroke_weight`           | bool        | `true`  |
| `state.magic_wand_stroke_weight_tolerance` | float (pt)  | `5.0`   |
| `state.magic_wand_opacity`                 | bool        | `true`  |
| `state.magic_wand_opacity_tolerance`       | int 0–100   | `5`     |
| `state.magic_wand_blending_mode`           | bool        | `false` |

The four "obvious" criteria are on by default; Blending Mode is
off. The state keys' names match the field names in the panel
layout one-for-one (with the boolean's name = the criterion +
the tolerance's name = `<criterion>_tolerance`).

## Cross-app artifacts

- `workspace/panels/magic_wand.yaml` — panel layout + state-key
  bindings + Reset menu item.
- `workspace/tools/magic_wand.yaml` — tool spec (id, cursor, the
  five-criterion handler list, `tool_options_panel: magic_wand`).
- `workspace/state.yaml` — declares the nine `magic_wand_*` keys
  and their defaults.
- A new `tool_options_panel` field on tool yaml (parallel to
  `tool_options_dialog`); native apps' toolbar dblclick handlers
  dispatch to "show this panel" instead of "open this dialog"
  when the field is present.

A new `doc.magic_wand.apply` effect runs the predicate on
mousedown:

- **Inputs:** the seed element path (from a hit-test on the
  click coordinate), and the modifier (`replace` / `add` /
  `subtract`).
- **Behavior:** walks the document, applies the eligibility
  filter and the AND-of-enabled-criteria predicate against the
  seed, then mutates the selection per the modifier.

The predicate function lives in a shared module:
`algorithms/magic_wand` (`magic_wand_match` taking a seed
element + a candidate element + the nine state keys → bool).
Cross-language parity is mechanical; no new geometry primitives
are needed.

## Phase 1 / Phase 2 split

### Phase 1 (this spec)
- Five criteria with the predicate semantics above.
- Click / Shift+click / Alt+click gestures.
- Panel + dblclick wiring + state persistence.
- Per-app implementation in Rust → Swift → OCaml → Python order.

### Phase 2 (deferred)
- Gradient similarity (when two gradients should be considered
  "the same" — first-stop match? interpolated-midpoint match?).
- Pattern similarity (same questions).
- Perceptual color space (Lab / OKLab) opt-in.
- "Match by current selection" mode (multi-element seed) — if
  user feedback asks for it.

## Related tools

- **Selection tool** — wand uses the same eligibility filter
  (locked / hidden / mask) so muscle memory transfers.
- **Paintbrush / Blob Brush** — share the dblclick-on-icon
  pattern. Magic Wand is the first tool to use the panel
  destination instead of a dialog.
- **`Select > Same > Fill Color`** menu items — semantically
  similar to wand-with-only-fill-color-on, but the wand is
  multi-criterion and re-runnable from a click.
