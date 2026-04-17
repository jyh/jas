//! Artboards panel menu definition (placeholder).
//!
//! The Artboards panel is still being spec'd in `ARTBOARDS.md`; this
//! module provides the minimum scaffolding required for the panel to
//! appear in the default layout and the Window menu — LABEL, Close
//! menu entry, no-op dispatch.

use crate::workspace::app_state::AppState;
use crate::workspace::workspace::PanelAddr;
use super::panel_menu::PanelMenuItem;

pub const LABEL: &str = "Artboards";

pub fn menu_items() -> Vec<PanelMenuItem> {
    vec![
        PanelMenuItem::Action {
            label: "Close Artboards",
            command: "close_panel",
            shortcut: "",
        },
    ]
}

pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) {
    match cmd {
        "close_panel" => state.workspace_layout.close_panel(addr),
        _ => {}
    }
}

pub fn is_checked(_cmd: &str, _state: &AppState) -> bool {
    false
}
