/// Artboards panel menu definition (ARTBOARDS.md).
///
/// The panel body (row list + footer) is rendered by the generic
/// YAML interpreter from `workspace/panels/artboards.yaml`; this
/// module provides the hamburger-menu wiring for the Window-menu
/// integration. Every artboard mutation flows through the YAML
/// action pipeline (`LayersPanel.dispatchYamlAction`) — the
/// `dispatch` function here only handles `close_panel`.

public enum ArtboardsPanel {
    /// Source of truth is workspace/panels/artboards.yaml's `menu:`
    /// block (review #15); the generic reader builds the items from the
    /// bundle. Phase-1-deferred entries (Convert to Artboards, Artboard
    /// Options, Rearrange) are grayed by the YAML action catalog's
    /// `enabled_when: false`.
    public static func menuItems() -> [PanelMenuItem] {
        menuItemsFromYaml("artboards_panel_content")
    }

    /// Dispatch a menu command. All artboard mutations route through
    /// the YAML action pipeline (`LayersPanel.dispatchYamlAction`),
    /// which reads the current Artboards-panel selection from the
    /// store so actions like `delete_artboards` see the user's
    /// checked rows. `close_panel` is handled locally.
    public static func dispatch(_ cmd: String, addr: PanelAddr,
                                 layout: inout WorkspaceLayout,
                                 model: Model? = nil) {
        switch cmd {
        case "close_panel":
            layoutApply(&layout, opClosePanel(addr))
        default:
            guard let m = model else { return }
            let abSel = (m.stateStore.getPanelState("artboards")["artboards_panel_selection"] as? [Any])?
                .compactMap { $0 as? String } ?? []
            // The menu dispatches a non-radio item by its bare action
            // (``menuItems(fromRaw:)``), so the item's declared `params`
            // are evaluated here, in the menu's own context, as Rust's
            // panel-menu pick and the web's do. Without it "Artboard
            // Options..." and "Rename" ran with no `artboard_id` (row 280).
            let entries = (WorkspaceData.load()?.panelMenuRaw("artboards_panel_content") ?? [])
                .compactMap { $0 as? [String: Any] }.filter { $0["action"] as? String == cmd }
            let declared = entries.count == 1 ? (entries[0]["params"] as? [String: Any]) ?? [:] : [:]
            let params = declared.isEmpty ? [:] : DialogWidgetActions.resolveParams(
                declared, context: panelMenuContext("artboards_panel_content", layout: layout, model: m))
            LayersPanel.dispatchYamlAction(
                cmd, model: m,
                artboardsPanelSelection: abSel,
                params: params
            )
        }
    }
}
