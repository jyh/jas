"""Text-on-path tool for placing text along a curve.

Supports three modes:
1. Drag to create a new text-on-path element.
2. Click on an existing Path element to convert it to a TextPath and edit in place.
3. Drag the start-offset handle to reposition text along the path.
"""

from __future__ import annotations

import dataclasses
from typing import TYPE_CHECKING

from geometry.element import (
    Color, CurveTo, Fill, LineTo, MoveTo, Path, TextPath,
    path_closest_offset, path_distance_to_point, path_point_at_offset,
)
from tools.tool import CanvasTool, ToolContext, DRAG_THRESHOLD

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter

_OFFSET_HANDLE_RADIUS = 5.0


class TextPathTool(CanvasTool):
    """Click on an existing path to convert it, or drag to create a new curve."""

    def __init__(self):
        self._drag_start: tuple[float, float] | None = None
        self._drag_end: tuple[float, float] | None = None
        self._control: tuple[float, float] | None = None
        # Offset handle drag state
        self._offset_dragging = False
        self._offset_drag_path: tuple[int, ...] | None = None
        self._offset_preview: float | None = None

    # -- helpers --

    def _find_selected_textpath_handle(self, ctx: ToolContext, x: float, y: float
                                       ) -> tuple[tuple[int, ...], TextPath] | None:
        """Check if (x, y) is near the start-offset handle of a selected TextPath."""
        doc = ctx.document
        for es in doc.selection:
            elem = doc.get_element(es.path)
            if isinstance(elem, TextPath) and elem.d:
                hx, hy = path_point_at_offset(elem.d, elem.start_offset)
                if abs(x - hx) <= _OFFSET_HANDLE_RADIUS + 2 and abs(y - hy) <= _OFFSET_HANDLE_RADIUS + 2:
                    return (es.path, elem)
        return None

    # -- tool events --

    def on_press(self, ctx: ToolContext, x: float, y: float,
                 shift: bool = False, alt: bool = False) -> None:
        ctx.snapshot()
        # 1) Check offset handle drag
        handle_hit = self._find_selected_textpath_handle(ctx, x, y)
        if handle_hit is not None:
            path, _elem = handle_hit
            self._offset_dragging = True
            self._offset_drag_path = path
            self._offset_preview = None
            return
        # 2) Start drag-create
        self._drag_start = (x, y)
        self._drag_end = (x, y)
        self._control = None

    def on_move(self, ctx: ToolContext, x: float, y: float,
                shift: bool = False, dragging: bool = False) -> None:
        # Offset handle drag
        if self._offset_dragging and self._offset_drag_path is not None:
            elem = ctx.document.get_element(self._offset_drag_path)
            if isinstance(elem, TextPath) and elem.d:
                self._offset_preview = path_closest_offset(elem.d, x, y)
                ctx.request_update()
            return
        # Drag-create
        if self._drag_start is not None:
            self._drag_end = (x, y)
            sx, sy = self._drag_start
            dx, dy = x - sx, y - sy
            dist = (dx * dx + dy * dy) ** 0.5
            if dist > DRAG_THRESHOLD:
                nx, ny = -dy / dist, dx / dist
                mx, my = (sx + x) / 2, (sy + y) / 2
                self._control = (mx + nx * dist * 0.3, my + ny * dist * 0.3)
            ctx.request_update()

    def on_release(self, ctx: ToolContext, x: float, y: float,
                   shift: bool = False, alt: bool = False) -> None:
        # Offset handle drag commit
        if self._offset_dragging and self._offset_drag_path is not None:
            if self._offset_preview is not None:
                elem = ctx.document.get_element(self._offset_drag_path)
                if isinstance(elem, TextPath):
                    new_elem = dataclasses.replace(elem, start_offset=self._offset_preview)
                    new_doc = ctx.document.replace_element(self._offset_drag_path, new_elem)
                    ctx.controller.set_document(new_doc)
            self._offset_dragging = False
            self._offset_drag_path = None
            self._offset_preview = None
            ctx.request_update()
            return

        if self._drag_start is None:
            return
        sx, sy = self._drag_start
        self._drag_start = None
        self._drag_end = None
        w = abs(x - sx)
        h = abs(y - sy)

        if w <= DRAG_THRESHOLD and h <= DRAG_THRESHOLD:
            # Click (not drag): check if we hit a Path to convert
            hit = ctx.hit_test_path_curve(x, y)
            if hit is not None:
                path, elem = hit
                if isinstance(elem, Path):
                    # Convert Path to TextPath
                    tp = TextPath(
                        d=elem.d, content="",
                        start_offset=path_closest_offset(elem.d, x, y),
                        fill=Fill(color=Color(0, 0, 0)),
                        font_size=16.0,
                    )
                    new_doc = ctx.document.replace_element(path, tp)
                    ctx.controller.set_document(new_doc)
                    ctx.controller.select_element(path)
                    ctx.start_text_edit(path, tp)
                    ctx.request_update()
                    return
                elif isinstance(elem, TextPath):
                    # Click on existing TextPath: start editing
                    ctx.controller.select_element(path)
                    ctx.start_text_edit(path, elem)
                    ctx.request_update()
                    return
        else:
            # Drag: create a new text-on-path element
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
            doc = ctx.document
            li = doc.selected_layer
            ci = len(doc.layers[li].children) - 1
            path = (li, ci)
            ctx.start_text_edit(path, elem)
        self._control = None
        ctx.request_update()

    def on_double_click(self, ctx: ToolContext, x: float, y: float) -> None:
        hit = ctx.hit_test_path_curve(x, y)
        if hit is not None:
            path, elem = hit
            if isinstance(elem, TextPath):
                ctx.controller.select_element(path)
                ctx.start_text_edit(path, elem)
                ctx.request_update()

    def deactivate(self, ctx: ToolContext) -> None:
        ctx.commit_text_edit()

    def draw_overlay(self, ctx: ToolContext, painter: 'QPainter') -> None:
        from PySide6.QtCore import QPointF, Qt
        from PySide6.QtGui import QBrush, QColor, QPen, QPainterPath

        # Draw drag-create preview
        if self._drag_start is not None and self._drag_end is not None:
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

        # Draw offset handle for selected TextPath elements
        doc = ctx.document
        for es in doc.selection:
            elem = doc.get_element(es.path)
            if isinstance(elem, TextPath) and elem.d:
                offset = self._offset_preview if (
                    self._offset_dragging and self._offset_drag_path == es.path
                    and self._offset_preview is not None
                ) else elem.start_offset
                hx, hy = path_point_at_offset(elem.d, offset)
                r = _OFFSET_HANDLE_RADIUS
                # Diamond shape
                painter.setPen(QPen(QColor(255, 140, 0), 1.5))
                painter.setBrush(QBrush(QColor(255, 200, 80)))
                diamond = QPainterPath()
                diamond.moveTo(hx, hy - r)
                diamond.lineTo(hx + r, hy)
                diamond.lineTo(hx, hy + r)
                diamond.lineTo(hx - r, hy)
                diamond.closeSubpath()
                painter.drawPath(diamond)
