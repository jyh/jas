#!/usr/bin/env python3
"""Generate the Path B panel-layout golden corpus.

Runs the canonical ``layout_panel`` (jas/panels/panel_layout.py) over a set
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
sys.path.insert(0, os.path.join(ROOT, "jas"))

from panels.panel_layout import layout_panel  # noqa: E402

# (case name, compiled panel id, available content width).
# avail_w = 228 is the canonical dock content width (dock 240 - 12 scrollbar).
SEED = [
    ("symbols@228", "symbols_panel_content", 228),
    ("opacity@228", "opacity_panel_content", 228),
]


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
