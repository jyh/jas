"""Line tool: drag to draw a straight line segment."""

from __future__ import annotations

from typing import TYPE_CHECKING

from geometry.element import RgbColor, Line, Stroke
from tools.drawing_tool import DrawingToolBase

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter


class LineTool(DrawingToolBase):
    def _create_element(self, sx, sy, ex, ey):
        return Line(x1=sx, y1=sy, x2=ex, y2=ey,
                    stroke=Stroke(color=RgbColor(0, 0, 0), width=1.0))

    def _draw_preview(self, painter, sx, sy, ex, ey):
        from PySide6.QtCore import QPointF
        painter.drawLine(QPointF(sx, sy), QPointF(ex, ey))
