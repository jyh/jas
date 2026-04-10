"""Hit test primitives. Mirrors jas_dioxus/src/algorithms/hit_test.rs."""

from __future__ import annotations

from algorithms.hit_test import (
    point_in_rect,
    segments_intersect,
    segment_intersects_rect,
    rects_intersect,
    element_intersects_rect,
    element_intersects_polygon,
)
from geometry.element import Color, Fill, Line, Rect, Stroke, Transform


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


# ---- transform-aware hit-testing ----


def test_translated_line_intersects_rect():
    line = Line(x1=0, y1=5, x2=10, y2=5,
                transform=Transform.translate(100, 0))
    assert element_intersects_rect(line, 95, 0, 20, 10)
    assert not element_intersects_rect(line, 0, 0, 10, 10)


def test_rotated_rect_intersects_rect():
    rect = Rect(x=0, y=0, width=10, height=10,
                fill=Fill(color=Color(r=0, g=0, b=0)),
                transform=Transform.rotate(45))
    assert element_intersects_rect(rect, 6, 6, 2, 2)
    assert not element_intersects_rect(rect, 12, 0, 2, 2)


def test_scaled_line_intersects_rect():
    line = Line(x1=0, y1=0, x2=5, y2=0,
                transform=Transform.scale(2, 2))
    assert element_intersects_rect(line, 8, -1, 4, 2)
    assert element_intersects_rect(line, 6, -1, 2, 2)


def test_singular_transform_returns_false():
    line = Line(x1=0, y1=0, x2=10, y2=0,
                transform=Transform.scale(0, 0))
    assert not element_intersects_rect(line, 0, 0, 10, 10)


def test_no_transform_still_works():
    line = Line(x1=0, y1=5, x2=10, y2=5)
    assert element_intersects_rect(line, 0, 0, 10, 10)
    assert not element_intersects_rect(line, 20, 0, 10, 10)


def test_translated_line_intersects_polygon():
    line = Line(x1=0, y1=5, x2=10, y2=5,
                transform=Transform.translate(100, 0))
    sq = [(95, 0), (115, 0), (115, 10), (95, 10)]
    assert element_intersects_polygon(line, sq)
    sq2 = [(0, 0), (10, 0), (10, 10), (0, 10)]
    assert not element_intersects_polygon(line, sq2)
