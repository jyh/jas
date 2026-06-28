#!/usr/bin/env python3
"""Generate the Path B panel-layout golden corpus.

Runs the canonical ``layout_panel`` (workspace_interpreter/panel_layout.py) over a set
of seed panels from the compiled workspace bundle and writes the pinned
golden to test_fixtures/algorithms/panel_layout.json.  Every app's
cross_language_test asserts its own layout_panel against this file (Template
A — pinned vectors, in-suite, byte-exact integer math).

Regenerate after changing the algorithm, the seed list, or the bundle:

    python -m workspace_interpreter.compile workspace/ workspace/workspace.json
    python scripts/gen_panel_layout_fixture.py

See PATH_B_DESIGN.md (esp. Appendix A) for the contract.
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from workspace_interpreter.panel_layout import layout_panel  # noqa: E402

# (case name, compiled panel id, available content width).
# avail_w = 228 is the canonical dock content width (dock 240 - 12 scrollbar).
# All 16 panels. avail_h=600 drives vertical flex (foreach lists grow to fill).
# Per-panel `ctx` is the data scope used to evaluate foreach sources and text
# bindings; symbols carries a deterministic master list so its foreach expands
# (the first foreach data slice). Panels left at {} expand foreach to empty
# (no-data state) and resolve bound text to null.
_PANELS = [
    "symbols", "opacity", "align", "artboards", "boolean", "brushes",
    "character", "concepts", "magic_wand", "paragraph", "properties",
    "stroke", "swatches", "color", "gradient", "layers",
]

_SYMBOLS_CTX = {
    "active_document": {
        "symbols": [
            {"id": "m1", "name": "Star", "usage_count": 3},
            {"id": "m2", "name": "Gear", "usage_count": 0},
            {"id": "m3", "name": "Logo Mark", "usage_count": 12},
        ],
        "selection_count": 1,
    },
    "panel": {"selected_symbol": "m1"},
}

# artboards + concepts use column-only foreach, which the v1 engine handles, so
# a data fixture is all that's needed (no engine change). brushes/gradient/layers/
# swatches use row/wrap (and nested) foreach — deferred until the engine grows
# row/wrap expansion — so they stay at {} (empty lists) for now.
_ARTBOARDS_CTX = {
    "active_document": {
        "artboards": [
            {"name": "Artboard 1", "number": 1},
            {"name": "Mobile", "number": 2},
            {"name": "Desktop Hero", "number": 3},
        ],
    },
}

_CONCEPTS_CTX = {
    "active_document": {
        "selected_concept": {
            "name": "Gear",
            "params": [{"name": "radius"}, {"name": "teeth"}, {"name": "angle"}],
            "operations": [{"label": "Rotate 45"}, {"label": "Mirror"}],
            "violations": [{"message": "teeth must be >= 3"}],
        },
    },
    "data": {"concepts": [{"name": "Gear"}, {"name": "Star"}, {"name": "Spiral"}]},
}

# layers uses a ROW foreach (isolation-stack breadcrumb); gradient a WRAP foreach
# (gradient tile grid — the tiles have no bindings, so only the count matters).
_LAYERS_CTX = {
    "panel": {
        "isolation_stack": [
            {"container_name": "Layer 1"},
            {"container_name": "Group A"},
            {"container_name": "Path 3"},
        ],
    },
}

_GRADIENT_CTX = {
    "panel": {"active_library_id": "lib1", "thumbnail_size": 32},
    "data": {"gradient_libraries": {"lib1": {"gradients": [{}, {}, {}, {}, {}, {}, {}, {}]}}},
}

_CTX = {
    "symbols": _SYMBOLS_CTX,
    "artboards": _ARTBOARDS_CTX,
    "concepts": _CONCEPTS_CTX,
    "layers": _LAYERS_CTX,
    "gradient": _GRADIENT_CTX,
}
_AVAIL_H = 600

SEED = [
    (f"{name}@228", f"{name}_panel_content", 228, _AVAIL_H, _CTX.get(name, {}))
    for name in _PANELS
]


def main() -> int:
    bundle = json.load(open(os.path.join(ROOT, "workspace", "workspace.json")))
    panels = bundle["panels"]
    cases = []
    for name, panel_id, avail_w, avail_h, ctx in SEED:
        node = panels[panel_id]
        rects = layout_panel(node, avail_w, avail_h, ctx)
        cases.append({
            "name": name,
            "function": "layout_panel",
            "args": {"panel": panel_id, "avail_w": avail_w, "avail_h": avail_h, "ctx": ctx},
            "expected": rects,
        })
    out_path = os.path.join(ROOT, "test_fixtures", "algorithms", "panel_layout.json")
    with open(out_path, "w") as f:
        json.dump(cases, f, indent=2)
        f.write("\n")
    print(f"wrote {len(cases)} cases -> {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
