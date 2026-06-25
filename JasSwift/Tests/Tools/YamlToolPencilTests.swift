import Testing
import Foundation
@testable import JasLib

// Pencil-tool behavioral tests — Swift port of the Rust pencil seam tests in
// jas_dioxus/src/tools/yaml_tool.rs (pencil_parity_* family, the
// pencil_yaml_tool() loader + five #[test] fns). These cover the
// externally-observable outcomes of the YAML-driven pencil tool loaded from the
// workspace bundle: a freehand drag samples into one Path whose `d` is a
// MoveTo followed by CurveTos; a press+release at the same point still commits
// a (degenerate) Path; the committed Path carries the model's stroke default
// and no fill; a release with no prior press is a no-op; and the Path's MoveTo
// starts at the press point.
//
// Seam mapping from Rust to Swift:
//   on_press      -> onPress(ctx, x:, y:, shift:, alt:)
//   on_move(drag) -> onMove(ctx, x:, y:, shift:, alt:, dragging:)
//   on_release    -> onRelease(ctx, x:, y:, shift:, alt:)
//
// The committed element is a Path; in Swift the Path-case payload (`pe`) is the
// `Path` struct, with pe.d : [PathCommand], pe.stroke : Stroke?, pe.fill :
// Fill?. Structurally identical to YamlToolPenTests.swift with "pen" -> "pencil".

private func pencilTool() -> YamlTool? {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let spec = tools["pencil"] as? [String: Any] else {
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

// MARK: - Loader sanity

@Test func pencilToolLoadsFromWorkspace() throws {
    let tool = try #require(pencilTool())
    #expect(tool.spec.id == "pencil")
}

// MARK: - Freehand drag -> one Path of MoveTo + CurveTos

@Test func pencilParityFreehandDrawCreatesPath() throws {
    let tool = try #require(pencilTool())
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    // Press at the origin, then drag 20 samples along a sine wave, then
    // release. The drag samples are fit into a smooth Bezier path.
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: false)
    for i in 1...20 {
        let x = Double(i) * 5.0
        let y = sin(Double(i) * 0.1) * 20.0
        tool.onMove(ctx, x: x, y: y, shift: false, alt: false, dragging: true)
    }
    tool.onRelease(ctx, x: 100, y: 0, shift: false, alt: false)

    let children = model.document.layers[0].children
    #expect(children.count == 1)
    guard case .path(let pe) = children[0] else {
        Issue.record("expected Path, got \(children[0])")
        return
    }
    // MoveTo + at least one CurveTo, and every command after the MoveTo is a
    // CurveTo (no lines, no closepath).
    #expect(pe.d.count >= 2, "path should have MoveTo + at least one CurveTo")
    if case .moveTo = pe.d[0] {} else {
        Issue.record("d[0] expected MoveTo, got \(pe.d[0])")
    }
    for cmd in pe.d.dropFirst() {
        if case .curveTo = cmd {} else {
            Issue.record("expected CurveTo after the MoveTo, got \(cmd)")
        }
    }
}

// MARK: - Press+release at the same point -> degenerate Path

@Test func pencilParityClickWithoutDragCreatesDegeneratePath() throws {
    let tool = try #require(pencilTool())
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    // Press + release at the same point — on_release pushes the final point,
    // giving the buffer 2 identical points. fit_curve returns 1 degenerate
    // segment, which still lands a Path.
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)
    #expect(model.document.layers[0].children.count == 1,
            "degenerate stroke is still committed as a path")
}

// MARK: - Path uses model defaults (stroke, no fill)

@Test func pencilParityPathUsesModelDefaults() throws {
    let tool = try #require(pencilTool())
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: false)
    tool.onMove(ctx, x: 50, y: 50, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 100, y: 0, shift: false, alt: false)

    let children = model.document.layers[0].children
    #expect(children.count == 1)
    guard case .path(let pe) = children[0] else {
        Issue.record("expected Path, got \(children[0])")
        return
    }
    #expect(pe.stroke != nil, "pencil path should have a stroke")
    #expect(pe.fill == nil, "pencil path should have no fill")
}

// MARK: - Release without a prior press is a no-op

@Test func pencilParityReleaseWithoutPressIsNoop() throws {
    let tool = try #require(pencilTool())
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    tool.onRelease(ctx, x: 50, y: 60, shift: false, alt: false)
    #expect(model.document.layers[0].children.isEmpty,
            "release with no prior press should produce no element")
}

// MARK: - Path starts at the press point

@Test func pencilParityPathStartsAtPressPoint() throws {
    let tool = try #require(pencilTool())
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 15, y: 25, shift: false, alt: false)
    tool.onMove(ctx, x: 50, y: 50, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 100, y: 0, shift: false, alt: false)

    let children = model.document.layers[0].children
    #expect(children.count == 1)
    guard case .path(let pe) = children[0] else {
        Issue.record("expected Path, got \(children[0])")
        return
    }
    if case .moveTo(let x, let y) = pe.d[0] {
        #expect(x == 15)
        #expect(y == 25)
    } else {
        Issue.record("d[0] expected MoveTo(15,25), got \(pe.d[0])")
    }
}
