import Testing
import Foundation
import CoreGraphics
@testable import JasLib

// Phase 5b of the Swift YAML tool-runtime migration. Covers overlay
// rendering — style parsing, color parsing, and the end-to-end path
// that drawOverlay takes for each shape type.

// MARK: - parseOverlayColor

@Test func parseOverlayColorHex() {
    let c = parseOverlayColor("#ff0000")
    #expect(c != nil)
    if let components = c?.components {
        #expect(abs(components[0] - 1) < 1e-6)
        #expect(abs(components[1] - 0) < 1e-6)
        #expect(abs(components[2] - 0) < 1e-6)
    }
}

@Test func parseOverlayColorRgba() {
    let c = parseOverlayColor("rgba(74,144,217,0.5)")
    #expect(c != nil)
    if let components = c?.components {
        #expect(abs(components[0] - 74.0 / 255) < 1e-3)
        #expect(abs(components[3] - 0.5) < 1e-6)
    }
}

@Test func parseOverlayColorNone() {
    #expect(parseOverlayColor("none") == nil)
}

@Test func parseOverlayColorInvalid() {
    #expect(parseOverlayColor("banana") == nil)
}

// MARK: - Named CSS colors in overlay styles (pencil / paintbrush parity)
//
// The pencil and paintbrush freehand-preview specs style their
// `buffer_polyline` overlay with `stroke: black` — a CSS named color.
// `parseOverlayColor` must resolve it; otherwise the stroke is nil and
// `drawBufferPolylineOverlay` skips the whole preview, so nothing is
// visible mid-drag and the stroke only appears on mouseup. Rust renders
// these because it hands the raw "black" string to the browser canvas
// (`set_stroke_style_str`), which understands named colors; Swift
// converts to a CGColor eagerly and so must resolve the name itself.
// Shape tools use `rgba()` / `#hex`, which always parsed — which is why
// the smoke saw shape previews draw and the pencil preview blank. This
// is a color-parser parity gap, NOT an SH-5 repaint regression (the
// pencil requests a repaint per drag event exactly as the shapes do).

@Test func parseOverlayColorNamedBlack() {
    let c = parseOverlayColor("black")
    #expect(c != nil, "named color 'black' must resolve or the preview draws nothing")
    if let comp = c?.components {
        #expect(abs(comp[0]) < 1e-6)
        #expect(abs(comp[1]) < 1e-6)
        #expect(abs(comp[2]) < 1e-6)
        #expect(abs(comp[3] - 1) < 1e-6)
    }
}

@Test func parseOverlayColorNamedWhite() {
    let c = parseOverlayColor("white")
    #expect(c != nil)
    if let comp = c?.components {
        #expect(abs(comp[0] - 1) < 1e-6)
        #expect(abs(comp[1] - 1) < 1e-6)
        #expect(abs(comp[2] - 1) < 1e-6)
    }
}

@Test func parseOverlayColorNamedIsCaseInsensitive() {
    #expect(parseOverlayColor("Black") != nil)
}

@Test func parseOverlayStyleNamedStrokeResolves() {
    // The exact style string the pencil / paintbrush specs carry.
    let s = parseOverlayStyle("stroke: black; stroke-width: 1;")
    #expect(s.stroke != nil, "named-color stroke must resolve or the preview is blank")
    #expect(s.strokeWidth == 1)
}

// MARK: - parseOverlayStyle

@Test func parseOverlayStyleDashArray() {
    let s = parseOverlayStyle("stroke: #ff0000; stroke-width: 2; stroke-dasharray: 4 4;")
    #expect(s.strokeWidth == 2)
    #expect(s.dash == [4, 4])
    #expect(s.stroke != nil)
}

@Test func parseOverlayStyleFillNone() {
    let s = parseOverlayStyle("stroke: #000; fill: none;")
    #expect(s.fill == nil)
    #expect(s.stroke != nil)
}

@Test func parseOverlayStyleCommaSeparatedDash() {
    let s = parseOverlayStyle("stroke-dasharray: 4, 2, 1, 2;")
    #expect(s.dash == [4, 2, 1, 2])
}

// MARK: - drawOverlay end-to-end smoke tests

private func makeBitmapContext(_ size: Int = 64) -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    return CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: size * 4,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

private func makeCtxFor(_ model: Model) -> ToolContext {
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

@Test func yamlToolDrawOverlayRectWhileDrawingDoesNotCrash() {
    // Rect tool: overlay draws only while mode == drawing.
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let rect = tools["rect"] as? [String: Any],
          let tool = YamlTool.fromWorkspaceTool(rect) else {
        Issue.record("couldn't load rect tool")
        return
    }
    let model = Model(document: Document(
        layers: [Layer(children: [])], selectedLayer: 0, selection: []
    ))
    let ctx = makeCtxFor(model)
    tool.onPress(ctx, x: 10, y: 10, shift: false, alt: false)
    tool.onMove(ctx, x: 30, y: 40, shift: false, alt: false, dragging: true)
    // mode is now "drawing" — overlay will render.
    let bmp = makeBitmapContext()
    tool.drawOverlay(ctx, bmp)
    #expect(tool.toolState("mode") as? String == "drawing")
}

@Test func yamlToolDrawOverlayGuardFalseIsNoop() {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let rect = tools["rect"] as? [String: Any],
          let tool = YamlTool.fromWorkspaceTool(rect) else {
        Issue.record("couldn't load rect tool")
        return
    }
    // Without a mousedown, mode is idle → guard `mode == 'drawing'` false.
    let model = Model()
    let ctx = makeCtxFor(model)
    let bmp = makeBitmapContext()
    // Should not crash.
    tool.drawOverlay(ctx, bmp)
}

/// Count pixels that received any ink (alpha > 0) in a
/// transparent-backed context.
private func inkPixelCount(_ ctx: CGContext, _ size: Int) -> Int {
    guard let data = ctx.data else { return 0 }
    let ptr = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
    var n = 0
    for i in stride(from: 0, to: size * size * 4, by: 4) where ptr[i + 3] > 0 { n += 1 }
    return n
}

private func loadTool(_ id: String) -> YamlTool? {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let spec = tools[id] as? [String: Any] else { return nil }
    return YamlTool.fromWorkspaceTool(spec)
}

@Test func pencilBufferPolylineOverlayDrawsInkMidDrag() throws {
    // End-to-end regression: a pencil drag must render a visible preview
    // polyline BEFORE mouseup. The `stroke: black` named-color gap left
    // this overlay resolving to a nil stroke → zero ink drawn.
    let tool = try #require(loadTool("pencil"))
    let model = Model(document: Document(
        layers: [Layer(children: [])], selectedLayer: 0, selection: []))
    let ctx = makeCtxFor(model)
    let size = 128
    tool.onPress(ctx, x: 10, y: 10, shift: false, alt: false)
    for i in 1...10 {
        tool.onMove(ctx, x: Double(10 + i * 10), y: Double(10 + i * 8),
                    shift: false, alt: false, dragging: true)
    }
    let bmp = makeBitmapContext(size)
    tool.drawOverlay(ctx, bmp)
    #expect(inkPixelCount(bmp, size) > 0,
            "pencil preview polyline must draw ink mid-drag (stroke: black)")
}

@Test func paintbrushBufferPolylineOverlayDrawsInkMidDrag() throws {
    // Same named-color gap affects the paintbrush preview.
    let tool = try #require(loadTool("paintbrush"))
    let model = Model(document: Document(
        layers: [Layer(children: [])], selectedLayer: 0, selection: []))
    let ctx = makeCtxFor(model)
    let size = 128
    tool.onPress(ctx, x: 10, y: 10, shift: false, alt: false)
    for i in 1...10 {
        tool.onMove(ctx, x: Double(10 + i * 10), y: Double(10 + i * 8),
                    shift: false, alt: false, dragging: true)
    }
    let bmp = makeBitmapContext(size)
    tool.drawOverlay(ctx, bmp)
    #expect(inkPixelCount(bmp, size) > 0,
            "paintbrush preview polyline must draw ink mid-drag (stroke: black)")
}

@Test func yamlToolDrawOverlayStarShape() {
    // Star overlay goes through drawStarOverlay → strokePolygonOverlay.
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let starSpec = tools["star"] as? [String: Any],
          let tool = YamlTool.fromWorkspaceTool(starSpec) else {
        Issue.record("couldn't load star tool")
        return
    }
    let model = Model(document: Document(
        layers: [Layer(children: [])], selectedLayer: 0, selection: []
    ))
    let ctx = makeCtxFor(model)
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: false)
    tool.onMove(ctx, x: 50, y: 50, shift: false, alt: false, dragging: true)
    let bmp = makeBitmapContext()
    tool.drawOverlay(ctx, bmp)
}
