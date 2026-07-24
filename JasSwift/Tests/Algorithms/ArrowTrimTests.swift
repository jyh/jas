import Testing
import Foundation
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

// ── Orientation (the trim-chord law, ARROWFIX2 item 1) ───────────
// Mirrors jas_dioxus/src/algorithms/arrow_trim.rs orientation tests.

@Test func arrowOrientJyhPenReleaseTailIsTheChordNotTheScrap() {
    // JYH's real saved pen-release tail (last two curves of Untitled-2.svg):
    // the final ~1.3px segment has ctrl2 coincident with the endpoint.
    let tail: [PathCommand] = [
        .moveTo(416.6667, 174.6667),
        .curveTo(x1: 415.5973, y1: 165.0424, x2: 411.0564, y2: 163.4462, x: 407.3333, y: 156.0),
        .curveTo(x1: 407.0522, y1: 155.4378, x2: 406.0, y2: 154.6667, x: 406.0, y: 154.6667),
    ]
    // Triangle head, stroke width 6.6667, scale 100 -> end_setback 26.6668 >
    // tail length 23.0559 -> heads-only -> whole-tail chord = -2.0608 rad.
    let (_, end100) = ArrowTrim.headAngles(tail, startSetback: 0, endSetback: 4.0 * 6.6667)
    #expect(approx(end100, -2.060755))
    let (_, end200) = ArrowTrim.headAngles(tail, startSetback: 0, endSetback: 4.0 * 6.6667 * 2.0)
    #expect(approx(end200, -2.060755))
    // Up-and-left on screen (y down): cos<0 (left), sin<0 (up).
    #expect(cos(end100) < 0 && sin(end100) < 0)
}

@Test func arrowOrientCurvedEndCutChordIsScaleSensitive() {
    let arch: [PathCommand] = [.moveTo(0, 0), .curveTo(x1: 0, y1: 100, x2: 200, y2: 100, x: 200, y: 0)]
    let (_, s100) = ArrowTrim.headAngles(arch, startSetback: 0, endSetback: 4.0 * 6.6667)
    let (_, s200) = ArrowTrim.headAngles(arch, startSetback: 0, endSetback: 4.0 * 6.6667 * 2.0)
    #expect(approx(s100, -1.374535))
    #expect(approx(s200, -1.165320))
    #expect(s200 > s100)  // a larger head samples a shallower chord
}

@Test func arrowOrientStartHeadIsTheChordNotTheHook() {
    let hook: [PathCommand] = [
        .moveTo(0, 0),
        .curveTo(x1: 0.3, y1: -0.3, x2: 0.6, y2: 0.2, x: 1.0, y: 0.0),
        .lineTo(60, 0),
    ]
    let (start, _) = ArrowTrim.headAngles(hook, startSetback: 4.0 * 6.6667, endSetback: 0)
    #expect(approx(start, Double.pi))  // straight back, outward
}

@Test func arrowOrientDegeneratePointFallsBackToTangentWalk() {
    let pt: [PathCommand] = [.moveTo(5, 5), .lineTo(5, 5)]
    let (start, end) = ArrowTrim.headAngles(pt, startSetback: 2, endSetback: 2)
    #expect(approx(start, Double.pi))
    #expect(approx(end, 0))
}
