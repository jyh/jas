"""Art brush: one vector artwork stretched along the full stroke path.

Port of jas_dioxus/src/algorithms/art_along_path.rs (BRUSHES.md §Brush
types > Art). The artwork is a set of closed polygons in artwork
coordinates (x in [0, width], y in [0, height]); it is warped onto the
stroke path so the artwork x-axis maps to arc-length (0 -> start, width ->
end) and its y-axis maps to the perpendicular offset, centred on the path
and scaled to the ribbon height = (scale / 100) * stroke_weight.
``flip_along`` reverses the arc-length mapping; ``flip_across`` mirrors the
offset. Phase 1: polygon artwork only, first subpath only, proportional
scale (the artwork stretches to the full path length).
"""

import math
from dataclasses import dataclass


@dataclass
class ArtBrush:
    artwork_width: float
    artwork_height: float
    artwork: list      # list of polygons, each a list of (x, y)
    scale: float       # percent
    flip_across: bool
    flip_along: bool
    stroke_weight: float  # pt


def art_along_path(commands, brush: "ArtBrush"):
    """Warp ``brush.artwork`` along ``commands``. Returns one warped
    polygon (list of (x, y)) per artwork polygon; [] for degenerate input."""
    if brush.artwork_width <= 0 or brush.artwork_height <= 0:
        return []
    pts = _flatten(commands)
    if len(pts) < 2:
        return []
    cum = [0.0] * len(pts)
    for i in range(1, len(pts)):
        dx = pts[i][0] - pts[i - 1][0]
        dy = pts[i][1] - pts[i - 1][1]
        cum[i] = cum[i - 1] + math.hypot(dx, dy)
    total = cum[-1]
    if total <= 0:
        return []
    h_out = (brush.scale / 100.0) * brush.stroke_weight
    out = []
    for poly in brush.artwork:
        warped = []
        for ax, ay in poly:
            t = min(max(ax / brush.artwork_width, 0.0), 1.0)
            if brush.flip_along:
                t = 1.0 - t
            px, py, tan = _point_at_arclength(pts, cum, total, t * total)
            off = (ay - brush.artwork_height / 2.0) / brush.artwork_height * h_out
            if brush.flip_across:
                off = -off
            nx = -math.sin(tan)
            ny = math.cos(tan)
            warped.append((px + nx * off, py + ny * off))
        out.append(warped)
    return out


def _point_at_arclength(pts, cum, total, s):
    """Point (x, y) and tangent (radians) at arc-length ``s``."""
    s = min(max(s, 0.0), total)
    lo, hi = 1, len(pts) - 1
    while lo < hi:
        mid = (lo + hi) // 2
        if cum[mid] < s:
            lo = mid + 1
        else:
            hi = mid
    i = lo
    seg = cum[i] - cum[i - 1]
    f = (s - cum[i - 1]) / seg if seg > 0 else 0.0
    x0, y0 = pts[i - 1]
    x1, y1 = pts[i]
    x = x0 + (x1 - x0) * f
    y = y0 + (y1 - y0) * f
    tan = math.atan2(y1 - y0, x1 - x0)
    return x, y, tan


def _flatten(commands):
    """Flatten the first subpath of ``commands`` into a polyline."""
    from geometry.element import MoveTo, LineTo, CurveTo, QuadTo, ClosePath

    out = []
    cx = cy = sx = sy = 0.0
    started = False

    def push(x, y):
        if out and out[-1][0] == x and out[-1][1] == y:
            return
        out.append((x, y))

    for cmd in commands:
        if isinstance(cmd, MoveTo):
            if started:
                return out
            cx, cy = cmd.x, cmd.y
            sx, sy = cx, cy
            push(cx, cy)
        elif isinstance(cmd, LineTo):
            push(cmd.x, cmd.y)
            cx, cy = cmd.x, cmd.y
            started = True
        elif isinstance(cmd, CurveTo):
            for k in range(1, 17):
                t = k / 16.0
                u = 1.0 - t
                bx = u * u * u * cx + 3 * u * u * t * cmd.x1 + 3 * u * t * t * cmd.x2 + t * t * t * cmd.x
                by = u * u * u * cy + 3 * u * u * t * cmd.y1 + 3 * u * t * t * cmd.y2 + t * t * t * cmd.y
                push(bx, by)
            cx, cy = cmd.x, cmd.y
            started = True
        elif isinstance(cmd, QuadTo):
            for k in range(1, 13):
                t = k / 12.0
                u = 1.0 - t
                bx = u * u * cx + 2 * u * t * cmd.x1 + t * t * cmd.x
                by = u * u * cy + 2 * u * t * cmd.y1 + t * t * cmd.y
                push(bx, by)
            cx, cy = cmd.x, cmd.y
            started = True
        elif isinstance(cmd, ClosePath):
            if cx != sx or cy != sy:
                push(sx, sy)
            return out
        else:
            return out
    return out
