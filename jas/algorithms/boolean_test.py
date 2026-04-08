"""Boolean ops tests. Mirrors jas_dioxus/src/algorithms/boolean.rs."""

from __future__ import annotations

import math

from algorithms.boolean import (
    boolean_union,
    boolean_intersect,
    boolean_subtract,
    boolean_exclude,
    project_onto_segment,
)
from algorithms import boolean_normalize


# ---------------------------------------------------------------------------
# Region helpers
# ---------------------------------------------------------------------------

EPS = 1e-9


def ring_signed_area(ring):
    n = len(ring)
    if n < 3:
        return 0.0
    s = 0.0
    for i in range(n):
        x1, y1 = ring[i]
        x2, y2 = ring[(i + 1) % n]
        s += x1 * y2 - x2 * y1
    return s / 2.0


def point_in_ring(ring, pt):
    px, py = pt
    n = len(ring)
    if n < 3:
        return False
    inside = False
    j = n - 1
    for i in range(n):
        xi, yi = ring[i]
        xj, yj = ring[j]
        if ((yi > py) != (yj > py)
                and px < (xj - xi) * (py - yi) / (yj - yi) + xi):
            inside = not inside
        j = i
    return inside


def polygon_set_area(ps):
    total = 0.0
    for i, ring in enumerate(ps):
        a = abs(ring_signed_area(ring))
        depth = 0
        if ring:
            pt = ring[0]
            for j, other in enumerate(ps):
                if i != j and point_in_ring(other, pt):
                    depth += 1
        if depth % 2 == 0:
            total += a
        else:
            total -= a
    return total


def point_in_polygon_set(ps, pt):
    return sum(1 for r in ps if point_in_ring(r, pt)) % 2 == 1


def polygon_set_bbox(ps):
    min_x = math.inf
    min_y = math.inf
    max_x = -math.inf
    max_y = -math.inf
    any_pt = False
    for ring in ps:
        for x, y in ring:
            if x < min_x:
                min_x = x
            if y < min_y:
                min_y = y
            if x > max_x:
                max_x = x
            if y > max_y:
                max_y = y
            any_pt = True
    if not any_pt:
        return None
    return (min_x, min_y, max_x - min_x, max_y - min_y)


def approx_eq(a, b):
    return abs(a - b) < EPS


def assert_region(actual, expected_area, *, inside=(), outside=(), bbox=None):
    area = polygon_set_area(actual)
    assert approx_eq(area, expected_area), \
        f"area mismatch: expected {expected_area}, got {area}, rings: {actual}"
    for pt in inside:
        assert point_in_polygon_set(actual, pt), f"point {pt} should be inside {actual}"
    for pt in outside:
        assert not point_in_polygon_set(actual, pt), f"point {pt} should be outside {actual}"
    if bbox is not None and expected_area > EPS:
        act = polygon_set_bbox(actual)
        assert act is not None
        assert all(approx_eq(a, e) for a, e in zip(act, bbox)), \
            f"bbox mismatch: expected {bbox}, got {act}"


def assert_empty(actual):
    area = sum(abs(ring_signed_area(r)) for r in actual)
    assert area < EPS, f"expected empty, got area {area}, rings: {actual}"


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def square_a():
    return [[(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]]


def square_b_overlap():
    return [[(5.0, 5.0), (15.0, 5.0), (15.0, 15.0), (5.0, 15.0)]]


def square_disjoint():
    return [[(20.0, 0.0), (30.0, 0.0), (30.0, 10.0), (20.0, 10.0)]]


def square_inside():
    return [[(3.0, 3.0), (7.0, 3.0), (7.0, 7.0), (3.0, 7.0)]]


def square_edge_touching():
    return [[(10.0, 0.0), (20.0, 0.0), (20.0, 10.0), (10.0, 10.0)]]


def bowtie():
    return [[(0.0, 0.0), (10.0, 10.0), (10.0, 0.0), (0.0, 10.0)]]


# ---------------------------------------------------------------------------
# Trivial cases
# ---------------------------------------------------------------------------


def test_union_disjoint():
    assert_region(boolean_union(square_a(), square_disjoint()), 200.0,
                  inside=[(5, 5), (25, 5)], outside=[(15, 5), (-1, -1)])


def test_intersect_disjoint_empty():
    assert_empty(boolean_intersect(square_a(), square_disjoint()))


def test_subtract_disjoint():
    assert_region(boolean_subtract(square_a(), square_disjoint()), 100.0,
                  inside=[(5, 5)], outside=[(25, 5)],
                  bbox=(0, 0, 10, 10))


def test_exclude_disjoint():
    assert_region(boolean_exclude(square_a(), square_disjoint()), 200.0,
                  inside=[(5, 5), (25, 5)], outside=[(15, 5)])


def test_union_identical():
    assert_region(boolean_union(square_a(), square_a()), 100.0,
                  inside=[(5, 5)], outside=[(11, 11)],
                  bbox=(0, 0, 10, 10))


def test_intersect_identical():
    assert_region(boolean_intersect(square_a(), square_a()), 100.0,
                  inside=[(5, 5)], outside=[(11, 11)],
                  bbox=(0, 0, 10, 10))


def test_subtract_identical_empty():
    assert_empty(boolean_subtract(square_a(), square_a()))


def test_exclude_identical_empty():
    assert_empty(boolean_exclude(square_a(), square_a()))


# ---------------------------------------------------------------------------
# Inner / contained
# ---------------------------------------------------------------------------


def test_union_with_inner():
    assert_region(boolean_union(square_a(), square_inside()), 100.0,
                  inside=[(5, 5), (4, 4)], outside=[(11, 11)],
                  bbox=(0, 0, 10, 10))


def test_intersect_with_inner():
    assert_region(boolean_intersect(square_a(), square_inside()), 16.0,
                  inside=[(5, 5)], outside=[(2, 2), (8, 8)],
                  bbox=(3, 3, 4, 4))


def test_subtract_inner_creates_hole():
    assert_region(boolean_subtract(square_a(), square_inside()), 84.0,
                  inside=[(1, 1), (9, 9), (1, 9), (9, 1)],
                  outside=[(5, 5)],
                  bbox=(0, 0, 10, 10))


# ---------------------------------------------------------------------------
# Overlapping
# ---------------------------------------------------------------------------


def test_union_overlapping():
    assert_region(boolean_union(square_a(), square_b_overlap()), 175.0,
                  inside=[(2, 2), (12, 12), (7, 7)],
                  outside=[(2, 12), (12, 2)],
                  bbox=(0, 0, 15, 15))


def test_intersect_overlapping():
    assert_region(boolean_intersect(square_a(), square_b_overlap()), 25.0,
                  inside=[(7, 7)], outside=[(2, 2), (12, 12)],
                  bbox=(5, 5, 5, 5))


def test_subtract_overlap_l_shape():
    assert_region(boolean_subtract(square_a(), square_b_overlap()), 75.0,
                  inside=[(2, 2), (2, 8), (8, 2)],
                  outside=[(7, 7), (12, 12)],
                  bbox=(0, 0, 10, 10))


def test_exclude_overlapping():
    assert_region(boolean_exclude(square_a(), square_b_overlap()), 150.0,
                  inside=[(2, 2), (12, 12)], outside=[(7, 7)],
                  bbox=(0, 0, 15, 15))


# ---------------------------------------------------------------------------
# Touching
# ---------------------------------------------------------------------------


def test_union_edge_touching():
    assert_region(boolean_union(square_a(), square_edge_touching()), 200.0,
                  inside=[(5, 5), (15, 5)], outside=[(-1, 5), (25, 5)],
                  bbox=(0, 0, 20, 10))


def test_intersect_edge_touching_empty():
    assert_empty(boolean_intersect(square_a(), square_edge_touching()))


# ---------------------------------------------------------------------------
# Empty operands
# ---------------------------------------------------------------------------


def test_union_with_empty():
    assert_region(boolean_union(square_a(), []), 100.0,
                  inside=[(5, 5)], outside=[(15, 5)],
                  bbox=(0, 0, 10, 10))


def test_intersect_with_empty():
    assert_empty(boolean_intersect(square_a(), []))


def test_subtract_empty_from_a():
    assert_region(boolean_subtract(square_a(), []), 100.0,
                  inside=[(5, 5)], bbox=(0, 0, 10, 10))


def test_subtract_a_from_empty():
    assert_empty(boolean_subtract([], square_a()))


# ---------------------------------------------------------------------------
# Property tests
# ---------------------------------------------------------------------------


_PROPERTY_GRID = [(i + 0.5, j + 0.5) for i in range(-2, 19) for j in range(-2, 19)]


def regions_equal(p, q):
    if not approx_eq(polygon_set_area(p), polygon_set_area(q)):
        return False
    for pt in _PROPERTY_GRID:
        if point_in_polygon_set(p, pt) != point_in_polygon_set(q, pt):
            return False
    pb = polygon_set_bbox(p)
    qb = polygon_set_bbox(q)
    if pb is None and qb is None:
        return True
    if pb is None or qb is None:
        return False
    return all(approx_eq(a, b) for a, b in zip(pb, qb))


def test_union_commutative():
    a = square_a()
    b = square_b_overlap()
    assert regions_equal(boolean_union(a, b), boolean_union(b, a))


def test_intersect_commutative():
    a = square_a()
    b = square_b_overlap()
    assert regions_equal(boolean_intersect(a, b), boolean_intersect(b, a))


def test_exclude_commutative():
    a = square_a()
    b = square_b_overlap()
    assert regions_equal(boolean_exclude(a, b), boolean_exclude(b, a))


def test_decomposition():
    a = square_a()
    b = square_b_overlap()
    lhs = boolean_union(boolean_subtract(a, b), boolean_intersect(a, b))
    assert regions_equal(lhs, a)


def test_exclude_involution():
    a = square_a()
    b = square_b_overlap()
    result = boolean_exclude(boolean_exclude(a, b), b)
    assert regions_equal(result, a)


# ---------------------------------------------------------------------------
# Associativity
# ---------------------------------------------------------------------------


def venn_a():
    return [[(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]]


def venn_b():
    return [[(6.0, 0.0), (16.0, 0.0), (16.0, 10.0), (6.0, 10.0)]]


def venn_c():
    return [[(3.0, 6.0), (13.0, 6.0), (13.0, 16.0), (3.0, 16.0)]]


def test_union_associative():
    lhs = boolean_union(boolean_union(venn_a(), venn_b()), venn_c())
    rhs = boolean_union(venn_a(), boolean_union(venn_b(), venn_c()))
    assert regions_equal(lhs, rhs)


def test_intersect_associative():
    lhs = boolean_intersect(boolean_intersect(venn_a(), venn_b()), venn_c())
    rhs = boolean_intersect(venn_a(), boolean_intersect(venn_b(), venn_c()))
    assert regions_equal(lhs, rhs)


def test_exclude_associative():
    lhs = boolean_exclude(boolean_exclude(venn_a(), venn_b()), venn_c())
    rhs = boolean_exclude(venn_a(), boolean_exclude(venn_b(), venn_c()))
    assert regions_equal(lhs, rhs)


# ---------------------------------------------------------------------------
# Shared-edge regression
# ---------------------------------------------------------------------------


def test_shared_edges_all_ops():
    a = [[(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]]
    b = [[(5.0, 0.0), (15.0, 0.0), (15.0, 10.0), (5.0, 10.0)]]
    assert approx_eq(polygon_set_area(boolean_union(a, b)), 150.0)
    assert approx_eq(polygon_set_area(boolean_intersect(a, b)), 50.0)
    assert approx_eq(polygon_set_area(boolean_subtract(a, b)), 50.0)
    assert approx_eq(polygon_set_area(boolean_subtract(b, a)), 50.0)
    assert approx_eq(polygon_set_area(boolean_exclude(a, b)), 100.0)


# ---------------------------------------------------------------------------
# Self-intersecting bowtie
# ---------------------------------------------------------------------------


def test_union_bowtie_with_empty():
    assert approx_eq(polygon_set_area(boolean_union(bowtie(), [])), 50.0)


def test_union_bowtie_with_covering_rect():
    rect = [[(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]]
    assert approx_eq(polygon_set_area(boolean_union(bowtie(), rect)), 100.0)


def test_intersect_bowtie_bottom_half():
    rect = [[(0.0, 0.0), (10.0, 0.0), (10.0, 5.0), (0.0, 5.0)]]
    result = boolean_intersect(bowtie(), rect)
    assert approx_eq(polygon_set_area(result), 25.0)


def test_subtract_rect_from_bowtie():
    rect = [[(0.0, 0.0), (10.0, 0.0), (10.0, 5.0), (0.0, 5.0)]]
    result = boolean_subtract(bowtie(), rect)
    assert approx_eq(polygon_set_area(result), 25.0)


# ---------------------------------------------------------------------------
# Perturbation
# ---------------------------------------------------------------------------


def _perturbed(delta):
    a = [[(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]]
    b = [[(5.0, delta), (15.0, delta), (15.0, 10.0 + delta), (5.0, 10.0 + delta)]]
    return a, b


def _check_perturbation(delta):
    a, b = _perturbed(delta)
    u_area = polygon_set_area(boolean_union(a, b))
    s_area = polygon_set_area(boolean_subtract(a, b))
    assert abs(u_area - 150.0) < 0.1, f"delta={delta}: union area {u_area}"
    assert abs(s_area - 50.0) < 0.1, f"delta={delta}: subtract area {s_area}"


def test_perturb_1e_minus_15():
    _check_perturbation(1e-15)


def test_perturb_1e_minus_10():
    _check_perturbation(1e-10)


def test_perturb_1e_minus_8():
    _check_perturbation(1e-8)


def test_perturb_1e_minus_3():
    _check_perturbation(1e-3)


# ---------------------------------------------------------------------------
# project_onto_segment unit tests
# ---------------------------------------------------------------------------


def test_project_horizontal():
    assert project_onto_segment((0, 0), (10, 0), (5, 1e-11)) == (5, 0)


def test_project_vertical():
    assert project_onto_segment((5, 0), (5, 10), (5 + 1e-11, 7)) == (5, 7)


def test_project_clamps_low():
    assert project_onto_segment((0, 0), (10, 0), (-5, 0)) == (0, 0)


def test_project_clamps_high():
    assert project_onto_segment((0, 0), (10, 0), (15, 0)) == (10, 0)


def test_project_degenerate():
    assert project_onto_segment((5, 5), (5, 5), (100, 100)) == (5, 5)


# ---------------------------------------------------------------------------
# Normalizer tests
# ---------------------------------------------------------------------------


def total_area(ps):
    return sum(abs(ring_signed_area(r)) for r in ps)


def test_normalize_simple_square_passthrough():
    input_ps = [[(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]]
    out = boolean_normalize.normalize(input_ps)
    assert len(out) == 1
    assert approx_eq(total_area(out), 100.0)


def test_normalize_empty_yields_empty():
    assert boolean_normalize.normalize([]) == []


def test_normalize_consecutive_duplicates():
    input_ps = [[
        (0.0, 0.0), (0.0, 0.0), (10.0, 0.0), (10.0, 10.0),
        (10.0, 10.0), (0.0, 10.0)
    ]]
    out = boolean_normalize.normalize(input_ps)
    assert len(out) == 1
    assert len(out[0]) == 4
    assert approx_eq(total_area(out), 100.0)


def test_normalize_figure_eight():
    input_ps = [[(0.0, 0.0), (10.0, 10.0), (10.0, 0.0), (0.0, 10.0)]]
    out = boolean_normalize.normalize(input_ps)
    assert len(out) == 2
    assert approx_eq(total_area(out), 50.0)
    for r in out:
        assert len(r) == 3
