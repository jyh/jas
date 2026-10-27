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

/// One Edit menu clipboard verb, as every route runs it. A paste carries no
/// offset here: each paste runs its action's YAML (`doc.paste`), which holds
/// the offsets (24, 0, 24) and the layer choice, fed the clipboard read.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ClipVerb {
    /// Copy the selection's payload (`op_apply::selection_clipboard_svg`).
    Copy,
    /// Copy, then the reference-aware delete (one undo step), or ask first.
    Cut,
    /// Paste, Paste in Place, Paste Preserving Layers: the clipboard read
    /// goes to the action's YAML as `param.clipboard`.
    Paste,
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
        "paste" | "paste_in_place" | "paste_preserving_layers" => ClipVerb::Paste,
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
    let Some(ops) = make_instance_ops(model.document(), crate::tools::tool::PASTE_OFFSET) else { return };
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

    /// Every paste route RUNS ITS ACTION'S YAML (`doc.paste`, fed the
    /// clipboard read as `param.clipboard`), so the offsets live in
    /// `actions.yaml` alone (item 8 clipboard M′, 2026-10-26). No route calls
    /// the paste law itself, and none names `PASTE_OFFSET`; the law's one
    /// caller is the op layer (`op_apply`'s `"paste"`), which the effect uses.
    #[test]
    fn no_paste_route_calls_the_paste_law_or_names_an_offset() {
        let sites = [("menu_bar.rs", include_str!("menu_bar.rs")),
                     ("keyboard.rs", include_str!("keyboard.rs")),
                     ("clipboard.rs", include_str!("clipboard.rs")),
                     ("ffi.rs", include_str!("../ffi.rs"))];
        for (name, src) in sites {
            // Production code only: the test module of each file may drive
            // the law directly as a setup step.
            let prod = src.split("#[cfg(test)]\nmod tests").next().unwrap();
            let code: String = prod.lines()
                .filter(|l| !l.trim_start().starts_with("//"))
                .collect::<Vec<_>>().join("\n");
            assert!(!code.contains("PASTE_OFFSET"), "{name} names PASTE_OFFSET; the YAML carries it");
            assert!(!code.contains("apply_paste_clipboard_text("),
                "{name} calls the paste law; run the action's YAML (`doc.paste`)");
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
        for paste in ["paste", "paste_in_place", "paste_preserving_layers"] {
            assert_eq!(clipboard_verb(paste), Some(ClipVerb::Paste), "{paste}");
        }
    }
}
