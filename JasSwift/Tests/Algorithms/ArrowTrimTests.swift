import Testing
@testable import JasLib

// Mirrors jas_dioxus/src/algorithms/arrow_trim.rs tests. Pins the arc-length
// trim (de Casteljau split) that replaced the old anchor-displacement shorten.

private func endpoint(_ cmd: PathCommand) -> (Double, Double) {
    switch cmd {
    case .moveTo(let x, let y), .lineTo(let x, let y): return (x, y)
    case .curveTo(_, _, _, _, let x, let y): return (x, y)
    case .quadTo(_, _, let x, let y): return (x, y)
    default: return (Double.nan, Double.nan)
    }
}

private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-4) -> Bool {
    abs(a - b) < tol
}

@Test func arrowTrimLineBothEndsIsExact() {
    let d: [PathCommand] = [.moveTo(0, 0), .lineTo(100, 0)]
    let r = ArrowTrim.trimPath(d, startSetback: 10, endSetback: 20)
    #expect(r.count == 2)
    #expect(approx(endpoint(r[0]).0, 10))
    #expect(approx(endpoint(r[1]).0, 80))
}

@Test func arrowTrimZeroSetbackIsIdentity() {
    let d: [PathCommand] = [.moveTo(0, 0), .curveTo(x1: 10, y1: 10, x2: 20, y2: 10, x: 30, y: 0)]
    #expect(ArrowTrim.trimPath(d, startSetback: 0, endSetback: 0) == d)
}

@Test func arrowTrimCurveEndKeepsACurveNotAFold() {
    // Symmetric arch cubic; trim ~25% of arc off the end. The kept endpoint
    // lands ON the curve (x<40, lifted off y=0), still a CurveTo.
    let d: [PathCommand] = [.moveTo(0, 0), .curveTo(x1: 0, y1: 40, x2: 40, y2: 40, x: 40, y: 0)]
    let r = ArrowTrim.trimPath(d, startSetback: 0, endSetback: 20)
    #expect(r.count == 2)
    if case .curveTo = r[1] {} else { Issue.record("expected a CurveTo, got \(r[1])") }
    let e = endpoint(r[1])
    #expect(e.0 < 40 - 1e-6)
    #expect(e.1 > 1e-6)
    // Matches the Rust golden to the 4-decimal law.
    #expect(approx(e.0, 35.7550))
    #expect(approx(e.1, 19.3582))
}

@Test func arrowTrimSetbackExceedingTotalIsHeadsOnly() {
    let d: [PathCommand] = [.moveTo(0, 0), .lineTo(30, 0)]
    #expect(ArrowTrim.trimPath(d, startSetback: 0, endSetback: 50).isEmpty)
    #expect(ArrowTrim.trimPath(d, startSetback: 50, endSetback: 0).isEmpty)
}

@Test func arrowTrimOverlappingSetbacksDegenerateToHeadsOnly() {
    let d: [PathCommand] = [.moveTo(0, 0), .lineTo(40, 0)]
    #expect(ArrowTrim.trimPath(d, startSetback: 25, endSetback: 25).isEmpty)
}

@Test func arrowTrimSpansACornerAcrossTwoSegments() {
    let d: [PathCommand] = [.moveTo(0, 0), .lineTo(50, 0), .lineTo(50, 50)]
    let r = ArrowTrim.trimPath(d, startSetback: 10, endSetback: 10)
    #expect(r.count == 3)
    #expect(approx(endpoint(r[0]).0, 10))
    #expect(approx(endpoint(r[1]).0, 50))
    #expect(approx(endpoint(r[1]).1, 0))
    #expect(approx(endpoint(r[2]).0, 50))
    #expect(approx(endpoint(r[2]).1, 40))
}

@Test func arrowTrimQuadEndMatchesRustGolden() {
    let d: [PathCommand] = [.moveTo(0, 0), .quadTo(x1: 30, y1: 60, x: 60, y: 0)]
    let r = ArrowTrim.trimPath(d, startSetback: 0, endSetback: 15)
    #expect(r.count == 2)
    let e = endpoint(r[1])
    #expect(approx(e.0, 52.5346))
    #expect(approx(e.1, 13.0731))
}
