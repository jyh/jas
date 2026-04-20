# Opacity

The Opacity Panel sets opacity properties of the current selection.

- MODE_DROPDOWN selects the mode
- OPACITY_SLIDER allows setting the opacity of the selection, from 0-100%
- OPACITY_PREVIEW shows a preview of the selection
- MASK_PREVIEW shows a preview of masked opacity
- MAKE_MASK_BUTTON makes an opacity mask
- CLIP_BUTTON clips to the mask
- INVERT_MASK_BUTTON inverts the mask

```yaml
panel:
- .row:
  - .col-6: MODE_DROPDOWN
- .row:
  - .col-3: "Opacity:"
  - .col-9: OPACITY_SLIDER
- .row:
  - .col-3: OPACITY_PREVIEW
  - .col-3: MASK_PREVIEW
  - .col-6:
    - .row: MAKE_MASK_BUTTON
    - .row: CLIP_BUTTON
    - .row: INVERT_MASK_BUTTON
```
