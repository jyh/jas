"""PATH_B_DESIGN B.7: the 2-D ``type: grid`` (``cols: C``, ``gap: G``, a
``grid: {row, col}`` per child) is laid out by the shared pass. Until
2026-10-10 it was neither a measured container nor a drawn leaf, so a grid's
children vanished from every port's rects -- the toolbar's thirteen tool
buttons among them.

The rule, all integer: the cell width is ``(inner_w - G*(C-1)) // C``; a cell
at column ``c`` starts at ``c * (cw + G)``; a row is as tall as its tallest
child, and rows are ``G`` apart. A child without ``grid`` takes the next cell
in reading order. Each child is measured in its cell's width, so a fixed-size
leaf keeps its size and a fill leaf takes the cell.
"""

from workspace_interpreter.panel_layout import layout_panel


def _rects(content, avail_w=72):
    return {tuple(r["path"]): r["rect"] for r in layout_panel({"content": content}, avail_w)}


def _btn(row=None, col=None):
    node = {"type": "icon_button", "icon": "x"}
    if row is not None:
        node["grid"] = {"row": row, "col": col}
    return node


def _grid(children, cols=2, gap=2, style=None):
    node = {"type": "grid", "cols": cols, "gap": gap, "children": children}
    if style is not None:
        node["style"] = style
    return node


def test_a_grids_children_are_laid_out():
    r = _rects(_grid([_btn(0, 0), _btn(0, 1)]))
    assert (0,) in r and (1,) in r, r


def test_cells_are_columns_of_the_inner_width_gap_apart():
    # inner 72: cw = (72 - 2) // 2 = 35; col 1 starts at 35 + 2 = 37.
    r = _rects(_grid([_btn(0, 0), _btn(0, 1)]))
    assert (r[(0,)]["x"], r[(1,)]["x"]) == (0, 37)
    assert r[(0,)]["y"] == r[(1,)]["y"] == 0


def test_a_fixed_size_leaf_keeps_its_size_in_its_cell():
    r = _rects(_grid([_btn(0, 0)]))
    assert (r[(0,)]["w"], r[(0,)]["h"]) == (24, 24)


def test_rows_are_the_tallest_child_tall_and_gap_apart():
    tall = {"type": "icon_button", "icon": "x", "style": {"height": 30}, "grid": {"row": 0, "col": 1}}
    r = _rects(_grid([_btn(0, 0), tall, _btn(1, 0)]))
    assert r[(2,)]["y"] == 30 + 2


def test_a_child_without_a_cell_takes_the_next_in_reading_order():
    r = _rects(_grid([_btn(), _btn(), _btn()]))
    assert (r[(0,)]["x"], r[(0,)]["y"]) == (0, 0)
    assert (r[(1,)]["x"], r[(1,)]["y"]) == (37, 0)
    assert (r[(2,)]["x"], r[(2,)]["y"]) == (0, 24 + 2)


def test_the_grid_is_as_tall_as_its_rows_plus_padding():
    r = _rects(_grid([_btn(0, 0), _btn(1, 1)], style={"padding": 4}))
    # inner 64: two rows of 24, one gap of 2, padding 4 + 4.
    assert r[()]["h"] == 24 + 2 + 24 + 8
    assert r[(1,)]["x"] == 4 + (64 - 2) // 2 + 2


def test_a_hidden_child_takes_no_cell():
    hidden = {"type": "icon_button", "icon": "x", "visible": False}
    r = _rects(_grid([hidden, _btn()]))
    assert (1,) in r and (0,) not in r
    assert (r[(1,)]["x"], r[(1,)]["y"]) == (0, 0)


def test_a_row_number_no_child_uses_takes_no_space():
    # Rows 0 and 2: row 2 sits directly below row 0, one gap down.
    r = _rects(_grid([_btn(0, 0), _btn(2, 0)]))
    assert r[(1,)]["y"] == 24 + 2


def test_a_float_cell_falls_back_to_reading_order():
    # `{row: 1.0, col: 1.0}` is not a JSON integer cell; the child takes the
    # next cell after the previous child's (0, 0), which is (0, 1).
    floaty = {"type": "icon_button", "icon": "x", "grid": {"row": 1.0, "col": 1.0}}
    r = _rects(_grid([_btn(0, 0), floaty]))
    assert (r[(1,)]["x"], r[(1,)]["y"]) == (37, 0)
