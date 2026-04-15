//! Layers panel menu definition.

use crate::workspace::app_state::AppState;
use crate::workspace::workspace::PanelAddr;
use super::panel_menu::PanelMenuItem;

/// Human-readable label for this panel.
pub const LABEL: &str = "Layers";

/// Menu items for the Layers panel.
pub fn menu_items() -> Vec<PanelMenuItem> {
    vec![
        PanelMenuItem::Action {
            label: "New Layer...",
            command: "new_layer",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "New Group",
            command: "new_group",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Hide All Layers",
            command: "toggle_all_layers_visibility",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Outline All Layers",
            command: "toggle_all_layers_outline",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Lock All Layers",
            command: "toggle_all_layers_lock",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Enter Isolation Mode",
            command: "enter_isolation_mode",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Exit Isolation Mode",
            command: "exit_isolation_mode",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Flatten Artwork",
            command: "flatten_artwork",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Collect in New Layer",
            command: "collect_in_new_layer",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Close Layers",
            command: "close_panel",
            shortcut: "",
        },
    ]
}

/// Dispatch a menu command for the Layers panel.
pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) {
    match cmd {
        "close_panel" => state.workspace_layout.close_panel(addr),
        // Tier-3 stubs: log only until document model is implemented.
        "new_layer"
        | "new_group"
        | "toggle_all_layers_visibility"
        | "toggle_all_layers_outline"
        | "toggle_all_layers_lock"
        | "enter_isolation_mode"
        | "exit_isolation_mode"
        | "flatten_artwork"
        | "collect_in_new_layer" => {
            #[cfg(debug_assertions)]
            eprintln!("[layers_panel] dispatch: {cmd}");
        }
        _ => {}
    }
}

/// Query whether a toggle/radio command is checked.
pub fn is_checked(_cmd: &str, _state: &AppState) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace::workspace::{DockEdge, GroupAddr, WorkspaceLayout};
    use crate::workspace::color_panel_view::ColorMode;
    use crate::workspace::app_state::StrokePanelState;

    fn test_app_state() -> AppState {
        AppState {
            tabs: vec![],
            active_tab: 0,
            active_tool: crate::tools::tool::ToolKind::Selection,
            app_config: crate::workspace::workspace::AppConfig::default(),
            workspace_layout: WorkspaceLayout::default_layout(),
            fill_on_top: true,
            color_panel_mode: ColorMode::Hsb,
            app_default_fill: Some(crate::geometry::element::Fill::new(
                crate::geometry::element::Color::WHITE,
            )),
            app_default_stroke: Some(crate::geometry::element::Stroke::new(
                crate::geometry::element::Color::BLACK,
                1.0,
            )),
            swatch_libraries: serde_json::json!({}),
            stroke_panel: StrokePanelState::default(),
        }
    }

    #[test]
    fn menu_has_new_layer() {
        let items = menu_items();
        let has = items.iter().any(|item| matches!(
            item,
            PanelMenuItem::Action { command: "new_layer", .. }
        ));
        assert!(has, "menu missing new_layer action");
    }

    #[test]
    fn menu_has_new_group() {
        let items = menu_items();
        let has = items.iter().any(|item| matches!(
            item,
            PanelMenuItem::Action { command: "new_group", .. }
        ));
        assert!(has, "menu missing new_group action");
    }

    #[test]
    fn menu_has_visibility_toggles() {
        let items = menu_items();
        for cmd in &[
            "toggle_all_layers_visibility",
            "toggle_all_layers_outline",
            "toggle_all_layers_lock",
        ] {
            let has = items.iter().any(|item| matches!(
                item,
                PanelMenuItem::Action { command: c, .. } if *c == *cmd
            ));
            assert!(has, "menu missing {cmd} action");
        }
    }

    #[test]
    fn menu_has_isolation_mode() {
        let items = menu_items();
        for cmd in &["enter_isolation_mode", "exit_isolation_mode"] {
            let has = items.iter().any(|item| matches!(
                item,
                PanelMenuItem::Action { command: c, .. } if *c == *cmd
            ));
            assert!(has, "menu missing {cmd} action");
        }
    }

    #[test]
    fn menu_has_flatten_and_collect() {
        let items = menu_items();
        for cmd in &["flatten_artwork", "collect_in_new_layer"] {
            let has = items.iter().any(|item| matches!(
                item,
                PanelMenuItem::Action { command: c, .. } if *c == *cmd
            ));
            assert!(has, "menu missing {cmd} action");
        }
    }

    #[test]
    fn menu_has_close_action() {
        let items = menu_items();
        let has = items.iter().any(|item| matches!(
            item,
            PanelMenuItem::Action { command: "close_panel", .. }
        ));
        assert!(has, "menu missing close_panel action");
    }

    #[test]
    fn dispatch_close_removes_panel() {
        let mut state = test_app_state();
        let dock_id = state
            .workspace_layout
            .anchored_dock(DockEdge::Right)
            .unwrap()
            .id;
        // Layers is in its own group in the default layout
        let addr = PanelAddr {
            group: GroupAddr {
                dock_id,
                group_idx: 2,
            },
            panel_idx: 0,
        };
        assert!(state
            .workspace_layout
            .is_panel_visible(crate::workspace::workspace::PanelKind::Layers));
        dispatch("close_panel", addr, &mut state);
        assert!(!state
            .workspace_layout
            .is_panel_visible(crate::workspace::workspace::PanelKind::Layers));
    }

    #[test]
    fn dispatch_tier3_commands_no_panic() {
        let mut state = test_app_state();
        let dock_id = state
            .workspace_layout
            .anchored_dock(DockEdge::Right)
            .unwrap()
            .id;
        let addr = PanelAddr {
            group: GroupAddr {
                dock_id,
                group_idx: 2,
            },
            panel_idx: 0,
        };
        // All tier-3 commands should dispatch without panic
        for cmd in &[
            "new_layer",
            "new_group",
            "toggle_all_layers_visibility",
            "toggle_all_layers_outline",
            "toggle_all_layers_lock",
            "enter_isolation_mode",
            "exit_isolation_mode",
            "flatten_artwork",
            "collect_in_new_layer",
        ] {
            dispatch(cmd, addr, &mut state);
        }
    }

    #[test]
    fn is_checked_returns_false() {
        let state = test_app_state();
        assert!(!is_checked("anything", &state));
    }
}
