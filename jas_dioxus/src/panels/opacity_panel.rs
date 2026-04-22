//! Opacity panel menu definition.
//!
//! Phase-1 scope: handle the four panel-local toggle commands
//! (`toggle_opacity_thumbnails`, `toggle_opacity_options`,
//! `toggle_new_masks_clipping`, `toggle_new_masks_inverted`). The
//! mask-lifecycle and page-level menu items are declared in the YAML
//! (`workspace/panels/opacity.yaml`) with `enabled_when: "false"`, so they
//! remain inert until later phases add document-model fields and renderer
//! support. `mode` and `opacity` working values are driven by the panel
//! controls (MODE_DROPDOWN, OPACITY_INPUT) via the interpreter's
//! bind-update path, not through this dispatch.

use crate::workspace::app_state::AppState;
use crate::workspace::workspace::PanelAddr;
use super::panel_menu::PanelMenuItem;

/// Menu items for the Opacity panel.
///
/// The YAML mirror lives in `workspace/panels/opacity.yaml`. Items whose
/// semantics depend on document-model or renderer work not yet landed are
/// gated there with `enabled_when: "false"` rather than omitted here — the
/// native menu still shows them so users see the full shape of the panel.
pub fn menu_items() -> Vec<PanelMenuItem> {
    vec![
        PanelMenuItem::Toggle {
            label: "Hide Thumbnails",
            command: "toggle_opacity_thumbnails",
        },
        PanelMenuItem::Toggle {
            label: "Show Options",
            command: "toggle_opacity_options",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Make Opacity Mask",
            command: "make_opacity_mask",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Release Opacity Mask",
            command: "release_opacity_mask",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Disable Opacity Mask",
            command: "disable_opacity_mask",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Unlink Opacity Mask",
            command: "unlink_opacity_mask",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Toggle {
            label: "New Opacity Masks Are Clipping",
            command: "toggle_new_masks_clipping",
        },
        PanelMenuItem::Toggle {
            label: "New Opacity Masks Are Inverted",
            command: "toggle_new_masks_inverted",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Toggle {
            label: "Page Isolated Blending",
            command: "toggle_page_isolated_blending",
        },
        PanelMenuItem::Toggle {
            label: "Page Knockout Group",
            command: "toggle_page_knockout_group",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Close Opacity",
            command: "close_panel",
            shortcut: "",
        },
    ]
}

/// Dispatch a menu command for the Opacity panel.
pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) {
    match cmd {
        "close_panel" => state.workspace_layout.close_panel(addr),
        "toggle_opacity_thumbnails" => {
            state.opacity_panel.thumbnails_hidden = !state.opacity_panel.thumbnails_hidden;
        }
        "toggle_opacity_options" => {
            state.opacity_panel.options_shown = !state.opacity_panel.options_shown;
        }
        "toggle_new_masks_clipping" => {
            state.opacity_panel.new_masks_clipping = !state.opacity_panel.new_masks_clipping;
        }
        "toggle_new_masks_inverted" => {
            state.opacity_panel.new_masks_inverted = !state.opacity_panel.new_masks_inverted;
        }
        // Mask-lifecycle commands route to the document controller. Make
        // uses the document's new_masks_* preferences; the others are
        // first-wins toggles on the selection.
        "make_opacity_mask" => {
            let clip = state.opacity_panel.new_masks_clipping;
            let invert = state.opacity_panel.new_masks_inverted;
            if let Some(tab) = state.tab_mut() {
                crate::document::controller::Controller::make_mask_on_selection(
                    &mut tab.model, clip, invert);
            }
        }
        "release_opacity_mask" => {
            if let Some(tab) = state.tab_mut() {
                crate::document::controller::Controller::release_mask_on_selection(&mut tab.model);
            }
        }
        "disable_opacity_mask" => {
            if let Some(tab) = state.tab_mut() {
                crate::document::controller::Controller::toggle_mask_disabled_on_selection(&mut tab.model);
            }
        }
        "unlink_opacity_mask" => {
            if let Some(tab) = state.tab_mut() {
                crate::document::controller::Controller::toggle_mask_linked_on_selection(&mut tab.model);
            }
        }
        // Page-level blending commands remain deferred in YAML with
        // status: pending_renderer; ignored here.
        _ => {}
    }
}

/// Query whether a toggle/radio command is checked.
pub fn is_checked(cmd: &str, state: &AppState) -> bool {
    match cmd {
        "toggle_opacity_thumbnails" => state.opacity_panel.thumbnails_hidden,
        "toggle_opacity_options"    => state.opacity_panel.options_shown,
        "toggle_new_masks_clipping" => state.opacity_panel.new_masks_clipping,
        "toggle_new_masks_inverted" => state.opacity_panel.new_masks_inverted,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace::workspace::{DockId, GroupAddr, WorkspaceLayout};

    fn test_app_state() -> AppState {
        AppState {
            tabs: vec![],
            active_tab: 0,
            active_tool: crate::tools::tool::ToolKind::Selection,
            app_config: crate::workspace::workspace::AppConfig::default(),
            workspace_layout: WorkspaceLayout::default_layout(),
            fill_on_top: true,
            color_panel_mode: crate::workspace::color_panel_view::ColorMode::Hsb,
            app_default_fill: Some(crate::geometry::element::Fill::new(
                crate::geometry::element::Color::WHITE,
            )),
            app_default_stroke: Some(crate::geometry::element::Stroke::new(
                crate::geometry::element::Color::BLACK,
                1.0,
            )),
            swatch_libraries: serde_json::json!({}),
            stroke_panel: crate::workspace::app_state::StrokePanelState::default(),
            gradient_panel: crate::workspace::app_state::GradientPanelState::default(),
            character_panel: crate::workspace::app_state::CharacterPanelState::default(),
            paragraph_panel: crate::workspace::app_state::ParagraphPanelState::default(),
            align_panel: crate::workspace::app_state::AlignPanelState::default(),
            boolean_panel: crate::workspace::app_state::BooleanPanelState::default(),
            opacity_panel: crate::workspace::app_state::OpacityPanelState::default(),
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
            artboards_panel_selection: Vec::new(),
            artboards_panel_anchor: None,
            artboards_renaming: None,
            artboards_reference_point: "center".to_string(),
            artboards_rearrange_dirty: false,
        }
    }

    fn panel_addr() -> PanelAddr {
        PanelAddr {
            group: GroupAddr {
                dock_id: DockId(0),
                group_idx: 0,
            },
            panel_idx: 0,
        }
    }

    // ── Menu structure ─────────────────────────────────────

    #[test]
    fn menu_has_ten_spec_items_plus_close() {
        // Ten items from OPACITY.md's panel menu spec, plus a trailing
        // "Close Opacity" (every native panel exposes close_panel).
        // Three separators divide the spec groups; a fourth precedes Close.
        let items = menu_items();
        let seps = items.iter().filter(|i| matches!(i, PanelMenuItem::Separator)).count();
        let others = items.iter().filter(|i| !matches!(i, PanelMenuItem::Separator)).count();
        assert_eq!(seps, 4);
        assert_eq!(others, 11);
    }

    #[test]
    fn menu_has_four_toggles_in_panel_local_state() {
        let items = menu_items();
        let toggle_cmds: Vec<&str> = items.iter().filter_map(|i| match i {
            PanelMenuItem::Toggle { command, .. } => Some(*command),
            _ => None,
        }).collect();
        // Four top-of-menu / bottom-of-menu toggles plus two deferred
        // page-level toggles that are still declared as Toggle items.
        assert!(toggle_cmds.contains(&"toggle_opacity_thumbnails"));
        assert!(toggle_cmds.contains(&"toggle_opacity_options"));
        assert!(toggle_cmds.contains(&"toggle_new_masks_clipping"));
        assert!(toggle_cmds.contains(&"toggle_new_masks_inverted"));
    }

    #[test]
    fn menu_has_four_mask_lifecycle_actions_in_order() {
        let items = menu_items();
        let action_cmds: Vec<&str> = items.iter().filter_map(|i| match i {
            PanelMenuItem::Action { command, .. } => Some(*command),
            _ => None,
        }).collect();
        // Four mask-lifecycle actions in spec order, followed by close_panel
        // as the closing action.
        assert_eq!(action_cmds, vec![
            "make_opacity_mask",
            "release_opacity_mask",
            "disable_opacity_mask",
            "unlink_opacity_mask",
            "close_panel",
        ]);
    }

    // ── Dispatch toggles panel-local state ─────────────────

    #[test]
    fn dispatch_toggle_thumbnails_flips_field() {
        let mut st = test_app_state();
        assert!(!st.opacity_panel.thumbnails_hidden);
        dispatch("toggle_opacity_thumbnails", panel_addr(), &mut st);
        assert!(st.opacity_panel.thumbnails_hidden);
        dispatch("toggle_opacity_thumbnails", panel_addr(), &mut st);
        assert!(!st.opacity_panel.thumbnails_hidden);
    }

    #[test]
    fn dispatch_toggle_options_flips_field() {
        let mut st = test_app_state();
        assert!(!st.opacity_panel.options_shown);
        dispatch("toggle_opacity_options", panel_addr(), &mut st);
        assert!(st.opacity_panel.options_shown);
    }

    #[test]
    fn dispatch_toggle_new_masks_clipping_flips_from_default_true() {
        let mut st = test_app_state();
        assert!(st.opacity_panel.new_masks_clipping);
        dispatch("toggle_new_masks_clipping", panel_addr(), &mut st);
        assert!(!st.opacity_panel.new_masks_clipping);
    }

    #[test]
    fn dispatch_toggle_new_masks_inverted_flips_from_default_false() {
        let mut st = test_app_state();
        assert!(!st.opacity_panel.new_masks_inverted);
        dispatch("toggle_new_masks_inverted", panel_addr(), &mut st);
        assert!(st.opacity_panel.new_masks_inverted);
    }

    // ── Integration tests: dispatch routes to the Controller ───

    /// Build a real AppState with one tab containing a layer + one
    /// rect, selected, so dispatch → Controller calls have something
    /// to operate on.
    fn app_state_with_one_selected_rect() -> AppState {
        use crate::document::controller::Controller;
        use crate::geometry::element::{
            CommonProps, Element, LayerElem, RectElem,
        };
        use crate::document::document::{Document, ElementSelection};
        use std::rc::Rc;
        let mut st = AppState::new();
        let rect = Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
            common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        });
        let layer = Element::Layer(LayerElem {
            name: "L0".into(),
            children: vec![Rc::new(rect)],
            common: CommonProps::default(),
            isolated_blending: false,
            knockout_group: false,
        });
        let doc = Document {
            layers: vec![layer],
            selected_layer: 0,
            selection: vec![ElementSelection::all(vec![0, 0])],
            ..Document::default()
        };
        let model = crate::document::model::Model::new(doc, None);
        st.add_tab(crate::workspace::app_state::TabState::with_model(model));
        // Sanity: touch Controller to make sure the path compiles.
        let _ = Controller::make_mask_on_selection;
        st
    }

    fn selection_mask_some(st: &AppState) -> bool {
        st.tab().and_then(|t| {
            let doc = t.model.document();
            let first = doc.selection.first()?;
            doc.get_element(&first.path).map(|e| e.common().mask.is_some())
        }).unwrap_or(false)
    }

    #[test]
    fn dispatch_make_opacity_mask_creates_mask_on_selection() {
        let mut st = app_state_with_one_selected_rect();
        assert!(!selection_mask_some(&st));
        dispatch("make_opacity_mask", panel_addr(), &mut st);
        assert!(selection_mask_some(&st));
    }

    #[test]
    fn dispatch_make_uses_document_defaults_for_clip_invert() {
        let mut st = app_state_with_one_selected_rect();
        st.opacity_panel.new_masks_clipping = false;
        st.opacity_panel.new_masks_inverted = true;
        dispatch("make_opacity_mask", panel_addr(), &mut st);
        let mask = st.tab().unwrap().model.document()
            .get_element(&vec![0, 0]).unwrap()
            .common().mask.as_ref().unwrap().clone();
        assert!(!mask.clip);
        assert!(mask.invert);
    }

    #[test]
    fn dispatch_release_clears_mask_on_selection() {
        let mut st = app_state_with_one_selected_rect();
        dispatch("make_opacity_mask", panel_addr(), &mut st);
        assert!(selection_mask_some(&st));
        dispatch("release_opacity_mask", panel_addr(), &mut st);
        assert!(!selection_mask_some(&st));
    }

    #[test]
    fn dispatch_disable_and_unlink_toggle_mask_fields() {
        let mut st = app_state_with_one_selected_rect();
        dispatch("make_opacity_mask", panel_addr(), &mut st);
        dispatch("disable_opacity_mask", panel_addr(), &mut st);
        let disabled = st.tab().unwrap().model.document()
            .get_element(&vec![0, 0]).unwrap()
            .common().mask.as_ref().unwrap().disabled;
        assert!(disabled);
        dispatch("unlink_opacity_mask", panel_addr(), &mut st);
        let linked = st.tab().unwrap().model.document()
            .get_element(&vec![0, 0]).unwrap()
            .common().mask.as_ref().unwrap().linked;
        assert!(!linked);
    }

    #[test]
    fn dispatch_mask_lifecycle_does_not_touch_panel_state() {
        // The mask menu items route to the Controller and operate on the
        // active tab's document; panel-local state fields must be left
        // alone (they govern UI chrome, not the selection's masks).
        let mut st = test_app_state();
        let before = st.opacity_panel.clone();
        dispatch("make_opacity_mask", panel_addr(), &mut st);
        dispatch("release_opacity_mask", panel_addr(), &mut st);
        dispatch("disable_opacity_mask", panel_addr(), &mut st);
        dispatch("unlink_opacity_mask", panel_addr(), &mut st);
        assert_eq!(before.thumbnails_hidden, st.opacity_panel.thumbnails_hidden);
        assert_eq!(before.options_shown, st.opacity_panel.options_shown);
        assert_eq!(before.new_masks_clipping, st.opacity_panel.new_masks_clipping);
        assert_eq!(before.new_masks_inverted, st.opacity_panel.new_masks_inverted);
    }

    // ── is_checked ─────────────────────────────────────────

    #[test]
    fn is_checked_reflects_panel_state() {
        let mut st = test_app_state();
        assert!(!is_checked("toggle_opacity_thumbnails", &st));
        assert!(is_checked("toggle_new_masks_clipping", &st));
        st.opacity_panel.thumbnails_hidden = true;
        st.opacity_panel.new_masks_clipping = false;
        assert!(is_checked("toggle_opacity_thumbnails", &st));
        assert!(!is_checked("toggle_new_masks_clipping", &st));
    }

    #[test]
    fn is_checked_returns_false_for_unknown_command() {
        let st = test_app_state();
        assert!(!is_checked("nonexistent_command", &st));
        assert!(!is_checked("make_opacity_mask", &st));
    }
}
