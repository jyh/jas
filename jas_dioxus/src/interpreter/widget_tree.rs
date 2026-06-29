//! Shared canonical panel widget-TREE snapshot pass (TESTING_STRATEGY.md §4).
//!
//! Rust port of `workspace_interpreter/widget_tree.py`, the structural sibling
//! of `panel_layout::layout_panel`.  Where the layout pass computes per-widget
//! *rects*, this pass emits a per-widget *structural record* — byte-identical
//! across all native apps — so the panel widget tree itself (its shape, kinds,
//! and which widgets dispatch vs. fall to a placeholder) is a cross-app
//! byte-gate instead of five framework renderings eyeballed side by side.
//!
//! Determinism / portability is the same contract as `panel_layout`: every
//! field is read straight from the compiled bundle; the ONLY expression
//! evaluated is a `foreach` source (to know how many expansions) — the same
//! evaluation `layout_panel` already does and the panel_layout corpus already
//! pins, so no new cross-language eval surface is introduced.  `bind` / `style`
//! record the SORTED KEY SETS (not the expressions/values), so the snapshot
//! captures structure without depending on per-value formatting.
//!
//! Output is a pre-order (parent before children) list of records; `path` is
//! the node's tree path relative to the panel content root (root = `[]`, its
//! i-th declared child = `[i]`, a foreach's i-th expansion = `[..., i]`) — the
//! same path scheme as `panel_layout` except statically-hidden children are
//! kept (recorded with `visible: false`) instead of dropped.

use serde_json::{json, Map, Value};

use super::expr::eval;
use super::expr_types::Value as EVal;

/// Canonical widget-kind vocabulary: the union of kinds rendered by at least
/// one app's panel/dialog dispatch.  The single source of truth is
/// `widget_tree.py`'s `CANONICAL_WIDGET_KINDS`; each native port bakes a copy
/// and the `panel_widget_tree.json` golden enforces they stay in sync — a
/// drifted copy flips a `kind` from its `type` to "placeholder" (or back) and
/// reddens the cross-app gate.
const CANONICAL_WIDGET_KINDS: [&str; 37] = [
    "container", "row", "col", "grid",
    "text", "button", "icon", "icon_button", "icon_select",
    "slider", "number_input", "text_input", "length_input",
    "toggle", "checkbox", "select", "combo_box", "dropdown",
    "color_swatch", "color_gradient", "color_hue_bar", "color_bar",
    "radio_group", "radio", "gradient_tile", "gradient_slider",
    "separator", "spacer", "disclosure", "panel",
    "fill_stroke_widget", "tree_view", "element_preview", "tabs",
    "icon_button_group", "reference_point_widget",
    "placeholder",
];

/// Walk a compiled panel node (`{"type":"panel","content":<root>}`) into a
/// pre-order JSON array of structural records (see the module docs).
///
/// `ctx` is the data scope (`state` / `panel` / `data` / `active_document`
/// namespaces) used only to evaluate `foreach` sources; pass `{}` for a
/// literals-only scope (a foreach over an undefined source expands to nothing).
//
// The cross-app byte-gate (`cross_language_test::algorithm_widget_tree_vectors`)
// is the sole caller (this pass is not yet wired into a render path), so it
// reads as dead without the test cfg.
#[allow(dead_code)]
pub fn widget_tree(panel_node: &Value, ctx: &Value) -> Value {
    let root = match panel_node.get("content") {
        Some(r) if r.is_object() => r,
        _ => return json!([]),
    };
    let mut out: Vec<Value> = vec![];
    walk(root, &[], ctx, &mut out);
    Value::Array(out)
}

/// Sorted key set of an optional object field (e.g. `bind` / `style`), or `[]`
/// when the field is absent or not an object.
#[allow(dead_code)] // Reachable only through `widget_tree` (test-only caller).
fn sorted_keys(v: Option<&Value>) -> Vec<String> {
    match v.and_then(|x| x.as_object()) {
        Some(m) => {
            let mut keys: Vec<String> = m.keys().cloned().collect();
            keys.sort();
            keys
        }
        None => vec![],
    }
}

/// The structural record for one widget node (no recursion).
#[allow(dead_code)] // Reachable only through `widget_tree` (test-only caller).
fn record(node: &Value, path: &[i64]) -> Value {
    let t = node.get("type").and_then(|v| v.as_str()).unwrap_or("");
    let nid = node.get("id").and_then(|v| v.as_str()).unwrap_or("");
    let kind = if CANONICAL_WIDGET_KINDS.contains(&t) {
        t
    } else {
        "placeholder"
    };
    // `col` is the static integer (a float truncates, mirroring Python `int()`);
    // a non-number (or absent) `col` records as 0.
    let col = node
        .get("col")
        .filter(|v| v.is_number())
        .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
        .unwrap_or(0);
    let v = node.get("visible");
    // `visible` is the static literal only (false iff `visible: false`); a
    // string `visible:` expr or a `bind.visible` is dynamic — recorded as
    // `dyn_visible` rather than evaluated, so the snapshot stays eval-free.
    let visible = v.and_then(|x| x.as_bool()) != Some(false);
    let bind = node.get("bind");
    let style = node.get("style");
    let dyn_visible = v.map_or(false, |x| x.is_string())
        || bind.map_or(false, |b| b.is_object() && b.get("visible").is_some());
    json!({
        "path": path,
        "type": t,
        "id": nid,
        "kind": kind,
        "col": col,
        "visible": visible,
        "dyn_visible": dyn_visible,
        "bind": sorted_keys(bind),
        "style": sorted_keys(style),
    })
}

#[allow(dead_code)] // Reachable only through `widget_tree` (test-only caller).
fn walk(node: &Value, path: &[i64], ctx: &Value, out: &mut Vec<Value>) {
    out.push(record(node, path));
    // A foreach container expands its `do` template once per item of
    // eval(foreach.source, ctx) — mirrors panel_layout::foreach exactly so the
    // expansion count (and thus the path set) is identical to the rects.
    let foreach = node.get("foreach").filter(|v| v.is_object());
    let do_template = node.get("do").filter(|v| !v.is_null());
    if let (Some(spec), Some(template)) = (foreach, do_template) {
        let src = spec.get("source").and_then(|v| v.as_str()).unwrap_or("");
        let var = spec.get("as").and_then(|v| v.as_str()).unwrap_or("item");
        let items: Vec<Value> = match eval(src, ctx) {
            EVal::List(v) => v,
            _ => vec![],
        };
        let base_obj: Map<String, Value> = ctx.as_object().cloned().unwrap_or_default();
        for (i, item) in items.into_iter().enumerate() {
            let mut item_data: Map<String, Value> = match item {
                Value::Object(m) => m,
                other => {
                    let mut m = Map::new();
                    m.insert("_value".to_string(), other);
                    m
                }
            };
            item_data.insert("_index".to_string(), json!(i));
            let mut child = base_obj.clone();
            child.insert(var.to_string(), Value::Object(item_data));
            let child_ctx = Value::Object(child);
            let mut cp = path.to_vec();
            cp.push(i as i64);
            if template.is_object() {
                walk(template, &cp, &child_ctx, out);
            }
        }
        return;
    }
    // A plain container recurses its declared children. Unlike the layout pass
    // (which drops `visible: false`), every object child is kept and recorded so
    // a wrongly-hidden widget is catchable; non-object entries occupy their
    // index but emit nothing, matching the layout pass's skip.
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
