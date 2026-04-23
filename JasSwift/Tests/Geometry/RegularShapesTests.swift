import Foundation
import Testing
@testable import JasLib

// Phase 4 of the Swift YAML tool-runtime migration. Covers the
// regularPolygonPoints / starPoints kernels in Geometry/RegularShapes.swift.

@Test func regularPolygonTriangleEdgeHorizontal() {
    // Triangle whose first edge runs from (0, 0) to (10, 0) — the third
    // vertex sits above the edge at centroid offset sqrt(3)/2 * edge.
    let pts = regularPolygonPoints(0, 0, 10, 0, 3)
    #expect(pts.count == 3)
    #expect(abs(pts[0].0 - 0) < 1e-9)
    #expect(abs(pts[0].1 - 0) < 1e-9)
    #expect(abs(pts[1].0 - 10) < 1e-9)
    #expect(abs(pts[1].1 - 0) < 1e-9)
    // Equilateral triangle apex height = edge * sqrt(3)/2 ≈ 8.66.
    #expect(abs(pts[2].0 - 5) < 1e-9)
    #expect(abs(pts[2].1 - (10 * sqrt(3.0) / 2)) < 1e-6)
}

@Test func regularPolygonSquareFirstEdge() {
    let pts = regularPolygonPoints(0, 0, 10, 0, 4)
    #expect(pts.count == 4)
    // Second vertex matches the given edge endpoint.
    #expect(abs(pts[1].0 - 10) < 1e-9)
    #expect(abs(pts[1].1 - 0) < 1e-9)
    // Opposite edge sits at y = 10 (CW rotation to the right of the edge).
    #expect(abs(pts[2].1 - 10) < 1e-6)
    #expect(abs(pts[3].1 - 10) < 1e-6)
}

@Test func regularPolygonDegenerateReturnsNCopies() {
    let pts = regularPolygonPoints(3, 4, 3, 4, 5)
    #expect(pts.count == 5)
    for p in pts {
        #expect(p.0 == 3 && p.1 == 4)
    }
}

@Test func starPointsFirstOuterAtTopCenter() {
    // Inscribed in [0, 0] × [100, 100]. First outer vertex is top-center.
    let pts = starPoints(0, 0, 100, 100, 5)
    #expect(pts.count == 10)
    #expect(abs(pts[0].0 - 50) < 1e-9)
    #expect(abs(pts[0].1 - 0) < 1e-9)
}

@Test func starPointsAlternatesOuterInner() {
    let pts = starPoints(0, 0, 100, 100, 5)
    // Inner radius ratio is 0.4, so inner vertices sit at distance
    // 0.4 * 50 = 20 from center (50, 50).
    for k in 0..<10 {
        let dx = pts[k].0 - 50
        let dy = pts[k].1 - 50
        let r = sqrt(dx * dx + dy * dy)
        let expected = (k % 2 == 0) ? 50.0 : 20.0
        #expect(abs(r - expected) < 1e-6)
    }
}

@Test func starInnerRatioIsFortyPercent() {
    #expect(starInnerRatio == 0.4)
}
