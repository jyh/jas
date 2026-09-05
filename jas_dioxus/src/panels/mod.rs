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

/// Query whether a menu command is enabled for a panel kind.
///
/// ONE path for every panel, the twin of `panel_is_checked`: the panel's
/// bundle menu entry is looked up by its runtime command, its `enabled_when:`
/// predicate is evaluated against the panel's context, and that is the answer
/// (`true` with no predicate, as `menu_state` defaults). The two native hooks
/// this replaced — Color's `active_color().is_some()`, Swatches'
/// `!selected_swatches.is_empty()` — restated rules color.yaml and
/// swatches.yaml already state; every other panel answered `true` without
/// reading the YAML at all, so "New Brush" never greyed out and the gradient
/// rows declared `enabled_when: "false"` stayed live in both active ports.
pub(crate) fn panel_is_enabled(kind: PanelKind, cmd: &str, state: &AppState) -> bool {
    let content_id = crate::interpreter::workspace::panel_kind_to_content_id(kind);
    let ctx = panel_menu::panel_menu_ctx(content_id, state);
    panel_menu::is_enabled_from_yaml(content_id, cmd, &ctx)
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

    /// The PRODUCTION route for a Brushes menu click: the folded command the
    /// menu view dispatches must reach the panel's declared action WITH its
    /// params, the action's generic `set_panel_state` must land in the Brushes
    /// panel's own state, and the check mark must follow.
    ///
    /// Before this landed the chain broke twice over. `brushes_panel::dispatch`
    /// handed the FOLDED command (`set_brush_view_mode:list`) to
    /// `dispatch_action` with an empty params map, so no action of that name
    /// existed and nothing ran; and had it run,
    /// `renderer::apply_set_panel_state_with_ctx` dispatched on the effect's
    /// `key` alone, ignored the `panel: brushes` the effect names, and fell
    /// through to the STROKE panel. jas_dioxus stored no Brushes panel state at
    /// all, so every Brushes check mark evaluated the declared default forever
    /// while JasSwift's shared panel store moved with the user.
    #[test]
    fn brushes_menu_click_moves_the_check_mark() {
        let layout = WorkspaceLayout::default_layout();
        let mut state = test_app_state(layout);
        let addr = PanelAddr {
            group: GroupAddr { dock_id: crate::workspace::workspace::DockId(0), group_idx: 0 },
            panel_idx: 0,
        };

        // The view-mode radio moves, and with it the enabled-ness of the three
        // thumbnail-size rows (brushes.yaml gates those on view_mode).
        brushes_panel::dispatch("set_brush_view_mode:list", addr, &mut state);
        assert!(panel_is_checked(PanelKind::Brushes, "set_brush_view_mode:list", &state),
            "List View should be checked after the menu click");
        assert!(!panel_is_checked(PanelKind::Brushes, "set_brush_view_mode:thumbnail", &state),
            "Thumbnail View should have lost its check mark");

        // A second, independent key: the two radios do not share a slot.
        brushes_panel::dispatch("set_brush_thumbnail_size:large", addr, &mut state);
        assert!(panel_is_checked(PanelKind::Brushes, "set_brush_thumbnail_size:large", &state));
        assert!(!panel_is_checked(PanelKind::Brushes, "set_brush_thumbnail_size:small", &state));
        // ...and the first write survived the second.
        assert!(panel_is_checked(PanelKind::Brushes, "set_brush_view_mode:list", &state));
    }

    /// Two panels declare a `thumbnail_size` and both write it through the SAME
    /// generic `set_panel_state` effect. A handler that dispatches on the
    /// effect's `key` alone — which is what this app did — cannot tell them
    /// apart, so this is the sharpest statement of why the `panel:` the effect
    /// names has to be read.
    #[test]
    fn brushes_and_swatches_keep_separate_thumbnail_sizes() {
        let layout = WorkspaceLayout::default_layout();
        let mut state = test_app_state(layout);
        let addr = PanelAddr {
            group: GroupAddr { dock_id: crate::workspace::workspace::DockId(0), group_idx: 0 },
            panel_idx: 0,
        };

        swatches_panel::dispatch("set_swatch_thumbnail_size:medium", addr, &mut state);
        brushes_panel::dispatch("set_brush_thumbnail_size:large", addr, &mut state);

        assert!(panel_is_checked(
            PanelKind::Swatches, "set_swatch_thumbnail_size:medium", &state),
            "the Swatches size must not follow the Brushes write");
        assert!(panel_is_checked(
            PanelKind::Brushes, "set_brush_thumbnail_size:large", &state),
            "the Brushes size must not follow the Swatches write");
    }

    /// Where this app WRITES a declared panel key and where it READS one back
    /// have to be the same place.
    ///
    /// `panel_menu::typed_panel_slot_keys` names the five (panel, key) pairs a
    /// panel-named `set_panel_state` is routed into a typed `AppState` slot for
    /// instead of into the generic per-panel table; `panel_menu_ctx` builds the
    /// scope a panel menu evaluates against. This drives each pair END TO END —
    /// the real write path, then the real read path — because a weaker test
    /// (does the key APPEAR in the context?) is answered by the bundle's
    /// declared defaults and cannot fail.
    #[test]
    fn every_typed_write_target_round_trips_through_the_menu_context() {
        let claimed = panel_menu::typed_panel_slot_keys();
        assert_eq!(claimed.len(), 5, "the typed-slot census changed; add a probe below");
        for (content_id, key) in claimed {
            // A value the key's own enum / type accepts and that is NOT the
            // declared default, so a write that silently does nothing reds.
            let (value_expr, expected) = match (content_id, key) {
                ("color_panel_content", "mode") => ("\"cmyk\"", serde_json::json!("cmyk")),
                ("swatches_panel_content", "thumbnail_size") =>
                    ("\"large\"", serde_json::json!("large")),
                ("symbols_panel_content", "selected_symbol") =>
                    ("\"star\"", serde_json::json!("star")),
                ("concepts_panel_content", "selected_concept") =>
                    ("\"triangle\"", serde_json::json!("triangle")),
                ("layers_panel_content", "type_filter") =>
                    ("[\"path\"]", serde_json::json!(["path"])),
                other => panic!("no probe for {other:?}"),
            };
            let layout = WorkspaceLayout::default_layout();
            let mut state = test_app_state(layout);
            let before = panel_menu::panel_menu_ctx(content_id, &state)["panel"][key].clone();
            assert_ne!(
                before, expected,
                "{content_id}/{key}: the probe equals the default and cannot fail"
            );

            let mut sps = serde_json::Map::new();
            sps.insert("panel".into(), serde_json::Value::String(content_id.to_string()));
            sps.insert("key".into(), serde_json::Value::String(key.to_string()));
            sps.insert("value".into(), serde_json::Value::String(value_expr.to_string()));
            crate::interpreter::renderer::apply_set_panel_state_with_ctx(&sps, &mut state, None);

            assert_eq!(
                panel_menu::panel_menu_ctx(content_id, &state)["panel"][key],
                expected,
                "{content_id} writes `{key}` somewhere panel_menu_ctx cannot see"
            );
            // ...and the generic table did not ALSO take a copy: a key with two
            // homes is the split-brain this routing exists to prevent.
            assert!(
                state.panel_state.get(content_id).map_or(true, |m| !m.contains_key(key)),
                "{content_id}/{key} landed in BOTH the typed slot and the generic table"
            );
        }
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
            panel_state: std::collections::HashMap::new(),
        }
    }

    /// Build a real AppState holding one tab whose document has a layer with
    /// a rect at `[0, 0]` — SELECTED on the canvas, the state every "needs a
    /// canvas selection" predicate is about — and a group at `[0, 1]` for the
    /// layers-panel rollups (a group is a container AND a group; a layer is a
    /// container only; a rect is neither). Same construction as
    /// `opacity_panel::tests::app_state_with_one_selected_rect`, plus the group.
    fn app_state_with_one_selected_rect() -> AppState {
        use crate::geometry::element::{CommonProps, Element, GroupElem, LayerElem, RectElem};
        use crate::document::document::{Document, ElementSelection};
        use std::rc::Rc;
        let mut st = AppState::new();
        let rect = |x: f64| Element::Rect(RectElem {
            x, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        });
        let group = Element::Group(GroupElem {
            children: vec![Rc::new(rect(20.0))],
            common: CommonProps { name: Some("G".into()), ..Default::default() },
            isolated_blending: false,
            knockout_group: false,
        });
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(rect(0.0)), Rc::new(group)],
            common: CommonProps { name: Some("L0".into()), ..Default::default() },
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
        st
    }

    /// The panel menus' `enabled_when:` predicates, through the generic
    /// panel-menu evaluator — the `enabled` half of what
    /// `test_fixtures/algorithms/panel_menu_state.json` pins.
    ///
    /// Until this landed `panel_is_enabled` answered `true` for every panel but
    /// Color and Swatches, whose native `is_enabled` hooks restated in Rust two
    /// rules the YAML already states; the other forty-odd `enabled_when` rows
    /// were never evaluated live in EITHER active port, so "New Brush" was
    /// never greyed out and every gradient row declared `enabled_when:
    /// "false"` read as enabled. The corpus arm could not see it: it seeds the
    /// context directly and says nothing about whether an app BUILDS one.
    #[test]
    fn panel_is_enabled_evaluates_the_yaml_predicates() {
        let layout = WorkspaceLayout::default_layout();
        let mut st = test_app_state(layout);

        // brushes.yaml: "New Brush" reads `active_document.has_selection` —
        // no document, no selection.
        assert!(
            !panel_is_enabled(PanelKind::Brushes, "open_brush_options:create", &st),
            "New Brush needs a canvas selection"
        );
        // `panel.selected_brushes.length > 0`, read from the GENERIC table
        // (#116): empty at the declared default, live after a write.
        assert!(!panel_is_enabled(PanelKind::Brushes, "duplicate_brush", &st));
        assert!(!panel_is_enabled(PanelKind::Brushes, "delete_brush", &st));
        st.panel_state
            .entry("brushes_panel_content".to_string())
            .or_default()
            .insert("selected_brushes".into(), serde_json::json!([0]));
        assert!(panel_is_enabled(PanelKind::Brushes, "duplicate_brush", &st));
        assert!(panel_is_enabled(PanelKind::Brushes, "delete_brush", &st));

        // symbols.yaml / concepts.yaml: `panel.selected_* != null`, published
        // from the typed slots.
        assert!(!panel_is_enabled(PanelKind::Symbols, "place_instance", &st));
        st.symbols_selected = Some("star".into());
        assert!(panel_is_enabled(PanelKind::Symbols, "place_instance", &st));
        assert!(!panel_is_enabled(PanelKind::Concepts, "place_concept_instance", &st));
        st.concepts_selected = Some("chair".into());
        assert!(panel_is_enabled(PanelKind::Concepts, "place_concept_instance", &st));

        // layers.yaml: "Exit Isolation Mode" reads `panel.isolation_stack.length`.
        assert!(!panel_is_enabled(PanelKind::Layers, "exit_isolation_mode", &st));
        st.layers_isolation_stack.push(vec![0]);
        assert!(panel_is_enabled(PanelKind::Layers, "exit_isolation_mode", &st));

        // artboards.yaml: `active_document.artboards_panel_selection_ids.length`.
        assert!(!panel_is_enabled(PanelKind::Artboards, "open_artboard_options", &st));
        st.artboards_panel_selection.push("ab-1".into());
        assert!(panel_is_enabled(PanelKind::Artboards, "open_artboard_options", &st));

        // gradient.yaml: a literal `enabled_when: "false"` is a disabled row.
        assert!(!panel_is_enabled(PanelKind::Gradient, "gradient_reverse", &st));

        // No predicate, and no entry at all: enabled — `menu_state`'s default.
        assert!(panel_is_enabled(PanelKind::Brushes, "select_all_unused_brushes", &st));
        assert!(panel_is_enabled(PanelKind::Brushes, "no_such_command", &st));

        // With a real selection on the canvas: New Brush lights, a mask can
        // be made but not released, and New Symbol's `selection_count == 1`.
        let mut sel = app_state_with_one_selected_rect();
        assert!(panel_is_enabled(PanelKind::Brushes, "open_brush_options:create", &sel));
        assert!(panel_is_enabled(PanelKind::Opacity, "make_opacity_mask", &sel));
        assert!(!panel_is_enabled(PanelKind::Opacity, "release_opacity_mask", &sel));
        assert!(panel_is_enabled(PanelKind::Symbols, "new_symbol", &sel));
        // Put a mask on the selection: the four mask rows flip together.
        crate::document::controller::Controller::make_mask_on_selection(
            &mut sel.tabs[0].model, true, false);
        assert!(!panel_is_enabled(PanelKind::Opacity, "make_opacity_mask", &sel));
        assert!(panel_is_enabled(PanelKind::Opacity, "release_opacity_mask", &sel));
        assert!(panel_is_enabled(PanelKind::Opacity, "disable_opacity_mask", &sel));
        assert!(panel_is_enabled(PanelKind::Opacity, "unlink_opacity_mask", &sel));

        // layers.yaml's rollups over the LAYERS-PANEL selection on that
        // document (runtime_contexts.yaml: is_container = the sole selected
        // item is a group or layer; has_group = any selected item is a group).
        // `[0]` is the layer, `[0, 0]` the rect, `[0, 1]` the group.
        sel.layers_panel_selection = vec![vec![0]];
        assert!(panel_is_enabled(PanelKind::Layers, "new_group", &sel));
        assert!(panel_is_enabled(PanelKind::Layers, "enter_isolation_mode", &sel),
                "a layer is a container");
        assert!(!panel_is_enabled(PanelKind::Layers, "flatten_artwork", &sel),
                "a layer is not a group");
        assert!(panel_is_enabled(PanelKind::Layers, "collect_in_new_layer", &sel));
        sel.layers_isolation_stack.push(vec![0]);
        assert!(!panel_is_enabled(PanelKind::Layers, "collect_in_new_layer", &sel),
                "not while isolated: the conjunction's second half");
        sel.layers_isolation_stack.clear();
        sel.layers_panel_selection = vec![vec![0, 0]];
        assert!(!panel_is_enabled(PanelKind::Layers, "enter_isolation_mode", &sel),
                "a rect is not a container");
        assert!(!panel_is_enabled(PanelKind::Layers, "flatten_artwork", &sel));
        sel.layers_panel_selection = vec![vec![0, 1]];
        assert!(panel_is_enabled(PanelKind::Layers, "enter_isolation_mode", &sel),
                "a group is a container");
        assert!(panel_is_enabled(PanelKind::Layers, "flatten_artwork", &sel),
                "a group is a group");
        sel.layers_panel_selection = vec![vec![0, 0], vec![0, 1]];
        assert!(!panel_is_enabled(PanelKind::Layers, "enter_isolation_mode", &sel),
                "two items: not the SOLE selected item");
        assert!(panel_is_enabled(PanelKind::Layers, "flatten_artwork", &sel),
                "at least one of them is a group");
        sel.layers_panel_selection.clear();
        assert!(!panel_is_enabled(PanelKind::Layers, "new_group", &sel));
    }

    /// The two panels whose enabled state ALREADY worked natively must keep
    /// working once their hooks are gone — the generic evaluator has to read
    /// the same live values the hooks read (`active_color()`'s tiers for
    /// Color, the typed swatches selection for Swatches), not the bundle
    /// defaults.
    #[test]
    fn panel_is_enabled_still_follows_live_state_for_the_native_panels() {
        let layout = WorkspaceLayout::default_layout();
        let mut st = test_app_state(layout);

        // color.yaml: `if state.fill_on_top then state.fill_color != null else
        // state.stroke_color != null`. test_app_state seeds a white app-tier
        // fill and a black app-tier stroke, fill on top.
        assert!(panel_is_enabled(PanelKind::Color, "invert_active_color", &st));
        assert!(panel_is_enabled(PanelKind::Color, "complement_active_color", &st));
        st.app_default_fill = None;
        assert!(
            !panel_is_enabled(PanelKind::Color, "invert_active_color", &st),
            "no fill in any tier, fill on top: nothing to invert"
        );
        st.fill_on_top = false;
        assert!(
            panel_is_enabled(PanelKind::Color, "invert_active_color", &st),
            "stroke on top, and the stroke tier holds black"
        );
        // …and the swatches selection lives in a typed slot.
        assert!(!panel_is_enabled(PanelKind::Swatches, "delete_swatch", &st));
        assert!(!panel_is_enabled(PanelKind::Swatches, "duplicate_swatch", &st));
        st.swatches_panel.selected_swatches = vec![2];
        assert!(panel_is_enabled(PanelKind::Swatches, "delete_swatch", &st));
        assert!(panel_is_enabled(PanelKind::Swatches, "duplicate_swatch", &st));
    }

    /// The namespace reads a panel-menu predicate string makes: every
    /// `<head>.<key>` whose head is one of the four namespaces the menu
    /// context publishes, plus the bare OPACITY.md selection predicates. The
    /// scanner is a receiver assumption, stated: it skips string literals,
    /// keeps two segments (`panel.selected_brushes`, not `.length`), and a
    /// bare identifier outside the listed five is invisible to it — the
    /// reference's own parser censuses bare names in
    /// `workspace_interpreter/tests/test_panel_menu_state.py`, so a new one
    /// reds there.
    fn predicate_reads(expr: &str) -> Vec<String> {
        const HEADS: [&str; 4] = ["state", "panel", "active_document", "preferences"];
        const BARE: [&str; 5] = [
            "selection_has_mask", "selection_mask_clip", "selection_mask_invert",
            "selection_mask_linked", "editing_target_is_mask",
        ];
        let mut out = Vec::new();
        // Even-indexed pieces are outside quotes (both quote styles occur).
        for (i, piece) in expr.split(|c| c == '"' || c == '\'').enumerate() {
            if i % 2 == 1 { continue; }
            let mut ident = String::new();
            let flush = |ident: &mut String, out: &mut Vec<String>| {
                if ident.is_empty() { return; }
                let segs: Vec<&str> = ident.split('.').collect();
                if segs.len() >= 2 && HEADS.contains(&segs[0]) {
                    out.push(format!("{}.{}", segs[0], segs[1]));
                } else if segs.len() == 1 && BARE.contains(&segs[0]) {
                    out.push(segs[0].to_string());
                }
                ident.clear();
            };
            for c in piece.chars() {
                if c.is_ascii_alphanumeric() || c == '_' || c == '.' {
                    ident.push(c);
                } else {
                    flush(&mut ident, &mut out);
                }
            }
            flush(&mut ident, &mut out);
        }
        out
    }

    fn ctx_has_path(ctx: &serde_json::Value, path: &str) -> bool {
        let mut cur = ctx;
        for seg in path.split('.') {
            match cur.get(seg) {
                Some(v) => cur = v,
                None => return false,
            }
        }
        true
    }

    /// Every read a panel-menu predicate makes resolves to a key the LIVE
    /// menu context publishes. "Which decisions have no witness" and "which
    /// reads have no source" are two different passes; this is the second.
    ///
    /// A key may legitimately be null (`panel.selected_symbol`), so presence
    /// is the assertion, not truthiness. The positive control is the read
    /// count: a scanner that matched nothing would pass an empty census.
    #[test]
    fn every_panel_menu_predicate_read_is_published_to_the_menu_context() {
        let ws = crate::interpreter::workspace::Workspace::load().expect("bundle");
        let panels = ws.data().get("panels").and_then(|p| p.as_object()).expect("panels");
        let st = app_state_with_one_selected_rect();
        let mut reads = 0usize;
        let mut missing: Vec<String> = Vec::new();
        for (content_id, panel) in panels {
            let Some(menu) = panel.get("menu").and_then(|m| m.as_array()) else { continue };
            let ctx = panel_menu::panel_menu_ctx(content_id, &st);
            for e in menu {
                let Some(obj) = e.as_object() else { continue };
                for key in ["enabled_when", "checked_when", "checked"] {
                    let Some(expr) = obj.get(key).and_then(|v| v.as_str()) else { continue };
                    for path in predicate_reads(expr) {
                        reads += 1;
                        if !ctx_has_path(&ctx, &path) {
                            missing.push(format!("{content_id}: {key}: {expr:?} reads {path}"));
                        }
                    }
                }
            }
        }
        assert!(reads >= 40, "positive control: only {reads} predicate reads found");
        assert!(
            missing.is_empty(),
            "panel-menu predicate reads the menu context does not publish:\n{}",
            missing.join("\n")
        );
    }
}
