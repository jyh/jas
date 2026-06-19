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
            layout.closePanel(addr)
        case "new_symbol", "place_instance", "delete_symbol_action":
            guard let m = model else { return }
            dispatchSymbolAction(cmd, model: m)
        default:
            break
        }
    }

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        false
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

    /// Gather every existing element id (layers + master store) so a
    /// freshly minted id avoids collisions. Mirrors the `makeInstance`
    /// gather + the Rust `existing_ids` walk (operands stay opaque:
    /// only Group/Layer children are recursed).
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

    /// Mint a collision-free id (retry up to 100x), or nil.
    private static func mint(_ existing: Set<String>) -> String? {
        for _ in 0..<100 {
            let c = generateElementId()
            if !existing.contains(c) { return c }
        }
        return nil
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
        case "new_symbol":
            // Enabled only when exactly ONE whole element (kind=.all;
            // not a control-point sub-selection) is selected, mirroring
            // makeInstance.
            let doc = model.document
            let sorted = doc.selection.sorted {
                $0.path.lexicographicallyPrecedes($1.path)
            }
            guard sorted.count == 1, let es = sorted.first else { return }
            guard es.kind == .all else { return }
            let path = es.path
            var existing = existingIds(doc)
            guard let masterId = mint(existing) else { return }
            existing.insert(masterId)
            guard let refId = mint(existing) else { return }
            // The Controller mutator self-brackets one undo step via editDocument.
            let controller = Controller(model: model)
            controller.makeSymbol(path, masterId: masterId, refId: refId)
            // Keep the new master panel-selected so Place / Delete target
            // it immediately. makeSymbol keeps an existing id as the
            // master key (assign-on-create), so resolve which id actually
            // became the master from the in-place instance's target.
            var resolved = masterId
            if case .live(.reference(let r)) = model.document.tryGetElement(path) {
                resolved = r.target.id
            }
            setSelectedSymbol(model, resolved)

        case "place_instance":
            guard let masterId = selectedSymbol(model) else { return }
            let existing = existingIds(model.document)
            guard let refId = mint(existing) else { return }
            // The Controller mutator self-brackets one undo step via editDocument.
            let controller = Controller(model: model)
            controller.placeInstance(masterId: masterId, refId: refId)

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
