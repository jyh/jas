/// Character panel menu definition (placeholder).
///
/// The Character panel itself is still being spec'd in `CHARACTER.md` /
/// `TSPAN.md`; this module provides the minimum scaffolding required
/// for the panel to appear in the default layout and the Window menu.

public enum CharacterPanel {
    public static let label = "Character"

    public static func menuItems() -> [PanelMenuItem] {
        [.action(label: "Close Character", command: "close_panel")]
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
