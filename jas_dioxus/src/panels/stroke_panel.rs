//! Stroke panel menu definition.

use crate::workspace::app_state::AppState;
use crate::workspace::workspace::PanelAddr;
use super::panel_menu::PanelMenuItem;

/// Menu items for the Stroke panel.
pub fn menu_items() -> Vec<PanelMenuItem> {
    // Source of truth is workspace/panels/stroke.yaml's `menu:` block
    // (review #15); the generic reader builds the items from the bundle.
    super::panel_menu::menu_items_from_yaml("stroke_panel_content")
}

/// Dispatch a menu command for the Stroke panel.
///
/// The cap/join radio commands arrive param-folded from the generic
/// menu builder (`set_stroke_cap:round`, `set_stroke_join:bevel`) — see
/// `panel_menu::command_with_params`. We split the suffix back off and
/// write the panel-state field, then push to the selection so the menu
/// and the in-panel cap/join buttons stay in sync.
pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) {
    if let Some(cap) = cmd.strip_prefix("set_stroke_cap:") {
        state.stroke_panel.cap = cap.to_string();
        state.apply_stroke_panel_to_selection();
        return;
    }
    if let Some(join) = cmd.strip_prefix("set_stroke_join:") {
        state.stroke_panel.join = join.to_string();
        state.apply_stroke_panel_to_selection();
        return;
    }
    match cmd {
        "close_panel" => state.workspace_layout.close_panel(addr),
        _ => {}
    }
}

/// Query whether a radio command is checked. The cap/join radio
/// commands carry their value as a `:suffix` (see `dispatch`); the
/// checkmark follows the matching panel-state field.
pub fn is_checked(cmd: &str, state: &AppState) -> bool {
    if let Some(cap) = cmd.strip_prefix("set_stroke_cap:") {
        return state.stroke_panel.cap == cap;
    }
    if let Some(join) = cmd.strip_prefix("set_stroke_join:") {
        return state.stroke_panel.join == join;
    }
    false
}
