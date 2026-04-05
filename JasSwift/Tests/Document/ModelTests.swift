import Testing
@testable import JasLib

@Test func modelDefaultDocument() {
    let model = JasModel()
    #expect(model.document.title == "Untitled")
    #expect(model.document.layers.count == 1)
}

@Test func modelInitialDocument() {
    let model = JasModel(document: JasDocument(title: "Test"))
    #expect(model.document.title == "Test")
}

@Test func modelSetDocumentNotifies() {
    let model = JasModel()
    var received: [String] = []
    model.onDocumentChanged { doc in received.append(doc.title) }
    model.document = JasDocument(title: "Changed")
    #expect(received == ["Changed"])
}

@Test func modelMultipleListeners() {
    let model = JasModel()
    var a: [String] = []
    var b: [String] = []
    model.onDocumentChanged { doc in a.append(doc.title) }
    model.onDocumentChanged { doc in b.append(doc.title) }
    model.document = JasDocument(title: "X")
    #expect(a == ["X"])
    #expect(b == ["X"])
}

@Test func modelListenerCalledOnEachChange() {
    let model = JasModel()
    var counts: [Int] = []
    model.onDocumentChanged { doc in counts.append(doc.layers.count) }
    let layer = JasLayer(name: "L1", children: [])
    model.document = JasDocument(layers: [layer])
    model.document = JasDocument(layers: [layer, layer])
    #expect(counts == [1, 2])
}

@Test func modelImmutability() {
    let model = JasModel()
    let before = model.document
    model.document = JasDocument(title: "New")
    let after = model.document
    #expect(before.title == "Untitled")
    #expect(after.title == "New")
}

@Test func modelUndoRedo() {
    let model = JasModel()
    #expect(!model.canUndo)
    model.snapshot()
    model.document = JasDocument(title: "A")
    #expect(model.canUndo)
    #expect(!model.canRedo)
    model.undo()
    #expect(model.document.title == "Untitled")
    #expect(model.canRedo)
    model.redo()
    #expect(model.document.title == "A")
}

@Test func modelUndoClearsRedoOnNewEdit() {
    let model = JasModel()
    model.snapshot()
    model.document = JasDocument(title: "A")
    model.snapshot()
    model.document = JasDocument(title: "B")
    model.undo()
    #expect(model.document.title == "A")
    #expect(model.canRedo)
    model.snapshot()
    model.document = JasDocument(title: "C")
    #expect(!model.canRedo)
}

@Test func modelUndoEmptyStack() {
    let model = JasModel()
    model.undo()
    #expect(model.document.title == "Untitled")
}

@Test func modelRedoEmptyStack() {
    let model = JasModel()
    model.redo()
    #expect(model.document.title == "Untitled")
}
