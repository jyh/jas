"""STATUS-flask 705 (1b) and (2), ruled 2026-10-31: two CSS defaults in a ROW.

(1b) A row never shrinks a cell below the ``min_width`` it declares. CSS
``min-width`` beats ``flex-shrink``, and a flex item's automatic minimum is
its content's, so the floor carries up through a container: a column holding
a leaf with ``min_width: 180`` is never shrunk below 180. When the floors
alone do not fit the row, the row shrinks as it did before.

(2) ``align-items: stretch``. In a row that declares no ``alignment`` (or
``alignment: stretch``), a LEAF with no declared ``height``, ``size`` or
``aspect_ratio`` takes the row's inner height, floored by its ``min_height``.
The row's inner height is its declared height less its padding, else its
tallest child. A row that declares another alignment centres as before.

The Color Picker is the case that raised both: Windows planned its field
135 wide and its strip 100 tall, where the web draws 180 x 180 and 32 x 180.
"""

import json
import pathlib

from workspace_interpreter.panel_layout import layout_panel


def _row(children, avail_w=400, **style):
    content = {"type": "container", "layout": "row", "style": style, "children": children}
    rects = layout_panel({"content": content}, avail_w)
    return {tuple(r["path"]): r["rect"] for r in rects}


def _leaf(**style):
    return {"type": "color_gradient", "style": style}


def _w(rects, *path):
    return rects[path]["w"]


# (1b) the floor ---------------------------------------------------------

def test_an_over_subscribed_row_without_floors_shrinks_every_cell_in_proportion():
    # The control: today's shrink, unchanged.
    r = _row([_leaf(width=100), _leaf(width=300)], avail_w=200)
    assert (_w(r, 0), _w(r, 1)) == (50, 150)


def test_a_row_never_shrinks_a_leaf_below_its_min_width():
    r = _row([_leaf(width=100, min_width=90), _leaf(width=300)], avail_w=200)
    assert (_w(r, 0), _w(r, 1)) == (90, 110)


def test_the_other_cells_share_what_is_left_in_proportion():
    r = _row([_leaf(min_width=100), _leaf(width=100), _leaf(width=300)], avail_w=300)
    assert (_w(r, 0), _w(r, 1), _w(r, 2)) == (100, 50, 150)


def test_the_floor_carries_up_through_a_container():
    col = {"type": "container", "layout": "column", "children": [_leaf(width=100, min_width=90)]}
    r = _row([col, _leaf(width=300)], avail_w=200)
    assert (_w(r, 0), _w(r, 0, 0), _w(r, 1)) == (90, 90, 110)


def test_a_nested_rows_floor_is_the_sum_of_its_cells_floors_and_gaps():
    inner = {"type": "container", "layout": "row", "style": {"gap": 4},
             "children": [_leaf(min_width=60), _leaf(min_width=30), _leaf(width=50)]}
    r = _row([inner, _leaf(width=400)], avail_w=200)
    # 60 + 30 + 0, and two gaps of 4: the floorless cell shrinks to 0, its gap stays.
    assert _w(r, 0) == 98
    assert (_w(r, 0, 0), _w(r, 0, 1), _w(r, 0, 2)) == (60, 30, 0)


def test_when_the_floors_do_not_fit_the_row_shrinks_as_before():
    r = _row([_leaf(width=150, min_width=150), _leaf(width=150, min_width=150)], avail_w=200)
    assert (_w(r, 0), _w(r, 1)) == (100, 100)


def test_a_row_that_fits_is_unchanged_by_a_floor():
    r = _row([_leaf(width=100, min_width=90), _leaf(width=50)], avail_w=400)
    assert (_w(r, 0), _w(r, 1)) == (100, 50)


# (2) the stretch ---------------------------------------------------------

def _h(rects, *path):
    return rects[path]["h"]


def test_a_heightless_leaf_takes_the_rows_height():
    r = _row([_leaf(width=10, height=60), _leaf(width=10)])
    assert (_h(r, 1), r[(1,)]["y"]) == (60, 0)


def test_a_row_that_declares_another_alignment_centres_as_before():
    # The control.
    r = _row([_leaf(width=10, height=60), _leaf(width=10)], alignment="center")
    assert (_h(r, 1), r[(1,)]["y"]) == (20, 20)


def test_alignment_stretch_is_the_default_spelled_out():
    r = _row([_leaf(width=10, height=60), _leaf(width=10)], alignment="stretch")
    assert _h(r, 1) == 60


def test_a_declared_height_size_or_aspect_ratio_is_not_stretched():
    r = _row([_leaf(width=10, height=60), _leaf(width=10, height=30),
              {"type": "color_swatch", "style": {"size": 16}},
              _leaf(width=40, aspect_ratio=2)])
    assert (_h(r, 1), _h(r, 2), _h(r, 3)) == (30, 16, 20)


def test_a_container_child_is_not_stretched():
    col = {"type": "container", "layout": "column", "children": [_leaf(width=10)]}
    r = _row([_leaf(width=10, height=60), col])
    assert _h(r, 1) == 20


def test_the_rows_declared_height_less_its_padding_is_the_inner_height():
    r = _row([_leaf(width=10)], height=50, padding="5 0 5 0")
    assert _h(r, 0) == 40


def test_a_stretched_leaf_is_floored_by_its_min_height():
    r = _row([_leaf(width=10, min_height=70)], height=50)
    assert _h(r, 0) == 70


# At the object -----------------------------------------------------------

def _picker_plan():
    """The shipped picker planned at its declared width: ``{id: (node,
    rect)}`` for the field and the strip."""
    path = pathlib.Path(__file__).resolve().parents[2] / "workspace" / "workspace.json"
    picker = json.loads(path.read_text(encoding="utf-8"))["dialogs"]["color_picker"]
    nodes = {}

    def walk(n, p):
        if isinstance(n, dict):
            if n.get("id") in ("cp_gradient", "cp_colorbar"):
                nodes[n["id"]] = (n, tuple(p))
            for i, c in enumerate(n.get("children") or []):
                walk(c, p + [i])

    walk(picker["content"], [])
    rects = {tuple(r["path"]): r["rect"]
             for r in layout_panel({"content": picker["content"]}, picker["width"])}
    return {k: (n, rects[p]) for k, (n, p) in nodes.items()}


def test_the_color_pickers_field_is_its_min_width_square_and_the_strip_its_height():
    """As the web draws them (field 180 x 180, strip 180 tall, measured
    10-31); the numbers are read from the YAML, not typed."""
    plan = _picker_plan()
    field, fr = plan["cp_gradient"]
    _strip, sr = plan["cp_colorbar"]
    side = field["style"]["min_width"]
    assert (fr["w"], fr["h"]) == (side, side), fr
    assert sr["h"] == fr["h"], sr


def test_the_color_pickers_strip_keeps_its_width_at_the_declared_width():
    """The strip declares ``min_width`` equal to its ``width`` (32), so the
    over-subscribed main row cannot take it below what the web draws (32 x
    180, measured 10-31; on the web the row is not over-subscribed, and
    ``min-width: 32px`` moves nothing there, measured)."""
    plan = _picker_plan()
    strip, sr = plan["cp_colorbar"]
    assert strip["style"].get("min_width") == strip["style"]["width"], strip["style"]
    assert sr["w"] == strip["style"]["width"], sr
