"""path_text_layout tests. Mirrors jas_dioxus/src/algorithms/path_text_layout.rs."""

from __future__ import annotations

from algorithms.path_text_layout import layout_path_text
from geometry.element import MoveTo, LineTo


def straight():
    return (MoveTo(0.0, 0.0), LineTo(100.0, 0.0))


def fixed(w):
    return lambda s: len(s) * w


def approx(a, b, tol=1e-6):
    return abs(a - b) < tol


def test_empty_content_is_empty_layout():
    l = layout_path_text(straight(), "", 0.0, 16.0, fixed(10.0))
    assert l.char_count == 0
    assert l.glyphs == []


def test_glyphs_advance_along_straight_path():
    l = layout_path_text(straight(), "abc", 0.0, 16.0, fixed(10.0))
    assert len(l.glyphs) == 3
    assert approx(l.glyphs[0].cx, 5.0)
    assert approx(l.glyphs[1].cx, 15.0)
    assert approx(l.glyphs[2].cx, 25.0)
    for g in l.glyphs:
        assert approx(g.cy, 0.0)
        assert approx(g.angle, 0.0)


def test_cursor_pos_at_start_is_path_origin():
    l = layout_path_text(straight(), "abc", 0.0, 16.0, fixed(10.0))
    x, y, _ = l.cursor_pos(0)
    assert approx(x, 0.0)
    assert approx(y, 0.0)


def test_cursor_pos_at_end_is_after_last_glyph():
    l = layout_path_text(straight(), "abc", 0.0, 16.0, fixed(10.0))
    x, _, _ = l.cursor_pos(3)
    assert approx(x, 30.0)


def test_hit_test_picks_nearest_cursor_index():
    l = layout_path_text(straight(), "abc", 0.0, 16.0, fixed(10.0))
    assert l.hit_test(12.0, 0.0) == 1
    assert l.hit_test(1000.0, 0.0) == 3
    assert l.hit_test(-100.0, 0.0) == 0


def test_start_offset_shifts_glyphs_along_path():
    l = layout_path_text(straight(), "abc", 0.5, 16.0, fixed(10.0))
    assert approx(l.glyphs[0].cx, 55.0)
    assert approx(l.glyphs[1].cx, 65.0)
    assert approx(l.glyphs[2].cx, 75.0)


def test_total_length_matches_straight_path():
    l = layout_path_text(straight(), "ab", 0.0, 16.0, fixed(10.0))
    assert approx(l.total_length, 100.0)


def test_cursor_pos_for_index_in_middle():
    l = layout_path_text(straight(), "abc", 0.0, 16.0, fixed(10.0))
    x, _, _ = l.cursor_pos(1)
    assert approx(x, 10.0)


def test_empty_path_has_zero_total_length():
    l = layout_path_text((), "abc", 0.0, 16.0, fixed(10.0))
    assert l.total_length == 0.0


def test_glyphs_overflow_when_path_too_short():
    l = layout_path_text(straight(), "abcdefghijkl", 0.0, 16.0, fixed(10.0))
    assert any(g.overflow for g in l.glyphs)
