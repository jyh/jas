"""Drawing tools: Line, Rect, Polygon."""

from __future__ import annotations

import math
from typing import TYPE_CHECKING

from geometry.element import (
    Color, Line, Polygon, Rect, Stroke,
)
from tools.tool import CanvasTool, ToolContext

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter


_POLYGON_SIDES = 5


def _constrain_angle(sx: float, sy: float, ex: float, ey: float) -> tuple[float, float]:
    dx = ex - sx
    dy = ey - sy
    dist = math.hypot(dx, dy)
    if dist == 0:
        return (ex, ey)
    angle = math.atan2(dy, dx)
    snapped = round(angle / (math.pi / 4)) * (math.pi / 4)
    return (sx + dist * math.cos(snapped), sy + dist * math.sin(snapped))


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


class DrawingToolBase(CanvasTool):
    """Base for press-drag-release drawing tools."""

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
            if shift:
                x, y = _constrain_angle(*self._drag_start, x, y)
            self._drag_end = (x, y)
            ctx.request_update()

    def on_release(self, ctx: ToolContext, x: float, y: float,
                   shift: bool = False, alt: bool = False) -> None:
        if self._drag_start is None:
            return
        sx, sy = self._drag_start
        if shift:
            x, y = _constrain_angle(sx, sy, x, y)
        self._drag_start = None
        self._drag_end = None
        elem = self._create_element(sx, sy, x, y)
        if elem is not None:
            ctx.controller.add_element(elem)

    def _create_element(self, sx, sy, ex, ey):
        raise NotImplementedError

    def _draw_preview(self, painter: QPainter, sx, sy, ex, ey) -> None:
        raise NotImplementedError

    def draw_overlay(self, ctx: ToolContext, painter: QPainter) -> None:
        from PySide6.QtGui import QColor, QPen, Qt
        if self._drag_start is None or self._drag_end is None:
            return
        sx, sy = self._drag_start
        ex, ey = self._drag_end
        pen = QPen(QColor(100, 100, 100), 1.0, Qt.PenStyle.DashLine)
        painter.setPen(pen)
        from PySide6.QtGui import QBrush
        painter.setBrush(QBrush())
        self._draw_preview(painter, sx, sy, ex, ey)


class LineTool(DrawingToolBase):
    def _create_element(self, sx, sy, ex, ey):
        return Line(x1=sx, y1=sy, x2=ex, y2=ey,
                    stroke=Stroke(color=Color(0, 0, 0), width=1.0))

    def _draw_preview(self, painter, sx, sy, ex, ey):
        from PySide6.QtCore import QPointF
        painter.drawLine(QPointF(sx, sy), QPointF(ex, ey))


class RectTool(DrawingToolBase):
    def _create_element(self, sx, sy, ex, ey):
        x, y = min(sx, ex), min(sy, ey)
        w, h = abs(ex - sx), abs(ey - sy)
        return Rect(x=x, y=y, width=w, height=h,
                    stroke=Stroke(color=Color(0, 0, 0), width=1.0))

    def _draw_preview(self, painter, sx, sy, ex, ey):
        from PySide6.QtCore import QPointF, QRectF
        painter.drawRect(QRectF(QPointF(sx, sy), QPointF(ex, ey)).normalized())


class PolygonTool(DrawingToolBase):
    def _create_element(self, sx, sy, ex, ey):
        pts = _regular_polygon_points(sx, sy, ex, ey, _POLYGON_SIDES)
        return Polygon(points=tuple(pts),
                       stroke=Stroke(color=Color(0, 0, 0), width=1.0))

    def _draw_preview(self, painter, sx, sy, ex, ey):
        from PySide6.QtCore import QPointF
        pts = _regular_polygon_points(sx, sy, ex, ey, _POLYGON_SIDES)
        if pts:
            painter.drawPolygon([QPointF(x, y) for x, y in pts])
