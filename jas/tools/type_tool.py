"""Type tool with native in-place text editing.

Click on existing unlocked text to edit it; click on empty canvas to
create a new (initially empty) text element and immediately enter editing
mode. Drag to create an area text box.

While editing:
 - Mouse drag inside the editing element extends the selection.
 - Standard text editing keys (arrows, backspace, delete, Home/End,
   Cmd+A/C/X/V/Z) are routed to the session via `on_key_event`.
 - The OS cursor is hidden over the active edit area; a vertical text
   caret is drawn at the insertion point.
 - All character-level edits go through a per-session undo stack and
   collapse to a *single* document-undo step.

See `jas_dioxus/src/tools/text_edit.rs` for the full design notes.
"""

from __future__ import annotations

import dataclasses
from typing import TYPE_CHECKING

from geometry.element import (
    Color, Element, Fill, Group, Layer, Text, Stroke,
)
from algorithms.text_layout import layout as _layout, TextLayout
from tools.text_edit import (
    EditTarget, TextEditSession, empty_text_elem,
    BLINK_HALF_PERIOD_MS, now_ms as _now_ms, cursor_visible as _cursor_visible,
)
from tools.text_measure import make_measurer
from tools.tool import CanvasTool, KeyMods, ToolContext, DRAG_THRESHOLD

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter


def _show_selection_bbox() -> bool:
    """Indirection to canvas.SHOW_SELECTION_BBOX so the type tool can
    consult it without a hard import-time dependency on the canvas
    module (which transitively imports Qt)."""
    from canvas.canvas import SHOW_SELECTION_BBOX
    return SHOW_SELECTION_BBOX


def _text_draw_bounds(t: Text) -> tuple[float, float, float, float]:
    """Bounding box used to hit-test a Text element. Both point and area
    text are treated as having `e.y` at their top edge."""
    if t.is_area_text:
        return (t.x, t.y, max(t.width, 1.0), max(t.height, 1.0))
    lines = t.content.split('\n') if t.content else [""]
    max_chars = max(len(l) for l in lines) if lines else 0
    w = max(max_chars, 1) * t.font_size * 0.55
    h = len(lines) * t.font_size
    return (t.x, t.y, w, h)


def _accent_color(t: Text) -> "QColor":
    from PySide6.QtGui import QColor
    c = (t.fill.color if t.fill is not None
         else (t.stroke.color if t.stroke is not None else Color(0, 0, 0)))
    return QColor(int(c.r * 255), int(c.g * 255), int(c.b * 255))


def _selection_color(t: Text) -> "QColor":
    """Light sky blue, falling back to yellow if too close to fill or stroke."""
    from PySide6.QtGui import QColor
    blue_lum = 0.2126 * 0.529 + 0.7152 * 0.808 + 0.0722 * 0.980
    candidates = []
    if t.fill is not None:
        candidates.append(t.fill.color)
    if t.stroke is not None:
        candidates.append(t.stroke.color)
    for c in candidates:
        lum = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        if abs(lum - blue_lum) < 0.15:
            return QColor(255, 235, 80, 128)
    return QColor(135, 206, 250, 115)


@dataclasses.dataclass
class _Dragging:
    start_x: float
    start_y: float
    cur_x: float
    cur_y: float


class TypeTool(CanvasTool):
    def __init__(self):
        # Drag-to-create state machine. None == idle.
        self._drag: _Dragging | None = None
        # active edit session, if any
        self.session: TextEditSession | None = None
        self._did_snapshot = False
        self._hover_text = False

    # ---- helpers ----

    def _build_layout(self, ctx: ToolContext) -> tuple[Text, TextLayout] | None:
        if self.session is None or self.session.target != EditTarget.TEXT:
            return None
        try:
            elem = ctx.document.get_element(self.session.path)
        except (IndexError, KeyError):
            return None
        if not isinstance(elem, Text):
            return None
        t = dataclasses.replace(elem, content=self.session.content)
        measure = make_measurer(t.font_family, t.font_weight, t.font_style, t.font_size)
        max_w = t.width if t.is_area_text else 0.0
        lay = _layout(t.content, max_w, t.font_size, measure)
        return (t, lay)

    def _hit_test_text(self, ctx: ToolContext, x: float, y: float
                       ) -> tuple[tuple[int, ...], Text] | None:
        """Recursive hit-test that respects locked groups/elements."""
        doc = ctx.document
        result: list[tuple[tuple[int, ...], Text] | None] = [None]

        def rec(elem, path):
            if isinstance(elem, Layer):
                for i, c in enumerate(elem.children):
                    rec(c, path + (i,))
            elif isinstance(elem, Group):
                if elem.locked:
                    return
                for i, c in enumerate(elem.children):
                    rec(c, path + (i,))
            elif isinstance(elem, Text):
                if elem.locked:
                    return
                bx, by, bw, bh = _text_draw_bounds(elem)
                if bx <= x <= bx + bw and by <= y <= by + bh:
                    result[0] = (path, elem)
        for li, layer in enumerate(doc.layers):
            rec(layer, (li,))
        return result[0]

    def _cursor_at(self, ctx: ToolContext, x: float, y: float) -> int:
        built = self._build_layout(ctx)
        if built is None:
            return 0
        t, lay = built
        return lay.hit_test(x - t.x, y - t.y)

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

    def _begin_session_existing(self, ctx: ToolContext, path: tuple,
                                elem: Text, cursor: int) -> None:
        self.session = TextEditSession(
            path=path, target=EditTarget.TEXT,
            content=elem.content, insertion=cursor,
            blink_epoch_ms=_now_ms(),
        )
        self._did_snapshot = False
        ctx.controller.select_element(path)

    def _begin_session_new(self, ctx: ToolContext, x: float, y: float,
                           width: float, height: float) -> None:
        ctx.snapshot()
        self._did_snapshot = True
        elem = empty_text_elem(x, y, width, height)
        ctx.controller.add_element(elem)
        doc = ctx.document
        li = doc.selected_layer
        ci = len(doc.layers[li].children) - 1
        path = (li, ci)
        ctx.controller.select_element(path)
        self.session = TextEditSession(
            path=path, target=EditTarget.TEXT, content="",
            insertion=0, blink_epoch_ms=_now_ms(),
        )

    def _end_session(self) -> None:
        self.session = None
        self._did_snapshot = False
        self._drag = None

    # ---- CanvasTool API ----

    def on_press(self, ctx: ToolContext, x: float, y: float,
                 shift: bool = False, alt: bool = False) -> None:
        if self.session is not None:
            try:
                elem = ctx.document.get_element(self.session.path)
            except (IndexError, KeyError):
                elem = None
            in_elem = False
            if isinstance(elem, Text):
                bx, by, bw, bh = _text_draw_bounds(elem)
                in_elem = bx <= x <= bx + bw and by <= y <= by + bh
            if in_elem:
                cursor = self._cursor_at(ctx, x, y)
                self.session.set_insertion(cursor, False)
                self.session.drag_active = True
                self.session.blink_epoch_ms = _now_ms()
                ctx.request_update()
                return
            self._end_session()

        hit = self._hit_test_text(ctx, x, y)
        if hit is not None:
            path, t = hit
            self._begin_session_existing(ctx, path, t, 0)
            cursor = self._cursor_at(ctx, x, y)
            self.session.set_insertion(cursor, False)
            self.session.drag_active = True
            self.session.blink_epoch_ms = _now_ms()
            ctx.request_update()
            return

        self._drag = _Dragging(start_x=x, start_y=y, cur_x=x, cur_y=y)

    def on_move(self, ctx: ToolContext, x: float, y: float,
                shift: bool = False, dragging: bool = False) -> None:
        if self.session is not None and self.session.drag_active and dragging:
            cursor = self._cursor_at(ctx, x, y)
            self.session.set_insertion(cursor, True)
            self.session.blink_epoch_ms = _now_ms()
            ctx.request_update()
            return
        if self._drag is not None:
            self._drag.cur_x = x
            self._drag.cur_y = y
            ctx.request_update()
        if self.session is None:
            self._hover_text = self._hit_test_text(ctx, x, y) is not None
        else:
            self._hover_text = False

    def on_release(self, ctx: ToolContext, x: float, y: float,
                   shift: bool = False, alt: bool = False) -> None:
        if self.session is not None:
            self.session.drag_active = False
            self.session.blink_epoch_ms = _now_ms()
            self._drag = None
            ctx.request_update()
            return
        if self._drag is None:
            return
        sx, sy = self._drag.start_x, self._drag.start_y
        self._drag = None
        w = abs(x - sx)
        h = abs(y - sy)
        if w > DRAG_THRESHOLD or h > DRAG_THRESHOLD:
            bx, by = min(sx, x), min(sy, y)
            self._begin_session_new(ctx, bx, by, w, h)
        else:
            self._begin_session_new(ctx, sx, sy, 0.0, 0.0)
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
                text = self.session.copy_selection()
                if text is not None:
                    _clipboard_write(text)
                return True
            if key in ("x", "X"):
                text = self.session.copy_selection()
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
            self._ensure_snapshot(ctx)
            self.session.insert("\n")
            self.session.blink_epoch_ms = _now_ms()
            self._sync_to_model(ctx)
            ctx.request_update()
            return True
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
        if key in ("ArrowUp", "ArrowDown"):
            built = self._build_layout(ctx)
            if built is not None:
                _, lay = built
                if key == "ArrowUp":
                    new_pos = lay.cursor_up(self.session.insertion)
                else:
                    new_pos = lay.cursor_down(self.session.insertion)
                self.session.set_insertion(new_pos, mods.shift)
                self.session.blink_epoch_ms = _now_ms()
                ctx.request_update()
            return True
        if key == "Home":
            built = self._build_layout(ctx)
            if built is not None:
                _, lay = built
                line = lay.line_for_cursor(self.session.insertion)
                self.session.set_insertion(lay.lines[line].start, mods.shift)
                self.session.blink_epoch_ms = _now_ms()
                ctx.request_update()
            return True
        if key == "End":
            built = self._build_layout(ctx)
            if built is not None:
                _, lay = built
                line = lay.line_for_cursor(self.session.insertion)
                self.session.set_insertion(lay.lines[line].end, mods.shift)
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
        if self._hover_text:
            return "ibeam"
        return None

    def is_editing(self) -> bool:
        return self.session is not None

    def paste_text(self, ctx: ToolContext, text: str) -> bool:
        if self.session is None:
            return False
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
        from PySide6.QtGui import QBrush, QColor, QPen

        # Drag-create preview rectangle.
        if self.session is None and self._drag is not None:
            sx, sy = self._drag.start_x, self._drag.start_y
            ex, ey = self._drag.cur_x, self._drag.cur_y
            pen = QPen(QColor(100, 100, 100), 1.0, Qt.PenStyle.DashLine)
            painter.setPen(pen)
            painter.setBrush(QBrush())
            painter.drawRect(QRectF(QPointF(sx, sy), QPointF(ex, ey)).normalized())

        if self.session is None:
            return
        built = self._build_layout(ctx)
        if built is None:
            return
        t, lay = built

        sel_color = _selection_color(t)
        caret_color = _accent_color(t)

        # Selection rectangles.
        if self.session.has_selection():
            lo, hi = self.session.selection_range()
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(QBrush(sel_color))
            for line_idx, line in enumerate(lay.lines):
                line_lo = max(line.start, lo)
                line_hi = min(line.end, hi)
                if line_lo >= line_hi:
                    continue
                if line_lo == line.start:
                    x_lo = 0.0
                else:
                    x_lo = next((g.x for g in lay.glyphs
                                 if g.idx == line_lo and g.line == line_idx), 0.0)
                if line_hi == line.end:
                    x_hi = line.width
                else:
                    x_hi = next((g.x for g in lay.glyphs
                                 if g.idx == line_hi and g.line == line_idx), line.width)
                painter.drawRect(QRectF(t.x + x_lo, t.y + line.top,
                                        x_hi - x_lo, line.height))

        # The bounding box around the edited text is not drawn
        # here — the Type tool selects the element when it starts
        # editing, so the selection overlay (see
        # ``_draw_selection_overlays`` in ``canvas/canvas.py``) is
        # responsible for rendering the box. That keeps the rule
        # "area text shows its bbox iff the element is selected"
        # in a single place.

        # Caret.
        if _cursor_visible(self.session.blink_epoch_ms):
            cx, cy, ch = lay.cursor_xy(self.session.insertion)
            painter.setPen(QPen(caret_color, 1.5))
            painter.drawLine(QPointF(t.x + cx, t.y + cy - ch * 0.8),
                             QPointF(t.x + cx, t.y + cy + ch * 0.2))


def _clipboard_write(text: str) -> None:
    try:
        from PySide6.QtWidgets import QApplication  # type: ignore
        app = QApplication.instance()
        if app is not None:
            app.clipboard().setText(text)
    except (ImportError, AttributeError):
        pass
