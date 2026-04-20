"""Tests for geometry.live: element_to_polygon_set, apply_operation,
bounds_of_polygon_set, and CompoundShape.evaluate/bounds.

Mirrors the jas_dioxus live.rs tests for cross-language parity.
"""

def _rect_at(x, y, w=10.0, h=10.0):
    from geometry.element import Rect
    return Rect(x=x, y=y, width=w, height=h, rx=0.0, ry=0.0)


def _bbox(ring):
    xs = [p[0] for p in ring]
    ys = [p[1] for p in ring]
    return (min(xs), min(ys), max(xs), max(ys))


def test_element_to_polygon_set_rect():
    from geometry.live import DEFAULT_PRECISION, element_to_polygon_set
    ps = element_to_polygon_set(_rect_at(0, 0), DEFAULT_PRECISION)
    assert len(ps) == 1
    assert ps[0] == [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]


def test_compound_shape_union_of_two_rects():
    from geometry.element import CompoundOperation, CompoundShape
    from geometry.live import DEFAULT_PRECISION
    cs = CompoundShape(
        operation=CompoundOperation.UNION,
        operands=(_rect_at(0, 0), _rect_at(5, 0)),
    )
    polygons = cs.evaluate(DEFAULT_PRECISION)
    assert len(polygons) == 1
    min_x, min_y, max_x, max_y = _bbox(polygons[0])
    assert abs(min_x - 0.0) < 1e-6
    assert abs(max_x - 15.0) < 1e-6
    assert abs(min_y - 0.0) < 1e-6
    assert abs(max_y - 10.0) < 1e-6


def test_compound_shape_intersection():
    from geometry.element import CompoundOperation, CompoundShape
    from geometry.live import DEFAULT_PRECISION
    cs = CompoundShape(
        operation=CompoundOperation.INTERSECTION,
        operands=(_rect_at(0, 0), _rect_at(5, 0)),
    )
    polygons = cs.evaluate(DEFAULT_PRECISION)
    assert len(polygons) == 1
    min_x, _, max_x, _ = _bbox(polygons[0])
    assert abs(min_x - 5.0) < 1e-6
    assert abs(max_x - 10.0) < 1e-6


def test_compound_shape_exclude_is_symmetric_difference():
    from geometry.element import CompoundOperation, CompoundShape
    from geometry.live import DEFAULT_PRECISION
    cs = CompoundShape(
        operation=CompoundOperation.EXCLUDE,
        operands=(_rect_at(0, 0), _rect_at(5, 0)),
    )
    polygons = cs.evaluate(DEFAULT_PRECISION)
    assert len(polygons) == 2  # two disjoint strips


def test_compound_shape_subtract_front():
    from geometry.element import CompoundOperation, CompoundShape
    from geometry.live import DEFAULT_PRECISION
    cs = CompoundShape(
        operation=CompoundOperation.SUBTRACT_FRONT,
        operands=(_rect_at(0, 0), _rect_at(5, 0)),
    )
    polygons = cs.evaluate(DEFAULT_PRECISION)
    assert len(polygons) == 1
    min_x, _, max_x, _ = _bbox(polygons[0])
    assert abs(min_x - 0.0) < 1e-6
    assert abs(max_x - 5.0) < 1e-6


def test_compound_shape_bounds_reflects_evaluation():
    from geometry.element import CompoundOperation, CompoundShape
    cs = CompoundShape(
        operation=CompoundOperation.UNION,
        operands=(_rect_at(0, 0), _rect_at(5, 0)),
    )
    bx, by, bw, bh = cs.bounds()
    assert abs(bx - 0.0) < 1e-6
    assert abs(by - 0.0) < 1e-6
    assert abs(bw - 15.0) < 1e-6
    assert abs(bh - 10.0) < 1e-6


def test_empty_compound_has_empty_bounds():
    from geometry.element import CompoundOperation, CompoundShape
    cs = CompoundShape(operation=CompoundOperation.UNION, operands=())
    assert cs.bounds() == (0.0, 0.0, 0.0, 0.0)


def test_path_flattens_into_polygon_set():
    from geometry.element import ClosePath, LineTo, MoveTo, Path
    from geometry.live import DEFAULT_PRECISION, element_to_polygon_set
    p = Path(d=(
        MoveTo(0.0, 0.0),
        LineTo(10.0, 0.0),
        LineTo(10.0, 10.0),
        LineTo(0.0, 10.0),
        ClosePath(),
    ))
    ps = element_to_polygon_set(p, DEFAULT_PRECISION)
    assert len(ps) == 1
    min_x, min_y, max_x, max_y = _bbox(ps[0])
    assert abs(min_x - 0.0) < 1e-6
    assert abs(max_x - 10.0) < 1e-6


def test_expand_produces_polygon_per_ring():
    from geometry.element import (
        Color,
        CompoundOperation,
        CompoundShape,
        Fill,
        Polygon,
    )
    from geometry.live import DEFAULT_PRECISION
    red = Fill(color=Color.rgb(1.0, 0.0, 0.0))
    cs = CompoundShape(
        operation=CompoundOperation.EXCLUDE,
        operands=(_rect_at(0, 0), _rect_at(5, 0)),
        fill=red,
    )
    expanded = cs.expand(DEFAULT_PRECISION)
    # XOR of two overlapping rects → 2 non-overlapping strips → 2 polygons
    assert len(expanded) == 2
    for poly in expanded:
        assert isinstance(poly, Polygon)
        assert poly.fill == red


def test_release_returns_operands_verbatim():
    from geometry.element import CompoundOperation, CompoundShape
    r1 = _rect_at(0, 0)
    r2 = _rect_at(5, 0)
    cs = CompoundShape(
        operation=CompoundOperation.UNION,
        operands=(r1, r2),
    )
    released = cs.release()
    assert released == (r1, r2)


def test_multi_subpath_path_yields_multi_ring():
    from geometry.element import ClosePath, LineTo, MoveTo, Path
    from geometry.live import DEFAULT_PRECISION, element_to_polygon_set
    p = Path(d=(
        MoveTo(0.0, 0.0), LineTo(10.0, 0.0), LineTo(10.0, 10.0),
        LineTo(0.0, 10.0), ClosePath(),
        MoveTo(20.0, 0.0), LineTo(30.0, 0.0), LineTo(30.0, 10.0),
        LineTo(20.0, 10.0), ClosePath(),
    ))
    ps = element_to_polygon_set(p, DEFAULT_PRECISION)
    assert len(ps) == 2
