//! Layers panel menu definition.

use crate::workspace::app_state::AppState;
use crate::workspace::workspace::PanelAddr;
use super::panel_menu::PanelMenuItem;

/// Human-readable label for this panel.
pub const LABEL: &str = "Layers";

/// Menu items for the Layers panel.
pub fn menu_items() -> Vec<PanelMenuItem> {
    vec![
        PanelMenuItem::Action {
            label: "Close Layers",
            command: "close_panel",
            shortcut: "",
        },
    ]
}

/// Dispatch a menu command for the Layers panel.
pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) {
    match cmd {
        "close_panel" => state.workspace_layout.close_panel(addr),
        _ => {}
    }
}

/// Query whether a toggle/radio command is checked.
pub fn is_checked(_cmd: &str, _state: &AppState) -> bool {
    false
}
