import Testing
@testable import JasLib

@Test func modelDefaultDocument() {
    let model = JasModel()
    #expect(model.document.title == "Untitled")
    #expect(model.document.layers.isEmpty)
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
