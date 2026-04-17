/// Character panel menu definition.
///
/// Mirrors the item list in `CHARACTER.md` and matches the Rust
/// `character_panel.rs` module. The four toggle commands (All Caps,
/// Small Caps, Superscript, Subscript) are rendered as the native
/// hamburger menu items; the yaml-driven menu declared in
/// `workspace/panels/character.yaml` carries the same actions with
/// `bind: panel.*_caps / super / sub` checked expressions so the
/// two surfaces stay in sync.
///
/// Layer B wiring — per-panel state, `apply_character_panel_to_selection`,
/// and menu checkmark reflection from panel state — will arrive in a
/// later pass.

public enum CharacterPanel {
    public static let label = "Character"

    public static func menuItems() -> [PanelMenuItem] {
        [
            .toggle(label: "Show Snap to Glyph Options", command: "toggle_snap_to_glyph_visible"),
            .separator,
            .toggle(label: "All Caps", command: "toggle_all_caps"),
            .toggle(label: "Small Caps", command: "toggle_small_caps"),
            .toggle(label: "Superscript", command: "toggle_superscript"),
            .toggle(label: "Subscript", command: "toggle_subscript"),
            .separator,
            .action(label: "Close Character", command: "close_panel"),
        ]
    }

    public static func dispatch(_ cmd: String, addr: PanelAddr, layout: inout WorkspaceLayout) {
        switch cmd {
        case "close_panel": layout.closePanel(addr)
        // Toggle commands flow through the yaml-menu action
        // dispatch (which flips the panel.* bool in the StateStore);
        // no layout-level state to mutate here yet.
        default: break
        }
    }

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        // Reads for the mirror toggles live in the StateStore
        // (panel-scoped bools), not on WorkspaceLayout. Until that
        // read path is threaded through this helper, menu
        // checkmarks for mirror toggles are driven by the yaml-side
        // `checked: panel.*` binding on the yaml menu rather than
        // by this native module.
        false
    }
}
