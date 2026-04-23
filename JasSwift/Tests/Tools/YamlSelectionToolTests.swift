import Testing
import Foundation
@testable import JasLib

// Phase 6 of the Swift YAML tool-runtime migration. End-to-end tests
// that drive YamlTool with the Selection spec loaded from
// workspace/workspace.json and verify behavior matches the native
// SelectionTool. This is the "prove the pattern works" gate before
// Phase 7 per-tool migration.

private func selectionTool() -> YamlTool? {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let spec = tools["selection"] as? [String: Any] else {
        return nil
    }
    return YamlTool.fromWorkspaceTool(spec)
}

private func makeRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Element {
    .rect(Rect(x: x, y: y, width: w, height: h))
}

private func twoRectModel() -> Model {
    let layer = Layer(children: [
        makeRect(0, 0, 10, 10),
        makeRect(50, 50, 10, 10),
    ])
    return Model(document: Document(
        layers: [layer], selectedLayer: 0, selection: []
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

// MARK: - Debug: let ... in dispatch

@Test func yamlToolLetInBindingWorksInHandler() {
    // Verify let+in form evaluates `in:` effects with the binding.
    let tool = YamlTool.fromWorkspaceTool([
        "id": "foo",
        "state": ["seen": "no"],
        "handlers": ["on_mousedown": [
            ["let": ["v": "event.x"],
             "in": [
                ["set": ["tool.foo.seen": "v"]],
             ]]
        ]],
    ])!
    let model = Model()
    let ctx = ToolContext(
        model: model,
        controller: Controller(model: model),
        hitTestSelection: { _ in false },
        hitTestHandle: { _ in nil },
        hitTestText: { _ in nil },
        hitTestPathCurve: { _, _ in nil },
        requestUpdate: {},
        drawElementOverlay: { _, _, _ in }
    )
    tool.onPress(ctx, x: 42, y: 0, shift: false, alt: false)
    if let n = tool.toolState("seen") as? Int {
        #expect(n == 42)
    } else if let n = tool.toolState("seen") as? Double {
        #expect(n == 42)
    } else {
        Issue.record("expected numeric seen, got \(String(describing: tool.toolState("seen")))")
    }
}

@Test func nullEqualsNullEvaluatesTrue() {
    #expect(evaluate("null == null", context: [:]) == .bool(true))
}

@Test func nsNullBindingComparesToNull() {
    let ctx: [String: Any] = ["hit": NSNull()]
    #expect(evaluate("hit == null", context: ctx) == .bool(true))
}

@Test func yamlToolIfThenElseInsideLetInHits() {
    // Minimal test to isolate the bug: can the `if:` effect inside
    // an `in:` block see the binding and write to tool state?
    let tool = YamlTool.fromWorkspaceTool([
        "id": "foo",
        "state": ["branch": "none"],
        "handlers": ["on_mousedown": [
            ["let": ["v": "event.x"],
             "in": [
                ["if": "v > 5",
                 "then": [["set": ["tool.foo.branch": "'big'"]]],
                 "else": [["set": ["tool.foo.branch": "'small'"]]]],
             ]]
        ]],
    ])!
    let model = Model()
    let ctx = ToolContext(
        model: model,
        controller: Controller(model: model),
        hitTestSelection: { _ in false },
        hitTestHandle: { _ in nil },
        hitTestText: { _ in nil },
        hitTestPathCurve: { _, _ in nil },
        requestUpdate: {},
        drawElementOverlay: { _, _, _ in }
    )
    tool.onPress(ctx, x: 10, y: 0, shift: false, alt: false)
    #expect(tool.toolState("branch") as? String == "big")
}

@Test func yamlToolLetInNullBindingDetectedByIfGuard() {
    // With `hit = null`, `if hit == null` should take the then branch.
    let tool = YamlTool.fromWorkspaceTool([
        "id": "foo",
        "state": ["branch": "none"],
        "handlers": ["on_mousedown": [
            ["let": ["hit": "hit_test(event.x, event.y)"],
             "in": [
                ["if": "hit == null",
                 "then": [["set": ["tool.foo.branch": "'miss'"]]],
                 "else": [["set": ["tool.foo.branch": "'hit'"]]]]
             ]]
        ]],
    ])!
    // No registered document → hit_test returns null.
    let model = Model()
    let ctx = ToolContext(
        model: model,
        controller: Controller(model: model),
        hitTestSelection: { _ in false },
        hitTestHandle: { _ in nil },
        hitTestText: { _ in nil },
        hitTestPathCurve: { _, _ in nil },
        requestUpdate: {},
        drawElementOverlay: { _, _, _ in }
    )
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: false)
    #expect(tool.toolState("branch") as? String == "miss")
}

// MARK: - Tool loads

@Test func yamlSelectionToolLoadsFromWorkspace() throws {
    let tool = try #require(selectionTool())
    #expect(tool.spec.id == "selection")
    #expect(tool.spec.cursor == "arrow")
    #expect(tool.spec.shortcut == "V")
}

// MARK: - Click

@Test func yamlSelectionClickOnElementSelects() throws {
    let tool = try #require(selectionTool())
    let model = twoRectModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 5, y: 5, shift: false, alt: false)
    tool.onRelease(ctx, x: 5, y: 5, shift: false, alt: false)
    #expect(model.document.selection.count == 1)
    #expect(model.document.selection.first?.path == [0, 0])
}

@Test func yamlSelectionClickEmptySpaceClears() throws {
    let tool = try #require(selectionTool())
    let model = twoRectModel()
    Controller(model: model).selectElement([0, 0])
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 200, y: 200, shift: false, alt: false)
    tool.onRelease(ctx, x: 200, y: 200, shift: false, alt: false)
    #expect(model.document.selection.isEmpty)
}

@Test func yamlSelectionShiftClickTogglesSelection() throws {
    let tool = try #require(selectionTool())
    let model = twoRectModel()
    // First shift-click adds.
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 5, y: 5, shift: true, alt: false)
    tool.onRelease(ctx, x: 5, y: 5, shift: true, alt: false)
    #expect(model.document.selection.count == 1)
    // Second shift-click on the same element removes.
    tool.onPress(ctx, x: 5, y: 5, shift: true, alt: false)
    tool.onRelease(ctx, x: 5, y: 5, shift: true, alt: false)
    #expect(model.document.selection.isEmpty)
}

// MARK: - Drag (translate)

@Test func yamlSelectionDragMovesSelectedElement() throws {
    let tool = try #require(selectionTool())
    let model = twoRectModel()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 5, y: 5, shift: false, alt: false)
    tool.onMove(ctx, x: 15, y: 15, shift: false, dragging: true)
    tool.onRelease(ctx, x: 15, y: 15, shift: false, alt: false)
    if case .rect(let r) = model.document.layers[0].children[0] {
        #expect(r.x == 10 && r.y == 10)
    } else {
        Issue.record("expected rect")
    }
}

// MARK: - Marquee

@Test func yamlSelectionMarqueeReleaseSelectsElements() throws {
    let tool = try #require(selectionTool())
    let model = twoRectModel()
    let ctx = makeCtx(model: model)
    // Start in empty space, drag over the first rect, release.
    tool.onPress(ctx, x: -5, y: -5, shift: false, alt: false)
    tool.onMove(ctx, x: 12, y: 12, shift: false, dragging: true)
    tool.onRelease(ctx, x: 12, y: 12, shift: false, alt: false)
    #expect(model.document.selection.contains { $0.path == [0, 0] })
}

// MARK: - Alt+drag (copy)

@Test func yamlSelectionAltDragCopiesSelection() throws {
    let tool = try #require(selectionTool())
    let model = twoRectModel()
    let ctx = makeCtx(model: model)
    // Click to select, then Alt+drag. Alt is captured at press time.
    tool.onPress(ctx, x: 5, y: 5, shift: false, alt: true)
    tool.onMove(ctx, x: 100, y: 100, shift: false, dragging: true)
    tool.onRelease(ctx, x: 100, y: 100, shift: false, alt: true)
    // Originals at (0,0) and (50,50) still there; a new copy appended.
    #expect(model.document.layers[0].children.count == 3)
}

// MARK: - Escape

@Test func yamlSelectionEscapeIdlesState() throws {
    let tool = try #require(selectionTool())
    let model = twoRectModel()
    let ctx = makeCtx(model: model)
    // Put the tool into marquee mode.
    tool.onPress(ctx, x: -5, y: -5, shift: false, alt: false)
    #expect(tool.toolState("mode") as? String == "marquee")
    _ = tool.onKeyEvent(ctx, "Escape", KeyMods())
    #expect(tool.toolState("mode") as? String == "idle")
}
