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
        case "promote_to_concept":
            // CONCEPTS.md §10 — the fitter / promote (the inverse of expand).
            // Detect + replace the single selected raw shape with a Generated.
            promote(model: model)
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

    /// Native intercept for `apply_concept_operation` (CONCEPTS.md §9): apply a
    /// named concept operation to the single selected Generated instance. The
    /// operation's effect is RESOLVED here, at production time — look the
    /// operation up in the registry by `opId`, evaluate its `set:` expressions
    /// with the instance's CURRENT params bound under `param`, and bake the
    /// resulting `changes` map into the op (value-in-op). Routed through
    /// `opApply` inside the one-undo `withTxn`/`nameTxn` bracket; replay merges
    /// `changes` and never re-evaluates. Mirrors the Rust `apply_concept_operation`
    /// dispatch arm. No-op unless exactly one Generated element is selected and
    /// the resolved changes are non-empty.
    public static func applyOperation(model: Model, opId: String) {
        let doc = model.document
        guard doc.selection.count == 1, let sel = doc.selection.first else { return }
        let path = sel.path
        guard case .live(.generated(let gen)) = doc.tryGetElement(path) else { return }

        // Look up the concept + operation, then resolve its `set:` expressions
        // over the instance's current params → the concrete `changes` map.
        guard let concept = WorkspaceData.load()?.concept(gen.conceptId),
              let ops = concept["operations"] as? [[String: Any]],
              let operation = ops.first(where: { ($0["id"] as? String) == opId }),
              let set = operation["set"] as? [String: Any] else { return }

        let ctx: [String: Any] = ["param": gen.params]
        var changes: [String: Any] = [:]
        for (name, exprV) in set {
            guard let src = exprV as? String else { continue }
            if case .number(let n) = evaluate(src, context: ctx) {
                changes[name] = n
            }
        }
        guard !changes.isEmpty else { return }

        let op: [String: Any] = [
            "op": "apply_concept_operation",
            "path": path,
            "op_id": opId,
            "changes": changes,
        ]
        model.withTxn {
            model.nameTxn("apply_concept_operation")
            opApply(model, Controller(model: model), op)
        }
    }

    /// Native intercept for `promote_to_concept` (CONCEPTS.md §10 — the fitter /
    /// promote, the inverse of expand). Promote the single selected raw shape to
    /// a `Generated` concept instance: extract the element's WORLD-space vertices
    /// (bake any element transform into the points so the fitter sees world
    /// space), try each registered concept's `fitter` expression over them (bound
    /// under `shape.points`) in sorted-id order, and on the FIRST match split its
    /// flat result `[params..., cx, cy, rotation]` into the concept params (first
    /// K, by declared order) and a placement transform (`translate(cx,cy) ·
    /// rotate(rot)`). Everything is baked into the op value-in-op and routed
    /// through `opApply` in the one-undo `withTxn`/`nameTxn` bracket; a no-match
    /// (or a non-Polygon/Polyline selection) is a silent no-op. Mirrors the Rust
    /// `promote_to_concept` dispatch arm.
    public static func promote(model: Model) {
        let doc = model.document
        guard doc.selection.count == 1, let sel = doc.selection.first else { return }
        let path = sel.path
        guard let elem = doc.tryGetElement(path) else { return }

        // Only a Polygon / Polyline carries promotable vertices in v1.
        let rawPoints: [(Double, Double)]
        switch elem {
        case .polygon(let p): rawPoints = p.points
        case .polyline(let p): rawPoints = p.points
        default: return
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
        guard let registry = WorkspaceData.load()?.concepts() else { return }
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
        guard let pick = chosen else { return }  // nothing matched: no-op

        // Placement: translate(cx,cy) * rotate(rot) — rotate then translate.
        let t = Transform.translate(pick.cx, pick.cy)
            .multiply(Transform.rotate(pick.rot))
        let op: [String: Any] = [
            "op": "promote_to_concept",
            "path": path,
            "concept_id": pick.conceptId,
            "params": pick.params,
            "transform": [t.a, t.b, t.c, t.d, t.e, t.f],
        ]
        model.withTxn {
            model.nameTxn("promote_to_concept")
            opApply(model, Controller(model: model), op)
        }
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
