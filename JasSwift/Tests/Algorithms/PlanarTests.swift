import Testing
@testable import JasLib

// Mirrors the planar graph extraction test suite in
// jas_dioxus/src/algorithms/planar.rs.

private let AREA_EPS: Double = 1e-6

private func closedSquare(_ x: Double, _ y: Double, _ side: Double) -> PlanarPolyline {
    return [
        (x, y),
        (x + side, y),
        (x + side, y + side),
        (x, y + side),
        (x, y),
    ]
}

private func segment(_ a: PlanarPoint, _ b: PlanarPoint) -> PlanarPolyline {
    return [a, b]
}

private func totalTopLevelArea(_ g: PlanarGraph) -> Double {
    return g.topLevelFaces
        .map { abs(g.faceNetArea($0)) }
        .reduce(0.0, +)
}

// MARK: - 1. Two crossing segments

@Test func twoCrossingSegmentsHaveNoBoundedFaces() {
    let g = PlanarGraph.build([
        segment((-1, 0), (1, 0)),
        segment((0, -1), (0, 1)),
    ])
    #expect(g.faceCount == 0)
}

// MARK: - 2. Closed square

@Test func closedSquareIsOneFace() {
    let g = PlanarGraph.build([closedSquare(0, 0, 10)])
    #expect(g.faceCount == 1)
    #expect(abs(totalTopLevelArea(g) - 100.0) < AREA_EPS)
}

// MARK: - 3. Square with one diagonal

@Test func squareWithOneDiagonalIsTwoTriangles() {
    let g = PlanarGraph.build([
        closedSquare(0, 0, 10),
        segment((0, 0), (10, 10)),
    ])
    #expect(g.faceCount == 2)
    #expect(abs(totalTopLevelArea(g) - 100.0) < AREA_EPS)
    for f in g.topLevelFaces {
        #expect(abs(abs(g.faceNetArea(f)) - 50.0) < AREA_EPS)
    }
}

// MARK: - 4. Square with both diagonals

@Test func squareWithBothDiagonalsIsFourTriangles() {
    let g = PlanarGraph.build([
        closedSquare(0, 0, 10),
        segment((0, 0), (10, 10)),
        segment((10, 0), (0, 10)),
    ])
    #expect(g.faceCount == 4)
    #expect(abs(totalTopLevelArea(g) - 100.0) < AREA_EPS)
    for f in g.topLevelFaces {
        #expect(abs(abs(g.faceNetArea(f)) - 25.0) < AREA_EPS)
    }
}

// MARK: - 5. Two disjoint squares

@Test func twoDisjointSquaresAreTwoFaces() {
    let g = PlanarGraph.build([
        closedSquare(0, 0, 10),
        closedSquare(20, 0, 10),
    ])
    #expect(g.faceCount == 2)
    #expect(abs(totalTopLevelArea(g) - 200.0) < AREA_EPS)
}

// MARK: - 6. Two squares sharing an edge

@Test func twoSquaresSharingAnEdgeAreTwoFaces() {
    let g = PlanarGraph.build([
        closedSquare(0, 0, 10),
        closedSquare(10, 0, 10),
    ])
    #expect(g.faceCount == 2)
    #expect(abs(totalTopLevelArea(g) - 200.0) < AREA_EPS)
}

// MARK: - 7. T-junctions

@Test func tJunctionCreatesVertex() {
    // A horizontal segment (0,0)-(10,0) and a vertical (5,0)-(5,5) whose
    // endpoint sits exactly on the horizontal's interior.
    //
    // Derivation: the T-vertex at (5,0) is degree 3, but (0,0), (10,0)
    // and (5,5) are all degree 1, so the iterative degree-1 prune eats
    // everything. Zero faces either way — this pins that splitting at
    // the T does not INVENT a face. The T-split's observable
    // consequences are pinned by the two chord tests below.
    let g = PlanarGraph.build([
        segment((0, 0), (10, 0)),
        segment((5, 0), (5, 5)),
    ])
    #expect(g.faceCount == 0)
}

@Test func tJunctionChordSplitsSquareIntoTwoHalves() {
    // Closed 10x10 square plus an open chord (0,5)-(10,5). BOTH chord
    // endpoints are T-junctions: (0,5) lies in the interior of the
    // square's left edge, (10,5) in the interior of its right edge.
    //
    // Derivation. Splitting both side edges at y=5 leaves (0,5) and
    // (10,5) at degree 3 and every other vertex at degree 2 — nothing
    // prunes. The chord cuts the square into two 10-wide, 5-tall
    // rectangles: faceCount = 2, each of area 10*5 = 50, total 100.
    // Without the T-split the chord's endpoints are isolated degree-1
    // vertices, the chord prunes away, and one face of area 100 remains.
    let g = PlanarGraph.build([
        closedSquare(0, 0, 10),
        segment((0, 5), (10, 5)),
    ])
    #expect(g.faceCount == 2)
    let top = g.topLevelFaces
    #expect(top.count == 2)
    for f in top {
        #expect(abs(abs(g.faceNetArea(f)) - 50.0) < AREA_EPS)
    }
    #expect(abs(totalTopLevelArea(g) - 100.0) < AREA_EPS)
}

@Test func tJunctionCornerToEdgeChordSplits25And75() {
    // Closed 10x10 square plus a chord from the corner (0,0) to (10,5).
    // The tail coincides with an existing square vertex (plain vertex
    // snap); the head is a T-junction on the right edge's interior.
    //
    // Derivation. The chord cuts off triangle (0,0)-(10,0)-(10,5):
    // area = 1/2 * 10 * 5 = 25. The remainder is the quadrilateral
    // (0,0)-(10,5)-(10,10)-(0,10); shoelace: 0*5-10*0 + 10*10-10*5
    // + 10*10-0*10 + 0*0-0*10 = 0 + 50 + 100 + 0 = 150, half = 75.
    // So faceCount = 2 with areas {25, 75}, total 100.
    let g = PlanarGraph.build([
        closedSquare(0, 0, 10),
        segment((0, 0), (10, 5)),
    ])
    #expect(g.faceCount == 2)
    let areas = g.topLevelFaces
        .map { abs(g.faceNetArea($0)) }
        .sorted()
    #expect(areas.count == 2)
    #expect(abs(areas[0] - 25.0) < AREA_EPS)
    #expect(abs(areas[1] - 75.0) < AREA_EPS)
}

// MARK: - 8. Concentric squares (containment / holes)

@Test func squareWithInnerSquareIsOuterWithOneHole() {
    let g = PlanarGraph.build([
        closedSquare(0, 0, 20),
        closedSquare(5, 5, 10),
    ])
    #expect(g.faceCount == 2)
    let top = g.topLevelFaces
    #expect(top.count == 1)
    let outer = top[0]
    #expect(g.faces[outer.value].holes.count == 1)
    #expect(abs(abs(g.faceOuterArea(outer)) - 400.0) < AREA_EPS)
    #expect(abs(abs(g.faceNetArea(outer)) - 300.0) < AREA_EPS)
    let inner = (0..<g.faces.count)
        .map { FaceId($0) }
        .first(where: { g.faces[$0.value].depth == 2 })!
    #expect(g.faces[inner.value].parent == outer)
    #expect(abs(abs(g.faceNetArea(inner)) - 100.0) < AREA_EPS)
}

// MARK: - 9. Hit test on the cross-diagonal square

@Test func hitTestFindsCorrectQuadrantInDiagonalSquare() {
    let g = PlanarGraph.build([
        closedSquare(0, 0, 10),
        segment((0, 0), (10, 10)),
        segment((10, 0), (0, 10)),
    ])
    let samples: [PlanarPoint] = [
        (5, 1), // bottom
        (9, 5), // right
        (5, 9), // top
        (1, 5), // left
    ]
    var hits: [FaceId] = []
    for s in samples {
        let f = g.hitTest(s)
        #expect(f != nil)
        if let f = f { hits.append(f) }
    }
    let unique = Set(hits)
    #expect(unique.count == 4)
}

// MARK: - 10. Degenerate inputs

@Test func emptyInputYieldsEmptyGraph() {
    let g = PlanarGraph.build([])
    #expect(g.faceCount == 0)
}

@Test func zeroLengthSegmentIsDropped() {
    let g = PlanarGraph.build([segment((1, 1), (1, 1))])
    #expect(g.faceCount == 0)
}

@Test func singlePointPlanarPolylineIsDropped() {
    let g = PlanarGraph.build([[(3, 3)]])
    #expect(g.faceCount == 0)
}

// MARK: - 11. Square with an external tail

@Test func squareWithExternalTailPrunesToOneFace() {
    let g = PlanarGraph.build([
        closedSquare(0, 0, 10),
        segment((10, 10), (15, 15)),
    ])
    #expect(g.faceCount == 1)
    #expect(abs(totalTopLevelArea(g) - 100.0) < AREA_EPS)
}

// MARK: - 12. Square with an internal tail

@Test func squareWithInternalTailPrunesToOneFace() {
    let g = PlanarGraph.build([
        closedSquare(0, 0, 10),
        segment((0, 0), (5, 5)),
    ])
    #expect(g.faceCount == 1)
    #expect(abs(totalTopLevelArea(g) - 100.0) < AREA_EPS)
}

// MARK: - 13. Square with a branching tree of strokes

@Test func squareWithInternalTreePrunesToOneFace() {
    let g = PlanarGraph.build([
        closedSquare(0, 0, 10),
        [(0, 0), (3, 3)],
        [(3, 3), (5, 3)],
        [(3, 3), (3, 5)],
        [(5, 3), (6, 4)],
    ])
    #expect(g.faceCount == 1)
    #expect(abs(totalTopLevelArea(g) - 100.0) < AREA_EPS)
}

// MARK: - 14. Isolated open stroke

@Test func isolatedOpenStrokeYieldsNoFaces() {
    let g = PlanarGraph.build([segment((0, 0), (5, 5))])
    #expect(g.faceCount == 0)
}

// MARK: - 15. Square with two disjoint holes

@Test func squareWithTwoDisjointHoles() {
    let g = PlanarGraph.build([
        closedSquare(0, 0, 30),
        closedSquare(5, 5, 5),
        closedSquare(20, 20, 5),
    ])
    #expect(g.faceCount == 3)
    let top = g.topLevelFaces
    #expect(top.count == 1)
    let outer = top[0]
    #expect(g.faces[outer.value].holes.count == 2)
    #expect(abs(abs(g.faceNetArea(outer)) - 850.0) < AREA_EPS)
}

// MARK: - 16. Three-deep nested squares

@Test func threeDeepNestedSquares() {
    let g = PlanarGraph.build([
        closedSquare(0, 0, 30),
        closedSquare(5, 5, 20),
        closedSquare(10, 10, 10),
    ])
    #expect(g.faceCount == 3)

    var byDepth: [Int: [FaceId]] = [:]
    for (i, f) in g.faces.enumerated() {
        byDepth[f.depth, default: []].append(FaceId(i))
    }
    #expect(byDepth[1]?.count == 1)
    #expect(byDepth[2]?.count == 1)
    #expect(byDepth[3]?.count == 1)

    let a = byDepth[1]![0]
    let b = byDepth[2]![0]
    let c = byDepth[3]![0]
    #expect(g.faces[b.value].parent == a)
    #expect(g.faces[c.value].parent == b)

    #expect(abs(abs(g.faceNetArea(a)) - 500.0) < AREA_EPS)
    #expect(abs(abs(g.faceNetArea(b)) - 300.0) < AREA_EPS)
    #expect(abs(abs(g.faceNetArea(c)) - 100.0) < AREA_EPS)
}

// MARK: - 17. Hit test inside a hole

@Test func hitTestInHoleReturnsHoleNotParent() {
    let g = PlanarGraph.build([
        closedSquare(0, 0, 20),
        closedSquare(5, 5, 10),
    ])
    let outerHit = g.hitTest((1, 1))
    #expect(outerHit != nil)
    if let outerHit = outerHit {
        #expect(g.faces[outerHit.value].depth == 1)
    }
    let holeHit = g.hitTest((10, 10))
    #expect(holeHit != nil)
    if let holeHit = holeHit {
        #expect(g.faces[holeHit.value].depth == 2)
        #expect(g.faces[holeHit.value].parent == outerHit)
    }
}

// MARK: - 18. Collinear overlap

@Test func collinearOverlap() {
    // Closed 10x10 square plus a closed rectangle [2,8]x[0,5] whose
    // bottom edge lies ALONG the square's bottom edge: the span y=0,
    // x in [2,8] is traced twice, once by each polyline.
    //
    // Derivation. Splitting the square's bottom edge at x=2 and x=8
    // makes the doubled span a single shared atomic edge. The
    // arrangement then has two bounded faces that SHARE that span,
    // neither containing the other:
    //   - the inner rectangle, area 6*5 = 30;
    //   - the square minus the rectangle, area 100 - 30 = 70. Shoelace
    //     on (0,0),(2,0),(2,5),(8,5),(8,0),(10,0),(10,10),(0,10):
    //     0 + 10 - 30 - 40 + 0 + 100 + 100 + 0 = 140, half = 70.
    // So faceCount = 2, BOTH top-level (depth 1), total area 100.
    //
    // Without collinear splitting the two polylines stay separate
    // components and the rectangle is mis-classified as a HOLE of the
    // square (one top-level face of net area 70) — wrong: the two
    // regions are adjacent, not nested.
    let g = PlanarGraph.build([
        closedSquare(0, 0, 10),
        [(2, 0), (8, 0), (8, 5), (2, 5), (2, 0)],
    ])
    #expect(g.faceCount == 2)
    let top = g.topLevelFaces
    #expect(top.count == 2)
    for f in top {
        #expect(g.faces[f.value].holes.isEmpty)
    }
    let areas = top.map { abs(g.faceNetArea($0)) }.sorted()
    #expect(abs(areas[0] - 30.0) < AREA_EPS)
    #expect(abs(areas[1] - 70.0) < AREA_EPS)
    #expect(abs(totalTopLevelArea(g) - 100.0) < AREA_EPS)
}

@Test func collinearPartialOverlapOfTwoSquaresKeepsTwoFaces() {
    // Square A = [0,10]x[0,10]; square B = [10,20]x[3,13]. Their
    // boundaries share the collinear span x=10, y in [3,10] — a PARTIAL
    // edge overlap.
    //
    // Derivation: the two squares meet along a segment but their
    // interiors are disjoint (A is x<=10, B is x>=10), so the bounded
    // faces are exactly A and B: faceCount = 2, areas 100 and 100, both
    // top-level. Splitting the shared span at y=3 and y=10 is what makes
    // them one connected arrangement rather than two overlapping
    // components; the areas are the same either way, so this pins that
    // the split does not CHANGE the answer for touching-but-not-
    // overlapping input.
    let g = PlanarGraph.build([
        closedSquare(0, 0, 10),
        closedSquare(10, 3, 10),
    ])
    #expect(g.faceCount == 2)
    #expect(g.topLevelFaces.count == 2)
    for f in g.topLevelFaces {
        #expect(abs(abs(g.faceNetArea(f)) - 100.0) < AREA_EPS)
    }
}

// MARK: - Deferred / known limitations

@Test(.disabled("incremental rebuild not yet supported"))
func incrementalAddStroke() {
}
