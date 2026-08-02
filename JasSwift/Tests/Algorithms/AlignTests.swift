/// Tests for the Align algorithm primitives. Mirrors
/// `jas_dioxus/src/algorithms/align.rs` tests.
///
/// Stage 3d covers the reference enum, bounds helpers, and axis
/// utilities. The six Align operations land in Stage 3e, six
/// Distribute in 3f, two Distribute Spacing in 3g.

import Foundation
import Testing
@testable import JasLib

private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Element {
    .rect(Rect(x: x, y: y, width: w, height: h))
}

@Test func alignUnionBoundsEmptyReturnsZero() {
    let b = alignUnionBounds([], alignGeometricBounds)
    #expect(b.x == 0 && b.y == 0 && b.width == 0 && b.height == 0)
}

@Test func alignUnionBoundsSingleElement() {
    let b = alignUnionBounds([rect(10, 20, 30, 40)], alignGeometricBounds)
    #expect(b.x == 10 && b.y == 20 && b.width == 30 && b.height == 40)
}

@Test func alignUnionBoundsThreeElementsSpansAll() {
    let b = alignUnionBounds([
        rect(0, 0, 10, 10),
        rect(20, 5, 10, 10),
        rect(40, 40, 20, 20),
    ], alignGeometricBounds)
    #expect(b.x == 0 && b.y == 0 && b.width == 60 && b.height == 60)
}

@Test func alignAxisExtentHorizontal() {
    let (lo, hi, mid) = alignAxisExtent((10, 20, 40, 60), .horizontal)
    #expect(lo == 10 && hi == 50 && mid == 30)
}

@Test func alignAxisExtentVertical() {
    let (lo, hi, mid) = alignAxisExtent((10, 20, 40, 60), .vertical)
    #expect(lo == 20 && hi == 80 && mid == 50)
}

@Test func alignAnchorPositionMinCenterMax() {
    let b: BBox = (10, 20, 40, 60)
    #expect(alignAnchorPosition(b, .horizontal, .min) == 10)
    #expect(alignAnchorPosition(b, .horizontal, .center) == 30)
    #expect(alignAnchorPosition(b, .horizontal, .max) == 50)
    #expect(alignAnchorPosition(b, .vertical, .min) == 20)
    #expect(alignAnchorPosition(b, .vertical, .center) == 50)
    #expect(alignAnchorPosition(b, .vertical, .max) == 80)
}

private func bboxEqual(_ a: BBox, _ b: BBox) -> Bool {
    a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height
}

@Test func alignReferenceBboxUnpacksEachVariant() {
    let b: BBox = (1, 2, 3, 4)
    #expect(bboxEqual(AlignReference.selection(b).bbox, b))
    #expect(bboxEqual(AlignReference.artboard(b).bbox, b))
    #expect(bboxEqual(AlignReference.keyObject(bbox: b, path: [0]).bbox, b))
}

@Test func alignReferenceKeyPathOnlyForKeyObject() {
    let b: BBox = (0, 0, 10, 10)
    #expect(AlignReference.selection(b).keyPath == nil)
    #expect(AlignReference.artboard(b).keyPath == nil)
    #expect(AlignReference.keyObject(bbox: b, path: [0, 2]).keyPath == [0, 2])
}

@Test func alignPreviewBoundsMatchesElementBounds() {
    let e = rect(10, 20, 30, 40)
    let b = alignPreviewBounds(e)
    #expect(b.x == 10 && b.y == 20 && b.width == 30 && b.height == 40)
}

@Test func alignGeometricBoundsMatchesElementGeometricBounds() {
    let e = rect(10, 20, 30, 40)
    let b = alignGeometricBounds(e)
    #expect(b.x == 10 && b.y == 20 && b.width == 30 && b.height == 40)
}

// MARK: - Align operations

private func selectionRef(_ b: BBox) -> AlignReference { .selection(b) }
private func refOf(_ rects: [Element]) -> AlignReference {
    selectionRef(alignUnionBounds(rects, alignGeometricBounds))
}

@Test func alignLeftMovesTwoRectsToLeftEdge() {
    let rs = [rect(10, 0, 10, 10), rect(30, 0, 10, 10), rect(60, 0, 10, 10)]
    let r = refOf(rs)
    let input: [(ElementPath, Element)] = [([0], rs[0]), ([1], rs[1]), ([2], rs[2])]
    let out = alignLeft(input, r, alignGeometricBounds)
    #expect(out.count == 2)
    #expect(out[0] == AlignTranslation(path: [1], dx: -20, dy: 0))
    #expect(out[1] == AlignTranslation(path: [2], dx: -50, dy: 0))
}

@Test func alignRightMovesToRightEdge() {
    let rs = [rect(10, 0, 10, 10), rect(30, 0, 10, 10), rect(60, 0, 10, 10)]
    let r = refOf(rs)
    let input: [(ElementPath, Element)] = [([0], rs[0]), ([1], rs[1]), ([2], rs[2])]
    let out = alignRight(input, r, alignGeometricBounds)
    #expect(out.count == 2)
    #expect(out[0].dx == 50)
    #expect(out[1].dx == 30)
}

@Test func alignHorizontalCenterMovesToMidpoint() {
    let rs = [rect(10, 0, 10, 10), rect(30, 0, 10, 10), rect(60, 0, 10, 10)]
    let r = refOf(rs)
    let input: [(ElementPath, Element)] = [([0], rs[0]), ([1], rs[1]), ([2], rs[2])]
    let out = alignHorizontalCenter(input, r, alignGeometricBounds)
    #expect(out.count == 3)
    #expect(out[0].dx == 25)
    #expect(out[1].dx == 5)
    #expect(out[2].dx == -25)
}

@Test func alignTopOnlyAffectsY() {
    let rs = [rect(0, 10, 10, 10), rect(20, 30, 10, 10), rect(40, 50, 10, 10)]
    let r = refOf(rs)
    let input: [(ElementPath, Element)] = [([0], rs[0]), ([1], rs[1]), ([2], rs[2])]
    let out = alignTop(input, r, alignGeometricBounds)
    for t in out { #expect(t.dx == 0) }
    #expect(out.count == 2)
}

@Test func alignVerticalCenterMovesToMidline() {
    let rs = [rect(0, 0, 10, 10), rect(20, 20, 10, 10)]
    let r = refOf(rs)
    let input: [(ElementPath, Element)] = [([0], rs[0]), ([1], rs[1])]
    let out = alignVerticalCenter(input, r, alignGeometricBounds)
    #expect(out.count == 2)
    #expect(out[0].dy == 10)
    #expect(out[1].dy == -10)
}

@Test func alignBottomMovesToBottomEdge() {
    let rs = [rect(0, 0, 10, 20), rect(20, 0, 10, 10)]
    let r = refOf(rs)
    let input: [(ElementPath, Element)] = [([0], rs[0]), ([1], rs[1])]
    let out = alignBottom(input, r, alignGeometricBounds)
    #expect(out.count == 1)
    #expect(out[0].path == [1])
    #expect(out[0].dy == 10)
}

@Test func alignLeftWithKeyObjectDoesNotMoveKey() {
    let rs = [rect(10, 0, 10, 10), rect(30, 0, 10, 10), rect(60, 0, 10, 10)]
    let keyPath: ElementPath = [1]
    let r = AlignReference.keyObject(bbox: rs[1].geometricBounds, path: keyPath)
    let input: [(ElementPath, Element)] = [([0], rs[0]), ([1], rs[1]), ([2], rs[2])]
    let out = alignLeft(input, r, alignGeometricBounds)
    for t in out { #expect(t.path != keyPath) }
    #expect(out.count == 2)
    #expect(out[0] == AlignTranslation(path: [0], dx: 20, dy: 0))
    #expect(out[1] == AlignTranslation(path: [2], dx: -30, dy: 0))
}

@Test func alignLeftEmptyInputYieldsEmptyOutput() {
    let r: AlignReference = .selection((0, 0, 10, 10))
    let out = alignLeft([], r, alignGeometricBounds)
    #expect(out.isEmpty)
}

// MARK: - Distribute operations

@Test func distributeRequiresAtLeastThreeElements() {
    let rs = [rect(0, 0, 10, 10), rect(50, 0, 10, 10)]
    let r = refOf(rs)
    let input: [(ElementPath, Element)] = [([0], rs[0]), ([1], rs[1])]
    #expect(distributeLeft(input, r, alignGeometricBounds).isEmpty)
}

@Test func distributeLeftAlreadyEvenEmitsNoTranslations() {
    let rs = [rect(0, 0, 10, 10), rect(50, 0, 10, 10), rect(100, 0, 10, 10)]
    let r = refOf(rs)
    let input: [(ElementPath, Element)] = [([0], rs[0]), ([1], rs[1]), ([2], rs[2])]
    #expect(distributeLeft(input, r, alignGeometricBounds).isEmpty)
}

@Test func distributeLeftUnevenMovesMiddleToCenter() {
    let rs = [rect(0, 0, 10, 10), rect(30, 0, 10, 10), rect(100, 0, 10, 10)]
    let r = refOf(rs)
    let input: [(ElementPath, Element)] = [([0], rs[0]), ([1], rs[1]), ([2], rs[2])]
    let out = distributeLeft(input, r, alignGeometricBounds)
    #expect(out.count == 1)
    #expect(out[0] == AlignTranslation(path: [1], dx: 20, dy: 0))
}

@Test func distributeHorizontalCenterEvenlySpacesCenters() {
    let rs = [rect(0, 0, 10, 10), rect(20, 0, 10, 10), rect(100, 0, 10, 10)]
    let r = refOf(rs)
    let input: [(ElementPath, Element)] = [([0], rs[0]), ([1], rs[1]), ([2], rs[2])]
    let out = distributeHorizontalCenter(input, r, alignGeometricBounds)
    #expect(out.count == 1)
    #expect(out[0].path == [1])
    #expect(out[0].dx == 30)
}

@Test func distributeTopMovesOnlyY() {
    let rs = [rect(0, 0, 10, 10), rect(5, 30, 10, 10), rect(10, 100, 10, 10)]
    let r = refOf(rs)
    let input: [(ElementPath, Element)] = [([0], rs[0]), ([1], rs[1]), ([2], rs[2])]
    let out = distributeTop(input, r, alignGeometricBounds)
    #expect(out.count == 1)
    #expect(out[0].path == [1])
    #expect(out[0].dx == 0)
    #expect(out[0].dy == 20)
}

@Test func distributeHandlesUnsortedInput() {
    let rs = [rect(100, 0, 10, 10), rect(30, 0, 10, 10), rect(0, 0, 10, 10)]
    let r = refOf(rs)
    let input: [(ElementPath, Element)] = [([0], rs[0]), ([1], rs[1]), ([2], rs[2])]
    let out = distributeLeft(input, r, alignGeometricBounds)
    #expect(out.count == 1)
    #expect(out[0].path == [1])
    #expect(out[0].dx == 20)
}

@Test func distributeArtboardReferenceUsesArtboardExtent() {
    let rs = [rect(20, 0, 10, 10), rect(40, 0, 10, 10), rect(60, 0, 10, 10)]
    let r: AlignReference = .artboard((0, 0, 200, 100))
    let input: [(ElementPath, Element)] = [([0], rs[0]), ([1], rs[1]), ([2], rs[2])]
    let out = distributeLeft(input, r, alignGeometricBounds)
    #expect(out.count == 3)
    #expect(out[0].dx == -20)
    #expect(out[1].dx == 60)
    #expect(out[2].dx == 140)
}

@Test func distributeVerticalCenterWithKeySkipsKey() {
    let rs = [rect(0, 0, 10, 10), rect(0, 30, 10, 10), rect(0, 100, 10, 10)]
    let keyPath: ElementPath = [1]
    let r = AlignReference.keyObject(bbox: rs[1].geometricBounds, path: keyPath)
    let input: [(ElementPath, Element)] = [([0], rs[0]), ([1], rs[1]), ([2], rs[2])]
    let out = distributeVerticalCenter(input, r, alignGeometricBounds)
    for t in out { #expect(t.path != keyPath) }
}

// MARK: - Distribute Spacing operations

@Test func distributeSpacingRequiresAtLeastThreeElements() {
    let rs = [rect(0, 0, 10, 10), rect(50, 0, 10, 10)]
    let r = refOf(rs)
    let input: [(ElementPath, Element)] = [([0], rs[0]), ([1], rs[1])]
    #expect(distributeHorizontalSpacing(input, r, nil, alignGeometricBounds).isEmpty)
}

@Test func distributeHorizontalSpacingAverageEqualisesGaps() {
    let rs = [rect(0, 0, 10, 10), rect(20, 0, 10, 10), rect(90, 0, 10, 10)]
    let r = refOf(rs)
    let input: [(ElementPath, Element)] = [([0], rs[0]), ([1], rs[1]), ([2], rs[2])]
    let out = distributeHorizontalSpacing(input, r, nil, alignGeometricBounds)
    #expect(out.count == 1)
    #expect(out[0].path == [1])
    #expect(out[0].dx == 25)
}

@Test func distributeVerticalSpacingAverageEqualisesGaps() {
    let rs = [rect(0, 0, 10, 10), rect(0, 20, 10, 10), rect(0, 90, 10, 10)]
    let r = refOf(rs)
    let input: [(ElementPath, Element)] = [([0], rs[0]), ([1], rs[1]), ([2], rs[2])]
    let out = distributeVerticalSpacing(input, r, nil, alignGeometricBounds)
    #expect(out.count == 1)
    #expect(out[0].path == [1])
    #expect(out[0].dy == 25)
}

@Test func distributeSpacingExplicitWithoutKeyReturnsEmpty() {
    let rs = [rect(0, 0, 10, 10), rect(50, 0, 10, 10), rect(100, 0, 10, 10)]
    let r = refOf(rs)  // Selection ref, no key.
    let input: [(ElementPath, Element)] = [([0], rs[0]), ([1], rs[1]), ([2], rs[2])]
    let out = distributeHorizontalSpacing(input, r, 12, alignGeometricBounds)
    #expect(out.isEmpty)
}

@Test func distributeHorizontalSpacingExplicitAppliesExactGap() {
    let rs = [rect(0, 0, 10, 10), rect(100, 0, 10, 10), rect(200, 0, 10, 10)]
    let keyPath: ElementPath = [1]
    let r = AlignReference.keyObject(bbox: rs[1].geometricBounds, path: keyPath)
    let input: [(ElementPath, Element)] = [([0], rs[0]), ([1], rs[1]), ([2], rs[2])]
    let out = distributeHorizontalSpacing(input, r, 20, alignGeometricBounds)
    #expect(out.count == 2)
    #expect(out[0].path == [0])
    #expect(out[0].dx == 70)
    #expect(out[1].path == [2])
    #expect(out[1].dx == -70)
}

@Test func distributeSpacingExplicitZeroGapMakesElementsTouch() {
    let rs = [rect(0, 0, 10, 10), rect(100, 0, 10, 10), rect(200, 0, 10, 10)]
    let keyPath: ElementPath = [1]
    let r = AlignReference.keyObject(bbox: rs[1].geometricBounds, path: keyPath)
    let input: [(ElementPath, Element)] = [([0], rs[0]), ([1], rs[1]), ([2], rs[2])]
    let out = distributeHorizontalSpacing(input, r, 0, alignGeometricBounds)
    #expect(out.count == 2)
    #expect(out[0].dx == 90)
    #expect(out[1].dx == -90)
}


// MARK: - RESOLVEDALIGN: align must measure what is DRAWN
//
// `alignPreviewBounds` and `alignGeometricBounds` are both resolver-less, so a
// symbol instance measured as a zero box at the origin whichever way Use
// Preview Bounds was set. Measured in the Rust twin before the repair: union
// (0,0,110,110) and Align Right moving the instance 110 when the only honest
// answer was 95.
//
// Twins of Rust's tests in algorithms/align.rs.

private func alignRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double,
                       id: String? = nil) -> Element {
    .rect(Rect(x: x, y: y, width: w, height: h, id: id))
}

@Test func alignRightMovesASymbolInstanceByItsDrawnEdge() {
    // Master at (5,7,10,20) → right edge 15; anchor at (100,100,10,10) → 110.
    let instance = Element.live(.reference(ReferenceElem(
        target: ElementRef("m1"), name: nil, id: "i1")))
    let anchor = alignRect(100, 100, 10, 10)
    let doc = Document(layers: [Layer(children: [instance, anchor])],
                       symbols: [alignRect(5, 7, 10, 20, id: "m1")])
    let resolver = RebuildResolver(document: doc)
    let bf: AlignBoundsFn = { alignResolvedBounds($0, resolver, alignGeometricBounds) }

    let u = alignUnionBounds([instance, anchor], bf)
    #expect(abs(u.x - 5) < 1e-9 && abs(u.y - 7) < 1e-9
            && abs(u.width - 105) < 1e-9 && abs(u.height - 103) < 1e-9,
            "union: expected (5,7,105,103), got \(u)")

    let out = alignRight([([0, 0], instance), ([0, 1], anchor)], .selection(u), bf)
    #expect(out.count == 1, "only the instance moves: \(out)")
    #expect(out.first?.path == [0, 0])
    #expect(abs((out.first?.dx ?? 0) - 95) < 1e-9, "expected dx 95, got \(String(describing: out.first))")
}

@Test func previewModeStillInflatesAStrokedLeafInsideAGroup() {
    // The trap this nearly walked into: wrapping the resolver around a
    // HARD-CODED geometric leaf would fix the instance and silently drop stroke
    // inflation from every stroked element inside a group. The leaf is a
    // parameter for exactly this reason, so the two modes still differ.
    let stroked = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10,
                                    stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 4)))
    let group = Element.group(Group(children: [stroked]))
    let resolver = RebuildResolver(document: Document(layers: []))

    let geo = alignResolvedBounds(group, resolver, alignGeometricBounds)
    let prev = alignResolvedBounds(group, resolver, alignPreviewBounds)
    #expect(geo == (x: 0, y: 0, width: 10, height: 10))
    #expect(prev == (x: -2, y: -2, width: 14, height: 14),
            "preview must still inflate by half the 4pt stroke, got \(prev)")
}

@Test func theResolverlessAlignBoundsFnsAreUnchanged() {
    // The conformance runner has no document and passes these directly; they
    // must keep answering exactly what they always did.
    let r = alignRect(1, 2, 3, 4)
    #expect(alignPreviewBounds(r) == r.bounds)
    #expect(alignGeometricBounds(r) == r.geometricBounds)
    let inst = Element.live(.reference(ReferenceElem(target: ElementRef("m1"), name: nil)))
    #expect(alignGeometricBounds(inst) == (x: 0, y: 0, width: 0, height: 0))
}
