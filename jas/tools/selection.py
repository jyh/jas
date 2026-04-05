"""Selection tools: Selection, Direct Selection, Group Selection."""

from __future__ import annotations

import math
from typing import TYPE_CHECKING

from geometry.element import (
    Path, control_points as element_control_points, move_control_points,
    path_handle_positions, move_path_handle,
)
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


class SelectionToolBase(CanvasTool):
    """Base class for selection tools with shared drag/move behavior."""

    def __init__(self):
        self._drag_start: tuple[float, float] | None = None
        self._drag_end: tuple[float, float] | None = None
        self._moving: bool = False

    def _select_rect(self, ctx: ToolContext, x: float, y: float,
                     w: float, h: float, extend: bool) -> None:
        raise NotImplementedError

    def _check_handle_hit(self, ctx: ToolContext, x: float, y: float) -> bool:
        """Override in DirectSelectionTool to check handle hits. Returns True if handled."""
        return False

    def on_press(self, ctx: ToolContext, x: float, y: float,
                 shift: bool = False, alt: bool = False) -> None:
        ctx.snapshot()
        if self._check_handle_hit(ctx, x, y):
            return
        if ctx.hit_test_selection(x, y):
            self._drag_start = (x, y)
            self._drag_end = (x, y)
            self._moving = True
            return
        self._drag_start = (x, y)
        self._drag_end = (x, y)
        self._moving = False

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
        if shift and self._moving:
            x, y = _constrain_angle(sx, sy, x, y)
        self._drag_start = None
        self._drag_end = None
        was_moving = self._moving
        self._moving = False
        if was_moving:
            dx, dy = x - sx, y - sy
            if dx != 0 or dy != 0:
                if alt:
                    ctx.controller.copy_selection(dx, dy)
                else:
                    ctx.controller.move_selection(dx, dy)
            ctx.request_update()
            return
        self._select_rect(ctx,
                          min(sx, x), min(sy, y),
                          abs(x - sx), abs(y - sy),
                          extend=shift)

    def draw_overlay(self, ctx: ToolContext, painter: QPainter) -> None:
        from PySide6.QtCore import QPointF, QRectF, Qt
        from PySide6.QtGui import QBrush, QColor, QPen
        if self._drag_start is None or self._drag_end is None:
            return
        sx, sy = self._drag_start
        ex, ey = self._drag_end
        if self._moving:
            dx, dy = ex - sx, ey - sy
            from canvas.canvas import _SELECTION_COLOR, _draw_element_overlay
            for es in ctx.document.selection:
                elem = ctx.document.get_element(es.path)
                moved = move_control_points(elem, es.control_points, dx, dy)
                pen = QPen(_SELECTION_COLOR, 1.0, Qt.PenStyle.DashLine)
                painter.setPen(pen)
                painter.setBrush(QBrush())
                _draw_element_overlay(painter, moved, es.control_points)
        else:
            pen = QPen(QColor(100, 100, 100), 1.0, Qt.PenStyle.DashLine)
            painter.setPen(pen)
            painter.setBrush(QBrush())
            painter.drawRect(QRectF(QPointF(sx, sy), QPointF(ex, ey)).normalized())


class SelectionTool(SelectionToolBase):
    def _select_rect(self, ctx, x, y, w, h, extend):
        ctx.controller.select_rect(x, y, w, h, extend=extend)


class GroupSelectionTool(SelectionToolBase):
    def _select_rect(self, ctx, x, y, w, h, extend):
        ctx.controller.group_select_rect(x, y, w, h, extend=extend)


class DirectSelectionTool(SelectionToolBase):
    def __init__(self):
        super().__init__()
        self._handle_drag: tuple[tuple[int, ...], int, str] | None = None
        self._handle_drag_start: tuple[float, float] | None = None
        self._handle_drag_end: tuple[float, float] | None = None

    def _select_rect(self, ctx, x, y, w, h, extend):
        ctx.controller.direct_select_rect(x, y, w, h, extend=extend)

    def _check_handle_hit(self, ctx, x, y):
        hit = ctx.hit_test_handle(x, y)
        if hit is not None:
            self._handle_drag = hit
            self._handle_drag_start = (x, y)
            self._handle_drag_end = (x, y)
            return True
        return False

    def on_move(self, ctx, x, y, shift=False, dragging=False):
        if self._handle_drag is not None:
            self._handle_drag_end = (x, y)
            ctx.request_update()
            return
        super().on_move(ctx, x, y, shift, dragging)

    def on_release(self, ctx, x, y, shift=False, alt=False):
        if self._handle_drag is not None:
            sx, sy = self._handle_drag_start
            path, anchor_idx, handle_type = self._handle_drag
            dx, dy = x - sx, y - sy
            self._handle_drag = None
            self._handle_drag_start = None
            self._handle_drag_end = None
            if dx != 0 or dy != 0:
                ctx.controller.move_path_handle(path, anchor_idx, handle_type, dx, dy)
            ctx.request_update()
            return
        super().on_release(ctx, x, y, shift, alt)

    def draw_overlay(self, ctx, painter):
        if self._handle_drag is not None and self._handle_drag_start is not None and self._handle_drag_end is not None:
            from PySide6.QtCore import Qt
            from PySide6.QtGui import QBrush, QPen
            from canvas.canvas import _SELECTION_COLOR, _draw_element_overlay
            sx, sy = self._handle_drag_start
            ex, ey = self._handle_drag_end
            path, anchor_idx, handle_type = self._handle_drag
            dx, dy = ex - sx, ey - sy
            elem = ctx.document.get_element(path)
            if isinstance(elem, Path):
                moved = move_path_handle(elem, anchor_idx, handle_type, dx, dy)
                for es in ctx.document.selection:
                    if es.path == path:
                        pen = QPen(_SELECTION_COLOR, 1.0, Qt.PenStyle.DashLine)
                        painter.setPen(pen)
                        painter.setBrush(QBrush())
                        _draw_element_overlay(painter, moved, es.control_points)
                        break
        super().draw_overlay(ctx, painter)
