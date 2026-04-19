"""Tests for the word-wrap text layout."""

from algorithms.text_layout import (
    layout, ordered_range,
    layout_with_paragraphs, ParagraphSegment, TextAlign,
    build_paragraph_segments,
)


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


# ── Phase 5: paragraph-aware layout ──────────────────────────

def test_empty_paragraph_list_matches_plain():
    m = fixed(10.0)
    plain = layout("hello world", 100.0, 16.0, m)
    para = layout_with_paragraphs("hello world", 100.0, 16.0, [], m)
    assert len(plain.lines) == len(para.lines)
    assert len(plain.glyphs) == len(para.glyphs)
    for a, b in zip(plain.glyphs, para.glyphs):
        assert a.x == b.x
        assert a.right == b.right
        assert a.line == b.line


def test_left_indent_shifts_every_line():
    segs = [ParagraphSegment(char_start=0, char_end=11, left_indent=20.0)]
    l = layout_with_paragraphs("hello world", 60.0, 16.0, segs, fixed(10.0))
    assert l.glyphs[0].x == 20.0


def test_right_indent_narrows_wrap_width():
    segs = [ParagraphSegment(char_start=0, char_end=11, right_indent=60.0)]
    l = layout_with_paragraphs("hello world", 110.0, 16.0, segs, fixed(10.0))
    assert len(l.lines) >= 2


def test_first_line_indent_only_shifts_first_line():
    segs = [ParagraphSegment(char_start=0, char_end=11, first_line_indent=25.0)]
    l = layout_with_paragraphs("hello world", 60.0, 16.0, segs, fixed(10.0))
    first_line_first = next(g for g in l.glyphs if g.line == 0)
    second_line_first = next(g for g in l.glyphs if g.line == 1)
    assert first_line_first.x == 25.0
    assert second_line_first.x == 0.0


def test_alignment_center_shifts_to_center():
    segs = [ParagraphSegment(char_start=0, char_end=2,
                             text_align=TextAlign.CENTER)]
    l = layout_with_paragraphs("hi", 100.0, 16.0, segs, fixed(10.0))
    assert l.glyphs[0].x == 40.0


def test_alignment_right_shifts_to_right_edge():
    segs = [ParagraphSegment(char_start=0, char_end=2,
                             text_align=TextAlign.RIGHT)]
    l = layout_with_paragraphs("hi", 100.0, 16.0, segs, fixed(10.0))
    assert l.glyphs[0].x == 80.0


def test_space_before_skipped_for_first_paragraph():
    segs = [
        ParagraphSegment(char_start=0, char_end=2,
                         space_before=50.0, space_after=0.0),
        ParagraphSegment(char_start=2, char_end=4, space_before=30.0),
    ]
    l = layout_with_paragraphs("abcd", 100.0, 16.0, segs, fixed(10.0))
    assert len(l.lines) == 2
    assert l.lines[0].top == 0.0
    # 16 (line height) + 30 (space_before of para 2) = 46.
    assert l.lines[1].top == 46.0


def test_space_after_inserts_gap():
    segs = [
        ParagraphSegment(char_start=0, char_end=2, space_after=20.0),
        ParagraphSegment(char_start=2, char_end=4),
    ]
    l = layout_with_paragraphs("abcd", 100.0, 16.0, segs, fixed(10.0))
    assert l.lines[1].top == 36.0


def test_alignment_with_indent_uses_remaining_width():
    # "hi" centered in box of effective width 80 (100-20 left).
    # (80-20)/2 = 30; +20 left_indent → x=50.
    segs = [ParagraphSegment(char_start=0, char_end=2,
                             left_indent=20.0,
                             text_align=TextAlign.CENTER)]
    l = layout_with_paragraphs("hi", 100.0, 16.0, segs, fixed(10.0))
    assert l.glyphs[0].x == 50.0


# ── build_paragraph_segments ─────────────────────────────────

def _wrapper(left=0.0, right=0.0, fli=0.0, sb=0.0, sa=0.0, ta=None):
    from geometry.tspan import Tspan
    return Tspan(id=0, content="", jas_role="paragraph",
                 jas_left_indent=left if left else None,
                 jas_right_indent=right if right else None,
                 text_indent=fli if fli else None,
                 jas_space_before=sb if sb else None,
                 jas_space_after=sa if sa else None,
                 text_align=ta)


def _body(content):
    from geometry.tspan import Tspan
    return Tspan(id=0, content=content)


def test_no_wrapper_yields_no_segments():
    segs = build_paragraph_segments((_body("hello"),), "hello", True)
    assert segs == []


def test_single_wrapper_covers_content():
    segs = build_paragraph_segments(
        (_wrapper(left=12.0), _body("hello")), "hello", True)
    assert len(segs) == 1
    assert segs[0].char_start == 0
    assert segs[0].char_end == 5
    assert segs[0].left_indent == 12.0


def test_two_wrappers_split_content():
    segs = build_paragraph_segments((
        _wrapper(), _body("ab"),
        _wrapper(sb=6.0, ta="center"), _body("cde"),
    ), "abcde", True)
    assert len(segs) == 2
    assert segs[1].char_start == 2
    assert segs[1].char_end == 5
    assert segs[1].space_before == 6.0
    assert segs[1].text_align == TextAlign.CENTER
