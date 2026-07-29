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
        drawElementOverlay: { _, _, _ in }
    )
    return (ctx, m, ctrl)
}

private func layerChildren(_ model: Model) -> [Element] {
    model.document.layers[0].children
}

// MARK: - Line tool tests (YAML-driven per Phase 7.3)

private func lineTool() -> CanvasTool {
    createTools()[.line]!
}

@Test func lineToolDrawLine() {
    let tool = lineTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onMove(ctx, x: 30, y: 40, shift: false, alt: false, dragging: true)
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

@Test func lineToolZeroLengthNotCreated() {
    // YAML uses hypot > 2 to suppress stray clicks, matching native's
    // behavior (native DrawingToolBase also guarded on length).
    let tool = lineTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)
    #expect(layerChildren(model).isEmpty)
}

// MARK: - Rect tool tests

/// Per Phase 7 of SWIFT_TOOL_RUNTIME.md the Rect tool is now
/// YAML-driven. These tests run against createTools() so they
/// exercise the live wiring, matching the Rust rect_parity_* set.

private func rectTool() -> CanvasTool {
    // The registry handles YAML→native fallback; tests just ask for
    // the wired-in tool.
    createTools()[.rect]!
}

@Test func rectToolDrawRect() {
    let tool = rectTool()
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

@Test func rectToolZeroSizeNotCreated() {
    // YAML behavior: a plain click (release at press) is suppressed
    // so no invisible shape is deposited. Prior native behavior
    // was to create a zero-size rect; the YAML policy supersedes.
    let tool = rectTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)
    #expect(layerChildren(model).isEmpty)
}

@Test func rectToolNegativeDragNormalizes() {
    let tool = rectTool()
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

// MARK: - Rounded rect tool tests (YAML-driven per Phase 7.2)

private func roundedRectTool() -> CanvasTool {
    createTools()[.roundedRect]!
}

/// rx/ry default the rounded_rect YAML hardcodes.
private let roundedRectYamlRadius: Double = 10

@Test func roundedRectToolDrawRoundedRect() {
    let tool = roundedRectTool()
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
        #expect(r.rx == roundedRectYamlRadius)
        #expect(r.ry == roundedRectYamlRadius)
    } else {
        Issue.record("Expected Rect element")
    }
}

@Test func roundedRectToolZeroSizeNotCreated() {
    let tool = roundedRectTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)
    #expect(layerChildren(model).isEmpty)
}

@Test func roundedRectToolNegativeDragNormalizes() {
    let tool = roundedRectTool()
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
        #expect(r.rx == roundedRectYamlRadius)
        #expect(r.ry == roundedRectYamlRadius)
    } else {
        Issue.record("Expected Rect element")
    }
}

// MARK: - Star tool tests (YAML-driven per Phase 7.5)

private func starTool() -> CanvasTool {
    createTools()[.star]!
}

/// Default outer-vertex count the star YAML commits on mouseup.
/// Kept local because the constant lives in the YAML spec now.
private let defaultStarPoints = 5

@Test func starToolDrawStar() {
    let tool = starTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 110, y: 120, shift: false, alt: false)
    let children = layerChildren(model)
    #expect(children.count == 1)
    if case .polygon(let p) = children[0] {
        #expect(p.points.count == 2 * defaultStarPoints)
    } else {
        Issue.record("Expected Polygon element")
    }
}

@Test func starToolZeroSizeNotCreated() {
    let tool = starTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)
    #expect(layerChildren(model).isEmpty)
}

@Test func starToolFirstVertexAtTop() {
    let tool = starTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 100, y: 100, shift: false, alt: false)
    if case .polygon(let p) = layerChildren(model)[0] {
        #expect(abs(p.points[0].0 - 50.0) < 1e-9)
        #expect(abs(p.points[0].1 - 0.0) < 1e-9)
    } else {
        Issue.record("Expected Polygon element")
    }
}

@Test func starToolDefaultPointsIsFive() {
    #expect(defaultStarPoints == 5)
}

// MARK: - Polygon tool tests (YAML-driven per Phase 7.4)

private func polygonTool() -> CanvasTool {
    createTools()[.polygon]!
}

@Test func polygonToolDrawPolygon() {
    let tool = polygonTool()
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

// MARK: - Selection tool tests (YAML-driven per Phase 7.6)

private func selectionTool() -> CanvasTool {
    createTools()[.selection]!
}

@Test func selectionToolMarqueeSelect() {
    let tool = selectionTool()
    let rect: Element = .rect(Rect(x: 50, y: 50, width: 20, height: 20,
                                   stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)))
    let layer = Layer(name: "L", children: [rect])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    tool.onPress(ctx, x: 45, y: 45, shift: false, alt: false)
    tool.onMove(ctx, x: 75, y: 75, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 75, y: 75, shift: false, alt: false)
    #expect(!model.document.selection.isEmpty)
}

@Test func selectionToolMarqueeMiss() {
    let tool = selectionTool()
    let rect: Element = .rect(Rect(x: 50, y: 50, width: 20, height: 20,
                                   stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)))
    let layer = Layer(name: "L", children: [rect])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: false)
    tool.onMove(ctx, x: 10, y: 10, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 10, y: 10, shift: false, alt: false)
    #expect(model.document.selection.isEmpty)
}

@Test func selectionToolMoveSelection() {
    let tool = selectionTool()
    let rect: Element = .rect(Rect(x: 50, y: 50, width: 20, height: 20,
                                   stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)))
    let layer = Layer(name: "L", children: [rect])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    // Click on the rect to select it, then drag to move.
    tool.onPress(ctx, x: 60, y: 60, shift: false, alt: false)
    tool.onMove(ctx, x: 70, y: 70, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 70, y: 70, shift: false, alt: false)
    let moved = layerChildren(model)[0]
    if case .rect(let r) = moved {
        #expect(r.x == 60)
        #expect(r.y == 60)
    } else {
        Issue.record("Expected Rect element")
    }
}

// MARK: - Scale tool: doc-space reference reconcile at a non-identity view
//
// Regression guard for the transform-tool doc-space reconcile (branch
// testing-strategy). At a NON-identity view (zoom != 1, view_offset != 0) a
// custom clicked reference point must pivot the committed scale about the
// DOCUMENT point under the cursor, not the raw screen point. The cross-
// language corpora run only at the identity view (where doc == screen), so
// this case is otherwise unguarded. Mirrors COORD_RECONCILE_TESTS.md CR-012.

private func scaleTool() -> CanvasTool {
    createTools()[.scale]!
}

@Test func scaleCustomRefPivotsAboutDocPointAtNonIdentityView() {
    // Rect at document (0,0), 100x100, selected.
    let rect: Element = .rect(Rect(x: 0, y: 0, width: 100, height: 100,
                                   stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)))
    let layer = Layer(name: "L", children: [rect])
    let sel: Selection = [ElementSelection.all([0, 0])]
    let doc = Document(layers: [layer], selection: sel)
    let model = Model(document: doc)

    // Non-identity view: screen = doc * 2 + (10, 20)  =>  doc = (screen - off) / 2.
    model.zoomLevel = 2.0
    model.viewOffsetX = 10.0
    model.viewOffsetY = 20.0
    let (ctx, _, _) = makeCtx(model: model)
    let tool = scaleTool()

    // 1. Plain click at SCREEN (10, 20) -> doc (0, 0): set the custom
    //    reference point to the rect's top-left corner.
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)

    // 2. Drag-scale: press SCREEN (210, 220) -> doc (100, 100); release
    //    SCREEN (410, 420) -> doc (200, 200). With pivot (0,0) that is
    //    sx = sy = 200 / 100 = 2.0.
    tool.onPress(ctx, x: 210, y: 220, shift: false, alt: false)
    tool.onMove(ctx, x: 410, y: 420, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 410, y: 420, shift: false, alt: false)

    // The committed scale is carried in the element transform (rect x/y/w/h
    // stay local). Verify the PIVOT is document (0,0): the reference point is
    // the fixed point of the scale, and the opposite corner (100,100) doubles
    // to (200,200). Pre-fix the click stored the SCREEN point (10,20) into the
    // doc-space reference field, so the pivot landed at doc (10,20) and
    // applyPoint(0,0) would be (-10,-20) — which these assertions reject.
    let t = layerChildren(model)[0].transform ?? .identity
    let pivot = t.applyPoint(0, 0)
    let corner = t.applyPoint(100, 100)
    #expect(abs(pivot.0 - 0.0) < 1e-6 && abs(pivot.1 - 0.0) < 1e-6,
            "reference point should be the fixed point at doc (0,0); got \(pivot)")
    #expect(abs(corner.0 - 200.0) < 1e-6 && abs(corner.1 - 200.0) < 1e-6,
            "opposite corner should double to (200,200); got \(corner)")
}

// Regression: Type-on-Path must convert screen -> doc in its pointer
// handlers (like TypeTool / the Rust reference). Pre-fix it fed raw widget
// coords into path geometry, so a drag-created path landed at screen coords
// and drifted under zoom/pan. Guarded only here — corpora run at identity.
@Test func typeOnPathDragCreateConvertsScreenToDocAtNonIdentityView() {
    let doc = Document(layers: [Layer(name: "L", children: [])])
    let model = Model(document: doc)
    // screen = doc * 2 + (10, 20)  =>  doc = (screen - off) / 2.
    model.zoomLevel = 2.0
    model.viewOffsetX = 10.0
    model.viewOffsetY = 20.0
    let (ctx, _, _) = makeCtx(model: model)
    let tool = TypeOnPathTool()

    // Drag SCREEN (110,120) -> (410,120): doc (50,50) -> (200,50), well past
    // the drag threshold, so a new TextPath is created spanning those coords.
    tool.onPress(ctx, x: 110, y: 120, shift: false, alt: false)
    tool.onMove(ctx, x: 410, y: 120, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 410, y: 120, shift: false, alt: false)

    let children = layerChildren(model)
    #expect(children.count == 1, "drag-create should add one TextPath")
    guard case .textPath(let tp) = children[0] else {
        Issue.record("expected a TextPath; got \(children.first as Any)")
        return
    }
    guard case .moveTo(let mx, let my) = tp.d.first else {
        Issue.record("expected d to start with moveTo; got \(tp.d)")
        return
    }
    #expect(abs(mx - 50.0) < 1e-6 && abs(my - 50.0) < 1e-6,
            "path start should be doc (50,50), not raw screen; got (\(mx),\(my))")
    // Last command's endpoint (line or curve) should be doc (200,50).
    let end: (Double, Double)?
    switch tp.d.last {
    case .lineTo(let x, let y): end = (x, y)
    case .curveTo(_, _, _, _, let x, let y): end = (x, y)
    default: end = nil
    }
    #expect(end != nil && abs(end!.0 - 200.0) < 1e-6 && abs(end!.1 - 50.0) < 1e-6,
            "path end should be doc (200,50), not raw screen; got \(end as Any)")
}

// MARK: - Add Anchor Point tool tests (YAML-driven per Phase 7.11-13)
//
// Drag-adjusts-handles, cusp-drag, and Space+drag reposition from the
// native tool are dropped per the YAML MVP scope — insertion of an
// anchor on a segment is all that remains. The Anchor Point tool
// covers corner/smooth toggling for previously-placed anchors.

private func addAnchorPointTool() -> CanvasTool {
    createTools()[.addAnchorPoint]!
}

private let aapCurvePathElem: Element = .path(Path(
    d: [.moveTo(0, 0), .curveTo(x1: 33, y1: 0, x2: 67, y2: 0, x: 100, y: 0)],
    stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)
, fillRule: .nonzero))

@Test func addAnchorPointClickOnPathAddsPoint() {
    let tool = addAnchorPointTool()
    let layer = Layer(name: "L", children: [aapCurvePathElem])
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
    let tool = addAnchorPointTool()
    let layer = Layer(name: "L", children: [aapCurvePathElem])
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
    let tool = addAnchorPointTool()
    let layer = Layer(name: "L", children: [aapCurvePathElem])
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

@Test func addAnchorPointInsertPreservesSelection() {
    let tool = addAnchorPointTool()
    let layer = Layer(name: "L", children: [aapCurvePathElem])
    let sel: Selection = [ElementSelection.all([0, 0])]
    let doc = Document(layers: [layer], selection: sel)
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    tool.onPress(ctx, x: 50, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 0, shift: false, alt: false)
    if case .path(let p) = layerChildren(model)[0] {
        #expect(p.d.count == 3)
    } else {
        Issue.record("Expected Path element")
    }
    let es = model.document.getElementSelection([0, 0])
    #expect(es != nil)
    #expect(es!.kind == .all)
}

@Test func addAnchorPointSplitLineSegment() {
    let tool = addAnchorPointTool()
    let pathElem: Element = .path(Path(
        d: [.moveTo(0, 0), .lineTo(100, 0)],
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)
    , fillRule: .nonzero))
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

// MARK: - Pencil tool tests (YAML-driven per Phase 7.9)

private func pencilTool() -> CanvasTool {
    createTools()[.pencil]!
}

@Test func pencilToolFreehandDrawCreatesPath() {
    let tool = pencilTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: false)
    for i in 1...20 {
        let x = Double(i) * 5.0
        let y = sin(Double(i) * 0.1) * 20.0
        tool.onMove(ctx, x: x, y: y, shift: false, alt: false, dragging: true)
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
    // fit_curve on a 2-point identical-coordinate buffer still emits
    // one degenerate curveTo; the path exists but is zero-length.
    // Matches native behavior.
    let tool = pencilTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)
    #expect(layerChildren(model).count == 1)
}

@Test func pencilToolPathHasStroke() {
    let tool = pencilTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: false)
    tool.onMove(ctx, x: 50, y: 50, shift: false, alt: false, dragging: true)
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
    let tool = pencilTool()
    let (ctx, model, _) = makeCtx()
    tool.onRelease(ctx, x: 50, y: 60, shift: false, alt: false)
    #expect(layerChildren(model).isEmpty)
}

@Test func pencilToolMoveWithoutPressIsNoop() {
    let tool = pencilTool()
    let (ctx, model, _) = makeCtx()
    tool.onMove(ctx, x: 50, y: 60, shift: false, alt: false, dragging: true)
    #expect(layerChildren(model).isEmpty)
}

@Test func pencilToolPathStartsAtPressPoint() {
    let tool = pencilTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 15, y: 25, shift: false, alt: false)
    tool.onMove(ctx, x: 50, y: 50, shift: false, alt: false, dragging: true)
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
               stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1), fillRule: .nonzero))
}

private func makeLongPath() -> Element {
    .path(Path(d: [.moveTo(0, 0), .lineTo(50, 0), .lineTo(100, 0), .lineTo(150, 0)],
               stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1), fillRule: .nonzero))
}

private func makeClosedPath() -> Element {
    .path(Path(d: [.moveTo(0, 0), .lineTo(100, 0), .lineTo(100, 100),
                   .lineTo(0, 100), .closePath],
               fill: Fill(color: Color(r: 0, g: 0, b: 0)),
               stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1), fillRule: .nonzero))
}

private func pathEraserTool() -> CanvasTool {
    createTools()[.pathEraser]!
}

@Test func pathEraserDeletesSmallPath() {
    let tool = pathEraserTool()
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
    let tool = pathEraserTool()
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
    let tool = pathEraserTool()
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
    let tool = pathEraserTool()
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
    let tool = pathEraserTool()
    let path = makeLongPath()
    let layer = Layer(name: "L", children: [path])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    tool.onRelease(ctx, x: 75, y: 0, shift: false, alt: false)
    #expect(layerChildren(model).count == 1)
}

@Test func pathEraserMoveWithoutPressIsNoop() {
    let tool = pathEraserTool()
    let path = makeLongPath()
    let layer = Layer(name: "L", children: [path])
    let doc = Document(layers: [layer])
    let model = Model(document: doc)
    let (ctx, _, _) = makeCtx(model: model)
    tool.onMove(ctx, x: 75, y: 0, shift: false, alt: false, dragging: true)
    #expect(layerChildren(model).count == 1)
}

@Test func pathEraserStateTransitions() {
    let tool = pathEraserTool()
    let (ctx, _, _) = makeCtx()
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 0, y: 0, shift: false, alt: false)
}

@Test func pathEraserLockedPathNotErased() {
    let tool = pathEraserTool()
    let small: Element = .path(Path(
        d: [.moveTo(0, 0), .lineTo(1, 1)],
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1),
        locked: true
    , fillRule: .nonzero))
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
    let tool = pathEraserTool()
    let path: Element = .path(Path(
        d: [.moveTo(0, 0), .lineTo(100, 0), .lineTo(200, 0)],
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)
    , fillRule: .nonzero))
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
    let tool = pathEraserTool()
    let path: Element = .path(Path(
        d: [.moveTo(0, 0), .curveTo(x1: 50, y1: -100, x2: 150, y2: -100, x: 200, y: 0)],
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 1)
    , fillRule: .nonzero))
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

// MARK: - Type tool tests

@Test func typeToolDragCreatesAreaText() {
    let tool = TypeTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onMove(ctx, x: 60, y: 70, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 110, y: 80, shift: false, alt: false)
    let children = layerChildren(model)
    #expect(children.count == 1)
    if case .text(let t) = children[0] {
        #expect(abs(t.x - 10.0) < 0.01)
        #expect(abs(t.y - 20.0) < 0.01)
        #expect(t.width > 0.0)
        #expect(t.height > 0.0)
    } else {
        Issue.record("expected text element")
    }
}

@Test func typeToolClickCreatesPointText() {
    let tool = TypeTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 50, y: 60, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 60, shift: false, alt: false)
    let children = layerChildren(model)
    #expect(children.count == 1)
    if case .text(let t) = children[0] {
        #expect(abs(t.x - 50.0) < 0.01)
        #expect(abs(t.y - 60.0) < 0.01)
    } else {
        Issue.record("expected text element")
    }
}

@Test func typeToolTinyDragTreatedAsClick() {
    let tool = TypeTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 5, y: 5, shift: false, alt: false)
    tool.onRelease(ctx, x: 6, y: 6, shift: false, alt: false)
    let children = layerChildren(model)
    #expect(children.count == 1)
}

@Test func typeToolMoveWithoutPressIsNoop() {
    let tool = TypeTool()
    let (ctx, model, _) = makeCtx()
    tool.onMove(ctx, x: 100, y: 100, shift: false, alt: false, dragging: false)
    let children = layerChildren(model)
    #expect(children.isEmpty)
}

// MARK: - Type-on-path tool tests

@Test func typeOnPathToolNewIsIdle() {
    let tool = TypeOnPathTool()
    #expect(tool.dragStart == nil)
    #expect(tool.controlPt == nil)
    #expect(tool.offsetDragging == false)
}

@Test func typeOnPathToolPressStartsDragCreate() {
    let tool = TypeOnPathTool()
    let (ctx, _, _) = makeCtx()
    tool.onPress(ctx, x: 12, y: 34, shift: false, alt: false)
    #expect(tool.dragStart?.0 == 12 && tool.dragStart?.1 == 34)
    #expect(tool.dragEnd?.0 == 12 && tool.dragEnd?.1 == 34)
    // No control point yet — only set once dist > dragThreshold.
    #expect(tool.controlPt == nil)
}

@Test func typeOnPathToolMoveAfterPressSetsControlPoint() {
    let tool = TypeOnPathTool()
    let (ctx, _, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onMove(ctx, x: 50, y: 60, shift: false, alt: false, dragging: true)
    #expect(tool.dragEnd?.0 == 50 && tool.dragEnd?.1 == 60)
    // Distance ≈ 56 > dragThreshold, so a control point is set.
    #expect(tool.controlPt != nil)
}

@Test func typeOnPathToolTinyMoveDoesNotSetControlPoint() {
    let tool = TypeOnPathTool()
    let (ctx, _, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onMove(ctx, x: 11, y: 21, shift: false, alt: false, dragging: true)
    #expect(tool.controlPt == nil)
}

@Test func typeOnPathToolMoveWithoutPressIsNoop() {
    let tool = TypeOnPathTool()
    let (ctx, _, _) = makeCtx()
    tool.onMove(ctx, x: 50, y: 60, shift: false, alt: false, dragging: true)
    #expect(tool.dragStart == nil)
    #expect(tool.controlPt == nil)
}

@Test func typeOnPathToolDragCreatesCurvedTextPath() {
    let tool = TypeOnPathTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onMove(ctx, x: 50, y: 60, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 50, y: 60, shift: false, alt: false)
    let children = layerChildren(model)
    #expect(children.count == 1)
    if case .textPath(let tp) = children[0] {
        // New session-based design creates an empty TextPath and enters
        // an editing session immediately (matches Rust/Python/OCaml).
        #expect(tp.content == "")
        #expect(tp.d.count == 2)
        if case .moveTo(let sx, let sy) = tp.d[0] {
            #expect(sx == 10 && sy == 20)
        } else {
            Issue.record("Expected MoveTo")
        }
        if case .curveTo(_, _, _, _, let ex, let ey) = tp.d[1] {
            #expect(ex == 50 && ey == 60)
        } else {
            Issue.record("Expected CurveTo")
        }
    } else {
        Issue.record("Expected TextPath element")
    }
}

@Test func typeOnPathToolPressReleaseWithoutMoveCreatesLineTo() {
    let tool = TypeOnPathTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 60, shift: false, alt: false)
    let children = layerChildren(model)
    #expect(children.count == 1)
    if case .textPath(let tp) = children[0] {
        if case .lineTo = tp.d[1] { } else {
            Issue.record("Expected LineTo")
        }
    } else {
        Issue.record("Expected TextPath element")
    }
}

@Test func typeOnPathToolTinyDragWithoutHitIsNoop() {
    let tool = TypeOnPathTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 11, y: 21, shift: false, alt: false)
    #expect(layerChildren(model).isEmpty)
}

@Test func typeOnPathToolClickOnPathConvertsToTextPath() {
    let tool = TypeOnPathTool()
    let pathElem = Path(
        d: [.moveTo(0, 0), .lineTo(100, 0)],
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0))
    , fillRule: .nonzero)
    let layer = Layer(name: "L", children: [.path(pathElem)])
    let model = Model()
    model.setDocumentForTest(Document(layers: [layer]))
    let ctrl = Controller(model: model)
    let ctx = ToolContext(
        model: model,
        controller: ctrl,
        hitTestSelection: { _ in false },
        hitTestHandle: { _ in nil },
        hitTestText: { _ in nil },
        hitTestPathCurve: { _, _ in ([0, 0], .path(pathElem)) },
        requestUpdate: {},
        drawElementOverlay: { _, _, _ in }
    )
    tool.onPress(ctx, x: 50, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 0, shift: false, alt: false)
    let children = layerChildren(model)
    #expect(children.count == 1)
    if case .textPath = children[0] { } else {
        Issue.record("Expected TextPath element after conversion")
    }
}

@Test func typeOnPathToolPressDoesNotSnapshotUntilCommit() {
    // In the session-based design a press on empty canvas only stages
    // a drag — the document snapshot is taken when the user actually
    // commits a new TextPath on release. Mirrors Rust/OCaml/Python.
    let tool = TypeOnPathTool()
    let (ctx, model, _) = makeCtx()
    #expect(model.canUndo == false)
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    #expect(model.canUndo == false)
    tool.onRelease(ctx, x: 60, y: 80, shift: false, alt: false)
    #expect(model.canUndo == true)
}

// MARK: - Drawing tools use model defaults

@Test func rectToolUsesModelDefaults() {
    let m = Model()
    m.defaultFill = Fill(color: Color(r: 1, g: 0, b: 0))
    m.defaultStroke = Stroke(color: Color(r: 0, g: 0, b: 1), width: 3.0)
    let tool = rectTool()
    let (ctx, _, _) = makeCtx(model: m)
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 110, y: 70, shift: false, alt: false)
    let children = layerChildren(m)
    #expect(children.count == 1)
    if case .rect(let r) = children[0] {
        #expect(r.fill == Fill(color: Color(r: 1, g: 0, b: 0)))
        #expect(r.stroke == Stroke(color: Color(r: 0, g: 0, b: 1), width: 3.0))
    } else {
        Issue.record("Expected Rect element")
    }
}

// MARK: - Type-on-path: LOCK IS IMMUTABLE, AND IT IS INHERITED
//
// transcripts/LAYER_STRUCTURE.md §13 (lock is inherited, not materialized) and
// §15.1 (locked means immutable), both RULED by JYH 2026-07-28.
//
// The Type-on-Path tool is the one place in either active port where a missing
// lock guard costs the ARTIST THEIR ARTWORK rather than merely their
// expectation: a click on an existing Path runs
// `document.replaceElement(path, with: .textPath(tp))` and the Path is GONE.
// There is no later refusal point — reaching the element IS the conversion.
// So these assert the strong form: the document is BYTE-IDENTICAL afterwards,
// through `documentToTestJson`, the same serialization the cross-language
// corpus compares.
//
// THESE ARE PER-PORT GATES AND CANNOT BE SHARED. Both ports' gesture runners
// build the tool by id out of the YAML workspace (Rust
// `recorder::replay::build_gesture_tool` -> `YamlTool::from_workspace_tool`;
// this port's `loadYamlTool`), and Type / Type-on-a-Path are permanent-native
// in every port by ratified policy (NATIVE_BOUNDARY.md). A gesture fixture
// naming `type_on_path` would fatalError, not run. The Rust twin lives in
// jas_dioxus/src/tools/type_on_path_tool.rs `mod tests`.
//
// They bind the PRODUCTION hit test — the free `hitTestPathCurve(in:x:y:)`
// that `CanvasNSView` injects into `ToolContext`. A test supplying its own
// closure (as `makeCtx` does) would prove nothing about what ships.

/// A ToolContext whose `hitTestPathCurve` is the real production walk over
/// `model.document`, not a stub.
private func makeLiveHitCtx(_ model: Model) -> (ToolContext, Controller) {
    let ctrl = Controller(model: model)
    let ctx = ToolContext(
        model: model,
        controller: ctrl,
        hitTestSelection: { _ in false },
        hitTestHandle: { _ in nil },
        hitTestText: { _ in nil },
        hitTestPathCurve: { x, y in hitTestPathCurve(in: model.document, x: x, y: y) },
        requestUpdate: {},
        drawElementOverlay: { _, _, _ in }
    )
    return (ctx, ctrl)
}

/// A horizontal path at y=100 running x 0..200 — the same geometry the Rust
/// twin uses, so a hit at (100, 100) is unambiguous in both ports.
private func hLine(locked: Bool = false) -> Path {
    Path(d: [.moveTo(0, 100), .lineTo(200, 100)],
         stroke: Stroke(color: Color(r: 0, g: 0, b: 0)),
         locked: locked,
         fillRule: .nonzero)
}

/// Press and release at the same point (no drag, so the empty-canvas arm of
/// `onRelease` is a documented no-op) and return the canonical document JSON
/// before and after.
private func clickAndCapture(_ tool: TypeOnPathTool, _ ctx: ToolContext,
                             _ model: Model, _ x: Double, _ y: Double) -> (String, String) {
    let before = documentToTestJson(model.document)
    tool.onPress(ctx, x: x, y: y, shift: false, alt: false)
    tool.onRelease(ctx, x: x, y: y, shift: false, alt: false)
    return (before, documentToTestJson(model.document))
}

@Test func typeOnPathLeavesALockedPathByteIdentical() {
    let model = Model()
    model.setDocumentForTest(
        Document(layers: [Layer(name: "L", children: [.path(hLine(locked: true))])]))
    let (ctx, _) = makeLiveHitCtx(model)
    let tool = TypeOnPathTool()
    let (before, after) = clickAndCapture(tool, ctx, model, 100, 100)
    #expect(before == after, "a locked Path must survive a Type-on-Path click byte-identically")
    #expect(model.canUndo == false, "a refused conversion must not leave an undo step")
}

@Test func typeOnPathLeavesAPathInsideALockedLayerByteIdentical() {
    // §13: the child's OWN flag is false. Only an inherited read sees this.
    let model = Model()
    model.setDocumentForTest(
        Document(layers: [Layer(name: "L", children: [.path(hLine())], locked: true)]))
    let (ctx, _) = makeLiveHitCtx(model)
    let tool = TypeOnPathTool()
    let (before, after) = clickAndCapture(tool, ctx, model, 100, 100)
    #expect(before == after, "a Path inside a locked LAYER must survive byte-identically")
    #expect(model.canUndo == false, "a refused conversion must not leave an undo step")
}

@Test func typeOnPathLeavesAPathInsideALockedGroupByteIdentical() {
    // This port searches one level deeper than Rust (the UNRULED depth
    // divergence, seat/fleet/SCOPE-lock-immutable.md §8 Q3). While it does,
    // the guard has to cover that depth too.
    let model = Model()
    model.setDocumentForTest(Document(layers: [
        Layer(name: "L", children: [.group(Group(children: [.path(hLine())], locked: true))])
    ]))
    let (ctx, _) = makeLiveHitCtx(model)
    let tool = TypeOnPathTool()
    let (before, after) = clickAndCapture(tool, ctx, model, 100, 100)
    #expect(before == after, "a Path inside a locked GROUP must survive byte-identically")
    #expect(model.canUndo == false)
}

@Test func typeOnPathLeavesALockedGrandchildPathByteIdentical() {
    // The grandchild's OWN flag, under an UNLOCKED group — the read the
    // group-level guard does not already imply.
    let model = Model()
    model.setDocumentForTest(Document(layers: [
        Layer(name: "L", children: [.group(Group(children: [.path(hLine(locked: true))]))])
    ]))
    let (ctx, _) = makeLiveHitCtx(model)
    let tool = TypeOnPathTool()
    let (before, after) = clickAndCapture(tool, ctx, model, 100, 100)
    #expect(before == after, "a locked Path inside an unlocked Group must survive byte-identically")
    #expect(model.canUndo == false)
}

@Test func typeOnPathDoesNotOpenASessionOnALockedTextPath() {
    // Byte-identity alone would pass here — opening a session does not write
    // immediately. The session IS the mutation waiting to happen.
    let model = Model()
    let tp = TextPath(d: [.moveTo(0, 100), .lineTo(200, 100)], content: "abc",
                      startOffset: 0, fontSize: 16.0, locked: true)
    model.setDocumentForTest(Document(layers: [Layer(name: "L", children: [.textPath(tp)])]))
    let (ctx, _) = makeLiveHitCtx(model)
    let tool = TypeOnPathTool()
    _ = clickAndCapture(tool, ctx, model, 50, 100)
    #expect(model.currentEditSession == nil, "typing into a locked TextPath would mutate it")
}

@Test func typeOnPathDoesNotOpenASessionOnATextPathInALockedLayer() {
    let model = Model()
    let tp = TextPath(d: [.moveTo(0, 100), .lineTo(200, 100)], content: "abc",
                      startOffset: 0, fontSize: 16.0)
    model.setDocumentForTest(
        Document(layers: [Layer(name: "L", children: [.textPath(tp)], locked: true)]))
    let (ctx, _) = makeLiveHitCtx(model)
    let tool = TypeOnPathTool()
    _ = clickAndCapture(tool, ctx, model, 50, 100)
    #expect(model.currentEditSession == nil,
            "typing into a TextPath in a locked layer would mutate it")
}

/// THE DISCRIMINATOR. Without it every assertion above is satisfied by a tool
/// that refuses everything — including the artist's unlocked artwork.
@Test func typeOnPathStillConvertsAnUnlockedPath() {
    let model = Model()
    model.setDocumentForTest(Document(layers: [Layer(name: "L", children: [.path(hLine())])]))
    let (ctx, _) = makeLiveHitCtx(model)
    let tool = TypeOnPathTool()
    let (before, after) = clickAndCapture(tool, ctx, model, 100, 100)
    #expect(before != after, "an UNLOCKED path must still convert")
    #expect(model.currentEditSession != nil)
}

// MARK: - Type-on-path SEARCH DEPTH — PROBES OF UNRULED BEHAVIOUR
//
// These two pin what this port does TODAY. They are NOT a ruling, and nothing
// here should be read as one. seat/fleet/SCOPE-lock-immutable.md §8 Q3 asks
// which depth is canonical, and the question is open. Their job is to make a
// ruling VISIBLE: whichever way it lands, one of them turns red and says the
// behaviour changed out loud, instead of a silent drift.
//
// Measured, both ports, at the time of writing:
//   Rust  hit_test_path_curve   layer children only        (2-deep)
//   Swift hitTestPathCurve      one level into Groups      (3-deep, exactly)
// The Rust twin carries the mirror-image probe.

/// This port's 3-deep search DOES reach a path inside one Group.
/// The Rust twin asserts the opposite for the same document. UNRULED.
@Test func probeTypeOnPathReachesAPathOneGroupDeep_UNRULED() {
    let model = Model()
    model.setDocumentForTest(Document(layers: [
        Layer(name: "L", children: [.group(Group(children: [.path(hLine())]))])
    ]))
    let (ctx, _) = makeLiveHitCtx(model)
    let tool = TypeOnPathTool()
    let (before, after) = clickAndCapture(tool, ctx, model, 100, 100)
    #expect(before != after, "an UNLOCKED grouped path converts at this port's depth")
}

/// …and STOPS there. This port's walk is not a recursion — it is the child
/// loop with one hand-unrolled level, so a path two Groups deep is unreachable
/// here too. That is the finding worth a ruling: this port's depth is not the
/// house's `hit_test` (2-deep) NOR its `hit_test_deep` (unbounded), but a third
/// number that no rule names. Both this port's own Type tool
/// (`TypeTool.hitTestText`) and Rust's recurse without limit.
@Test func probeTypeOnPathDoesNotReachAPathTwoGroupsDeep_UNRULED() {
    let model = Model()
    model.setDocumentForTest(Document(layers: [
        Layer(name: "L", children: [
            .group(Group(children: [.group(Group(children: [.path(hLine())]))]))
        ])
    ]))
    let (ctx, _) = makeLiveHitCtx(model)
    let tool = TypeOnPathTool()
    let (before, after) = clickAndCapture(tool, ctx, model, 100, 100)
    #expect(before == after, "the walk stops at one Group — hand-unrolled, not recursive")
}
