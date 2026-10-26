//! THE MENU'S MODEL-PURE VERBS, ONE TABLE FOR EVERY ROUTE.
//!
//! Six Edit / Object menu actions are `log` stubs in `actions.yaml`: their
//! behaviour is the menu's own, in every app. (`unlock_all`, `hide_selection`
//! and `show_all` left this table 2026-10-25: their YAML is `doc.op`, the op
//! layer by name, so every route runs the declared action.) The reference routes them
//! through `_MENU_NATIVE_HANDLERS`, Swift through `MenuActions`. Here the web
//! menu (`menu_bar`), the action corpus (`recorder::replay`) and the engine's
//! menu dispatch (`ffi::jas_dispatch_action`, flask STATUS §242: Select All
//! was refused on Windows) all call [`run`], so no route can hold a verb the
//! others lack. Not web-gated: the engine has no web.
//!
//! This is the UI layer, so [`make_instance`] mints its ids here, never
//! inside a `Controller` method (see `generate_element_id`'s contract).

use crate::document::controller::Controller;
use crate::document::model::Model;
use crate::tools::tool::PASTE_OFFSET;

/// The actions [`run`] handles, in the reference's order.
pub const VERBS: [&str; 6] = [
    "select_all", "group", "ungroup", "ungroup_all", "lock", "make_instance",
];

/// Run `action` on `model` if it is one of [`VERBS`]; `false` (nothing run)
/// otherwise. Each edit is ONE undo step; `select_all` writes the selection,
/// which is not an edit and records none.
pub fn run(action: &str, model: &mut Model) -> bool {
    match action {
        "select_all" => Controller::select_all(model),
        "group" => model.with_txn(|m| Controller::group_selection(m)),
        "ungroup" => model.with_txn(|m| Controller::ungroup_selection(m)),
        "ungroup_all" => model.with_txn(|m| Controller::ungroup_all(m)),
        "lock" => model.with_txn(|m| Controller::lock_selection(m)),
        "make_instance" => make_instance(model),
        _ => return false,
    }
    true
}

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

/// Object > Make Instance, as a headless mutation on a [`Model`].
///
/// Replaces the single whole-element selection with a by-id reference to it,
/// offset by [`PASTE_OFFSET`], under ONE undo transaction. No-op unless
/// exactly ONE `All`-kind element is selected (the same guard the menu item's
/// enablement uses).
///
/// The two element ids are minted HERE, in the UI layer, through the shared
/// `mint_unique_ids` loop, then passed in to `create_reference`. Under the
/// action corpus's deterministic id source that yields the golden-pinned
/// `"01234567"` / `"89abcdef"`.
pub fn make_instance(model: &mut Model) {
    use crate::document::artboard::{generate_element_id, mint_unique_ids};
    use crate::document::document::SelectionKind;
    // Enabled only when exactly ONE whole element is selected (kind = All; not
    // a control-point sub-selection). Otherwise no-op, like group's guard.
    let target_path = {
        let sel = &model.document().selection;
        let [es] = sel.as_slice() else { return; };
        if es.kind != SelectionKind::All { return; }
        es.path.clone()
    };
    // Mint two distinct, collision-free ids against every id already in the
    // document (see `Document::element_ids`), through the shared mint loop.
    let mut existing = model.document().element_ids();
    let Some(ids) =
        mint_unique_ids(2, &mut existing, &mut || generate_element_id(None))
    else {
        return;
    };
    let (target_id, ref_id) = (&ids[0], &ids[1]);
    // create_reference + offset-move under ONE snapshot = a single undo step
    // (offset rides on the new reference's common.transform via move_selection).
    model.with_txn(|m| {
        Controller::create_reference(m, &target_path, &target_id, &ref_id);
        Controller::move_selection(m, PASTE_OFFSET, PASTE_OFFSET);
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

    /// [`VERBS`] is the list the routes and their tests read; [`run`] is what
    /// runs. Each verb in the list must be one `run` handles, and nothing
    /// else is, or a route reads a verb as run that ran nothing.
    /// [`CLIPBOARD_VERBS`] is exactly what [`clipboard_verb`] knows, and no
    /// clipboard verb is also a model verb (one route each).
    #[test]
    fn every_clipboard_verb_is_known_and_nothing_else_is() {
        for verb in CLIPBOARD_VERBS {
            assert!(clipboard_verb(verb).is_some(), "{verb}");
            assert!(!VERBS.contains(&verb), "{verb} is not a model verb");
        }
        for other in ["select_all", "undo", "copy ", "paste_text", ""] {
            assert_eq!(clipboard_verb(other), None, "{other:?}");
        }
        assert_eq!(clipboard_verb("paste"), Some(ClipVerb::Paste { offset: PASTE_OFFSET, preserve_layers: false }));
        assert_eq!(clipboard_verb("paste_in_place"), Some(ClipVerb::Paste { offset: 0.0, preserve_layers: false }));
        assert_eq!(clipboard_verb("paste_preserving_layers"), Some(ClipVerb::Paste { offset: PASTE_OFFSET, preserve_layers: true }));
    }

    #[test]
    fn every_verb_is_run_and_nothing_else_is() {
        for verb in VERBS {
            let mut model = Model::new(Document::default(), None);
            assert!(run(verb, &mut model), "{verb} is listed and run handles it");
        }
        // The three whose YAML is `doc.op` run from the declared action, never here.
        for other in ["copy", "paste", "undo", "hide", "select_all ", "", "unlock_all",
                      "hide_selection", "show_all"] {
            let mut model = Model::new(Document::default(), None);
            assert!(!run(other, &mut model), "{other:?} is not a menu verb");
        }
    }
}

/// What [`delete_selection`] did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeleteOutcome {
    /// Nothing was selected, so nothing changed.
    NothingSelected,
    /// Deleting would ORPHAN this many live instances, so nothing was deleted:
    /// the caller asks first (`delete_orphan_confirm`, its `count` param).
    WouldOrphan(usize),
    /// The selection was deleted, as ONE undo step.
    Deleted,
}

/// Edit > Delete and the Delete key: the web keyboard's REFERENCE-AWARE delete,
/// one law for every engine route (the key, and `delete_selection` by action,
/// which a tool's YAML dispatches). It never orphans a live instance without
/// asking: it reports [`DeleteOutcome::WouldOrphan`] and deletes nothing.
pub fn delete_selection(model: &mut Model) -> DeleteOutcome {
    let paths: Vec<Vec<usize>> =
        model.document().selection.iter().map(|es| es.path.clone()).collect();
    if paths.is_empty() {
        return DeleteOutcome::NothingSelected;
    }
    let orphans = crate::document::dependency_index::orphaned_references(model.document(), &paths).len();
    if orphans > 0 {
        return DeleteOutcome::WouldOrphan(orphans);
    }
    crate::document::op_apply::journal_delete_selection(model, "delete_selection");
    DeleteOutcome::Deleted
}

/// `delete_selection` as a host runs it, for every host that claims it (the
/// engine's, and a YAML tool's, whose Delete dispatches it): the Delete key's
/// reference-aware law (`menu_native::delete_selection`). A would-be orphan
/// opens `delete_orphan_confirm` in `store` with its `count` and deletes
/// nothing. `None` when it ran; the refusal otherwise.
pub fn run_delete_selection(
    store: &mut crate::interpreter::state_store::StateStore, model: Option<&mut Model>,
) -> Option<crate::interpreter::effects::Unhandled> {
    use crate::interpreter::effects::{open_dialog_in, Unhandled};
    use serde_json::Value;
    let Some(model) = model else { return Some(Unhandled::NoModel("delete_selection".into())) };
    if let DeleteOutcome::WouldOrphan(count) = delete_selection(model) {
        const ID: &str = "delete_orphan_confirm";
        let ws = crate::interpreter::workspace::Workspace::load();
        let Some(def) = ws.as_ref().and_then(|w| w.dialog(ID)) else {
            return Some(Unhandled::UnknownDialog(ID.into()));
        };
        let params = [("count".to_string(), Value::from(count))].into_iter().collect();
        open_dialog_in(ID, def, Some(params), None, &Value::Null, store, Some(model));
    }
    None
}
