//! The Layers panel's structural `doc.*` verbs (PHASE3 §5.4-5.5, OP_LOG.md §9
//! Phases P4/P5), ONE implementation for both Rust runners: the web's
//! `renderer::run_yaml_effect` and the shared `effects::run_doc_effect` the
//! engine runs. Until 2026-10-26 they lived only in the web's runner, so the
//! engine refused every Layers-panel action that uses them (STATUS-jas item 22).
//!
//! Each caller supplies its own expression evaluator (`eval`), because the two
//! runners resolve an expression against different contexts; the verbs' laws are
//! here. The mutating verbs journal through `op_apply` (value-in-op: every
//! operand is resolved to a literal first); `doc.set` writes through the model.
//! `doc.create_layer` and `doc.clone_at` are pure binders: they return a value
//! for an `as:` name and change nothing.

use crate::document::model::Model;
use crate::geometry::element::{CommonProps, Element, LayerElem, Visibility};
use crate::interpreter::expr_types::Value;

/// The verbs this module implements.
pub const VERBS: [&str; 9] = [
    "doc.create_layer", "doc.clone_at", "doc.delete_at", "doc.insert_after", "doc.insert_at",
    "doc.unpack_group_at", "doc.wrap_in_layer", "doc.wrap_in_group", "doc.set",
];

/// The value an `as:` name binds for verb `name`, computed BEFORE [`run`]
/// mutates anything: the new Layer for `doc.create_layer`, an id-less deep
/// clone for `doc.clone_at`, the element about to be removed for
/// `doc.delete_at`; `None` for every other verb. JSON `null` when the path
/// names nothing.
pub fn binding(name: &str, spec: &serde_json::Value, eval: &dyn Fn(&str) -> Value, model: &Model) -> Option<serde_json::Value> {
    match name {
        "doc.create_layer" => {
            let name_expr = spec.get("name").and_then(|v| v.as_str()).unwrap_or("'Layer'");
            let name = match eval(name_expr) {
                Value::Str(s) => s,
                Value::Color(c) => c,
                _ => "Layer".to_string(),
            };
            let layer = Element::Layer(LayerElem {
                children: Vec::new(),
                common: CommonProps { name: Some(name), ..Default::default() },
                isolated_blending: false,
                knockout_group: false,
            });
            serde_json::to_value(&layer).ok()
        }
        "doc.clone_at" | "doc.delete_at" => {
            let Value::Path(indices) = eval(spec.as_str().unwrap_or("")) else {
                return Some(serde_json::Value::Null);
            };
            let mut elem = model.document().get_element(&indices).cloned();
            // A COPY IS BORN ID-LESS: a duplicate lands in the SAME parent while
            // the original stays, so a clone keeping its ids would leave two live
            // elements wearing each id (REFERENCE_GRAPH.md §2.5).
            if name == "doc.clone_at" {
                if let Some(e) = elem.as_mut() {
                    crate::geometry::element::clear_ids(e);
                }
            }
            Some(elem.and_then(|e| serde_json::to_value(&e).ok()).unwrap_or(serde_json::Value::Null))
        }
        _ => None,
    }
}

/// Run verb `name`, or return `false` when it is not one of [`VERBS`]. `ctx` is
/// the caller's context, read for a bare identifier an `element:` argument
/// names (an `as:` binding). A malformed operand does nothing.
pub fn run(name: &str, spec: &serde_json::Value, ctx: &serde_json::Value, eval: &dyn Fn(&str) -> Value, model: &mut Model) -> bool {
    let apply = |model: &mut Model, op: serde_json::Value| {
        let _ = crate::document::op_apply::op_apply(model, &op);
    };
    match name {
        // Pure binders: their whole effect is the `as:` value.
        "doc.create_layer" | "doc.clone_at" => {}
        "doc.delete_at" => {
            if let Value::Path(indices) = eval(spec.as_str().unwrap_or("")) {
                apply(model, serde_json::json!({"op": "delete_at", "path": indices}));
            }
        }
        // VALUE-IN-OP: the resolved element is carried WHOLE in the op.
        "doc.insert_after" => {
            let path = spec.get("path").and_then(|v| v.as_str()).unwrap_or("");
            if let (Value::Path(indices), Some(e)) = (eval(path), resolve_element_arg(spec.get("element"), ctx, eval)) {
                if let Ok(element) = serde_json::to_value(&e) {
                    apply(model, serde_json::json!({"op": "insert_after", "path": indices, "element": element}));
                }
            }
        }
        "doc.insert_at" => {
            let parent = spec.get("parent_path").and_then(|v| v.as_str()).unwrap_or("path()");
            let Value::Path(parent_indices) = eval(parent) else { return true };
            let index = match spec.get("index") {
                Some(serde_json::Value::String(s)) => match eval(s) {
                    Value::Number(n) => n as usize,
                    _ => 0,
                },
                Some(serde_json::Value::Number(n)) => n.as_u64().unwrap_or(0) as usize,
                _ => 0,
            };
            if let Some(e) = resolve_element_arg(spec.get("element"), ctx, eval) {
                if let Ok(element) = serde_json::to_value(&e) {
                    apply(model, serde_json::json!({
                        "op": "insert_at", "parent_path": parent_indices, "index": index, "element": element,
                    }));
                }
            }
        }
        // Replace a Group at path with its children in place (a non-Group
        // target is a no-op), as ONE journaled op on the resolved path.
        "doc.unpack_group_at" => {
            if let Value::Path(indices) = eval(spec.as_str().unwrap_or("")) {
                apply(model, serde_json::json!({"op": "unpack_group_at", "path": indices}));
            }
        }
        // The wrapping verbs journal ONE op on the resolved, sorted paths. The
        // layer's `name` is resolved against the LIVE document first, so replay
        // never re-derives a possibly-colliding name.
        "doc.wrap_in_layer" | "doc.wrap_in_group" => {
            let paths_expr = spec.get("paths").and_then(|v| v.as_str()).unwrap_or("[]");
            let Value::List(raw) = eval(paths_expr) else { return true };
            let paths = normalize_path_markers(&raw);
            if paths.is_empty() {
                return true;
            }
            let mut op = if name == "doc.wrap_in_layer" {
                let name_expr = spec.get("name").and_then(|v| v.as_str()).unwrap_or("'Layer'");
                let layer_name = match eval(name_expr) {
                    Value::Str(s) => s,
                    _ => "Layer".to_string(),
                };
                serde_json::json!({"op": "wrap_in_layer", "paths": paths, "name": layer_name})
            } else {
                serde_json::json!({"op": "wrap_in_group", "paths": paths})
            };
            // An optional value-in-op container id, journaled as a literal.
            if let Some(Value::Str(id)) = spec.get("id").and_then(|v| v.as_str()).map(|e| eval(e)) {
                op["id"] = serde_json::Value::String(id);
            }
            apply(model, op);
        }
        "doc.set" => {
            let path = spec.get("path").and_then(|v| v.as_str()).unwrap_or("");
            let Value::Path(indices) = eval(path) else { return true };
            if let Some(fields) = spec.get("fields").and_then(|v| v.as_object()) {
                for (dotted, expr_v) in fields {
                    let val = match expr_v.as_str() {
                        Some(expr) => eval(expr),
                        None => Value::from_json(expr_v),
                    };
                    set_field(model, &indices, dotted, &val);
                }
            }
        }
        _ => return false,
    }
    true
}

/// Resolve an `element:` argument: a bare identifier naming a ctx-bound
/// element (an `as:` binding) read DIRECTLY, so the JSON object is not
/// stringified by the Value round trip; else an expression; else a raw JSON
/// element.
fn resolve_element_arg(arg: Option<&serde_json::Value>, ctx: &serde_json::Value, eval: &dyn Fn(&str) -> Value) -> Option<Element> {
    match arg? {
        serde_json::Value::String(s) => {
            if let Some(direct) = ctx.get(s) {
                if let Ok(elem) = serde_json::from_value::<Element>(direct.clone()) {
                    return Some(elem);
                }
            }
            serde_json::from_value::<Element>(crate::interpreter::effects::value_to_json(&eval(s))).ok()
        }
        other => serde_json::from_value::<Element>(other.clone()).ok(),
    }
}

/// `{__path__: [..]}` markers as plain index arrays, malformed items dropped,
/// sorted into document order (the collect and the reverse-delete in op_apply
/// both depend on it).
fn normalize_path_markers(raw: &[serde_json::Value]) -> Vec<Vec<usize>> {
    let mut out: Vec<Vec<usize>> = raw.iter()
        .filter_map(|item| item.get("__path__")?.as_array()?.iter()
            .map(|n| n.as_u64().map(|u| u as usize)).collect())
        .collect();
    out.sort();
    out
}

/// Write one dotted field of the TOP-LEVEL layer at `path` (`common.visibility`,
/// `common.locked`, `common.opacity`, `name`). A locked layer is locked by
/// inheritance at read time, never by setting the flag on its contents.
/// Anything else, or a path that is not one top-level index, does nothing.
fn set_field(model: &mut Model, path: &[usize], dotted: &str, value: &Value) {
    let [idx] = path else { return };
    let mut doc = model.document().clone();
    let Some(elem) = doc.layers.get_mut(*idx) else { return };
    let written = match (dotted, value) {
        ("common.visibility", Value::Str(s)) => match s.as_str() {
            "invisible" => Some(Visibility::Invisible),
            "outline" => Some(Visibility::Outline),
            "preview" => Some(Visibility::Preview),
            _ => None,
        }
        .map(|v| elem.common_mut().visibility = v)
        .is_some(),
        ("common.locked", Value::Bool(b)) => {
            elem.common_mut().locked = *b;
            true
        }
        ("common.opacity", Value::Number(n)) => {
            elem.common_mut().opacity = *n;
            true
        }
        ("name", Value::Str(s)) => match elem {
            Element::Layer(le) => {
                le.set_name(s.clone());
                true
            }
            _ => false,
        },
        _ => false,
    };
    if written {
        model.set_document(doc);
    }
}
