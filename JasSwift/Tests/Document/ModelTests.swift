import Testing
@testable import JasLib

@Test func modelDefaultDocument() {
    let model = Model()
    #expect(model.filename.hasPrefix("Untitled-"))
    #expect(model.document.layers.count == 1)
}

@Test func modelInitialFilename() {
    let model = Model(filename: "Test")
    #expect(model.filename == "Test")
}

@Test func modelSetDocumentNotifies() {
    let model = Model()
    var received: [Int] = []
    model.onDocumentChanged { doc in received.append(doc.layers.count) }
    model.document = Document(layers: [])
    #expect(received == [0])
}

@Test func modelMultipleListeners() {
    let model = Model()
    var a: [Int] = []
    var b: [Int] = []
    model.onDocumentChanged { doc in a.append(doc.layers.count) }
    model.onDocumentChanged { doc in b.append(doc.layers.count) }
    model.document = Document(layers: [])
    #expect(a == [0])
    #expect(b == [0])
}

@Test func modelListenerCalledOnEachChange() {
    let model = Model()
    var counts: [Int] = []
    model.onDocumentChanged { doc in counts.append(doc.layers.count) }
    let layer = Layer(name: "L1", children: [])
    model.document = Document(layers: [layer])
    model.document = Document(layers: [layer, layer])
    #expect(counts == [1, 2])
}

@Test func modelImmutability() {
    let model = Model()
    let before = model.document
    model.document = Document(layers: [])
    let after = model.document
    #expect(before.layers.count == 1)
    #expect(after.layers.count == 0)
}

@Test func modelFilename() {
    let model = Model()
    #expect(model.filename.hasPrefix("Untitled-"))
    model.filename = "drawing.jas"
    #expect(model.filename == "drawing.jas")
}

@Test func modelUndoRedo() {
    let model = Model()
    #expect(!model.canUndo)
    model.snapshot()
    model.document = Document(layers: [])
    #expect(model.canUndo)
    #expect(!model.canRedo)
    model.undo()
    #expect(model.document.layers.count == 1)
    #expect(model.canRedo)
    model.redo()
    #expect(model.document.layers.count == 0)
}

@Test func modelUndoClearsRedoOnNewEdit() {
    let layer = Layer(name: "L1", children: [])
    let model = Model()
    model.snapshot()
    model.document = Document(layers: [layer])
    model.snapshot()
    model.document = Document(layers: [layer, layer])
    model.undo()
    #expect(model.document.layers.count == 1)
    #expect(model.canRedo)
    model.snapshot()
    model.document = Document(layers: [])
    #expect(!model.canRedo)
}

@Test func modelUndoEmptyStack() {
    let model = Model()
    model.undo()
    #expect(model.document.layers.count == 1)
}

@Test func modelRedoEmptyStack() {
    let model = Model()
    model.redo()
    #expect(model.document.layers.count == 1)
}
