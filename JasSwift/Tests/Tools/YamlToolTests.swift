import Testing
import Foundation
@testable import JasLib

// Phase 5 of the Swift YAML tool-runtime migration. Covers the
// YamlTool class — ToolSpec parsing, state-defaults seeding, and
// event dispatch through buildYamlToolEffects.

// MARK: - Test helpers

private func makeCtx(model: Model) -> ToolContext {
    return ToolContext(
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

private func simpleSpec(_ id: String, _ handlers: [String: [Any]],
                        _ state: [String: Any] = [:]) -> [String: Any] {
    return [
        "id": id,
        "handlers": handlers,
        "state": state,
    ]
}

// MARK: - ToolSpec parsing

@Test func toolSpecFromWorkspaceRequiresId() {
    #expect(ToolSpec.fromWorkspaceTool([:]) == nil)
    #expect(ToolSpec.fromWorkspaceTool(["id": "foo"]) != nil)
}

@Test func toolSpecParsesCursorAndMenuLabel() {
    let spec = ToolSpec.fromWorkspaceTool([
        "id": "foo", "cursor": "crosshair", "menu_label": "Foo Tool",
        "shortcut": "F",
    ])!
    #expect(spec.cursor == "crosshair")
    #expect(spec.menuLabel == "Foo Tool")
    #expect(spec.shortcut == "F")
}

@Test func toolSpecParsesStateDefaultsShorthand() {
    let spec = ToolSpec.fromWorkspaceTool([
        "id": "foo",
        "state": ["count": 3, "active": false],
    ])!
    #expect((spec.stateDefaults["count"] as? Int) == 3)
    #expect((spec.stateDefaults["active"] as? Bool) == false)
}

@Test func toolSpecParsesStateDefaultsLongForm() {
    let spec = ToolSpec.fromWorkspaceTool([
        "id": "foo",
        "state": ["mode": ["default": "idle", "enum": ["idle", "busy"]]],
    ])!
    #expect((spec.stateDefaults["mode"] as? String) == "idle")
}

@Test func toolSpecParsesHandlers() {
    let spec = ToolSpec.fromWorkspaceTool([
        "id": "foo",
        "handlers": ["on_mousedown": [["doc.snapshot": NSNull()]]],
    ])!
    #expect(spec.handler("on_mousedown").count == 1)
    #expect(spec.handler("on_mousemove").isEmpty)
}

@Test func toolSpecParsesOverlay() {
    let spec = ToolSpec.fromWorkspaceTool([
        "id": "foo",
        "overlay": [
            "if": "tool.foo.show",
            "render": ["type": "rect", "x": 0, "y": 0],
        ],
    ])!
    #expect(spec.overlay.count == 1)
    #expect(spec.overlay.first?.guardExpr == "tool.foo.show")
    #expect((spec.overlay.first?.render["type"] as? String) == "rect")
}

// MARK: - YamlTool dispatch

@Test func yamlToolSeedsStateDefaults() {
    let tool = YamlTool.fromWorkspaceTool(simpleSpec(
        "foo", [:], ["count": 7]
    ))!
    #expect(tool.toolState("count") as? Int == 7)
}

@Test func yamlToolMousedownDispatchesHandler() {
    // Handler writes into its own tool-scope state.
    let tool = YamlTool.fromWorkspaceTool(simpleSpec(
        "foo",
        ["on_mousedown": [["set": ["$tool.foo.pressed": "true"]]]]
    ))!
    let model = Model()
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    // The handler's set effect routes via tool scope.
    #expect((tool.toolState("pressed") as? Bool) == true)
}

@Test func yamlToolMouseupPayloadCarriesCoordinates() {
    // Handler reads event.x via an expression and stashes it.
    let tool = YamlTool.fromWorkspaceTool(simpleSpec(
        "foo",
        ["on_mouseup": [["set": ["$tool.foo.x_at_release": "event.x"]]]]
    ))!
    let model = Model()
    let ctx = makeCtx(model: model)
    tool.onRelease(ctx, x: 42, y: 0, shift: false, alt: false)
    if let n = tool.toolState("x_at_release") as? Double {
        #expect(n == 42)
    } else if let n = tool.toolState("x_at_release") as? Int {
        #expect(n == 42)
    } else {
        Issue.record("expected numeric x_at_release")
    }
}

@Test func yamlToolEmptyHandlerIsNoop() {
    let tool = YamlTool.fromWorkspaceTool(simpleSpec("foo", [:]))!
    let model = Model()
    let ctx = makeCtx(model: model)
    // No on_mousedown handler — should not crash or mutate anything.
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: false)
    #expect(model.document.selection.isEmpty)
}

@Test func yamlToolActivateResetsStateDefaults() {
    let tool = YamlTool.fromWorkspaceTool(simpleSpec(
        "foo", [:], ["mode": "idle"]
    ))!
    let model = Model()
    let ctx = makeCtx(model: model)
    // Mutate the state manually via a mousedown handler.
    tool.onPress(ctx, x: 0, y: 0, shift: false, alt: false)
    // Activate again — defaults get re-seeded.
    tool.activate(ctx)
    #expect(tool.toolState("mode") as? String == "idle")
}

@Test func yamlToolKeydownDispatchesWhenDeclared() {
    let tool = YamlTool.fromWorkspaceTool(simpleSpec(
        "foo",
        ["on_keydown": [["set": ["$tool.foo.last_key": "event.key"]]]]
    ))!
    let model = Model()
    let ctx = makeCtx(model: model)
    let consumed = tool.onKeyEvent(ctx, "Escape", KeyMods())
    #expect(consumed)
    #expect(tool.toolState("last_key") as? String == "Escape")
}

@Test func yamlToolKeydownReturnsFalseWhenUndeclared() {
    let tool = YamlTool.fromWorkspaceTool(simpleSpec("foo", [:]))!
    let model = Model()
    let ctx = makeCtx(model: model)
    #expect(!tool.onKeyEvent(ctx, "Escape", KeyMods()))
}

@Test func yamlToolCursorOverrideReflectsSpec() {
    let tool = YamlTool.fromWorkspaceTool([
        "id": "foo", "cursor": "crosshair",
    ])!
    #expect(tool.cursorOverride() == "crosshair")
}

@Test func yamlToolDispatchesDocEffects() {
    // on_mousedown adds a rect to the document.
    let tool = YamlTool.fromWorkspaceTool([
        "id": "foo",
        "handlers": ["on_mousedown": [
            ["doc.add_element": ["element": [
                "type": "rect",
                "x": "event.x", "y": "event.y",
                "width": 10, "height": 10,
            ]]]
        ]],
    ])!
    let model = Model(document: Document(
        layers: [Layer(children: [])],
        selectedLayer: 0, selection: []
    ))
    let ctx = makeCtx(model: model)
    tool.onPress(ctx, x: 5, y: 7, shift: false, alt: false)
    #expect(model.document.layers[0].children.count == 1)
}
