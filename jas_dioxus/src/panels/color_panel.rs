//! Color panel menu definition.

use crate::geometry::element::Color;
use crate::workspace::app_state::AppState;
use crate::workspace::color_panel_view::ColorMode;
use crate::workspace::workspace::PanelAddr;
use super::panel_menu::PanelMenuItem;

/// Human-readable label for this panel.
pub const LABEL: &str = "Color";

/// Menu items for the Color panel.
pub fn menu_items() -> Vec<PanelMenuItem> {
    vec![
        PanelMenuItem::Radio {
            label: "Grayscale",
            command: "mode_grayscale",
            group: "color_mode",
        },
        PanelMenuItem::Radio {
            label: "RGB",
            command: "mode_rgb",
            group: "color_mode",
        },
        PanelMenuItem::Radio {
            label: "HSB",
            command: "mode_hsb",
            group: "color_mode",
        },
        PanelMenuItem::Radio {
            label: "CMYK",
            command: "mode_cmyk",
            group: "color_mode",
        },
        PanelMenuItem::Radio {
            label: "Web Safe RGB",
            command: "mode_web_safe_rgb",
            group: "color_mode",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Invert",
            command: "invert_color",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Complement",
            command: "complement_color",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Close Color",
            command: "close_panel",
            shortcut: "",
        },
    ]
}

/// Dispatch a menu command for the Color panel.
pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) {
    // Mode changes
    if let Some(mode) = ColorMode::from_command(cmd) {
        state.color_panel_mode = mode;
        return;
    }

    match cmd {
        "close_panel" => state.workspace_layout.close_panel(addr),
        "invert_color" => {
            if let Some(color) = state.active_color() {
                let (r, g, b, _) = color.to_rgba();
                let inverted = Color::rgb(1.0 - r, 1.0 - g, 1.0 - b);
                state.set_active_color(inverted);
            }
        }
        "complement_color" => {
            if let Some(color) = state.active_color() {
                let (h, s, br, _) = color.to_hsba();
                // No-op if saturation is 0
                if s > 0.001 {
                    let new_h = (h + 180.0) % 360.0;
                    let complemented = Color::hsb(new_h, s, br);
                    state.set_active_color(complemented);
                }
            }
        }
        _ => {}
    }
}

/// Query whether a toggle/radio command is checked.
pub fn is_checked(cmd: &str, state: &AppState) -> bool {
    if let Some(mode) = ColorMode::from_command(cmd) {
        return state.color_panel_mode == mode;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace::workspace::{DockEdge, GroupAddr, WorkspaceLayout};

    fn test_app_state() -> AppState {
        AppState {
            tabs: vec![],
            active_tab: 0,
            active_tool: crate::tools::tool::ToolKind::Selection,
            app_config: crate::workspace::workspace::AppConfig::default(),
            workspace_layout: WorkspaceLayout::default_layout(),
            fill_on_top: true,
            color_panel_mode: ColorMode::Hsb,
            app_default_fill: Some(crate::geometry::element::Fill::new(crate::geometry::element::Color::WHITE)),
            app_default_stroke: Some(crate::geometry::element::Stroke::new(crate::geometry::element::Color::BLACK, 1.0)),
            swatch_libraries: serde_json::json!({}),
            stroke_panel: crate::workspace::app_state::StrokePanelState::default(),
            character_panel: crate::workspace::app_state::CharacterPanelState::default(),
            layers_renaming: None,
            layers_collapsed: std::collections::HashSet::new(),
            layers_panel_selection: Vec::new(),
            layers_drag_target: None,
            layers_context_menu: None,
            layers_search_query: String::new(),
            layers_isolation_stack: Vec::new(),
            layers_solo_state: None,
            layers_saved_lock_states: std::collections::HashMap::new(),
            layers_hidden_types: std::collections::HashSet::new(),
            layers_filter_dropdown_open: false,
        }
    }

    #[test]
    fn menu_has_all_modes() {
        let items = menu_items();
        let mode_cmds: Vec<&str> = items.iter().filter_map(|item| match item {
            PanelMenuItem::Radio { command, group: "color_mode", .. } => Some(*command),
            _ => None,
        }).collect();
        assert_eq!(mode_cmds, vec![
            "mode_grayscale", "mode_rgb", "mode_hsb", "mode_cmyk", "mode_web_safe_rgb",
        ]);
    }

    #[test]
    fn menu_has_invert_and_complement() {
        let items = menu_items();
        let action_cmds: Vec<&str> = items.iter().filter_map(|item| match item {
            PanelMenuItem::Action { command, .. } => Some(*command),
            _ => None,
        }).collect();
        assert!(action_cmds.contains(&"invert_color"));
        assert!(action_cmds.contains(&"complement_color"));
    }

    #[test]
    fn dispatch_mode_change() {
        let mut state = test_app_state();
        let addr = PanelAddr {
            group: GroupAddr {
                dock_id: state.workspace_layout.anchored_dock(DockEdge::Right).unwrap().id,
                group_idx: 0,
            },
            panel_idx: 0,
        };
        assert_eq!(state.color_panel_mode, ColorMode::Hsb);
        dispatch("mode_rgb", addr, &mut state);
        assert_eq!(state.color_panel_mode, ColorMode::Rgb);
    }

    #[test]
    fn is_checked_matches_mode() {
        let mut state = test_app_state();
        assert!(is_checked("mode_hsb", &state));
        assert!(!is_checked("mode_rgb", &state));
        state.color_panel_mode = ColorMode::Cmyk;
        assert!(is_checked("mode_cmyk", &state));
        assert!(!is_checked("mode_hsb", &state));
    }

    #[test]
    fn menu_has_close_action() {
        let items = menu_items();
        let has_close = items.iter().any(|item| matches!(
            item,
            PanelMenuItem::Action { command: "close_panel", .. }
        ));
        assert!(has_close);
    }
}
