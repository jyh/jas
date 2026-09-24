//! The seven artboard `doc.*` effects, web-free (W2b-14).
//!
//! These lived in the web's `renderer.rs::run_yaml_effect`, so the engine
//! refused every artboard action with `UnknownDocEffect`. They are MOVED here,
//! not rewritten. `effects::run_doc_effect` dispatches to [`run`], and the web
//! reaches it through its existing `doc.*` fallback into the shared runner.
//! The reference hosts the same keys in its shared `effects.py`.
//!
//! ⛔ EVERY EXPRESSION IS EVALUATED THROUGH `eval_expr(expr, store, ctx)`, where
//! `ctx` overrides the store. The web's fallback hands the shared runner a
//! THROWAWAY EMPTY store and the whole eval context as `ctx`, so an arm that
//! read the store directly would see nothing on the web path.
//!
//! Each arm resolves its expressions to literals and routes ONE op through
//! `op_apply`, so it journals and replays as the web's did (OP_LOG.md §9). Ids
//! are MINTED here, once. Replay reads the recorded literal and never mints.
//!
//! ⚠️ Not carried from the web: `doc.create_artboard`'s `as:` binding. The
//! shared runner binds `as:` for no effect, and no workspace action uses it
//! with an artboard key. The reference returns the artboard for one.

use serde_json::{json, Value};

use super::effects::{eval_expr, value_to_json};
use super::expr_types::Value as EVal;
use super::state_store::StateStore;
use crate::document::artboard::{generate_artboard_id, mint_unique_ids, next_artboard_name};
use crate::document::model::Model;
use crate::document::op_apply::op_apply;

/// The keys [`run`] hosts.
pub const KEYS: [&str; 7] = [
    "doc.create_artboard",
    "doc.delete_artboard_by_id",
    "doc.duplicate_artboard",
    "doc.set_artboard_field",
    "doc.set_artboard_options_field",
    "doc.move_artboards_up",
    "doc.move_artboards_down",
];

/// A list value's string items, in order; anything else is empty.
pub(crate) fn extract_id_list(val: &EVal) -> Vec<String> {
    match val {
        EVal::List(arr) => arr.iter().filter_map(|v| v.as_str().map(str::to_string)).collect(),
        _ => Vec::new(),
    }
}

/// Mint one artboard id no artboard in `model` carries.
fn mint_one(model: &Model) -> Option<String> {
    let mut existing: std::collections::HashSet<String> =
        model.document().artboards.iter().map(|a| a.id.clone()).collect();
    mint_unique_ids(1, &mut existing, &mut || generate_artboard_id(None)).map(|ids| ids[0].clone())
}

/// A spec value as a literal: a string is an expression, anything else is
/// already one.
fn literal(v: &Value, store: &StateStore, ctx: &Value) -> EVal {
    match v.as_str() {
        Some(s) => eval_expr(s, store, ctx),
        None => EVal::from_json(v),
    }
}

/// Run artboard effect `name` (one of [`KEYS`]). A spec that does not resolve
/// (a non-string id, a missing field) changes nothing, as on the web.
pub fn run(name: &str, spec: &Value, ctx: &Value, store: &StateStore, model: &mut Model) {
    let op = match name {
        // { [field]: expr, ... }: the name is derived from the live document
        // and any override replaces it.
        "doc.create_artboard" => {
            let Some(spec) = spec.as_object() else { return };
            let Some(id) = mint_one(model) else { return };
            let mut fields = serde_json::Map::new();
            fields.insert("name".into(), json!(next_artboard_name(&model.document().artboards)));
            for (k, v) in spec {
                fields.insert(k.clone(), value_to_json(&literal(v, store, ctx)));
            }
            json!({"op": "create_artboard", "id": id, "fields": Value::Object(fields)})
        }
        // id_expr
        "doc.delete_artboard_by_id" => {
            let EVal::Str(id) = eval_expr(spec.as_str().unwrap_or(""), store, ctx) else { return };
            json!({"op": "delete_artboard_by_id", "id": id})
        }
        // id_expr | { id, offset_x?, offset_y? }; each offset defaults to 20.
        "doc.duplicate_artboard" => {
            let (id_expr, ox, oy) = match spec {
                Value::String(s) => (s.as_str(), None, None),
                Value::Object(m) => (
                    m.get("id").and_then(Value::as_str).unwrap_or(""),
                    m.get("offset_x").and_then(Value::as_str),
                    m.get("offset_y").and_then(Value::as_str),
                ),
                _ => return,
            };
            let EVal::Str(id) = eval_expr(id_expr, store, ctx) else { return };
            let offset = |e: Option<&str>| match e.map(|s| eval_expr(s, store, ctx)) {
                Some(EVal::Number(n)) => n,
                _ => 20.0,
            };
            let (ox, oy) = (offset(ox), offset(oy));
            // A missing source changes nothing either way: `op_apply` refuses
            // it and journals nothing (its own arm says so). This early return
            // only saves the mint, so a mutant deleting it survives every arm,
            // and that survival is the answer rather than a gap.
            if !model.document().artboards.iter().any(|a| a.id == id) {
                return;
            }
            let Some(new_id) = mint_one(model) else { return };
            let new_name = next_artboard_name(&model.document().artboards);
            json!({"op": "duplicate_artboard", "id": id, "new_id": new_id, "name": new_name,
                   "offset_x": ox, "offset_y": oy})
        }
        // { id, field, value }
        "doc.set_artboard_field" => {
            let Some(spec) = spec.as_object() else { return };
            let Some(field) = spec.get("field").and_then(Value::as_str) else { return };
            let Some(value) = spec.get("value") else { return };
            let value = value_to_json(&literal(value, store, ctx));
            let id_expr = spec.get("id").and_then(Value::as_str).unwrap_or("");
            let EVal::Str(id) = eval_expr(id_expr, store, ctx) else { return };
            json!({"op": "set_artboard_field", "id": id, "field": field, "value": value})
        }
        // { field, value }: a document-wide option.
        "doc.set_artboard_options_field" => {
            let Some(spec) = spec.as_object() else { return };
            let Some(field) = spec.get("field").and_then(Value::as_str) else { return };
            let Some(value) = spec.get("value") else { return };
            let value = value_to_json(&literal(value, store, ctx));
            json!({"op": "set_artboard_options_field", "field": field, "value": value})
        }
        // ids_expr
        "doc.move_artboards_up" | "doc.move_artboards_down" => {
            let ids = extract_id_list(&eval_expr(spec.as_str().unwrap_or(""), store, ctx));
            json!({"op": name.trim_start_matches("doc."), "ids": ids})
        }
        _ => return,
    };
    let _ = op_apply(model, &op);
}

#[cfg(test)]
mod tests {
    use serde_json::{json, Value};

    use crate::document::artboard::Artboard;
    use crate::document::document::Document;
    use crate::document::model::Model;
    use crate::interpreter::effects::{run_effects, Unhandled};
    use crate::interpreter::state_store::StateStore;

    /// Three artboards `a`, `b`, `c`, named and sized apart so every arm
    /// below can tell them apart.
    fn three() -> Model {
        let mut doc = Document::default();
        doc.artboards = ["a", "b", "c"]
            .iter()
            .enumerate()
            .map(|(i, id)| {
                let mut ab = Artboard::default_with_id(id.to_string());
                ab.name = format!("Artboard {}", i + 1);
                ab.x = 1000.0 * i as f64;
                ab
            })
            .collect();
        Model::new(doc, None)
    }

    /// Run one effect through the SHARED runner, with the WEB's throwaway
    /// empty store: the moved arms must read only `ctx`, since that is all
    /// the web's fallback hands them.
    fn run(model: &mut Model, effect: Value, ctx: Value) -> Vec<Unhandled> {
        let mut store = StateStore::new();
        run_effects(&[effect], &ctx, &mut store, Some(model), None, None, None).unhandled
    }

    fn ids(m: &Model) -> Vec<String> {
        m.document().artboards.iter().map(|a| a.id.clone()).collect()
    }

    #[test]
    fn create_appends_one_with_a_fresh_id_the_next_name_and_the_overrides() {
        let mut m = three();
        let un = run(&mut m, json!({"doc.create_artboard": {"x": "panel.x", "width": "250"}}),
                     json!({"panel": {"x": 40}}));
        assert!(un.is_empty(), "{un:?}");
        let abs = &m.document().artboards;
        assert_eq!(abs.len(), 4);
        let new = &abs[3];
        assert!(!["a", "b", "c"].contains(&new.id.as_str()), "a fresh id: {}", new.id);
        assert_eq!(new.name, "Artboard 4");
        assert_eq!((new.x, new.width), (40.0, 250.0), "overrides evaluated against ctx");
    }

    #[test]
    fn delete_by_id_removes_exactly_the_named_one_and_a_miss_changes_nothing() {
        let mut m = three();
        assert!(run(&mut m, json!({"doc.delete_artboard_by_id": "panel.target"}),
                    json!({"panel": {"target": "b"}})).is_empty());
        assert_eq!(ids(&m), vec!["a", "c"]);
        assert!(run(&mut m, json!({"doc.delete_artboard_by_id": "'zz'"}), json!({})).is_empty());
        assert_eq!(ids(&m), vec!["a", "c"], "a miss is a no-op");
    }

    #[test]
    fn duplicate_appends_an_offset_copy_under_a_fresh_id_and_the_next_name() {
        let mut m = three();
        assert!(run(&mut m, json!({"doc.duplicate_artboard": {"id": "'b'", "offset_x": "5"}}),
                    json!({})).is_empty());
        let abs = &m.document().artboards;
        assert_eq!(abs.len(), 4);
        let (src, dup) = (&abs[1], &abs[3]);
        assert_ne!(dup.id, src.id);
        assert_eq!(dup.name, "Artboard 4");
        // offset_x given, offset_y defaults to 20 (the reference's default).
        assert_eq!((dup.x, dup.y), (src.x + 5.0, src.y + 20.0));
        // The bare-string form names the id alone.
        assert!(run(&mut m, json!({"doc.duplicate_artboard": "'a'"}), json!({})).is_empty());
        assert_eq!(m.document().artboards.len(), 5);
        // A missing source duplicates nothing.
        assert!(run(&mut m, json!({"doc.duplicate_artboard": "'zz'"}), json!({})).is_empty());
        assert_eq!(m.document().artboards.len(), 5);
    }

    #[test]
    fn set_field_writes_the_named_artboards_field_only() {
        let mut m = three();
        assert!(run(&mut m, json!({"doc.set_artboard_field":
                                   {"id": "'c'", "field": "name", "value": "panel.n"}}),
                    json!({"panel": {"n": "Cover"}})).is_empty());
        let names: Vec<&str> = m.document().artboards.iter().map(|a| a.name.as_str()).collect();
        assert_eq!(names, vec!["Artboard 1", "Artboard 2", "Cover"]);
    }

    #[test]
    fn set_options_field_writes_the_document_wide_option() {
        let mut m = three();
        let before = m.document().artboard_options.update_while_dragging;
        assert!(run(&mut m, json!({"doc.set_artboard_options_field":
                                   {"field": "update_while_dragging", "value": "not panel.v"}}),
                    json!({"panel": {"v": before}})).is_empty());
        assert_eq!(m.document().artboard_options.update_while_dragging, !before);
    }

    #[test]
    fn move_up_and_down_reorder_by_the_listed_ids() {
        let mut m = three();
        assert!(run(&mut m, json!({"doc.move_artboards_up": "panel.ids"}),
                    json!({"panel": {"ids": ["c"]}})).is_empty());
        assert_eq!(ids(&m), vec!["a", "c", "b"]);
        assert!(run(&mut m, json!({"doc.move_artboards_down": "panel.ids"}),
                    json!({"panel": {"ids": ["a"]}})).is_empty());
        assert_eq!(ids(&m), vec!["c", "a", "b"]);
    }

    /// Each key journals ONE op and so is undoable as one step, as the web's
    /// arms were (they route through `op_apply`).
    #[test]
    fn a_create_is_undone_by_one_undo() {
        let mut m = three();
        m.begin_txn();
        assert!(run(&mut m, json!({"doc.create_artboard": {}}), json!({})).is_empty());
        m.commit_txn();
        assert_eq!(m.document().artboards.len(), 4);
        m.undo();
        assert_eq!(ids(&m), vec!["a", "b", "c"]);
    }
}
