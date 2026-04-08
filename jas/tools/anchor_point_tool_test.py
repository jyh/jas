"""Anchor Point (Convert) tool tests.

Mirrors jas_dioxus/src/tools/anchor_point_tool.rs `mod tests`. The
meaningful coverage is in the geometry helpers
(convert_corner_to_smooth / convert_smooth_to_corner /
move_path_handle_independent / is_smooth_point), which the tool
sequences.
"""

from __future__ import annotations

from geometry.element import (
    CurveTo, LineTo, MoveTo, Path,
    convert_corner_to_smooth, convert_smooth_to_corner,
    is_smooth_point, move_path_handle_independent,
)


def make_line_path() -> Path:
    return Path(d=(
        MoveTo(0.0, 0.0),
        LineTo(50.0, 0.0),
        LineTo(100.0, 0.0),
    ))


def make_smooth_path() -> Path:
    return Path(d=(
        MoveTo(0.0, 0.0),
        CurveTo(10.0, 20.0, 40.0, 20.0, 50.0, 0.0),
        CurveTo(60.0, -20.0, 90.0, -20.0, 100.0, 0.0),
    ))


def approx_eq(a: float, b: float) -> bool:
    return abs(a - b) < 0.01


def test_corner_point_is_not_smooth():
    pe = make_line_path()
    assert not is_smooth_point(pe.d, 0)
    assert not is_smooth_point(pe.d, 1)
    assert not is_smooth_point(pe.d, 2)


def test_smooth_point_is_smooth():
    pe = make_smooth_path()
    assert is_smooth_point(pe.d, 1)


def test_convert_corner_to_smooth_creates_handles():
    pe = make_line_path()
    result = convert_corner_to_smooth(pe, 1, 50.0, 30.0)
    assert isinstance(result.d[1], CurveTo)
    # Outgoing handle on the next segment is at (50, 30).
    nc = result.d[2]
    assert isinstance(nc, CurveTo)
    assert approx_eq(nc.x1, 50.0)
    assert approx_eq(nc.y1, 30.0)
    # Incoming handle on this segment is reflected: (50, -30).
    cur = result.d[1]
    assert isinstance(cur, CurveTo)
    assert approx_eq(cur.x2, 50.0)
    assert approx_eq(cur.y2, -30.0)


def test_convert_first_anchor_corner_to_smooth():
    pe = make_line_path()
    result = convert_corner_to_smooth(pe, 0, 10.0, 20.0)
    nc = result.d[1]
    assert isinstance(nc, CurveTo)
    assert approx_eq(nc.x1, 10.0)
    assert approx_eq(nc.y1, 20.0)


def test_convert_last_anchor_corner_to_smooth():
    pe = make_line_path()
    result = convert_corner_to_smooth(pe, 2, 100.0, 30.0)
    cur = result.d[2]
    assert isinstance(cur, CurveTo)
    # Reflected of (100, 30) through (100, 0) = (100, -30).
    assert approx_eq(cur.x2, 100.0)
    assert approx_eq(cur.y2, -30.0)
    assert approx_eq(cur.x, 100.0)
    assert approx_eq(cur.y, 0.0)


def test_convert_smooth_to_corner_collapses_handles():
    pe = make_smooth_path()
    result = convert_smooth_to_corner(pe, 1)
    assert not is_smooth_point(result.d, 1)
    cur = result.d[1]
    assert isinstance(cur, CurveTo)
    assert approx_eq(cur.x2, cur.x)
    assert approx_eq(cur.y2, cur.y)
    nc = result.d[2]
    assert isinstance(nc, CurveTo)
    assert approx_eq(nc.x1, 50.0)
    assert approx_eq(nc.y1, 0.0)


def test_independent_handle_move_does_not_reflect():
    pe = make_smooth_path()
    result = move_path_handle_independent(pe, 1, "out", 10.0, 5.0)
    nc = result.d[2]
    assert isinstance(nc, CurveTo)
    assert approx_eq(nc.x1, 70.0)        # 60 + 10
    assert approx_eq(nc.y1, -15.0)       # -20 + 5
    # Incoming handle on cmd[1] is unchanged.
    cur = result.d[1]
    assert isinstance(cur, CurveTo)
    assert approx_eq(cur.x2, 40.0)
    assert approx_eq(cur.y2, 20.0)
