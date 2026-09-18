import Foundation
import Testing
@testable import JasLib

// MARK: - Properties panel field EDITING — apply to selection (Part B.2)

private func applyModel(_ elements: [Element], selected: [ElementPath]) -> Model {
    let layer = Layer(children: elements)
    let selection: Selection = selected.map { ElementSelection.all($0) }
    return Model(document: Document(layers: [layer], selectedLayer: 0,
                                    selection: selection))
}

private func rectE(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Element {
    .rect(Rect(x: x, y: y, width: w, height: h))
}

@Test func applyXMovesSelection() {
    let m = applyModel([rectE(10, 20, 30, 40)], selected: [[0, 0]])
    applyPropertiesField(controller: Controller(model: m), field: "x", value: 50.0)
    #expect(selectionEvaluatedBounds(m.document).x == 50)
}

/// AN X EDIT LANDS WHERE IT WAS TYPED ON A **TRANSFORMED** SELECTION.
///
/// ⛔ THIS ARM COULD NOT HAVE BEEN WRITTEN BEFORE 2026-09-18. The wave-2b
/// block recorded the limit in its own words — *"the X oracle holds only on
/// an untransformed selection: X/Y belongs to the S-3 class"* — and the
/// calibrated fixture carries no transform precisely because of it.
/// `applyPropertiesField` computes `v - bbox.x`, a DOCUMENT-space delta off
/// the evaluated bounds, and hands it to `moveSelection`, which was
/// transform-blind: on a rotated rect the element travelled along its own
/// axes and the box did not land on the typed number. S-3 (#188) converts
/// that delta, so the oracle now holds for the whole class and the limit is
/// CLOSED rather than filed.
///
/// MEASURED COST OF THE OLD BEHAVIOUR, by disabling the conversion in the
/// twin: typing 40 landed the box at **31.78**. Rotation is chosen so the
/// linear part is not the identity and `e = f = 0` cannot hide a mistreated
/// translation. Twin: Rust `an_x_edit_lands_on_a_transformed_selection`.
@Test func anXEditLandsOnATransformedSelection() {
    let cases: [(String, Transform)] = [
        ("rotated", Transform.rotate(30)),
        ("scaled", Transform.scale(2, 3)),
        ("rotated and translated", Transform.translate(50, 60).multiply(Transform.rotate(30))),
    ]
    for (name, t) in cases {
        let m = applyModel([.rect(Rect(x: 10, y: 20, width: 30, height: 40, transform: t))],
                           selected: [[0, 0]])
        applyPropertiesField(controller: Controller(model: m), field: "x", value: 40.0)
        let landed = selectionEvaluatedBounds(m.document).x
        #expect(abs(landed - 40) < 1e-9, "\(name): x landed at \(landed), typed 40")
    }
}

@Test func applyWScalesToValue() {
    let m = applyModel([rectE(0, 0, 100, 50)], selected: [[0, 0]])
    applyPropertiesField(controller: Controller(model: m), field: "w", value: 200.0)
    let b = selectionEvaluatedBounds(m.document)
    #expect(abs(b.width - 200) < 1e-6)
    #expect(abs(b.height - 50) < 1e-6)
}

@Test func applyWWithConstrainScalesBoth() {
    let m = applyModel([rectE(0, 0, 100, 50)], selected: [[0, 0]])
    m.stateStore.initPanel("properties_panel_content", defaults: ["prop_constrain": true])
    applyPropertiesField(controller: Controller(model: m), field: "w", value: 200.0)
    let b = selectionEvaluatedBounds(m.document)
    #expect(abs(b.width - 200) < 1e-6)
    #expect(abs(b.height - 100) < 1e-6)  // H follows (×2)
}

@Test func applyRotationSwapsExtents() {
    let m = applyModel([rectE(0, 0, 100, 50)], selected: [[0, 0]])
    applyPropertiesField(controller: Controller(model: m), field: "rotation", value: 90.0)
    let b = selectionEvaluatedBounds(m.document)
    #expect(abs(b.width - 50) < 1e-4)
    #expect(abs(b.height - 100) < 1e-4)
}

@Test func applyOpacityAndBlend() {
    let m = applyModel([rectE(0, 0, 10, 10)], selected: [[0, 0]])
    let c = Controller(model: m)
    applyPropertiesField(controller: c, field: "opacity", value: 40.0)
    applyPropertiesField(controller: c, field: "blend", value: "multiply")
    let e = m.document.getElement([0, 0])
    #expect(e.opacity == 0.4)
    #expect(e.blendMode == .multiply)
}

@Test func applyWMultiSelectionScalesGroup() {
    // Two 100x50 rects at x=0 and x=200 -> union bbox W = 300. Setting W=600
    // scales the GROUP about the bbox top-left by 2 (x only).
    let m = applyModel([rectE(0, 0, 100, 50), rectE(200, 0, 100, 50)],
                       selected: [[0, 0], [0, 1]])
    applyPropertiesField(controller: Controller(model: m), field: "w", value: 600.0)
    let b = selectionEvaluatedBounds(m.document)
    #expect(abs(b.width - 600) < 1e-6)
    #expect(abs(b.x - 0) < 1e-6)       // bbox top-left preserved
    #expect(abs(b.height - 50) < 1e-6) // H unchanged
}

@Test func applyRotationMultiSelectionRotatesGroup() {
    // Two 10x10 rects at x=0 and x=100 -> union (0,0,110,10). A 90deg group
    // rotation about the bbox center swaps the union to 10 x 110.
    let m = applyModel([rectE(0, 0, 10, 10), rectE(100, 0, 10, 10)],
                       selected: [[0, 0], [0, 1]])
    applyPropertiesField(controller: Controller(model: m), field: "rotation", value: 90.0)
    let b = selectionEvaluatedBounds(m.document)
    #expect(abs(b.width - 10) < 1e-4)
    #expect(abs(b.height - 110) < 1e-4)
}

// MARK: - SHEAR-FIELD (single + multi + rotation-keeps-shear)

/// Decompose a 2x3 affine's shear angle back to degrees:
/// atan((a*c + b*d) / (a*d - b*c)).
private func decomposedShearDeg(_ t: Transform) -> Double {
    let det = t.a * t.d - t.b * t.c
    return atan((t.a * t.c + t.b * t.d) / det) * (180 / Double.pi)
}

@Test func applyShearSetsAngle() {
    // T2: rect 100x50 at origin, apply shear 30 -> the resulting element
    // transform decomposes back to a shear of 30deg.
    let m = applyModel([rectE(0, 0, 100, 50)], selected: [[0, 0]])
    applyPropertiesField(controller: Controller(model: m), field: "shear", value: 30.0)
    let t = m.document.getElement([0, 0]).transform ?? .identity
    #expect(abs(decomposedShearDeg(t) - 30) < 1e-4)
}

@Test func applyRotationPreservesShear() {
    // T3: apply shear 30 THEN rotation 45 -> the resulting transform still
    // decomposes to shear 30 AND rotation 45 (the rotation upgrade preserves
    // shear instead of assuming shear-free).
    let m = applyModel([rectE(0, 0, 100, 50)], selected: [[0, 0]])
    let c = Controller(model: m)
    applyPropertiesField(controller: c, field: "shear", value: 30.0)
    applyPropertiesField(controller: c, field: "rotation", value: 45.0)
    let t = m.document.getElement([0, 0]).transform ?? .identity
    #expect(abs(decomposedShearDeg(t) - 30) < 1e-4)
    #expect(abs(atan2(t.b, t.a) * (180 / Double.pi) - 45) < 1e-4)
}

@Test func applyShearMultiSelectionShearsGroup() {
    // T4: two 10x10 rects at x=0 and x=100 -> union (0,0,110,10), center
    // (55,5). A 45deg group shear about the bbox center widens the union to
    // w=120, h=10, x=-5.
    let m = applyModel([rectE(0, 0, 10, 10), rectE(100, 0, 10, 10)],
                       selected: [[0, 0], [0, 1]])
    applyPropertiesField(controller: Controller(model: m), field: "shear", value: 45.0)
    let b = selectionEvaluatedBounds(m.document)
    #expect(abs(b.width - 120) < 1e-4)
    #expect(abs(b.height - 10) < 1e-4)
    #expect(abs(b.x - (-5)) < 1e-4)
}

@Test func applyShearNoSelectionNoCrash() {
    let m = applyModel([rectE(0, 0, 10, 10)], selected: [])
    applyPropertiesField(controller: Controller(model: m), field: "shear", value: 30.0)
    // No selection -> no-op, no crash.
    #expect(m.document.getElement([0, 0]).transform == nil)
}
