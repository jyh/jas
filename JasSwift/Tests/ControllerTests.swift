import Testing
@testable import JasLib

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
