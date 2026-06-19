//! The single op dispatcher — `op_apply` (OP_LOG.md §4 / §9, Increment 3b-B).
//!
//! STAGED-ASTERISK: this is the promoted, production-shared form of what was
//! the `#[cfg(test)]` `apply_op` dispatcher. It is the §4 single-path end-state
//! built in the increment that needs it. In 3b-B it is adopted from production
//! for **exactly three replay-safe verbs** — `select_rect`, `copy_selection`,
//! and `move_selection` — which are the ones `RecordedElem.capture_recipe`
//! consumes. Those three populate `targets:[common.id]` (Fork 4); EVERY OTHER
//! verb here keeps `targets: Vec::new()` and is reachable only from the
//! `#[cfg(test)]` cross-language harness (which shims through this module so
//! harness + production share ONE dispatcher and ONE `record_op` site). The
//! other ~30 `doc.*` production verbs, the `renderer.rs::run_yaml_effect`
//! AppState-level handlers (Layers-panel Duplicate / Duplicate Artboard), the
//! per-frame drag coalescing, and the full 33-verb unification are explicitly
//! deferred per OP_LOG.md §9.
//!
//! Production input must never panic, so every param read is hardened: numbers
//! resolve with `as_f64().unwrap_or(0.0)`; a missing REQUIRED field (a path, an
//! id, a transform) early-returns/skips rather than unwrapping. The harness
//! fixtures (which always carry well-formed params) replay byte-identically.

use crate::document::controller::{self, Controller};
use crate::document::document::ElementPath;
use crate::document::model::Model;

/// Parse a JSON array of indices into an [`ElementPath`]. Returns `None` if the
/// field is absent or not an array of non-negative integers (a malformed
/// production payload skips the op rather than panicking).
fn parse_path(v: Option<&serde_json::Value>) -> Option<ElementPath> {
    let arr = v?.as_array()?;
    Some(arr.iter().map(|i| i.as_u64().unwrap_or(0) as usize).collect())
}

/// Read a string field, or `None` if absent / not a string.
fn str_field<'a>(op: &'a serde_json::Value, key: &str) -> Option<&'a str> {
    op.get(key).and_then(|v| v.as_str())
}

/// Read an f64 field, defaulting to 0.0 (the non-panicking number form).
fn num_field(op: &serde_json::Value, key: &str) -> f64 {
    op.get(key).and_then(|v| v.as_f64()).unwrap_or(0.0)
}

/// The single op dispatcher (OP_LOG.md §4). Applies one primitive op to the
/// model and records it into the open transaction (the `checkpoint_equivalence`
/// gate, §5-6). History-navigation ops (`snapshot`/`undo`/`redo`) manage the
/// transaction boundary / journal cursor and are NOT primitive ops, so they
/// early-return WITHOUT being journaled. `record_op` is a no-op when no
/// transaction is open, so this is safe to call unconditionally.
pub fn op_apply(model: &mut Model, op: &serde_json::Value) {
    let Some(name) = op["op"].as_str() else {
        // A primitive op with no verb is malformed; skip it (never panic).
        return;
    };
    // History-navigation ops (OP_LOG.md §5): they manage transaction
    // boundaries / the journal cursor and are NOT primitive ops, so they
    // are never journaled. `snapshot` commits the prior action's
    // transaction (relocated redo-clear) and opens a new one, so the
    // mutator ops that follow JOIN one checkpoint; undo/redo end the open
    // context and move the cursor.
    match name {
        "snapshot" => {
            model.commit_txn();
            model.begin_txn();
            return;
        }
        "undo" => {
            model.undo();
            return;
        }
        "redo" => {
            model.redo();
            return;
        }
        _ => {}
    }
    // OP_LOG.md §9 (Increment 3b-B) — close the subsequent-drag-frame
    // journaling hole. Every verb below except `select_rect` is an UNDOABLE
    // mutation that writes through `edit_document`, which SELF-BRACKETS
    // (begin/write/commit) when no transaction is open. On a bare drag frame
    // (selection.yaml emits `doc.snapshot` only on the FIRST mousemove), that
    // self-commit closes the transaction BEFORE `record_op` runs (so the op is
    // dropped) and before the batch owner's `name_txn`/`commit_txn` fires (so
    // the txn is unnamed). Opening the transaction HERE — and leaving it OPEN —
    // makes `edit_document` JOIN it (in_txn==true ⇒ no self-commit), so
    // `record_op` lands the op and the batch owner (run_effects /
    // run_yaml_effects) names + commits the single transaction. `begin_txn` is
    // a no-op while one is already open, so the harness (which always brackets
    // around `op_apply`) and the snapshot-led first frame are byte-unchanged.
    // `select_rect` is EXCLUDED: it only changes selection (non-undoable,
    // serialized state), so a bare marquee must stay journal-neutral — opening a
    // txn for it would spuriously journal a selection-only batch as an
    // undoable step.
    if name != "select_rect" && !model.in_txn() {
        model.begin_txn();
    }
    // Fork-4 `targets` (OP_LOG.md §9). Populated for the THREE replay-safe
    // verbs `capture_recipe` consumes; every other verb keeps it empty.
    // `move_selection`/`copy_selection` resolve the source ids BEFORE the
    // mutation (a copy is born id-less; a move can change which ids are
    // selected — pre-mutation avoids the post-mutation-id hazard).
    // `select_rect` resolves AFTER its Controller call (the selection it just
    // established IS the keystone targets).
    let mut targets: Vec<String> = Vec::new();
    if name == "move_selection" || name == "copy_selection" {
        targets = controller::selection_to_ids(model.document());
    }
    match name {
        "select_rect" => {
            Controller::select_rect(
                model,
                num_field(op, "x"),
                num_field(op, "y"),
                num_field(op, "width"),
                num_field(op, "height"),
                op["extend"].as_bool().unwrap_or(false),
            );
            // Keystone: the resolved selection is this op's targets, so
            // `capture_recipe` can seed its working set (empty targets ⇒
            // empty recipe). Resolved AFTER the Controller call.
            targets = controller::selection_to_ids(model.document());
        }
        "move_selection" => {
            Controller::move_selection(model, num_field(op, "dx"), num_field(op, "dy"));
        }
        "copy_selection" => {
            Controller::copy_selection(model, num_field(op, "dx"), num_field(op, "dy"));
        }
        "assign_id" => {
            let (Some(path), Some(id)) = (parse_path(op.get("path")), str_field(op, "id"))
            else {
                return;
            };
            Controller::assign_id(model, &path, id);
        }
        "create_reference" => {
            let (Some(target_path), Some(target_id), Some(ref_id)) = (
                parse_path(op.get("target_path")),
                str_field(op, "target_id"),
                str_field(op, "ref_id"),
            ) else {
                return;
            };
            Controller::create_reference(model, &target_path, target_id, ref_id);
        }
        // Symbols P2 operations (SYMBOLS.md §7). Value-in-op: the ids and
        // paths are read literally from the fixture payload, exactly like
        // the create_reference arm.
        "make_symbol" => {
            let (Some(path), Some(master_id), Some(ref_id)) = (
                parse_path(op.get("path")),
                str_field(op, "master_id"),
                str_field(op, "ref_id"),
            ) else {
                return;
            };
            Controller::make_symbol(model, &path, master_id, ref_id);
        }
        "place_instance" => {
            let (Some(master_id), Some(ref_id)) =
                (str_field(op, "master_id"), str_field(op, "ref_id"))
            else {
                return;
            };
            Controller::place_instance(model, master_id, ref_id);
        }
        "detach" => {
            let Some(path) = parse_path(op.get("path")) else {
                return;
            };
            Controller::detach(model, &path);
        }
        "redefine" => {
            let (Some(master_id), Some(path), Some(ref_id)) = (
                str_field(op, "master_id"),
                parse_path(op.get("path")),
                str_field(op, "ref_id"),
            ) else {
                return;
            };
            Controller::redefine(model, master_id, &path, ref_id);
        }
        "delete_symbol" => {
            let Some(master_id) = str_field(op, "master_id") else {
                return;
            };
            Controller::delete_symbol(model, master_id);
        }
        // Symbols P4 (SYMBOLS.md §4 / Fork F2). Value-in-op: the instance
        // transform is carried in the payload as {a,b,c,d,e,f} (the same
        // matrix shape parsed elsewhere) and applied verbatim.
        "set_instance_transform" => {
            let Some(path) = parse_path(op.get("path")) else {
                return;
            };
            let t = &op["transform"];
            if !t.is_object() {
                return;
            }
            let transform = crate::geometry::element::Transform {
                a: num_field(t, "a"),
                b: num_field(t, "b"),
                c: num_field(t, "c"),
                d: num_field(t, "d"),
                e: num_field(t, "e"),
                f: num_field(t, "f"),
            };
            Controller::set_instance_transform(model, &path, transform);
        }
        "delete_selection" => {
            let new_doc = model.document().delete_selection();
            model.edit_document(new_doc);
        }
        "lock_selection" => {
            Controller::lock_selection(model);
        }
        "unlock_all" => {
            Controller::unlock_all(model);
        }
        "hide_selection" => {
            Controller::hide_selection(model);
        }
        "show_all" => {
            Controller::show_all(model);
        }
        "set_character_attribute" => {
            let (Some(path), Some(attribute), Some(value)) = (
                parse_path(op.get("path")),
                str_field(op, "attribute"),
                str_field(op, "value"),
            ) else {
                return;
            };
            let char_start = op.get("char_start").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
            let char_end = op.get("char_end").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
            Controller::set_character_attribute(
                model, &path, char_start, char_end, attribute, value,
            );
        }
        // Boolean ops (OP_LOG.md §9 trap: these were NOT in apply_op — added
        // for the boolean_union_simplify_grouping pin). The destructive
        // boolean combines the ≥2 selected sibling paths; `simplify` refits
        // the (now-selected) output. Both write via edit_document, joining
        // the harness transaction so the pair is one journaled Transaction.
        "boolean_union" => {
            Controller::apply_destructive_boolean(
                model,
                "union",
                &crate::document::controller::BooleanOptions::default(),
            );
        }
        "simplify" => {
            let precision = op.get("precision").and_then(|v| v.as_f64()).unwrap_or(0.5);
            Controller::simplify_selection(model, precision);
        }
        // Unknown verb: a malformed/unsupported production payload is skipped
        // rather than panicking. (The harness corpus only carries known verbs,
        // so this never fires under test — the byte-gate would catch a typo.)
        _ => return,
    }
    // Capture the op into the open transaction so the journal replays to
    // the same document — the checkpoint_equivalence gate (OP_LOG.md §5-6).
    // `targets` (Fork 4) is populated above for the three replay-safe verbs;
    // empty for every other verb (the gate compares documents, not metadata,
    // so empty is fine there). record_op is a no-op when no transaction is open.
    model.record_op(crate::document::op_log::PrimitiveOp {
        op: name.to_string(),
        params: op.clone(),
        targets,
    });
}
