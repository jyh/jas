import Testing
import AppKit
@testable import JasLib

// The selection OUTLINE trace + bezier/tangent handles are drawn UNDER the
// element transform, so a scaled element would thicken their fixed pen widths /
// circle radii. `selectionOutlineScale(doc, path)` returns the combined
// transform SCALE = sqrt(|det|) of the linear part, multiplied over the
// element's own transform and every ancestor (group/layer) transform; the
// overlay divides its fixed widths / radii by it so they render at a constant
// size (still zoom-scaled, like the handle squares). 1x for no transform, 2x
// for a uniform 2x scale, geometric mean for non-uniform.
//
// Mirrors the Python `SelectionOutlineScaleTest` reference (ref commit
// 107505da): identity -> 1.0; uniform 2x -> 2.0; non-uniform det 16 -> 4.0.

private func docWith(_ elem: Element) -> Document {
    let layer = Layer(name: "L0", children: [elem])
    return Document(layers: [layer], selection: [ElementSelection.all([0, 0])])
}

@Test func selectionOutlineScaleIdentityIsOne() {
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    #expect(selectionOutlineScale(docWith(rect), [0, 0]) == 1.0)
}

@Test func selectionOutlineScaleUniform2x() {
    let rect = Element.rect(Rect(
        x: 0, y: 0, width: 10, height: 10,
        transform: Transform(a: 2, b: 0, c: 0, d: 2, e: 0, f: 0)))
    #expect(selectionOutlineScale(docWith(rect), [0, 0]) == 2.0)
}

@Test func selectionOutlineScaleNonuniformGeometricMean() {
    // det = 2 * 8 = 16 -> sqrt = 4.
    let rect = Element.rect(Rect(
        x: 0, y: 0, width: 10, height: 10,
        transform: Transform(a: 2, b: 0, c: 0, d: 8, e: 0, f: 0)))
    #expect(selectionOutlineScale(docWith(rect), [0, 0]) == 4.0)
}
