import Foundation

/// Build the `active_document` context namespace from a Model.
///
/// Centralises the construction used by:
/// - Panel body rendering (DockPanelView.buildPanelCtx) — drives
///   `bind.disabled` / `bind.visible` expressions that read
///   `active_document.*`.
/// - Layers-panel action dispatch (LayersPanel.dispatchYamlAction) —
///   evaluated against the same surface so action predicates and
///   render-time predicates see the same values.
///
/// `layersPanelSelection` carries the layers-panel tree-selection so
/// computed fields like `new_layer_insert_index` and
/// `layers_panel_selection_count` see live panel state. Pass `[]`
/// from callers that don't have layers-panel context.
public func buildActiveDocumentView(
    model: Model?,
    layersPanelSelection: [[Int]] = []
) -> [String: Any] {
    guard let m = model else {
        return [
            "top_level_layers": [] as [Any],
            "top_level_layer_paths": [] as [Any],
            "next_layer_name": "Layer 1",
            "new_layer_insert_index": 0,
            "layers_panel_selection_count": layersPanelSelection.count,
            "has_selection": false,
            "selection_count": 0,
            "element_selection": [] as [Any],
        ]
    }
    var topLevelLayers: [[String: Any]] = []
    var topLevelLayerPaths: [[String: Any]] = []
    var layerNames: Set<String> = []
    for (i, layer) in m.document.layers.enumerated() {
        let vis: String
        switch layer.visibility {
        case .invisible: vis = "invisible"
        case .outline: vis = "outline"
        case .preview: vis = "preview"
        }
        let pathJson: [String: Any] = ["__path__": [i]]
        topLevelLayers.append([
            "kind": "Layer",
            "name": layer.name,
            "common": [
                "visibility": vis,
                "locked": layer.locked,
            ],
            "path": pathJson,
        ])
        topLevelLayerPaths.append(pathJson)
        layerNames.insert(layer.name)
    }
    var n = 1
    while layerNames.contains("Layer \(n)") { n += 1 }
    let nextLayerName = "Layer \(n)"
    let topLevelSelected = layersPanelSelection
        .filter { $0.count == 1 }
        .map { $0[0] }
    let newLayerInsertIndex = topLevelSelected.min().map { $0 + 1 }
        ?? m.document.layers.count
    let sortedSelection = m.document.selection.sorted { a, b in
        for (x, y) in zip(a.path, b.path) {
            if x != y { return x < y }
        }
        return a.path.count < b.path.count
    }
    let elementSelection: [[String: Any]] = sortedSelection.map {
        ["__path__": $0.path]
    }
    return [
        "top_level_layers": topLevelLayers,
        "top_level_layer_paths": topLevelLayerPaths,
        "next_layer_name": nextLayerName,
        "new_layer_insert_index": newLayerInsertIndex,
        "layers_panel_selection_count": layersPanelSelection.count,
        "has_selection": !m.document.selection.isEmpty,
        "selection_count": m.document.selection.count,
        "element_selection": elementSelection,
    ]
}
