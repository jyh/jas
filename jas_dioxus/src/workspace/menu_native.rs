//! THE MENU'S NATIVE VERBS: the clipboard and Delete laws every route shares.
//!
//! Its model-verb table is GONE (2026-10-25): `unlock_all`, `hide_selection`,
//! `show_all`, `lock`, `select_all`, `group`, `ungroup`, `ungroup_all` and
//! `make_instance` were `log` stubs in `actions.yaml` whose behaviour lived in
//! one native table per port, and each now runs its YAML (`doc.op`, or
//! `doc.make_instance` for the last) on every route. What remains here is
//! [`make_instance_ops`], the ops that effect applies. Not web-gated: the
//! engine has no web.
//!
//! This is the UI layer, so [`make_instance_ops`] mints its ids here, never
//! inside a `Controller` method (see `generate_element_id`'s contract).

use crate::document::model::Model;
use crate::tools::tool::PASTE_OFFSET;

/// One Edit menu clipboard verb, as every route runs it. The offsets live
/// HERE: Paste and Paste, Preserving Layers land [`PASTE_OFFSET`] down and
/// right (the paste run stacks from there); Paste in Place lands at 0.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ClipVerb {
    /// Copy the selection's payload (`op_apply::selection_clipboard_svg`).
    Copy,
    /// Copy, then the reference-aware delete (one undo step), or ask first.
    Cut,
    /// Paste the clipboard text through `op_apply::apply_paste_clipboard_text`.
    Paste { offset: f64, preserve_layers: bool },
}

/// The clipboard actions, in menu order: what [`clipboard_verb`] knows.
pub const CLIPBOARD_VERBS: [&str; 5] = ["cut", "copy", "paste", "paste_in_place", "paste_preserving_layers"];

/// The clipboard verb `action` names, or `None`. Their `actions.yaml` bodies
/// are `log` stubs; the platform half (the system clipboard) is the shell's,
/// and the engine's half (the payload, the paste law) is this.
pub fn clipboard_verb(action: &str) -> Option<ClipVerb> {
    Some(match action {
        "copy" => ClipVerb::Copy,
        "cut" => ClipVerb::Cut,
        "paste" => ClipVerb::Paste { offset: PASTE_OFFSET, preserve_layers: false },
        "paste_in_place" => ClipVerb::Paste { offset: 0.0, preserve_layers: false },
        "paste_preserving_layers" => ClipVerb::Paste { offset: PASTE_OFFSET, preserve_layers: true },
        _ => return None,
    })
}

/// Object > Make Instance's two value-in-op ops, or `None` (a no-op) unless
/// exactly ONE `All`-kind element is selected and two ids could be minted.
///
/// Make Instance is an OFFSET REFERENCE (SYMBOLS.md: "offset like Make
/// Instance"), never Make Symbol: `create_reference` to the selected element,
/// then `move_selection` by `offset` (the YAML's own number). The two ids are
/// minted HERE, before the ops, through the shared `mint_unique_ids` loop, so
/// the journal replays to the same ids; under the action corpus's
/// deterministic id source they are the golden-pinned `"01234567"` /
/// `"89abcdef"`. `doc.make_instance` applies them under the YAML's `snapshot`.
pub fn make_instance_ops(doc: &crate::document::document::Document, offset: f64)
    -> Option<[serde_json::Value; 2]>
{
    use crate::document::artboard::{generate_element_id, mint_unique_ids};
    use crate::document::document::SelectionKind;
    let [es] = doc.selection.as_slice() else { return None; };
    if es.kind != SelectionKind::All { return None; }
    // Two distinct ids, collision-free against every id already in the
    // document (see `Document::element_ids`).
    let mut existing = doc.element_ids();
    let ids = mint_unique_ids(2, &mut existing, &mut || generate_element_id(None))?;
    Some([
        serde_json::json!({"op": "create_reference", "target_path": es.path,
                           "target_id": ids[0], "ref_id": ids[1]}),
        serde_json::json!({"op": "move_selection", "dx": offset, "dy": offset}),
    ])
}

/// Make Instance on a model, as the YAML runs it (ONE undo step, the paste
/// offset): the tests' setup step for a document holding a reference.
#[cfg(test)]
pub fn make_instance(model: &mut Model) {
    let Some(ops) = make_instance_ops(model.document(), PASTE_OFFSET) else { return };
    model.with_txn(|m| {
        for op in &ops {
            let _ = crate::document::op_apply::op_apply(m, op);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::document::Document;

    /// The web app's paste sites take their offsets from [`clipboard_verb`],
    /// the table the engine's menu and key routes read, so the three apps
    /// cannot drift on a paste offset. Neither site names `PASTE_OFFSET`
    /// itself (the bank's §1 item 4, 2026-10-17).
    #[test]
    fn the_web_paste_sites_read_the_clipboard_table() {
        let sites = [("menu_bar.rs", include_str!("menu_bar.rs")),
                     ("keyboard.rs", include_str!("keyboard.rs"))];
        for (name, src) in sites {
            let code: String = src.lines()
                .filter(|l| !l.trim_start().starts_with("//"))
                .collect::<Vec<_>>().join("\n");
            assert!(!code.contains("PASTE_OFFSET"), "{name} names PASTE_OFFSET; read clipboard_verb");
            assert!(code.contains("clipboard_verb("), "{name} does not read clipboard_verb");
        }
    }

    /// [`CLIPBOARD_VERBS`] is exactly what [`clipboard_verb`] knows.
    #[test]
    fn every_clipboard_verb_is_known_and_nothing_else_is() {
        for verb in CLIPBOARD_VERBS {
            assert!(clipboard_verb(verb).is_some(), "{verb}");
        }
        for other in ["select_all", "undo", "copy ", "paste_text", ""] {
            assert_eq!(clipboard_verb(other), None, "{other:?}");
        }
        assert_eq!(clipboard_verb("paste"), Some(ClipVerb::Paste { offset: PASTE_OFFSET, preserve_layers: false }));
        assert_eq!(clipboard_verb("paste_in_place"), Some(ClipVerb::Paste { offset: 0.0, preserve_layers: false }));
        assert_eq!(clipboard_verb("paste_preserving_layers"), Some(ClipVerb::Paste { offset: PASTE_OFFSET, preserve_layers: true }));
    }
}
