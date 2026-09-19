//! **W2b-8 — the five selection-level predicates the YAML binds by BARE NAME,
//! out from behind `feature = "web"`.**
//!
//! `workspace/panels/opacity.yaml` binds `selection_has_mask`,
//! `selection_mask_clip`, `selection_mask_invert` and `selection_mask_linked`
//! with no `panel.` or `state.` prefix, and `OPACITY.md §Preview interactions`
//! adds `editing_target_is_mask`. They are the complete bare-name vocabulary
//! the panel compiler recognises (`panels::predicate_reads`' `BARE` list).
//!
//! Until this module they were built only by
//! `workspace::dock_panel::build_selection_predicates`, which is
//! `#[cfg(feature = "web")]` — so **the engine's scope contained none of them.**
//!
//! ## ⛔ Why that is a defect and not merely a gap
//!
//! Two of the four document-derived facts are the *bound expressions* of
//! CHECKBOXES (`op_clip` → `selection_mask_clip`, `op_invert_mask` →
//! `selection_mask_invert`). A checkbox press writes the **negation of its
//! bound expression**, so a scope that does not contain the fact negates a
//! value that is not there. **That is W2b-7's defect in a second panel**, and
//! it is the reason this module exists rather than a `live_values` on some
//! opacity host: these are not panel fields at all, they are facts about the
//! selection, and they belong at the scope ROOT where the YAML reads them.

use crate::document::model::{EditingTarget, Model};
use serde_json::{Map, Value};

/// The five bare names, so a caller can assert it has covered them and a
/// future addition to the panel compiler's `BARE` list reds here.
pub const BARE_FACTS: [&str; 5] = [
    "selection_has_mask", "selection_mask_clip", "selection_mask_invert",
    "selection_mask_linked", "editing_target_is_mask",
];

/// **The four DOCUMENT-derived mask predicates, per `OPACITY.md §States`.**
///
/// `has_mask` requires EVERY selected element to carry a mask — a mixed
/// selection counts as "no mask". The clip / invert / linked triple is read
/// from the FIRST selected element's mask, which is what drives the
/// first-wins bindings on the clip and invert checkboxes.
///
/// ⚠️ **`linked` defaults to TRUE when there is no mask**, so the link
/// indicator shows the linked glyph on a fresh selection — the spec's "new
/// masks are linked" default. `clip` and `invert` default to FALSE. Getting
/// that asymmetry backwards is invisible in any arm that only checks a
/// masked selection.
pub fn mask_facts(doc: &crate::document::document::Document) -> (bool, bool, bool, bool) {
    let has = !doc.selection.is_empty() && doc.selection.iter().all(|es| {
        doc.get_element(&es.path)
            .map(|e| e.common().mask.is_some())
            .unwrap_or(false)
    });
    let first_mask = doc.selection.first()
        .and_then(|es| doc.get_element(&es.path))
        .and_then(|e| e.common().mask.as_ref());
    let (c, i, l) = match first_mask {
        Some(mask) => (mask.clip, mask.invert, mask.linked),
        None => (false, false, true),
    };
    (has, c, i, l)
}

/// True when mask-editing mode is active, so the previews can show a
/// persistent highlight on the current editing target.
///
/// This one reads the MODEL rather than the document. It lives here anyway
/// because `EditingTarget` is ungated (`document::model`) and the YAML binds
/// it by the same bare-name mechanism — splitting the five across a feature
/// gate would put half a vocabulary on each side.
pub fn editing_target_is_mask(model: &Model) -> bool {
    matches!(model.editing_target, EditingTarget::Mask(_))
}

/// **All five, as the scope reads them.** Inserted at the scope ROOT, because
/// the YAML binds them as bare names — not under `panel.` or `state.`.
pub fn selection_predicates(model: &Model) -> Map<String, Value> {
    let (has_mask, clip, invert, linked) = mask_facts(model.document());
    let mut m = Map::new();
    m.insert("selection_has_mask".into(), Value::Bool(has_mask));
    m.insert("selection_mask_clip".into(), Value::Bool(clip));
    m.insert("selection_mask_invert".into(), Value::Bool(invert));
    m.insert("selection_mask_linked".into(), Value::Bool(linked));
    m.insert("editing_target_is_mask".into(), Value::Bool(editing_target_is_mask(model)));
    debug_assert_eq!(m.len(), BARE_FACTS.len());
    m
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::document::{Document, ElementSelection};
    use crate::geometry::element::{Element, GroupElem, Mask};

    /// ⛔ **EVERY ARM HERE RUNS IN A BUILD WITH NO WEB FEATURE, AND THAT IS THE
    /// POINT OF W2b-8.** Before this module the five predicates were built only
    /// by `workspace::dock_panel`, which is `#[cfg(feature = "web")]`, so the
    /// engine's scope contained none of them and a build without `web` could
    /// not even name them. ⚠️ The crate declares `default = ["web"]`, so the
    /// web-free set is `--lib --no-default-features --features ffi`.
    fn mask(clip: bool, invert: bool, linked: bool) -> Mask {
        Mask {
            subtree: Box::new(Element::Group(GroupElem::default())),
            clip, invert, disabled: false, linked,
            unlink_transform: None,
        }
    }

    /// A minimal element that can carry a mask. `GroupElem` is used because it
    /// derives `Default`; the predicates read only `common().mask`, so the
    /// element KIND is not part of what is being measured here.
    fn elem(m: Option<Mask>) -> Element {
        let mut e = Element::Group(GroupElem::default());
        e.common_mut().mask = m.map(Box::new);
        e
    }

    fn doc_with(elems: Vec<Element>, selected: Vec<usize>) -> Document {
        let mut d = Document::default();
        d.layers = elems;
        d.selection = selected.into_iter().map(|i| ElementSelection::all(vec![i])).collect();
        d
    }

    /// **THE DEFAULTS ARE ASYMMETRIC AND THE ASYMMETRY IS THE LAW.** With no
    /// mask, `linked` is TRUE (the spec's "new masks are linked", so the link
    /// indicator shows the linked glyph on a fresh selection) while `clip` and
    /// `invert` are FALSE. An arm that only exercises a MASKED selection cannot
    /// see this, and getting it backwards is invisible everywhere else.
    #[test]
    fn with_no_mask_linked_defaults_true_and_clip_invert_default_false() {
        let d = doc_with(vec![elem(None)], vec![0]);
        assert_eq!(mask_facts(&d), (false, false, false, true));
        // And on an EMPTY selection, which is a different road to the same row.
        assert_eq!(mask_facts(&Document::default()), (false, false, false, true));
    }

    /// `has_mask` requires EVERY selected element to carry one — a mixed
    /// selection counts as "no mask" per OPACITY.md §States.
    #[test]
    fn a_mixed_selection_counts_as_no_mask() {
        let d = doc_with(vec![elem(Some(mask(true, true, true))), elem(None)], vec![0, 1]);
        assert!(!mask_facts(&d).0, "a mixed selection reported a mask");
        // Anti-vacuity: the same two elements, with the unmasked one left OUT
        // of the selection, DO report a mask — so the false above is about the
        // mixture and not about the document.
        let d2 = doc_with(vec![elem(Some(mask(true, true, true))), elem(None)], vec![0]);
        assert!(mask_facts(&d2).0);
    }

    /// The clip / invert / linked triple is FIRST-WINS, which is what drives
    /// the checkboxes' bindings on a multi-element selection.
    #[test]
    fn clip_invert_linked_come_from_the_first_selected_mask() {
        let d = doc_with(
            vec![elem(Some(mask(true, false, false))), elem(Some(mask(false, true, true)))],
            vec![0, 1]);
        assert_eq!(mask_facts(&d), (true, true, false, false),
                   "the triple did not come from the FIRST selected mask");
        // Reverse the selection order and the triple follows it — so "first"
        // means first SELECTED, not first in the layer list.
        let d2 = doc_with(
            vec![elem(Some(mask(true, false, false))), elem(Some(mask(false, true, true)))],
            vec![1, 0]);
        assert_eq!(mask_facts(&d2), (true, false, true, true));
    }

    /// **The scope map must carry every bare name the panel binds**, or a
    /// binding silently reads null and a checkbox negates a value that is not
    /// there. Derived from the panel's own YAML rather than typed.
    #[test]
    fn selection_predicates_covers_every_bare_name_the_yaml_binds() {
        let src = std::fs::read_to_string(
            concat!(env!("CARGO_MANIFEST_DIR"), "/../workspace/panels/opacity.yaml"))
            .expect("opacity.yaml is readable");
        let model = crate::document::model::Model::new(Document::default(), None);
        let m = selection_predicates(&model);
        let mut found = 0;
        for name in BARE_FACTS {
            if src.contains(name) {
                found += 1;
                assert!(m.contains_key(name),
                        "opacity.yaml binds the bare name {name} and the scope omits it");
            }
        }
        assert!(found >= 3,
                "read only {found} bare names out of opacity.yaml — the panel's \
                 shape changed and this arm is no longer measuring anything");
        assert_eq!(m.len(), BARE_FACTS.len(),
                   "the scope carries something outside the declared vocabulary");
    }

    /// Every value is a JSON BOOL. A binding that reads a null or a string
    /// evaluates falsey either way, so a type slip here is invisible until a
    /// press negates the wrong thing.
    #[test]
    fn every_predicate_is_a_json_bool() {
        let model = crate::document::model::Model::new(Document::default(), None);
        for (k, v) in selection_predicates(&model) {
            assert!(v.is_boolean(), "{k} is {v}, not a bool");
        }
    }

    /// `editing_target_is_mask` is false on a fresh model — and it is the one
    /// of the five that reads the MODEL rather than the document.
    #[test]
    fn editing_target_is_mask_is_false_on_a_fresh_model() {
        let model = crate::document::model::Model::new(Document::default(), None);
        assert!(!editing_target_is_mask(&model));
        assert_eq!(selection_predicates(&model)["editing_target_is_mask"],
                   serde_json::Value::Bool(false));
    }
}
