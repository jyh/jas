# Artboards

The Artboards Panel sets properties of artboards. Every document has a set of
artboards, which are areas that are intended for printing. When the document is
printed, the contents is clipped to the artboards, and one artboard is printed
per page. We have not implemented printing yet, but at this point we want to add
support for artboards. In the default layout, the Artboard Panel is a sibling of
the Layers Panel.

Artboards are resizable with an Artboard Tool that we will design
later. Artboards may overlap.

When a new document is created, by default it starts with a single artboard of
size 612pt * 792pt.

An artboard displays on the canvas as a white area. The canvas background is
gray, determined by the theme. An example is shown in
examples/artboard-canvas.md.

The Artboard Panel contains a list of rows, each row with the following
elements.

- ARTBOARD_NUMBER (artboards are assigned unique numbers starting with 1)
- ARTBOARD_NAME
- ARTBOARD_DIALOG_BUTTON (brings up the Artboard Dialogue Box, an example is
  shown in examples/artboard-dialog.png)

```yaml panel:
- .row:
  - .col-1: ARTBOARD_NUMBER
  - .col-10: ARTBOARD_NAME
  - .col-1: ARTBOARD_DIALOG_BUTTON ```

The panel menu has the following entries.

- Roman Hanging Punctuation (w/checkbox)
- ----
- Justification... (brings up the Justification Dialog box shown in
  examples/justification.png)
- Hyphenation... (brings up the Hyphenation Dialog box shown in
  examples/hyphenation.png)
- ----
- Reset Panel (resets panel element back to their defaults, updating the
  selection)

THIS IS WORK IN PROGRESS
