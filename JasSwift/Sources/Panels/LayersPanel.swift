/// Layers panel menu definition.

import AppKit
import Foundation

/// Convert a RESOLVED interpreter `Value` (the production eval result for a
/// `value` op param) into the op-literal `Any` the `opApply` arms parse via
/// `jsonToValue` — NSNumber for numbers/bools (the `isBool` discriminator is
/// preserved), String for strings/colors. A non-coercible value (null / list /
/// path / closure) returns nil, which the caller treats as "skip the op"
/// exactly like the old handlers' typed guards. Mirrors Rust's
/// `value_to_json` → `op_apply` jsonToValue round-trip (OP_LOG.md §9).
private func opLiteral(_ v: Value) -> Any? {
    switch v {
    case .bool(let b): return NSNumber(value: b)
    case .number(let n): return NSNumber(value: n)
    case .string(let s): return s
    case .color(let c): return c
    case .null, .list, .path, .closure: return nil
    }
}

public enum LayersPanel {
    /// Source of truth is workspace/panels/layers.yaml's `menu:` block
    /// (review #15); the generic reader builds the items from the bundle.
    /// The three all-layers rows carry `{{if …}}` label expressions
    /// (Hide/Show, Outline/Preview, Lock/Unlock); the menu view resolves
    /// them at render time via ``panelDynamicLabel``.
    public static func menuItems() -> [PanelMenuItem] {
        menuItemsFromYaml("layers_panel_content")
    }

    /// Resolve the three all-layers menu rows' `{{if …}}` label
    /// expressions against the document's any-layer rollups, so the menu
    /// shows "Hide All Layers" vs "Show All Layers" (etc.) per current
    /// state. Returns nil for commands without a dynamic label (the menu
    /// view then keeps the YAML label verbatim). Mirrors the Rust
    /// reference `layers_panel::dynamic_label`.
    public static func dynamicLabel(_ cmd: String, model: Model?) -> String? {
        guard let model = model else { return nil }
        let layers = model.document.layers
        switch cmd {
        case "toggle_all_layers_visibility":
            let anyVisible = layers.contains { $0.visibility != .invisible }
            return anyVisible ? "Hide All Layers" : "Show All Layers"
        case "toggle_all_layers_outline":
            let anyPreview = layers.contains { $0.visibility == .preview }
            return anyPreview ? "Outline All Layers" : "Preview All Layers"
        case "toggle_all_layers_lock":
            let anyUnlocked = layers.contains { !$0.locked }
            return anyUnlocked ? "Lock All Layers" : "Unlock All Layers"
        default:
            return nil
        }
    }

    public static func dispatch(_ cmd: String, addr: PanelAddr, layout: inout WorkspaceLayout, model: Model? = nil) {
        switch cmd {
        case "close_panel": layoutApply(&layout, opClosePanel(addr))
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

        runLayersPanelEffects(effects, actionName: actionName, ctx: ctx,
                              model: model, actions: actions,
                              dialogs: ws.data["dialogs"] as? [String: Any],
                              onCloseDialog: onCloseDialog)
    }

    /// Build the LayersPanel platform-effect registry and run `effects` through
    /// the shared `runEffects` pipeline, naming the owning transaction
    /// `actionName` (OP_LOG.md §9). Extracted from ``dispatchYamlAction`` so the
    /// registry construction has a single home; the production dispatch and the
    /// test seam (``runEffectsForTest``) share ONE registry, so a production-
    /// route test exercises exactly the same handlers a panel/menu gesture does.
    private static func runLayersPanelEffects(
        _ effects: [Any], actionName: String, ctx: [String: Any],
        model: Model, actions: [String: Any]?, dialogs: [String: Any]?,
        onCloseDialog: (() -> Void)?
    ) {
        // Platform handlers
        // OP_LOG.md Increment 1: the `snapshot` effect OPENS the undo
        // transaction (beginTxn) rather than pushing a bare checkpoint, so the
        // subsequent doc.* writes ride inside it via the enforced setDocument
        // path; the runEffects owner (the dispatch at the end) commits it once
        // (one undo step). Mirrors the Rust / Python / OCaml snapshot ->
        // begin_txn routing. beginTxn is a no-op while one is already open.
        let snapshotHandler: PlatformEffect = { _, _, _ in
            model.beginTxn()
            return nil
        }
        // OP_LOG.md §9: the verb33 doc.* handlers below route through the SHARED
        // `opApply` dispatcher (the same path the tool gestures use), so each
        // panel/menu gesture JOURNALS a real op (verb + RESOLVED params) into
        // the open transaction — matching Rust's `run_yaml_effect` arms which
        // build a resolved op JSON and call `op_apply`. The mutation is
        // byte-identical (opApply calls the SAME mutators these handlers used
        // before routing); the only added effect is `recordOp`. A shared
        // Controller is reused across handlers (it is stateless — a thin wrapper
        // over `model`). Mirrors `jas_dioxus` renderer.rs.
        let controller = Controller(model: model)
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
            // .replacing(...) preserves documentSetup / printPreferences
            // — passing them through the designated init silently drops
            // any field not enumerated, which would reset the user's
            // Print dialog state on every layer rename / lock toggle.
            model.editDocument(model.document.replacing(layers: newLayers))
            return nil
        }
        // Phase 3 Group B: delete/clone/insert. The returned Element (top-
        // level Layer wrapped via Element.layer or a nested element) flows
        // through ctx via as:-binding. Swift's [String: Any] ctx holds
        // Element values directly (no serde roundtrip needed).
        // doc.delete_at: path — OP_LOG.md §9 Phase P4. Routes through the SHARED
        // `opApply` dispatcher (`apply_delete_element_at`, the SAME
        // Document.deleteElement body). The optional `as:`-bound removed element
        // is resolved from the live doc BEFORE opApply mutates it (opApply has no
        // return value), preserving the Phase-3 return-binding contract.
        let docDeleteAtHandler: PlatformEffect = { value, callCtx, _ in
            guard let pathExpr = value as? String else { return nil }
            let pathVal = evaluate(pathExpr, context: callCtx)
            guard case .path(let indices) = pathVal, !indices.isEmpty
            else { return nil }
            let doc = model.document
            // Resolve the to-be-removed element for the optional `as:` binding
            // before the mutation (clamped/guarded exactly as the arm is).
            guard let removed = doc.tryGetElement(indices) else { return nil }
            opApply(model, controller, ["op": "delete_at", "path": indices])
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
        // doc.insert_after: { path, element } — OP_LOG.md §9 Phase P4. VALUE-IN-OP:
        // the resolved Element (from a preceding NON-JOURNALED `doc.clone_at`
        // binder) is carried VERBATIM in the op under `element` and routed
        // through the SHARED `opApply` dispatcher (`apply_insert_element_after`
        // → Document.insertElementAfter, which handles both top-level Layer and
        // nested inserts). A top-level path with a non-Layer element is a no-op
        // inside the arm (mirrors the old guard).
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
            // A top-level insert requires a Layer (the arm routes through
            // Document.insertElementAfter, which traps on a non-Layer at depth 1);
            // preserve the old handler's silent skip for that case.
            if indices.count == 1, case .layer = elem {} else if indices.count == 1 {
                return nil
            }
            opApply(model, controller,
                    ["op": "insert_after", "path": indices, "element": elem])
            return nil
        }

        // doc.wrap_in_layer: { paths, name } — OP_LOG.md §9 Phase P5. Append a new
        // top-level Layer containing the selected elements. Routes through the
        // SHARED `opApply` dispatcher (`apply_wrap_in_layer`, the SAME multi-step
        // collect/reverse-delete/append body) so the whole wrap JOURNALS as ONE
        // `wrap_in_layer` op. CRITICAL: the `name` expr is resolved against the
        // LIVE doc FIRST and journaled as the RESOLVED LITERAL — replay must NOT
        // re-derive a possibly-colliding name from the (now-mutated) tree. The
        // `__path__` markers are normalized to plain index arrays for the op.
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
            // Top-level only (Swift's top level is [Layer]).
            let topLevelIndices = normalized.compactMap { p -> Int? in
                p.count == 1 ? p[0] : nil
            }
            if topLevelIndices.count != normalized.count { return nil }
            // Resolve the name FIRST (against the live doc) and journal the LITERAL.
            let nameExpr = (spec["name"] as? String) ?? "'Layer'"
            let nameVal = evaluate(nameExpr, context: callCtx)
            let name: String
            if case .string(let s) = nameVal { name = s } else { name = "Layer" }
            opApply(model, controller,
                    ["op": "wrap_in_layer", "paths": normalized, "name": name])
            return nil
        }

        // doc.wrap_in_group: { paths } — OP_LOG.md §9 Phase P5. Wrap the elements
        // at the given paths into a new Group at the topmost source position.
        // Routes through the SHARED `opApply` dispatcher (`apply_wrap_in_group`)
        // so the multi-step mutation JOURNALS as ONE op carrying the RESOLVED
        // plain index arrays. All paths must share a parent and be nested
        // (depth >= 2); the arm collects in document order and inserts at the
        // topmost source index.
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
            // All paths must share the same parent and be nested (depth >= 2) —
            // the same same-parent invariant the arm assumes (it inserts the
            // group at the topmost source's parent).
            guard let first = normalized.first, first.count >= 2 else { return nil }
            let parentPath = Array(first.dropLast())
            for p in normalized where Array(p.dropLast()) != parentPath {
                return nil
            }
            opApply(model, controller, ["op": "wrap_in_group", "paths": normalized])
            return nil
        }

        // doc.unpack_group_at: path — OP_LOG.md §9 Phase P5. Replace a Group with
        // its children in place. Routes through the SHARED `opApply` dispatcher
        // (`apply_unpack_group_at`) so the multi-step extraction JOURNALS as ONE
        // op carrying the RESOLVED plain index path. A non-Group target (or a
        // top-level path) is a no-op inside the arm.
        let docUnpackGroupAtHandler: PlatformEffect = { value, callCtx, _ in
            guard let pathExpr = value as? String else { return nil }
            let pathVal = evaluate(pathExpr, context: callCtx)
            guard case .path(let indices) = pathVal, indices.count >= 2 else { return nil }
            opApply(model, controller, ["op": "unpack_group_at", "path": indices])
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
        // doc.insert_at: { parent_path, index, element } — OP_LOG.md §9 Phase P4.
        // VALUE-IN-OP: the resolved Layer (from a preceding NON-JOURNALED
        // `doc.create_layer` binder) is wrapped as an Element and carried VERBATIM
        // in the op under `element`, routed through the SHARED `opApply`
        // dispatcher (`apply_insert_element_at`, the SAME top-level [Layer] insert
        // body, which clamps the index). Top-level insert only (Swift's top level
        // is [Layer]).
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
            opApply(model, controller, [
                "op": "insert_at", "parent_path": parentIndices,
                "index": index, "element": Element.layer(elem),
            ])
            return nil
        }

        // list_push: { target, value } — special-case routing.
        // - panel.isolation_stack — Phase 3 Group D enter_isolation_mode;
        //   writes the evaluated Path value to model.layersIsolationStack.
        // - panel.recent_colors — Swatches Panel set_active_color
        //   effect; routes the hex through ColorPanel.pushRecentColor
        //   so model.recentColors stays the single source of truth, and
        //   mirrors the post-push list back into the calling panel's
        //   store so the recent strip updates immediately.
        let listPushHandler: PlatformEffect = { value, callCtx, store in
            guard let spec = value as? [String: Any] else { return nil }
            let target = (spec["target"] as? String) ?? ""
            let valueExpr: String
            if let s = spec["value"] as? String { valueExpr = s }
            else { return nil }
            if target == "panel.isolation_stack" {
                let val = evaluate(valueExpr, context: callCtx)
                guard case .path(let indices) = val else { return nil }
                model.layersIsolationStack.append(indices)
            } else if target == "panel.recent_colors" {
                let val = evaluate(valueExpr, context: callCtx)
                let hex: String?
                switch val {
                case .color(let c): hex = c
                case .string(let s) where s.hasPrefix("#"): hex = s
                default: hex = nil
                }
                if let h = hex, !h.isEmpty {
                    // Push to model — registered listeners
                    // (WorkspaceState.installRecentColorsBridge) mirror
                    // the new list into every panel.recent_colors that
                    // is initialized, so the calling panel and any
                    // sibling panel both update reactively.
                    ColorPanel.pushRecentColor(h, model: model)
                }
            }
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

        // doc.delete_selection — OP_LOG.md §9 Phase P4. Delete every currently-
        // selected element. Routes through the SHARED `opApply` dispatcher
        // (`apply_delete_selection`, the SAME Document.deleteSelection body) so
        // the deletion JOURNALS a real `delete_selection` op (targets carry the
        // pre-deletion selection ids). Reachable via the YAML orphan-confirm OK
        // actions; Swift's menu Delete/Cut use a native NSAlert confirm but route
        // the mutation through the SAME opApply verb (see JasCommands).
        let docDeleteSelectionHandler: PlatformEffect = { _, _, _ in
            opApply(model, controller, ["op": "delete_selection"])
            return nil
        }

        // make_compound_shape — replace the >=2 selected siblings with a single
        // live compound shape (UNION). A self-bracketing edit: makeCompoundShape
        // joins the txn the `snapshot` effect already opened and the runEffects
        // owner commits it. Mirrors the other apps' compound-shape verb.
        let makeCompoundShapeHandler: PlatformEffect = { _, _, _ in
            controller.makeCompoundShape()
            return nil
        }

        // doc.copy_selection_to_clipboard — non-document side effect (no op /
        // no journal): write the current selection's SVG to the system
        // pasteboard, mirroring the menu Cut copy-half. Paired with
        // doc.delete_selection in cut_orphan_confirm_ok.
        let docCopySelectionToClipboardHandler: PlatformEffect = { _, _, _ in
            let doc = model.document
            let elements = doc.selection.map { doc.getElement($0.path) }
            guard !elements.isEmpty else { return nil }
            let svg = documentToSvg(Document(layers: [Layer(children: elements)]))
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(svg, forType: .string)
            return nil
        }

        // ── Artboard handlers (ARTBOARDS.md §Menu, §Rename, §Reordering) ──
        //
        // OP_LOG.md §9 Phase P2/P3 — each evaluates its YAML exprs to RESOLVED
        // literals, builds the per-verb op JSON, and routes through the SHARED
        // `opApply` dispatcher (`apply_create_artboard` / `apply_set_artboard_*`
        // / ...), the SAME Artboard-helper mutation body these handlers used
        // before routing. Routing through `opApply` JOURNALS the edit as a real
        // op (one op per field-call, so artboard_options_confirm — which chains
        // ten set_artboard_field calls — lands as ten ops in its one txn) and
        // replays byte-identically. VALUE-IN-OP: create/duplicate mint the id
        // ONCE here (production entropy) and journal it as a LITERAL, so replay
        // reads it VERBATIM and never re-mints. Mirrors Rust renderer.rs.

        let docCreateArtboardHandler: PlatformEffect = { value, callCtx, _ in
            let spec = (value as? [String: Any]) ?? [:]
            let doc = model.document
            // Collision-retry id mint (production entropy) — the ONLY mint;
            // opApply replays the recorded literal and never mints.
            let existing = Set(doc.artboards.map(\.id))
            var id = ""
            for _ in 0..<100 {
                let c = generateArtboardId()
                if !existing.contains(c) { id = c; break }
            }
            guard !id.isEmpty else { return nil }
            // Build a RESOLVED flat `fields` object: the default name (derived
            // from the live doc) plus each YAML expr evaluated to a literal
            // (replay has no eval context). A `name` override in `spec` replaces
            // the default below.
            var fields: [String: Any] = ["name": nextArtboardName(doc.artboards)]
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
                if let literal = opLiteral(val) { fields[k] = literal }
            }
            opApply(model, controller,
                    ["op": "create_artboard", "id": id, "fields": fields])
            return id
        }

        let docDeleteArtboardByIdHandler: PlatformEffect = { value, callCtx, _ in
            guard let idExpr = value as? String else { return nil }
            let val = evaluate(idExpr, context: callCtx)
            guard case .string(let target) = val else { return nil }
            opApply(model, controller, ["op": "delete_artboard_by_id", "id": target])
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
            // Resolve the source up front: a missing source short-circuits
            // BEFORE we mint, so a no-op duplicate journals nothing (matching
            // the opApply arm). VALUE-IN-OP: mint new_id + derive name HERE
            // (the ONLY mint / derive) and journal both as literals.
            guard doc.artboards.contains(where: { $0.id == target }) else { return nil }
            let existing = Set(doc.artboards.map(\.id))
            var newId = ""
            for _ in 0..<100 {
                let c = generateArtboardId()
                if !existing.contains(c) { newId = c; break }
            }
            guard !newId.isEmpty else { return nil }
            opApply(model, controller, [
                "op": "duplicate_artboard", "id": target, "new_id": newId,
                "name": nextArtboardName(doc.artboards),
                "offset_x": ox, "offset_y": oy,
            ])
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
            guard let literal = opLiteral(val) else { return nil }
            opApply(model, controller, [
                "op": "set_artboard_field", "id": target,
                "field": field, "value": literal,
            ])
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
            guard let literal = opLiteral(val) else { return nil }
            opApply(model, controller, [
                "op": "set_artboard_options_field", "field": field, "value": literal,
            ])
            return nil
        }

        // The eight print-config field setters (PRINT.md §1–§6) — OP_LOG.md §9
        // Phase P1. Each evaluates its YAML `value` expr to a RESOLVED literal,
        // builds a `{op, field, value[, index]}` op JSON, and routes through the
        // SHARED `opApply` dispatcher (which calls `applyPrintConfigField`, the
        // SAME field-match + type-coerce + setDocument body the per-field
        // switches drove before P1). Routing through `opApply` JOURNALS the edit
        // as a real op so it replays byte-identically (checkpoint_equivalence).
        // `set_output_ink_field` also carries an `index`; a missing index on the
        // ink verb skips (preserving the old early-return). A type mismatch /
        // unknown field is a no-op inside `opApply` that journals nothing.
        // Factory: one closure per print-config verb, all sharing this body.
        func printConfigHandler(_ verb: String) -> PlatformEffect {
            return { value, callCtx, _ in
                guard let spec = value as? [String: Any],
                      let field = spec["field"] as? String else { return nil }
                let val: Value
                if let s = spec["value"] as? String {
                    val = evaluate(s, context: callCtx)
                } else if let b = spec["value"] as? Bool {
                    val = .bool(b)
                } else if let n = spec["value"] as? NSNumber {
                    val = .number(n.doubleValue)
                } else {
                    return nil
                }
                guard let literal = opLiteral(val) else { return nil }
                var op: [String: Any] = ["op": verb, "field": field, "value": literal]
                if verb == "set_output_ink_field" {
                    guard let indexNum = spec["index"] as? NSNumber else { return nil }
                    op["index"] = indexNum.intValue
                }
                opApply(model, controller, op)
                return nil
            }
        }
        let docSetDocumentSetupFieldHandler = printConfigHandler("set_document_setup_field")
        let docSetPrintPreferencesFieldHandler = printConfigHandler("set_print_preferences_field")
        let docSetMarksAndBleedFieldHandler = printConfigHandler("set_marks_and_bleed_field")
        let docSetOutputFieldHandler = printConfigHandler("set_output_field")
        let docSetOutputInkFieldHandler = printConfigHandler("set_output_ink_field")
        let docSetGraphicsFieldHandler = printConfigHandler("set_graphics_field")
        let docSetColorManagementFieldHandler = printConfigHandler("set_color_management_field")
        let docSetAdvancedFieldHandler = printConfigHandler("set_advanced_field")

        // geometry.export_pdf — PRINT.md §1B. Generates a PDF from the
        // current document and presents an NSSavePanel for the user to
        // pick the destination. filename_hint optional.
        let geometryExportPdfHandler: PlatformEffect = { value, _, _ in
            let spec = value as? [String: Any] ?? [:]
            let bytes = documentToPdf(model.document)
            let hint: String = (spec["filename_hint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? pdfFilenameForModel(model)
            let panel = NSSavePanel()
            panel.title = "Export to PDF"
            panel.nameFieldStringValue = hint
            panel.allowedContentTypes = [.pdf]
            panel.allowsOtherFileTypes = false
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            do {
                try bytes.write(to: url)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
            return nil
        }

        // doc.move_artboards_up / _down — OP_LOG.md §9 Phase P2. Resolve the ids
        // list expr to literal strings, build a `{op, ids}` op, and route
        // through the SHARED `opApply` dispatcher (`apply_move_artboards_up/down`,
        // the SAME swap-with-neighbor-skipping-selected body the inline reorder
        // ran). A boundary no-op (top/bottom artboard) journals nothing.
        func moveArtboards(verb: String, idsExpr: String, callCtx: [String: Any]) {
            let val = evaluate(idsExpr, context: callCtx)
            guard case .list(let items) = val else { return }
            let ids = items.compactMap { $0.value as? String }
            opApply(model, controller, ["op": verb, "ids": ids])
        }

        let docMoveArtboardsUpHandler: PlatformEffect = { value, callCtx, _ in
            guard let idsExpr = value as? String else { return nil }
            moveArtboards(verb: "move_artboards_up", idsExpr: idsExpr, callCtx: callCtx)
            return nil
        }

        let docMoveArtboardsDownHandler: PlatformEffect = { value, callCtx, _ in
            guard let idsExpr = value as? String else { return nil }
            moveArtboards(verb: "move_artboards_down", idsExpr: idsExpr, callCtx: callCtx)
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
            "doc.set_document_setup_field": docSetDocumentSetupFieldHandler,
            "doc.set_print_preferences_field": docSetPrintPreferencesFieldHandler,
            "doc.set_marks_and_bleed_field": docSetMarksAndBleedFieldHandler,
            "doc.set_output_field": docSetOutputFieldHandler,
            "doc.set_output_ink_field": docSetOutputInkFieldHandler,
            "doc.set_graphics_field": docSetGraphicsFieldHandler,
            "doc.set_color_management_field": docSetColorManagementFieldHandler,
            "doc.set_advanced_field": docSetAdvancedFieldHandler,
            "doc.move_artboards_up": docMoveArtboardsUpHandler,
            "doc.move_artboards_down": docMoveArtboardsDownHandler,
            "doc.delete_selection": docDeleteSelectionHandler,
            "doc.copy_selection_to_clipboard": docCopySelectionToClipboardHandler,
            "make_compound_shape": makeCompoundShapeHandler,
            "geometry.export_pdf": geometryExportPdfHandler,
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
        //
        // OP_LOG.md §9: name this panel-action dispatch site so the owning
        // transaction is stamped with the actions.yaml verb (`nameTxn`). The
        // verb33 doc.* handlers above route through `opApply` (which calls
        // `recordOp`), so the named transaction now journals a real op per
        // panel/menu gesture — matching Rust's `run_yaml_effects_named`.
        runEffects(effects, ctx: ctx, store: model.stateStore,
                   actions: actions,
                   dialogs: dialogs,
                   platformEffects: platformEffects,
                   model: model, actionName: actionName)
    }

    #if DEBUG
    /// TEST SEAM (OP_LOG.md §9 production-route proofs). Run an arbitrary
    /// `effects` list through the SAME LayersPanel platform-effect registry +
    /// `nameTxn` path the production ``dispatchYamlAction`` uses, so a
    /// production-route test drives the REAL handlers (not a hand-rolled copy).
    /// `ctx` defaults to empty; pass `params` for actions that read `param.*`.
    static func runEffectsForTest(
        actionName: String, effects: [Any], model: Model,
        params: [String: Any] = [:]
    ) {
        let ws = WorkspaceData.load()
        let ctx: [String: Any] = ["param": params]
        runLayersPanelEffects(effects, actionName: actionName, ctx: ctx,
                              model: model,
                              actions: ws?.data["actions"] as? [String: Any],
                              dialogs: ws?.data["dialogs"] as? [String: Any],
                              onCloseDialog: nil)
    }
    #endif

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        false
    }
}
