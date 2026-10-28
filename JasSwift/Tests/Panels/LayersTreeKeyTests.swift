import Testing
import Foundation
@testable import JasLib

// The Layers tree's keys run layers.yaml's `keyboard:` rows (STATUS-jas item 8
// class L, step 2b): `LayersPanel.treeKey` resolves a chord in the action
// context and dispatches the row's action. Mirrors the Rust
// `layers_tree_key_tests`.

/// multi_layer.svg, seeded as the action corpus seeds it: rows, top first,
/// [1] [1,0] [0] [0,0]; `selection` is the Layers panel selection.
private func twoLayers(selection: [[Int]]) -> Model {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../test_fixtures/svg/multi_layer.svg").standardizedFileURL
    let svg = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let model = Model(document: svgToDocument(svg))
    if let ws = WorkspaceData.load(), let panels = ws.panels() {
        for pid in panels.keys.sorted() {
            model.stateStore.initPanel(pid, defaults: ws.panelStateDefaults(pid))
        }
    }
    model.stateStore.setPanel("layers_panel_content", "layers_panel_selection",
                              selection.map { ["__path__": $0] as [String: Any] })
    model.stateStore.setActivePanel("layers_panel_content")
    return model
}

@Test func treeKeyDownMovesTheSelectionAndTheTargetLayer() {
    let model = twoLayers(selection: [[1]])
    #expect(model.document.layers.count == 2, "positive control: two layers")
    #expect(LayersPanel.treeKey(KeyChord(key: "ArrowDown"), model: model))
    #expect(layersPanelSelection(model: model) == [[1, 0]])
    #expect(model.document.selectedLayer == 1)
}

@Test func treeKeyUpWithNothingSelectedSelectsTheLastRow() {
    let model = twoLayers(selection: [])
    #expect(LayersPanel.treeKey(KeyChord(key: "ArrowUp"), model: model))
    #expect(layersPanelSelection(model: model) == [[0, 0]])
}

@Test func treeKeyF2StartsTheRenameOfTheOneSelectedRow() {
    let model = twoLayers(selection: [[1, 0]])
    #expect(LayersPanel.treeKey(KeyChord(key: "F2"), model: model))
    let renaming = model.stateStore.getPanel("layers_panel_content", "renaming_element") as? [String: Any]
    #expect(renaming?["__path__"] as? [Int] == [1, 0])
}

@Test func treeKeyRightCollapsesNothingAndEntersTheContainer() {
    let model = twoLayers(selection: [[1]])
    #expect(LayersPanel.treeKey(KeyChord(key: "ArrowRight"), model: model))
    #expect(layersPanelSelection(model: model) == [[1, 0]])
}

@Test func treeKeyLeavesAnUnboundKeyToTheHost() {
    let model = twoLayers(selection: [[1]])
    #expect(!LayersPanel.treeKey(KeyChord(key: "X"), model: model))
    #expect(layersPanelSelection(model: model) == [[1]], "nothing moved")
}
