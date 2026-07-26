//! Ring normalizer: turn an arbitrary (possibly self-intersecting)
//! polygon set into an equivalent set of **simple** rings under the
//! **non-zero winding** fill rule.
//!
// Module-wide allow: tested but not yet wired into the document model.
#![allow(dead_code)]
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
//! # Scope: one ring at a time
//!
//! Normalization is **per ring**. Each ring of the input is replaced
//! by the simple rings that bound the same filled region *considered
//! alone*, under the **non-zero winding rule** — which is what a
//! single self-intersecting subpath means (SVG `fill-rule="nonzero"`).
//! How the resulting rings then combine with each other is *not* this
//! module's business: [`crate::algorithms::boolean`] defines a
//! `PolygonSet` as a flat list of rings under the **even-odd** rule,
//! with orientation explicitly outside the contract, and its sweep is
//! what resolves nesting and overlap. A ring-with-hole therefore
//! passes through as two rings whatever their orientations, and two
//! overlapping rings pass through as two rings; anything else would
//! silently re-interpret the operand.
//!
//! SPEC NOTE for the council. The two rules meeting here — non-zero
//! within a ring, even-odd between rings — disagree on exactly the
//! cases one would call "inter-ring winding cancellation". Two nested
//! same-orientation rings are a hole under even-odd but a solid under
//! non-zero; two overlapping same-orientation rings are a symmetric
//! difference under even-odd but a union under non-zero. This module
//! follows `boolean.rs`'s ratified even-odd contract for the between-
//! rings question and does not touch it. If the intent is that a
//! `PolygonSet` carry the document's `fill-rule` instead of a fixed
//! one, that is a schema decision, not a normalizer decision.
//!
//! The output rings of a rebuilt ring are simple and pairwise
//! non-overlapping, oriented so the filled side is on the left: outer
//! boundaries counter-clockwise (positive signed area) and hole
//! boundaries clockwise (negative signed area). Collinear vertices are
//! **retained** — collapsing them is the Boolean panel's separate
//! "Remove Redundant Points" option, which defaults to off (see
//! `transcripts/BOOLEAN.md`).
//!
//! # Two paths
//!
//! **Fast path.** If the ring is already simple — no two of its edges
//! meet except where consecutive edges share their one vertex — and it
//! encloses a non-zero area, it is returned unchanged, orientation
//! included. This is the common case, and keeping it a literal
//! pass-through is what lets [`crate::algorithms::boolean`] call the
//! normalizer on every operand without perturbing non-degenerate
//! results.
//!
//! **Arrangement path.** Otherwise the ring's region boundary is
//! rebuilt from scratch:
//!
//!   1. Split every edge at every meeting with every other edge —
//!      proper crossings, T-junctions and collinear-overlap ends —
//!      using [`crate::algorithms::arrangement::split_points`]. The
//!      result is a *conforming* arrangement: no edge interior holds
//!      another edge's vertex, and no two edges overlap over a span.
//!   2. Reduce to the set of undirected **atomic spans**. Direction
//!      and multiplicity are deliberately discarded here: under the
//!      non-zero rule a doubly-wound square fills exactly the same
//!      region as a singly-wound one, so what matters is not how many
//!      times a span was traced but whether the region differs across
//!      it.
//!   3. Classify each span by the winding of the ORIGINAL ring just
//!      to its left and just to its right. A span is part of the
//!      output boundary iff exactly one side is filled; it is then
//!      oriented with the filled side on its left. Spans with the
//!      same filled-ness on both sides are interior to the region or
//!      exterior to it and are dropped — which is precisely how
//!      collinear self-overlap, retrograde spans and inter-ring
//!      cancellation all resolve, without a special case for any of
//!      them.
//!   4. Chain the surviving directed spans into rings by always
//!      taking the first outgoing span **clockwise** from the
//!      reversal of the incoming one. That is the standard
//!      face-tracing rule and is what keeps two lobes meeting at a
//!      pinch vertex separate instead of fusing them.
//!
//! # Degenerate classes
//!
//! Each is pinned by a unit test with a hand-derived expected value
//! (shoelace sums written into the test), because these are *shared*
//! limitations: a differential comparison between the Rust and Swift
//! ports is blind to them — wrong-vs-wrong compares equal. The
//! cross-language corpus gates AGREEMENT; the unit tests gate
//! CORRECTNESS.
//!
//!   - **Proper self-intersection** (figure-8) — step 1's crossing.
//!   - **T-junction** — a ring passing through one of its own
//!     vertices, or two rings touching at a vertex. Step 1 now
//!     reports these; the old strict predicate required a strictly
//!     interior crossing on *both* edges and so missed them.
//!   - **Collinear self-overlap** — a ring retracing part of its own
//!     boundary. Step 1 splits at the overlap ends, step 3 drops the
//!     doubled span because the region is the same on both sides.
//!   - **Retrograde loops** — a subpath that reverses direction, or a
//!     counter-wound loop spliced into the outer boundary by a slit.
//!     The slit is dropped by step 3; the counter-wound loop survives
//!     as a hole (or vanishes) exactly as its winding dictates.
//!   - **Inter-ring relations** — deliberately NOT resolved here; see
//!     the scope section above. Pinned by pass-through tests so that
//!     the even-odd contract cannot be broken by accident.
//!
//! # Complexity
//!
//! O(n²) split scan plus O(E²) for the per-span winding sample (each
//! span needs the distance to every other span to size its probe
//! offset). Fine for user-drawn paths with at most a few hundred
//! edges; not intended for arbitrarily complex input. The fast path
//! costs one O(n²) scan and is what the common case pays.
//!
//! # Epsilon policy
//!
//! Inherited unchanged from [`crate::algorithms::arrangement`] for
//! everything about *whether* two edges meet. The one new tolerance
//! is the winding-probe offset of step 3: for a span of length `L`
//! whose midpoint is at distance `d` from the nearest other span, the
//! probe sits at `0.25 · min(L, d)` perpendicular to the span. Both
//! terms matter — `L` keeps the probe from sliding past the span's
//! own ends, `d` keeps it from crossing a neighbouring boundary — and
//! the 0.25 leaves a factor-of-four margin. The consequence to know:
//! geometry thinner than a quarter of the nearest feature is not
//! resolved, but nothing legitimately thin is *dropped*, because the
//! probe is always sized relative to the actual local feature size
//! rather than to a fixed absolute epsilon.

use crate::algorithms::arrangement::{
    add_or_find_vertex, dist, split_points, VERT_EPS,
};
use crate::algorithms::boolean::{PolygonSet, Ring};
use std::collections::BTreeSet;

/// Normalize a polygon set: replace each ring by the simple rings that
/// bound the same region *considered alone*, under the non-zero winding
/// rule. Ring-to-ring relations are left to
/// [`crate::algorithms::boolean`]'s even-odd sweep. See the
/// module-level docs for semantics and scope.
pub fn normalize(input: &PolygonSet) -> PolygonSet {
    let mut out: PolygonSet = Vec::new();
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
    // The two workers take a whole set so their geometry reads
    // naturally; here the set is always this one ring.
    let one: PolygonSet = vec![cleaned];
    if is_already_normalized(&one) {
        return one;
    }
    rebuild_from_arrangement(&one)
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
// Fast path: is the input already a well-formed polygon set?
// ---------------------------------------------------------------------------

/// One directed edge of one ring, tagged with where it came from so
/// the "legitimately adjacent" exemption can be checked.
struct TaggedEdge {
    a: (f64, f64),
    b: (f64, f64),
    ring: usize,
    edge: usize,
    ring_len: usize,
}

fn tagged_edges(rings: &PolygonSet) -> Vec<TaggedEdge> {
    let mut out = Vec::new();
    for (ri, ring) in rings.iter().enumerate() {
        let n = ring.len();
        for i in 0..n {
            out.push(TaggedEdge {
                a: ring[i],
                b: ring[(i + 1) % n],
                ring: ri,
                edge: i,
                ring_len: n,
            });
        }
    }
    out
}

/// True if `rings` already satisfies the normalizer's output contract,
/// so it can be returned untouched. Called with a one-ring set; written
/// against a set so the geometry reads naturally.
///
/// Two conditions, both necessary:
///
///   1. **No edge meets another** except where two consecutive edges of
///      the same ring share their one common vertex. Any other reported
///      meeting is a crossing, a T-junction, a pinch, or a collinear
///      overlap — all of which need the arrangement.
///   2. **The boundary really is a boundary.** Immediately inside the
///      ring and immediately outside it, the winding must differ in
///      *filled-ness* — exactly one of the two must be zero. True for
///      any simple ring of either orientation; false for a degenerate
///      zero-area ring, whose "inside" is not filled either.
fn is_already_normalized(rings: &PolygonSet) -> bool {
    let edges = tagged_edges(rings);
    for e in &edges {
        // A degenerate edge survived dedup only if two vertices differ
        // by less than VERT_EPS without being bit-equal. Hand it to the
        // arrangement rather than reasoning about it here.
        if dist(e.a, e.b) <= VERT_EPS {
            return false;
        }
    }
    for i in 0..edges.len() {
        for j in (i + 1)..edges.len() {
            let (p, q) = (&edges[i], &edges[j]);
            let pts = split_points(p.a, p.b, q.a, q.b);
            if pts.is_empty() {
                continue;
            }
            let same_ring = p.ring == q.ring;
            let n = p.ring_len;
            let consecutive = same_ring
                && ((q.edge + 1) % n == p.edge || (p.edge + 1) % n == q.edge);
            // Consecutive edges legitimately meet at exactly one
            // point: their shared vertex. Anything else — two points
            // (a collinear overlap), or a single point that is not an
            // endpoint of both — is a degeneracy.
            let shared_vertex_only = consecutive
                && pts.len() == 1
                && (pts[0].1 == 0.0 || pts[0].1 == 1.0)
                && (pts[0].2 == 0.0 || pts[0].2 == 1.0);
            if !shared_vertex_only {
                return false;
            }
        }
    }
    for ring in rings {
        let inside = sample_inside_simple_ring(ring);
        let w_all = winding_of_set(rings, inside);
        let w_self = winding_number(ring, inside);
        let w_without = w_all - w_self;
        if (w_all != 0) == (w_without != 0) {
            return false;
        }
    }
    true
}

// ---------------------------------------------------------------------------
// Arrangement path
// ---------------------------------------------------------------------------

/// Rebuild the boundary of the non-zero-winding region of `rings` from
/// a conforming arrangement of their edges. Called with a one-ring set;
/// see the module docs for the four steps.
fn rebuild_from_arrangement(rings: &PolygonSet) -> PolygonSet {
    // ----- 1. Conforming arrangement -----
    let mut segments: Vec<((f64, f64), (f64, f64))> = Vec::new();
    for ring in rings {
        let n = ring.len();
        for i in 0..n {
            let (a, b) = (ring[i], ring[(i + 1) % n]);
            if dist(a, b) > VERT_EPS {
                segments.push((a, b));
            }
        }
    }
    if segments.is_empty() {
        return Vec::new();
    }

    let mut vert_pts: Vec<(f64, f64)> = Vec::new();
    let mut seg_params: Vec<Vec<(f64, usize)>> = vec![Vec::new(); segments.len()];
    for (si, &(a, b)) in segments.iter().enumerate() {
        let va = add_or_find_vertex(&mut vert_pts, a);
        let vb = add_or_find_vertex(&mut vert_pts, b);
        seg_params[si].push((0.0, va));
        seg_params[si].push((1.0, vb));
    }
    for i in 0..segments.len() {
        for j in (i + 1)..segments.len() {
            let (a1, a2) = segments[i];
            let (b1, b2) = segments[j];
            for (p, s, t) in split_points(a1, a2, b1, b2) {
                let v = add_or_find_vertex(&mut vert_pts, p);
                seg_params[i].push((s, v));
                seg_params[j].push((t, v));
            }
        }
    }

    // ----- 2. Undirected atomic spans -----
    // Multiplicity and direction are dropped on purpose: see the
    // module docs. A BTreeSet also fixes the span order, which fixes
    // the output ring order — the Swift port iterates the same
    // sequence, so the two agree vertex for vertex.
    let mut span_set: BTreeSet<(usize, usize)> = BTreeSet::new();
    for params in seg_params.iter_mut() {
        params.sort_by(|a, b| {
            a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal)
        });
        let mut chain: Vec<usize> = Vec::new();
        for &(_, v) in params.iter() {
            if chain.last() != Some(&v) {
                chain.push(v);
            }
        }
        for w in chain.windows(2) {
            let (u, v) = (w[0], w[1]);
            if u != v {
                span_set.insert(if u < v { (u, v) } else { (v, u) });
            }
        }
    }
    let spans: Vec<(usize, usize)> = span_set.into_iter().collect();
    if spans.is_empty() {
        return Vec::new();
    }

    // ----- 3. Winding classification -----
    // Kept spans, each oriented so the filled region is on its left.
    let mut kept: Vec<(usize, usize)> = Vec::new();
    for (si, &(u, v)) in spans.iter().enumerate() {
        let (ax, ay) = vert_pts[u];
        let (bx, by) = vert_pts[v];
        let mx = (ax + bx) / 2.0;
        let my = (ay + by) / 2.0;
        let dx = bx - ax;
        let dy = by - ay;
        let len = (dx * dx + dy * dy).sqrt();
        if len <= VERT_EPS {
            continue;
        }
        // Probe offset: a quarter of the smaller of this span's length
        // and its midpoint's distance to the nearest other span, so the
        // probe cannot slide past this span's ends nor cross a
        // neighbouring boundary. See the module docs.
        let mut nearest = f64::INFINITY;
        for (sj, &(p, q)) in spans.iter().enumerate() {
            if sj == si {
                continue;
            }
            let d = point_segment_distance((mx, my), vert_pts[p], vert_pts[q]);
            if d < nearest {
                nearest = d;
            }
        }
        let limit = if nearest.is_finite() && nearest > 0.0 && nearest < len {
            nearest
        } else {
            len
        };
        let offset = 0.25 * limit;
        // Unit left normal of u -> v.
        let nx = -dy / len;
        let ny = dx / len;
        let w_left = winding_of_set(rings, (mx + nx * offset, my + ny * offset));
        let w_right = winding_of_set(rings, (mx - nx * offset, my - ny * offset));
        let left_filled = w_left != 0;
        let right_filled = w_right != 0;
        if left_filled == right_filled {
            continue; // interior to the region, or exterior to it
        }
        if left_filled {
            kept.push((u, v));
        } else {
            kept.push((v, u));
        }
    }
    if kept.is_empty() {
        return Vec::new();
    }

    // ----- 4. Chain into rings -----
    // Per-vertex outgoing kept spans, sorted counter-clockwise by
    // direction angle.
    let mut outgoing: Vec<Vec<usize>> = vec![Vec::new(); vert_pts.len()];
    for (ki, &(u, _)) in kept.iter().enumerate() {
        outgoing[u].push(ki);
    }
    let angle_of = |ki: usize| -> f64 {
        let (u, v) = kept[ki];
        let (ax, ay) = vert_pts[u];
        let (bx, by) = vert_pts[v];
        (by - ay).atan2(bx - ax)
    };
    for list in outgoing.iter_mut() {
        list.sort_by(|&a, &b| {
            angle_of(a)
                .partial_cmp(&angle_of(b))
                .unwrap_or(std::cmp::Ordering::Equal)
        });
    }

    let mut used = vec![false; kept.len()];
    let mut out: PolygonSet = Vec::new();
    for start in 0..kept.len() {
        if used[start] {
            continue;
        }
        let mut ring: Ring = Vec::new();
        let mut e = start;
        loop {
            used[e] = true;
            ring.push(vert_pts[kept[e].0]);
            let v = kept[e].1;
            // Angle looking back along the edge we just travelled.
            let (ox, oy) = vert_pts[kept[e].0];
            let (vx, vy) = vert_pts[v];
            let back = (oy - vy).atan2(ox - vx);
            let list = &outgoing[v];
            if list.is_empty() {
                break;
            }
            // First span clockwise from `back`: the largest angle
            // strictly below it, wrapping to the largest overall.
            let mut pick = list[list.len() - 1];
            for &cand in list.iter() {
                if angle_of(cand) < back {
                    pick = cand;
                } else {
                    break;
                }
            }
            if pick == start {
                break;
            }
            if used[pick] {
                // Defensive: a well-formed region boundary never
                // revisits a span, so this cannot fire for valid
                // input. Bail rather than spin.
                break;
            }
            e = pick;
        }
        let ring = dedup_consecutive(&ring);
        if ring.len() >= 3 {
            out.push(ring);
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Winding and sampling
// ---------------------------------------------------------------------------

/// Winding number of `ring` around `point`: signed count of ring
/// edges crossed by a horizontal ray from `point` in the +x
/// direction, where each upward-crossing edge counts +1 and each
/// downward-crossing edge counts −1.
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

/// Total winding of a whole polygon set: the sum over its rings. This
/// is the definition of the input's filled region under the non-zero
/// rule, and the only thing the arrangement path consults.
fn winding_of_set(rings: &PolygonSet, point: (f64, f64)) -> i32 {
    rings.iter().map(|r| winding_number(r, point)).sum()
}

/// Distance from `p` to the segment `a`-`b` (clamped at the ends).
fn point_segment_distance(p: (f64, f64), a: (f64, f64), b: (f64, f64)) -> f64 {
    let dx = b.0 - a.0;
    let dy = b.1 - a.1;
    let len2 = dx * dx + dy * dy;
    if len2 <= 0.0 {
        return dist(p, a);
    }
    let mut t = ((p.0 - a.0) * dx + (p.1 - a.1) * dy) / len2;
    if t < 0.0 {
        t = 0.0;
    } else if t > 1.0 {
        t = 1.0;
    }
    dist(p, (a.0 + t * dx, a.1 + t * dy))
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

    /// Rotate a ring so its lexicographically smallest vertex comes
    /// first, without changing the cyclic order. Lets a test pin an
    /// exact vertex sequence without also pinning which vertex the
    /// traversal happened to start at.
    fn canonical(ring: &Ring) -> Ring {
        let n = ring.len();
        let mut best = 0usize;
        for i in 1..n {
            let (bx, by) = ring[best];
            let (x, y) = ring[i];
            if x < bx || (x == bx && y < by) {
                best = i;
            }
        }
        (0..n).map(|k| ring[(best + k) % n]).collect()
    }

    /// The signed areas of a normalizer result, sorted ascending.
    /// Negative entries are hole boundaries (CW), positive ones are
    /// outer boundaries (CCW).
    fn signed_areas(ps: &PolygonSet) -> Vec<f64> {
        let mut v: Vec<f64> = ps.iter().map(ring_signed_area).collect();
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        v
    }

    /// True if no two non-adjacent edges of `ring` meet — i.e. the
    /// ring is simple, which is the normalizer's whole contract.
    fn is_simple(ring: &Ring) -> bool {
        let n = ring.len();
        for i in 0..n {
            for j in (i + 1)..n {
                let adjacent = j == i + 1 || (i == 0 && j == n - 1);
                let pts = crate::algorithms::arrangement::split_points(
                    ring[i],
                    ring[(i + 1) % n],
                    ring[j],
                    ring[(j + 1) % n],
                );
                if adjacent {
                    // Consecutive edges legitimately meet at exactly
                    // their shared vertex, and nowhere else.
                    if pts.len() != 1 {
                        return false;
                    }
                } else if !pts.is_empty() {
                    return false;
                }
            }
        }
        true
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
        // A CW square (negative signed area). A lone CW ring is a
        // well-formed polygon set — its winding is -1 inside and 0
        // outside, so its boundary IS the boundary of the filled
        // region — and so it takes the fast path and comes back
        // untouched, sign included.
        let input: PolygonSet = vec![vec![(0.0, 0.0), (0.0, 10.0), (10.0, 10.0), (10.0, 0.0)]];
        let out = normalize(&input);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0], input[0]);
        assert!((signed_areas(&out)[0] + 100.0).abs() < 1e-9);
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

    // ----------- Degenerate class: T-junction self-touch -----------

    #[test]
    fn t_junction_self_intersection() {
        // The same bowtie as above, but with (5,5) made an explicit
        // VERTEX of the ring rather than an interior crossing point:
        //   (0,0) -> (5,5) -> (10,10) -> (10,0) -> (0,10) -> close.
        // The edge (10,0)-(0,10) now passes exactly through the ring's
        // own vertex (5,5). The old predicate demanded a strictly
        // interior parameter on BOTH edges, so it saw nothing, called
        // the pentagon simple and returned it whole.
        //
        // Derivation: inserting a vertex on a straight edge cannot
        // change the region, so the answer must be identical to the
        // bowtie's — the two lobes
        //   left  (0,0),(5,5),(0,10): 2A = 0*5-5*0 + 5*10-0*5
        //                                  + 0*0-0*10 = 50 -> +25
        //   right (5,5),(10,0),(10,10): 2A = 5*0-10*5 + 10*10-10*0
        //                                  + 10*5-5*10 = 50 -> +25
        // Both lobes are filled (winding +1 on the left, -1 on the
        // right of the original), so both survive, and both come out
        // CCW because the normalizer orients the filled side left.
        let input: PolygonSet = vec![vec![
            (0.0, 0.0),
            (5.0, 5.0),
            (10.0, 10.0),
            (10.0, 0.0),
            (0.0, 10.0),
        ]];
        let out = normalize(&input);
        assert_eq!(out.len(), 2, "expected two lobes, got {:?}", out);
        let areas = signed_areas(&out);
        assert!((areas[0] - 25.0).abs() < 1e-9, "areas: {:?}", areas);
        assert!((areas[1] - 25.0).abs() < 1e-9, "areas: {:?}", areas);
        let mut got: Vec<Ring> = out.iter().map(canonical).collect();
        got.sort_by(|a, b| a.partial_cmp(b).unwrap());
        assert_eq!(
            got,
            vec![
                vec![(0.0, 0.0), (5.0, 5.0), (0.0, 10.0)],
                vec![(5.0, 5.0), (10.0, 0.0), (10.0, 10.0)],
            ]
        );
        for r in &out {
            assert!(is_simple(r), "output ring not simple: {:?}", r);
        }
    }

    #[test]
    fn pinch_at_a_revisited_vertex_splits_into_two_lobes() {
        // A ring that visits (5,5) twice — a "pinch" rather than a
        // crossing:
        //   (0,0) -> (5,5) -> (10,0) -> (10,10) -> (5,5) -> (0,10)
        // Both meetings are at endpoints of both edges, so again the
        // old strict predicate saw nothing.
        //
        // Derivation: the ring is two triangles joined at (5,5),
        //   (0,0),(5,5),(0,10) -> +25   (as computed above)
        //   (5,5),(10,0),(10,10) -> +25
        // and every point of either is wound exactly once, so both are
        // filled. Total 50 over two simple rings.
        let input: PolygonSet = vec![vec![
            (0.0, 0.0),
            (5.0, 5.0),
            (10.0, 0.0),
            (10.0, 10.0),
            (5.0, 5.0),
            (0.0, 10.0),
        ]];
        let out = normalize(&input);
        assert_eq!(out.len(), 2, "expected two lobes, got {:?}", out);
        assert!((total_area(&out) - 50.0).abs() < 1e-9);
        for r in &out {
            assert_eq!(r.len(), 3, "expected a triangle, got {:?}", r);
            assert!(is_simple(r));
        }
    }

    // ----------- Degenerate class: collinear self-overlap -----------

    #[test]
    fn collinear_self_retrace() {
        // A 10x10 square whose top edge carries a SLIT: the path runs
        // in to (5,5) and straight back out along the same line.
        //   (0,0) -> (10,0) -> (10,10) -> (5,10) -> (5,5) -> (5,10)
        //         -> (0,10) -> close
        // The two slit edges are exact reverses of each other: a
        // collinear overlap over their whole span. The determinant is
        // zero, so the old predicate returned None and the ring came
        // back whole — not simple, with a zero-area spine hanging off
        // its boundary.
        //
        // Derivation. A retraced span contributes nothing to the
        // winding: to its left the count is +1 (from the square) -1 +1
        // = +1, and to its right it is +1 as well, so the region is
        // the same on both sides and the span is not a boundary. What
        // remains is the plain square, with the vertex (5,10) retained
        // (collapsing collinear vertices is the Boolean panel's
        // separate opt-in). Shoelace on (0,0),(10,0),(10,10),(5,10),
        // (0,10): 0 + 100 + 50 + 50 + 0 = 200 -> area 100.
        let input: PolygonSet = vec![vec![
            (0.0, 0.0),
            (10.0, 0.0),
            (10.0, 10.0),
            (5.0, 10.0),
            (5.0, 5.0),
            (5.0, 10.0),
            (0.0, 10.0),
        ]];
        let out = normalize(&input);
        assert_eq!(out.len(), 1, "expected one ring, got {:?}", out);
        assert_eq!(
            canonical(&out[0]),
            vec![
                (0.0, 0.0),
                (10.0, 0.0),
                (10.0, 10.0),
                (5.0, 10.0),
                (0.0, 10.0)
            ]
        );
        let areas = signed_areas(&out);
        assert!((areas[0] - 100.0).abs() < 1e-9, "areas: {:?}", areas);
        assert!(is_simple(&out[0]));
    }

    // ----------- Degenerate class: retrograde loop -----------

    #[test]
    fn retrograde_loop_cancels_under_non_zero_winding() {
        // A ring that traces a big square CCW and also, spliced in via
        // a slit from the corner (0,0), a small COUNTER-rotating loop
        // in its interior:
        //   (0,0) -> (5,2) -> (5,4) -> (7,4) -> (7,2) -> (5,2)
        //         -> (0,0) -> (10,0) -> (10,10) -> (0,10) -> close
        // The inner loop runs CW: shoelace on (5,2),(5,4),(7,4),(7,2)
        // = 10 - 8 - 14 + 4 = -8, so signed area -4.
        //
        // Derivation. Inside the inner loop the winding is +1 (outer
        // square) + (-1) (inner CW loop) = 0, so that region is NOT
        // filled: the loop must survive as a HOLE, not vanish and not
        // fill. In the rest of the square the winding is +1. The slit
        // (0,0)-(5,2) is traversed both ways, so the winding is +1 on
        // both of its sides and it is dropped — the hole is not
        // connected to the outer boundary by a hairline.
        //
        // Expected output therefore: two rings, the square CCW at
        // +100 and the inner loop CW at -4, for a net filled area of
        // 96. Both simple. The old recursive-split normalizer found no
        // proper crossing at all here and returned the whole
        // ten-vertex tangle as if it were one simple ring.
        let input: PolygonSet = vec![vec![
            (0.0, 0.0),
            (5.0, 2.0),
            (5.0, 4.0),
            (7.0, 4.0),
            (7.0, 2.0),
            (5.0, 2.0),
            (0.0, 0.0),
            (10.0, 0.0),
            (10.0, 10.0),
            (0.0, 10.0),
        ]];
        let out = normalize(&input);
        assert_eq!(out.len(), 2, "expected square + hole, got {:?}", out);
        let areas = signed_areas(&out);
        assert!((areas[0] + 4.0).abs() < 1e-9, "areas: {:?}", areas);
        assert!((areas[1] - 100.0).abs() < 1e-9, "areas: {:?}", areas);
        // Net filled area = outer minus hole.
        assert!((areas.iter().sum::<f64>() - 96.0).abs() < 1e-9);
        let mut got: Vec<Ring> = out.iter().map(canonical).collect();
        got.sort_by(|a, b| a.partial_cmp(b).unwrap());
        assert_eq!(
            got,
            vec![
                vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)],
                vec![(5.0, 2.0), (5.0, 4.0), (7.0, 4.0), (7.0, 2.0)],
            ]
        );
        for r in &out {
            assert!(is_simple(r), "output ring not simple: {:?}", r);
        }
    }

    #[test]
    fn co_rotating_spliced_loop_fuses_into_one_ring() {
        // The same shape as above but with the inner loop running the
        // SAME way as the outer square (CCW): (5,2) -> (7,2) -> (7,4)
        // -> (5,4). Inside it the winding is +1 + 1 = 2, which is
        // non-zero, so that region is filled — and being filled on
        // both sides of the loop, the loop is not a boundary at all.
        //
        // Derivation: the filled region is exactly the square, so the
        // answer is one CCW ring of area 100. This is the companion of
        // the test above: same slit, same loop, opposite winding,
        // completely different answer — which is the whole point of
        // evaluating the winding rather than counting rings.
        let input: PolygonSet = vec![vec![
            (0.0, 0.0),
            (5.0, 2.0),
            (7.0, 2.0),
            (7.0, 4.0),
            (5.0, 4.0),
            (5.0, 2.0),
            (0.0, 0.0),
            (10.0, 0.0),
            (10.0, 10.0),
            (0.0, 10.0),
        ]];
        let out = normalize(&input);
        assert_eq!(out.len(), 1, "expected one ring, got {:?}", out);
        assert_eq!(
            canonical(&out[0]),
            vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
        );
        assert!((signed_areas(&out)[0] - 100.0).abs() < 1e-9);
    }

    // ----------- Inter-ring relations: NOT this module's call -----------
    //
    // `boolean::PolygonSet` is contractually a flat list of rings under
    // the EVEN-ODD rule, with orientation explicitly outside the
    // contract. So the normalizer must not read a set's rings as one
    // non-zero-wound region: doing so re-interprets the operand. The
    // tests below pin that, ring relation by ring relation, so a
    // later widening of the scope cannot happen silently. The
    // disagreement between the two rules is written up in the module
    // docs as a spec question for the council.

    #[test]
    fn nested_co_oriented_rings_keep_the_hole() {
        // Two CCW rings of one set, one nested inside the other. Under
        // even-odd (the ratified PolygonSet contract) the inner ring is
        // a HOLE: a ray from a point inside it crosses two ring edges.
        // Under non-zero it would instead be solid, winding 1 + 1 = 2.
        //
        // Both rings are individually simple, so both pass through
        // untouched and the even-odd reading is preserved for the sweep
        // to act on. Had the normalizer taken the non-zero reading of
        // the whole set it would have deleted the inner ring here — and
        // with it every donut expressed the natural way, which is what
        // `boolean::tests::intersect_with_holed_polygon_preserves_hole`
        // exercises end to end.
        let outer = vec![(0.0, 0.0), (20.0, 0.0), (20.0, 20.0), (0.0, 20.0)];
        let inner = vec![(5.0, 5.0), (15.0, 5.0), (15.0, 15.0), (5.0, 15.0)];
        let out = normalize(&vec![outer.clone(), inner.clone()]);
        assert_eq!(out, vec![outer, inner]);
    }

    #[test]
    fn nested_opposed_rings_keep_the_hole() {
        // The same nesting with the inner ring wound the other way.
        // Even-odd does not care about orientation, so the answer must
        // be identical to the co-oriented case above: both rings
        // through untouched, the hole intact.
        let outer = vec![(0.0, 0.0), (20.0, 0.0), (20.0, 20.0), (0.0, 20.0)];
        let inner = vec![(5.0, 5.0), (5.0, 15.0), (15.0, 15.0), (15.0, 5.0)];
        let out = normalize(&vec![outer.clone(), inner.clone()]);
        assert_eq!(out, vec![outer, inner]);
    }

    #[test]
    fn overlapping_rings_are_left_for_the_sweep() {
        // Two CCW squares of one set that genuinely overlap: [0,10]^2
        // and [5,15]^2. Their boundaries CROSS, at (10,5) and (5,10) —
        // so this is the case where a set-wide reading is most
        // tempting. Under even-odd the overlap [5,10]^2 is outside the
        // region (two crossings), making the set a symmetric
        // difference; under non-zero it would be the union. Each ring
        // is simple on its own, so both pass through and the sweep
        // decides.
        let a = vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        let b = vec![(5.0, 5.0), (15.0, 5.0), (15.0, 15.0), (5.0, 15.0)];
        let out = normalize(&vec![a.clone(), b.clone()]);
        assert_eq!(out, vec![a, b]);
    }

    #[test]
    fn rings_sharing_a_collinear_edge_pass_through() {
        // Two CCW squares of one set sharing a full edge: [0,10]x[0,10]
        // and [10,20]x[0,10]. The shared span x=10 is traced upward by
        // the first ring and downward by the second — an INTER-ring
        // collinear overlap. Each ring is still simple by itself, so
        // both pass through; fusing them across the shared span would
        // be the non-zero reading of the set.
        let a = vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        let b = vec![(10.0, 0.0), (20.0, 0.0), (20.0, 10.0), (10.0, 10.0)];
        let out = normalize(&vec![a.clone(), b.clone()]);
        assert_eq!(out, vec![a, b]);
    }

    #[test]
    fn disjoint_rings_take_the_fast_path_untouched() {
        // Two CCW squares that share nothing. Pins that widening the
        // intersection predicate did not drag the ordinary case onto
        // the arrangement path — the rings come back bit-identical, in
        // input order.
        let a = vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        let b = vec![(20.0, 0.0), (30.0, 0.0), (30.0, 10.0), (20.0, 10.0)];
        let out = normalize(&vec![a.clone(), b.clone()]);
        assert_eq!(out, vec![a, b]);
    }

    #[test]
    fn a_degenerate_ring_does_not_take_its_siblings_with_it() {
        // One good ring plus one zero-area collinear ring. Per-ring
        // scope means the collinear one is dropped (it encloses
        // nothing) and the good one survives verbatim — a set-wide
        // rebuild would have had to decide what the degenerate ring
        // "meant" for its sibling.
        let a = vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        let flat = vec![(20.0, 0.0), (25.0, 0.0), (30.0, 0.0)];
        let out = normalize(&vec![a.clone(), flat]);
        assert_eq!(out, vec![a]);
    }

    #[test]
    fn zero_area_collinear_ring_is_dropped() {
        // Three collinear vertices enclose nothing, so the non-zero
        // region is empty and the output must be empty too.
        let input: PolygonSet = vec![vec![(0.0, 0.0), (5.0, 0.0), (10.0, 0.0)]];
        assert!(normalize(&input).is_empty());
    }
}
