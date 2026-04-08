import Testing
import Foundation
@testable import JasLib

// Mirrors the fit_curve test suite in jas_dioxus/src/algorithms/fit_curve.rs.

private func bezierAt(_ seg: FitSegment, _ t: Double) -> (Double, Double) {
    let mt = 1.0 - t
    let b0 = mt * mt * mt
    let b1 = 3.0 * t * mt * mt
    let b2 = 3.0 * t * t * mt
    let b3 = t * t * t
    return (
        b0 * seg.p1x + b1 * seg.c1x + b2 * seg.c2x + b3 * seg.p2x,
        b0 * seg.p1y + b1 * seg.c1y + b2 * seg.c2y + b3 * seg.p2y
    )
}

private func approxEq(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool {
    abs(a - b) < tol
}

private func pointApproxEq(_ a: (Double, Double), _ b: (Double, Double), _ tol: Double = 1e-9) -> Bool {
    approxEq(a.0, b.0, tol) && approxEq(a.1, b.1, tol)
}

// MARK: - Degenerate input

@Test func fitEmptyReturnsEmpty() {
    #expect(fitCurve(points: [], error: 1.0).isEmpty)
}

@Test func fitSinglePointReturnsEmpty() {
    #expect(fitCurve(points: [(0, 0)], error: 1.0).isEmpty)
}

@Test func fitTwoPointsReturnsOneSegment() {
    let r = fitCurve(points: [(0, 0), (10, 0)], error: 1.0)
    #expect(r.count == 1)
}

// MARK: - Endpoints preserved

@Test func fitTwoPointsEndpointsPreserved() {
    let pts: [(Double, Double)] = [(0, 0), (10, 0)]
    let r = fitCurve(points: pts, error: 1.0)
    let seg = r[0]
    #expect(pointApproxEq((seg.p1x, seg.p1y), pts[0]))
    #expect(pointApproxEq((seg.p2x, seg.p2y), pts.last!))
}

@Test func fitCurveEndpointsPreservedArc() {
    let pts: [(Double, Double)] = (0...20).map { i in
        let t = Double(i) / 20.0 * .pi / 2.0
        return (10.0 * cos(t), 10.0 * sin(t))
    }
    let r = fitCurve(points: pts, error: 0.5)
    #expect(!r.isEmpty)
    #expect(pointApproxEq((r[0].p1x, r[0].p1y), pts[0]))
    let last = r[r.count - 1]
    #expect(pointApproxEq((last.p2x, last.p2y), pts.last!))
}

// MARK: - Continuity at segment joins

@Test func fitSegmentsAreC0Continuous() {
    let pts: [(Double, Double)] = (0..<30).map { i in
        let x = Double(i)
        return (x, 5.0 * sin(x * 0.3))
    }
    let r = fitCurve(points: pts, error: 0.5)
    #expect(r.count >= 2)
    for i in 0..<(r.count - 1) {
        let endPrev = (r[i].p2x, r[i].p2y)
        let startNext = (r[i + 1].p1x, r[i + 1].p1y)
        #expect(pointApproxEq(endPrev, startNext))
    }
}

// MARK: - Approximation quality

@Test func fitTwoPointsSegmentPassesThroughEndpoints() {
    let pts: [(Double, Double)] = [(0, 0), (100, 50)]
    let r = fitCurve(points: pts, error: 1.0)
    let seg = r[0]
    #expect(pointApproxEq(bezierAt(seg, 0.0), pts[0]))
    #expect(pointApproxEq(bezierAt(seg, 1.0), pts[1]))
}

@Test func fitInputPointsWithinErrorTolerance() {
    let pts: [(Double, Double)] = (0..<15).map { i in
        let x = Double(i)
        return (x, 0.1 * x * x)
    }
    let error: Double = 1.0
    let segs = fitCurve(points: pts, error: error)
    let samplesPerSeg = 100
    var samples: [(Double, Double)] = []
    for seg in segs {
        for i in 0...samplesPerSeg {
            samples.append(bezierAt(seg, Double(i) / Double(samplesPerSeg)))
        }
    }
    for p in pts {
        var minDist = Double.infinity
        for s in samples {
            let dx = s.0 - p.0
            let dy = s.1 - p.1
            let d = sqrt(dx * dx + dy * dy)
            if d < minDist { minDist = d }
        }
        #expect(minDist <= error * 2.0, "point \(p) too far from fit: \(minDist)")
    }
}

// MARK: - Error parameter affects segment count

@Test func tighterErrorGivesAtLeastAsManySegments() {
    let pts: [(Double, Double)] = (0..<50).map { i in
        let x = Double(i) * 0.5
        return (x, 5.0 * sin(x * 0.5))
    }
    let loose = fitCurve(points: pts, error: 5.0)
    let tight = fitCurve(points: pts, error: 0.1)
    #expect(tight.count >= loose.count)
}

// MARK: - Specific shapes

@Test func fitStraightLineCollinearPoints() {
    let pts: [(Double, Double)] = (0..<10).map { (Double($0), 2.0 * Double($0)) }
    let r = fitCurve(points: pts, error: 1.0)
    #expect(r.count == 1)
}

@Test func fitHorizontalLine() {
    let pts: [(Double, Double)] = (0..<10).map { (Double($0), 5.0) }
    let r = fitCurve(points: pts, error: 1.0)
    #expect(r.count == 1)
    #expect(pointApproxEq((r[0].p1x, r[0].p1y), (0, 5)))
    #expect(pointApproxEq((r[0].p2x, r[0].p2y), (9, 5)))
}

@Test func fitVerticalLine() {
    let pts: [(Double, Double)] = (0..<10).map { (3.0, Double($0)) }
    let r = fitCurve(points: pts, error: 1.0)
    #expect(r.count == 1)
    #expect(pointApproxEq((r[0].p1x, r[0].p1y), (3, 0)))
    #expect(pointApproxEq((r[0].p2x, r[0].p2y), (3, 9)))
}

@Test func fitCircularArcReturnsSomeSegments() {
    let pts: [(Double, Double)] = (0...60).map { i in
        let t = Double(i) / 60.0 * .pi
        return (50.0 * cos(t), 50.0 * sin(t))
    }
    let r = fitCurve(points: pts, error: 0.5)
    #expect(!r.isEmpty)
    #expect(r.count <= pts.count)
}

@Test func fitTwoCoincidentPointsDoesNotPanic() {
    _ = fitCurve(points: [(5, 5), (5, 5)], error: 1.0)
}
