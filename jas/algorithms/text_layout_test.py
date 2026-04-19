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


# ── Phase 6: list markers + counter run rule ─────────────────

from algorithms.text_layout import (
    marker_text, to_alpha, to_roman, compute_counters, MARKER_GAP_PT,
)


def test_marker_text_bullets():
    assert marker_text("bullet-disc", 1) == "\u2022"
    assert marker_text("bullet-open-circle", 99) == "\u25CB"
    assert marker_text("bullet-square", 1) == "\u25A0"
    assert marker_text("bullet-open-square", 1) == "\u25A1"
    assert marker_text("bullet-dash", 1) == "\u2013"
    assert marker_text("bullet-check", 1) == "\u2713"


def test_marker_text_decimal():
    assert marker_text("num-decimal", 1) == "1."
    assert marker_text("num-decimal", 42) == "42."


def test_marker_text_alpha():
    assert marker_text("num-lower-alpha", 1) == "a."
    assert marker_text("num-lower-alpha", 26) == "z."
    assert marker_text("num-lower-alpha", 27) == "aa."
    assert marker_text("num-upper-alpha", 28) == "AB."


def test_marker_text_roman():
    assert marker_text("num-lower-roman", 1) == "i."
    assert marker_text("num-lower-roman", 4) == "iv."
    assert marker_text("num-lower-roman", 9) == "ix."
    assert marker_text("num-upper-roman", 1990) == "MCMXC."


def test_marker_text_unknown_returns_empty():
    assert marker_text("invented-style", 1) == ""


def test_compute_counters_consecutive_decimal():
    segs = [ParagraphSegment(list_style="num-decimal") for _ in range(3)]
    assert compute_counters(segs) == [1, 2, 3]


def test_compute_counters_bullet_breaks_run():
    segs = [
        ParagraphSegment(list_style="num-decimal"),
        ParagraphSegment(list_style="num-decimal"),
        ParagraphSegment(list_style="bullet-disc"),
        ParagraphSegment(list_style="num-decimal"),
    ]
    assert compute_counters(segs) == [1, 2, 0, 1]


def test_compute_counters_different_num_style_resets():
    segs = [
        ParagraphSegment(list_style="num-decimal"),
        ParagraphSegment(list_style="num-decimal"),
        ParagraphSegment(list_style="num-lower-alpha"),
        ParagraphSegment(list_style="num-lower-alpha"),
    ]
    assert compute_counters(segs) == [1, 2, 1, 2]


def test_compute_counters_no_style_breaks_run():
    segs = [
        ParagraphSegment(list_style="num-decimal"),
        ParagraphSegment(list_style=None),
        ParagraphSegment(list_style="num-decimal"),
    ]
    assert compute_counters(segs) == [1, 0, 1]


def test_list_segment_carries_style_and_marker_gap():
    from geometry.tspan import Tspan
    segs = build_paragraph_segments(
        (Tspan(id=0, content="", jas_role="paragraph",
               jas_list_style="bullet-disc"),
         Tspan(id=1, content="hello")),
        "hello", True)
    assert len(segs) == 1
    assert segs[0].list_style == "bullet-disc"
    assert segs[0].marker_gap == MARKER_GAP_PT


def test_list_pushes_text_by_marker_gap():
    segs = [ParagraphSegment(char_start=0, char_end=2,
                              list_style="bullet-disc", marker_gap=12.0)]
    l = layout_with_paragraphs("hi", 100.0, 16.0, segs, fixed(10.0))
    assert l.glyphs[0].x == 12.0


def test_list_combines_left_indent_and_marker_gap():
    segs = [ParagraphSegment(char_start=0, char_end=2,
                              left_indent=20.0,
                              list_style="num-decimal", marker_gap=12.0)]
    l = layout_with_paragraphs("hi", 100.0, 16.0, segs, fixed(10.0))
    assert l.glyphs[0].x == 32.0


def test_list_ignores_first_line_indent():
    segs = [ParagraphSegment(char_start=0, char_end=2,
                              first_line_indent=25.0,
                              list_style="bullet-disc", marker_gap=12.0)]
    l = layout_with_paragraphs("hi", 100.0, 16.0, segs, fixed(10.0))
    assert l.glyphs[0].x == 12.0  # not 12 + 25


def test_to_alpha_rollover():
    assert to_alpha(1, False) == "a"
    assert to_alpha(26, False) == "z"
    assert to_alpha(27, False) == "aa"
    assert to_alpha(703, False) == "aaa"


def test_to_roman_above_3999_falls_back():
    assert to_roman(4000, False) == "(4000)"


# ── Phase 7: hanging punctuation ─────────────────────────────

from algorithms.text_layout import is_left_hanger, is_right_hanger


def test_left_hanger_class_membership():
    for c in ['"', "'", "\u201C", "\u2018", "\u00AB", "\u2039",
              "(", "[", "{"]:
        assert is_left_hanger(c), c
    for c in ['a', '.', ',', ')', ']', '}', "\u201D"]:
        assert not is_left_hanger(c), c


def test_right_hanger_class_membership():
    for c in ['"', "'", "\u201D", "\u2019", "\u00BB", "\u203A",
              ")", "]", "}", ".", ",",
              "-", "\u2013", "\u2014"]:
        assert is_right_hanger(c), c
    for c in ['a', "\u201C", "\u2018", "(", "[", "{"]:
        assert not is_right_hanger(c), c


def test_hanging_off_no_effect():
    segs = [ParagraphSegment(char_start=0, char_end=4,
                              text_align=TextAlign.LEFT,
                              hanging_punctuation=False)]
    l = layout_with_paragraphs("(ab)", 100.0, 16.0, segs, fixed(10.0))
    assert l.glyphs[0].x == 0.0


def test_left_aligned_left_hanger_shifts_into_left_margin():
    segs = [ParagraphSegment(char_start=0, char_end=4,
                              text_align=TextAlign.LEFT,
                              hanging_punctuation=True)]
    l = layout_with_paragraphs("(abc", 100.0, 16.0, segs, fixed(10.0))
    assert l.glyphs[0].x == -10.0  # '(' in margin
    assert l.glyphs[1].x == 0.0    # 'a' at edge


def test_left_aligned_right_hanger_no_shift():
    segs = [ParagraphSegment(char_start=0, char_end=3,
                              text_align=TextAlign.LEFT,
                              hanging_punctuation=True)]
    l = layout_with_paragraphs("ab.", 100.0, 16.0, segs, fixed(10.0))
    assert l.glyphs[0].x == 0.0
    assert l.glyphs[2].x == 20.0  # '.' inside the box


def test_right_aligned_right_hanger_sticks_outside():
    segs = [ParagraphSegment(char_start=0, char_end=3,
                              text_align=TextAlign.RIGHT,
                              hanging_punctuation=True)]
    l = layout_with_paragraphs("ab.", 100.0, 16.0, segs, fixed(10.0))
    assert l.glyphs[1].right == 100.0
    assert l.glyphs[2].x == 100.0  # '.' sticks out


def test_right_aligned_left_hanger_no_shift():
    segs = [ParagraphSegment(char_start=0, char_end=3,
                              text_align=TextAlign.RIGHT,
                              hanging_punctuation=True)]
    l = layout_with_paragraphs("(ab", 100.0, 16.0, segs, fixed(10.0))
    assert l.glyphs[2].right == 100.0
    assert l.glyphs[0].x == 70.0  # '(' inside, normal right-align


def test_centered_both_sides_hang():
    segs = [ParagraphSegment(char_start=0, char_end=4,
                              text_align=TextAlign.CENTER,
                              hanging_punctuation=True)]
    l = layout_with_paragraphs("(ab.", 100.0, 16.0, segs, fixed(10.0))
    # effective_visible_w = 20; shift = (100-20)/2 - 10 = 30.
    assert l.glyphs[0].x == 30.0
    assert l.glyphs[1].x == 40.0
    assert l.glyphs[2].x == 50.0
    assert l.glyphs[3].x == 60.0


def test_dash_hangs_at_eol_when_right_aligned():
    segs = [ParagraphSegment(char_start=0, char_end=3,
                              text_align=TextAlign.RIGHT,
                              hanging_punctuation=True)]
    l = layout_with_paragraphs("ab-", 100.0, 16.0, segs, fixed(10.0))
    assert l.glyphs[2].x == 100.0  # '-' hangs right


def test_hanging_with_left_indent():
    segs = [ParagraphSegment(char_start=0, char_end=3,
                              left_indent=20.0,
                              text_align=TextAlign.LEFT,
                              hanging_punctuation=True)]
    l = layout_with_paragraphs("(ab", 100.0, 16.0, segs, fixed(10.0))
    assert l.glyphs[0].x == 10.0  # '(' = 20 - 10
    assert l.glyphs[1].x == 20.0  # 'a' at left_indent edge


# ── Phase 10: Justify path via Knuth-Plass composer ──


def test_justify_ragged_last_line_keeps_natural_glue():
    segs = [ParagraphSegment(char_start=0, char_end=8,
                              text_align=TextAlign.JUSTIFY)]
    l = layout_with_paragraphs("ab cd ef", 100.0, 16.0, segs, fixed(10.0))
    # Single-line paragraph = "last line" => uses ragged-Left default.
    last = l.glyphs[-1]
    assert abs(last.right - 80.0) < 1e-6


def test_justify_all_stretches_last_line_to_fill_box():
    segs = [ParagraphSegment(char_start=0, char_end=8,
                              text_align=TextAlign.JUSTIFY,
                              last_line_align=TextAlign.JUSTIFY)]
    l = layout_with_paragraphs("ab cd ef", 100.0, 16.0, segs, fixed(10.0))
    last = l.glyphs[-1]
    assert abs(last.right - 100.0) < 1.0


def test_justify_two_lines_first_fills_second_ragged():
    segs = [ParagraphSegment(char_start=0, char_end=17,
                              text_align=TextAlign.JUSTIFY)]
    l = layout_with_paragraphs("ab cd ef gh ij kl", 100.0, 16.0, segs,
                                fixed(10.0))
    assert len(l.lines) >= 2
    line0 = l.lines[0]
    line0_right = max((g.right for g in l.glyphs[line0.glyph_start:line0.glyph_end]),
                       default=0.0)
    assert line0_right > 80.0
    last_line = l.lines[-1]
    last_right = max((g.right for g in l.glyphs[last_line.glyph_start:last_line.glyph_end]),
                      default=0.0)
    assert last_right <= 100.0 + 1e-6


def test_justify_preserves_char_count():
    segs = [ParagraphSegment(char_start=0, char_end=17,
                              text_align=TextAlign.JUSTIFY)]
    l = layout_with_paragraphs("ab cd ef gh ij kl", 100.0, 16.0, segs,
                                fixed(10.0))
    assert l.char_count == 17
    assert len(l.glyphs) == 17
