import Testing
@testable import JasLib

// Mirrors the boolean ops test suite in
// jas_dioxus/src/algorithms/boolean.rs and the normalizer tests in
// jas_dioxus/src/algorithms/normalize.rs.
//
// We assert on regions, never on raw vertex sequences. The
// implementation is free to choose any vertex ordering, ring count,
// or orientation as long as the resulting region matches.

// MARK: - Region helpers

private let EPS: Double = 1e-9

private func ringSignedAreaT(_ ring: BoolRing) -> Double {
    if ring.count < 3 { return 0.0 }
    var sum = 0.0
    let n = ring.count
    for i in 0..<n {
        let (x1, y1) = ring[i]
        let (x2, y2) = ring[(i + 1) % n]
        sum += x1 * y2 - x2 * y1
    }
    return sum / 2.0
}

private func pointInRingT(_ ring: BoolRing, _ pt: (Double, Double)) -> Bool {
    let (px, py) = pt
    let n = ring.count
    if n < 3 { return false }
    var inside = false
    var j = n - 1
    for i in 0..<n {
        let (xi, yi) = ring[i]
        let (xj, yj) = ring[j]
        let intersects = (yi > py) != (yj > py)
            && px < (xj - xi) * (py - yi) / (yj - yi) + xi
        if intersects { inside.toggle() }
        j = i
    }
    return inside
}

private func polygonSetAreaT(_ ps: BoolPolygonSet) -> Double {
    var total = 0.0
    for (i, ring) in ps.enumerated() {
        let a = abs(ringSignedAreaT(ring))
        var depth = 0
        if let pt = ring.first {
            for (j, other) in ps.enumerated() where i != j {
                if pointInRingT(other, pt) { depth += 1 }
            }
        }
        if depth % 2 == 0 { total += a } else { total -= a }
    }
    return total
}

private func pointInPolygonSetT(_ ps: BoolPolygonSet, _ pt: (Double, Double)) -> Bool {
    var n = 0
    for ring in ps where pointInRingT(ring, pt) { n += 1 }
    return n % 2 == 1
}

private func polygonSetBboxT(_ ps: BoolPolygonSet) -> (Double, Double, Double, Double)? {
    var minX = Double.infinity, minY = Double.infinity
    var maxX = -Double.infinity, maxY = -Double.infinity
    var any = false
    for ring in ps {
        for (x, y) in ring {
            if x < minX { minX = x }
            if y < minY { minY = y }
            if x > maxX { maxX = x }
            if y > maxY { maxY = y }
            any = true
        }
    }
    return any ? (minX, minY, maxX - minX, maxY - minY) : nil
}

private func approxEqT(_ a: Double, _ b: Double) -> Bool {
    abs(a - b) < EPS
}

private func assertRegion(
    _ actual: BoolPolygonSet,
    expectedArea: Double,
    insidePts: [(Double, Double)] = [],
    outsidePts: [(Double, Double)] = [],
    expectedBbox: (Double, Double, Double, Double)? = nil
) {
    let area = polygonSetAreaT(actual)
    #expect(approxEqT(area, expectedArea), "area mismatch: expected \(expectedArea) got \(area), rings: \(actual)")
    for pt in insidePts {
        #expect(pointInPolygonSetT(actual, pt), "point \(pt) should be inside \(actual)")
    }
    for pt in outsidePts {
        #expect(!pointInPolygonSetT(actual, pt), "point \(pt) should be outside \(actual)")
    }
    if let exp = expectedBbox, expectedArea > EPS {
        let act = polygonSetBboxT(actual)!
        #expect(approxEqT(act.0, exp.0) && approxEqT(act.1, exp.1)
                && approxEqT(act.2, exp.2) && approxEqT(act.3, exp.3),
                "bbox mismatch: expected \(exp), got \(act)")
    }
}

private func assertEmpty(_ actual: BoolPolygonSet) {
    let area = actual.map { abs(ringSignedAreaT($0)) }.reduce(0.0, +)
    #expect(area < EPS, "expected empty region, got area \(area), rings: \(actual)")
}

// MARK: - Fixtures

private func squareA() -> BoolPolygonSet {
    [[(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]]
}
private func squareBOverlap() -> BoolPolygonSet {
    [[(5.0, 5.0), (15.0, 5.0), (15.0, 15.0), (5.0, 15.0)]]
}
private func squareDisjoint() -> BoolPolygonSet {
    [[(20.0, 0.0), (30.0, 0.0), (30.0, 10.0), (20.0, 10.0)]]
}
private func squareInside() -> BoolPolygonSet {
    [[(3.0, 3.0), (7.0, 3.0), (7.0, 7.0), (3.0, 7.0)]]
}
private func squareEdgeTouching() -> BoolPolygonSet {
    [[(10.0, 0.0), (20.0, 0.0), (20.0, 10.0), (10.0, 10.0)]]
}
private func squareVertexTouching() -> BoolPolygonSet {
    [[(10.0, 10.0), (20.0, 10.0), (20.0, 20.0), (10.0, 20.0)]]
}

// MARK: - Trivial cases

@Test func boolUnionDisjoint() {
    let result = booleanUnion(squareA(), squareDisjoint())
    assertRegion(result, expectedArea: 200.0,
                 insidePts: [(5, 5), (25, 5)], outsidePts: [(15, 5), (-1, -1)])
}

@Test func boolIntersectDisjointEmpty() {
    assertEmpty(booleanIntersect(squareA(), squareDisjoint()))
}

@Test func boolSubtractDisjoint() {
    let result = booleanSubtract(squareA(), squareDisjoint())
    assertRegion(result, expectedArea: 100.0,
                 insidePts: [(5, 5)], outsidePts: [(25, 5)],
                 expectedBbox: (0, 0, 10, 10))
}

@Test func boolExcludeDisjoint() {
    let result = booleanExclude(squareA(), squareDisjoint())
    assertRegion(result, expectedArea: 200.0,
                 insidePts: [(5, 5), (25, 5)], outsidePts: [(15, 5)])
}

@Test func boolUnionIdentical() {
    let result = booleanUnion(squareA(), squareA())
    assertRegion(result, expectedArea: 100.0,
                 insidePts: [(5, 5)], outsidePts: [(11, 11)],
                 expectedBbox: (0, 0, 10, 10))
}

@Test func boolIntersectIdentical() {
    let result = booleanIntersect(squareA(), squareA())
    assertRegion(result, expectedArea: 100.0,
                 insidePts: [(5, 5)], outsidePts: [(11, 11)],
                 expectedBbox: (0, 0, 10, 10))
}

@Test func boolSubtractIdenticalEmpty() {
    assertEmpty(booleanSubtract(squareA(), squareA()))
}

@Test func boolExcludeIdenticalEmpty() {
    assertEmpty(booleanExclude(squareA(), squareA()))
}

// MARK: - Inner / contained

@Test func boolUnionWithInner() {
    let result = booleanUnion(squareA(), squareInside())
    assertRegion(result, expectedArea: 100.0,
                 insidePts: [(5, 5), (4, 4)], outsidePts: [(11, 11)],
                 expectedBbox: (0, 0, 10, 10))
}

@Test func boolIntersectWithInner() {
    let result = booleanIntersect(squareA(), squareInside())
    assertRegion(result, expectedArea: 16.0,
                 insidePts: [(5, 5)], outsidePts: [(2, 2), (8, 8)],
                 expectedBbox: (3, 3, 4, 4))
}

@Test func boolSubtractInnerCreatesHole() {
    let result = booleanSubtract(squareA(), squareInside())
    assertRegion(result, expectedArea: 100.0 - 16.0,
                 insidePts: [(1, 1), (9, 9), (1, 9), (9, 1)],
                 outsidePts: [(5, 5)],
                 expectedBbox: (0, 0, 10, 10))
}

// MARK: - Overlapping

@Test func boolUnionOverlapping() {
    let result = booleanUnion(squareA(), squareBOverlap())
    assertRegion(result, expectedArea: 175.0,
                 insidePts: [(2, 2), (12, 12), (7, 7)],
                 outsidePts: [(2, 12), (12, 2)],
                 expectedBbox: (0, 0, 15, 15))
}

@Test func boolIntersectOverlapping() {
    let result = booleanIntersect(squareA(), squareBOverlap())
    assertRegion(result, expectedArea: 25.0,
                 insidePts: [(7, 7)], outsidePts: [(2, 2), (12, 12)],
                 expectedBbox: (5, 5, 5, 5))
}

@Test func boolSubtractOverlapLeavesL() {
    let result = booleanSubtract(squareA(), squareBOverlap())
    assertRegion(result, expectedArea: 75.0,
                 insidePts: [(2, 2), (2, 8), (8, 2)],
                 outsidePts: [(7, 7), (12, 12)],
                 expectedBbox: (0, 0, 10, 10))
}

@Test func boolExcludeOverlapping() {
    let result = booleanExclude(squareA(), squareBOverlap())
    assertRegion(result, expectedArea: 150.0,
                 insidePts: [(2, 2), (12, 12)], outsidePts: [(7, 7)],
                 expectedBbox: (0, 0, 15, 15))
}

// MARK: - Touching cases

@Test func boolUnionEdgeTouching() {
    let result = booleanUnion(squareA(), squareEdgeTouching())
    assertRegion(result, expectedArea: 200.0,
                 insidePts: [(5, 5), (15, 5)], outsidePts: [(-1, 5), (25, 5)],
                 expectedBbox: (0, 0, 20, 10))
}

@Test func boolIntersectEdgeTouchingEmpty() {
    assertEmpty(booleanIntersect(squareA(), squareEdgeTouching()))
}

@Test func boolUnionVertexTouching() {
    let result = booleanUnion(squareA(), squareVertexTouching())
    assertRegion(result, expectedArea: 200.0,
                 insidePts: [(5, 5), (15, 15)], outsidePts: [(-1, -1), (5, 15)])
}

// MARK: - Empty operands

@Test func boolUnionWithEmpty() {
    let result = booleanUnion(squareA(), [])
    assertRegion(result, expectedArea: 100.0, insidePts: [(5, 5)], outsidePts: [(15, 5)],
                 expectedBbox: (0, 0, 10, 10))
}

@Test func boolIntersectWithEmpty() {
    assertEmpty(booleanIntersect(squareA(), []))
}

@Test func boolSubtractEmptyFromA() {
    let result = booleanSubtract(squareA(), [])
    assertRegion(result, expectedArea: 100.0, insidePts: [(5, 5)],
                 expectedBbox: (0, 0, 10, 10))
}

@Test func boolSubtractAFromEmpty() {
    assertEmpty(booleanSubtract([], squareA()))
}

// MARK: - Property tests

private let propertySampleGrid: [(Double, Double)] = {
    var pts: [(Double, Double)] = []
    for i in -2...18 {
        for j in -2...18 {
            pts.append((Double(i) + 0.5, Double(j) + 0.5))
        }
    }
    return pts
}()

private func regionsEqual(_ p: BoolPolygonSet, _ q: BoolPolygonSet) -> Bool {
    if !approxEqT(polygonSetAreaT(p), polygonSetAreaT(q)) { return false }
    for pt in propertySampleGrid {
        if pointInPolygonSetT(p, pt) != pointInPolygonSetT(q, pt) { return false }
    }
    let pb = polygonSetBboxT(p)
    let qb = polygonSetBboxT(q)
    switch (pb, qb) {
    case (nil, nil): return true
    case (.some, nil), (nil, .some): return false
    case (.some(let a), .some(let b)):
        return approxEqT(a.0, b.0) && approxEqT(a.1, b.1) && approxEqT(a.2, b.2) && approxEqT(a.3, b.3)
    }
}

@Test func boolUnionCommutativeOverlapping() {
    #expect(regionsEqual(booleanUnion(squareA(), squareBOverlap()),
                         booleanUnion(squareBOverlap(), squareA())))
}

@Test func boolIntersectCommutativeOverlapping() {
    #expect(regionsEqual(booleanIntersect(squareA(), squareBOverlap()),
                         booleanIntersect(squareBOverlap(), squareA())))
}

@Test func boolExcludeCommutativeOverlapping() {
    #expect(regionsEqual(booleanExclude(squareA(), squareBOverlap()),
                         booleanExclude(squareBOverlap(), squareA())))
}

@Test func boolDecompositionOverlapping() {
    let a = squareA()
    let b = squareBOverlap()
    let lhs = booleanUnion(booleanSubtract(a, b), booleanIntersect(a, b))
    #expect(regionsEqual(lhs, a))
}

@Test func boolExcludeInvolutionOverlapping() {
    let a = squareA()
    let b = squareBOverlap()
    let result = booleanExclude(booleanExclude(a, b), b)
    #expect(regionsEqual(result, a))
}

// MARK: - Associativity

private func vennA() -> BoolPolygonSet {
    [[(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]]
}
private func vennB() -> BoolPolygonSet {
    [[(6.0, 0.0), (16.0, 0.0), (16.0, 10.0), (6.0, 10.0)]]
}
private func vennC() -> BoolPolygonSet {
    [[(3.0, 6.0), (13.0, 6.0), (13.0, 16.0), (3.0, 16.0)]]
}

@Test func boolUnionAssociativeThreeSquares() {
    let lhs = booleanUnion(booleanUnion(vennA(), vennB()), vennC())
    let rhs = booleanUnion(vennA(), booleanUnion(vennB(), vennC()))
    #expect(regionsEqual(lhs, rhs))
}

@Test func boolIntersectAssociativeThreeSquares() {
    let lhs = booleanIntersect(booleanIntersect(vennA(), vennB()), vennC())
    let rhs = booleanIntersect(vennA(), booleanIntersect(vennB(), vennC()))
    #expect(regionsEqual(lhs, rhs))
}

@Test func boolExcludeAssociativeThreeSquares() {
    let lhs = booleanExclude(booleanExclude(vennA(), vennB()), vennC())
    let rhs = booleanExclude(vennA(), booleanExclude(vennB(), vennC()))
    #expect(regionsEqual(lhs, rhs))
}

// MARK: - Shared-edge regression

@Test func sharedEdgesAllOps() {
    let a: BoolPolygonSet = [[(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]]
    let b: BoolPolygonSet = [[(5.0, 0.0), (15.0, 0.0), (15.0, 10.0), (5.0, 10.0)]]
    #expect(approxEqT(polygonSetAreaT(booleanUnion(a, b)), 150.0))
    #expect(approxEqT(polygonSetAreaT(booleanIntersect(a, b)), 50.0))
    #expect(approxEqT(polygonSetAreaT(booleanSubtract(a, b)), 50.0))
    #expect(approxEqT(polygonSetAreaT(booleanSubtract(b, a)), 50.0))
    #expect(approxEqT(polygonSetAreaT(booleanExclude(a, b)), 100.0))
}

// MARK: - Self-intersecting input (bowtie)

private func bowtie() -> BoolPolygonSet {
    [[(0.0, 0.0), (10.0, 10.0), (10.0, 0.0), (0.0, 10.0)]]
}

@Test func boolUnionBowtieWithEmpty() {
    let result = booleanUnion(bowtie(), [])
    #expect(approxEqT(polygonSetAreaT(result), 50.0))
}

@Test func boolUnionBowtieWithCoveringRect() {
    let rect: BoolPolygonSet = [[(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]]
    #expect(approxEqT(polygonSetAreaT(booleanUnion(bowtie(), rect)), 100.0))
}

@Test func boolIntersectBowtieBottomHalf() {
    let rect: BoolPolygonSet = [[(0.0, 0.0), (10.0, 0.0), (10.0, 5.0), (0.0, 5.0)]]
    let result = booleanIntersect(bowtie(), rect)
    #expect(approxEqT(polygonSetAreaT(result), 25.0))
}

@Test func boolSubtractRectFromBowtie() {
    let rect: BoolPolygonSet = [[(0.0, 0.0), (10.0, 0.0), (10.0, 5.0), (0.0, 5.0)]]
    let result = booleanSubtract(bowtie(), rect)
    #expect(approxEqT(polygonSetAreaT(result), 25.0))
}

// MARK: - Perturbation tests

private func perturbedFixture(_ delta: Double) -> (BoolPolygonSet, BoolPolygonSet) {
    let a: BoolPolygonSet = [[(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]]
    let b: BoolPolygonSet = [[(5.0, delta), (15.0, delta), (15.0, 10.0 + delta), (5.0, 10.0 + delta)]]
    return (a, b)
}

private func checkPerturbation(_ delta: Double) {
    let (a, b) = perturbedFixture(delta)
    let u = booleanUnion(a, b)
    let s = booleanSubtract(a, b)
    let uOk = abs(polygonSetAreaT(u) - 150.0) < 0.1
    let sOk = abs(polygonSetAreaT(s) - 50.0) < 0.1
    #expect(uOk, "delta \(delta): union area \(polygonSetAreaT(u)) not within 0.1 of 150")
    #expect(sOk, "delta \(delta): subtract area \(polygonSetAreaT(s)) not within 0.1 of 50")
}

@Test func perturb1eMinus15() { checkPerturbation(1e-15) }
@Test func perturb1eMinus11() { checkPerturbation(1e-11) }
@Test func perturb1eMinus10() { checkPerturbation(1e-10) }
@Test func perturb1eMinus8()  { checkPerturbation(1e-8)  }
@Test func perturb1eMinus6()  { checkPerturbation(1e-6)  }
@Test func perturb1eMinus3()  { checkPerturbation(1e-3)  }

// MARK: - project_onto_segment unit tests

@Test func projectOntoSegmentHorizontal() {
    let p = projectOntoSegment((0, 0), (10, 0), (5, 1e-11))
    #expect(p == (5, 0))
}

@Test func projectOntoSegmentVertical() {
    let p = projectOntoSegment((5, 0), (5, 10), (5 + 1e-11, 7))
    #expect(p == (5, 7))
}

@Test func projectOntoSegmentClampsLow() {
    #expect(projectOntoSegment((0, 0), (10, 0), (-5, 0)) == (0, 0))
}

@Test func projectOntoSegmentClampsHigh() {
    #expect(projectOntoSegment((0, 0), (10, 0), (15, 0)) == (10, 0))
}

@Test func projectOntoSegmentDegenerate() {
    #expect(projectOntoSegment((5, 5), (5, 5), (100, 100)) == (5, 5))
}

@Test func projectOntoSegmentDiagonal() {
    // 45-degree edge; point slightly off the line projects onto the line.
    let p = projectOntoSegment((0.0, 0.0), (10.0, 10.0), (5.0, 5.0 + 1e-10))
    #expect(abs(p.0 - 5.0) < 1e-10)
    #expect(abs(p.1 - 5.0) < 1e-10)
    #expect(p.0 == p.1)
}

// MARK: - Hole / non-axis-aligned / non-commutativity coverage
// Backported from jas_dioxus/src/algorithms/boolean.rs

@Test func intersectWithHoledPolygonPreservesHole() {
    // Donut: outer 10x10 minus inner 4x4.
    let donut: BoolPolygonSet = [
        [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)],
        [(3.0, 3.0), (7.0, 3.0), (7.0, 7.0), (3.0, 7.0)],
    ]
    let clip: BoolPolygonSet = [[(5.0, 0.0), (10.0, 0.0), (10.0, 10.0), (5.0, 10.0)]]
    let result = booleanIntersect(donut, clip)
    // Right half of outer (50) minus right half of hole (8) = 42.
    assertRegion(result, expectedArea: 42.0,
                 insidePts: [(6, 1), (8, 8), (9, 5)],
                 outsidePts: [(5.5, 5), (1, 1)],
                 expectedBbox: (5, 0, 5, 10))
}

@Test func triangleIntersectSquareClipsCorner() {
    let triangle: BoolPolygonSet = [[(0.0, 0.0), (10.0, 0.0), (0.0, 10.0)]]
    let result = booleanIntersect(squareA(), triangle)
    assertRegion(result, expectedArea: 50.0,
                 insidePts: [(1, 1), (3, 3)],
                 outsidePts: [(8, 8), (6, 6)],
                 expectedBbox: (0, 0, 10, 10))
}

@Test func triangleSubtractSquareLeavesOtherTriangle() {
    let triangle: BoolPolygonSet = [[(0.0, 0.0), (10.0, 0.0), (0.0, 10.0)]]
    let result = booleanSubtract(squareA(), triangle)
    assertRegion(result, expectedArea: 50.0,
                 insidePts: [(8, 8), (7, 5)],
                 outsidePts: [(1, 1), (3, 3)],
                 expectedBbox: (0, 0, 10, 10))
}

@Test func subtractEdgeTouchingReturnsAUnchanged() {
    let result = booleanSubtract(squareA(), squareEdgeTouching())
    assertRegion(result, expectedArea: 100.0,
                 insidePts: [(5, 5)], outsidePts: [(15, 5)],
                 expectedBbox: (0, 0, 10, 10))
}

@Test func boolSubtractIsNotCommutative() {
    let a = squareA()
    let b = squareBOverlap()
    let ab = booleanSubtract(a, b)
    let ba = booleanSubtract(b, a)
    // Same area (75 each) but different regions.
    #expect(!regionsEqual(ab, ba))
}

@Test func boolSubtractIsNotAssociative() {
    // (a - b) - b = a - b ; a - (b - b) = a
    let a = squareA()
    let b = squareBOverlap()
    let c = squareBOverlap()
    let lhs = booleanSubtract(booleanSubtract(a, b), c)
    let rhs = booleanSubtract(a, booleanSubtract(b, c))
    #expect(!regionsEqual(lhs, rhs))
}

// MARK: - Normalizer tests

private func totalArea(_ ps: BoolPolygonSet) -> Double {
    ps.map { abs(ringSignedAreaT($0)) }.reduce(0.0, +)
}

@Test func normSimpleSquarePassesThrough() {
    let input: BoolPolygonSet = [[(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]]
    let out = normalize(input)
    #expect(out.count == 1)
    #expect(approxEqT(totalArea(out), 100.0))
}

@Test func normSimpleTrianglePassesThrough() {
    let input: BoolPolygonSet = [[(0.0, 0.0), (10.0, 0.0), (5.0, 10.0)]]
    let out = normalize(input)
    #expect(out.count == 1)
    #expect(approxEqT(totalArea(out), 50.0))
}

@Test func normEmptyInputYieldsEmpty() {
    #expect(normalize([]).isEmpty)
}

@Test func normRingFewerThanThreeDropped() {
    #expect(normalize([[(0.0, 0.0), (10.0, 0.0)]]).isEmpty)
}

@Test func normConsecutiveDuplicatesDeduped() {
    let input: BoolPolygonSet = [[
        (0.0, 0.0), (0.0, 0.0), (10.0, 0.0), (10.0, 10.0),
        (10.0, 10.0), (0.0, 10.0)
    ]]
    let out = normalize(input)
    #expect(out.count == 1)
    #expect(out[0].count == 4)
    #expect(approxEqT(totalArea(out), 100.0))
}

@Test func normFigureEightBecomesTwoTriangles() {
    let input: BoolPolygonSet = [[(0.0, 0.0), (10.0, 10.0), (10.0, 0.0), (0.0, 10.0)]]
    let out = normalize(input)
    #expect(out.count == 2)
    #expect(approxEqT(totalArea(out), 50.0))
    for r in out { #expect(r.count == 3) }
}
