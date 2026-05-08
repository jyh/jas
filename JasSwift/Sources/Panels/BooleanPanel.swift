/// Boolean panel menu definition.
///
/// Menu items follow `transcripts/BOOLEAN.md` § Panel metadata:
/// Repeat Boolean Operation, Boolean Options…, Make / Release /
/// Expand Compound Shape, Reset Panel, Close Boolean. The operation
/// button grid and its action dispatch land in phase 9b+.

public enum BooleanPanel {
    public static func menuItems() -> [PanelMenuItem] {
        [
            .action(label: "Repeat Boolean Operation", command: "repeat_boolean_operation"),
            .action(label: "Boolean Options\u{2026}", command: "open_boolean_options"),
            .separator,
            .action(label: "Make Compound Shape", command: "make_compound_shape"),
            .action(label: "Release Compound Shape", command: "release_compound_shape"),
            .action(label: "Expand Compound Shape", command: "expand_compound_shape"),
            .separator,
            .action(label: "Reset Panel", command: "reset_boolean_panel"),
            .separator,
            .action(label: "Close Boolean", command: "close_panel"),
        ]
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
