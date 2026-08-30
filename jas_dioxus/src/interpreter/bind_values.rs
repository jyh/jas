//! Shared canonical panel bind-VALUE snapshot pass (TESTING_STRATEGY.md §4).
//!
//! Rust port of `workspace_interpreter/bind_values.py`, the third sibling of
//! `panel_layout::layout_panel` (per-widget *rects*) and
//! `widget_tree::widget_tree` (per-widget *structural records*). Where those two
//! are deliberately value-blind, this pass RESOLVES the panel's data bindings
//! and pins the resulting strings.
//!
//! Why a third pass instead of widening one of the other two: `widget_tree`
//! records the sorted KEY NAMES of `bind` / `style` and collapses a dynamic
//! `visible` into a `dyn_visible` flag on purpose — that is what makes it
//! stable, and widening it would rewrite every record it emits. `panel_layout`
//! resolves `{{ }}` text but consumes it as `chars().count() * CHAR_WIDTH`, so
//! any two strings of equal length produce the same rect.
//!
//! Together those leave the bind-VALUE surface unpinned. Measured on the Color
//! panel: the two data scopes that differ only in `panel.hex` — `"664040"` vs
//! `"664141"`, the byte pattern of the colour divergence the corpus census was
//! written to answer — produce IDENTICAL `widget_tree` output and IDENTICAL
//! `layout_panel` rects, and differ in exactly one row here. Both halves are
//! asserted in `cross_language_test::bind_values_separates_equal_length_hex_*`.
//!
//! Output is a pre-order JSON array of
//! `{"path": [int, ...], "id": str, "key": str, "type": str, "value": str}`.
//! `path` uses the same scheme as `widget_tree`. `key` is `"visible"` for a
//! dynamic `visible: <expr>` string, `"bind.<name>"` per `bind` key in sorted
//! order, and `"content"` / `"label"` for a node string containing `{{ }}`.
//! A node with none of those emits NO row, so the snapshot's size tracks the
//! panel's binding surface rather than its widget count.
//!
//! `value` is built only from `Value::to_string_coerce` — the same coercion
//! `{{ }}` interpolation uses — so this pass adds no new number-formatting
//! surface. A `bind` expression evaluating to a JSON OBJECT becomes a JSON
//! STRING inside the evaluator, whose key order is a known cross-port
//! divergence; no vector in `panel_bind_values.json` binds an object.

use serde_json::{json, Value as Json};

use super::expr::{eval, eval_text};
use super::expr_types::Value as EVal;

/// Walk a compiled panel node (`{"type":"panel","content":<root>}`) into a
/// pre-order JSON array of resolved-binding records (see the module docs).
///
/// `ctx` is the data scope (`state` / `panel` / `data` / `active_document`
/// namespaces, plus any `foreach` item bindings added during the walk); pass
/// `{}` for a scope in which every binding resolves to null.
//
// WIRED 2026-08-25 (S-C.1): `ffi::jas_bind_values` is now a production caller,
// so the `#[allow(dead_code)]` that stood here — and the note that this pass was
// "not yet wired into a render path" — are both retired. The cross-app byte-gate
// remains the parity pin; it is no longer the only reason this code is reachable.
pub fn bind_values(panel_node: &Json, ctx: &Json) -> Json {
    let root = match panel_node.get("content") {
        Some(r) if r.is_object() => r,
        _ => return json!([]),
    };
    let mut out: Vec<Json> = vec![];
    walk(root, &[], ctx, &mut out);
    Json::Array(out)
}

/// The canonical `(type, value)` pair for one evaluated value. Scalars use the
/// shared interpolation coercion; a list is `"["` + elements joined by `","` +
/// `"]"`, each element canonicalized the same way (nested lists nest brackets).
#[allow(dead_code)] // Reachable only through `bind_values` (test-only caller).
fn canon_value(v: &EVal) -> (&'static str, String) {
    match v {
        EVal::Null => ("null", v.to_string_coerce()),
        EVal::Bool(_) => ("bool", v.to_string_coerce()),
        EVal::Number(_) => ("number", v.to_string_coerce()),
        EVal::Str(_) => ("string", v.to_string_coerce()),
        EVal::Color(_) => ("color", v.to_string_coerce()),
        EVal::Path(_) => ("path", v.to_string_coerce()),
        EVal::Closure { .. } => ("closure", v.to_string_coerce()),
        EVal::List(items) => {
            let parts: Vec<String> = items
                .iter()
                .map(|e| canon_value(&EVal::from_json(e)).1)
                .collect();
            ("list", format!("[{}]", parts.join(",")))
        }
    }
}

#[allow(dead_code)] // Reachable only through `bind_values` (test-only caller).
fn row(path: &[i64], node_id: &str, key: &str, v: &EVal) -> Json {
    let (ty, val) = canon_value(v);
    json!({"path": path, "id": node_id, "key": key, "type": ty, "value": val})
}

/// Every resolved-binding record for one node (no recursion).
#[allow(dead_code)] // Reachable only through `bind_values` (test-only caller).
fn rows_for(node: &Json, path: &[i64], ctx: &Json, out: &mut Vec<Json>) {
    let nid = node.get("id").and_then(|v| v.as_str()).unwrap_or("");
    // A dynamic `visible:` expression, coerced through the shared truthiness
    // rule. The compiled bundle lands the YAML `visible: <expr>` form under
    // `bind` instead, so this arm is carried for completeness.
    if let Some(expr) = node.get("visible").and_then(|v| v.as_str()) {
        out.push(row(path, nid, "visible", &EVal::Bool(eval(expr, ctx).to_bool())));
    }
    if let Some(map) = node.get("bind").and_then(|v| v.as_object()) {
        let mut keys: Vec<&String> = map.keys().collect();
        keys.sort();
        for k in keys {
            let entry = &map[k];
            let v = match entry.as_str() {
                Some(expr) => eval(expr, ctx),
                // A non-string `bind` entry is a literal in the bundle; record
                // it through the same coercion so the row shape stays uniform.
                None => EVal::from_json(entry),
            };
            out.push(row(path, nid, &format!("bind.{}", k), &v));
        }
    }
    // `{{ }}`-bearing content / label: the surface panel_layout reduces to a
    // scalar count. A literal string carries no binding and is not recorded.
    for key in ["content", "label"] {
        if let Some(raw) = node.get(key).and_then(|v| v.as_str()) {
            if raw.contains("{{") {
                out.push(row(path, nid, key, &EVal::Str(eval_text(raw, ctx))));
            }
        }
    }
}

#[allow(dead_code)] // Reachable only through `bind_values` (test-only caller).
fn walk(node: &Json, path: &[i64], ctx: &Json, out: &mut Vec<Json>) {
    rows_for(node, path, ctx, out);
    // A foreach container expands its `do` template once per item of
    // eval(foreach.source, ctx) — the same expansion widget_tree performs, so a
    // path here names the same node it names there.
    let foreach = node.get("foreach").filter(|v| v.is_object());
    let do_template = node.get("do").filter(|v| !v.is_null());
    if let (Some(spec), Some(template)) = (foreach, do_template) {
        let src = spec.get("source").and_then(|v| v.as_str()).unwrap_or("");
        let var = spec.get("as").and_then(|v| v.as_str()).unwrap_or("item");
        let items: Vec<Json> = match eval(src, ctx) {
            EVal::List(v) => v,
            _ => vec![],
        };
        let base_obj = ctx.as_object().cloned().unwrap_or_default();
        for (i, item) in items.into_iter().enumerate() {
            let mut item_data = match item {
                Json::Object(m) => m,
                other => {
                    let mut m = serde_json::Map::new();
                    m.insert("_value".to_string(), other);
                    m
                }
            };
            item_data.insert("_index".to_string(), json!(i));
            let mut child = base_obj.clone();
            child.insert(var.to_string(), Json::Object(item_data));
            let child_ctx = Json::Object(child);
            let mut cp = path.to_vec();
            cp.push(i as i64);
            if template.is_object() {
                walk(template, &cp, &child_ctx, out);
            }
        }
        return;
    }
    // Plain container: recurse every object child at its declared index,
    // including statically-hidden ones (mirrors widget_tree, not the layout
    // pass) so a binding on a wrongly-hidden widget stays comparable.
    if let Some(children) = node.get("children").and_then(|v| v.as_array()) {
        for (i, child) in children.iter().enumerate() {
            if child.is_object() {
                let mut cp = path.to_vec();
                cp.push(i as i64);
                walk(child, &cp, ctx, out);
            }
        }
    }
}
