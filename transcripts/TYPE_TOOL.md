# Type tools

Two tools place and edit text: the **Type** tool (point text
and area text) and the **Type on Path** tool (text flowed along
an existing path). Both are permanent-native per
`NATIVE_BOUNDARY.md` §6 — text editing involves IME, font
shaping, text-run segmentation, and caret geometry that don't
fit the YAML effect model.

| Tool          | Shortcut | Commits to                             |
|---------------|----------|----------------------------------------|
| Type          | T        | new `Text` element (point or area)     |
| Type on Path  | —        | new `TextPath` element using a path's d|

Both tools own in-place editing sessions while the text element
they just created (or re-entered) is under the caret.

**Cursor:** I-beam for both; switches to crosshair while
placing the initial rectangle / clicking the target path.

## Type tool

Two creation gestures:

- **Click** — places a **point-text** element at the cursor.
  The text flows freely; line breaks require explicit newlines.
  The element's `text_width` / `text_height` grow with content.
- **Click and drag** — places an **area-text** element inside
  the drag rectangle. The text wraps to the rectangle's width;
  additional lines extend the visible region up to the height.
  Overflow behavior depends on the `tspan` overflow rules;
  see `PARAGRAPH.md` for paragraph-level specifics.

Either gesture immediately opens an editing session with the
caret at the end of the (empty) text. The session owns all key
input until:

- The user clicks outside the element (commits edits, ends session).
- The user presses Escape (commits and ends).
- The user switches to another tool (commits and ends).

## Type on Path tool

Single gesture:

- **Click on a Path / Polygon / any element with a d
  attribute** — converts that element into a `TextPath` with
  empty content, opens an edit session, and types along the
  path. Characters follow the curve at their baseline; the
  path's d is preserved verbatim.

`start_offset` controls where on the path the text begins
(0 = start of d, 1 = end). The default is 0. Dragging the
start-offset handle is handled by the element-level control
points rather than the tool.

## Editing sessions

Both tools delegate to the shared `TextEditSession` (native
code — per-language `text_edit.<ext>`). The session:

- Renders the caret with a blink timer owned by the canvas.
- Routes keyboard input via `capture_keyboard()` returning True.
- Handles IME composition.
- Wraps text to the element's `text_width` when area mode.
- Maintains a per-tspan selection range for Character / Paragraph
  panel writes.

Panels that push attributes onto the selection (Character,
Paragraph, Stroke, Fill) route through the session when one is
active: writes go to `tspan` override fields on the current
selection range, and the element's `tspans` array is updated
on commit.

## Relationship to the Character / Paragraph panels

- The **Character panel** (see `CHARACTER.md`) controls
  font-family, size, weight, letter-spacing, etc. — properties
  that apply at the tspan level inside a Text element.
- The **Paragraph panel** (see `PARAGRAPH.md`) controls
  alignment, indents, hyphenation, and word-/letter-spacing
  justification controls.
- Both panels read from the current selection (tspan range) and
  write back through the edit session.

## Why these stay native

Unlike shape tools — which are essentially "capture two points,
compute geometry, commit" — text editing is a stateful
interaction with:

- Keyboard input (including IME for non-Latin scripts).
- Font shaping and kerning via platform font engines.
- Line-break calculation sensitive to locale and wrap width.
- Caret / cursor blink driven by a timer loop.
- Selection rendering that overlays glyph runs.
- Clipboard integration (plain text, rich text).

The `workspace/tools/*.yaml` grammar is expressive for the
draw-a-shape pattern but doesn't have primitives for any of
the above. Making the Type tools YAML-driven would mean either
expanding the grammar (large) or forwarding every keyboard
event to a native handler (defeats the purpose). The policy in
`NATIVE_BOUNDARY.md` §6 is to leave them native; all four
apps (Rust, Swift, OCaml, Python) keep hand-written
`type_tool.<ext>` and `type_on_path_tool.<ext>` files.

## Related tools

- **Selection tools** pick up committed Text / TextPath
  elements for moving, scaling, duplicating.
- **Anchor Point tools** on a TextPath element edit the path,
  which reflows the text.
