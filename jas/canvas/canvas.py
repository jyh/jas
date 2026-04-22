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
    ArcTo, BlendMode, Circle, ClosePath, CurveTo, Element, Ellipse, Group, Layer, Line,
    LineTo, MoveTo, Path, PathCommand, Polygon, Polyline, QuadTo, Rect, SmoothCurveTo,
    SmoothQuadTo, Text, TextPath,
    Color, Fill, LineCap, LineJoin, Stroke, StrokeAlign, Transform,
    control_points as element_control_points,
    path_handle_positions,
    path_distance_to_point,
    path_point_at_offset,
)
from canvas.arrowheads import (
    arrow_setback, shorten_path,
    draw_arrowheads, draw_arrowheads_line,
)
from canvas.offset_path import (
    render_variable_width_path, render_variable_width_line,
)
from document.model import Model
from tools.tool import CanvasTool, ToolContext, HIT_RADIUS, HANDLE_DRAW_SIZE
from tools.toolbar import Tool
from tools import create_tools


def _make_white_arrow_cursor() -> QCursor:
    """Create a white (hollow) arrow cursor for the Partial Selection tool."""
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


def _make_interior_selection_cursor() -> QCursor:
    """Create a white arrow + plus cursor for the Interior Selection tool."""
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
    r, g, b, a = c.to_rgba()
    return QColor.fromRgbF(r, g, b, a)


def _qt_composition_mode(m: BlendMode) -> QPainter.CompositionMode:
    """Map a ``BlendMode`` to the QPainter composition mode.

    Qt natively supports all 16 of the Opacity panel's blend modes.
    ``NORMAL`` maps to ``CompositionMode_SourceOver`` (the Qt default).
    """
    cm = QPainter.CompositionMode
    return {
        BlendMode.NORMAL:      cm.CompositionMode_SourceOver,
        BlendMode.DARKEN:      cm.CompositionMode_Darken,
        BlendMode.MULTIPLY:    cm.CompositionMode_Multiply,
        BlendMode.COLOR_BURN:  cm.CompositionMode_ColorBurn,
        BlendMode.LIGHTEN:     cm.CompositionMode_Lighten,
        BlendMode.SCREEN:      cm.CompositionMode_Screen,
        BlendMode.COLOR_DODGE: cm.CompositionMode_ColorDodge,
        BlendMode.OVERLAY:     cm.CompositionMode_Overlay,
        BlendMode.SOFT_LIGHT:  cm.CompositionMode_SoftLight,
        BlendMode.HARD_LIGHT:  cm.CompositionMode_HardLight,
        BlendMode.DIFFERENCE:  cm.CompositionMode_Difference,
        BlendMode.EXCLUSION:   cm.CompositionMode_Exclusion,
        # Qt does not expose HSL blend operators by name; fall back to
        # SourceOver for those four modes. The blend_mode field is still
        # stored on the element and round-trips through SVG / test JSON.
        BlendMode.HUE:         cm.CompositionMode_SourceOver,
        BlendMode.SATURATION:  cm.CompositionMode_SourceOver,
        BlendMode.COLOR:       cm.CompositionMode_SourceOver,
        BlendMode.LUMINOSITY:  cm.CompositionMode_SourceOver,
    }[m]


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


def _parse_pt(s: str) -> float | None:
    """Parse a CSS length string in ``pt``. Returns the numeric value,
    or ``None`` when the string is empty or has an unrecognised unit.
    Mirrors Rust's ``parse_pt`` helper."""
    if not s:
        return None
    s = s.strip()
    if s.endswith("pt"):
        s = s[:-2]
    try:
        return float(s)
    except ValueError:
        return None


def _parse_em(s: str) -> float | None:
    """Parse a CSS length string in ``em``. Returns the numeric value,
    or ``None`` when empty / unparseable."""
    if not s:
        return None
    s = s.strip()
    if s.endswith("em"):
        s = s[:-2]
    try:
        return float(s)
    except ValueError:
        return None


def _parse_scale_percent(s: str) -> float:
    """Parse a percent scale string (e.g. ``"120"``). Empty returns
    ``1.0`` (identity); unparseable also returns ``1.0``."""
    if not s:
        return 1.0
    try:
        return float(s) / 100.0
    except ValueError:
        return 1.0


def _parse_rotate_deg(s: str) -> float:
    """Parse a rotation string (degrees). Empty / unparseable → 0."""
    if not s:
        return 0.0
    try:
        return float(s)
    except ValueError:
        return 0.0


def _parse_baseline_shift(s: str, font_size: float) -> tuple[float, float]:
    """Parse Character-panel ``baseline_shift`` → ``(size_scale, y_shift)``.

    - ``"super"``: shrink to 70% and shift up ~35% of font size.
    - ``"sub"``: shrink to 70% and shift down ~20% of font size.
    - ``"Npt"``: shift up by N points with the original size.
    - Empty: identity.
    """
    if s == "super":
        return (0.7, -font_size * 0.35)
    if s == "sub":
        return (0.7, font_size * 0.2)
    pt = _parse_pt(s)
    if pt is not None:
        return (1.0, -pt)
    return (1.0, 0.0)


def _apply_text_capitalization(font, text_transform: str, font_variant: str) -> None:
    """Apply QFont capitalization for ``text_transform`` and
    ``font_variant``. ``text_transform: uppercase`` / ``lowercase``
    map to the matching QFont enums; ``font_variant: small-caps``
    uses QFont.Capitalization.SmallCaps. No-op when neither is set."""
    from PySide6.QtGui import QFont
    Cap = QFont.Capitalization
    if text_transform == "uppercase":
        font.setCapitalization(Cap.AllUppercase)
    elif text_transform == "lowercase":
        font.setCapitalization(Cap.AllLowercase)
    elif font_variant == "small-caps":
        font.setCapitalization(Cap.SmallCaps)


def _letter_spacing_px(letter_spacing: str, kerning: str, font_size: float) -> float:
    """Combined letter-spacing in pixels for QFont. Tracking and
    numeric kerning both express as ``Nem``; Canvas lacks per-pair
    kerning, so we accumulate them into a uniform advance (matches
    Rust's approximation in ``canvas/render.rs``)."""
    ls_em = _parse_em(letter_spacing) or 0.0
    k_em = _parse_em(kerning) or 0.0
    return (ls_em + k_em) * font_size


def _draw_segmented_text(painter: QPainter, t) -> None:
    """Draw a Text element's tspans in sequence on a shared baseline,
    each using its effective font (override or parent fallback) and
    effective text-decoration. Mirrors Rust's ``draw_segmented_text``,
    Swift's ``drawSegmentedText``, and OCaml's ``_draw_segmented_text``.

    Covers TSPAN.md's rendering "minimum subset": font + decoration
    per tspan on one line. Omits per-tspan baseline-shift / transform
    / rotate / dx and multi-line wrapping — those collapse to the
    element-wide defaults for now.
    """
    from PySide6.QtGui import QFont
    from PySide6.QtCore import QPointF

    parent_bold = t.font_weight == "bold"
    parent_italic = t.font_style == "italic"
    parent_decor_tokens = [
        tok for tok in t.text_decoration.split()
        if tok and tok != "none"
    ]

    fill = t.fill
    if fill is not None:
        painter.setPen(_qcolor(fill.color))
    else:
        painter.setPen(QColor("black"))

    # Baseline sits at the first visual line: element y + 0.8 *
    # font_size. Segmented rendering is one-line only for now.
    baseline = t.y + t.font_size * 0.8
    cx = t.x

    for span in t.tspans:
        if not span.content:
            continue
        eff_family = span.font_family if span.font_family is not None else t.font_family
        eff_size = span.font_size if span.font_size is not None else t.font_size
        eff_bold = (span.font_weight == "bold") if span.font_weight is not None else parent_bold
        eff_italic = (span.font_style == "italic") if span.font_style is not None else parent_italic

        font = QFont(eff_family, int(eff_size))
        font.setPointSizeF(eff_size)
        if eff_bold:
            font.setBold(True)
        if eff_italic:
            font.setItalic(True)

        # Effective decoration: Some(tuple) overrides (empty tuple =
        # explicit no-decoration); None inherits parent tokens.
        if span.text_decoration is not None:
            members = span.text_decoration
            has_u = "underline" in members
            has_s = "line-through" in members
        else:
            has_u = "underline" in parent_decor_tokens
            has_s = "line-through" in parent_decor_tokens
        if has_u:
            font.setUnderline(True)
        if has_s:
            font.setStrikeOut(True)

        painter.setFont(font)

        # Per-tspan positioning:
        #   dx (em): leading-edge horizontal nudge, scaled by eff_size.
        #   baseline_shift (pt, + is up): subtracted from the shared
        #     baseline (Qt y grows downward, same convention as CSS).
        #   rotate (deg) / transform (SVG matrix): wrap the tspan draw
        #     around its starting baseline point.
        dx_px = (span.dx or 0.0) * eff_size
        cx += dx_px
        b_shift = span.baseline_shift or 0.0
        tspan_baseline = baseline - b_shift
        rot_deg = span.rotate or 0.0
        has_rotate = rot_deg != 0.0
        has_transform = span.transform is not None

        from PySide6.QtGui import QFontMetricsF, QTransform
        fm = QFontMetricsF(font)
        w = fm.horizontalAdvance(span.content)

        if has_rotate or has_transform:
            painter.save()
            painter.translate(cx, tspan_baseline)
            if has_transform:
                tr = span.transform
                painter.setTransform(
                    QTransform(tr.a, tr.b, tr.c, tr.d, tr.e, tr.f),
                    combine=True,
                )
            if has_rotate:
                painter.rotate(rot_deg)
            painter.drawText(QPointF(0, 0), span.content)
            painter.restore()
        else:
            painter.drawText(QPointF(cx, tspan_baseline), span.content)
        cx += w


def _apply_stroke(painter: QPainter, stroke: Stroke | None) -> tuple[float, StrokeAlign]:
    """Apply stroke properties to the painter. Returns (opacity, align)."""
    if stroke is not None:
        effective_width = stroke.width if stroke.align == StrokeAlign.CENTER else stroke.width * 2.0
        pen = QPen(_qcolor(stroke.color), effective_width)
        pen.setCapStyle(_CAP_MAP[stroke.linecap])
        pen.setJoinStyle(_JOIN_MAP[stroke.linejoin])
        pen.setMiterLimit(stroke.miter_limit)
        if stroke.dash_pattern:
            pen.setDashPattern([float(x) for x in stroke.dash_pattern])
        painter.setPen(pen)
        return (stroke.opacity, stroke.align)
    else:
        painter.setPen(QPen(0))
        return (1.0, StrokeAlign.CENTER)


def _stroke_aligned(painter: QPainter, path: QPainterPath,
                    align: StrokeAlign) -> None:
    """Stroke a path with alignment clipping."""
    if align == StrokeAlign.CENTER:
        painter.strokePath(path, painter.pen())
    elif align == StrokeAlign.INSIDE:
        painter.save()
        painter.setClipPath(path)
        painter.strokePath(path, painter.pen())
        painter.restore()
    elif align == StrokeAlign.OUTSIDE:
        inverse = QPainterPath()
        inverse.addRect(-1e6, -1e6, 2e6, 2e6)
        inverse.addPath(path)
        inverse.setFillRule(Qt.FillRule.OddEvenFill)
        painter.save()
        painter.setClipPath(inverse)
        painter.strokePath(path, painter.pen())
        painter.restore()


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


import enum


class MaskPlan(enum.Enum):
    """How the mask subtree's rendered alpha is applied to the
    element. Selected by ``_mask_plan`` from the mask's ``clip`` and
    ``invert`` fields; consumed by ``_draw_element_with_mask``.
    Mirrors the Rust / Swift / OCaml renderer's ``MaskPlan`` /
    ``mask_plan`` types. OPACITY.md §Rendering.
    """
    # Element clipped to the mask shape. DestinationIn applied
    # across the whole offscreen image. `clip: true, invert: false`.
    CLIP_IN = "clip_in"
    # Element clipped to the *inverse* of the mask shape.
    # DestinationOut across the whole offscreen image. Covers both
    # `clip: true, invert: true` and — for alpha-based masks —
    # `clip: false, invert: true`, which collapse to the same output
    # (E * (1 - M) everywhere) since the mask's outside-region alpha
    # is zero either way.
    CLIP_OUT = "clip_out"
    # `clip: false, invert: false`: element stays at full alpha
    # outside the mask subtree's bounding box; DestinationIn with
    # the mask applies only inside the bbox via a clipped sub-painter.
    REVEAL_OUTSIDE_BBOX = "reveal_outside_bbox"


def _mask_plan(mask) -> MaskPlan | None:
    """Pick a ``MaskPlan`` for the mask, or ``None`` when the mask
    is inactive (``disabled=True``)."""
    if mask.disabled:
        return None
    if mask.clip and not mask.invert:
        return MaskPlan.CLIP_IN
    if mask.clip and mask.invert:
        return MaskPlan.CLIP_OUT
    # Alpha-based masks can't distinguish `clip: false, invert: true`
    # from `clip: true, invert: true` (both yield E * (1 - M) when
    # the mask's outside-region alpha is 0), so route them through
    # the same composite.
    if not mask.clip and mask.invert:
        return MaskPlan.CLIP_OUT
    return MaskPlan.REVEAL_OUTSIDE_BBOX


def _effective_mask_transform(mask, elem) -> "Transform | None":
    """Return the transform that should be applied when rendering
    the mask's subtree on top of the ancestor coord system. Track
    C phase 3, OPACITY.md §Document model:

    - ``linked=True``  — mask inherits ``elem.transform`` (mask
      follows the element).
    - ``linked=False`` — mask uses ``mask.unlink_transform`` (the
      element's transform captured at unlink time, frozen so the
      mask stays fixed under subsequent element edits).

    Returns ``None`` when the picked transform is absent (identity
    case) so the caller can skip the ``_apply_transform`` call.
    """
    if mask.linked:
        return getattr(elem, 'transform', None)
    return mask.unlink_transform


def _draw_element(painter: QPainter, elem: Element,
                  ancestor_vis=None) -> None:
    """Draw a single element, dispatching to the mask composite
    path when the element carries an active mask."""
    mask = getattr(elem, 'mask', None)
    if mask is not None:
        plan = _mask_plan(mask)
        if plan is not None:
            _draw_element_with_mask(painter, elem, mask, plan, ancestor_vis)
            return
    _draw_element_body(painter, elem, ancestor_vis)


def _draw_element_with_mask(painter: QPainter, elem: Element,
                            mask, plan: MaskPlan,
                            ancestor_vis) -> None:
    """Render ``elem`` with its opacity mask composited in per
    ``plan``. The element body is drawn onto an offscreen
    ``QImage`` with the main painter's current world transform;
    the mask subtree is then composited. The offscreen image is
    finally blitted onto the main painter at device coordinates.

    OPACITY.md §Rendering.
    """
    from PySide6.QtGui import QImage
    device = painter.device()
    if device is None:
        _draw_element_body(painter, elem, ancestor_vis)
        return
    w = int(device.width())
    h = int(device.height())
    if w <= 0 or h <= 0:
        return
    image = QImage(w, h, QImage.Format.Format_ARGB32_Premultiplied)
    image.fill(0)  # fully transparent
    cm = QPainter.CompositionMode
    sub = QPainter(image)
    try:
        sub.setRenderHint(
            QPainter.RenderHint.Antialiasing,
            bool(painter.renderHints() & QPainter.RenderHint.Antialiasing),
        )
        sub.setTransform(painter.transform())
        _draw_element_body(sub, elem, ancestor_vis)
        # Apply the mask's effective transform (per
        # _effective_mask_transform), then composite the mask
        # subtree against the element body. Track C phase 3.
        sub.save()
        _apply_transform(sub, _effective_mask_transform(mask, elem))
        if plan == MaskPlan.CLIP_IN:
            sub.setCompositionMode(cm.CompositionMode_DestinationIn)
            _draw_element(sub, mask.subtree, ancestor_vis)
        elif plan == MaskPlan.CLIP_OUT:
            sub.setCompositionMode(cm.CompositionMode_DestinationOut)
            _draw_element(sub, mask.subtree, ancestor_vis)
        elif plan == MaskPlan.REVEAL_OUTSIDE_BBOX:
            # `clip: false, invert: false`: keep the element body at
            # full alpha outside the mask subtree's bounding box;
            # apply DestinationIn only inside the bbox via a clipped
            # sub-painter. OPACITY.md §Rendering.
            bx, by, bw, bh = mask.subtree.bounds()
            if bw > 0 and bh > 0:
                sub.save()
                sub.setClipRect(QRectF(bx, by, bw, bh))
                sub.setCompositionMode(cm.CompositionMode_DestinationIn)
                _draw_element(sub, mask.subtree, ancestor_vis)
                sub.restore()
            # Empty-bbox mask: body passes through unmodified
            # (mask has nothing to composite against).
        sub.restore()
    finally:
        sub.end()
    painter.save()
    painter.resetTransform()
    painter.drawImage(0, 0, image)
    painter.restore()


def _draw_element_body(painter: QPainter, elem: Element,
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

    blend_mode = getattr(elem, 'blend_mode', None)
    if blend_mode is not None:
        painter.setCompositionMode(_qt_composition_mode(blend_mode))

    transform = getattr(elem, 'transform', None)
    _apply_transform(painter, transform)

    match elem:
        case Line(x1=x1, y1=y1, x2=x2, y2=y2, stroke=stroke):
            if outline:
                _apply_outline_style(painter)
                painter.drawLine(QPointF(x1, y1), QPointF(x2, y2))
            else:
                stroke_opacity, stroke_align = _apply_stroke(painter, stroke)
                if stroke_opacity < 1.0:
                    painter.setOpacity(painter.opacity() * stroke_opacity)
                # Shorten line for arrowheads
                lx1, ly1, lx2, ly2 = x1, y1, x2, y2
                if stroke is not None:
                    dx = lx2 - lx1
                    dy = ly2 - ly1
                    ln = math.sqrt(dx * dx + dy * dy)
                    if ln > 0:
                        ux, uy = dx / ln, dy / ln
                        start_sb = arrow_setback(stroke.start_arrow.value, stroke.width, stroke.start_arrow_scale)
                        end_sb = arrow_setback(stroke.end_arrow.value, stroke.width, stroke.end_arrow_scale)
                        lx1 += ux * start_sb
                        ly1 += uy * start_sb
                        lx2 -= ux * end_sb
                        ly2 -= uy * end_sb
                # Variable-width or normal stroke
                wp = getattr(elem, 'width_points', ())
                if wp and stroke is not None:
                    render_variable_width_line(painter, lx1, ly1, lx2, ly2,
                                              wp, _qcolor(stroke.color), stroke.linecap)
                else:
                    line_path = QPainterPath()
                    line_path.moveTo(lx1, ly1)
                    line_path.lineTo(lx2, ly2)
                    _stroke_aligned(painter, line_path, stroke_align)
                # Arrowheads
                if stroke is not None:
                    center = stroke.arrow_align.value == "center_at_end"
                    draw_arrowheads_line(painter, x1, y1, x2, y2,
                                        stroke.start_arrow.value, stroke.end_arrow.value,
                                        stroke.start_arrow_scale, stroke.end_arrow_scale,
                                        stroke.width, _qcolor(stroke.color), center)

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
                painter.drawPath(_build_path(d))
            else:
                # Shorten path for arrowheads
                stroke_cmds = d
                if stroke is not None:
                    start_sb = arrow_setback(stroke.start_arrow.value, stroke.width, stroke.start_arrow_scale)
                    end_sb = arrow_setback(stroke.end_arrow.value, stroke.width, stroke.end_arrow_scale)
                    if start_sb > 0 or end_sb > 0:
                        stroke_cmds = tuple(shorten_path(list(d), start_sb, end_sb))
                wp = getattr(elem, 'width_points', ())
                if wp and stroke is not None:
                    # Fill first if present
                    if fill is not None:
                        _apply_fill(painter, fill)
                        painter.setPen(QPen(0))
                        painter.drawPath(_build_path(d))
                    # Variable-width stroke
                    stroke_opacity, _ = _apply_stroke(painter, stroke)
                    if stroke_opacity < 1.0:
                        painter.setOpacity(painter.opacity() * stroke_opacity)
                    render_variable_width_path(painter, stroke_cmds,
                                              wp, _qcolor(stroke.color),
                                              stroke.linecap)
                else:
                    # Normal fill+stroke
                    _apply_fill(painter, fill)
                    stroke_opacity, stroke_align = _apply_stroke(painter, stroke)
                    if stroke_opacity < 1.0:
                        painter.setOpacity(painter.opacity() * stroke_opacity)
                    qpath = _build_path(stroke_cmds)
                    if fill is not None:
                        painter.drawPath(_build_path(d))
                        _stroke_aligned(painter, qpath, stroke_align)
                    else:
                        if stroke_align == StrokeAlign.CENTER:
                            painter.drawPath(qpath)
                        else:
                            painter.setBrush(QBrush())
                            _stroke_aligned(painter, qpath, stroke_align)
                # Arrowheads
                if stroke is not None:
                    center = stroke.arrow_align.value == "center_at_end"
                    draw_arrowheads(painter, d,
                                   stroke.start_arrow.value, stroke.end_arrow.value,
                                   stroke.start_arrow_scale, stroke.end_arrow_scale,
                                   stroke.width, _qcolor(stroke.color), center)

        case Text() as t:
            # Multi-tspan Text renders each tspan with its effective
            # font + decoration on a shared baseline. Single no-
            # override tspan falls through to the flat path below.
            # First pass mirrors the Rust / Swift / OCaml canvas —
            # per-tspan baseline-shift / rotate / transform / dx and
            # wrapping are follow-ups.
            if len(t.tspans) != 1 or not t.tspans[0].has_no_overrides():
                _draw_segmented_text(painter, t)
                return
            x = t.x; y = t.y; content = t.content
            ff = t.font_family; fs = t.font_size
            fw = t.font_weight; fst = t.font_style
            td = t.text_decoration
            tw = t.width; th = t.height
            fill = t.fill; stroke = t.stroke
            # Baseline-shift: super/sub shrink + offset; numeric "Npt"
            # shifts up by N pt with full size; empty = identity.
            size_scale, y_shift = _parse_baseline_shift(t.baseline_shift, fs)
            effective_fs = fs * size_scale
            from PySide6.QtGui import QFont
            font = QFont(ff, int(effective_fs))
            font.setPointSizeF(effective_fs)
            if fw == "bold":
                font.setBold(True)
            if fst == "italic":
                font.setItalic(True)
            if td == "underline" or "underline" in td.split():
                font.setUnderline(True)
            if td == "line-through" or "line-through" in td.split():
                font.setStrikeOut(True)
            # text_transform / font_variant via QFont capitalization.
            _apply_text_capitalization(font, t.text_transform, t.font_variant)
            # letter_spacing = tracking + kerning (both 1/1000 em),
            # expressed in px for QFont.setLetterSpacing.
            ls_px = _letter_spacing_px(t.letter_spacing, t.kerning, effective_fs)
            if ls_px != 0.0:
                font.setLetterSpacing(QFont.SpacingType.AbsoluteSpacing, ls_px)
            painter.setFont(font)
            if fill is not None:
                painter.setPen(_qcolor(fill.color))
            elif stroke is not None:
                _apply_stroke(painter, stroke)
            else:
                painter.setPen(QColor("black"))
            # H/V scale wraps the whole text draw around the element
            # origin. Character rotation is *per-glyph* (matches SVG's
            # <text rotate> spec and Illustrator's Character Rotation
            # field): each glyph rotates around its own baseline,
            # leaving the overall layout horizontal.
            h_scale = _parse_scale_percent(t.horizontal_scale)
            v_scale = _parse_scale_percent(t.vertical_scale)
            rot_deg = _parse_rotate_deg(t.rotate)
            needs_scale = (h_scale != 1.0 or v_scale != 1.0)
            if needs_scale:
                painter.save()
                painter.translate(x, y)
                painter.scale(h_scale, v_scale)
                painter.translate(-x, -y)
            # Layout: line_height (when non-empty) overrides the
            # default line stride (which equals font_size).
            from algorithms.text_layout import (
                layout_with_paragraphs as _layout_para,
                build_paragraph_segments as _build_segments,
            )
            from tools.text_measure import make_measurer
            measure = make_measurer(ff, fw, fst, effective_fs)
            max_w = tw if (tw > 0 and th > 0) else 0.0
            line_h = _parse_pt(t.line_height)
            if line_h is not None:
                layout_fs = line_h
            else:
                # Phase 8: when Character lineHeight is empty (Auto)
                # and the first paragraph wrapper carries
                # jas:auto-leading, override the Auto default with
                # auto_leading% of the font size. V1 applies one
                # Auto override element-wide using the first
                # wrapper's value.
                auto_pct = next(
                    (ts.jas_auto_leading for ts in t.tspans
                     if ts.jas_role == "paragraph"
                     and ts.jas_auto_leading is not None),
                    None)
                layout_fs = (effective_fs * auto_pct / 100.0
                             if auto_pct is not None else effective_fs)
            # Phase 5: paragraph-aware layout. The wrapper tspans
            # (jas_role == "paragraph") inside the element provide
            # per-paragraph indent / space / alignment attrs; absent
            # wrappers fall through to a single default segment so
            # plain text without wrappers renders identically.
            psegs = _build_segments(t.tspans, content, max_w > 0)
            lay = _layout_para(content, max_w, layout_fs, psegs, measure)
            for line in lay.lines:
                s = content[line.start:line.end].rstrip('\n')
                baseline = y + line.baseline_y + y_shift
                # Per-line x shift comes from the first glyph's x —
                # the paragraph-aware layout already shifted it by
                # left_indent + first_line_indent + alignment.
                line_x_shift = lay.glyphs[line.glyph_start].x \
                    if line.glyph_start < len(lay.glyphs) else 0.0
                line_x = x + line_x_shift
                if rot_deg == 0.0:
                    # Fast path: QFont.setLetterSpacing handles inter-
                    # glyph advance for a single drawText call.
                    painter.drawText(QPointF(line_x, baseline), s)
                else:
                    # Per-glyph rotation: draw each char with its own
                    # translate/rotate/restore. letter_spacing is
                    # folded into the manual advance since drawText
                    # per char doesn't chain kern.
                    cx = line_x
                    for ch in s:
                        painter.save()
                        painter.translate(cx, baseline)
                        painter.rotate(rot_deg)
                        painter.drawText(QPointF(0, 0), ch)
                        painter.restore()
                        cx += measure(ch) + ls_px
            # Phase 6: list markers. Walk segments after the body
            # text pass, drawing each list paragraph's marker glyph
            # at x = element.x + segment.left_indent on the first-
            # line baseline. Counter values are computed once across
            # all segments so the run rule (consecutive same-style
            # num-* paragraphs count up; bullets / no-style /
            # different num style all reset) holds across the
            # element.
            if psegs:
                from algorithms.text_layout import (
                    compute_counters as _compute_counters,
                    marker_text as _marker_text,
                )
                counters = _compute_counters(psegs)
                for si, seg in enumerate(psegs):
                    style = seg.list_style or ""
                    if not style:
                        continue
                    marker = _marker_text(style, counters[si])
                    if not marker:
                        continue
                    first_line = next(
                        (l for l in lay.lines if l.start >= seg.char_start),
                        None)
                    if first_line is None:
                        continue
                    baseline = y + first_line.baseline_y + y_shift
                    marker_x = x + seg.left_indent
                    painter.drawText(QPointF(marker_x, baseline), marker)
            if needs_scale:
                painter.restore()

        case TextPath() as tp:
            d = tp.d; content = tp.content; start_offset = tp.start_offset
            ff = tp.font_family; fs = tp.font_size
            fw = tp.font_weight; fst = tp.font_style
            td = tp.text_decoration
            fill = tp.fill; stroke = tp.stroke
            from PySide6.QtGui import QFont, QFontMetricsF
            font = QFont(ff, int(fs))
            font.setPointSizeF(fs)
            if fw == "bold":
                font.setBold(True)
            if fst == "italic":
                font.setItalic(True)
            if td == "underline" or "underline" in td.split():
                font.setUnderline(True)
            if td == "line-through" or "line-through" in td.split():
                font.setStrikeOut(True)
            # text_transform / font_variant on the per-character path
            # draw: capitalization applies inside the per-char save/
            # restore block below, same as the point-text case.
            _apply_text_capitalization(font, tp.text_transform, tp.font_variant)
            ls_px = _letter_spacing_px(tp.letter_spacing, tp.kerning, fs)
            if ls_px != 0.0:
                font.setLetterSpacing(QFont.SpacingType.AbsoluteSpacing, ls_px)
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


# ---------------------------------------------------------------------------
# Artboard rendering (ARTBOARDS.md §Canvas appearance)
# ---------------------------------------------------------------------------
#
# Z-order around the existing element / selection passes:
#
#   1. Canvas background (white fill in paintEvent)
#   2. _draw_artboard_fills       — per artboard, list order
#   3. (element tree — unchanged)
#   4. _draw_fade_overlay         — dims off-artboard regions (Phase E)
#   5. _draw_artboard_borders     — 1px dark-gray border per artboard
#   6. _draw_artboard_accent      — 2px accent outline for panel-selected
#   7. _draw_artboard_labels      — "N  Name" above top-left corner
#   8. _draw_artboard_display_marks — center mark / cross hairs / safe areas
#   9. _draw_selection_overlays   — unchanged
#
# Matches jas_dioxus/src/canvas/render.rs, JasSwift CanvasSubwindow, and
# jas_ocaml canvas_subwindow — same colors and geometry across apps.

_ARTBOARD_BORDER_COLOR = QColor(48, 48, 48)
_ARTBOARD_ACCENT_COLOR = QColor(0, 120, 215, 242)  # ~0.95 alpha
_ARTBOARD_MARK_COLOR = QColor(150, 150, 150)
_ARTBOARD_LABEL_COLOR = QColor(200, 200, 200)
_ARTBOARD_FADE_COLOR = QColor(160, 160, 160, 128)  # 50% alpha


def _draw_artboard_fills(painter: QPainter, doc: Document) -> None:
    """Layer 2: per-artboard fill. Transparent artboards skip (canvas
    shows through); color fills paint the stored hex."""
    painter.save()
    painter.setPen(Qt.PenStyle.NoPen)
    for ab in doc.artboards:
        if ab.fill == "transparent" or not ab.fill:
            continue
        c = QColor(ab.fill)
        if c.isValid():
            painter.setBrush(QBrush(c))
            painter.drawRect(QRectF(ab.x, ab.y, ab.width, ab.height))
    painter.restore()


def _draw_fade_overlay(painter: QPainter, doc: Document,
                       widget_width: int, widget_height: int) -> None:
    """Layer 4: dim off-artboard regions when fade_region_outside_artboard
    is on. Fills the whole canvas with 50%-opacity neutral gray, then
    punches out each artboard via DestinationOut composition."""
    if not doc.artboard_options.fade_region_outside_artboard:
        return
    if not doc.artboards:
        return
    painter.save()
    painter.setPen(Qt.PenStyle.NoPen)
    painter.setBrush(QBrush(_ARTBOARD_FADE_COLOR))
    painter.drawRect(QRectF(0, 0, widget_width, widget_height))
    painter.setCompositionMode(
        QPainter.CompositionMode.CompositionMode_DestinationOut
    )
    painter.setBrush(QBrush(QColor(0, 0, 0, 255)))
    for ab in doc.artboards:
        painter.drawRect(QRectF(ab.x, ab.y, ab.width, ab.height))
    painter.restore()


def _draw_artboard_borders(painter: QPainter, doc: Document) -> None:
    """Layer 5: 1px dark-gray border around each artboard."""
    painter.save()
    painter.setBrush(Qt.BrushStyle.NoBrush)
    pen = QPen(_ARTBOARD_BORDER_COLOR)
    pen.setWidthF(1.0)
    painter.setPen(pen)
    for ab in doc.artboards:
        painter.drawRect(QRectF(ab.x, ab.y, ab.width, ab.height))
    painter.restore()


def _draw_artboard_accent(painter: QPainter, doc: Document,
                           panel_selected_ids) -> None:
    """Layer 6: 2px accent outline on panel-selected artboards. The
    accent sits 1.5px outside the default border so its outer edge is
    one pixel past the border's outer edge."""
    if not panel_selected_ids:
        return
    selected = set(panel_selected_ids)
    painter.save()
    painter.setBrush(Qt.BrushStyle.NoBrush)
    pen = QPen(_ARTBOARD_ACCENT_COLOR)
    pen.setWidthF(2.0)
    painter.setPen(pen)
    pad = 1.5
    for ab in doc.artboards:
        if ab.id in selected:
            painter.drawRect(QRectF(
                ab.x - pad, ab.y - pad,
                ab.width + 2 * pad, ab.height + 2 * pad,
            ))
    painter.restore()


def _draw_artboard_labels(painter: QPainter, doc: Document) -> None:
    """Layer 7: "N  Name" label above the top-left corner of each
    artboard. Baseline sits 3 document units above the artboard's
    top edge."""
    painter.save()
    painter.setPen(_ARTBOARD_LABEL_COLOR)
    from PySide6.QtGui import QFont
    f = QFont()  # default font family — Qt picks platform sans
    f.setPointSize(11)
    painter.setFont(f)
    for i, ab in enumerate(doc.artboards):
        label = f"{i + 1}  {ab.name}"
        painter.drawText(QPointF(ab.x, ab.y - 3.0), label)
    painter.restore()


def _draw_artboard_center_mark(painter: QPainter, ab) -> None:
    cx = ab.x + ab.width / 2.0
    cy = ab.y + ab.height / 2.0
    arm = 5.0
    painter.drawLine(QPointF(cx - arm, cy), QPointF(cx + arm, cy))
    painter.drawLine(QPointF(cx, cy - arm), QPointF(cx, cy + arm))


def _draw_artboard_cross_hairs(painter: QPainter, ab) -> None:
    cx = ab.x + ab.width / 2.0
    cy = ab.y + ab.height / 2.0
    painter.drawLine(QPointF(ab.x, cy), QPointF(ab.x + ab.width, cy))
    painter.drawLine(QPointF(cx, ab.y), QPointF(cx, ab.y + ab.height))


def _draw_artboard_safe_areas(painter: QPainter, ab) -> None:
    """Action-safe at 90%, title-safe at 80%, centered."""
    for frac in (0.9, 0.8):
        w = ab.width * frac
        h = ab.height * frac
        x = ab.x + (ab.width - w) / 2.0
        y = ab.y + (ab.height - h) / 2.0
        painter.drawRect(QRectF(x, y, w, h))


def _draw_artboard_display_marks(painter: QPainter, doc: Document) -> None:
    """Layer 8: per-artboard optional overlays (center mark / cross
    hairs / video safe areas)."""
    painter.save()
    painter.setBrush(Qt.BrushStyle.NoBrush)
    pen = QPen(_ARTBOARD_MARK_COLOR)
    pen.setWidthF(1.0)
    painter.setPen(pen)
    for ab in doc.artboards:
        if ab.show_center_mark:
            _draw_artboard_center_mark(painter, ab)
        if ab.show_cross_hairs:
            _draw_artboard_cross_hairs(painter, ab)
        if ab.show_video_safe_areas:
            _draw_artboard_safe_areas(painter, ab)
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
        # Artboards panel selection — mirrored from the workspace state
        # store (``panel["artboards"]["artboards_panel_selection"]``) so
        # the canvas accent pass can highlight panel-selected artboards
        # without reaching into the store during paint.
        self._artboards_panel_selection: list[str] = []
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
        elif tool == Tool.PARTIAL_SELECTION:
            return _make_white_arrow_cursor()
        elif tool == Tool.INTERIOR_SELECTION:
            return _make_interior_selection_cursor()
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

    def set_artboards_panel_selection(self, ids) -> None:
        """Push the current Artboards-panel selection (list of ids) so
        the canvas accent pass can render the 2px outline. Triggers a
        repaint if the list differs from the cached value."""
        new_ids = [s for s in (ids or []) if isinstance(s, str)]
        if new_ids != self._artboards_panel_selection:
            self._artboards_panel_selection = new_ids
            self.update()

    def paintEvent(self, event: QPaintEvent):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.fillRect(self.rect(), QColor("white"))
        doc = self._model.document
        # Z-layer 2: per-artboard fills.
        _draw_artboard_fills(painter, doc)
        # Z-layer 3: document elements.
        for layer in doc.layers:
            _draw_element(painter, layer)
        # Z-layer 4: fade overlay (off-artboard dimming).
        _draw_fade_overlay(painter, doc, self.width(), self.height())
        # Z-layer 5-8: artboard chrome.
        _draw_artboard_borders(painter, doc)
        _draw_artboard_accent(painter, doc, self._artboards_panel_selection)
        _draw_artboard_labels(painter, doc)
        _draw_artboard_display_marks(painter, doc)
        # Z-layer 9: selection overlays, then tool overlay.
        _draw_selection_overlays(painter, doc)
        self._active_tool.draw_overlay(self._tool_ctx, painter)
        painter.end()
