"""Geometry helpers for precise hit-testing.

Pure-geometry functions used by the controller for marquee selection,
element intersection tests, and control-point queries.  These do not
depend on the document model — only on element geometry.
"""

from __future__ import annotations

from geometry.element import (
    Circle, Element, Ellipse, Group, Layer, Line, Path, Polygon, Polyline,
    Rect, Text,
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
        case _:
            return []


def all_cps(elem: Element) -> frozenset[int]:
    """Return a frozenset of all control point indices for an element."""
    return frozenset(range(control_point_count(elem)))


def element_intersects_rect(elem: Element,
                            rx: float, ry: float, rw: float, rh: float) -> bool:
    """Test whether the visible drawn portion of elem intersects the selection rect.

    TODO: This ignores the element's transform. If an element has a non-identity
    transform, its visual position differs from its raw coordinates. To fix,
    inverse-transform the selection rect into the element's local coordinate
    space before testing (inheriting transforms from parent groups).
    """
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
                return any(segment_intersects_rect(*seg, rx, ry, rw, rh)
                           for seg in segments_of_element(elem))
            return any(segment_intersects_rect(*seg, rx, ry, rw, rh)
                       for seg in segments_of_element(elem))

        case Path():
            if elem.fill is not None:
                segs = segments_of_element(elem)
                endpoints = [(s[0], s[1]) for s in segs] + [(s[2], s[3]) for s in segs]
                if any(point_in_rect(px, py, rx, ry, rw, rh) for px, py in endpoints):
                    return True
                return any(segment_intersects_rect(*seg, rx, ry, rw, rh) for seg in segs)
            return any(segment_intersects_rect(*seg, rx, ry, rw, rh)
                       for seg in segments_of_element(elem))

        case Text():
            return rects_intersect(*elem.bounds(), rx, ry, rw, rh)

        case _:
            return rects_intersect(*elem.bounds(), rx, ry, rw, rh)
