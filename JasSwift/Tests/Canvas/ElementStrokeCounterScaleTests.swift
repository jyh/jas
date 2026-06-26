import Testing
import AppKit
@testable import JasLib

// An element's own STROKE is drawn UNDER the element transform, so the matrix
// would scale the stroke width (on top of any scale_strokes bake at apply time)
// — a DOUBLE-scale. The render path threads an accumulated `elementScale` (the
// product of every ancestor + own transform `sqrt(|det|)`) and divides the
// element's stroke width by it at the stroke-set site, so the element transform
// never thickens the stroke (it still scales with ZOOM, which is the view
// transform, not counted here).
//
// `transformScaleFactor(t)` is the per-transform `sqrt(|det|)` building block
// (the same one used by `selectionOutlineScale`). `counterScaledElementStroke`
// is the pure analog of Python's `_counter_scaled_element`: it folds this
// element's own transform scale into the inherited `elementScale` and returns
// the (counter-scaled width, accumulated scale).
//
// Mirrors the Python `ElementStrokeCounterScaleTest` reference (ref commit
// 8ac2f4d1): transform_scale_factor(None)=1, (2x)=2, (det16)=4; stroke 4 with a
// 2x transform -> 2.0; no transform -> unchanged; nested (parent 3x + own 2x,
// width 12) -> 2.0.

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

@Test func strokeDividedByElementScale() {
    let (width, scale) = counterScaledElementStroke(
        strokeWidth: 4.0,
        transform: Transform(a: 2, b: 0, c: 0, d: 2, e: 0, f: 0),
        elementScale: 1.0)
    #expect(scale == 2.0)
    #expect(width == 2.0)  // 4 / 2
}

@Test func strokeNoTransformUnchanged() {
    let (width, scale) = counterScaledElementStroke(
        strokeWidth: 4.0, transform: nil, elementScale: 1.0)
    #expect(scale == 1.0)
    #expect(width == 4.0)
}

@Test func strokeAccumulatesWithParentScale() {
    // Stroked element with its own 2x, inside a parent already at 3x.
    let (width, scale) = counterScaledElementStroke(
        strokeWidth: 12.0,
        transform: Transform(a: 2, b: 0, c: 0, d: 2, e: 0, f: 0),
        elementScale: 3.0)
    #expect(scale == 6.0)   // 3 * 2
    #expect(width == 2.0)   // 12 / 6
}
