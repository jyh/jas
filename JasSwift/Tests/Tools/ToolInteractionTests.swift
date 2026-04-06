import Testing
import AppKit
@testable import JasLib

/// Create a ToolContext with a fresh model and controller.
private func makeCtx(model: Model? = nil) -> (ToolContext, Model, Controller) {
    let m = model ?? Model()
    let ctrl = Controller(model: m)
    let ctx = ToolContext(
        model: m,
        controller: ctrl,
        hitTestSelection: { _ in false },
        hitTestHandle: { _ in nil },
        hitTestText: { _ in nil },
        hitTestPathCurve: { _, _ in nil },
        requestUpdate: {},
        startTextEdit: { _, _ in },
        commitTextEdit: {},
        drawElementOverlay: { _, _, _ in }
    )
    return (ctx, m, ctrl)
}

private func layerChildren(_ model: Model) -> [Element] {
    model.document.layers[0].children
}

// MARK: - Line tool tests

@Test func lineToolDrawLine() {
    let tool = LineTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onMove(ctx, x: 30, y: 40, shift: false, dragging: true)
    tool.onRelease(ctx, x: 50, y: 60, shift: false, alt: false)
    let children = layerChildren(model)
    #expect(children.count == 1)
    if case .line(let line) = children[0] {
        #expect(line.x1 == 10)
        #expect(line.y1 == 20)
        #expect(line.x2 == 50)
        #expect(line.y2 == 60)
    } else {
        Issue.record("Expected Line element")
    }
}

@Test func lineToolZeroLengthLineStillCreated() {
    let tool = LineTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)
    let children = layerChildren(model)
    #expect(children.count == 1)
}

// MARK: - Rect tool tests

@Test func rectToolDrawRect() {
    let tool = RectTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 110, y: 70, shift: false, alt: false)
    let children = layerChildren(model)
    #expect(children.count == 1)
    if case .rect(let r) = children[0] {
        #expect(r.x == 10)
        #expect(r.y == 20)
        #expect(r.width == 100)
        #expect(r.height == 50)
    } else {
        Issue.record("Expected Rect element")
    }
}

@Test func rectToolZeroSizeRectStillCreated() {
    let tool = RectTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)
    let children = layerChildren(model)
    #expect(children.count == 1)
    if case .rect(let r) = children[0] {
        #expect(r.width == 0)
        #expect(r.height == 0)
    } else {
        Issue.record("Expected Rect element")
    }
}

@Test func rectToolNegativeDragNormalizes() {
    let tool = RectTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 100, y: 80, shift: false, alt: false)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)
    let children = layerChildren(model)
    #expect(children.count == 1)
    if case .rect(let r) = children[0] {
        #expect(r.x == 10)
        #expect(r.y == 20)
        #expect(r.width == 90)
        #expect(r.height == 60)
    } else {
        Issue.record("Expected Rect element")
    }
}

// MARK: - Polygon tool tests

@Test func polygonToolDrawPolygon() {
    let tool = PolygonTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 50, y: 50, shift: false, alt: false)
    tool.onRelease(ctx, x: 100, y: 50, shift: false, alt: false)
    let children = layerChildren(model)
    #expect(children.count == 1)
    if case .polygon(let p) = children[0] {
        #expect(p.points.count == polygonSides)
    } else {
        Issue.record("Expected Polygon element")
    }
}

// MARK: - Selection tool tests

@Test func selectionToolMarqueeSelect() {
    let tool = SelectionTool()
    let rect: Element = .rect(Rect(x: 50, y: 50, width: 20, height: 20,
                                   stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)))
    let layer = Layer(name: "L", children: [rect])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    tool.onPress(ctx, x: 45, y: 45, shift: false, alt: false)
    tool.onRelease(ctx, x: 75, y: 75, shift: false, alt: false)
    #expect(!model.document.selection.isEmpty)
}

@Test func selectionToolMarqueeMiss() {
    let tool = SelectionTool()
    let rect: Element = .rect(Rect(x: 50, y: 50, width: 20, height: 20,
                                   stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)))
    let layer = Layer(name: "L", children: [rect])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 10, y: 10, shift: false, alt: false)
    #expect(model.document.selection.isEmpty)
}

@Test func selectionToolMoveSelection() {
    let tool = SelectionTool()
    let rect: Element = .rect(Rect(x: 50, y: 50, width: 20, height: 20,
                                   stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)))
    let layer = Layer(name: "L", children: [rect])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let ctrl = Controller(model: model)
    ctrl.selectRect(x: 45, y: 45, width: 30, height: 30, extend: false)
    #expect(!model.document.selection.isEmpty)
    let ctx = ToolContext(
        model: model,
        controller: ctrl,
        hitTestSelection: { _ in true },
        hitTestHandle: { _ in nil },
        hitTestText: { _ in nil },
        hitTestPathCurve: { _, _ in nil },
        requestUpdate: {},
        startTextEdit: { _, _ in },
        commitTextEdit: {},
        drawElementOverlay: { _, _, _ in }
    )
    tool.onPress(ctx, x: 60, y: 60, shift: false, alt: false)
    tool.onMove(ctx, x: 70, y: 70, shift: false, dragging: true)
    tool.onRelease(ctx, x: 70, y: 70, shift: false, alt: false)
    let moved = layerChildren(model)[0]
    if case .rect(let r) = moved {
        #expect(r.x == 60)
        #expect(r.y == 60)
    } else {
        Issue.record("Expected Rect element")
    }
}
