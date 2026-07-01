"""Equivalence vectors shared with the Rust reference
(jas_dioxus/src/algorithms/bristle_stroke.rs) and the Swift / OCaml ports:
width 4, density 25 -> two bristles at +/-2 along a straight horizontal path."""

from algorithms.bristle_stroke import BristleBrush, bristle_stroke
from geometry.element import MoveTo, LineTo


def _brush():
    return BristleBrush(size=4.0, density=25.0, thickness=30.0, opacity=30.0,
                        stroke_weight=1.0)


def _close(a, x, y):
    return abs(a[0] - x) < 1e-6 and abs(a[1] - y) < 1e-6


def test_straight_path_two_offset_bristles():
    out = bristle_stroke([MoveTo(0.0, 0.0), LineTo(100.0, 0.0)], _brush())
    assert len(out) == 2
    assert _close(out[0][0], 0.0, -2.0)
    assert _close(out[0][1], 100.0, -2.0)
    assert _close(out[1][0], 0.0, 2.0)
    assert _close(out[1][1], 100.0, 2.0)


def test_count_and_alpha():
    b = _brush()
    assert b.count() == 2
    assert abs(b.alpha() - 0.3) < 1e-9


def test_empty_for_degenerate():
    assert bristle_stroke([MoveTo(0.0, 0.0)], _brush()) == []
