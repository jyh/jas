# Magic wand

The Magic Wand Panel specifies properties of the Magic Wand, which starts with a selection, and selects additional elements based on whether those elements are similar to the selection in stroke and fill.

- If FILL_COLOR_CHECKBOX is active, elements are selected if they have a similar fill color, tolerance is given by FILL_TOLERANCE. This is RMS distance in RGB.
- STROKE_COLOR is similar to FILL_COLOR.
- STROKE_WEIGHT allows selecting elements if they have similar stroke weight. STROKE_TOLERANCE is in points.
- OPACITY allows selecting elements if they have similar opacity. OPACITY_TOLERANCE is in percent.

Here is the layout in bootstrp-style format.
```yaml
panel:
- .row:
  - .col-5: FILL\_COLOR\_CHECKBOX
  - .col-7: ["Tolerance:", FILL\_TOLERANCE]
- .row:
  - .col-5: STROKE\_COLOR\_CHECKBOX
  - .col-7: ["Tolerance:", STROKE\_TOLERANCE]
- .row:
  - .col-5: STROKE\_WEIGHT\_CHECKBOX
  - .col-7: ["Tolerance:", STROKE\_WEIGHT\_TOLERANCE (pt)]
- .row:
  - .col-5: OPACITY\_CHECKBOX
  - .col-7: ["Tolerance:", OPACITY\_TOLERANCE (%)]
```
