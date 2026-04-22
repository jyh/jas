# Opacity

The Opacity Panel sets opacity properties of the current selection. The
displayed tab title resolves through the i18n key `panel_title.opacity`
(English: "Opacity").

- MODE_DROPDOWN selects the mode
- OPACITY_INPUT is a numeric field for the opacity of the selection (0-100%), with direct text entry and arrow-key stepping
- OPACITY_DISCLOSURE is a chevron that opens a popover containing OPACITY_SLIDER
- OPACITY_SLIDER (inside the OPACITY_DISCLOSURE popover) allows setting the opacity by dragging, from 0-100%
- OPACITY_PREVIEW shows a preview of the selection
- MASK_PREVIEW shows a preview of masked opacity
- LINK_INDICATOR is a small icon between OPACITY_PREVIEW and MASK_PREVIEW showing whether the mask is linked to the element's transform; clicking it toggles the link state
- MAKE_MASK_BUTTON makes an opacity mask
- CLIP_CHECKBOX toggles whether the mask clips
- INVERT_MASK_CHECKBOX toggles whether the mask is inverted

```yaml
panel:
- .row:
  - .col-4: MODE_DROPDOWN
  - .col-3: "Opacity:"
  - .col-4: OPACITY_INPUT
  - .col-1: OPACITY_DISCLOSURE
- .row:
  - .col-3: OPACITY_PREVIEW
  - .col-1: LINK_INDICATOR
  - .col-3: MASK_PREVIEW
  - .col-5:
    - .row: MAKE_MASK_BUTTON
    - .row: CLIP_CHECKBOX
    - .row: INVERT_MASK_CHECKBOX
```

## Mode values

All sixteen modes below are required in every implementation. The dropdown
renders groups in the order shown, with a divider between groups. The default
value is `normal`. Display labels are resolved through the i18n layer using
the key `mode.<id>` (for example, `mode.color_burn` resolves to "Color Burn"
in English).

```yaml
MODE_DROPDOWN:
  default: normal
  groups:
    - [normal]
    - [darken, multiply, color_burn]
    - [lighten, screen, color_dodge]
    - [overlay, soft_light, hard_light]
    - [difference, exclusion]
    - [hue, saturation, color, luminosity]
```

## Panel menu

The panel exposes a hamburger menu at the top-right. Items are grouped, with
a divider between groups. Labels are resolved through the i18n layer using
the key `opacity_menu.<id>`.

- `hide_thumbnails` collapses the preview row (`OPACITY_PREVIEW` and
  `MASK_PREVIEW`) to save vertical space.
- `show_options` reveals the `page_isolated_blending` and `page_knockout_group`
  controls inline in the panel body, below the preview row.
- `make_mask` and `release_mask` are alternate entry points for
  `MAKE_MASK_BUTTON` in its "No mask" and "Has mask" states respectively; each
  menu item and the button produce the same result.
- `disable_mask` and `unlink_mask` have no button equivalent in the panel
  body; the menu is the only entry point.
- `disable_mask` toggles all selected masks based on the first selected
  element's disabled state. If the first mask is enabled, the action disables
  all selected masks; if the first is disabled, the action enables all. The
  menu label stays "Disable Opacity Mask" regardless of state.
- `unlink_mask` toggles all selected masks based on the first selected
  element's link state. The menu label flips between "Unlink Opacity Mask"
  and "Link Opacity Mask" to reflect the first element's current state.
- `new_masks_clipping` and `new_masks_inverted` are document preferences that
  set the initial state of the **next** mask created; they do not affect
  existing masks. `new_masks_clipping` defaults to `true`.
- `page_isolated_blending` and `page_knockout_group` apply to the document
  root.
- Items carry a `status` field when they are not yet fully landed.
  `status: open_design` means the semantics are still being designed.
  `status: pending_model` means the semantics are settled but the document
  model does not yet carry the required field.
  `status: pending_renderer` means the semantics are settled and the model
  carries the field, but the renderer does not yet support the required
  compositing. In every case the menu entry should be rendered but disabled
  until the status clears.

```yaml
PANEL_MENU:
  groups:
    - - {id: hide_thumbnails,        kind: toggle}
      - {id: show_options,           kind: toggle}
    - - {id: make_mask,              kind: action, enabled_when: "!selection_has_mask"}
      - {id: release_mask,           kind: action, enabled_when: "selection_has_mask"}
      - {id: disable_mask,           kind: action, enabled_when: "selection_has_mask",  status: pending_model}
      - {id: unlink_mask,            kind: action, enabled_when: "selection_has_mask",  status: pending_model}
    - - {id: new_masks_clipping,     kind: toggle, scope: document, default: true}
      - {id: new_masks_inverted,     kind: toggle, scope: document, default: false}
    - - {id: page_isolated_blending, kind: toggle, scope: document, status: pending_renderer}
      - {id: page_knockout_group,    kind: toggle, scope: document, status: pending_renderer}
```

## States

The panel derives a predicate `selection_has_mask` from the current selection.
A selection "has a mask" when every element in the selection has an opacity
mask attached. Mixed selections (some masked, some not) count as not having a
mask for the purposes of this predicate.

Control states:

| Control                    | No mask           | Has mask                              |
|----------------------------|-------------------|---------------------------------------|
| MODE_DROPDOWN              | enabled           | enabled                               |
| OPACITY_INPUT / DISCLOSURE | enabled           | enabled                               |
| OPACITY_PREVIEW            | shows selection   | shows selection                       |
| MASK_PREVIEW               | empty-mask glyph  | shows mask contents                   |
| LINK_INDICATOR             | hidden            | visible; linked/unlinked icon         |
| MAKE_MASK_BUTTON           | label "Make Mask" | label "Release"                       |
| CLIP_CHECKBOX              | disabled          | enabled, reflects mask state          |
| INVERT_MASK_CHECKBOX       | disabled          | enabled, reflects mask state          |

`MAKE_MASK_BUTTON` keeps its identifier across both states; only the displayed
label and the verb of its action change. Clicking it in the "No mask" state
creates a mask; clicking it in the "Has mask" state releases the mask.

When a mask is first made, `CLIP_CHECKBOX` and `INVERT_MASK_CHECKBOX` are
initialized from the document defaults `new_masks_clipping` and
`new_masks_inverted`.

`MASK_PREVIEW` in the "No mask" state renders a fixed empty-mask glyph (a
circle with a diagonal slash); implementations should not substitute their
own placeholder artwork.

## Document model

The panel reads and writes the following fields. Every element in the
document carries these; defaults apply when the field is unset.

| Field             | Type                      | Default   |
|-------------------|---------------------------|-----------|
| `element.opacity` | number, 0-100             | `100`     |
| `element.mode`    | mode id (see Mode values) | `normal`  |
| `element.mask`    | optional mask subtree     | *unset*   |

When `element.mask` is present it carries its own fields:

| Field                   | Type             | Default                                             |
|-------------------------|------------------|-----------------------------------------------------|
| `mask.subtree`          | element subtree  | required                                            |
| `mask.clip`             | boolean          | copy of document `new_masks_clipping` at creation   |
| `mask.invert`           | boolean          | copy of document `new_masks_inverted` at creation   |
| `mask.disabled`         | boolean          | `false`                                             |
| `mask.linked`           | boolean          | `true`                                              |
| `mask.unlink_transform` | matrix, optional | *unset*                                             |

When `mask.disabled` is `true`, the element composites as if no mask exists;
`mask.clip` and `mask.invert` are preserved unchanged so that re-enabling
restores the prior state. `MASK_PREVIEW` renders the mask contents in a
grayed rendering to indicate the mask is inert.

When `mask.linked` is `true`, the mask's coordinate space is the element's
local coordinate space — mask transforms follow the element. When
`mask.linked` is `false`, the mask's effective transform is
`mask.unlink_transform`, which is captured at unlink time; the mask stays
fixed in document coordinates regardless of subsequent element transforms.
Relinking clears `mask.unlink_transform` and restores inheritance.

`mask.disabled` and `mask.linked` are orthogonal; neither implies the other,
and disabling does not restore linkage.

### Rendering

An opacity mask composites the element body against the mask subtree's
rendered alpha channel. Writing `E(x, y)` for the element's alpha at a
pixel, `M(x, y)` for the mask subtree's rendered alpha, and `B` for the
mask subtree's bounding box:

| `clip` | `invert` | Output alpha at `(x, y)`                                    |
|--------|----------|-------------------------------------------------------------|
| true   | false    | `E * M`                                                     |
| true   | true     | `E * (1 - M)`                                               |
| false  | false    | `E * M` inside `B`, `E` outside `B` (reveal-by-default)     |
| false  | true     | `E * (1 - M)` inside `B`, `E` outside `B`                   |

`clip: true` treats the area outside the mask subtree's rendered region as
fully transparent — the element is clipped to the mask shape. `clip: false`
treats it as fully opaque — the element stays visible outside the mask
subtree's bounding box, and the mask only modulates opacity within `B`.
Both modes are implemented via alpha compositing; a future phase may
promote `M` to mask subtree luminance so that a black-opaque mask reads
as fully transparent (matching the PDF §11 soft-mask convention).

Every group element additionally carries:

| Field                     | Type    | Default |
|---------------------------|---------|---------|
| `group.isolated_blending` | boolean | `false` |
| `group.knockout_group`    | boolean | `false` |

The group flags live on every group so that per-group isolation and knockout
can be added later without a schema migration. The only UI hooks today are
the `page_isolated_blending` and `page_knockout_group` menu items
(`status: pending_renderer`), which, when the renderer is ready, will write
to the document root group.

## Multi-selection

Each control is evaluated independently against the current selection. The
panel is fully editable for mixed selections; any edit applies to every
element in the selection.

| Control              | Uniform selection       | Mixed selection                                    |
|----------------------|-------------------------|----------------------------------------------------|
| MODE_DROPDOWN        | shows the shared mode   | shows blank; picking a value applies to all        |
| OPACITY_INPUT        | shows the shared value  | shows `—`; typing a value applies to all           |
| OPACITY_SLIDER       | thumb at shared value   | thumb at neutral center; dragging applies to all   |
| OPACITY_PREVIEW      | the selected element    | the first selected element                         |
| MASK_PREVIEW         | the shared mask         | empty-mask glyph                                   |
| LINK_INDICATOR       | reflects shared state   | reflects the first element's state                 |
| MAKE_MASK_BUTTON     | Make/Release per States | "Make Mask" (mixed counts as no-mask per States)   |
| CLIP_CHECKBOX        | reflects shared state   | disabled                                           |
| INVERT_MASK_CHECKBOX | reflects shared state   | disabled                                           |

Each control's uniform/mixed evaluation is independent. A selection that is
uniform on opacity but mixed on mode shows the opacity value and a blank
mode — do not collapse these into a single panel-wide "mixed" flag.

## Preview interactions

The document model has an "editing target" — the subtree that drawing tools
operate on. The default editing target is the element's content (its main
subtree). Mask-editing mode switches the target to the mask subtree.

Both previews show a persistent highlight indicating which one is the current
editing target.

Drawing tools route new elements to the editing target via the shared
`Controller.add_element` entry point: in content-mode the element is
appended to the selected layer (the default); in mask-editing mode it is
appended to the masked element's mask subtree instead. When the mask
subtree isn't a container (e.g. a bare shape, created externally), the
add falls back to layer-append so the user's stroke isn't lost.

Primary clicks:

- Click `OPACITY_PREVIEW` → make the element's content the editing target.
  This is the default, so the click matters mainly for exiting mask-editing
  mode.
- Click `MASK_PREVIEW` → make the mask subtree the editing target
  (mask-editing mode). Requires `element.mask` to be present.
- Click `LINK_INDICATOR` → toggle `mask.linked`. Requires `element.mask` to
  be present.

Additional shortcuts on `MASK_PREVIEW`:

| Input                                    | Action                                                         |
|------------------------------------------|----------------------------------------------------------------|
| Option/Alt-click                         | Isolate the mask on the canvas (show only mask contents)       |
| Shift-click                              | Toggle `disable_mask` (keeps mask attached but not rendered)   |
| Drag from `OPACITY_PREVIEW` to this cell | Replace the mask contents with a copy of the element's artwork |

Escape returns to content-editing mode and exits mask-isolation if active.
(Keyboard Escape is still pending; currently isolation is exited by
Alt-clicking MASK_PREVIEW again.)

## Deferred additions

- `SELECTION_TYPE_LABEL` — a small caption above the preview row showing the
  element kind of the current selection (for example, "Text", "Path", "Group").
  Mixed-kind selections show "Mixed"; an empty selection hides the label.
  Deferred because it introduces a dependency on a centralized element-type
  label registry that does not yet exist.
