import Foundation

/// Model-pure Object / Edit menu verbs, extracted from ``JasCommands`` so the
/// SAME implementation is reachable from two callers: the live menu (which has
/// only a focused, optional ``Model``) and the cross-language ACTION corpus
/// runner (which drives a constructed ``Model`` directly). The menu and the
/// corpus MUST share one implementation — otherwise the corpus would gate a
/// reimplementation, not the production code path. Each handler takes a
/// non-optional ``Model`` and constructs its own ``Controller`` internally,
/// preserving the prior `withTxn` bracketing, controller calls, and id minting
/// verbatim. Mirrors the Python `menu.menu` free functions the
/// `_MENU_NATIVE_HANDLERS` intercept routes to.
enum MenuActions {
    /// Select every element on the canvas. Non-undoable selection write through
    /// the Controller (matches the prior `selectAll()` body).
    static func selectAll(_ model: Model) {
        let controller = Controller(model: model)
        controller.selectAll()
    }

    /// Group the current selection under ONE undo step. `withTxn` opens ONE
    /// bracket; the Controller mutator's editDocument joins it. Mirrors Rust's
    /// `with_txn { Controller::... }`.
    static func groupSelection(_ model: Model) {
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        let controller = Controller(model: model)
        model.withTxn { controller.groupSelection() }
    }

    /// Ungroup the selected groups one level under ONE undo step.
    static func ungroupSelection(_ model: Model) {
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        let controller = Controller(model: model)
        model.withTxn { controller.ungroupSelection() }
    }

    /// Recursively flatten every unlocked group across all layers (locked
    /// groups are kept, but their children are still flattened). No-op (no undo
    /// step) when nothing changed. Undoable: editDocument self-brackets one undo
    /// step.
    static func ungroupAll(_ model: Model) {
        let doc = model.document
        var changed = false

        func flatten(_ children: [Element]) -> [Element] {
            var result: [Element] = []
            for child in children {
                switch child {
                case .group(let g) where !g.locked:
                    changed = true
                    result.append(contentsOf: flatten(g.children))
                case .group(let g):
                    // Locked group: recurse into children but keep the group
                    let newChildren = flatten(g.children)
                    result.append(.group(Group(children: newChildren,
                                               opacity: g.opacity, transform: g.transform,
                                               locked: g.locked)))
                default:
                    result.append(child)
                }
            }
            return result
        }

        let newLayers = doc.layers.map { layer in
            let newChildren = flatten(layer.children)
            return Layer(name: layer.name, children: newChildren,
                         opacity: layer.opacity, transform: layer.transform,
                         locked: layer.locked)
        }
        guard changed else { return }
        // Undoable: editDocument self-brackets one undo step.
        model.editDocument(Document(layers: newLayers,
                                  selectedLayer: doc.selectedLayer, selection: []))
    }

    /// Lock the current selection under ONE undo step.
    static func lockSelection(_ model: Model) {
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        let controller = Controller(model: model)
        model.withTxn { controller.lockSelection() }
    }

    /// Unlock every locked element under ONE undo step.
    static func unlockAll(_ model: Model) {
        let controller = Controller(model: model)
        model.withTxn { controller.unlockAll() }
    }

    /// Hide (set visibility=invisible) the current selection under ONE undo step.
    static func hideSelection(_ model: Model) {
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        let controller = Controller(model: model)
        model.withTxn { controller.hideSelection() }
    }

    /// Show every hidden element under ONE undo step.
    static func showAll(_ model: Model) {
        let controller = Controller(model: model)
        model.withTxn { controller.showAll() }
    }

    /// "Make Instance": the first user-facing way to create a live reference.
    /// Native UI glue (NOT a Controller op) that composes two already-pinned ops
    /// under ONE snapshot: `createReference` (the UI mints `targetId`/`refId`,
    /// value-in-op, with a collision-retry loop over existing ids — never minted
    /// in a Controller) then a move of the now-selected reference by
    /// `(pasteOffset, pasteOffset)`. The offset rides on the new reference's
    /// transform via `moveSelection`. Enabled only when exactly ONE whole element
    /// (kind=.all; not a control-point sub-selection) is selected. Mirrors Rust's
    /// `make_instance` menu_bar dispatch.
    static func makeInstance(_ model: Model) {
        let doc = model.document
        // `Selection` is a Set; sort by path lexicographically so the
        // single-selection pick is deterministic.
        let sorted = doc.selection.sorted {
            $0.path.lexicographicallyPrecedes($1.path)
        }
        guard sorted.count == 1, let es = sorted.first else { return }
        guard es.kind == .all else { return }
        let targetPath = es.path
        // Gather every existing element id so the freshly minted
        // targetId / refId can avoid collisions.
        var existing: Set<String> = []
        func gatherIds(_ elem: Element) {
            if let id = elem.id { existing.insert(id) }
            switch elem {
            case .group(let g): for c in g.children { gatherIds(c) }
            case .layer(let l): for c in l.children { gatherIds(c) }
            default: break
            }
        }
        for layer in doc.layers { gatherIds(.layer(layer)) }
        // Mint two distinct, collision-free ids (mirrors the artboard
        // mint loop in LayersPanel).
        func mint() -> String? {
            for _ in 0..<100 {
                let c = generateElementId()
                if !existing.contains(c) { return c }
            }
            return nil
        }
        guard let targetId = mint() else { return }
        existing.insert(targetId)
        guard let refId = mint() else { return }
        // createReference + offset-move under ONE snapshot = a single
        // undo step (offset rides on the new reference's transform via
        // moveSelection).
        // Both ops join ONE withTxn bracket = a single undo step (each
        // Controller mutator's editDocument joins it). Mirrors Rust's
        // with_txn around make_instance's two ops.
        let controller = Controller(model: model)
        model.withTxn {
            controller.createReference(targetPath, targetId: targetId, refId: refId)
            controller.moveSelection(dx: pasteOffset, dy: pasteOffset)
        }
    }
}
