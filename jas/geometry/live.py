"""LiveElement framework helpers.

Shared infrastructure for non-destructive element kinds that store
source inputs and evaluate them on demand. `CompoundShape` (defined
in `geometry.element`) is the first conformer; this module provides
the geometry-bridge helper (`element_to_polygon_set`), the boolean
dispatcher (`apply_operation`), bounds helper, and the evaluate
function that CompoundShape calls.

See `transcripts/BOOLEAN.md` § Live element framework.
"""

from __future__ import annotations

import math
from typing import TYPE_CHECKING

from algorithms.boolean import (
    PolygonSet,
    boolean_exclude,
    boolean_intersect,
    boolean_subtract,
    boolean_union,
)

if TYPE_CHECKING:
    from geometry.element import CompoundOperation, Element


# Default geometric tolerance in points. Matches the Precision default
# in the Boolean Options dialog (BOOLEAN.md § Boolean Options dialog).
# Equals 0.01 mm.
DEFAULT_PRECISION: float = 0.0283


def element_to_polygon_set(elem: "Element", precision: float) -> PolygonSet:
    """Flatten a document element into a polygon set suitable for the
    boolean algorithm.

    - Rect / Polygon / Polyline / Circle / Ellipse: direct conversion.
      Polyline is implicitly closed for even-odd fill.
    - Group / Layer: recursively concatenate children's rings.
    - CompoundShape: recursively evaluate.
    - Path / TextPath: flatten Bezier commands to rings per subpath.
    - Line / Text: empty (zero area or glyph-outline flattening
      deferred to a font-outline pipeline).
    """
    from geometry.element import (
        Circle,
        CompoundShape,
        Ellipse,
        Group,
        Layer,
        Line,
        Path,
        Polygon,
        Polyline,
        Rect,
        Text,
        TextPath,
    )

    if isinstance(elem, Rect):
        return [[
            (elem.x, elem.y),
            (elem.x + elem.width, elem.y),
            (elem.x + elem.width, elem.y + elem.height),
            (elem.x, elem.y + elem.height),
        ]]
    if isinstance(elem, Polygon):
        return [list(elem.points)] if elem.points else []
    if isinstance(elem, Polyline):
        return [list(elem.points)] if elem.points else []
    if isinstance(elem, Circle):
        return [_circle_to_ring(elem.cx, elem.cy, elem.r, precision)]
    if isinstance(elem, Ellipse):
        return [_ellipse_to_ring(elem.cx, elem.cy, elem.rx, elem.ry, precision)]
    if isinstance(elem, (Group, Layer)):
        out: PolygonSet = []
        for child in elem.children:
            out.extend(element_to_polygon_set(child, precision))
        return out
    if isinstance(elem, CompoundShape):
        return elem.evaluate(precision)
    if isinstance(elem, (Path, TextPath)):
        return _flatten_path_to_rings(elem.d)
    # Line has zero area; Text glyph flattening deferred.
    if isinstance(elem, (Line, Text)):
        return []
    return []


def apply_operation(
    op: "CompoundOperation", operand_sets: list[PolygonSet]
) -> PolygonSet:
    """Dispatch a boolean operation across an arbitrary number of
    operands. Binary ops fold left-to-right; SubtractFront consumes
    the last operand as the cutter and unions the remaining survivors
    after each has the cutter removed.
    """
    from geometry.element import CompoundOperation

    if not operand_sets:
        return []
    if op == CompoundOperation.UNION:
        result = operand_sets[0]
        for b in operand_sets[1:]:
            result = boolean_union(result, b)
        return result
    if op == CompoundOperation.INTERSECTION:
        result = operand_sets[0]
        for b in operand_sets[1:]:
            result = boolean_intersect(result, b)
        return result
    if op == CompoundOperation.SUBTRACT_FRONT:
        if len(operand_sets) < 2:
            return operand_sets[0]
        cutter = operand_sets[-1]
        survivors = operand_sets[:-1]
        acc: PolygonSet = []
        for s in survivors:
            acc = boolean_union(acc, boolean_subtract(s, cutter))
        return acc
    if op == CompoundOperation.EXCLUDE:
        result = operand_sets[0]
        for b in operand_sets[1:]:
            result = boolean_exclude(result, b)
        return result
    return []


def bounds_of_polygon_set(
    ps: PolygonSet,
) -> tuple[float, float, float, float]:
    """Tight bounding box of a polygon set. Returns (0, 0, 0, 0) for
    empty input.
    """
    min_x = math.inf
    min_y = math.inf
    max_x = -math.inf
    max_y = -math.inf
    for ring in ps:
        for x, y in ring:
            if x < min_x:
                min_x = x
            if y < min_y:
                min_y = y
            if x > max_x:
                max_x = x
            if y > max_y:
                max_y = y
    if not math.isfinite(min_x):
        return (0.0, 0.0, 0.0, 0.0)
    return (min_x, min_y, max_x - min_x, max_y - min_y)


# ── Internal helpers ──────────────────────────────────────────────


def _segments_for_arc(radius: float, precision: float) -> int:
    """Number of segments to approximate a circle of the given radius
    so the max perpendicular distance to the true arc is at most
    `precision`. Error per segment ≈ r(1 − cos(π/n)); solving for n
    yields n ≥ π·√(r / (2·precision)).
    """
    if radius <= 0.0 or precision <= 0.0:
        return 32
    n = math.ceil(math.pi * math.sqrt(radius / (2.0 * precision)))
    return max(n, 8)


def _circle_to_ring(
    cx: float, cy: float, r: float, precision: float
) -> list[tuple[float, float]]:
    n = _segments_for_arc(r, precision)
    return [
        (cx + r * math.cos(2.0 * math.pi * i / n),
         cy + r * math.sin(2.0 * math.pi * i / n))
        for i in range(n)
    ]


def _ellipse_to_ring(
    cx: float, cy: float, rx: float, ry: float, precision: float
) -> list[tuple[float, float]]:
    n = _segments_for_arc(max(rx, ry), precision)
    return [
        (cx + rx * math.cos(2.0 * math.pi * i / n),
         cy + ry * math.sin(2.0 * math.pi * i / n))
        for i in range(n)
    ]


def _flatten_path_to_rings(d) -> PolygonSet:
    """Flatten path commands into one ring per subpath. MoveTo starts
    a new ring; ClosePath finalizes the current ring. Open subpaths
    are finalized at the next MoveTo or end-of-commands. Rings with
    fewer than 3 points are dropped.
    """
    from geometry.element import (
        ArcTo,
        ClosePath,
        CurveTo,
        LineTo,
        MoveTo,
        QuadTo,
        SmoothCurveTo,
        SmoothQuadTo,
    )

    rings: PolygonSet = []
    cur: list[tuple[float, float]] = []
    cx = cy = 0.0
    FLATTEN_STEPS = 20

    def flush():
        nonlocal cur
        if len(cur) >= 3:
            rings.append(cur)
        cur = []

    for cmd in d:
        if isinstance(cmd, MoveTo):
            flush()
            cur.append((cmd.x, cmd.y))
            cx, cy = cmd.x, cmd.y
        elif isinstance(cmd, LineTo):
            cur.append((cmd.x, cmd.y))
            cx, cy = cmd.x, cmd.y
        elif isinstance(cmd, CurveTo):
            for i in range(1, FLATTEN_STEPS + 1):
                t = i / FLATTEN_STEPS
                mt = 1.0 - t
                px = (mt ** 3 * cx + 3.0 * mt ** 2 * t * cmd.x1
                      + 3.0 * mt * t ** 2 * cmd.x2 + t ** 3 * cmd.x)
                py = (mt ** 3 * cy + 3.0 * mt ** 2 * t * cmd.y1
                      + 3.0 * mt * t ** 2 * cmd.y2 + t ** 3 * cmd.y)
                cur.append((px, py))
            cx, cy = cmd.x, cmd.y
        elif isinstance(cmd, QuadTo):
            for i in range(1, FLATTEN_STEPS + 1):
                t = i / FLATTEN_STEPS
                mt = 1.0 - t
                px = mt ** 2 * cx + 2.0 * mt * t * cmd.x1 + t ** 2 * cmd.x
                py = mt ** 2 * cy + 2.0 * mt * t * cmd.y1 + t ** 2 * cmd.y
                cur.append((px, py))
            cx, cy = cmd.x, cmd.y
        elif isinstance(cmd, ClosePath):
            flush()
        elif isinstance(cmd, (SmoothCurveTo, SmoothQuadTo, ArcTo)):
            # Approximate as line-to-endpoint, matching existing
            # flatten_path_commands behavior.
            cur.append((cmd.x, cmd.y))
            cx, cy = cmd.x, cmd.y
    flush()
    return rings
