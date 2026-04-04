from dataclasses import dataclass

from PySide6.QtCore import QPointF, QRectF, QSize, Qt
from PySide6.QtGui import (
    QBrush, QColor, QPainter, QPainterPath, QPen, QTransform, QMouseEvent, QPaintEvent,
)
from PySide6.QtWidgets import QWidget

from controller import Controller
from document import Document
from element import (
    ArcTo, Circle, ClosePath, CurveTo, Element, Ellipse, Group, Layer, Line,
    LineTo, MoveTo, Path, PathCommand, Polygon, Polyline, QuadTo, Rect, SmoothCurveTo,
    SmoothQuadTo, Text,
    Color, Fill, LineCap, LineJoin, Stroke, Transform,
    control_points as element_control_points,
)
from model import Model
from toolbar import Tool


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
        self.setMinimumSize(320, 240)
        self.setMouseTracking(True)
        model.on_document_changed(self._on_document_changed)

    @property
    def bbox(self) -> BoundingBox:
        return self._bbox

    def set_tool(self, tool: Tool) -> None:
        self._current_tool = tool

    def _on_document_changed(self, document: Document) -> None:
        self.update()

    def sizeHint(self):
        return QSize(int(self._bbox.width), int(self._bbox.height))

    def mousePressEvent(self, event: QMouseEvent):
        if self._current_tool in (Tool.SELECTION, Tool.DIRECT_SELECTION, Tool.GROUP_SELECTION, Tool.LINE, Tool.RECT) and event.button() == Qt.MouseButton.LeftButton:
            self._drag_start = event.position()
            self._drag_end = event.position()

    def mouseMoveEvent(self, event: QMouseEvent):
        if self._drag_start is not None:
            self._drag_end = event.position()
            self.update()

    def mouseReleaseEvent(self, event: QMouseEvent):
        if self._drag_start is not None and event.button() == Qt.MouseButton.LeftButton:
            end = event.position()
            start = self._drag_start
            tool = self._current_tool
            self._drag_start = None
            self._drag_end = None
            # Selection tool: marquee select
            if tool == Tool.SELECTION:
                x = min(start.x(), end.x())
                y = min(start.y(), end.y())
                w = abs(end.x() - start.x())
                h = abs(end.y() - start.y())
                self._controller.select_rect(x, y, w, h)
                return
            # Group selection tool: marquee without group expansion
            if tool == Tool.GROUP_SELECTION:
                x = min(start.x(), end.x())
                y = min(start.y(), end.y())
                w = abs(end.x() - start.x())
                h = abs(end.y() - start.y())
                self._controller.group_select_rect(x, y, w, h)
                return
            # Direct selection tool: marquee with individual CP selection
            if tool == Tool.DIRECT_SELECTION:
                x = min(start.x(), end.x())
                y = min(start.y(), end.y())
                w = abs(end.x() - start.x())
                h = abs(end.y() - start.y())
                self._controller.direct_select_rect(x, y, w, h)
                return
            # Create the element based on current tool
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
            pen = QPen(QColor(100, 100, 100), 1.0, Qt.PenStyle.DashLine)
            painter.setPen(pen)
            painter.setBrush(QBrush())
            if self._current_tool == Tool.LINE:
                painter.drawLine(self._drag_start, self._drag_end)
            elif self._current_tool in (Tool.RECT, Tool.SELECTION, Tool.DIRECT_SELECTION, Tool.GROUP_SELECTION):
                painter.drawRect(QRectF(self._drag_start, self._drag_end).normalized())
        painter.end()
