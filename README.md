# Jas

Vector graphics editor with four parallel implementations sharing the same
architecture:

| Implementation | UI Framework | Directory |
|----------------|-------------|-----------|
| Python | Qt/PySide6 | `jas/` |
| OCaml | GTK/lablgtk | `jas_ocaml/` |
| Rust | Dioxus/WASM | `jas_dioxus/` |
| Swift | AppKit | `JasSwift/` |

## Design

- [ARCH.md](ARCH.md) — MVC architecture, model, controller, canvas, and tools overview
- [DOCUMENT.md](DOCUMENT.md) — Document model, layers, element types, path commands, and bounds
- [SELECTION.md](SELECTION.md) — Selection state, three selection modes, hit testing, and operations
- [TOOLS.md](TOOLS.md) — Toolbar layout, CanvasTool interface, and all ten tools
- [MENU.md](MENU.md) — Menu bar structure, commands, and keyboard shortcuts

## Project Structure

Each implementation follows the same architecture:

- `geometry/` — Element types, path utilities, SVG import/export, measurement units
- `document/` — Immutable document model, observable model state, controller
- `tools/` — Toolbar, tool protocol, and tool implementations (selection, drawing, pen, text, text-on-path)
- `canvas/` — Canvas rendering and interaction widget
- `menu/` — Application menu bar

### Python (`jas/`)

```bash
cd jas
python jas_app.py
```

### OCaml (`jas_ocaml/`)

```bash
cd jas_ocaml
./run.sh
```

### Rust (`jas_dioxus/`)

```bash
cd jas_dioxus
dx serve
```

### Swift (`JasSwift/`)

```bash
cd JasSwift
swift run
```

## Tests

```bash
# Python
cd jas && python -m pytest geometry/ document/ canvas/ tools/ menu/ -q

# OCaml
cd jas_ocaml && dune runtest

# Rust
cd jas_dioxus && cargo test

# Swift
cd JasSwift && swift test
```

## License

Apache License 2.0. See [LICENSE](LICENSE).
