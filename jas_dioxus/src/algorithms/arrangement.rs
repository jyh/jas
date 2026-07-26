//! Shared arrangement primitives: the segment-splitting predicate and
//! the epsilon policy that [`crate::algorithms::planar`] and
//! [`crate::algorithms::boolean_normalize`] both build on.
//!
// Module-wide allow: this is a support module for two algorithms that
// are themselves tested but not yet wired into the document model.
#![allow(dead_code)]
//!
//! # Why one module
//!
//! Both the planar-graph extractor and the ring normalizer need the
//! same first stage: take a bag of line segments and split them until
//! the result is a **conforming arrangement** —
//!
//!   1. no segment's interior contains another segment's endpoint
//!      (no T-junctions left unsplit), and
//!   2. no two segments overlap over a span of positive length (no
//!      collinear overlap left unsplit).
//!
//! Both properties are prerequisites for any winding argument: a
//! T-junction that is not split hides a vertex from the topology, and
//! an unsplit collinear overlap hides the fact that two boundaries
//! coincide. Sharing one predicate is also what keeps the two
//! algorithms — and the Rust and Swift ports of each — answering
//! identically. The Swift mirror is
//! `JasSwift/Sources/Algorithms/Arrangement.swift`.
//!
//! # Epsilon policy
//!
//! Deliberately unchanged from the pre-existing convention in these
//! two modules, so that fixing the degenerate cases does not also
//! shift the tolerance behaviour of the non-degenerate ones:
//!
//!   - [`VERT_EPS`] (1e-9, absolute, input units) — two points are the
//!     same vertex if they are closer than this. Also the zero-length
//!     segment threshold.
//!   - [`PARAM_EPS`] (1e-9, on the normalized segment parameter) — a
//!     parameter within this of 0 or 1 *is* 0 or 1, i.e. the meeting
//!     is at an endpoint rather than in the interior.
//!   - [`DENOM_EPS`] (1e-12, on the raw 2x2 determinant) — below this
//!     the pair is treated as parallel. Pairs this close to parallel
//!     are then either collinear (handled by the overlap branch) or
//!     crossing at a grazing angle far outside both segments, which
//!     the parametric branch would reject anyway.
//!   - [`COLLINEAR_EPS`] (1e-9, absolute perpendicular distance) — a
//!     parallel pair is collinear if both of one segment's endpoints
//!     are within this of the other's infinite line.
//!
//! The one deliberate change of *behaviour* is inclusivity: the old
//! predicate demanded a strictly interior crossing on both segments
//! (`0 < s < 1` and `0 < t < 1`), which is exactly what made
//! T-junctions invisible. [`split_points`] accepts the closed range
//! on both parameters and additionally reports collinear overlaps.

/// A 2D point.
pub type Point = (f64, f64);

/// Vertex coincidence and zero-length tolerance, in input units.
pub const VERT_EPS: f64 = 1e-9;

/// Parameter-band epsilon: |s| <= PARAM_EPS means "at the start".
pub const PARAM_EPS: f64 = 1e-9;

/// Determinant tolerance for parallel-pair detection.
pub const DENOM_EPS: f64 = 1e-12;

/// Perpendicular-distance tolerance for collinearity of a parallel
/// pair, in input units.
pub const COLLINEAR_EPS: f64 = 1e-9;

/// Euclidean distance.
pub fn dist(a: Point, b: Point) -> f64 {
    let dx = a.0 - b.0;
    let dy = a.1 - b.1;
    (dx * dx + dy * dy).sqrt()
}

/// Linear-search vertex dedup: return the index of an existing vertex
/// within [`VERT_EPS`] of `pt`, or push `pt` and return its index.
pub fn add_or_find_vertex(verts: &mut Vec<Point>, pt: Point) -> usize {
    for (i, v) in verts.iter().enumerate() {
        if dist(*v, pt) < VERT_EPS {
            return i;
        }
    }
    verts.push(pt);
    verts.len() - 1
}

fn clamp01(v: f64) -> f64 {
    if v < 0.0 {
        0.0
    } else if v > 1.0 {
        1.0
    } else {
        v
    }
}

/// Perpendicular distance from `p` to the infinite line through
/// `a1`, `a2`. Returns the distance to `a1` for a degenerate segment.
fn line_distance(a1: Point, a2: Point, p: Point) -> f64 {
    let dx = a2.0 - a1.0;
    let dy = a2.1 - a1.1;
    let len = (dx * dx + dy * dy).sqrt();
    if len <= VERT_EPS {
        return dist(a1, p);
    }
    ((p.0 - a1.0) * dy - (p.1 - a1.1) * dx).abs() / len
}

/// Parameter of `p` projected onto segment `a1`-`a2`, clamped to
/// `[0, 1]`. Returns 0 for a degenerate segment.
fn project_param(a1: Point, a2: Point, p: Point) -> f64 {
    let dx = a2.0 - a1.0;
    let dy = a2.1 - a1.1;
    let len2 = dx * dx + dy * dy;
    if len2 <= 0.0 {
        return 0.0;
    }
    clamp01(((p.0 - a1.0) * dx + (p.1 - a1.1) * dy) / len2)
}

/// Snap a parameter that is within [`PARAM_EPS`] of an endpoint onto
/// that endpoint exactly, then clamp into `[0, 1]`.
fn snap_param(v: f64) -> f64 {
    if v <= PARAM_EPS {
        0.0
    } else if v >= 1.0 - PARAM_EPS {
        1.0
    } else {
        v
    }
}

/// Every arrangement-relevant meeting point of segments `a1`-`a2` and
/// `b1`-`b2`, as `(point, s, t)` where `s` is the point's parameter on
/// `a` and `t` its parameter on `b`.
///
/// Reports, in one predicate:
///
///   - **proper crossings** — `s` and `t` both strictly interior;
///   - **T-junctions** — one parameter at an endpoint, the other
///     interior. These are the cases the old strict predicate dropped;
///   - **endpoint coincidences** — both parameters at endpoints. Cheap
///     no-ops for the caller (the vertex already exists) but reported
///     for uniformity;
///   - **collinear overlaps** — for a parallel, collinear pair whose
///     spans overlap, the two ends of the overlap. One point if the
///     overlap degenerates to a single touch.
///
/// Returned points are taken from an existing endpoint whenever one of
/// the parameters sits at an endpoint, so a T-junction vertex lands
/// *exactly* on the vertex that caused it rather than on a rounded
/// re-computation of it. That exactness is what lets the caller's
/// vertex dedup fuse the two into one.
pub fn split_points(a1: Point, a2: Point, b1: Point, b2: Point) -> Vec<(Point, f64, f64)> {
    let dxa = a2.0 - a1.0;
    let dya = a2.1 - a1.1;
    let dxb = b2.0 - b1.0;
    let dyb = b2.1 - b1.1;
    let denom = dxa * dyb - dya * dxb;

    if denom.abs() > DENOM_EPS {
        let dxab = a1.0 - b1.0;
        let dyab = a1.1 - b1.1;
        let s = (dxb * dyab - dyb * dxab) / denom;
        let t = (dxa * dyab - dya * dxab) / denom;
        if s < -PARAM_EPS || s > 1.0 + PARAM_EPS || t < -PARAM_EPS || t > 1.0 + PARAM_EPS {
            return Vec::new();
        }
        let s = snap_param(s);
        let t = snap_param(t);
        let p = if s == 0.0 {
            a1
        } else if s == 1.0 {
            a2
        } else if t == 0.0 {
            b1
        } else if t == 1.0 {
            b2
        } else {
            (a1.0 + s * dxa, a1.1 + s * dya)
        };
        return vec![(p, s, t)];
    }

    // Parallel. Only collinear pairs can overlap.
    let len2a = dxa * dxa + dya * dya;
    if len2a <= 0.0 {
        return Vec::new();
    }
    if line_distance(a1, a2, b1) > COLLINEAR_EPS || line_distance(a1, a2, b2) > COLLINEAR_EPS {
        return Vec::new();
    }

    // Project b's endpoints into a's parameter space (unclamped, so a
    // span that starts before a1 or ends after a2 is detected).
    let tb1 = ((b1.0 - a1.0) * dxa + (b1.1 - a1.1) * dya) / len2a;
    let tb2 = ((b2.0 - a1.0) * dxa + (b2.1 - a1.1) * dya) / len2a;
    let (lo, hi) = if tb1 <= tb2 { (tb1, tb2) } else { (tb2, tb1) };
    let start = if lo > 0.0 { lo } else { 0.0 };
    let end = if hi < 1.0 { hi } else { 1.0 };
    if end < start - PARAM_EPS {
        return Vec::new();
    }

    let mut out: Vec<(Point, f64, f64)> = Vec::new();
    let ends = if (end - start).abs() <= PARAM_EPS {
        vec![start]
    } else {
        vec![start, end]
    };
    for u in ends {
        let s = snap_param(u);
        // The overlap end is always one of the four original
        // endpoints; pick it exactly rather than re-deriving it.
        let p = if s == 0.0 {
            a1
        } else if s == 1.0 {
            a2
        } else if (u - tb1).abs() <= PARAM_EPS {
            b1
        } else if (u - tb2).abs() <= PARAM_EPS {
            b2
        } else {
            (a1.0 + u * dxa, a1.1 + u * dya)
        };
        let t = snap_param(project_param(b1, b2, p));
        out.push((p, s, t));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proper_crossing_reports_interior_parameters() {
        let pts = split_points((0.0, 0.0), (10.0, 10.0), (10.0, 0.0), (0.0, 10.0));
        assert_eq!(pts.len(), 1);
        let (p, s, t) = pts[0];
        assert!((p.0 - 5.0).abs() < 1e-12 && (p.1 - 5.0).abs() < 1e-12);
        assert!((s - 0.5).abs() < 1e-12);
        assert!((t - 0.5).abs() < 1e-12);
    }

    #[test]
    fn t_junction_reports_the_exact_touching_endpoint() {
        // b's start (5,0) sits in the interior of a. The reported
        // point must be b1 itself, bit-exact, not 5.0000000001.
        let pts = split_points((0.0, 0.0), (10.0, 0.0), (5.0, 0.0), (5.0, 5.0));
        assert_eq!(pts.len(), 1);
        let (p, s, t) = pts[0];
        assert_eq!(p, (5.0, 0.0));
        assert!((s - 0.5).abs() < 1e-12);
        assert_eq!(t, 0.0);
    }

    #[test]
    fn endpoint_coincidence_is_reported_at_the_shared_vertex() {
        let pts = split_points((0.0, 0.0), (10.0, 0.0), (0.0, 0.0), (0.0, 10.0));
        assert_eq!(pts.len(), 1);
        assert_eq!(pts[0].0, (0.0, 0.0));
        assert_eq!(pts[0].1, 0.0);
        assert_eq!(pts[0].2, 0.0);
    }

    #[test]
    fn parallel_but_not_collinear_pair_has_no_split_points() {
        assert!(split_points((0.0, 0.0), (10.0, 0.0), (0.0, 1.0), (10.0, 1.0)).is_empty());
    }

    #[test]
    fn crossing_outside_both_segments_has_no_split_points() {
        // The lines meet at (20,0), beyond the end of both segments.
        assert!(split_points((0.0, 0.0), (10.0, 0.0), (30.0, 10.0), (25.0, 5.0)).is_empty());
    }

    #[test]
    fn collinear_partial_overlap_reports_both_overlap_ends() {
        // a covers x in [0,10]; b covers x in [4,20]. Overlap [4,10].
        let pts = split_points((0.0, 0.0), (10.0, 0.0), (4.0, 0.0), (20.0, 0.0));
        assert_eq!(pts.len(), 2);
        assert_eq!(pts[0].0, (4.0, 0.0));
        assert!((pts[0].1 - 0.4).abs() < 1e-12);
        assert_eq!(pts[0].2, 0.0);
        assert_eq!(pts[1].0, (10.0, 0.0));
        assert_eq!(pts[1].1, 1.0);
        assert!((pts[1].2 - 0.375).abs() < 1e-12);
    }

    #[test]
    fn collinear_reversed_overlap_reports_both_overlap_ends() {
        // Same spans as above but b runs the other way; the answer
        // must not depend on b's direction.
        let pts = split_points((0.0, 0.0), (10.0, 0.0), (20.0, 0.0), (4.0, 0.0));
        assert_eq!(pts.len(), 2);
        assert_eq!(pts[0].0, (4.0, 0.0));
        assert_eq!(pts[1].0, (10.0, 0.0));
    }

    #[test]
    fn collinear_contained_span_reports_the_inner_ends() {
        // b sits strictly inside a: both of b's endpoints split a.
        let pts = split_points((0.0, 0.0), (10.0, 0.0), (3.0, 0.0), (7.0, 0.0));
        assert_eq!(pts.len(), 2);
        assert_eq!(pts[0].0, (3.0, 0.0));
        assert_eq!(pts[1].0, (7.0, 0.0));
    }

    #[test]
    fn collinear_touching_at_one_point_reports_one_point() {
        // a covers [0,10], b covers [10,20]: they meet only at x=10.
        let pts = split_points((0.0, 0.0), (10.0, 0.0), (10.0, 0.0), (20.0, 0.0));
        assert_eq!(pts.len(), 1);
        assert_eq!(pts[0].0, (10.0, 0.0));
    }

    #[test]
    fn collinear_disjoint_spans_have_no_split_points() {
        assert!(split_points((0.0, 0.0), (10.0, 0.0), (20.0, 0.0), (30.0, 0.0)).is_empty());
    }

    #[test]
    fn collinear_full_retrace_reports_both_endpoints() {
        // A segment and its exact reverse — the collinear self-overlap
        // that a retraced spike produces.
        let pts = split_points((5.0, 10.0), (5.0, 5.0), (5.0, 5.0), (5.0, 10.0));
        assert_eq!(pts.len(), 2);
        assert_eq!(pts[0].0, (5.0, 10.0));
        assert_eq!(pts[1].0, (5.0, 5.0));
    }
}
