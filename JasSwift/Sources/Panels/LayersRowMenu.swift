import Foundation

/// The Layers row's context menu as the Mac tree draws and runs it (STATUS-jas
/// row 141 part 3): layers.yaml's `context_menu:` on `lp_tree`, in the scope
/// the dock renders the panel with, plus the row bound as `node` by
/// ``WidgetEvent/rowBinding`` (the copy the forms runner also uses). The view
/// draws ``entries`` and runs a pick through ``pick(_:model:onDialogWrite:onDialogOpened:onDialogClosed:)``,
/// the engine's door, so the yaml's own `enabled_when` and the dispatch-path
/// guards (the last-layer rule and the orphan gate) apply to it as to every
/// other route. Nothing here is Mac-specific; the view keeps only the drawing.
struct LayersRowMenu {
    static let panelId = "layers_panel_content"

    /// The node that declares `context_menu:` (`lp_tree`).
    let holder: [String: Any]
    /// The panel's render scope with this row bound.
    let scope: [String: Any]

    /// The menu of row `path`, or nil when the panel, its holder or the row
    /// is missing (a row that is not drawn has no menu).
    static func at(_ path: ElementPath, model: Model) -> LayersRowMenu? {
        guard let ws = WorkspaceData.load(), let panel = ws.panel(panelId),
              let holder = findHolder(panel["content"]) else { return nil }
        if !model.stateStore.hasPanel(panelId) {
            model.stateStore.initPanel(panelId, defaults: ws.panelStateDefaults(panelId))
        }
        var scope = buildPanelBodyContext(ws: ws, model: model, contentId: panelId,
                                          opacityPanel: OpacityPanelState())
        guard case .success(let (name, data)) = WidgetEvent.rowBinding(holder, scope: scope, row: path) else {
            return nil
        }
        scope[name] = data
        return LayersRowMenu(holder: holder, scope: scope)
    }

    /// Row 142's rule, which is layers.yaml's since row 257 D3: the row's
    /// `secondary_press` behaviour makes a row that is not panel-selected the
    /// sole panel selection, and does nothing on a selected row, so the menu
    /// acts on the right row. The shell sends the event on the secondary
    /// press, before the menu is built, and decides nothing itself. It runs
    /// through the engine's door in the row's scope (the row's container is
    /// the holder's `do:`), so the answer is the door's: `committed`, `inert`
    /// (on a selected row), or nil when the row is not drawn.
    @discardableResult
    static func secondaryPress(_ path: ElementPath, model: Model) -> WidgetEvent.Result? {
        guard let menu = at(path, model: model),
              let row = menu.holder["do"] as? [String: Any] else { return nil }
        return PanelWidgetEvents(model: model, panelId: panelId, scope: menu.scope)
            .behavior(row, event: "secondary_press")
    }

    /// The entries as a shell draws them (``WidgetEvent/contextMenuEntries``).
    var entries: [WidgetEvent.ContextMenuEntry] {
        WidgetEvent.contextMenuEntries(holder, scope: scope)
    }

    /// Run the item at yaml `index` through the door. The dialog callbacks are
    /// the dock's, so an item that opens a dialog (Options for Layer...) opens
    /// the yaml dialog as the panel menu's item does.
    @discardableResult
    func pick(_ index: Int, model: Model,
              onDialogWrite: ((String, Any?) -> Void)? = nil,
              onDialogOpened: (() -> Void)? = nil,
              onDialogClosed: (() -> Void)? = nil) -> WidgetEvent.Result {
        PanelWidgetEvents(model: model, panelId: Self.panelId, scope: scope,
                          onDialogWrite: onDialogWrite,
                          onDialogOpened: onDialogOpened,
                          onDialogClosed: onDialogClosed)
            .contextMenuItem(holder, index: index)
    }

    /// The first node under `node` that declares `context_menu:`.
    private static func findHolder(_ node: Any?) -> [String: Any]? {
        if let a = node as? [Any] {
            for c in a { if let f = findHolder(c) { return f } }
            return nil
        }
        guard let d = node as? [String: Any] else { return nil }
        if d["context_menu"] != nil { return d }
        for k in ["children", "do"] { if let f = findHolder(d[k]) { return f } }
        return nil
    }
}
