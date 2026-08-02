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

// MARK: - Filled polyline: the fill closes the point list implicitly
//
// A `<polyline>` with a fill paints as though the last point were joined back
// to the first, so `[[0,0],[0,100],[100,100],[100,0]]` strokes as a U but FILLS
// as the full 100x100 square. Mirrors the four
// `filled_polyline_*` / `unfilled_polyline_*` tests in
// jas_dioxus/src/algorithms/hit_test.rs, and the four `polyline_*_marquee_*`
// vectors in test_fixtures/algorithms/hit_test.json.

private func redFilledPolyline(_ pts: [(Double, Double)]) -> Element {
    .polyline(Polyline(points: pts, fill: Fill(color: .init(r: 255, g: 0, b: 0))))
}

@Test func filledPolylineMarqueeInsideImplicitClose() {
    let u = redFilledPolyline([(0, 0), (0, 100), (100, 100), (100, 0)])
    #expect(elementIntersectsRect(u, 40, 20, 20, 20))
}

@Test func unfilledPolylineMarqueeInsideOpenRun() {
    let u = Element.polyline(Polyline(points: [(0, 0), (0, 100), (100, 100), (100, 0)]))
    #expect(!elementIntersectsRect(u, 40, 20, 20, 20))
}

@Test func filledPolylineMarqueeOutsideBounds() {
    let u = redFilledPolyline([(0, 0), (0, 100), (100, 100), (100, 0)])
    #expect(!elementIntersectsRect(u, 200, 200, 10, 10))
}

@Test func filledPolylineMarqueeInBboxOutsideClosedFill() {
    // The arm is the bounding box, not a point-in-fill test: an open
    // triangle's empty bbox corner still answers true.
    let tri = redFilledPolyline([(0, 0), (100, 0), (100, 100)])
    #expect(elementIntersectsRect(tri, 5, 60, 10, 10))
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

// MARK: - RESOLVEDHIT: the resolver-less verb's contract, pinned
//
// The tempting "fix" for an unhittable symbol instance is to give the
// resolver-less path something to chew on — flatten the instance, cache
// geometry on it, widen the default case. Each would make the SHARED verb
// answer a question it cannot actually see: with no document behind it, there
// is no fact about where a target id is.
//
// These pin the boundary, so the shortcut cannot land later and look green.
// Twins of Rust's `the_resolverless_verb_keeps_answering_false_for_a_reference`
// and friends in algorithms/hit_test.rs.

private func bareReference() -> Element {
    Element.live(.reference(ReferenceElem(target: ElementRef("m1"), name: nil, id: nil)))
}

@Test func theResolverlessVerbKeepsAnsweringFalseForAReference() {
    let r = bareReference()
    #expect(!elementIntersectsRect(r, -1000, -1000, 2000, 2000))
    let big = [(-1000.0, -1000.0), (1000.0, -1000.0), (1000.0, 1000.0), (-1000.0, 1000.0)]
    #expect(!elementIntersectsPolygon(r, big))
    #expect(segmentsOfElement(r).isEmpty)
}

@Test func aResolverThatResolvesNothingAgreesWithTheResolverlessVerb() {
    // NullResolver is not a special case in the `...With` path — it is the
    // ordinary dangling answer. If these two ever disagree, the resolving form
    // has grown geometry out of nothing.
    let r = bareReference()
    #expect(elementIntersectsRectWith(r, -1000, -1000, 2000, 2000, NullResolver())
            == elementIntersectsRect(r, -1000, -1000, 2000, 2000))
}

@Test func aResolverThatResolvesTheTargetSeesTheMastersGeometry() {
    // The algorithm-level half of the controller tests: same element, two
    // resolvers, opposite answers — so the repair demonstrably turns on
    // resolution and not on anything else about the element.
    struct One: ElementResolver {
        let master: Element
        func resolve(_ id: ElementRef) -> Element? { id.id == "m1" ? master : nil }
    }
    let master = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10,
                                   fill: Fill(color: Color(r: 1, g: 0, b: 0, a: 1)),
                                   id: "m1"))
    let r = bareReference()
    #expect(elementIntersectsRectWith(r, -1, -1, 12, 12, One(master: master)))
    #expect(!elementIntersectsRect(r, -1, -1, 12, 12))
}
