"""Lasso tool — freehand polygon selection."""

from __future__ import annotations

import math
from enum import Enum, auto

from PySide6.QtGui import QPainter, QColor, QPen, QPainterPath
from PySide6.QtCore import Qt, QPointF

from tools.tool import CanvasTool, ToolContext

_MIN_POINT_DIST = 2.0


class _State(Enum):
    IDLE = auto()
    DRAWING = auto()


class LassoTool(CanvasTool):
    def __init__(self) -> None:
        self._state = _State.IDLE
        self._points: list[tuple[float, float]] = []
        self._shift = False

    def on_press(self, ctx: ToolContext, x: float, y: float,
                 shift: bool = False, alt: bool = False) -> None:
        self._state = _State.DRAWING
        self._points = [(x, y)]
        self._shift = shift

    def on_move(self, ctx: ToolContext, x: float, y: float,
                shift: bool = False, dragging: bool = False) -> None:
        if self._state != _State.DRAWING:
            return
        self._shift = shift
        if self._points:
            lx, ly = self._points[-1]
            dist = math.hypot(x - lx, y - ly)
            if dist >= _MIN_POINT_DIST:
                self._points.append((x, y))

    def on_release(self, ctx: ToolContext, x: float, y: float,
                   shift: bool = False, alt: bool = False) -> None:
        if self._state == _State.DRAWING:
            extend = self._shift or shift
            if len(self._points) >= 3:
                ctx.model.snapshot()
                ctx.controller.select_polygon(self._points, extend=extend)
            elif not extend:
                ctx.controller.set_selection(frozenset())
        self._state = _State.IDLE
        self._points = []

    def draw_overlay(self, ctx: ToolContext, painter: QPainter) -> None:
        if self._state != _State.DRAWING or len(self._points) < 2:
            return
        pen = QPen(QColor(0, 120, 215, 204), 1.0)
        painter.setPen(pen)
        painter.setBrush(QColor(0, 120, 215, 25))
        path = QPainterPath()
        path.moveTo(QPointF(self._points[0][0], self._points[0][1]))
        for px, py in self._points[1:]:
            path.lineTo(QPointF(px, py))
        path.closeSubpath()
        painter.drawPath(path)

    def activate(self, ctx: ToolContext) -> None:
        self._state = _State.IDLE
        self._points = []

    def deactivate(self, ctx: ToolContext) -> None:
        self._state = _State.IDLE
        self._points = []
