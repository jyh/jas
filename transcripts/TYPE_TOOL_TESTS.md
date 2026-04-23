# Type & Type on Path Tools — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source: **no yaml**
— both tools are permanent-native per `NATIVE_BOUNDARY.md` §6. Design
doc: `transcripts/TYPE_TOOL.md`.

Covers **Type** (point text + area text) and **Type on Path**. These
two tools are hand-written in each native app rather than YAML-driven
because text editing involves IME, font shaping, caret timers, and
line-break calculation that don't fit the YAML effect grammar.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other platforms
covered in Session J parity sweep.

Flask is omitted from this suite entirely — it has no canvas text
subsystem (see memory `project_flask_tspan_deferred`).

---

## Known broken

_Last reviewed: 2026-04-23_

_Track known-broken entries for Type-specific regressions here._
There are active known-gaps tracked in other docs:

- Paragraph-level multi-line wrapping in the segmented canvas is
  deferred (memory `project_tspan_multiline_paragraph`). Area-text
  wrapping still works at the tspan level; full paragraph-grade
  wrapping is a Paragraph-panel phase issue, not a Type-tool one.

---

## Automation coverage

_Last synced: 2026-04-23_

**Python — `jas/tools/type_tool_test.py`,
`jas/tools/type_on_path_tool_test.py`** (each ~10 tests)
- Click creates point-text; drag creates area-text with rectangle
  bounds.
- Edit session lifecycle (open on create / close on commit).
- IME composition routed through session; captureKeyboard → True
  while session active.
- Type on Path: click on a Path / Polygon / shape with a d
  attribute converts it to a TextPath element.

**Swift — `JasSwift/Tests/Tools/TypeToolTests.swift`,
`JasSwift/Tests/Tools/TypeOnPathToolTests.swift`**
- Mirror of Python coverage + AppKit NSTextView integration checks.

**OCaml — `jas_ocaml/test/tools/type_tool_test.ml`,
`jas_ocaml/test/tools/type_on_path_tool_test.ml`**
- Mirror via GTK text entry integration tests.

**Rust — `jas_dioxus/src/tools/type_tool.rs` (#[cfg(test)])**,
`jas_dioxus/src/tools/type_on_path_tool.rs` (#[cfg(test)])
- Reference hand-written implementations.

**Flask — none.** No canvas text editor.

The manual suite below covers what auto-tests cannot: actual caret
rendering and blink, IME interaction across platforms, panel
integration (Character / Paragraph), visible layout of area text as
it wraps, and the visual round-trip through the shared
`TextEditSession`.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document.
3. Appearance: **Dark**.
4. Type tool active (press `T`) or Type on Path tool active (no
   default shortcut — select from toolbox).

When a test calls for a **type path fixture**: Pen tool → draw an
open curve across the canvas (click corner at (50,300); drag-smooth
to (200,150) by dragging to (250,150); click corner at (350,300);
click corner at (500,150); Esc).

When a test calls for a **typed text**: after creating the Text
element, type "Hello World" into the active edit session.

---

## Tier definitions

- **P0 — existential.** Tool doesn't activate, doesn't create a Text
  element, or crashes.
- **P1 — core.** Click/drag creates the expected Text element and
  enters an edit session; characters appear as typed.
- **P2 — edge & polish.** Caret rendering, IME, line wrap, panel
  writes, cursor glyph, clipboard, appearance theming.

---

## Session table of contents

| Session | Topic                                       | Est.  | IDs      |
|---------|---------------------------------------------|-------|----------|
| A       | Smoke & lifecycle                           | ~5m   | 001–009  |
| B       | Type — create point text                    | ~8m   | 010–039  |
| C       | Type — create area text                     | ~8m   | 040–069  |
| D       | Type — edit session commit paths            | ~6m   | 070–089  |
| E       | Type — panel integration                    | ~8m   | 090–109  |
| F       | Type — IME / non-Latin                      | ~8m   | 110–129  |
| G       | Type on Path — basic creation               | ~6m   | 130–149  |
| H       | Type on Path — start_offset                 | ~5m   | 150–169  |
| I       | Overlay, cursor, theming                    | ~5m   | 170–189  |
| J       | Cross-app parity                            | ~15m  | 200–229  |

Full pass: ~75 min.

---

## Session A — Smoke & lifecycle (~5 min)

- [ ] **TYP-001** [wired] Type tool activates via `T` shortcut.
      Do: Press T.
      Expect: Type tool active; cursor becomes I-beam over canvas.
      — last: —

- [ ] **TYP-002** [wired] Type on Path activates via toolbox icon.
      Do: Click the Type on Path icon.
      Expect: Active state; I-beam cursor.
      — last: —

- [ ] **TYP-003** [wired] Cursor switches to crosshair during
  placement.
      Setup: Type tool active.
      Do: Press mouse (begin placing a rectangle).
      Expect: Cursor shifts from I-beam to crosshair during the
              placement drag; reverts to I-beam (or session caret)
              on release.
      — last: —

---

## Session B — Type — create point text (~8 min)

**P0**

- [ ] **TYP-010** [wired] Click creates a point-text element.
      Do: Click at (100,100).
      Expect: A blank Text element appears at (100,100); caret
              visible blinking at the click point; edit session
              active.
      — last: —

- [ ] **TYP-011** [wired] Typing appears as characters in the point
  text.
      Setup: TYP-010 state.
      Do: Type "Hello".
      Expect: "Hello" appears on the canvas at the caret; caret
              advances with each keystroke.
      — last: —

**P1**

- [ ] **TYP-012** [wired] Line breaks require explicit newlines.
      Setup: Empty point text, caret active.
      Do: Type "Hello", Enter, "World".
      Expect: Two lines — "Hello" above, "World" below — both
              flowing freely without wrap.
      — last: —

- [ ] **TYP-013** [wired] Point text width grows with content.
      Setup: Empty point text.
      Do: Type a long single line ("The quick brown fox jumps").
      Expect: Text does NOT wrap; element's effective width grows
              to fit the content (no rectangle bounds).
      — last: —

**P2**

- [ ] **TYP-014** [wired] Clicking through on an existing Text
  element enters its edit session.
      Setup: TYP-011 state committed (clicked away).
      Do: Click inside the existing "Hello" text with Type tool.
      Expect: Caret enters that text at the clicked position.
      — last: —

---

## Session C — Type — create area text (~8 min)

**P0**

- [ ] **TYP-040** [wired] Drag creates an area-text element.
      Do: Press at (100,100); drag to (400,300); release.
      Expect: A blank area Text element appears inside that
              rectangle; caret visible at the top-left of the box;
              edit session active.
      — last: —

- [ ] **TYP-041** [wired] Area text wraps to rectangle width.
      Setup: TYP-040 state.
      Do: Type a long paragraph.
      Expect: Text wraps at the rectangle's right edge; additional
              lines flow downward within the box.
      — last: —

**P1**

- [ ] **TYP-042** [wired] Area text overflow extends visible region.
      Setup: Area text box 200×100.
      Do: Type enough text to exceed the height.
      Expect: Text continues beyond the box height (per tspan
              overflow rules — visible or clipped depending on
              element configuration).
      — last: —

- [ ] **TYP-043** [wired] Tiny drag (1 px) creates point text, not
  area text.
      Do: Press; drag 1 px; release.
      Expect: Point-text element created (matching click semantics);
              edit session active.
      — last: —

**P2**

- [ ] **TYP-044** [wired] Area text rectangle is drawn up-and-left
  correctly.
      Do: Press (400,300); drag to (100,100); release.
      Expect: Area text rectangle covers (100,100)–(400,300) after
              normalization.
      — last: —

---

## Session D — Type — edit session commit paths (~6 min)

**P1**

- [ ] **TYP-070** [wired] Clicking outside commits and ends session.
      Setup: Area text with "Hello World" typed, caret active.
      Do: Click empty canvas with Type tool (outside the text).
      Expect: Edit session ends; caret disappears; text element
              committed as "Hello World".
      — last: —

- [ ] **TYP-071** [wired] Esc commits and ends session.
      Setup: TYP-070 state (before the click-out).
      Do: Press Esc.
      Expect: Same outcome — session ends, text committed.
      — last: —

- [ ] **TYP-072** [wired] Switching tools commits and ends session.
      Setup: Active edit session with "Hello" typed.
      Do: Press V (Selection).
      Expect: Text committed; Selection tool active; caret gone.
      — last: —

**P2**

- [ ] **TYP-073** [wired] Empty point-text commit leaves a 0-char
  element (or discards).
      Setup: Click to create point text; don't type anything.
      Do: Click away.
      Expect: Either a zero-character Text element exists (per
              design) or nothing was committed — verify per-app
              behavior matches consistently.
      — last: —

---

## Session E — Type — panel integration (~8 min)

**P1**

- [ ] **TYP-090** [wired] Character panel font-size write goes
  through the session.
      Setup: Type "Hello"; select "Hel" via caret drag.
      Do: Set size to 36 pt via Character panel.
      Expect: "Hel" renders at 36 pt; "lo" remains at prior size
              (tspan override).
      — last: —

- [ ] **TYP-091** [wired] Paragraph panel alignment works.
      Setup: Area text with multi-line content; caret inside.
      Do: Click Right Align in Paragraph panel.
      Expect: All lines in the paragraph right-align within the
              rectangle.
      — last: —

**P2**

- [ ] **TYP-092** [wired] Stroke panel write goes to tspan override.
      Setup: Caret in existing text; select a range.
      Do: Set stroke = red 1 pt.
      Expect: Just that range renders with a red stroke on glyphs.
      — last: —

---

## Session F — Type — IME / non-Latin (~8 min)

**P1**

- [ ] **TYP-110** [wired] IME composition shows marked text.
      Setup: Enable an IME (e.g. Pinyin on macOS) with Type tool;
             click to create point text.
      Do: Type a Pinyin sequence that starts a composition.
      Expect: Marked text (underlined, pre-committed) appears at
              caret; commit step finalizes to CJK characters.
      — last: —

- [ ] **TYP-111** [wired] Non-Latin scripts render at correct
  baseline.
      Setup: Type tool; point text.
      Do: Type Japanese / Arabic / Hebrew characters.
      Expect: Glyphs render with platform-correct shaping and
              baseline (no tofu / missing-glyph boxes).
      — last: —

**P2**

- [ ] **TYP-112** [wired] Mixed RTL + LTR text renders in logical
  order.
      Setup: Point text.
      Do: Type "Hello שלום world".
      Expect: "שלום" runs right-to-left within the containing LTR
              context; caret position tracks logical order.
      — last: —

---

## Session G — Type on Path — basic creation (~6 min)

**P0**

- [ ] **TYP-130** [wired] Click on a Path converts it to a TextPath.
      Setup: Type path fixture; Type on Path tool active.
      Do: Click on the path.
      Expect: Path element is replaced with (or promoted to) a
              TextPath element; edit session opens; caret at path
              start (start_offset=0).
      — last: —

- [ ] **TYP-131** [wired] Typing flows characters along the path.
      Setup: TYP-130 state.
      Do: Type "Hello".
      Expect: Characters appear along the path; each glyph's
              baseline follows the curve; characters don't cross
              over.
      — last: —

**P1**

- [ ] **TYP-132** [wired] Clicking on a Polygon works identically.
      Setup: Polygon tool → draw pentagon → switch to Type on Path.
      Do: Click the polygon.
      Expect: TextPath creation succeeds on any element with a d
              attribute.
      — last: —

- [ ] **TYP-133** [wired] Clicking on a non-path element does not
  convert.
      Setup: Rect → switch to Type on Path (assume Rect has no d).
      Do: Click the rect.
      Expect: Either the rect is treated as a path (if converted
              implicitly), or the click is a no-op. Verify
              consistent behavior per design doc.
      — last: —

---

## Session H — Type on Path — start_offset (~5 min)

**P1**

- [ ] **TYP-150** [wired] Default start_offset is 0.
      Setup: TYP-130 state.
      Do: Observe the first glyph's baseline position.
      Expect: First glyph sits at path t=0 (the MoveTo point).
      — last: —

**P2**

- [ ] **TYP-151** [wired] Editing start_offset via element control
  points shifts text.
      Setup: TYP-130 state committed; select the TextPath with
             Selection tool; open Partial Selection to reach the
             start-offset handle.
      Do: Drag the start-offset handle along the path.
      Expect: Text origin shifts along the path as the handle moves.
              The design doc explicitly notes this is handled by the
              element control points, not the Type on Path tool.
      — last: —

---

## Session I — Overlay, cursor, theming (~5 min)

**P2**

- [ ] **TYP-170** [wired] Caret blinks at ~1 Hz while session active.
      Setup: Active edit session.
      Do: Observe caret.
      Expect: Caret toggles visible/invisible at the platform-
              standard caret-blink rate.
      — last: —

- [ ] **TYP-171** [wired] I-beam cursor over text content.
      Setup: Committed text on canvas; Type tool active.
      Do: Hover the text.
      Expect: Cursor reads as I-beam (text-hover affordance).
      — last: —

- [ ] **TYP-172** [wired] Caret readable on all three appearances.
      Setup: Active edit session.
      Do: Switch Dark / Medium / Light.
      Expect: Caret remains visible on each background; no black-
              on-black regression.
      — last: —

---

## Cross-app parity — Session J (~15 min)

~5 load-bearing tests. Batch by app. Flask excluded (no canvas text
subsystem).

- **TYP-200** [wired] Click creates a point-text element identically.
      Do: Click at (100,100).
      Expect: One Text element added with position (100,100) and
              edit session active in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **TYP-201** [wired] Drag creates area-text with matching bounds.
      Do: Press (100,100); drag (400,300); release.
      Expect: One area Text element with matching rectangle bounds
              in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **TYP-202** [wired] Typing characters appears consistently in all
  apps.
      Do: Type "Hello" into a fresh point text.
      Expect: Text content reads "Hello" in every app's document
              model after commit.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **TYP-203** [wired] Click-outside commits and ends session
  identically.
      Do: Active session; click empty canvas.
      Expect: Session ends, text committed, caret gone in every app.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- **TYP-204** [wired] Type on Path converts a Path element
  identically.
      Do: Type path fixture; click on it with Type on Path.
      Expect: TextPath element produced in every app; edit session
              active at start_offset=0.
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

---

## Graveyard

_No retired tests yet._

---

## Enhancements

- **ENH-001** Unified "text hit" — clicking on an existing text
  element with the Selection tool could transparently switch into
  Type tool for inline editing. Out of scope today. _Raised during
  TYP-014 on 2026-04-23._

- **ENH-002** Paragraph-level wrapping in canvas — segmented-canvas
  area text doesn't yet do full paragraph wrap (tspan-level only).
  Deferred per memory `project_tspan_multiline_paragraph`. _Raised
  during TYP-042 on 2026-04-23._

- **ENH-003** Start-offset drag in Type on Path tool itself — today
  the user must switch to Partial Selection to drag the start-offset
  handle. A sticky handle during Type-on-Path sessions would be
  friendlier. _Raised during TYP-151 on 2026-04-23._
