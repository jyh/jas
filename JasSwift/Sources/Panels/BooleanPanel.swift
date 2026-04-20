/// Boolean panel menu definition.
///
/// Menu items follow `transcripts/BOOLEAN.md` § Panel metadata:
/// Repeat Boolean Operation, Boolean Options…, Make / Release /
/// Expand Compound Shape, Reset Panel, Close Boolean. The operation
/// button grid and its action dispatch land in phase 9b+.

public enum BooleanPanel {
    public static let label = "Boolean"

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
        switch cmd {
        case "close_panel": layout.closePanel(addr)
        case "make_compound_shape":
            if let m = model { Controller(model: m).makeCompoundShape() }
        case "release_compound_shape":
            if let m = model { Controller(model: m).releaseCompoundShape() }
        case "expand_compound_shape":
            if let m = model { Controller(model: m).expandCompoundShape() }
        // Repeat / Boolean Options / Reset dispatch is phase 9c+.
        default: break
        }
    }

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        false
    }
}
