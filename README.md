# Jas

Vector graphics editor implemented in three languages: Python, OCaml, and Swift.

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

# Swift
cd JasSwift && swift test
```

## License

Apache License 2.0. See [LICENSE](LICENSE).
