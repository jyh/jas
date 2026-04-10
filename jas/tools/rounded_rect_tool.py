"""Rounded Rectangle tool: drag to draw a rectangle with fixed corner radius."""

from __future__ import annotations

from typing import TYPE_CHECKING

from geometry.element import RgbColor, Rect, Stroke
from tools.drawing_tool import DrawingToolBase

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter


# Default corner radius (in points) for new rounded rectangles.
ROUNDED_RECT_RADIUS = 10.0


class RoundedRectTool(DrawingToolBase):
    """Rounded rectangle tool. Uses ROUNDED_RECT_RADIUS for corner radius."""

    def _create_element(self, sx, sy, ex, ey):
        x, y = min(sx, ex), min(sy, ey)
        w, h = abs(ex - sx), abs(ey - sy)
        if w <= 0 or h <= 0:
            return None
        return Rect(x=x, y=y, width=w, height=h,
                    rx=ROUNDED_RECT_RADIUS, ry=ROUNDED_RECT_RADIUS,
                    stroke=Stroke(color=RgbColor(0, 0, 0), width=1.0))

    def _draw_preview(self, painter, sx, sy, ex, ey):
        from PySide6.QtCore import QPointF, QRectF
        rect = QRectF(QPointF(sx, sy), QPointF(ex, ey)).normalized()
        r = min(ROUNDED_RECT_RADIUS, rect.width() / 2.0, rect.height() / 2.0)
        painter.drawRoundedRect(rect, r, r)
