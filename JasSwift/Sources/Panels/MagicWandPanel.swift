/// Magic Wand panel menu definition.
///
/// Menu items follow `transcripts/MAGIC_WAND_TOOL.md` §Panel: just
/// "Reset Magic Wand" and "Close Magic Wand". The reset action routes
/// through the yaml-driven renderer dispatch (see
/// `workspace/actions.yaml: reset_magic_wand_panel`), which writes the
/// nine `magic_wand_*` keys back to their state defaults.

public enum MagicWandPanel {
    /// Source of truth is workspace/panels/magic_wand.yaml's `menu:`
    /// block (review #15); the generic reader builds the items from the
    /// bundle.
    public static func menuItems() -> [PanelMenuItem] {
        menuItemsFromYaml("magic_wand_panel_content")
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
