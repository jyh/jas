/// Properties panel menu definition.

public enum PropertiesPanel {
    /// Source of truth is workspace/panels/properties.yaml's `menu:`
    /// block (review #15); the generic reader builds the items from the
    /// bundle.
    public static func menuItems() -> [PanelMenuItem] {
        menuItemsFromYaml("properties_panel_content")
    }

    public static func dispatch(_ cmd: String, addr: PanelAddr, layout: inout WorkspaceLayout) {
        switch cmd {
        case "close_panel": layoutApply(&layout, opClosePanel(addr))
        default: break
        }
    }

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        false
    }
}
