# Align

The Alignment Panel allows the elements on the selection to be aligned in a few different ways.

Alignment:
- The ALIGN_LEFT_BUTTON finds the leftmost bounding box of all the elements in the selection, and moves all elements horizontally to have the same left position
- The ALIGN_HORIZONTAL_BUTTON finds the mid-point of all the elements in the selection, and moves all elements horizontally to have the same midpoint
- The ALIGN_RIGHT_BUTTON finds the rightmost bounding box of all the elements in the selection, and moves all elements horizontally to have the same right position
- ALIGN_TOP_BUTTON, ALIGN_VERTICAL_BUTTON, ALIGN_BOTTOM_BUTTON do the same, but in the vertical dimension

Distribute tries to ensure that the _spacing_ of elements is uniform.
- The DISTRIBUTE_LEFT_BUTTON moves the elements in the selection horizontally so that the left coordinates of their bounding boxes are evenly spaced
- DISTRIBUTE_HORIZONTAL_BUTTON does the same, with the midpoints
- DISTRIBUTE_RIGHT_BUTTON does the same, with the right coordinates
- DISTRIBUTE_TOP_BUTTON, DISTRIBUTE_VERTICAL_BUTTON, and DISTRIBUTE_BOTTOM_BUTTON do the same, but moving element vertically to ensure an even vertical distribution

The spacing tools look at the spacing between elements and tries to ensure even spacing.
- DISTRIBUTE_VERTICAL_SPACING_BUTTON moves elements vertically to ensure that the spacing between the elements is the same
- DISTRIBUTE_HORIZONTAL_SPACING_BUTTON moves elements horizontally to ensure that the spacing between the elements is the same

Here is the layout described in bootstrap form.

```yaml
panel:
- .row: "Align Objects:"
- .row:
  - .col-2: ALIGN_LEFT_BUTTON
  - .col-2: ALIGN_HORIZONTAL_BUTTON
  - .col-2: ALGN_RIGHT_BUTTON
  - .col-2: ALIGN_TOP_BUTTON
  - .col-2: ALIGN_VERTICAL_BUTTON
  - .col-2: ALIGN_BOTTOM_BUTTON
- .row: "Distribute Objects:"
- .row:
  - .col-2: DISTRIBUTE_LEFT_BUTTON
  - .col-2: DISTRIBUTE_HORIZONTAL_BUTTON
  - .col-2: DISTRIBUTE_RIGHT_BUTTON
  - .col-2: DISTRIBUTE_TOP_BUTTON
  - .col-2: DISTRIBUTE_VERTICAL_BUTTON
  - .col-2: DISTRIBUTE_BOTTOM_BUTTON
- .row:
  - .col-6:
    - .row: "Distribute Spacing:"
	- .col-3: DISTRIBUTE_VERTICAL_SPACING_BUTTON
	- .col-3: DISTRIBUTE_HORIZONTAL_SPACING_BUTTON
```

The Alignment panel has the following menu:
- Use Preview Bounds (if this is checked, the preview bounding box is used, which takes into account fill and stroke)
