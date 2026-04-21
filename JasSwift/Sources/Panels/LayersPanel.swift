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
             "exit_isolation_mode",
             "new_group",
             "flatten_artwork":
            if let m = model {
                dispatchYamlAction(cmd, model: m)
            }
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
                                           artboardsPanelSelection: [String] = [],
                                           params: [String: Any] = [:],
                                           onCloseDialog: (() -> Void)? = nil) {
        guard let ws = WorkspaceData.load(),
              let actions = ws.data["actions"] as? [String: Any],
              let actionDef = actions[actionName] as? [String: Any],
              let effects = actionDef["effects"] as? [Any]
        else { return }

        let activeDoc = buildActiveDocumentView(
            model: model,
            layersPanelSelection: panelSelection,
            artboardsPanelSelection: artboardsPanelSelection
        )
        // Inject panel.layers_panel_selection as list of __path__ markers
        // for Group B actions (delete/duplicate_layer_selection).
        let selectionMarkers: [[String: Any]] = panelSelection.map {
            ["__path__": $0]
        }
        let panel: [String: Any] = [
            "layers_panel_selection": selectionMarkers,
            "artboards_panel_selection": artboardsPanelSelection,
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
                                       selection: model.document.selection,
                                       artboards: model.document.artboards,
                                       artboardOptions: model.document.artboardOptions)
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
                                           selection: doc.selection,
                                           artboards: doc.artboards,
                                           artboardOptions: doc.artboardOptions)
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
                                           selection: doc.selection,
                                           artboards: doc.artboards,
                                           artboardOptions: doc.artboardOptions)
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
                                       selection: model.document.selection,
                                       artboards: model.document.artboards,
                                       artboardOptions: model.document.artboardOptions)
            return nil
        }

        // doc.wrap_in_group: { paths } — wrap the elements at the given
        // paths into a new Group at the topmost source position. All
        // paths must share the same parent and be at least depth 2
        // (children of a Layer or deeper); Swift's Document.layers is
        // [Layer], so top-level items cannot be wrapped in a Group.
        let docWrapInGroupHandler: PlatformEffect = { value, callCtx, _ in
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
            // All paths must share the same parent and be nested (depth >= 2).
            guard let first = normalized.first, first.count >= 2 else { return nil }
            let parentPath = Array(first.dropLast())
            for p in normalized where Array(p.dropLast()) != parentPath {
                return nil
            }
            // Collect the selected children in document order.
            let doc = model.document
            let children = normalized.map { doc.getElement($0) }
            // Delete all but the topmost in reverse, then replace the
            // topmost with a new Group containing every collected child.
            var newDoc = doc
            for p in normalized.dropFirst().reversed() {
                newDoc = newDoc.deleteElement(p)
            }
            let newGroup = Element.group(Group(children: children))
            newDoc = newDoc.replaceElement(first, with: newGroup)
            model.document = newDoc
            return nil
        }

        // doc.unpack_group_at: path — replace a Group with its children
        // in place. Path must point to a Group nested inside a Layer;
        // top-level paths (length 1) point to Layers, which cannot be
        // unpacked.
        let docUnpackGroupAtHandler: PlatformEffect = { value, callCtx, _ in
            guard let pathExpr = value as? String else { return nil }
            let pathVal = evaluate(pathExpr, context: callCtx)
            guard case .path(let indices) = pathVal, indices.count >= 2 else { return nil }
            let doc = model.document
            let elem = doc.getElement(indices)
            guard case .group(let g) = elem else { return nil }
            var newDoc = doc
            if g.children.isEmpty {
                newDoc = newDoc.deleteElement(indices)
            } else {
                // Replace the group with its first child, then insert
                // each subsequent child just after its predecessor.
                newDoc = newDoc.replaceElement(indices, with: g.children[0])
                var insertAfter = indices
                for child in g.children.dropFirst() {
                    newDoc = newDoc.insertElementAfter(insertAfter, element: child)
                    insertAfter[insertAfter.count - 1] += 1
                }
            }
            model.document = newDoc
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
                                       selection: model.document.selection,
                                       artboards: model.document.artboards,
                                       artboardOptions: model.document.artboardOptions)
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

        // ── Artboard handlers (ARTBOARDS.md §Menu, §Rename, §Reordering) ──
        //
        // All seven mirror the Python / Rust doc.* handlers. They mutate
        // model.document via the Artboard type helpers and commit via
        // reassigning model.document.

        let docCreateArtboardHandler: PlatformEffect = { value, callCtx, _ in
            let spec = (value as? [String: Any]) ?? [:]
            var doc = model.document
            let existing = Set(doc.artboards.map(\.id))
            var id = ""
            for _ in 0..<100 {
                let c = generateArtboardId()
                if !existing.contains(c) { id = c; break }
            }
            guard !id.isEmpty else { return nil }
            var ab = Artboard.defaultWithId(id)
            ab = ab.with(name: nextArtboardName(doc.artboards))
            for (k, v) in spec {
                let val: Value
                if let s = v as? String {
                    val = evaluate(s, context: callCtx)
                } else if let s = v as? Int {
                    val = .number(Double(s))
                } else if let s = v as? Double {
                    val = .number(s)
                } else if let b = v as? Bool {
                    val = .bool(b)
                } else {
                    continue
                }
                switch k {
                case "name": if case .string(let s) = val { ab = ab.with(name: s) }
                case "x": if case .number(let n) = val { ab = ab.with(x: n) }
                case "y": if case .number(let n) = val { ab = ab.with(y: n) }
                case "width": if case .number(let n) = val { ab = ab.with(width: n) }
                case "height": if case .number(let n) = val { ab = ab.with(height: n) }
                case "fill":
                    if case .string(let s) = val {
                        ab = ab.with(fill: ArtboardFill.fromCanonical(s))
                    } else if case .color(let s) = val {
                        ab = ab.with(fill: ArtboardFill.fromCanonical(s))
                    }
                case "show_center_mark": if case .bool(let b) = val { ab = ab.with(showCenterMark: b) }
                case "show_cross_hairs": if case .bool(let b) = val { ab = ab.with(showCrossHairs: b) }
                case "show_video_safe_areas": if case .bool(let b) = val { ab = ab.with(showVideoSafeAreas: b) }
                case "video_ruler_pixel_aspect_ratio":
                    if case .number(let n) = val { ab = ab.with(videoRulerPixelAspectRatio: n) }
                default: break
                }
            }
            doc = Document(
                layers: doc.layers,
                selectedLayer: doc.selectedLayer,
                selection: doc.selection,
                artboards: doc.artboards + [ab],
                artboardOptions: doc.artboardOptions
            )
            model.document = doc
            return ab.id
        }

        let docDeleteArtboardByIdHandler: PlatformEffect = { value, callCtx, _ in
            guard let idExpr = value as? String else { return nil }
            let val = evaluate(idExpr, context: callCtx)
            guard case .string(let target) = val else { return nil }
            let doc = model.document
            let newArtboards = doc.artboards.filter { $0.id != target }
            if newArtboards.count == doc.artboards.count { return nil }
            model.document = Document(
                layers: doc.layers,
                selectedLayer: doc.selectedLayer,
                selection: doc.selection,
                artboards: newArtboards,
                artboardOptions: doc.artboardOptions
            )
            return nil
        }

        let docDuplicateArtboardHandler: PlatformEffect = { value, callCtx, _ in
            let idExpr: String
            var ox = 20.0
            var oy = 20.0
            if let s = value as? String {
                idExpr = s
            } else if let m = value as? [String: Any] {
                idExpr = (m["id"] as? String) ?? ""
                if let s = m["offset_x"] as? String,
                   case .number(let n) = evaluate(s, context: callCtx) { ox = n }
                if let s = m["offset_y"] as? String,
                   case .number(let n) = evaluate(s, context: callCtx) { oy = n }
            } else {
                return nil
            }
            let idVal = evaluate(idExpr, context: callCtx)
            guard case .string(let target) = idVal else { return nil }
            let doc = model.document
            guard let source = doc.artboards.first(where: { $0.id == target }) else { return nil }
            let existing = Set(doc.artboards.map(\.id))
            var newId = ""
            for _ in 0..<100 {
                let c = generateArtboardId()
                if !existing.contains(c) { newId = c; break }
            }
            guard !newId.isEmpty else { return nil }
            let dup = Artboard(
                id: newId,
                name: nextArtboardName(doc.artboards),
                x: source.x + ox,
                y: source.y + oy,
                width: source.width,
                height: source.height,
                fill: source.fill,
                showCenterMark: source.showCenterMark,
                showCrossHairs: source.showCrossHairs,
                showVideoSafeAreas: source.showVideoSafeAreas,
                videoRulerPixelAspectRatio: source.videoRulerPixelAspectRatio
            )
            model.document = Document(
                layers: doc.layers,
                selectedLayer: doc.selectedLayer,
                selection: doc.selection,
                artboards: doc.artboards + [dup],
                artboardOptions: doc.artboardOptions
            )
            return nil
        }

        let docSetArtboardFieldHandler: PlatformEffect = { value, callCtx, _ in
            guard let spec = value as? [String: Any] else { return nil }
            let idExpr = (spec["id"] as? String) ?? ""
            guard let field = spec["field"] as? String else { return nil }
            let idVal = evaluate(idExpr, context: callCtx)
            guard case .string(let target) = idVal else { return nil }
            let val: Value
            if let s = spec["value"] as? String {
                val = evaluate(s, context: callCtx)
            } else if let b = spec["value"] as? Bool {
                val = .bool(b)
            } else if let n = spec["value"] as? Double {
                val = .number(n)
            } else if let i = spec["value"] as? Int {
                val = .number(Double(i))
            } else {
                return nil
            }
            let doc = model.document
            let newArtboards: [Artboard] = doc.artboards.map { ab in
                guard ab.id == target else { return ab }
                switch field {
                case "name": if case .string(let s) = val { return ab.with(name: s) }
                case "x": if case .number(let n) = val { return ab.with(x: n) }
                case "y": if case .number(let n) = val { return ab.with(y: n) }
                case "width": if case .number(let n) = val { return ab.with(width: n) }
                case "height": if case .number(let n) = val { return ab.with(height: n) }
                case "fill":
                    if case .string(let s) = val {
                        return ab.with(fill: ArtboardFill.fromCanonical(s))
                    }
                    if case .color(let s) = val {
                        return ab.with(fill: ArtboardFill.fromCanonical(s))
                    }
                case "show_center_mark":
                    if case .bool(let b) = val { return ab.with(showCenterMark: b) }
                case "show_cross_hairs":
                    if case .bool(let b) = val { return ab.with(showCrossHairs: b) }
                case "show_video_safe_areas":
                    if case .bool(let b) = val { return ab.with(showVideoSafeAreas: b) }
                case "video_ruler_pixel_aspect_ratio":
                    if case .number(let n) = val { return ab.with(videoRulerPixelAspectRatio: n) }
                default: break
                }
                return ab
            }
            model.document = Document(
                layers: doc.layers,
                selectedLayer: doc.selectedLayer,
                selection: doc.selection,
                artboards: newArtboards,
                artboardOptions: doc.artboardOptions
            )
            return nil
        }

        let docSetArtboardOptionsFieldHandler: PlatformEffect = { value, callCtx, _ in
            guard let spec = value as? [String: Any],
                  let field = spec["field"] as? String else { return nil }
            let val: Value
            if let s = spec["value"] as? String {
                val = evaluate(s, context: callCtx)
            } else if let b = spec["value"] as? Bool {
                val = .bool(b)
            } else {
                return nil
            }
            guard case .bool(let flag) = val else { return nil }
            let doc = model.document
            let newOpts: ArtboardOptions
            switch field {
            case "fade_region_outside_artboard":
                newOpts = ArtboardOptions(
                    fadeRegionOutsideArtboard: flag,
                    updateWhileDragging: doc.artboardOptions.updateWhileDragging
                )
            case "update_while_dragging":
                newOpts = ArtboardOptions(
                    fadeRegionOutsideArtboard: doc.artboardOptions.fadeRegionOutsideArtboard,
                    updateWhileDragging: flag
                )
            default: return nil
            }
            model.document = Document(
                layers: doc.layers,
                selectedLayer: doc.selectedLayer,
                selection: doc.selection,
                artboards: doc.artboards,
                artboardOptions: newOpts
            )
            return nil
        }

        func reorderArtboards(up: Bool, idsExpr: String, callCtx: [String: Any]) {
            let val = evaluate(idsExpr, context: callCtx)
            guard case .list(let items) = val else { return }
            let ids = items.compactMap { $0.value as? String }
            let selected = Set(ids)
            var abs = model.document.artboards
            var changed = false
            if up {
                for i in 0..<abs.count {
                    if !selected.contains(abs[i].id) { continue }
                    if i == 0 { continue }
                    if selected.contains(abs[i - 1].id) { continue }
                    abs.swapAt(i - 1, i)
                    changed = true
                }
            } else {
                for i in stride(from: abs.count - 1, through: 0, by: -1) {
                    if !selected.contains(abs[i].id) { continue }
                    if i + 1 >= abs.count { continue }
                    if selected.contains(abs[i + 1].id) { continue }
                    abs.swapAt(i, i + 1)
                    changed = true
                }
            }
            guard changed else { return }
            let doc = model.document
            model.document = Document(
                layers: doc.layers,
                selectedLayer: doc.selectedLayer,
                selection: doc.selection,
                artboards: abs,
                artboardOptions: doc.artboardOptions
            )
        }

        let docMoveArtboardsUpHandler: PlatformEffect = { value, callCtx, _ in
            guard let idsExpr = value as? String else { return nil }
            reorderArtboards(up: true, idsExpr: idsExpr, callCtx: callCtx)
            return nil
        }

        let docMoveArtboardsDownHandler: PlatformEffect = { value, callCtx, _ in
            guard let idsExpr = value as? String else { return nil }
            reorderArtboards(up: false, idsExpr: idsExpr, callCtx: callCtx)
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
            "doc.wrap_in_group": docWrapInGroupHandler,
            "doc.unpack_group_at": docUnpackGroupAtHandler,
            "doc.create_artboard": docCreateArtboardHandler,
            "doc.delete_artboard_by_id": docDeleteArtboardByIdHandler,
            "doc.duplicate_artboard": docDuplicateArtboardHandler,
            "doc.set_artboard_field": docSetArtboardFieldHandler,
            "doc.set_artboard_options_field": docSetArtboardOptionsFieldHandler,
            "doc.move_artboards_up": docMoveArtboardsUpHandler,
            "doc.move_artboards_down": docMoveArtboardsDownHandler,
            "list_push": listPushHandler,
            "pop": popHandler,
        ]
        if onCloseDialog != nil {
            platformEffects["close_dialog"] = closeDialogHandler
        }

        // Use the model's own StateStore so effects (open_dialog,
        // close_dialog, set_panel_state, and anything reading
        // panel / dialog scope via expressions) see the live app
        // state instead of a throwaway fresh store. Required for the
        // Artboards panel — open_artboard_options writes its dialog
        // state here and the DockPanelView bridge reads the
        // transition to show the overlay. ``dialogs`` must be
        // supplied for open_dialog to locate the dialog definition.
        let dialogs = ws.data["dialogs"] as? [String: Any]
        runEffects(effects, ctx: ctx, store: model.stateStore,
                   actions: actions,
                   dialogs: dialogs,
                   platformEffects: platformEffects)
    }

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        false
    }
}
