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
