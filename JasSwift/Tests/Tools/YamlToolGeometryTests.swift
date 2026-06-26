import Testing
import Foundation
@testable import JasLib

// Geometry tool gesture-seam tests — Swift port of the Rust geometry seam
// tests in jas_dioxus/src/tools/yaml_tool.rs. ONE combined file covering all
// five geometry tools: rect, ellipse, rounded_rect, polygon, and star.
//
// Each case loads the PRODUCTION tool from the workspace bundle and drives it
// through on_press / on_move (dragging) / on_release. With an identity view,
// doc coords equal the screen coords passed to the verbs. These tools read NO
// app-level state, so — unlike the blob/selection seam tests — there is no
// app-state seed/bridge call.
//
// Seam mapping from Rust to Swift:
//   on_press        -> onPress(ctx, x:, y:, shift:, alt:)
//   on_move(drag)   -> onMove(ctx, x:, y:, shift:, alt:, dragging:)
//   on_release      -> onRelease(ctx, x:, y:, shift:, alt:)
//
// Committed element types (mirroring the Rust Element variants 1:1):
//   rect / rounded_rect -> .rect(Rect)        (rx/ry > 0 for rounded)
//   ellipse             -> .ellipse(Ellipse)  (cx/cy center, rx/ry half-extent)
//   polygon             -> .polygon(Polygon)  (5 points)
//   star                -> .polygon(Polygon)  (10 points, alternating in/out)

private func geomTool(_ id: String) -> YamlTool? {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let spec = tools[id] as? [String: Any] else {
        return nil
    }
    return YamlTool.fromWorkspaceTool(spec)
}

private func emptyLayerModel() -> Model {
    Model(document: Document(
        layers: [Layer(children: [])],
        selectedLayer: 0, selection: []
    ))
}

private func makeCtx(model: Model) -> ToolContext {
    ToolContext(
        model: model,
        controller: Controller(model: model),
        hitTestSelection: { _ in false },
        hitTestHandle: { _ in nil },
        hitTestText: { _ in nil },
        hitTestPathCurve: { _, _ in nil },
        requestUpdate: {},
        drawElementOverlay: { _, _, _ in }
    )
}

// MARK: - Rect tool

@Test func rectParityDrawRect() throws {
    // press(10,20); drag to(110,70); release(110,70) -> ONE Rect with
    // top-left (10,20), 100x50.
    let tool = try #require(geomTool("rect"))
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onMove(ctx, x: 110, y: 70, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 110, y: 70, shift: false, alt: false)

    let children = model.document.layers[0].children
    #expect(children.count == 1, "draw commits exactly one Rect")
    guard case .rect(let r) = children[0] else {
        Issue.record("expected Rect, got \(children[0])")
        return
    }
    #expect(r.x == 10)
    #expect(r.y == 20)
    #expect(r.width == 100)
    #expect(r.height == 50)
}

@Test func rectParityZeroSizeRectNotCreated() throws {
    // Press and release at the same point — no movement, no rect.
    let tool = try #require(geomTool("rect"))
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)

    #expect(model.document.layers[0].children.isEmpty,
            "a zero-size drag commits no Rect")
}

@Test func rectParityNegativeDragNormalizes() throws {
    // press(100,80); drag back to(10,20). Rect normalizes to (10,20,90,60).
    let tool = try #require(geomTool("rect"))
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 100, y: 80, shift: false, alt: false)
    tool.onMove(ctx, x: 10, y: 20, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)

    let children = model.document.layers[0].children
    #expect(children.count == 1)
    guard case .rect(let r) = children[0] else {
        Issue.record("expected Rect, got \(children[0])")
        return
    }
    #expect(r.x == 10)
    #expect(r.y == 20)
    #expect(r.width == 90)
    #expect(r.height == 60)
}

@Test func rectParityUsesModelDefaults() throws {
    // The committed Rect picks up the model default fill/stroke. Mirrors the
    // Rust rect_parity_uses_model_defaults case: red fill, blue 3pt stroke.
    let tool = try #require(geomTool("rect"))
    let model = emptyLayerModel()
    model.defaultFill = Fill(color: .rgb(r: 1, g: 0, b: 0, a: 1))
    model.defaultStroke = Stroke(color: .rgb(r: 0, g: 0, b: 1, a: 1), width: 3)
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onMove(ctx, x: 110, y: 70, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 110, y: 70, shift: false, alt: false)

    let children = model.document.layers[0].children
    #expect(children.count == 1)
    guard case .rect(let r) = children[0] else {
        Issue.record("expected Rect, got \(children[0])")
        return
    }
    #expect(r.fill == Fill(color: .rgb(r: 1, g: 0, b: 0, a: 1)))
    #expect(r.stroke == Stroke(color: .rgb(r: 0, g: 0, b: 1, a: 1), width: 3))
}

// MARK: - Ellipse tool

@Test func ellipseParityDrawEllipse() throws {
    // press(10,20); drag to(110,70); release: bbox 100x50; ellipse fits with
    // cx=60, cy=45, rx=50, ry=25.
    let tool = try #require(geomTool("ellipse"))
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onMove(ctx, x: 110, y: 70, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 110, y: 70, shift: false, alt: false)

    let children = model.document.layers[0].children
    #expect(children.count == 1)
    guard case .ellipse(let e) = children[0] else {
        Issue.record("expected Ellipse, got \(children[0])")
        return
    }
    #expect(e.cx == 60)
    #expect(e.cy == 45)
    #expect(e.rx == 50)
    #expect(e.ry == 25)
}

@Test func ellipseParityZeroSizeNotCreated() throws {
    let tool = try #require(geomTool("ellipse"))
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)

    #expect(model.document.layers[0].children.isEmpty,
            "a zero-size drag commits no Ellipse")
}

@Test func ellipseParityNegativeDragYieldsPositiveRadii() throws {
    // press(100,80); drag back to(10,20). cx=55, cy=50, rx=45, ry=30.
    let tool = try #require(geomTool("ellipse"))
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 100, y: 80, shift: false, alt: false)
    tool.onMove(ctx, x: 10, y: 20, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)

    let children = model.document.layers[0].children
    #expect(children.count == 1)
    guard case .ellipse(let e) = children[0] else {
        Issue.record("expected Ellipse, got \(children[0])")
        return
    }
    #expect(e.cx == 55)
    #expect(e.cy == 50)
    #expect(e.rx == 45)
    #expect(e.ry == 30)
}

// MARK: - RoundedRect tool

@Test func roundedRectParityDrawWithRadius() throws {
    // press(10,20); drag to(110,70): a Rect 100x50 at (10,20) with rx=ry=10.
    let tool = try #require(geomTool("rounded_rect"))
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onMove(ctx, x: 110, y: 70, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 110, y: 70, shift: false, alt: false)

    let children = model.document.layers[0].children
    #expect(children.count == 1)
    guard case .rect(let r) = children[0] else {
        Issue.record("expected Rect, got \(children[0])")
        return
    }
    #expect(r.x == 10)
    #expect(r.y == 20)
    #expect(r.width == 100)
    #expect(r.height == 50)
    #expect(r.rx == 10)
    #expect(r.ry == 10)
}

@Test func roundedRectParityZeroSizeNotCreated() throws {
    let tool = try #require(geomTool("rounded_rect"))
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)

    #expect(model.document.layers[0].children.isEmpty,
            "a zero-size drag commits no rounded Rect")
}

@Test func roundedRectParityNegativeDragNormalizes() throws {
    // press(100,80); drag back to(10,20). Rect normalizes to (10,20,90,60),
    // rx=10.
    let tool = try #require(geomTool("rounded_rect"))
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 100, y: 80, shift: false, alt: false)
    tool.onMove(ctx, x: 10, y: 20, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)

    let children = model.document.layers[0].children
    #expect(children.count == 1)
    guard case .rect(let r) = children[0] else {
        Issue.record("expected Rect, got \(children[0])")
        return
    }
    #expect(r.x == 10)
    #expect(r.y == 20)
    #expect(r.width == 90)
    #expect(r.height == 60)
    #expect(r.rx == 10)
}

// MARK: - Polygon tool

@Test func polygonParityDrawPolygon() throws {
    // press(50,50); drag to(100,50): a Polygon with 5 points (default sides).
    let tool = try #require(geomTool("polygon"))
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 50, y: 50, shift: false, alt: false)
    tool.onMove(ctx, x: 100, y: 50, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 100, y: 50, shift: false, alt: false)

    let children = model.document.layers[0].children
    #expect(children.count == 1)
    guard case .polygon(let p) = children[0] else {
        Issue.record("expected Polygon, got \(children[0])")
        return
    }
    #expect(p.points.count == 5)
}

@Test func polygonParityShortDragNoPolygon() throws {
    // Sub-threshold drag (press and release at the same point) -> no polygon.
    let tool = try #require(geomTool("polygon"))
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 50, y: 50, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 50, shift: false, alt: false)

    #expect(model.document.layers[0].children.isEmpty,
            "a sub-threshold drag commits no Polygon")
}

// MARK: - Star tool

@Test func starParityDrawStar() throws {
    // press(10,20); drag to(110,120): a Polygon with 10 points (5 outer x 2,
    // alternating inner/outer).
    let tool = try #require(geomTool("star"))
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onMove(ctx, x: 110, y: 120, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 110, y: 120, shift: false, alt: false)

    let children = model.document.layers[0].children
    #expect(children.count == 1)
    guard case .polygon(let p) = children[0] else {
        Issue.record("expected Polygon, got \(children[0])")
        return
    }
    #expect(p.points.count == 10)
}

@Test func starParityZeroSizeNotCreated() throws {
    let tool = try #require(geomTool("star"))
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)

    #expect(model.document.layers[0].children.isEmpty,
            "a zero-size drag commits no Star")
}

@Test func starParityNegativeDragNormalizes() throws {
    // press(100,100); drag back to(0,0). 10 points; first outer point at the
    // top-center of the normalized bounding box: (50, 0).
    let tool = try #require(geomTool("star"))
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 100, y: 100, shift: false, alt: false)
    tool.onMove(ctx, x: 0, y: 0, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 0, y: 0, shift: false, alt: false)

    let children = model.document.layers[0].children
    #expect(children.count == 1)
    guard case .polygon(let p) = children[0] else {
        Issue.record("expected Polygon, got \(children[0])")
        return
    }
    #expect(p.points.count == 10)
    #expect(abs(p.points[0].0 - 50) < 1e-9)
    #expect(abs(p.points[0].1 - 0) < 1e-9)
}
