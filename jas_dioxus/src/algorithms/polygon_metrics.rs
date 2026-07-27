//! Region metrics for the boolean conformance harness — the *measuring
//! instruments*, not the thing measured.
//!
//! Every `boolean` and `boolean_normalize` golden is expressed in these
//! functions: a vector pins `area`, `ring_count`, `all_rings_simple` and a
//! list of inside/outside sample answers, and all of those come from here.
//! They were hand-copied — once into `src/bin/algorithm_roundtrip.rs`,
//! once into `boolean.rs`'s test module, and `ring_signed_area` again into
//! `boolean_normalize.rs`'s — with nothing comparing the copies, and
//! mirrored again by hand into Swift. A drift in a measuring instrument
//! silently rewrites what the boolean families appear to prove, so this
//! module is the single Rust copy. Its Swift mirror is
//! `JasSwift/Sources/Algorithms/PolygonMetrics.swift`.
//!
//! **Fill rule.** These are even-odd metrics. `transcripts/BOOLEAN.md`
//! clause 1 fixes the standing convention that a bare `PolygonSet` crossing
//! a function boundary inside the algorithm layer means *even-odd, already
//! canonical*, and clause 4 makes every generated boolean result declare
//! even-odd. Both things this module is pointed at — a boolean result and a
//! `normalize` output — are therefore read under even-odd.

use crate::algorithms::boolean::{PolygonSet, Ring};

type Point = (f64, f64);

/// Shoelace signed area of one ring. The sign carries the winding
/// direction; the magnitude is the enclosed area only when the ring does
/// not cross itself (a self-crossing ring's lobes cancel).
pub fn ring_signed_area(ring: &Ring) -> f64 {
    if ring.len() < 3 {
        return 0.0;
    }
    let mut sum = 0.0;
    let n = ring.len();
    for i in 0..n {
        let (x1, y1) = ring[i];
        let (x2, y2) = ring[(i + 1) % n];
        sum += x1 * y2 - x2 * y1;
    }
    sum * 0.5
}

/// Standard ray-casting point-in-ring test, treating the ring as closed
/// (last vertex joins the first). Points exactly on the boundary are
/// unspecified; callers pick sample points away from edges.
pub fn point_in_ring(ring: &Ring, pt: Point) -> bool {
    let (px, py) = pt;
    let n = ring.len();
    if n < 3 {
        return false;
    }
    let mut inside = false;
    let mut j = n - 1;
    for i in 0..n {
        let (xi, yi) = ring[i];
        let (xj, yj) = ring[j];
        let intersects = ((yi > py) != (yj > py)) && (px < (xj - xi) * (py - yi) / (yj - yi) + xi);
        if intersects {
            inside = !inside;
        }
        j = i;
    }
    inside
}

/// Even-odd "is this point in the region" — true iff `pt` lies inside an
/// odd number of rings.
pub fn point_in_polygon_set(ps: &PolygonSet, pt: Point) -> bool {
    let mut count = 0;
    for ring in ps {
        if point_in_ring(ring, pt) {
            count += 1;
        }
    }
    count % 2 == 1
}

/// Area of a region, as the harness has computed it up to now: sum
/// `|shoelace|` over the rings, signing each ring by its NESTING DEPTH —
/// the number of other rings that contain the ring's FIRST VERTEX, even
/// meaning plus and odd meaning minus.
///
/// Moved here verbatim from `src/bin/algorithm_roundtrip.rs` and
/// `boolean.rs`'s test module so that there is one Rust copy; behaviour
/// is unchanged by the move. The depth heuristic is correct only for a
/// canonical set (pairwise disjoint or strictly nested simple rings) and
/// is replaced in the commit that follows.
pub fn polygon_set_area(ps: &PolygonSet) -> f64 {
    let mut total = 0.0;
    for (i, ring) in ps.iter().enumerate() {
        let a = ring_signed_area(ring).abs();
        let mut depth = 0;
        if let Some(&pt) = ring.first() {
            for (j, other) in ps.iter().enumerate() {
                if i == j {
                    continue;
                }
                if point_in_ring(other, pt) {
                    depth += 1;
                }
            }
        }
        if depth % 2 == 0 {
            total += a;
        } else {
            total -= a;
        }
    }
    total
}

/// Check that a ring is simple: no two of its edges meet except where
/// consecutive edges share their one common vertex.
///
/// This deliberately uses the full arrangement predicate rather than a
/// proper-crossing test. A proper-crossing test reports `true` for a ring
/// carrying a T-junction (a vertex sitting in another edge's interior) or
/// a collinear self-overlap (an edge doubling back along itself), because
/// neither is a strict interior crossing — so the corpus's
/// `all_rings_simple` flag used to stay green on exactly the degeneracies
/// the normalizer exists to remove.
///
/// INTRA-ring only: it says nothing about one ring overlapping another.
pub fn is_ring_simple(ring: &Ring) -> bool {
    use crate::algorithms::arrangement::split_points;
    let n = ring.len();
    if n < 3 {
        return true;
    }
    for i in 0..n {
        for j in (i + 1)..n {
            let adjacent = j == i + 1 || (i == 0 && j == n - 1);
            let pts = split_points(ring[i], ring[(i + 1) % n], ring[j], ring[(j + 1) % n]);
            if adjacent {
                // Consecutive edges legitimately meet at exactly their
                // shared vertex, and nowhere else.
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

pub fn all_rings_simple(ps: &PolygonSet) -> bool {
    ps.iter().all(is_ring_simple)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sq(x0: f64, y0: f64, x1: f64, y1: f64) -> Ring {
        vec![(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    }

    // The canonical cases: pairwise disjoint or strictly nested simple
    // rings, where the nesting-depth heuristic is correct. They are here
    // so that whatever replaces it is pinned as a STRICT improvement.

    #[test]
    fn single_square_area_is_its_shoelace() {
        assert_eq!(polygon_set_area(&vec![sq(0.0, 0.0, 10.0, 10.0)]), 100.0);
    }

    #[test]
    fn empty_set_has_zero_area() {
        assert_eq!(polygon_set_area(&Vec::new()), 0.0);
    }

    #[test]
    fn ring_with_two_vertices_bounds_nothing() {
        assert_eq!(polygon_set_area(&vec![vec![(0.0, 0.0), (10.0, 0.0)]]), 0.0);
    }

    #[test]
    fn nested_square_reads_as_a_hole() {
        // 10x10 outer minus 4x4 inner.
        let ps = vec![sq(0.0, 0.0, 10.0, 10.0), sq(3.0, 3.0, 7.0, 7.0)];
        assert_eq!(polygon_set_area(&ps), 84.0);
    }

    #[test]
    fn three_nested_squares_alternate() {
        // 144 - 64 + 16.
        let ps = vec![
            sq(0.0, 0.0, 12.0, 12.0),
            sq(2.0, 2.0, 10.0, 10.0),
            sq(4.0, 4.0, 8.0, 8.0),
        ];
        assert_eq!(polygon_set_area(&ps), 96.0);
    }

    #[test]
    fn ring_signed_area_carries_the_winding_sign() {
        let ccw = sq(0.0, 0.0, 10.0, 10.0);
        let mut cw = ccw.clone();
        cw.reverse();
        assert_eq!(ring_signed_area(&ccw), 100.0);
        assert_eq!(ring_signed_area(&cw), -100.0);
    }

    #[test]
    fn point_in_polygon_set_is_even_odd() {
        let ps = vec![sq(0.0, 0.0, 10.0, 10.0), sq(3.0, 3.0, 7.0, 7.0)];
        assert!(point_in_polygon_set(&ps, (1.5, 5.0)));
        assert!(!point_in_polygon_set(&ps, (5.0, 5.0)));
        assert!(!point_in_polygon_set(&ps, (12.0, 5.0)));
    }

    #[test]
    fn is_ring_simple_rejects_a_self_crossing_ring() {
        assert!(is_ring_simple(&sq(0.0, 0.0, 10.0, 10.0)));
        assert!(!is_ring_simple(&vec![
            (0.0, 0.0),
            (10.0, 0.0),
            (0.0, 10.0),
            (10.0, 10.0)
        ]));
    }
}
