"""Arrowhead shape definitions and rendering.

Each shape is defined as a normalized path in a unit coordinate system:
- Pointing right (+x direction)
- Tip at origin (0, 0) for tip-at-end alignment
- Unit size (1.0 = stroke width at 100% scale)

At render time the shape is transformed: translate to endpoint,
rotate to match path tangent, scale by stroke_width * scale%.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from enum import Enum

from PySide6.QtCore import QPointF
from PySide6.QtGui import QBrush, QColor, QPainter, QPainterPath, QPen

from geometry.element import (
    MoveTo, LineTo, CurveTo, ClosePath, PathCommand,
)


class _ShapeStyle(Enum):
    FILLED = "filled"
    OUTLINE = "outline"


@dataclass(frozen=True)
class _ArrowShape:
    cmds: list
    style: _ShapeStyle
    back: float


# -- Shape definitions (unit coords, tip at (0,0), pointing right) --

_SIMPLE_ARROW_CMDS = [
    MoveTo(0, 0), LineTo(-4, -2), LineTo(-4, 2), ClosePath(),
]
_OPEN_ARROW_CMDS = [
    MoveTo(-4, -2), LineTo(0, 0), LineTo(-4, 2),
]
_CLOSED_ARROW_CMDS = [
    MoveTo(0, 0), LineTo(-4, -2), LineTo(-4, 2), ClosePath(),
    MoveTo(-4.5, -2), LineTo(-4.5, 2),
]
_STEALTH_ARROW_CMDS = [
    MoveTo(0, 0), LineTo(-4.5, -1.8), LineTo(-3, 0),
    LineTo(-4.5, 1.8), ClosePath(),
]
_BARBED_ARROW_CMDS = [
    MoveTo(0, 0),
    CurveTo(x1=-2, y1=-0.5, x2=-3.5, y2=-1.5, x=-4.5, y=-2),
    LineTo(-3, 0), LineTo(-4.5, 2),
    CurveTo(x1=-3.5, y1=1.5, x2=-2, y2=0.5, x=0, y=0),
    ClosePath(),
]
_HALF_ARROW_UPPER_CMDS = [
    MoveTo(0, 0), LineTo(-4, -2), LineTo(-4, 0), ClosePath(),
]
_HALF_ARROW_LOWER_CMDS = [
    MoveTo(0, 0), LineTo(-4, 0), LineTo(-4, 2), ClosePath(),
]

_CIRCLE_R = 2.0
_KK = 0.5522847498  # bezier circle constant
_CIRCLE_CMDS = [
    MoveTo(0, 0),
    CurveTo(x1=0, y1=-_CIRCLE_R * _KK,
            x2=-_CIRCLE_R + _CIRCLE_R * _KK, y2=-_CIRCLE_R,
            x=-_CIRCLE_R, y=-_CIRCLE_R),
    CurveTo(x1=-_CIRCLE_R - _CIRCLE_R * _KK, y1=-_CIRCLE_R,
            x2=-2 * _CIRCLE_R, y2=-_CIRCLE_R * _KK,
            x=-2 * _CIRCLE_R, y=0),
    CurveTo(x1=-2 * _CIRCLE_R, y1=_CIRCLE_R * _KK,
            x2=-_CIRCLE_R - _CIRCLE_R * _KK, y2=_CIRCLE_R,
            x=-_CIRCLE_R, y=_CIRCLE_R),
    CurveTo(x1=-_CIRCLE_R + _CIRCLE_R * _KK, y1=_CIRCLE_R,
            x2=0, y2=_CIRCLE_R * _KK,
            x=0, y=0),
    ClosePath(),
]
_SQUARE_CMDS = [
    MoveTo(0, -2), LineTo(-4, -2), LineTo(-4, 2), LineTo(0, 2), ClosePath(),
]
_DIAMOND_CMDS = [
    MoveTo(0, 0), LineTo(-2.5, -2), LineTo(-5, 0), LineTo(-2.5, 2), ClosePath(),
]
_SLASH_CMDS = [
    MoveTo(0.5, -2), LineTo(-0.5, 2),
]


def _get_shape(name: str) -> _ArrowShape | None:
    """Look up an arrowhead shape by name."""
    shapes = {
        "simple_arrow":     _ArrowShape(_SIMPLE_ARROW_CMDS, _ShapeStyle.FILLED, 4),
        "open_arrow":       _ArrowShape(_OPEN_ARROW_CMDS, _ShapeStyle.OUTLINE, 4),
        "closed_arrow":     _ArrowShape(_CLOSED_ARROW_CMDS, _ShapeStyle.FILLED, 4),
        "stealth_arrow":    _ArrowShape(_STEALTH_ARROW_CMDS, _ShapeStyle.FILLED, 3),
        "barbed_arrow":     _ArrowShape(_BARBED_ARROW_CMDS, _ShapeStyle.FILLED, 3),
        "half_arrow_upper": _ArrowShape(_HALF_ARROW_UPPER_CMDS, _ShapeStyle.FILLED, 4),
        "half_arrow_lower": _ArrowShape(_HALF_ARROW_LOWER_CMDS, _ShapeStyle.FILLED, 4),
        "circle":           _ArrowShape(_CIRCLE_CMDS, _ShapeStyle.FILLED, 2 * _CIRCLE_R),
        "open_circle":      _ArrowShape(_CIRCLE_CMDS, _ShapeStyle.OUTLINE, 2 * _CIRCLE_R),
        "square":           _ArrowShape(_SQUARE_CMDS, _ShapeStyle.FILLED, 4),
        "open_square":      _ArrowShape(_SQUARE_CMDS, _ShapeStyle.OUTLINE, 4),
        "diamond":          _ArrowShape(_DIAMOND_CMDS, _ShapeStyle.FILLED, 2.5),
        "open_diamond":     _ArrowShape(_DIAMOND_CMDS, _ShapeStyle.OUTLINE, 2.5),
        "slash":            _ArrowShape(_SLASH_CMDS, _ShapeStyle.OUTLINE, 0.5),
    }
    return shapes.get(name)


def arrow_setback(name: str, stroke_width: float, scale_pct: float) -> float:
    """Get the path shortening distance for an arrowhead (in canvas pixels)."""
    shape = _get_shape(name)
    if shape is None:
        return 0.0
    return shape.back * stroke_width * scale_pct / 100.0


def _collect_points(cmds) -> list[tuple[float, float]]:
    """Collect significant points from path commands for tangent computation."""
    pts: list[tuple[float, float]] = []
    for cmd in cmds:
        if isinstance(cmd, (MoveTo, LineTo)):
            pts.append((cmd.x, cmd.y))
        elif isinstance(cmd, CurveTo):
            pts.append((cmd.x1, cmd.y1))
            pts.append((cmd.x2, cmd.y2))
            pts.append((cmd.x, cmd.y))
        elif hasattr(cmd, 'x') and hasattr(cmd, 'y'):
            pts.append((cmd.x, cmd.y))
    return pts


def start_tangent(cmds) -> tuple[float, float, float]:
    """Compute tangent angle at the start of a path (pointing away from path interior).

    Returns (x, y, angle).
    """
    pts = _collect_points(cmds)
    if not pts:
        return (0, 0, 0)
    sx, sy = pts[0]
    threshold = 0.1
    for nx, ny in pts[1:]:
        dx = sx - nx
        dy = sy - ny
        if dx * dx + dy * dy > threshold * threshold:
            return (sx, sy, math.atan2(dy, dx))
    return (sx, sy, math.pi)


def end_tangent(cmds) -> tuple[float, float, float]:
    """Compute tangent angle at the end of a path (pointing along path direction).

    Returns (x, y, angle).
    """
    pts = _collect_points(cmds)
    if not pts:
        return (0, 0, 0)
    ex, ey = pts[-1]
    threshold = 0.1
    for px, py in reversed(pts[:-1]):
        dx = ex - px
        dy = ey - py
        if dx * dx + dy * dy > threshold * threshold:
            return (ex, ey, math.atan2(dy, dx))
    return (ex, ey, 0)


def shorten_path(cmds: list, start_setback: float,
                 end_setback: float) -> list:
    """Shorten a path by moving start/end points inward along their tangent."""
    if not cmds:
        return cmds
    result = list(cmds)

    if start_setback > 0:
        sx, sy, angle = start_tangent(cmds)
        dx = -math.cos(angle) * start_setback
        dy = -math.sin(angle) * start_setback
        for i, cmd in enumerate(result):
            if isinstance(cmd, MoveTo) and abs(cmd.x - sx) < 1e-6 and abs(cmd.y - sy) < 1e-6:
                result[i] = MoveTo(cmd.x + dx, cmd.y + dy)
                break

    if end_setback > 0:
        ex, ey, angle = end_tangent(cmds)
        dx = -math.cos(angle) * end_setback
        dy = -math.sin(angle) * end_setback
        for i in range(len(result) - 1, -1, -1):
            cmd = result[i]
            if isinstance(cmd, LineTo) and abs(cmd.x - ex) < 1e-6 and abs(cmd.y - ey) < 1e-6:
                result[i] = LineTo(cmd.x + dx, cmd.y + dy)
                return result
            elif isinstance(cmd, CurveTo) and abs(cmd.x - ex) < 1e-6 and abs(cmd.y - ey) < 1e-6:
                result[i] = CurveTo(x1=cmd.x1, y1=cmd.y1,
                                    x2=cmd.x2, y2=cmd.y2,
                                    x=cmd.x + dx, y=cmd.y + dy)
                return result
            elif isinstance(cmd, MoveTo) and abs(cmd.x - ex) < 1e-6 and abs(cmd.y - ey) < 1e-6:
                result[i] = MoveTo(cmd.x + dx, cmd.y + dy)
                return result

    return result


def _build_arrow_path(cmds: list) -> QPainterPath:
    """Build a QPainterPath from arrow shape commands."""
    path = QPainterPath()
    for cmd in cmds:
        if isinstance(cmd, MoveTo):
            path.moveTo(cmd.x, cmd.y)
        elif isinstance(cmd, LineTo):
            path.lineTo(cmd.x, cmd.y)
        elif isinstance(cmd, CurveTo):
            path.cubicTo(cmd.x1, cmd.y1, cmd.x2, cmd.y2, cmd.x, cmd.y)
        elif isinstance(cmd, ClosePath):
            path.closeSubpath()
    return path


def _draw_one(painter: QPainter, shape: _ArrowShape,
              x: float, y: float, angle: float, scale: float,
              stroke_color: QColor, center_at_end: bool) -> None:
    """Draw a single arrowhead shape at the given position and angle."""
    if scale <= 0:
        return
    painter.save()
    painter.translate(x, y)
    painter.rotate(math.degrees(angle))
    if center_at_end:
        painter.translate(-2.0 * scale, 0)
    painter.scale(scale, scale)

    path = _build_arrow_path(shape.cmds)

    if shape.style == _ShapeStyle.FILLED:
        painter.setPen(QPen(0))
        painter.setBrush(QBrush(stroke_color))
        painter.drawPath(path)
    else:
        # Outline style: white fill + colored stroke
        painter.setBrush(QBrush(QColor(255, 255, 255)))
        painter.drawPath(path)
        pen = QPen(stroke_color, 1.0 / scale)
        painter.setPen(pen)
        painter.setBrush(QBrush())
        painter.drawPath(path)

    painter.restore()


def draw_arrowheads(painter: QPainter, cmds, start_name: str,
                    end_name: str, start_scale: float, end_scale: float,
                    stroke_width: float, stroke_color: QColor,
                    center_at_end: bool) -> None:
    """Draw arrowheads for a path element."""
    start_shape = _get_shape(start_name)
    if start_shape is not None:
        x, y, angle = start_tangent(cmds)
        s = stroke_width * start_scale / 100.0
        _draw_one(painter, start_shape, x, y, angle, s,
                  stroke_color, center_at_end)

    end_shape = _get_shape(end_name)
    if end_shape is not None:
        x, y, angle = end_tangent(cmds)
        s = stroke_width * end_scale / 100.0
        _draw_one(painter, end_shape, x, y, angle, s,
                  stroke_color, center_at_end)


def draw_arrowheads_line(painter: QPainter,
                         x1: float, y1: float, x2: float, y2: float,
                         start_name: str, end_name: str,
                         start_scale: float, end_scale: float,
                         stroke_width: float, stroke_color: QColor,
                         center_at_end: bool) -> None:
    """Draw arrowheads for a line element."""
    dx = x2 - x1
    dy = y2 - y1
    end_angle = math.atan2(dy, dx)
    start_angle = math.atan2(y1 - y2, x1 - x2)

    start_shape = _get_shape(start_name)
    if start_shape is not None:
        s = stroke_width * start_scale / 100.0
        _draw_one(painter, start_shape, x1, y1, start_angle, s,
                  stroke_color, center_at_end)

    end_shape = _get_shape(end_name)
    if end_shape is not None:
        s = stroke_width * end_scale / 100.0
        _draw_one(painter, end_shape, x2, y2, end_angle, s,
                  stroke_color, center_at_end)
