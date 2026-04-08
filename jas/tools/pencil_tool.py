"""Pencil tool for freehand drawing with automatic Bezier curve fitting."""

from __future__ import annotations

from typing import TYPE_CHECKING

from geometry.element import Color, CurveTo, MoveTo, Path, PathCommand, Stroke
from algorithms.fit_curve import fit_curve
from tools.tool import CanvasTool, ToolContext

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter

_FIT_ERROR = 4.0


class PencilTool(CanvasTool):
    def __init__(self):
        self._points: list[tuple[float, float]] = []
        self._drawing = False

    def on_press(self, ctx: ToolContext, x: float, y: float,
                 shift: bool = False, alt: bool = False) -> None:
        ctx.snapshot()
        self._drawing = True
        self._points = [(x, y)]
        ctx.request_update()

    def on_move(self, ctx: ToolContext, x: float, y: float,
                shift: bool = False, dragging: bool = False) -> None:
        if self._drawing:
            self._points.append((x, y))
            ctx.request_update()

    def on_release(self, ctx: ToolContext, x: float, y: float,
                   shift: bool = False, alt: bool = False) -> None:
        if not self._drawing:
            return
        self._drawing = False
        self._points.append((x, y))
        self._finish(ctx)

    def _finish(self, ctx: ToolContext) -> None:
        if len(self._points) < 2:
            self._points.clear()
            ctx.request_update()
            return
        segments = fit_curve(self._points, _FIT_ERROR)
        if not segments:
            self._points.clear()
            ctx.request_update()
            return
        cmds: list[PathCommand] = []
        seg0 = segments[0]
        cmds.append(MoveTo(seg0[0], seg0[1]))
        for seg in segments:
            cmds.append(CurveTo(seg[2], seg[3], seg[4], seg[5], seg[6], seg[7]))
        elem = Path(d=tuple(cmds),
                    stroke=Stroke(color=Color(0, 0, 0), width=1.0))
        ctx.controller.add_element(elem)
        self._points.clear()
        ctx.request_update()

    def draw_overlay(self, ctx: ToolContext, painter: QPainter) -> None:
        from PySide6.QtCore import QPointF
        from PySide6.QtGui import QColor, QPen
        if not self._drawing or len(self._points) < 2:
            return
        painter.setPen(QPen(QColor(0, 0, 0), 1.0))
        for i in range(1, len(self._points)):
            painter.drawLine(
                QPointF(self._points[i - 1][0], self._points[i - 1][1]),
                QPointF(self._points[i][0], self._points[i][1]),
            )
