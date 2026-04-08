"""Ring normalizer for self-intersecting polygons under non-zero winding.

Port of jas_dioxus/src/algorithms/normalize.rs.

Algorithm: recursive splitting. For each ring, find the first proper
interior crossing between two non-adjacent edges; if none, the ring is
simple. Otherwise split at the crossing into two sub-rings and recurse.
Filter resulting sub-rings by the winding number of the original ring at
a sample point inside each.

Scope: handles simple rings, figure-8 / proper interior self-intersections,
and multiple intersections (resolved recursively). Does not handle
T-junctions, collinear self-retrace, or inter-ring cancellation.
"""

from __future__ import annotations

import math

from algorithms.boolean import PolygonSet, Ring, Point, _set_normalize_hook


def normalize(input_ps: PolygonSet) -> PolygonSet:
    """Normalize a polygon set under the non-zero winding fill rule."""
    out: PolygonSet = []
    for ring in input_ps:
        out.extend(_normalize_ring(ring))
    return out


def _normalize_ring(ring: Ring) -> list[Ring]:
    cleaned = _dedup_consecutive(ring)
    if len(cleaned) < 3:
        return []
    simple = _split_recursively(cleaned)
    out: list[Ring] = []
    for sub in simple:
        if len(sub) < 3:
            continue
        sample = _sample_inside_simple_ring(sub)
        if _winding_number(cleaned, sample) != 0:
            out.append(sub)
    return out


# ---------------------------------------------------------------------------
# Vertex cleanup
# ---------------------------------------------------------------------------


def _dedup_consecutive(ring: Ring) -> Ring:
    out: Ring = []
    for p in ring:
        if not out or out[-1] != p:
            out.append(p)
    while len(out) >= 2 and out[0] == out[-1]:
        out.pop()
    return out


# ---------------------------------------------------------------------------
# Self-intersection detection / splitting
# ---------------------------------------------------------------------------


def _segment_proper_intersection(
    a1: Point, a2: Point, b1: Point, b2: Point
) -> Point | None:
    dx_a = a2[0] - a1[0]
    dy_a = a2[1] - a1[1]
    dx_b = b2[0] - b1[0]
    dy_b = b2[1] - b1[1]
    denom = dx_a * dy_b - dy_a * dx_b
    if abs(denom) < 1e-12:
        return None
    dx_ab = a1[0] - b1[0]
    dy_ab = a1[1] - b1[1]
    s = (dx_b * dy_ab - dy_b * dx_ab) / denom
    t = (dx_a * dy_ab - dy_a * dx_ab) / denom
    eps = 1e-9
    if s <= eps or s >= 1.0 - eps or t <= eps or t >= 1.0 - eps:
        return None
    return (a1[0] + s * dx_a, a1[1] + s * dy_a)


def _find_first_self_intersection(ring: Ring):
    """Returns (i, j, p) or None."""
    n = len(ring)
    if n < 4:
        return None
    for i in range(n):
        a1 = ring[i]
        a2 = ring[(i + 1) % n]
        for j in range(i + 2, n):
            if i == 0 and j == n - 1:
                continue  # wrap-around adjacent
            b1 = ring[j]
            b2 = ring[(j + 1) % n]
            p = _segment_proper_intersection(a1, a2, b1, b2)
            if p is not None:
                return (i, j, p)
    return None


def _split_ring_at(ring: Ring, i: int, j: int, p: Point) -> tuple[Ring, Ring]:
    n = len(ring)
    a: Ring = list(ring[: i + 1])
    a.append(p)
    a.extend(ring[j + 1 : n])
    b: Ring = [p]
    b.extend(ring[i + 1 : j + 1])
    return (a, b)


def _split_recursively(ring: Ring) -> list[Ring]:
    stack: list[Ring] = [ring]
    simple: list[Ring] = []
    while stack:
        r = stack.pop()
        if len(r) < 3:
            continue
        found = _find_first_self_intersection(r)
        if found is None:
            simple.append(r)
        else:
            i, j, p = found
            sa, sb = _split_ring_at(r, i, j, p)
            stack.append(sa)
            stack.append(sb)
    return simple


# ---------------------------------------------------------------------------
# Winding and sampling
# ---------------------------------------------------------------------------


def _winding_number(ring: Ring, point: Point) -> int:
    n = len(ring)
    if n < 3:
        return 0
    px, py = point
    w = 0
    for i in range(n):
        x1, y1 = ring[i]
        x2, y2 = ring[(i + 1) % n]
        upward = y1 <= py and y2 > py
        downward = y2 <= py and y1 > py
        if not upward and not downward:
            continue
        t = (py - y1) / (y2 - y1)
        x_cross = x1 + t * (x2 - x1)
        if x_cross > px:
            if upward:
                w += 1
            else:
                w -= 1
    return w


def _sample_inside_simple_ring(ring: Ring) -> Point:
    assert len(ring) >= 3
    x0, y0 = ring[0]
    x1, y1 = ring[1]
    mx = (x0 + x1) / 2.0
    my = (y0 + y1) / 2.0
    dx = x1 - x0
    dy = y1 - y0
    length = math.sqrt(dx * dx + dy * dy)
    if length == 0.0:
        x2, y2 = ring[2]
        return ((x0 + x1 + x2) / 3.0, (y0 + y1 + y2) / 3.0)
    nx = -dy / length
    ny = dx / length
    offset = length * 1e-4
    left: Point = (mx + nx * offset, my + ny * offset)
    right: Point = (mx - nx * offset, my - ny * offset)
    return left if _winding_number(ring, left) != 0 else right


# Wire normalize into boolean's hook so run_boolean uses it.
_set_normalize_hook(normalize)
