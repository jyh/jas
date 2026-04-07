"""Layout for text that flows along a path."""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Callable, List

from geometry.element import flatten_path_commands, _arc_lengths


@dataclass
class PathGlyph:
    idx: int
    offset: float
    width: float
    cx: float
    cy: float
    angle: float
    overflow: bool = False


@dataclass
class PathTextLayout:
    glyphs: List[PathGlyph] = field(default_factory=list)
    total_length: float = 0.0
    font_size: float = 0.0
    char_count: int = 0

    def cursor_pos(self, cursor: int) -> tuple[float, float, float] | None:
        if not self.glyphs:
            return None
        if cursor == 0:
            g = self.glyphs[0]
            dx = -math.cos(g.angle) * g.width / 2.0
            dy = -math.sin(g.angle) * g.width / 2.0
            return (g.cx + dx, g.cy + dy, g.angle)
        if cursor >= len(self.glyphs):
            g = self.glyphs[-1]
            dx = math.cos(g.angle) * g.width / 2.0
            dy = math.sin(g.angle) * g.width / 2.0
            return (g.cx + dx, g.cy + dy, g.angle)
        g = self.glyphs[cursor]
        dx = -math.cos(g.angle) * g.width / 2.0
        dy = -math.sin(g.angle) * g.width / 2.0
        return (g.cx + dx, g.cy + dy, g.angle)

    def hit_test(self, x: float, y: float) -> int:
        if not self.glyphs:
            return 0
        best_idx = 0
        best_dist = float("inf")
        for i, g in enumerate(self.glyphs):
            half = g.width / 2.0
            bx = g.cx - math.cos(g.angle) * half
            by = g.cy - math.sin(g.angle) * half
            ax = g.cx + math.cos(g.angle) * half
            ay = g.cy + math.sin(g.angle) * half
            db = math.hypot(x - bx, y - by)
            da = math.hypot(x - ax, y - ay)
            if db < best_dist:
                best_dist = db
                best_idx = i
            if da < best_dist:
                best_dist = da
                best_idx = i + 1
        return best_idx


def layout_path_text(d: tuple, content: str, start_offset: float,
                     font_size: float, measure: Callable[[str], float]) -> PathTextLayout:
    pts = flatten_path_commands(d)
    lengths = _arc_lengths(pts) if pts else [0.0]
    total = lengths[-1] if lengths else 0.0
    glyphs: List[PathGlyph] = []
    n = len(content)
    if total <= 0.0 or not pts:
        return PathTextLayout(glyphs=glyphs, total_length=total,
                              font_size=font_size, char_count=n)
    start_arc = max(0.0, min(1.0, start_offset)) * total
    cur_arc = start_arc
    for i, ch in enumerate(content):
        cw = measure(ch)
        center_arc = cur_arc + cw / 2.0
        overflow = center_arc > total
        cx, cy, angle = _sample_at_arc(pts, lengths, min(center_arc, total))
        glyphs.append(PathGlyph(idx=i, offset=cur_arc, width=cw,
                                cx=cx, cy=cy, angle=angle, overflow=overflow))
        cur_arc += cw
    return PathTextLayout(glyphs=glyphs, total_length=total,
                          font_size=font_size, char_count=n)


def _sample_at_arc(pts, lengths, arc):
    if len(pts) < 2:
        p = pts[0] if pts else (0.0, 0.0)
        return (p[0], p[1], 0.0)
    arc = max(0.0, arc)
    for i in range(1, len(lengths)):
        if lengths[i] >= arc:
            seg = lengths[i] - lengths[i - 1]
            t = (arc - lengths[i - 1]) / seg if seg > 0 else 0.0
            ax, ay = pts[i - 1]
            bx, by = pts[i]
            x = ax + t * (bx - ax)
            y = ay + t * (by - ay)
            angle = math.atan2(by - ay, bx - ax)
            return (x, y, angle)
    last = len(pts) - 1
    ax, ay = pts[last - 1]
    bx, by = pts[last]
    return (bx, by, math.atan2(by - ay, bx - ax))
