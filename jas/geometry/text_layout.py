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
from typing import Callable, List


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


@dataclass
class TextLayout:
    glyphs: List[Glyph] = field(default_factory=list)
    lines: List[LineInfo] = field(default_factory=list)
    font_size: float = 0.0
    char_count: int = 0

    def cursor_xy(self, cursor: int) -> tuple[float, float, float]:
        cursor = min(cursor, self.char_count)
        line_no = self.line_for_cursor(cursor)
        line = self.lines[line_no]
        height = line.height
        baseline_y = line.baseline_y
        if cursor == line.start:
            return (0.0, baseline_y, height)
        if cursor >= line.end:
            last = None
            for g in self.glyphs:
                if g.line == line_no:
                    last = g
            x = last.right if last else 0.0
            return (x, baseline_y, height)
        for g in self.glyphs:
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
        glyphs_on_line = [g for g in self.glyphs
                          if g.line == line_no and not g.is_trailing_space]
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
        glyphs_on_line = [g for g in self.glyphs
                          if g.line == line_no and not g.is_trailing_space]
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
    glyphs: List[Glyph] = []
    lines: List[LineInfo] = []
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

    return TextLayout(glyphs=glyphs, lines=lines, font_size=font_size, char_count=n)


def ordered_range(a: int, b: int) -> tuple[int, int]:
    return (a, b) if a <= b else (b, a)
