import Testing
import Foundation
@testable import JasLib

// Mirrors the unit tests in jas_dioxus/src/tools/anchor_point_tool.rs
// `mod tests`. The tool itself drives a simple state machine over
// shared geometry helpers (convertCornerToSmooth /
// convertSmoothToCorner / movePathHandleIndependent / isSmoothPoint),
// so the meaningful coverage lives in those helpers.

// MARK: - Fixtures

private func makeLinePath() -> [PathCommand] {
    [
        .moveTo(0.0, 0.0),
        .lineTo(50.0, 0.0),
        .lineTo(100.0, 0.0),
    ]
}

private func makeSmoothPath() -> [PathCommand] {
    [
        .moveTo(0.0, 0.0),
        .curveTo(x1: 10.0, y1: 20.0, x2: 40.0, y2: 20.0, x: 50.0, y: 0.0),
        .curveTo(x1: 60.0, y1: -20.0, x2: 90.0, y2: -20.0, x: 100.0, y: 0.0),
    ]
}

// MARK: - isSmoothPoint

@Test func cornerPointIsNotSmooth() {
    let d = makeLinePath()
    #expect(!isSmoothPoint(d, anchorIdx: 0))
    #expect(!isSmoothPoint(d, anchorIdx: 1))
    #expect(!isSmoothPoint(d, anchorIdx: 2))
}

@Test func smoothPointIsSmooth() {
    let d = makeSmoothPath()
    // Anchor 1 (50, 0) has incoming (40, 20) and outgoing (60, -20).
    #expect(isSmoothPoint(d, anchorIdx: 1))
}

// MARK: - convertCornerToSmooth

@Test func convertCornerToSmoothCreatesHandles() {
    let d = makeLinePath()
    // Convert anchor 1 (50, 0) by dragging to (50, 30).
    let result = convertCornerToSmooth(d, anchorIdx: 1, hx: 50.0, hy: 30.0)
    // Anchor 1 should now be a CurveTo.
    if case .curveTo = result[1] {} else { Issue.record("expected curveTo at index 1"); return }
    // Outgoing handle on the next segment is at (50, 30).
    if case .curveTo(let x1, let y1, _, _, _, _) = result[2] {
        #expect(abs(x1 - 50.0) < 0.01)
        #expect(abs(y1 - 30.0) < 0.01)
    } else {
        Issue.record("expected curveTo at index 2")
    }
    // Incoming handle on this segment is reflected: (50, -30).
    if case .curveTo(_, _, let x2, let y2, _, _) = result[1] {
        #expect(abs(x2 - 50.0) < 0.01)
        #expect(abs(y2 - (-30.0)) < 0.01)
    }
}

@Test func convertFirstAnchorCornerToSmooth() {
    let d = makeLinePath()
    // Anchor 0 (MoveTo at 0, 0) — only outgoing handle to set.
    let result = convertCornerToSmooth(d, anchorIdx: 0, hx: 10.0, hy: 20.0)
    if case .curveTo(let x1, let y1, _, _, _, _) = result[1] {
        #expect(abs(x1 - 10.0) < 0.01)
        #expect(abs(y1 - 20.0) < 0.01)
    } else {
        Issue.record("expected curveTo after converting first anchor")
    }
}

@Test func convertLastAnchorCornerToSmooth() {
    let d = makeLinePath()
    // Anchor 2 (last LineTo at 100, 0) — only incoming handle.
    let result = convertCornerToSmooth(d, anchorIdx: 2, hx: 100.0, hy: 30.0)
    if case .curveTo(_, _, let x2, let y2, let x, let y) = result[2] {
        // Reflected of (100, 30) through (100, 0) = (100, -30).
        #expect(abs(x2 - 100.0) < 0.01)
        #expect(abs(y2 - (-30.0)) < 0.01)
        #expect(abs(x - 100.0) < 0.01)
        #expect(abs(y - 0.0) < 0.01)
    } else {
        Issue.record("expected curveTo at last anchor")
    }
}

// MARK: - convertSmoothToCorner

@Test func convertSmoothToCornerCollapsesHandles() {
    let d = makeSmoothPath()
    let result = convertSmoothToCorner(d, anchorIdx: 1)
    // After conversion, anchor 1 has no visible handles.
    #expect(!isSmoothPoint(result, anchorIdx: 1))
    // x2, y2 of cmd[1] should equal the anchor (50, 0).
    if case .curveTo(_, _, let x2, let y2, let x, let y) = result[1] {
        #expect(abs(x2 - x) < 0.01)
        #expect(abs(y2 - y) < 0.01)
    }
    // x1, y1 of cmd[2] should equal the anchor.
    if case .curveTo(let x1, let y1, _, _, _, _) = result[2] {
        #expect(abs(x1 - 50.0) < 0.01)
        #expect(abs(y1 - 0.0) < 0.01)
    }
}

// MARK: - movePathHandleIndependent

@Test func independentHandleMoveDoesNotReflect() {
    let d = makeSmoothPath()
    // Move outgoing handle of anchor 1 by (10, 5).
    let result = movePathHandleIndependent(d, anchorIdx: 1, handleType: "out", dx: 10.0, dy: 5.0)
    // Outgoing handle (x1 of cmd[2]) is moved.
    if case .curveTo(let x1, let y1, _, _, _, _) = result[2] {
        #expect(abs(x1 - 70.0) < 0.01)        // 60 + 10
        #expect(abs(y1 - (-15.0)) < 0.01)     // -20 + 5
    }
    // Incoming handle (x2 of cmd[1]) is unchanged.
    if case .curveTo(_, _, let x2, let y2, _, _) = result[1] {
        #expect(abs(x2 - 40.0) < 0.01)
        #expect(abs(y2 - 20.0) < 0.01)
    }
}
