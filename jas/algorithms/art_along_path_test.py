"""Equivalence vectors shared with the Rust reference
(jas_dioxus/src/algorithms/art_along_path.rs) and the Swift / OCaml ports:
a tapered lens (rhombus) warped along a straight horizontal path."""

from algorithms.art_along_path import ArtBrush, art_along_path
from geometry.element import MoveTo, LineTo


def _brush():
    return ArtBrush(
        artwork_width=100.0,
        artwork_height=20.0,
        artwork=[[(0.0, 10.0), (50.0, 0.0), (100.0, 10.0), (50.0, 20.0)]],
        scale=100.0,
        flip_across=False,
        flip_along=False,
        stroke_weight=2.0,
    )


def _close(a, x, y):
    return abs(a[0] - x) < 1e-6 and abs(a[1] - y) < 1e-6


def test_straight_path_warps_to_centered_ribbon():
    out = art_along_path([MoveTo(0.0, 0.0), LineTo(100.0, 0.0)], _brush())
    assert len(out) == 1
    p = out[0]
    assert len(p) == 4
    assert _close(p[0], 0.0, 0.0)
    assert _close(p[1], 50.0, -1.0)
    assert _close(p[2], 100.0, 0.0)
    assert _close(p[3], 50.0, 1.0)


def test_empty_for_degenerate():
    assert art_along_path([MoveTo(0.0, 0.0)], _brush()) == []


def test_flip_across_mirrors_offset():
    b = _brush()
    b.flip_across = True
    out = art_along_path([MoveTo(0.0, 0.0), LineTo(100.0, 0.0)], b)
    assert abs(out[0][1][1] - 1.0) < 1e-6
