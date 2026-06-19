//! Boolean panel menu definition.
//!
//! The Boolean panel spec is in `transcripts/BOOLEAN.md` and will be
//! driven by `workspace/panels/boolean.yaml`. This module provides
//! the native menu scaffolding for the hamburger menu: Repeat
//! Boolean Operation, Boolean Options…, Make / Release / Expand
//! Compound Shape, Reset Panel, and Close Boolean. Operation
//! buttons (UNION / SUBTRACT_FRONT / ... / SUBTRACT_BACK plus EXPAND)
//! live in the yaml content tree and dispatch to same-named effects
//! implemented in renderer.rs.

use crate::workspace::app_state::AppState;
use crate::workspace::workspace::PanelAddr;
use super::panel_menu::PanelMenuItem;

pub fn menu_items() -> Vec<PanelMenuItem> {
    // Source of truth is workspace/panels/boolean.yaml's `menu:` block
    // (review #15); the generic reader builds the items from the bundle.
    super::panel_menu::menu_items_from_yaml("boolean_panel_content")
}

pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) {
    match cmd {
        "close_panel" => crate::workspace::layout_apply::layout_apply(
            &mut state.workspace_layout,
            &crate::workspace::layout_apply::op_close_panel(addr),
        ),
        // Forward menu commands to the YAML actions catalog so the
        // hamburger menu fires the same effect chain as the panel
        // YAML dispatch wiring.
        "repeat_boolean_operation"
        | "open_boolean_options"
        | "make_compound_shape"
        | "release_compound_shape"
        | "expand_compound_shape"
        | "reset_boolean_panel" => {
            let params = serde_json::Map::new();
            crate::interpreter::renderer::dispatch_action(cmd, &params, state);
        }
        _ => {}
    }
}

pub fn is_checked(_cmd: &str, _state: &AppState) -> bool {
    // No toggle-style menu items in the Boolean panel menu.
    false
}
