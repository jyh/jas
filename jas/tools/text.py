"""Text tool for placing and editing text elements."""

from __future__ import annotations

from typing import TYPE_CHECKING

from geometry.element import Color, Fill, Text
from tools.tool import CanvasTool, ToolContext

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter


class TextTool(CanvasTool):
    def __init__(self):
        self._drag_start: tuple[float, float] | None = None
        self._drag_end: tuple[float, float] | None = None

    def on_press(self, ctx: ToolContext, x: float, y: float,
                 shift: bool = False, alt: bool = False) -> None:
        self._drag_start = (x, y)
        self._drag_end = (x, y)

    def on_move(self, ctx: ToolContext, x: float, y: float,
                shift: bool = False, dragging: bool = False) -> None:
        if self._drag_start is not None:
            self._drag_end = (x, y)
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
            bx, by = min(sx, x), min(sy, y)
            elem = Text(x=bx, y=by, content="Lorem Ipsum",
                        width=w, height=h,
                        fill=Fill(color=Color(0, 0, 0)))
            ctx.controller.add_element(elem)
        else:
            hit = ctx.hit_test_text(sx, sy)
            if hit is not None:
                path, text_elem = hit
                ctx.start_text_edit(path, text_elem)
            else:
                elem = Text(x=sx, y=sy, content="Lorem Ipsum",
                            fill=Fill(color=Color(0, 0, 0)))
                ctx.controller.add_element(elem)

    def deactivate(self, ctx: ToolContext) -> None:
        ctx.commit_text_edit()

    def draw_overlay(self, ctx: ToolContext, painter: QPainter) -> None:
        from PySide6.QtCore import QPointF, QRectF, Qt
        from PySide6.QtGui import QBrush, QColor, QPen
        if self._drag_start is None or self._drag_end is None:
            return
        sx, sy = self._drag_start
        ex, ey = self._drag_end
        pen = QPen(QColor(100, 100, 100), 1.0, Qt.PenStyle.DashLine)
        painter.setPen(pen)
        painter.setBrush(QBrush())
        painter.drawRect(QRectF(QPointF(sx, sy), QPointF(ex, ey)).normalized())
