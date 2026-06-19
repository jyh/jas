//! Symbols panel menu definition (SYMBOLS.md §8, P3 first slice).
//!
//! The panel body (master row list + footer) is rendered by the generic
//! YAML interpreter from `workspace/panels/symbols.yaml`; this module
//! provides the hamburger menu wiring so the panel integrates with the
//! Window menu and panel-menu chrome.
//!
//! Each menu entry fires a YAML action (see workspace/actions.yaml). The
//! mutating symbol ops (new_symbol / place_instance / delete_symbol_action)
//! are intercepted natively in `interpreter::renderer::dispatch_action`
//! (they mint ids by the value-in-op rule and call the shared symbol
//! operations); the dispatch here only routes the command string and
//! handles `close_panel`.

use crate::workspace::app_state::AppState;
use crate::workspace::workspace::PanelAddr;
use super::panel_menu::PanelMenuItem;

/// Menu items for the Symbols panel.
///
/// Source of truth is workspace/panels/symbols.yaml's `menu:` block; the
/// generic reader builds the items from the bundle.
pub fn menu_items() -> Vec<PanelMenuItem> {
    super::panel_menu::menu_items_from_yaml("symbols_panel_content")
}

/// Dispatch a menu command for the Symbols panel.
///
/// `close_panel` is handled here. The symbol actions route through the
/// shared `dispatch_action` pipeline, where the native intercept mints
/// ids and calls the Controller ops.
pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) {
    match cmd {
        "close_panel" => crate::workspace::layout_apply::layout_apply(
            &mut state.workspace_layout,
            &crate::workspace::layout_apply::op_close_panel(addr),
        ),
        "new_symbol" | "place_instance" | "delete_symbol_action" => {
            let params = serde_json::Map::new();
            crate::interpreter::renderer::dispatch_action(cmd, &params, state);
        }
        _ => {}
    }
}

/// Query whether a toggle/radio command is checked. The Symbols panel
/// has no stateful toggles in the menu (this slice).
pub fn is_checked(_cmd: &str, _state: &AppState) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn labels(items: &[PanelMenuItem]) -> Vec<&str> {
        items.iter().filter_map(|i| i.label()).collect()
    }
    fn commands(items: &[PanelMenuItem]) -> Vec<&str> {
        items.iter().filter_map(|i| i.command()).collect()
    }

    #[test]
    fn menu_has_all_spec_entries() {
        let items = menu_items();
        let labels = labels(&items);
        assert!(labels.contains(&"New Symbol"));
        assert!(labels.contains(&"Place Instance"));
        assert!(labels.contains(&"Delete Symbol"));
        assert!(labels.contains(&"Close Symbols"));
    }

    #[test]
    fn menu_commands_match_yaml_actions() {
        let items = menu_items();
        let commands = commands(&items);
        for cmd in &["new_symbol", "place_instance", "delete_symbol_action", "close_panel"] {
            assert!(commands.contains(cmd), "menu should include command {cmd}");
        }
    }

    #[test]
    fn is_checked_always_false() {
        let st = AppState::new();
        for cmd in &["new_symbol", "place_instance", "delete_symbol_action", "close_panel"] {
            assert!(!is_checked(cmd, &st));
        }
    }
}
