"""PATH_B_DESIGN B.8 (a child's ``style.position``) and B.9 (a leaf's
``style.size``).

Until 2026-10-12 no layout pass read either key, while the web DOM did (through
CSS). The ``fill_stroke_widget`` template places its five children at absolute
points derived from one ``size`` param, so every port stacked them in a column
104 px tall inside a 60 px box, and the Color panel's next rows overlapped its
mode buttons (flask, live, #363).

Synthetic panels, so each rule is witnessed by a shape the shipped panels may
not take. The shipped cases are pinned by the ``panel_layout.json`` and
``pane_layout.json`` goldens, which Rust and Swift replay, and by the overlap
gate, which no longer excludes Color and Swatches.
"""

import json
import os

from workspace_interpreter.panel_layout import layout_panel

_ROOT = os.path.join(os.path.dirname(__file__), "..", "..")


def _rects(content, avail_w=200):
    return {tuple(r["path"]): r["rect"] for r in layout_panel({"content": content}, avail_w)}


def _btn(**style):
    return {"type": "icon_button", "style": style}


def _at(x, y, node):
    node = dict(node)
    node["style"] = dict(node.get("style") or {}, position={"x": x, "y": y})
    return node


# ── B.9: a leaf's size ───────────────────────────────────────────────

def test_a_leaf_without_a_size_keeps_its_kind_size():
    # The control: the kind table's icon_button is 24 x 24.
    r = _rects({"type": "container", "children": [_btn()]})
    assert (r[(0,)]["w"], r[(0,)]["h"]) == (24, 24)


def test_a_leafs_size_is_its_width_and_height():
    r = _rects({"type": "container", "children": [_btn(size=14.4)]})
    assert (r[(0,)]["w"], r[(0,)]["h"]) == (14, 14)


def test_a_declared_width_and_height_still_apply_after_size():
    r = _rects({"type": "container", "children": [_btn(size=14, width=30, height=9)]})
    assert (r[(0,)]["w"], r[(0,)]["h"]) == (30, 9)


def test_a_size_moves_a_flow_rows_next_cell():
    # A row of two sized buttons: the second starts after the first's SIZE.
    r = _rects({"type": "row", "style": {"gap": 2},
                "children": [_btn(size=11.52), _btn(size=11.52)]})
    assert r[(1,)]["x"] == 11 + 2


# ── B.8: a child's position ──────────────────────────────────────────

def test_a_positioned_child_is_placed_at_its_point_inside_the_padding():
    r = _rects({"type": "container", "style": {"padding": 5},
                "children": [_at(4.32, 15.84, _btn(size=10))]})
    assert (r[(0,)]["x"], r[(0,)]["y"]) == (5 + 4, 5 + 15)


def test_a_positioned_child_takes_no_space_in_a_column():
    r = _rects({"type": "container", "style": {"gap": 3},
                "children": [_at(0, 30, _btn(size=10)), _btn(size=10)]})
    assert r[(1,)]["y"] == 0, "the flow sibling starts at the top, with no gap for the positioned one"


def test_a_positioned_child_takes_no_space_in_a_row():
    r = _rects({"type": "row", "style": {"gap": 3},
                "children": [_at(50, 0, _btn(size=10)), _btn(size=10)]})
    assert r[(1,)]["x"] == 0


def test_positioned_children_may_overlap_each_other():
    # The fill and stroke squares: the second is drawn over the first.
    r = _rects({"type": "container",
                "children": [_at(4, 4, _btn(size=26)), _at(15, 15, _btn(size=26))]})
    assert (r[(0,)]["x"], r[(1,)]["x"]) == (4, 15)
    assert (r[(0,)]["y"], r[(1,)]["y"]) == (4, 15)


def test_the_parents_height_reaches_its_lowest_positioned_child():
    r = _rects({"type": "container", "children": [
        {"type": "container", "children": [_btn(size=10), _at(0, 40, _btn(size=12))]},
        _btn(size=10),
    ]})
    assert r[(0,)]["h"] == 40 + 12
    assert r[(1,)]["y"] == 40 + 12, "the next row starts after the positioned child, not over it"


def test_a_declared_height_still_decides():
    r = _rects({"type": "container", "children": [
        {"type": "container", "style": {"height": 20},
         "children": [_at(0, 40, _btn(size=12))]},
    ]})
    assert r[(0,)]["h"] == 20


def test_a_positioned_fill_leaf_reaches_the_parents_right_edge():
    # Measured at inner_w - x, so a fill leaf ends at the right edge.
    r = _rects({"type": "container", "children": [_at(30, 0, {"type": "separator"})]}, 100)
    assert (r[(0,)]["x"], r[(0,)]["w"]) == (30, 70)


def test_a_rows_natural_width_reaches_its_rightmost_positioned_child():
    # A container in a flow row is sized by its natural width.
    inner = {"type": "container", "children": [_at(30, 0, _btn(size=10))]}
    r = _rects({"type": "row", "children": [inner, _btn(size=10)]}, 400)
    assert r[(1,)]["x"] >= 30 + 10, r


def test_output_is_pre_order_in_child_index_order():
    out = layout_panel({"content": {"type": "container", "children": [
        _btn(size=10), _at(0, 40, {"type": "row", "children": [_btn(size=5)]}), _btn(size=10),
    ]}}, 200)
    assert [r["path"] for r in out] == [[], [0], [1], [1, 0], [2]]


def test_a_position_that_is_not_two_numbers_is_not_honoured():
    r = _rects({"type": "container", "children": [
        _btn(size=10), _at("50%", 7, _btn(size=10)),
    ]})
    assert r[(1,)]["y"] == 10, "laid out in the flow, after its sibling"


# ── The shipped widget: derived from the bundle, never typed ─────────

def test_the_color_panels_fill_stroke_widget_places_every_child_at_its_point():
    ws = json.load(open(os.path.join(_ROOT, "workspace", "workspace.json"), encoding="utf-8"))
    panel = ws["panels"]["color_panel_content"]
    widget_path = None
    for i, row in enumerate(panel["content"]["children"]):
        for j, c in enumerate(row.get("children") or []):
            if isinstance(c, dict) and c.get("_template") == "fill_stroke_widget":
                widget_path, widget = (i, j), c
    assert widget_path is not None, "the Color panel's fill/stroke widget was not found"
    r = {tuple(x["path"]): x["rect"] for x in layout_panel(panel, 228)}
    box = r[widget_path]
    kids = widget["children"]
    assert len(kids) == 5
    for k, c in enumerate(kids):
        pos = c["style"]["position"]
        got = r[widget_path + (k,)]
        assert (got["x"], got["y"]) == (box["x"] + int(pos["x"]), box["y"] + int(pos["y"])), c.get("id")
        assert got["x"] + got["w"] <= box["x"] + box["w"], f"{c.get('id')} past the box's right edge"
        assert got["y"] + got["h"] <= box["y"] + box["h"], f"{c.get('id')} past the box's bottom"
