/// Magic Wand panel menu definition.
///
/// Menu items follow `transcripts/MAGIC_WAND_TOOL.md` §Panel: just
/// "Reset Magic Wand" and "Close Magic Wand". The reset action routes
/// through the yaml-driven renderer dispatch (see
/// `workspace/actions.yaml: reset_magic_wand_panel`), which writes the
/// nine `magic_wand_*` keys back to their state defaults.

public enum MagicWandPanel {
    public static func menuItems() -> [PanelMenuItem] {
        [
            .action(label: "Reset Magic Wand", command: "reset_magic_wand_panel"),
            .separator,
            .action(label: "Close Magic Wand", command: "close_panel"),
        ]
    }

    public static func dispatch(_ cmd: String, addr: PanelAddr, layout: inout WorkspaceLayout) {
        switch cmd {
        case "close_panel": layout.closePanel(addr)
        // reset_magic_wand_panel flows through the yaml-driven
        // renderer dispatch path.
        default: break
        }
    }

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        false
    }
}
