"""Text-on-path tool for placing text along a curve."""

from __future__ import annotations

from typing import TYPE_CHECKING

from element import Color, CurveTo, Fill, LineTo, MoveTo, TextPath
from tool import CanvasTool, ToolContext

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter


class TextPathTool(CanvasTool):
    """Click on an existing path to convert it, or drag to create a new curve."""

    def __init__(self):
        self._drag_start: tuple[float, float] | None = None
        self._drag_end: tuple[float, float] | None = None
        self._control: tuple[float, float] | None = None

    def on_press(self, ctx: ToolContext, x: float, y: float,
                 shift: bool = False, alt: bool = False) -> None:
        self._drag_start = (x, y)
        self._drag_end = (x, y)
        self._control = None

    def on_move(self, ctx: ToolContext, x: float, y: float,
                shift: bool = False, dragging: bool = False) -> None:
        if self._drag_start is not None:
            self._drag_end = (x, y)
            # Control point is perpendicular offset from midpoint
            sx, sy = self._drag_start
            mx, my = (sx + x) / 2, (sy + y) / 2
            dx, dy = x - sx, y - sy
            dist = (dx * dx + dy * dy) ** 0.5
            if dist > 4:
                # Offset proportional to drag distance
                nx, ny = -dy / dist, dx / dist
                self._control = (mx + nx * dist * 0.3, my + ny * dist * 0.3)
            ctx.request_update()

    def on_release(self, ctx: ToolContext, x: float, y: float,
                   shift: bool = False, alt: bool = False) -> None:
        if self._drag_start is None:
            return
        sx, sy = self._drag_start
        self._drag_start = None
        self._drag_end = None
        w = abs(x - sx)
        h = abs(y - sy)
        if w > 4 or h > 4:
            # Create a text-on-path element with a curve
            if self._control is not None:
                cx, cy = self._control
                d = (
                    MoveTo(sx, sy),
                    CurveTo(cx, cy, cx, cy, x, y),
                )
            else:
                d = (
                    MoveTo(sx, sy),
                    LineTo(x, y),
                )
            elem = TextPath(d=d, content="Lorem Ipsum",
                            fill=Fill(color=Color(0, 0, 0)))
            ctx.controller.add_element(elem)
        self._control = None

    def draw_overlay(self, ctx: ToolContext, painter: 'QPainter') -> None:
        from PySide6.QtCore import QPointF, QRectF, Qt
        from PySide6.QtGui import QBrush, QColor, QPen, QPainterPath
        if self._drag_start is None or self._drag_end is None:
            return
        sx, sy = self._drag_start
        ex, ey = self._drag_end
        pen = QPen(QColor(100, 100, 100), 1.0, Qt.PenStyle.DashLine)
        painter.setPen(pen)
        painter.setBrush(QBrush())
        path = QPainterPath()
        path.moveTo(sx, sy)
        if self._control is not None:
            cx, cy = self._control
            path.cubicTo(cx, cy, cx, cy, ex, ey)
        else:
            path.lineTo(ex, ey)
        painter.drawPath(path)
