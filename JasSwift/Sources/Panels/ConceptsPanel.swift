import Foundation

/// The Concepts panel (CONCEPTS.md §6). The `concepts_panel_select` action is
/// generic (`set_panel_state` writes `selected_concept` into the shared store).
/// `place_concept_instance`, `set_concept_param`, `promote_to_concept` and
/// `apply_concept_operation` run their YAML (`doc.place_concept_instance`,
/// `doc.set_concept_param`, `doc.promote_to_concept`,
/// `doc.apply_concept_operation`); the ops those effects apply are built here,
/// as Rust's `symbols_host` builds them.
public enum ConceptsPanel {
    /// The panel's menu, from concepts.yaml's `menu:` block.
    public static func menuItems() -> [PanelMenuItem] {
        menuItemsFromYaml(scopeId)
    }

    /// A Concepts menu command: Close closes the panel, Place Instance runs its
    /// YAML through the dispatcher that holds the `doc.*` handlers, and Promote
    /// runs the native verb. Mirrors the Rust `panel_menu::dispatch_yaml_menu`.
    public static func menuDispatch(_ cmd: String, addr: PanelAddr,
                                    layout: inout WorkspaceLayout, model: Model? = nil) {
        if cmd == "close_panel" { layoutApply(&layout, opClosePanel(addr)); return }
        guard let model = model, !cmd.isEmpty else { return }
        switch cmd {
        case "place_concept_instance": LayersPanel.dispatchYamlAction(cmd, model: model)
        case "promote_to_concept": LayersPanel.dispatchYamlAction(cmd, model: model)
        default: runYamlActionByName(cmd, params: [:], model: model)
        }
    }

    /// The StateStore scope id for the Concepts panel; the generic
    /// `set_panel_state { panel: concepts }` effect appends `_panel_content`,
    /// and the YAML `panel.selected_concept` read resolves against it.
    private static let scopeId = "concepts_panel_content"

    /// The panel-selected concept id from the shared store, or nil.
    static func selectedConcept(_ model: Model) -> String? {
        model.stateStore.getPanel(scopeId, "selected_concept") as? String
    }

    /// Write the panel-selected concept id (or clear it) into the shared store,
    /// initializing the panel scope first when it does not yet exist. The
    /// generic `concepts_panel_select` action normally writes `selected_concept`
    /// via `set_panel_state`, but `setPanel` is a no-op on an absent scope (it is
    /// an optional-chaining write) and the native intercept can fire before the
    /// panel has rendered (e.g. the action corpus drives a fresh Model), so seed
    /// the scope from its YAML defaults first. Bumps the panel state version so
    /// the row highlight / footer-button binds refresh. Mirrors
    /// SymbolsPanel.setSelectedSymbol.
    static func setSelectedConcept(_ model: Model, _ id: String?) {
        if !model.stateStore.hasPanel(scopeId) {
            let defaults = WorkspaceData.load()?.panelStateDefaults(scopeId) ?? [:]
            model.stateStore.initPanel(scopeId, defaults: defaults)
        }
        model.stateStore.setPanel(scopeId, "selected_concept", id ?? NSNull())
        model.panelStateVersion &+= 1
    }

    /// A concept's declared default params (`params: [{name, default}]`) as a
    /// params object. Rust `symbols_host::concept_default_params`.
    static func defaultParams(_ concept: [String: Any]) -> [String: Any] {
        guard let params = concept["params"] as? [[String: Any]] else { return [:] }
        var out: [String: Any] = [:]
        for p in params {
            if let name = p["name"] as? String, let def = p["default"] {
                out[name] = def
            }
        }
        return out
    }

    /// Mint one collision-free element id against every id already in `doc`
    /// (layer forest, the operands a live compound shape owns, and the master
    /// store — `Document.elementIds`) through THE ONE MINT LOOP. nil means
    /// the caller mints nothing and aborts.
    private static func mint(_ doc: Document) -> String? {
        var existing = doc.elementIds
        return mintUniqueIds(1, existing: &existing,
                             mint: { generateElementId() })?[0]
    }

    /// The one value-in-op op Place Instance applies
    /// (`doc.place_concept_instance` in actions.yaml): `place_concept_instance`
    /// of `conceptId` with its declared default params and a freshly minted id
    /// (CONCEPTS.md §6), or nil when the registry does not declare the concept
    /// or the mint fails. Rust `symbols_host::place_concept_instance_ops`.
    static func placeConceptInstanceOps(_ doc: Document, conceptId: String) -> [[String: Any]]? {
        guard let concept = WorkspaceData.load()?.concept(conceptId),
              let elemId = mint(doc) else { return nil }
        return [[
            "op": "place_concept_instance",
            "concept_id": conceptId,
            "params": defaultParams(concept),
            "elem_id": elemId,
        ]]
    }

    /// A committed concept-param value as a finite number: a number, or a
    /// string that is exactly a decimal number (`9`, `-2.5`, `1e3`; never
    /// `inf`, `nan` or a padded one); anything else nil. Rust
    /// `symbols_host::concept_param_value`.
    static func paramValue(_ value: Value) -> Double? {
        let v: Double
        switch value {
        case .number(let n): v = n
        case .string(let s):
            guard s.range(of: #"^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$"#,
                          options: .regularExpression) != nil, let d = Double(s) else { return nil }
            v = d
        default: return nil
        }
        return v.isFinite ? v : nil
    }

    /// The one value-in-op op a parameter field's commit applies
    /// (`doc.set_concept_param` in actions.yaml): `set_concept_param` of the
    /// one selected generated instance (CONCEPTS.md §6.4), or nil unless
    /// `value` is a finite number (``paramValue(_:)``) and exactly one
    /// generated instance is selected. Rust `symbols_host::set_concept_param_ops`.
    static func setConceptParamOps(_ doc: Document, name: String, value: Value) -> [[String: Any]]? {
        guard let v = paramValue(value), doc.selection.count == 1,
              let path = doc.selection.first?.path,
              case .live(.generated) = doc.tryGetElement(path) else { return nil }
        return [["op": "set_concept_param", "path": path, "name": name, "value": v]]
    }

    /// The one value-in-op op a Concepts-panel operation button applies
    /// (`doc.apply_concept_operation` in actions.yaml, CONCEPTS.md §9), or nil
    /// unless exactly one Generated instance is selected and its concept
    /// declares the operation `opId` whose `set:` expressions, evaluated over
    /// the instance's CURRENT params (bound under `param`), give at least one
    /// number other than the param's current value: `apply_concept_operation`
    /// of its path with those numbers as `changes`, and nil for an operation
    /// that changes nothing (Remove Side at 3). Replay merges `changes` and
    /// never re-evaluates. Rust
    /// `symbols_host::apply_concept_operation_ops`.
    static func applyConceptOperationOps(_ doc: Document, opId: String) -> [[String: Any]]? {
        guard doc.selection.count == 1, let sel = doc.selection.first else { return nil }
        let path = sel.path
        guard case .live(.generated(let gen)) = doc.tryGetElement(path) else { return nil }

        // Look up the concept + operation, then resolve its `set:` expressions
        // over the instance's current params → the concrete `changes` map.
        guard let concept = WorkspaceData.load()?.concept(gen.conceptId),
              let ops = concept["operations"] as? [[String: Any]],
              let operation = ops.first(where: { ($0["id"] as? String) == opId }),
              let set = operation["set"] as? [String: Any] else { return nil }

        let ctx: [String: Any] = ["param": gen.params]
        var changes: [String: Any] = [:]
        for (name, exprV) in set {
            guard let src = exprV as? String else { continue }
            // A change equal to the current value is no change.
            if case .number(let n) = evaluate(src, context: ctx),
               (gen.params[name] as? NSNumber)?.doubleValue != n {
                changes[name] = n
            }
        }
        guard !changes.isEmpty else { return nil }
        return [[
            "op": "apply_concept_operation",
            "path": path,
            "op_id": opId,
            "changes": changes,
        ]]
    }

    /// The one op Object > Promote to Concept applies
    /// (`doc.promote_to_concept` in actions.yaml, CONCEPTS.md §10), or nil
    /// unless exactly one polygon or polyline is selected and a registered
    /// concept's fitter matches it: the element's transform baked into its
    /// points, concepts in sorted-id order, the first fitter returning k params
    /// + cx, cy, rot wins, placed at translate(cx, cy) · rotate(rot). Rust
    /// `symbols_host::promote_to_concept_ops`.
    static func promoteToConceptOps(_ doc: Document) -> [[String: Any]]? {
        guard doc.selection.count == 1, let sel = doc.selection.first else { return nil }
        let path = sel.path
        guard let elem = doc.tryGetElement(path) else { return nil }

        // Only a Polygon / Polyline carries promotable vertices in v1.
        let rawPoints: [(Double, Double)]
        switch elem {
        case .polygon(let p): rawPoints = p.points
        case .polyline(let p): rawPoints = p.points
        default: return nil
        }
        // Bake any element transform into the points so the fitter sees WORLD
        // space (the promoted instance re-places via its own transform).
        let pts: [(Double, Double)]
        if let t = elem.transform {
            pts = rawPoints.map { t.applyPoint($0.0, $0.1) }
        } else {
            pts = rawPoints
        }
        let pointsList: [[Double]] = pts.map { [$0.0, $0.1] }
        let ctx: [String: Any] = ["shape": ["points": pointsList]]

        // Try each registered concept's fitter in sorted-id order (a
        // deterministic first-match); keep the first that matches.
        guard let registry = WorkspaceData.load()?.concepts() else { return nil }
        var chosen: (conceptId: String, params: [String: Any],
                     cx: Double, cy: Double, rot: Double)?
        for id in registry.keys.sorted() {
            guard let concept = registry[id] as? [String: Any],
                  let fitter = concept["fitter"] as? String else { continue }
            // Null / non-list ⇒ no match for this concept.
            guard case .list(let items) = evaluate(fitter, context: ctx) else { continue }
            // The concept's declared params, in order — the first K result slots.
            let paramNames: [String] = (concept["params"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
            let k = paramNames.count
            guard items.count >= k + 3 else { continue }  // need params + cx,cy,rot
            let nums: [Double] = items.map { fitterNum($0.value) }
            var params: [String: Any] = [:]
            for (i, name) in paramNames.enumerated() { params[name] = nums[i] }
            chosen = (id, params, nums[k], nums[k + 1], nums[k + 2])
            break
        }
        guard let pick = chosen else { return nil }  // nothing matched: no-op

        // Placement: translate(cx,cy) * rotate(rot) — rotate then translate.
        let t = Transform.translate(pick.cx, pick.cy)
            .multiply(Transform.rotate(pick.rot))
        return [[
            "op": "promote_to_concept",
            "path": path,
            "concept_id": pick.conceptId,
            "params": pick.params,
            "transform": [t.a, t.b, t.c, t.d, t.e, t.f],
        ]]
    }
}

/// Read a Double out of an expression-list item (NSNumber / Double / Int),
/// defaulting to 0 (the non-crashing form), for the fitter result splitting.
private func fitterNum(_ v: Any) -> Double {
    if let d = v as? Double { return d }
    if let n = v as? NSNumber { return n.doubleValue }
    if let i = v as? Int { return Double(i) }
    return 0
}
