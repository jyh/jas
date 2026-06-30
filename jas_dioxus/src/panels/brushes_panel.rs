//! Brushes panel menu definition (BRUSHES.md).
//!
//! The panel body (library disclosure headers + brush tiles + footer
//! toolbar) is rendered by the generic YAML interpreter from
//! `workspace/panels/brushes.yaml`; this module provides the hamburger
//! menu wiring so the panel integrates with the Window menu and panel-menu
//! chrome.
//!
//! Brushes is a TOGGLE-ONLY panel: it is not part of the default layout.
//! `Window > Brushes` summons it on demand (see the `toggle_panel_brushes`
//! arm in `menu_bar.rs`, gated on group membership so the first click adds
//! the panel via `WorkspaceLayout::show_panel`).
//!
//! Each menu entry fires a YAML action (see workspace/actions.yaml); the
//! dispatch here routes the command string through the shared
//! `dispatch_action` pipeline (the same path the panel-body buttons use)
//! and handles `close_panel` locally.

use crate::workspace::app_state::AppState;
use crate::workspace::workspace::PanelAddr;
use super::panel_menu::PanelMenuItem;

/// Menu items for the Brushes panel.
///
/// Source of truth is workspace/panels/brushes.yaml's `menu:` block; the
/// generic reader builds the items from the compiled bundle.
pub fn menu_items() -> Vec<PanelMenuItem> {
    super::panel_menu::menu_items_from_yaml("brushes_panel_content")
}

/// Dispatch a menu command for the Brushes panel.
///
/// `close_panel` is handled here. Every other command is a brush action
/// defined in actions.yaml and is routed through the shared
/// `dispatch_action` pipeline so the hamburger menu fires the same effect
/// chain as the panel-body wiring.
pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) {
    match cmd {
        "close_panel" => crate::workspace::layout_apply::layout_apply(
            &mut state.workspace_layout,
            &crate::workspace::layout_apply::op_close_panel(addr),
        ),
        _ => {
            let params = serde_json::Map::new();
            crate::interpreter::renderer::dispatch_action(cmd, &params, state);
        }
    }
}

/// Query whether a toggle/radio command is checked. The Brushes panel's
/// stateful menu items (view mode, thumbnail size, category filters,
/// persistence) carry `checked_when:` predicates in the bundle, which the
/// generic menu-state evaluator resolves; this native hook has no extra
/// state to report, mirroring the sibling panels.
pub fn is_checked(_cmd: &str, _state: &AppState) -> bool {
    false
}
