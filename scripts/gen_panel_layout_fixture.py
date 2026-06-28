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
# All 16 panels. The composite/data-driven widgets in color/gradient/layers
# (color_bar / fill_stroke_widget / gradient_slider / gradient_tile / dropdown /
# tree_view) lay out as canonical fixed boxes; their data-driven rows (foreach
# expansions, tree rows) need a data fixture and are deferred (no-data state).
_PANELS = [
    "symbols", "opacity", "align", "artboards", "boolean", "brushes",
    "character", "concepts", "magic_wand", "paragraph", "properties",
    "stroke", "swatches", "color", "gradient", "layers",
]
SEED = [(f"{name}@228", f"{name}_panel_content", 228) for name in _PANELS]


def main() -> int:
    bundle = json.load(open(os.path.join(ROOT, "workspace", "workspace.json")))
    panels = bundle["panels"]
    cases = []
    for name, panel_id, avail_w in SEED:
        node = panels[panel_id]
        rects = layout_panel(node, avail_w)
        cases.append({
            "name": name,
            "function": "layout_panel",
            "args": {"panel": panel_id, "avail_w": avail_w},
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
