//! Character panel menu definition.
//!
//! Mirrors the menu items listed in CHARACTER.md. Toggle items for
//! All Caps / Small Caps / Superscript / Subscript track the same
//! panel-state bools the in-panel icon toggles use, so either surface
//! writes the same attribute on the selection.

use crate::workspace::app_state::AppState;
use crate::workspace::workspace::PanelAddr;
use super::panel_menu::PanelMenuItem;

/// Menu items for the Character panel.
pub fn menu_items() -> Vec<PanelMenuItem> {
    // Source of truth is workspace/panels/character.yaml's `menu:` block
    // (review #15); the generic reader builds the items from the bundle.
    super::panel_menu::menu_items_from_yaml("character_panel_content")
}

/// Dispatch a menu command for the Character panel: the generic route, which
/// runs the item's `actions.yaml` action in the panel's scope, as the engine
/// does (row 174). The toggles' `set_panel_state` lands in the same typed
/// field the panel's own toggles write, and applies it to the selection.
pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) {
    let _ = super::panel_menu::dispatch_yaml_menu("character_panel_content", cmd, addr, state);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace::workspace::{DockId, GroupAddr};

    fn text_state() -> AppState {
        let svg = r#"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="40"><text x="0" y="20">Hello</text></svg>"#;
        let mut st = AppState::new();
        st.add_tab(crate::workspace::app_state::TabState::new());
        st.tabs[st.active_tab].model = crate::document::model::Model::new(
            crate::geometry::svg::svg_to_document(svg), None);
        crate::document::controller::Controller::select_all(&mut st.tabs[st.active_tab].model);
        st
    }

    fn case(st: &AppState) -> (String, String, String) {
        use crate::geometry::element::Element;
        let doc = st.tabs[st.active_tab].model.document();
        doc.selection.iter().find_map(|es| match doc.get_element(&es.path) {
            Some(Element::Text(t)) =>
                Some((t.text_transform.clone(), t.font_variant.clone(), t.baseline_shift.clone())),
            _ => None,
        }).expect("a selected text element")
    }

    /// Row 174: the web's Character menu runs its actions.yaml entries, and
    /// the result on the ELEMENT is the engine's (`ffi` arm
    /// `every_live_character_menu_item_runs_in_the_engine`, the same sequence).
    #[test]
    fn the_character_menu_runs_its_yaml_on_the_web() {
        let addr = PanelAddr { group: GroupAddr { dock_id: DockId(0), group_idx: 0 }, panel_idx: 0 };
        let mut st = text_state();
        let s = |a: &str, b: &str, c: &str| (a.to_string(), b.to_string(), c.to_string());
        assert_eq!(case(&st), s("", "", ""), "the control");
        for (cmd, want, why) in [
            ("toggle_all_caps", s("uppercase", "", ""), "All Caps"),
            ("toggle_small_caps", s("", "small-caps", ""), "Small Caps clears All Caps"),
            ("toggle_superscript", s("", "small-caps", "super"), "Superscript"),
            ("toggle_subscript", s("", "small-caps", "sub"), "Subscript clears Superscript"),
            ("toggle_subscript", s("", "small-caps", ""), "Subscript again turns it off"),
            ("toggle_small_caps", s("", "", ""), "Small Caps again turns it off"),
        ] {
            dispatch(cmd, addr, &mut st);
            assert_eq!(case(&st), want, "{why}");
        }
        let before = st.character_panel.snap_to_glyph_visible;
        dispatch("toggle_snap_to_glyph_visible", addr, &mut st);
        assert_ne!(st.character_panel.snap_to_glyph_visible, before, "Show Snap to Glyph Options");
    }
}
