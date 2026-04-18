"""Type-on-path tool with native in-place text editing.

Three creation flows:
 1. Drag on empty canvas → builds a curved path and starts editing
    a TextPath that flows along it.
 2. Click on an existing Path element → converts it to a TextPath and
    enters editing mode at the click position.
 3. Click on an existing TextPath → enters editing mode at the click
    position.

Editing semantics, undo handling, and keyboard routing match TypeTool.
"""

from __future__ import annotations

import dataclasses
import math
from typing import TYPE_CHECKING

from geometry.element import (
    Color, RgbColor, CurveTo, Element, Fill, Group, Layer, LineTo, MoveTo,
    Path, Text, TextPath,
    path_closest_offset, path_distance_to_point, path_point_at_offset,
)
from algorithms.path_text_layout import layout_path_text, PathTextLayout
from tools.text_edit import EditTarget, TextEditSession, empty_text_path_elem
from tools.text_measure import make_measurer
from tools.tool import CanvasTool, KeyMods, ToolContext, DRAG_THRESHOLD, HIT_RADIUS
from tools.type_tool import _now_ms, _cursor_visible

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter

_OFFSET_HANDLE_RADIUS = 5.0


def _accent_color(tp: TextPath) -> "QColor":
    from PySide6.QtGui import QColor
    c = (tp.fill.color if tp.fill is not None
         else (tp.stroke.color if tp.stroke is not None else RgbColor(0, 0, 0)))
    r, g, b, _a = c.to_rgba()
    return QColor(int(r * 255), int(g * 255), int(b * 255))


def _selection_color(tp: TextPath) -> "QColor":
    from PySide6.QtGui import QColor
    blue_lum = 0.2126 * 0.529 + 0.7152 * 0.808 + 0.0722 * 0.980
    candidates = []
    if tp.fill is not None:
        candidates.append(tp.fill.color)
    if tp.stroke is not None:
        candidates.append(tp.stroke.color)
    for c in candidates:
        cr, cg, cb, _ca = c.to_rgba()
        lum = 0.2126 * cr + 0.7152 * cg + 0.0722 * cb
        if abs(lum - blue_lum) < 0.15:
            return QColor(255, 235, 80, 128)
    return QColor(135, 206, 250, 115)


class TypeOnPathTool(CanvasTool):
    def __init__(self):
        # Drag-create state
        self._drag_start: tuple[float, float] | None = None
        self._drag_end: tuple[float, float] | None = None
        self._control: tuple[float, float] | None = None
        # Offset handle drag
        self._offset_dragging = False
        self._offset_drag_path: tuple | None = None
        self._offset_preview: float | None = None
        # Edit session
        self.session: TextEditSession | None = None
        self._did_snapshot = False
        self._hover_textpath = False
        self._hover_path = False

    # ---- helpers ----

    def _build_layout(self, ctx: ToolContext) -> tuple[TextPath, PathTextLayout] | None:
        if self.session is None or self.session.target != EditTarget.TEXT_PATH:
            return None
        try:
            elem = ctx.document.get_element(self.session.path)
        except (IndexError, KeyError):
            return None
        if not isinstance(elem, TextPath):
            return None
        tp = dataclasses.replace(elem, content=self.session.content)
        measure = make_measurer(tp.font_family, tp.font_weight, tp.font_style, tp.font_size)
        lay = layout_path_text(tp.d, tp.content, tp.start_offset, tp.font_size, measure)
        return (tp, lay)

    def _hit_test_path_curve(self, ctx: ToolContext, x: float, y: float
                              ) -> tuple[tuple, Element] | None:
        doc = ctx.document
        threshold = HIT_RADIUS + 2
        for li, layer in enumerate(doc.layers):
            for ci, child in enumerate(layer.children):
                if isinstance(child, (Path, TextPath)) and not getattr(child, 'locked', False):
                    if path_distance_to_point(child.d, x, y) <= threshold:
                        return ((li, ci), child)
                elif isinstance(child, Group) and not isinstance(child, Layer):
                    if getattr(child, 'locked', False):
                        continue
                    for gi, gc in enumerate(child.children):
                        if isinstance(gc, (Path, TextPath)) and not getattr(gc, 'locked', False):
                            if path_distance_to_point(gc.d, x, y) <= threshold:
                                return ((li, ci, gi), gc)
        return None

    def _cursor_at(self, ctx: ToolContext, x: float, y: float) -> int:
        built = self._build_layout(ctx)
        if built is None:
            return 0
        _, lay = built
        return lay.hit_test(x, y)

    def _ensure_snapshot(self, ctx: ToolContext) -> None:
        if not self._did_snapshot:
            ctx.snapshot()
            self._did_snapshot = True

    def _sync_to_model(self, ctx: ToolContext) -> None:
        if self.session is None:
            return
        new_doc = self.session.apply_to_document(ctx.document)
        if new_doc is not None:
            ctx.controller.set_document(new_doc)

    def _current_element_tspans(self, ctx: ToolContext) -> tuple:
        if self.session is None:
            return ()
        try:
            elem = ctx.document.get_element(self.session.path)
        except Exception:
            return ()
        if isinstance(elem, Text):
            return tuple(elem.tspans)
        if isinstance(elem, TextPath):
            return tuple(elem.tspans)
        return ()

    def _replace_element_tspans(self, ctx: ToolContext, path: tuple,
                                 new_tspans) -> None:
        try:
            elem = ctx.document.get_element(path)
        except Exception:
            return
        if isinstance(elem, Text):
            new_elem = dataclasses.replace(elem, tspans=tuple(new_tspans))
        elif isinstance(elem, TextPath):
            new_elem = dataclasses.replace(elem, tspans=tuple(new_tspans))
        else:
            return
        ctx.controller.set_document(ctx.document.replace_element(path, new_elem))

    def _begin_session_existing(self, ctx: ToolContext, path: tuple,
                                 elem: TextPath, cursor: int) -> None:
        self.session = TextEditSession(
            path=path, target=EditTarget.TEXT_PATH,
            content=elem.content, insertion=cursor,
            blink_epoch_ms=_now_ms(),
        )
        self._did_snapshot = False
        ctx.controller.select_element(path)

    def _begin_session_convert_path(self, ctx: ToolContext, path: tuple,
                                     d: tuple, click_offset: float) -> None:
        ctx.snapshot()
        self._did_snapshot = True
        new_tp = dataclasses.replace(empty_text_path_elem(d), start_offset=click_offset)
        new_doc = ctx.document.replace_element(path, new_tp)
        ctx.controller.set_document(new_doc)
        ctx.controller.select_element(path)
        self.session = TextEditSession(
            path=path, target=EditTarget.TEXT_PATH, content="",
            insertion=0, blink_epoch_ms=_now_ms(),
        )

    def _begin_session_new_curve(self, ctx: ToolContext, d: tuple) -> None:
        ctx.snapshot()
        self._did_snapshot = True
        new_tp = empty_text_path_elem(d)
        ctx.controller.add_element(new_tp)
        doc = ctx.document
        li = doc.selected_layer
        ci = len(doc.layers[li].children) - 1
        path = (li, ci)
        ctx.controller.select_element(path)
        self.session = TextEditSession(
            path=path, target=EditTarget.TEXT_PATH, content="",
            insertion=0, blink_epoch_ms=_now_ms(),
        )

    def _end_session(self) -> None:
        self.session = None
        self._did_snapshot = False
        self._drag_start = None
        self._drag_end = None
        self._control = None

    def _find_offset_handle(self, ctx: ToolContext, x: float, y: float
                             ) -> tuple[tuple, float] | None:
        doc = ctx.document
        for es in doc.selection:
            elem = doc.get_element(es.path)
            if isinstance(elem, TextPath) and elem.d:
                hx, hy = path_point_at_offset(elem.d, elem.start_offset)
                if (abs(x - hx) <= _OFFSET_HANDLE_RADIUS + 2
                        and abs(y - hy) <= _OFFSET_HANDLE_RADIUS + 2):
                    return (es.path, elem.start_offset)
        return None

    # ---- CanvasTool API ----

    def on_press(self, ctx: ToolContext, x: float, y: float,
                 shift: bool = False, alt: bool = False) -> None:
        if self.session is not None:
            try:
                elem = ctx.document.get_element(self.session.path)
            except (IndexError, KeyError):
                elem = None
            near_elem = (isinstance(elem, TextPath)
                         and path_distance_to_point(elem.d, x, y) <= 20.0)
            if near_elem:
                cursor = self._cursor_at(ctx, x, y)
                self.session.set_insertion(cursor, False)
                self.session.drag_active = True
                self.session.blink_epoch_ms = _now_ms()
                ctx.request_update()
                return
            self._end_session()

        handle_hit = self._find_offset_handle(ctx, x, y)
        if handle_hit is not None:
            self._offset_dragging = True
            self._offset_drag_path = handle_hit[0]
            self._offset_preview = None
            return

        hit = self._hit_test_path_curve(ctx, x, y)
        if hit is not None:
            path, elem = hit
            if isinstance(elem, TextPath):
                self._begin_session_existing(ctx, path, elem, 0)
                cursor = self._cursor_at(ctx, x, y)
                self.session.set_insertion(cursor, False)
                self.session.drag_active = True
                self.session.blink_epoch_ms = _now_ms()
                ctx.request_update()
                return
            if isinstance(elem, Path):
                click_offset = path_closest_offset(elem.d, x, y)
                self._begin_session_convert_path(ctx, path, elem.d, click_offset)
                ctx.request_update()
                return

        self._drag_start = (x, y)
        self._drag_end = (x, y)
        self._control = None

    def on_move(self, ctx: ToolContext, x: float, y: float,
                shift: bool = False, dragging: bool = False) -> None:

        if self.session is not None and self.session.drag_active and dragging:
            cursor = self._cursor_at(ctx, x, y)
            self.session.set_insertion(cursor, True)
            self.session.blink_epoch_ms = _now_ms()
            ctx.request_update()
            return

        if self._offset_dragging and self._offset_drag_path is not None:
            elem = ctx.document.get_element(self._offset_drag_path)
            if isinstance(elem, TextPath) and elem.d:
                self._offset_preview = path_closest_offset(elem.d, x, y)
                ctx.request_update()
            return

        if self._drag_start is not None:
            self._drag_end = (x, y)
            sx, sy = self._drag_start
            dx, dy = x - sx, y - sy
            dist = math.hypot(dx, dy)
            if dist > DRAG_THRESHOLD:
                nx, ny = -dy / dist, dx / dist
                mx, my = (sx + x) / 2, (sy + y) / 2
                self._control = (mx + nx * dist * 0.3, my + ny * dist * 0.3)
            ctx.request_update()

        if self.session is None:
            hit = self._hit_test_path_curve(ctx, x, y)
            self._hover_textpath = hit is not None and isinstance(hit[1], TextPath)
            self._hover_path = hit is not None and isinstance(hit[1], Path)
        else:
            self._hover_textpath = False
            self._hover_path = False

    def on_release(self, ctx: ToolContext, x: float, y: float,
                   shift: bool = False, alt: bool = False) -> None:
        if self.session is not None:
            self.session.drag_active = False
            self.session.blink_epoch_ms = _now_ms()
            self._drag_start = None
            self._drag_end = None
            ctx.request_update()
            return

        if self._offset_dragging and self._offset_drag_path is not None:
            if self._offset_preview is not None:
                elem = ctx.document.get_element(self._offset_drag_path)
                if isinstance(elem, TextPath):
                    ctx.snapshot()
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
            self._control = None
            return
        if self._control is not None:
            cx, cy = self._control
            d = (MoveTo(sx, sy), CurveTo(cx, cy, cx, cy, x, y))
        else:
            d = (MoveTo(sx, sy), LineTo(x, y))
        self._control = None
        self._begin_session_new_curve(ctx, d)
        ctx.request_update()

    def on_double_click(self, ctx: ToolContext, x: float, y: float) -> None:
        if self.session is not None:
            self.session.select_all()
            self.session.blink_epoch_ms = _now_ms()
            ctx.request_update()

    def on_key_event(self, ctx: ToolContext, key: str, mods: KeyMods) -> bool:
        if self.session is None:
            return False

        if mods.cmd():
            if key in ("a", "A"):
                self.session.select_all()
                self.session.blink_epoch_ms = _now_ms()
                ctx.request_update()
                return True
            if key in ("z", "Z"):
                if mods.shift:
                    self.session.redo()
                else:
                    self.session.undo()
                self.session.blink_epoch_ms = _now_ms()
                self._sync_to_model(ctx)
                ctx.request_update()
                return True
            if key in ("c", "C"):
                elem_tspans = self._current_element_tspans(ctx)
                text = self.session.copy_selection_with_tspans(elem_tspans)
                if text is not None:
                    _clipboard_write(text)
                return True
            if key in ("x", "X"):
                elem_tspans = self._current_element_tspans(ctx)
                text = self.session.copy_selection_with_tspans(elem_tspans)
                if text is not None:
                    _clipboard_write(text)
                    self._ensure_snapshot(ctx)
                    self.session.backspace()
                    self.session.blink_epoch_ms = _now_ms()
                    self._sync_to_model(ctx)
                    ctx.request_update()
                return True

        if key == "Escape":
            self._end_session()
            ctx.request_update()
            return True
        if key == "Enter":
            return True  # No multi-line for path text.
        if key == "Backspace":
            self._ensure_snapshot(ctx)
            self.session.backspace()
            self.session.blink_epoch_ms = _now_ms()
            self._sync_to_model(ctx)
            ctx.request_update()
            return True
        if key == "Delete":
            self._ensure_snapshot(ctx)
            self.session.delete_forward()
            self.session.blink_epoch_ms = _now_ms()
            self._sync_to_model(ctx)
            ctx.request_update()
            return True
        if key == "ArrowLeft":
            self.session.set_insertion(max(0, self.session.insertion - 1), mods.shift)
            self.session.blink_epoch_ms = _now_ms()
            ctx.request_update()
            return True
        if key == "ArrowRight":
            self.session.set_insertion(self.session.insertion + 1, mods.shift)
            self.session.blink_epoch_ms = _now_ms()
            ctx.request_update()
            return True
        if key == "Home":
            self.session.set_insertion(0, mods.shift)
            self.session.blink_epoch_ms = _now_ms()
            ctx.request_update()
            return True
        if key == "End":
            self.session.set_insertion(len(self.session.content), mods.shift)
            self.session.blink_epoch_ms = _now_ms()
            ctx.request_update()
            return True

        if len(key) == 1 and not mods.cmd():
            self._ensure_snapshot(ctx)
            self.session.insert(key)
            self.session.blink_epoch_ms = _now_ms()
            self._sync_to_model(ctx)
            ctx.request_update()
            return True
        return False

    def captures_keyboard(self) -> bool:
        return self.session is not None

    def cursor_css_override(self) -> str | None:
        # While editing, always use the system I-beam.
        if self.session is not None:
            return "ibeam"
        if self._hover_textpath or self._hover_path:
            return "ibeam"
        return None

    def is_editing(self) -> bool:
        return self.session is not None

    def paste_text(self, ctx: ToolContext, text: str) -> bool:
        if self.session is None:
            return False
        elem_tspans = self._current_element_tspans(ctx)
        new_tspans = self.session.try_paste_tspans(elem_tspans, text)
        if new_tspans is not None:
            from geometry.tspan import concat_content
            self._ensure_snapshot(ctx)
            self._replace_element_tspans(ctx, self.session.path, new_tspans)
            caret = self.session.insertion + len(text)
            self.session.set_content(concat_content(list(new_tspans)),
                                     insertion=caret, anchor=caret)
            self.session.blink_epoch_ms = _now_ms()
            ctx.request_update()
            return True
        self._ensure_snapshot(ctx)
        self.session.insert(text)
        self.session.blink_epoch_ms = _now_ms()
        self._sync_to_model(ctx)
        ctx.request_update()
        return True

    def deactivate(self, ctx: ToolContext) -> None:
        self._end_session()

    def draw_overlay(self, ctx: ToolContext, painter: "QPainter") -> None:
        from PySide6.QtCore import QPointF, QRectF, Qt
        from PySide6.QtGui import QBrush, QColor, QPainterPath, QPen, QTransform

        # Drag-create preview
        if self.session is None and self._drag_start is not None and self._drag_end is not None:
            sx, sy = self._drag_start
            ex, ey = self._drag_end
            pen = QPen(QColor(100, 100, 100), 1.0, Qt.PenStyle.DashLine)
            painter.setPen(pen)
            painter.setBrush(QBrush())
            qpath = QPainterPath()
            qpath.moveTo(sx, sy)
            if self._control is not None:
                cx, cy = self._control
                qpath.cubicTo(cx, cy, cx, cy, ex, ey)
            else:
                qpath.lineTo(ex, ey)
            painter.drawPath(qpath)

        # Offset handles for selected TextPath elements
        doc = ctx.document
        for es in doc.selection:
            elem = doc.get_element(es.path)
            if isinstance(elem, TextPath) and elem.d:
                offset = (self._offset_preview if (self._offset_dragging
                          and self._offset_drag_path == es.path
                          and self._offset_preview is not None)
                          else elem.start_offset)
                hx, hy = path_point_at_offset(elem.d, offset)
                r = _OFFSET_HANDLE_RADIUS
                painter.setPen(QPen(QColor(255, 140, 0), 1.5))
                painter.setBrush(QBrush(QColor(255, 200, 80)))
                diamond = QPainterPath()
                diamond.moveTo(hx, hy - r)
                diamond.lineTo(hx + r, hy)
                diamond.lineTo(hx, hy + r)
                diamond.lineTo(hx - r, hy)
                diamond.closeSubpath()
                painter.drawPath(diamond)

        # Editing overlay
        if self.session is None:
            return
        built = self._build_layout(ctx)
        if built is None:
            return
        tp, lay = built
        sel_color = _selection_color(tp)
        caret_color = _accent_color(tp)

        if self.session.has_selection():
            lo, hi = self.session.selection_range()
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(QBrush(sel_color))
            for g in lay.glyphs:
                if g.idx < lo or g.idx >= hi:
                    continue
                painter.save()
                painter.translate(QPointF(g.cx, g.cy))
                painter.rotate(math.degrees(g.angle))
                painter.drawRect(QRectF(-g.width / 2.0, -tp.font_size * 0.8,
                                        g.width, tp.font_size))
                painter.restore()

        if _cursor_visible(self.session.blink_epoch_ms):
            pos = lay.cursor_pos(self.session.insertion)
            if pos is not None:
                cx, cy, angle = pos
                painter.save()
                painter.translate(QPointF(cx, cy))
                painter.rotate(math.degrees(angle))
                painter.setPen(QPen(caret_color, 1.5))
                painter.drawLine(QPointF(0.0, -tp.font_size * 0.8),
                                 QPointF(0.0, tp.font_size * 0.2))
                painter.restore()


def _clipboard_write(text: str) -> None:
    try:
        from PySide6.QtWidgets import QApplication  # type: ignore
        app = QApplication.instance()
        if app is not None:
            app.clipboard().setText(text)
    except (ImportError, AttributeError):
        pass
