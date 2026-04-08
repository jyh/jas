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

// MARK: - 7. T-junction (deferred)

@Test(.disabled("T-junctions where one polyline's vertex lands on another's interior not yet supported"))
func tJunctionCreatesVertex() {
    let g = PlanarGraph.build([
        segment((0, 0), (10, 0)),
        segment((5, 0), (5, 5)),
    ])
    #expect(g.faceCount == 0)
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

// MARK: - Deferred / known limitations

@Test(.disabled("collinear self-overlap not yet supported (mirrors BooleanNormalize)"))
func collinearOverlap() {
}

@Test(.disabled("incremental rebuild not yet supported"))
func incrementalAddStroke() {
}
