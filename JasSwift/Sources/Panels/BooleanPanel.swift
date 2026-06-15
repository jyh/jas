/// Boolean panel menu definition.
///
/// Menu items follow `transcripts/BOOLEAN.md` § Panel metadata:
/// Repeat Boolean Operation, Boolean Options…, Make / Release /
/// Expand Compound Shape, Reset Panel, Close Boolean. The operation
/// button grid and its action dispatch land in phase 9b+.

public enum BooleanPanel {
    /// Source of truth is workspace/panels/boolean.yaml's `menu:` block
    /// (review #15); the generic reader builds the items from the bundle.
    public static func menuItems() -> [PanelMenuItem] {
        menuItemsFromYaml("boolean_panel_content")
    }

    public static func dispatch(_ cmd: String, addr: PanelAddr, layout: inout WorkspaceLayout, model: Model? = nil) {
        if cmd == "close_panel" { layout.closePanel(addr); return }
        guard let model = model else { return }
        // Route through runYamlActionByName so the action's
        // `- snapshot` step runs (registering an undo entry)
        // before the destructive op. The previous direct
        // Controller.makeCompoundShape() etc. calls skipped that
        // step and made compound-shape menu actions un-undoable.
        model.stateStore.setActivePanel("boolean_panel_content")
        runYamlActionByName(cmd, params: [:], model: model)
    }

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        false
    }
}
