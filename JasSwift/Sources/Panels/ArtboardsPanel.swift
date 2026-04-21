/// Artboards panel menu definition (ARTBOARDS.md).
///
/// The panel body (row list + footer) is rendered by the generic
/// YAML interpreter from `workspace/panels/artboards.yaml`; this
/// module provides the hamburger-menu wiring for the Window-menu
/// integration. Every artboard mutation flows through the YAML
/// action pipeline (`LayersPanel.dispatchYamlAction`) — the
/// `dispatch` function here only handles `close_panel`.

public enum ArtboardsPanel {
    public static let label = "Artboards"

    /// Menu entries match `workspace/panels/artboards.yaml §menu` and
    /// `transcripts/ARTBOARDS.md §Menu` verbatim.
    public static func menuItems() -> [PanelMenuItem] {
        [
            .action(label: "New Artboard",          command: "new_artboard"),
            .action(label: "Duplicate Artboards",   command: "duplicate_artboards"),
            .action(label: "Delete Artboards",      command: "delete_artboards"),
            .action(label: "Rename",                command: "rename_artboard"),
            .separator,
            .action(label: "Delete Empty Artboards", command: "delete_empty_artboards"),
            .separator,
            // Phase-1 deferred per ARTBOARDS.md §Phase-1 deferrals —
            // the YAML action catalog grays these with enabled_when: false.
            .action(label: "Convert to Artboards",  command: "convert_to_artboards"),
            .action(label: "Artboard Options...",   command: "open_artboard_options"),
            .action(label: "Rearrange...",          command: "rearrange_artboards"),
            .separator,
            .action(label: "Reset Panel",           command: "reset_artboards_panel"),
            .separator,
            .action(label: "Close Artboards",       command: "close_panel"),
        ]
    }

    /// Dispatch a menu command. All artboard mutations route through
    /// the YAML action pipeline; this handler only owns `close_panel`.
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
