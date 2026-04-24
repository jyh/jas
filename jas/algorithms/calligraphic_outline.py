"""Variable-width outline of a path stroked with a Calligraphic brush.

Faithful Python port of jas_dioxus/src/algorithms/calligraphic_outline.rs
(which itself ports jas_flask/static/js/engine/geometry.mjs).

Brush parameters (BRUSHES.md §Brush types > Calligraphic):
    angle     - degrees, screen-fixed orientation of the oval major axis
    roundness - percent, 100 = circular, < 100 = elongated perp. to angle
    size      - pt, major-axis length

Per-point offset distance perpendicular to the path tangent:
    phi = theta_brush - (theta_path + pi/2)
    d(phi) = sqrt((a/2 . cos phi)^2 + (b/2 . sin phi)^2)
where a = brush.size, b = brush.size * brush.roundness / 100.

Phase 1 limits: only the `fixed` variation mode is honoured;
multi-subpath paths render the first subpath only.
"""

from __future__ import annotations

import math
from dataclasses import dataclass


@dataclass(frozen=True)
class CalligraphicBrush:
    angle: float       # degrees, screen-fixed
    roundness: float   # 0..100
    size: float        # pt


_SAMPLE_INTERVAL_PT = 1.0
_CUBIC_SAMPLES = 32
_QUADRATIC_SAMPLES = 24


def calligraphic_outline(commands, brush: CalligraphicBrush):
    """Compute the variable-width outline of `commands` stroked with a
    Calligraphic brush. Returns the closed polygon's points as a list
    of (x, y) tuples (forward along the left-offset, then back along
    the right-offset). Empty list for degenerate input.

    `commands` is a list of PathCommand instances (MoveTo, LineTo,
    CurveTo, QuadTo, ClosePath, …) from `geometry.element`.
    """
    samples = _sample_stroke_path(commands)
    if len(samples) < 2:
        return []

    a = brush.size / 2.0
    b = (brush.size * (brush.roundness / 100.0)) / 2.0
    theta_brush = math.radians(brush.angle)

    left = []
    right = []
    for sx, sy, tangent in samples:
        phi = theta_brush - (tangent + math.pi / 2.0)
        d = math.sqrt((a * math.cos(phi)) ** 2 + (b * math.sin(phi)) ** 2)
        nx = -math.sin(tangent)
        ny = math.cos(tangent)
        left.append((sx + nx * d, sy + ny * d))
        right.append((sx - nx * d, sy - ny * d))

    out = list(left)
    out.extend(reversed(right))
    return out


def _sample_stroke_path(commands):
    """Walk the command list emitting (x, y, tangent) samples.
    Returns samples for the first subpath only; subsequent MoveTo or
    a ClosePath terminates sampling."""
    out = []
    cx = cy = 0.0
    sx = sy = 0.0
    started = False

    # Local imports to avoid an import cycle at module load.
    from geometry.element import (
        MoveTo, LineTo, CurveTo, QuadTo, ClosePath,
    )

    for cmd in commands:
        if isinstance(cmd, MoveTo):
            if started:
                return out
            cx = cmd.x; cy = cmd.y
            sx = cx; sy = cy
        elif isinstance(cmd, LineTo):
            _sample_line(out, cx, cy, cmd.x, cmd.y)
            cx = cmd.x; cy = cmd.y
            started = True
        elif isinstance(cmd, CurveTo):
            _sample_cubic(out, cx, cy,
                          cmd.x1, cmd.y1, cmd.x2, cmd.y2, cmd.x, cmd.y)
            cx = cmd.x; cy = cmd.y
            started = True
        elif isinstance(cmd, QuadTo):
            _sample_quadratic(out, cx, cy, cmd.x1, cmd.y1, cmd.x, cmd.y)
            cx = cmd.x; cy = cmd.y
            started = True
        elif isinstance(cmd, ClosePath):
            if cx != sx or cy != sy:
                _sample_line(out, cx, cy, sx, sy)
            return out
        else:
            # Smooth/Arc variants unsupported in Phase 1; bail.
            return out
    return out


def _sample_line(out, x0, y0, x1, y1):
    length = math.hypot(x1 - x0, y1 - y0)
    if length == 0.0:
        return
    tangent = math.atan2(y1 - y0, x1 - x0)
    n = max(1, math.ceil(length / _SAMPLE_INTERVAL_PT))
    start_i = 0 if not out else 1
    for i in range(start_i, n + 1):
        t = i / n
        out.append((x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, tangent))


def _sample_cubic(out, x0, y0, x1, y1, x2, y2, x3, y3):
    start_i = 0 if not out else 1
    for i in range(start_i, _CUBIC_SAMPLES + 1):
        t = i / _CUBIC_SAMPLES
        u = 1.0 - t
        x = u*u*u * x0 + 3*u*u*t * x1 + 3*u*t*t * x2 + t*t*t * x3
        y = u*u*u * y0 + 3*u*u*t * y1 + 3*u*t*t * y2 + t*t*t * y3
        dx = 3*u*u * (x1 - x0) + 6*u*t * (x2 - x1) + 3*t*t * (x3 - x2)
        dy = 3*u*u * (y1 - y0) + 6*u*t * (y2 - y1) + 3*t*t * (y3 - y2)
        if dx == 0.0 and dy == 0.0:
            tangent = math.atan2(y3 - y0, x3 - x0)
        else:
            tangent = math.atan2(dy, dx)
        out.append((x, y, tangent))


def _sample_quadratic(out, x0, y0, x1, y1, x2, y2):
    start_i = 0 if not out else 1
    for i in range(start_i, _QUADRATIC_SAMPLES + 1):
        t = i / _QUADRATIC_SAMPLES
        u = 1.0 - t
        x = u*u * x0 + 2*u*t * x1 + t*t * x2
        y = u*u * y0 + 2*u*t * y1 + t*t * y2
        dx = 2*u * (x1 - x0) + 2*t * (x2 - x1)
        dy = 2*u * (y1 - y0) + 2*t * (y2 - y1)
        if dx == 0.0 and dy == 0.0:
            tangent = math.atan2(y2 - y0, x2 - x0)
        else:
            tangent = math.atan2(dy, dx)
        out.append((x, y, tangent))
