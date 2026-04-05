import Testing
import AppKit
@testable import JasLib

@Test func defaultToolIsSelection() {
    let tool: Tool = .selection
    #expect(tool == .selection)
}

@Test func toolEnumCases() {
    let tools = Tool.allCases
    #expect(tools.count == 9)
    #expect(tools.contains(.selection))
    #expect(tools.contains(.directSelection))
    #expect(tools.contains(.groupSelection))
    #expect(tools.contains(.pen))
    #expect(tools.contains(.text))
    #expect(tools.contains(.textPath))
    #expect(tools.contains(.line))
    #expect(tools.contains(.rect))
    #expect(tools.contains(.polygon))
}

@Test func contentViewInitializes() {
    let view = ContentView(workspace: WorkspaceState())
    _ = view.body
}

@Test func defaultBoundingBox() {
    let bbox = CanvasBoundingBox()
    #expect(bbox.x == 0 && bbox.y == 0 && bbox.width == 800 && bbox.height == 600)
}

@Test func customBoundingBox() {
    let bbox = CanvasBoundingBox(x: 10, y: 20, width: 1024, height: 768)
    #expect(bbox.x == 10 && bbox.y == 20 && bbox.width == 1024 && bbox.height == 768)
}

// MARK: - CanvasNSView tool tests

@Test func canvasNSViewDefaultTool() {
    let view = CanvasNSView()
    #expect(view.currentTool == .selection)
}

@Test func canvasNSViewSetTool() {
    let view = CanvasNSView()
    view.currentTool = .line
    #expect(view.currentTool == .line)
    view.currentTool = .rect
    #expect(view.currentTool == .rect)
}

@Test func lineToolCreatesLineElement() {
    let model = JasModel()
    let controller = Controller(model: model)
    let view = CanvasNSView()
    view.document = model.document
    view.controller = controller
    view.currentTool = .line
    view.onToolRead = { .line }

    // Simulate drag from (10,20) to (50,60) via internal state
    view.simulateDrag(from: NSPoint(x: 10, y: 20), to: NSPoint(x: 50, y: 60))

    let doc = model.document
    #expect(doc.layers.count == 1)
    if case .line(let line) = doc.layers[0].children[0] {
        #expect(line.x1 == 10)
        #expect(line.y1 == 20)
        #expect(line.x2 == 50)
        #expect(line.y2 == 60)
    } else {
        Issue.record("Expected a line element")
    }
}

@Test func rectToolCreatesRectElement() {
    let model = JasModel()
    let controller = Controller(model: model)
    let view = CanvasNSView()
    view.document = model.document
    view.controller = controller
    view.currentTool = .rect
    view.onToolRead = { .rect }

    // Drag from (50,60) to (10,20) — should normalize
    view.simulateDrag(from: NSPoint(x: 50, y: 60), to: NSPoint(x: 10, y: 20))

    let doc = model.document
    #expect(doc.layers.count == 1)
    if case .rect(let r) = doc.layers[0].children[0] {
        #expect(r.x == 10)
        #expect(r.y == 20)
        #expect(r.width == 40)
        #expect(r.height == 40)
    } else {
        Issue.record("Expected a rect element")
    }
}

@Test func drawingAddsToExistingLayer() {
    let model = JasModel()
    let controller = Controller(model: model)
    let layer = JasLayer(name: "L1", children: [
        .line(JasLine(x1: 0, y1: 0, x2: 1, y2: 1,
                      stroke: JasStroke(color: JasColor(r: 0, g: 0, b: 0))))
    ])
    model.document = JasDocument(layers: [layer])

    let view = CanvasNSView()
    view.document = model.document
    view.controller = controller
    view.currentTool = .line
    view.onToolRead = { .line }

    view.simulateDrag(from: NSPoint(x: 0, y: 0), to: NSPoint(x: 99, y: 99))

    let doc = model.document
    #expect(doc.layers.count == 1)
    #expect(doc.layers[0].children.count == 2)
}

@Test func selectionToolIgnoresMouse() {
    let model = JasModel()
    let controller = Controller(model: model)
    let view = CanvasNSView()
    view.document = model.document
    view.controller = controller
    view.currentTool = .selection
    view.onToolRead = { .selection }

    view.simulateDrag(from: NSPoint(x: 10, y: 10), to: NSPoint(x: 50, y: 50))

    // No elements should have been created
    #expect(model.document.layers[0].children.isEmpty)
}
