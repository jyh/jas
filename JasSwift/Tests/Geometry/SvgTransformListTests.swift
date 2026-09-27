import Testing
@testable import JasLib

// SVG transform lists (SVG 1.1 §7.6): a `transform` attribute is a LIST of
// functions applied right to left, and `rotate` takes an optional centre.
// Each arm maps a point through the imported transform and compares it with
// the point SVG itself puts there. Twin of Rust's `svg.rs`
// `transform_list_tests`, on the same inputs.

private let pxToPtForTests = 72.0 / 96.0

/// The rect's imported transform; `.some(nil)` when it imported none.
private func transformOf(_ t: String) -> Transform?? {
    let d = svgToDocument(##"<?xml version="1.0" encoding="UTF-8"?><svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><g><rect x="0" y="0" width="1" height="1" fill="#000000" transform=""## + t + ##""/></g></svg>"##)
    func find(_ e: Element) -> Transform?? {
        switch e {
        case .rect(let r): return .some(r.transform)
        case .group(let g): return g.children.lazy.compactMap(find).first
        case .layer(let l): return l.children.lazy.compactMap(find).first
        default: return nil
        }
    }
    return d.layers.lazy.compactMap { find(.layer($0)) }.first
}

/// `t` sends the file point (x, y) to the file point (ex, ey). Compared in
/// pt, the model's space (these files have no viewBox, so a unit is a px).
private func expectMaps(_ t: String, _ p: (Double, Double), _ e: (Double, Double)) {
    guard let found = transformOf(t) else { Issue.record("no rect for `\(t)`"); return }
    guard let m = found else { Issue.record("`\(t)` imported as no transform"); return }
    let k = pxToPtForTests
    let (gx, gy) = m.applyPoint(p.0 * k, p.1 * k)
    #expect(abs(gx - e.0 * k) < 1e-9 && abs(gy - e.1 * k) < 1e-9,
            "`\(t)`: \(p) -> (\(gx / k), \(gy / k)), SVG puts it at \(e)")
}

@Test func svgTransformRotateAboutACentre() {
    // +90 deg with y down turns (+5, 0) from the centre into (0, +5).
    expectMaps("rotate(90 10 0)", (15, 0), (10, 5))
    expectMaps("rotate(-90 -37 164)", (-37, 154), (-47, 164))
}

@Test func svgTransformAListAppliesRightToLeft() {
    expectMaps("translate(10,0) rotate(90)", (1, 0), (10, 1))
    expectMaps("scale(2) translate(5,0)", (0, 0), (10, 0))
    expectMaps("translate(10 0), scale(2)", (1, 1), (12, 2))
}

@Test func svgTransformSkewsAreRead() {
    expectMaps("skewX(45)", (0, 1), (1, 1))
    expectMaps("skewY(45)", (1, 0), (1, 1))
}

@Test func svgTransformSingleFunctionsStillRead() {
    expectMaps("translate(3,4)", (0, 0), (3, 4))
    expectMaps("translate(3)", (0, 0), (3, 0))
    expectMaps("rotate(90)", (1, 0), (0, 1))
    expectMaps("scale(2,3)", (1, 1), (2, 3))
    expectMaps("matrix(1,0,0,1,7,8)", (0, 0), (7, 8))
}

@Test func svgTransformAMalformedListImportsNoTransform() {
    #expect(transformOf("rotate(abc)") == .some(nil))
    #expect(transformOf("translate(1,0) wobble(3)") == .some(nil))
}
