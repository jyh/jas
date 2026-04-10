"""Planar graph extraction.

Turn a collection of polylines (open or closed) into a planar
subdivision and enumerate the bounded faces. Port of
jas_dioxus/src/algorithms/planar.rs.

Pipeline:
    1. Collect all line segments from all input polylines.
    2. Find every segment-segment intersection (naive O(n²)).
    3. Snap nearby intersection points and shared endpoints into
       single vertices.
    4. Prune vertices of degree 1 iteratively.
    5. Build a DCEL (doubly connected edge list).
    6. Traverse half-edge cycles to enumerate faces.
    7. Drop the unbounded outer face.
    8. Compute face containment to mark hole relationships.

Deferred (mirrors boolean_normalize): Bezier curves (caller flattens),
T-junctions, collinear overlap, incremental rebuild, spatial
acceleration.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field


# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

Point = tuple[float, float]
Polyline = list[Point]

# Indices into PlanarGraph arrays. Plain ints; the type aliases are
# documentation only, mirroring the newtype distinction in the Rust port.
VertexId = int
HalfEdgeId = int
FaceId = int


@dataclass
class Vertex:
    pos: Point
    outgoing: HalfEdgeId


@dataclass
class HalfEdge:
    """Directed half-edge.

    We deliberately do not store a ``face`` field; the cycle
    structure already carries that information, and the unbounded
    face is dropped before return so there is no sentinel to invent.
    """
    origin: VertexId
    twin: HalfEdgeId
    next: HalfEdgeId
    prev: HalfEdgeId


@dataclass
class Face:
    boundary: HalfEdgeId
    holes: list[HalfEdgeId] = field(default_factory=list)
    parent: FaceId | None = None
    depth: int = 0


@dataclass
class PlanarGraph:
    vertices: list[Vertex] = field(default_factory=list)
    half_edges: list[HalfEdge] = field(default_factory=list)
    faces: list[Face] = field(default_factory=list)

    def face_count(self) -> int:
        return len(self.faces)

    def top_level_faces(self) -> list[FaceId]:
        return [i for i, f in enumerate(self.faces) if f.depth == 1]

    def face_outer_area(self, face: FaceId) -> float:
        return abs(self._cycle_signed_area(self.faces[face].boundary))

    def face_net_area(self, face: FaceId) -> float:
        outer = self.face_outer_area(face)
        holes_sum = sum(
            abs(self._cycle_signed_area(h))
            for h in self.faces[face].holes
        )
        return outer - holes_sum

    def hit_test(self, point: Point) -> FaceId | None:
        """Deepest face containing the point. A click in a hole
        returns the hole face, not its parent. Naive O(F) for now.
        """
        best: FaceId | None = None
        best_depth = 0
        for fi, face in enumerate(self.faces):
            poly = self._cycle_polygon(face.boundary)
            if _winding_number(poly, point) != 0 and face.depth > best_depth:
                best_depth = face.depth
                best = fi
        return best

    # ----- internal cycle helpers -----

    def _cycle_signed_area(self, start: HalfEdgeId) -> float:
        s = 0.0
        e = start
        while True:
            ax, ay = self.vertices[self.half_edges[e].origin].pos
            ne = self.half_edges[e].next
            bx, by = self.vertices[self.half_edges[ne].origin].pos
            s += ax * by - bx * ay
            e = ne
            if e == start:
                break
        return s / 2.0

    def _cycle_polygon(self, start: HalfEdgeId) -> list[Point]:
        out: list[Point] = []
        e = start
        while True:
            out.append(self.vertices[self.half_edges[e].origin].pos)
            e = self.half_edges[e].next
            if e == start:
                break
        return out


# ---------------------------------------------------------------------------
# Numerical helpers
# ---------------------------------------------------------------------------

# Vertex coincidence and zero-length tolerance, in input units.
_VERT_EPS = 1e-9

# Parameter-band epsilon; matches boolean_normalize.
_PARAM_EPS = 1e-9

# Determinant tolerance for parallel-segment rejection.
_DENOM_EPS = 1e-12


def _dist(a: Point, b: Point) -> float:
    dx = a[0] - b[0]
    dy = a[1] - b[1]
    return math.sqrt(dx * dx + dy * dy)


def _add_or_find_vertex(verts: list[Point], pt: Point) -> int:
    """Linear-search vertex dedup."""
    for i, v in enumerate(verts):
        if _dist(v, pt) < _VERT_EPS:
            return i
    verts.append(pt)
    return len(verts) - 1


def _intersect_proper(a1: Point, a2: Point, b1: Point, b2: Point):
    """Parametric line-line intersection requiring a strictly
    interior crossing on both segments. Mirrors
    boolean_normalize._segment_proper_intersection.

    Returns ``(point, s, t)`` or ``None``.
    """
    dxa = a2[0] - a1[0]
    dya = a2[1] - a1[1]
    dxb = b2[0] - b1[0]
    dyb = b2[1] - b1[1]
    denom = dxa * dyb - dya * dxb
    if abs(denom) < _DENOM_EPS:
        return None
    dxab = a1[0] - b1[0]
    dyab = a1[1] - b1[1]
    s = (dxb * dyab - dyb * dxab) / denom
    t = (dxa * dyab - dya * dxab) / denom
    if s <= _PARAM_EPS or s >= 1.0 - _PARAM_EPS \
            or t <= _PARAM_EPS or t >= 1.0 - _PARAM_EPS:
        return None
    return ((a1[0] + s * dxa, a1[1] + s * dya), s, t)


def _winding_number(poly: list[Point], point: Point) -> int:
    """Half-open upward/downward classification to avoid
    double-counting at vertices."""
    n = len(poly)
    if n < 3:
        return 0
    px, py = point
    w = 0
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
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


def _sample_inside(poly: list[Point]) -> Point:
    """Pick a point strictly inside the polygon traced by ``poly``,
    regardless of CW/CCW orientation. Mirrors
    boolean_normalize._sample_inside_simple_ring.
    """
    assert len(poly) >= 3
    x0, y0 = poly[0]
    x1, y1 = poly[1]
    mx = (x0 + x1) / 2.0
    my = (y0 + y1) / 2.0
    dx = x1 - x0
    dy = y1 - y0
    length = math.sqrt(dx * dx + dy * dy)
    if length == 0.0:
        x2, y2 = poly[2]
        return ((x0 + x1 + x2) / 3.0, (y0 + y1 + y2) / 3.0)
    nx = -dy / length
    ny = dx / length
    offset = length * 1e-4
    left = (mx + nx * offset, my + ny * offset)
    right = (mx - nx * offset, my - ny * offset)
    return left if _winding_number(poly, left) != 0 else right


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------


def build(polylines: list[Polyline]) -> PlanarGraph:
    """Build a planar graph from a set of polylines."""
    # ----- 1. Collect non-degenerate segments -----
    segments: list[tuple[Point, Point]] = []
    for poly in polylines:
        if len(poly) < 2:
            continue
        for i in range(len(poly) - 1):
            a = poly[i]
            b = poly[i + 1]
            if _dist(a, b) > _VERT_EPS:
                segments.append((a, b))
    if not segments:
        return PlanarGraph()

    # ----- 2-3. Per-segment vertex lists with snap-merging -----
    vert_pts: list[Point] = []
    seg_params: list[list[tuple[float, int]]] = [[] for _ in segments]
    for si, (a, b) in enumerate(segments):
        va = _add_or_find_vertex(vert_pts, a)
        vb = _add_or_find_vertex(vert_pts, b)
        seg_params[si].append((0.0, va))
        seg_params[si].append((1.0, vb))

    # ----- 4. Naive O(n²) proper-interior intersection -----
    n_seg = len(segments)
    for i in range(n_seg):
        for j in range(i + 1, n_seg):
            a1, a2 = segments[i]
            b1, b2 = segments[j]
            hit = _intersect_proper(a1, a2, b1, b2)
            if hit is None:
                continue
            p, s, t = hit
            v = _add_or_find_vertex(vert_pts, p)
            seg_params[i].append((s, v))
            seg_params[j].append((t, v))

    # ----- 5. Sort each segment's vertex list, drop snapped
    # duplicates, emit atomic edges. -----
    edge_set: set[tuple[int, int]] = set()
    for params in seg_params:
        params.sort(key=lambda pv: pv[0])
        chain: list[int] = []
        prev: int | None = None
        for _, v in params:
            if v != prev:
                chain.append(v)
                prev = v
        for k in range(len(chain) - 1):
            u = chain[k]
            v = chain[k + 1]
            if u != v:
                e = (u, v) if u < v else (v, u)
                edge_set.add(e)
    edges: list[tuple[int, int]] = sorted(edge_set)

    # ----- 6. Iteratively prune degree-1 vertices -----
    while edges:
        deg = [0] * len(vert_pts)
        for u, v in edges:
            deg[u] += 1
            deg[v] += 1
        before = len(edges)
        edges = [(u, v) for (u, v) in edges if deg[u] >= 2 and deg[v] >= 2]
        if len(edges) == before:
            break
    if not edges:
        return PlanarGraph()

    # Compact the vertex list to drop pruned-away vertices.
    used = [False] * len(vert_pts)
    for u, v in edges:
        used[u] = True
        used[v] = True
    new_id = [-1] * len(vert_pts)
    compacted: list[Point] = []
    for i, p in enumerate(vert_pts):
        if used[i]:
            new_id[i] = len(compacted)
            compacted.append(p)
    edges = [(new_id[u], new_id[v]) for (u, v) in edges]
    vert_pts = compacted
    n_v = len(vert_pts)

    # ----- 7. Build half-edges and DCEL links -----
    n_he = len(edges) * 2
    he_origin = [0] * n_he
    he_twin = [0] * n_he
    for k, (u, v) in enumerate(edges):
        i = k * 2
        he_origin[i] = u
        he_origin[i + 1] = v
        he_twin[i] = i + 1
        he_twin[i + 1] = i

    # Per-vertex outgoing half-edges, sorted CCW by angle.
    outgoing_at: list[list[int]] = [[] for _ in range(n_v)]
    for i in range(n_he):
        outgoing_at[he_origin[i]].append(i)
    for v_idx in range(n_v):
        ox, oy = vert_pts[v_idx]

        def angle_key(e: int, ox: float = ox, oy: float = oy) -> float:
            tx, ty = vert_pts[he_origin[he_twin[e]]]
            return math.atan2(ty - oy, tx - ox)

        outgoing_at[v_idx].sort(key=angle_key)

    # For each half-edge `e` ending at vertex `v`:
    #   next(e) = the outgoing half-edge from `v` immediately CW
    #             from `e.twin` in the angular order at `v`.
    he_next = [0] * n_he
    he_prev = [0] * n_he
    for e in range(n_he):
        etwin = he_twin[e]
        v = he_origin[etwin]
        lst = outgoing_at[v]
        idx = lst.index(etwin)
        cw_idx = (idx - 1) % len(lst)
        ne = lst[cw_idx]
        he_next[e] = ne
        he_prev[ne] = e

    # ----- 8. Enumerate half-edge cycles -----
    he_cycle = [-1] * n_he
    cycles: list[list[int]] = []
    for start in range(n_he):
        if he_cycle[start] != -1:
            continue
        cyc: list[int] = []
        e = start
        while True:
            he_cycle[e] = len(cycles)
            cyc.append(e)
            e = he_next[e]
            if e == start:
                break
        cycles.append(cyc)

    # ----- 9. Signed area; classify positive vs negative -----
    areas: list[float] = []
    cycle_polys: list[list[Point]] = []
    for cyc in cycles:
        poly = [vert_pts[he_origin[e]] for e in cyc]
        cycle_polys.append(poly)
        s = 0.0
        n = len(poly)
        for i in range(n):
            ax, ay = poly[i]
            bx, by = poly[(i + 1) % n]
            s += ax * by - bx * ay
        areas.append(s / 2.0)

    pos_cycles = [i for i in range(len(cycles)) if areas[i] > 0.0]
    neg_cycles = [i for i in range(len(cycles)) if areas[i] < 0.0]
    n_faces = len(pos_cycles)

    # ----- 11. Parent of each face -----
    parents: list[int | None] = [None] * n_faces
    for fi in range(n_faces):
        cyc_f = pos_cycles[fi]
        area_f = areas[cyc_f]
        sample = _sample_inside(cycle_polys[cyc_f])
        best: int | None = None
        best_area = math.inf
        for gi in range(n_faces):
            if gi == fi:
                continue
            cyc_g = pos_cycles[gi]
            area_g = areas[cyc_g]
            if area_g <= area_f:
                continue
            if _winding_number(cycle_polys[cyc_g], sample) != 0 \
                    and area_g < best_area:
                best_area = area_g
                best = gi
        parents[fi] = best

    # ----- 12. Depth via topological propagation -----
    depth = [0] * n_faces
    changed = True
    while changed:
        changed = False
        for f in range(n_faces):
            if depth[f] != 0:
                continue
            p = parents[f]
            if p is None:
                depth[f] = 1
                changed = True
            elif depth[p] != 0:
                depth[f] = depth[p] + 1
                changed = True

    # ----- 13. Hole assignment -----
    face_holes: list[list[int]] = [[] for _ in range(n_faces)]
    for neg_i in neg_cycles:
        area_neg = abs(areas[neg_i])
        sample = _sample_inside(cycle_polys[neg_i])
        best = None
        best_area = math.inf
        for fi in range(n_faces):
            cyc_g = pos_cycles[fi]
            area_f = areas[cyc_g]
            if area_f <= area_neg:
                continue
            if _winding_number(cycle_polys[cyc_g], sample) != 0 \
                    and area_f < best_area:
                best_area = area_f
                best = fi
        if best is not None:
            face_holes[best].append(neg_i)
        # else: part of the unbounded face — drop.

    # ----- Materialize public structures -----
    vertices = [
        Vertex(pos=vert_pts[i],
               outgoing=outgoing_at[i][0] if outgoing_at[i] else 0)
        for i in range(n_v)
    ]
    half_edges = [
        HalfEdge(
            origin=he_origin[e],
            twin=he_twin[e],
            next=he_next[e],
            prev=he_prev[e],
        )
        for e in range(n_he)
    ]
    faces = []
    for fi in range(n_faces):
        outer_cycle = pos_cycles[fi]
        boundary = cycles[outer_cycle][0]
        holes = [cycles[c][0] for c in face_holes[fi]]
        faces.append(Face(
            boundary=boundary,
            holes=holes,
            parent=parents[fi],
            depth=depth[fi],
        ))

    return PlanarGraph(vertices=vertices, half_edges=half_edges, faces=faces)
