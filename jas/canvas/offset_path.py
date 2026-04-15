"""Variable-width stroke rendering via offset paths.

Flattens a path to a polyline, computes normals at each sample point,
evaluates the width profile, and builds a filled polygon representing
the stroke outline.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from PySide6.QtCore import QPointF, Qt
from PySide6.QtGui import QBrush, QColor, QPainter, QPainterPath, QPen

from geometry.element import (
    LineCap, StrokeWidthPoint,
    flatten_path_commands,
)


@dataclass
class _PathSample:
    x: float
    y: float
    nx: float  # unit normal x
    ny: float  # unit normal y
    t: float   # fractional offset along path [0, 1]


def _arc_lengths(pts: list[tuple[float, float]]) -> list[float]:
    """Compute cumulative arc lengths for a polyline."""
    lengths = [0.0]
    for i in range(1, len(pts)):
        dx = pts[i][0] - pts[i - 1][0]
        dy = pts[i][1] - pts[i - 1][1]
        lengths.append(lengths[-1] + math.sqrt(dx * dx + dy * dy))
    return lengths


def _sample_path_with_normals(cmds) -> list[_PathSample]:
    """Sample a path with normals at each point."""
    pts = flatten_path_commands(cmds)
    if len(pts) < 2:
        return []
    lengths = _arc_lengths(pts)
    total = lengths[-1]
    if total == 0:
        return []

    samples: list[_PathSample] = []
    for i in range(len(pts)):
        t = lengths[i] / total
        if i == 0:
            dx = pts[1][0] - pts[0][0]
            dy = pts[1][1] - pts[0][1]
        elif i == len(pts) - 1:
            dx = pts[i][0] - pts[i - 1][0]
            dy = pts[i][1] - pts[i - 1][1]
        else:
            dx = pts[i + 1][0] - pts[i - 1][0]
            dy = pts[i + 1][1] - pts[i - 1][1]
        length = math.sqrt(dx * dx + dy * dy)
        if length > 1e-10:
            nx, ny = -dy / length, dx / length
        else:
            nx, ny = 0.0, 1.0
        samples.append(_PathSample(x=pts[i][0], y=pts[i][1],
                                   nx=nx, ny=ny, t=t))
    return samples


def _sample_line_with_normals(x1: float, y1: float,
                               x2: float, y2: float) -> list[_PathSample]:
    """Sample a line segment with normals."""
    dx = x2 - x1
    dy = y2 - y1
    length = math.sqrt(dx * dx + dy * dy)
    if length < 1e-10:
        return []
    nx = -dy / length
    ny = dx / length
    num_samples = 32
    samples: list[_PathSample] = []
    for i in range(num_samples + 1):
        t = i / num_samples
        samples.append(_PathSample(
            x=x1 + dx * t, y=y1 + dy * t,
            nx=nx, ny=ny, t=t))
    return samples


def _smoothstep(t: float) -> float:
    """Smoothstep interpolation."""
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def _evaluate_width_at(points: tuple[StrokeWidthPoint, ...],
                        t: float) -> tuple[float, float]:
    """Evaluate the width profile at parameter t."""
    if not points:
        return (0.0, 0.0)
    if len(points) == 1:
        return (points[0].width_left, points[0].width_right)
    if t <= points[0].t:
        return (points[0].width_left, points[0].width_right)
    if t >= points[-1].t:
        return (points[-1].width_left, points[-1].width_right)
    for i in range(1, len(points)):
        if t <= points[i].t:
            dt = points[i].t - points[i - 1].t
            frac = (t - points[i - 1].t) / dt if dt > 0 else 0.0
            s = _smoothstep(frac)
            wl = points[i - 1].width_left + s * (points[i].width_left - points[i - 1].width_left)
            wr = points[i - 1].width_right + s * (points[i].width_right - points[i - 1].width_right)
            return (wl, wr)
    return (points[-1].width_left, points[-1].width_right)


def _render_from_samples(painter: QPainter, samples: list[_PathSample],
                          width_points: tuple[StrokeWidthPoint, ...],
                          stroke_color: QColor,
                          linecap: LineCap) -> None:
    """Build and fill the offset polygon from samples."""
    if len(samples) < 2:
        return

    left: list[tuple[float, float]] = []
    right: list[tuple[float, float]] = []

    for s in samples:
        wl, wr = _evaluate_width_at(width_points, s.t)
        left.append((s.x + s.nx * wl, s.y + s.ny * wl))
        right.append((s.x - s.nx * wr, s.y - s.ny * wr))

    wl0, wr0 = _evaluate_width_at(width_points, 0)
    wln, wrn = _evaluate_width_at(width_points, 1)

    path = QPainterPath()

    # Start cap
    s0 = samples[0]
    if linecap == LineCap.ROUND and wl0 + wr0 > 0.1:
        r = (wl0 + wr0) / 2.0
        tangent_angle = math.atan2(s0.ny, -s0.nx)
        # Move to right edge, arc to left edge
        path.moveTo(right[0][0], right[0][1])
        # Approximate semicircle with cubicTo
        start_deg = math.degrees(tangent_angle + math.pi / 2)
        sweep_deg = -180.0
        # Use arcTo for the start cap
        rect_x = s0.x - r
        rect_y = s0.y - r
        path.arcTo(rect_x, rect_y, 2 * r, 2 * r, start_deg, sweep_deg)
    elif linecap == LineCap.SQUARE and wl0 + wr0 > 0.1:
        ext = (wl0 + wr0) / 2.0
        bx = -s0.ny
        by = s0.nx
        path.moveTo(right[0][0] + bx * ext, right[0][1] + by * ext)
        path.lineTo(left[0][0] + bx * ext, left[0][1] + by * ext)
    else:
        path.moveTo(left[0][0], left[0][1])

    # Left edge forward
    for x, y in left:
        path.lineTo(x, y)

    # End cap
    sn = samples[-1]
    if linecap == LineCap.ROUND and wln + wrn > 0.1:
        r = (wln + wrn) / 2.0
        tangent_angle = math.atan2(sn.ny, -sn.nx)
        start_deg = math.degrees(tangent_angle - math.pi / 2)
        sweep_deg = -180.0
        rect_x = sn.x - r
        rect_y = sn.y - r
        path.arcTo(rect_x, rect_y, 2 * r, 2 * r, start_deg, sweep_deg)
    elif linecap == LineCap.SQUARE and wln + wrn > 0.1:
        ext = (wln + wrn) / 2.0
        fx = sn.ny
        fy = -sn.nx
        ll = left[-1]
        rl = right[-1]
        path.lineTo(ll[0] + fx * ext, ll[1] + fy * ext)
        path.lineTo(rl[0] + fx * ext, rl[1] + fy * ext)

    # Right edge reversed
    for x, y in reversed(right):
        path.lineTo(x, y)

    path.closeSubpath()

    painter.save()
    painter.setPen(QPen(0))
    painter.setBrush(QBrush(stroke_color))
    painter.drawPath(path)
    painter.restore()


def render_variable_width_path(painter: QPainter, cmds,
                                width_points: tuple[StrokeWidthPoint, ...],
                                stroke_color: QColor,
                                linecap: LineCap) -> None:
    """Render a variable-width stroke for a path element."""
    samples = _sample_path_with_normals(cmds)
    _render_from_samples(painter, samples, width_points,
                         stroke_color, linecap)


def render_variable_width_line(painter: QPainter,
                                x1: float, y1: float,
                                x2: float, y2: float,
                                width_points: tuple[StrokeWidthPoint, ...],
                                stroke_color: QColor,
                                linecap: LineCap) -> None:
    """Render a variable-width stroke for a line element."""
    samples = _sample_line_with_normals(x1, y1, x2, y2)
    _render_from_samples(painter, samples, width_points,
                         stroke_color, linecap)
