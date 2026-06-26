import Testing
import Foundation
@testable import JasLib

// Line tool gesture-seam tests — Swift port of the Rust line seam tests in
// jas_dioxus/src/tools/yaml_tool.rs (the line_parity_* family +
// line_yaml_tool() loader).
//
// These drive the PRODUCTION line tool loaded from the workspace bundle
// through on_press / on_move / on_release and assert the committed Line
// element. The line tool is SIMPLE: press-drag-release commits a single
// Line (x1,y1 = press point, x2,y2 = release point) in doc space; a drag
// shorter than 2pt (hypot) is rejected; it reads NO app-level state, so —
// unlike the blob seam tests — there is no app-state seed/bridge call.
// With an identity view the doc coords equal the screen coords passed to
// the verbs.
//
// Seam mapping from Rust to Swift:
//   on_press        -> onPress(ctx, x:, y:, shift:, alt:)
//   on_move(drag)   -> onMove(ctx, x:, y:, shift:, alt:, dragging:)
//   on_release      -> onRelease(ctx, x:, y:, shift:, alt:)
//   tool.tool_state -> tool.toolState("mode")   (the tool's self-contained
//                      store: "idle" -> "drawing" on press -> "idle" on
//                      release)
//
// The committed element is a Line; in Swift the Line-case payload (`le`) is
// the Line struct, with le.x1 / le.y1 / le.x2 / le.y2 : Double.

private func lineTool() -> YamlTool? {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let spec = tools["line"] as? [String: Any] else {
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

@Test func lineToolLoadsFromWorkspace() throws {
    let tool = try #require(lineTool())
    #expect(tool.spec.id == "line")
}

// MARK: - draw_line: press-drag-release commits one Line at press/release pts

@Test func lineParityDrawLine() throws {
    // press(10,20); move(30,40,dragging); release(50,60) -> exactly ONE
    // child, a Line with x1=10,y1=20,x2=50,y2=60 (the intermediate move
    // updates the preview only; x2/y2 come from the release point).
    let tool = try #require(lineTool())
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onMove(ctx, x: 30, y: 40, shift: false, alt: false, dragging: true)
    tool.onRelease(ctx, x: 50, y: 60, shift: false, alt: false)

    let children = model.document.layers[0].children
    #expect(children.count == 1, "draw commits exactly one Line")
    guard case .line(let le) = children[0] else {
        Issue.record("expected Line, got \(children[0])")
        return
    }
    #expect(le.x1 == 10)
    #expect(le.y1 == 20)
    #expect(le.x2 == 50)
    #expect(le.y2 == 60)
}

// MARK: - short_line_not_created: zero-length drag commits nothing

@Test func lineParityShortLineNotCreated() throws {
    // Press and release at the same point — hypot distance = 0, below the
    // 2pt minimum — so nothing is committed.
    let tool = try #require(lineTool())
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)

    #expect(model.document.layers[0].children.isEmpty,
            "a zero-length drag commits no Line")
}

// MARK: - idle_after_release: mode latches idle -> drawing -> idle

@Test func lineParityIdleAfterRelease() throws {
    // The tool's "mode" starts idle, flips to drawing on press, and returns
    // to idle on release.
    let tool = try #require(lineTool())
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    #expect(tool.toolState("mode") as? String == "idle")
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    #expect(tool.toolState("mode") as? String == "drawing")
    tool.onRelease(ctx, x: 50, y: 60, shift: false, alt: false)
    #expect(tool.toolState("mode") as? String == "idle")
}

// MARK: - move_without_press_is_noop: move before press changes nothing

@Test func lineParityMoveWithoutPressIsNoop() throws {
    // on_mousemove's handler is guarded by mode == "drawing"; without a
    // prior on_mousedown, mode stays "idle" and nothing is committed.
    let tool = try #require(lineTool())
    let model = emptyLayerModel()
    let ctx = makeCtx(model: model)
    tool.onMove(ctx, x: 50, y: 60, shift: false, alt: false, dragging: true)

    #expect(tool.toolState("mode") as? String == "idle",
            "move without a prior press leaves mode idle")
    #expect(model.document.layers[0].children.isEmpty,
            "move without a prior press commits nothing")
}
