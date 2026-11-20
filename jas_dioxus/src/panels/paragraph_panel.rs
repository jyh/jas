//! Paragraph panel menu definition.
//!
//! Mirrors the menu items declared in `workspace/panels/paragraph.yaml`.
//! Hanging Punctuation runs its actions.yaml entry on the generic route
//! (row 181), whose effect derives the panel from the selection first;
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
        // The generic route (row 181): the item's YAML runs
        // `toggle_paragraph_field`, whose arm derives the panel from the
        // SELECTION before it flips the one field and applies the whole panel.
        // The native arm this replaced flipped the typed slot as the last
        // write left it, so after a selection change it stamped the previous
        // paragraph's indents and alignment over the new one.
        "toggle_hanging_punctuation" => {
            return super::panel_menu::dispatch_yaml_menu("paragraph_panel_content", cmd, addr, state);
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::controller::Controller;
    use crate::geometry::element::Element;
    use crate::panels::{panel_is_checked, PanelKind};
    use crate::workspace::workspace::{DockId, GroupAddr};

    /// Two area texts, one paragraph each. The SECOND carries Hanging
    /// Punctuation and a 12 pt left indent; the first carries neither.
    fn two_paragraphs() -> AppState {
        let svg = r#"<svg xmlns="http://www.w3.org/2000/svg" xmlns:jas="urn:jas:1" width="200" height="100"><text x="0" y="20" font-size="12" style="inline-size: 180px; white-space: pre-wrap;" xml:space="preserve"><tspan jas:role="paragraph"></tspan><tspan>First</tspan></text><text x="0" y="60" font-size="12" style="inline-size: 180px; white-space: pre-wrap;" xml:space="preserve"><tspan jas:role="paragraph" jas:hanging-punctuation="true" jas:left-indent="12"></tspan><tspan>Second</tspan></text></svg>"#;
        let mut st = AppState::new();
        st.add_tab(crate::workspace::app_state::TabState::new());
        st.tabs[st.active_tab].model = crate::document::model::Model::new(
            crate::geometry::svg::svg_to_document(svg), None);
        st
    }

    fn select(st: &mut AppState, i: usize) {
        Controller::select_element(&mut st.tabs[st.active_tab].model, &vec![0, i]);
    }

    /// (hanging punctuation, left indent) on text `i`'s paragraph wrapper.
    fn wrapper(st: &AppState, i: usize) -> (Option<bool>, Option<f64>) {
        let doc = st.tabs[st.active_tab].model.document();
        match doc.get_element(&vec![0, i]) {
            Some(Element::Text(t)) => t.tspans.iter()
                .find(|s| s.jas_role.as_deref() == Some("paragraph"))
                .map(|s| (s.jas_hanging_punctuation, s.jas_left_indent))
                .expect("a paragraph wrapper"),
            other => panic!("text {i} is not a text: {other:?}"),
        }
    }

    /// Row 181: the Paragraph menu's Hanging Punctuation reads the SELECTION,
    /// in its check and in its toggle. The web's native row flipped the typed
    /// slot as the LAST write left it and applied the WHOLE panel, so after a
    /// selection change it stamped the previous paragraph's fields over the
    /// new one (the W2b-7 clobber), and its check showed the previous flag.
    #[test]
    fn the_hanging_punctuation_row_reads_the_selection_after_a_selection_change() {
        let addr = PanelAddr { group: GroupAddr { dock_id: DockId(0), group_idx: 0 }, panel_idx: 0 };
        let mut st = two_paragraphs();
        let checked = |st: &AppState| panel_is_checked(
            PanelKind::Paragraph, "toggle_hanging_punctuation", st);
        assert_eq!(wrapper(&st, 1), (Some(true), Some(12.0)), "the control: the fixture's flagged paragraph");
        select(&mut st, 0);
        assert!(!checked(&st), "the first paragraph has no hanging punctuation");
        select(&mut st, 1);
        assert!(checked(&st), "the second paragraph has it: the check shows the selection");
        dispatch("toggle_hanging_punctuation", addr, &mut st);
        assert_eq!(wrapper(&st, 1), (None, Some(12.0)),
                   "the toggle turns it OFF and keeps the paragraph's own indent");
        assert!(!checked(&st), "and the check follows");
        dispatch("toggle_hanging_punctuation", addr, &mut st);
        assert_eq!(wrapper(&st, 1), (Some(true), Some(12.0)), "and back on");
        select(&mut st, 0);
        assert!(!checked(&st), "back to the first paragraph: unchecked");
        dispatch("toggle_hanging_punctuation", addr, &mut st);
        assert_eq!(wrapper(&st, 0), (Some(true), None),
                   "the first paragraph gains the flag and NOT the second's indent");
    }
}
