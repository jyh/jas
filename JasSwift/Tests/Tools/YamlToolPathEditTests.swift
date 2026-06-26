import Testing
import Foundation
@testable import JasLib

// Path-edit tool gesture-seam tests — Swift port of the Rust path-EDIT seam
// tests in jas_dioxus/src/tools/yaml_tool.rs. ONE combined file covering TWO
// path-edit tools: path_eraser and smooth.
//
// Each case loads the PRODUCTION tool from the workspace bundle and drives it
// through on_press / on_release. With an identity view (zoomLevel == 0 on a
// fresh Model), doc coords equal the screen coords passed to the verbs. These
// tools read NO app-level state — the eraser cuts whatever path geometry the
// drag rect crosses, and smooth re-fits the selected path geometry under the
// cursor — so, unlike the blob/selection seam tests, there is no app-state
// seed/bridge call. The ToolContext hit-test closures are stubbed because the
// path-edit effects resolve directly against the document geometry by
// coordinate (eraser) or against the document selection (smooth).
//
// Seam mapping from Rust to Swift:
//   on_press        -> onPress(ctx, x:, y:, shift:, alt:)
//   on_release      -> onRelease(ctx, x:, y:, shift:, alt:)
//
// The numbers below mirror the Rust fixtures and assertions EXACTLY:
//   model_with_long_line_path        (path_eraser) — open line split into 2
//   model_with_selected_zigzag_path  (smooth)      — SELECTED zigzag re-fit

private func pathEditTool(_ id: String) -> YamlTool? {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let spec = tools[id] as? [String: Any] else {
        return nil
    }
    return YamlTool.fromWorkspaceTool(spec)
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

private func firstPath(_ model: Model) -> Path? {
    let children = model.document.layers[0].children
    guard let first = children.first, case .path(let p) = first else { return nil }
    return p
}

// MARK: - path_eraser tool

// model_with_long_line_path: a single open Path MoveTo(0,0) + LineTo(100,0),
// black 1pt stroke, inside one layer named "L". No selection.
private func modelWithLongLinePath() -> Model {
    let path = Path(d: [.moveTo(0, 0), .lineTo(100, 0)],
                    fill: nil, stroke: Stroke(color: .black, width: 1.0))
    let layer = Layer(name: "L", children: [.path(path)])
    return Model(document: Document(
        layers: [layer], selectedLayer: 0, selection: []
    ))
}

@Test func pathEraserParitySplitsOpenPath() throws {
    // Press in the middle of the line at (50, 0) — should split the line
    // into two sub-paths. The layer goes from 1 child to 2. Undoable.
    let tool = try #require(pathEditTool("path_eraser"))
    let model = modelWithLongLinePath()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 50, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 0, shift: false, alt: false)

    let children = model.document.layers[0].children
    #expect(children.count == 2, "single line should split into 2 sub-paths")
    #expect(model.canUndo)
}

@Test func pathEraserParityMissDoesNothing() throws {
    // Press far from the line -> document unchanged (still 1 child).
    let tool = try #require(pathEditTool("path_eraser"))
    let model = modelWithLongLinePath()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 500, y: 500, shift: false, alt: false)
    tool.onRelease(ctx, x: 500, y: 500, shift: false, alt: false)

    let children = model.document.layers[0].children
    #expect(children.count == 1, "miss should not change the path count")
}

// MARK: - smooth tool

// model_with_selected_zigzag_path: a Path that starts at MoveTo(0,0) and then
// has 20 LineTos zig-zagging between y=+5 (even i) and y=-5 (odd i), x = i*5.
// The path is SELECTED in the document (selection at path [0, 0]); selection
// matters — smooth only re-fits selected paths.
private func zigzagCommands() -> [PathCommand] {
    var cmds: [PathCommand] = [.moveTo(0, 0)]
    for i in 1...20 {
        let x = Double(i) * 5.0
        let y = (i % 2 == 0) ? 5.0 : -5.0
        cmds.append(.lineTo(x, y))
    }
    return cmds
}

private func zigzagLayer() -> Layer {
    let path = Path(d: zigzagCommands(),
                    fill: nil, stroke: Stroke(color: .black, width: 1.0))
    return Layer(name: "L", children: [.path(path)])
}

private func modelWithSelectedZigzagPath() -> Model {
    Model(document: Document(
        layers: [zigzagLayer()],
        selectedLayer: 0,
        selection: [ElementSelection.all([0, 0])]
    ))
}

private func modelWithUnselectedZigzagPath() -> Model {
    Model(document: Document(
        layers: [zigzagLayer()],
        selectedLayer: 0,
        selection: []
    ))
}

@Test func smoothParityReducesCommandsOnZigzag() throws {
    // SELECTED zigzag. Smooth at the midpoint (50, 0) — default radius 100
    // covers the whole path — re-fits it to fewer commands. Undoable.
    let tool = try #require(pathEditTool("smooth"))
    let model = modelWithSelectedZigzagPath()
    let ctx = makeCtx(model: model)
    let originalLen = try #require(firstPath(model)).d.count
    tool.onPress(ctx, x: 50, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 0, shift: false, alt: false)

    let newLen = try #require(firstPath(model)).d.count
    #expect(newLen < originalLen,
            "smooth should reduce command count on a zigzag (was \(originalLen), now \(newLen))")
    #expect(model.canUndo)
}

@Test func smoothParityOnlyAffectsSelectedPaths() throws {
    // UNSELECTED zigzag — smooth should do nothing (command count unchanged).
    let tool = try #require(pathEditTool("smooth"))
    let model = modelWithUnselectedZigzagPath()
    let ctx = makeCtx(model: model)
    let originalLen = try #require(firstPath(model)).d.count
    tool.onPress(ctx, x: 50, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 0, shift: false, alt: false)

    let newLen = try #require(firstPath(model)).d.count
    #expect(newLen == originalLen)
}
