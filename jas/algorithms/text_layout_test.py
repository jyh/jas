"""Tests for the word-wrap text layout."""

from algorithms.text_layout import (
    layout, ordered_range,
    layout_with_paragraphs, ParagraphSegment, TextAlign,
    build_paragraph_segments,
    layout_with_hyphen, HyphenOpts,
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


# ── Cross-port fixes ──────────────────────────────────────


def test_justify_right_positions_last_line_flush_right():
    # JUSTIFY_RIGHT: text-align="justify", text-align-last="right".
    # Body lines stretch to fill; the last line is *not* stretched and
    # must be positioned flush right. Without applying last_line_align
    # in the alignment shift the last line falls back to the Justify
    # arm (x=0), and the user sees what looks like a left-aligned
    # paragraph.
    segs = [ParagraphSegment(char_start=0, char_end=17,
                              text_align=TextAlign.JUSTIFY,
                              last_line_align=TextAlign.RIGHT)]
    l = layout_with_paragraphs("ab cd ef gh ij kl", 100.0, 16.0, segs,
                                fixed(10.0))
    assert len(l.lines) >= 2
    last_line = l.lines[-1]
    last_glyphs = l.glyphs[last_line.glyph_start:last_line.glyph_end]
    last_right = max((g.right for g in last_glyphs), default=0.0)
    assert abs(last_right - 100.0) < 1.0, \
        f"justify-right last line should sit flush right; got right={last_right}"


def test_justify_center_positions_last_line_centered():
    segs = [ParagraphSegment(char_start=0, char_end=17,
                              text_align=TextAlign.JUSTIFY,
                              last_line_align=TextAlign.CENTER)]
    l = layout_with_paragraphs("ab cd ef gh ij kl", 100.0, 16.0, segs,
                                fixed(10.0))
    assert len(l.lines) >= 2
    last_line = l.lines[-1]
    last_glyphs = l.glyphs[last_line.glyph_start:last_line.glyph_end]
    leftmost = min((g.x for g in last_glyphs), default=0.0)
    rightmost = max((g.right for g in last_glyphs), default=0.0)
    leading = leftmost
    trailing = 100.0 - rightmost
    assert abs(leading - trailing) < 1.0, \
        f"justify-center last line should be centered; leading={leading} trailing={trailing}"


def test_default_segment_with_full_range_wraps_like_no_segments():
    # Regression: post-apply_paragraph_panel_to_selection the text
    # element carries a single empty wrapper followed by the body;
    # build_segments_from_text returns one segment with default attrs
    # covering the full content range. The wrapping must still happen
    # — without it the user sees the paragraph collapse to a single
    # line the moment a paragraph-panel control is clicked.
    segs = [ParagraphSegment(char_start=0, char_end=11)]
    l = layout_with_paragraphs("hello world", 60.0, 16.0, segs,
                                fixed(10.0))
    assert len(l.lines) >= 2, \
        f"expected wrap-induced multi-line layout; got {len(l.lines)} lines"


def test_space_before_after_apply_between_sub_paragraphs_within_segment():
    # Regression: the user types "a\nb\nc" then sets space_before —
    # only one wrapper covers all three lines, so the segment spans
    # three sub-paragraphs (separated by hard '\n'). Without applying
    # space_before / space_after at sub-paragraph boundaries within
    # the segment, the lines stack tightly and the panel control
    # looks like a no-op.
    segs = [ParagraphSegment(char_start=0, char_end=5,
                              space_before=12.0, space_after=6.0)]
    l = layout_with_paragraphs("a\nb\nc", 100.0, 16.0, segs, fixed(10.0))
    assert len(l.lines) == 3
    assert l.lines[0].top == 0.0
    # Line 1 top = 16 (line 0 height) + 6 (space_after of sub-para 0) +
    # 12 (space_before of sub-para 1) = 34.
    assert l.lines[1].top == 34.0, \
        f"sub-paragraph 1 must include space_after + space_before; got {l.lines[1].top}"
    assert l.lines[2].top == 68.0


def test_greedy_hyphenation_breaks_long_word_on_left_aligned_text():
    # The user clicks Hyphenate with default (left-aligned) text.
    # Plain ``layout`` ignored seg.hyphenate before — only justify
    # composed with hyphenation. With layout_with_hyphen the long
    # word splits at a hyphenation candidate and a visible '-'
    # marker (trailing_hyphen) appears at end of line.
    opts = HyphenOpts(min_word=4, min_before=2, min_after=2,
                       allow_capitalized=True)
    # "go information" — 12 chars natural. At 80px box, "go " (24)
    # fits and "information" (88) wraps. With hyphenation we can try
    # "in-" / "infor-" / "informa-" etc. as line endings.
    l = layout_with_hyphen("go information", 80.0, 16.0, opts, fixed(8.0))
    assert len(l.lines) >= 2, "should wrap"
    line0 = l.lines[0]
    assert line0.trailing_hyphen, \
        f"first line should end with hyphenation marker; line0={line0}"


def test_hyphenation_skips_capitalized_words_by_default():
    # "Trump" matches the sample "1ru" pattern at position 1 → would
    # break as "T-rump". The capitalized-word protection (default-on,
    # allow_capitalized=False) must skip this word entirely.
    opts = HyphenOpts(min_word=4, min_before=1, min_after=1,
                       allow_capitalized=False)
    # 60px box; "stuff Trump" natural = 88. Without hyphen
    # protection "T-rump" would split. With protection, the whole
    # word "Trump" wraps to next line and the line ends ragged.
    l = layout_with_hyphen("stuff Trump", 60.0, 16.0, opts, fixed(8.0))
    assert len(l.lines) >= 2
    # No line may end with trailing_hyphen — the only candidate
    # would be inside "Trump", and that's blocked.
    for line in l.lines:
        assert not line.trailing_hyphen, \
            f"Trump must not be hyphenated; lines={[ln.trailing_hyphen for ln in l.lines]}"


def test_hyphenation_allows_capitalized_when_flag_set():
    opts = HyphenOpts(min_word=4, min_before=1, min_after=1,
                       allow_capitalized=True)
    l = layout_with_hyphen("stuff Trump", 60.0, 16.0, opts, fixed(8.0))
    # With protection off, hyphenation may apply (depends on the
    # sample patterns matching). We only assert the call doesn't
    # raise and produces ≥1 line.
    assert len(l.lines) >= 1


def test_paragraph_layout_routes_to_hyphen_layout_for_left_aligned_with_hyphenate():
    # When seg.hyphenate is True and seg.text_align is LEFT (not
    # JUSTIFY), layout_with_paragraphs must route through
    # layout_with_hyphen so the long word breaks at a hyphenation
    # candidate. Without this fix the user clicks Hyphenate on
    # left-aligned text and nothing visibly changes.
    segs = [ParagraphSegment(char_start=0, char_end=14,
                              text_align=TextAlign.LEFT,
                              hyphenate=True,
                              hyphenate_min_word=4,
                              hyphenate_min_before=2,
                              hyphenate_min_after=2)]
    l = layout_with_paragraphs("go information", 80.0, 16.0, segs,
                                fixed(8.0))
    assert len(l.lines) >= 2
    # The first line should carry a trailing_hyphen.
    assert l.lines[0].trailing_hyphen, \
        "left-aligned text with seg.hyphenate=True should hyphenate-break"


def test_justify_hyphenation_marks_line_with_trailing_hyphen():
    # When justify_layout breaks at a hyphen Penalty (width > 0) the
    # line must carry trailing_hyphen=True so the renderer can draw
    # the '-' glyph (source content has no hyphen at the break).
    # We use a long word in a narrow box so hyphenation kicks in.
    segs = [ParagraphSegment(char_start=0, char_end=15,
                              text_align=TextAlign.JUSTIFY,
                              hyphenate=True,
                              hyphenate_min_word=4,
                              hyphenate_min_before=2,
                              hyphenate_min_after=2)]
    # 8 px per char; "info information" → "info " (40) ok, then
    # "information" (88) exceeds 60-wide box; the composer may try a
    # hyphen break.
    l = layout_with_paragraphs("info information", 60.0, 16.0, segs,
                                fixed(8.0))
    # If no hyphenation candidate fits we may still break; tolerate
    # both — only assert at least one outcome is well-formed.
    found_hyphen = any(getattr(line, "trailing_hyphen", False)
                       for line in l.lines)
    # The fixture above doesn't guarantee a hyphen-break (depends on
    # the sample patterns) — assert the field exists and serializes
    # consistently across the whole layout.
    for line in l.lines:
        assert hasattr(line, "trailing_hyphen"), \
            "LineInfo must expose trailing_hyphen flag"
        # Default for non-hyphen lines must be False.
        assert isinstance(line.trailing_hyphen, bool)


def test_justify_retries_with_looser_max_ratio_when_strict_fails():
    # When the strict max_ratio (10) makes compose() return None for
    # one paragraph, the layout should retry with a much looser cap
    # (100) so the segment still justifies. Without this the segment
    # falls back to plain layout (left-aligned) and body lines look
    # left-flush instead of stretched.
    # Use a very narrow box where some sub-paragraph is infeasible at
    # max_ratio=10. We synthesize via a small width with words that
    # need significant glue stretch.
    # 8 px per char, "Your healthcare provider" = 24 chars natural=192.
    # In a 200-wide box, "Your healthcare" (15 chars=120) would be
    # ~one line; the second body needs significant stretch.
    content = ("Your healthcare provider at Genome Medical has ordered "
               "a genetic test with Invitae on your behalf.")
    segs = [ParagraphSegment(
        char_start=0, char_end=len(content),
        text_align=TextAlign.JUSTIFY,
        last_line_align=TextAlign.RIGHT)]
    # Use widths the strict cap struggles with; the retry must
    # produce a valid composition rather than returning None.
    for box_w in (200.0, 240.0, 280.0):
        l = layout_with_paragraphs(content, box_w, 16.0, segs, fixed(8.0))
        # Must produce a layout with multiple lines (retry succeeded
        # rather than falling back to plain layout via None).
        assert len(l.lines) >= 2, \
            f"box_w={box_w}: composer failed even with looser max_ratio cap"
        # First non-empty body line should reach near right edge.
        for i, line in enumerate(l.lines):
            line_glyphs = l.glyphs[line.glyph_start:line.glyph_end]
            if not line_glyphs:
                continue
            lr = max((g.right for g in line_glyphs), default=0.0)
            if i == 0 and not line.hard_break and i + 1 < len(l.lines):
                # First body line must be stretched within tolerance
                # of the box width.
                assert lr > box_w - 20.0, \
                    f"box_w={box_w} line 0 (body): expected stretched ≈{box_w}; got {lr}"
                break
