import Foundation
import Testing
@testable import JasLib

// STATUS-jas item 24 (flask §564 finding J): the Layers menu's toggle-all
// labels are `{{if …}}` templates over `active_document.any_layer_*`, which
// no port built until 2026-10-26. The menu evaluates them in its own context;
// no native table restates them.

private func label(_ cmd: String, _ model: Model) -> String {
    let raw = LayersPanel.menuItems().compactMap { item -> String? in
        if case .action(let l, let c, _) = item, c == cmd { return l }
        return nil
    }.first ?? ""
    #expect(raw.contains("{{"), "the control: the YAML label is a template: \(raw)")
    return panelMenuLabel(.layers, label: raw, layout: WorkspaceLayout.defaultLayout(), model: model)
}

@Test func theLayersMenuLabelsResolveFromTheirTemplates() {
    let visible = Model(document: Document(layers: [Layer(name: "A", children: [])], selectedLayer: 0, selection: []))
    #expect(label("toggle_all_layers_visibility", visible) == "Hide All Layers")
    #expect(label("toggle_all_layers_lock", visible) == "Lock All Layers")
    let hidden = Model(document: Document(
        layers: [Layer(name: "A", children: [], locked: true, visibility: .invisible)], selectedLayer: 0, selection: []))
    #expect(label("toggle_all_layers_visibility", hidden) == "Show All Layers")
    #expect(label("toggle_all_layers_outline", hidden) == "Preview All Layers")
    #expect(label("toggle_all_layers_lock", hidden) == "Unlock All Layers")
}
