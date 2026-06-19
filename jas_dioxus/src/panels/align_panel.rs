//! Align panel menu definition.
//!
//! The Align panel spec is in `transcripts/ALIGN.md` and driven
//! by `workspace/panels/align.yaml`. This module provides the
//! native menu scaffolding: a Use Preview Bounds toggle, a Reset
//! Panel action, and Close Align. Operation buttons live in the
//! yaml content tree and dispatch to same-named platform effects
//! (align_left, distribute_top, etc.) implemented in renderer.rs.

use crate::workspace::app_state::AppState;
use crate::workspace::workspace::PanelAddr;
use super::panel_menu::PanelMenuItem;

pub fn menu_items() -> Vec<PanelMenuItem> {
    // Source of truth is workspace/panels/align.yaml's `menu:` block
    // (review #15); the generic reader builds the items from the bundle.
    super::panel_menu::menu_items_from_yaml("align_panel_content")
}

pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) {
    match cmd {
        "close_panel" => crate::workspace::layout_apply::layout_apply(
            &mut state.workspace_layout,
            &crate::workspace::layout_apply::op_close_panel(addr),
        ),
        "toggle_use_preview_bounds" => {
            state.align_panel.use_preview_bounds = !state.align_panel.use_preview_bounds;
        }
        "reset_align_panel" => state.reset_align_panel(),
        _ => {}
    }
}

pub fn is_checked(cmd: &str, state: &AppState) -> bool {
    match cmd {
        "toggle_use_preview_bounds" => state.align_panel.use_preview_bounds,
        _ => false,
    }
}
