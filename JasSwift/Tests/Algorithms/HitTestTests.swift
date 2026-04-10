import Testing
import Foundation
@testable import JasLib

// Mirrors the hit_test test suite in jas_dioxus/src/algorithms/hit_test.rs.

// MARK: - pointInRect

@Test func pointInRectInterior() {
    #expect(pointInRect(5, 5, 0, 0, 10, 10))
}

@Test func pointInRectOutside() {
    #expect(!pointInRect(15, 5, 0, 0, 10, 10))
    #expect(!pointInRect(-1, 5, 0, 0, 10, 10))
    #expect(!pointInRect(5, 15, 0, 0, 10, 10))
    #expect(!pointInRect(5, -1, 0, 0, 10, 10))
}

@Test func pointInRectOnEdge() {
    #expect(pointInRect(0, 5, 0, 0, 10, 10))
    #expect(pointInRect(10, 5, 0, 0, 10, 10))
    #expect(pointInRect(5, 0, 0, 0, 10, 10))
    #expect(pointInRect(5, 10, 0, 0, 10, 10))
}

@Test func pointInRectOnCorner() {
    #expect(pointInRect(0, 0, 0, 0, 10, 10))
    #expect(pointInRect(10, 10, 0, 0, 10, 10))
}

// MARK: - segmentsIntersect

@Test func segmentsIntersectCrossing() {
    #expect(segmentsIntersect(0, 0, 10, 10, 0, 10, 10, 0))
}

@Test func segmentsIntersectParallelNo() {
    #expect(!segmentsIntersect(0, 0, 10, 0, 0, 1, 10, 1))
}

@Test func segmentsIntersectSeparate() {
    #expect(!segmentsIntersect(0, 0, 1, 1, 5, 5, 6, 6))
}

@Test func segmentsIntersectTouchingAtEndpoint() {
    #expect(segmentsIntersect(0, 0, 5, 5, 5, 5, 10, 10))
}

@Test func segmentsIntersectTIntersection() {
    #expect(segmentsIntersect(0, 5, 10, 5, 5, 5, 5, 0))
}

// MARK: - segmentIntersectsRect

@Test func segmentInsideRect() {
    #expect(segmentIntersectsRect(2, 2, 8, 8, 0, 0, 10, 10))
}

@Test func segmentOutsideRect() {
    #expect(!segmentIntersectsRect(20, 0, 30, 0, 0, 0, 10, 10))
}

@Test func segmentCrossesRect() {
    #expect(segmentIntersectsRect(-5, 5, 15, 5, 0, 0, 10, 10))
}

@Test func segmentOneEndpointInside() {
    #expect(segmentIntersectsRect(5, 5, 20, 20, 0, 0, 10, 10))
}

@Test func segmentEndpointOnEdge() {
    #expect(segmentIntersectsRect(10, 5, 20, 5, 0, 0, 10, 10))
}

// MARK: - rectsIntersect

@Test func rectsIntersectOverlapping() {
    #expect(rectsIntersect(0, 0, 10, 10, 5, 5, 10, 10))
}

@Test func rectsIntersectSeparate() {
    #expect(!rectsIntersect(0, 0, 10, 10, 20, 0, 10, 10))
}

@Test func rectsIntersectContained() {
    #expect(rectsIntersect(0, 0, 100, 100, 25, 25, 50, 50))
}

@Test func rectsIntersectEdgeTouching() {
    #expect(!rectsIntersect(0, 0, 10, 10, 10, 0, 10, 10))
}

@Test func rectsIntersectCornerTouching() {
    #expect(!rectsIntersect(0, 0, 10, 10, 10, 10, 10, 10))
}

@Test func rectsIntersectIdentical() {
    #expect(rectsIntersect(0, 0, 10, 10, 0, 0, 10, 10))
}

// MARK: - elementIntersectsRect

@Test func lineElementIntersectsRectOverlapping() {
    let line = Element.line(Line(x1: -5, y1: 5, x2: 15, y2: 5))
    #expect(elementIntersectsRect(line, 0, 0, 10, 10))
}

@Test func lineElementOutsideRect() {
    let line = Element.line(Line(x1: 20, y1: 0, x2: 30, y2: 0))
    #expect(!elementIntersectsRect(line, 0, 0, 10, 10))
}

@Test func rectElementOverlappingRect() {
    let rect = Element.rect(Rect(x: 5, y: 5, width: 10, height: 10))
    #expect(elementIntersectsRect(rect, 0, 0, 10, 10))
}

@Test func rectElementOutsideRect() {
    let rect = Element.rect(Rect(x: 20, y: 20, width: 5, height: 5))
    #expect(!elementIntersectsRect(rect, 0, 0, 10, 10))
}

// MARK: - Transform-aware hit-testing

@Test func translatedLineIntersectsRect() {
    let line = Element.line(Line(x1: 0, y1: 5, x2: 10, y2: 5,
        transform: Transform.translate(100, 0)))
    #expect(elementIntersectsRect(line, 95, 0, 20, 10))
    #expect(!elementIntersectsRect(line, 0, 0, 10, 10))
}

@Test func rotatedRectIntersectsRect() {
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10,
        fill: Fill(color: .init(r: 0, g: 0, b: 0)),
        transform: Transform.rotate(45)))
    #expect(elementIntersectsRect(rect, 6, 6, 2, 2))
    #expect(!elementIntersectsRect(rect, 12, 0, 2, 2))
}

@Test func scaledLineIntersectsRect() {
    let line = Element.line(Line(x1: 0, y1: 0, x2: 5, y2: 0,
        transform: Transform.scale(2, 2)))
    #expect(elementIntersectsRect(line, 8, -1, 4, 2))
    #expect(elementIntersectsRect(line, 6, -1, 2, 2))
}

@Test func singularTransformReturnsFalse() {
    let line = Element.line(Line(x1: 0, y1: 0, x2: 10, y2: 0,
        transform: Transform.scale(0, 0)))
    #expect(!elementIntersectsRect(line, 0, 0, 10, 10))
}

@Test func noTransformStillWorks() {
    let line = Element.line(Line(x1: 0, y1: 5, x2: 10, y2: 5))
    #expect(elementIntersectsRect(line, 0, 0, 10, 10))
    #expect(!elementIntersectsRect(line, 20, 0, 10, 10))
}

@Test func translatedLineIntersectsPolygon() {
    let line = Element.line(Line(x1: 0, y1: 5, x2: 10, y2: 5,
        transform: Transform.translate(100, 0)))
    let sq = [(95.0, 0.0), (115.0, 0.0), (115.0, 10.0), (95.0, 10.0)]
    #expect(elementIntersectsPolygon(line, sq))
    let sq2 = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
    #expect(!elementIntersectsPolygon(line, sq2))
}
