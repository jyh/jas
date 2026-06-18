"""Polyline-to-Bezier simplification with corner detection.

Wraps :func:`algorithms.fit_curve.fit_curve` (Schneider 1990) so it can
be applied to a closed or open polyline that mixes straight runs and
smooth arcs. The wrapper:

1. Detects "corners" -- vertices where the direction changes by more
   than ``corner_angle_threshold`` (default 30 degrees). Boolean
   operation outputs preserve original sharp corners but flatten arcs
   into many short segments; fitting one curve across a corner would
   round it off, so corners must split the polyline into per-segment
   runs before fitting.
2. For each run between corners, calls fit_curve with the supplied
   error tolerance. A run of two points emits a single LineTo; longer
   runs emit one or more CurveTo segments.
3. Re-stitches the run outputs into a single PathCommand sequence,
   closing with ClosePath when the input was a closed ring.

Mirrors ``jas_dioxus/src/algorithms/simplify.rs`` for cross-language
behavioral equivalence (the prime directive).
"""

from __future__ import annotations

import math

from algorithms.fit_curve import fit_curve
from geometry.element import ClosePath, CurveTo, LineTo, MoveTo, PathCommand

# Default corner angle threshold: 30 degrees (in radians).
DEFAULT_CORNER_ANGLE: float = math.pi / 6.0


def simplify_polyline(
    points: list[tuple[float, float]],
    precision: float,
    closed: bool,
) -> list[PathCommand]:
    """Simplify a polyline to a Bezier-rich PathCommand sequence.

    ``points`` is the polyline (no duplicate closing vertex).
    ``precision`` is the Schneider max-error tolerance in document units
    (typically points). ``closed`` controls whether the wraparound seam
    can become a corner and whether the output ends with ``ClosePath``.

    Returns a sequence starting with ``MoveTo`` and ending with (for
    closed inputs) ``ClosePath``. Returns an empty list when fewer than
    2 points are supplied.
    """
    return simplify_polyline_with_angle(
        points, precision, closed, DEFAULT_CORNER_ANGLE)


def simplify_polyline_with_angle(
    points: list[tuple[float, float]],
    precision: float,
    closed: bool,
    corner_angle_threshold: float,
) -> list[PathCommand]:
    """:func:`simplify_polyline` with an explicit corner-angle threshold
    (in radians). Useful for tests and future tuning surfaces.
    """
    if len(points) < 2:
        return []
    if len(points) == 2:
        out: list[PathCommand] = [
            MoveTo(x=points[0][0], y=points[0][1]),
            LineTo(x=points[1][0], y=points[1][1]),
        ]
        if closed:
            out.append(ClosePath())
        return out

    corners = detect_corners(points, corner_angle_threshold, closed)
    runs = split_into_runs(points, corners, closed)

    out = [MoveTo(x=runs[0][0][0], y=runs[0][0][1])]
    for run in runs:
        if len(run) == 2:
            # Pure line segment -- no fitting.
            out.append(LineTo(x=run[1][0], y=run[1][1]))
        else:
            # Bezier fit on the run.
            segs = fit_curve(run, precision)
            if not segs:
                # Defensive: fit failed (too few points after
                # filtering); fall back to a straight line to the last
                # vertex.
                out.append(LineTo(x=run[-1][0], y=run[-1][1]))
                continue
            for seg in segs:
                _x0, _y0, c1x, c1y, c2x, c2y, x, y = seg
                out.append(CurveTo(x1=c1x, y1=c1y, x2=c2x, y2=c2y, x=x, y=y))
    if closed:
        out.append(ClosePath())
    return out


def detect_corners(
    points: list[tuple[float, float]],
    angle_threshold: float,
    closed: bool,
) -> list[int]:
    """Return indices of corner vertices. A corner is a vertex where the
    direction change between the incoming and outgoing edges exceeds
    ``angle_threshold`` radians. For ``closed`` inputs, the wraparound
    seam (vertex 0) is treated like any other interior vertex; for open
    inputs, endpoints (index 0 and n-1) are never corners.
    """
    n = len(points)
    corners: list[int] = []
    cos_threshold = math.cos(angle_threshold)
    start = 0 if closed else 1
    end = n if closed else n - 1
    for i in range(start, end):
        prev_idx = (i + n - 1) % n
        next_idx = (i + 1) % n
        v1 = _norm(_sub(points[i], points[prev_idx]))
        v2 = _norm(_sub(points[next_idx], points[i]))
        # Degenerate (zero-length) edges shouldn't mark corners.
        if v1 is None or v2 is None:
            continue
        d = _dot(v1, v2)
        # d == 1 means edges are collinear (no turn); d < cos_threshold
        # means the turn exceeds angle_threshold.
        if d < cos_threshold:
            corners.append(i)
    return corners


def split_into_runs(
    points: list[tuple[float, float]],
    corners: list[int],
    closed: bool,
) -> list[list[tuple[float, float]]]:
    """Split ``points`` into runs separated by corners. Each run is a new
    list because closed-ring runs may wrap around the seam.
    """
    n = len(points)
    if not corners:
        if closed:
            # No corners on a closed ring -- emit one run that includes
            # the seam vertex twice (start == end) so fit_curve can
            # recover a closed-loop Bezier approximation.
            r = list(points)
            r.append(points[0])
            return [r]
        else:
            return [list(points)]
    runs: list[list[tuple[float, float]]] = []
    if closed:
        # Walk corner-to-corner around the ring. Each run starts at
        # corner k and ends at corner k+1 (mod corners.len()),
        # collecting every intermediate vertex.
        for k in range(len(corners)):
            a = corners[k]
            b = corners[(k + 1) % len(corners)]
            run: list[tuple[float, float]] = []
            i = a
            run.append(points[i])
            while True:
                i = (i + 1) % n
                run.append(points[i])
                if i == b:
                    break
            runs.append(run)
    else:
        # Open polyline: runs are [start..corners[0]],
        # [corners[0]..corners[1]], ..., [corners[last]..n-1].
        prev = 0
        for c in corners:
            runs.append(list(points[prev:c + 1]))
            prev = c
        runs.append(list(points[prev:n]))
    return runs


def _sub(a: tuple[float, float], b: tuple[float, float]) -> tuple[float, float]:
    return (a[0] - b[0], a[1] - b[1])


def _dot(a: tuple[float, float], b: tuple[float, float]) -> float:
    return a[0] * b[0] + a[1] * b[1]


def _norm(v: tuple[float, float]) -> tuple[float, float] | None:
    m = math.sqrt(v[0] * v[0] + v[1] * v[1])
    if m < 1e-12:
        return None
    return (v[0] / m, v[1] / m)
