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
    ///
    /// PRESERVATION. Ungroup All speaks to group NESTING and to the selection.
    /// Everything else — a kept locked group's name, id, mask, blend mode and
    /// opacity flags; every layer's own attributes; the document's symbols,
    /// artboards, artboard options, Document Setup and print preferences — is a
    /// bystander and comes back untouched. That is structural here, not a
    /// checklist: the three writes below are clone-then-mutate
    /// (``Group/withChildren(_:)``, ``Layer/withChildren(_:)``,
    /// ``Document/replacing(layers:symbols:selectedLayer:selection:artboards:artboardOptions:documentSetup:printPreferences:)``),
    /// so there is no field list that can fall behind the structs.
    ///
    /// This body used to rebuild all three through their memberwise
    /// initializers naming 4 of 11, 5 of 11 and 3 of 8 fields — the Swift
    /// copy-site omission class (EDIT_SEMANTICS_FREEZE.md §3.1), landing at a
    /// shipping menu action. Ungroup All DELETED every artboard and reset the
    /// Print dialog; a kept locked group lost its name, id and mask. Rust never
    /// had the defect (`(**child).clone()` / `new_doc.layers = new_layers`,
    /// `controller.rs:2348,2376` — the same in-place shape). Gated by
    /// `UngroupAllPreservationTests`, which asserts BY VALUE.
    ///
    /// "Unlocked" is INHERITED (transcripts/LAYER_STRUCTURE.md §13): a Group
    /// inside a locked layer or a locked group is left alone, structure
    /// included, exactly as one with its own flag set is.
    static func ungroupAll(_ model: Model) {
        let doc = model.document
        var changed = false

        // `ancestorLocked` is the INHERITED half of the lock read
        // (transcripts/LAYER_STRUCTURE.md §13): a Group survives when its own
        // flag is set OR when anything it sits inside is locked. This is the
        // same `effectiveLocked` fold, threaded through a walk that already has
        // the ancestors in hand. It is NOT a new guard — `ungroup_all` always
        // read lock; §13 changed what the word means.
        func flatten(_ children: [Element], _ ancestorLocked: Bool) -> [Element] {
            var result: [Element] = []
            for child in children {
                switch child {
                case .group(let g) where !(ancestorLocked || g.locked):
                    changed = true
                    result.append(contentsOf: flatten(g.children, false))
                case .group(let g):
                    // Locked group: recurse into children but keep the group
                    result.append(.group(g.withChildren(flatten(g.children, true))))
                default:
                    result.append(child)
                }
            }
            return result
        }

        let newLayers = doc.layers.map { $0.withChildren(flatten($0.children, $0.locked)) }
        guard changed else { return }
        // Undoable: editDocument self-brackets one undo step.
        model.editDocument(doc.replacing(layers: newLayers, selection: []))
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
        // Mint two distinct, collision-free ids against every id already in the
        // document (see `Document.elementIds`), through THE ONE MINT LOOP.
        var existing = doc.elementIds
        guard let ids = mintUniqueIds(2, existing: &existing,
                                      mint: { generateElementId() })
        else { return }
        let (targetId, refId) = (ids[0], ids[1])
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
