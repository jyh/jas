/// Layers panel menu definition.

public enum LayersPanel {
    public static let label = "Layers"

    public static func menuItems() -> [PanelMenuItem] {
        [
            .action(label: "New Layer...", command: "new_layer"),
            .action(label: "New Group", command: "new_group"),
            .separator,
            .action(label: "Hide All Layers", command: "toggle_all_layers_visibility"),
            .action(label: "Outline All Layers", command: "toggle_all_layers_outline"),
            .action(label: "Lock All Layers", command: "toggle_all_layers_lock"),
            .separator,
            .action(label: "Enter Isolation Mode", command: "enter_isolation_mode"),
            .action(label: "Exit Isolation Mode", command: "exit_isolation_mode"),
            .separator,
            .action(label: "Flatten Artwork", command: "flatten_artwork"),
            .action(label: "Collect in New Layer", command: "collect_in_new_layer"),
            .separator,
            .action(label: "Close Layers", command: "close_panel"),
        ]
    }

    public static func dispatch(_ cmd: String, addr: PanelAddr, layout: inout WorkspaceLayout, model: Model? = nil) {
        switch cmd {
        case "close_panel": layout.closePanel(addr)
        case "toggle_all_layers_visibility",
             "toggle_all_layers_outline",
             "toggle_all_layers_lock":
            if let m = model {
                dispatchYamlAction(cmd, model: m)
            }
        // Tier-3 stubs: log only until document model is implemented.
        case "new_layer", "new_group",
             "enter_isolation_mode", "exit_isolation_mode",
             "flatten_artwork", "collect_in_new_layer":
            #if DEBUG
            print("[LayersPanel] dispatch: \(cmd)")
            #endif
        default: break
        }
    }

    /// Dispatch a layers action through the compiled YAML effects (Phase 3).
    /// Wires snapshot/doc.set/doc.delete_at/doc.clone_at/doc.insert_after
    /// as platformEffects on the active Model. Injects
    /// active_document rollups and (if supplied) panel.layers_panel_selection
    /// into the evaluation context — needed by Group B actions.
    public static func dispatchYamlAction(_ actionName: String, model: Model,
                                           panelSelection: [[Int]] = []) {
        guard let ws = WorkspaceData.load(),
              let actions = ws.data["actions"] as? [String: Any],
              let actionDef = actions[actionName] as? [String: Any],
              let effects = actionDef["effects"] as? [Any]
        else { return }

        // Build active_document view from model.document.layers
        var topLevelLayers: [[String: Any]] = []
        var topLevelLayerPaths: [[String: Any]] = []
        for (i, layer) in model.document.layers.enumerated() {
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
        }
        let activeDoc: [String: Any] = [
            "top_level_layers": topLevelLayers,
            "top_level_layer_paths": topLevelLayerPaths,
            "layers_panel_selection_count": panelSelection.count,
        ]
        // Inject panel.layers_panel_selection as list of __path__ markers
        // for Group B actions (delete/duplicate_layer_selection).
        let selectionMarkers: [[String: Any]] = panelSelection.map {
            ["__path__": $0]
        }
        let panel: [String: Any] = [
            "layers_panel_selection": selectionMarkers,
        ]
        let ctx: [String: Any] = [
            "active_document": activeDoc,
            "panel": panel,
        ]

        // Platform handlers
        let snapshotHandler: PlatformEffect = { _, _, _ in
            model.snapshot()
            return nil
        }
        let docSetHandler: PlatformEffect = { value, callCtx, _ in
            guard let spec = value as? [String: Any] else { return nil }
            let pathExpr = (spec["path"] as? String) ?? ""
            let fields = (spec["fields"] as? [String: Any]) ?? [:]
            let pathVal = evaluate(pathExpr, context: callCtx)
            guard case .path(let indices) = pathVal,
                  indices.count == 1,
                  indices[0] >= 0 && indices[0] < model.document.layers.count
            else { return nil }
            let idx = indices[0]
            let layer = model.document.layers[idx]
            var newVisibility = layer.visibility
            var newLocked = layer.locked
            var newName = layer.name
            for (dotted, exprV) in fields {
                let exprStr = (exprV as? String) ?? ""
                let v = evaluate(exprStr, context: callCtx)
                switch dotted {
                case "common.visibility":
                    if case .string(let s) = v {
                        switch s {
                        case "invisible": newVisibility = .invisible
                        case "outline": newVisibility = .outline
                        case "preview": newVisibility = .preview
                        default: break
                        }
                    }
                case "common.locked":
                    if case .bool(let b) = v { newLocked = b }
                case "name":
                    if case .string(let s) = v { newName = s }
                default: break
                }
            }
            var newLayers = model.document.layers
            newLayers[idx] = Layer(
                name: newName, children: layer.children,
                opacity: layer.opacity, transform: layer.transform,
                locked: newLocked, visibility: newVisibility
            )
            model.document = Document(layers: newLayers,
                                       selectedLayer: model.document.selectedLayer,
                                       selection: model.document.selection)
            return nil
        }
        // Phase 3 Group B: delete/clone/insert. Returned Layer flows
        // through ctx via as:-binding. Swift's [String: Any] ctx holds
        // Layer values directly (no serde roundtrip needed).
        let docDeleteAtHandler: PlatformEffect = { value, callCtx, _ in
            guard let pathExpr = value as? String else { return nil }
            let pathVal = evaluate(pathExpr, context: callCtx)
            guard case .path(let indices) = pathVal,
                  indices.count == 1,
                  indices[0] >= 0 && indices[0] < model.document.layers.count
            else { return nil }
            let idx = indices[0]
            let removed = model.document.layers[idx]
            var newLayers = model.document.layers
            newLayers.remove(at: idx)
            model.document = Document(layers: newLayers,
                                       selectedLayer: model.document.selectedLayer,
                                       selection: model.document.selection)
            return removed
        }
        let docCloneAtHandler: PlatformEffect = { value, callCtx, _ in
            guard let pathExpr = value as? String else { return nil }
            let pathVal = evaluate(pathExpr, context: callCtx)
            guard case .path(let indices) = pathVal,
                  indices.count == 1,
                  indices[0] >= 0 && indices[0] < model.document.layers.count
            else { return nil }
            // Swift Layer is a value type; copy is implicit
            return model.document.layers[indices[0]]
        }
        let docInsertAfterHandler: PlatformEffect = { value, callCtx, _ in
            guard let spec = value as? [String: Any] else { return nil }
            let pathExpr = (spec["path"] as? String) ?? ""
            let pathVal = evaluate(pathExpr, context: callCtx)
            guard case .path(let indices) = pathVal,
                  indices.count == 1
            else { return nil }
            // element: may be a raw Layer (from clone_at) or a bare
            // identifier referring to a ctx-bound Layer.
            let newElement: Layer?
            if let layer = spec["element"] as? Layer {
                newElement = layer
            } else if let name = spec["element"] as? String,
                      let layer = callCtx[name] as? Layer {
                newElement = layer
            } else {
                newElement = nil
            }
            guard let elem = newElement else { return nil }
            let insertIdx = min(indices[0] + 1, model.document.layers.count)
            var newLayers = model.document.layers
            newLayers.insert(elem, at: insertIdx)
            model.document = Document(layers: newLayers,
                                       selectedLayer: model.document.selectedLayer,
                                       selection: model.document.selection)
            return nil
        }

        let platformEffects: [String: PlatformEffect] = [
            "snapshot": snapshotHandler,
            "doc.set": docSetHandler,
            "doc.delete_at": docDeleteAtHandler,
            "doc.clone_at": docCloneAtHandler,
            "doc.insert_after": docInsertAfterHandler,
        ]

        let store = StateStore()
        runEffects(effects, ctx: ctx, store: store,
                   actions: actions, platformEffects: platformEffects)
    }

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        false
    }
}
