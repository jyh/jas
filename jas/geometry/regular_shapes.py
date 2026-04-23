"""Shape-geometry helpers for regular polygons and stars.

Python analogue of jas_dioxus/src/geometry/regular_shapes.rs,
JasSwift/Sources/Geometry/RegularShapes.swift, and
jas_ocaml/lib/geometry/regular_shapes.ml.

L2 primitives per NATIVE_BOUNDARY.md §5 — shape geometry is shared
across vector-illustration apps.
"""

from __future__ import annotations

import math

# Ratio of inner radius to outer radius for the default star.
STAR_INNER_RATIO: float = 0.4


def regular_polygon_points(
    x1: float, y1: float, x2: float, y2: float, n: int,
) -> list[tuple[float, float]]:
    """Compute vertices of a regular N-gon whose first edge runs from
    (x1, y1) to (x2, y2). Returns ``n`` (x, y) pairs. For degenerate
    zero-length edges returns ``n`` copies of the start point.
    """
    ex = x2 - x1
    ey = y2 - y1
    s = math.hypot(ex, ey)
    if s == 0.0:
        return [(x1, y1)] * n
    mx = (x1 + x2) / 2.0
    my = (y1 + y2) / 2.0
    px = -ey / s
    py = ex / s
    d = s / (2.0 * math.tan(math.pi / n))
    cx = mx + d * px
    cy = my + d * py
    r = s / (2.0 * math.sin(math.pi / n))
    theta0 = math.atan2(y1 - cy, x1 - cx)
    return [
        (cx + r * math.cos(theta0 + 2.0 * math.pi * k / n),
         cy + r * math.sin(theta0 + 2.0 * math.pi * k / n))
        for k in range(n)
    ]


def star_points(
    sx: float, sy: float, ex: float, ey: float, points: int,
) -> list[tuple[float, float]]:
    """Compute vertices of a star inscribed in the axis-aligned
    bounding box with corners (sx, sy) and (ex, ey). ``points`` is
    the number of outer vertices; the returned list alternates
    outer/inner for ``2 * points`` total. The first outer point
    sits at top-center."""
    cx = (sx + ex) / 2.0
    cy = (sy + ey) / 2.0
    rx_outer = abs(ex - sx) / 2.0
    ry_outer = abs(ey - sy) / 2.0
    rx_inner = rx_outer * STAR_INNER_RATIO
    ry_inner = ry_outer * STAR_INNER_RATIO
    n = points * 2
    theta0 = -math.pi / 2.0
    out: list[tuple[float, float]] = []
    for k in range(n):
        angle = theta0 + math.pi * k / points
        rx, ry = (rx_outer, ry_outer) if k % 2 == 0 else (rx_inner, ry_inner)
        out.append((cx + rx * math.cos(angle), cy + ry * math.sin(angle)))
    return out
