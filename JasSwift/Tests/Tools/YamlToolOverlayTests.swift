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
    tool.onMove(ctx, x: 30, y: 40, shift: false, dragging: true)
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
    tool.onMove(ctx, x: 50, y: 50, shift: false, dragging: true)
    let bmp = makeBitmapContext()
    tool.drawOverlay(ctx, bmp)
}
