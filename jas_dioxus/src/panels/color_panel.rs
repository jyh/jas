//! Color panel menu definition.

use crate::geometry::element::Color;
use crate::workspace::app_state::AppState;
use crate::workspace::color_panel_view::ColorMode;
use crate::workspace::workspace::PanelAddr;
use super::panel_menu::PanelMenuItem;

/// Menu items for the Color panel.
pub fn menu_items() -> Vec<PanelMenuItem> {
    // Source of truth is workspace/panels/color.yaml's `menu:` block
    // (review #15); the generic reader builds the items from the bundle.
    // The five mode rows share `action: set_color_panel_mode`, so the
    // builder folds each `params.mode` into the command
    // (`set_color_panel_mode:grayscale`, …) — `mode_from_command` below
    // splits that suffix back off.
    super::panel_menu::menu_items_from_yaml("color_panel_content")
}

/// Recover the `ColorMode` a menu command targets. The mode rows arrive
/// param-folded from the generic builder as `set_color_panel_mode:<value>`.
fn mode_from_command(cmd: &str) -> Option<ColorMode> {
    let value = cmd.strip_prefix("set_color_panel_mode:")?;
    match value {
        "grayscale" => Some(ColorMode::Grayscale),
        "rgb" => Some(ColorMode::Rgb),
        "hsb" => Some(ColorMode::Hsb),
        "cmyk" => Some(ColorMode::Cmyk),
        "web_safe_rgb" => Some(ColorMode::WebSafeRgb),
        _ => None,
    }
}

/// Dispatch a menu command for the Color panel.
pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) {
    // Mode changes (folded command form from the YAML radio group).
    if let Some(mode) = mode_from_command(cmd) {
        state.color_panel_mode = mode;
        return;
    }

    match cmd {
        "close_panel" => crate::workspace::layout_apply::layout_apply(
            &mut state.workspace_layout,
            &crate::workspace::layout_apply::op_close_panel(addr),
        ),
        "invert_active_color" => {
            if let Some(color) = state.active_color() {
                let (r, g, b, _) = color.to_rgba();
                let inverted = Color::rgb(1.0 - r, 1.0 - g, 1.0 - b);
                state.set_active_color(inverted);
            }
        }
        "complement_active_color" => {
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

/// Query whether a radio command is checked (the active color mode).
pub fn is_checked(cmd: &str, state: &AppState) -> bool {
    if let Some(mode) = mode_from_command(cmd) {
        return state.color_panel_mode == mode;
    }
    false
}

/// Query whether a menu command is enabled. Invert / Complement need
/// an active color (fill or stroke per `fill_on_top`) to operate on.
pub fn is_enabled(cmd: &str, state: &AppState) -> bool {
    match cmd {
        "invert_active_color" | "complement_active_color" => state.active_color().is_some(),
        _ => true,
    }
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
            prior_tool_for_spacebar: None,
            app_config: crate::workspace::workspace::AppConfig::default(),
            workspace_layout: WorkspaceLayout::default_layout(),
            fill_on_top: true,
            color_panel_mode: ColorMode::Hsb,
            app_default_fill: Some(crate::geometry::element::Fill::new(crate::geometry::element::Color::WHITE)),
            app_default_stroke: Some(crate::geometry::element::Stroke::new(crate::geometry::element::Color::BLACK, 1.0)),
            swatch_libraries: serde_json::json!({}),
            brush_libraries: serde_json::json!({}),
            stroke_panel: crate::workspace::app_state::StrokePanelState::default(),
            gradient_panel: crate::workspace::app_state::GradientPanelState::default(),
            character_panel: crate::workspace::app_state::CharacterPanelState::default(),
            paragraph_panel: crate::workspace::app_state::ParagraphPanelState::default(),
            align_panel: crate::workspace::app_state::AlignPanelState::default(),
            boolean_panel: crate::workspace::app_state::BooleanPanelState::default(),
            opacity_panel: crate::workspace::app_state::OpacityPanelState::default(),
            swatches_panel: crate::workspace::app_state::SwatchesPanelState::default(),
            layers_renaming: None,
            layers_collapsed: std::collections::HashSet::new(),
            layers_panel_selection: Vec::new(),
            layers_drag_target: None,
            layers_drag_source: None,
            layers_context_menu: None,
            layers_search_query: String::new(),
            layers_isolation_stack: Vec::new(),
            layers_solo_state: None,
            layers_saved_lock_states: std::collections::HashMap::new(),
            layers_hidden_types: std::collections::HashSet::new(),
            layers_filter_dropdown_open: false,
            artboards_panel_selection: Vec::new(),
            artboards_panel_anchor: None,
            artboards_renaming: None,
            artboards_reference_point: "center".to_string(),
            artboards_rearrange_dirty: false,
            symbols_selected: None,
            concepts_selected: None,
        }
    }

    // The menu DATA now comes from workspace/panels/color.yaml; these
    // assertions probe item commands via the `PanelMenuItem` accessors
    // rather than naming the `Action/Toggle/Radio` variants (which count
    // against the genericity metric). The mode rows share one YAML action
    // (`set_color_panel_mode`) and the builder folds `params.mode` into
    // each command.
    fn commands(items: &[PanelMenuItem]) -> Vec<&str> {
        items.iter().filter_map(|i| i.command()).collect()
    }

    #[test]
    fn menu_has_all_modes() {
        let items = menu_items();
        let cmds = commands(&items);
        for c in &[
            "set_color_panel_mode:grayscale",
            "set_color_panel_mode:rgb",
            "set_color_panel_mode:hsb",
            "set_color_panel_mode:cmyk",
            "set_color_panel_mode:web_safe_rgb",
        ] {
            assert!(cmds.contains(c), "menu missing mode command {c}");
        }
    }

    #[test]
    fn menu_has_invert_and_complement() {
        let items = menu_items();
        let cmds = commands(&items);
        assert!(cmds.contains(&"invert_active_color"));
        assert!(cmds.contains(&"complement_active_color"));
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
        dispatch("set_color_panel_mode:rgb", addr, &mut state);
        assert_eq!(state.color_panel_mode, ColorMode::Rgb);
    }

    #[test]
    fn is_checked_matches_mode() {
        let mut state = test_app_state();
        assert!(is_checked("set_color_panel_mode:hsb", &state));
        assert!(!is_checked("set_color_panel_mode:rgb", &state));
        state.color_panel_mode = ColorMode::Cmyk;
        assert!(is_checked("set_color_panel_mode:cmyk", &state));
        assert!(!is_checked("set_color_panel_mode:hsb", &state));
    }

    #[test]
    fn menu_has_close_action() {
        let items = menu_items();
        assert!(commands(&items).contains(&"close_panel"));
    }
}
