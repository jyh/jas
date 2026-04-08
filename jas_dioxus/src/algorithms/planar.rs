//! Planar graph extraction: turn a collection of polylines (open or
//! closed) into a planar subdivision and enumerate the bounded faces.
//!
// Tested but not yet wired into the document model.
#![allow(dead_code)]
//!
//! # What this is for
//!
//! Sketches in this app are sets of overlapping paths. The user
//! intuitively sees "shapes" wherever paths cross to enclose a region:
//! a circle bisected by a line is two half-disks; two overlapping
//! rectangles are three regions. This module extracts those regions
//! algorithmically so the rest of the app can hit-test, fill, and
//! select them as first-class objects.
//!
//! # Input assumptions
//!
//! Input is a set of **polylines**. Bézier flattening happens
//! upstream (same as the boolean operations pipeline). Each polyline
//! is either open (a stroke with two free ends) or closed (a loop).
//! No constraints on self-intersection or inter-path intersection.
//!
//! # Pipeline
//!
//!   1. Collect all line segments from all input polylines.
//!   2. Find every segment-segment intersection (naive O(n²) for
//!      now; Bentley-Ottmann later if profiling demands it).
//!   3. Snap nearby intersection points and shared endpoints into
//!      single vertices, using the same epsilon strategy as
//!      [`crate::algorithms::boolean_normalize`].
//!   4. **Prune** vertices of degree 1 iteratively. Any edge with a
//!      degree-1 endpoint can't bound a face, so it (and any pendant
//!      tree it belongs to) is removed before topology construction.
//!   5. Build a DCEL (doubly connected edge list) from what remains.
//!   6. Traverse half-edge cycles to enumerate faces.
//!   7. Identify and drop the unbounded outer face (signed area < 0
//!      under the CCW-interior convention).
//!   8. Compute face containment to mark hole relationships: each
//!      bounded face's parent is the smallest enclosing face. Even
//!      depth = outer region; odd depth = hole inside its parent.
//!
//! # Deferred / not yet handled
//!
//!   - Bézier curves (caller flattens to polylines first).
//!   - T-junctions where one polyline's interior passes exactly
//!     through another polyline's vertex. Same limitation as
//!     `boolean_normalize`; documented as `#[ignore]` tests.
//!   - Collinear segment overlap (two polylines retracing the same
//!     line). Same.
//!   - Incremental rebuild on stroke add/remove. Full rebuild only.
//!   - Spatial acceleration (R-tree / BVH) for hit testing.

use std::collections::BTreeSet;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// A 2D point.
pub type Point = (f64, f64);

/// A polyline: an ordered list of points. Open if the first and last
/// points differ; closed if they coincide (or if the caller marks it
/// closed by repeating the start point).
pub type Polyline = Vec<Point>;

/// Index into [`PlanarGraph::vertices`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct VertexId(pub usize);

/// Index into [`PlanarGraph::half_edges`]. Half-edges come in twin
/// pairs; for any half-edge `e`, `e.twin` is the half-edge running
/// the opposite direction along the same underlying segment.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct HalfEdgeId(pub usize);

/// Index into [`PlanarGraph::faces`]. Face 0 is conventionally the
/// unbounded outer face if it is retained; this module drops it
/// before returning, so all `FaceId`s in a returned graph refer to
/// bounded faces.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct FaceId(pub usize);

/// A vertex in the planar subdivision.
#[derive(Debug, Clone)]
pub struct Vertex {
    pub pos: Point,
    /// One of the half-edges originating at this vertex. The full
    /// star can be walked via `twin(prev(outgoing))`.
    pub outgoing: HalfEdgeId,
}

/// A directed half-edge. Twin pairs share the same underlying
/// undirected edge.
///
/// We deliberately do **not** store a `face` field. Half-edges in
/// our cycles either bound a [`Face`] (in which case the face's
/// `boundary` or one of its `holes` reaches them via the `next`
/// chain) or belong to the unbounded outer face (which is dropped).
/// Storing `face` per half-edge would force us to invent a sentinel
/// for the unbounded case; the cycle structure already carries that
/// information for free.
#[derive(Debug, Clone)]
pub struct HalfEdge {
    pub origin: VertexId,
    pub twin: HalfEdgeId,
    pub next: HalfEdgeId,
    pub prev: HalfEdgeId,
}

/// A bounded face in the subdivision.
///
/// A face has one **outer boundary** (the half-edge cycle that
/// surrounds its interior, oriented CCW) and zero or more **hole
/// boundaries** (each a half-edge cycle around an enclosed face,
/// oriented CW from this face's perspective).
///
/// The `parent` link points to the immediately enclosing face, or
/// `None` if this face is at the top level (its only "container" is
/// the dropped outer face). Containment depth determines whether
/// the face is an "outer" region (even depth) or a "hole" (odd
/// depth) — but both are returned as full Face entries; it's up to
/// the renderer to decide what to fill.
#[derive(Debug, Clone)]
pub struct Face {
    /// One half-edge of the outer boundary cycle.
    pub boundary: HalfEdgeId,
    /// One half-edge of each hole boundary cycle. Empty for faces
    /// with no holes.
    pub holes: Vec<HalfEdgeId>,
    /// The smallest face that contains this one, if any.
    pub parent: Option<FaceId>,
    /// Containment depth from the (dropped) outer face. Top-level
    /// faces have depth 1; their holes have depth 2; faces inside
    /// those holes have depth 3; and so on.
    pub depth: usize,
}

/// A complete planar subdivision: vertices, half-edges, and faces.
#[derive(Debug, Clone, Default)]
pub struct PlanarGraph {
    pub vertices: Vec<Vertex>,
    pub half_edges: Vec<HalfEdge>,
    pub faces: Vec<Face>,
}

impl PlanarGraph {
    /// Build a planar graph from a set of polylines. See the
    /// module-level docs for the full pipeline.
    pub fn build(polylines: &[Polyline]) -> Self {
        // ----- 1. Collect non-degenerate segments -----
        let mut segments: Vec<(Point, Point)> = Vec::new();
        for poly in polylines {
            if poly.len() < 2 {
                continue;
            }
            for w in poly.windows(2) {
                let (a, b) = (w[0], w[1]);
                if dist(a, b) > VERT_EPS {
                    segments.push((a, b));
                }
            }
        }
        if segments.is_empty() {
            return PlanarGraph::default();
        }

        // ----- 2-3. Per-segment vertex lists with snap-merging -----
        // For each segment, a list of (parameter, vertex_id) pairs:
        // its two endpoints (params 0 and 1) plus any interior
        // intersection points discovered in step 4.
        let mut vert_pts: Vec<Point> = Vec::new();
        let mut seg_params: Vec<Vec<(f64, usize)>> =
            vec![Vec::new(); segments.len()];
        for (si, &(a, b)) in segments.iter().enumerate() {
            let va = add_or_find_vertex(&mut vert_pts, a);
            let vb = add_or_find_vertex(&mut vert_pts, b);
            seg_params[si].push((0.0, va));
            seg_params[si].push((1.0, vb));
        }

        // ----- 4. Naive O(n²) proper-interior intersection -----
        // Same epsilon strategy as boolean_normalize: strict (0,1)
        // for both parameters. Endpoint coincidences are already
        // captured by step 2-3's vertex snap.
        for i in 0..segments.len() {
            for j in (i + 1)..segments.len() {
                let (a1, a2) = segments[i];
                let (b1, b2) = segments[j];
                if let Some((p, s, t)) = intersect_proper(a1, a2, b1, b2)
                {
                    let v = add_or_find_vertex(&mut vert_pts, p);
                    seg_params[i].push((s, v));
                    seg_params[j].push((t, v));
                }
            }
        }

        // ----- 5. Sort each segment's vertex list by parameter and
        // emit atomic edges between consecutive distinct vertices.
        let mut edge_set: BTreeSet<(usize, usize)> = BTreeSet::new();
        for params in seg_params.iter_mut() {
            params.sort_by(|a, b| {
                a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal)
            });
            // Drop consecutive duplicates that snapped to the same
            // vertex (e.g., a zero-length sub-segment between two
            // intersections that merged).
            let mut prev: Option<usize> = None;
            let mut chain: Vec<usize> = Vec::new();
            for &(_, v) in params.iter() {
                if Some(v) != prev {
                    chain.push(v);
                    prev = Some(v);
                }
            }
            for w in chain.windows(2) {
                let (u, v) = (w[0], w[1]);
                if u != v {
                    let e = if u < v { (u, v) } else { (v, u) };
                    edge_set.insert(e);
                }
            }
        }
        let mut edges: Vec<(usize, usize)> = edge_set.into_iter().collect();

        // ----- 6. Iteratively prune degree-1 vertices -----
        // Any edge with a degree-1 endpoint can't bound a face;
        // removing it may drop another vertex to degree 1, so loop
        // until fixed point. Whole pendant trees disappear in a few
        // rounds.
        loop {
            if edges.is_empty() {
                break;
            }
            let mut deg = vec![0usize; vert_pts.len()];
            for &(u, v) in &edges {
                deg[u] += 1;
                deg[v] += 1;
            }
            let before = edges.len();
            edges.retain(|&(u, v)| deg[u] >= 2 && deg[v] >= 2);
            if edges.len() == before {
                break;
            }
        }
        if edges.is_empty() {
            return PlanarGraph::default();
        }

        // Compact the vertex list to drop pruned-away vertices, so
        // index 0..n-1 in the returned graph all refer to live
        // vertices.
        let mut used = vec![false; vert_pts.len()];
        for &(u, v) in &edges {
            used[u] = true;
            used[v] = true;
        }
        let mut new_id = vec![usize::MAX; vert_pts.len()];
        let mut compacted: Vec<Point> = Vec::new();
        for (i, &p) in vert_pts.iter().enumerate() {
            if used[i] {
                new_id[i] = compacted.len();
                compacted.push(p);
            }
        }
        let edges: Vec<(usize, usize)> = edges
            .into_iter()
            .map(|(u, v)| (new_id[u], new_id[v]))
            .collect();
        let vert_pts = compacted;

        // ----- 7. Build half-edges and DCEL links -----
        let n_he = edges.len() * 2;
        let mut he_origin = vec![0usize; n_he];
        let mut he_twin = vec![0usize; n_he];
        for (k, &(u, v)) in edges.iter().enumerate() {
            let i = k * 2;
            he_origin[i] = u;
            he_origin[i + 1] = v;
            he_twin[i] = i + 1;
            he_twin[i + 1] = i;
        }

        // Per-vertex outgoing half-edges, sorted CCW by angle.
        let mut outgoing_at: Vec<Vec<usize>> =
            vec![Vec::new(); vert_pts.len()];
        for i in 0..n_he {
            outgoing_at[he_origin[i]].push(i);
        }
        for (v_idx, list) in outgoing_at.iter_mut().enumerate() {
            let origin = vert_pts[v_idx];
            list.sort_by(|&a, &b| {
                let ta = vert_pts[he_origin[he_twin[a]]];
                let tb = vert_pts[he_origin[he_twin[b]]];
                let aa = (ta.1 - origin.1).atan2(ta.0 - origin.0);
                let ab = (tb.1 - origin.1).atan2(tb.0 - origin.0);
                aa.partial_cmp(&ab)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
        }

        // For each half-edge `e` ending at vertex `v`:
        //
        //   next(e) = the outgoing half-edge from `v` that is
        //             immediately CW from `e.twin` in the angular
        //             ordering at `v`.
        //
        // (Sorted CCW means previous-in-list = CW neighbor.) This
        // is the standard "leftmost turn" rule for tracing a face
        // boundary with the face on the left.
        let mut he_next = vec![0usize; n_he];
        let mut he_prev = vec![0usize; n_he];
        for e in 0..n_he {
            let etwin = he_twin[e];
            let v = he_origin[etwin];
            let list = &outgoing_at[v];
            let idx = list.iter().position(|&x| x == etwin).unwrap();
            let cw_idx = (idx + list.len() - 1) % list.len();
            let next_e = list[cw_idx];
            he_next[e] = next_e;
            he_prev[next_e] = e;
        }

        // ----- 8. Enumerate half-edge cycles -----
        let mut he_cycle: Vec<isize> = vec![-1; n_he];
        let mut cycles: Vec<Vec<usize>> = Vec::new();
        for start in 0..n_he {
            if he_cycle[start] != -1 {
                continue;
            }
            let mut cyc = Vec::new();
            let mut e = start;
            loop {
                he_cycle[e] = cycles.len() as isize;
                cyc.push(e);
                e = he_next[e];
                if e == start {
                    break;
                }
            }
            cycles.push(cyc);
        }

        // ----- 9. Signed area per cycle; classify positive (bounded
        // face outer boundary) vs negative (hole or unbounded face).
        let mut areas: Vec<f64> = Vec::with_capacity(cycles.len());
        for cyc in &cycles {
            let n = cyc.len();
            let mut sum = 0.0;
            for i in 0..n {
                let a = vert_pts[he_origin[cyc[i]]];
                let b = vert_pts[he_origin[cyc[(i + 1) % n]]];
                sum += a.0 * b.1 - b.0 * a.1;
            }
            areas.push(sum / 2.0);
        }
        let pos_cycles: Vec<usize> = (0..cycles.len())
            .filter(|&i| areas[i] > 0.0)
            .collect();
        let neg_cycles: Vec<usize> = (0..cycles.len())
            .filter(|&i| areas[i] < 0.0)
            .collect();
        let n_faces = pos_cycles.len();

        // Materialize each cycle as a Vec<Point> for containment
        // queries.
        let cycle_polys: Vec<Vec<Point>> = cycles
            .iter()
            .map(|cyc| {
                cyc.iter().map(|&e| vert_pts[he_origin[e]]).collect()
            })
            .collect();

        // ----- 11. Parent of each face: smallest positive cycle
        // strictly enclosing this face's outer boundary.
        let mut parents: Vec<Option<FaceId>> = vec![None; n_faces];
        for fi in 0..n_faces {
            let cyc_f = pos_cycles[fi];
            let area_f = areas[cyc_f];
            let sample = sample_inside(&cycle_polys[cyc_f]);
            let mut best: Option<usize> = None;
            let mut best_area = f64::INFINITY;
            for gi in 0..n_faces {
                if gi == fi {
                    continue;
                }
                let cyc_g = pos_cycles[gi];
                let area_g = areas[cyc_g];
                if area_g <= area_f {
                    continue;
                }
                if winding_number(&cycle_polys[cyc_g], sample) != 0
                    && area_g < best_area
                {
                    best_area = area_g;
                    best = Some(gi);
                }
            }
            parents[fi] = best.map(FaceId);
        }

        // ----- 12. Depth via topological propagation from roots.
        let mut depth = vec![0usize; n_faces];
        loop {
            let mut changed = false;
            for f in 0..n_faces {
                if depth[f] != 0 {
                    continue;
                }
                match parents[f] {
                    None => {
                        depth[f] = 1;
                        changed = true;
                    }
                    Some(FaceId(p)) => {
                        if depth[p] != 0 {
                            depth[f] = depth[p] + 1;
                            changed = true;
                        }
                    }
                }
            }
            if !changed {
                break;
            }
        }

        // ----- 13. Hole assignment for each negative cycle.
        let mut face_holes: Vec<Vec<usize>> = vec![Vec::new(); n_faces];
        for &neg_i in &neg_cycles {
            let area_neg = areas[neg_i].abs();
            let sample = sample_inside(&cycle_polys[neg_i]);
            let mut best: Option<usize> = None;
            let mut best_area = f64::INFINITY;
            for fi in 0..n_faces {
                let cyc_g = pos_cycles[fi];
                let area_f = areas[cyc_g];
                if area_f <= area_neg {
                    continue;
                }
                if winding_number(&cycle_polys[cyc_g], sample) != 0
                    && area_f < best_area
                {
                    best_area = area_f;
                    best = Some(fi);
                }
            }
            if let Some(fi) = best {
                face_holes[fi].push(neg_i);
            }
            // else: this negative cycle is part of the unbounded
            // face — drop it.
        }

        // ----- Materialize public structures -----
        let vertices: Vec<Vertex> = vert_pts
            .iter()
            .enumerate()
            .map(|(i, &p)| Vertex {
                pos: p,
                outgoing: HalfEdgeId(
                    outgoing_at[i].first().copied().unwrap_or(0),
                ),
            })
            .collect();

        let half_edges: Vec<HalfEdge> = (0..n_he)
            .map(|e| HalfEdge {
                origin: VertexId(he_origin[e]),
                twin: HalfEdgeId(he_twin[e]),
                next: HalfEdgeId(he_next[e]),
                prev: HalfEdgeId(he_prev[e]),
            })
            .collect();

        let faces: Vec<Face> = (0..n_faces)
            .map(|fi| {
                let outer_cycle = pos_cycles[fi];
                let boundary = HalfEdgeId(cycles[outer_cycle][0]);
                let holes: Vec<HalfEdgeId> = face_holes[fi]
                    .iter()
                    .map(|&c| HalfEdgeId(cycles[c][0]))
                    .collect();
                Face {
                    boundary,
                    holes,
                    parent: parents[fi],
                    depth: depth[fi],
                }
            })
            .collect();

        PlanarGraph {
            vertices,
            half_edges,
            faces,
        }
    }

    /// Number of bounded faces.
    pub fn face_count(&self) -> usize {
        self.faces.len()
    }

    /// Absolute area of a face's outer boundary, ignoring its holes.
    pub fn face_outer_area(&self, face: FaceId) -> f64 {
        self.cycle_signed_area(self.faces[face.0].boundary).abs()
    }

    /// Net area of a face: outer boundary minus holes.
    pub fn face_net_area(&self, face: FaceId) -> f64 {
        let outer = self.face_outer_area(face);
        let holes_sum: f64 = self.faces[face.0]
            .holes
            .iter()
            .map(|&h| self.cycle_signed_area(h).abs())
            .sum();
        outer - holes_sum
    }

    /// Hit test: return the deepest face containing `point`, or
    /// `None` if `point` lies outside every face.
    ///
    /// "Deepest" means that if `point` falls inside a face that is
    /// itself a hole of an outer face, the inner (deeper) face is
    /// returned. Implementation is naive O(F) for now; an R-tree
    /// over face AABBs is the obvious next step.
    pub fn hit_test(&self, point: Point) -> Option<FaceId> {
        let mut best: Option<FaceId> = None;
        let mut best_depth = 0;
        for fi in 0..self.faces.len() {
            let poly = self.cycle_polygon(self.faces[fi].boundary);
            if winding_number(&poly, point) != 0
                && self.faces[fi].depth > best_depth
            {
                best_depth = self.faces[fi].depth;
                best = Some(FaceId(fi));
            }
        }
        best
    }

    /// All top-level faces (depth 1). Useful for iterating outer
    /// regions without recursing into holes.
    pub fn top_level_faces(&self) -> Vec<FaceId> {
        self.faces
            .iter()
            .enumerate()
            .filter(|(_, f)| f.depth == 1)
            .map(|(i, _)| FaceId(i))
            .collect()
    }

    // ----- internal cycle helpers -----

    /// Walk the half-edge cycle starting at `start` and compute its
    /// signed area (CCW = positive).
    fn cycle_signed_area(&self, start: HalfEdgeId) -> f64 {
        let mut sum = 0.0;
        let mut e = start.0;
        loop {
            let a = self.vertices[self.half_edges[e].origin.0].pos;
            let next_e = self.half_edges[e].next.0;
            let b = self.vertices[self.half_edges[next_e].origin.0].pos;
            sum += a.0 * b.1 - b.0 * a.1;
            e = next_e;
            if e == start.0 {
                break;
            }
        }
        sum / 2.0
    }

    /// Walk the half-edge cycle starting at `start` and return the
    /// vertex positions in cycle order.
    fn cycle_polygon(&self, start: HalfEdgeId) -> Vec<Point> {
        let mut out = Vec::new();
        let mut e = start.0;
        loop {
            out.push(self.vertices[self.half_edges[e].origin.0].pos);
            e = self.half_edges[e].next.0;
            if e == start.0 {
                break;
            }
        }
        out
    }
}

// ---------------------------------------------------------------------------
// Numerical helpers
// ---------------------------------------------------------------------------

/// Vertex coincidence and zero-length tolerance, in input units.
const VERT_EPS: f64 = 1e-9;

/// Parameter-band epsilon for [`intersect_proper`]; matches
/// [`crate::algorithms::boolean_normalize`].
const PARAM_EPS: f64 = 1e-9;

/// Determinant tolerance for parallel-segment rejection in
/// [`intersect_proper`]; matches `boolean_normalize`.
const DENOM_EPS: f64 = 1e-12;

fn dist(a: Point, b: Point) -> f64 {
    let dx = a.0 - b.0;
    let dy = a.1 - b.1;
    (dx * dx + dy * dy).sqrt()
}

/// Linear-search vertex dedup: return the index of an existing
/// vertex within [`VERT_EPS`] of `pt`, or insert and return a new
/// index.
fn add_or_find_vertex(verts: &mut Vec<Point>, pt: Point) -> usize {
    for (i, v) in verts.iter().enumerate() {
        if dist(*v, pt) < VERT_EPS {
            return i;
        }
    }
    verts.push(pt);
    verts.len() - 1
}

/// Parametric line-line intersection requiring a strictly interior
/// crossing on both segments. Mirrors
/// `boolean_normalize::segment_proper_intersection`.
///
/// Returns `(point, s, t)` where `s` is the parameter on the first
/// segment and `t` is the parameter on the second.
fn intersect_proper(
    a1: Point,
    a2: Point,
    b1: Point,
    b2: Point,
) -> Option<(Point, f64, f64)> {
    let dxa = a2.0 - a1.0;
    let dya = a2.1 - a1.1;
    let dxb = b2.0 - b1.0;
    let dyb = b2.1 - b1.1;
    let denom = dxa * dyb - dya * dxb;
    if denom.abs() < DENOM_EPS {
        return None;
    }
    let dxab = a1.0 - b1.0;
    let dyab = a1.1 - b1.1;
    let s = (dxb * dyab - dyb * dxab) / denom;
    let t = (dxa * dyab - dya * dxab) / denom;
    if s <= PARAM_EPS
        || s >= 1.0 - PARAM_EPS
        || t <= PARAM_EPS
        || t >= 1.0 - PARAM_EPS
    {
        return None;
    }
    Some(((a1.0 + s * dxa, a1.1 + s * dya), s, t))
}

/// Winding number of a polygon around a point. Half-open rule on
/// the upward/downward edge classification avoids double-counting
/// when the test ray passes exactly through a polygon vertex.
fn winding_number(poly: &[Point], point: Point) -> i32 {
    let n = poly.len();
    if n < 3 {
        return 0;
    }
    let (px, py) = point;
    let mut w: i32 = 0;
    for i in 0..n {
        let (x1, y1) = poly[i];
        let (x2, y2) = poly[(i + 1) % n];
        let upward = y1 <= py && y2 > py;
        let downward = y2 <= py && y1 > py;
        if !upward && !downward {
            continue;
        }
        let t = (py - y1) / (y2 - y1);
        let x_cross = x1 + t * (x2 - x1);
        if x_cross > px {
            if upward {
                w += 1;
            } else {
                w -= 1;
            }
        }
    }
    w
}

/// Pick a point strictly inside the polygon traced by `poly`,
/// regardless of whether the polygon is wound CW or CCW. Strategy:
/// offset the midpoint of the first edge perpendicular to that edge
/// by a small fraction of its length, choosing whichever side has
/// nonzero winding in the polygon itself. Mirrors the trick used in
/// `boolean_normalize::sample_inside_simple_ring`.
fn sample_inside(poly: &[Point]) -> Point {
    let n = poly.len();
    debug_assert!(n >= 3);
    let (x0, y0) = poly[0];
    let (x1, y1) = poly[1];
    let mx = (x0 + x1) / 2.0;
    let my = (y0 + y1) / 2.0;
    let dx = x1 - x0;
    let dy = y1 - y0;
    let len = (dx * dx + dy * dy).sqrt();
    if len == 0.0 {
        let (x2, y2) = poly[2];
        return ((x0 + x1 + x2) / 3.0, (y0 + y1 + y2) / 3.0);
    }
    let nx = -dy / len;
    let ny = dx / len;
    let offset = len * 1e-4;
    let left = (mx + nx * offset, my + ny * offset);
    let right = (mx - nx * offset, my - ny * offset);
    if winding_number(poly, left) != 0 {
        left
    } else {
        right
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    // Numerical tolerance for area comparisons in tests.
    const AREA_EPS: f64 = 1e-6;

    // ----- helpers -----

    fn closed_square(x: f64, y: f64, side: f64) -> Polyline {
        vec![
            (x, y),
            (x + side, y),
            (x + side, y + side),
            (x, y + side),
            (x, y),
        ]
    }

    fn segment(a: Point, b: Point) -> Polyline {
        vec![a, b]
    }

    /// Sum of `face_net_area` over every top-level face.
    fn total_top_level_area(g: &PlanarGraph) -> f64 {
        g.top_level_faces()
            .into_iter()
            .map(|f| g.face_net_area(f).abs())
            .sum()
    }

    // ----- 1. Two crossing segments -----

    #[test]
    fn two_crossing_segments_have_no_bounded_faces() {
        // A '+' shape: two segments crossing at the origin. Every
        // endpoint is degree 1, so after pruning the entire input
        // disappears.
        let g = PlanarGraph::build(&[
            segment((-1.0, 0.0), (1.0, 0.0)),
            segment((0.0, -1.0), (0.0, 1.0)),
        ]);
        assert_eq!(g.face_count(), 0);
    }

    // ----- 2. Closed square -----

    #[test]
    fn closed_square_is_one_face() {
        let g = PlanarGraph::build(&[closed_square(0.0, 0.0, 10.0)]);
        assert_eq!(g.face_count(), 1);
        assert!((total_top_level_area(&g) - 100.0).abs() < AREA_EPS);
    }

    // ----- 3. Square with one diagonal -----

    #[test]
    fn square_with_one_diagonal_is_two_triangles() {
        let g = PlanarGraph::build(&[
            closed_square(0.0, 0.0, 10.0),
            segment((0.0, 0.0), (10.0, 10.0)),
        ]);
        assert_eq!(g.face_count(), 2);
        assert!((total_top_level_area(&g) - 100.0).abs() < AREA_EPS);
        // Both triangles have area 50.
        for f in g.top_level_faces() {
            assert!((g.face_net_area(f).abs() - 50.0).abs() < AREA_EPS);
        }
    }

    // ----- 4. Square with both diagonals -----

    #[test]
    fn square_with_both_diagonals_is_four_triangles() {
        let g = PlanarGraph::build(&[
            closed_square(0.0, 0.0, 10.0),
            segment((0.0, 0.0), (10.0, 10.0)),
            segment((10.0, 0.0), (0.0, 10.0)),
        ]);
        assert_eq!(g.face_count(), 4);
        assert!((total_top_level_area(&g) - 100.0).abs() < AREA_EPS);
        for f in g.top_level_faces() {
            assert!((g.face_net_area(f).abs() - 25.0).abs() < AREA_EPS);
        }
    }

    // ----- 5. Two disjoint squares -----

    #[test]
    fn two_disjoint_squares_are_two_faces() {
        let g = PlanarGraph::build(&[
            closed_square(0.0, 0.0, 10.0),
            closed_square(20.0, 0.0, 10.0),
        ]);
        assert_eq!(g.face_count(), 2);
        assert!((total_top_level_area(&g) - 200.0).abs() < AREA_EPS);
    }

    // ----- 6. Two squares sharing an edge -----

    #[test]
    fn two_squares_sharing_an_edge_are_two_faces() {
        // Left square [0,10]x[0,10], right square [10,20]x[0,10].
        // The shared edge x=10 between y=0 and y=10 should appear
        // exactly once in the topology.
        let g = PlanarGraph::build(&[
            closed_square(0.0, 0.0, 10.0),
            closed_square(10.0, 0.0, 10.0),
        ]);
        assert_eq!(g.face_count(), 2);
        assert!((total_top_level_area(&g) - 200.0).abs() < AREA_EPS);
    }

    // ----- 7. T-junction (deferred) -----

    #[test]
    #[ignore = "T-junctions where one polyline's vertex lands on another's interior not yet supported"]
    fn t_junction_creates_vertex() {
        // A horizontal segment from (0,0) to (10,0), and a vertical
        // segment from (5,0) to (5,5). The vertical's endpoint sits
        // exactly on the horizontal's interior. Both are open
        // polylines, so the whole thing should prune to nothing.
        let g = PlanarGraph::build(&[
            segment((0.0, 0.0), (10.0, 0.0)),
            segment((5.0, 0.0), (5.0, 5.0)),
        ]);
        assert_eq!(g.face_count(), 0);
    }

    // ----- 8. Concentric squares (containment / holes) -----

    #[test]
    fn square_with_inner_square_is_outer_with_one_hole() {
        // Outer 20x20, inner 10x10 centered. No intersections; the
        // inner is fully contained.
        let g = PlanarGraph::build(&[
            closed_square(0.0, 0.0, 20.0),
            closed_square(5.0, 5.0, 10.0),
        ]);
        // Two faces total (outer ring, inner square).
        assert_eq!(g.face_count(), 2);
        // Exactly one top-level face: the outer one.
        let top = g.top_level_faces();
        assert_eq!(top.len(), 1);
        let outer = top[0];
        // The outer face has the inner square recorded as a hole.
        assert_eq!(g.faces[outer.0].holes.len(), 1);
        // The outer's net area is 400 - 100 = 300; its outer-only
        // area is 400.
        assert!((g.face_outer_area(outer).abs() - 400.0).abs() < AREA_EPS);
        assert!((g.face_net_area(outer).abs() - 300.0).abs() < AREA_EPS);
        // The inner face (depth 2) has area 100 and parent = outer.
        let inner = (0..g.faces.len())
            .map(FaceId)
            .find(|f| g.faces[f.0].depth == 2)
            .expect("expected an inner hole face");
        assert_eq!(g.faces[inner.0].parent, Some(outer));
        assert!((g.face_net_area(inner).abs() - 100.0).abs() < AREA_EPS);
    }

    // ----- 9. Hit test on the cross-diagonal square -----

    #[test]
    fn hit_test_finds_correct_quadrant_in_diagonal_square() {
        let g = PlanarGraph::build(&[
            closed_square(0.0, 0.0, 10.0),
            segment((0.0, 0.0), (10.0, 10.0)),
            segment((10.0, 0.0), (0.0, 10.0)),
        ]);
        // Pick a sample point in each of the four triangles. Each
        // sample should land in a distinct face.
        let samples = [
            (5.0, 1.0), // bottom triangle
            (9.0, 5.0), // right triangle
            (5.0, 9.0), // top triangle
            (1.0, 5.0), // left triangle
        ];
        let mut hits = Vec::new();
        for s in samples {
            let f = g.hit_test(s).expect("sample should land in some face");
            hits.push(f);
        }
        // All four samples should land in distinct faces.
        let mut sorted = hits.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(sorted.len(), 4, "expected 4 distinct face hits, got {:?}", hits);
    }

    // ----- 10. Degenerate inputs -----

    #[test]
    fn empty_input_yields_empty_graph() {
        let g = PlanarGraph::build(&[]);
        assert_eq!(g.face_count(), 0);
    }

    #[test]
    fn zero_length_segment_is_dropped() {
        let g = PlanarGraph::build(&[segment((1.0, 1.0), (1.0, 1.0))]);
        assert_eq!(g.face_count(), 0);
    }

    #[test]
    fn single_point_polyline_is_dropped() {
        let g = PlanarGraph::build(&[vec![(3.0, 3.0)]]);
        assert_eq!(g.face_count(), 0);
    }

    // ----- 11. Square with an external tail -----

    #[test]
    fn square_with_external_tail_prunes_to_one_face() {
        // A closed square plus an open stroke that starts at one
        // corner and extends outward. The tail's free end is degree
        // 1 and gets pruned.
        let g = PlanarGraph::build(&[
            closed_square(0.0, 0.0, 10.0),
            segment((10.0, 10.0), (15.0, 15.0)),
        ]);
        assert_eq!(g.face_count(), 1);
        assert!((total_top_level_area(&g) - 100.0).abs() < AREA_EPS);
    }

    // ----- 12. Square with an internal tail -----

    #[test]
    fn square_with_internal_tail_prunes_to_one_face() {
        // Tail starts at a corner and ends at a free point inside
        // the square. The free end is degree 1 and gets pruned.
        let g = PlanarGraph::build(&[
            closed_square(0.0, 0.0, 10.0),
            segment((0.0, 0.0), (5.0, 5.0)),
        ]);
        assert_eq!(g.face_count(), 1);
        assert!((total_top_level_area(&g) - 100.0).abs() < AREA_EPS);
    }

    // ----- 13. Square with a branching tree of strokes -----

    #[test]
    fn square_with_internal_tree_prunes_to_one_face() {
        // A tree of pendant edges hanging off a corner. The
        // iterative degree-1 prune should eat the whole tree in a
        // few rounds.
        let g = PlanarGraph::build(&[
            closed_square(0.0, 0.0, 10.0),
            // tree rooted at (0,0): trunk to (3,3), then two branches
            vec![(0.0, 0.0), (3.0, 3.0)],
            vec![(3.0, 3.0), (5.0, 3.0)],
            vec![(3.0, 3.0), (3.0, 5.0)],
            // sub-branch off (5,3)
            vec![(5.0, 3.0), (6.0, 4.0)],
        ]);
        assert_eq!(g.face_count(), 1);
        assert!((total_top_level_area(&g) - 100.0).abs() < AREA_EPS);
    }

    // ----- 14. Isolated open stroke -----

    #[test]
    fn isolated_open_stroke_yields_no_faces() {
        let g = PlanarGraph::build(&[segment((0.0, 0.0), (5.0, 5.0))]);
        assert_eq!(g.face_count(), 0);
    }

    // ----- 15. Square with a single hole (covered by test 8); use
    // ----- this slot for a square with two disjoint holes.

    #[test]
    fn square_with_two_disjoint_holes() {
        let g = PlanarGraph::build(&[
            closed_square(0.0, 0.0, 30.0),
            closed_square(5.0, 5.0, 5.0),    // hole A
            closed_square(20.0, 20.0, 5.0),  // hole B
        ]);
        // Three faces: outer + two holes.
        assert_eq!(g.face_count(), 3);
        let top = g.top_level_faces();
        assert_eq!(top.len(), 1);
        let outer = top[0];
        assert_eq!(g.faces[outer.0].holes.len(), 2);
        // outer 900, minus two 25-area holes = 850 net.
        assert!((g.face_net_area(outer).abs() - 850.0).abs() < AREA_EPS);
    }

    // ----- 16. Three-deep nested squares -----

    #[test]
    fn three_deep_nested_squares() {
        // A contains B contains C, no intersections.
        let g = PlanarGraph::build(&[
            closed_square(0.0, 0.0, 30.0),  // A, depth 1
            closed_square(5.0, 5.0, 20.0),  // B, depth 2 (hole of A)
            closed_square(10.0, 10.0, 10.0),// C, depth 3 (hole of B)
        ]);
        assert_eq!(g.face_count(), 3);

        // Group faces by depth.
        let mut by_depth: BTreeMap<usize, Vec<FaceId>> = BTreeMap::new();
        for (i, f) in g.faces.iter().enumerate() {
            by_depth.entry(f.depth).or_default().push(FaceId(i));
        }
        assert_eq!(by_depth.get(&1).map(|v| v.len()), Some(1));
        assert_eq!(by_depth.get(&2).map(|v| v.len()), Some(1));
        assert_eq!(by_depth.get(&3).map(|v| v.len()), Some(1));

        let a = by_depth[&1][0];
        let b = by_depth[&2][0];
        let c = by_depth[&3][0];
        assert_eq!(g.faces[b.0].parent, Some(a));
        assert_eq!(g.faces[c.0].parent, Some(b));

        // Net areas: A = 900 - 400 = 500; B = 400 - 100 = 300; C = 100.
        assert!((g.face_net_area(a).abs() - 500.0).abs() < AREA_EPS);
        assert!((g.face_net_area(b).abs() - 300.0).abs() < AREA_EPS);
        assert!((g.face_net_area(c).abs() - 100.0).abs() < AREA_EPS);
    }

    // ----- 17. Hit test inside a hole returns the hole, not its parent -----

    #[test]
    fn hit_test_in_hole_returns_hole_not_parent() {
        let g = PlanarGraph::build(&[
            closed_square(0.0, 0.0, 20.0),
            closed_square(5.0, 5.0, 10.0),
        ]);
        // A point in the annulus (inside outer, outside hole)
        // should hit the outer face.
        let outer_hit = g.hit_test((1.0, 1.0)).expect("annulus point should hit");
        assert_eq!(g.faces[outer_hit.0].depth, 1);
        // A point inside the hole should hit the hole face, not its
        // parent.
        let hole_hit = g.hit_test((10.0, 10.0)).expect("hole point should hit");
        assert_eq!(g.faces[hole_hit.0].depth, 2);
        assert_eq!(g.faces[hole_hit.0].parent, Some(outer_hit));
    }

    // ----- Deferred / known limitations -----

    #[test]
    #[ignore = "collinear self-overlap not yet supported (mirrors boolean_normalize)"]
    fn collinear_overlap() {
        // Two polylines that share part of an edge in the same
        // direction. Not yet handled.
    }

    #[test]
    #[ignore = "incremental rebuild not yet supported"]
    fn incremental_add_stroke() {
        // Adding a stroke to an existing graph should be cheaper
        // than full rebuild. Not yet implemented.
    }
}
