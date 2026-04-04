from dataclasses import dataclass

from PySide6.QtCore import QPointF, QRectF, QSize, Qt
from PySide6.QtGui import (
    QBrush, QColor, QPainter, QPainterPath, QPen, QTransform, QMouseEvent, QPaintEvent,
)
from PySide6.QtWidgets import QLineEdit, QWidget

import math

from controller import Controller
from document import Document, ElementSelection
from element import (
    ArcTo, Circle, ClosePath, CurveTo, Element, Ellipse, Group, Layer, Line,
    LineTo, MoveTo, Path, PathCommand, Polygon, Polyline, QuadTo, Rect, SmoothCurveTo,
    SmoothQuadTo, Text,
    Color, Fill, LineCap, LineJoin, Stroke, Transform,
    control_points as element_control_points, move_control_points,
)
from model import Model
from toolbar import Tool


def _constrain_angle(sx: float, sy: float, ex: float, ey: float) -> tuple[float, float]:
    """Constrain (ex, ey) relative to (sx, sy) to the nearest 45-degree axis."""
    dx = ex - sx
    dy = ey - sy
    dist = math.hypot(dx, dy)
    if dist == 0:
        return (ex, ey)
    angle = math.atan2(dy, dx)
    snapped = round(angle / (math.pi / 4)) * (math.pi / 4)
    return (sx + dist * math.cos(snapped), sy + dist * math.sin(snapped))


@dataclass(frozen=True)
class BoundingBox:
    """Axis-aligned bounding box in px."""
    x: float
    y: float
    width: float
    height: float


def _qcolor(c: Color) -> QColor:
    return QColor.fromRgbF(c.r, c.g, c.b, c.a)


def _apply_fill(painter: QPainter, fill: Fill | None) -> None:
    if fill is not None:
        painter.setBrush(QBrush(_qcolor(fill.color)))
    else:
        painter.setBrush(QBrush())


_CAP_MAP : dict[LineCap, Qt.PenCapStyle] = {
    LineCap.BUTT: Qt.PenCapStyle.FlatCap,
    LineCap.ROUND: Qt.PenCapStyle.RoundCap,
    LineCap.SQUARE: Qt.PenCapStyle.SquareCap,
}

_JOIN_MAP : dict[LineJoin, Qt.PenJoinStyle] = {
    LineJoin.MITER: Qt.PenJoinStyle.MiterJoin,
    LineJoin.ROUND: Qt.PenJoinStyle.RoundJoin,
    LineJoin.BEVEL: Qt.PenJoinStyle.BevelJoin,
}


def _apply_stroke(painter: QPainter, stroke: Stroke | None) -> None:
    if stroke is not None:
        pen = QPen(_qcolor(stroke.color), stroke.width)
        pen.setCapStyle(_CAP_MAP[stroke.linecap])
        pen.setJoinStyle(_JOIN_MAP[stroke.linejoin])
        painter.setPen(pen)
    else:
        painter.setPen(QPen(0))


def _apply_transform(painter: QPainter, transform: Transform | None) -> None:
    if transform is not None:
        t = transform
        painter.setTransform(
            QTransform(t.a, t.b, t.c, t.d, t.e, t.f), combine=True,
        )


def _build_path(cmds: tuple[PathCommand, ...]) -> QPainterPath:
    """Build a QPainterPath from SVG path commands."""
    path = QPainterPath()
    last_control = None
    # start = (0.0, 0.0)
    for cmd in cmds:
        match cmd:
            case MoveTo(x, y):
                path.moveTo(x, y)
                # start = (x, y)
                last_control = None
            case LineTo(x, y):
                path.lineTo(x, y)
                last_control = None
            case CurveTo(x1, y1, x2, y2, x, y):
                path.cubicTo(x1, y1, x2, y2, x, y)
                last_control = (x2, y2)
            case SmoothCurveTo(x2, y2, x, y):
                cur = path.currentPosition()
                if last_control is not None:
                    x1 : float = 2 * cur.x() - last_control[0]
                    y1 = 2 * cur.y() - last_control[1]
                else:
                    x1, y1 = cur.x(), cur.y()
                path.cubicTo(x1, y1, x2, y2, x, y)
                last_control = (x2, y2)
            case QuadTo(x1, y1, x, y):
                path.quadTo(x1, y1, x, y)
                last_control = (x1, y1)
            case SmoothQuadTo(x, y):
                cur = path.currentPosition()
                if last_control is not None:
                    x1 : float = 2 * cur.x() - last_control[0]
                    y1 : float = 2 * cur.y() - last_control[1]
                else:
                    x1 : float = cur.x()
                    y1 : float = cur.y()
                path.quadTo(x1, y1, x, y)
                last_control = (x1, y1)
            case ArcTo():
                # Approximate arc with line to endpoint
                path.lineTo(cmd.x, cmd.y)
                last_control = None
            case ClosePath():
                path.closeSubpath()
                last_control = None
            case _:
                raise ValueError(f"Unknown path command: {cmd}")

    return path


def _draw_element(painter: QPainter, elem: Element) -> None:
    """Draw a single element using the QPainter."""
    painter.save()

    opacity = getattr(elem, 'opacity', 1.0)
    if opacity < 1.0:
        painter.setOpacity(painter.opacity() * opacity)

    transform = getattr(elem, 'transform', None)
    _apply_transform(painter, transform)

    match elem:
        case Line(x1=x1, y1=y1, x2=x2, y2=y2, stroke=stroke):
            _apply_stroke(painter, stroke)
            painter.drawLine(QPointF(x1, y1), QPointF(x2, y2))

        case Rect(x=x, y=y, width=w, height=h, rx=rx, ry=ry,
                  fill=fill, stroke=stroke):
            _apply_fill(painter, fill)
            _apply_stroke(painter, stroke)
            if rx > 0 or ry > 0:
                painter.drawRoundedRect(QRectF(x, y, w, h), rx, ry)
            else:
                painter.drawRect(QRectF(x, y, w, h))

        case Circle(cx=cx, cy=cy, r=r, fill=fill, stroke=stroke):
            _apply_fill(painter, fill)
            _apply_stroke(painter, stroke)
            painter.drawEllipse(QPointF(cx, cy), r, r)

        case Ellipse(cx=cx, cy=cy, rx=rx, ry=ry, fill=fill, stroke=stroke):
            _apply_fill(painter, fill)
            _apply_stroke(painter, stroke)
            painter.drawEllipse(QPointF(cx, cy), rx, ry)

        case Polyline(points=points, fill=fill, stroke=stroke):
            _apply_fill(painter, fill)
            _apply_stroke(painter, stroke)
            if points:
                qpoints = [QPointF(x, y) for x, y in points]
                painter.drawPolyline(qpoints)

        case Polygon(points=points, fill=fill, stroke=stroke):
            _apply_fill(painter, fill)
            _apply_stroke(painter, stroke)
            if points:
                qpoints = [QPointF(x, y) for x, y in points]
                painter.drawPolygon(qpoints)

        case Path(d=d, fill=fill, stroke=stroke):
            _apply_fill(painter, fill)
            _apply_stroke(painter, stroke)
            painter.drawPath(_build_path(d))

        case Text(x=x, y=y, content=content, font_family=ff,
                  font_size=fs, fill=fill, stroke=stroke):
            from PySide6.QtGui import QFont
            font = QFont(ff, int(fs))
            painter.setFont(font)
            if fill is not None:
                painter.setPen(_qcolor(fill.color))
            elif stroke is not None:
                _apply_stroke(painter, stroke)
            else:
                painter.setPen(QColor("black"))
            painter.drawText(QPointF(x, y), content)

        case Group(children=children) | Layer(children=children):
            for child in children:
                _draw_element(painter, child)
        
        case Element():
            raise ValueError(f"Unknown element type: {elem}")

    painter.restore()


_POLYGON_SIDES = 5


def _regular_polygon_points(x1: float, y1: float, x2: float, y2: float,
                            n: int) -> list[tuple[float, float]]:
    """Compute vertices of a regular n-gon with (x1,y1) and (x2,y2) as adjacent vertices."""
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


_SELECTION_COLOR = QColor(0, 120, 255)
_HANDLE_SIZE = 6.0


def _control_points(elem: Element) -> list[tuple[float, float]]:
    """Return the control-point positions for selection handles."""
    return element_control_points(elem)


def _draw_element_overlay(painter: QPainter, elem: Element,
                          selected_cps: frozenset[int] = frozenset()) -> None:
    """Draw the selection overlay (blue outline + handles) for one element.

    selected_cps is the set of control-point indices that should be
    filled blue; the rest are filled white.
    """
    pen = QPen(_SELECTION_COLOR, 1.0)
    painter.setPen(pen)
    painter.setBrush(QBrush())

    match elem:
        case Line(x1=x1, y1=y1, x2=x2, y2=y2):
            painter.drawLine(QPointF(x1, y1), QPointF(x2, y2))
        case Rect(x=x, y=y, width=w, height=h, rx=rx, ry=ry):
            if rx > 0 or ry > 0:
                painter.drawRoundedRect(QRectF(x, y, w, h), rx, ry)
            else:
                painter.drawRect(QRectF(x, y, w, h))
        case Circle(cx=cx, cy=cy, r=r):
            painter.drawEllipse(QPointF(cx, cy), r, r)
        case Ellipse(cx=cx, cy=cy, rx=rx, ry=ry):
            painter.drawEllipse(QPointF(cx, cy), rx, ry)
        case Polygon(points=points):
            if points:
                painter.drawPolygon([QPointF(x, y) for x, y in points])
        case Polyline(points=points):
            if points:
                painter.drawPolyline([QPointF(x, y) for x, y in points])
        case Path(d=d):
            painter.drawPath(_build_path(d))
        case _:
            bx, by, bw, bh = elem.bounds()
            painter.drawRect(QRectF(bx, by, bw, bh))

    # Draw handles
    half = _HANDLE_SIZE / 2
    painter.setPen(QPen(_SELECTION_COLOR, 1.0))
    for i, (px, py) in enumerate(_control_points(elem)):
        if i in selected_cps:
            painter.setBrush(QBrush(_SELECTION_COLOR))
        else:
            painter.setBrush(QBrush(QColor("white")))
        painter.drawRect(QRectF(px - half, py - half, _HANDLE_SIZE, _HANDLE_SIZE))


def _draw_selection_overlays(painter: QPainter, doc: Document) -> None:
    """Draw selection overlays for all selected elements."""
    for es in doc.selection:
        path = es.path
        if not path:
            continue
        painter.save()
        # Walk the path, applying transforms from each ancestor
        node: Element = doc.layers[path[0]]
        if len(path) > 1:
            _apply_transform(painter, getattr(node, 'transform', None))
            for idx in path[1:-1]:
                assert isinstance(node, Group)
                node = node.children[idx]
                _apply_transform(painter, getattr(node, 'transform', None))
            assert isinstance(node, Group)
            node = node.children[path[-1]]
        # Apply the selected element's own transform
        _apply_transform(painter, getattr(node, 'transform', None))
        _draw_element_overlay(painter, node, es.control_points)
        painter.restore()


class CanvasWidget(QWidget):
    """The canvas view. Receives document updates from the Model."""

    _HIT_RADIUS = 6.0  # pixels to detect a click on a control point

    def __init__(self, model: Model, controller: Controller,
                 bbox: BoundingBox = BoundingBox(0, 0, 800, 600)):
        super().__init__()
        self._model = model
        self._controller = controller
        self._bbox = bbox
        self._current_tool = Tool.SELECTION
        # Drag state for drawing tools
        self._drag_start: QPointF | None = None
        self._drag_end: QPointF | None = None
        # Move-drag state
        self._moving: bool = False
        # Inline text editing state
        self._text_editor: QLineEdit | None = None
        self._editing_path: tuple[int, ...] | None = None
        self.setMinimumSize(320, 240)
        self.setMouseTracking(True)
        model.on_document_changed(self._on_document_changed)

    @property
    def bbox(self) -> BoundingBox:
        return self._bbox

    def set_tool(self, tool: Tool) -> None:
        self._commit_text_edit()
        self._current_tool = tool

    def _on_document_changed(self, document: Document) -> None:
        self.update()

    def sizeHint(self):
        return QSize(int(self._bbox.width), int(self._bbox.height))

    def _hit_test_selection(self, pos: QPointF) -> bool:
        """Return True if pos is near any selected control point."""
        doc = self._model.document
        r = self._HIT_RADIUS
        for es in doc.selection:
            elem = doc.get_element(es.path)
            cps = element_control_points(elem)
            for i, (px, py) in enumerate(cps):
                if i in es.control_points:
                    if abs(pos.x() - px) <= r and abs(pos.y() - py) <= r:
                        return True
        return False

    def _hit_test_text(self, pos: QPointF) -> tuple[tuple[int, ...], Text] | None:
        """Return (path, Text) if pos is within a text element's bounds."""
        doc = self._model.document
        for li, layer in enumerate(doc.layers):
            for ci, child in enumerate(layer.children):
                if isinstance(child, Text):
                    bx, by, bw, bh = child.bounds()
                    if bx <= pos.x() <= bx + bw and by <= pos.y() <= by + bh:
                        return ((li, ci), child)
        return None

    def _start_text_edit(self, path: tuple[int, ...], text_elem: Text) -> None:
        """Show an inline editor over the text element."""
        self._commit_text_edit()
        self._editing_path = path
        from PySide6.QtGui import QFont
        editor = QLineEdit(self)
        editor.setText(text_elem.content)
        font = QFont(text_elem.font_family, int(text_elem.font_size))
        editor.setFont(font)
        # Position the editor at the text element's location
        bx, by, bw, bh = text_elem.bounds()
        editor.setGeometry(int(bx), int(by), max(int(bw) + 20, 100), int(bh) + 4)
        editor.setStyleSheet(
            "background: white; border: 1px solid #4a90d9; padding: 0px;"
        )
        editor.returnPressed.connect(self._commit_text_edit)
        editor.show()
        editor.setFocus()
        editor.selectAll()
        self._text_editor = editor

    def _commit_text_edit(self) -> None:
        """Apply the edited text to the document and remove the editor."""
        if self._text_editor is None or self._editing_path is None:
            return
        new_text = self._text_editor.text()
        path = self._editing_path
        doc = self._model.document
        old_elem = doc.get_element(path)
        if isinstance(old_elem, Text) and new_text != old_elem.content:
            import dataclasses
            new_elem = dataclasses.replace(old_elem, content=new_text)
            self._model.document = doc.replace_element(path, new_elem)
        self._text_editor.deleteLater()
        self._text_editor = None
        self._editing_path = None

    def mousePressEvent(self, event: QMouseEvent):
        if self._current_tool in (Tool.SELECTION, Tool.DIRECT_SELECTION, Tool.GROUP_SELECTION, Tool.TEXT, Tool.LINE, Tool.RECT, Tool.POLYGON) and event.button() == Qt.MouseButton.LeftButton:
            pos = event.position()
            # Check if clicking on a selected CP → move mode
            if self._current_tool in (Tool.SELECTION, Tool.DIRECT_SELECTION, Tool.GROUP_SELECTION):
                if self._hit_test_selection(pos):
                    self._drag_start = pos
                    self._drag_end = pos
                    self._moving = True
                    return
            self._drag_start = pos
            self._drag_end = pos
            self._moving = False

    def mouseMoveEvent(self, event: QMouseEvent):
        if self._drag_start is not None:
            pos = event.position()
            if event.modifiers() & Qt.KeyboardModifier.ShiftModifier:
                cx, cy = _constrain_angle(
                    self._drag_start.x(), self._drag_start.y(), pos.x(), pos.y())
                self._drag_end = QPointF(cx, cy)
            else:
                self._drag_end = pos
            self.update()

    def mouseReleaseEvent(self, event: QMouseEvent):
        if self._drag_start is not None and event.button() == Qt.MouseButton.LeftButton:
            end = event.position()
            start = self._drag_start
            tool = self._current_tool
            moving = self._moving
            shift = bool(event.modifiers() & Qt.KeyboardModifier.ShiftModifier)
            option = bool(event.modifiers() & Qt.KeyboardModifier.AltModifier)
            self._drag_start = None
            self._drag_end = None
            self._moving = False
            # Move mode: apply delta
            if moving:
                if shift:
                    cx, cy = _constrain_angle(start.x(), start.y(), end.x(), end.y())
                    end = QPointF(cx, cy)
                dx = end.x() - start.x()
                dy = end.y() - start.y()
                if dx != 0 or dy != 0:
                    if option:
                        self._controller.copy_selection(dx, dy)
                    else:
                        self._controller.move_selection(dx, dy)
                self.update()
                return
            # Selection tools: shift means extend
            extend = shift
            if tool == Tool.SELECTION:
                x = min(start.x(), end.x())
                y = min(start.y(), end.y())
                w = abs(end.x() - start.x())
                h = abs(end.y() - start.y())
                self._controller.select_rect(x, y, w, h, extend=extend)
                return
            # Group selection tool: marquee without group expansion
            if tool == Tool.GROUP_SELECTION:
                x = min(start.x(), end.x())
                y = min(start.y(), end.y())
                w = abs(end.x() - start.x())
                h = abs(end.y() - start.y())
                self._controller.group_select_rect(x, y, w, h, extend=extend)
                return
            # Direct selection tool: marquee with individual CP selection
            if tool == Tool.DIRECT_SELECTION:
                x = min(start.x(), end.x())
                y = min(start.y(), end.y())
                w = abs(end.x() - start.x())
                h = abs(end.y() - start.y())
                self._controller.direct_select_rect(x, y, w, h, extend=extend)
                return
            # Text tool: edit existing text or place new text
            if tool == Tool.TEXT:
                hit = self._hit_test_text(start)
                if hit is not None:
                    path, text_elem = hit
                    self._start_text_edit(path, text_elem)
                else:
                    elem = Text(
                        x=start.x(), y=start.y(),
                        content="Lorem Ipsum",
                        fill=Fill(color=Color(0, 0, 0)),
                    )
                    self._controller.add_element(elem)
                return
            # Drawing tools: shift means constrain angle
            if shift:
                cx, cy = _constrain_angle(start.x(), start.y(), end.x(), end.y())
                end = QPointF(cx, cy)
            if tool == Tool.LINE:
                elem = Line(
                    x1=start.x(), y1=start.y(),
                    x2=end.x(), y2=end.y(),
                    stroke=Stroke(color=Color(0, 0, 0), width=1.0),
                )
            elif tool == Tool.RECT:
                x = min(start.x(), end.x())
                y = min(start.y(), end.y())
                w = abs(end.x() - start.x())
                h = abs(end.y() - start.y())
                elem = Rect(
                    x=x, y=y, width=w, height=h,
                    stroke=Stroke(color=Color(0, 0, 0), width=1.0),
                )
            elif tool == Tool.POLYGON:
                pts = _regular_polygon_points(
                    start.x(), start.y(), end.x(), end.y(), _POLYGON_SIDES)
                elem = Polygon(
                    points=tuple(pts),
                    stroke=Stroke(color=Color(0, 0, 0), width=1.0),
                )
            else:
                return
            self._controller.add_element(elem)

    def paintEvent(self, event: QPaintEvent):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.fillRect(self.rect(), QColor("white"))
        doc = self._model.document
        for layer in doc.layers:
            _draw_element(painter, layer)
        # Draw selection overlays
        _draw_selection_overlays(painter, doc)
        # Draw drag preview
        if self._drag_start is not None and self._drag_end is not None:
            if self._moving:
                # Draw trace of elements being moved
                dx = self._drag_end.x() - self._drag_start.x()
                dy = self._drag_end.y() - self._drag_start.y()
                for es in doc.selection:
                    elem = doc.get_element(es.path)
                    moved = move_control_points(elem, es.control_points, dx, dy)
                    pen = QPen(_SELECTION_COLOR, 1.0, Qt.PenStyle.DashLine)
                    painter.setPen(pen)
                    painter.setBrush(QBrush())
                    _draw_element_overlay(painter, moved, es.control_points)
            else:
                pen = QPen(QColor(100, 100, 100), 1.0, Qt.PenStyle.DashLine)
                painter.setPen(pen)
                painter.setBrush(QBrush())
                if self._current_tool == Tool.LINE:
                    painter.drawLine(self._drag_start, self._drag_end)
                elif self._current_tool == Tool.POLYGON:
                    pts = _regular_polygon_points(
                        self._drag_start.x(), self._drag_start.y(),
                        self._drag_end.x(), self._drag_end.y(), _POLYGON_SIDES)
                    if pts:
                        qpts = [QPointF(x, y) for x, y in pts]
                        painter.drawPolygon(qpts)
                elif self._current_tool in (Tool.RECT, Tool.SELECTION, Tool.DIRECT_SELECTION, Tool.GROUP_SELECTION):
                    painter.drawRect(QRectF(self._drag_start, self._drag_end).normalized())
        painter.end()
