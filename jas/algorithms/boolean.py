"""Boolean operations on planar polygons (union, intersection, difference, xor).

Port of jas_dioxus/src/algorithms/boolean.rs.

Data model: a `PolygonSet` is a list of rings; a ring is a closed polygon
expressed as a list of (x, y) vertices without the implicit closing vertex.
Multiple rings represent a region under the even-odd fill rule.

Inputs may be self-intersecting; they are normalized as a pre-pass under
the non-zero winding fill rule. See `boolean_normalize.py`.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from enum import Enum
from functools import cmp_to_key

# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

Point = tuple[float, float]
Ring = list[Point]
PolygonSet = list[Ring]


# ---------------------------------------------------------------------------
# Internal types
# ---------------------------------------------------------------------------


class _Op(Enum):
    UNION = 0
    INTERSECTION = 1
    DIFFERENCE = 2
    XOR = 3


class _Polygon(Enum):
    SUBJECT = 0
    CLIPPING = 1


class _EdgeType(Enum):
    NORMAL = 0
    SAME_TRANSITION = 1
    DIFFERENT_TRANSITION = 2
    NON_CONTRIBUTING = 3


@dataclass
class _SweepEvent:
    point: Point
    is_left: bool
    polygon: _Polygon
    other_event: int = -1
    in_out: bool = False
    other_in_out: bool = False
    in_result: bool = False
    edge_type: _EdgeType = _EdgeType.NORMAL
    prev_in_result: int = -1


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def boolean_union(a: PolygonSet, b: PolygonSet) -> PolygonSet:
    """`a ∪ b` — region covered by either operand."""
    return _run_boolean(a, b, _Op.UNION)


def boolean_intersect(a: PolygonSet, b: PolygonSet) -> PolygonSet:
    """`a ∩ b` — region covered by both operands."""
    return _run_boolean(a, b, _Op.INTERSECTION)


def boolean_subtract(a: PolygonSet, b: PolygonSet) -> PolygonSet:
    """`a − b` — region in `a` but not `b`. Not symmetric."""
    return _run_boolean(a, b, _Op.DIFFERENCE)


def boolean_exclude(a: PolygonSet, b: PolygonSet) -> PolygonSet:
    """`a ⊕ b` — symmetric difference."""
    return _run_boolean(a, b, _Op.XOR)


# ---------------------------------------------------------------------------
# Geometric primitives
# ---------------------------------------------------------------------------


def _point_lex_less(a: Point, b: Point) -> bool:
    if a[0] != b[0]:
        return a[0] < b[0]
    return a[1] < b[1]


def _signed_area(p0: Point, p1: Point, p2: Point) -> float:
    return (p0[0] - p2[0]) * (p1[1] - p2[1]) - (p1[0] - p2[0]) * (p0[1] - p2[1])


def _points_eq(a: Point, b: Point) -> bool:
    return abs(a[0] - b[0]) < 1e-9 and abs(a[1] - b[1]) < 1e-9


def project_onto_segment(a: Point, b: Point, p: Point) -> Point:
    """Project `p` onto the segment `a → b`, clamped to the endpoints.

    Used by `_handle_collinear` to keep split points on the edge being
    split (see boolean.rs comments for the off-line-split bug history).
    """
    dx = b[0] - a[0]
    dy = b[1] - a[1]
    len_sq = dx * dx + dy * dy
    if len_sq == 0.0:
        return a
    t = ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len_sq
    if t < 0.0:
        t = 0.0
    elif t > 1.0:
        t = 1.0
    return (a[0] + t * dx, a[1] + t * dy)


# ---------------------------------------------------------------------------
# Event ordering
# ---------------------------------------------------------------------------


def _event_less(events: list[_SweepEvent], a: int, b: int) -> bool:
    ea = events[a]
    eb = events[b]
    if ea.point[0] != eb.point[0]:
        return ea.point[0] < eb.point[0]
    if ea.point[1] != eb.point[1]:
        return ea.point[1] < eb.point[1]
    if ea.is_left != eb.is_left:
        return not ea.is_left  # right before left
    other_a = events[ea.other_event].point
    other_b = events[eb.other_event].point
    area = _signed_area(ea.point, other_a, other_b)
    if area != 0.0:
        return area > 0.0
    return ea.polygon.value < eb.polygon.value


def _status_less(events: list[_SweepEvent], a: int, b: int) -> bool:
    if a == b:
        return False
    ea = events[a]
    eb = events[b]
    other_a = events[ea.other_event].point
    other_b = events[eb.other_event].point
    if (_signed_area(ea.point, other_a, eb.point) != 0.0
            or _signed_area(ea.point, other_a, other_b) != 0.0):
        # Not collinear
        if ea.point == eb.point:
            return _signed_area(ea.point, other_a, other_b) > 0.0
        if _event_less(events, a, b):
            return _signed_area(ea.point, other_a, eb.point) > 0.0
        return _signed_area(eb.point, other_b, ea.point) < 0.0
    # Collinear: tie-break by polygon then by point order
    if ea.polygon != eb.polygon:
        return ea.polygon.value < eb.polygon.value
    if ea.point != eb.point:
        return _point_lex_less(ea.point, eb.point)
    return _point_lex_less(other_a, other_b)


# ---------------------------------------------------------------------------
# Result classification
# ---------------------------------------------------------------------------


def _edge_in_result(event: _SweepEvent, op: _Op) -> bool:
    et = event.edge_type
    if et == _EdgeType.NORMAL:
        if op == _Op.UNION:
            return event.other_in_out
        if op == _Op.INTERSECTION:
            return not event.other_in_out
        if op == _Op.DIFFERENCE:
            if event.polygon == _Polygon.SUBJECT:
                return event.other_in_out
            return not event.other_in_out
        return True  # XOR
    if et == _EdgeType.SAME_TRANSITION:
        return op == _Op.UNION or op == _Op.INTERSECTION
    if et == _EdgeType.DIFFERENT_TRANSITION:
        return op == _Op.DIFFERENCE
    return False  # NON_CONTRIBUTING


# ---------------------------------------------------------------------------
# Snap-rounding
# ---------------------------------------------------------------------------

_SNAP_RATIO = 1e-9


def _snap_grid(a: PolygonSet, b: PolygonSet) -> float | None:
    """Power-of-2 grid spacing as a fraction of the combined bbox diagonal."""
    min_x = math.inf
    min_y = math.inf
    max_x = -math.inf
    max_y = -math.inf
    any_pt = False
    for ring in a:
        for x, y in ring:
            if x < min_x:
                min_x = x
            if y < min_y:
                min_y = y
            if x > max_x:
                max_x = x
            if y > max_y:
                max_y = y
            any_pt = True
    for ring in b:
        for x, y in ring:
            if x < min_x:
                min_x = x
            if y < min_y:
                min_y = y
            if x > max_x:
                max_x = x
            if y > max_y:
                max_y = y
            any_pt = True
    if not any_pt:
        return None
    dx = max_x - min_x
    dy = max_y - min_y
    diagonal = math.sqrt(dx * dx + dy * dy)
    if diagonal <= 0.0:
        return None
    target = diagonal * _SNAP_RATIO
    if target <= 0.0 or not math.isfinite(target):
        return None
    exponent = math.ceil(math.log2(target))
    return math.ldexp(1.0, exponent)


def _snap_round(ps: PolygonSet, grid: float) -> PolygonSet:
    """Snap each vertex to the nearest power-of-2 grid point, dedup, drop
    rings of fewer than 3 distinct vertices."""
    out: PolygonSet = []
    for ring in ps:
        new_ring: Ring = []
        for x, y in ring:
            p: Point = (round(x / grid) * grid, round(y / grid) * grid)
            if not new_ring or new_ring[-1] != p:
                new_ring.append(p)
        # Drop wrap-around duplicate
        while len(new_ring) >= 2 and new_ring[0] == new_ring[-1]:
            new_ring.pop()
        if len(new_ring) >= 3:
            out.append(new_ring)
    return out


def _clone_nondegenerate(ps: PolygonSet) -> PolygonSet:
    return [list(r) for r in ps if len(r) >= 3]


# ---------------------------------------------------------------------------
# Sweep state
# ---------------------------------------------------------------------------


def _add_edge(events: list[_SweepEvent], p1: Point, p2: Point, polygon: _Polygon) -> None:
    if p1 == p2:
        return
    if _point_lex_less(p1, p2):
        lp, rp = p1, p2
    else:
        lp, rp = p2, p1
    l = len(events)
    r = l + 1
    le = _SweepEvent(point=lp, is_left=True, polygon=polygon, other_event=r)
    re = _SweepEvent(point=rp, is_left=False, polygon=polygon, other_event=l)
    events.append(le)
    events.append(re)


def _add_polygon_set(events: list[_SweepEvent], ps: PolygonSet, polygon: _Polygon) -> None:
    for ring in ps:
        n = len(ring)
        if n < 3:
            continue
        for i in range(n):
            _add_edge(events, ring[i], ring[(i + 1) % n], polygon)


# ---------------------------------------------------------------------------
# Top-level dispatch
# ---------------------------------------------------------------------------

# Hook for the normalizer. Set by boolean_normalize.py at import time so we
# avoid a circular import (boolean_normalize imports from this module).
_normalize_hook: list = [lambda ps: ps]


def _set_normalize_hook(fn) -> None:
    _normalize_hook[0] = fn


def _run_boolean(a: PolygonSet, b: PolygonSet, op: _Op) -> PolygonSet:
    grid = _snap_grid(a, b)
    if grid is not None:
        a_snap = _snap_round(a, grid)
        b_snap = _snap_round(b, grid)
    else:
        a_snap = _clone_nondegenerate(a)
        b_snap = _clone_nondegenerate(b)

    a_norm = _normalize_hook[0](a_snap)
    b_norm = _normalize_hook[0](b_snap)

    grid2 = _snap_grid(a_norm, b_norm)
    if grid2 is not None:
        a_final = _snap_round(a_norm, grid2)
        b_final = _snap_round(b_norm, grid2)
    else:
        a_final = a_norm
        b_final = b_norm

    return _run_boolean_sweep(a_final, b_final, op)


def _run_boolean_sweep(a: PolygonSet, b: PolygonSet, op: _Op) -> PolygonSet:
    """Run just the Martinez sweep on already-prepared inputs."""
    a_empty = all(len(r) < 3 for r in a)
    b_empty = all(len(r) < 3 for r in b)
    if a_empty and b_empty:
        return []
    if a_empty:
        if op in (_Op.UNION, _Op.XOR):
            return _clone_nondegenerate(b)
        return []
    if b_empty:
        if op in (_Op.UNION, _Op.XOR, _Op.DIFFERENCE):
            return _clone_nondegenerate(a)
        return []

    events: list[_SweepEvent] = []
    _add_polygon_set(events, a, _Polygon.SUBJECT)
    _add_polygon_set(events, b, _Polygon.CLIPPING)

    # Ascending event_less order so popping from the front is correct.
    def cmp_events(a: int, b: int) -> int:
        if _event_less(events, a, b):
            return -1
        if _event_less(events, b, a):
            return 1
        return 0

    queue: list[int] = list(range(len(events)))
    queue.sort(key=cmp_to_key(cmp_events))

    processed: list[int] = []
    status: list[int] = []

    while queue:
        idx = queue.pop(0)
        processed.append(idx)
        ev = events[idx]
        if ev.is_left:
            pos = _status_insert_pos(events, status, idx)
            status.insert(pos, idx)
            _compute_fields(events, status, pos)
            if pos + 1 < len(status):
                _possible_intersection(events, queue, idx, status[pos + 1], op)
            if pos > 0:
                _possible_intersection(events, queue, status[pos - 1], idx, op)
            events[idx].in_result = _edge_in_result(events[idx], op)
        else:
            other = ev.other_event
            if other in status:
                pos = status.index(other)
                above = status[pos + 1] if pos + 1 < len(status) else None
                below = status[pos - 1] if pos > 0 else None
                status.pop(pos)
                if below is not None and above is not None:
                    _possible_intersection(events, queue, below, above, op)
            events[idx].in_result = events[other].in_result

    return _connect_edges(events, processed)


# ---------------------------------------------------------------------------
# Status & queue helpers
# ---------------------------------------------------------------------------


def _status_insert_pos(events: list[_SweepEvent], status: list[int], idx: int) -> int:
    lo = 0
    hi = len(status)
    while lo < hi:
        mid = (lo + hi) // 2
        if _status_less(events, status[mid], idx):
            lo = mid + 1
        else:
            hi = mid
    return lo


def _queue_push(queue: list[int], events: list[_SweepEvent], idx: int) -> None:
    """Insert into the queue maintaining ascending event_less order."""
    lo = 0
    hi = len(queue)
    while lo < hi:
        mid = (lo + hi) // 2
        if _event_less(events, queue[mid], idx):
            lo = mid + 1
        else:
            hi = mid
    queue.insert(lo, idx)


# ---------------------------------------------------------------------------
# Intersection detection
# ---------------------------------------------------------------------------


def _find_intersection(a1: Point, a2: Point, b1: Point, b2: Point):
    """Returns ('none', None), ('point', p), or ('overlap', None)."""
    dx_a = a2[0] - a1[0]
    dy_a = a2[1] - a1[1]
    dx_b = b2[0] - b1[0]
    dy_b = b2[1] - b1[1]
    denom = dx_a * dy_b - dy_a * dx_b
    if abs(denom) < 1e-12:
        return ("overlap", None)
    dx_ab = a1[0] - b1[0]
    dy_ab = a1[1] - b1[1]
    s = (dx_b * dy_ab - dy_b * dx_ab) / denom
    t = (dx_a * dy_ab - dy_a * dx_ab) / denom
    eps = 1e-9
    if s < -eps or s > 1.0 + eps or t < -eps or t > 1.0 + eps:
        return ("none", None)
    if s < 0.0:
        s = 0.0
    elif s > 1.0:
        s = 1.0
    return ("point", (a1[0] + s * dx_a, a1[1] + s * dy_a))


def _possible_intersection(
    events: list[_SweepEvent], queue: list[int], e1: int, e2: int, op: _Op
) -> None:
    if events[e1].polygon == events[e2].polygon:
        return
    a1 = events[e1].point
    a2 = events[events[e1].other_event].point
    b1 = events[e2].point
    b2 = events[events[e2].other_event].point
    kind, p = _find_intersection(a1, a2, b1, b2)
    if kind == "none":
        return
    if kind == "point":
        if not _points_eq(p, a1) and not _points_eq(p, a2):
            _divide_segment(events, queue, e1, p)
        if not _points_eq(p, b1) and not _points_eq(p, b2):
            _divide_segment(events, queue, e2, p)
    else:  # overlap
        _handle_collinear(events, queue, e1, e2, op)


# ---------------------------------------------------------------------------
# Collinear handling
# ---------------------------------------------------------------------------


def _handle_collinear(
    events: list[_SweepEvent], queue: list[int], e1: int, e2: int, op: _Op
) -> None:
    ev1 = events[e1]
    ev2 = events[e2]
    e1r = ev1.other_event
    e2r = ev2.other_event
    p1l = ev1.point
    p1r = events[e1r].point
    p2l = ev2.point
    p2r = events[e2r].point

    # Re-check true collinearity
    if (abs(_signed_area(p1l, p1r, p2l)) > 1e-9
            or abs(_signed_area(p1l, p1r, p2r)) > 1e-9):
        return

    # Overlap extent on dominant axis
    dx = abs(p1r[0] - p1l[0])
    dy = abs(p1r[1] - p1l[1])

    def proj(p: Point) -> float:
        return p[0] if dx >= dy else p[1]

    s1_lo = min(proj(p1l), proj(p1r))
    s1_hi = max(proj(p1l), proj(p1r))
    s2_lo = min(proj(p2l), proj(p2r))
    s2_hi = max(proj(p2l), proj(p2r))
    lo = max(s1_lo, s2_lo)
    hi = min(s1_hi, s2_hi)
    if hi - lo <= 1e-9:
        return

    left_coincide = _points_eq(p1l, p2l)
    right_coincide = _points_eq(p1r, p2r)

    same_dir = ev1.in_out == ev2.in_out
    kept_type = _EdgeType.SAME_TRANSITION if same_dir else _EdgeType.DIFFERENT_TRANSITION

    if left_coincide and right_coincide:
        # Case A — identical edges
        ev1.edge_type = _EdgeType.NON_CONTRIBUTING
        ev2.edge_type = kept_type
        ev1.in_result = _edge_in_result(ev1, op)
        ev2.in_result = _edge_in_result(ev2, op)
        return

    if left_coincide:
        # Case B — shared left endpoint
        if _event_less(events, e1r, e2r):
            longer_left, shorter_right_pt = e2, p1r
        else:
            longer_left, shorter_right_pt = e1, p2r
        longer_left_pt = events[longer_left].point
        longer_right_pt = events[events[longer_left].other_event].point
        shorter_right_pt = project_onto_segment(longer_left_pt, longer_right_pt, shorter_right_pt)
        if longer_left == e1:
            ev1.edge_type = _EdgeType.NON_CONTRIBUTING
            ev2.edge_type = kept_type
        else:
            ev1.edge_type = kept_type
            ev2.edge_type = _EdgeType.NON_CONTRIBUTING
        ev1.in_result = _edge_in_result(ev1, op)
        ev2.in_result = _edge_in_result(ev2, op)
        _divide_segment(events, queue, longer_left, shorter_right_pt)
        return

    if right_coincide:
        # Case C — shared right endpoint
        if _event_less(events, e1, e2):
            longer_left, later_left_pt = e1, p2l
        else:
            longer_left, later_left_pt = e2, p1l
        longer_left_pt = events[longer_left].point
        longer_right_pt = events[events[longer_left].other_event].point
        later_left_pt = project_onto_segment(longer_left_pt, longer_right_pt, later_left_pt)
        _, nr_idx = _divide_segment(events, queue, longer_left, later_left_pt)
        events[nr_idx].edge_type = _EdgeType.NON_CONTRIBUTING
        shorter = e2 if longer_left == e1 else e1
        events[shorter].edge_type = kept_type
        events[nr_idx].in_result = _edge_in_result(events[nr_idx], op)
        events[shorter].in_result = _edge_in_result(events[shorter], op)
        return

    # Case D — neither coincide. Sort the four endpoints by event order.
    def cmp_ev(a: int, b: int) -> int:
        if _event_less(events, a, b):
            return -1
        if _event_less(events, b, a):
            return 1
        return 0

    endpoints = sorted([e1, e1r, e2, e2r], key=cmp_to_key(cmp_ev))
    first, second, third, fourth = endpoints
    first_ev = events[first]
    if first_ev.other_event == fourth:
        # Case D1 — containment
        first_pt = first_ev.point
        first_other_pt = events[first_ev.other_event].point
        mid_left = project_onto_segment(first_pt, first_other_pt, events[second].point)
        mid_right = project_onto_segment(first_pt, first_other_pt, events[third].point)
        _, nr1 = _divide_segment(events, queue, first, mid_left)
        _, _ = _divide_segment(events, queue, nr1, mid_right)
        events[nr1].edge_type = _EdgeType.NON_CONTRIBUTING
        shorter = e2 if first == e1 else e1
        events[shorter].edge_type = kept_type
        events[nr1].in_result = _edge_in_result(events[nr1], op)
        events[shorter].in_result = _edge_in_result(events[shorter], op)
    else:
        # Case D2 — partial overlap
        first_pt = first_ev.point
        first_other_pt = events[first_ev.other_event].point
        split_a = project_onto_segment(first_pt, first_other_pt, events[second].point)
        other_left = events[fourth].other_event
        other_left_pt = events[other_left].point
        other_right_pt = events[events[other_left].other_event].point
        split_b = project_onto_segment(other_left_pt, other_right_pt, events[third].point)
        _, nr1 = _divide_segment(events, queue, first, split_a)
        _, _ = _divide_segment(events, queue, other_left, split_b)
        events[nr1].edge_type = _EdgeType.NON_CONTRIBUTING
        kept_left = e2 if first == e1 else e1
        events[kept_left].edge_type = kept_type
        events[nr1].in_result = _edge_in_result(events[nr1], op)
        events[kept_left].in_result = _edge_in_result(events[kept_left], op)


# ---------------------------------------------------------------------------
# Segment subdivision
# ---------------------------------------------------------------------------


def _divide_segment(
    events: list[_SweepEvent], queue: list[int], edge_left_idx: int, p: Point
) -> tuple[int, int]:
    edge_left = events[edge_left_idx]
    edge_right_idx = edge_left.other_event
    polygon = edge_left.polygon

    l_idx = len(events)
    nr_idx = l_idx + 1
    l_event = _SweepEvent(point=p, is_left=False, polygon=polygon, other_event=edge_left_idx)
    nr_event = _SweepEvent(point=p, is_left=True, polygon=polygon, other_event=edge_right_idx)
    events.append(l_event)
    events.append(nr_event)

    edge_left.other_event = l_idx
    events[edge_right_idx].other_event = nr_idx

    _queue_push(queue, events, l_idx)
    _queue_push(queue, events, nr_idx)
    return (l_idx, nr_idx)


# ---------------------------------------------------------------------------
# Field computation
# ---------------------------------------------------------------------------


def _compute_fields(events: list[_SweepEvent], status: list[int], pos: int) -> None:
    idx = status[pos]
    ev = events[idx]
    if pos == 0:
        ev.in_out = False
        ev.other_in_out = True
        return
    prev_idx = status[pos - 1]
    prev = events[prev_idx]
    if ev.polygon == prev.polygon:
        ev.in_out = not prev.in_out
        ev.other_in_out = prev.other_in_out
    else:
        prev_other = events[prev.other_event]
        prev_vertical = prev.point[0] == prev_other.point[0]
        ev.in_out = not prev.other_in_out
        ev.other_in_out = (not prev.in_out) if prev_vertical else prev.in_out
    if prev.in_result:
        ev.prev_in_result = prev_idx
    else:
        ev.prev_in_result = prev.prev_in_result


# ---------------------------------------------------------------------------
# Connection step
# ---------------------------------------------------------------------------


def _connect_edges(events: list[_SweepEvent], order: list[int]) -> PolygonSet:
    in_result: list[int] = []
    for idx in order:
        e = events[idx]
        is_in = e.in_result if e.is_left else events[e.other_event].in_result
        if is_in:
            in_result.append(idx)

    pos_in_result: dict[int, int] = {idx: i for i, idx in enumerate(in_result)}
    visited = [False] * len(in_result)
    result: PolygonSet = []

    for start in range(len(in_result)):
        if visited[start]:
            continue
        ring: Ring = []
        i = start
        while True:
            visited[i] = True
            cur_event = in_result[i]
            ring.append(events[cur_event].point)
            partner = events[cur_event].other_event
            partner_pos = pos_in_result.get(partner)
            if partner_pos is None:
                break
            visited[partner_pos] = True
            partner_point = events[partner].point
            nxt: int | None = None
            j = partner_pos + 1
            while j < len(in_result):
                if not visited[j]:
                    if events[in_result[j]].point == partner_point:
                        nxt = j
                        break
                    if events[in_result[j]].point[0] > partner_point[0]:
                        break
                j += 1
            if nxt is None:
                k = partner_pos
                while k > 0:
                    k -= 1
                    if not visited[k]:
                        if events[in_result[k]].point == partner_point:
                            nxt = k
                            break
                        if events[in_result[k]].point[0] < partner_point[0]:
                            break
            if nxt is None:
                break
            i = nxt
            if i == start:
                break
        if len(ring) >= 3:
            result.append(ring)

    return result


# Wire the normalizer into _normalize_hook by importing the module after
# all top-level definitions in this file are in place. This avoids the
# circular import: boolean_normalize.py imports from this module.
from algorithms import boolean_normalize as _bn  # noqa: F401, E402
