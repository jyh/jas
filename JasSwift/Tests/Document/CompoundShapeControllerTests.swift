import Testing
@testable import JasLib

/// Tests for Controller.makeCompoundShape / releaseCompoundShape /
/// expandCompoundShape — mirror jas_dioxus controller_test.rs.

private func rectAt(_ x: Double, _ y: Double) -> Element {
    .rect(Rect(x: x, y: y, width: 10, height: 10))
}

private func modelWithRects(_ rects: [Element], selected: [ElementPath]) -> Model {
    let layer = Layer(children: rects)
    let sel: Selection = Set(selected.map { ElementSelection.all($0) })
    let doc = Document(layers: [layer], selectedLayer: 0, selection: sel)
    return Model(document: doc)
}

private func topChildrenCount(_ model: Model) -> Int {
    model.document.layers[0].children.count
}

@Test func makeCompoundShapeWrapsSelection() {
    let model = modelWithRects([rectAt(0, 0), rectAt(5, 0)],
                               selected: [[0, 0], [0, 1]])
    Controller(model: model).makeCompoundShape()
    #expect(topChildrenCount(model) == 1)
    let child = model.document.layers[0].children[0]
    if case .live = child {
    } else {
        Issue.record("expected live element")
    }
}

@Test func makeCompoundShapeSelectionIsNewCompound() {
    let model = modelWithRects([rectAt(0, 0), rectAt(5, 0)],
                               selected: [[0, 0], [0, 1]])
    Controller(model: model).makeCompoundShape()
    #expect(model.document.selection.count == 1)
}

@Test func makeCompoundShapeLessThanTwoIsNoop() {
    let model = modelWithRects([rectAt(0, 0)], selected: [[0, 0]])
    Controller(model: model).makeCompoundShape()
    #expect(topChildrenCount(model) == 1)
    if case .rect = model.document.layers[0].children[0] {
    } else {
        Issue.record("expected rect, compound was created")
    }
}

@Test func releaseCompoundShapeRestoresOperands() {
    let model = modelWithRects([rectAt(0, 0), rectAt(5, 0)],
                               selected: [[0, 0], [0, 1]])
    let ctrl = Controller(model: model)
    ctrl.makeCompoundShape()
    ctrl.releaseCompoundShape()
    #expect(topChildrenCount(model) == 2)
    #expect(model.document.selection.count == 2)
}

@Test func expandCompoundShapeReplacesWithPolygons() {
    // Two overlapping rects to Union to one polygon.
    let model = modelWithRects([rectAt(0, 0), rectAt(5, 0)],
                               selected: [[0, 0], [0, 1]])
    let ctrl = Controller(model: model)
    ctrl.makeCompoundShape()
    ctrl.expandCompoundShape()
    #expect(topChildrenCount(model) == 1)
    if case .polygon = model.document.layers[0].children[0] {
    } else {
        Issue.record("expected polygon element")
    }
}

// MARK: - Destructive boolean ops

private func twoOverlapping() -> Model {
    modelWithRects([rectAt(0, 0), rectAt(5, 0)], selected: [[0, 0], [0, 1]])
}

@Test func destructiveUnionProducesOnePolygon() {
    let m = twoOverlapping()
    Controller(model: m).applyDestructiveBoolean("union")
    #expect(topChildrenCount(m) == 1)
    if case .polygon = m.document.layers[0].children[0] {
    } else { Issue.record("expected polygon") }
}

@Test func destructiveIntersectionProducesOnePolygon() {
    let m = twoOverlapping()
    Controller(model: m).applyDestructiveBoolean("intersection")
    #expect(topChildrenCount(m) == 1)
}

@Test func destructiveExcludeProducesTwoPolygons() {
    let m = twoOverlapping()
    Controller(model: m).applyDestructiveBoolean("exclude")
    #expect(topChildrenCount(m) == 2)
}

@Test func destructiveSubtractFrontConsumesFront() {
    let m = twoOverlapping()
    Controller(model: m).applyDestructiveBoolean("subtract_front")
    #expect(topChildrenCount(m) == 1)
}

@Test func destructiveSubtractBackConsumesBack() {
    let m = twoOverlapping()
    Controller(model: m).applyDestructiveBoolean("subtract_back")
    #expect(topChildrenCount(m) == 1)
}

@Test func destructiveCropUsesFrontmostAsMask() {
    let m = twoOverlapping()
    Controller(model: m).applyDestructiveBoolean("crop")
    #expect(topChildrenCount(m) == 1)
}

@Test func destructiveUnknownOpIsNoop() {
    let m = twoOverlapping()
    let before = topChildrenCount(m)
    Controller(model: m).applyDestructiveBoolean("nonexistent")
    #expect(topChildrenCount(m) == before)
}
