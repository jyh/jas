#!/usr/bin/env python3
"""Generate the Path B panel golden corpora (rects, structure, and values).

Runs the three canonical panel passes over seed panels from the compiled
workspace bundle and writes their pinned goldens:

  * ``layout_panel``  -> test_fixtures/algorithms/panel_layout.json
  * ``widget_tree``   -> test_fixtures/algorithms/panel_widget_tree.json
  * ``bind_values``   -> test_fixtures/algorithms/panel_bind_values.json

Every app's cross_language_test asserts its own implementation against these
files (Template A — pinned vectors, in-suite, byte-exact).

The first two share one seed list over all 16 panels.  ``bind_values`` has its
OWN, deliberately short seed list (``BIND_SEED``): it pins resolved VALUES, so
its vectors need a rich data scope, and a value snapshot of every panel would be
mostly repetition that churns on unrelated edits.  See the module docstring of
``workspace_interpreter/bind_values.py``.

Regenerate after changing an algorithm, a seed list, or the bundle:

    python -m workspace_interpreter.compile workspace/ workspace/workspace.json
    python scripts/gen_panel_layout_fixture.py

See PATH_B_DESIGN.md (esp. Appendix A) for the contract.
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from workspace_interpreter.bind_values import bind_values  # noqa: E402
from workspace_interpreter.panel_layout import layout_panel  # noqa: E402
from workspace_interpreter.widget_tree import widget_tree  # noqa: E402

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

# brushes + swatches: outer column foreach over open libraries -> a disclosure
# section per library -> inner WRAP foreach of brush/swatch tiles.
_BRUSHES_CTX = {
    "panel": {"open_libraries": [{"id": "lib1"}], "thumbnail_size": 24},
    "data": {"brush_libraries": {"lib1": {"name": "Calligraphic", "brushes": [
        {"name": "5 pt Round", "slug": "r5"},
        {"name": "3 pt Flat", "slug": "f3"},
        {"name": "Tapered", "slug": "tp"},
    ]}}},
}

_SWATCHES_CTX = {
    "panel": {"open_libraries": [{"id": "lib1"}], "thumbnail_size": 16},
    "data": {"swatch_libraries": {"lib1": {"name": "Default", "swatches": [
        {} for _ in range(10)
    ]}}},
}

_CTX = {
    "symbols": _SYMBOLS_CTX,
    "artboards": _ARTBOARDS_CTX,
    "concepts": _CONCEPTS_CTX,
    "layers": _LAYERS_CTX,
    "gradient": _GRADIENT_CTX,
    "brushes": _BRUSHES_CTX,
    "swatches": _SWATCHES_CTX,
}
_AVAIL_H = 600

SEED = [
    (f"{name}@228", f"{name}_panel_content", 228, _AVAIL_H, _CTX.get(name, {}))
    for name in _PANELS
]

# ---------------------------------------------------------------------------
# bind_values seeds — four vectors over three panels, one per expression shape
# ---------------------------------------------------------------------------
#
# Chosen to cover the shapes the value surface can take, not to cover panels:
#   * a colour swatch                 -> color/swatches `bind.color`
#   * a numeric field (weight, dashes) -> stroke `bind.value` on length_input
#   * a conditional `visible`          -> color `bind.visible` on the five
#     per-mode slider containers (exactly one true per vector)
#   * a `foreach`                      -> swatches, two NESTED foreach levels,
#     including the `{{ }}` disclosure label panel_layout reduces to a count
# Plus the arms that only a value snapshot can tell apart: a null colour vs a
# present one, an empty string vs null, and non-integral numbers.

# The colour bug's own panel, with a selection: `panel.hex` is the six-character
# field whose divergence started the census ("664040" vs "664141").
_BV_COLOR_SELECTED = {
    "state": {
        "fill_color": "#664040",
        "stroke_color": "#112233",
        "fill_on_top": True,
    },
    "panel": {
        "mode": "hsb",
        "hex": "664040",
        # HSB of #664040 as the panel shows it (h=0 because r>g==b).
        "h": 0, "s": 37.254902, "b": 40,
        "r": 102, "g": 64, "bl": 64,
        "c": 0, "m": 37.254902, "y": 37.254902, "k": 60,
        # Three filled recent slots; slots 3..9 resolve to null, so the same
        # widget kind is pinned in both its present and its empty state.
        "recent_colors": ["#664040", "#112233", "#ffffff"],
    },
}

# No active colour: every `bind.disabled` flips true, every `bind.color` that
# reads the active attribute goes null, and a different slider container is
# visible. `hex: ""` is the empty STRING, which canonicalizes to the same
# characters as null and is distinguished only by the record's `type`.
_BV_COLOR_NONE = {
    "state": {
        "fill_color": None,
        "stroke_color": "#112233",
        "fill_on_top": True,
    },
    "panel": {
        "mode": "cmyk",
        "hex": "",
        "h": 0, "s": 0, "b": 0,
        "r": 0, "g": 0, "bl": 0,
        "c": 0, "m": 0, "y": 0, "k": 0,
        "recent_colors": [],
    },
}

# Two libraries, one expanded and one collapsed: the outer foreach expands per
# library and the inner one per swatch, so tile colours resolve from the foreach
# item and the disclosure label from a bundle lookup keyed by it.
_BV_SWATCHES = {
    "state": {
        "fill_color": "#ff0000",
        "stroke_color": None,
        "fill_on_top": False,
    },
    "panel": {
        "open_libraries": [
            {"id": "lib1", "collapsed": False},
            {"id": "lib2", "collapsed": True},
        ],
        "selected_swatches": ["lib1:0"],
        "recent_colors": ["#ff0000"],
        "thumbnail_size": 16,
    },
    "data": {
        "swatch_libraries": {
            "lib1": {"name": "Default", "swatches": [
                {"color": "#ff0000"}, {"color": "#00ff00"},
            ]},
            "lib2": {"name": "Grays", "swatches": [
                {"color": "#808080"},
            ]},
        },
    },
}

# Dash + arrowhead state, for the numeric-field shape: `weight` and the dash /
# gap lengths are length_input bindings, and 2.5 / 0.5 / 1.25 are the
# non-integral values that separate a real value pin from a length pin.
_BV_STROKE = {
    "state": {"stroke_brush": None},
    "panel": {
        "weight": 2.5,
        "cap": "round",
        "join": "bevel",
        "miter_limit": 4,
        "align_stroke": "inside",
        "dashed": True,
        "dash_align_anchors": False,
        "dash_1": 6, "gap_1": 3,
        "dash_2": 0.5, "gap_2": 1.25,
        "dash_3": 0, "gap_3": 0,
        "start_arrowhead": "none",
        "end_arrowhead": "Arrow 5",
        "start_arrowhead_scale": 100,
        "end_arrowhead_scale": 200,
        "link_arrowhead_scale": True,
        "arrow_align": "tip_at_end",
        "profile": "Width Profile 1",
        "profile_flipped": False,
    },
}

# ---------------------------------------------------------------------------
# LIST-shaped bind values (CORPUS_CENSUS.md 10(c))
# ---------------------------------------------------------------------------
#
# `canon_value` documents the list form as "[" + elements joined by "," + "]",
# each element canonicalized the same way (so a nested list nests its
# brackets).  Every list row the four seeds above produce is the SINGLE-element
# `[lib1:0]`, which exercises neither the separator nor the recursion: changing
# the join string to ";" in any port leaves all three rows byte-identical.  The
# three seeds below are the vectors that make those two halves of the contract
# observable.

# Multi-element, from live-shaped data: three swatches selected across two
# libraries.  `bind.selected_in` is `panel.selected_swatches` verbatim, so each
# of the three tiles reports the whole selection and the joined form appears
# three times.  (The ids are the "lib:index" strings `swatches@two_libraries`
# already uses, not the `item_type: number` the panel's state block declares --
# matching the existing vector rather than introducing a second convention.)
_BV_SWATCHES_MULTI = {
    "state": {"fill_color": "#ff0000", "stroke_color": None,
              "fill_on_top": False},
    "panel": {
        "open_libraries": [
            {"id": "lib1", "collapsed": False},
            {"id": "lib2", "collapsed": True},
        ],
        "selected_swatches": ["lib1:0", "lib1:1", "lib2:0"],
        "recent_colors": [],
        "thumbnail_size": 16,
    },
    "data": {
        "swatch_libraries": {
            "lib1": {"name": "Default", "swatches": [
                {"color": "#ff0000"}, {"color": "#00ff00"},
            ]},
            "lib2": {"name": "Grays", "swatches": [
                {"color": "#808080"},
            ]},
        },
    },
}

# NESTED, and deliberately SYNTHETIC: no binding in the compiled bundle
# produces a list of lists today (checked over all 311 declared bind entries:
# the ones that can evaluate to a list are selected_swatches, selected_brushes,
# type_filter, panel_selection and element_selection -- all flat -- plus the
# gradient panel's `stops`, a flat list of OBJECTS, which is excluded for the
# same key-order reason `element_tree` and `twirl_states` are).  The recursion
# is nevertheless implemented and documented in all three ports, so this scope
# feeds `panel.selected_swatches` a list of lists purely to pin it: an inner
# multi-element list, an EMPTY inner list (which must render as `[]`, not as
# the empty string a null renders as), and one doubly-nested element.
_BV_SWATCHES_NESTED = {
    "state": {"fill_color": None, "stroke_color": None, "fill_on_top": True},
    "panel": {
        "open_libraries": [{"id": "lib1", "collapsed": False}],
        "selected_swatches": [["lib1:0", "lib1:1"], [], ["lib2:0", ["deep"]]],
        "recent_colors": [],
        "thumbnail_size": 16,
    },
    "data": {
        "swatch_libraries": {
            "lib1": {"name": "Default", "swatches": [{"color": "#ff0000"}]},
        },
    },
}

# The layers tree_view, whose `bind` block is the bundle's densest list surface:
# `element_selection` is a list of PATH values (the reference builds it as
# `[Value.path(p) for p in canvas_selection]`; over a JSON scope the same values
# arrive as the `{"__path__": [...]}` marker every port decodes), and
# `layers_panel_selection` / `type_filter` are lists of strings (the seed uses
# ids where the app stores path markers; the vector is about the LIST form).  A path INSIDE a list
# is the one element arm no other vector reaches: `type` "path" occurs zero
# times in the 225 rows of the four seeds above.
#
# `element_tree` and `twirl_states` are left null on purpose -- both are OBJECT
# bindings, and an object's JSON key order is a known cross-port divergence
# (census row #50), which `bind_values`' own module docs say no vector may bind
# until that row closes.  A null there also keeps the tree's row foreach from
# expanding, so the vector stays 12 rows wide and is about the list forms.
_BV_LAYERS_LISTS = {
    "state": {},
    "panel": {
        "layers_panel_selection": ["el_a", "el_b", "el_c"],
        "type_filter": ["path", "text"],
        "isolation_stack": [],
        "twirl_states": None,
        "renaming_element": None,
        "drag_active": False,
        "search_query": "",
    },
    "active_document": {
        "element_tree": None,
        "element_selection": [
            {"__path__": [0, 1]},
            {"__path__": [0, 2, 3]},
            {"__path__": [1]},
        ],
        "artboards_panel_selection_ids": [],
    },
}

# (case name, compiled panel id, ctx)
BIND_SEED = [
    ("color@hsb_selected", "color_panel_content", _BV_COLOR_SELECTED),
    ("color@cmyk_no_active_color", "color_panel_content", _BV_COLOR_NONE),
    ("swatches@two_libraries", "swatches_panel_content", _BV_SWATCHES),
    ("stroke@dashed_bevel", "stroke_panel_content", _BV_STROKE),
    ("swatches@multi_selection", "swatches_panel_content", _BV_SWATCHES_MULTI),
    ("swatches@nested_selection", "swatches_panel_content",
     _BV_SWATCHES_NESTED),
    ("layers@selection_lists", "layers_panel_content", _BV_LAYERS_LISTS),
]


def main() -> int:
    bundle = json.load(open(os.path.join(ROOT, "workspace", "workspace.json"), encoding="utf-8"))
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
    with open(out_path, "w", encoding="utf-8", newline="") as f:
        json.dump(cases, f, indent=2)
        f.write("\n")
    print(f"wrote {len(cases)} cases -> {out_path}")

    # Widget-tree golden from the SAME seeds/ctx (the panel_widget_tree.json
    # gate had no generator, so it could drift undetected — finding #32). Each
    # app's cross_language_test asserts its widget_tree against this file.
    wt_cases = []
    for name, panel_id, _avail_w, _avail_h, ctx in SEED:
        tree = widget_tree(panels[panel_id], ctx)
        wt_cases.append({
            "name": panel_id,
            "function": "widget_tree",
            "args": {"panel": panel_id, "ctx": ctx},
            "expected": tree,
        })
    wt_path = os.path.join(ROOT, "test_fixtures", "algorithms", "panel_widget_tree.json")
    with open(wt_path, "w", encoding="utf-8", newline="") as f:
        json.dump(wt_cases, f, indent=2)
        f.write("\n")
    print(f"wrote {len(wt_cases)} cases -> {wt_path}")

    # Bind-VALUE golden, from BIND_SEED (its own seeds — see the module docs).
    bv_cases = []
    for name, panel_id, ctx in BIND_SEED:
        bv_cases.append({
            "name": name,
            "function": "bind_values",
            "args": {"panel": panel_id, "ctx": ctx},
            "expected": bind_values(panels[panel_id], ctx),
        })
    bv_path = os.path.join(ROOT, "test_fixtures", "algorithms", "panel_bind_values.json")
    with open(bv_path, "w", encoding="utf-8", newline="") as f:
        json.dump(bv_cases, f, indent=2)
        f.write("\n")
    rows = sum(len(c["expected"]) for c in bv_cases)
    print(f"wrote {len(bv_cases)} cases ({rows} rows) -> {bv_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
