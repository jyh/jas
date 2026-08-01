import Testing
@testable import JasLib

// Mirrors workspace_interpreter/tests/test_dash_renderer.py and
// jas_dioxus/src/algorithms/dash_renderer.rs tests.

private func approxEq(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool {
    abs(a - b) < tol
}

private func endpoints(_ cmd: PathCommand) -> (Double, Double)? {
    switch cmd {
    case .moveTo(let x, let y), .lineTo(let x, let y): return (x, y)
    default: return nil
    }
}

@Test func dashEmptyArrayReturnsPathUnchanged() {
    let path: [PathCommand] = [.moveTo(0, 0), .lineTo(10, 0), .lineTo(10, 10), .closePath]
    let r = DashRenderer.expandDashedStroke(path: path, dashArray: [], alignAnchors: false)
    #expect(r.count == 1)
    #expect(r[0] == path)
}

@Test func dashEmptyPathReturnsEmpty() {
    let r = DashRenderer.expandDashedStroke(path: [], dashArray: [4, 2], alignAnchors: false)
    #expect(r.isEmpty)
}

@Test func dashPreserveSimpleLineOnePeriod() {
    let path: [PathCommand] = [.moveTo(0, 0), .lineTo(6, 0)]
    let r = DashRenderer.expandDashedStroke(path: path, dashArray: [4, 2], alignAnchors: false)
    #expect(r.count == 1)
    #expect(r[0] == [.moveTo(0, 0), .lineTo(4, 0)])
}

@Test func dashPreserveSimpleLinePartialPeriod() {
    let path: [PathCommand] = [.moveTo(0, 0), .lineTo(10, 0)]
    let r = DashRenderer.expandDashedStroke(path: path, dashArray: [4, 2], alignAnchors: false)
    #expect(r.count == 2)
    #expect(r[0] == [.moveTo(0, 0), .lineTo(4, 0)])
    #expect(r[1] == [.moveTo(6, 0), .lineTo(10, 0)])
}

@Test func dashPreserveDashSpansCorner() {
    let path: [PathCommand] = [.moveTo(0, 0), .lineTo(5, 0), .lineTo(5, 5)]
    let r = DashRenderer.expandDashedStroke(path: path, dashArray: [4, 2], alignAnchors: false)
    #expect(r.count == 2)
    #expect(r[0] == [.moveTo(0, 0), .lineTo(4, 0)])
    #expect(r[1] == [.moveTo(5, 1), .lineTo(5, 5)])
}

@Test func dashAlignOpenTwoAnchorLineNoFlexNeeded() {
    let path: [PathCommand] = [.moveTo(0, 0), .lineTo(10, 0)]
    let r = DashRenderer.expandDashedStroke(path: path, dashArray: [4, 2], alignAnchors: true)
    #expect(r.count == 2)
    #expect(r[0] == [.moveTo(0, 0), .lineTo(4, 0)])
    #expect(r[1] == [.moveTo(6, 0), .lineTo(10, 0)])
}

@Test func dashAlignOpenPathEndpointStartsWithFullDash() {
    let path: [PathCommand] = [.moveTo(0, 0), .lineTo(20, 0)]
    let r = DashRenderer.expandDashedStroke(path: path, dashArray: [4, 2], alignAnchors: true)
    #expect(!r.isEmpty)
    #expect(r[0][0] == .moveTo(0, 0))
}

@Test func dashAlignClosedRectDashSpansCorner() {
    let path: [PathCommand] = [
        .moveTo(0, 0), .lineTo(24, 0), .lineTo(24, 24),
        .lineTo(0, 24), .closePath,
    ]
    let r = DashRenderer.expandDashedStroke(path: path, dashArray: [16, 4], alignAnchors: true)
    var spansCorner = false
    outer: for sub in r {
        for (idx, cmd) in sub.enumerated() {
            if let (x, y) = endpoints(cmd), approxEq(x, 24), approxEq(y, 0) {
                if idx > 0 && idx < sub.count - 1 {
                    spansCorner = true
                    break outer
                }
            }
        }
    }
    #expect(spansCorner)
}

@Test func dashAlignOpenZigzagTerminatesAtEndpoint() {
    let path: [PathCommand] = [.moveTo(0, 0), .lineTo(50, 0), .lineTo(50, 75)]
    let r = DashRenderer.expandDashedStroke(path: path, dashArray: [12, 6], alignAnchors: true)
    #expect(!r.isEmpty)
    let lastCmd = r.last!.last!
    if let (x, y) = endpoints(lastCmd) {
        #expect(approxEq(x, 50))
        #expect(approxEq(y, 75))
    } else {
        Issue.record("last command should be lineTo")
    }
}

// MARK: - S-4: a leading ClosePath is a no-op
//
// Ruled by JYH at the fleet council, 2026-07-27. A subpath that is
// nothing but Z establishes no anchor and produces no dash. Swift
// already behaved this way when these were written -- expandPreserve and
// expandAlign both guard the cyclic wrap on `anchors.first`, and
// expandAlign guards `nSegs` on `anchorsWalk.count > 0` -- so these are
// regression pins, not a fix. The live reference raised IndexError on
// the same inputs; these are its counterparts, and mirror the
// `leading_close_*` tests in jas_dioxus/src/algorithms/dash_renderer.rs.

@Test func dashLeadingCloseBareProducesNoDashPreserve() {
    #expect(DashRenderer.expandDashedStroke(
        path: [.closePath], dashArray: [4, 2], alignAnchors: false).isEmpty)
}

@Test func dashLeadingCloseBareProducesNoDashAlign() {
    #expect(DashRenderer.expandDashedStroke(
        path: [.closePath], dashArray: [4, 2], alignAnchors: true).isEmpty)
}

/// A leading Z is a no-op, not a poison pill: the subpath after it still
/// dashes. Asserted as equality against the same path WITHOUT the leading
/// Z, so an implementation that bailed out early and returned nothing
/// would fail rather than pass vacuously. The companion count assertion
/// keeps the equality non-vacuous.
@Test func dashLeadingCloseDoesNotSuppressTheRealSubpath() {
    let real: [PathCommand] = [.moveTo(0, 0), .lineTo(20, 0)]
    let withZ: [PathCommand] = [.closePath] + real
    for align in [false, true] {
        let a = DashRenderer.expandDashedStroke(
            path: withZ, dashArray: [4, 2], alignAnchors: align)
        let b = DashRenderer.expandDashedStroke(
            path: real, dashArray: [4, 2], alignAnchors: align)
        #expect(a == b, "align=\(align)")
        #expect(a.count == 4, "align=\(align)")
    }
}

@Test func dashDeterminism() {
    let path: [PathCommand] = [
        .moveTo(0, 0), .lineTo(100, 0), .lineTo(100, 60),
        .lineTo(0, 60), .closePath,
    ]
    let r1 = DashRenderer.expandDashedStroke(path: path, dashArray: [12, 6], alignAnchors: true)
    let r2 = DashRenderer.expandDashedStroke(path: path, dashArray: [12, 6], alignAnchors: true)
    #expect(r1 == r2)
}

// MARK: - Curve segments (DASH_ALIGN.md walk_dashes / subpath_between)
//
// Mirrors the `align_*_cubic_*` tests in
// jas_dioxus/src/algorithms/dash_renderer.rs. The checkers never restate
// the renderer's arithmetic: they evaluate the ORIGINAL cubic from its
// Bernstein definition -- a different formulation from the de-Casteljau
// lerps the renderer splits with -- and assert every point of every
// emitted dash lies on THAT curve. A renderer that walked the chord
// instead (the pre-fix behaviour) puts the whole run on y == 0, which
// `bulge` catches.

/// The reference arc: a symmetric hump from (0,0) to (60,0) whose height
/// is exactly 30 at t = 0.5 (y(t) = 120 t (1-t)) and whose chord is the
/// straight segment y == 0. Collapsing the curve to its chord is
/// therefore an error of up to 30 units.
private let dashArc: [PathCommand] = [
    .moveTo(0, 0),
    .curveTo(x1: 20, y1: 40, x2: 40, y2: 40, x: 60, y: 0),
]

/// Bernstein evaluation of dashArc -- the mathematical definition,
/// independent of how the renderer subdivides.
private func dashArcPoint(_ t: Double) -> (Double, Double) {
    let p0 = (0.0, 0.0), p1 = (20.0, 40.0), p2 = (40.0, 40.0), p3 = (60.0, 0.0)
    let mt = 1.0 - t
    let b0 = mt * mt * mt, b1 = 3 * mt * mt * t, b2 = 3 * mt * t * t, b3 = t * t * t
    return (b0 * p0.0 + b1 * p1.0 + b2 * p2.0 + b3 * p3.0,
            b0 * p0.1 + b1 * p1.1 + b2 * p2.1 + b3 * p3.1)
}

/// True distance from `p` to dashArc: a coarse scan of dashArcPoint to
/// bracket the closest parameter, then a ternary search to converge on
/// it. Refining matters -- a bare 4000-sample scan bottoms out around
/// 0.017 near the fast-moving ends, which would force a slack tolerance
/// and blunt the checker.
private func dashDistToArc(_ p: (Double, Double)) -> Double {
    func dAt(_ t: Double) -> Double {
        let q = dashArcPoint(t)
        return ((q.0 - p.0) * (q.0 - p.0) + (q.1 - p.1) * (q.1 - p.1)).squareRoot()
    }
    let n = 2000
    var bestI = 0
    var best = Double.infinity
    for i in 0...n {
        let d = dAt(Double(i) / Double(n))
        if d < best { best = d; bestI = i }
    }
    var lo = Double(max(bestI - 1, 0)) / Double(n)
    var hi = Double(min(bestI + 1, n)) / Double(n)
    for _ in 0..<200 {
        let m1 = lo + (hi - lo) / 3.0
        let m2 = hi - (hi - lo) / 3.0
        if dAt(m1) < dAt(m2) { hi = m2 } else { lo = m1 }
    }
    return min(dAt(0.5 * (lo + hi)), best)
}

/// Every point the emitted sub-paths actually draw through: line
/// endpoints, and curves sampled along their own Bernstein form. Control
/// points are excluded -- they need not lie on the curve.
private func dashDrawnPoints(_ subs: [[PathCommand]]) -> [(Double, Double)] {
    var out: [(Double, Double)] = []
    for sub in subs {
        var cur = (0.0, 0.0)
        for cmd in sub {
            switch cmd {
            case .moveTo(let x, let y), .lineTo(let x, let y):
                out.append((x, y)); cur = (x, y)
            case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
                for i in 0...20 {
                    let t = Double(i) / 20.0, mt = 1.0 - t
                    let b0 = mt * mt * mt, b1 = 3 * mt * mt * t
                    let b2 = 3 * mt * t * t, b3 = t * t * t
                    out.append((b0 * cur.0 + b1 * x1 + b2 * x2 + b3 * x,
                                b0 * cur.1 + b1 * y1 + b2 * y2 + b3 * y))
                }
                cur = (x, y)
            case .quadTo(let x1, let y1, let x, let y):
                for i in 0...20 {
                    let t = Double(i) / 20.0, mt = 1.0 - t
                    out.append((mt * mt * cur.0 + 2 * mt * t * x1 + t * t * x,
                                mt * mt * cur.1 + 2 * mt * t * y1 + t * t * y))
                }
                cur = (x, y)
            default:
                break
            }
        }
    }
    return out
}

private func dashEndpoint(_ cmd: PathCommand) -> (Double, Double) {
    switch cmd {
    case .moveTo(let x, let y), .lineTo(let x, let y): return (x, y)
    case .curveTo(_, _, _, _, let x, let y): return (x, y)
    case .quadTo(_, _, let x, let y): return (x, y)
    default: return (Double.nan, Double.nan)
    }
}

private func dashMaxBulge(_ subs: [[PathCommand]]) -> Double {
    dashDrawnPoints(subs).reduce(0.0) { max($0, abs($1.1)) }
}

/// THE ARTIST-VISIBLE DEFECT. Draw a curve, dash it, switch the Stroke
/// panel to align-to-anchors: the whole stroke disappears. A bare open
/// cubic has no lineTo and no closePath, so a lines-only engine finds
/// "no segments" and emits nothing.
@Test func dashAlignOpenCubicIsNotDropped() {
    let r = DashRenderer.expandDashedStroke(
        path: dashArc, dashArray: [12, 6], alignAnchors: true)
    #expect(!r.isEmpty, "an open cubic must still produce dashes")
}

/// Preserve mode drops it too -- the pure function is blind to curves in
/// BOTH modes. Only align is artist-visible, because the canvas renderer
/// routes preserve mode to the platform's own dash array and never calls
/// this function.
@Test func dashPreserveOpenCubicIsNotDropped() {
    let r = DashRenderer.expandDashedStroke(
        path: dashArc, dashArray: [12, 6], alignAnchors: false)
    #expect(!r.isEmpty, "an open cubic must still produce dashes")
}

/// A closed cubic -- closePath makes it look like it "has segments", but
/// the anchor walk then finds a single point and folds to nothing.
@Test func dashAlignClosedCubicIsNotDropped() {
    let r = DashRenderer.expandDashedStroke(
        path: dashArc + [.closePath], dashArray: [12, 6], alignAnchors: true)
    #expect(!r.isEmpty, "a closed cubic must still produce dashes")
}

/// The dashes must ride the curve, and they must be curves.
@Test func dashAlignOpenCubicDashesRideTheCurve() {
    let r = DashRenderer.expandDashedStroke(
        path: dashArc, dashArray: [12, 6], alignAnchors: true)
    #expect(!r.isEmpty)
    for p in dashDrawnPoints(r) {
        let d = dashDistToArc(p)
        #expect(d < 1e-6, "drawn point \(p) is \(d) off the curve")
    }
    let bulge = dashMaxBulge(r)
    #expect(bulge > 20.0, "dashes hug the chord (max |y| = \(bulge)), not the arc")
    let emitsCurve = r.contains { sub in
        sub.contains { if case .curveTo = $0 { return true } else { return false } }
    }
    #expect(emitsCurve,
            "a dash over a cubic must be emitted as a cubic (DASH_ALIGN.md subpath_between)")
}

/// EE boundary: a single open segment gets a full dash at each end, so
/// the run starts exactly at the curve start and finishes exactly at the
/// curve end.
@Test func dashAlignOpenCubicStartsAndEndsOnTheEndpoints() {
    let r = DashRenderer.expandDashedStroke(
        path: dashArc, dashArray: [12, 6], alignAnchors: true)
    #expect(!r.isEmpty)
    guard let firstSub = r.first, let lastSub = r.last,
          let firstCmd = firstSub.first, let lastCmd = lastSub.last else {
        Issue.record("no dashes emitted"); return
    }
    let f = dashEndpoint(firstCmd)
    #expect(approxEq(f.0, 0) && approxEq(f.1, 0), "got \(f)")
    let l = dashEndpoint(lastCmd)
    #expect(approxEq(l.0, 60) && approxEq(l.1, 0), "got \(l)")
}

/// The silent-wrong-answer sibling: a curve followed by a line survives
/// the "has segments" screen, so nothing vanishes -- the curve is just
/// quietly replaced by its chord. Arc length and geometry are both
/// wrong, and the curve's own endpoint is not treated as an alignment
/// anchor.
@Test func dashAlignCubicThenLineKeepsTheCurveAndAnchorsItsEndpoint() {
    let path = dashArc + [.lineTo(90, 0)]
    let r = DashRenderer.expandDashedStroke(
        path: path, dashArray: [12, 6], alignAnchors: true)
    #expect(!r.isEmpty)
    let bulge = dashMaxBulge(r)
    #expect(bulge > 20.0, "the cubic was flattened to its chord (max |y| = \(bulge))")

    // (60,0) is an interior anchor -> a dash is centered on it, so some
    // sub-path crosses it rather than starting or ending there.
    var spans = false
    for sub in r {
        for (idx, cmd) in sub.enumerated() {
            let p = dashEndpoint(cmd)
            if approxEq(p.0, 60), approxEq(p.1, 0), idx > 0, idx < sub.count - 1 {
                spans = true
            }
        }
    }
    #expect(spans, "a dash must be centered on the curve's own endpoint anchor")
}
