# Paragraph

The Paragraph Panel sets properties of paragraphs, longer space of text that may include wrapping and indentation. In the default layout, the Paragraph Panel is a sibling of the Character Panel.

- ALIGN_LEFT aligns each line to the left boundary, with a ragged right.
- ALIGN_CENTER centers each line, the left and right are ragged.
- ALIGN_RIGHT aligns each line to the right margin, leaving the left ragged.
- The JUSTIFY operations justify to both margins.
  - JUSTIFY_LEFT justifies the last line left, leaving the right ragged.
  - JUSTIFY_RIGHT justifies the last line right, leaving the left ragged.
  - JUSTIFY_CENTER justifies the last line in the center.
  - JUSTIFY_ALL forces justification on all lines
- BULLETS_DROPDOWN lists a set of bullet list styles. Each paragraph starts with a bullet. We can include normal bullets, dashes, checkmarks, open bullets, square, open squares.
- NUMBERED_LIST_DROPDOWN gives a set of numbered list styles. Each paragraph starts with a number. Numbered lists can be enumerated by numbers, letters, roman numerals (both capitals and lower case), and other styles.
- LEFT_INDENT allows specifying an identation for all the lines in a paragraph.
- RIGHT_INDENT does the same, but indents from the right margin.
- FIRST_LINE_INDENT_VALUE specifies additional indentation for the first line of each paragraph.
- SPACE_BEFORE_VALUE indicates additional vertical spacing for every paragraph but the first one.
- SPACE_AFTER_VALUE indicates additional veritcal spacing between paragraphs.
- HYPHENATE, when checked, specifies that line breaking is allowed to use hyphenation.

Here is the layout in bootstrap style format, shown in examples/paragraph.png.

```yaml
panel:
- .row: ALIGN_LEFT ALIGN_CENTER ALIGN_RIGHT JUSTIFY_LEFT JUSTIFY_CENTER JUSTIFY_RIGHT JUSTIFY_ALL
- .row: BULLETS_DROPDOWN NUMBERED_LIST_DROPDOWN
- .row:
  - .col-1: left indent icon
  - .col-5: LEFT_INDENT_VALUE
  - .col-1: right indent icon
  - .col-5: RIGHT_INDENT_VALUE
- .row:
  - .col-1: first line indent icon
  - .col-5: FIRST_LINE_INDENT_VALUE
- .row:
  - .col-1: space before icon
  - .col-5: SPACE_BEFORE_VALUE
  - .col-1: space after icon
  - .col-5: SPACE_AFTER_VALUE
- .row:
  - .col-3: HYPHENATE_CHECKBOX
```

The panel menu has the following entries.

- Hanging Punctuation (w/checkbox)
- ----
- Justification... (brings up the Justification Dialog box shown in examples/justification.png)
- Hyphenation... (brings up the Hyphenation Dialog box shown in examples/hyphenation.png)
- ----
- Reset Panel (resets panel element back to their defaults, updating the selection)

Hanging punctuation (often called optical margin alignment) is a typographic
technique where punctuation marks at the beginning or end of a line are pushed
slightly into the margin.

The goal isn't to be messy; it's actually to create the illusion of a perfectly
straight edge.

Common Characters That "Hang",
- Quotation marks: These are the most common culprits.
- Hyphens and Dashes: Used at the end of justified lines.
- Periods and Commas: Often pushed slightly out to keep the "wall" of text solid.
- Bullet points: Pushing the bullet into the margin so the first letters of the list items align vertically.

With hanging punctuation, These characters sit in the "gutter." The heavy vertical strokes of the letters (like H, L, or T) form a crisp, unbroken line.

With standard punctuation, all characters fit within the margins.
