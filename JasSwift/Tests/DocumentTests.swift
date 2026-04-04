import Testing
@testable import JasLib

@Test func defaultDocumentTitle() {
    let doc = JasDocument()
    #expect(doc.title == "Untitled")
}

@Test func customDocumentTitle() {
    let doc = JasDocument(title: "My Drawing")
    #expect(doc.title == "My Drawing")
}

@Test func emptyDocument() {
    let doc = JasDocument()
    let b = doc.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 0 && b.height == 0)
}

@Test func singleLayerDocument() {
    let layer = JasLayer(name: "Layer 1", children: [.rect(JasRect(x: 0, y: 0, width: 10, height: 10))])
    let doc = JasDocument(layers: [layer])
    let b = doc.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 10 && b.height == 10)
}

@Test func multipleLayersDocument() {
    let l1 = JasLayer(name: "Background", children: [.rect(JasRect(x: 0, y: 0, width: 10, height: 10))])
    let l2 = JasLayer(name: "Foreground", children: [.circle(JasCircle(cx: 50, cy: 50, r: 5))])
    let doc = JasDocument(layers: [l1, l2])
    let b = doc.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 55 && b.height == 55)
}

@Test func documentLayersAccessible() {
    let l1 = JasLayer(name: "A", children: [])
    let l2 = JasLayer(name: "B", children: [])
    let doc = JasDocument(layers: [l1, l2])
    #expect(doc.layers.count == 2)
    #expect(doc.layers[0].name == "A")
    #expect(doc.layers[1].name == "B")
}

// MARK: - Selection tests

private func makeTestDoc() -> JasDocument {
    let rect = Element.rect(JasRect(x: 0, y: 0, width: 10, height: 10))
    let circle = Element.circle(JasCircle(cx: 50, cy: 50, r: 5))
    let line = Element.line(JasLine(x1: 0, y1: 0, x2: 1, y2: 1))
    let group = Element.group(JasGroup(children: [line]))
    let layer0 = JasLayer(name: "L0", children: [rect, circle, group])
    let layer1 = JasLayer(name: "L1", children: [rect])
    return JasDocument(layers: [layer0, layer1])
}

@Test func defaultSelectionEmpty() {
    let doc = makeTestDoc()
    #expect(doc.selection.isEmpty)
}

@Test func selectionWithPaths() {
    let sel: Selection = [[0, 0], [0, 1]]
    let doc = JasDocument(layers: makeTestDoc().layers, selection: sel)
    #expect(doc.selection.count == 2)
    #expect(doc.selection.contains([0, 0]))
    #expect(doc.selection.contains([0, 1]))
}

@Test func getElementLayer() {
    let doc = makeTestDoc()
    let elem = doc.getElement([0])
    if case .layer(let l) = elem {
        #expect(l.name == "L0")
    } else {
        Issue.record("Expected layer")
    }
}

@Test func getElementChild() {
    let doc = makeTestDoc()
    let elem = doc.getElement([0, 1])
    if case .circle = elem {
        // ok
    } else {
        Issue.record("Expected circle")
    }
}

@Test func getElementNested() {
    let doc = makeTestDoc()
    let elem = doc.getElement([0, 2, 0])
    if case .line = elem {
        // ok
    } else {
        Issue.record("Expected line")
    }
}

@Test func replaceElementChild() {
    let doc = makeTestDoc()
    let newRect = Element.rect(JasRect(x: 5, y: 5, width: 20, height: 20))
    let doc2 = doc.replaceElement([0, 0], with: newRect)
    #expect(doc2.getElement([0, 0]) == newRect)
    // original unchanged
    #expect(doc.getElement([0, 0]) == Element.rect(JasRect(x: 0, y: 0, width: 10, height: 10)))
}

@Test func replaceElementNested() {
    let doc = makeTestDoc()
    let newLine = Element.line(JasLine(x1: 1, y1: 2, x2: 3, y2: 4))
    let doc2 = doc.replaceElement([0, 2, 0], with: newLine)
    #expect(doc2.getElement([0, 2, 0]) == newLine)
}

@Test func replaceElementPreservesOtherChildren() {
    let doc = makeTestDoc()
    let newRect = Element.rect(JasRect(x: 99, y: 99, width: 1, height: 1))
    let doc2 = doc.replaceElement([0, 0], with: newRect)
    if case .circle = doc2.getElement([0, 1]) { } else { Issue.record("Expected circle") }
    if case .group = doc2.getElement([0, 2]) { } else { Issue.record("Expected group") }
}

@Test func replaceElementPreservesOtherLayers() {
    let doc = makeTestDoc()
    let newRect = Element.rect(JasRect(x: 99, y: 99, width: 1, height: 1))
    let doc2 = doc.replaceElement([0, 0], with: newRect)
    #expect(doc2.layers[1] == doc.layers[1])
}

@Test func replaceElementPreservesSelection() {
    let sel: Selection = [[0, 1]]
    let doc = JasDocument(layers: makeTestDoc().layers, selection: sel)
    let doc2 = doc.replaceElement([0, 0], with: .rect(JasRect(x: 1, y: 1, width: 2, height: 2)))
    #expect(doc2.selection == sel)
}

@Test func replaceElementReturnsLayerType() {
    let doc = makeTestDoc()
    let newRect = Element.rect(JasRect(x: 1, y: 1, width: 2, height: 2))
    let doc2 = doc.replaceElement([0, 0], with: newRect)
    // layers[0] should still be a JasLayer (struct type, always true if it compiles)
    #expect(doc2.layers[0].name == "L0")
}
