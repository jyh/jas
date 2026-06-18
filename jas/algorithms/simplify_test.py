"""Polyline simplification tests.

Mirrors the ``#[cfg(test)]`` module in
``jas_dioxus/src/algorithms/simplify.rs`` for cross-language behavioral
equivalence.
"""

from __future__ import annotations

import math

from algorithms.simplify import (
    DEFAULT_CORNER_ANGLE,
    detect_corners,
    simplify_polyline,
)
from geometry.element import ClosePath, CurveTo, LineTo, MoveTo


def test_empty_input_returns_empty():
    assert simplify_polyline([], 0.5, True) == []


def test_two_points_emits_lineto():
    out = simplify_polyline([(0.0, 0.0), (10.0, 0.0)], 0.5, False)
    assert len(out) == 2
    assert isinstance(out[0], MoveTo)
    assert isinstance(out[1], LineTo)


def test_detect_corners_on_square():
    # Closed unit square -- every vertex is a 90 degree corner.
    sq = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
    corners = detect_corners(sq, DEFAULT_CORNER_ANGLE, True)
    assert corners == [0, 1, 2, 3]


def test_detect_corners_on_collinear_points():
    # Collinear points should not yield corners.
    line = [(float(i), 0.0) for i in range(10)]
    corners = detect_corners(line, DEFAULT_CORNER_ANGLE, False)
    assert corners == [], f"got unexpected corners on a straight line: {corners}"


def test_detect_corners_below_threshold_is_smooth():
    # 25-degree turn -- below the 30-degree threshold, no corner.
    angle = math.radians(25.0)
    pts = [
        (0.0, 0.0),
        (10.0, 0.0),
        (10.0 + 10.0 * math.cos(angle), 10.0 * math.sin(angle)),
    ]
    corners = detect_corners(pts, DEFAULT_CORNER_ANGLE, False)
    assert corners == [], f"25 degree turn should not be a corner, got {corners}"


def test_detect_corners_above_threshold_is_corner():
    # 45-degree turn -- above the 30-degree threshold, marked.
    angle = math.radians(45.0)
    pts = [
        (0.0, 0.0),
        (10.0, 0.0),
        (10.0 + 10.0 * math.cos(angle), 10.0 * math.sin(angle)),
    ]
    corners = detect_corners(pts, DEFAULT_CORNER_ANGLE, False)
    assert corners == [1]


def test_simplify_square_keeps_lines():
    # Closed square -- every edge is straight, so the output should be
    # 4 LineTo + ClosePath after the initial MoveTo. No CurveTo.
    sq = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
    out = simplify_polyline(sq, 0.5, True)
    curve_count = sum(1 for c in out if isinstance(c, CurveTo))
    line_count = sum(1 for c in out if isinstance(c, LineTo))
    assert curve_count == 0, "square should fit with no curves"
    assert line_count == 4, "square should fit as 4 LineTo segments"
    assert isinstance(out[-1], ClosePath)


def test_simplify_circle_recovers_curves():
    # 32-segment regular circle sampling -- should fit as curves with no
    # corners and no LineTo.
    n = 32
    r = 50.0
    pts = [
        (r * math.cos(2.0 * math.pi * i / n), r * math.sin(2.0 * math.pi * i / n))
        for i in range(n)
    ]
    out = simplify_polyline(pts, 0.5, True)
    curve_count = sum(1 for c in out if isinstance(c, CurveTo))
    line_count = sum(1 for c in out if isinstance(c, LineTo))
    assert curve_count > 0, "circle sampling should fit at least one CurveTo"
    assert line_count == 0, "circle sampling should not produce LineTo"
    assert isinstance(out[-1], ClosePath)


def test_open_polyline_endpoints_are_not_corners():
    # Three collinear points -- endpoints at index 0 and 2 must not be
    # reported as corners, only vertex 1 could (and it shouldn't here
    # because it is collinear).
    pts = [(0.0, 0.0), (5.0, 0.0), (10.0, 0.0)]
    corners = detect_corners(pts, DEFAULT_CORNER_ANGLE, False)
    assert corners == [], f"got {corners}"
