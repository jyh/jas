import Testing
@testable import JasLib

// MARK: - Properties panel field EDITING — apply to selection (Part B.2)

private func applyModel(_ elements: [Element], selected: [ElementPath]) -> Model {
    let layer = Layer(children: elements)
    let selection: Selection = Set(selected.map { ElementSelection.all($0) })
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
