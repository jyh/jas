/// Symbols panel menu definition + native action arms (SYMBOLS.md §8, P3
/// first slice).
///
/// The panel body (master row list + footer) is rendered by the generic
/// YAML interpreter from `workspace/panels/symbols.yaml`; this module
/// provides the hamburger-menu wiring (Window-menu integration) and the
/// NATIVE action arms for the mutating symbol ops.
///
/// The mutating ops (new_symbol / place_instance / delete_symbol_action)
/// mint ids by the value-in-op rule (like `makeInstance` in JasCommands)
/// and call the shared symbol Controller ops, so the YAML actions are
/// `log` stubs. ``dispatchSymbolAction(_:model:)`` is the single native
/// entry point, called both from the hamburger menu (`dispatch`) and from
/// the panel-footer button clicks (`YamlPanelBodyView.dispatchYamlAction`
/// native fast-path). Mirrors the Rust lead's `dispatch_action` symbol
/// intercept in `interpreter::renderer`.

import Foundation

public enum SymbolsPanel {
    /// Source of truth is workspace/panels/symbols.yaml's `menu:` block;
    /// the generic reader builds the items from the bundle.
    public static func menuItems() -> [PanelMenuItem] {
        menuItemsFromYaml("symbols_panel_content")
    }

    /// Dispatch a menu command. `close_panel` is handled locally; the
    /// symbol mutations route through the native ``dispatchSymbolAction``
    /// arm (which reads the panel-selected master from the store, mints
    /// ids, and calls the Controller ops).
    public static func dispatch(_ cmd: String, addr: PanelAddr,
                                 layout: inout WorkspaceLayout,
                                 model: Model? = nil) {
        switch cmd {
        case "close_panel":
            layoutApply(&layout, opClosePanel(addr))
        case "delete_symbol_action":
            guard let m = model else { return }
            dispatchSymbolAction(cmd, model: m)
        // Their YAML says what they do (`doc.new_symbol`, `doc.place_instance`).
        case "new_symbol", "place_instance":
            guard let m = model else { return }
            LayersPanel.dispatchYamlAction(cmd, model: m)
        default:
            break
        }
    }

    // MARK: - Native action arms (value-in-op; modeled on makeInstance)

    /// The StateStore scope id for the Symbols panel. The shared
    /// `symbols_panel_select` action writes `selected_symbol` here via
    /// `set_panel_state { panel: symbols }` (the effect appends the
    /// `_panel_content` suffix), and the YAML `panel.selected_symbol`
    /// read resolves against this same active-panel scope. The native
    /// arms read / write the identical key so all paths agree.
    private static let scopeId = "symbols_panel_content"

    /// Read the panel-selected master id from the shared store (or nil).
    /// Keys on the stable master id so the selection survives instance
    /// placement / deletion. A null sentinel (NSNull, from the YAML init)
    /// reads back as no selection.
    static func selectedSymbol(_ model: Model) -> String? {
        model.stateStore.getPanel(scopeId, "selected_symbol") as? String
    }

    /// Write the panel-selected master id (or clear it). Bumps the panel
    /// state version so the row highlight / footer-button binds refresh.
    /// `setPanel` is a no-op when the scope does not yet exist, so seed it
    /// first — the native arms can fire before the panel has rendered (the
    /// arm minted the only master, so nothing initialized the scope yet).
    private static func setSelectedSymbol(_ model: Model, _ id: String?) {
        if !model.stateStore.hasPanel(scopeId) {
            let defaults = WorkspaceData.load()?.panelStateDefaults(scopeId) ?? [:]
            model.stateStore.initPanel(scopeId, defaults: defaults)
        }
        model.stateStore.setPanel(scopeId, "selected_symbol", id ?? NSNull())
        model.panelStateVersion &+= 1
    }

    /// The one value-in-op op Make Symbol applies (`doc.new_symbol` in
    /// actions.yaml, SYMBOLS.md §7), or nil unless exactly ONE element is
    /// wholly selected, or the mint fails: `make_symbol` of its path with a
    /// minted master id and reference id. Rust `symbols_host::new_symbol_ops`.
    static func newSymbolOps(_ doc: Document) -> [[String: Any]]? {
        guard doc.selection.count == 1, let es = doc.selection.first, es.kind == .all,
              let ids = mint(doc, 2) else { return nil }
        return [["op": "make_symbol", "path": es.path, "master_id": ids[0], "ref_id": ids[1]]]
    }

    /// The master a Make Symbol at `path` made, read AFTER the op: an element
    /// that had an id keeps it as the master's. Rust
    /// `symbols_host::new_symbol_master`.
    static func newSymbolMaster(_ doc: Document, path: [Int]) -> String? {
        if case .live(.reference(let r)) = doc.tryGetElement(path) { return r.target.id }
        return nil
    }

    /// The one value-in-op op Place Instance applies (`doc.place_instance` in
    /// actions.yaml): `place_instance` of `master` with a freshly minted
    /// reference id (SYMBOLS.md §7), or nil when the mint fails. Rust
    /// `symbols_host::place_instance_ops`.
    static func placeInstanceOps(_ doc: Document, master: String) -> [[String: Any]]? {
        guard let refId = mint(doc, 1)?[0] else { return nil }
        return [["op": "place_instance", "master_id": master, "ref_id": refId]]
    }

    /// Mint `count` collision-free element ids against every id already in
    /// `doc` (layer forest, the operands a live compound shape owns, and the
    /// master store — `Document.elementIds`) through THE ONE MINT LOOP.
    /// nil means the caller mints nothing and aborts.
    private static func mint(_ doc: Document, _ count: Int) -> [String]? {
        var existing = doc.elementIds
        return mintUniqueIds(count, existing: &existing,
                             mint: { generateElementId() })
    }

    /// Native intercept for the Symbols panel ops. Each takes a single
    /// snapshot so the op is one undo step, then returns. Mirrors the
    /// Rust `dispatch_action` symbol arms.
    ///
    /// - `new_symbol`: promote the single whole-element canvas selection
    ///   to a master (mint master_id + ref_id, snapshot, makeSymbol),
    ///   keeping the new master panel-selected.
    /// - `place_instance`: place a new instance of the panel-selected
    ///   master (mint ref_id, snapshot, placeInstance).
    /// - `delete_symbol_action`: delete the panel-selected master.
    ///   Reference-aware: when the master still has live instances, warn
    ///   first via the synchronous orphan confirm (Swift's native modal
    ///   precedent — same wording as the YAML dialog); confirming deletes
    ///   it, Cancel does nothing. With no instances it deletes silently.
    ///   Clears the panel selection after a delete.
    static func dispatchSymbolAction(_ action: String, model: Model) {
        switch action {
        case "delete_symbol_action":
            guard let masterId = selectedSymbol(model) else { return }
            let usage = DependencyIndex.build(model.document)
                .rdeps[masterId]?.count ?? 0
            if usage > 0 {
                // Reference-aware: warn before leaving live instances
                // empty. Swift uses the synchronous native modal (the
                // same precedent as the element-delete orphan confirm),
                // with verbatim wording matching the YAML dialog. Cancel
                // does nothing (no snapshot, no delete).
                if !confirmOrphaningDeleteSymbol(usage) { return }
            }
            // The Controller mutator self-brackets one undo step via editDocument.
            let controller = Controller(model: model)
            controller.deleteSymbol(masterId: masterId)
            setSelectedSymbol(model, nil)

        default:
            break
        }
    }

    /// Present the synchronous reference-aware delete confirm for the
    /// Symbols panel. Body text is the cross-language-pinned
    /// `orphanWarningBody` ("Deleting will leave N live instance(s)
    /// empty.") so it reads identically to the YAML dialog. "Cancel" is
    /// the safe default; "Delete" is the destructive confirming button.
    /// Returns true when the user confirms. Mirrors JasCommands'
    /// `confirmOrphaningDelete`.
    static func confirmOrphaningDeleteSymbol(_ count: Int) -> Bool {
        JasCommands.confirmOrphaningDelete(count)
    }
}
