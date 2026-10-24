import Testing
import Foundation
@testable import JasLib

// A dialog a TOOL opens is handed to its host (flask STATUS §285, Rust's
// `a_tool_opened_dialog_reaches_the_engine`): Scale's Alt-held click without a
// drag opens `scale_options` (scale.yaml). The tool runs on its own private
// store, so the host takes the dialog with `takeOpenedDialog` and opens it in
// the model's store. Before this the tool's runEffects had no dialog table and
// the open was dropped.

private func scaleTool() -> YamlTool? {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let spec = tools["scale"] as? [String: Any] else { return nil }
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

@Test func anAltClickWithScaleHandsOverItsOptionsDialog() throws {
    for alt in [false, true] {
        let tool = try #require(scaleTool())
        let model = Model(document: Document(layers: [Layer(name: "L", children: [])],
                                             selectedLayer: 0, selection: []))
        let ctx = makeCtx(model: model)
        tool.activate(ctx)
        tool.onPress(ctx, x: 80, y: 80, shift: false, alt: alt)
        tool.onRelease(ctx, x: 80, y: 80, shift: false, alt: alt)
        let opened = tool.takeOpenedDialog()
        if alt {
            #expect(opened?.id == "scale_options", "Alt opens the options")
            #expect(tool.takeOpenedDialog() == nil, "handed over once, closed in the tool")
        } else {
            #expect(opened == nil, "the control: no Alt, no dialog")
        }
    }
}

// The host half: the handed-over dialog opens in the MODEL's store, and a
// param resolved in the tool's scope arrives as itself (Artboard Options
// passes `artboard_id`).
@Test func aHandedOverDialogOpensInTheModelsStore() throws {
    let model = Model(document: Document(layers: [Layer(name: "L", children: [])],
                                         selectedLayer: 0, selection: []))
    #expect(model.stateStore.getDialogId() == nil, "the control: nothing open")
    #expect(openToolDialog((id: "scale_options", params: [:]), model: model))
    #expect(model.stateStore.getDialogId() == "scale_options")
    #expect(toolParamLiteral("ab12") == "'ab12'")
    #expect(toolParamLiteral("it's") == nil, "a quote cannot be escaped")
    #expect(toolParamLiteral(3.5 as NSNumber) == "3.5")
    #expect(toolParamLiteral(true as NSNumber) == "true")
    #expect(toolParamLiteral([1]) == nil)
}

// The reference point a transform tool's click sets is APP state
// (`state.transform_reference_point`, shared by Scale, Rotate and Shear), so
// the host copies it to the model's store beside the opened dialog (flask
// STATUS §537; Rust `a_transform_tools_click_point_reaches_the_engines_store`).
// Before this only the dialog moved, so Rotate Options' OK turned about the
// selection's centre. The control: a plain click stores the point too, so a
// dialog opened later from the toolbar sees it.
@Test func aTransformToolsClickPointReachesTheModelsStore() throws {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any] else { Issue.record("no bundle"); return }
    for id in ["scale", "rotate", "shear"] {
        for alt in [false, true] {
            let spec = try #require(tools[id] as? [String: Any])
            let tool = try #require(YamlTool.fromWorkspaceTool(spec))
            let model = Model(document: Document(layers: [Layer(name: "L", children: [])],
                                                 selectedLayer: 0, selection: []))
            let ctx = makeCtx(model: model)
            tool.activate(ctx)
            tool.onPress(ctx, x: 300, y: 200, shift: false, alt: alt)
            tool.onRelease(ctx, x: 300, y: 200, shift: false, alt: alt)
            #expect(model.stateStore.get("transform_reference_point") is NSNull,
                    "\(id): the control, the seeded default stands until the hand-off")
            handOffToolEvent(tool, model: model)
            let p = model.stateStore.get("transform_reference_point") as? [Any]
            #expect((p?.compactMap { ($0 as? NSNumber)?.doubleValue }) == [300, 200],
                    "\(id) alt=\(alt): \(String(describing: p))")
            #expect((model.stateStore.getDialogId() == "\(id)_options") == alt,
                    "\(id) alt=\(alt): dialog \(String(describing: model.stateStore.getDialogId()))")
        }
    }
}
