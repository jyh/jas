//! Magic Wand panel menu definition.
//!
//! The Magic Wand panel spec is in `transcripts/MAGIC_WAND_TOOL.md`
//! and driven by `workspace/panels/magic_wand.yaml`. This module
//! provides the native menu scaffolding: a Reset action and Close
//! Magic Wand. The five criterion checkboxes + four tolerance fields
//! live in the yaml content tree and dispatch to actions like
//! `reset_magic_wand_panel` (declared in workspace/actions.yaml).

use crate::workspace::app_state::AppState;
use crate::workspace::workspace::PanelAddr;
use super::panel_menu::PanelMenuItem;

pub fn menu_items() -> Vec<PanelMenuItem> {
    // Source of truth is workspace/panels/magic_wand.yaml's `menu:` block
    // (review #15); the generic reader builds the items from the bundle.
    super::panel_menu::menu_items_from_yaml("magic_wand_panel_content")
}

pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) {
    match cmd {
        "close_panel" => crate::workspace::layout_apply::layout_apply(
            &mut state.workspace_layout,
            &crate::workspace::layout_apply::op_close_panel(addr),
        ),
        // reset_magic_wand_panel routes through the yaml-driven
        // renderer dispatch path (see actions.yaml). This native
        // menu-dispatch no-ops for it so the hamburger menu hits
        // the shared effects pipeline.
        _ => {}
    }
}

pub fn is_checked(_cmd: &str, _state: &AppState) -> bool {
    // Magic Wand panel has no checkable menu items in MVP.
    false
}
