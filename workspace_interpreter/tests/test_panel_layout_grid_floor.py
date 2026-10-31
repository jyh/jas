"""STATUS-jas row 68: a ``col`` grid line honours its cells' floors.

A row whose children carry ``col`` spans is planned by ``_grid``, not
``_flow``. Until row 68 its over-subscribed branch shrank every cell in
proportion and ignored ``min_width``, so a floor inside a ``col`` cell could
not hold (Magic Wand's "Stroke Weight" toggle, STATUS-flask 717). It now
shrinks through ``_shrink``, the same rule ``_flow`` uses: a cell whose share
would fall below its floor is frozen there and the rest re-share. With no
floor anywhere ``_shrink`` IS the old proportional rule, remainder order
included, so every plan without a floor is unchanged.
"""

from workspace_interpreter.panel_layout import layout_panel


def _leaf(w, floor=None):
    st = {"width": w}
    if floor is not None:
        st["min_width"] = floor
    return {"type": "color_gradient", "style": st}


def _line(left, right, inner=200, gap=6):
    panel = {"content": {"type": "container", "layout": "row",
                         "style": {"gap": gap},
                         "children": [
                             {"type": "container", "col": 5, "children": [left]},
                             {"type": "container", "col": 7, "children": [right]}]}}
    rects = {tuple(r["path"]): r["rect"] for r in layout_panel(panel, inner, 400, {})}
    return rects[(0,)]["w"], rects[(1,)]["w"]


def test_a_floor_in_a_col_cell_holds_when_the_line_is_over_subscribed():
    # desired 150 + 149 > 194: proportional gives 98 / 96; the left floor is 105.
    left, right = _line(_leaf(150, 105), _leaf(149))
    assert (left, right) == (105, 89), (left, right)


def test_the_floor_freezes_only_the_cell_that_needs_it():
    # The right cell's floor (80) is below its share, so it does not bind.
    left, right = _line(_leaf(150, 105), _leaf(149, 80))
    assert (left, right) == (105, 89), (left, right)


def test_without_floors_the_line_shrinks_in_proportion_as_before():
    # 194 * 150 // 299 = 97, 194 * 149 // 299 = 96, remainder 1 to the first.
    assert _line(_leaf(150), _leaf(149)) == (98, 96)


def test_floors_that_cannot_all_hold_are_dropped():
    # 120 + 100 > 194: every cell shrinks in proportion, as _flow does.
    assert _line(_leaf(150, 120), _leaf(149, 100)) == _line(_leaf(150), _leaf(149))
