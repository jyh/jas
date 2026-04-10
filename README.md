# Jas

Jas is a vector graphics editor — a small, inspectable cousin of Adobe
Illustrator — that exists as **four parallel implementations** of the
same application, one per language, each tracking the same
architecture, the same document model, the same tool set, and the
same tests.

| Implementation | UI framework           | Directory      | How to run                |
|----------------|------------------------|----------------|---------------------------|
| Python         | Qt / PySide6           | [`jas/`](jas/)               | `cd jas && python jas_app.py` |
| OCaml          | GTK 3 / lablgtk3       | [`jas_ocaml/`](jas_ocaml/)   | `cd jas_ocaml && ./run.sh`    |
| Rust           | Dioxus (HTML5 canvas)  | [`jas_dioxus/`](jas_dioxus/) | `cd jas_dioxus && dx serve`   |
| Swift          | AppKit                 | [`JasSwift/`](JasSwift/)     | `cd JasSwift && swift run`    |

The four apps are expected to behave identically: the same SVG round-
trips through all of them, the same in-canvas text editor reacts to
the same key events, the same selection tool picks the same elements
from the same marquee. New features land in one port first (usually
Rust), get tuned, and are then propagated to the other three with
matching tests.

## Why four copies?

Building the same program four ways is a deliberate design
constraint, not a historical accident. It enforces:

- **A small, portable architecture** — anything that would be easy in
  one language and awkward in the others tends to get removed, so the
  design converges on ideas that work everywhere.
- **Framework-independent logic** — the model, document, geometry,
  text layout, and tool state machines are all pure code, testable
  without a window or a running event loop.
- **Framework-specific edges** — rendering, cursor overrides, file
  dialogs, and the toolbar bitmaps live in each app's canvas module,
  and nowhere else.
- **Cross-language equivalence as a test** — when something diverges
  (kerning, UTF-8 handling, SVG y-convention), the bug is visible
  because only one port exhibits it.

## What it does

Jas is a single-window editor for SVG-shaped documents. It currently
supports:

- **Shapes** — Rectangle, Rounded Rectangle, Ellipse, Line, Polygon,
  and Star primitives, each draggable into place.
- **Paths** — a full Pen tool with smooth/corner/cusp anchor points;
  Add/Delete/Anchor-Point editors; a freehand Pencil tool with Bezier
  curve fitting; a Path Eraser that splits curves while preserving
  their shape; and a Smooth tool that regularizes anchor points along
  a drag.
- **Text and Type on a Path** — a fully native in-place text editor
  with word-wrap, soft-wrap navigation, per-character hit-testing,
  undo/redo (collapsed to a single document snapshot per session), a
  blinking caret, selection highlighting, multi-line area text, and a
  Type-on-Path variant where glyphs flow along a curve with an
  interactive start-offset handle.
- **Selection** — three modes (Selection, Direct Selection, Group
  Selection) covering element selection, control-point selection, and
  group-traversal selection, with marquee, shift-extend, alt-copy,
  keyboard nudge, and hit-testing against filled, stroked, and curved
  shapes.
- **Document model** — immutable `Document` with nested layers and
  groups, an observable `Model` with an undo/redo stack, and a
  `Controller` for every mutation operation. Documents are never
  mutated; every edit produces a new `Document`.
- **SVG I/O** — each app can export its current document to SVG and
  reopen SVGs it wrote. Text y-coordinates are converted between the
  SVG baseline and the layout-box top so files round-trip stably.
- **Menu and keyboard** — an Illustrator-style menu bar plus keyboard
  shortcuts for tools and common edit commands.

## Design

All four ports share one set of design documents, kept deliberately
short:

- [ARCH.md](ARCH.md) — MVC architecture, Model/Controller/Canvas
  boundaries, the `CanvasTool` interface, and the directory layout
  every port mirrors.
- [DOCUMENT.md](DOCUMENT.md) — the immutable `Document`, layers,
  element types, path commands, bounds, and control-point conventions.
- [SELECTION.md](SELECTION.md) — selection state, the three modes, hit
  testing, marquee intersection, and selection operations.
- [TOOLS.md](TOOLS.md) — the toolbar, shared constants, and each of
  the tools (state machines, overlays, keyboard handling).
- [WORKSPACE.md](WORKSPACE.md) — the workspace layout system: pane
  positioning, dock panels, snap constraints, the working-copy save
  pattern, and persistence across all four implementations.
- [MENU.md](MENU.md) — the menu bar structure, commands, and the
  keyboard shortcuts they expose.
- [KEYBOARD_SHORTCUTS.md](KEYBOARD_SHORTCUTS.md) — the target
  Illustrator shortcut set used as a reference.
- [REQUIREMENTS.md](REQUIREMENTS.md) — the high-level product
  requirements the project started from.
- [TRANSCRIPT.md](TRANSCRIPT.md) — the original prompts used to
  bootstrap each feature.

## Project structure

Each implementation mirrors the same module layout. Names differ
slightly per language but the split is identical:

| Directory         | Contents                                                                                     |
|-------------------|----------------------------------------------------------------------------------------------|
| `geometry/`       | Element types, `PathCommand`, bounds, control-point positions, SVG import/export, unit conversion, text layout (word-wrap, UTF-8, glyph index), path-text layout (arc-length glyph placement), curve fitting |
| `document/`       | Immutable `Document`, observable `Model` with undo/redo, `Controller` with all mutation operations |
| `tools/`          | `CanvasTool` interface, `ToolContext` facade, shared constants, toolbar, and every tool implementation (selection tools, drawing tools, Pen, Pencil, Path Eraser, Smooth, Anchor Point editors, Type, Type on a Path, plus the shared `text_edit` session and `text_measure` helper) |
| `workspace/`      | Workspace layout: pane positions and snap constraints, dock/panel management, persistence, and the working-copy save pattern |
| `canvas/`         | Rendering via the platform 2D API, hit-testing, cursor management, and event dispatch to the active tool |
| `menu/`           | The application menu bar and its command table                                              |
| `assets/icons/`   | Shared PNG/SVG cursors and toolbar icons used by all four apps                               |

## Running

### Python (Qt)

```bash
cd jas
python jas_app.py
```

Requires PySide6 (see `requirements.txt`).

### OCaml (GTK)

```bash
cd jas_ocaml
./run.sh       # wraps `dune exec bin/main.exe`
```

Requires a recent OCaml with `lablgtk3`, `cairo2`, `xmlm`, and `str`
(see `dune-project`).

### Rust (Dioxus, browser)

```bash
cd jas_dioxus
dx serve       # opens the app in a browser via WebAssembly
```

Requires the Dioxus CLI (`dx`) and a recent Rust toolchain.

### Swift (AppKit)

```bash
cd JasSwift
swift run
```

Requires macOS and a recent Swift toolchain.

## Tests

Each port has its own test runner. All four suites are expected to
pass together on every change to shared logic.

```bash
# Python
cd jas && PYTHONPATH=. python -m pytest

# OCaml
cd jas_ocaml && dune runtest

# Rust
cd jas_dioxus && cargo test

# Swift
cd JasSwift && swift test
```

Current counts: Rust **330**, Swift **325**, Python **393**, OCaml all
suites passing. Tests are organized by module and run without any GUI
dependency — they exercise the pure model, geometry, text layout,
SVG, and tool state machines directly, so they run in milliseconds.

## License

Apache License 2.0. See [LICENSE](LICENSE).
