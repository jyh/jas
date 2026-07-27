import Testing
@testable import JasLib

// Mirrors the tests in jas_dioxus/src/algorithms/polygon_metrics.rs.
//
// These pin the harness's OWN measuring instruments -- the functions every
// boolean and boolean_normalize golden is expressed in. Every number is
// derived from first principles (cell decomposition on a grid the vertices
// lie on, cross-checked against a dense-grid Riemann sum), never read back
// from an implementation, because both ports carried the same defect and a
// port-vs-port comparison is blind to a shared one.

private func sq(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> BoolRing {
    [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
}

@Suite struct PolygonMetricsTests {

    // MARK: canonical cases -- where the superseded nesting-depth
    // heuristic was already right, so the replacement is pinned as a
    // strict improvement.

    @Test func singleSquareAreaIsItsShoelace() {
        #expect(polygonSetArea([sq(0, 0, 10, 10)]) == 100.0)
    }

    @Test func emptySetHasZeroArea() {
        #expect(polygonSetArea([]) == 0.0)
    }

    @Test func ringWithTwoVerticesBoundsNothing() {
        #expect(polygonSetArea([[(0, 0), (10, 0)]]) == 0.0)
    }

    @Test func nestedSquareReadsAsAHole() {
        // 10x10 outer minus 4x4 inner.
        #expect(polygonSetArea([sq(0, 0, 10, 10), sq(3, 3, 7, 7)]) == 84.0)
    }

    @Test func threeNestedSquaresAlternate() {
        // 144 - 64 + 16.
        #expect(polygonSetArea([sq(0, 0, 12, 12), sq(2, 2, 10, 10), sq(4, 4, 8, 8)]) == 96.0)
    }

    // MARK: the repair. Each comment records what the nesting-depth
    // metric returned, so a reader can check the expectation does not
    // coincide with the bug's output.

    @Test func halfOverlappingSquaresLoseTheOverlapTwice() {
        // Two 10x10 squares overlapping in a 5x10 band: the odd-parity
        // region is the two 5x10 strips, 100. Depth metric: 0.0.
        #expect(polygonSetArea([sq(0, 0, 10, 10), sq(5, 0, 15, 10)]) == 100.0)
    }

    @Test func cornerOverlappingSquaresLoseTheOverlapTwice() {
        // 4x4 corner overlap: 100 + 100 - 2*16. Depth metric: 0.0,
        // because ring 2 is listed from (6,6), which is inside ring 1.
        let ps: BoolPolygonSet = [sq(0, 0, 10, 10), [(6, 6), (16, 6), (16, 16), (6, 16)]]
        #expect(polygonSetArea(ps) == 168.0)
    }

    @Test func areaDoesNotDependOnWhichVertexARingStartsAt() {
        // Same two squares and the same cyclic order as the test above,
        // rotated to start at (16,6), which is OUTSIDE ring 1. The depth
        // metric answered 0.0 there and 200.0 here for one region.
        let ps: BoolPolygonSet = [sq(0, 0, 10, 10), [(16, 6), (16, 16), (6, 16), (6, 6)]]
        #expect(polygonSetArea(ps) == 168.0)
    }

    @Test func tripleOverlapIsParityNotPairwiseSubtraction() {
        // Three 6x6 squares on a 3-unit grid. Coverage per 3x3 cell,
        // bottom row first: 1,2,1 / 1,3,2 / 0,1,1 -- six ODD cells, so
        // 6*9 = 54. Charging every pairwise overlap twice would instead
        // give 108 - 2*(9 + 18 + 18) = 18. Depth metric: 108.0.
        let ps: BoolPolygonSet = [
            sq(0, 0, 6, 6),
            [(9, 9), (3, 9), (3, 3), (9, 3)],
            [(9, 0), (9, 6), (3, 6), (3, 0)],
        ]
        #expect(polygonSetArea(ps) == 54.0)
    }

    @Test func selfCrossingRingMeasuresBothLobes() {
        // A bowtie crossing itself at (5,5): two triangles of base 10 and
        // height 5. Its shoelace sum is exactly 0, so the depth metric --
        // which sums |shoelace| -- answered 0.0.
        let ring: BoolRing = [(0, 0), (10, 0), (0, 10), (10, 10)]
        #expect(ringSignedArea(ring) == 0.0)
        #expect(polygonSetArea([ring]) == 50.0)
    }

    @Test func slopedEdgesAreMeasuredExactly() {
        // 10x10 square plus a right triangle with legs 10 at (5,5). The
        // triangle is x>=5, y>=5, x+y<=20, so its intersection with the
        // square is exactly the 5x5 block [5,10]x[5,10]: 100 + 50 - 50.
        // Depth metric: 50.0.
        let ps: BoolPolygonSet = [sq(0, 0, 10, 10), [(5, 5), (15, 5), (5, 15)]]
        #expect(polygonSetArea(ps) == 100.0)
    }

    @Test func ringsSharingAnEdgeAreNotOverlapping() {
        // Two 5x10 squares meeting along x=5. The shared edge has zero
        // area, so touching must not be charged as overlap: 50 + 50. The
        // depth metric also answered 100.0 -- this pins that the
        // replacement does not over-correct.
        let ps: BoolPolygonSet = [sq(0, 0, 5, 10), [(10, 0), (10, 10), (5, 10), (5, 0)]]
        #expect(polygonSetArea(ps) == 100.0)
    }

    // MARK: the other instruments

    @Test func ringSignedAreaCarriesTheWindingSign() {
        let ccw = sq(0, 0, 10, 10)
        #expect(ringSignedArea(ccw) == 100.0)
        #expect(ringSignedArea(ccw.reversed()) == -100.0)
    }

    @Test func pointInPolygonSetIsEvenOdd() {
        let ps: BoolPolygonSet = [sq(0, 0, 10, 10), sq(3, 3, 7, 7)]
        #expect(pointInPolygonSet(ps, (1.5, 5.0)))
        #expect(!pointInPolygonSet(ps, (5.0, 5.0)))
        #expect(!pointInPolygonSet(ps, (12.0, 5.0)))
    }

    @Test func isRingSimpleRejectsASelfCrossingRing() {
        #expect(isRingSimple(sq(0, 0, 10, 10)))
        #expect(!isRingSimple([(0, 0), (10, 0), (0, 10), (10, 10)]))
    }

    @Test func allRingsSimpleSaysNothingAboutInterRingOverlap() {
        // The split of duties, stated as a test: two rings that
        // half-overlap are each individually simple, so this predicate is
        // green. Only the area sees the overlap.
        let ps: BoolPolygonSet = [sq(0, 0, 10, 10), sq(5, 0, 15, 10)]
        #expect(allRingsSimple(ps))
        #expect(polygonSetArea(ps) == 100.0)
    }
}
