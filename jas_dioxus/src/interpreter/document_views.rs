//! Views of the document that a panel binds under `active_document.*`, built
//! web-free so the web view (`renderer::build_active_document_view`) and the
//! engine's scope (`panel_scope::engine_scope`) call ONE definition (W2b-15).
//! They read only the document and the workspace.

use serde_json::{json, Value};

use crate::document::document::Document;
use crate::geometry::element::Element;
use crate::geometry::live::LiveVariant;

/// The Brushes panel's two gates (BRUSHES.md § Bottom toolbar;
/// runtime_contexts.yaml): `(selection_has_brushed_stroke,
/// selection_is_single_brushed_stroke)`. A selected element is a brushed stroke
/// when it is a path carrying a non-empty `stroke_brush`; only the selected
/// elements are read, never their descendants. A stale selection path counts as
/// nothing, never a panic.
pub fn brushed_stroke_facts(doc: &Document) -> (bool, bool) {
    let brushed = doc.selection.iter().filter(|es| matches!(
        doc.get_element(&es.path),
        Some(Element::Path(p)) if p.stroke_brush.as_deref().is_some_and(|b| !b.is_empty())
    )).count();
    (brushed > 0, doc.selection.len() == 1 && brushed == 1)
}

/// Symbols view (SYMBOLS.md §8). One row per master in the off-canvas
/// store. `name` is the master's common.name, falling back to a
/// positional "Symbol N" label so every row shows something readable.
/// `usage_count` is the number of live instances of the master — the
/// length of its reverse-dependency list (rdeps) in the dependency
/// index, the same signal that gates the reference-aware delete.
pub fn symbols_view(doc: &Document) -> Value {
    let dep_index = crate::document::dependency_index::dependency_index(doc);
    let rows: Vec<Value> = doc
        .symbols
        .iter()
        .enumerate()
        .map(|(i, m)| {
            let id = m.common().id.clone().unwrap_or_default();
            let name = match m.common().name.as_deref() {
                Some(n) if !n.is_empty() => n.to_string(),
                _ => format!("Symbol {}", i + 1),
            };
            let usage_count = dep_index
                .rdeps
                .get(&id)
                .map(|v| v.len())
                .unwrap_or(0);
            json!({
                "id": id,
                "name": name,
                "usage_count": usage_count,
            })
        })
        .collect();
    Value::Array(rows)
}

/// `active_document.selected_concept`: when exactly one `Generated` concept
/// instance is selected, its concept's view ([`concept_view`]); `null` otherwise,
/// so the Concepts panel switches to PARAMS mode only then.
pub fn selected_concept_view(doc: &Document) -> Value {
    if doc.selection.len() != 1 {
        return Value::Null;
    }
    match doc.get_element(&doc.selection[0].path) {
        Some(Element::Live(LiveVariant::Generated(ge))) => concept_view(&ge.concept_id, &ge.params),
        _ => Value::Null,
    }
}

/// Build `active_document.selected_concept` for a selected `Generated` instance:
/// the concept's display name + its declared param schema (name/min/max) merged
/// with the instance's current values (CONCEPTS.md §6.4, Slice 2). Null if the
/// concept is not registered.
pub fn concept_view(
    concept_id: &str,
    instance_params: &serde_json::Value,
) -> serde_json::Value {
    let Some(ws) = crate::interpreter::workspace::Workspace::load() else {
        return serde_json::Value::Null;
    };
    let Some(concept) = ws.concept(concept_id) else {
        return serde_json::Value::Null;
    };
    let name = concept
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or(concept_id);
    let mut params_out: Vec<serde_json::Value> = Vec::new();
    if let Some(schema) = concept.get("params").and_then(|v| v.as_array()) {
        for p in schema {
            let Some(pname) = p.get("name").and_then(|v| v.as_str()) else {
                continue;
            };
            let value = instance_params
                .get(pname)
                .cloned()
                .or_else(|| p.get("default").cloned())
                .unwrap_or(serde_json::Value::Null);
            let mut entry = serde_json::json!({ "name": pname, "value": value });
            if let Some(min) = p.get("min") {
                entry["min"] = min.clone();
            }
            if let Some(max) = p.get("max") {
                entry["max"] = max.clone();
            }
            params_out.push(entry);
        }
    }
    // The concept's named operations (CONCEPTS.md §9): id + label + description,
    // so the panel can render a button per operation. Empty when the concept
    // declares no `operations:`.
    let mut operations_out: Vec<serde_json::Value> = Vec::new();
    if let Some(ops) = concept.get("operations").and_then(|v| v.as_array()) {
        for o in ops {
            let Some(oid) = o.get("id").and_then(|v| v.as_str()) else {
                continue;
            };
            operations_out.push(serde_json::json!({
                "id": oid,
                "label": o.get("label").and_then(|v| v.as_str()).unwrap_or(oid),
                "description": o.get("description").and_then(|v| v.as_str()).unwrap_or(""),
            }));
        }
    }
    // The concept's VIOLATED constraints (CONCEPTS.md §11): evaluate each
    // constraint's `check` over the instance's params; collect the ones that are
    // NOT truthy (`to_bool`, the same truthiness `if` uses), in declared order.
    // Advisory + read-only — the panel surfaces these as a warning. Empty when
    // the concept declares no `constraints:` or all hold.
    let mut violations_out: Vec<serde_json::Value> = Vec::new();
    if let Some(cons) = concept.get("constraints").and_then(|v| v.as_array()) {
        let mut ctx = serde_json::Map::new();
        ctx.insert("param".to_string(), instance_params.clone());
        let ctx = serde_json::Value::Object(ctx);
        for c in cons {
            let Some(cid) = c.get("id").and_then(|v| v.as_str()) else {
                continue;
            };
            let Some(check) = c.get("check").and_then(|v| v.as_str()) else {
                continue;
            };
            if !crate::interpreter::expr::eval(check, &ctx).to_bool() {
                violations_out.push(serde_json::json!({
                    "id": cid,
                    "message": c.get("message").and_then(|v| v.as_str()).unwrap_or(""),
                }));
            }
        }
    }
    serde_json::json!({
        "concept_id": concept_id,
        "name": name,
        "params": params_out,
        "operations": operations_out,
        "violations": violations_out,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::test_fixture::{brushed_path as path, model_with, rect};

    const B: Option<&str> = Some("default_brushes/flat_10");

    /// W2b-18: the reference's table (`test_brush_panel_spec.py::CASES`), row
    /// for row: (name, children, selected, has, single).
    #[test]
    fn brushed_stroke_facts_match_the_reference_table() {
        let cases: Vec<(&str, Vec<Element>, Vec<usize>, bool, bool)> = vec![
            ("one brushed path", vec![path(0.0, B)], vec![0], true, true),
            ("one plain path", vec![path(0.0, None)], vec![0], false, false),
            ("brushed + plain selected", vec![path(0.0, B), path(60.0, None)], vec![0, 1], true, false),
            ("two brushed selected", vec![path(0.0, B), path(60.0, B)], vec![0, 1], true, false),
            ("brushed but NOT selected", vec![path(0.0, B), path(60.0, None)], vec![1], false, false),
            ("a rect", vec![rect(0.0, 0.0, 10.0, 10.0)], vec![0], false, false),
            ("empty brush id", vec![path(0.0, Some(""))], vec![0], false, false),
            ("nothing selected", vec![path(0.0, B)], vec![], false, false),
            ("a stale selection path", vec![path(0.0, B)], vec![7], false, false),
        ];
        for (name, children, sel, has, single) in cases {
            let m = model_with(children, &sel);
            assert_eq!(brushed_stroke_facts(m.document()), (has, single), "{name}");
        }
    }
}
