"""Polygon tool: drag to draw a regular polygon with N sides."""

from __future__ import annotations

import math
from typing import TYPE_CHECKING

from geometry.element import RgbColor, Polygon, Stroke
from tools.drawing_tool import DrawingToolBase
from tools.tool import POLYGON_SIDES

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter


def _regular_polygon_points(x1: float, y1: float, x2: float, y2: float,
                            n: int) -> list[tuple[float, float]]:
    ex, ey = x2 - x1, y2 - y1
    s = math.hypot(ex, ey)
    if s == 0:
        return [(x1, y1)] * n
    mx, my = (x1 + x2) / 2, (y1 + y2) / 2
    px, py = -ey / s, ex / s
    d = s / (2 * math.tan(math.pi / n))
    cx, cy = mx + d * px, my + d * py
    r = s / (2 * math.sin(math.pi / n))
    theta0 = math.atan2(y1 - cy, x1 - cx)
    return [(cx + r * math.cos(theta0 + 2 * math.pi * k / n),
             cy + r * math.sin(theta0 + 2 * math.pi * k / n))
            for k in range(n)]


class PolygonTool(DrawingToolBase):
    def _create_element(self, ctx, sx, sy, ex, ey):
        pts = _regular_polygon_points(sx, sy, ex, ey, POLYGON_SIDES)
        return Polygon(points=tuple(pts),
                       fill=ctx.model.default_fill,
                       stroke=ctx.model.default_stroke)

    def _draw_preview(self, painter, sx, sy, ex, ey):
        from PySide6.QtCore import QPointF
        pts = _regular_polygon_points(sx, sy, ex, ey, POLYGON_SIDES)
        if pts:
            painter.drawPolygon([QPointF(x, y) for x, y in pts])
