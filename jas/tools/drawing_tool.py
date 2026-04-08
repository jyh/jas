"""Drawing tool base class shared by line / rect / rounded_rect / polygon / star.

The individual drawing tools live in their own per-tool files
(`line_tool.py`, `rect_tool.py`, etc.) and import `DrawingToolBase`
from here. This file holds only the base class plus the angle-snap
helper used by every drawing tool.
"""

from __future__ import annotations

import math
from typing import TYPE_CHECKING

from tools.tool import CanvasTool, ToolContext

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter


def _constrain_angle(sx: float, sy: float, ex: float, ey: float) -> tuple[float, float]:
    dx = ex - sx
    dy = ey - sy
    dist = math.hypot(dx, dy)
    if dist == 0:
        return (ex, ey)
    angle = math.atan2(dy, dx)
    snapped = round(angle / (math.pi / 4)) * (math.pi / 4)
    return (sx + dist * math.cos(snapped), sy + dist * math.sin(snapped))


class DrawingToolBase(CanvasTool):
    """Base for press-drag-release drawing tools."""

    def __init__(self):
        self._drag_start: tuple[float, float] | None = None
        self._drag_end: tuple[float, float] | None = None

    def on_press(self, ctx: ToolContext, x: float, y: float,
                 shift: bool = False, alt: bool = False) -> None:
        ctx.snapshot()
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
