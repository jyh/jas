"""Hit test primitives. Mirrors jas_dioxus/src/algorithms/hit_test.rs."""

from __future__ import annotations

from algorithms.hit_test import (
    point_in_rect,
    segments_intersect,
    segment_intersects_rect,
    rects_intersect,
    element_intersects_rect,
)
from geometry.element import Color, Line, Rect, Stroke


# ---- point_in_rect ----


def test_point_in_rect_interior():
    assert point_in_rect(5, 5, 0, 0, 10, 10)


def test_point_in_rect_outside():
    assert not point_in_rect(15, 5, 0, 0, 10, 10)
    assert not point_in_rect(-1, 5, 0, 0, 10, 10)
    assert not point_in_rect(5, 15, 0, 0, 10, 10)
    assert not point_in_rect(5, -1, 0, 0, 10, 10)


def test_point_in_rect_on_edge():
    assert point_in_rect(0, 5, 0, 0, 10, 10)
    assert point_in_rect(10, 5, 0, 0, 10, 10)
    assert point_in_rect(5, 0, 0, 0, 10, 10)
    assert point_in_rect(5, 10, 0, 0, 10, 10)


def test_point_in_rect_on_corner():
    assert point_in_rect(0, 0, 0, 0, 10, 10)
    assert point_in_rect(10, 10, 0, 0, 10, 10)


# ---- segments_intersect ----


def test_segments_intersect_crossing():
    assert segments_intersect(0, 0, 10, 10, 0, 10, 10, 0)


def test_segments_intersect_parallel_no():
    assert not segments_intersect(0, 0, 10, 0, 0, 1, 10, 1)


def test_segments_intersect_separate():
    assert not segments_intersect(0, 0, 1, 1, 5, 5, 6, 6)


def test_segments_intersect_touching_at_endpoint():
    assert segments_intersect(0, 0, 5, 5, 5, 5, 10, 10)


def test_segments_intersect_t_intersection():
    assert segments_intersect(0, 5, 10, 5, 5, 5, 5, 0)


# ---- segment_intersects_rect ----


def test_segment_inside_rect():
    assert segment_intersects_rect(2, 2, 8, 8, 0, 0, 10, 10)


def test_segment_outside_rect():
    assert not segment_intersects_rect(20, 0, 30, 0, 0, 0, 10, 10)


def test_segment_crosses_rect():
    assert segment_intersects_rect(-5, 5, 15, 5, 0, 0, 10, 10)


def test_segment_one_endpoint_inside():
    assert segment_intersects_rect(5, 5, 20, 20, 0, 0, 10, 10)


def test_segment_endpoint_on_edge():
    assert segment_intersects_rect(10, 5, 20, 5, 0, 0, 10, 10)


# ---- rects_intersect ----


def test_rects_intersect_overlapping():
    assert rects_intersect(0, 0, 10, 10, 5, 5, 10, 10)


def test_rects_intersect_separate():
    assert not rects_intersect(0, 0, 10, 10, 20, 0, 10, 10)


def test_rects_intersect_contained():
    assert rects_intersect(0, 0, 100, 100, 25, 25, 50, 50)


def test_rects_intersect_edge_touching():
    assert not rects_intersect(0, 0, 10, 10, 10, 0, 10, 10)


def test_rects_intersect_corner_touching():
    assert not rects_intersect(0, 0, 10, 10, 10, 10, 10, 10)


def test_rects_intersect_identical():
    assert rects_intersect(0, 0, 10, 10, 0, 0, 10, 10)


# ---- element_intersects_rect ----


def _stroke():
    return Stroke(color=Color(0, 0, 0), width=1.0)


def test_line_element_overlapping_rect():
    line = Line(x1=-5, y1=5, x2=15, y2=5, stroke=_stroke())
    assert element_intersects_rect(line, 0, 0, 10, 10)


def test_line_element_outside_rect():
    line = Line(x1=20, y1=0, x2=30, y2=0, stroke=_stroke())
    assert not element_intersects_rect(line, 0, 0, 10, 10)


def test_rect_element_overlapping_rect():
    rect = Rect(x=5, y=5, width=10, height=10, stroke=_stroke())
    assert element_intersects_rect(rect, 0, 0, 10, 10)


def test_rect_element_outside_rect():
    rect = Rect(x=20, y=20, width=5, height=5, stroke=_stroke())
    assert not element_intersects_rect(rect, 0, 0, 10, 10)
