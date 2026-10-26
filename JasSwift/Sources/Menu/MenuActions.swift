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
    /// The model verbs whose YAML says what they do (`doc.op`): the menu runs
    /// the declared action through ``LayersPanel/dispatchYamlAction``, as the
    /// engine's door and the web menu do.
    static let yamlVerbs = ["unlock_all", "hide_selection", "show_all", "lock", "select_all",
                            "group", "ungroup", "ungroup_all", "make_instance", "promote_to_concept"]

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

    /// Object > Make Instance's two value-in-op ops, or nil (a no-op) unless
    /// exactly ONE whole element (kind=.all) is selected and two ids could be
    /// minted. Make Instance is an OFFSET REFERENCE (SYMBOLS.md: "offset like
    /// Make Instance"), never Make Symbol: `create_reference` to the selected
    /// element, then `move_selection` by `offset` (the YAML's own number). The
    /// ids are minted HERE, before the ops, through THE ONE MINT LOOP, so the
    /// journal replays to the same ids. The YAML's `doc.make_instance` applies
    /// them (``LayersPanel``). Rust `menu_native::make_instance_ops`.
    static func makeInstanceOps(_ doc: Document, offset: Double) -> [[String: Any]]? {
        guard doc.selection.count == 1, let es = doc.selection.first, es.kind == .all else { return nil }
        // Two distinct ids, collision-free against every id already in the
        // document (see `Document.elementIds`).
        var existing = doc.elementIds
        guard let ids = mintUniqueIds(2, existing: &existing, mint: { generateElementId() })
        else { return nil }
        return [
            ["op": "create_reference", "target_path": es.path, "target_id": ids[0], "ref_id": ids[1]],
            ["op": "move_selection", "dx": offset, "dy": offset],
        ]
    }
}
