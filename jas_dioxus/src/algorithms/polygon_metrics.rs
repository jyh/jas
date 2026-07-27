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
//! module is the single Rust copy and the `polygon_metrics` corpus
//! family pins its outputs against independently-derived expectations.
//! Its Swift mirror is `JasSwift/Sources/Algorithms/PolygonMetrics.swift`.
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

/// Every directed edge of every ring. Rings with fewer than three
/// vertices bound no region and are skipped.
fn edges(ps: &PolygonSet) -> Vec<(Point, Point)> {
    let mut out = Vec::new();
    for ring in ps {
        let n = ring.len();
        if n < 3 {
            continue;
        }
        for i in 0..n {
            out.push((ring[i], ring[(i + 1) % n]));
        }
    }
    out
}

/// The y at which two edges cross, if they do. Liberal on purpose:
/// endpoint touches count, and only exactly-parallel pairs are rejected.
/// The value is used solely to subdivide the scanline bands in
/// `polygon_set_area`, and an extra band boundary cannot change that
/// integral — a missing one can.
fn crossing_y(a: (Point, Point), b: (Point, Point)) -> Option<f64> {
    let ((ax1, ay1), (ax2, ay2)) = a;
    let ((bx1, by1), (bx2, by2)) = b;
    let dxa = ax2 - ax1;
    let dya = ay2 - ay1;
    let dxb = bx2 - bx1;
    let dyb = by2 - by1;
    let denom = dxa * dyb - dya * dxb;
    if denom == 0.0 {
        return None;
    }
    let dxab = ax1 - bx1;
    let dyab = ay1 - by1;
    let s = (dxb * dyab - dyb * dxab) / denom;
    let t = (dxa * dyab - dya * dxab) / denom;
    if !(0.0..=1.0).contains(&s) || !(0.0..=1.0).contains(&t) {
        return None;
    }
    Some(ay1 + s * dya)
}

/// Total width of the odd-parity part of the horizontal line at `y`.
///
/// Every edge strictly straddling `y` contributes one crossing x. Sorted,
/// those crossings alternate outside/inside/outside/…, so the odd-parity
/// measure is the sum of the 1st-to-2nd, 3rd-to-4th, … gaps. Horizontal
/// edges straddle nothing and drop out, which is what the even-odd rule
/// wants.
fn odd_parity_width(edges: &[(Point, Point)], y: f64) -> f64 {
    let mut xs: Vec<f64> = Vec::new();
    for &((x1, y1), (x2, y2)) in edges {
        let (lo, hi) = if y1 < y2 { (y1, y2) } else { (y2, y1) };
        if y > lo && y < hi {
            xs.push(x1 + (y - y1) * (x2 - x1) / (y2 - y1));
        }
    }
    xs.sort_by(f64::total_cmp);
    let mut total = 0.0;
    let mut i = 0;
    while i + 1 < xs.len() {
        total += xs[i + 1] - xs[i];
        i += 2;
    }
    total
}

/// Even-odd net area of a ring set — the true measure of the region, for
/// **any** ring set, including ones whose rings partially overlap each
/// other or cross themselves.
///
/// This replaces a nesting-depth heuristic that signed each ring by how
/// many other rings contained its **first vertex** (even → plus, odd →
/// minus) and summed `|shoelace|`. That is right only for a canonical set
/// — pairwise disjoint or strictly nested simple rings — and the two ways
/// it was wrong are exactly the two the boolean corpus most needs to see:
/// two partially overlapping rings both score depth 0, so it reported
/// `A1 + A2` instead of `A1 + A2 − 2·overlap`, and because the probe is
/// the first vertex, the answer moved when a ring was merely *listed*
/// from a different vertex. Since `is_ring_simple` is intra-ring only,
/// the corpus then had no instrument that could see inter-ring partial
/// overlap at all, and a normalizer regression leaving such an overlap in
/// its output could satisfy every golden.
///
/// Method: sweep in y. Cut the plane into bands at every vertex y and
/// every edge-edge crossing y. Inside one open band no edge starts, ends
/// or changes places with another, so `odd_parity_width` is *linear* in y
/// there; the mean of a linear function over an interval is the average
/// of its values at the interval's quarter and three-quarter points, so
/// `h · (w(¼) + w(¾)) / 2` is the band's exact contribution — and both
/// samples sit strictly inside the band, which keeps every vertex off the
/// scanline. Only arithmetic is used: no `arrangement`, no `planar`, no
/// `boolean`, so the instrument does not lean on anything it measures.
///
/// Cost is O(E²) for the crossing scan plus O(B·E) for the bands, where
/// B ≤ 2V + (number of crossings). The corpus's ring sets are tens of
/// vertices.
pub fn polygon_set_area(ps: &PolygonSet) -> f64 {
    let edges = edges(ps);
    if edges.is_empty() {
        return 0.0;
    }
    let mut ys: Vec<f64> = Vec::with_capacity(edges.len() * 2);
    for &(p, q) in &edges {
        ys.push(p.1);
        ys.push(q.1);
    }
    for i in 0..edges.len() {
        for j in (i + 1)..edges.len() {
            if let Some(y) = crossing_y(edges[i], edges[j]) {
                ys.push(y);
            }
        }
    }
    ys.sort_by(f64::total_cmp);
    ys.dedup();
    let mut total = 0.0;
    for w in ys.windows(2) {
        let (y0, y1) = (w[0], w[1]);
        let h = y1 - y0;
        if !(h > 0.0) {
            continue;
        }
        let a = odd_parity_width(&edges, y0 + h * 0.25);
        let b = odd_parity_width(&edges, y0 + h * 0.75);
        total += h * (a + b) * 0.5;
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

    // The repair. Each of these was RED against the nesting-depth
    // metric, and each comment records what that metric returned, so a
    // reader can check the expectation does not coincide with the bug's
    // output. Every number is derived from first principles (cell
    // decomposition on a grid the vertices lie on) and cross-checked
    // against a dense-grid Riemann sum, never read back from an
    // implementation.

    #[test]
    fn half_overlapping_squares_lose_the_overlap_twice() {
        // Two 10x10 squares overlapping in a 5x10 band: the odd-parity
        // region is the two 5x10 strips, 100. Depth metric: 0.0.
        let ps = vec![sq(0.0, 0.0, 10.0, 10.0), sq(5.0, 0.0, 15.0, 10.0)];
        assert_eq!(polygon_set_area(&ps), 100.0);
    }

    #[test]
    fn corner_overlapping_squares_lose_the_overlap_twice() {
        // 4x4 corner overlap: 100 + 100 - 2*16. Depth metric: 0.0,
        // because ring 2 is listed from (6,6), which is inside ring 1.
        let ps = vec![
            sq(0.0, 0.0, 10.0, 10.0),
            vec![(6.0, 6.0), (16.0, 6.0), (16.0, 16.0), (6.0, 16.0)],
        ];
        assert_eq!(polygon_set_area(&ps), 168.0);
    }

    #[test]
    fn area_does_not_depend_on_which_vertex_a_ring_starts_at() {
        // Same two squares and the same cyclic order as the test above,
        // rotated to start at (16,6), which is OUTSIDE ring 1. The depth
        // metric answered 0.0 there and 200.0 here for one region; the
        // even-odd measure answers 168.0 for both.
        let ps = vec![
            sq(0.0, 0.0, 10.0, 10.0),
            vec![(16.0, 6.0), (16.0, 16.0), (6.0, 16.0), (6.0, 6.0)],
        ];
        assert_eq!(polygon_set_area(&ps), 168.0);
    }

    #[test]
    fn triple_overlap_is_parity_not_pairwise_subtraction() {
        // Three 6x6 squares on a 3-unit grid. Coverage per 3x3 cell,
        // bottom row first: 1,2,1 / 1,3,2 / 0,1,1 — six ODD cells, so
        // 6*9 = 54. Charging every pairwise overlap twice would instead
        // give 108 - 2*(9 + 18 + 18) = 18, so this pins that the rule is
        // parity and not pairwise subtraction. Depth metric: 108.0.
        let ps = vec![
            sq(0.0, 0.0, 6.0, 6.0),
            vec![(9.0, 9.0), (3.0, 9.0), (3.0, 3.0), (9.0, 3.0)],
            vec![(9.0, 0.0), (9.0, 6.0), (3.0, 6.0), (3.0, 0.0)],
        ];
        assert_eq!(polygon_set_area(&ps), 54.0);
    }

    #[test]
    fn self_crossing_ring_measures_both_lobes() {
        // A bowtie crossing itself at (5,5): two triangles of base 10
        // and height 5. Its shoelace sum is exactly 0, so the depth
        // metric — which sums |shoelace| — answered 0.0.
        let ring: Ring = vec![(0.0, 0.0), (10.0, 0.0), (0.0, 10.0), (10.0, 10.0)];
        assert_eq!(ring_signed_area(&ring), 0.0);
        assert_eq!(polygon_set_area(&vec![ring]), 50.0);
    }

    #[test]
    fn sloped_edges_are_measured_exactly() {
        // 10x10 square plus a right triangle with legs 10 at (5,5). The
        // triangle is x>=5, y>=5, x+y<=20, so its intersection with the
        // square is exactly the 5x5 block [5,10]x[5,10]: 100 + 50 - 50.
        // Depth metric: 50.0.
        let ps = vec![
            sq(0.0, 0.0, 10.0, 10.0),
            vec![(5.0, 5.0), (15.0, 5.0), (5.0, 15.0)],
        ];
        assert_eq!(polygon_set_area(&ps), 100.0);
    }

    #[test]
    fn rings_sharing_an_edge_are_not_overlapping() {
        // Two 5x10 squares meeting along x=5. The shared edge has zero
        // area, so touching must not be charged as overlap: 50 + 50.
        // The depth metric also answered 100.0 — this is here to pin
        // that the replacement does not over-correct.
        let ps = vec![
            sq(0.0, 0.0, 5.0, 10.0),
            vec![(10.0, 0.0), (10.0, 10.0), (5.0, 10.0), (5.0, 0.0)],
        ];
        assert_eq!(polygon_set_area(&ps), 100.0);
    }

    #[test]
    fn all_rings_simple_says_nothing_about_inter_ring_overlap() {
        // The split of duties, stated as a test: two rings that
        // half-overlap are each individually simple, so this predicate is
        // green. Only the area sees the overlap.
        let ps = vec![sq(0.0, 0.0, 10.0, 10.0), sq(5.0, 0.0, 15.0, 10.0)];
        assert!(all_rings_simple(&ps));
        assert_eq!(polygon_set_area(&ps), 100.0);
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
