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
            layout.closePanel(addr)
        default:
            guard let m = model else { return }
            let abSel = (m.stateStore.getPanelState("artboards")["artboards_panel_selection"] as? [Any])?
                .compactMap { $0 as? String } ?? []
            LayersPanel.dispatchYamlAction(
                cmd, model: m,
                artboardsPanelSelection: abSel
            )
        }
    }

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        false
    }
}
