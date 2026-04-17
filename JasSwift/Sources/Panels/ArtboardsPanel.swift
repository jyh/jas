/// Artboards panel menu definition (placeholder).

public enum ArtboardsPanel {
    public static let label = "Artboards"

    public static func menuItems() -> [PanelMenuItem] {
        [.action(label: "Close Artboards", command: "close_panel")]
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
