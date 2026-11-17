//! Swatches panel menu definition.
//!
//! Menu items mirror the `menu:` block in
//! `workspace/panels/swatches.yaml`. The dynamic submenu
//! ("Open Swatch Library") declares `items_from`: the generic menu view
//! draws its rows and runs `toggle_swatch_library_open` (design
//! 2026-10-28 §3.4; until then a native flyout here). New Swatch,
//! Swatch Options and Save Swatch Library run their YAML, which opens a
//! dialog.
//!
//! Wired: thumbnail size (st.swatches_panel.thumbnail_size). The five
//! library verbs (duplicate_swatch, delete_swatch, sort_swatches_by_name,
//! select_all_unused_swatches, add_used_colors) are `swatch.*` effects in
//! actions.yaml, dispatched through the shared runner.

use crate::workspace::app_state::AppState;
use crate::workspace::workspace::PanelAddr;
use super::panel_menu::PanelMenuItem;

/// Menu items for the Swatches panel.
///
/// Source of truth is workspace/panels/swatches.yaml's `menu:` block
/// (review #15); the generic reader builds the items from the bundle.
///
/// The three thumbnail-size rows share `action: set_swatch_thumbnail_size`,
/// so the builder folds each `params.size` into the command
/// (`set_swatch_thumbnail_size:small`, …) — `dispatch` splits that suffix
/// back off; the CHECK MARK is swatches.yaml's own `checked_when:`,
/// evaluated generically by `panels::panel_is_checked`. The "Open Swatch
/// Library" submenu is a `PanelMenuItem::Submenu` (its `items_from`), which
/// dispatches its own rows and never reaches `dispatch`.
pub fn menu_items() -> Vec<PanelMenuItem> {
    super::panel_menu::menu_items_from_yaml("swatches_panel_content")
}

/// Dispatch a menu command for the Swatches panel.
pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) -> Vec<serde_json::Value> {
    // Thumbnail-size radio arrives param-folded from the generic menu
    // builder (`set_swatch_thumbnail_size:small`); split the value back
    // off and store it.
    if let Some(size) = cmd.strip_prefix("set_swatch_thumbnail_size:") {
        state.swatches_panel.thumbnail_size = size.to_string();
        return Vec::new();
    }
    match cmd {
        "close_panel" => crate::workspace::layout_apply::layout_apply(
            &mut state.workspace_layout,
            &crate::workspace::layout_apply::op_close_panel(addr),
        ),
        // The five library verbs are `swatch.*` effects in actions.yaml (the
        // reference is workspace_interpreter/effects.py), run through the
        // shared dispatcher like every other YAML action.
        "sort_swatches_by_name"
        | "select_all_unused_swatches"
        | "add_used_colors"
        | "delete_swatch"
        | "duplicate_swatch" => {
            let params = serde_json::Map::new();
            return crate::interpreter::renderer::dispatch_action(cmd, &params, state);
        }
        // New Swatch and Swatch Options open the Swatch Options dialog from
        // their YAML; the action evaluates with this panel's scope (Swatch
        // Options reads the panel's selected swatch), and its deferred
        // `open_dialog` goes back to the menu view, which opens it.
        "new_swatch" | "open_swatch_options" | "save_swatch_library" => {
            return super::panel_menu::dispatch_yaml_menu("swatches_panel_content", cmd, addr, state);
        }
        _ => {}
    }
    Vec::new()
}
