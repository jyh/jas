"""Star tool: drag to draw an N-pointed star inscribed in the bounding box."""

from __future__ import annotations

import math
from typing import TYPE_CHECKING

from geometry.element import Color, Polygon, Stroke
from tools.drawing_tool import DrawingToolBase

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter


# Default number of outer vertices for new stars.
STAR_POINTS = 5

# Ratio of inner radius to outer radius for stars.
_STAR_INNER_RATIO = 0.4


def _star_points(sx: float, sy: float, ex: float, ey: float,
                 n: int) -> list[tuple[float, float]]:
    """Vertices of a star inscribed in the bounding box. The star has ``n``
    outer vertices alternating with ``n`` inner vertices, for ``2 * n`` total.
    The first outer vertex is at the top of the box."""
    cx = (sx + ex) / 2
    cy = (sy + ey) / 2
    rx_outer = abs(ex - sx) / 2
    ry_outer = abs(ey - sy) / 2
    rx_inner = rx_outer * _STAR_INNER_RATIO
    ry_inner = ry_outer * _STAR_INNER_RATIO
    theta0 = -math.pi / 2
    pts = []
    for k in range(2 * n):
        angle = theta0 + math.pi * k / n
        rx = rx_outer if k % 2 == 0 else rx_inner
        ry = ry_outer if k % 2 == 0 else ry_inner
        pts.append((cx + rx * math.cos(angle), cy + ry * math.sin(angle)))
    return pts


class StarTool(DrawingToolBase):
    """Star tool. Draws a star inscribed in the dragged bounding box."""

    def _create_element(self, sx, sy, ex, ey):
        if abs(ex - sx) <= 0 or abs(ey - sy) <= 0:
            return None
        pts = _star_points(sx, sy, ex, ey, STAR_POINTS)
        return Polygon(points=tuple(pts),
                       stroke=Stroke(color=Color(0, 0, 0), width=1.0))

    def _draw_preview(self, painter, sx, sy, ex, ey):
        from PySide6.QtCore import QPointF
        pts = _star_points(sx, sy, ex, ey, STAR_POINTS)
        if pts:
            painter.drawPolygon([QPointF(x, y) for x, y in pts])
