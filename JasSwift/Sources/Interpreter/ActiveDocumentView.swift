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
    layersPanelSelection: [[Int]] = [],
    artboardsPanelSelection: [String] = []
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
            "artboards": [] as [Any],
            "artboard_options": [
                "fade_region_outside_artboard": true,
                "update_while_dragging": true,
            ] as [String: Any],
            "artboards_count": 0,
            "next_artboard_name": "Artboard 1",
            "current_artboard_id": NSNull(),
            "current_artboard": [:] as [String: Any],
            "artboards_panel_selection_ids": artboardsPanelSelection,
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
    // Artboard view (ARTBOARDS.md §Artboard data model).
    let artboardsView: [[String: Any]] = m.document.artboards.enumerated().map { (i, ab) in
        [
            "id": ab.id,
            "name": ab.name,
            "number": i + 1,
            "x": ab.x,
            "y": ab.y,
            "width": ab.width,
            "height": ab.height,
            "fill": ab.fill.asCanonical,
            "show_center_mark": ab.showCenterMark,
            "show_cross_hairs": ab.showCrossHairs,
            "show_video_safe_areas": ab.showVideoSafeAreas,
            "video_ruler_pixel_aspect_ratio": ab.videoRulerPixelAspectRatio,
        ]
    }
    let selectedSet = Set(artboardsPanelSelection)
    let current = m.document.artboards.first(where: { selectedSet.contains($0.id) })
        ?? m.document.artboards.first
    let currentArtboardJson: [String: Any]
    let currentArtboardId: Any
    if let a = current {
        currentArtboardJson = [
            "id": a.id,
            "name": a.name,
            "x": a.x,
            "y": a.y,
            "width": a.width,
            "height": a.height,
        ]
        currentArtboardId = a.id
    } else {
        currentArtboardJson = [:]
        currentArtboardId = NSNull()
    }
    let nextArtboardName_ = nextArtboardName(m.document.artboards)
    return [
        "top_level_layers": topLevelLayers,
        "top_level_layer_paths": topLevelLayerPaths,
        "next_layer_name": nextLayerName,
        "new_layer_insert_index": newLayerInsertIndex,
        "layers_panel_selection_count": layersPanelSelection.count,
        "has_selection": !m.document.selection.isEmpty,
        "selection_count": m.document.selection.count,
        "element_selection": elementSelection,
        "artboards": artboardsView,
        "artboard_options": [
            "fade_region_outside_artboard": m.document.artboardOptions.fadeRegionOutsideArtboard,
            "update_while_dragging": m.document.artboardOptions.updateWhileDragging,
        ] as [String: Any],
        "artboards_count": m.document.artboards.count,
        "next_artboard_name": nextArtboardName_,
        "current_artboard_id": currentArtboardId,
        "current_artboard": currentArtboardJson,
        "artboards_panel_selection_ids": artboardsPanelSelection,
    ]
}

/// Build the selection-level predicates referenced by yaml
/// expressions (``selection_has_mask``, ``selection_mask_clip``,
/// ``selection_mask_invert``, ``selection_mask_linked``) per
/// OPACITY.md § States / § Document model. Mixed selections count
/// as "no mask"; the mask fields are read from the first selected
/// element's mask, driving "first-wins" bindings on
/// CLIP_CHECKBOX / INVERT_MASK_CHECKBOX / LINK_INDICATOR. Mirrors
/// ``build_selection_predicates`` in ``jas_dioxus``.
public func buildSelectionPredicates(model: Model?) -> [String: Any] {
    guard let m = model else {
        return [
            "selection_has_mask": false,
            "selection_mask_clip": false,
            "selection_mask_invert": false,
            // Default `linked` to true so the LINK_INDICATOR shows
            // the linked glyph when no mask exists — matches the
            // "New masks are linked" spec default.
            "selection_mask_linked": true,
        ]
    }
    let doc = m.document
    let hasMask = selectionHasMask(doc)
    let first = firstMask(doc)
    return [
        "selection_has_mask": hasMask,
        "selection_mask_clip": first?.clip ?? false,
        "selection_mask_invert": first?.invert ?? false,
        "selection_mask_linked": first?.linked ?? true,
    ]
}
