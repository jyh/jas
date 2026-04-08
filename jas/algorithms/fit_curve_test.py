"""Bezier curve fitter tests. Mirrors jas_dioxus/src/algorithms/fit_curve.rs."""

from __future__ import annotations

import math

from algorithms.fit_curve import fit_curve


def bezier_at(seg, t):
    p1x, p1y, c1x, c1y, c2x, c2y, p2x, p2y = seg
    mt = 1.0 - t
    b0 = mt * mt * mt
    b1 = 3.0 * t * mt * mt
    b2 = 3.0 * t * t * mt
    b3 = t * t * t
    return (
        b0 * p1x + b1 * c1x + b2 * c2x + b3 * p2x,
        b0 * p1y + b1 * c1y + b2 * c2y + b3 * p2y,
    )


def approx_eq(a, b, tol=1e-9):
    return abs(a - b) < tol


def point_approx_eq(a, b, tol=1e-9):
    return approx_eq(a[0], b[0], tol) and approx_eq(a[1], b[1], tol)


# ---- Degenerate input ----


def test_empty_returns_empty():
    assert fit_curve([], 1.0) == []


def test_single_point_returns_empty():
    assert fit_curve([(0.0, 0.0)], 1.0) == []


def test_two_points_returns_one_segment():
    r = fit_curve([(0.0, 0.0), (10.0, 0.0)], 1.0)
    assert len(r) == 1


# ---- Endpoints preserved ----


def test_two_points_endpoints_preserved():
    pts = [(0.0, 0.0), (10.0, 0.0)]
    r = fit_curve(pts, 1.0)
    seg = r[0]
    assert point_approx_eq((seg[0], seg[1]), pts[0])
    assert point_approx_eq((seg[6], seg[7]), pts[-1])


def test_endpoints_preserved_arc():
    pts = [
        (10.0 * math.cos(i / 20 * math.pi / 2), 10.0 * math.sin(i / 20 * math.pi / 2))
        for i in range(21)
    ]
    r = fit_curve(pts, 0.5)
    assert len(r) > 0
    assert point_approx_eq((r[0][0], r[0][1]), pts[0])
    assert point_approx_eq((r[-1][6], r[-1][7]), pts[-1])


# ---- Continuity ----


def test_segments_are_c0_continuous():
    pts = [(float(i), 5.0 * math.sin(i * 0.3)) for i in range(30)]
    r = fit_curve(pts, 0.5)
    assert len(r) >= 2
    for i in range(len(r) - 1):
        end_prev = (r[i][6], r[i][7])
        start_next = (r[i + 1][0], r[i + 1][1])
        assert point_approx_eq(end_prev, start_next), f"join {i}: {end_prev} vs {start_next}"


# ---- Approximation quality ----


def test_two_points_segment_passes_through_endpoints():
    pts = [(0.0, 0.0), (100.0, 50.0)]
    r = fit_curve(pts, 1.0)
    seg = r[0]
    assert point_approx_eq(bezier_at(seg, 0.0), pts[0])
    assert point_approx_eq(bezier_at(seg, 1.0), pts[1])


def test_input_points_within_error_tolerance():
    pts = [(float(i), 0.1 * i * i) for i in range(15)]
    error = 1.0
    segs = fit_curve(pts, error)
    samples_per = 100
    samples = []
    for seg in segs:
        for i in range(samples_per + 1):
            samples.append(bezier_at(seg, i / samples_per))
    for p in pts:
        min_d = min(math.hypot(s[0] - p[0], s[1] - p[1]) for s in samples)
        assert min_d <= error * 2.0, f"point {p} too far: {min_d}"


# ---- Error parameter ----


def test_tighter_error_gives_at_least_as_many_segments():
    pts = [(i * 0.5, 5.0 * math.sin(i * 0.5 * 0.5)) for i in range(50)]
    loose = fit_curve(pts, 5.0)
    tight = fit_curve(pts, 0.1)
    assert len(tight) >= len(loose), f"tight={len(tight)} loose={len(loose)}"


# ---- Specific shapes ----


def test_straight_line_collinear_points():
    pts = [(float(i), 2.0 * i) for i in range(10)]
    r = fit_curve(pts, 1.0)
    assert len(r) == 1


def test_horizontal_line():
    pts = [(float(i), 5.0) for i in range(10)]
    r = fit_curve(pts, 1.0)
    assert len(r) == 1
    assert point_approx_eq((r[0][0], r[0][1]), (0.0, 5.0))
    assert point_approx_eq((r[0][6], r[0][7]), (9.0, 5.0))


def test_vertical_line():
    pts = [(3.0, float(i)) for i in range(10)]
    r = fit_curve(pts, 1.0)
    assert len(r) == 1
    assert point_approx_eq((r[0][0], r[0][1]), (3.0, 0.0))
    assert point_approx_eq((r[0][6], r[0][7]), (3.0, 9.0))


def test_circular_arc_returns_some_segments():
    pts = [
        (50.0 * math.cos(i / 60 * math.pi), 50.0 * math.sin(i / 60 * math.pi))
        for i in range(61)
    ]
    r = fit_curve(pts, 0.5)
    assert len(r) > 0
    assert len(r) <= len(pts)


def test_two_coincident_points_does_not_crash():
    fit_curve([(5.0, 5.0), (5.0, 5.0)], 1.0)
