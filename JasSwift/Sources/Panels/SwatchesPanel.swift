/// Swatches panel menu definition.

public enum SwatchesPanel {
    public static let label = "Swatches"

    public static func menuItems() -> [PanelMenuItem] {
        [.action(label: "Close Swatches", command: "close_panel")]
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
