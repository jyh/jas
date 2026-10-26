//! W2b-17 (fork F-J): the Symbols and Concepts panels' native verbs, web-free.
//!
//! Their YAML actions are `log` stubs: the verbs mint ids by the value-in-op
//! rule and call the shared Controller / `op_apply` ops, which the effects
//! runner cannot express. The web's `dispatch_action` and the engine's
//! `EngineHost` both call [`run`], so there is ONE implementation.
//!
//! The panel selection is a PARAMETER, not a slot: the web passes its
//! `AppState` fields, and the engine passes the store's `symbols.selected_symbol`
//! and `concepts.selected_concept`, which is where the YAML's own
//! `set_panel_state` writes them and where Swift reads them.

use serde_json::{json, Map, Value};

use crate::document::artboard::{generate_element_id, mint_unique_ids};
use crate::document::controller::Controller;
use crate::document::document::SelectionKind;
use crate::document::model::Model;
use crate::geometry::element::{Element, Transform};
use crate::geometry::live::LiveVariant;
use crate::interpreter::expr::eval;
use crate::interpreter::expr_types::Value as EVal;
use crate::interpreter::workspace::Workspace;

/// The three action names this module hosts. Since 2026-10-26 five verbs that
/// were hosted here run their YAML instead: `new_symbol` (`doc.new_symbol`,
/// [`run_new_symbol`]), `place_instance`
/// (`doc.place_instance`, [`place_instance_ops`]), `place_concept_instance`
/// (`doc.place_concept_instance`, [`place_concept_instance_ops`]),
/// `set_concept_param` (`doc.set_concept_param`, [`set_concept_param_ops`])
/// and `promote_to_concept` (`doc.promote_to_concept`,
/// [`promote_to_concept_ops`]).
pub const ACTIONS: [&str; 3] = [
    "delete_symbol_action", "delete_symbol_orphan_confirm_ok", "apply_concept_operation",
];

/// What a hosted verb asks its caller to do besides the document change it
/// already made.
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    /// Nothing further (including a verb that found nothing to do).
    Done,
    /// The Symbols panel's selection becomes this (`None` clears it).
    SelectSymbol(Option<String>),
    /// Open the named confirm dialog with these params; the document is
    /// unchanged. The engine opens it in its store (the dialog door).
    Dialog { id: String, params: Value },
    /// Close the open dialog (the confirm's OK already ran). When it deleted
    /// the master, the Symbols panel's selection is cleared as well.
    CloseDialog { cleared_selection: bool },
}

/// Run the hosted verb `action`, or `None` when it is not one of [`ACTIONS`].
pub fn run(
    model: &mut Model,
    action: &str,
    params: &Value,
    selected_symbol: Option<&str>,
) -> Option<Outcome> {
    Some(match action {
        "delete_symbol_action" => {
            let Some(master) = selected_symbol else { return Some(Outcome::Done) };
            let usage = crate::document::dependency_index::dependency_index(model.document())
                .rdeps.get(master).map(|v| v.len()).unwrap_or(0);
            if usage > 0 {
                // Reference-aware: warn first, mutate nothing.
                return Some(Outcome::Dialog {
                    id: "delete_symbol_orphan_confirm".into(),
                    params: json!({"count": usage}),
                });
            }
            model.with_txn(|m| Controller::delete_symbol(m, master));
            Outcome::SelectSymbol(None)
        }
        "delete_symbol_orphan_confirm_ok" => {
            let Some(master) = selected_symbol else {
                return Some(Outcome::CloseDialog { cleared_selection: false });
            };
            model.with_txn(|m| Controller::delete_symbol(m, master));
            Outcome::CloseDialog { cleared_selection: true }
        }
        "apply_concept_operation" => {
            apply_concept_operation(model, params);
            Outcome::Done
        }
        _ => return None,
    })
}

/// The one value-in-op op the Symbols panel's Place Instance applies
/// (`doc.place_instance` in actions.yaml): `place_instance` of `master` with a
/// freshly minted reference id (SYMBOLS.md §7), or `None` when the mint fails.
/// The reference's `document.controller.place_instance_ops` mints the same op.
pub fn place_instance_ops(doc: &crate::document::document::Document, master: &str) -> Option<Vec<Value>> {
    let mut existing = doc.element_ids();
    let ids = mint_unique_ids(1, &mut existing, &mut || generate_element_id(None))?;
    Some(vec![json!({"op": "place_instance", "master_id": master, "ref_id": ids[0]})])
}

/// The path of the single selected element, if exactly one is selected.
fn single_path(model: &Model) -> Option<Vec<usize>> {
    let sel = &model.document().selection;
    (sel.len() == 1).then(|| sel[0].path.clone())
}

/// The one value-in-op op Make Symbol applies (`doc.new_symbol` in
/// actions.yaml, SYMBOLS.md §7), or `None` unless exactly ONE element is
/// wholly selected, or the mint fails: `make_symbol` of its path with a minted
/// master id and reference id. The reference's `new_symbol_ops`.
pub fn new_symbol_ops(doc: &crate::document::document::Document) -> Option<Vec<Value>> {
    let [es] = doc.selection.as_slice() else { return None };
    if es.kind != SelectionKind::All {
        return None;
    }
    let mut existing = doc.element_ids();
    let ids = mint_unique_ids(2, &mut existing, &mut || generate_element_id(None))?;
    Some(vec![json!({"op": "make_symbol", "path": es.path, "master_id": ids[0], "ref_id": ids[1]})])
}

/// The master a Make Symbol at `path` made, read AFTER the op: make_symbol
/// keeps an element's own id as the master key, so the minted id is not
/// always the master. The target of the reference now at `path`, else `None`.
/// The reference's `new_symbol_master`.
pub fn new_symbol_master(doc: &crate::document::document::Document, path: &[usize]) -> Option<String> {
    match doc.get_element(&path.to_vec()) {
        Some(Element::Live(LiveVariant::Reference(r))) => Some(r.target.0.clone()),
        _ => None,
    }
}

/// Run Make Symbol on `model` (`doc.new_symbol`): its op, then the master it
/// made, for an `as:` name (`None` when nothing ran). Both Rust runners call it.
pub fn run_new_symbol(model: &mut Model) -> Option<String> {
    let ops = new_symbol_ops(model.document())?;
    let path: Vec<usize> = ops[0]["path"].as_array()?.iter()
        .filter_map(|v| v.as_u64().map(|n| n as usize)).collect();
    for op in &ops {
        let _ = crate::document::op_apply::op_apply(model, op);
    }
    new_symbol_master(model.document(), &path)
}

/// A concept's declared default params (`params: [{name, default}]`) as a
/// params object. The reference's `document.controller.concept_default_params`.
pub fn concept_default_params(concept: &Value) -> Map<String, Value> {
    let mut defaults = Map::new();
    for p in concept.get("params").and_then(Value::as_array).into_iter().flatten() {
        if let (Some(name), Some(def)) = (p.get("name").and_then(Value::as_str), p.get("default")) {
            defaults.insert(name.to_string(), def.clone());
        }
    }
    defaults
}

/// The one value-in-op op the Concepts panel's Place Instance applies
/// (`doc.place_concept_instance` in actions.yaml): `place_concept_instance` of
/// `concept_id` with its declared default params and a freshly minted id
/// (CONCEPTS.md §6), or `None` when the registry does not declare the concept
/// or the mint fails. The reference's `place_concept_instance_ops`.
pub fn place_concept_instance_ops(doc: &crate::document::document::Document, concept_id: &str) -> Option<Vec<Value>> {
    let concept = Workspace::load().and_then(|w| w.concept(concept_id).cloned())?;
    let mut existing = doc.element_ids();
    let ids = mint_unique_ids(1, &mut existing, &mut || generate_element_id(None))?;
    Some(vec![json!({
        "op": "place_concept_instance",
        "concept_id": concept_id,
        "params": Value::Object(concept_default_params(&concept)),
        "elem_id": ids[0],
    })])
}

/// A committed concept-param value as a finite number: a number, or a string
/// that is exactly a decimal number (`9`, `-2.5`, `1e3`; never `inf`, `NaN`
/// or a padded one); anything else `None`. The reference's
/// `concept_param_value`.
pub fn concept_param_value(value: &EVal) -> Option<f64> {
    let v = match value {
        EVal::Number(n) => *n,
        EVal::Str(s) if is_decimal(s) => s.parse::<f64>().ok()?,
        _ => return None,
    };
    v.is_finite().then_some(v)
}

/// `[+-]?(digits[.digits?] | .digits)([eE][+-]?digits)?`, the reference's
/// pattern.
fn is_decimal(s: &str) -> bool {
    let b = s.as_bytes();
    let mut i = 0;
    let digits = |i: &mut usize| { let st = *i; while *i < b.len() && b[*i].is_ascii_digit() { *i += 1; } *i - st };
    if i < b.len() && (b[i] == b'+' || b[i] == b'-') { i += 1; }
    let int = digits(&mut i);
    let mut frac = 0;
    if i < b.len() && b[i] == b'.' { i += 1; frac = digits(&mut i); }
    if int == 0 && frac == 0 { return false; }
    if i < b.len() && (b[i] == b'e' || b[i] == b'E') {
        i += 1;
        if i < b.len() && (b[i] == b'+' || b[i] == b'-') { i += 1; }
        if digits(&mut i) == 0 { return false; }
    }
    i == b.len()
}

/// The one value-in-op op a Concepts-panel parameter field's commit applies
/// (`doc.set_concept_param` in actions.yaml): `set_concept_param` of the one
/// selected generated instance (CONCEPTS.md §6.4), or `None` unless `value` is
/// a finite number ([`concept_param_value`]) and exactly one generated instance
/// is selected. The reference's `set_concept_param_ops`.
pub fn set_concept_param_ops(doc: &crate::document::document::Document, name: &str, value: &EVal) -> Option<Vec<Value>> {
    let value = concept_param_value(value)?;
    let [es] = doc.selection.as_slice() else { return None };
    let Some(Element::Live(LiveVariant::Generated(_))) = doc.get_element(&es.path) else { return None };
    Some(vec![json!({"op": "set_concept_param", "path": es.path, "name": name, "value": value})])
}

/// Apply a named concept operation to the single selected generated instance
/// (CONCEPTS.md §9), resolving its `set:` expressions over the instance's
/// current params at production time and baking the `changes` into the op.
fn apply_concept_operation(model: &mut Model, params: &Value) {
    let Some(op_id) = params.get("op_id").and_then(Value::as_str) else { return };
    let Some(path) = single_path(model) else { return };
    let Some(Element::Live(LiveVariant::Generated(ge))) = model.document().get_element(&path).cloned()
    else {
        return;
    };
    let changes = Workspace::load().and_then(|w| w.concept(&ge.concept_id).cloned()).and_then(|c| {
        let operation = c.get("operations")?.as_array()?.iter()
            .find(|o| o.get("id").and_then(Value::as_str) == Some(op_id))?.clone();
        let set = operation.get("set")?.as_object()?.clone();
        let ctx = json!({"param": ge.params.clone()});
        let mut changes = Map::new();
        for (name, expr_v) in &set {
            if let Some(src) = expr_v.as_str() {
                if let EVal::Number(n) = eval(src, &ctx) {
                    changes.insert(name.clone(), json!(n));
                }
            }
        }
        Some(changes)
    });
    let Some(changes) = changes.filter(|c| !c.is_empty()) else { return };
    let op = json!({
        "op": "apply_concept_operation",
        "path": path,
        "op_id": op_id,
        "changes": Value::Object(changes),
    });
    model.with_txn(|m| {
        m.name_txn("apply_concept_operation");
        let _ = crate::document::op_apply::op_apply(m, &op);
    });
}

/// Promote the single selected polygon or polyline to a generated concept
/// instance (CONCEPTS.md §10): try each registered concept's `fitter` over the
/// element's WORLD-space points, in sorted-id order, and take the first match.
/// A no-match is a silent no-op.
/// The one op Object > Promote to Concept applies (`doc.promote_to_concept`
/// in actions.yaml, CONCEPTS.md §10), or `None` unless exactly one polygon or
/// polyline is selected and a registered concept's fitter matches it: the
/// element's transform baked into its points, concepts in sorted-id order,
/// the first fitter returning k params + cx, cy, rot wins, placed at
/// translate(cx, cy) · rotate(rot). The reference's `promote_to_concept_ops`.
pub fn promote_to_concept_ops(doc: &crate::document::document::Document) -> Option<Vec<Value>> {
    let [es] = doc.selection.as_slice() else { return None };
    let path = es.path.clone();
    let elem = doc.get_element(&path).cloned()?;
    let raw_points: Vec<(f64, f64)> = match &elem {
        Element::Polygon(p) => p.points.clone(),
        Element::Polyline(p) => p.points.clone(),
        _ => return None,
    };
    let pts: Vec<(f64, f64)> = match elem.common().transform.as_ref() {
        Some(t) => raw_points.iter().map(|(x, y)| t.apply_point(*x, *y)).collect(),
        None => raw_points,
    };
    let ctx = json!({"shape": {"points": pts.iter().map(|(x, y)| json!([*x, *y])).collect::<Vec<_>>()}});
    let ws = Workspace::load()?;
    let registry = ws.concepts()?;
    let mut ids: Vec<&String> = registry.keys().collect();
    ids.sort();
    let mut chosen: Option<(String, Value, f64, f64, f64)> = None;
    for id in ids {
        let concept = &registry[id];
        let Some(fitter) = concept.get("fitter").and_then(Value::as_str) else { continue };
        let EVal::List(items) = eval(fitter, &ctx) else { continue };
        let names: Vec<String> = concept.get("params").and_then(Value::as_array)
            .map(|ps| ps.iter().filter_map(|p| p.get("name").and_then(Value::as_str).map(String::from))
                .collect())
            .unwrap_or_default();
        let k = names.len();
        if items.len() < k + 3 {
            continue; // malformed fitter output (need params + cx, cy, rot)
        }
        let nums: Vec<f64> = items.iter().map(|v| v.as_f64().unwrap_or(0.0)).collect();
        let mut p = Map::new();
        for (i, name) in names.iter().enumerate() {
            p.insert(name.clone(), json!(nums[i]));
        }
        chosen = Some((id.clone(), Value::Object(p), nums[k], nums[k + 1], nums[k + 2]));
        break;
    }
    let (concept_id, params, cx, cy, rot) = chosen?;
    // Placement: translate(cx, cy) * rotate(rot).
    let t = Transform::translate(cx, cy).multiply(&Transform::rotate(rot));
    Some(vec![json!({
        "op": "promote_to_concept",
        "path": path,
        "concept_id": concept_id,
        "params": params,
        "transform": [t.a, t.b, t.c, t.d, t.e, t.f],
    })])
}
