//! Panel definitions: one module per panel kind.
//!
//! Each panel module defines its menu items, dispatch function,
//! and checked-state query. Panel labels are read from the workspace
//! YAML `summary:` field. This module provides unified lookup functions
//! that dispatch by [`PanelKind`].

pub mod panel_menu;
pub mod panel_menu_state;
pub mod panel_menu_view;

pub mod align_panel;
pub mod artboards_panel;
pub mod boolean_panel;
pub mod brushes_panel;
pub mod character_panel;
pub mod color_panel;
pub mod layers_panel;
pub mod magic_wand_panel;
pub mod opacity_panel;
pub mod paragraph_panel;
pub mod properties_panel;
pub mod stroke_panel;
pub mod swatches_panel;
pub mod symbols_panel;

use crate::interpreter::workspace::{Workspace, panel_kind_to_content_id};
use crate::workspace::app_state::AppState;
use crate::workspace::workspace::{PanelAddr, PanelKind};
use panel_menu::PanelMenuItem;

/// Human-readable label for a panel kind, read from the workspace YAML
/// `summary:` field of the panel's content spec.
pub fn panel_label(kind: PanelKind) -> String {
    let content_id = panel_kind_to_content_id(kind);
    Workspace::load()
        .and_then(|ws| ws.panel(content_id)?.get("summary")?.as_str().map(String::from))
        .unwrap_or_else(|| {
            content_id.strip_suffix("_panel_content").unwrap_or("Panel").to_string()
        })
}

/// Menu items for a panel kind.
pub fn panel_menu(kind: PanelKind) -> Vec<PanelMenuItem> {
    match kind {
        PanelKind::Layers => layers_panel::menu_items(),
        PanelKind::Color => color_panel::menu_items(),
        PanelKind::Swatches => swatches_panel::menu_items(),
        PanelKind::Brushes => brushes_panel::menu_items(),
        PanelKind::Stroke => stroke_panel::menu_items(),
        PanelKind::Properties => properties_panel::menu_items(),
        PanelKind::Character => character_panel::menu_items(),
        PanelKind::Paragraph => paragraph_panel::menu_items(),
        PanelKind::Artboards => artboards_panel::menu_items(),
        PanelKind::Align => align_panel::menu_items(),
        PanelKind::Boolean => boolean_panel::menu_items(),
        PanelKind::Opacity => opacity_panel::menu_items(),
        PanelKind::MagicWand => magic_wand_panel::menu_items(),
        PanelKind::Symbols => symbols_panel::menu_items(),
        // Gradient / Concepts are rendered generically from the YAML bundle
        // and have no native panel module, so their hamburger menu is empty
        // (the bundle supplies any panel-menu rows). They exist as PanelKind
        // variants purely so the dock can show/hide them by the generic
        // toggle_panel path.
        PanelKind::Gradient | PanelKind::Concepts => Vec::new(),
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
        PanelKind::Brushes => brushes_panel::dispatch(cmd, addr, state),
        PanelKind::Stroke => stroke_panel::dispatch(cmd, addr, state),
        PanelKind::Properties => properties_panel::dispatch(cmd, addr, state),
        PanelKind::Character => character_panel::dispatch(cmd, addr, state),
        PanelKind::Paragraph => paragraph_panel::dispatch(cmd, addr, state),
        PanelKind::Artboards => artboards_panel::dispatch(cmd, addr, state),
        PanelKind::Align => align_panel::dispatch(cmd, addr, state),
        PanelKind::Boolean => boolean_panel::dispatch(cmd, addr, state),
        PanelKind::Opacity => opacity_panel::dispatch(cmd, addr, state),
        PanelKind::MagicWand => magic_wand_panel::dispatch(cmd, addr, state),
        PanelKind::Symbols => symbols_panel::dispatch(cmd, addr, state),
        // No native module (YAML-rendered): no bespoke menu commands.
        PanelKind::Gradient | PanelKind::Concepts => {}
    }
}

/// Override the static menu label for a panel command, if the panel
/// declares a dynamic label for that command. Returns None to use
/// the static label from `panel_menu`. Used by the menu view to show
/// state-dependent labels like "Hide All Layers" / "Show All Layers".
pub(crate) fn panel_dynamic_label(
    kind: PanelKind,
    cmd: &str,
    state: &AppState,
) -> Option<String> {
    match kind {
        PanelKind::Layers => layers_panel::dynamic_label(cmd, state),
        _ => None,
    }
}

/// Query whether a toggle/radio command is checked for a panel kind.
///
/// ONE path for every panel: the panel's bundle menu entry is looked up by its
/// runtime command, its `checked_when:` / `checked:` predicate is evaluated
/// against the panel's context, and that is the answer. The fourteen per-panel
/// native `is_checked` hooks this replaced are gone — with them went a
/// `return false` in `brushes_panel` whose comment claimed "the generic
/// menu-state evaluator resolves" the predicates it was silently dropping, and
/// six `match cmd` arms that re-stated in Rust a rule the YAML already stated.
///
/// The port-specific residue is `panel_menu::panel_menu_ctx`: where this app
/// KEEPS each live value, not what the menu does with it.
pub(crate) fn panel_is_checked(kind: PanelKind, cmd: &str, state: &AppState) -> bool {
    let content_id = crate::interpreter::workspace::panel_kind_to_content_id(kind);
    let ctx = panel_menu::panel_menu_ctx(content_id, state);
    panel_menu::is_checked_from_yaml(content_id, cmd, &ctx)
}

/// Query whether a menu command is enabled for a panel kind. Defaults
/// to `true` for panels / commands without a state-conditional rule.
pub(crate) fn panel_is_enabled(kind: PanelKind, cmd: &str, state: &AppState) -> bool {
    match kind {
        PanelKind::Color => color_panel::is_enabled(cmd, state),
        PanelKind::Swatches => swatches_panel::is_enabled(cmd, state),
        _ => true,
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
        assert_eq!(panel_label(PanelKind::Properties), "Object properties");
        assert_eq!(panel_label(PanelKind::Align), "Align");
    }

    #[test]
    fn align_panel_menu_has_expected_entries() {
        let items = panel_menu(PanelKind::Align);
        // Three entries + two separators = 5 total per ALIGN.md.
        assert_eq!(items.len(), 5);
        assert!(matches!(
            items[0],
            PanelMenuItem::Toggle { command: "toggle_use_preview_bounds", .. }
        ));
        assert!(matches!(items[1], PanelMenuItem::Separator));
        assert!(matches!(
            items[2],
            PanelMenuItem::Action { command: "reset_align_panel", .. }
        ));
        assert!(matches!(items[3], PanelMenuItem::Separator));
        assert!(matches!(
            items[4],
            PanelMenuItem::Action { command: "close_panel", label: "Close Align", .. }
        ));
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
        // default_layout has Right dock: group 0 = [Color, Swatches], group 1 = [Stroke, Properties], group 2 = [Layers]
        let layout = WorkspaceLayout::default_layout();
        let dock_id = layout.anchored_dock(DockEdge::Right).unwrap().id;
        // Color is at group 0, panel index 0
        let addr = PanelAddr {
            group: GroupAddr { dock_id, group_idx: 0 },
            panel_idx: 0,
        };

        let mut state = test_app_state(layout);
        assert!(state.workspace_layout.is_panel_visible(PanelKind::Color));
        panel_dispatch(PanelKind::Color, "close_panel", addr, &mut state);
        assert!(!state.workspace_layout.is_panel_visible(PanelKind::Color));
    }

    /// The Brushes panel's eleven `checked_when:` predicates, through the
    /// generic panel-menu evaluator.
    ///
    /// Until this landed `brushes_panel::is_checked` was `false` for every
    /// command, with a comment claiming "the generic menu-state evaluator
    /// resolves" the bundle's predicates — which it did not, because
    /// `menu_state` is the MENUBAR walk and never ran on a panel's menu. All
    /// eleven check marks were dead here while five of them worked in
    /// JasSwift's hand-coded rule: a live prime-directive divergence.
    #[test]
    fn panel_is_checked_evaluates_brushes_checked_when() {
        let layout = WorkspaceLayout::default_layout();
        let state = test_app_state(layout);
        // brushes.yaml declares `category_filter` default `[calligraphic,
        // scatter, art, pattern, bristle]`, `view_mode: thumbnail` and
        // `thumbnail_size: small`, so a panel with no live overrides shows
        // exactly those check marks.
        for cat in ["calligraphic", "scatter", "art", "pattern", "bristle"] {
            assert!(
                panel_is_checked(
                    PanelKind::Brushes,
                    &format!("toggle_brush_category:{cat}"),
                    &state
                ),
                "Show {cat} Brushes should be checked at the declared default"
            );
        }
        assert!(panel_is_checked(
            PanelKind::Brushes, "set_brush_view_mode:thumbnail", &state));
        assert!(!panel_is_checked(
            PanelKind::Brushes, "set_brush_view_mode:list", &state));
        assert!(panel_is_checked(
            PanelKind::Brushes, "set_brush_thumbnail_size:small", &state));
        assert!(!panel_is_checked(
            PanelKind::Brushes, "set_brush_thumbnail_size:medium", &state));
        assert!(!panel_is_checked(
            PanelKind::Brushes, "set_brush_thumbnail_size:large", &state));
        // "Make Persistent" reads a namespace no native hook ever consulted:
        // `any(preferences.brushes.persistent_libraries, fun lib -> lib ==
        // panel.selected_library)`. preferences.yaml lists `default_brushes`
        // and brushes.yaml's `selected_library` defaults to it, so it is
        // checked — and it was dead in BOTH active ports before this.
        assert!(panel_is_checked(
            PanelKind::Brushes, "toggle_brush_library_persistent", &state));
        // A command that names no menu entry is not checked, and neither is
        // an entry that declares no predicate.
        assert!(!panel_is_checked(PanelKind::Brushes, "sort_brushes_by_name", &state));
        assert!(!panel_is_checked(PanelKind::Brushes, "no_such_command", &state));
    }

    /// The panels whose check marks ALREADY worked natively must keep working
    /// once the native hooks are gone — the generic evaluator has to read the
    /// same live values the hooks read, not the bundle defaults.
    #[test]
    fn panel_is_checked_still_follows_live_state_for_the_native_panels() {
        let layout = WorkspaceLayout::default_layout();
        let mut state = test_app_state(layout);

        state.opacity_panel.thumbnails_hidden = true;
        state.opacity_panel.new_masks_clipping = false;
        assert!(panel_is_checked(PanelKind::Opacity, "toggle_opacity_thumbnails", &state));
        assert!(!panel_is_checked(PanelKind::Opacity, "toggle_new_masks_clipping", &state));
        state.opacity_panel.thumbnails_hidden = false;
        state.opacity_panel.new_masks_clipping = true;
        assert!(!panel_is_checked(PanelKind::Opacity, "toggle_opacity_thumbnails", &state));
        assert!(panel_is_checked(PanelKind::Opacity, "toggle_new_masks_clipping", &state));

        state.color_panel_mode = crate::workspace::color_panel_view::ColorMode::Cmyk;
        assert!(panel_is_checked(PanelKind::Color, "set_color_panel_mode:cmyk", &state));
        assert!(!panel_is_checked(PanelKind::Color, "set_color_panel_mode:rgb", &state));

        state.stroke_panel.cap = "round".to_string();
        state.stroke_panel.join = "bevel".to_string();
        assert!(panel_is_checked(PanelKind::Stroke, "set_stroke_cap:round", &state));
        assert!(!panel_is_checked(PanelKind::Stroke, "set_stroke_cap:butt", &state));
        assert!(panel_is_checked(PanelKind::Stroke, "set_stroke_join:bevel", &state));
        assert!(!panel_is_checked(PanelKind::Stroke, "set_stroke_join:miter", &state));

        state.swatches_panel.thumbnail_size = "medium".to_string();
        assert!(panel_is_checked(
            PanelKind::Swatches, "set_swatch_thumbnail_size:medium", &state));
        assert!(!panel_is_checked(
            PanelKind::Swatches, "set_swatch_thumbnail_size:small", &state));

        state.character_panel.all_caps = true;
        state.character_panel.small_caps = false;
        assert!(panel_is_checked(PanelKind::Character, "toggle_all_caps", &state));
        assert!(!panel_is_checked(PanelKind::Character, "toggle_small_caps", &state));

        state.paragraph_panel.hanging_punctuation = true;
        assert!(panel_is_checked(
            PanelKind::Paragraph, "toggle_hanging_punctuation", &state));

        state.align_panel.use_preview_bounds = true;
        assert!(panel_is_checked(PanelKind::Align, "toggle_use_preview_bounds", &state));
        state.align_panel.use_preview_bounds = false;
        assert!(!panel_is_checked(PanelKind::Align, "toggle_use_preview_bounds", &state));
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
            prior_tool_for_spacebar: None,
            app_config: crate::workspace::workspace::AppConfig::default(),
            workspace_layout: layout,
            fill_on_top: true,
            color_panel_mode: crate::workspace::color_panel_view::ColorMode::Hsb,
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
            layers_type_filter: std::collections::HashSet::new(),
            layers_filter_dropdown_open: false,
            artboards_panel_selection: Vec::new(),
            artboards_panel_anchor: None,
            artboards_renaming: None,
            artboards_reference_point: "center".to_string(),
            artboards_rearrange_dirty: false,
            symbols_selected: None,
            properties_constrain: false,
            concepts_selected: None,
        }
    }
}
