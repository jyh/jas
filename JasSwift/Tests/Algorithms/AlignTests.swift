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

