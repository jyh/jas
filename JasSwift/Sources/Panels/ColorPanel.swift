/// Color panel menu definition.

public enum ColorPanel {
    public static let label = "Color"

    public static func menuItems() -> [PanelMenuItem] {
        [.action(label: "Close Color", command: "close_panel")]
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
