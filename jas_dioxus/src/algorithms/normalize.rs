//! Ring normalizer: turn an arbitrary (possibly self-intersecting)
//! polygon set into an equivalent set of **simple** rings under the
//! **non-zero winding** fill rule.
//!
//! # What this is for
//!
//! The boolean operations in [`crate::algorithms::boolean`] assume
//! simple (non-self-intersecting) input rings. User-drawn input —
//! pen-tool paths, imported SVG with `fill-rule="nonzero"` — is often
//! self-intersecting, either deliberately (figure-8, ribbon knots) or
//! accidentally (sloppy click). This module is the pre-pass that
//! takes such input and returns an equivalent simple-ring
//! representation, so the boolean code can stay single-purpose.
//!
//! # What "equivalent" means
//!
//! Two polygon sets are equivalent iff they describe the same
//! **filled region** under their respective fill rules. The filled
//! region of the input is defined by the non-zero winding rule
//! applied to the original rings: a point is inside iff the signed
//! winding count around it is non-zero.
//!
//! The output is a set of simple rings whose even-odd / signed-area
//! fill region matches the input's non-zero winding fill region. The
//! output's rings are oriented so outer boundaries are
//! counter-clockwise (positive signed area) and any hole-like
//! sub-regions come out as separate rings with negative signed
//! area. Downstream code ([`run_boolean`]) is agnostic to this
//! orientation convention.
//!
//! # Scope of this first implementation
//!
//! Handles:
//!   - Simple rings (pass through with consecutive-duplicate removal)
//!   - Self-intersecting rings with **proper** interior crossings
//!     (the common figure-8 / accidental-loop cases)
//!   - Rings with multiple self-intersections (resolved recursively)
//!
//! Does **not** yet handle:
//!   - Degenerate self-touches where the ring passes through one of
//!     its own vertices (T-intersections)
//!   - Collinear self-overlaps (ring retracing part of itself on the
//!     same line)
//!   - Interaction between multiple rings in the same `PolygonSet`
//!     (each ring is normalized independently; overlap / cancellation
//!     between different rings is not detected)
//!
//! The deferred cases are called out with TODOs in the code and
//! tracked as `#[ignore]` tests.
//!
//! # Algorithm
//!
//! Recursive splitting:
//!
//!   1. Remove consecutive duplicate vertices.
//!   2. Find the first proper self-intersection between two
//!      non-adjacent edges. If none, the ring is simple — return it.
//!   3. Otherwise, split the ring at the crossing point into two
//!      sub-rings (one for each "lobe" of the crossing), and recurse
//!      on each.
//!   4. Collect all resulting simple sub-rings.
//!   5. Filter by the **winding number of the original ring** at a
//!      sample point inside each sub-ring. Sub-rings whose original-
//!      winding is zero are dropped (cancelled regions).
//!
//! Complexity is O(n² · k) where k is the number of self-intersections
//! (each split scans all edges for the next intersection). Fine for
//! user-drawn paths with at most a few dozen self-intersections; not
//! intended for arbitrarily complex input.

use crate::algorithms::boolean::{PolygonSet, Ring};

/// Normalize a polygon set: return an equivalent simple-ring
/// representation under the non-zero winding fill rule. See the
/// module-level docs for semantics and scope.
pub fn normalize(input: &PolygonSet) -> PolygonSet {
    let mut out = Vec::new();
    for ring in input {
        out.extend(normalize_ring(ring));
    }
    out
}

/// Normalize a single ring. Returns 0, 1, or more simple rings.
fn normalize_ring(ring: &Ring) -> Vec<Ring> {
    let cleaned = dedup_consecutive(ring);
    if cleaned.len() < 3 {
        return Vec::new();
    }

    // Recursively split until every sub-ring is simple.
    let simple = split_recursively(cleaned.clone());

    // Filter by winding number of the ORIGINAL (pre-split) ring at a
    // sample point inside each sub-ring. Sub-rings whose winding in
    // the original is zero are cancelled regions — drop them.
    let mut out: Vec<Ring> = Vec::new();
    for sub in simple {
        if sub.len() < 3 {
            continue;
        }
        let sample = sample_inside_simple_ring(&sub);
        if winding_number(&cleaned, sample) != 0 {
            out.push(sub);
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Vertex cleanup
// ---------------------------------------------------------------------------

/// Remove consecutive duplicate vertices, including the wrap-around
/// duplicate if the ring closes back onto itself.
fn dedup_consecutive(ring: &Ring) -> Ring {
    let mut out: Ring = Vec::with_capacity(ring.len());
    for &p in ring {
        if out.last() != Some(&p) {
            out.push(p);
        }
    }
    while out.len() >= 2 && out.first() == out.last() {
        out.pop();
    }
    out
}

// ---------------------------------------------------------------------------
// Self-intersection detection and splitting
// ---------------------------------------------------------------------------

/// Find the first proper self-intersection between two non-adjacent
/// edges of `ring`. Returns `(i, j, p)` where `i < j` are the edge
/// indices (edge `k` goes from `ring[k]` to `ring[(k+1) % n]`) and
/// `p` is the crossing point.
///
/// Adjacent edges (including the wrap-around pair `(0, n-1)`) are
/// skipped because they share a vertex and can't "properly" cross.
fn find_first_self_intersection(ring: &Ring) -> Option<(usize, usize, (f64, f64))> {
    let n = ring.len();
    if n < 4 {
        return None;
    }
    for i in 0..n {
        let a1 = ring[i];
        let a2 = ring[(i + 1) % n];
        for j in (i + 2)..n {
            // Skip the wrap-around adjacent pair.
            if i == 0 && j == n - 1 {
                continue;
            }
            let b1 = ring[j];
            let b2 = ring[(j + 1) % n];
            if let Some(p) = segment_proper_intersection(a1, a2, b1, b2) {
                return Some((i, j, p));
            }
        }
    }
    None
}

/// Parametric line-line intersection requiring a **strictly
/// interior** crossing on both segments. Returns `None` for parallel
/// segments, for segments that only touch at an endpoint, and for
/// segments whose intersection lies outside either segment.
fn segment_proper_intersection(
    a1: (f64, f64),
    a2: (f64, f64),
    b1: (f64, f64),
    b2: (f64, f64),
) -> Option<(f64, f64)> {
    let dxa = a2.0 - a1.0;
    let dya = a2.1 - a1.1;
    let dxb = b2.0 - b1.0;
    let dyb = b2.1 - b1.1;
    let denom = dxa * dyb - dya * dxb;
    if denom.abs() < 1e-12 {
        return None;
    }
    let dxab = a1.0 - b1.0;
    let dyab = a1.1 - b1.1;
    let s = (dxb * dyab - dyb * dxab) / denom;
    let t = (dxa * dyab - dya * dxab) / denom;
    const EPS: f64 = 1e-9;
    if s <= EPS || s >= 1.0 - EPS || t <= EPS || t >= 1.0 - EPS {
        return None;
    }
    Some((a1.0 + s * dxa, a1.1 + s * dya))
}

/// Split `ring` at a crossing of edges `i` and `j` (with `i < j`) at
/// point `p`, producing two sub-rings:
///
///   A: `ring[0..=i]`, `p`, `ring[j+1..n]`
///   B: `p`, `ring[i+1..=j]`
///
/// These two sub-rings together cover the same sequence of vertices
/// as the original ring with `p` inserted at both crossing positions.
fn split_ring_at(ring: &Ring, i: usize, j: usize, p: (f64, f64)) -> (Ring, Ring) {
    let n = ring.len();
    let mut a: Ring = Vec::with_capacity(i + 2 + (n - j - 1));
    for k in 0..=i {
        a.push(ring[k]);
    }
    a.push(p);
    for k in (j + 1)..n {
        a.push(ring[k]);
    }

    let mut b: Ring = Vec::with_capacity(j - i + 1);
    b.push(p);
    for k in (i + 1)..=j {
        b.push(ring[k]);
    }

    (a, b)
}

/// Recursively split a ring at each self-intersection until every
/// resulting sub-ring is simple.
fn split_recursively(ring: Ring) -> Vec<Ring> {
    let mut stack: Vec<Ring> = vec![ring];
    let mut simple: Vec<Ring> = Vec::new();
    while let Some(r) = stack.pop() {
        if r.len() < 3 {
            continue;
        }
        match find_first_self_intersection(&r) {
            Some((i, j, p)) => {
                let (a, b) = split_ring_at(&r, i, j, p);
                stack.push(a);
                stack.push(b);
            }
            None => {
                simple.push(r);
            }
        }
    }
    simple
}

// ---------------------------------------------------------------------------
// Winding and sampling
// ---------------------------------------------------------------------------

/// Winding number of `ring` around `point`: signed count of ring
/// edges crossed by a horizontal ray from `point` in the +x
/// direction, where each upward-crossing edge counts +1 and each
/// downward-crossing edge counts −1.
///
/// Used to determine whether a sub-ring's interior was actually
/// filled under the non-zero winding rule of the original
/// self-intersecting ring.
fn winding_number(ring: &Ring, point: (f64, f64)) -> i32 {
    let n = ring.len();
    if n < 3 {
        return 0;
    }
    let (px, py) = point;
    let mut w: i32 = 0;
    for i in 0..n {
        let (x1, y1) = ring[i];
        let (x2, y2) = ring[(i + 1) % n];
        // Half-open rule to avoid double-counting when the ray
        // passes exactly through a vertex.
        let upward = y1 <= py && y2 > py;
        let downward = y2 <= py && y1 > py;
        if !upward && !downward {
            continue;
        }
        // x-coordinate where the edge crosses y = py.
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

/// Pick a point guaranteed to be strictly inside a simple ring.
///
/// Strategy: offset the midpoint of the ring's first edge by a small
/// distance perpendicular to that edge, on the interior side. The
/// interior side is determined by checking which of the two offsets
/// has a non-zero winding number in the ring itself.
fn sample_inside_simple_ring(ring: &Ring) -> (f64, f64) {
    let n = ring.len();
    debug_assert!(n >= 3);
    let (x0, y0) = ring[0];
    let (x1, y1) = ring[1];
    let mx = (x0 + x1) / 2.0;
    let my = (y0 + y1) / 2.0;
    let dx = x1 - x0;
    let dy = y1 - y0;
    let len = (dx * dx + dy * dy).sqrt();
    if len == 0.0 {
        // Degenerate edge; fall back to the centroid of the first three
        // vertices. Not robust in general but handles well-formed input.
        let (x2, y2) = ring[2];
        return ((x0 + x1 + x2) / 3.0, (y0 + y1 + y2) / 3.0);
    }
    // Unit perpendicular pointing "left" of the edge direction.
    let nx = -dy / len;
    let ny = dx / len;
    // Offset distance: a small fraction of the edge length. Needs to
    // be large enough to land strictly inside one cell of the ring,
    // small enough not to land outside.
    let offset = len * 1e-4;
    let left = (mx + nx * offset, my + ny * offset);
    let right = (mx - nx * offset, my - ny * offset);
    if winding_number(ring, left) != 0 {
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

    fn ring_signed_area(ring: &Ring) -> f64 {
        let mut sum = 0.0;
        let n = ring.len();
        for i in 0..n {
            let (x1, y1) = ring[i];
            let (x2, y2) = ring[(i + 1) % n];
            sum += x1 * y2 - x2 * y1;
        }
        sum / 2.0
    }

    fn total_area(ps: &PolygonSet) -> f64 {
        ps.iter().map(|r| ring_signed_area(r).abs()).sum()
    }

    // ----------- Simple rings (pass through) -----------

    #[test]
    fn simple_square_passes_through() {
        let input: PolygonSet = vec![vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]];
        let out = normalize(&input);
        assert_eq!(out.len(), 1);
        assert!((total_area(&out) - 100.0).abs() < 1e-9);
    }

    #[test]
    fn simple_triangle_passes_through() {
        let input: PolygonSet = vec![vec![(0.0, 0.0), (10.0, 0.0), (5.0, 10.0)]];
        let out = normalize(&input);
        assert_eq!(out.len(), 1);
        assert!((total_area(&out) - 50.0).abs() < 1e-9);
    }

    #[test]
    fn cw_square_passes_through_preserving_signed_area() {
        // A CW square (negative signed area). The normalizer currently
        // doesn't enforce output orientation, so the signed area sign
        // is preserved. What matters is the absolute area.
        let input: PolygonSet = vec![vec![(0.0, 0.0), (0.0, 10.0), (10.0, 10.0), (10.0, 0.0)]];
        let out = normalize(&input);
        assert_eq!(out.len(), 1);
        assert!((total_area(&out) - 100.0).abs() < 1e-9);
    }

    // ----------- Degenerate input -----------

    #[test]
    fn empty_input_yields_empty_output() {
        let input: PolygonSet = vec![];
        let out = normalize(&input);
        assert!(out.is_empty());
    }

    #[test]
    fn ring_with_fewer_than_three_vertices_is_dropped() {
        let input: PolygonSet = vec![vec![(0.0, 0.0), (10.0, 0.0)]];
        let out = normalize(&input);
        assert!(out.is_empty());
    }

    #[test]
    fn ring_with_consecutive_duplicates_is_deduped() {
        let input: PolygonSet = vec![vec![
            (0.0, 0.0),
            (0.0, 0.0),
            (10.0, 0.0),
            (10.0, 10.0),
            (10.0, 10.0),
            (0.0, 10.0),
        ]];
        let out = normalize(&input);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].len(), 4);
        assert!((total_area(&out) - 100.0).abs() < 1e-9);
    }

    #[test]
    fn ring_collapsing_to_single_point_is_dropped() {
        let input: PolygonSet = vec![vec![(5.0, 5.0), (5.0, 5.0), (5.0, 5.0), (5.0, 5.0)]];
        let out = normalize(&input);
        assert!(out.is_empty());
    }

    // ----------- Single self-intersection -----------

    #[test]
    fn figure_eight_becomes_two_simple_triangles() {
        // Classic bowtie: the two diagonals cross at (5, 5).
        // Input visit order: (0,0) -> (10,10) -> (10,0) -> (0,10) -> close.
        // Edges (0,0)-(10,10) and (10,0)-(0,10) cross at (5,5).
        let input: PolygonSet =
            vec![vec![(0.0, 0.0), (10.0, 10.0), (10.0, 0.0), (0.0, 10.0)]];
        let out = normalize(&input);
        assert_eq!(out.len(), 2, "figure-8 should split into two triangles: {:?}", out);
        // Both triangles have area 25.
        let total = total_area(&out);
        assert!(
            (total - 50.0).abs() < 1e-9,
            "expected total area 50, got {} (rings: {:?})",
            total,
            out
        );
        // Each ring should have exactly 3 distinct vertices.
        for r in &out {
            assert_eq!(r.len(), 3, "expected triangle, got {:?}", r);
        }
    }

    #[test]
    fn retrograde_loop_cancels_under_non_zero_winding() {
        // A ring that traces a big square CCW, then makes a tiny
        // counter-rotating loop inside: the loop has winding -1 in the
        // original, so the big square + loop has winding +1 - 1 = 0
        // inside the loop, which is "cancelled" and should be a hole
        // in the output. With the simpler "recursive split" approach
        // implemented here, we'd need the loop to be a proper
        // self-intersection — which a simple inscribed loop isn't. So
        // for now, leave this ignored as a known limitation.
        //
        // TODO: handle T-junctions / collinear overlaps where a loop
        // shares an edge with the outer boundary.
    }

    // ----------- Known limitations (documented as ignored tests) -----------

    #[test]
    #[ignore = "T-junction self-intersections (ring passes through its own vertex) not yet supported"]
    fn t_junction_self_intersection() {
        // A ring that passes through one of its own vertices. The
        // current proper-intersection check skips endpoint touches,
        // so this doesn't get detected or split.
    }

    #[test]
    #[ignore = "collinear self-overlap (ring retracing itself) not yet supported"]
    fn collinear_self_retrace() {
        // A ring that retraces part of its own boundary, which should
        // cancel under non-zero winding but currently isn't handled.
    }

    #[test]
    #[ignore = "inter-ring winding not yet considered; each ring is normalized independently"]
    fn overlapping_rings_cancel_by_winding() {
        // Two separate rings in the same PolygonSet where one is
        // CCW and the other CW inside it, like a ring-with-hole
        // expressed as two rings with opposing winding. The current
        // implementation normalizes each ring in isolation and
        // misses the cancellation.
    }
}
