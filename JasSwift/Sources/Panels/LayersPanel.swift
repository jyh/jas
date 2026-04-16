/// Layers panel menu definition.

public enum LayersPanel {
    public static let label = "Layers"

    public static func menuItems() -> [PanelMenuItem] {
        [
            .action(label: "New Layer...", command: "new_layer"),
            .action(label: "New Group", command: "new_group"),
            .separator,
            .action(label: "Hide All Layers", command: "toggle_all_layers_visibility"),
            .action(label: "Outline All Layers", command: "toggle_all_layers_outline"),
            .action(label: "Lock All Layers", command: "toggle_all_layers_lock"),
            .separator,
            .action(label: "Enter Isolation Mode", command: "enter_isolation_mode"),
            .action(label: "Exit Isolation Mode", command: "exit_isolation_mode"),
            .separator,
            .action(label: "Flatten Artwork", command: "flatten_artwork"),
            .action(label: "Collect in New Layer", command: "collect_in_new_layer"),
            .separator,
            .action(label: "Close Layers", command: "close_panel"),
        ]
    }

    public static func dispatch(_ cmd: String, addr: PanelAddr, layout: inout WorkspaceLayout) {
        switch cmd {
        case "close_panel": layout.closePanel(addr)
        // Tier-3 stubs: log only until document model is implemented.
        case "new_layer", "new_group",
             "toggle_all_layers_visibility", "toggle_all_layers_outline",
             "toggle_all_layers_lock",
             "enter_isolation_mode", "exit_isolation_mode",
             "flatten_artwork", "collect_in_new_layer":
            #if DEBUG
            print("[LayersPanel] dispatch: \(cmd)")
            #endif
        default: break
        }
    }

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        false
    }
}
