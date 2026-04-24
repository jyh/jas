import Foundation
import Testing
@testable import JasLib

// Phase 4 of the Swift YAML tool-runtime migration. Covers the shared
// PathOps kernels previously duplicated across tool files.

// MARK: - Basic helpers

@Test func lerpMidpoint() {
    #expect(lerp(0, 10, 0.5) == 5)
    #expect(lerp(4, 8, 0) == 4)
    #expect(lerp(4, 8, 1) == 8)
}

@Test func evalCubicEndpoints() {
    let (sx, sy) = evalCubic(0, 0, 10, 0, 20, 0, 30, 0, 0)
    #expect(sx == 0 && sy == 0)
    let (ex, ey) = evalCubic(0, 0, 10, 0, 20, 0, 30, 0, 1)
    #expect(ex == 30 && ey == 0)
}

@Test func evalCubicMidpointStraightLine() {
    // Control points on the straight line produce the midpoint at t = 0.5.
    let (mx, my) = evalCubic(0, 0, 10, 0, 20, 0, 30, 0, 0.5)
    #expect(abs(mx - 15) < 1e-9 && abs(my) < 1e-9)
}

// MARK: - Endpoint / start-point

@Test func cmdEndpointVariants() {
    #expect(cmdEndpoint(.moveTo(1, 2))! == (1, 2))
    #expect(cmdEndpoint(.lineTo(3, 4))! == (3, 4))
    #expect(cmdEndpoint(.curveTo(x1: 0, y1: 0, x2: 0, y2: 0, x: 5, y: 6))! == (5, 6))
    #expect(cmdEndpoint(.quadTo(x1: 0, y1: 0, x: 7, y: 8))! == (7, 8))
    #expect(cmdEndpoint(.closePath) == nil)
}

@Test func cmdStartPointsChain() {
    let cmds: [PathCommand] = [
        .moveTo(1, 1),
        .lineTo(5, 1),
        .lineTo(5, 5),
    ]
    let starts = cmdStartPoints(cmds)
    #expect(starts.count == 3)
    #expect(starts[0] == (0, 0))
    #expect(starts[1] == (1, 1))
    #expect(starts[2] == (5, 1))
}

@Test func cmdStartPointAtIndex() {
    let cmds: [PathCommand] = [.moveTo(10, 10), .lineTo(20, 10)]
    #expect(cmdStartPoint(cmds, 0) == (0, 0))
    #expect(cmdStartPoint(cmds, 1) == (10, 10))
}

// MARK: - Flattening

@Test func flattenWithCmdMapLineSegments() {
    let cmds: [PathCommand] = [.moveTo(0, 0), .lineTo(10, 0), .lineTo(10, 10)]
    let (pts, map) = flattenWithCmdMap(cmds)
    #expect(pts.count == 3)
    #expect(map == [0, 1, 2])
    #expect(pts[0] == (0, 0))
    #expect(pts[1] == (10, 0))
    #expect(pts[2] == (10, 10))
}

@Test func flattenWithCmdMapCurveSamples20Steps() {
    let cmds: [PathCommand] = [
        .moveTo(0, 0),
        .curveTo(x1: 0, y1: 10, x2: 10, y2: 10, x: 10, y: 0),
    ]
    let (pts, map) = flattenWithCmdMap(cmds)
    // 1 point from moveTo + 20 samples from curveTo = 21 total.
    #expect(pts.count == 21)
    // All curve samples tagged with cmd index 1.
    #expect(map.filter { $0 == 1 }.count == 20)
}

// MARK: - Projection

@Test func closestOnLineMidpoint() {
    // Projecting (5, 5) onto segment (0,0)—(10,0).
    let (d, t) = closestOnLine(0, 0, 10, 0, 5, 5)
    #expect(abs(d - 5) < 1e-9)
    #expect(abs(t - 0.5) < 1e-9)
}

@Test func closestOnLineClampedBeforeStart() {
    let (d, t) = closestOnLine(0, 0, 10, 0, -5, 0)
    #expect(abs(d - 5) < 1e-9)
    #expect(t == 0)
}

@Test func closestOnCubicStraightLine() {
    // A cubic that traces the straight line (0,0)-(30,0). Projecting
    // (15, 3) should find t near 0.5 with distance near 3.
    let (d, t) = closestOnCubic(0, 0, 10, 0, 20, 0, 30, 0, 15, 3)
    #expect(abs(d - 3) < 1e-3)
    #expect(abs(t - 0.5) < 1e-2)
}

@Test func closestSegmentAndTPicksCorrectSegment() {
    let cmds: [PathCommand] = [
        .moveTo(0, 0),
        .lineTo(10, 0),
        .lineTo(10, 10),
    ]
    // (10, 5) sits on the second segment exactly.
    let r = closestSegmentAndT(cmds, 10, 5)!
    #expect(r.0 == 2)
    #expect(abs(r.1 - 0.5) < 1e-9)
}

// MARK: - Splitting

@Test func splitCubicAtHalfReconstructsEndpoints() {
    let (first, second) = splitCubic(0, 0, 0, 10, 10, 10, 10, 0, 0.5)
    // First ends at the curve's midpoint; second ends at the full endpoint.
    #expect(second.4 == 10 && second.5 == 0)
    // The midpoint of a symmetric bell at t=0.5 is (5, 7.5).
    #expect(abs(first.4 - 5) < 1e-9)
    #expect(abs(first.5 - 7.5) < 1e-9)
}

@Test func splitCubicCmdAtProducesTwoCurves() {
    let (a, b) = splitCubicCmdAt((0, 0), 0, 10, 10, 10, 10, 0, 0.5)
    if case .curveTo(_, _, _, _, let x, let y) = a {
        #expect(abs(x - 5) < 1e-9 && abs(y - 7.5) < 1e-9)
    } else { Issue.record("expected curveTo") }
    if case .curveTo(_, _, _, _, let x, let y) = b {
        #expect(x == 10 && y == 0)
    } else { Issue.record("expected curveTo") }
}

@Test func splitQuadCmdAtMidpoint() {
    let (a, b) = splitQuadCmdAt((0, 0), 5, 10, 10, 0, 0.5)
    if case .quadTo(_, _, let x, let y) = a {
        // Midpoint of the quadratic is (5, 5).
        #expect(abs(x - 5) < 1e-9 && abs(y - 5) < 1e-9)
    } else { Issue.record("expected quadTo") }
    if case .quadTo(_, _, let x, let y) = b {
        #expect(x == 10 && y == 0)
    } else { Issue.record("expected quadTo") }
}

// MARK: - Anchor deletion

@Test func deleteAnchorInteriorMerges() {
    // 4 anchors: M, L, L, L — delete middle.
    let cmds: [PathCommand] = [
        .moveTo(0, 0),
        .lineTo(10, 0),
        .lineTo(20, 0),
        .lineTo(30, 0),
    ]
    let r = deleteAnchorFromPath(cmds, 1)!
    #expect(r.count == 3)
    if case .lineTo(let x, _) = r[1] {
        #expect(x == 20)
    } else { Issue.record("expected lineTo after merge") }
}

@Test func deleteAnchorFirstPromotesSecond() {
    let cmds: [PathCommand] = [
        .moveTo(0, 0),
        .lineTo(10, 0),
        .lineTo(20, 0),
    ]
    let r = deleteAnchorFromPath(cmds, 0)!
    if case .moveTo(let x, _) = r[0] {
        #expect(x == 10)
    } else { Issue.record("expected moveTo after promotion") }
}

@Test func deleteAnchorWithTwoAnchorsReturnsNil() {
    let cmds: [PathCommand] = [.moveTo(0, 0), .lineTo(10, 0)]
    #expect(deleteAnchorFromPath(cmds, 0) == nil)
}

// MARK: - Anchor insertion

@Test func insertPointInPathLineSegmentAtHalf() {
    let cmds: [PathCommand] = [.moveTo(0, 0), .lineTo(10, 0)]
    let r = insertPointInPath(cmds, 1, 0.5)
    #expect(r.commands.count == 3)
    #expect(r.anchorX == 5 && r.anchorY == 0)
    #expect(r.firstNewIdx == 1)
}

@Test func insertPointInPathCurveSplit() {
    let cmds: [PathCommand] = [
        .moveTo(0, 0),
        .curveTo(x1: 0, y1: 10, x2: 10, y2: 10, x: 10, y: 0),
    ]
    let r = insertPointInPath(cmds, 1, 0.5)
    // Two curveTos replace the original.
    #expect(r.commands.count == 3)
    if case .curveTo = r.commands[1] {} else { Issue.record("expected curveTo") }
    if case .curveTo = r.commands[2] {} else { Issue.record("expected curveTo") }
    #expect(abs(r.anchorX - 5) < 1e-9)
    #expect(abs(r.anchorY - 7.5) < 1e-9)
}

// MARK: - Liang-Barsky

@Test func lineSegmentIntersectsRectHitsAndMisses() {
    // Crosses through.
    #expect(lineSegmentIntersectsRect(-1, 5, 20, 5, 0, 0, 10, 10))
    // Entirely outside.
    #expect(!lineSegmentIntersectsRect(-5, -5, -1, -1, 0, 0, 10, 10))
    // Endpoint inside.
    #expect(lineSegmentIntersectsRect(5, 5, 20, 20, 0, 0, 10, 10))
}

@Test func liangBarskyEntryExitParameters() {
    // Horizontal line through a centered square.
    let tMin = liangBarskyTMin(-5, 5, 15, 5, 0, 0, 10, 10)
    let tMax = liangBarskyTMax(-5, 5, 15, 5, 0, 0, 10, 10)
    #expect(abs(tMin - 0.25) < 1e-9)
    #expect(abs(tMax - 0.75) < 1e-9)
}

// MARK: - Path ↔ PolygonSet adapters

@Test func pathToPolygonSetSingleSquare() {
    let cmds: [PathCommand] = [
        .moveTo(0, 0),
        .lineTo(10, 0),
        .lineTo(10, 10),
        .lineTo(0, 10),
        .closePath,
    ]
    let ps = pathToPolygonSet(cmds)
    #expect(ps.count == 1)
    #expect(ps[0].count == 4)
    #expect(ps[0][0] == (0, 0))
    #expect(ps[0][2] == (10, 10))
}

@Test func pathToPolygonSetMultipleSubpaths() {
    // Two disjoint triangles.
    let cmds: [PathCommand] = [
        .moveTo(0, 0),
        .lineTo(10, 0),
        .lineTo(5, 10),
        .closePath,
        .moveTo(20, 0),
        .lineTo(30, 0),
        .lineTo(25, 10),
        .closePath,
    ]
    let ps = pathToPolygonSet(cmds)
    #expect(ps.count == 2)
    #expect(ps[0].count == 3)
    #expect(ps[1].count == 3)
    #expect(ps[0][0] == (0, 0))
    #expect(ps[1][0] == (20, 0))
}

@Test func polygonSetToPathSingleRing() {
    let ps: BoolPolygonSet = [[(0, 0), (10, 0), (10, 10), (0, 10)]]
    let cmds = polygonSetToPath(ps)
    // 4-vertex ring → MoveTo + 3 LineTo + ClosePath = 5 commands.
    #expect(cmds.count == 5)
    if case .moveTo(let x, let y) = cmds[0] {
        #expect(x == 0 && y == 0)
    } else {
        Issue.record("expected moveTo at index 0")
    }
    if case .closePath = cmds[4] {} else {
        Issue.record("expected closePath at index 4")
    }
}

@Test func polygonSetToPathDropsDegenerateRings() {
    // Two rings: one valid (3 points), one 2-point (degenerate).
    let ps: BoolPolygonSet = [
        [(0, 0), (10, 0), (5, 10)],
        [(20, 0), (30, 0)],
    ]
    let cmds = polygonSetToPath(ps)
    // Only the valid ring emits commands: MoveTo + 2 LineTo + Close.
    #expect(cmds.count == 4)
}

@Test func polygonSetRoundtripThroughPath() {
    let cmds: [PathCommand] = [
        .moveTo(0, 0),
        .lineTo(10, 0),
        .lineTo(10, 10),
        .lineTo(0, 10),
        .closePath,
    ]
    let ps1 = pathToPolygonSet(cmds)
    let cmds2 = polygonSetToPath(ps1)
    let ps2 = pathToPolygonSet(cmds2)
    #expect(ps1.count == ps2.count)
    for i in ps1.indices {
        #expect(ps1[i].count == ps2[i].count)
        for j in ps1[i].indices {
            #expect(ps1[i][j] == ps2[i][j])
        }
    }
}
