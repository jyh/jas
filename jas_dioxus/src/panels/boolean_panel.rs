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

pub const LABEL: &str = "Boolean";

pub fn menu_items() -> Vec<PanelMenuItem> {
    vec![
        PanelMenuItem::Action {
            label: "Repeat Boolean Operation",
            command: "repeat_boolean_operation",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Boolean Options…",
            command: "open_boolean_options",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Make Compound Shape",
            command: "make_compound_shape",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Release Compound Shape",
            command: "release_compound_shape",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Expand Compound Shape",
            command: "expand_compound_shape",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Reset Panel",
            command: "reset_boolean_panel",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Close Boolean",
            command: "close_panel",
            shortcut: "",
        },
    ]
}

pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) {
    match cmd {
        "close_panel" => state.workspace_layout.close_panel(addr),
        // All compound-shape, repeat, options, and reset commands
        // are routed through the yaml-driven renderer dispatch path;
        // this native menu-dispatch no-ops so the hamburger menu
        // goes through the same shared effects pipeline.
        _ => {}
    }
}

pub fn is_checked(_cmd: &str, _state: &AppState) -> bool {
    // No toggle-style menu items in the Boolean panel menu.
    false
}
