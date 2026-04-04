"""Pen tool for constructing Bezier paths."""

from __future__ import annotations

import math
from typing import TYPE_CHECKING

from element import (
    ClosePath, Color, CurveTo, MoveTo, Path, PathCommand, Stroke,
)
from tool import CanvasTool, ToolContext

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter


_PEN_CLOSE_RADIUS = 6.0
_HANDLE_SIZE = 6.0


class PenPoint:
    """A control point in the pen tool's in-progress path."""
    __slots__ = ('x', 'y', 'hx_in', 'hy_in', 'hx_out', 'hy_out', 'smooth')

    def __init__(self, x: float, y: float):
        self.x = x
        self.y = y
        self.hx_in = x
        self.hy_in = y
        self.hx_out = x
        self.hy_out = y
        self.smooth = False


class PenTool(CanvasTool):
    def __init__(self):
        self._points: list[PenPoint] = []
        self._dragging: bool = False
        self._mouse_x: float = 0
        self._mouse_y: float = 0

    def _finish(self, ctx: ToolContext, close: bool = False):
        if len(self._points) < 2:
            self._points.clear()
            self._dragging = False
            ctx.request_update()
            return
        p0 = self._points[0]
        if not close and len(self._points) >= 3:
            pn = self._points[-1]
            if math.hypot(pn.x - p0.x, pn.y - p0.y) <= _PEN_CLOSE_RADIUS:
                close = True
        cmds: list[PathCommand] = []
        cmds.append(MoveTo(p0.x, p0.y))
        n = len(self._points)
        if close and n >= 3:
            pn = self._points[-1]
            if math.hypot(pn.x - p0.x, pn.y - p0.y) <= _PEN_CLOSE_RADIUS:
                n -= 1
        for i in range(1, n):
            prev = self._points[i - 1]
            curr = self._points[i]
            cmds.append(CurveTo(
                prev.hx_out, prev.hy_out,
                curr.hx_in, curr.hy_in,
                curr.x, curr.y,
            ))
        if close:
            last = self._points[n - 1]
            cmds.append(CurveTo(
                last.hx_out, last.hy_out,
                p0.hx_in, p0.hy_in,
                p0.x, p0.y,
            ))
            cmds.append(ClosePath())
        elem = Path(d=tuple(cmds),
                    stroke=Stroke(color=Color(0, 0, 0), width=1.0))
        ctx.controller.add_element(elem)
        self._points.clear()
        self._dragging = False
        ctx.request_update()

    def on_press(self, ctx: ToolContext, x: float, y: float,
                 shift: bool = False, alt: bool = False) -> None:
        if len(self._points) >= 2:
            p0 = self._points[0]
            if math.hypot(x - p0.x, y - p0.y) <= _PEN_CLOSE_RADIUS:
                self._finish(ctx, close=True)
                return
        self._dragging = True
        self._points.append(PenPoint(x, y))
        ctx.request_update()

    def on_move(self, ctx: ToolContext, x: float, y: float,
                shift: bool = False, dragging: bool = False) -> None:
        self._mouse_x = x
        self._mouse_y = y
        if self._dragging and self._points:
            pt = self._points[-1]
            pt.hx_out = x
            pt.hy_out = y
            pt.hx_in = 2 * pt.x - x
            pt.hy_in = 2 * pt.y - y
            pt.smooth = True
        ctx.request_update()

    def on_release(self, ctx: ToolContext, x: float, y: float,
                   shift: bool = False, alt: bool = False) -> None:
        self._dragging = False
        ctx.request_update()

    def on_double_click(self, ctx: ToolContext, x: float, y: float) -> None:
        if self._points:
            self._points.pop()
        self._finish(ctx)

    def on_key(self, ctx: ToolContext, key: int) -> bool:
        from PySide6.QtCore import Qt
        if self._points and key in (Qt.Key.Key_Escape, Qt.Key.Key_Return, Qt.Key.Key_Enter):
            self._finish(ctx)
            return True
        return False

    def deactivate(self, ctx: ToolContext) -> None:
        if self._points:
            self._finish(ctx)

    def draw_overlay(self, ctx: ToolContext, painter: QPainter) -> None:
        from PySide6.QtCore import QPointF, QRectF, Qt
        from PySide6.QtGui import QBrush, QColor, QPainterPath, QPen
        if not self._points:
            return
        sel_color = QColor(0, 120, 255)
        # Draw committed curve segments
        if len(self._points) >= 2:
            painter.setPen(QPen(QColor(0, 0, 0), 1.0))
            painter.setBrush(QBrush())
            path = QPainterPath()
            p0 = self._points[0]
            path.moveTo(p0.x, p0.y)
            for i in range(1, len(self._points)):
                prev = self._points[i - 1]
                curr = self._points[i]
                path.cubicTo(prev.hx_out, prev.hy_out,
                             curr.hx_in, curr.hy_in,
                             curr.x, curr.y)
            painter.drawPath(path)
        # Draw preview curve from last point to mouse
        if not self._dragging:
            last = self._points[-1]
            mx, my = self._mouse_x, self._mouse_y
            p0 = self._points[0]
            near_start = (len(self._points) >= 2
                          and math.hypot(mx - p0.x, my - p0.y) <= _PEN_CLOSE_RADIUS)
            painter.setPen(QPen(QColor(100, 100, 100), 1.0, Qt.PenStyle.DashLine))
            if near_start:
                preview = QPainterPath()
                preview.moveTo(last.x, last.y)
                preview.cubicTo(last.hx_out, last.hy_out,
                                p0.hx_in, p0.hy_in, p0.x, p0.y)
                painter.drawPath(preview)
            else:
                preview = QPainterPath()
                preview.moveTo(last.x, last.y)
                preview.cubicTo(last.hx_out, last.hy_out, mx, my, mx, my)
                painter.drawPath(preview)
        # Draw handle lines and endpoints
        for pt in self._points:
            if pt.smooth:
                painter.setPen(QPen(sel_color, 1.0))
                painter.setBrush(QBrush())
                painter.drawLine(QPointF(pt.hx_in, pt.hy_in),
                                 QPointF(pt.hx_out, pt.hy_out))
                r = 3.0
                painter.setBrush(QBrush(QColor("white")))
                painter.drawEllipse(QPointF(pt.hx_in, pt.hy_in), r, r)
                painter.drawEllipse(QPointF(pt.hx_out, pt.hy_out), r, r)
            half = _HANDLE_SIZE / 2
            painter.setPen(QPen(sel_color, 1.0))
            painter.setBrush(QBrush(sel_color))
            painter.drawRect(QRectF(pt.x - half, pt.y - half,
                                    _HANDLE_SIZE, _HANDLE_SIZE))
