//! Panel definitions: one module per panel kind.
//!
//! Each panel module defines its label, menu items, dispatch function,
//! and checked-state query. This module provides unified lookup functions
//! that dispatch by [`PanelKind`].

pub mod panel_menu;
pub mod panel_menu_state;
pub mod panel_menu_view;

pub mod color_panel;
pub mod layers_panel;
pub mod properties_panel;
pub mod stroke_panel;
pub mod swatches_panel;

use crate::workspace::app_state::AppState;
use crate::workspace::workspace::{PanelAddr, PanelKind};
use panel_menu::PanelMenuItem;

/// Human-readable label for a panel kind.
pub fn panel_label(kind: PanelKind) -> &'static str {
    match kind {
        PanelKind::Layers => layers_panel::LABEL,
        PanelKind::Color => color_panel::LABEL,
        PanelKind::Swatches => swatches_panel::LABEL,
        PanelKind::Stroke => stroke_panel::LABEL,
        PanelKind::Properties => properties_panel::LABEL,
    }
}

/// Menu items for a panel kind.
pub fn panel_menu(kind: PanelKind) -> Vec<PanelMenuItem> {
    match kind {
        PanelKind::Layers => layers_panel::menu_items(),
        PanelKind::Color => color_panel::menu_items(),
        PanelKind::Swatches => swatches_panel::menu_items(),
        PanelKind::Stroke => stroke_panel::menu_items(),
        PanelKind::Properties => properties_panel::menu_items(),
    }
}

/// Dispatch a menu command for a panel kind.
pub(crate) fn panel_dispatch(
    kind: PanelKind,
    cmd: &str,
    addr: PanelAddr,
    state: &mut AppState,
) {
    match kind {
        PanelKind::Layers => layers_panel::dispatch(cmd, addr, state),
        PanelKind::Color => color_panel::dispatch(cmd, addr, state),
        PanelKind::Swatches => swatches_panel::dispatch(cmd, addr, state),
        PanelKind::Stroke => stroke_panel::dispatch(cmd, addr, state),
        PanelKind::Properties => properties_panel::dispatch(cmd, addr, state),
    }
}

/// Query whether a toggle/radio command is checked for a panel kind.
pub(crate) fn panel_is_checked(kind: PanelKind, cmd: &str, state: &AppState) -> bool {
    match kind {
        PanelKind::Layers => layers_panel::is_checked(cmd, state),
        PanelKind::Color => color_panel::is_checked(cmd, state),
        PanelKind::Swatches => swatches_panel::is_checked(cmd, state),
        PanelKind::Stroke => stroke_panel::is_checked(cmd, state),
        PanelKind::Properties => properties_panel::is_checked(cmd, state),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace::workspace::{
        DockEdge, GroupAddr, WorkspaceLayout,
    };

    #[test]
    fn panel_label_matches_all_kinds() {
        assert_eq!(panel_label(PanelKind::Layers), "Layers");
        assert_eq!(panel_label(PanelKind::Color), "Color");
        assert_eq!(panel_label(PanelKind::Stroke), "Stroke");
        assert_eq!(panel_label(PanelKind::Properties), "Properties");
    }

    #[test]
    fn panel_menu_non_empty_for_all_kinds() {
        for &kind in PanelKind::ALL {
            let items = panel_menu(kind);
            assert!(!items.is_empty(), "{:?} menu is empty", kind);
        }
    }

    #[test]
    fn every_panel_has_close_action() {
        for &kind in PanelKind::ALL {
            let items = panel_menu(kind);
            let has_close = items.iter().any(|item| matches!(
                item,
                PanelMenuItem::Action { command: "close_panel", .. }
            ));
            assert!(has_close, "{:?} menu missing close_panel action", kind);
        }
    }

    #[test]
    fn close_label_matches_panel_name() {
        for &kind in PanelKind::ALL {
            let items = panel_menu(kind);
            let close_item = items.iter().find(|item| matches!(
                item,
                PanelMenuItem::Action { command: "close_panel", .. }
            ));
            if let Some(PanelMenuItem::Action { label, .. }) = close_item {
                let expected = format!("Close {}", panel_label(kind));
                assert_eq!(*label, expected.as_str(),
                    "{:?} close label mismatch", kind);
            }
        }
    }

    #[test]
    fn panel_dispatch_close_removes_panel() {
        // default_layout has Right dock: group 0 = [Layers], group 1 = [Color, Swatches, Stroke, Properties]
        let layout = WorkspaceLayout::default_layout();
        let dock_id = layout.anchored_dock(DockEdge::Right).unwrap().id;
        // Color is at group 1, panel index 0
        let addr = PanelAddr {
            group: GroupAddr { dock_id, group_idx: 1 },
            panel_idx: 0,
        };

        let mut state = test_app_state(layout);
        assert!(state.workspace_layout.is_panel_visible(PanelKind::Color));
        panel_dispatch(PanelKind::Color, "close_panel", addr, &mut state);
        assert!(!state.workspace_layout.is_panel_visible(PanelKind::Color));
    }

    #[test]
    fn panel_is_checked_defaults_false() {
        let layout = WorkspaceLayout::default_layout();
        let state = test_app_state(layout);
        for &kind in PanelKind::ALL {
            assert!(!panel_is_checked(kind, "anything", &state));
        }
    }

    /// Build a minimal AppState for testing (no tabs, default config).
    fn test_app_state(layout: WorkspaceLayout) -> AppState {
        AppState {
            tabs: vec![],
            active_tab: 0,
            active_tool: crate::tools::tool::ToolKind::Selection,
            app_config: crate::workspace::workspace::AppConfig::default(),
            workspace_layout: layout,
            fill_on_top: true,
            color_panel_mode: crate::workspace::color_panel_view::ColorMode::Hsb,
        }
    }
}
