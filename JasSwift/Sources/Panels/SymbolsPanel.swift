/// Symbols panel menu definition and the ops its YAML effects apply
/// (SYMBOLS.md §8).
///
/// The panel body (master row list + footer) is rendered by the generic
/// YAML interpreter from `workspace/panels/symbols.yaml`; this module
/// provides the hamburger-menu wiring (Window-menu integration), the
/// value-in-op ops the `doc.*` effects apply (minting ids where a verb
/// needs them, as Rust's `symbols_host` does), and Delete Symbol's confirm
/// presenter (``runDeleteSymbol(_:confirm:)``). Since 2026-10-26 every
/// symbol verb runs its YAML.

import Foundation

public enum SymbolsPanel {
    /// Source of truth is workspace/panels/symbols.yaml's `menu:` block;
    /// the generic reader builds the items from the bundle.
    public static func menuItems() -> [PanelMenuItem] {
        menuItemsFromYaml("symbols_panel_content")
    }

    /// Dispatch a menu command. `close_panel` is handled locally; New Symbol
    /// and Place Instance run their YAML, and Delete Symbol runs its YAML
    /// through ``runDeleteSymbol(_:confirm:)``, which presents its confirm.
    public static func dispatch(_ cmd: String, addr: PanelAddr,
                                 layout: inout WorkspaceLayout,
                                 model: Model? = nil) {
        switch cmd {
        case "close_panel":
            layoutApply(&layout, opClosePanel(addr))
        case "delete_symbol_action":
            guard let m = model else { return }
            runDeleteSymbol(m)
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

    /// The one op Delete Symbol applies (`doc.delete_symbol` in actions.yaml,
    /// SYMBOLS.md §7), or nil unless `master` names a master in the store:
    /// `delete_symbol` of that id. Its instances stay in place, resolving to
    /// nothing. Rust `symbols_host::delete_symbol_ops`.
    static func deleteSymbolOps(_ doc: Document, master: String) -> [[String: Any]]? {
        guard doc.symbols.contains(where: { $0.id == master }) else { return nil }
        return [["op": "delete_symbol", "master_id": master]]
    }

    /// Delete Symbol, every Mac route (the panel's Delete button and its
    /// menu): actions.yaml `delete_symbol_action`. A master with live
    /// instances leaves `delete_symbol_orphan_confirm` open in the store,
    /// which the Mac presents AS its NSAlert (`confirm`, injectable for
    /// tests): the dialog is closed there, and a Delete runs
    /// `delete_symbol_orphan_confirm_ok`'s YAML with the dialog's `master` as
    /// `param.master`, exactly as the dialog's Delete button passes it.
    /// Otherwise the YAML deleted the master already, as ONE undo step.
    /// `JasCommands.runDeleteSelection`'s form.
    static func runDeleteSymbol(_ model: Model,
                                confirm: (Int) -> Bool = JasCommands.confirmOrphaningDelete) {
        LayersPanel.dispatchYamlAction("delete_symbol_action", model: model)
        guard model.stateStore.getDialogId() == "delete_symbol_orphan_confirm" else { return }
        let params = model.stateStore.getDialogParams() ?? [:]
        let count = (params["count"] as? NSNumber)?.intValue ?? 0
        model.stateStore.closeDialog()
        if confirm(count) {
            LayersPanel.dispatchYamlAction("delete_symbol_orphan_confirm_ok", model: model,
                                           params: ["master": params["master"] ?? NSNull()])
        }
    }
}
