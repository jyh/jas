import Testing
import AppKit
@testable import JasLib

// The selection control-point handles must be FIXED SIZE — the element's
// transform MOVES the handle positions but never SCALES the handle glyphs.
// `selectionHandleRects(doc, path)` returns document-space rects whose CENTER
// is the element-transformed control point and whose SIZE is the constant
// `handleDrawSize` (NOT multiplied by the element transform). Containers
// (Group/Layer) and Text/TextPath carry no control-point squares.
//
// Mirrors the Python `SelectionHandleRectsTest` reference (ref commit
// 08b3f3a9): identity positions; 2x-scale handles move but stay
// handleDrawSize; no handles for Group.

private func docWith(_ elem: Element) -> Document {
    let layer = Layer(name: "L0", children: [elem])
    return Document(layers: [layer], selection: [ElementSelection.all([0, 0])])
}

/// Sorted (centerX, centerY) of each handle rect, for order-independent compare.
private func sortedCenters(_ rects: [CGRect]) -> [(Double, Double)] {
    let half = handleDrawSize / 2
    var centers: [(Double, Double)] = []
    for r in rects {
        centers.append((Double(r.minX + half), Double(r.minY + half)))
    }
    centers.sort { a, b in a.0 != b.0 ? a.0 < b.0 : a.1 < b.1 }
    return centers
}

private func sortedPoints(_ pts: [(Double, Double)]) -> [(Double, Double)] {
    var p = pts
    p.sort { a, b in a.0 != b.0 ? a.0 < b.0 : a.1 < b.1 }
    return p
}

@Test func selectionHandlesIdentityAtControlPoints() {
    let rect = Element.rect(Rect(x: 10, y: 20, width: 30, height: 40))
    let rects = selectionHandleRects(docWith(rect), [0, 0])
    let centers = sortedCenters(rects)
    let expected = sortedPoints([(10, 20), (40, 20), (40, 60), (10, 60)])
    #expect(centers.count == expected.count)
    for (got, want) in zip(centers, expected) {
        #expect(abs(got.0 - want.0) < 1e-9)
        #expect(abs(got.1 - want.1) < 1e-9)
    }
    for r in rects {
        #expect(r.width == handleDrawSize)
        #expect(r.height == handleDrawSize)
    }
}

@Test func selectionHandlesScaledMoveButDoNotGrow() {
    // 100x100 rect at origin with a 2x scale transform.
    let rect = Element.rect(Rect(
        x: 0, y: 0, width: 100, height: 100,
        transform: Transform(a: 2, b: 0, c: 0, d: 2, e: 0, f: 0)))
    let rects = selectionHandleRects(docWith(rect), [0, 0])
    // Positions are the TRANSFORMED corners: (0,0),(200,0),(200,200),(0,200).
    let centers = sortedCenters(rects)
    let expected = sortedPoints([(0, 0), (200, 0), (200, 200), (0, 200)])
    #expect(centers.count == expected.count)
    for (got, want) in zip(centers, expected) {
        #expect(abs(got.0 - want.0) < 1e-9)
        #expect(abs(got.1 - want.1) < 1e-9)
    }
    // CRITICAL: each handle is still handleDrawSize, NOT 2x.
    for r in rects {
        #expect(r.width == handleDrawSize)
        #expect(r.height == handleDrawSize)
    }
}

@Test func selectionHandlesNoneForGroup() {
    let grp = Element.group(Group(children: [
        .rect(Rect(x: 0, y: 0, width: 10, height: 10))
    ]))
    let layer = Layer(name: "L0", children: [grp])
    let doc = Document(layers: [layer], selection: [ElementSelection.all([0, 0])])
    #expect(selectionHandleRects(doc, [0, 0]).isEmpty)
}
