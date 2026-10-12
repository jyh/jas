"""The hit test's law: a click hits what is painted, not a bounding box.

The statement is `transcripts/SELECTION_TOOL.md` § Hit test: painted
geometry; this module is its executable meaning, and the Rust and
Swift ports mirror it function for function (`hit_law.rs`,
`HitLaw.swift`). `doc_primitives.hit_test` and `hit_test_deep` walk
the document and ask `painted_hit` / `leaf_painted_hit` about each
element.

The geometry it reads comes from the domain layer (`geometry.element`,
`geometry.live`), which the interpreter already computes through.
"""

from __future__ import annotations

import math

HIT_TOLERANCE = 3.0
"""How far from a painted edge a click still hits, in document units."""

CURVE_STEPS = 20
"""Line segments per Bezier segment; the path flattener's own count."""

ELLIPSE_SIDES = 64
"""Sides of the polygon that stands in for a circle or ellipse outline."""


# ── Geometry helpers ─────────────────────────────────────


def _dist_to_segment(px, py, ax, ay, bx, by) -> float:
    dx, dy = bx - ax, by - ay
    len2 = dx * dx + dy * dy
    if len2 == 0.0:
        return math.hypot(px - ax, py - ay)
    t = ((px - ax) * dx + (py - ay) * dy) / len2
    t = max(0.0, min(1.0, t))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def _dist_to_outline(px, py, polylines) -> float:
    """Distance to the nearest segment of any (points, closed) polyline."""
    best = math.inf
    for pts, closed in polylines:
        n = len(pts)
        if n == 1:
            best = min(best, math.hypot(px - pts[0][0], py - pts[0][1]))
            continue
        last = n if closed else n - 1
        for i in range(last):
            ax, ay = pts[i]
            bx, by = pts[(i + 1) % n]
            best = min(best, _dist_to_segment(px, py, ax, ay, bx, by))
    return best


def _winding(px, py, ring) -> int:
    """Winding number of `ring` (implicitly closed) around the point."""
    w = 0
    n = len(ring)
    for i in range(n):
        ax, ay = ring[i]
        bx, by = ring[(i + 1) % n]
        if ay <= py:
            if by > py and (bx - ax) * (py - ay) - (px - ax) * (by - ay) > 0:
                w += 1
        elif by <= py and (bx - ax) * (py - ay) - (px - ax) * (by - ay) < 0:
            w -= 1
    return w


def _inside_rings(px, py, rings, even_odd: bool) -> bool:
    total = 0
    for ring in rings:
        if len(ring) >= 3:
            total += _winding(px, py, ring)
    return (total % 2 != 0) if even_odd else (total != 0)


def _ellipse_polygon(cx, cy, rx, ry):
    return [(cx + rx * math.cos(2 * math.pi * k / ELLIPSE_SIDES),
             cy + ry * math.sin(2 * math.pi * k / ELLIPSE_SIDES))
            for k in range(ELLIPSE_SIDES)]


def path_subpaths(d) -> list[tuple[list[tuple[float, float]], bool]]:
    """Flatten path commands to one (points, closed) polyline per subpath.

    Unlike `flatten_path_commands`, a MoveTo starts a NEW polyline, so
    nothing is drawn between one subpath's end and the next one's
    start. Smooth curves and arcs go straight to their end point, as in
    the path flattener.
    """
    from geometry.element import ClosePath, CurveTo, MoveTo, QuadTo

    out: list[tuple[list[tuple[float, float]], bool]] = []
    cur: list[tuple[float, float]] = []
    cx = cy = 0.0
    sx = sy = 0.0

    def flush(closed: bool):
        nonlocal cur
        if cur:
            out.append((cur, closed))
        cur = []

    for cmd in d:
        if isinstance(cmd, MoveTo):
            flush(False)
            cur = [(cmd.x, cmd.y)]
            cx, cy = sx, sy = cmd.x, cmd.y
        elif isinstance(cmd, ClosePath):
            flush(True)
            cx, cy = sx, sy
        else:
            if not cur:
                cur = [(cx, cy)]
            if isinstance(cmd, CurveTo):
                for i in range(1, CURVE_STEPS + 1):
                    t = i / CURVE_STEPS
                    mt = 1.0 - t
                    cur.append((
                        mt ** 3 * cx + 3 * mt ** 2 * t * cmd.x1
                        + 3 * mt * t ** 2 * cmd.x2 + t ** 3 * cmd.x,
                        mt ** 3 * cy + 3 * mt ** 2 * t * cmd.y1
                        + 3 * mt * t ** 2 * cmd.y2 + t ** 3 * cmd.y))
            elif isinstance(cmd, QuadTo):
                for i in range(1, CURVE_STEPS + 1):
                    t = i / CURVE_STEPS
                    mt = 1.0 - t
                    cur.append((
                        mt ** 2 * cx + 2 * mt * t * cmd.x1 + t ** 2 * cmd.x,
                        mt ** 2 * cy + 2 * mt * t * cmd.y1 + t ** 2 * cmd.y))
            else:
                # LineTo, SmoothCurveTo, SmoothQuadTo, ArcTo
                cur.append((cmd.x, cmd.y))
            cx, cy = cmd.x, cmd.y
    flush(False)
    return out


# ── The law ──────────────────────────────────────────────


def _outline(elem):
    """(points, closed) polylines for a leaf, or None when the leaf is
    hit by its bounding box instead (text, resolver-backed live kinds)."""
    from geometry.element import (
        Circle, CompoundShape, Ellipse, Line, Path, Polygon, Polyline, Rect,
    )
    if isinstance(elem, Line):
        return [([(elem.x1, elem.y1), (elem.x2, elem.y2)], False)]
    if isinstance(elem, Rect):
        x, y, w, h = elem.x, elem.y, elem.width, elem.height
        return [([(x, y), (x + w, y), (x + w, y + h), (x, y + h)], True)]
    if isinstance(elem, Circle):
        return [(_ellipse_polygon(elem.cx, elem.cy, elem.r, elem.r), True)]
    if isinstance(elem, Ellipse):
        return [(_ellipse_polygon(elem.cx, elem.cy, elem.rx, elem.ry), True)]
    if isinstance(elem, Polyline):
        return [(list(elem.points), False)]
    if isinstance(elem, Polygon):
        return [(list(elem.points), True)]
    if isinstance(elem, Path):
        return path_subpaths(elem.d)
    if isinstance(elem, CompoundShape):
        from geometry.live import DEFAULT_PRECISION
        return [(list(r), True) for r in elem.evaluate(DEFAULT_PRECISION)]
    return None


def _inside_fill(elem, outline, px, py) -> bool:
    from geometry.element import (
        Circle, CompoundShape, Ellipse, FillRule, Line, Path, Rect,
    )
    if isinstance(elem, Line):
        return False
    if isinstance(elem, Rect):
        return (elem.x <= px <= elem.x + elem.width
                and elem.y <= py <= elem.y + elem.height)
    if isinstance(elem, Circle):
        return math.hypot(px - elem.cx, py - elem.cy) <= elem.r
    if isinstance(elem, Ellipse):
        if elem.rx <= 0 or elem.ry <= 0:
            return False
        nx, ny = (px - elem.cx) / elem.rx, (py - elem.cy) / elem.ry
        return nx * nx + ny * ny <= 1.0
    even_odd = isinstance(elem, CompoundShape) or (
        isinstance(elem, Path) and elem.fill_rule == FillRule.EVENODD)
    return _inside_rings(px, py, [pts for pts, _ in outline], even_odd)


def _has_fill(elem) -> bool:
    return (getattr(elem, "fill", None) is not None
            or getattr(elem, "fill_gradient", None) is not None)


def _stroke_reach(stroke) -> float:
    from geometry.element import StrokeAlign
    return stroke.width / 2.0 if stroke.align == StrokeAlign.CENTER else stroke.width


def _box_contains(elem, px, py) -> bool:
    try:
        b = elem.bounds()
    except TypeError:
        b = elem.bounds
    return b[0] <= px <= b[0] + b[2] and b[1] <= py <= b[1] + b[3]


def to_local(elem, px, py):
    """Map a point from the parent's coordinates into `elem`'s own;
    None when the element's transform cannot be inverted."""
    t = getattr(elem, "transform", None)
    if t is None:
        return px, py
    inv = t.inverse()
    if inv is None:
        return None
    return inv.apply_point(px, py)


def leaf_painted_hit(elem, px, py, outline_mode: bool) -> bool:
    """Whether a non-container element is hit at (px, py), given in its
    PARENT's coordinates."""
    local = to_local(elem, px, py)
    if local is None:
        return False
    px, py = local
    outline = _outline(elem)
    if outline is None:
        return _box_contains(elem, px, py)
    if outline_mode:
        return _dist_to_outline(px, py, outline) <= HIT_TOLERANCE
    if _has_fill(elem) and _inside_fill(elem, outline, px, py):
        return True
    stroke = getattr(elem, "stroke", None)
    if stroke is not None:
        return _dist_to_outline(px, py, outline) <= _stroke_reach(stroke) + HIT_TOLERANCE
    return False


def is_container(elem) -> bool:
    from geometry.element import Group
    return isinstance(elem, Group)  # Layer is a Group


def blocks_hit(elem, cap):
    """The effective visibility of `elem` under `cap`, or None when the
    element (and everything inside it) cannot be hit."""
    from geometry.element import Visibility
    if getattr(elem, "locked", False):
        return None
    vis = min(cap, getattr(elem, "visibility", Visibility.PREVIEW))
    return None if vis == Visibility.INVISIBLE else vis


def painted_hit(elem, px, py, cap) -> bool:
    """Whether `elem` is hit at (px, py), given in its PARENT's
    coordinates, under the inherited visibility `cap`. A group is hit
    when any child is."""
    from geometry.element import Visibility
    vis = blocks_hit(elem, cap)
    if vis is None:
        return False
    if is_container(elem):
        local = to_local(elem, px, py)
        if local is None:
            return False
        return any(painted_hit(c, local[0], local[1], vis)
                   for c in reversed(elem.children))
    return leaf_painted_hit(elem, px, py, vis == Visibility.OUTLINE)


def deep_hit(elem, path, px, py, cap):
    """The deepest painted leaf under (px, py) inside `elem`, as a path,
    or None. Coordinates are in `elem`'s PARENT's space."""
    from geometry.element import Visibility
    vis = blocks_hit(elem, cap)
    if vis is None:
        return None
    if is_container(elem):
        local = to_local(elem, px, py)
        if local is None:
            return None
        for i in range(len(elem.children) - 1, -1, -1):
            r = deep_hit(elem.children[i], path + [i], local[0], local[1], vis)
            if r is not None:
                return r
        return None
    return path if leaf_painted_hit(elem, px, py, vis == Visibility.OUTLINE) else None
