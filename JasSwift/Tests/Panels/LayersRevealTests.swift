import Testing
import Foundation
@testable import JasLib

// Row 78: the Layers reveal is a STORE effect, `scroll_to_selected`'s
// `set_panel_state` of collapsed_paths through `tree_reveal`, run when the
// canvas selection changes; never a write from the tree's draw.

/// The shared fixture's first document (`element_tree.json` cases[0]): it
/// selects [0,1], a group; rows [1] [0] [0,1] [0,1,0] [0,0].
private func fixtureModel() throws -> Model {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../test_fixtures/layers/element_tree.json").standardizedFileURL
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    let cases = json?["cases"] as? [[String: Any]] ?? []
    let data = try JSONSerialization.data(withJSONObject: cases.first?["document"] as Any, options: [.sortedKeys])
    let model = Model(document: testJsonToDocument(String(data: data, encoding: .utf8)!))
    if let ws = WorkspaceData.load(), let panels = ws.panels() {
        for pid in panels.keys.sorted() {
            model.stateStore.initPanel(pid, defaults: ws.panelStateDefaults(pid))
        }
    }
    return model
}

@Test func scrollToSelectedOpensTheSelectionsCollapsedAncestors() throws {
    let model = try fixtureModel()
    #expect(model.document.selectedPaths == [[0, 1]], "positive control: the fixture selects the group [0,1]")
    setLayersCollapsedPaths(model: model, [[1], [0], [0, 1]])
    LayersPanel.dispatchYamlAction("scroll_to_selected", model: model, params: [:])
    // [0] is an ancestor of the selection and opens; the selected group itself
    // stays collapsed; the unrelated [1] keeps its state.
    #expect(layersCollapsedPaths(model: model) == [[1], [0, 1]])
}

@Test func scrollToSelectedWithAnotherPanelActiveStillWritesLayers() throws {
    // The canvas fires it whichever panel is active; the Layers dispatcher
    // binds `panel` to the Layers scope, so the read and the write agree.
    let model = try fixtureModel()
    model.stateStore.setActivePanel("color_panel_content")
    setLayersCollapsedPaths(model: model, [[0]])
    LayersPanel.dispatchYamlAction("scroll_to_selected", model: model, params: [:])
    #expect(layersCollapsedPaths(model: model) == [])
}
