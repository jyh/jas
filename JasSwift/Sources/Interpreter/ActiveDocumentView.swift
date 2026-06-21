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
            "document_setup": documentSetupView(.default),
            "print_preferences": printPreferencesView(.default),
            "artboards_count": 0,
            "next_artboard_name": "Artboard 1",
            "current_artboard_id": NSNull(),
            "current_artboard": [:] as [String: Any],
            "artboards_panel_selection_ids": artboardsPanelSelection,
            "symbols": [] as [Any],
            "selected_concept": NSNull(),
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
            "name": layer.name ?? "",
            "common": [
                "visibility": vis,
                "locked": layer.locked,
            ],
            "path": pathJson,
        ])
        topLevelLayerPaths.append(pathJson)
        if let n = layer.name { layerNames.insert(n) }
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
    // Symbols view (SYMBOLS.md §8). One row per master in the off-canvas
    // store. `name` is the master's common.name, falling back to a
    // positional "Symbol N" label so every row shows something readable.
    // `usage_count` is the number of live instances of the master — the
    // length of its reverse-dependency list (rdeps) in the dependency
    // index, the same signal that gates the reference-aware delete.
    let depIndex = DependencyIndex.build(m.document)
    let symbolsView: [[String: Any]] = m.document.symbols.enumerated().map { (i, master) in
        let id = master.id ?? ""
        let name: String
        if let n = master.name, !n.isEmpty {
            name = n
        } else {
            name = "Symbol \(i + 1)"
        }
        let usageCount = depIndex.rdeps[id]?.count ?? 0
        return [
            "id": id,
            "name": name,
            "usage_count": usageCount,
        ]
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
        // Drives the Boolean panel's Expand button + the Release/
        // Expand Compound Shape menu items: enabled only when at
        // least one selected element is a compound shape.
        "selection_has_compound_shape": m.document.selection.contains {
            // Use the bounds-checked lookup: a selection may carry a
            // stale path into a since-mutated document. Mirrors Rust's
            // matches!(get_element(...), Some(Element::Live(_))) which
            // is false for a missing element rather than a crash.
            if case .live = m.document.tryGetElement($0.path) { return true }
            return false
        },
        "artboards": artboardsView,
        "artboard_options": [
            "fade_region_outside_artboard": m.document.artboardOptions.fadeRegionOutsideArtboard,
            "update_while_dragging": m.document.artboardOptions.updateWhileDragging,
        ] as [String: Any],
        "document_setup": documentSetupView(m.document.documentSetup),
        "print_preferences": printPreferencesView(m.document.printPreferences),
        "artboards_count": m.document.artboards.count,
        "next_artboard_name": nextArtboardName_,
        "current_artboard_id": currentArtboardId,
        "current_artboard": currentArtboardJson,
        "artboards_panel_selection_ids": artboardsPanelSelection,
        "symbols": symbolsView,
        // Concepts panel Slice 2: the single selected Generated instance's
        // concept (param schema merged with its current values), or null.
        "selected_concept": selectedConceptView(m.document),
    ]
}

/// Build `active_document.selected_concept` (CONCEPTS.md §6.4): null unless
/// exactly one `Generated` concept instance is selected; otherwise
/// `{ concept_id, name, params: [{ name, value, min, max }, …] }` — the
/// concept's registry param schema merged with the instance's current values
/// (instance value if present, else the schema default). Drives the Concepts
/// panel's PARAMS mode. Mirrors Rust `build_selected_concept_view`.
private func selectedConceptView(_ doc: Document) -> Any {
    guard doc.selection.count == 1, let sel = doc.selection.first else { return NSNull() }
    let path = sel.path
    guard case .live(.generated(let gen)) = doc.tryGetElement(path) else { return NSNull() }
    guard let concept = WorkspaceData.load()?.concept(gen.conceptId) else { return NSNull() }
    let name = (concept["name"] as? String) ?? gen.conceptId
    var paramsOut: [[String: Any]] = []
    if let schema = concept["params"] as? [[String: Any]] {
        for p in schema {
            guard let pname = p["name"] as? String else { continue }
            let value: Any = gen.params[pname] ?? p["default"] ?? NSNull()
            var entry: [String: Any] = ["name": pname, "value": value]
            if let mn = p["min"] { entry["min"] = mn }
            if let mx = p["max"] { entry["max"] = mx }
            paramsOut.append(entry)
        }
    }
    return [
        "concept_id": gen.conceptId,
        "name": name,
        "params": paramsOut,
    ] as [String: Any]
}

private func documentSetupView(_ s: DocumentSetup) -> [String: Any] {
    return [
        "bleed_top": s.bleedTop,
        "bleed_right": s.bleedRight,
        "bleed_bottom": s.bleedBottom,
        "bleed_left": s.bleedLeft,
        "bleed_uniform": s.bleedUniform,
        "show_images_outline": s.showImagesOutline,
        "highlight_substituted_glyphs": s.highlightSubstitutedGlyphs,
        "grid_size": s.gridSize,
        "grid_color": s.gridColor,
        "paper_color": s.paperColor,
        "simulate_colored_paper": s.simulateColoredPaper,
        "transparency_flattener_preset": s.transparencyFlattenerPreset.rawValue,
        "discard_white_overprint": s.discardWhiteOverprint,
    ]
}

private func advancedView(_ a: Advanced) -> [String: Any] {
    return [
        "print_as_bitmap": a.printAsBitmap,
        "overprint_flattener_preset": a.overprintFlattenerPreset.rawValue,
    ]
}

private func colorManagementView(_ c: ColorManagement) -> [String: Any] {
    return [
        "document_profile": c.documentProfile,
        "color_handling": c.colorHandling.rawValue,
        "printer_profile": c.printerProfile,
        "rendering_intent": c.renderingIntent.rawValue,
        "preserve_rgb_numbers": c.preserveRgbNumbers,
    ]
}

private func graphicsView(_ g: Graphics) -> [String: Any] {
    return [
        "flatness": g.flatness,
        "font_download": g.fontDownload.rawValue,
        "postscript_level": g.postscriptLevel.rawValue,
        "data_format": g.dataFormat.rawValue,
        "compatible_gradient_printing": g.compatibleGradientPrinting,
        "raster_effects_resolution": g.rasterEffectsResolution,
    ]
}

private func inkOverrideView(_ ink: InkOverride) -> [String: Any] {
    return [
        "name": ink.name,
        "print": ink.print,
        "frequency": ink.frequency,
        "angle": ink.angle,
        "dot_shape": ink.dotShape.rawValue,
    ]
}

private func outputView(_ o: Output) -> [String: Any] {
    return [
        "mode": o.mode.rawValue,
        "emulsion": o.emulsion.rawValue,
        "image_polarity": o.imagePolarity.rawValue,
        "printer_resolution": o.printerResolution,
        "convert_spot_to_process": o.convertSpotToProcess,
        "overprint_black": o.overprintBlack,
        "inks": o.inks.map(inkOverrideView),
    ]
}

private func marksAndBleedView(_ m: MarksAndBleed) -> [String: Any] {
    return [
        "all_printer_marks": m.allPrinterMarks,
        "trim_marks": m.trimMarks,
        "registration_marks": m.registrationMarks,
        "color_bars": m.colorBars,
        "page_information": m.pageInformation,
        "printer_mark_type": m.printerMarkType.rawValue,
        "trim_mark_weight": m.trimMarkWeight,
        "mark_offset": m.markOffset,
        "use_document_bleed": m.useDocumentBleed,
        "bleed_top": m.bleedTop,
        "bleed_right": m.bleedRight,
        "bleed_bottom": m.bleedBottom,
        "bleed_left": m.bleedLeft,
    ]
}

private func printPreferencesView(_ p: PrintPreferences) -> [String: Any] {
    return [
        "preset_name": p.presetName,
        "printer_name": p.printerName ?? NSNull(),
        "copies": p.copies,
        "collate": p.collate,
        "reverse_order": p.reverseOrder,
        "artboard_range_mode": p.artboardRangeMode.rawValue,
        "artboard_range": p.artboardRange,
        "ignore_artboards": p.ignoreArtboards,
        "skip_blank_artboards": p.skipBlankArtboards,
        "media_size": p.mediaSize.rawValue,
        "media_width": p.mediaWidth,
        "media_height": p.mediaHeight,
        "orientation": p.orientation.rawValue,
        "auto_rotate": p.autoRotate,
        "transverse": p.transverse,
        "print_layers": p.printLayers.rawValue,
        "placement_x": p.placementX,
        "placement_y": p.placementY,
        "scaling_mode": p.scalingMode.rawValue,
        "custom_scale": p.customScale,
        "tile_overlap_h": p.tileOverlapH,
        "tile_overlap_v": p.tileOverlapV,
        "tile_range": p.tileRange,
        "marks_and_bleed": marksAndBleedView(p.marksAndBleed),
        "output": outputView(p.output),
        "graphics": graphicsView(p.graphics),
        "color_management": colorManagementView(p.colorManagement),
        "advanced": advancedView(p.advanced),
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
            "editing_target_is_mask": false,
        ]
    }
    let doc = m.document
    let hasMask = selectionHasMask(doc)
    let first = firstMask(doc)
    // OPACITY.md §Preview interactions: `editing_target_is_mask`
    // reflects whether mask-editing mode is active, so
    // OPACITY_PREVIEW / MASK_PREVIEW can show a persistent
    // highlight on the current editing target.
    let editingMask: Bool = {
        if case .mask = m.editingTarget { return true }
        return false
    }()
    return [
        "selection_has_mask": hasMask,
        "selection_mask_clip": first?.clip ?? false,
        "selection_mask_invert": first?.invert ?? false,
        "selection_mask_linked": first?.linked ?? true,
        "editing_target_is_mask": editingMask,
    ]
}
