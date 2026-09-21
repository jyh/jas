"""Geometry helpers for precise hit-testing.

Pure-geometry functions used by the controller for marquee selection,
element intersection tests, and control-point queries.  These do not
depend on the document model — only on element geometry.
"""

from __future__ import annotations

from geometry.element import (
    Circle, CompoundShape, Element, Ellipse, GeneratedElem, Group, Layer,
    LiveElement, Line, Path, Polygon, Polyline, RecordedElem, Rect,
    ReferenceElem, Text, TextPath, Transform,
    control_point_count,
    flatten_path_commands,
)


# ---------------------------------------------------------------------------
# Primitive geometry
# ---------------------------------------------------------------------------

def point_in_rect(px: float, py: float,
                  rx: float, ry: float, rw: float, rh: float) -> bool:
    return rx <= px <= rx + rw and ry <= py <= ry + rh


def _cross(ox: float, oy: float, ax: float, ay: float,
           bx: float, by: float) -> float:
    return (ax - ox) * (by - oy) - (ay - oy) * (bx - ox)


def _on_segment(px1: float, py1: float, px2: float, py2: float,
                qx: float, qy: float) -> bool:
    return (min(px1, px2) <= qx <= max(px1, px2) and
            min(py1, py2) <= qy <= max(py1, py2))


def segments_intersect(ax1: float, ay1: float, ax2: float, ay2: float,
                       bx1: float, by1: float, bx2: float, by2: float) -> bool:
    d1 = _cross(bx1, by1, bx2, by2, ax1, ay1)
    d2 = _cross(bx1, by1, bx2, by2, ax2, ay2)
    d3 = _cross(ax1, ay1, ax2, ay2, bx1, by1)
    d4 = _cross(ax1, ay1, ax2, ay2, bx2, by2)
    if ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and \
       ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0)):
        return True
    eps = 1e-10
    if abs(d1) < eps and _on_segment(bx1, by1, bx2, by2, ax1, ay1): return True
    if abs(d2) < eps and _on_segment(bx1, by1, bx2, by2, ax2, ay2): return True
    if abs(d3) < eps and _on_segment(ax1, ay1, ax2, ay2, bx1, by1): return True
    if abs(d4) < eps and _on_segment(ax1, ay1, ax2, ay2, bx2, by2): return True
    return False


def segment_intersects_rect(x1: float, y1: float, x2: float, y2: float,
                            rx: float, ry: float, rw: float, rh: float) -> bool:
    if point_in_rect(x1, y1, rx, ry, rw, rh):
        return True
    if point_in_rect(x2, y2, rx, ry, rw, rh):
        return True
    edges = [
        (rx, ry, rx + rw, ry),
        (rx + rw, ry, rx + rw, ry + rh),
        (rx + rw, ry + rh, rx, ry + rh),
        (rx, ry + rh, rx, ry),
    ]
    return any(segments_intersect(x1, y1, x2, y2, *e) for e in edges)


def rects_intersect(ax: float, ay: float, aw: float, ah: float,
                    bx: float, by: float, bw: float, bh: float) -> bool:
    return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by


def circle_intersects_rect(cx: float, cy: float, r: float,
                           rx: float, ry: float, rw: float, rh: float,
                           filled: bool) -> bool:
    closest_x = max(rx, min(cx, rx + rw))
    closest_y = max(ry, min(cy, ry + rh))
    dist_sq = (cx - closest_x) ** 2 + (cy - closest_y) ** 2
    if not filled:
        corners = [(rx, ry), (rx + rw, ry), (rx + rw, ry + rh), (rx, ry + rh)]
        max_dist_sq = max((cx - cx2) ** 2 + (cy - cy2) ** 2 for cx2, cy2 in corners)
        return dist_sq <= r * r <= max_dist_sq
    return dist_sq <= r * r


def ellipse_intersects_rect(cx: float, cy: float, erx: float, ery: float,
                            rx: float, ry: float, rw: float, rh: float,
                            filled: bool) -> bool:
    if erx == 0 or ery == 0:
        return False
    return circle_intersects_rect(
        cx / erx, cy / ery, 1.0,
        rx / erx, ry / ery, rw / erx, rh / ery,
        filled,
    )


def _point_segment_dist_sq(px: float, py: float,
                           x1: float, y1: float, x2: float, y2: float) -> float:
    """Squared distance from a point to the CLOSED segment (x1,y1)-(x2,y2).
    A zero-length segment degrades to the point-to-point distance."""
    dx = x2 - x1
    dy = y2 - y1
    len_sq = dx * dx + dy * dy
    t = 0.0 if len_sq <= 0.0 else max(0.0, min(1.0, ((px - x1) * dx + (py - y1) * dy) / len_sq))
    qx = x1 + t * dx
    qy = y1 + t * dy
    return (px - qx) ** 2 + (py - qy) ** 2


def circle_intersects_polygon(cx: float, cy: float, r: float,
                              poly: list[tuple[float, float]],
                              filled: bool) -> bool:
    """The polygon-region counterpart of ``circle_intersects_rect``, with
    the same two semantics: ``filled`` asks whether the DISC meets the
    region, ``not filled`` whether the stroked RING does.

    Both reduce to two numbers: the distance from the centre to the
    nearest point of the region (0 when the centre is inside it) and to
    the farthest, which is always a vertex. The disc meets the region
    when the nearest is within r; the ring does when r lies between the
    two, so a region the disc swallows whole misses the ring. Mirrors
    Rust's ``circle_intersects_polygon``.
    """
    if not poly:
        return False
    if point_in_polygon(cx, cy, poly):
        min_dist_sq = 0.0
    else:
        n = len(poly)
        min_dist_sq = min(
            _point_segment_dist_sq(cx, cy, *poly[i], *poly[(i + 1) % n])
            for i in range(n)
        )
    if not filled:
        max_dist_sq = max((cx - px) ** 2 + (cy - py) ** 2 for px, py in poly)
        return min_dist_sq <= r * r <= max_dist_sq
    return min_dist_sq <= r * r


def ellipse_intersects_polygon(cx: float, cy: float, erx: float, ery: float,
                               poly: list[tuple[float, float]],
                               filled: bool) -> bool:
    """Polygon-region counterpart of ``ellipse_intersects_rect``: divide
    the ellipse and the region by the radii so the ellipse becomes the
    unit circle, then ask the circle question. An affine image of a
    polygon is a polygon, so nothing about the region is approximated.
    """
    if erx == 0 or ery == 0:
        return False
    unit = [(x / erx, y / ery) for x, y in poly]
    return circle_intersects_polygon(cx / erx, cy / ery, 1.0, unit, filled)


# ---------------------------------------------------------------------------
# Element-level queries
# ---------------------------------------------------------------------------

def segments_of_element(elem: Element) -> list[tuple[float, float, float, float]]:
    """Return the line segments that make up the visible drawn edges of an element."""
    match elem:
        case Line(x1=x1, y1=y1, x2=x2, y2=y2):
            return [(x1, y1, x2, y2)]
        case Rect(x=x, y=y, width=w, height=h):
            return [(x, y, x+w, y), (x+w, y, x+w, y+h),
                    (x+w, y+h, x, y+h), (x, y+h, x, y)]
        case Polyline(points=pts):
            return [(pts[i][0], pts[i][1], pts[i+1][0], pts[i+1][1])
                    for i in range(len(pts) - 1)] if len(pts) >= 2 else []
        case Polygon(points=pts):
            if len(pts) < 2:
                return []
            segs = [(pts[i][0], pts[i][1], pts[i+1][0], pts[i+1][1])
                    for i in range(len(pts) - 1)]
            segs.append((pts[-1][0], pts[-1][1], pts[0][0], pts[0][1]))
            return segs
        case Path(d=cmds):
            pts = flatten_path_commands(cmds)
            return [(pts[i][0], pts[i][1], pts[i+1][0], pts[i+1][1])
                    for i in range(len(pts) - 1)] if len(pts) >= 2 else []
        # A compound shape's segments are the edges of EVERY evaluated
        # ring, each closed: a hole's boundary is a boundary and the hole's
        # interior is not the shape. Mirrors Rust's `Element::Live` arm.
        case CompoundShape():
            from geometry.live import DEFAULT_PRECISION
            segs: list[tuple[float, float, float, float]] = []
            for ring in elem.evaluate(DEFAULT_PRECISION):
                _push_ring_segments(ring, segs)
            return segs
        # No coordinates without a resolver, and this verb has none: a
        # dangling reference evaluates to empty (REFERENCE_GRAPH.md §3).
        # Explicit rather than folded into the catch-all, so a new live
        # kind has to say which side of that line it falls on.
        case ReferenceElem() | RecordedElem() | GeneratedElem():
            return []
        case _:
            return []


def _push_ring_segments(ring, segs: list) -> None:
    """Append ``ring``'s edges, closed, to ``segs``."""
    if len(ring) < 2:
        return
    for i in range(len(ring) - 1):
        segs.append((ring[i][0], ring[i][1], ring[i+1][0], ring[i+1][1]))
    segs.append((ring[-1][0], ring[-1][1], ring[0][0], ring[0][1]))


def element_intersects_rect(elem: Element,
                            rx: float, ry: float, rw: float, rh: float) -> bool:
    """Test whether the visible drawn portion of elem intersects the selection rect."""
    if elem.transform is not None:
        inv = elem.transform.inverse()
        if inv is None:
            return False
        corners = [
            inv.apply_point(rx, ry),
            inv.apply_point(rx + rw, ry),
            inv.apply_point(rx + rw, ry + rh),
            inv.apply_point(rx, ry + rh),
        ]
        return _element_intersects_polygon_local(elem, corners)
    return _element_intersects_rect_local(elem, rx, ry, rw, rh)


def _element_intersects_rect_local(elem: Element,
                                   rx: float, ry: float, rw: float, rh: float) -> bool:
    """Rect hit-test against raw (untransformed) coordinates."""
    match elem:
        case Line():
            return segment_intersects_rect(elem.x1, elem.y1, elem.x2, elem.y2,
                                            rx, ry, rw, rh)
        case Rect():
            if elem.fill is not None:
                return rects_intersect(elem.x, elem.y, elem.width, elem.height,
                                        rx, ry, rw, rh)
            return any(segment_intersects_rect(*seg, rx, ry, rw, rh)
                       for seg in segments_of_element(elem))

        case Circle():
            return circle_intersects_rect(elem.cx, elem.cy, elem.r,
                                           rx, ry, rw, rh,
                                           elem.fill is not None)
        case Ellipse():
            return ellipse_intersects_rect(elem.cx, elem.cy, elem.rx, elem.ry,
                                            rx, ry, rw, rh,
                                            elem.fill is not None)
        case Polyline():
            if elem.fill is not None:
                return rects_intersect(*elem.bounds(), rx, ry, rw, rh)
            return any(segment_intersects_rect(*seg, rx, ry, rw, rh)
                       for seg in segments_of_element(elem))

        case Polygon():
            if elem.fill is not None:
                pts = elem.points
                if any(point_in_rect(px, py, rx, ry, rw, rh) for px, py in pts):
                    return True
                if _region_corner_inside_bounds(elem, rx, ry, rw, rh):
                    return True
                return any(segment_intersects_rect(*seg, rx, ry, rw, rh)
                           for seg in segments_of_element(elem))
            return any(segment_intersects_rect(*seg, rx, ry, rw, rh)
                       for seg in segments_of_element(elem))

        # Path, and every live kind: tested against the element's own
        # segments, never its bounding box alone, or a marquee in a
        # compound shape's hole selects it.
        case Path() | LiveElement():
            segs = segments_of_element(elem)
            if elem.fill is not None:
                endpoints = [(s[0], s[1]) for s in segs] + [(s[2], s[3]) for s in segs]
                if any(point_in_rect(px, py, rx, ry, rw, rh) for px, py in endpoints):
                    return True
                if _region_corner_inside_bounds(elem, rx, ry, rw, rh):
                    return True
            return any(segment_intersects_rect(*seg, rx, ry, rw, rh) for seg in segs)

        case Text():
            return rects_intersect(*elem.bounds(), rx, ry, rw, rh)

        case _:
            return rects_intersect(*elem.bounds(), rx, ry, rw, rh)


def _region_corner_inside_bounds(elem: Element,
                                 rx: float, ry: float, rw: float, rh: float) -> bool:
    """A marquee may lie WHOLLY INSIDE a filled shape: it touches no vertex
    and crosses no segment, yet every point of it is painted. The polygon
    path has always had this clause (a region vertex inside the bounds);
    this is the rect path's copy, so the two agree by construction. It is
    the bounding box on both paths, as in both ports."""
    bx, by, bw, bh = elem.bounds()
    return any(point_in_rect(px, py, bx, by, bw, bh)
               for px, py in ((rx, ry), (rx + rw, ry),
                              (rx + rw, ry + rh), (rx, ry + rh)))


# ---------------------------------------------------------------------------
# Polygon geometry
# ---------------------------------------------------------------------------

def point_in_polygon(px: float, py: float, poly: list[tuple[float, float]]) -> bool:
    """Ray-casting (even-odd) point-in-polygon test."""
    n = len(poly)
    if n < 3:
        return False
    inside = False
    j = n - 1
    for i in range(n):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if ((yi > py) != (yj > py)) and (px < (xj - xi) * (py - yi) / (yj - yi) + xi):
            inside = not inside
        j = i
    return inside


def segment_intersects_polygon(x1: float, y1: float, x2: float, y2: float,
                               poly: list[tuple[float, float]]) -> bool:
    if point_in_polygon(x1, y1, poly) or point_in_polygon(x2, y2, poly):
        return True
    n = len(poly)
    for i in range(n):
        j = (i + 1) % n
        if segments_intersect(x1, y1, x2, y2, poly[i][0], poly[i][1], poly[j][0], poly[j][1]):
            return True
    return False


def element_intersects_polygon(elem: Element,
                               poly: list[tuple[float, float]]) -> bool:
    """Test whether the visible drawn portion of elem intersects the polygon."""
    if elem.transform is not None:
        inv = elem.transform.inverse()
        if inv is None:
            return False
        local_poly = [inv.apply_point(x, y) for x, y in poly]
        return _element_intersects_polygon_local(elem, local_poly)
    return _element_intersects_polygon_local(elem, poly)


def _element_intersects_polygon_local(elem: Element,
                                      poly: list[tuple[float, float]]) -> bool:
    """Polygon hit-test against raw (untransformed) coordinates."""
    match elem:
        case Line():
            return segment_intersects_polygon(elem.x1, elem.y1, elem.x2, elem.y2, poly)
        case Rect():
            if elem.fill is not None:
                corners = [(elem.x, elem.y), (elem.x + elem.width, elem.y),
                           (elem.x + elem.width, elem.y + elem.height),
                           (elem.x, elem.y + elem.height)]
                if any(point_in_polygon(cx, cy, poly) for cx, cy in corners):
                    return True
                if any(point_in_rect(px, py, elem.x, elem.y, elem.width, elem.height)
                       for px, py in poly):
                    return True
                return any(segment_intersects_polygon(*seg, poly)
                           for seg in segments_of_element(elem))
            return any(segment_intersects_polygon(*seg, poly)
                       for seg in segments_of_element(elem))
        # A transformed marquee arrives HERE, so every kind with a real arm
        # on the rect path needs one on this path too. A curve has no
        # segments, and the catch-all below would see nothing of it.
        case Ellipse():
            return ellipse_intersects_polygon(elem.cx, elem.cy, elem.rx, elem.ry,
                                              poly, elem.fill is not None)
        case Circle():
            return circle_intersects_polygon(elem.cx, elem.cy, elem.r,
                                             poly, elem.fill is not None)
        case Text() | TextPath() | Group() | Layer():
            bx, by, bw, bh = elem.bounds()
            corners = [(bx, by), (bx + bw, by), (bx + bw, by + bh), (bx, by + bh)]
            if any(point_in_polygon(cx, cy, poly) for cx, cy in corners):
                return True
            if any(point_in_rect(px, py, bx, by, bw, bh) for px, py in poly):
                return True
            rect_segs = [(bx, by, bx + bw, by), (bx + bw, by, bx + bw, by + bh),
                         (bx + bw, by + bh, bx, by + bh), (bx, by + bh, bx, by)]
            return any(segment_intersects_polygon(*seg, poly) for seg in rect_segs)
        case _:
            if elem.fill is not None:
                segs = segments_of_element(elem)
                endpoints = [(s[0], s[1]) for s in segs] + [(s[2], s[3]) for s in segs]
                if any(point_in_polygon(px, py, poly) for px, py in endpoints):
                    return True
                if any(point_in_rect(px, py, *elem.bounds()) for px, py in poly):
                    return True
                return any(segment_intersects_polygon(*seg, poly) for seg in segs)
            return any(segment_intersects_polygon(*seg, poly)
                       for seg in segments_of_element(elem))
