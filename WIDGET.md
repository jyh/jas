# Character

The Character Panel allows setting properties of text in the selection. An example is shown in examples/character.png.

- The FONT_DROPDOWN contains a list of available fonts, with a checkmark next to the current font.
- The STYLE_DROPDOWN allows selecting from the available style of the font (e.g. italic, bold, etc)
- The FONT_SIZE_DROPDOWN gives a selection of font sizes from 6pt to 64pt, and allows direct input of a point size
- The LEADING_DROPDOWN is like font size, but sets the leading of the text
- KERNING affects the spacing between characters
- TRACKING is similar to KERNING
- VERTICAL_SCALE stretches the vertical size of the text
- HORIZONTAL_SCALE stretches the horizontal size
- BASELINE_SHIFT allows shifting the baseline
- CHARACTER_ROTATION applies a rotation to each character in the text
- ALL_CAPS produces all capitals, even if the text is written in lowercase
- SMALL_CAPS produces small captials for text written in lowercase, and regular capitals for character writeen in uppercase
- SUPERSCRIPT places the selected text n superscript position
- SUBSCRIPT does the same for subscript position
- UNDERLINE underlines the selected text
- STRIKETHROUGH applies strikethrough to the text

Note that these operations are performed on the selected text, which may be a tspan within a text element.

Here is the panel layout in bootstrap style.

```yaml
panel:
- .row: FONT_DROPDOWN
- .row: STYLE_DROPDOWN
- .row:
  - .col-2: font size icon
  - .col-4: FONT_SIZE_DROPDOWN
  - .col-2: leading icon
  - .col-4: LEADING_DROPDOWN
- .row:
  - .col-2: kerning icon
  - .col-4: KERNING_DROPDOWN
  - .col-2: tracking icon
  - .col-4: TRACKING_DROPDOWN
- .row:
  - .col-2: vertical scale icon
  - .col-4: VERTICAL_SCALE_DROPDOWN
  - .col-2: horizontal scale icon
  - .col-4: HORIZONTAL SCALE DROPDOWN
- .row:
  - .col-2: baseline shift icon
  - .col-4: BASELINE_SHIFT_DROPDOWN
  - .col-2: character rotaton icon
  - .col-4: CHARACTER_ROTATION_DROPDOWN
- .row:
  - .col-2: ALL_CAPS_BUTTON
  - .col-2: SMALL_CAPS_BUTTON
  - .col-2: SUPERSCRIPT_BUTTON
  - .col-2: SUBSCRIPT_BUTTON
  - .col-2: UNDERLINE_BUTTON
  - .col-2: STRIKETHROUGH_BUTTON
```

The menu has the following entries.

- Show Snap to Glyph Options (checkmark if active)
- ----
- Show Font Height Options (checkmark if active)
- ----
- Standard Vertical Roman Alignment (checkmark if active)
- ----
- Touch Type Tool  (checkmark if active)
- Enable in-menu font previews (checkmark if active)
- ----
- All Caps  (checkmark if active)
- Small Caps  (checkmark if active)
- Superscript  (checkmark if active)
- Subscript  (checkmark if active)
- ----
- Fractional Widths  (checkmark if active)
- ----
- No Break  (checkmark if active)
- ----
- Reset Panel

Please read and understand these requirements. Analyze them for inconsistencies
and completeness. Make suggestions for improvements, ranking them in priority
from high to low, and giving each a number. What are the benefits? What are the
downsides? Be ready for a deep dive into any of the suggestions.
