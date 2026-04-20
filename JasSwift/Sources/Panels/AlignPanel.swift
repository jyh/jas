/// Align panel menu definition.
///
/// Menu items follow `transcripts/ALIGN.md` §Panel menu: a
/// "Use Preview Bounds" toggle, a "Reset Panel" action, and
/// "Close Align". Stages 3b-3j will wire AlignPanelState,
/// algorithms, and platform-effect handlers; this stage only
/// registers the menu scaffolding so PanelKind.align can flow
/// through dispatch tables.

public enum AlignPanel {
    public static let label = "Align"

    public static func menuItems() -> [PanelMenuItem] {
        [
            .toggle(label: "Use Preview Bounds", command: "toggle_use_preview_bounds"),
            .separator,
            .action(label: "Reset Panel", command: "reset_align_panel"),
            .separator,
            .action(label: "Close Align", command: "close_panel"),
        ]
    }

    public static func dispatch(_ cmd: String, addr: PanelAddr, layout: inout WorkspaceLayout) {
        switch cmd {
        case "close_panel": layout.closePanel(addr)
        // toggle_use_preview_bounds and reset_align_panel route
        // through the yaml-driven renderer dispatch; Stage 3h wires
        // them to AlignPanelState.
        default: break
        }
    }

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        // Stage 3h will wire toggle_use_preview_bounds to
        // AlignPanelState.useePreviewBounds via the shared
        // store / model.
        false
    }
}
