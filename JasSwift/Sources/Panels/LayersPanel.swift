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
             "toggle_all_layers_lock",
             "new_layer",
             "collect_in_new_layer",
             "enter_isolation_mode",
             "exit_isolation_mode":
            if let m = model {
                dispatchYamlAction(cmd, model: m)
            }
        // Tier-3 stubs: log only until document model is implemented.
        case "new_group",
             "flatten_artwork":
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
                                           panelSelection: [[Int]] = [],
                                           params: [String: Any] = [:],
                                           onCloseDialog: (() -> Void)? = nil) {
        guard let ws = WorkspaceData.load(),
              let actions = ws.data["actions"] as? [String: Any],
              let actionDef = actions[actionName] as? [String: Any],
              let effects = actionDef["effects"] as? [Any]
        else { return }

        // Build active_document view from model.document.layers
        var topLevelLayers: [[String: Any]] = []
        var topLevelLayerPaths: [[String: Any]] = []
        var layerNames: Set<String> = []
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
            layerNames.insert(layer.name)
        }
        // Phase 3 Group C: next_layer_name + new_layer_insert_index for new_layer
        var n = 1
        while layerNames.contains("Layer \(n)") { n += 1 }
        let nextLayerName = "Layer \(n)"
        let topLevelSelected = panelSelection
            .filter { $0.count == 1 }
            .map { $0[0] }
        let newLayerInsertIndex = topLevelSelected.min().map { $0 + 1 }
            ?? model.document.layers.count
        let activeDoc: [String: Any] = [
            "top_level_layers": topLevelLayers,
            "top_level_layer_paths": topLevelLayerPaths,
            "layers_panel_selection_count": panelSelection.count,
            "next_layer_name": nextLayerName,
            "new_layer_insert_index": newLayerInsertIndex,
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
            "param": params,
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
        // Phase 3 Group B: delete/clone/insert. The returned Element (top-
        // level Layer wrapped via Element.layer or a nested element) flows
        // through ctx via as:-binding. Swift's [String: Any] ctx holds
        // Element values directly (no serde roundtrip needed).
        let docDeleteAtHandler: PlatformEffect = { value, callCtx, _ in
            guard let pathExpr = value as? String else { return nil }
            let pathVal = evaluate(pathExpr, context: callCtx)
            guard case .path(let indices) = pathVal, !indices.isEmpty
            else { return nil }
            let doc = model.document
            // Top-level: delete from [Layer]; deeper: walk Element tree
            // via Document.deleteElement / getElement.
            if indices.count == 1 {
                guard indices[0] >= 0 && indices[0] < doc.layers.count
                else { return nil }
                let removed = Element.layer(doc.layers[indices[0]])
                var newLayers = doc.layers
                newLayers.remove(at: indices[0])
                model.document = Document(layers: newLayers,
                                           selectedLayer: doc.selectedLayer,
                                           selection: doc.selection)
                return removed
            }
            let removed = doc.getElement(indices)
            model.document = doc.deleteElement(indices)
            return removed
        }
        let docCloneAtHandler: PlatformEffect = { value, callCtx, _ in
            guard let pathExpr = value as? String else { return nil }
            let pathVal = evaluate(pathExpr, context: callCtx)
            guard case .path(let indices) = pathVal, !indices.isEmpty
            else { return nil }
            let doc = model.document
            if indices.count == 1 {
                guard indices[0] >= 0 && indices[0] < doc.layers.count
                else { return nil }
                return Element.layer(doc.layers[indices[0]])
            }
            return doc.getElement(indices)
        }
        let docInsertAfterHandler: PlatformEffect = { value, callCtx, _ in
            guard let spec = value as? [String: Any] else { return nil }
            let pathExpr = (spec["path"] as? String) ?? ""
            let pathVal = evaluate(pathExpr, context: callCtx)
            guard case .path(let indices) = pathVal, !indices.isEmpty
            else { return nil }
            // element: may be a raw Element (from clone_at/delete_at) or a
            // bare identifier referring to a ctx-bound Element.
            let newElement: Element?
            if let e = spec["element"] as? Element {
                newElement = e
            } else if let name = spec["element"] as? String,
                      let e = callCtx[name] as? Element {
                newElement = e
            } else {
                newElement = nil
            }
            guard let elem = newElement else { return nil }
            let doc = model.document
            // Top-level: insert into [Layer]; deeper: insert into the
            // Element tree via Document.insertElementAfter.
            if indices.count == 1 {
                guard case .layer(let layer) = elem else { return nil }
                let insertIdx = min(indices[0] + 1, doc.layers.count)
                var newLayers = doc.layers
                newLayers.insert(layer, at: insertIdx)
                model.document = Document(layers: newLayers,
                                           selectedLayer: doc.selectedLayer,
                                           selection: doc.selection)
            } else {
                model.document = doc.insertElementAfter(indices, element: elem)
            }
            return nil
        }

        // doc.wrap_in_layer: { paths, name } — append a new top-level
        // Layer containing the selected elements. Swift's Document.layers
        // is [Layer] (top-level Layers only), so this only supports a
        // top-level selection.
        let docWrapInLayerHandler: PlatformEffect = { value, callCtx, _ in
            guard let spec = value as? [String: Any] else { return nil }
            let pathsExpr = (spec["paths"] as? String) ?? "[]"
            let pathsVal = evaluate(pathsExpr, context: callCtx)
            guard case .list(let items) = pathsVal else { return nil }
            var normalized: [[Int]] = []
            for item in items {
                if let obj = item.value as? [String: Any],
                   let arr = obj["__path__"] as? [Int] {
                    normalized.append(arr)
                }
            }
            if normalized.isEmpty { return nil }
            normalized.sort { $0.lexicographicallyPrecedes($1) }
            // Top-level only
            let topLevelIndices = normalized.compactMap { p -> Int? in
                p.count == 1 ? p[0] : nil
            }
            if topLevelIndices.count != normalized.count { return nil }
            // Evaluate name expression
            let nameExpr = (spec["name"] as? String) ?? "'Layer'"
            let nameVal = evaluate(nameExpr, context: callCtx)
            let name: String
            if case .string(let s) = nameVal { name = s } else { name = "Layer" }
            // Collect children in document order
            let originalLayers = model.document.layers
            let childLayers = topLevelIndices.map { originalLayers[$0] }
            // Promote Layer -> Element (Layer's children are Elements;
            // collecting Layers into a layer means wrapping them as
            // inner structure). For now, wrap them as children using
            // Element.layer(inner).
            var children: [Element] = []
            for c in childLayers {
                children.append(Element.layer(c))
            }
            // Remove sources in descending order
            let sortedIndices = topLevelIndices.sorted(by: >)
            var newLayers = originalLayers
            for idx in sortedIndices {
                newLayers.remove(at: idx)
            }
            let newLayer = Layer(name: name, children: children)
            newLayers.append(newLayer)
            model.document = Document(layers: newLayers,
                                       selectedLayer: model.document.selectedLayer,
                                       selection: model.document.selection)
            return nil
        }

        // doc.create_layer: { name } — factory returning a new Layer
        // value. Bind via as: and insert with doc.insert_at.
        let docCreateLayerHandler: PlatformEffect = { value, callCtx, _ in
            guard let spec = value as? [String: Any] else { return nil }
            let nameExpr = (spec["name"] as? String) ?? "'Layer'"
            let nameVal = evaluate(nameExpr, context: callCtx)
            let name: String
            if case .string(let s) = nameVal { name = s } else { name = "Layer" }
            return Layer(name: name, children: [])
        }
        // doc.insert_at: { parent_path, index, element } — top-level insert
        // for now (nested insertion deferred to a later sub-tollgate).
        let docInsertAtHandler: PlatformEffect = { value, callCtx, _ in
            guard let spec = value as? [String: Any] else { return nil }
            let parentExpr = (spec["parent_path"] as? String) ?? "path()"
            let parentVal = evaluate(parentExpr, context: callCtx)
            guard case .path(let parentIndices) = parentVal,
                  parentIndices.isEmpty
            else { return nil }
            // Resolve index — may be a plain number or an expression string.
            var index = 0
            if let s = spec["index"] as? String {
                if case .number(let n) = evaluate(s, context: callCtx) {
                    index = Int(n)
                }
            } else if let n = spec["index"] as? Int {
                index = n
            }
            // Resolve element — raw Layer or ctx-bound identifier.
            let layer: Layer?
            if let l = spec["element"] as? Layer { layer = l }
            else if let name = spec["element"] as? String,
                    let l = callCtx[name] as? Layer { layer = l }
            else { layer = nil }
            guard let elem = layer else { return nil }
            let insertIdx = max(0, min(index, model.document.layers.count))
            var newLayers = model.document.layers
            newLayers.insert(elem, at: insertIdx)
            model.document = Document(layers: newLayers,
                                       selectedLayer: model.document.selectedLayer,
                                       selection: model.document.selection)
            return nil
        }

        // list_push: { target, value } — Phase 3 Group D: enter_isolation_mode.
        // Only target=panel.isolation_stack is handled here; writes the
        // evaluated Path value to model.layersIsolationStack.
        let listPushHandler: PlatformEffect = { value, callCtx, _ in
            guard let spec = value as? [String: Any] else { return nil }
            let target = (spec["target"] as? String) ?? ""
            guard target == "panel.isolation_stack" else { return nil }
            let valueExpr: String
            if let s = spec["value"] as? String { valueExpr = s }
            else { return nil }
            let val = evaluate(valueExpr, context: callCtx)
            guard case .path(let indices) = val else { return nil }
            model.layersIsolationStack.append(indices)
            return nil
        }
        // pop: "panel.isolation_stack" — Phase 3 Group D: exit_isolation_mode.
        let popHandler: PlatformEffect = { value, _, _ in
            guard let target = value as? String else { return nil }
            guard target == "panel.isolation_stack" else { return nil }
            if !model.layersIsolationStack.isEmpty {
                _ = model.layersIsolationStack.removeLast()
            }
            return nil
        }

        // close_dialog: invoke the onCloseDialog callback if supplied.
        // Layer Options uses this to dismiss the SwiftUI sheet after
        // layer_options_confirm commits its changes. No-op when the
        // caller didn't provide a handler.
        let closeDialogHandler: PlatformEffect = { _, _, _ in
            onCloseDialog?()
            return nil
        }

        var platformEffects: [String: PlatformEffect] = [
            "snapshot": snapshotHandler,
            "doc.set": docSetHandler,
            "doc.delete_at": docDeleteAtHandler,
            "doc.clone_at": docCloneAtHandler,
            "doc.insert_after": docInsertAfterHandler,
            "doc.insert_at": docInsertAtHandler,
            "doc.create_layer": docCreateLayerHandler,
            "doc.wrap_in_layer": docWrapInLayerHandler,
            "list_push": listPushHandler,
            "pop": popHandler,
        ]
        if onCloseDialog != nil {
            platformEffects["close_dialog"] = closeDialogHandler
        }

        let store = StateStore()
        runEffects(effects, ctx: ctx, store: store,
                   actions: actions, platformEffects: platformEffects)
    }

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        false
    }
}
