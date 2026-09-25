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

/// The eight action names this module hosts.
pub const ACTIONS: [&str; 8] = [
    "new_symbol", "place_instance", "delete_symbol_action", "delete_symbol_orphan_confirm_ok",
    "place_concept_instance", "set_concept_param", "apply_concept_operation", "promote_to_concept",
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
    /// unchanged. The engine has no dialog door and refuses this by name.
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
    selected_concept: Option<&str>,
) -> Option<Outcome> {
    Some(match action {
        "new_symbol" => new_symbol(model),
        "place_instance" => {
            if let (Some(master), Some(ids)) = (selected_symbol, mint(model, 1)) {
                model.with_txn(|m| Controller::place_instance(m, master, &ids[0]));
            }
            Outcome::Done
        }
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
        "place_concept_instance" => {
            if let Some(concept_id) = selected_concept {
                place_concept_instance(model, concept_id);
            }
            Outcome::Done
        }
        "set_concept_param" => {
            set_concept_param(model, params);
            Outcome::Done
        }
        "apply_concept_operation" => {
            apply_concept_operation(model, params);
            Outcome::Done
        }
        "promote_to_concept" => {
            promote_to_concept(model);
            Outcome::Done
        }
        _ => return None,
    })
}

/// Mint `count` collision-free element ids against every id already in the
/// document, through THE ONE MINT LOOP.
fn mint(model: &Model, count: usize) -> Option<Vec<String>> {
    let mut existing = model.document().element_ids();
    mint_unique_ids(count, &mut existing, &mut || generate_element_id(None))
}

/// The path of the single selected element, if exactly one is selected.
fn single_path(model: &Model) -> Option<Vec<usize>> {
    let sel = &model.document().selection;
    (sel.len() == 1).then(|| sel[0].path.clone())
}

/// Promote the single selected whole element to a master (SYMBOLS.md §7), and
/// select the new master so Place and Delete target it at once.
fn new_symbol(model: &mut Model) -> Outcome {
    let sel = &model.document().selection;
    let [es] = sel.as_slice() else { return Outcome::Done };
    if es.kind != SelectionKind::All {
        return Outcome::Done;
    }
    let path = es.path.clone();
    let Some(ids) = mint(model, 2) else { return Outcome::Done };
    let (master_id, ref_id) = (ids[0].clone(), ids[1].clone());
    model.with_txn(|m| Controller::make_symbol(m, &path, &master_id, &ref_id));
    // make_symbol keeps an existing id as the master key; resolve which id
    // actually became the master from the path's instance target.
    let resolved = match model.document().get_element(&path) {
        Some(Element::Live(LiveVariant::Reference(r))) => r.target.0.clone(),
        _ => master_id,
    };
    Outcome::SelectSymbol(Some(resolved))
}

/// Place a generated instance of `concept_id` with its declared default params
/// (CONCEPTS.md §6), journaled as a `place_concept_instance` op.
fn place_concept_instance(model: &mut Model, concept_id: &str) {
    let mut defaults = Map::new();
    if let Some(c) = Workspace::load().and_then(|w| w.concept(concept_id).cloned()) {
        for p in c.get("params").and_then(Value::as_array).into_iter().flatten() {
            if let (Some(name), Some(def)) = (p.get("name").and_then(Value::as_str), p.get("default")) {
                defaults.insert(name.to_string(), def.clone());
            }
        }
    }
    let Some(ids) = mint(model, 1) else { return };
    let op = json!({
        "op": "place_concept_instance",
        "concept_id": concept_id,
        "params": Value::Object(defaults),
        "elem_id": ids[0],
    });
    model.with_txn(|m| {
        m.name_txn("place_concept_instance");
        let _ = crate::document::op_apply::op_apply(m, &op);
    });
}

/// Set one param of the single selected generated instance (Slice 2).
fn set_concept_param(model: &mut Model, params: &Value) {
    let Some(name) = params.get("name").and_then(Value::as_str) else { return };
    let Some(value) = params.get("value").and_then(|v| {
        v.as_f64().or_else(|| v.as_str().and_then(|s| s.parse::<f64>().ok()))
    }) else {
        return;
    };
    let Some(path) = single_path(model) else { return };
    let op = json!({"op": "set_concept_param", "path": path, "name": name, "value": value});
    model.with_txn(|m| {
        m.name_txn("set_concept_param");
        let _ = crate::document::op_apply::op_apply(m, &op);
    });
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
fn promote_to_concept(model: &mut Model) {
    let Some(path) = single_path(model) else { return };
    let Some(elem) = model.document().get_element(&path).cloned() else { return };
    let raw_points: Vec<(f64, f64)> = match &elem {
        Element::Polygon(p) => p.points.clone(),
        Element::Polyline(p) => p.points.clone(),
        _ => return,
    };
    let pts: Vec<(f64, f64)> = match elem.common().transform.as_ref() {
        Some(t) => raw_points.iter().map(|(x, y)| t.apply_point(*x, *y)).collect(),
        None => raw_points,
    };
    let ctx = json!({"shape": {"points": pts.iter().map(|(x, y)| json!([*x, *y])).collect::<Vec<_>>()}});
    let Some(ws) = Workspace::load() else { return };
    let Some(registry) = ws.concepts() else { return };
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
    let Some((concept_id, params, cx, cy, rot)) = chosen else { return };
    // Placement: translate(cx, cy) * rotate(rot).
    let t = Transform::translate(cx, cy).multiply(&Transform::rotate(rot));
    let op = json!({
        "op": "promote_to_concept",
        "path": path,
        "concept_id": concept_id,
        "params": params,
        "transform": [t.a, t.b, t.c, t.d, t.e, t.f],
    });
    model.with_txn(|m| {
        m.name_txn("promote_to_concept");
        let _ = crate::document::op_apply::op_apply(m, &op);
    });
}
