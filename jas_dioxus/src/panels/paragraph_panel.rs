//! Paragraph panel menu definition.
//!
//! Mirrors the menu items declared in `workspace/panels/paragraph.yaml`.
//! Hanging Punctuation is a panel-state toggle handled here directly;
//! Justification… / Hyphenation… are dialog openers handled by
//! `panel_menu_view.rs` (which has access to the dialog signal).
//! Reset Panel routes through `apply_paragraph_panel_to_selection`.

use crate::workspace::app_state::AppState;
use crate::workspace::workspace::PanelAddr;
use super::panel_menu::PanelMenuItem;

pub fn menu_items() -> Vec<PanelMenuItem> {
    // Source of truth is workspace/panels/paragraph.yaml's `menu:` block
    // (review #15); the generic reader builds the items from the bundle.
    super::panel_menu::menu_items_from_yaml("paragraph_panel_content")
}

pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) -> Vec<serde_json::Value> {
    match cmd {
        "close_panel" => crate::workspace::layout_apply::layout_apply(
            &mut state.workspace_layout,
            &crate::workspace::layout_apply::op_close_panel(addr),
        ),
        "toggle_hanging_punctuation" => {
            state.paragraph_panel.hanging_punctuation =
                !state.paragraph_panel.hanging_punctuation;
            state.apply_paragraph_panel_to_selection();
        }
        "reset_paragraph_panel" => {
            state.reset_paragraph_panel();
        }
        // The Justification / Hyphenation openers run their YAML, whose
        // deferred `open_dialog` the menu view applies.
        "open_paragraph_justification" | "open_paragraph_hyphenation" => {
            return crate::interpreter::renderer::dispatch_action(cmd, &serde_json::Map::new(), state);
        }
        _ => {}
    }
    Vec::new()
}
