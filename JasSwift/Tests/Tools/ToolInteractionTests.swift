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

// MARK: - Rounded rect tool tests

@Test func roundedRectToolDrawRoundedRect() {
    let tool = RoundedRectTool()
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
        #expect(r.rx == roundedRectRadius)
        #expect(r.ry == roundedRectRadius)
    } else {
        Issue.record("Expected Rect element")
    }
}

@Test func roundedRectToolZeroSizeNotCreated() {
    let tool = RoundedRectTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)
    let children = layerChildren(model)
    #expect(children.count == 0)
}

@Test func roundedRectToolNegativeDragNormalizes() {
    let tool = RoundedRectTool()
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
        #expect(r.rx == roundedRectRadius)
        #expect(r.ry == roundedRectRadius)
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

// MARK: - Add Anchor Point tool tests

@Test func addAnchorPointClickOnPathAddsPoint() {
    let tool = AddAnchorPointTool()
    let pathElem: Element = .path(Path(
        d: [.moveTo(0, 0), .curveTo(x1: 33, y1: 0, x2: 67, y2: 0, x: 100, y: 0)],
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)
    ))
    let layer = Layer(name: "L", children: [pathElem])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    tool.onPress(ctx, x: 50, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 0, shift: false, alt: false)
    let children = layerChildren(model)
    #expect(children.count == 1)
    if case .path(let p) = children[0] {
        // Original: moveTo + 1 curveTo = 2; after split: moveTo + 2 curveTos = 3
        #expect(p.d.count == 3)
        if case .moveTo = p.d[0] {} else { Issue.record("Expected moveTo") }
        if case .curveTo = p.d[1] {} else { Issue.record("Expected curveTo") }
        if case .curveTo = p.d[2] {} else { Issue.record("Expected curveTo") }
    } else {
        Issue.record("Expected Path element")
    }
}

@Test func addAnchorPointClickAwayDoesNothing() {
    let tool = AddAnchorPointTool()
    let pathElem: Element = .path(Path(
        d: [.moveTo(0, 0), .curveTo(x1: 33, y1: 0, x2: 67, y2: 0, x: 100, y: 0)],
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)
    ))
    let layer = Layer(name: "L", children: [pathElem])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    tool.onPress(ctx, x: 50, y: 100, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 100, shift: false, alt: false)
    if case .path(let p) = layerChildren(model)[0] {
        #expect(p.d.count == 2)
    } else {
        Issue.record("Expected Path element")
    }
}

@Test func addAnchorPointSplitPreservesEndpoints() {
    let tool = AddAnchorPointTool()
    let pathElem: Element = .path(Path(
        d: [.moveTo(0, 0), .curveTo(x1: 33, y1: 0, x2: 67, y2: 0, x: 100, y: 0)],
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)
    ))
    let layer = Layer(name: "L", children: [pathElem])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    tool.onPress(ctx, x: 50, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 0, shift: false, alt: false)
    if case .path(let p) = layerChildren(model)[0] {
        // First CurveTo endpoint near (50, 0)
        if case .curveTo(_, _, _, _, let x, let y) = p.d[1] {
            #expect(abs(x - 50.0) < 1.0)
            #expect(abs(y) < 1.0)
        } else { Issue.record("Expected curveTo") }
        // Second CurveTo endpoint at (100, 0)
        if case .curveTo(_, _, _, _, let x, let y) = p.d[2] {
            #expect(abs(x - 100.0) < 0.01)
            #expect(abs(y) < 0.01)
        } else { Issue.record("Expected curveTo") }
    } else {
        Issue.record("Expected Path element")
    }
}

@Test func addAnchorPointDragAdjustsHandles() {
    let tool = AddAnchorPointTool()
    let pathElem: Element = .path(Path(
        d: [.moveTo(0, 0), .curveTo(x1: 33, y1: 0, x2: 67, y2: 0, x: 100, y: 0)],
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)
    ))
    let layer = Layer(name: "L", children: [pathElem])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    // Press at midpoint to split, then drag upward
    tool.onPress(ctx, x: 50, y: 0, shift: false, alt: false)
    tool.onMove(ctx, x: 50, y: 20, shift: false, dragging: true)
    tool.onRelease(ctx, x: 50, y: 20, shift: false, alt: false)
    if case .path(let p) = layerChildren(model)[0] {
        #expect(p.d.count == 3)
        // Outgoing handle (x1, y1 of second CurveTo) at drag position
        if case .curveTo(let x1, let y1, _, _, _, _) = p.d[2] {
            #expect(abs(x1 - 50.0) < 0.01)
            #expect(abs(y1 - 20.0) < 0.01)
        } else { Issue.record("Expected curveTo") }
        // Incoming handle (x2, y2 of first CurveTo) mirrored
        if case .curveTo(_, _, let x2, let y2, _, _) = p.d[1] {
            #expect(abs(x2 - 50.0) < 0.01)
            #expect(abs(y2 - (-20.0)) < 0.01)
        } else { Issue.record("Expected curveTo") }
    } else {
        Issue.record("Expected Path element")
    }
}

@Test func addAnchorPointCuspDragLeavesIncomingHandle() {
    let tool = AddAnchorPointTool()
    let pathElem: Element = .path(Path(
        d: [.moveTo(0, 0), .curveTo(x1: 33, y1: 0, x2: 67, y2: 0, x: 100, y: 0)],
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)
    ))
    let layer = Layer(name: "L", children: [pathElem])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    // Split the curve at midpoint
    tool.onPress(ctx, x: 50, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 0, shift: false, alt: false)
    if case .path(let p) = layerChildren(model)[0] {
        #expect(p.d.count == 3)
        // Record incoming handle before cusp update
        var inX2 = 0.0, inY2 = 0.0
        if case .curveTo(_, _, let x2, let y2, _, _) = p.d[1] {
            inX2 = x2; inY2 = y2
        }
        // Apply cusp update directly
        var cmds = p.d
        AddAnchorPointTool.updateHandles(&cmds, firstCmdIdx: 1,
                                          anchorX: 50, anchorY: 0,
                                          dragX: 50, dragY: 20, cusp: true)
        // Outgoing handle at drag position
        if case .curveTo(let x1, let y1, _, _, _, _) = cmds[2] {
            #expect(abs(x1 - 50.0) < 0.01)
            #expect(abs(y1 - 20.0) < 0.01)
        } else { Issue.record("Expected curveTo") }
        // Incoming handle unchanged (cusp)
        if case .curveTo(_, _, let x2, let y2, _, _) = cmds[1] {
            #expect(abs(x2 - inX2) < 0.01)
            #expect(abs(y2 - inY2) < 0.01)
        } else { Issue.record("Expected curveTo") }
    } else {
        Issue.record("Expected Path element")
    }
}

@Test func addAnchorPointInsertUpdatesSelectionIndices() {
    let tool = AddAnchorPointTool()
    let pathElem: Element = .path(Path(
        d: [.moveTo(0, 0), .curveTo(x1: 33, y1: 0, x2: 67, y2: 0, x: 100, y: 0)],
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)
    ))
    let layer = Layer(name: "L", children: [pathElem])
    // Select the path with all CPs (indices 0 and 1)
    let sel: Selection = [ElementSelection(path: [0, 0], controlPoints: [0, 1])]
    let doc = Document(layers: [layer], selection: sel)
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    // Insert at midpoint
    tool.onPress(ctx, x: 50, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 0, shift: false, alt: false)
    // Path now has 3 anchors
    if case .path(let p) = layerChildren(model)[0] {
        #expect(p.d.count == 3)
    } else {
        Issue.record("Expected Path element")
    }
    // Selection should have shifted: {0,1} -> {0, 1(new), 2(was 1)}
    let es = model.document.getElementSelection([0, 0])
    #expect(es != nil)
    #expect(es!.controlPoints == [0, 1, 2])
}

@Test func addAnchorPointSpaceRepositionsAnchor() {
    let tool = AddAnchorPointTool()
    let pathElem: Element = .path(Path(
        d: [.moveTo(0, 0), .curveTo(x1: 33, y1: 0, x2: 67, y2: 0, x: 100, y: 0)],
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)
    ))
    let layer = Layer(name: "L", children: [pathElem])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)

    // Insert point at midpoint
    tool.onPress(ctx, x: 50, y: 0, shift: false, alt: false)

    // Simulate Space press (keyCode 49), then drag to reposition
    let spaceKey: UInt16 = 49
    #expect(tool.onKey(ctx, keyCode: spaceKey) == true)
    tool.onMove(ctx, x: 60, y: 10, shift: false, dragging: true)

    // Anchor command endpoint should be at (60, 10)
    if case .path(let p) = layerChildren(model)[0] {
        if case .curveTo(_, _, _, _, let x, let y) = p.d[1] {
            #expect(abs(x - 60.0) < 1.0)
            #expect(abs(y - 10.0) < 1.0)
        } else { Issue.record("Expected CurveTo") }
    } else { Issue.record("Expected Path") }

    // Release Space, drag further — should adjust handles, not reposition
    _ = tool.onKeyUp(ctx, keyCode: spaceKey)
    tool.onMove(ctx, x: 70, y: 20, shift: false, dragging: true)

    // Anchor should still be near (60, 10)
    if case .path(let p) = layerChildren(model)[0] {
        if case .curveTo(_, _, _, _, let x, let y) = p.d[1] {
            #expect(abs(x - 60.0) < 1.0)
            #expect(abs(y - 10.0) < 1.0)
        } else { Issue.record("Expected CurveTo") }
        // Outgoing handle should reflect the drag
        if case .curveTo(let x1, let y1, _, _, _, _) = p.d[2] {
            #expect(abs(x1 - 70.0) < 1.0)
            #expect(abs(y1 - 20.0) < 1.0)
        } else { Issue.record("Expected CurveTo") }
    } else { Issue.record("Expected Path") }

    tool.onRelease(ctx, x: 70, y: 20, shift: false, alt: false)
}

@Test func addAnchorPointSplitLineSegment() {
    let tool = AddAnchorPointTool()
    let pathElem: Element = .path(Path(
        d: [.moveTo(0, 0), .lineTo(100, 0)],
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)
    ))
    let layer = Layer(name: "L", children: [pathElem])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    tool.onPress(ctx, x: 50, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 0, shift: false, alt: false)
    if case .path(let p) = layerChildren(model)[0] {
        #expect(p.d.count == 3)
        if case .lineTo = p.d[1] {} else { Issue.record("Expected lineTo") }
        if case .lineTo = p.d[2] {} else { Issue.record("Expected lineTo") }
        if case .lineTo(let x, _) = p.d[1] {
            #expect(abs(x - 50.0) < 1.0)
        }
    } else {
        Issue.record("Expected Path element")
    }
}

// MARK: - Pencil tool tests

@Test func pencilToolFreehandDrawCreatesPath() {
    let tool = PencilTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: false)
    for i in 1...20 {
        let x = Double(i) * 5.0
        let y = sin(Double(i) * 0.1) * 20.0
        tool.onMove(ctx, x: x, y: y, shift: false, dragging: true)
    }
    tool.onRelease(ctx, x: 100, y: 0, shift: false, alt: false)
    let children = layerChildren(model)
    #expect(children.count == 1)
    if case .path(let p) = children[0] {
        #expect(p.d.count >= 2)
        if case .moveTo = p.d[0] {} else { Issue.record("First command should be moveTo") }
        for cmd in p.d.dropFirst() {
            if case .curveTo = cmd {} else { Issue.record("Expected curveTo") }
        }
    } else {
        Issue.record("Expected Path element")
    }
}

@Test func pencilToolClickWithoutDragCreatesPath() {
    let tool = PencilTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)
    let children = layerChildren(model)
    #expect(children.count == 1)
}

@Test func pencilToolPathHasStroke() {
    let tool = PencilTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: false)
    tool.onMove(ctx, x: 50, y: 50, shift: false, dragging: true)
    tool.onRelease(ctx, x: 100, y: 0, shift: false, alt: false)
    let children = layerChildren(model)
    if case .path(let p) = children[0] {
        #expect(p.stroke != nil)
        #expect(p.fill == nil)
    } else {
        Issue.record("Expected Path element")
    }
}

@Test func pencilToolReleaseWithoutPressIsNoop() {
    let tool = PencilTool()
    let (ctx, model, _) = makeCtx()
    tool.onRelease(ctx, x: 50, y: 60, shift: false, alt: false)
    let children = layerChildren(model)
    #expect(children.count == 0)
}

@Test func pencilToolMoveWithoutPressIsNoop() {
    let tool = PencilTool()
    let (ctx, model, _) = makeCtx()
    tool.onMove(ctx, x: 50, y: 60, shift: false, dragging: true)
    let children = layerChildren(model)
    #expect(children.count == 0)
}

@Test func pencilToolPathStartsAtPressPoint() {
    let tool = PencilTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 15, y: 25, shift: false, alt: false)
    tool.onMove(ctx, x: 50, y: 50, shift: false, dragging: true)
    tool.onRelease(ctx, x: 100, y: 0, shift: false, alt: false)
    let children = layerChildren(model)
    if case .path(let p) = children[0] {
        if case .moveTo(let x, let y) = p.d[0] {
            #expect(x == 15)
            #expect(y == 25)
        } else {
            Issue.record("First command should be moveTo")
        }
    } else {
        Issue.record("Expected Path element")
    }
}

// MARK: - Path Eraser tool tests

private func makeLinePath(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Element {
    .path(Path(d: [.moveTo(x1, y1), .lineTo(x2, y2)],
               stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)))
}

private func makeLongPath() -> Element {
    .path(Path(d: [.moveTo(0, 0), .lineTo(50, 0), .lineTo(100, 0), .lineTo(150, 0)],
               stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)))
}

private func makeClosedPath() -> Element {
    .path(Path(d: [.moveTo(0, 0), .lineTo(100, 0), .lineTo(100, 100),
                   .lineTo(0, 100), .closePath],
               fill: Fill(color: Color(r: 0, g: 0, b: 0)),
               stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)))
}

@Test func pathEraserDeletesSmallPath() {
    let tool = PathEraserTool()
    let small = makeLinePath(0, 0, 1, 1)
    let layer = Layer(name: "L", children: [small])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    tool.onPress(ctx, x: 0.5, y: 0.5, shift: false, alt: false)
    tool.onRelease(ctx, x: 0.5, y: 0.5, shift: false, alt: false)
    #expect(layerChildren(model).count == 0)
}

@Test func pathEraserSplitsOpenPath() {
    let tool = PathEraserTool()
    let path = makeLongPath()
    let layer = Layer(name: "L", children: [path])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    tool.onPress(ctx, x: 75, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 75, y: 0, shift: false, alt: false)
    #expect(layerChildren(model).count == 2, "open path should split into 2 parts")
}

@Test func pathEraserOpensClosedPath() {
    let tool = PathEraserTool()
    let path = makeClosedPath()
    let layer = Layer(name: "L", children: [path])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    tool.onPress(ctx, x: 50, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 0, shift: false, alt: false)
    let children = layerChildren(model)
    #expect(children.count == 1, "closed path should become one open path")
    if case .path(let p) = children[0] {
        let hasClosed = p.d.contains(where: { if case .closePath = $0 { return true }; return false })
        #expect(!hasClosed, "result should not be closed")
    } else {
        Issue.record("Expected Path element")
    }
}

@Test func pathEraserMissDoesNothing() {
    let tool = PathEraserTool()
    let path = makeLongPath()
    let layer = Layer(name: "L", children: [path])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    tool.onPress(ctx, x: 75, y: 50, shift: false, alt: false)
    tool.onRelease(ctx, x: 75, y: 50, shift: false, alt: false)
    #expect(layerChildren(model).count == 1)
}

@Test func pathEraserReleaseWithoutPressIsNoop() {
    let tool = PathEraserTool()
    let path = makeLongPath()
    let layer = Layer(name: "L", children: [path])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    tool.onRelease(ctx, x: 75, y: 0, shift: false, alt: false)
    #expect(layerChildren(model).count == 1)
}

@Test func pathEraserMoveWithoutPressIsNoop() {
    let tool = PathEraserTool()
    let path = makeLongPath()
    let layer = Layer(name: "L", children: [path])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    tool.onMove(ctx, x: 75, y: 0, shift: false, dragging: true)
    #expect(layerChildren(model).count == 1)
}

@Test func pathEraserStateTransitions() {
    let tool = PathEraserTool()
    let (ctx, _, _) = makeCtx()
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 0, y: 0, shift: false, alt: false)
}

@Test func pathEraserLockedPathNotErased() {
    let tool = PathEraserTool()
    let small: Element = .path(Path(
        d: [.moveTo(0, 0), .lineTo(1, 1)],
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1),
        locked: true
    ))
    let layer = Layer(name: "L", children: [small])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    tool.onPress(ctx, x: 0.5, y: 0.5, shift: false, alt: false)
    tool.onRelease(ctx, x: 0.5, y: 0.5, shift: false, alt: false)
    #expect(layerChildren(model).count == 1, "locked path should not be erased")
}

@Test func pathEraserSplitEndpointsHugEraser() {
    // Horizontal path (0,0)→(100,0)→(200,0).
    // Erase at x=50 with eraserSize=2 => eraser rect x=[48,52].
    let tool = PathEraserTool()
    let path: Element = .path(Path(
        d: [.moveTo(0, 0), .lineTo(100, 0), .lineTo(200, 0)],
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)
    ))
    let layer = Layer(name: "L", children: [path])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    tool.onPress(ctx, x: 50.0, y: 0.0, shift: false, alt: false)
    tool.onRelease(ctx, x: 50.0, y: 0.0, shift: false, alt: false)
    let children = layerChildren(model)
    #expect(children.count == 2, "should split into 2 parts")
    // Part 1 should end near x=48.
    if case .path(let pe) = children[0] {
        let lastCmd = pe.d.last!
        if let end = lastCmd.endpoint {
            #expect(abs(end.0 - 48.0) < 0.5, "part1 end x=\(end.0) should be near 48")
        }
    }
    // Part 2 should start near x=52.
    if case .path(let pe) = children[1] {
        if case .moveTo(let x, _) = pe.d[0] {
            #expect(abs(x - 52.0) < 0.5, "part2 start x=\(x) should be near 52")
        }
    }
}

@Test func pathEraserSplitPreservesCurves() {
    // Cubic curve from (0,0) to (200,0) arching upward.
    let tool = PathEraserTool()
    let path: Element = .path(Path(
        d: [.moveTo(0, 0), .curveTo(x1: 50, y1: -100, x2: 150, y2: -100, x: 200, y: 0)],
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)
    ))
    let layer = Layer(name: "L", children: [path])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    tool.onPress(ctx, x: 100.0, y: -75.0, shift: false, alt: false)
    tool.onRelease(ctx, x: 100.0, y: -75.0, shift: false, alt: false)
    let children = layerChildren(model)
    #expect(children.count == 2, "should split into 2 parts")
    // Part 1 should end with curveTo.
    if case .path(let pe) = children[0] {
        let last = pe.d.last!
        if case .curveTo = last {
            // ok
        } else {
            Issue.record("part1 should end with curveTo, got \(last)")
        }
    }
    // Part 2 should contain curveTo ending at (200, 0).
    if case .path(let pe) = children[1] {
        #expect(pe.d.count >= 2, "part2 should have at least 2 commands")
        if case .curveTo(_, _, _, _, let x, let y) = pe.d[1] {
            #expect(abs(x - 200.0) < 0.01, "curve should end at x=200, got \(x)")
            #expect(abs(y - 0.0) < 0.01, "curve should end at y=0, got \(y)")
        } else {
            Issue.record("part2 should contain curveTo, got \(pe.d[1])")
        }
    }
}
