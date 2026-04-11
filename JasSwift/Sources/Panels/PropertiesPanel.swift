/// Properties panel menu definition.

public enum PropertiesPanel {
    public static let label = "Properties"

    public static func menuItems() -> [PanelMenuItem] {
        [.action(label: "Close Properties", command: "close_panel")]
    }

    public static func dispatch(_ cmd: String, addr: PanelAddr, layout: inout WorkspaceLayout) {
        switch cmd {
        case "close_panel": layout.closePanel(addr)
        default: break
        }
    }

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        false
    }
}
