import Testing
import AppKit
@testable import JasLib

// An element's own STROKE is drawn UNDER the element transform, so the matrix
// would scale the stroke width (on top of any scale_strokes bake at apply time)
// — a DOUBLE-scale. The render path threads an accumulated `elementScale` (the
// product of every ancestor + own transform `sqrt(|det|)`) and rebinds the
// element to a COPY whose stroke width is divided by that scale, so the element
// transform never thickens the stroke (it still scales with ZOOM, which is the
// view transform, not counted here). Because the rewrite happens at the source
// (the element copy), EVERY reader of `stroke.width` — the pen line width AND the
// Line / Path arrowhead SETBACK — sees the divided width.
//
// `transformScaleFactor(t)` is the per-transform `sqrt(|det|)` building block
// (the same one used by `selectionOutlineScale`). `counterScaledElement` is the
// pure analog of Python's `_counter_scaled_element` / OCaml's `Element.with_stroke`
// copy: it folds this element's own transform scale into the inherited
// `elementScale` and returns `(element, accumulatedScale)` where the element is a
// stroke-divided copy (or unchanged when there is no actual scale).
//
// Mirrors the Python `ElementStrokeCounterScaleTest` reference (ref commit
// 8ac2f4d1): transform_scale_factor(None)=1, (2x)=2, (det16)=4; a stroked rect
// (width 4) with a 2x transform -> returned stroke.width 2.0; no transform ->
// element unchanged (width 4); nested (parent 3x + own 2x, width 12) -> 2.0.

@Test func transformScaleFactorNilIsOne() {
    #expect(transformScaleFactor(nil) == 1.0)
}

@Test func transformScaleFactorUniform2x() {
    #expect(transformScaleFactor(Transform(a: 2, b: 0, c: 0, d: 2, e: 0, f: 0)) == 2.0)
}

@Test func transformScaleFactorNonuniformDet16() {
    // det = 2 * 8 = 16 -> sqrt = 4.
    #expect(transformScaleFactor(Transform(a: 2, b: 0, c: 0, d: 8, e: 0, f: 0)) == 4.0)
}

/// Build a stroked rect with the given width and optional transform.
private func strokedRect(width strokeWidth: Double, transform: Transform?) -> Element {
    let stroke = Stroke(color: Color(r: 0, g: 0, b: 0, a: 1), width: strokeWidth)
    return .rect(Rect(x: 0, y: 0, width: 10, height: 10,
                      fill: nil, stroke: stroke, transform: transform))
}

@Test func counterScaledElementStrokeDividedByOwn2x() {
    let elem = strokedRect(width: 4.0, transform: Transform(a: 2, b: 0, c: 0, d: 2, e: 0, f: 0))
    let (out, scale) = counterScaledElement(elem, elementScale: 1.0)
    #expect(scale == 2.0)
    #expect(out.stroke?.width == 2.0)  // 4 / 2 — the divided width every reader sees
}

@Test func counterScaledElementNoTransformUnchanged() {
    let elem = strokedRect(width: 4.0, transform: nil)
    let (out, scale) = counterScaledElement(elem, elementScale: 1.0)
    #expect(scale == 1.0)
    #expect(out.stroke?.width == 4.0)  // no actual scale -> element returned unchanged
    #expect(out == elem)
}

@Test func counterScaledElementAccumulatesWithParentScale() {
    // Stroked rect with its own 2x, inside a parent already at 3x; width 12.
    let elem = strokedRect(width: 12.0, transform: Transform(a: 2, b: 0, c: 0, d: 2, e: 0, f: 0))
    let (out, scale) = counterScaledElement(elem, elementScale: 3.0)
    #expect(scale == 6.0)            // 3 * 2
    #expect(out.stroke?.width == 2.0)  // 12 / 6
}
