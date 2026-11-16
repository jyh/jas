import Testing
import Foundation
@testable import JasLib

// STATUS-jas row 141 part 3: the Mac Layers row's context menu is DRAWN and RUN
// from layers.yaml's `context_menu:` through `LayersRowMenu`, never hand-built.
// These arms hold the helper the native row calls: it binds the row as `node`
// in the panel's scope, its entries are the yaml's, and a pick runs through
// the engine's door (`PanelWidgetEvents.contextMenuItem`), so the yaml's own
// `enabled_when` and the dispatch-path guards (row 141 parts 2a, 2b) apply.

/// multi_layer.svg: rows, top first, [1] [1,0] [0] [0,0]; two layers, each with
/// one leaf child.
private func twoLayers() -> Model {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../test_fixtures/svg/multi_layer.svg").standardizedFileURL
    let svg = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let model = Model(document: svgToDocument(svg))
    if let ws = WorkspaceData.load(), let panels = ws.panels() {
        for pid in panels.keys.sorted() {
            model.stateStore.initPanel(pid, defaults: ws.panelStateDefaults(pid))
        }
    }
    model.stateStore.setActivePanel("layers_panel_content")
    return model
}

private func labels(_ es: [WidgetEvent.ContextMenuEntry]) -> [String] {
    es.map { if case .item(let l, _, _) = $0 { return l } else { return "—" } }
}

private func index(_ es: [WidgetEvent.ContextMenuEntry], _ label: String) -> Int? {
    for e in es { if case .item(let l, _, let i) = e, l == label { return i } }
    return nil
}

@Test func theRowMenuIsTheYamlsMenuInTheRowsScope() throws {
    let model = twoLayers()
    let menu = try #require(LayersRowMenu.at([1], model: model))
    #expect(labels(menu.entries) == ["Options for Layer...", "Duplicate", "Delete Selection", "—",
                                     "Enter Isolation Mode", "—", "Flatten Artwork", "Collect in New Layer"])
    // The row is bound as `node`: the layer row enables the layer-only item
    // (an unbound `node` disables it everywhere) and the leaf row disables it.
    #expect(menu.entries[0] == .item(label: "Options for Layer...", enabled: true, index: 0))
    let leaf = try #require(LayersRowMenu.at([1, 0], model: model))
    let opts = leaf.entries.first { if case .item(let l, _, _) = $0 { return l == "Options for Layer..." } else { return false } }
    #expect(opts == .item(label: "Options for Layer...", enabled: false, index: 0))
}

@Test func aRowThatIsNotInTheTreeHasNoMenu() {
    #expect(LayersRowMenu.at([7], model: twoLayers()) == nil)
}

/// A pick runs through the door, in the row's scope: Duplicate duplicates the
/// panel selection, and the isolation item isolates THIS row.
@Test func aPickRunsTheYamlItemThroughTheDoor() throws {
    let model = twoLayers()
    setLayersPanelSelection(model: model, [[1]])
    let menu = try #require(LayersRowMenu.at([1], model: model))
    let dup = try #require(index(menu.entries, "Duplicate"))
    #expect(menu.pick(dup, model: model).outcome == "committed")
    #expect(model.document.layers.count == 3, "Duplicate duplicated the selected layer")

    let row = try #require(LayersRowMenu.at([0], model: model))
    let iso = try #require(index(row.entries, "Enter Isolation Mode"))
    #expect(row.pick(iso, model: model).outcome == "committed")
    #expect(model.layersIsolationStack == [[0]], "the isolation item isolates the row it was opened on")
}

/// The last-layer rule (part 2a) reaches the Mac menu: with every top-level
/// layer panel-selected, Delete Selection is disabled AND the door refuses it.
@Test func deleteSelectionIsRefusedWhenItWouldDeleteEveryLayer() throws {
    let model = twoLayers()
    setLayersPanelSelection(model: model, [[0], [1]])
    let menu = try #require(LayersRowMenu.at([1], model: model))
    let del = try #require(index(menu.entries, "Delete Selection"))
    #expect(menu.entries.contains(.item(label: "Delete Selection", enabled: false, index: del)))
    #expect(menu.pick(del, model: model).outcome == "refused")
    #expect(model.document.layers.count == 2)
}
