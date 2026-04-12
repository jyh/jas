"""Selection tool: marquee select elements, drag-to-move, Alt+drag copies.

This file also defines `SelectionToolBase`, the shared base class for
the three selection variants. `PartialSelectionTool` and `InteriorSelectionTool`
live in their own files and import `SelectionToolBase` from here.
"""

from __future__ import annotations

import math
from enum import Enum, auto
from typing import TYPE_CHECKING

from tools.tool import CanvasTool, ToolContext, DRAG_THRESHOLD

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


class _SelectionState(Enum):
    IDLE = auto()
    MARQUEE = auto()       # drag-to-select rectangle
    PENDING_MOVE = auto()  # press on selectable, waiting for first drag
    MOVING = auto()        # live drag (mutating per move)


class SelectionToolBase(CanvasTool):
    """Base class for selection tools with shared drag/move behavior.

    Uses a live-edit model: the press records the start, and the
    first `on_move` past `DRAG_THRESHOLD` snapshots once and
    mutates the document per move. No dashed ghost — the actual
    element re-renders on each frame.
    """

    def __init__(self):
        self._state: _SelectionState = _SelectionState.IDLE
        self._drag_start: tuple[float, float] | None = None
        self._marquee_cur: tuple[float, float] | None = None
        self._last: tuple[float, float] | None = None
        self._copied: bool = False
        self._alt_held: bool = False

    def _select_rect(self, ctx: ToolContext, x: float, y: float,
                     w: float, h: float, extend: bool) -> None:
        raise NotImplementedError

    def _check_handle_hit(self, ctx: ToolContext, x: float, y: float) -> bool:
        """Override in PartialSelectionTool to check handle hits. Returns True if handled."""
        return False

    def on_press(self, ctx: ToolContext, x: float, y: float,
                 shift: bool = False, alt: bool = False) -> None:
        self._alt_held = alt
        if self._check_handle_hit(ctx, x, y):
            return
        self._drag_start = (x, y)
        if ctx.hit_test_selection(x, y):
            self._state = _SelectionState.PENDING_MOVE
        else:
            self._state = _SelectionState.MARQUEE
            self._marquee_cur = (x, y)

    def on_move(self, ctx: ToolContext, x: float, y: float,
                shift: bool = False, dragging: bool = False) -> None:
        if self._state == _SelectionState.IDLE:
            return
        if self._state == _SelectionState.PENDING_MOVE:
            sx, sy = self._drag_start
            if math.hypot(x - sx, y - sy) > DRAG_THRESHOLD:
                ctx.snapshot()
                self._state = _SelectionState.MOVING
                self._last = self._drag_start
                self._copied = False
                self.on_move(ctx, x, y, shift=shift, dragging=dragging)
            return
        if self._state == _SelectionState.MOVING:
            lx, ly = self._last
            fx, fy = x, y
            if shift:
                fx, fy = _constrain_angle(lx, ly, x, y)
            dx, dy = fx - lx, fy - ly
            if self._alt_held and not self._copied:
                ctx.controller.copy_selection(dx, dy)
                self._copied = True
            else:
                ctx.controller.move_selection(dx, dy)
            self._last = (fx, fy)
            ctx.request_update()
            return
        # MARQUEE
        self._marquee_cur = (x, y)
        ctx.request_update()

    def on_release(self, ctx: ToolContext, x: float, y: float,
                   shift: bool = False, alt: bool = False) -> None:
        was_state = self._state
        self._state = _SelectionState.IDLE
        start = self._drag_start
        self._drag_start = None
        self._marquee_cur = None
        self._last = None
        if was_state == _SelectionState.MOVING:
            ctx.request_update()
            return
        if was_state == _SelectionState.PENDING_MOVE:
            # Press without significant movement on a selectable —
            # selection already happened in on_press; nothing to do.
            return
        if was_state == _SelectionState.MARQUEE and start is not None:
            sx, sy = start
            rw = abs(x - sx)
            rh = abs(y - sy)
            if rw > 1.0 or rh > 1.0:
                ctx.snapshot()
                self._select_rect(ctx,
                                  min(sx, x), min(sy, y),
                                  rw, rh,
                                  extend=shift)
            elif not shift:
                # Click on empty canvas — clear the selection.
                ctx.controller.set_selection(frozenset())

    def draw_overlay(self, ctx: ToolContext, painter: QPainter) -> None:
        from PySide6.QtCore import QPointF, QRectF, Qt
        from PySide6.QtGui import QBrush, QColor, QPen
        # Only the marquee needs an overlay; live moves render the
        # updated element on the next frame.
        if self._state == _SelectionState.MARQUEE \
                and self._drag_start is not None and self._marquee_cur is not None:
            sx, sy = self._drag_start
            ex, ey = self._marquee_cur
            pen = QPen(QColor(100, 100, 100), 1.0, Qt.PenStyle.DashLine)
            painter.setPen(pen)
            painter.setBrush(QBrush())
            painter.drawRect(QRectF(QPointF(sx, sy), QPointF(ex, ey)).normalized())


class SelectionTool(SelectionToolBase):
    def _select_rect(self, ctx, x, y, w, h, extend):
        ctx.controller.select_rect(x, y, w, h, extend=extend)
