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
    /// The model-pure menu verbs, by action name: Rust `menu_native::VERBS`,
    /// in its order. ``run(_:_:)`` runs exactly these.
    /// `unlock_all`, `hide_selection`, `show_all`, `lock`, `select_all`, `group`,
    /// `ungroup` and `ungroup_all` left it 2026-10-25: their YAML is `doc.op`
    /// (the op layer by name), so the menu runs the declared action
    /// (``yamlVerbs``).
    static let verbs = ["make_instance"]

    /// The model verbs whose YAML says what they do (`doc.op`): the menu runs
    /// the declared action through ``LayersPanel/dispatchYamlAction``, as the
    /// engine's door and the web menu do.
    static let yamlVerbs = ["unlock_all", "hide_selection", "show_all", "lock", "select_all",
                            "group", "ungroup", "ungroup_all"]

    /// Run `action` on `model` if it is one of ``verbs``; `false` (nothing
    /// run) otherwise. Rust `menu_native::run`. The live menu (``JasCommands``)
    /// and the level-1 input-script runner both call it.
    @discardableResult
    static func run(_ action: String, _ model: Model) -> Bool {
        switch action {
        case "make_instance": makeInstance(model)
        default: return false
        }
        return true
    }

    /// Revert is offered only when there are changes AND a saved version to
    /// return to (an `Untitled-` document was never saved). Mirrors Rust
    /// `can_revert`, whose never-saved guard is "no saved SVG on the tab".
    static func canRevert(_ model: Model) -> Bool {
        model.isModified && !model.filename.hasPrefix("Untitled-")
    }

    /// Apply a confirmed Revert to the saved file's text: install the document
    /// Open gives (the root's sheet, the artboard invariant), not the bare
    /// codec read, as ONE undoable step, then mark the document clean. Returns
    /// whether anything changed. Mirrors Rust `apply_revert`. The menu's
    /// `revert()` keeps the confirmation alert and the file read, which cannot
    /// be driven from a test; this half is what the tests drive.
    @discardableResult
    static func applyRevert(_ model: Model, svg: String) -> Bool {
        guard canRevert(model) else { return false }
        // editDocument self-brackets one undo step.
        model.editDocument(documentForOpen(svg))
        model.markSaved()
        return true
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
