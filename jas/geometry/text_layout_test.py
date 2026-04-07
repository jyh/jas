"""Tests for the word-wrap text layout."""

from geometry.text_layout import layout, ordered_range


def fixed(w):
    return lambda s: len(s) * w


def test_empty_string_has_one_line():
    l = layout("", 100.0, 16.0, fixed(10.0))
    assert len(l.lines) == 1
    assert l.char_count == 0
    assert l.cursor_xy(0)[0] == 0.0


def test_point_text_no_wrapping():
    l = layout("hello world", 0.0, 16.0, fixed(10.0))
    assert len(l.lines) == 1
    assert l.char_count == 11


def test_hard_newline_splits_lines():
    l = layout("ab\ncd", 0.0, 16.0, fixed(10.0))
    assert len(l.lines) == 2
    assert l.lines[0].end == 2
    assert l.lines[0].hard_break
    assert l.lines[1].start == 3


def test_word_wrap_breaks_on_whitespace():
    l = layout("hello world", 60.0, 16.0, fixed(10.0))
    assert len(l.lines) == 2
    assert l.lines[0].start == 0
    assert l.lines[1].start == 6


def test_long_word_breaks_at_max_width_chars():
    l = layout("abcdef", 30.0, 16.0, fixed(10.0))
    assert len(l.lines) == 2
    assert l.lines[0].end == 3
    assert l.lines[1].end == 6


def test_hit_test_first_char():
    l = layout("hello", 0.0, 16.0, fixed(10.0))
    assert l.hit_test(0.0, 8.0) == 0
    assert l.hit_test(7.0, 8.0) == 1


def test_hit_test_past_end():
    l = layout("hello", 0.0, 16.0, fixed(10.0))
    assert l.hit_test(999.0, 8.0) == 5


def test_hit_test_below_last_line_clamps():
    l = layout("a\nb", 0.0, 16.0, fixed(10.0))
    assert l.hit_test(0.0, 999.0) == 2


def test_cursor_xy_advances_with_index():
    l = layout("abc", 0.0, 16.0, fixed(10.0))
    assert l.cursor_xy(0)[0] == 0.0
    assert l.cursor_xy(1)[0] == 10.0
    assert l.cursor_xy(2)[0] == 20.0
    assert l.cursor_xy(3)[0] == 30.0


def test_cursor_up_down_preserves_x():
    l = layout("hello\nworld", 0.0, 16.0, fixed(10.0))
    assert l.cursor_up(6) == 0
    assert l.cursor_up(8) == 2


def test_cursor_down_at_last_line_goes_to_end():
    l = layout("hi", 0.0, 16.0, fixed(10.0))
    assert l.cursor_down(1) == l.char_count


def test_ordered_range_swaps():
    assert ordered_range(3, 1) == (1, 3)
    assert ordered_range(1, 3) == (1, 3)
    assert ordered_range(2, 2) == (2, 2)


def test_line_for_cursor_after_hard_break_stays_on_prev_line():
    l = layout("ab\ncd", 0.0, 16.0, fixed(10.0))
    assert l.line_for_cursor(2) == 0
    assert l.line_for_cursor(3) == 1


def test_glyphs_match_char_count():
    l = layout("hello world", 60.0, 16.0, fixed(10.0))
    assert len(l.glyphs) == l.char_count


def test_cursor_down_between_wrapped_lines():
    l = layout("abcd ef", 40.0, 16.0, fixed(10.0))
    assert len(l.lines) == 2
    assert l.cursor_down(1) == 6


def test_lines_past_max_height_still_emitted():
    l = layout("a\nb\nc\nd\ne", 0.0, 16.0, fixed(10.0))
    assert len(l.lines) == 5


def test_point_text_cursor_xy_at_end_is_full_width():
    l = layout("hi", 0.0, 16.0, fixed(10.0))
    assert l.cursor_xy(2)[0] == 20.0


def test_hit_test_on_first_line_with_multiple_lines():
    l = layout("ab\ncd", 0.0, 16.0, fixed(10.0))
    assert l.hit_test(999.0, 5.0) == 2


def test_soft_wrap_trailing_space_skipped_in_hit_test():
    l = layout("ab cd", 30.0, 16.0, fixed(10.0))
    assert len(l.lines) == 2
    assert l.hit_test(99.0, 8.0) == 2
