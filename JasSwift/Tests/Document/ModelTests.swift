import Testing
@testable import JasLib

@Test func modelDefaultDocument() {
    let model = JasModel()
    #expect(model.filename.hasPrefix("Untitled-"))
    #expect(model.document.layers.count == 1)
}

@Test func modelInitialFilename() {
    let model = JasModel(filename: "Test")
    #expect(model.filename == "Test")
}

@Test func modelSetDocumentNotifies() {
    let model = JasModel()
    var received: [Int] = []
    model.onDocumentChanged { doc in received.append(doc.layers.count) }
    model.document = JasDocument(layers: [])
    #expect(received == [0])
}

@Test func modelMultipleListeners() {
    let model = JasModel()
    var a: [Int] = []
    var b: [Int] = []
    model.onDocumentChanged { doc in a.append(doc.layers.count) }
    model.onDocumentChanged { doc in b.append(doc.layers.count) }
    model.document = JasDocument(layers: [])
    #expect(a == [0])
    #expect(b == [0])
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
    model.document = JasDocument(layers: [])
    let after = model.document
    #expect(before.layers.count == 1)
    #expect(after.layers.count == 0)
}

@Test func modelFilename() {
    let model = JasModel()
    #expect(model.filename.hasPrefix("Untitled-"))
    model.filename = "drawing.jas"
    #expect(model.filename == "drawing.jas")
}

@Test func modelUndoRedo() {
    let model = JasModel()
    #expect(!model.canUndo)
    model.snapshot()
    model.document = JasDocument(layers: [])
    #expect(model.canUndo)
    #expect(!model.canRedo)
    model.undo()
    #expect(model.document.layers.count == 1)
    #expect(model.canRedo)
    model.redo()
    #expect(model.document.layers.count == 0)
}

@Test func modelUndoClearsRedoOnNewEdit() {
    let layer = JasLayer(name: "L1", children: [])
    let model = JasModel()
    model.snapshot()
    model.document = JasDocument(layers: [layer])
    model.snapshot()
    model.document = JasDocument(layers: [layer, layer])
    model.undo()
    #expect(model.document.layers.count == 1)
    #expect(model.canRedo)
    model.snapshot()
    model.document = JasDocument(layers: [])
    #expect(!model.canRedo)
}

@Test func modelUndoEmptyStack() {
    let model = JasModel()
    model.undo()
    #expect(model.document.layers.count == 1)
}

@Test func modelRedoEmptyStack() {
    let model = JasModel()
    model.redo()
    #expect(model.document.layers.count == 1)
}
