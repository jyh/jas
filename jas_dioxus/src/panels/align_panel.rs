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

pub const LABEL: &str = "Align";

pub fn menu_items() -> Vec<PanelMenuItem> {
    vec![
        PanelMenuItem::Toggle {
            label: "Use Preview Bounds",
            command: "toggle_use_preview_bounds",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Reset Panel",
            command: "reset_align_panel",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Close Align",
            command: "close_panel",
            shortcut: "",
        },
    ]
}

pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) {
    match cmd {
        "close_panel" => state.workspace_layout.close_panel(addr),
        // toggle_use_preview_bounds and reset_align_panel are
        // wired through the yaml-driven renderer dispatch path;
        // see renderer.rs. This native menu-dispatch no-ops for
        // them so the hamburger menu routes through the shared
        // effects pipeline.
        _ => {}
    }
}

pub fn is_checked(_cmd: &str, _state: &AppState) -> bool {
    // Stage 2b will wire this to state.align_panel.use_preview_bounds
    // once AlignPanelState lands on AppState.
    false
}
