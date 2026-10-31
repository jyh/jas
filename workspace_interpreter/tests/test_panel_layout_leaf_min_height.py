"""Row 62 (STATUS-flask §703): a LEAF's ``style.min_height`` floors its height,
and ``style.aspect_ratio`` (width ÷ height) sets an undeclared height.

Until 2026-10-31 a leaf read only ``height`` and ``size`` for its height
(B.6 floored containers alone), so the Color Picker's field (``min_width:
180, aspect_ratio: 1, min_height: 180``) and strip (``min_height: 100``) were
laid out 20 tall in every port, and drew squashed on Windows. The web renders
the field 180 × 180 (measured on the deployed picker, 10-31).

The rules: a declared ``height`` (or ``size``) is the height; else an
``aspect_ratio`` gives ``w / r`` rounded half away from zero, from the leaf's
FINAL width (after its floors and the clamp to the space available); else
the kind's height. Then ``min_height`` floors whichever it is.
"""

import json
import os

from workspace_interpreter.panel_layout import layout_panel


def _rect(leaf, avail_w=400):
    rects = layout_panel({"content": {"type": "container", "layout": "column", "children": [leaf]}}, avail_w)
    return next(r["rect"] for r in rects if r["path"] == [0])


def _leaf(**style):
    return {"type": "color_gradient", "style": style}


def test_without_a_min_height_a_leaf_is_its_kind_height():
    # The control: the kind's height (20 for a kind with no row in the table).
    assert _rect(_leaf())["h"] == 20


def test_a_leafs_min_height_floors_its_kind_height():
    assert _rect(_leaf(min_height=100))["h"] == 100


def test_a_leafs_min_height_floors_a_declared_height_and_never_lowers_it():
    assert _rect(_leaf(height=50, min_height=60))["h"] == 60
    assert _rect(_leaf(height=80, min_height=60))["h"] == 80


def test_an_aspect_ratio_sets_an_undeclared_height_from_the_width():
    assert _rect(_leaf(width=120, aspect_ratio=2))["h"] == 60
    assert _rect(_leaf(min_width=180, aspect_ratio=1))["h"] == 180


def test_an_aspect_ratio_rounds_half_away_from_zero():
    # 181 / 2 = 90.5: half away is 91 (Python's round() would say 90).
    assert _rect(_leaf(width=181, aspect_ratio=2))["h"] == 91


def test_a_declared_height_wins_over_an_aspect_ratio():
    assert _rect(_leaf(width=120, aspect_ratio=2, height=40))["h"] == 40


def test_min_height_floors_an_aspect_ratios_height():
    assert _rect(_leaf(width=100, aspect_ratio=2, min_height=60))["h"] == 60


def test_an_aspect_ratio_reads_the_width_after_the_clamp_to_the_space():
    r = _rect(_leaf(min_width=180, aspect_ratio=1), avail_w=150)
    assert (r["w"], r["h"]) == (150, 150)


def test_a_non_positive_or_non_numeric_aspect_ratio_is_ignored():
    for bad in (0, -1, "1", True):
        assert _rect(_leaf(width=120, aspect_ratio=bad))["h"] == 20, bad


def test_the_color_pickers_field_and_strip_from_their_own_yaml():
    """At the object: the shipped picker's field and strip, their expected
    sizes computed from the YAML's own numbers, not typed."""
    path = os.path.join(os.path.dirname(__file__), "..", "..", "workspace", "workspace.json")
    with open(path, encoding="utf-8") as f:
        picker = json.load(f)["dialogs"]["color_picker"]
    rects = layout_panel({"content": picker["content"]}, 720)
    nodes = {}

    def walk(n, path):
        if isinstance(n, dict):
            if n.get("id") in ("cp_gradient", "cp_colorbar"):
                nodes[n["id"]] = (n, path)
            for i, c in enumerate(n.get("children") or []):
                walk(c, path + [i])

    walk(picker["content"], [])
    by_path = {tuple(r["path"]): r["rect"] for r in rects}
    field, field_path = nodes["cp_gradient"]
    fst = field["style"]
    want_w = fst["min_width"]
    want_h = max(int(want_w / fst["aspect_ratio"] + 0.5), fst["min_height"])
    got = by_path[tuple(field_path)]
    assert (got["w"], got["h"]) == (want_w, want_h) == (180, 180), got
    strip, strip_path = nodes["cp_colorbar"]
    got = by_path[tuple(strip_path)]
    assert (got["w"], got["h"]) == (strip["style"]["width"], strip["style"]["min_height"]), got
