//! Character panel menu definition (placeholder).
//!
//! The Character panel itself is still being spec'd in `CHARACTER.md` /
//! `TSPAN.md`; this module provides the minimum scaffolding required
//! for the panel to appear in the default layout and the Window menu
//! — a `LABEL`, a menu with a `Close Character` entry, and a no-op
//! dispatch beyond closing. Extend as the panel's UI and actions land.

use crate::workspace::app_state::AppState;
use crate::workspace::workspace::PanelAddr;
use super::panel_menu::PanelMenuItem;

/// Human-readable label for this panel.
pub const LABEL: &str = "Character";

/// Menu items for the Character panel.
pub fn menu_items() -> Vec<PanelMenuItem> {
    vec![
        PanelMenuItem::Action {
            label: "Close Character",
            command: "close_panel",
            shortcut: "",
        },
    ]
}

/// Dispatch a menu command for the Character panel.
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
