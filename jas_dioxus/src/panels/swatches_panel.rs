//! Swatches panel menu definition.
//!
//! Menu items mirror the `menu:` block in
//! `workspace/panels/swatches.yaml`. The dynamic submenu
//! ("Open Swatch Library") and most data-mutating actions
//! (new_swatch, duplicate_swatch, delete_swatch, etc.) are
//! placeholders that log and no-op until the corresponding
//! controller / library-mutation plumbing lands. Thumbnail size
//! works end-to-end via st.swatches_panel.thumbnail_size.

use crate::workspace::app_state::AppState;
use crate::workspace::workspace::PanelAddr;
use super::panel_menu::PanelMenuItem;

/// Menu items for the Swatches panel.
pub fn menu_items() -> Vec<PanelMenuItem> {
    vec![
        PanelMenuItem::Action {
            label: "New Swatch",
            command: "new_swatch",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Duplicate Swatch",
            command: "duplicate_swatch",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Delete Swatch",
            command: "delete_swatch",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Select All Unused",
            command: "select_all_unused_swatches",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Add Used Colors",
            command: "add_used_colors",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Sort by Name",
            command: "sort_swatches_by_name",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Radio {
            label: "Small Thumbnail View",
            command: "set_swatch_thumbnail_small",
            group: "thumbnail_size",
        },
        PanelMenuItem::Radio {
            label: "Medium Thumbnail View",
            command: "set_swatch_thumbnail_medium",
            group: "thumbnail_size",
        },
        PanelMenuItem::Radio {
            label: "Large Thumbnail View",
            command: "set_swatch_thumbnail_large",
            group: "thumbnail_size",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Swatch Options...",
            command: "open_swatch_options",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        // The "Open Swatch Library" dynamic submenu would list every
        // workspace/swatches/*.json file. The PanelMenuItem enum
        // doesn't support submenus yet; surface as a placeholder
        // action for now.
        PanelMenuItem::Action {
            label: "Open Swatch Library...",
            command: "open_swatch_library",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Save Swatch Library",
            command: "save_swatch_library",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Close Swatches",
            command: "close_panel",
            shortcut: "",
        },
    ]
}

/// Dispatch a menu command for the Swatches panel.
pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) {
    match cmd {
        "close_panel" => state.workspace_layout.close_panel(addr),
        "set_swatch_thumbnail_small" => {
            state.swatches_panel.thumbnail_size = "small".into();
        }
        "set_swatch_thumbnail_medium" => {
            state.swatches_panel.thumbnail_size = "medium".into();
        }
        "set_swatch_thumbnail_large" => {
            state.swatches_panel.thumbnail_size = "large".into();
        }
        // Other actions are placeholders — see module doc. Logging
        // helps surface unwired commands during manual testing.
        "new_swatch"
        | "duplicate_swatch"
        | "delete_swatch"
        | "select_all_unused_swatches"
        | "add_used_colors"
        | "sort_swatches_by_name"
        | "open_swatch_options"
        | "open_swatch_library"
        | "save_swatch_library" => {
            web_sys::console::log_1(
                &format!("[swatches] command '{cmd}' is not yet wired").into());
        }
        _ => {}
    }
}

/// Query whether a toggle / radio command is checked.
pub fn is_checked(cmd: &str, state: &AppState) -> bool {
    let size = state.swatches_panel.thumbnail_size.as_str();
    match cmd {
        "set_swatch_thumbnail_small" => size == "small",
        "set_swatch_thumbnail_medium" => size == "medium",
        "set_swatch_thumbnail_large" => size == "large",
        _ => false,
    }
}
