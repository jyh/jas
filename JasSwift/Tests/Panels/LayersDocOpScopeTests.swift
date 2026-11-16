import Testing
import Foundation
@testable import JasLib

// STATUS-jas row 144, the second break. A `doc.op` argument is an expression,
// evaluated by `docOpArgs` in the platform effect's call context. From the menu
// path that context is `actionContext`, which carries `panel`. From the
// engine's panel door it is the behavior's locals plus `event`, which leave
// `panel` to the store (`scopeLocals`), so `panel.*` read null. The fork's
// `move_elements` reads `paths: panel.layers_panel_selection`, so a valid row
// drop through the door moved nothing. The seam's context (`param` only) is
// the door's shape.

private func twoLayers() -> Model {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../test_fixtures/svg/multi_layer.svg").standardizedFileURL
    let model = Model(document: svgToDocument((try? String(contentsOf: url, encoding: .utf8)) ?? ""))
    if let ws = WorkspaceData.load(), let panels = ws.panels() {
        for pid in panels.keys.sorted() { model.stateStore.initPanel(pid, defaults: ws.panelStateDefaults(pid)) }
    }
    model.stateStore.setActivePanel("layers_panel_content")
    return model
}

@Test func aDocOpArgumentReadsThePanelFromTheStoreWhenTheCallerLeavesItOut() {
    let model = twoLayers()
    model.stateStore.setPanel("layers_panel_content", "layers_panel_selection",
                              [["__path__": [1, 0]] as [String: Any]])
    #expect(!model.document.selection.contains { $0.path == [1, 0] }, "positive control: not selected yet")
    LayersPanel.runEffectsForTest(actionName: "row144_probe", effects: [
        ["doc.op": ["op": "select_path", "path": "panel.layers_panel_selection[0]"]],
    ], model: model)
    #expect(model.document.selection.contains { $0.path == [1, 0] },
            "select_path took its path from panel.*: \(model.document.selection.map { $0.path })")
}

@Test func aCallersOwnPanelStillWins() {
    // CONTROL: the menu path supplies its own `panel` (with model-held keys),
    // and the store's must not replace it.
    let model = twoLayers()
    model.stateStore.setPanel("layers_panel_content", "layers_panel_selection",
                              [["__path__": [0, 0]] as [String: Any]])
    LayersPanel.runEffectsForTest(actionName: "row144_probe", effects: [
        ["doc.op": ["op": "select_path", "path": "param.p"]],
    ], model: model, params: ["p": ["__path__": [1, 0]] as [String: Any]])
    #expect(model.document.selection.contains { $0.path == [1, 0] }, "\(model.document.selection.map { $0.path })")
}
