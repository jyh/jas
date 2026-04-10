from dataclasses import dataclass

from PySide6.QtCore import QPointF, QRectF, QSize, Qt
from PySide6.QtGui import (
    QBrush, QColor, QCursor, QPainter, QPainterPath, QPen, QPixmap, QTransform,
    QMouseEvent, QPaintEvent,
)
from PySide6.QtWidgets import QLineEdit, QTextEdit, QWidget

import math

from document.controller import Controller
from document.document import Document, ElementSelection
from geometry.element import (
    ArcTo, Circle, ClosePath, CurveTo, Element, Ellipse, Group, Layer, Line,
    LineTo, MoveTo, Path, PathCommand, Polygon, Polyline, QuadTo, Rect, SmoothCurveTo,
    SmoothQuadTo, Text, TextPath,
    Color, Fill, LineCap, LineJoin, Stroke, Transform,
    control_points as element_control_points,
    path_handle_positions,
    path_distance_to_point,
    path_point_at_offset,
)
from document.model import Model
from tools.tool import CanvasTool, ToolContext, HIT_RADIUS, HANDLE_DRAW_SIZE
from tools.toolbar import Tool
from tools import create_tools


def _make_white_arrow_cursor() -> QCursor:
    """Create a white (hollow) arrow cursor for the Direct Selection tool."""
    pixmap = QPixmap(24, 24)
    pixmap.fill(Qt.GlobalColor.transparent)
    painter = QPainter(pixmap)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    path = QPainterPath()
    path.moveTo(4, 1)
    path.lineTo(4, 19)
    path.lineTo(8, 15)
    path.lineTo(12, 22)
    path.lineTo(15, 20)
    path.lineTo(11, 13)
    path.lineTo(16, 13)
    path.closeSubpath()
    painter.setPen(QPen(QColor(0, 0, 0), 1.5))
    painter.setBrush(QBrush(QColor(255, 255, 255)))
    painter.drawPath(path)
    painter.end()
    return QCursor(pixmap, 4, 1)


def _make_group_selection_cursor() -> QCursor:
    """Create a white arrow + plus cursor for the Group Selection tool."""
    pixmap = QPixmap(24, 24)
    pixmap.fill(Qt.GlobalColor.transparent)
    painter = QPainter(pixmap)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    path = QPainterPath()
    path.moveTo(4, 1)
    path.lineTo(4, 19)
    path.lineTo(8, 15)
    path.lineTo(12, 22)
    path.lineTo(15, 20)
    path.lineTo(11, 13)
    path.lineTo(16, 13)
    path.closeSubpath()
    painter.setPen(QPen(QColor(0, 0, 0), 1.5))
    painter.setBrush(QBrush(QColor(255, 255, 255)))
    painter.drawPath(path)
    # Plus sign
    painter.setPen(QPen(QColor(0, 0, 0), 2))
    painter.drawLine(17, 20, 23, 20)
    painter.drawLine(20, 17, 20, 23)
    painter.end()
    return QCursor(pixmap, 4, 1)


def _make_pen_cursor() -> QCursor:
    """Create a pen cursor from the reference PNG bitmap."""
    import os
    png_path = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "icons", "pen tool.png")
    pixmap = QPixmap(png_path)
    if pixmap.isNull():
        return QCursor(Qt.CursorShape.CrossCursor)
    pixmap = pixmap.scaled(32, 32, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation)
    pixmap.setDevicePixelRatio(2.0)
    return QCursor(pixmap, 1, 1)


def _make_add_anchor_point_cursor() -> QCursor:
    """Create an add anchor point cursor from the reference PNG bitmap."""
    import os
    png_path = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "icons", "add anchor point.png")
    pixmap = QPixmap(png_path)
    if pixmap.isNull():
        return QCursor(Qt.CursorShape.CrossCursor)
    pixmap = pixmap.scaled(32, 32, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation)
    pixmap.setDevicePixelRatio(2.0)
    return QCursor(pixmap, 1, 1)


def _make_delete_anchor_point_cursor() -> QCursor:
    """Create a delete anchor point cursor from the reference PNG bitmap."""
    import os
    png_path = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "icons", "delete anchor point.png")
    pixmap = QPixmap(png_path)
    if pixmap.isNull():
        return QCursor(Qt.CursorShape.CrossCursor)
    pixmap = pixmap.scaled(32, 32, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation)
    pixmap.setDevicePixelRatio(2.0)
    return QCursor(pixmap, 1, 1)


def _make_pencil_cursor() -> QCursor:
    """Create a pencil cursor from the reference PNG bitmap."""
    import os
    png_path = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "icons", "pencil tool.png")
    pixmap = QPixmap(png_path)
    if pixmap.isNull():
        return QCursor(Qt.CursorShape.CrossCursor)
    pixmap = pixmap.scaled(32, 32, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation)
    pixmap.setDevicePixelRatio(2.0)
    return QCursor(pixmap, 1, 31)


def _make_path_eraser_cursor() -> QCursor:
    """Create a path eraser cursor from the reference PNG bitmap."""
    import os
    png_path = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "icons", "path eraser tool.png")
    pixmap = QPixmap(png_path)
    if pixmap.isNull():
        return QCursor(Qt.CursorShape.CrossCursor)
    pixmap = pixmap.scaled(32, 32, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation)
    pixmap.setDevicePixelRatio(2.0)
    return QCursor(pixmap, 1, 31)


def _make_type_cursor() -> QCursor:
    """Create the Type tool cursor from assets/icons/type cursor.png."""
    import os
    png_path = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "icons", "type cursor.png")
    pixmap = QPixmap(png_path)
    if pixmap.isNull():
        return QCursor(Qt.CursorShape.IBeamCursor)
    pixmap = pixmap.scaled(32, 32, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation)
    pixmap.setDevicePixelRatio(2.0)
    return QCursor(pixmap, 16, 16)


def _make_type_on_path_cursor() -> QCursor:
    """Create the Type-on-a-Path tool cursor from assets/icons/type on a path cursor.png."""
    import os
    png_path = os.path.join(
        os.path.dirname(__file__), "..", "..", "assets", "icons", "type on a path cursor.png")
    pixmap = QPixmap(png_path)
    if pixmap.isNull():
        return QCursor(Qt.CursorShape.IBeamCursor)
    pixmap = pixmap.scaled(32, 32, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation)
    pixmap.setDevicePixelRatio(2.0)
    # Hot spot near the I-beam center; png is 32x32 device px (16x16 logical).
    return QCursor(pixmap, 16, 12)


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


def _arc_to_beziers(
    cx0: float, cy0: float,
    rx: float, ry: float, x_rotation: float,
    large_arc: bool, sweep: bool,
    x: float, y: float,
) -> list[tuple[float, float, float, float, float, float]]:
    """Convert an SVG arc to a list of cubic Bezier curves (x1,y1,x2,y2,x,y).

    Implements the W3C SVG endpoint-to-center parameterization (F.6).
    """
    # F.6.2 — degenerate cases
    if (cx0 == x and cy0 == y) or (rx == 0 and ry == 0):
        return []

    rx = abs(rx)
    ry = abs(ry)
    phi = math.radians(x_rotation)
    cos_phi = math.cos(phi)
    sin_phi = math.sin(phi)

    # F.6.5.1 — compute (x1', y1')
    dx2 = (cx0 - x) / 2.0
    dy2 = (cy0 - y) / 2.0
    x1p = cos_phi * dx2 + sin_phi * dy2
    y1p = -sin_phi * dx2 + cos_phi * dy2

    # F.6.6.2 — ensure radii are large enough
    x1p_sq = x1p * x1p
    y1p_sq = y1p * y1p
    rx_sq = rx * rx
    ry_sq = ry * ry
    lam = x1p_sq / rx_sq + y1p_sq / ry_sq
    if lam > 1.0:
        s = math.sqrt(lam)
        rx *= s
        ry *= s
        rx_sq = rx * rx
        ry_sq = ry * ry

    # F.6.5.2 — compute (cx', cy')
    num = max(rx_sq * ry_sq - rx_sq * y1p_sq - ry_sq * x1p_sq, 0.0)
    den = rx_sq * y1p_sq + ry_sq * x1p_sq
    sq = math.sqrt(num / den) if den > 0 else 0.0
    if large_arc == sweep:
        sq = -sq
    cxp = sq * rx * y1p / ry
    cyp = -sq * ry * x1p / rx

    # F.6.5.3 — compute (cx, cy)
    mx = (cx0 + x) / 2.0
    my = (cy0 + y) / 2.0
    ccx = cos_phi * cxp - sin_phi * cyp + mx
    ccy = sin_phi * cxp + cos_phi * cyp + my

    # F.6.5.5/6 — compute theta1 and dtheta
    def angle(ux: float, uy: float, vx: float, vy: float) -> float:
        n = math.sqrt(ux * ux + uy * uy) * math.sqrt(vx * vx + vy * vy)
        if n == 0:
            return 0.0
        c = max(-1.0, min(1.0, (ux * vx + uy * vy) / n))
        a = math.acos(c)
        if ux * vy - uy * vx < 0:
            a = -a
        return a

    theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dtheta = angle(
        (x1p - cxp) / rx, (y1p - cyp) / ry,
        (-x1p - cxp) / rx, (-y1p - cyp) / ry,
    )
    if not sweep and dtheta > 0:
        dtheta -= 2 * math.pi
    elif sweep and dtheta < 0:
        dtheta += 2 * math.pi

    # Split into segments of at most pi/2
    n_segs = max(1, int(math.ceil(abs(dtheta) / (math.pi / 2))))
    seg_angle = dtheta / n_segs

    # Bezier approximation of a unit arc segment
    alpha = math.sin(seg_angle) * (math.sqrt(4 + 3 * math.tan(seg_angle / 2) ** 2) - 1) / 3

    curves: list[tuple[float, float, float, float, float, float]] = []
    cos_t = math.cos(theta1)
    sin_t = math.sin(theta1)
    for _ in range(n_segs):
        cos_t2 = math.cos(theta1 + seg_angle)
        sin_t2 = math.sin(theta1 + seg_angle)

        # Endpoint on the ellipse (before rotation)
        ex1 = rx * cos_t
        ey1 = ry * sin_t
        ex2 = rx * cos_t2
        ey2 = ry * sin_t2

        # Derivatives
        dx1 = -rx * sin_t
        dy1 = ry * cos_t
        dx2 = -rx * sin_t2
        dy2 = ry * cos_t2

        # Control points (in rotated frame, then translated)
        cp1x = cos_phi * (ex1 + alpha * dx1) - sin_phi * (ey1 + alpha * dy1) + ccx
        cp1y = sin_phi * (ex1 + alpha * dx1) + cos_phi * (ey1 + alpha * dy1) + ccy
        cp2x = cos_phi * (ex2 - alpha * dx2) - sin_phi * (ey2 - alpha * dy2) + ccx
        cp2y = sin_phi * (ex2 - alpha * dx2) + cos_phi * (ey2 - alpha * dy2) + ccy
        epx = cos_phi * ex2 - sin_phi * ey2 + ccx
        epy = sin_phi * ex2 + cos_phi * ey2 + ccy

        curves.append((cp1x, cp1y, cp2x, cp2y, epx, epy))

        theta1 += seg_angle
        cos_t = cos_t2
        sin_t = sin_t2

    return curves


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
            case ArcTo(rx=arx, ry=ary, x_rotation=rot,
                       large_arc=la, sweep=sw, x=ax, y=ay):
                cur = path.currentPosition()
                beziers = _arc_to_beziers(
                    cur.x(), cur.y(), arx, ary, rot, la, sw, ax, ay,
                )
                for bx1, by1, bx2, by2, bx, by in beziers:
                    path.cubicTo(bx1, by1, bx2, by2, bx, by)
                if not beziers:
                    path.lineTo(ax, ay)
                last_control = None
            case ClosePath():
                path.closeSubpath()
                last_control = None
            case _:
                raise ValueError(f"Unknown path command: {cmd}")

    return path


def _apply_outline_style(painter: QPainter) -> None:
    """Configure ``painter`` for an outline-mode draw of a shape.

    The spec says "stroke of size 0"; in practice Qt strokes of width
    0 render as "cosmetic" hairlines (1 device pixel regardless of
    zoom), which matches the intended look. No fill, solid black
    stroke. Used when an element's effective visibility is
    :class:`Visibility.OUTLINE`.
    """
    from PySide6.QtGui import QBrush, QPen, Qt
    painter.setBrush(QBrush())
    pen = QPen(QColor("black"), 0.0)
    pen.setCosmetic(True)
    pen.setStyle(Qt.SolidLine)
    painter.setPen(pen)


def _draw_element(painter: QPainter, elem: Element,
                  ancestor_vis=None) -> None:
    """Draw a single element using the QPainter.

    ``ancestor_vis`` is the capping visibility inherited from parent
    Groups/Layers. The element's effective visibility is the minimum
    of its own ``visibility`` and ``ancestor_vis``:

    - ``INVISIBLE`` effective → the subtree is skipped entirely.
    - ``OUTLINE`` effective → every non-Text element is drawn with a
      thin black cosmetic stroke and no fill. Text and TextPath are
      the exception and render as Preview.
    - ``PREVIEW`` effective → normal rendering.
    """
    from geometry.element import Visibility
    if ancestor_vis is None:
        ancestor_vis = Visibility.PREVIEW
    effective = min(ancestor_vis, elem.visibility, key=lambda v: v.value)
    if effective == Visibility.INVISIBLE:
        return
    outline = effective == Visibility.OUTLINE

    painter.save()

    opacity = getattr(elem, 'opacity', 1.0)
    if opacity < 1.0:
        painter.setOpacity(painter.opacity() * opacity)

    transform = getattr(elem, 'transform', None)
    _apply_transform(painter, transform)

    match elem:
        case Line(x1=x1, y1=y1, x2=x2, y2=y2, stroke=stroke):
            if outline:
                _apply_outline_style(painter)
            else:
                _apply_stroke(painter, stroke)
            painter.drawLine(QPointF(x1, y1), QPointF(x2, y2))

        case Rect(x=x, y=y, width=w, height=h, rx=rx, ry=ry,
                  fill=fill, stroke=stroke):
            if outline:
                _apply_outline_style(painter)
            else:
                _apply_fill(painter, fill)
                _apply_stroke(painter, stroke)
            if rx > 0 or ry > 0:
                painter.drawRoundedRect(QRectF(x, y, w, h), rx, ry)
            else:
                painter.drawRect(QRectF(x, y, w, h))

        case Circle(cx=cx, cy=cy, r=r, fill=fill, stroke=stroke):
            if outline:
                _apply_outline_style(painter)
            else:
                _apply_fill(painter, fill)
                _apply_stroke(painter, stroke)
            painter.drawEllipse(QPointF(cx, cy), r, r)

        case Ellipse(cx=cx, cy=cy, rx=rx, ry=ry, fill=fill, stroke=stroke):
            if outline:
                _apply_outline_style(painter)
            else:
                _apply_fill(painter, fill)
                _apply_stroke(painter, stroke)
            painter.drawEllipse(QPointF(cx, cy), rx, ry)

        case Polyline(points=points, fill=fill, stroke=stroke):
            if outline:
                _apply_outline_style(painter)
            else:
                _apply_fill(painter, fill)
                _apply_stroke(painter, stroke)
            if points:
                qpoints = [QPointF(x, y) for x, y in points]
                painter.drawPolyline(qpoints)

        case Polygon(points=points, fill=fill, stroke=stroke):
            if outline:
                _apply_outline_style(painter)
            else:
                _apply_fill(painter, fill)
                _apply_stroke(painter, stroke)
            if points:
                qpoints = [QPointF(x, y) for x, y in points]
                painter.drawPolygon(qpoints)

        case Path(d=d, fill=fill, stroke=stroke):
            if outline:
                _apply_outline_style(painter)
            else:
                _apply_fill(painter, fill)
                _apply_stroke(painter, stroke)
            painter.drawPath(_build_path(d))

        case Text(x=x, y=y, content=content, font_family=ff,
                  font_size=fs, font_weight=fw, font_style=fst,
                  text_decoration=td,
                  width=tw, height=th,
                  fill=fill, stroke=stroke):
            from PySide6.QtGui import QFont
            font = QFont(ff, int(fs))
            if fw == "bold":
                font.setBold(True)
            if fst == "italic":
                font.setItalic(True)
            if td == "underline":
                font.setUnderline(True)
            elif td == "line-through":
                font.setStrikeOut(True)
            painter.setFont(font)
            if fill is not None:
                painter.setPen(_qcolor(fill.color))
            elif stroke is not None:
                _apply_stroke(painter, stroke)
            else:
                painter.setPen(QColor("black"))
            # Use the wrapped layout module so what the user sees matches
            # what the in-place editor measures.
            from algorithms.text_layout import layout as _layout
            from tools.text_measure import make_measurer
            measure = make_measurer(ff, fw, fst, fs)
            max_w = tw if (tw > 0 and th > 0) else 0.0
            lay = _layout(content, max_w, fs, measure)
            for line in lay.lines:
                s = content[line.start:line.end].rstrip('\n')
                painter.drawText(QPointF(x, y + line.baseline_y), s)

        case TextPath(d=d, content=content, start_offset=start_offset,
                      font_family=ff, font_size=fs,
                      font_weight=fw, font_style=fst, text_decoration=td,
                      fill=fill, stroke=stroke):
            from PySide6.QtGui import QFont, QFontMetricsF
            font = QFont(ff, int(fs))
            if fw == "bold":
                font.setBold(True)
            if fst == "italic":
                font.setItalic(True)
            if td == "underline":
                font.setUnderline(True)
            elif td == "line-through":
                font.setStrikeOut(True)
            painter.setFont(font)
            if fill is not None:
                painter.setPen(_qcolor(fill.color))
            elif stroke is not None:
                _apply_stroke(painter, stroke)
            else:
                painter.setPen(QColor("black"))
            path = _build_path(d)
            total_len = path.length()
            if total_len > 0:
                fm = QFontMetricsF(font)
                offset = start_offset * total_len
                for ch in content:
                    cw = fm.horizontalAdvance(ch)
                    mid = offset + cw / 2
                    if mid > total_len:
                        break
                    pct = mid / total_len
                    pt = path.pointAtPercent(pct)
                    angle = path.angleAtPercent(pct)
                    painter.save()
                    painter.translate(pt)
                    painter.rotate(-angle)
                    painter.drawText(QPointF(-cw / 2, fs / 3), ch)
                    painter.restore()
                    offset += cw

        case Group(children=children) | Layer(children=children):
            for child in children:
                _draw_element(painter, child, effective)

        case Element():
            raise ValueError(f"Unknown element type: {elem}")

    painter.restore()



_SELECTION_COLOR = QColor(0, 120, 255)
_HANDLE_SIZE = HANDLE_DRAW_SIZE
_HANDLE_CIRCLE_RADIUS = HANDLE_DRAW_SIZE / 2.0


def _control_points(elem: Element) -> list[tuple[float, float]]:
    """Return the control-point positions for selection handles."""
    return element_control_points(elem)


def _draw_element_overlay(painter: QPainter, elem: Element,
                          kind=None) -> None:
    """Draw the selection overlay for one element.

    Rule: every selected element (except Text/TextPath) is outlined
    by re-tracing its own geometry in bright blue, and its control-
    point squares are drawn on top. A CP listed in ``kind`` is filled
    blue; the rest are filled white. On ``.all`` every CP is filled
    blue — the whole element is grabbable.

    Text and TextPath are the exception: instead of re-tracing their
    geometry, they get a plain bounding-box rectangle (for area text
    the bbox aligns with the explicit area dimensions; for point
    text it wraps the glyphs). No CP squares for Text/TextPath.

    Groups and Layers emit no overlay themselves — their descendants
    are individually in the selection (see ``select_element``) and
    draw their own highlights.
    """
    from document.document import (
        selection_kind_contains as _contains,
        selection_kind_to_sorted as _to_sorted,
        selection_partial,
    )
    if kind is None:
        kind = selection_partial([])

    pen = QPen(_SELECTION_COLOR, 1.0)
    painter.setPen(pen)
    painter.setBrush(QBrush())

    # Text and TextPath: bounding-box highlight only. No CP squares.
    if isinstance(elem, (Text, TextPath)):
        bx, by, bw, bh = elem.bounds()
        painter.drawRect(QRectF(bx, by, bw, bh))
        return

    # Groups and Layers: nothing. Their descendants render their own
    # highlights when the group is selected.
    if isinstance(elem, (Group, Layer)):
        return

    # All other shapes: stroke the element's own geometry in blue.
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

    # Draw Bezier handles for selected path control points.
    cp_highlight = list(_to_sorted(kind, len(_control_points(elem))))
    if isinstance(elem, Path) and cp_highlight:
        anchors = _control_points(elem)
        for cp_idx in cp_highlight:
            if cp_idx >= len(anchors):
                continue
            ax, ay = anchors[cp_idx]
            h_in, h_out = path_handle_positions(elem.d, cp_idx)
            painter.setPen(QPen(_SELECTION_COLOR, 1.0))
            painter.setBrush(QBrush(QColor("white")))
            if h_in is not None:
                painter.drawLine(QPointF(ax, ay), QPointF(*h_in))
                painter.drawEllipse(QPointF(*h_in),
                                    _HANDLE_CIRCLE_RADIUS, _HANDLE_CIRCLE_RADIUS)
            if h_out is not None:
                painter.drawLine(QPointF(ax, ay), QPointF(*h_out))
                painter.drawEllipse(QPointF(*h_out),
                                    _HANDLE_CIRCLE_RADIUS, _HANDLE_CIRCLE_RADIUS)

    # Draw control-point squares for every non-Text, non-container
    # selected element.
    half = _HANDLE_SIZE / 2
    painter.setPen(QPen(_SELECTION_COLOR, 1.0))
    for i, (px, py) in enumerate(_control_points(elem)):
        if _contains(kind, i):
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
                if not isinstance(node, Group):
                    break
                node = node.children[idx]
                _apply_transform(painter, getattr(node, 'transform', None))
            if not isinstance(node, Group):
                painter.restore()
                continue
            node = node.children[path[-1]]
        # Apply the selected element's own transform
        _apply_transform(painter, getattr(node, 'transform', None))
        _draw_element_overlay(painter, node, es.kind)
        painter.restore()


class CanvasWidget(QWidget):
    """The canvas view. Receives document updates from the Model."""

    _HIT_RADIUS = HIT_RADIUS

    def __init__(self, model: Model, controller: Controller,
                 bbox: BoundingBox = BoundingBox(0, 0, 800, 600)):
        super().__init__()
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self._model = model
        self._controller = controller
        self._bbox = bbox
        self._current_tool_enum = Tool.SELECTION
        # Inline text editing state (managed by canvas, exposed via context)
        self._text_editor: QLineEdit | None = None
        self._editing_path: tuple[int, ...] | None = None
        # Tool system
        self._tools = create_tools()
        self._tool_ctx = ToolContext(
            model=model,
            controller=controller,
            hit_test_selection=self._hit_test_selection,
            hit_test_handle=self._hit_test_handle,
            hit_test_text=self._hit_test_text,
            hit_test_path_curve=self._hit_test_path_curve,
            request_update=self.update,
        )
        self.setMinimumSize(320, 240)
        self.setMouseTracking(True)
        self._update_cursor()
        model.on_document_changed(self._on_document_changed)
        # Caret blink timer: ticks while the active tool is in an editing
        # session (TypeTool / TypeOnPathTool with an open session).
        try:
            from PySide6.QtCore import QTimer
            self._blink_timer = QTimer(self)
            self._blink_timer.setInterval(265)
            self._blink_timer.timeout.connect(self._on_blink_tick)
            self._blink_timer.start()
        except (ImportError, RuntimeError):
            self._blink_timer = None

    def _on_blink_tick(self) -> None:
        editing = self._active_tool.is_editing()
        if editing:
            self.update()
        # Refresh the cursor when editing state changes (e.g. the type
        # tool entering or leaving a session) so the override flips to
        # the system I-beam.
        if editing != getattr(self, "_was_editing", False):
            self._was_editing = editing
            self._update_cursor()

    @property
    def bbox(self) -> BoundingBox:
        return self._bbox

    @property
    def _active_tool(self) -> CanvasTool:
        return self._tools[self._current_tool_enum]

    def set_tool(self, tool: Tool) -> None:
        saved_selection = self._model.document.selection
        self._active_tool.deactivate(self._tool_ctx)
        self._current_tool_enum = tool
        self._active_tool.activate(self._tool_ctx)
        self._update_cursor()
        # Preserve selection across tool changes
        if self._model.document.selection != saved_selection:
            from dataclasses import replace
            self._model.document = replace(self._model.document,
                                           selection=saved_selection)

    def _update_cursor(self) -> None:
        # Active tool can override the per-tool cursor (e.g. the type
        # tools switch to the system I-beam while in an editing session).
        override = None
        try:
            override = self._active_tool.cursor_css_override()
        except AttributeError:
            override = None
        if override == "ibeam":
            self.setCursor(QCursor(Qt.CursorShape.IBeamCursor))
            return
        self.setCursor(self._cursor_for_tool(self._current_tool_enum))

    @staticmethod
    def _cursor_for_tool(tool: Tool) -> QCursor:
        if tool == Tool.SELECTION:
            return QCursor(Qt.CursorShape.ArrowCursor)
        elif tool == Tool.DIRECT_SELECTION:
            return _make_white_arrow_cursor()
        elif tool == Tool.GROUP_SELECTION:
            return _make_group_selection_cursor()
        elif tool == Tool.PEN:
            return _make_pen_cursor()
        elif tool == Tool.ADD_ANCHOR_POINT:
            return _make_add_anchor_point_cursor()
        elif tool == Tool.DELETE_ANCHOR_POINT:
            return _make_delete_anchor_point_cursor()
        elif tool == Tool.PENCIL:
            return _make_pencil_cursor()
        elif tool == Tool.PATH_ERASER:
            return _make_path_eraser_cursor()
        elif tool == Tool.TYPE:
            return _make_type_cursor()
        elif tool == Tool.TYPE_ON_PATH:
            return _make_type_on_path_cursor()
        else:
            return QCursor(Qt.CursorShape.CrossCursor)

    def _on_document_changed(self, document: Document) -> None:
        self.update()

    def sizeHint(self):
        return QSize(int(self._bbox.width), int(self._bbox.height))

    def _hit_test_selection(self, x: float, y: float) -> bool:
        from document.document import selection_kind_contains as _contains
        doc = self._model.document
        r = self._HIT_RADIUS
        for es in doc.selection:
            elem = doc.get_element(es.path)
            cps = element_control_points(elem)
            for i, (px, py) in enumerate(cps):
                if _contains(es.kind, i):
                    if abs(x - px) <= r and abs(y - py) <= r:
                        return True
        return False

    def _hit_test_handle(self, x: float, y: float
                         ) -> tuple[tuple[int, ...], int, str] | None:
        from document.document import selection_kind_to_sorted as _to_sorted
        doc = self._model.document
        r = self._HIT_RADIUS
        for es in doc.selection:
            elem = doc.get_element(es.path)
            if not isinstance(elem, Path):
                continue
            from geometry.element import control_point_count
            n = control_point_count(elem)
            for cp_idx in _to_sorted(es.kind, n):
                h_in, h_out = path_handle_positions(elem.d, cp_idx)
                if h_in is not None:
                    if abs(x - h_in[0]) <= r and abs(y - h_in[1]) <= r:
                        return (es.path, cp_idx, 'in')
                if h_out is not None:
                    if abs(x - h_out[0]) <= r and abs(y - h_out[1]) <= r:
                        return (es.path, cp_idx, 'out')
        return None

    def _hit_test_text(self, x: float, y: float) -> tuple[tuple[int, ...], Text] | None:
        doc = self._model.document
        for li, layer in enumerate(doc.layers):
            for ci, child in enumerate(layer.children):
                if isinstance(child, Text):
                    bx, by, bw, bh = child.bounds()
                    if bx <= x <= bx + bw and by <= y <= by + bh:
                        return ((li, ci), child)
        return None

    def _hit_test_path_curve(self, x: float, y: float
                             ) -> tuple[tuple[int, ...], Element] | None:
        """Test if (x, y) is near a Path or TextPath element's curve."""
        doc = self._model.document
        threshold = self._HIT_RADIUS + 2
        for li, layer in enumerate(doc.layers):
            for ci, child in enumerate(layer.children):
                if isinstance(child, (Path, TextPath)):
                    dist = path_distance_to_point(child.d, x, y)
                    if dist <= threshold:
                        return ((li, ci), child)
                elif isinstance(child, Group) and not isinstance(child, Layer):
                    for gi, gc in enumerate(child.children):
                        if isinstance(gc, (Path, TextPath)):
                            dist = path_distance_to_point(gc.d, x, y)
                            if dist <= threshold:
                                return ((li, ci, gi), gc)
        return None

    # -- Event dispatch to active tool --

    @staticmethod
    def _qt_key_to_name(event) -> str:
        from PySide6.QtCore import Qt as _Qt
        k = event.key()
        # Special keys → JS-style names.
        special = {
            _Qt.Key.Key_Escape: "Escape",
            _Qt.Key.Key_Return: "Enter",
            _Qt.Key.Key_Enter: "Enter",
            _Qt.Key.Key_Backspace: "Backspace",
            _Qt.Key.Key_Delete: "Delete",
            _Qt.Key.Key_Left: "ArrowLeft",
            _Qt.Key.Key_Right: "ArrowRight",
            _Qt.Key.Key_Up: "ArrowUp",
            _Qt.Key.Key_Down: "ArrowDown",
            _Qt.Key.Key_Home: "Home",
            _Qt.Key.Key_End: "End",
            _Qt.Key.Key_Tab: "Tab",
        }
        if k in special:
            return special[k]
        text = event.text()
        if text and text.isprintable():
            return text
        return ""

    def _build_key_mods(self, event) -> "KeyMods":
        from tools.tool import KeyMods
        m = event.modifiers()
        return KeyMods(
            shift=bool(m & Qt.KeyboardModifier.ShiftModifier),
            ctrl=bool(m & Qt.KeyboardModifier.ControlModifier),
            alt=bool(m & Qt.KeyboardModifier.AltModifier),
            meta=bool(m & Qt.KeyboardModifier.MetaModifier),
        )

    def keyPressEvent(self, event):
        # When the active tool is capturing keyboard (active text edit
        # session), all keys go to it first.
        if self._active_tool.captures_keyboard():
            from tools.tool import KeyMods
            mods = self._build_key_mods(event)
            # Cmd+V → async paste path; otherwise pass to on_key_event.
            if mods.cmd() and event.text().lower() == "v":
                from PySide6.QtWidgets import QApplication
                app = QApplication.instance()
                text = app.clipboard().text() if app is not None else ""
                if text:
                    self._active_tool.paste_text(self._tool_ctx, text)
                    self.update()
                return
            name = self._qt_key_to_name(event)
            if name and self._active_tool.on_key_event(self._tool_ctx, name, mods):
                self._update_cursor_for_tool()
                return
        if self._active_tool.on_key(self._tool_ctx, event.key()):
            return
        super().keyPressEvent(event)

    def keyReleaseEvent(self, event):
        if self._active_tool.on_key_release(self._tool_ctx, event.key()):
            return
        super().keyReleaseEvent(event)

    def _update_cursor_for_tool(self) -> None:
        override = self._active_tool.cursor_css_override()
        if override == "none":
            self.setCursor(QCursor(Qt.CursorShape.BlankCursor))
        elif override == "ibeam":
            self.setCursor(QCursor(Qt.CursorShape.IBeamCursor))
        else:
            self.setCursor(self._cursor_for_tool(self._current_tool_enum))

    def mouseDoubleClickEvent(self, event: QMouseEvent):
        if event.button() == Qt.MouseButton.LeftButton:
            pos = event.position()
            self._active_tool.on_double_click(self._tool_ctx, pos.x(), pos.y())
            return
        super().mouseDoubleClickEvent(event)

    def mousePressEvent(self, event: QMouseEvent):
        self.setFocus()
        if event.button() == Qt.MouseButton.LeftButton:
            pos = event.position()
            shift = bool(event.modifiers() & Qt.KeyboardModifier.ShiftModifier)
            alt = bool(event.modifiers() & Qt.KeyboardModifier.AltModifier)
            self._active_tool.on_press(self._tool_ctx, pos.x(), pos.y(), shift, alt)
            self._update_cursor_for_tool()

    def mouseMoveEvent(self, event: QMouseEvent):
        pos = event.position()
        shift = bool(event.modifiers() & Qt.KeyboardModifier.ShiftModifier)
        dragging = bool(event.buttons() & Qt.MouseButton.LeftButton)
        self._active_tool.on_move(self._tool_ctx, pos.x(), pos.y(), shift, dragging)
        self._update_cursor_for_tool()

    def mouseReleaseEvent(self, event: QMouseEvent):
        if event.button() == Qt.MouseButton.LeftButton:
            pos = event.position()
            shift = bool(event.modifiers() & Qt.KeyboardModifier.ShiftModifier)
            alt = bool(event.modifiers() & Qt.KeyboardModifier.AltModifier)
            self._active_tool.on_release(self._tool_ctx, pos.x(), pos.y(), shift, alt)

    def paintEvent(self, event: QPaintEvent):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.fillRect(self.rect(), QColor("white"))
        doc = self._model.document
        for layer in doc.layers:
            _draw_element(painter, layer)
        _draw_selection_overlays(painter, doc)
        self._active_tool.draw_overlay(self._tool_ctx, painter)
        painter.end()
