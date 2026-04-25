# Eyedropper

The Eyedropper tool samples appearance attributes from a clicked source
element and writes them to other elements. The five attribute groups it
samples — Fill, Stroke, Opacity, Character, Paragraph — map to the
existing per-document state surfaces (`state.fill_*`, `state.stroke_*`,
`state.character_*`, `state.paragraph_*`) and to the panels that own
them.

**Shortcut:** `I`

**Tool icon:** An eyedropper at ~45°: rubber squeeze cap (with
horizontal grip lines) at the upper right, thin glass tube descending
to a sharp tip at the lower left. Single-color outline matching the
toolbar foreground (matches the Pencil / Paintbrush / Blob Brush /
Magic Wand convention). Authored inline as SVG path data in each
app's icons module. The PNG reference `examples/eyedropper-tool.png`
is a visual baseline only — not loaded at runtime.

**Toolbar slot:** Top-level slot, no alternates in Phase 1.

**Cursor:** Standard eyedropper glyph, hot spot at the tip. The
cursor is the same in both empty-cache and loaded-cache states; the
loaded indicator is rendered as an overlay (see § Overlay).

## Gestures

The eyedropper operates on a single click. There is no drag and no
marquee.

- **Plain click on an eligible element:** writes the source's attrs
  into `state.eyedropper_cache`. If the current selection is
  non-empty, also writes those attrs to every eligible target in the
  selection.
- **Plain click on empty document space:** no-op.
- **Alt+click on an eligible element:** writes
  `state.eyedropper_cache` to that element. If the cache is null,
  falls through to plain-click semantics (sample). Selection is
  unchanged.
- **Alt+click on empty document space:** no-op.
- **Escape:** clears `state.eyedropper_cache`.

When clicking on a Group or Layer container, the source resolves to
the **innermost element under the cursor** (the leaf-most descendant).
Containers themselves are never sampled — they have no own fill,
stroke, opacity, or blend.

Shift has no effect in Phase 1. Phase 2 may reuse Shift for pixel-RGB
sampling (see § Phase 1 / Phase 2 split).

The cache lives in `state.eyedropper_cache`, persists with the
document, and survives tool switches; loading a document with a
non-null cache restores the loaded-dropper state. The cache is
cleared only by Escape (or by a fresh sample replacing it).

## Eligibility

Source-side eligibility (what can be clicked as a source) and
target-side eligibility (what can receive the apply) are not the same.

### Source eligibility — what can be sampled

| Element kind | Eligible? | Notes |
|---|---|---|
| Locked element | Yes | Visible; sampling doesn't mutate it |
| Hidden (`visibility = invisible`) | No | Not hit-testable |
| Outline-mode element | Yes | Samples the model attrs (fill / stroke / etc.), not the rendered outline color |
| Path / Rect / Circle / Ellipse / Polygon / Polyline / Line | Yes | Fill + Stroke + Opacity groups apply |
| Text / TextPath | Yes | All five attribute groups apply |
| CompoundShape (live element) | Yes | Compound's own fill / stroke / opacity / blend |
| Group / Layer (containers) | No (descend) | Source resolves to the innermost descendant under the cursor |
| Mask-subtree element | No | Defines mask shape, not painted output |
| CompoundShape operand | No | Operand attrs don't surface through the compound |
| Placed `<image>` | Yes | Phase 1 samples element-level attrs only (`opacity`, `blend_mode`, plus any `fill` / `stroke` the image element happens to carry); pixel-RGB at the click point is Phase 2a |
| Artboard | No | Not a paintable element |

### Target eligibility — what receives the apply

The target set is "every element in the selection" (plain click) or
"the clicked element" (Alt+click). When the resolved target is a
container, the apply walks into the container and applies to every
eligible leaf descendant.

| Element kind | Eligible? | Notes |
|---|---|---|
| Locked element | No | Skip silently — can't mutate |
| Hidden element | Yes | Attrs persist; rendering catches up when unhidden |
| Outline-mode element | Yes | Same as above |
| Path / Rect / Circle / Ellipse / Polygon / Polyline / Line | Yes | |
| Text / TextPath | Yes | Character / Paragraph groups apply only when target is a text element |
| CompoundShape (live element) | Yes | Writes the compound's own attrs |
| Group / Layer (containers) in the selection | No (recurse) | Walk into the container; apply to each eligible leaf descendant |
| Mask-subtree element | No | Attrs there don't render as paint |
| CompoundShape operand | No | Operand attrs don't surface |
| Placed `<image>` | Yes (limited) | Element-level attrs (opacity, blend mode) apply; Character / Paragraph sub-toggles are no-ops on image elements |
| Artboard | No | Not an element |

The eyedropper inherits Magic Wand's locked / hidden / mask-subtree
filter philosophy with one important asymmetry: locked is YES on the
source side (sampling reads), NO on the target side (applying writes).
Hidden is the reverse — NO on source (can't hit-test), YES on target
(writes persist).

## Attribute groups

The cached appearance is structured into five groups, each gated by a
master toggle plus optional sub-toggles. Master OFF → entire group
skipped. Master ON + sub OFF → that sub-attribute skipped. Both must
be ON for an attribute to be copied.

When the source lacks an attribute (e.g. a Path being sampled has no
character data) or the target can't receive it (e.g. applying
character attrs to a Path), the corresponding sub-toggles are no-ops
at apply time. No warning, no error.

### Fill

Single toggle. When `state.eyedropper_fill` is on, copies the source's
`fill` attribute (color, none, gradient, or pattern — whatever the
source has).

### Stroke

Master toggle `state.eyedropper_stroke` plus eight sub-toggles. The
sub-toggles cover the surface defined in `STROKE.md`:

| Sub-toggle state key | Covers |
|---|---|
| `state.eyedropper_stroke_color` | `stroke` (color, none, gradient, or pattern) |
| `state.eyedropper_stroke_weight` | `stroke-width` |
| `state.eyedropper_stroke_cap_join` | `stroke-linecap`, `stroke-linejoin`, `stroke-miterlimit` |
| `state.eyedropper_stroke_align` | `stroke-align` |
| `state.eyedropper_stroke_dash` | `stroke-dashed` + the six dash/gap values |
| `state.eyedropper_stroke_arrowheads` | start/end shape, scales, scale-link, arrow-align |
| `state.eyedropper_stroke_profile` | profile + flipped |
| `state.eyedropper_stroke_brush` | `jas:stroke-brush` |

### Opacity

Master toggle `state.eyedropper_opacity` plus two sub-toggles:

| Sub-toggle state key | Covers |
|---|---|
| `state.eyedropper_opacity_alpha` | `element.opacity` |
| `state.eyedropper_opacity_blend` | `element.mode` (blend mode) |

`element.mask` is never copied — masks are subtree references and
don't transfer cleanly across elements.

### Character

Master toggle `state.eyedropper_character` plus six sub-toggles for
the most commonly customized attrs:

| Sub-toggle state key | Covers (see `CHARACTER.md`) |
|---|---|
| `state.eyedropper_character_font` | font family + style (font-weight + font-style) |
| `state.eyedropper_character_size` | font size |
| `state.eyedropper_character_leading` | leading |
| `state.eyedropper_character_kerning` | kerning |
| `state.eyedropper_character_tracking` | tracking |
| `state.eyedropper_character_color` | character color |

Other character attrs (vertical scale, horizontal scale, baseline
shift, language, etc.) are not individually toggleable in Phase 1 —
they ride with the master. Phase 2 may add finer-grained sub-toggles
if user feedback asks for them.

### Paragraph

Master toggle `state.eyedropper_paragraph` plus four sub-toggles:

| Sub-toggle state key | Covers (see `PARAGRAPH.md`) |
|---|---|
| `state.eyedropper_paragraph_align` | paragraph alignment |
| `state.eyedropper_paragraph_indent` | left / right / first-line indents |
| `state.eyedropper_paragraph_space` | space before / after |
| `state.eyedropper_paragraph_hyphenate` | hyphenate flag |

Other paragraph attrs ride with the master in Phase 1.

## Tool Options dialog

Double-clicking the Eyedropper icon in the toolbar opens the
Eyedropper Tool Options dialog. The dialog is declared in
`workspace/dialogs/eyedropper_tool_options.yaml` (id:
`eyedropper_tool_options`) and wired via the `tool_options_dialog`
field on the tool yaml — the same convention introduced by Paintbrush
and Blob Brush.

### Layout

Sub-toggles render indented under their master and are visibly
disabled (greyed) when the master is OFF; their values persist across
master toggling, matching the dash/gap input pattern in `STROKE.md`
§ Dashed line.

```yaml
dialog:
- "Sample and apply:"
- FILL_CHECKBOX
- STROKE_CHECKBOX
- .indent:
  - STROKE_COLOR_CHECKBOX
  - STROKE_WEIGHT_CHECKBOX
  - STROKE_CAP_JOIN_CHECKBOX
  - STROKE_ALIGN_CHECKBOX
  - STROKE_DASH_CHECKBOX
  - STROKE_ARROWHEADS_CHECKBOX
  - STROKE_PROFILE_CHECKBOX
  - STROKE_BRUSH_CHECKBOX
- OPACITY_CHECKBOX
- .indent:
  - OPACITY_ALPHA_CHECKBOX
  - OPACITY_BLEND_CHECKBOX
- CHARACTER_CHECKBOX
- .indent:
  - CHAR_FONT_CHECKBOX
  - CHAR_SIZE_CHECKBOX
  - CHAR_LEADING_CHECKBOX
  - CHAR_KERNING_CHECKBOX
  - CHAR_TRACKING_CHECKBOX
  - CHAR_COLOR_CHECKBOX
- PARAGRAPH_CHECKBOX
- .indent:
  - PARA_ALIGN_CHECKBOX
  - PARA_INDENT_CHECKBOX
  - PARA_SPACE_CHECKBOX
  - PARA_HYPHENATE_CHECKBOX
- .row.spacer
- .row:
  - RESET_BUTTON
  - CANCEL_BUTTON
  - OK_BUTTON
```

### Behavior

The dialog opens populated with current state: each
`state.eyedropper_*` key reads into the dialog's working copy via the
standard `init:` block. Edits modify the working copy only.

Buttons:

- **Reset** — writes the declared defaults (all-true) to the dialog's
  working copy. Affects dialog state only; nothing commits until OK.
- **Cancel** — discards the working copy; closes without writing.
- **OK** — writes every working-copy value to the corresponding
  `state.eyedropper_*` key.

`state.eyedropper_cache` is never touched by the dialog — the dialog
edits the *toggles*, not the cache.

## State persistence

Toggle values live in `state.eyedropper_*`, per-document:

| State key | Type | Default |
|---|---|---|
| `state.eyedropper_fill` | bool | `true` |
| `state.eyedropper_stroke` | bool | `true` |
| `state.eyedropper_stroke_color` | bool | `true` |
| `state.eyedropper_stroke_weight` | bool | `true` |
| `state.eyedropper_stroke_cap_join` | bool | `true` |
| `state.eyedropper_stroke_align` | bool | `true` |
| `state.eyedropper_stroke_dash` | bool | `true` |
| `state.eyedropper_stroke_arrowheads` | bool | `true` |
| `state.eyedropper_stroke_profile` | bool | `true` |
| `state.eyedropper_stroke_brush` | bool | `true` |
| `state.eyedropper_opacity` | bool | `true` |
| `state.eyedropper_opacity_alpha` | bool | `true` |
| `state.eyedropper_opacity_blend` | bool | `true` |
| `state.eyedropper_character` | bool | `true` |
| `state.eyedropper_character_font` | bool | `true` |
| `state.eyedropper_character_size` | bool | `true` |
| `state.eyedropper_character_leading` | bool | `true` |
| `state.eyedropper_character_kerning` | bool | `true` |
| `state.eyedropper_character_tracking` | bool | `true` |
| `state.eyedropper_character_color` | bool | `true` |
| `state.eyedropper_paragraph` | bool | `true` |
| `state.eyedropper_paragraph_align` | bool | `true` |
| `state.eyedropper_paragraph_indent` | bool | `true` |
| `state.eyedropper_paragraph_space` | bool | `true` |
| `state.eyedropper_paragraph_hyphenate` | bool | `true` |
| `state.eyedropper_cache` | Appearance? | `null` |

`state.eyedropper_cache` is the most recently sampled appearance,
nullable. It serializes with the document so a non-null cache survives
save/load.

## Overlay

A single render type drives the in-tool visual feedback: a small color
chip following the cursor while `state.eyedropper_cache != null`.

- **Render type:** `cursor_color_chip` (new; joins the eight existing
  render types in the YAML tool overlay system).
- **Geometry:** 12×12 px filled rectangle at offset (+12, +12) from
  the cursor position.
- **Fill:** the cached fill color. When `cache.fill` is `none`,
  gradient, or pattern, the chip renders the standard none-glyph
  instead of a solid color.
- **Border:** 1 px outline drawn from the cached stroke color when
  `cache.stroke` is solid; otherwise a fixed neutral outline so the
  chip stays visible against any canvas backdrop.
- **Visibility:** rendered only while the eyedropper is the active
  tool and `state.eyedropper_cache != null`.

There is no hover-bbox preview in Phase 1. Click-then-canvas-update is
the feedback for what the apply did. Phase 2 may add a candidate-tint
preview if user feedback asks for it.

## Cross-app artifacts

- `workspace/tools/eyedropper.yaml` — tool spec: id, cursor, gesture
  handler list, `tool_options_dialog: eyedropper_tool_options`.
- `workspace/dialogs/eyedropper_tool_options.yaml` — dialog layout,
  state-key bindings, Reset wiring.
- `workspace/state.yaml` — declares all `state.eyedropper_*` toggle
  keys with defaults, plus `state.eyedropper_cache`.
- New `cursor_color_chip` overlay render type added to each app's
  overlay dispatch.
- New effect handlers wired into the YAML runtime:
  - `doc.eyedropper.sample` — extracts the source element's attrs
    into the cache; if selection ≠ ∅, also writes those attrs to
    every eligible target in the selection.
  - `doc.eyedropper.apply_loaded` — applies `state.eyedropper_cache`
    to the Alt+click target (eligible-target rules from
    § Eligibility).

No shared algorithm module is needed — Magic Wand needed
`algorithms/magic_wand` because of the predicate, but eyedropper's
logic is mechanical reads/writes against an attr list driven by the
dialog yaml. Each app implements `extract_appearance(element,
toggles)` and `apply_appearance(target, appearance, toggles)` using
the same attr-list-to-state-key mapping.

## Phase 1 / Phase 2 split

### Phase 1 (this spec)

- Click + Alt+click + Esc gesture set; cache lives in
  `state.eyedropper_cache`.
- Five attribute groups with sub-toggles, all-on defaults.
- Tool Options dialog wired via `tool_options_dialog`.
- Source / target eligibility tables.
- Static eyedropper cursor + `cursor_color_chip` overlay when loaded.
- Per-app implementation in Rust → Swift → OCaml → Python order.

### Phase 2 (deferred)

- **2a — Canvas-internal pixel readback.** Sample the rendered pixel
  at the cursor's canvas coordinate. Covers gradient-point sampling
  and placed-image pixel sampling. Per-app readback hooks: `wgpu` /
  canvas in jas_dioxus, `CGContext.data` in JasSwift,
  `Cairo.Image_surface.get_data` in jas_ocaml, `QImage.bits()` /
  `constBits()` in jas (Python), `getImageData` in Flask.
- **2b — OS-level off-canvas sampling.** Sample any pixel on screen,
  including outside the app window. Best-effort per platform;
  impossible in Flask (browser sandbox). macOS uses
  `CGWindowListCreateImage` with Screen Recording permission;
  Wayland needs `xdg-desktop-portal`; X11 uses
  `gdk_pixbuf_get_from_window`.
- **2c — Modifier choice for pixel sampling.** Likely Shift (matching
  the well-known idiom) or "automatic when target supports pixel
  sampling." TBD when Phase 2a lands.
- **2d — Hover-bbox preview overlay.** Tint the candidate that would
  receive the apply, rendered while the cursor is loaded.
- **2e — Cached-appearance preview swatch.** A color swatch in the
  Tool Options dialog showing the current `state.eyedropper_cache`.
- **Finer-grained character / paragraph sub-toggles** — vertical
  scale, horizontal scale, baseline shift, language; tab stops, word
  spacing, letter spacing, etc. — added if user feedback asks for
  them.

## Related tools

- **Color panel** (`COLOR.md`) — eyedropper writes through to
  `state.fill_color` / `state.stroke_color` when Fill / Stroke→Color
  toggles are on; the Color panel's dual-write pattern propagates the
  change to selected elements.
- **Stroke panel** (`STROKE.md`) — same dual-write surface for all
  `state.stroke_*` keys; eyedropper writes to them and
  `apply_stroke_panel_to_selection` (per app) carries the values onto
  the canvas.
- **Character / Paragraph panels** (`CHARACTER.md`,
  `PARAGRAPH.md`) — same dual-write pattern; eyedropper participates
  in their state surface.
- **Magic Wand** (`MAGIC_WAND_TOOL.md`) — adjacent hit-test
  eligibility table style; the locked / hidden asymmetry is the main
  difference (eyedropper YES-source on locked; wand NO).
- **Paintbrush** (`PAINTBRUSH_TOOL.md`) and **Blob Brush**
  (`BLOB_BRUSH_TOOL.md`) — co-define the `tool_options_dialog`
  convention; eyedropper is the third tool in this family.
