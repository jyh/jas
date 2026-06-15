/// Align panel menu definition.
///
/// Menu items follow `transcripts/ALIGN.md` §Panel menu: a
/// "Use Preview Bounds" toggle, a "Reset Panel" action, and
/// "Close Align". Each non-close command routes through
/// runYamlActionByName so the YAML actions catalog is the source of
/// truth for what the buttons do.

public enum AlignPanel {
    /// Source of truth is workspace/panels/align.yaml's `menu:` block
    /// (review #15); the generic reader builds the items from the bundle.
    public static func menuItems() -> [PanelMenuItem] {
        menuItemsFromYaml("align_panel_content")
    }

    public static func dispatch(_ cmd: String, addr: PanelAddr, layout: inout WorkspaceLayout, model: Model? = nil) {
        if cmd == "close_panel" { layout.closePanel(addr); return }
        guard let model = model else { return }
        // Pin the active panel id so set_panel_state effects target
        // the Align panel rather than whichever panel rendered most
        // recently — without this, the toggle wrote to the wrong
        // panel store and the checkmark never followed.
        model.stateStore.setActivePanel("align_panel_content")
        runYamlActionByName(cmd, params: [:], model: model)
    }

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        false
    }

    /// Same as ``isChecked`` but with model in scope so the toggle's
    /// checkmark can read the panel state. Used by the hamburger
    /// menu's checked-state logic.
    public static func isCheckedWithModel(_ cmd: String, model: Model?) -> Bool {
        guard let model = model else { return false }
        switch cmd {
        case "toggle_use_preview_bounds":
            return (model.stateStore.getPanel(
                "align_panel_content", "use_preview_bounds") as? Bool) ?? false
        default:
            return false
        }
    }
}
