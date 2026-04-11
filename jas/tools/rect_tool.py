"""Rectangle tool: drag to draw an axis-aligned rectangle."""

from __future__ import annotations

from typing import TYPE_CHECKING

from geometry.element import RgbColor, Rect, Stroke
from tools.drawing_tool import DrawingToolBase

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter


class RectTool(DrawingToolBase):
    def _create_element(self, ctx, sx, sy, ex, ey):
        x, y = min(sx, ex), min(sy, ey)
        w, h = abs(ex - sx), abs(ey - sy)
        return Rect(x=x, y=y, width=w, height=h,
                    fill=ctx.model.default_fill,
                    stroke=ctx.model.default_stroke)

    def _draw_preview(self, painter, sx, sy, ex, ey):
        from PySide6.QtCore import QPointF, QRectF
        painter.drawRect(QRectF(QPointF(sx, sy), QPointF(ex, ey)).normalized())
