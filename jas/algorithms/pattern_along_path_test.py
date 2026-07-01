"""Equivalence vectors shared with the Rust reference
(jas_dioxus/src/algorithms/pattern_along_path.rs) and the Swift / OCaml
ports: a diamond side tile tiled twice along a straight 100-long path."""

from algorithms.pattern_along_path import PatternBrush, pattern_along_path
from geometry.element import MoveTo, LineTo


def _brush():
    return PatternBrush(
        tile_width=100.0, tile_height=20.0,
        side=[[(0.0, 10.0), (50.0, 0.0), (100.0, 10.0), (50.0, 20.0)]],
        scale=100.0, spacing=0.0, flip_across=False, flip_along=False,
        stroke_weight=10.0,
    )


def _close(a, x, y):
    return abs(a[0] - x) < 1e-6 and abs(a[1] - y) < 1e-6


def test_straight_path_tiles_twice():
    out = pattern_along_path([MoveTo(0.0, 0.0), LineTo(100.0, 0.0)], _brush())
    assert len(out) == 2
    assert _close(out[0][0], 0.0, 0.0)
    assert _close(out[0][1], 25.0, -5.0)
    assert _close(out[0][2], 50.0, 0.0)
    assert _close(out[1][0], 50.0, 0.0)
    assert _close(out[1][2], 100.0, 0.0)


def test_empty_for_degenerate():
    assert pattern_along_path([MoveTo(0.0, 0.0)], _brush()) == []
