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


# ── ReferenceElem (REFERENCE_GRAPH.md Phase 1a) ─────────────────
# Mirror the jas_dioxus live.rs reference tests for cross-language parity.

class _MapResolver:
    """A test resolver backed by an id→element dict."""
    def __init__(self, mapping):
        self._mapping = mapping

    def resolve(self, ref):
        return self._mapping.get(ref)


def test_reference_evaluates_to_target_geometry():
    from geometry.element import ReferenceElem
    from geometry.live import DEFAULT_PRECISION
    resolver = _MapResolver({"r1": _rect_at(0, 0)})
    reference = ReferenceElem(target="r1")
    visiting = set()
    ps = reference.evaluate_with(DEFAULT_PRECISION, resolver, visiting)
    assert len(ps) == 1
    min_x, _, max_x, _ = _bbox(ps[0])
    assert abs(min_x - 0.0) < 1e-6
    assert abs(max_x - 10.0) < 1e-6
    # The cycle-guard set is left clean after a successful resolve.
    assert visiting == set()


def test_dangling_reference_evaluates_empty():
    from geometry.element import NullResolver, ReferenceElem
    from geometry.live import DEFAULT_PRECISION
    reference = ReferenceElem(target="missing")
    ps = reference.evaluate_with(DEFAULT_PRECISION, NullResolver(), set())
    assert ps == []  # dangling reference evaluates empty, never errors


def test_reference_cycle_breaks_to_empty():
    from geometry.element import Element, ReferenceElem
    from geometry.live import DEFAULT_PRECISION

    # Resolver where id "a" resolves to a reference back to "a" — a
    # self-cycle. The threaded visited-set must break it.
    class _CycleResolver:
        def resolve(self, ref):
            if ref == "a":
                return ReferenceElem(target="a")
            return None

    reference = ReferenceElem(target="a")
    visiting = set()
    ps = reference.evaluate_with(DEFAULT_PRECISION, _CycleResolver(), visiting)
    assert ps == []  # cycle breaks to empty, no infinite recursion
    assert visiting == set()  # cycle-guard set restored after evaluation


def test_reference_reports_its_target_as_dependency():
    from geometry.element import ReferenceElem
    reference = ReferenceElem(target="t")
    assert reference.dependencies() == ["t"]


def test_compound_dependencies_default_empty():
    from geometry.element import CompoundOperation, CompoundShape
    cs = CompoundShape(operation=CompoundOperation.UNION, operands=())
    assert cs.dependencies() == []


def test_element_to_polygon_set_resolves_reference():
    """A reference embedded in element_to_polygon_set_with resolves
    through the supplied resolver."""
    from geometry.element import ReferenceElem
    from geometry.live import DEFAULT_PRECISION, element_to_polygon_set_with
    resolver = _MapResolver({"r1": _rect_at(0, 0)})
    reference = ReferenceElem(target="r1")
    ps = element_to_polygon_set_with(reference, DEFAULT_PRECISION, resolver, set())
    assert len(ps) == 1
    min_x, _, max_x, _ = _bbox(ps[0])
    assert abs(min_x - 0.0) < 1e-6
    assert abs(max_x - 10.0) < 1e-6


def test_reference_via_null_resolver_is_dangling():
    """The 2-arg element_to_polygon_set wrapper uses a NullResolver, so a
    reference resolves to empty (existing call sites stay safe)."""
    from geometry.element import ReferenceElem
    from geometry.live import DEFAULT_PRECISION, element_to_polygon_set
    ps = element_to_polygon_set(ReferenceElem(target="r1"), DEFAULT_PRECISION)
    assert ps == []
