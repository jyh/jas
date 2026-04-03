import Testing
@testable import JasLib

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
