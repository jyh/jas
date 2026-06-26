import Testing
@testable import JasLib

// MARK: - Selection → Properties panel X/Y/W/H (decision-5 Part B.1)
//
// The Properties panel shows the selection's EVALUATED bounding box: each
// element's geometric bbox mapped through its own + ancestor transforms,
// axis-aligned, unioned. Mirrors the Python selection_evaluated_bounds tests.

private func propModel(_ elements: [Element], selected: [ElementPath]) -> Model {
    let layer = Layer(children: elements)
    let selection: Selection = Set(selected.map { ElementSelection.all($0) })
    return Model(document: Document(layers: [layer], selectedLayer: 0,
                                    selection: selection))
}

private func rectT(_ x: Double, _ y: Double, _ w: Double, _ h: Double,
                   _ t: Transform? = nil) -> Element {
    .rect(Rect(x: x, y: y, width: w, height: h, transform: t))
}

@Test func evalBoundsUntransformedRect() {
    let doc = propModel([rectT(10, 20, 30, 40)], selected: [[0, 0]]).document
    let b = selectionEvaluatedBounds(doc)
    #expect(b.x == 10 && b.y == 20 && b.width == 30 && b.height == 40)
}

@Test func evalBoundsScaledRectGrows() {
    let doc = propModel([rectT(10, 20, 30, 40, Transform.scale(2))],
                        selected: [[0, 0]]).document
    let b = selectionEvaluatedBounds(doc)
    #expect(b.x == 20 && b.y == 40 && b.width == 60 && b.height == 80)
}

@Test func evalBoundsTranslatedRectShifts() {
    let doc = propModel([rectT(10, 20, 30, 40, Transform.translate(5, 7))],
                        selected: [[0, 0]]).document
    let b = selectionEvaluatedBounds(doc)
    #expect(b.x == 15 && b.y == 27 && b.width == 30 && b.height == 40)
}

@Test func evalBoundsRotate90SwapsExtents() {
    // 10x20 rect rotated 90deg -> 20x10 bbox.
    let doc = propModel([rectT(0, 0, 10, 20, Transform.rotate(90))],
                        selected: [[0, 0]]).document
    let b = selectionEvaluatedBounds(doc)
    #expect(abs(b.width - 20) < 1e-6)
    #expect(abs(b.height - 10) < 1e-6)
}

@Test func evalBoundsUnionOfTwo() {
    let doc = propModel([rectT(0, 0, 10, 10), rectT(100, 0, 10, 10)],
                        selected: [[0, 0], [0, 1]]).document
    let b = selectionEvaluatedBounds(doc)
    #expect(b.x == 0 && b.y == 0 && b.width == 110 && b.height == 10)
}

@Test func evalBoundsEmptySelectionIsZero() {
    let doc = propModel([rectT(10, 20, 30, 40)], selected: []).document
    let b = selectionEvaluatedBounds(doc)
    #expect(b.x == 0 && b.y == 0 && b.width == 0 && b.height == 0)
}

@Test func propertiesOverridesWriteRoundedBbox() {
    let model = propModel([rectT(10, 20, 30, 40, Transform.scale(2))],
                          selected: [[0, 0]])
    let o = propertiesPanelLiveOverrides(model: model)
    #expect((o["prop_x"] as? Double) == 20)
    #expect((o["prop_y"] as? Double) == 40)
    #expect((o["prop_w"] as? Double) == 60)
    #expect((o["prop_h"] as? Double) == 80)
}

// MARK: - Part B.3: rotation / opacity / blend (first selected element)

@Test func propertiesAttrsFromFirstSelected() {
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10,
                                 opacity: 0.5,
                                 transform: Transform.rotate(90),
                                 blendMode: .multiply))
    let o = propertiesPanelLiveOverrides(model: propModel([rect], selected: [[0, 0]]))
    #expect(abs((o["prop_rotation"] as? Double ?? 0) - 90) < 0.01)
    #expect((o["prop_opacity"] as? Double) == 50)
    #expect((o["prop_blend"] as? String) == "multiply")
}

@Test func propertiesAttrsDefaultNoSelection() {
    let o = propertiesPanelLiveOverrides(model: propModel([rectT(0, 0, 10, 10)],
                                                          selected: []))
    #expect((o["prop_rotation"] as? Double) == 0)
    #expect((o["prop_opacity"] as? Double) == 100)
    #expect((o["prop_blend"] as? String) == "normal")
}
