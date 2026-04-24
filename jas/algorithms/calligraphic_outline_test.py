"""Tests for calligraphic_outline. Mirrors the JS / Rust unit tests."""

from __future__ import annotations

import math

import pytest

from algorithms.calligraphic_outline import (
    CalligraphicBrush, calligraphic_outline,
)
from geometry.element import MoveTo, LineTo, CurveTo


def test_empty_input_returns_empty():
    brush = CalligraphicBrush(angle=0.0, roundness=100.0, size=4.0)
    assert calligraphic_outline([], brush) == []


def test_single_move_returns_empty():
    brush = CalligraphicBrush(angle=0.0, roundness=100.0, size=4.0)
    assert calligraphic_outline([MoveTo(0.0, 0.0)], brush) == []


def test_horizontal_line_with_circular_brush():
    brush = CalligraphicBrush(angle=0.0, roundness=100.0, size=4.0)
    cmds = [MoveTo(0.0, 0.0), LineTo(10.0, 0.0)]
    pts = calligraphic_outline(cmds, brush)
    for (_, y) in pts:
        assert abs(abs(y) - 2.0) < 1e-3
    xs = [p[0] for p in pts]
    assert min(xs) == pytest.approx(0.0)
    assert max(xs) == pytest.approx(10.0)


def test_brush_angle_parallel_uses_minor_axis():
    brush = CalligraphicBrush(angle=0.0, roundness=50.0, size=4.0)
    cmds = [MoveTo(0.0, 0.0), LineTo(10.0, 0.0)]
    pts = calligraphic_outline(cmds, brush)
    for (_, y) in pts:
        assert abs(abs(y) - 1.0) < 1e-3


def test_brush_angle_perpendicular_uses_major_axis():
    brush = CalligraphicBrush(angle=90.0, roundness=50.0, size=4.0)
    cmds = [MoveTo(0.0, 0.0), LineTo(10.0, 0.0)]
    pts = calligraphic_outline(cmds, brush)
    for (_, y) in pts:
        assert abs(abs(y) - 2.0) < 1e-3


def test_circular_brush_independent_of_path_direction():
    brush = CalligraphicBrush(angle=30.0, roundness=100.0, size=4.0)
    cmds = [MoveTo(0.0, 0.0), LineTo(10.0, 10.0)]
    pts = calligraphic_outline(cmds, brush)
    for (x, y) in pts:
        dist = abs(x - y) / math.sqrt(2.0)
        assert abs(dist - 2.0) < 1e-3


def test_cubic_curve_sampled_and_outlined():
    brush = CalligraphicBrush(angle=0.0, roundness=100.0, size=4.0)
    cmds = [
        MoveTo(0.0, 0.0),
        CurveTo(x1=3.0, y1=5.0, x2=7.0, y2=5.0, x=10.0, y=0.0),
    ]
    pts = calligraphic_outline(cmds, brush)
    assert len(pts) > 50
    ys = [p[1] for p in pts]
    assert max(ys) > 3.0
    assert min(ys) < -0.5
