import Testing
@testable import JasLib

/// Helper: create a Selection from element paths.
private func sel(_ paths: ElementPath...) -> Selection {
    Set(paths.map { ElementSelection(path: $0) })
}

/// Helper: extract the set of paths from a Selection.
private func selPaths(_ selection: Selection) -> Set<ElementPath> {
    Set(selection.map(\.path))
}

@Test func controllerDefaultDocument() {
    let ctrl = Controller()
    #expect(ctrl.document.title == "Untitled")
    #expect(ctrl.document.layers.count == 1)
}

@Test func controllerInitialDocument() {
    let model = JasModel(document: JasDocument(title: "Test"))
    let ctrl = Controller(model: model)
    #expect(ctrl.document.title == "Test")
}

@Test func controllerSetTitle() {
    let ctrl = Controller()
    ctrl.setTitle("New Title")
    #expect(ctrl.document.title == "New Title")
}

@Test func controllerAddLayer() {
    let ctrl = Controller()
    let layer = JasLayer(name: "L1", children: [.rect(JasRect(x: 0, y: 0, width: 10, height: 10))])
    ctrl.addLayer(layer)
    #expect(ctrl.document.layers.count == 2)
    #expect(ctrl.document.layers[1].name == "L1")
}

@Test func controllerRemoveLayer() {
    let l1 = JasLayer(name: "A", children: [])
    let l2 = JasLayer(name: "B", children: [])
    let model = JasModel(document: JasDocument(layers: [l1, l2]))
    let ctrl = Controller(model: model)
    ctrl.removeLayer(at: 0)
    #expect(ctrl.document.layers.count == 1)
    #expect(ctrl.document.layers[0].name == "B")
}

@Test func controllerSetDocument() {
    let ctrl = Controller()
    ctrl.setDocument(JasDocument(title: "Replaced"))
    #expect(ctrl.document.title == "Replaced")
}

@Test func controllerMutationsNotifyModel() {
    let model = JasModel()
    let ctrl = Controller(model: model)
    var received: [String] = []
    model.onDocumentChanged { doc in received.append(doc.title) }
    ctrl.setTitle("Changed")
    #expect(received == ["Changed"])
}

@Test func controllerModelImmutability() {
    let ctrl = Controller()
    let before = ctrl.document
    ctrl.setTitle("New")
    let after = ctrl.document
    #expect(before.title == "Untitled")
    #expect(after.title == "New")
}

// MARK: - Selection controller tests

private func makeSelectionCtrl() -> Controller {
    let rect = Element.rect(JasRect(x: 0, y: 0, width: 10, height: 10))
    let line1 = Element.line(JasLine(x1: 0, y1: 0, x2: 5, y2: 5))
    let line2 = Element.line(JasLine(x1: 1, y1: 1, x2: 2, y2: 2))
    let group = Element.group(JasGroup(children: [line1, line2]))
    let layer = JasLayer(name: "L0", children: [rect, group])
    let doc = JasDocument(layers: [layer])
    return Controller(model: JasModel(document: doc))
}

@Test func controllerSetSelection() {
    let ctrl = makeSelectionCtrl()
    let s = sel([0, 0])
    ctrl.setSelection(s)
    #expect(selPaths(ctrl.document.selection) == [[0, 0]])
}

@Test func controllerSetSelectionClears() {
    let ctrl = makeSelectionCtrl()
    ctrl.setSelection(sel([0, 0]))
    ctrl.setSelection([])
    #expect(ctrl.document.selection.isEmpty)
}

@Test func controllerSelectElementDirectChild() {
    let ctrl = makeSelectionCtrl()
    ctrl.selectElement([0, 0])
    #expect(selPaths(ctrl.document.selection) == [[0, 0]])
}

@Test func controllerSelectElementInGroup() {
    let ctrl = makeSelectionCtrl()
    ctrl.selectElement([0, 1, 0])
    #expect(selPaths(ctrl.document.selection) == [[0, 1, 0], [0, 1, 1]])
}

@Test func controllerSelectElementInGroupOtherChild() {
    let ctrl = makeSelectionCtrl()
    ctrl.selectElement([0, 1, 1])
    #expect(selPaths(ctrl.document.selection) == [[0, 1, 0], [0, 1, 1]])
}

@Test func controllerSelectElementNotifies() {
    let ctrl = makeSelectionCtrl()
    var count = 0
    ctrl.model.onDocumentChanged { _ in count += 1 }
    ctrl.selectElement([0, 0])
    #expect(count == 1)
}

@Test func controllerSelectElementLayerPath() {
    let ctrl = makeSelectionCtrl()
    ctrl.selectElement([0])
    #expect(selPaths(ctrl.document.selection) == [[0]])
}

// MARK: - Marquee selection tests

private func makeMarqueeCtrl() -> Controller {
    let rectFar = Element.rect(JasRect(x: 100, y: 100, width: 10, height: 10))
    let line1 = Element.line(JasLine(x1: 0, y1: 0, x2: 5, y2: 5))
    let line2 = Element.line(JasLine(x1: 1, y1: 1, x2: 2, y2: 2))
    let group = Element.group(JasGroup(children: [line1, line2]))
    let layer = JasLayer(name: "L0", children: [rectFar, group])
    return Controller(model: JasModel(document: JasDocument(layers: [layer])))
}

@Test func selectRectHitsElement() {
    let ctrl = makeMarqueeCtrl()
    ctrl.selectRect(x: 99, y: 99, width: 12, height: 12)
    #expect(selPaths(ctrl.document.selection).contains([0, 0]))
}

@Test func selectRectMissesAll() {
    let ctrl = makeMarqueeCtrl()
    ctrl.selectRect(x: 200, y: 200, width: 10, height: 10)
    #expect(ctrl.document.selection.isEmpty)
}

@Test func selectRectGroupExpansion() {
    let ctrl = makeMarqueeCtrl()
    ctrl.selectRect(x: -1, y: -1, width: 7, height: 7)
    #expect(selPaths(ctrl.document.selection) == [[0, 1, 0], [0, 1, 1]])
}

@Test func selectRectReplacesPrevious() {
    let ctrl = makeMarqueeCtrl()
    ctrl.setSelection(sel([0, 0]))
    ctrl.selectRect(x: 200, y: 200, width: 10, height: 10)
    #expect(ctrl.document.selection.isEmpty)
}

@Test func selectRectMultipleElements() {
    let ctrl = makeMarqueeCtrl()
    ctrl.selectRect(x: -1, y: -1, width: 120, height: 120)
    let paths = selPaths(ctrl.document.selection)
    #expect(paths.contains([0, 0]))
    #expect(paths.contains([0, 1, 0]))
    #expect(paths.contains([0, 1, 1]))
}

// MARK: - Precise geometric hit-testing tests

@Test func selectRectMissesDiagonalLineCorner() {
    let line = Element.line(JasLine(x1: 0, y1: 0, x2: 100, y2: 100))
    let layer = JasLayer(name: "L0", children: [line])
    let ctrl = Controller(model: JasModel(document: JasDocument(layers: [layer])))
    ctrl.selectRect(x: 80, y: 0, width: 20, height: 20)
    #expect(ctrl.document.selection.isEmpty)
}

@Test func selectRectHitsDiagonalLine() {
    let line = Element.line(JasLine(x1: 0, y1: 0, x2: 100, y2: 100))
    let layer = JasLayer(name: "L0", children: [line])
    let ctrl = Controller(model: JasModel(document: JasDocument(layers: [layer])))
    ctrl.selectRect(x: 40, y: 40, width: 20, height: 20)
    #expect(selPaths(ctrl.document.selection).contains([0, 0]))
}

@Test func selectRectStrokeOnlyRectInteriorMisses() {
    let r = Element.rect(JasRect(x: 0, y: 0, width: 100, height: 100))
    let layer = JasLayer(name: "L0", children: [r])
    let ctrl = Controller(model: JasModel(document: JasDocument(layers: [layer])))
    ctrl.selectRect(x: 30, y: 30, width: 10, height: 10)
    #expect(ctrl.document.selection.isEmpty)
}

@Test func selectRectFilledRectInteriorHits() {
    let r = Element.rect(JasRect(x: 0, y: 0, width: 100, height: 100,
                                  fill: JasFill(color: JasColor(r: 1, g: 0, b: 0))))
    let layer = JasLayer(name: "L0", children: [r])
    let ctrl = Controller(model: JasModel(document: JasDocument(layers: [layer])))
    ctrl.selectRect(x: 30, y: 30, width: 10, height: 10)
    #expect(selPaths(ctrl.document.selection).contains([0, 0]))
}

// MARK: - Control point selection tests

@Test func selectControlPoint() {
    let line = Element.line(JasLine(x1: 10, y1: 20, x2: 50, y2: 60))
    let layer = JasLayer(name: "L0", children: [line])
    let ctrl = Controller(model: JasModel(document: JasDocument(layers: [layer])))
    ctrl.selectControlPoint(path: [0, 0], index: 1)
    #expect(ctrl.document.selection.count == 1)
    let es = ctrl.document.selection.first!
    #expect(es.path == [0, 0])
    #expect(es.selected == true)
    #expect(es.controlPoints == [1])
}

@Test func defaultElementSelectionFlags() {
    let ctrl = makeSelectionCtrl()
    ctrl.selectElement([0, 0])
    let es = ctrl.document.selection.first!
    #expect(es.selected == true)
    // Rect has 4 control points
    #expect(es.controlPoints == [0, 1, 2, 3])
}
