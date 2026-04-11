/// Stroke panel menu definition.

public enum StrokePanel {
    public static let label = "Stroke"

    public static func menuItems() -> [PanelMenuItem] {
        [.action(label: "Close Stroke", command: "close_panel")]
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
