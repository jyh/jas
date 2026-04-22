//! Character panel menu definition.
//!
//! Mirrors the menu items listed in CHARACTER.md. Toggle items for
//! All Caps / Small Caps / Superscript / Subscript track the same
//! panel-state bools the in-panel icon toggles use, so either surface
//! writes the same attribute on the selection.

use crate::workspace::app_state::AppState;
use crate::workspace::workspace::PanelAddr;
use super::panel_menu::PanelMenuItem;

/// Menu items for the Character panel.
pub fn menu_items() -> Vec<PanelMenuItem> {
    vec![
        PanelMenuItem::Toggle { label: "Show Snap to Glyph Options", command: "toggle_snap_to_glyph_visible" },
        PanelMenuItem::Separator,
        PanelMenuItem::Toggle { label: "All Caps", command: "toggle_all_caps" },
        PanelMenuItem::Toggle { label: "Small Caps", command: "toggle_small_caps" },
        PanelMenuItem::Toggle { label: "Superscript", command: "toggle_superscript" },
        PanelMenuItem::Toggle { label: "Subscript", command: "toggle_subscript" },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Close Character",
            command: "close_panel",
            shortcut: "",
        },
    ]
}

/// Dispatch a menu command for the Character panel. The toggle
/// commands flip the matching Character-panel state bool and push
/// the result to the selected text element(s) via the same pipeline
/// the icon toggles use, so menu and in-panel surfaces stay in sync.
pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) {
    match cmd {
        "close_panel" => state.workspace_layout.close_panel(addr),
        "toggle_snap_to_glyph_visible" => {
            state.character_panel.snap_to_glyph_visible = !state.character_panel.snap_to_glyph_visible;
        }
        "toggle_all_caps" => {
            state.character_panel.all_caps = !state.character_panel.all_caps;
            // Mutual exclusion with Small Caps (CHARACTER.md).
            if state.character_panel.all_caps { state.character_panel.small_caps = false; }
            state.apply_character_panel_to_selection();
        }
        "toggle_small_caps" => {
            state.character_panel.small_caps = !state.character_panel.small_caps;
            if state.character_panel.small_caps { state.character_panel.all_caps = false; }
            state.apply_character_panel_to_selection();
        }
        "toggle_superscript" => {
            state.character_panel.superscript = !state.character_panel.superscript;
            if state.character_panel.superscript { state.character_panel.subscript = false; }
            state.apply_character_panel_to_selection();
        }
        "toggle_subscript" => {
            state.character_panel.subscript = !state.character_panel.subscript;
            if state.character_panel.subscript { state.character_panel.superscript = false; }
            state.apply_character_panel_to_selection();
        }
        _ => {}
    }
}

/// Query whether a toggle/radio command is checked. Reads the same
/// panel-state bools the toggle dispatchers above write, so the menu
/// checkmark reflects the live state.
pub fn is_checked(cmd: &str, state: &AppState) -> bool {
    let cp = &state.character_panel;
    match cmd {
        "toggle_snap_to_glyph_visible" => cp.snap_to_glyph_visible,
        "toggle_all_caps" => cp.all_caps,
        "toggle_small_caps" => cp.small_caps,
        "toggle_superscript" => cp.superscript,
        "toggle_subscript" => cp.subscript,
        _ => false,
    }
}
