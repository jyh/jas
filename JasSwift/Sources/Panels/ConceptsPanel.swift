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
    /// `log` stubs). One undo step via the Controller mutator.
    public static func dispatch(_ action: String, model: Model) {
        switch action {
        case "place_concept_instance":
            guard let conceptId = selectedConcept(model) else { return }
            let existing = existingIds(model.document)
            guard let elemId = mint(existing) else { return }
            // The Controller mutator self-brackets one undo step via editDocument.
            let controller = Controller(model: model)
            controller.placeConceptInstance(
                conceptId: conceptId,
                params: defaultParams(conceptId),
                elemId: elemId)
        default:
            break
        }
    }

    /// Native intercept for `set_concept_param` (the YAML action is a `log`
    /// stub): find the single selected Generated instance and write
    /// `params[name] = value` (one undo via the Controller). Mirrors the Rust
    /// `set_concept_param` dispatch arm. No-op unless exactly one Generated
    /// element is selected.
    public static func setParam(model: Model, name: String, value: Double) {
        let doc = model.document
        guard doc.selection.count == 1, let sel = doc.selection.first else { return }
        let path = sel.path
        guard case .live(.generated) = doc.tryGetElement(path) else { return }
        Controller(model: model).setConceptParam(path, name: name, value: value)
    }
}
