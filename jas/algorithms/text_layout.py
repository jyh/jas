"""Word-wrapped text layout with per-character hit testing.

Pure layout: takes a `measure(s) -> float` callable that returns the pixel
width of a string and produces glyphs and lines. The closure can be backed
by Qt's `QFontMetricsF.horizontalAdvance` in production and a deterministic
stub in tests.

For point text (`max_width <= 0`) wrapping is disabled; only hard `\\n`
splits lines. For area text wrapping breaks on whitespace runs. A word
longer than `max_width` is broken at character boundaries. All character
indices are *Python str indices* (which are also code-point indices).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from collections.abc import Callable


@dataclass
class Glyph:
    idx: int
    line: int
    x: float
    right: float
    baseline_y: float
    top: float
    height: float
    is_trailing_space: bool = False


@dataclass
class LineInfo:
    start: int
    end: int
    hard_break: bool
    top: float
    baseline_y: float
    height: float
    width: float
    # Index range into `TextLayout.glyphs` for this line. Filled in at
    # the end of `layout()` so cursor/hit_test can slice in O(line)
    # rather than filtering the whole glyph list.
    glyph_start: int = 0
    glyph_end: int = 0
    # True when the line was wrapped at a hyphenation breakpoint
    # inside a word — the renderer must append a visible hyphen
    # glyph at the line's end. The synthetic hyphen advance is
    # already baked into the line's last visible glyph's `right`.
    trailing_hyphen: bool = False


@dataclass
class TextLayout:
    glyphs: list[Glyph] = field(default_factory=list)
    lines: list[LineInfo] = field(default_factory=list)
    font_size: float = 0.0
    char_count: int = 0

    def cursor_xy(self, cursor: int) -> tuple[float, float, float]:
        cursor = min(cursor, self.char_count)
        line_no = self.line_for_cursor(cursor)
        line = self.lines[line_no]
        height = line.height
        baseline_y = line.baseline_y
        line_glyphs = self.glyphs[line.glyph_start:line.glyph_end]
        if cursor == line.start:
            return (0.0, baseline_y, height)
        if cursor >= line.end:
            x = line_glyphs[-1].right if line_glyphs else 0.0
            return (x, baseline_y, height)
        for g in line_glyphs:
            if g.idx == cursor:
                return (g.x, baseline_y, height)
        return (0.0, baseline_y, height)

    def line_for_cursor(self, cursor: int) -> int:
        for i, l in enumerate(self.lines):
            if cursor < l.end:
                return i
            if cursor == l.end:
                if l.hard_break:
                    return i
                if i == len(self.lines) - 1:
                    return i
                return i + 1
        return len(self.lines) - 1

    def hit_test(self, x: float, y: float) -> int:
        if not self.lines:
            return 0
        line_no = len(self.lines) - 1
        for i, l in enumerate(self.lines):
            if y < l.top + l.height:
                line_no = i
                break
        line = self.lines[line_no]
        glyphs_on_line = [g for g in self.glyphs[line.glyph_start:line.glyph_end]
                          if not g.is_trailing_space]
        if not glyphs_on_line:
            return line.start
        if x <= glyphs_on_line[0].x:
            return line.start
        for g in glyphs_on_line:
            mid = (g.x + g.right) / 2.0
            if x < mid:
                return g.idx
        last_visible = glyphs_on_line[-1].idx + 1
        if line.hard_break:
            return line.end
        return max(line.start, min(last_visible, line.end))

    def cursor_up(self, cursor: int) -> int:
        line_no = self.line_for_cursor(cursor)
        if line_no == 0:
            return 0
        x, _, _ = self.cursor_xy(cursor)
        return self._cursor_at_line_x(line_no - 1, x)

    def cursor_down(self, cursor: int) -> int:
        line_no = self.line_for_cursor(cursor)
        if line_no + 1 >= len(self.lines):
            return self.char_count
        x, _, _ = self.cursor_xy(cursor)
        return self._cursor_at_line_x(line_no + 1, x)

    def _cursor_at_line_x(self, line_no: int, target_x: float) -> int:
        line = self.lines[line_no]
        glyphs_on_line = [g for g in self.glyphs[line.glyph_start:line.glyph_end]
                          if not g.is_trailing_space]
        if not glyphs_on_line:
            return line.start
        if target_x <= glyphs_on_line[0].x:
            return line.start
        for g in glyphs_on_line:
            mid = (g.x + g.right) / 2.0
            if target_x < mid:
                return g.idx
        return line.end


@dataclass
class HyphenOpts:
    """Hyphenation options for greedy (non-justify) layout. When
    passed to :func:`layout_with_hyphen`, the layout will try to
    break long words at hyphenation candidates instead of wrapping
    the whole word to the next line. Mirrors Rust ``HyphenOpts``."""
    min_word: int = 6
    min_before: int = 2
    min_after: int = 2
    # When False, words starting with an uppercase letter are
    # excluded from hyphenation (proper-noun protection).
    allow_capitalized: bool = False


def layout(content: str, max_width: float, font_size: float,
           measure: Callable[[str], float],
           first_line_extra: float = 0.0) -> TextLayout:
    return _layout_inner(content, max_width, font_size, None, measure,
                         first_line_extra)


def layout_with_hyphen(content: str, max_width: float, font_size: float,
                        opts: HyphenOpts,
                        measure: Callable[[str], float],
                        first_line_extra: float = 0.0) -> TextLayout:
    """Variant of :func:`layout` that consults hyphenation patterns
    when a non-whitespace token doesn't fit on the current line.
    Used by :func:`layout_with_paragraphs` for non-justify segments
    where ``seg.hyphenate`` is set. Mirrors Rust
    ``layout_with_hyphen``."""
    return _layout_inner(content, max_width, font_size, opts, measure,
                         first_line_extra)


def _layout_inner(content: str, max_width: float, font_size: float,
                   hyph_opts: HyphenOpts | None,
                   measure: Callable[[str], float],
                   first_line_extra: float = 0.0) -> TextLayout:
    line_height = font_size
    ascent = font_size * 0.8
    glyphs: list[Glyph] = []
    lines: list[LineInfo] = []
    chars = list(content)
    n = len(chars)
    idx = 0
    line_no = 0
    line_start_char = 0
    x = 0.0

    # First line is shifted right by ``first_line_extra`` (positive
    # for indent, the negative-hanging case is handled by the segment
    # caller). To keep the line from running past the right edge we
    # narrow the wrap width for that line only.
    def _line_max(ln: int) -> float:
        if max_width <= 0.0:
            return max_width
        if ln == 0 and first_line_extra > 0.0:
            return max(0.0, max_width - first_line_extra)
        return max_width

    def push_line(start: int, end: int, hard_break: bool, line_width: float,
                   trailing_hyphen: bool = False) -> None:
        top = line_no * line_height
        lines.append(LineInfo(
            start=start, end=end, hard_break=hard_break,
            top=top, baseline_y=top + ascent,
            height=line_height, width=line_width,
            trailing_hyphen=trailing_hyphen,
        ))

    while idx < n:
        if chars[idx] == '\n':
            push_line(line_start_char, idx, True, x)
            line_no += 1
            line_start_char = idx + 1
            x = 0.0
            idx += 1
            continue
        is_ws = chars[idx].isspace()
        end = idx + 1
        while end < n and chars[end] != '\n' and chars[end].isspace() == is_ws:
            end += 1
        token = ''.join(chars[idx:end])
        token_w = measure(token)

        if is_ws:
            for k, ch in enumerate(token):
                cw = measure(ch)
                glyphs.append(Glyph(
                    idx=idx + k, line=line_no, x=x, right=x + cw,
                    baseline_y=line_no * line_height + ascent,
                    top=line_no * line_height, height=line_height,
                ))
                x += cw
            idx = end
            continue

        if max_width > 0.0 and x + token_w > _line_max(line_no) and x > 0.0:
            # Hyphenation: try to split the token at a hyphenation
            # breakpoint that fits on the current line. Picks the
            # *largest* prefix that still leaves room for the hyphen,
            # greedy-style. If no break fits, falls through to the
            # standard wrap below. Mirrors Rust ``layout_inner``
            # hyphenation branch.
            hyphen_split: tuple[int, float] | None = None
            if hyph_opts is not None:
                token_chars = list(token)
                starts_capital = (len(token_chars) > 0
                                   and token_chars[0].isupper())
                allowed = (len(token_chars) >= hyph_opts.min_word
                           and (hyph_opts.allow_capitalized
                                or not starts_capital))
                if allowed:
                    from algorithms.hyphenator import (
                        EN_US_PATTERNS_SAMPLE as _EN, hyphenate as _hyph,
                    )
                    breaks = _hyph(token, _EN,
                                    hyph_opts.min_before,
                                    hyph_opts.min_after)
                    hyphen_w = measure("-")
                    avail = _line_max(line_no) - x
                    # Try the largest valid break point first.
                    for bi in range(len(token_chars) - 1, 0, -1):
                        if not (bi < len(breaks) and breaks[bi]):
                            continue
                        prefix = "".join(token_chars[:bi])
                        prefix_w = measure(prefix)
                        if prefix_w + hyphen_w <= avail:
                            hyphen_split = (bi, prefix_w)
                            break

            if hyphen_split is not None:
                split_at, _prefix_w = hyphen_split
                token_chars = list(token)
                # Emit the prefix glyphs on the current line, then the
                # synthetic hyphen, then wrap.
                for k in range(split_at):
                    cw = measure(token_chars[k])
                    glyphs.append(Glyph(
                        idx=idx + k, line=line_no, x=x, right=x + cw,
                        baseline_y=line_no * line_height + ascent,
                        top=line_no * line_height, height=line_height,
                    ))
                    x += cw
                hyphen_w = measure("-")
                # Synthetic hyphen glyph carries idx = split_at break
                # point so hit-test still maps to a real char. The
                # renderer recognises trailing_hyphen on the line and
                # draws the visible '-' here.
                glyphs.append(Glyph(
                    idx=idx + split_at, line=line_no,
                    x=x, right=x + hyphen_w,
                    baseline_y=line_no * line_height + ascent,
                    top=line_no * line_height, height=line_height,
                ))
                line_w = x + hyphen_w
                push_line(line_start_char, idx + split_at, False, line_w,
                           trailing_hyphen=True)
                line_no += 1
                line_start_char = idx + split_at
                x = 0.0
                # Place the tail token starting at x=0.
                tail_chars = token_chars[split_at:]
                tail_w = sum(measure(c) for c in tail_chars)
                if max_width > 0.0 and tail_w > _line_max(line_no):
                    # Char-by-char break.
                    for k, ch in enumerate(tail_chars):
                        cw = measure(ch)
                        if x + cw > _line_max(line_no) and x > 0.0:
                            push_line(line_start_char, idx + split_at + k,
                                       False, x)
                            line_no += 1
                            line_start_char = idx + split_at + k
                            x = 0.0
                        glyphs.append(Glyph(
                            idx=idx + split_at + k, line=line_no,
                            x=x, right=x + cw,
                            baseline_y=line_no * line_height + ascent,
                            top=line_no * line_height, height=line_height,
                        ))
                        x += cw
                else:
                    cur_x = x
                    for k, ch in enumerate(tail_chars):
                        cw = measure(ch)
                        glyphs.append(Glyph(
                            idx=idx + split_at + k, line=line_no,
                            x=cur_x, right=cur_x + cw,
                            baseline_y=line_no * line_height + ascent,
                            top=line_no * line_height, height=line_height,
                        ))
                        cur_x += cw
                    x = cur_x
                idx = end
                continue

            # No hyphenation break fits — fall through to standard
            # wrap-before-token path.
            for g in reversed(glyphs):
                if g.line != line_no:
                    break
                if not chars[g.idx].isspace():
                    break
                g.is_trailing_space = True
            push_line(line_start_char, idx, False, x)
            line_no += 1
            line_start_char = idx
            x = 0.0

        if max_width > 0.0 and token_w > _line_max(line_no) and x == 0.0:
            for k, ch in enumerate(token):
                cw = measure(ch)
                if x + cw > _line_max(line_no) and x > 0.0:
                    push_line(line_start_char, idx + k, False, x)
                    line_no += 1
                    line_start_char = idx + k
                    x = 0.0
                glyphs.append(Glyph(
                    idx=idx + k, line=line_no, x=x, right=x + cw,
                    baseline_y=line_no * line_height + ascent,
                    top=line_no * line_height, height=line_height,
                ))
                x += cw
        else:
            cur_x = x
            for k, ch in enumerate(token):
                cw = measure(ch)
                glyphs.append(Glyph(
                    idx=idx + k, line=line_no, x=cur_x, right=cur_x + cw,
                    baseline_y=line_no * line_height + ascent,
                    top=line_no * line_height, height=line_height,
                ))
                cur_x += cw
            x = cur_x

        idx = end

    push_line(line_start_char, n, False, x)
    if not lines:
        push_line(0, 0, False, 0.0)

    # Fill glyph_start/glyph_end for each line by sweeping the glyph
    # list once. Glyphs are emitted in line order.
    gi = 0
    for li, line in enumerate(lines):
        line.glyph_start = gi
        while gi < len(glyphs) and glyphs[gi].line == li:
            gi += 1
        line.glyph_end = gi

    return TextLayout(glyphs=glyphs, lines=lines, font_size=font_size, char_count=n)


def ordered_range(a: int, b: int) -> tuple[int, int]:
    return (a, b) if a <= b else (b, a)


# ── Phase 5 paragraph-aware layout ──────────────────────────

from enum import Enum


class TextAlign(Enum):
    """Horizontal alignment within a paragraph's effective box (the
    box width minus left/right indents). Phase 10 lights up
    ``JUSTIFY`` for area text via the every-line composer; point
    text and text-on-path coerce ``justify`` back to ``LEFT``."""
    LEFT = "left"
    CENTER = "center"
    RIGHT = "right"
    JUSTIFY = "justify"


@dataclass
class ParagraphSegment:
    """Per-paragraph layout constraints derived from the wrapper
    tspan attributes (or panel defaults when there is no wrapper).
    All indent / space values are in pixels."""
    char_start: int = 0
    char_end: int = 0
    left_indent: float = 0.0
    right_indent: float = 0.0
    # text-indent — additional x offset on the *first* line only.
    # Signed; negative produces a hanging indent. Phase 5 supports
    # non-negative values; negative falls back to 0. Ignored when
    # ``list_style`` is non-None per PARAGRAPH.md §Marker rendering.
    first_line_indent: float = 0.0
    # jas:space-before — extra vertical gap above this paragraph.
    # Always 0 for the first paragraph in the element.
    space_before: float = 0.0
    space_after: float = 0.0
    text_align: TextAlign = TextAlign.LEFT
    # jas:list-style — Phase 6. When non-None, the paragraph is a
    # list item: the layout pushes every line by an extra
    # ``marker_gap`` (so the marker has room before the text) and
    # ignores ``first_line_indent``. The marker glyph itself is
    # drawn at ``x = left_indent`` by the renderer.
    list_style: str | None = None
    # Gap between marker and text. Phase 6 uses a fixed 12pt per
    # PARAGRAPH.md §Marker rendering.
    marker_gap: float = 0.0
    # jas:hanging-punctuation — Phase 7. When True, hangable chars
    # at line start / end offset outside the effective edge by their
    # own advance width per PARAGRAPH.md §Hanging Punctuation.
    # Alignment interaction: left-aligned hangs only left side,
    # right-aligned only right, centered both.
    hanging_punctuation: bool = False
    # ── Phase 10: Justification dialog soft constraints ──
    word_spacing_min: float = 80.0
    word_spacing_desired: float = 100.0
    word_spacing_max: float = 133.0
    last_line_align: "TextAlign" = TextAlign.LEFT
    # ── Phase 10: Hyphenation dialog wiring ──
    hyphenate: bool = False
    # Defaults match Illustrator / InDesign Hyphenation dialog:
    # 6 / 2 / 2. The previous 3 / 1 / 1 was loose enough that the
    # sample pattern set produced "T-rump" (matching ".un1" / "1ru"
    # patterns at min_before=1).
    hyphenate_min_word: int = 6
    hyphenate_min_before: int = 2
    hyphenate_min_after: int = 2
    # 0 (Better Spacing) ... 6 (Fewer Hyphens)
    hyphenate_bias: int = 0
    # ``jas:hyphenate-capitalized`` — when False (the default in
    # Illustrator / InDesign / Word), proper nouns and other words
    # starting with an uppercase letter are NOT broken at
    # hyphenation candidates. Avoids breaks like "T-rump".
    hyphenate_capitalized: bool = False


def _trimmed_line_width(line: LineInfo, glyphs: list[Glyph]) -> float:
    """Visible width of a line: max ``right`` of any non-trailing-
    whitespace glyph, or 0 when the line has none."""
    w = 0.0
    for g in glyphs[line.glyph_start:line.glyph_end]:
        if not g.is_trailing_space and g.right > w:
            w = g.right
    return w


def layout_with_paragraphs(
    content: str,
    max_width: float,
    font_size: float,
    paragraphs: list[ParagraphSegment],
    measure: Callable[[str], float],
) -> TextLayout:
    """Paragraph-aware layout. For each segment lays out the covered
    slice with the segment's effective wrap width
    (``max_width - left_indent - right_indent``), inserts
    ``space_before`` / ``space_after`` vertical gaps between
    paragraphs (the very first paragraph's ``space_before`` is
    always skipped per PARAGRAPH.md §SVG attribute mapping), shifts
    the first line by ``first_line_indent``, and applies the
    segment's horizontal alignment.

    ``paragraphs`` must be ordered by ``char_start``; gaps and
    content past the last segment fall back to a default paragraph.
    When empty the entire content is one default paragraph —
    equivalent to calling :func:`layout`.

    Phase 5: alignment supports ``LEFT`` / ``CENTER`` / ``RIGHT``.
    The four ``JUSTIFY_*`` modes fall back to ``LEFT``."""
    chars = list(content)
    n = len(chars)
    line_height = font_size
    ascent = font_size * 0.8

    # Build the effective segment list: gap-fill so every char is
    # covered exactly once.
    segs: list[ParagraphSegment] = []
    cursor = 0
    for p in paragraphs:
        s = min(max(p.char_start, cursor), n)
        e = min(max(p.char_end, s), n)
        if s > cursor:
            segs.append(ParagraphSegment(char_start=cursor, char_end=s))
        if e > s:
            seg = ParagraphSegment(
                char_start=s, char_end=e,
                left_indent=p.left_indent, right_indent=p.right_indent,
                first_line_indent=p.first_line_indent,
                space_before=p.space_before, space_after=p.space_after,
                text_align=p.text_align,
                list_style=p.list_style, marker_gap=p.marker_gap,
                hanging_punctuation=p.hanging_punctuation,
                word_spacing_min=p.word_spacing_min,
                word_spacing_desired=p.word_spacing_desired,
                word_spacing_max=p.word_spacing_max,
                last_line_align=p.last_line_align,
                hyphenate=p.hyphenate,
                hyphenate_min_word=p.hyphenate_min_word,
                hyphenate_min_before=p.hyphenate_min_before,
                hyphenate_min_after=p.hyphenate_min_after,
                hyphenate_bias=p.hyphenate_bias,
                hyphenate_capitalized=p.hyphenate_capitalized)
            segs.append(seg)
        cursor = e
    if cursor < n:
        segs.append(ParagraphSegment(char_start=cursor, char_end=n))
    if not segs:
        segs.append(ParagraphSegment(char_start=0, char_end=n))

    all_glyphs: list[Glyph] = []
    all_lines: list[LineInfo] = []
    y_offset = 0.0
    line_count = 0

    for pi, seg in enumerate(segs):
        if pi > 0:
            y_offset += seg.space_before
        slice_str = ''.join(chars[seg.char_start:seg.char_end])
        # Phase 6: an active list adds marker_gap to the effective
        # left indent (so the marker has room before the text) AND
        # suppresses first_line_indent — the marker already occupies
        # the first-line position so a separate first-line offset
        # would push the text away from the marker.
        has_list = seg.list_style is not None
        list_indent = seg.marker_gap if has_list else 0.0
        effective_max = max(
            0.0, max_width - seg.left_indent - list_indent - seg.right_indent
        ) if max_width > 0.0 else 0.0
        # Negative first_line_indent (hanging indent) shifts the
        # first line LEFT of the left-indent edge — keep the sign so
        # the per-line offset can hang. Pulling the first line into
        # negative x relies on the segment's left_indent being large
        # enough to hold it; clipping is a UI concern handled outside
        # the layout. Mirrors OCaml text_layout.ml.
        first_line_extra = 0.0 if has_list else seg.first_line_indent
        # Phase 10: justify segments go through the every-line composer
        # instead of greedy first-fit. Falls back to greedy when the
        # composer can't find a feasible composition.
        para: TextLayout
        if seg.text_align == TextAlign.JUSTIFY and effective_max > 0.0:
            kp_para = _justify_layout_segment(slice_str, effective_max,
                                                font_size, seg, measure,
                                                first_line_extra)
            para = kp_para if kp_para is not None else layout(
                slice_str, effective_max, font_size, measure,
                first_line_extra)
        elif seg.hyphenate and effective_max > 0.0:
            # Non-justify segment with hyphenate enabled: greedy
            # layout with the hyphenation-aware breakpoint search.
            opts = HyphenOpts(
                min_word=seg.hyphenate_min_word,
                min_before=seg.hyphenate_min_before,
                min_after=seg.hyphenate_min_after,
                allow_capitalized=getattr(seg, "hyphenate_capitalized", False))
            para = layout_with_hyphen(slice_str, effective_max,
                                       font_size, opts, measure,
                                       first_line_extra)
        else:
            para = layout(slice_str, effective_max, font_size, measure,
                          first_line_extra)
        first_line_no_in_combined = line_count
        # A segment may span multiple sub-paragraphs (the user typed
        # "a\nb\nc" then applied panel attrs — one wrapper covers all
        # three). space_before / space_after are paragraph attributes,
        # so they must apply between each sub-paragraph too, not just
        # between top-level segments. Accumulates as we cross hard
        # breaks within the segment.
        sub_para_delta = 0.0
        for li, line in enumerate(para.lines):
            if li > 0 and para.lines[li - 1].hard_break:
                sub_para_delta += seg.space_after + seg.space_before
            x_shift = seg.left_indent + list_indent \
                + (first_line_extra if li == 0 else 0.0)
            line_avail = max(0.0, effective_max - (first_line_extra if li == 0 else 0.0)) \
                if effective_max > 0.0 else 0.0
            visible_w = _trimmed_line_width(line, para.glyphs)
            # Phase 7: hanging punctuation. Offset hangable chars at
            # line start / end outside the effective edge per
            # PARAGRAPH.md §Hanging Punctuation. Alignment per spec:
            # left-aligned hangs only left, right-aligned only right,
            # centered both.
            left_hang_w = 0.0
            right_hang_w = 0.0
            if seg.hanging_punctuation:
                # Justify is treated like Left/Center for left-edge
                # hangs: the body composer stretches the line to fill
                # the max width, but leading punctuation should still
                # hang into the margin so the visible left edge of the
                # paragraph is straight. Right hangs on Justify body
                # lines need composer support and stay disabled.
                allow_left = seg.text_align in (
                    TextAlign.LEFT, TextAlign.CENTER, TextAlign.JUSTIFY)
                allow_right = seg.text_align in (TextAlign.RIGHT, TextAlign.CENTER)
                line_glyphs = para.glyphs[line.glyph_start:line.glyph_end]
                first_g = next((g for g in line_glyphs if not g.is_trailing_space), None)
                last_g = next((g for g in reversed(line_glyphs) if not g.is_trailing_space), None)
                if allow_left and first_g is not None:
                    c = chars[seg.char_start + first_g.idx]
                    if is_left_hanger(c):
                        left_hang_w = first_g.right - first_g.x
                if allow_right and last_g is not None:
                    c = chars[seg.char_start + last_g.idx]
                    if is_right_hanger(c):
                        right_hang_w = last_g.right - last_g.x
            effective_visible_w = max(0.0, visible_w - left_hang_w - right_hang_w)
            # For a justified segment the body lines are stretched to
            # fill the line width by the composer, so a Justify-arm
            # shift of 0 leaves them flush with both edges. The LAST
            # line of each sub-paragraph (line ending in '\n', plus
            # the segment's overall final line) is *not* stretched, so
            # it needs to be positioned per ``seg.last_line_align``.
            # Without the hard_break check the last visible line of
            # the first sub-paragraph stays left-aligned even when the
            # user picked Justify Center / Right.
            is_last_line_of_segment = (li + 1 == len(para.lines))
            is_last_line_of_subparagraph = line.hard_break
            if (seg.text_align == TextAlign.JUSTIFY
                    and (is_last_line_of_segment
                         or is_last_line_of_subparagraph)):
                effective_align = seg.last_line_align
            else:
                effective_align = seg.text_align
            if effective_align == TextAlign.CENTER:
                align_shift = (line_avail - effective_visible_w) / 2.0 - left_hang_w \
                    if line_avail > effective_visible_w else -left_hang_w
            elif effective_align == TextAlign.RIGHT:
                align_shift = line_avail - effective_visible_w \
                    if line_avail > effective_visible_w else 0.0
            else:
                # LEFT or JUSTIFY: ragged left edge (or justify-already-
                # applied-by-composer to fill the box).
                align_shift = -left_hang_w
            total_shift = x_shift + align_shift
            orig_start = seg.char_start + line.start
            orig_end = seg.char_start + line.end
            top = y_offset + line.top + sub_para_delta
            baseline = y_offset + line.baseline_y + sub_para_delta
            glyph_start = len(all_glyphs)
            for g in para.glyphs[line.glyph_start:line.glyph_end]:
                all_glyphs.append(Glyph(
                    idx=seg.char_start + g.idx,
                    line=first_line_no_in_combined + li,
                    x=g.x + total_shift,
                    right=g.right + total_shift,
                    baseline_y=g.baseline_y + y_offset + sub_para_delta,
                    top=g.top + y_offset + sub_para_delta,
                    height=g.height,
                    is_trailing_space=g.is_trailing_space))
            glyph_end = len(all_glyphs)
            all_lines.append(LineInfo(
                start=orig_start, end=orig_end,
                hard_break=line.hard_break,
                top=top, baseline_y=baseline,
                height=line.height,
                width=visible_w + total_shift,
                glyph_start=glyph_start, glyph_end=glyph_end,
                trailing_hyphen=line.trailing_hyphen))
            line_count += 1
        if para.lines:
            y_offset += len(para.lines) * line_height + sub_para_delta
        y_offset += seg.space_after

    if not all_lines:
        # Empty content — keep single-empty-line invariant.
        all_lines.append(LineInfo(
            start=0, end=0, hard_break=False,
            top=0.0, baseline_y=ascent, height=line_height, width=0.0))

    return TextLayout(glyphs=all_glyphs, lines=all_lines,
                      font_size=font_size, char_count=n)


def build_paragraph_segments(
    tspans: tuple,  # tuple[Tspan, ...] — avoid circular import
    content: str,
    is_area: bool,
) -> list[ParagraphSegment]:
    """Build [ParagraphSegment] list from a Text/TextPath's tspans.
    Each tspan whose ``jas_role == "paragraph"`` is a wrapper that
    opens a new segment. Returns ``[]`` when no wrapper is present
    (caller falls back to default-paragraph layout)."""
    total_chars = len(content)
    segs: list[ParagraphSegment] = []
    cursor = 0
    current: ParagraphSegment | None = None
    for t in tspans:
        body_chars = len(t.content)
        if t.jas_role == "paragraph":
            if current is not None:
                current.char_end = cursor
                if current.char_end > current.char_start:
                    segs.append(current)
            list_style = t.jas_list_style
            marker_gap = MARKER_GAP_PT if list_style is not None else 0.0
            ta = _text_align_from(t.text_align, is_area)
            lla = _last_line_align_from(t.text_align_last, ta, is_area)
            _ws_min = t.jas_word_spacing_min if t.jas_word_spacing_min is not None else 80.0
            _ws_des = t.jas_word_spacing_desired if t.jas_word_spacing_desired is not None else 100.0
            _ws_max = t.jas_word_spacing_max if t.jas_word_spacing_max is not None else 133.0
            # Sanity-clamp: jas_word_spacing_desired out of [min,max] is
            # invalid data and would produce 0-width or negative glue,
            # squashing words together. Snap into range.
            if _ws_des < _ws_min:
                _ws_des = _ws_min
            if _ws_des > _ws_max:
                _ws_des = _ws_max
            current = ParagraphSegment(
                char_start=cursor, char_end=cursor,
                left_indent=t.jas_left_indent or 0.0,
                right_indent=t.jas_right_indent or 0.0,
                first_line_indent=t.text_indent or 0.0,
                space_before=t.jas_space_before or 0.0,
                space_after=t.jas_space_after or 0.0,
                text_align=ta,
                list_style=list_style, marker_gap=marker_gap,
                hanging_punctuation=bool(t.jas_hanging_punctuation),
                word_spacing_min=_ws_min,
                word_spacing_desired=_ws_des,
                word_spacing_max=_ws_max,
                last_line_align=lla,
                hyphenate=bool(t.jas_hyphenate),
                # Defaults match Illustrator / InDesign Hyphenation
                # dialog: 6 / 2 / 2 (was 3 / 1 / 1, which broke
                # "T-rump" via the sample pattern set).
                hyphenate_min_word=int(t.jas_hyphenate_min_word) if t.jas_hyphenate_min_word is not None else 6,
                hyphenate_min_before=int(t.jas_hyphenate_min_before) if t.jas_hyphenate_min_before is not None else 2,
                hyphenate_min_after=int(t.jas_hyphenate_min_after) if t.jas_hyphenate_min_after is not None else 2,
                hyphenate_bias=int(t.jas_hyphenate_bias) if t.jas_hyphenate_bias is not None else 0,
                # Capitalized words (proper nouns) excluded from
                # hyphenation by default per Illustrator / InDesign /
                # Word convention.
                hyphenate_capitalized=bool(t.jas_hyphenate_capitalized) if t.jas_hyphenate_capitalized is not None else False)
        else:
            cursor += body_chars
    if current is not None:
        current.char_end = min(cursor, total_chars)
        if current.char_end > current.char_start:
            segs.append(current)
    return segs


def _text_align_from(value: str | None, is_area: bool) -> TextAlign:
    """Map the wrapper tspan's ``text-align`` string to a TextAlign.
    Phase 10 promotes ``justify`` to ``JUSTIFY`` for area text;
    point text and text-on-path coerce ``justify`` back to LEFT."""
    if value == "center":
        return TextAlign.CENTER
    if value == "right":
        return TextAlign.RIGHT
    if value == "justify" and is_area:
        return TextAlign.JUSTIFY
    return TextAlign.LEFT


def _last_line_align_from(value: str | None, base: TextAlign,
                           is_area: bool) -> TextAlign:
    """Map the wrapper tspan's ``text-align-last`` string to the
    last-line alignment of a justified paragraph. Ignored when the
    paragraph isn't justified."""
    if base != TextAlign.JUSTIFY or not is_area:
        return TextAlign.LEFT
    if value == "center":
        return TextAlign.CENTER
    if value == "right":
        return TextAlign.RIGHT
    if value == "justify":
        return TextAlign.JUSTIFY
    return TextAlign.LEFT


# ── Phase 7: hanging punctuation char-class predicates ──────

# Open-side hangers: straight quotes (both sides), left curly /
# angle quotes, open brackets.
_LEFT_HANGERS = frozenset({
    '"', "'",
    "\u201C", "\u2018",      # left curly double / single quote
    "\u00AB", "\u2039",      # left angle double / single
    "(", "[", "{",
})

# Close-side hangers: straight quotes, right curly / angle quotes,
# close brackets, period / comma, hyphen / en dash / em dash. Dashes
# only ever hang at end-of-line — the layout consults this on the
# last visible glyph so that constraint is implicit.
_RIGHT_HANGERS = frozenset({
    '"', "'",
    "\u201D", "\u2019",      # right curly double / single quote
    "\u00BB", "\u203A",      # right angle double / single
    ")", "]", "}",
    ".", ",",
    "-", "\u2013", "\u2014",
})


def is_left_hanger(c: str) -> bool:
    """True if ``c`` may hang into the left margin per
    PARAGRAPH.md §Hanging Punctuation."""
    return c in _LEFT_HANGERS


def is_right_hanger(c: str) -> bool:
    """True if ``c`` may hang into the right margin per
    PARAGRAPH.md §Hanging Punctuation."""
    return c in _RIGHT_HANGERS


# ── Phase 6: list markers + counter run rule ────────────────

MARKER_GAP_PT: float = 12.0
"""Gap between marker and text per PARAGRAPH.md §Marker rendering."""


def to_alpha(n: int, upper: bool) -> str:
    """1 → 'a', 26 → 'z', 27 → 'aa', 28 → 'ab', ... Spreadsheet-
    style base-26 with no zero digit. ``upper`` capitalises."""
    if n <= 0:
        return ""
    base = ord("A") if upper else ord("a")
    chars = []
    v = n
    while v > 0:
        v -= 1
        chars.append(chr(base + (v % 26)))
        v //= 26
    return "".join(reversed(chars))


def to_roman(n: int, upper: bool) -> str:
    """1 → 'i', 4 → 'iv', 9 → 'ix', 1990 → 'mcmxc'. Above 3999
    falls back to ``(N)`` since standard Roman tops out at MMMCMXCIX."""
    if n <= 0:
        return ""
    if n > 3999:
        return f"({n})"
    pairs = [
        (1000, "M", "m"), (900, "CM", "cm"),
        (500, "D", "d"),  (400, "CD", "cd"),
        (100, "C", "c"),  (90, "XC", "xc"),
        (50, "L", "l"),   (40, "XL", "xl"),
        (10, "X", "x"),   (9, "IX", "ix"),
        (5, "V", "v"),    (4, "IV", "iv"),
        (1, "I", "i"),
    ]
    out = []
    v = n
    for val, u, l in pairs:
        while v >= val:
            out.append(u if upper else l)
            v -= val
    return "".join(out)


def marker_text(list_style: str, counter: int) -> str:
    """The literal glyph string that renders as the marker for the
    given ``jas:list-style`` value at 1-based ``counter``. Bullet
    styles ignore the counter; numbered styles format it per the
    §Bullets and numbered lists enumeration. Unknown styles return
    an empty string so the renderer skips drawing."""
    if list_style == "bullet-disc":         return "\u2022"
    if list_style == "bullet-open-circle":  return "\u25CB"
    if list_style == "bullet-square":       return "\u25A0"
    if list_style == "bullet-open-square":  return "\u25A1"
    if list_style == "bullet-dash":         return "\u2013"
    if list_style == "bullet-check":        return "\u2713"
    if list_style == "num-decimal":         return f"{counter}."
    if list_style == "num-lower-alpha":     return f"{to_alpha(counter, False)}."
    if list_style == "num-upper-alpha":     return f"{to_alpha(counter, True)}."
    if list_style == "num-lower-roman":     return f"{to_roman(counter, False)}."
    if list_style == "num-upper-roman":     return f"{to_roman(counter, True)}."
    return ""


def compute_counters(segs: list[ParagraphSegment]) -> list[int]:
    """Compute the 1-based counter for each numbered-list paragraph
    in ``segs``. Bullet and non-list paragraphs get 0. Per
    PARAGRAPH.md §Counter run rule: consecutive paragraphs with the
    same ``num-*`` list style continue counting; a different style
    or a bullet / no-style paragraph breaks the run."""
    counters: list[int] = []
    prev_num: str | None = None
    current = 0
    for seg in segs:
        style = seg.list_style
        if style is not None and style.startswith("num-"):
            if prev_num == style:
                current += 1
            else:
                current = 1
            counters.append(current)
            prev_num = style
        else:
            counters.append(0)
            prev_num = None
            current = 0
    return counters


# ── Phase 10: Justify path via Knuth-Plass composer ─────────


def _hyphen_penalty_from_bias(bias: int) -> float:
    """Map the dialog bias slider (0..6) to a KP penalty value.
    0 (Better Spacing) is cheap, 6 (Fewer Hyphens) is expensive."""
    return 50.0 + max(0, min(6, bias)) * (950.0 / 6.0)


def _last_line_justify_ratio(items: list, from_: int, to_: int,
                               line_width: float) -> float:
    """Custom ratio for the last line of a JUSTIFY_ALL paragraph.
    Excludes the fil-glue terminator so regular inter-word glues
    stretch / shrink to fill the line."""
    from algorithms.knuth_plass import KPBox, KPGlue
    nat = 0.0
    stretch_total = 0.0
    shrink_total = 0.0
    for ii in range(from_, to_):  # exclude trailing item `to_`
        item = items[ii]
        if isinstance(item, KPBox):
            nat += item.width
        elif isinstance(item, KPGlue):
            if item.stretch >= 1e8:  # fil-glue terminator, ignore
                continue
            nat += item.width
            stretch_total += item.stretch
            shrink_total += item.shrink
    slack = line_width - nat
    if slack > 0 and stretch_total > 0:
        return slack / stretch_total
    if slack < 0 and shrink_total > 0:
        return slack / shrink_total
    return 0.0


def _justify_layout_segment(
    content: str,
    max_width: float,
    font_size: float,
    seg: ParagraphSegment,
    measure: Callable[[str], float],
    first_line_extra: float = 0.0,
) -> TextLayout | None:
    """Justify-mode line layout via the every-line composer. Returns
    ``None`` when no feasible composition exists (caller falls back
    to greedy first-fit). Mirrors Rust ``justify_layout``."""
    from algorithms.knuth_plass import (
        compose, KPBox, KPGlue, KPOpts, KPPenalty, PENALTY_INFINITY,
    )
    from algorithms.hyphenator import (
        EN_US_PATTERNS_SAMPLE, hyphenate as _hyphenate,
    )

    line_height = font_size
    ascent = font_size * 0.8
    chars = list(content)
    n = len(chars)
    if n == 0:
        info = LineInfo(start=0, end=0, hard_break=False,
                         top=0.0, baseline_y=ascent,
                         height=line_height, width=0.0,
                         glyph_start=0, glyph_end=0)
        return TextLayout(glyphs=[], lines=[info],
                          font_size=font_size, char_count=0)

    space_w = measure(" ")
    desired_w = space_w * seg.word_spacing_desired / 100.0
    stretch_w = space_w * (seg.word_spacing_max - seg.word_spacing_desired) / 100.0
    shrink_w = space_w * (seg.word_spacing_desired - seg.word_spacing_min) / 100.0
    hyphen_w = measure("-")
    hyphen_pen = _hyphen_penalty_from_bias(seg.hyphenate_bias)

    # Sub-paragraphs split on '\n'.
    para_starts = [0]
    for i, c in enumerate(chars):
        if c == "\n":
            para_starts.append(i + 1)
    para_starts.append(n + 1)

    all_glyphs: list[Glyph] = []
    all_lines: list[LineInfo] = []
    next_line_no = 0

    for k in range(len(para_starts) - 1):
        para_start = para_starts[k]
        para_end_excl = min(max(0, para_starts[k + 1] - 1), n)
        if para_start > n:
            break
        slice_chars = chars[para_start:para_end_excl]

        items: list = []
        i = 0
        while i < len(slice_chars):
            if slice_chars[i].isspace():
                j = i
                while j < len(slice_chars) and slice_chars[j].isspace():
                    j += 1
                items.append(KPGlue(width=desired_w, stretch=stretch_w,
                                     shrink=shrink_w,
                                     char_idx=para_start + i))
                i = j
                continue
            word_start = i
            while i < len(slice_chars) and not slice_chars[i].isspace():
                i += 1
            word = "".join(slice_chars[word_start:i])
            word_w = measure(word)
            # Hyphenation candidates inside the word. Capitalized
            # words (proper nouns) are excluded unless explicitly
            # allowed — without this, "Trump" hyphenates to
            # "T-rump" via the sample pattern set.
            starts_capital = bool(word) and word[0].isupper()
            if (seg.hyphenate
                    and len(word) >= seg.hyphenate_min_word
                    and (getattr(seg, "hyphenate_capitalized", False)
                         or not starts_capital)):
                breaks = _hyphenate(word, EN_US_PATTERNS_SAMPLE,
                                     seg.hyphenate_min_before,
                                     seg.hyphenate_min_after)
                cur = 0
                for bi, is_break in enumerate(breaks):
                    if not is_break or bi == 0 or bi >= len(breaks) - 1:
                        continue
                    pre = word[cur:bi]
                    pre_w = measure(pre)
                    items.append(KPBox(width=pre_w,
                                        char_idx=para_start + word_start + cur))
                    items.append(KPPenalty(width=hyphen_w, value=hyphen_pen,
                                            flagged=True,
                                            char_idx=para_start + word_start + bi))
                    cur = bi
                tail = word[cur:]
                items.append(KPBox(width=measure(tail),
                                    char_idx=para_start + word_start + cur))
            else:
                items.append(KPBox(width=word_w,
                                    char_idx=para_start + word_start))
        # End-of-paragraph terminator. The line-end penalty forces
        # KP to break here. A fil-glue lets the composer absorb
        # arbitrary slack into the last line — necessary for
        # feasibility when the paragraph contains an unbreakable
        # word wider than the line, or a short last line that can't
        # stretch to max_width within the regular glue cap. For
        # Justify All we'd rather omit the fil-glue so KP picks
        # compositions whose last line stretches reasonably from
        # regular glues (project_justify_all_kp_fix.md), but
        # leaving it out makes pathological inputs (a too-long
        # word, a too-short last line) fail KP and fall back to a
        # ragged-left greedy layout. Build both item lists and try
        # the no-fil-glue list first when JUSTIFY is asked; on
        # failure retry with fil-glue.
        terminator_idx = para_start + len(slice_chars)
        items_with_fg = list(items)
        items_with_fg.append(KPGlue(width=0.0, stretch=1e9, shrink=0.0,
                                     char_idx=terminator_idx))
        items_with_fg.append(KPPenalty(width=0.0, value=-PENALTY_INFINITY,
                                        flagged=False,
                                        char_idx=terminator_idx))
        items_no_fg = list(items)
        items_no_fg.append(KPPenalty(width=0.0, value=-PENALTY_INFINITY,
                                      flagged=False,
                                      char_idx=terminator_idx))

        # Only the very first line of the very first sub-paragraph
        # carries the indent — subsequent sub-paragraphs (split on
        # '\n') start a fresh line at the normal left edge.
        if k == 0 and first_line_extra > 0.0:
            line_widths = [max(0.0, max_width - first_line_extra), max_width]
        else:
            line_widths = [max_width]

        def _try_compose(items_list):
            opts = KPOpts()
            br = compose(items_list, line_widths, opts)
            if br is None or not br:
                opts = KPOpts()
                opts.max_ratio = 100.0
                br = compose(items_list, line_widths, opts)
            return br if br else None

        if seg.last_line_align == TextAlign.JUSTIFY:
            breaks = _try_compose(items_no_fg)
            items = items_no_fg
            if not breaks:
                breaks = _try_compose(items_with_fg)
                items = items_with_fg
        else:
            breaks = _try_compose(items_with_fg)
            items = items_with_fg
        if not breaks:
            return None

        prev_break: int | None = None
        line_count = len(breaks)
        for lidx, br in enumerate(breaks):
            is_last = lidx == line_count - 1
            from_ = (prev_break + 1) if prev_break is not None else 0
            to_ = br.item_idx
            x = 0.0
            line_start_char = items[from_].char_idx
            line_end_char = items[from_].char_idx
            glyph_start = len(all_glyphs)
            top = next_line_no * line_height
            baseline_y = top + ascent
            for ii in range(from_, to_ + 1):
                item = items[ii]
                is_trailing = ii == to_
                if isinstance(item, KPBox):
                    chunk_end = (items[ii + 1].char_idx
                                  if ii + 1 < len(items)
                                  else (n + para_start))
                    ci = item.char_idx
                    box_end = min(chunk_end, para_start + len(slice_chars))
                    # Position chars within the box using *prefix*
                    # measurements of the box text rather than
                    # summing single-char widths. KP measured the box
                    # as a whole (with kerning); summing individual
                    # chars typically over-reports the width because
                    # kerning between adjacent glyphs is missing.
                    # Without this, justified lines visibly overflow
                    # the right margin by the cumulative kerning gap.
                    word_text = "".join(chars[ci:box_end])
                    word_origin = x
                    pos = ci
                    prev_w = 0.0
                    while pos < box_end:
                        prefix = word_text[:pos - ci + 1]
                        cur_w = measure(prefix)
                        cw = cur_w - prev_w
                        all_glyphs.append(Glyph(
                            idx=pos, line=next_line_no,
                            x=word_origin + prev_w,
                            right=word_origin + cur_w,
                            baseline_y=baseline_y, top=top,
                            height=line_height,
                            is_trailing_space=False))
                        prev_w = cur_w
                        line_end_char = pos + 1
                        pos += 1
                    x = word_origin + prev_w
                    ci = box_end
                elif isinstance(item, KPGlue):
                    run_end = (items[ii + 1].char_idx
                                if ii + 1 < len(items)
                                else (para_start + len(slice_chars)))
                    if is_trailing:
                        wi = item.char_idx
                        while wi < run_end:
                            all_glyphs.append(Glyph(
                                idx=wi, line=next_line_no,
                                x=x, right=x,
                                baseline_y=baseline_y, top=top,
                                height=line_height,
                                is_trailing_space=True))
                            wi += 1
                        line_end_char = run_end
                    else:
                        if is_last and seg.last_line_align != TextAlign.JUSTIFY:
                            r = 0.0
                        elif is_last and seg.last_line_align == TextAlign.JUSTIFY:
                            r = _last_line_justify_ratio(
                                items, from_, to_, max_width)
                        else:
                            r = br.ratio
                        adj = (item.width + r * item.stretch
                               if r >= 0 else item.width + r * item.shrink)
                        wi = item.char_idx
                        placed_first = False
                        while wi < run_end:
                            cw = adj if not placed_first else 0.0
                            all_glyphs.append(Glyph(
                                idx=wi, line=next_line_no,
                                x=x, right=x + cw,
                                baseline_y=baseline_y, top=top,
                                height=line_height,
                                is_trailing_space=False))
                            if not placed_first:
                                x += cw
                                placed_first = True
                            wi += 1
                        line_end_char = run_end
                elif isinstance(item, KPPenalty):
                    if is_trailing and item.width > 0:
                        all_glyphs.append(Glyph(
                            idx=item.char_idx, line=next_line_no,
                            x=x, right=x + item.width,
                            baseline_y=baseline_y, top=top,
                            height=line_height,
                            is_trailing_space=False))
                        x += item.width
            glyph_end = len(all_glyphs)
            hard_break = (is_last and para_end_excl < n
                          and chars[para_end_excl] == "\n")
            # The renderer needs to draw a visible hyphen at end of
            # line when the composer broke inside a word at a
            # hyphenation penalty. The penalty's ``width`` is the
            # hyphen advance (already baked into x), and ``width > 0``
            # distinguishes a hyphen penalty from the terminator
            # penalty (zero width). Source content has no hyphen at
            # this position, so without the explicit signal the
            # renderer would draw "exam" instead of "exam-".
            trailing_hyphen = False
            if to_ < len(items):
                term = items[to_]
                if isinstance(term, KPPenalty) and term.width > 0:
                    trailing_hyphen = True
            all_lines.append(LineInfo(
                start=line_start_char, end=line_end_char,
                hard_break=hard_break,
                top=top, baseline_y=baseline_y,
                height=line_height, width=x,
                glyph_start=glyph_start, glyph_end=glyph_end,
                trailing_hyphen=trailing_hyphen))
            next_line_no += 1
            prev_break = to_

    if not all_lines:
        all_lines.append(LineInfo(
            start=0, end=0, hard_break=False,
            top=0.0, baseline_y=ascent, height=line_height,
            width=0.0, glyph_start=0, glyph_end=0))

    return TextLayout(glyphs=all_glyphs, lines=all_lines,
                      font_size=font_size, char_count=n)
