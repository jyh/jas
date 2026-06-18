import Testing
import Foundation
@testable import JasLib

// Mirrors the simplify test suite in jas_dioxus/src/algorithms/simplify.rs.

private func isMoveTo(_ c: PathCommand) -> Bool { if case .moveTo = c { return true }; return false }
private func isLineTo(_ c: PathCommand) -> Bool { if case .lineTo = c { return true }; return false }
private func isCurveTo(_ c: PathCommand) -> Bool { if case .curveTo = c { return true }; return false }
private func isClosePath(_ c: PathCommand) -> Bool { if case .closePath = c { return true }; return false }

// MARK: - simplifyPolyline edge cases

@Test func simplifyEmptyInputReturnsEmpty() {
    #expect(simplifyPolyline([], precision: 0.5, closed: true).isEmpty)
}

@Test func simplifyTwoPointsEmitsLineTo() {
    let out = simplifyPolyline([(0.0, 0.0), (10.0, 0.0)], precision: 0.5, closed: false)
    #expect(out.count == 2)
    #expect(isMoveTo(out[0]))
    #expect(isLineTo(out[1]))
}

// MARK: - detectCorners

@Test func detectCornersOnSquare() {
    // Closed unit square — every vertex is a 90 degree corner.
    let sq: [(Double, Double)] = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
    let corners = detectCorners(sq, angleThreshold: defaultCornerAngle, closed: true)
    #expect(corners == [0, 1, 2, 3])
}

@Test func detectCornersOnCollinearPoints() {
    // Collinear points should not yield corners.
    let line: [(Double, Double)] = (0..<10).map { (Double($0), 0.0) }
    let corners = detectCorners(line, angleThreshold: defaultCornerAngle, closed: false)
    #expect(corners.isEmpty, "got unexpected corners on a straight line: \(corners)")
}

@Test func detectCornersBelowThresholdIsSmooth() {
    // 25-degree turn — below the 30-degree threshold, no corner.
    let angle = 25.0 * Double.pi / 180.0
    let pts: [(Double, Double)] = [
        (0.0, 0.0),
        (10.0, 0.0),
        (10.0 + 10.0 * cos(angle), 10.0 * sin(angle)),
    ]
    let corners = detectCorners(pts, angleThreshold: defaultCornerAngle, closed: false)
    #expect(corners.isEmpty, "25 degree turn should not be a corner, got \(corners)")
}

@Test func detectCornersAboveThresholdIsCorner() {
    // 45-degree turn — above the 30-degree threshold, marked.
    let angle = 45.0 * Double.pi / 180.0
    let pts: [(Double, Double)] = [
        (0.0, 0.0),
        (10.0, 0.0),
        (10.0 + 10.0 * cos(angle), 10.0 * sin(angle)),
    ]
    let corners = detectCorners(pts, angleThreshold: defaultCornerAngle, closed: false)
    #expect(corners == [1])
}

@Test func openPolylineEndpointsAreNotCorners() {
    // Three collinear points — endpoints at index 0 and 2 must not be
    // reported as corners, only vertex 1 could (and it shouldn't here
    // because it's collinear).
    let pts: [(Double, Double)] = [(0.0, 0.0), (5.0, 0.0), (10.0, 0.0)]
    let corners = detectCorners(pts, angleThreshold: defaultCornerAngle, closed: false)
    #expect(corners.isEmpty, "got \(corners)")
}

// MARK: - simplifyPolyline shape fitting

@Test func simplifySquareKeepsLines() {
    // Closed square — every edge is straight, so the output should be
    // 4 LineTo + ClosePath after the initial MoveTo. No CurveTo.
    let sq: [(Double, Double)] = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
    let out = simplifyPolyline(sq, precision: 0.5, closed: true)
    let curveCount = out.filter(isCurveTo).count
    let lineCount = out.filter(isLineTo).count
    #expect(curveCount == 0, "square should fit with no curves")
    #expect(lineCount == 4, "square should fit as 4 LineTo segments")
    #expect(out.last.map(isClosePath) == true)
}

@Test func simplifyCircleRecoversCurves() {
    // 32-segment regular circle sampling — should fit as Bezier curves
    // with no corners and no LineTo.
    let n = 32
    let r = 50.0
    let pts: [(Double, Double)] = (0..<n).map { i in
        let t = 2.0 * Double.pi * Double(i) / Double(n)
        return (r * cos(t), r * sin(t))
    }
    let out = simplifyPolyline(pts, precision: 0.5, closed: true)
    let curveCount = out.filter(isCurveTo).count
    let lineCount = out.filter(isLineTo).count
    #expect(curveCount > 0, "circle sampling should fit at least one CurveTo")
    #expect(lineCount == 0, "circle sampling should not produce LineTo")
    #expect(out.last.map(isClosePath) == true)
}
