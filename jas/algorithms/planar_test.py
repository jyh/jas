"""Planar graph extraction tests. Mirrors the Rust suite at
jas_dioxus/src/algorithms/planar.rs."""

from __future__ import annotations

import pytest

from algorithms.planar import build


AREA_EPS = 1e-6


def closed_square(x, y, side):
    return [
        (x, y),
        (x + side, y),
        (x + side, y + side),
        (x, y + side),
        (x, y),
    ]


def segment(a, b):
    return [a, b]


def total_top_level_area(g):
    return sum(abs(g.face_net_area(f)) for f in g.top_level_faces())


# ----- 1. Two crossing segments -----

def test_two_crossing_segments_have_no_bounded_faces():
    g = build([
        segment((-1.0, 0.0), (1.0, 0.0)),
        segment((0.0, -1.0), (0.0, 1.0)),
    ])
    assert g.face_count() == 0


# ----- 2. Closed square -----

def test_closed_square_is_one_face():
    g = build([closed_square(0.0, 0.0, 10.0)])
    assert g.face_count() == 1
    assert abs(total_top_level_area(g) - 100.0) < AREA_EPS


# ----- 3. Square with one diagonal -----

def test_square_with_one_diagonal():
    g = build([
        closed_square(0.0, 0.0, 10.0),
        segment((0.0, 0.0), (10.0, 10.0)),
    ])
    assert g.face_count() == 2
    assert abs(total_top_level_area(g) - 100.0) < AREA_EPS
    for f in g.top_level_faces():
        assert abs(abs(g.face_net_area(f)) - 50.0) < AREA_EPS


# ----- 4. Square with both diagonals -----

def test_square_with_both_diagonals():
    g = build([
        closed_square(0.0, 0.0, 10.0),
        segment((0.0, 0.0), (10.0, 10.0)),
        segment((10.0, 0.0), (0.0, 10.0)),
    ])
    assert g.face_count() == 4
    assert abs(total_top_level_area(g) - 100.0) < AREA_EPS
    for f in g.top_level_faces():
        assert abs(abs(g.face_net_area(f)) - 25.0) < AREA_EPS


# ----- 5. Two disjoint squares -----

def test_two_disjoint_squares():
    g = build([
        closed_square(0.0, 0.0, 10.0),
        closed_square(20.0, 0.0, 10.0),
    ])
    assert g.face_count() == 2
    assert abs(total_top_level_area(g) - 200.0) < AREA_EPS


# ----- 6. Two squares sharing an edge -----

def test_two_squares_sharing_an_edge():
    g = build([
        closed_square(0.0, 0.0, 10.0),
        closed_square(10.0, 0.0, 10.0),
    ])
    assert g.face_count() == 2
    assert abs(total_top_level_area(g) - 200.0) < AREA_EPS


# ----- 7. T-junction (deferred) -----

@pytest.mark.skip(reason="T-junctions where one polyline's vertex lands on another's interior not yet supported")
def test_t_junction():
    g = build([
        segment((0.0, 0.0), (10.0, 0.0)),
        segment((5.0, 0.0), (5.0, 5.0)),
    ])
    assert g.face_count() == 0


# ----- 8. Concentric squares -----

def test_square_with_inner_square():
    g = build([
        closed_square(0.0, 0.0, 20.0),
        closed_square(5.0, 5.0, 10.0),
    ])
    assert g.face_count() == 2
    top = g.top_level_faces()
    assert len(top) == 1
    outer = top[0]
    assert len(g.faces[outer].holes) == 1
    assert abs(abs(g.face_outer_area(outer)) - 400.0) < AREA_EPS
    assert abs(abs(g.face_net_area(outer)) - 300.0) < AREA_EPS
    inner = next(
        i for i, f in enumerate(g.faces) if f.depth == 2
    )
    assert g.faces[inner].parent == outer
    assert abs(abs(g.face_net_area(inner)) - 100.0) < AREA_EPS


# ----- 9. Hit test on the diagonal-cross square -----

def test_hit_test_diagonal_quadrants():
    g = build([
        closed_square(0.0, 0.0, 10.0),
        segment((0.0, 0.0), (10.0, 10.0)),
        segment((10.0, 0.0), (0.0, 10.0)),
    ])
    samples = [(5.0, 1.0), (9.0, 5.0), (5.0, 9.0), (1.0, 5.0)]
    hits = []
    for s in samples:
        f = g.hit_test(s)
        assert f is not None
        hits.append(f)
    assert len(set(hits)) == 4


# ----- 10. Degenerate inputs -----

def test_empty_input():
    g = build([])
    assert g.face_count() == 0


def test_zero_length_segment():
    g = build([segment((1.0, 1.0), (1.0, 1.0))])
    assert g.face_count() == 0


def test_single_point_polyline():
    g = build([[(3.0, 3.0)]])
    assert g.face_count() == 0


# ----- 11. Square with external tail -----

def test_square_with_external_tail():
    g = build([
        closed_square(0.0, 0.0, 10.0),
        segment((10.0, 10.0), (15.0, 15.0)),
    ])
    assert g.face_count() == 1
    assert abs(total_top_level_area(g) - 100.0) < AREA_EPS


# ----- 12. Square with internal tail -----

def test_square_with_internal_tail():
    g = build([
        closed_square(0.0, 0.0, 10.0),
        segment((0.0, 0.0), (5.0, 5.0)),
    ])
    assert g.face_count() == 1
    assert abs(total_top_level_area(g) - 100.0) < AREA_EPS


# ----- 13. Square with branching tree -----

def test_square_with_internal_tree():
    g = build([
        closed_square(0.0, 0.0, 10.0),
        [(0.0, 0.0), (3.0, 3.0)],
        [(3.0, 3.0), (5.0, 3.0)],
        [(3.0, 3.0), (3.0, 5.0)],
        [(5.0, 3.0), (6.0, 4.0)],
    ])
    assert g.face_count() == 1
    assert abs(total_top_level_area(g) - 100.0) < AREA_EPS


# ----- 14. Isolated open stroke -----

def test_isolated_open_stroke():
    g = build([segment((0.0, 0.0), (5.0, 5.0))])
    assert g.face_count() == 0


# ----- 15. Square with two disjoint holes -----

def test_square_with_two_disjoint_holes():
    g = build([
        closed_square(0.0, 0.0, 30.0),
        closed_square(5.0, 5.0, 5.0),
        closed_square(20.0, 20.0, 5.0),
    ])
    assert g.face_count() == 3
    top = g.top_level_faces()
    assert len(top) == 1
    outer = top[0]
    assert len(g.faces[outer].holes) == 2
    assert abs(abs(g.face_net_area(outer)) - 850.0) < AREA_EPS


# ----- 16. Three-deep nested squares -----

def test_three_deep_nested():
    g = build([
        closed_square(0.0, 0.0, 30.0),
        closed_square(5.0, 5.0, 20.0),
        closed_square(10.0, 10.0, 10.0),
    ])
    assert g.face_count() == 3
    by_depth: dict[int, list[int]] = {}
    for i, f in enumerate(g.faces):
        by_depth.setdefault(f.depth, []).append(i)
    assert len(by_depth.get(1, [])) == 1
    assert len(by_depth.get(2, [])) == 1
    assert len(by_depth.get(3, [])) == 1
    a = by_depth[1][0]
    b = by_depth[2][0]
    c = by_depth[3][0]
    assert g.faces[b].parent == a
    assert g.faces[c].parent == b
    assert abs(abs(g.face_net_area(a)) - 500.0) < AREA_EPS
    assert abs(abs(g.face_net_area(b)) - 300.0) < AREA_EPS
    assert abs(abs(g.face_net_area(c)) - 100.0) < AREA_EPS


# ----- 17. Hit test inside a hole -----

def test_hit_test_in_hole():
    g = build([
        closed_square(0.0, 0.0, 20.0),
        closed_square(5.0, 5.0, 10.0),
    ])
    outer_hit = g.hit_test((1.0, 1.0))
    assert outer_hit is not None
    assert g.faces[outer_hit].depth == 1
    hole_hit = g.hit_test((10.0, 10.0))
    assert hole_hit is not None
    assert g.faces[hole_hit].depth == 2
    assert g.faces[hole_hit].parent == outer_hit


# ----- Deferred / known limitations -----

@pytest.mark.skip(reason="collinear self-overlap not yet supported (mirrors boolean_normalize)")
def test_collinear_overlap():
    pass


@pytest.mark.skip(reason="incremental rebuild not yet supported")
def test_incremental_add_stroke():
    pass
