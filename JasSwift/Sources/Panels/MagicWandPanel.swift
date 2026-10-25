/// Magic Wand panel menu definition.
///
/// Menu items follow `transcripts/MAGIC_WAND_TOOL.md` §Panel: just
/// "Reset Magic Wand" and "Close Magic Wand". Reset runs
/// `workspace/actions.yaml: reset_magic_wand_panel`, which writes the
/// nine options back to their defaults.

public enum MagicWandPanel {
    /// Source of truth is workspace/panels/magic_wand.yaml's `menu:`
    /// block (review #15); the generic reader builds the items from the
    /// bundle.
    public static func menuItems() -> [PanelMenuItem] {
        menuItemsFromYaml("magic_wand_panel_content")
    }

    /// Any command but Close runs as its YAML action (Reset writes the nine
    /// options back in the panel and in `state.magic_wand_*`). Until
    /// 2026-10-25 every other command was dropped here, so the panel menu's
    /// Reset did nothing on the Mac.
    public static func dispatch(_ cmd: String, addr: PanelAddr, layout: inout WorkspaceLayout,
                                model: Model? = nil) {
        if cmd == "close_panel" { layoutApply(&layout, opClosePanel(addr)); return }
        guard let model = model, !cmd.isEmpty else { return }
        runYamlActionByName(cmd, params: [:], model: model)
    }
}
