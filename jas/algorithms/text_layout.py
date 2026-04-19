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


def layout(content: str, max_width: float, font_size: float,
           measure: Callable[[str], float]) -> TextLayout:
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

    def push_line(start: int, end: int, hard_break: bool, line_width: float) -> None:
        top = line_no * line_height
        lines.append(LineInfo(
            start=start, end=end, hard_break=hard_break,
            top=top, baseline_y=top + ascent,
            height=line_height, width=line_width,
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

        if max_width > 0.0 and x + token_w > max_width and x > 0.0:
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

        if max_width > 0.0 and token_w > max_width and x == 0.0:
            for k, ch in enumerate(token):
                cw = measure(ch)
                if x + cw > max_width and x > 0.0:
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
    box width minus left/right indents). Phase 5 supports the three
    non-justify alignments; the four ``JUSTIFY_*`` variants land
    with the composer in Phase 8 — they fall back to ``LEFT``."""
    LEFT = "left"
    CENTER = "center"
    RIGHT = "right"


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
    # non-negative values; negative falls back to 0.
    first_line_indent: float = 0.0
    # jas:space-before — extra vertical gap above this paragraph.
    # Always 0 for the first paragraph in the element.
    space_before: float = 0.0
    space_after: float = 0.0
    text_align: TextAlign = TextAlign.LEFT


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
                text_align=p.text_align)
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
        effective_max = max(0.0, max_width - seg.left_indent - seg.right_indent) \
            if max_width > 0.0 else 0.0
        para = layout(slice_str, effective_max, font_size, measure)
        first_line_extra = max(0.0, seg.first_line_indent)
        first_line_no_in_combined = line_count
        for li, line in enumerate(para.lines):
            x_shift = seg.left_indent + (first_line_extra if li == 0 else 0.0)
            line_avail = max(0.0, effective_max - (first_line_extra if li == 0 else 0.0)) \
                if effective_max > 0.0 else 0.0
            visible_w = _trimmed_line_width(line, para.glyphs)
            if seg.text_align == TextAlign.CENTER:
                align_shift = (line_avail - visible_w) / 2.0 if line_avail > visible_w else 0.0
            elif seg.text_align == TextAlign.RIGHT:
                align_shift = line_avail - visible_w if line_avail > visible_w else 0.0
            else:
                align_shift = 0.0
            total_shift = x_shift + align_shift
            orig_start = seg.char_start + line.start
            orig_end = seg.char_start + line.end
            top = y_offset + line.top
            baseline = y_offset + line.baseline_y
            glyph_start = len(all_glyphs)
            for g in para.glyphs[line.glyph_start:line.glyph_end]:
                all_glyphs.append(Glyph(
                    idx=seg.char_start + g.idx,
                    line=first_line_no_in_combined + li,
                    x=g.x + total_shift,
                    right=g.right + total_shift,
                    baseline_y=g.baseline_y + y_offset,
                    top=g.top + y_offset,
                    height=g.height,
                    is_trailing_space=g.is_trailing_space))
            glyph_end = len(all_glyphs)
            all_lines.append(LineInfo(
                start=orig_start, end=orig_end,
                hard_break=line.hard_break,
                top=top, baseline_y=baseline,
                height=line.height,
                width=visible_w + total_shift,
                glyph_start=glyph_start, glyph_end=glyph_end))
            line_count += 1
        if para.lines:
            y_offset += len(para.lines) * line_height
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
            current = ParagraphSegment(
                char_start=cursor, char_end=cursor,
                left_indent=t.jas_left_indent or 0.0,
                right_indent=t.jas_right_indent or 0.0,
                first_line_indent=t.text_indent or 0.0,
                space_before=t.jas_space_before or 0.0,
                space_after=t.jas_space_after or 0.0,
                text_align=_text_align_from(t.text_align, is_area))
        else:
            cursor += body_chars
    if current is not None:
        current.char_end = min(cursor, total_chars)
        if current.char_end > current.char_start:
            segs.append(current)
    return segs


def _text_align_from(value: str | None, is_area: bool) -> TextAlign:
    """Map the wrapper tspan's ``text-align`` string to a TextAlign.
    Phase 5 supports ``left`` / ``center`` / ``right``; the four
    ``justify*`` values fall back to LEFT until the composer lands."""
    if value == "center":
        return TextAlign.CENTER
    if value == "right":
        return TextAlign.RIGHT
    return TextAlign.LEFT
