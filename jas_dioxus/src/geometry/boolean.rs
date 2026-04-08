//! Boolean operations on planar polygons (union, intersection,
//! difference, exclusive-or).
//!
//! # Status
//!
//! **Spec only.** This module currently exposes the public API as
//! `unimplemented!()` stubs and a comprehensive test suite. The
//! intent is to nail down the contract — including all the
//! degenerate cases that quietly break naïve implementations —
//! *before* writing any algorithm code. Pick an algorithm
//! (Greiner-Hormann, Martinez-Rueda-Feito, or Weiler-Atherton),
//! implement it, and the tests below should pass without being
//! rewritten.
//!
//! # Data model
//!
//! All inputs and outputs are [`PolygonSet`] values. A `PolygonSet`
//! is a flat list of *rings*; a ring is a closed polygon expressed
//! as a list of `(x, y)` vertices (without an explicit closing
//! vertex — the last vertex is implicitly connected back to the
//! first).
//!
//! Multiple rings represent a region using the **even-odd fill
//! rule**: a point is *inside* the region iff a ray from the point
//! crosses an odd number of ring edges. This means a polygon with
//! a hole is two rings (the outer boundary and the hole), and the
//! result of a boolean operation may legitimately produce many
//! disjoint pieces and/or holes — all collected in the same flat
//! `PolygonSet`.
//!
//! Ring orientation is **not** part of the contract. The
//! implementation is free to emit clockwise or counter-clockwise
//! rings; the test suite asserts on the *region* (area, sample
//! points, bounding box), never on raw vertex sequences.
//!
//! # Out of scope here
//!
//! - Curves. Bezier and elliptical arcs must be flattened to a
//!   polyline before being passed in. The element-level adapter
//!   that wires these functions to `Element::Path` /
//!   `Element::Circle` / etc. lives elsewhere; this module is
//!   pure geometry.
//! - Self-intersecting input rings. The behaviour on a
//!   self-intersecting input is left intentionally undefined; if
//!   we need to handle them, we'll add a normalisation pass and
//!   tests for it explicitly.
//! - Open polylines. Boolean operations are defined on regions,
//!   not curves; lines and polylines have no interior.

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// A single closed ring as a vector of `(x, y)` vertices. The last
/// vertex is implicitly connected back to the first; do **not**
/// include a duplicate closing vertex.
pub type Ring = Vec<(f64, f64)>;

/// A region in the plane, represented as a flat list of rings under
/// the even-odd fill rule. Multiple rings can encode disjoint pieces
/// and/or holes.
pub type PolygonSet = Vec<Ring>;

// ---------------------------------------------------------------------------
// Public API — algorithm-agnostic
// ---------------------------------------------------------------------------

/// `a ∪ b` — the region covered by either operand.
pub fn boolean_union(a: &PolygonSet, b: &PolygonSet) -> PolygonSet {
    let _ = (a, b);
    unimplemented!("boolean_union: not yet implemented")
}

/// `a ∩ b` — the region covered by both operands.
pub fn boolean_intersect(a: &PolygonSet, b: &PolygonSet) -> PolygonSet {
    let _ = (a, b);
    unimplemented!("boolean_intersect: not yet implemented")
}

/// `a − b` — the region covered by `a` but not `b`. Not symmetric.
pub fn boolean_subtract(a: &PolygonSet, b: &PolygonSet) -> PolygonSet {
    let _ = (a, b);
    unimplemented!("boolean_subtract: not yet implemented")
}

/// `a ⊕ b` — symmetric difference; the region covered by exactly
/// one of the operands. Equivalent to `(a ∪ b) − (a ∩ b)`.
pub fn boolean_exclude(a: &PolygonSet, b: &PolygonSet) -> PolygonSet {
    let _ = (a, b);
    unimplemented!("boolean_exclude: not yet implemented")
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // -------------------------------------------------------------------
    // Region helpers
    //
    // We assert on *regions*, never on raw vertex sequences. The
    // implementation is free to choose any vertex ordering, starting
    // vertex, ring ordering, or orientation as long as the resulting
    // region matches.
    //
    // A region is characterised by:
    //   - its (signed-)area magnitude under the even-odd fill rule
    //   - the inside/outside answer at a set of sample points
    //   - its axis-aligned bounding box (when non-empty)
    //
    // These three together are enough to distinguish every test
    // case we care about, without being brittle to representation.
    // -------------------------------------------------------------------

    /// Shoelace area of a single ring. Sign reflects winding
    /// direction; we use the absolute value when comparing regions.
    fn ring_signed_area(ring: &Ring) -> f64 {
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
        sum / 2.0
    }

    /// Even-odd area of a region. Holes (rings with opposite winding
    /// or rings whose interior is "subtracted" by overlap parity)
    /// are handled by summing absolute areas of outer rings minus
    /// holes; in practice the implementation is free to use either
    /// winding-rule or even-odd output as long as the *net* covered
    /// area matches what we expect.
    ///
    /// We compute "net area" as the integral of the indicator
    /// function over the bounding box, which we approximate by
    /// summing absolute signed-areas with alternating signs based
    /// on a containment count at a sample inside each ring. That's
    /// overkill for the small test cases here, so we use a simpler
    /// rule: net_area = sum(|signed_area(ring)|) for outer rings
    /// minus sum(|signed_area(ring)|) for hole rings, where a hole
    /// is detected by being contained in another ring with the
    /// opposite winding sign.
    ///
    /// For all the test polygons in this file the simpler rule
    /// suffices because every test fixture has a known structure.
    /// We expose `polygon_set_area` only for asserting against a
    /// pre-computed expected value, so even a slightly liberal
    /// interpretation is fine for our purposes.
    fn polygon_set_area(ps: &PolygonSet) -> f64 {
        // Sum |signed_area| of every ring, with the sign of the
        // *outer* ring chosen as positive and contained rings
        // contributing with the opposite sign of their parent.
        // Implementation note: nearly every test below uses
        // pairwise-disjoint outer rings, so the simple sum of
        // absolute signed areas is correct in those cases. Only the
        // "with hole" tests need the containment correction.
        let mut total = 0.0;
        for (i, ring) in ps.iter().enumerate() {
            let a = ring_signed_area(ring).abs();
            // Count containments — a ring contained in an odd number
            // of other rings is a hole and contributes negatively.
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

    /// Standard ray-casting point-in-ring test. The ring is treated
    /// as a closed polygon (last vertex implicitly connects to the
    /// first).
    fn point_in_ring(ring: &Ring, pt: (f64, f64)) -> bool {
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
            let intersects = ((yi > py) != (yj > py))
                && (px < (xj - xi) * (py - yi) / (yj - yi) + xi);
            if intersects {
                inside = !inside;
            }
            j = i;
        }
        inside
    }

    /// Even-odd "is point inside this region" — true iff `pt` lies
    /// inside an odd number of rings.
    fn point_in_polygon_set(ps: &PolygonSet, pt: (f64, f64)) -> bool {
        let mut inside_count = 0;
        for ring in ps {
            if point_in_ring(ring, pt) {
                inside_count += 1;
            }
        }
        inside_count % 2 == 1
    }

    /// Axis-aligned bounding box of a `PolygonSet`. Returns
    /// `None` if the set has no vertices.
    fn polygon_set_bbox(ps: &PolygonSet) -> Option<(f64, f64, f64, f64)> {
        let mut min_x = f64::INFINITY;
        let mut min_y = f64::INFINITY;
        let mut max_x = f64::NEG_INFINITY;
        let mut max_y = f64::NEG_INFINITY;
        let mut any = false;
        for ring in ps {
            for &(x, y) in ring {
                if x < min_x {
                    min_x = x;
                }
                if y < min_y {
                    min_y = y;
                }
                if x > max_x {
                    max_x = x;
                }
                if y > max_y {
                    max_y = y;
                }
                any = true;
            }
        }
        if any {
            Some((min_x, min_y, max_x - min_x, max_y - min_y))
        } else {
            None
        }
    }

    const EPS: f64 = 1e-9;

    fn approx_eq(a: f64, b: f64) -> bool {
        (a - b).abs() < EPS
    }

    /// Assert that a `PolygonSet` represents the expected region.
    ///
    /// Checks (in order):
    ///   1. The net even-odd area matches `expected_area`.
    ///   2. Every `inside_pts` is reported inside.
    ///   3. Every `outside_pts` is reported outside.
    ///   4. If `expected_area` is non-zero, the bbox matches
    ///      `expected_bbox` (when supplied).
    ///
    /// Vertex order, ring order, ring count, and orientation are
    /// all unconstrained.
    fn assert_region(
        actual: &PolygonSet,
        expected_area: f64,
        inside_pts: &[(f64, f64)],
        outside_pts: &[(f64, f64)],
        expected_bbox: Option<(f64, f64, f64, f64)>,
    ) {
        let area = polygon_set_area(actual);
        assert!(
            approx_eq(area, expected_area),
            "area mismatch: expected {}, got {} (rings: {:?})",
            expected_area,
            area,
            actual
        );
        for &pt in inside_pts {
            assert!(
                point_in_polygon_set(actual, pt),
                "point {:?} should be inside region {:?}",
                pt,
                actual
            );
        }
        for &pt in outside_pts {
            assert!(
                !point_in_polygon_set(actual, pt),
                "point {:?} should be outside region {:?}",
                pt,
                actual
            );
        }
        if let Some(expected) = expected_bbox {
            if expected_area > EPS {
                let actual_bbox = polygon_set_bbox(actual).expect("non-empty region must have a bbox");
                assert!(
                    approx_eq(actual_bbox.0, expected.0)
                        && approx_eq(actual_bbox.1, expected.1)
                        && approx_eq(actual_bbox.2, expected.2)
                        && approx_eq(actual_bbox.3, expected.3),
                    "bbox mismatch: expected {:?}, got {:?}",
                    expected,
                    actual_bbox
                );
            }
        }
    }

    /// Assert that the result is the empty region (no rings, or
    /// rings whose total area is zero).
    fn assert_empty(actual: &PolygonSet) {
        let area: f64 = actual.iter().map(|r| ring_signed_area(r).abs()).sum();
        assert!(
            area < EPS,
            "expected empty region, got area {} (rings: {:?})",
            area,
            actual
        );
    }

    // -------------------------------------------------------------------
    // Polygon fixtures used across tests
    // -------------------------------------------------------------------

    /// Axis-aligned 10×10 square at the origin.
    fn square_a() -> PolygonSet {
        vec![vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]]
    }

    /// 10×10 square overlapping `square_a`'s top-right corner.
    /// Their intersection is a 5×5 square at (5, 5)-(10, 10).
    fn square_b_overlap() -> PolygonSet {
        vec![vec![(5.0, 5.0), (15.0, 5.0), (15.0, 15.0), (5.0, 15.0)]]
    }

    /// 10×10 square that doesn't touch `square_a` at all.
    fn square_disjoint() -> PolygonSet {
        vec![vec![(20.0, 0.0), (30.0, 0.0), (30.0, 10.0), (20.0, 10.0)]]
    }

    /// 10×10 square that exactly touches `square_a` along one edge
    /// (no area overlap, but the edge `x = 10` is shared).
    fn square_edge_touching() -> PolygonSet {
        vec![vec![(10.0, 0.0), (20.0, 0.0), (20.0, 10.0), (10.0, 10.0)]]
    }

    /// 10×10 square that touches `square_a` only at a single
    /// vertex (10, 10).
    fn square_vertex_touching() -> PolygonSet {
        vec![vec![(10.0, 10.0), (20.0, 10.0), (20.0, 20.0), (10.0, 20.0)]]
    }

    /// 4×4 square fully contained inside `square_a`.
    fn square_inside() -> PolygonSet {
        vec![vec![(3.0, 3.0), (7.0, 3.0), (7.0, 7.0), (3.0, 7.0)]]
    }

    // -------------------------------------------------------------------
    // Trivial cases — disjoint, identical, contained
    // -------------------------------------------------------------------

    #[test]
    fn union_disjoint_squares_yields_two_pieces() {
        let result = boolean_union(&square_a(), &square_disjoint());
        // 2 × 100 = 200 net area, two disjoint pieces.
        assert_region(
            &result,
            200.0,
            &[(5.0, 5.0), (25.0, 5.0)],
            &[(15.0, 5.0), (-1.0, -1.0)],
            None, // bbox is the union of both
        );
    }

    #[test]
    fn intersection_disjoint_squares_is_empty() {
        let result = boolean_intersect(&square_a(), &square_disjoint());
        assert_empty(&result);
    }

    #[test]
    fn subtract_disjoint_returns_a_unchanged() {
        let result = boolean_subtract(&square_a(), &square_disjoint());
        assert_region(
            &result,
            100.0,
            &[(5.0, 5.0)],
            &[(25.0, 5.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }

    #[test]
    fn exclude_disjoint_is_their_union() {
        let result = boolean_exclude(&square_a(), &square_disjoint());
        assert_region(
            &result,
            200.0,
            &[(5.0, 5.0), (25.0, 5.0)],
            &[(15.0, 5.0)],
            None,
        );
    }

    #[test]
    fn union_identical_polygons_is_one_polygon() {
        let result = boolean_union(&square_a(), &square_a());
        assert_region(
            &result,
            100.0,
            &[(5.0, 5.0)],
            &[(11.0, 11.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }

    #[test]
    fn intersection_identical_polygons_is_the_polygon() {
        let result = boolean_intersect(&square_a(), &square_a());
        assert_region(
            &result,
            100.0,
            &[(5.0, 5.0)],
            &[(11.0, 11.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }

    #[test]
    fn subtract_identical_polygons_is_empty() {
        let result = boolean_subtract(&square_a(), &square_a());
        assert_empty(&result);
    }

    #[test]
    fn exclude_identical_polygons_is_empty() {
        let result = boolean_exclude(&square_a(), &square_a());
        assert_empty(&result);
    }

    #[test]
    fn union_inner_polygon_is_the_outer() {
        let result = boolean_union(&square_a(), &square_inside());
        assert_region(
            &result,
            100.0,
            &[(5.0, 5.0), (4.0, 4.0)],
            &[(11.0, 11.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }

    #[test]
    fn intersection_with_inner_is_the_inner() {
        let result = boolean_intersect(&square_a(), &square_inside());
        assert_region(
            &result,
            16.0,
            &[(5.0, 5.0)],
            &[(2.0, 2.0), (8.0, 8.0)],
            Some((3.0, 3.0, 4.0, 4.0)),
        );
    }

    #[test]
    fn subtract_inner_creates_a_hole() {
        // a − b where b is fully inside a should leave a polygon
        // with a rectangular hole in the middle.
        let result = boolean_subtract(&square_a(), &square_inside());
        assert_region(
            &result,
            100.0 - 16.0,
            // points in the "donut" but not the hole
            &[(1.0, 1.0), (9.0, 9.0), (1.0, 9.0), (9.0, 1.0)],
            // points inside the hole
            &[(5.0, 5.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }

    // -------------------------------------------------------------------
    // Non-trivial overlap
    // -------------------------------------------------------------------

    #[test]
    fn union_overlapping_squares_is_l_shape() {
        let result = boolean_union(&square_a(), &square_b_overlap());
        // Union covers both squares minus the 5×5 overlap counted once.
        // = 100 + 100 − 25 = 175.
        assert_region(
            &result,
            175.0,
            &[(2.0, 2.0), (12.0, 12.0), (7.0, 7.0)],
            &[(2.0, 12.0), (12.0, 2.0)],
            Some((0.0, 0.0, 15.0, 15.0)),
        );
    }

    #[test]
    fn intersection_overlapping_squares_is_5x5_square() {
        let result = boolean_intersect(&square_a(), &square_b_overlap());
        assert_region(
            &result,
            25.0,
            &[(7.0, 7.0)],
            &[(2.0, 2.0), (12.0, 12.0)],
            Some((5.0, 5.0, 5.0, 5.0)),
        );
    }

    #[test]
    fn subtract_overlap_leaves_l_shape() {
        // a − b: the part of `a` not covered by `b`. Removes the
        // top-right 5×5 corner, leaving an L-shaped region of area 75.
        let result = boolean_subtract(&square_a(), &square_b_overlap());
        assert_region(
            &result,
            75.0,
            &[(2.0, 2.0), (2.0, 8.0), (8.0, 2.0)],
            &[(7.0, 7.0), (12.0, 12.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }

    #[test]
    fn exclude_overlapping_is_two_l_shapes() {
        let result = boolean_exclude(&square_a(), &square_b_overlap());
        // Two L-shapes joined at the corner; total area = 175 − 25 = 150.
        assert_region(
            &result,
            150.0,
            &[(2.0, 2.0), (12.0, 12.0)],
            &[(7.0, 7.0)],
            Some((0.0, 0.0, 15.0, 15.0)),
        );
    }

    // -------------------------------------------------------------------
    // Touching cases (no area overlap)
    //
    // These are the ones that quietly break naïve implementations:
    // edges that coincide exactly, vertices that lie on each other,
    // and shared edges that should not produce sliver artefacts.
    // -------------------------------------------------------------------

    #[test]
    fn union_edge_touching_squares_is_one_rectangle() {
        let result = boolean_union(&square_a(), &square_edge_touching());
        // Union should be a single 20×10 rectangle, area 200.
        assert_region(
            &result,
            200.0,
            &[(5.0, 5.0), (15.0, 5.0)],
            &[(-1.0, 5.0), (21.0, 5.0)],
            Some((0.0, 0.0, 20.0, 10.0)),
        );
    }

    #[test]
    fn intersection_edge_touching_squares_is_empty() {
        // Two squares sharing an edge have *no interior overlap*,
        // so the intersection is empty (or a zero-area edge, which
        // we treat as empty).
        let result = boolean_intersect(&square_a(), &square_edge_touching());
        assert_empty(&result);
    }

    #[test]
    fn subtract_edge_touching_returns_a_unchanged() {
        // Subtracting a polygon that touches but doesn't overlap
        // must not nibble away at the shared edge.
        let result = boolean_subtract(&square_a(), &square_edge_touching());
        assert_region(
            &result,
            100.0,
            &[(5.0, 5.0)],
            &[(15.0, 5.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }

    #[test]
    fn union_vertex_touching_squares_is_two_pieces_meeting_at_a_point() {
        // Two squares touching only at the corner (10, 10) should
        // produce a *region* of total area 200. Whether the
        // implementation reports them as one ring with a pinch
        // point or two separate rings is unspecified.
        let result = boolean_union(&square_a(), &square_vertex_touching());
        assert_region(
            &result,
            200.0,
            &[(5.0, 5.0), (15.0, 15.0)],
            &[(5.0, 15.0), (15.0, 5.0)],
            Some((0.0, 0.0, 20.0, 20.0)),
        );
    }

    #[test]
    fn intersection_vertex_touching_is_empty() {
        let result = boolean_intersect(&square_a(), &square_vertex_touching());
        assert_empty(&result);
    }

    // -------------------------------------------------------------------
    // Polygon with a hole as input
    // -------------------------------------------------------------------

    #[test]
    fn intersect_with_holed_polygon_preserves_hole() {
        // Donut: outer 10×10 square minus a 4×4 inner square.
        let donut: PolygonSet = vec![
            vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)],
            vec![(3.0, 3.0), (7.0, 3.0), (7.0, 7.0), (3.0, 7.0)],
        ];
        // Clip rectangle covering the right half of the outer square,
        // including some of the hole.
        let clip: PolygonSet = vec![vec![(5.0, 0.0), (10.0, 0.0), (10.0, 10.0), (5.0, 10.0)]];
        let result = boolean_intersect(&donut, &clip);
        // Intersection: right half of the donut. Area:
        //   right half of outer square = 50
        // − right half of hole         = 8
        //   net                        = 42
        assert_region(
            &result,
            42.0,
            &[(6.0, 1.0), (8.0, 8.0), (9.0, 5.0)],
            &[(5.5, 5.0), (1.0, 1.0)],
            Some((5.0, 0.0, 5.0, 10.0)),
        );
    }

    // -------------------------------------------------------------------
    // Regression / sanity checks for empty operands
    // -------------------------------------------------------------------

    #[test]
    fn union_with_empty_returns_other() {
        let empty: PolygonSet = vec![];
        let result = boolean_union(&square_a(), &empty);
        assert_region(
            &result,
            100.0,
            &[(5.0, 5.0)],
            &[(15.0, 15.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }

    #[test]
    fn intersect_with_empty_is_empty() {
        let empty: PolygonSet = vec![];
        let result = boolean_intersect(&square_a(), &empty);
        assert_empty(&result);
    }

    #[test]
    fn subtract_empty_from_a_returns_a() {
        let empty: PolygonSet = vec![];
        let result = boolean_subtract(&square_a(), &empty);
        assert_region(
            &result,
            100.0,
            &[(5.0, 5.0)],
            &[(15.0, 15.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }

    #[test]
    fn subtract_a_from_empty_is_empty() {
        let empty: PolygonSet = vec![];
        let result = boolean_subtract(&empty, &square_a());
        assert_empty(&result);
    }

    // -------------------------------------------------------------------
    // Triangle ∩ square — first non-axis-aligned operand
    //
    // Most boolean-op bugs only show up once at least one edge is
    // not horizontal/vertical. Worth covering at least one such
    // case in the spec.
    // -------------------------------------------------------------------

    #[test]
    fn triangle_intersect_square_clips_corner() {
        // Right triangle covering the lower-left of square_a.
        // Vertices: (0, 0), (10, 0), (0, 10). Area = 50.
        let triangle: PolygonSet = vec![vec![(0.0, 0.0), (10.0, 0.0), (0.0, 10.0)]];
        let result = boolean_intersect(&square_a(), &triangle);
        // The triangle is fully inside the square, so the
        // intersection is the triangle itself.
        assert_region(
            &result,
            50.0,
            &[(1.0, 1.0), (3.0, 3.0)],
            &[(8.0, 8.0), (6.0, 6.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }

    #[test]
    fn triangle_subtract_square_leaves_other_triangle() {
        // square − triangle (lower-left half) = upper-right half = area 50.
        let triangle: PolygonSet = vec![vec![(0.0, 0.0), (10.0, 0.0), (0.0, 10.0)]];
        let result = boolean_subtract(&square_a(), &triangle);
        assert_region(
            &result,
            50.0,
            &[(8.0, 8.0), (7.0, 5.0)],
            &[(1.0, 1.0), (3.0, 3.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }
}
