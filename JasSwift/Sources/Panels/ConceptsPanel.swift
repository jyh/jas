import Foundation

/// Native action arm for the Concepts panel (CONCEPTS.md §6). The
/// `concepts_panel_select` action is generic (`set_panel_state` writes
/// `selected_concept` into the shared store); `place_concept_instance` is a
/// `log` stub whose real work — mint a fresh element id (value-in-op), build a
/// Generated element from the panel-selected concept + its declared default
/// params, append + select — lives here, mirroring SymbolsPanel and the Rust
/// dispatch arm.
public enum ConceptsPanel {
    /// The StateStore scope id for the Concepts panel; the generic
    /// `set_panel_state { panel: concepts }` effect appends `_panel_content`,
    /// and the YAML `panel.selected_concept` read resolves against it.
    private static let scopeId = "concepts_panel_content"

    /// The panel-selected concept id from the shared store, or nil.
    static func selectedConcept(_ model: Model) -> String? {
        model.stateStore.getPanel(scopeId, "selected_concept") as? String
    }

    /// The concept's declared default params as a params object.
    static func defaultParams(_ conceptId: String) -> [String: Any] {
        guard let concept = WorkspaceData.load()?.concept(conceptId),
              let params = concept["params"] as? [[String: Any]] else { return [:] }
        var out: [String: Any] = [:]
        for p in params {
            if let name = p["name"] as? String, let def = p["default"] {
                out[name] = def
            }
        }
        return out
    }

    /// Gather every existing element id (layers + master store) so a freshly
    /// minted id avoids collisions. Mirrors SymbolsPanel.existingIds.
    private static func existingIds(_ doc: Document) -> Set<String> {
        var set: Set<String> = []
        func gather(_ elem: Element) {
            if let id = elem.id { set.insert(id) }
            switch elem {
            case .group(let g): for c in g.children { gather(c) }
            case .layer(let l): for c in l.children { gather(c) }
            default: break
            }
        }
        for layer in doc.layers { gather(.layer(layer)) }
        for master in doc.symbols { gather(master) }
        return set
    }

    private static func mint(_ existing: Set<String>) -> String? {
        for _ in 0..<100 {
            let c = generateElementId()
            if !existing.contains(c) { return c }
        }
        return nil
    }

    /// Native intercept for the Concepts panel ops (the YAML actions are
    /// `log` stubs). Routes through `opApply` so the placement JOURNALS as a
    /// real `place_concept_instance` op (value-in-op: the panel-selected
    /// concept id + its RESOLVED default params + the minted elem id),
    /// replayable like the sibling structural verbs. `withTxn` brackets the one
    /// undo step; the arm both mutates and records. Mirrors the Rust dispatch
    /// arm and the native-menu delete routing.
    public static func dispatch(_ action: String, model: Model) {
        switch action {
        case "place_concept_instance":
            guard let conceptId = selectedConcept(model) else { return }
            let existing = existingIds(model.document)
            guard let elemId = mint(existing) else { return }
            let op: [String: Any] = [
                "op": "place_concept_instance",
                "concept_id": conceptId,
                "params": defaultParams(conceptId),
                "elem_id": elemId,
            ]
            model.withTxn {
                model.nameTxn("place_concept_instance")
                opApply(model, Controller(model: model), op)
            }
        default:
            break
        }
    }

    /// Native intercept for `set_concept_param` (the YAML action is a `log`
    /// stub): find the single selected Generated instance and write
    /// `params[name] = value`. Routes through `opApply` so the edit JOURNALS as
    /// a real `set_concept_param` op (value-in-op: the RESOLVED path, param
    /// name, and committed value), replayable like the sibling property verbs.
    /// `withTxn` brackets the one undo step. Mirrors the Rust `set_concept_param`
    /// dispatch arm. No-op unless exactly one Generated element is selected.
    public static func setParam(model: Model, name: String, value: Double) {
        let doc = model.document
        guard doc.selection.count == 1, let sel = doc.selection.first else { return }
        let path = sel.path
        guard case .live(.generated) = doc.tryGetElement(path) else { return }
        let op: [String: Any] = [
            "op": "set_concept_param",
            "path": path,
            "name": name,
            "value": value,
        ]
        model.withTxn {
            model.nameTxn("set_concept_param")
            opApply(model, Controller(model: model), op)
        }
    }
}
