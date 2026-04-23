//! Effects interpreter — Rust port of workspace_interpreter/effects.py
//! plus the `doc.*` dispatcher mirroring jas_flask's `effects.mjs`.
//!
//! Executes effect lists from actions, behaviors, and tool handlers.
//! Each effect is a JSON object with a single key identifying the
//! effect type. When a `Model` is threaded through, `doc.*` effects
//! dispatch to `Controller` methods to mutate the document; without
//! a Model they are no-ops (matching Flask's observer fallback).

use serde_json;
use super::expr::eval;
use super::expr_types::Value;
use super::state_store::StateStore;
use crate::document::controller::Controller;
use crate::document::document::ElementPath;
use crate::document::model::Model;
use crate::geometry::element::{
    Color, CommonProps, Element, Fill, LineElem, RectElem, Stroke,
};

/// Execute a list of effects.
///
/// `model` is optional. When supplied, `doc.*` effects dispatch to
/// `Controller`. When `None`, `doc.*` effects are silently skipped —
/// callers that don't touch the document (e.g. panel behavior actions)
/// pass `None`.
pub fn run_effects(
    effects: &[serde_json::Value],
    ctx: &serde_json::Value,
    store: &mut StateStore,
    mut model: Option<&mut Model>,
    actions: Option<&serde_json::Value>,
    dialogs: Option<&serde_json::Value>,
) {
    for effect in effects {
        if let serde_json::Value::Object(map) = effect {
            run_one(map, ctx, store, model.as_deref_mut(), actions, dialogs);
        }
    }
}

fn eval_expr(expr: &str, store: &StateStore, ctx: &serde_json::Value) -> Value {
    let mut eval_ctx = store.eval_context();
    // Merge extra context (param, event, etc.)
    if let (serde_json::Value::Object(base), serde_json::Value::Object(extra)) =
        (&mut eval_ctx, ctx)
    {
        for (k, v) in extra {
            base.insert(k.clone(), v.clone());
        }
    }
    eval(&expr, &eval_ctx)
}

pub fn value_to_json(v: &Value) -> serde_json::Value {
    match v {
        Value::Null => serde_json::Value::Null,
        Value::Bool(b) => serde_json::json!(*b),
        Value::Number(n) => {
            if *n == (*n as i64) as f64 {
                serde_json::json!(*n as i64)
            } else {
                serde_json::json!(*n)
            }
        }
        Value::Str(s) => serde_json::json!(s),
        Value::Color(c) => serde_json::json!(c),
        Value::List(l) => serde_json::Value::Array(l.clone()),
        Value::Path(indices) => serde_json::json!({
            "__path__": indices.iter().map(|&i| i as u64).collect::<Vec<_>>()
        }),
        Value::Closure { .. } => serde_json::Value::Null,
    }
}

fn run_one(
    effect: &serde_json::Map<String, serde_json::Value>,
    ctx: &serde_json::Value,
    store: &mut StateStore,
    mut model: Option<&mut Model>,
    actions: Option<&serde_json::Value>,
    dialogs: Option<&serde_json::Value>,
) {
    // ── Document mutations (doc.*) — dispatched before generic effects
    // so a stray `doc.` key in an effect object doesn't silently fall
    // through to "unknown".
    if let Some((name, spec)) = effect
        .iter()
        .find(|(k, _)| k.starts_with("doc."))
    {
        if let Some(m) = model.as_deref_mut() {
            run_doc_effect(name, spec, ctx, store, m);
        }
        return;
    }

    // set: { key: expr, ... }
    //
    // YAML authors target state scopes via dotted paths with optional
    // `$` prefix: `$tool.selection.mode`, `$state.fill_color`,
    // `$panel.mode`. We strip the `$`, then dispatch on the first
    // segment so writes land in the matching store section. Unscoped
    // keys (no leading `state.`/`panel.`/`tool.`) continue to write
    // to the global state map — preserves existing call-site
    // behavior from before the tool-state scope was introduced.
    if let Some(serde_json::Value::Object(pairs)) = effect.get("set") {
        for (key, expr) in pairs {
            let expr_str = expr.as_str().unwrap_or("");
            let value = eval_expr(expr_str, store, ctx);
            let json = value_to_json(&value);
            set_by_scoped_target(store, key, json);
        }
        return;
    }

    // toggle: state_key
    if let Some(key_val) = effect.get("toggle") {
        let key = key_val.as_str().unwrap_or("");
        // Handle text interpolation for constructed keys like {{param.pane}}_visible
        let resolved_key = if key.contains("{{") {
            super::expr::eval_text(key, &store.eval_context())
        } else {
            key.to_string()
        };
        let current = store.get(&resolved_key).as_bool().unwrap_or(false);
        store.set(&resolved_key, serde_json::json!(!current));
        return;
    }

    // swap: [key_a, key_b]
    if let Some(serde_json::Value::Array(keys)) = effect.get("swap") {
        if keys.len() == 2 {
            let a = keys[0].as_str().unwrap_or("");
            let b = keys[1].as_str().unwrap_or("");
            let a_val = store.get(a).clone();
            let b_val = store.get(b).clone();
            store.set(a, b_val);
            store.set(b, a_val);
        }
        return;
    }

    // increment: { key, by }
    if let Some(serde_json::Value::Object(inc)) = effect.get("increment") {
        let key = inc.get("key").and_then(|v| v.as_str()).unwrap_or("");
        let by = inc.get("by").and_then(|v| v.as_f64()).unwrap_or(1.0);
        let current = store.get(key).as_f64().unwrap_or(0.0);
        store.set(key, serde_json::json!(current + by));
        return;
    }

    // decrement: { key, by }
    if let Some(serde_json::Value::Object(dec)) = effect.get("decrement") {
        let key = dec.get("key").and_then(|v| v.as_str()).unwrap_or("");
        let by = dec.get("by").and_then(|v| v.as_f64()).unwrap_or(1.0);
        let current = store.get(key).as_f64().unwrap_or(0.0);
        store.set(key, serde_json::json!(current - by));
        return;
    }

    // let: { name: expr, ... }  in: [ ...effects ]
    //
    // Extends the expression ctx with new bindings (keyed at top level —
    // handler references them as bare identifiers). Mirrors
    // jas_flask/static/js/engine/effects.mjs's let/in form.
    if let Some(serde_json::Value::Object(bindings_spec)) = effect.get("let") {
        let mut extended_ctx = ctx.clone();
        if let serde_json::Value::Object(extended_map) = &mut extended_ctx {
            for (name, expr_val) in bindings_spec {
                let expr_str = expr_val.as_str().unwrap_or("");
                let value = eval_expr(expr_str, store, ctx);
                extended_map.insert(name.clone(), value_to_json(&value));
            }
        }
        if let Some(serde_json::Value::Array(in_effects)) = effect.get("in") {
            run_effects(
                in_effects,
                &extended_ctx,
                store,
                model.as_deref_mut(),
                actions,
                dialogs,
            );
        }
        return;
    }

    // if: two supported shapes
    //
    //   Flat (Flask / tool handlers):
    //     if: "<expr>"
    //     then: [...]
    //     else: [...]
    //
    //   Nested (actions.yaml legacy):
    //     if:
    //       condition: "<expr>"
    //       then: [...]
    //       else: [...]
    //
    // The flat form is the authoring convention in workspace/tools/*.yaml
    // (matches jas_flask/static/js/engine/effects.mjs). The nested form
    // predates the tool runtime and is still used in workspace actions.
    // Both are accepted here so selection.yaml and action fixtures
    // continue to work.
    if let Some(if_val) = effect.get("if") {
        let (condition_expr, then_effects, else_effects) = match if_val {
            serde_json::Value::String(s) => {
                let then_eff = effect
                    .get("then")
                    .and_then(|v| v.as_array())
                    .cloned()
                    .unwrap_or_default();
                let else_eff = effect
                    .get("else")
                    .and_then(|v| v.as_array())
                    .cloned()
                    .unwrap_or_default();
                (s.clone(), then_eff, else_eff)
            }
            serde_json::Value::Object(cond_obj) => {
                let cond = cond_obj
                    .get("condition")
                    .and_then(|v| v.as_str())
                    .unwrap_or("false")
                    .to_string();
                let then_eff = cond_obj
                    .get("then")
                    .and_then(|v| v.as_array())
                    .cloned()
                    .unwrap_or_default();
                let else_eff = cond_obj
                    .get("else")
                    .and_then(|v| v.as_array())
                    .cloned()
                    .unwrap_or_default();
                (cond, then_eff, else_eff)
            }
            _ => return,
        };
        let result = eval_expr(&condition_expr, store, ctx);
        if result.to_bool() {
            run_effects(
                &then_effects, ctx, store,
                model.as_deref_mut(), actions, dialogs);
        } else {
            run_effects(
                &else_effects, ctx, store,
                model.as_deref_mut(), actions, dialogs);
        }
        return;
    }

    // set_panel_state: { key, value, panel? }
    if let Some(serde_json::Value::Object(sps)) = effect.get("set_panel_state") {
        let key = sps.get("key").and_then(|v| v.as_str()).unwrap_or("");
        let value_expr = sps.get("value").and_then(|v| v.as_str()).unwrap_or("null");
        let value = eval_expr(value_expr, store, ctx);
        if let Some(panel_id) = sps.get("panel").and_then(|v| v.as_str()) {
            store.set_panel(panel_id, key, value_to_json(&value));
        } else if let Some(active) = store.active_panel_id().map(|s| s.to_string()) {
            store.set_panel(&active, key, value_to_json(&value));
        }
        return;
    }

    // list_push: { target, value, unique, max_length }
    if let Some(serde_json::Value::Object(lp)) = effect.get("list_push") {
        let target = lp.get("target").and_then(|v| v.as_str()).unwrap_or("");
        let value_expr = lp.get("value").and_then(|v| v.as_str()).unwrap_or("null");
        let value = eval_expr(value_expr, store, ctx);
        let unique = lp.get("unique").and_then(|v| v.as_bool()).unwrap_or(false);
        let max_length = lp.get("max_length").and_then(|v| v.as_u64()).map(|n| n as usize);

        let parts: Vec<&str> = target.splitn(2, '.').collect();
        if parts.len() == 2 && parts[0] == "panel" {
            if let Some(active) = store.active_panel_id().map(|s| s.to_string()) {
                store.list_push(&active, parts[1], value_to_json(&value), unique, max_length);
            }
        }
        return;
    }

    // dispatch: action_name or { action, params }
    if let Some(dispatch) = effect.get("dispatch") {
        let (action_name, params) = match dispatch {
            serde_json::Value::String(s) => (s.as_str(), serde_json::Value::Null),
            serde_json::Value::Object(d) => {
                let name = d.get("action").and_then(|v| v.as_str()).unwrap_or("");
                let params = d.get("params").cloned().unwrap_or(serde_json::Value::Null);
                (name, params)
            }
            _ => return,
        };
        if let Some(actions_map) = actions {
            if let Some(action_def) = actions_map.get(action_name) {
                if let Some(serde_json::Value::Array(action_effects)) = action_def.get("effects") {
                    let mut dispatch_ctx = ctx.clone();
                    if let serde_json::Value::Object(p) = &params {
                        if let serde_json::Value::Object(c) = &mut dispatch_ctx {
                            let mut resolved = serde_json::Map::new();
                            for (k, v) in p {
                                if let Some(expr) = v.as_str() {
                                    let val = eval_expr(expr, store, &serde_json::Value::Object(c.clone()));
                                    resolved.insert(k.clone(), value_to_json(&val));
                                } else {
                                    resolved.insert(k.clone(), v.clone());
                                }
                            }
                            c.insert("param".to_string(), serde_json::Value::Object(resolved));
                        }
                    }
                    run_effects(action_effects, &dispatch_ctx, store, model.as_deref_mut(), actions, dialogs);
                }
            }
        }
        return;
    }

    // open_dialog: { id, params }
    if let Some(od) = effect.get("open_dialog") {
        let dlg_id = if let Some(obj) = od.as_object() {
            obj.get("id").and_then(|v| v.as_str()).unwrap_or("")
        } else {
            od.as_str().unwrap_or("")
        };
        let dlg_def = dialogs
            .and_then(|d| d.get(dlg_id));
        let dlg_def = match dlg_def {
            Some(d) => d,
            None => return,
        };
        // Extract state defaults
        let mut defaults = std::collections::HashMap::new();
        if let Some(serde_json::Value::Object(state_defs)) = dlg_def.get("state") {
            for (key, defn) in state_defs {
                let default_val = if let serde_json::Value::Object(d) = defn {
                    d.get("default").cloned().unwrap_or(serde_json::Value::Null)
                } else {
                    defn.clone()
                };
                defaults.insert(key.clone(), default_val);
            }
        }
        // Resolve params
        let resolved_params = if let Some(serde_json::Value::Object(raw_params)) =
            od.as_object().and_then(|o| o.get("params"))
        {
            let mut rp = std::collections::HashMap::new();
            for (k, v) in raw_params {
                let expr_str = v.as_str().unwrap_or("");
                let val = eval_expr(expr_str, store, ctx);
                rp.insert(k.clone(), value_to_json(&val));
            }
            Some(rp)
        } else {
            None
        };
        // Init dialog
        store.init_dialog(dlg_id, defaults, resolved_params);
        // Evaluate init expressions
        if let Some(serde_json::Value::Object(init_map)) = dlg_def.get("init") {
            for (key, expr) in init_map {
                let expr_str = expr.as_str().unwrap_or("");
                let val = eval_expr(expr_str, store, ctx);
                store.set_dialog(key, value_to_json(&val));
            }
        }
        // Capture preview snapshot if the dialog declares preview_targets.
        // Restored on close_dialog unless first cleared by an OK action via
        // clear_dialog_snapshot.
        if let Some(serde_json::Value::Object(targets_obj)) = dlg_def.get("preview_targets") {
            let mut targets = std::collections::HashMap::new();
            for (k, v) in targets_obj {
                if let Some(s) = v.as_str() {
                    targets.insert(k.clone(), s.to_string());
                }
            }
            store.capture_dialog_snapshot(&targets);
        }
        return;
    }

    // close_dialog: null or dialog_id
    if effect.contains_key("close_dialog") {
        // Preview restore: if a snapshot survived (i.e., no OK action
        // cleared it), revert each target to its captured original value.
        // Phase 0 handles only top-level state keys; deep paths defer to
        // Phase 8/9 alongside their first real consumer.
        if let Some(snapshot) = store.dialog_snapshot().cloned() {
            for (key, value) in snapshot {
                if !key.contains('.') {
                    store.set(&key, value);
                }
            }
            store.clear_dialog_snapshot();
        }
        store.close_dialog();
        return;
    }

    // clear_dialog_snapshot: drop the preview snapshot so close_dialog
    // does not restore. OK actions emit this before close_dialog to commit.
    if effect.contains_key("clear_dialog_snapshot") {
        store.clear_dialog_snapshot();
        return;
    }

    // log: message (debug only)
    if effect.contains_key("log") {
        return;
    }
}

/// Route a `set:` target to the right scope in the StateStore.
///
/// Target shapes (leading `$` stripped):
///   `tool.<id>.<key>[.<more>]` → `store.set_tool(id, combined_key, value)`
///   `panel.<key>`              → active panel's scope
///   `state.<key>`              → global state (explicit scope)
///   `<key>`                    → global state (implicit scope, legacy)
///
/// Deeper dotted paths under tool/panel are joined back with `.` and
/// stored as a flat key in the tool/panel scope, matching the existing
/// flat-map behavior there. Full nested-object writes can land in a
/// later phase if YAML authors need them.
fn set_by_scoped_target(
    store: &mut StateStore,
    raw_target: &str,
    value: serde_json::Value,
) {
    let target = raw_target.strip_prefix('$').unwrap_or(raw_target);
    let segs: Vec<&str> = target.splitn(2, '.').collect();
    match segs.as_slice() {
        ["tool", rest] => {
            let inner: Vec<&str> = rest.splitn(2, '.').collect();
            match inner.as_slice() {
                [tool_id, key] => store.set_tool(tool_id, key, value),
                // Too shallow: `tool.<id>` with no key. Silently skip —
                // same lenience other effects use for malformed input.
                _ => {}
            }
        }
        ["panel", key] => {
            if let Some(active) = store.active_panel_id().map(|s| s.to_string()) {
                store.set_panel(&active, key, value);
            }
        }
        ["state", key] => store.set(key, value),
        [key] => store.set(key, value),
        _ => {}
    }
}

/// Dispatch a `doc.*` effect to the Model via `Controller`. Runs only
/// when a Model is threaded through `run_effects`. Mirrors the `doc.*`
/// arm of jas_flask/static/js/engine/effects.mjs.
fn run_doc_effect(
    name: &str,
    spec: &serde_json::Value,
    ctx: &serde_json::Value,
    store: &mut StateStore,
    model: &mut Model,
) {
    match name {
        "doc.snapshot" => {
            model.snapshot();
        }
        "doc.clear_selection" => {
            Controller::clear_selection(model);
        }
        "doc.set_selection" => {
            let paths = extract_path_list(spec, store, ctx);
            let doc = model.document();
            // Drop paths that don't resolve to an element. Matches
            // Flask's setSelection behavior for invalid paths.
            let valid: Vec<ElementPath> = paths
                .into_iter()
                .filter(|p| doc.get_element(p).is_some())
                .collect();
            let selection = valid
                .into_iter()
                .map(|p| crate::document::document::ElementSelection::all(p))
                .collect();
            Controller::set_selection(model, selection);
        }
        "doc.add_to_selection" => {
            if let Some(path) = extract_path(spec, store, ctx) {
                Controller::add_to_selection(model, &path);
            }
        }
        "doc.toggle_selection" => {
            if let Some(path) = extract_path(spec, store, ctx) {
                Controller::toggle_selection(model, &path);
            }
        }
        "doc.translate_selection" => {
            if let serde_json::Value::Object(args) = spec {
                let dx = eval_number(args.get("dx"), store, ctx);
                let dy = eval_number(args.get("dy"), store, ctx);
                if dx != 0.0 || dy != 0.0 {
                    Controller::move_selection(model, dx, dy);
                }
            }
        }
        "doc.copy_selection" => {
            if let serde_json::Value::Object(args) = spec {
                let dx = eval_number(args.get("dx"), store, ctx);
                let dy = eval_number(args.get("dy"), store, ctx);
                Controller::copy_selection(model, dx, dy);
            }
        }
        "doc.add_element" => {
            // Shape: { element: { type: rect, x: ..., y: ..., width: ...,
            //                     height: ..., fill?: ..., stroke?: ... } }
            //
            // `parent` is accepted for compatibility with Flask's tool
            // handlers but not enforced — Controller::add_element adds
            // to the selected layer (or mask subtree) per the app's
            // normal semantics. An explicit parent would require a
            // path-based add path through Controller that doesn't
            // exist yet.
            if let serde_json::Value::Object(args) = spec {
                if let Some(serde_json::Value::Object(elem_spec)) = args.get("element") {
                    // Capture defaults by value before &mut borrow — Fill/Stroke
                    // derive Copy so this is cheap.
                    let default_fill = model.default_fill;
                    let default_stroke = model.default_stroke;
                    if let Some(element) = build_element(
                        elem_spec, store, ctx, default_fill, default_stroke,
                    ) {
                        Controller::add_element(model, element);
                    }
                }
            }
        }
        "doc.select_in_rect" => {
            if let serde_json::Value::Object(args) = spec {
                let x1 = eval_number(args.get("x1"), store, ctx);
                let y1 = eval_number(args.get("y1"), store, ctx);
                let x2 = eval_number(args.get("x2"), store, ctx);
                let y2 = eval_number(args.get("y2"), store, ctx);
                let additive = eval_bool(args.get("additive"), store, ctx);
                let rx = x1.min(x2);
                let ry = y1.min(y2);
                let rw = (x2 - x1).abs();
                let rh = (y2 - y1).abs();
                Controller::select_rect(model, rx, ry, rw, rh, additive);
            }
        }
        _ => {
            // Effects not implemented in this phase fall through silently.
            // doc.delete_selection, doc.add_element, doc.set_attr land in
            // later phases alongside the tools that need them.
        }
    }
}

/// Evaluate a `dx`/`dy`/`x1`/… argument that may be a number literal,
/// a numeric string expression, or a JSON number. Missing → 0.0.
fn eval_number(
    arg: Option<&serde_json::Value>,
    store: &StateStore,
    ctx: &serde_json::Value,
) -> f64 {
    match arg {
        None | Some(serde_json::Value::Null) => 0.0,
        Some(serde_json::Value::Number(n)) => n.as_f64().unwrap_or(0.0),
        Some(serde_json::Value::String(s)) => {
            match eval_expr(s, store, ctx) {
                Value::Number(n) => n,
                _ => 0.0,
            }
        }
        _ => 0.0,
    }
}

fn eval_bool(
    arg: Option<&serde_json::Value>,
    store: &StateStore,
    ctx: &serde_json::Value,
) -> bool {
    match arg {
        None | Some(serde_json::Value::Null) => false,
        Some(serde_json::Value::Bool(b)) => *b,
        Some(serde_json::Value::String(s)) => eval_expr(s, store, ctx).to_bool(),
        _ => false,
    }
}

/// Pull a single path out of a `doc.*` effect spec. Accepts:
///   - a raw JSON array of integers → path
///   - a string that evaluates to `Value::Path` → extract indices
///   - a string that evaluates to `Value::List` of integers → coerce
///   - `{ path: <expr> }` → recurse
fn extract_path(
    spec: &serde_json::Value,
    store: &StateStore,
    ctx: &serde_json::Value,
) -> Option<Vec<usize>> {
    match spec {
        serde_json::Value::Array(items) => {
            let mut out = Vec::with_capacity(items.len());
            for item in items {
                out.push(item.as_u64()? as usize);
            }
            Some(out)
        }
        serde_json::Value::String(s) => {
            match eval_expr(s, store, ctx) {
                Value::Path(indices) => Some(indices),
                Value::List(items) => {
                    let mut out = Vec::with_capacity(items.len());
                    for item in items {
                        out.push(item.as_u64()? as usize);
                    }
                    Some(out)
                }
                _ => None,
            }
        }
        serde_json::Value::Object(map) => {
            map.get("path").and_then(|v| extract_path(v, store, ctx))
        }
        _ => None,
    }
}

/// Build an Element from a YAML element spec dict. Dispatches on
/// `type:` and interprets the remaining fields as expressions.
///
/// `default_fill` / `default_stroke` are the Model's defaults —
/// fall-through values when the spec omits `fill:` or `stroke:`
/// entirely. This matches native tool behavior where a newly-drawn
/// Rect uses `model.default_fill` / `model.default_stroke` from the
/// color panel.
///
/// Spec fields that are present but null-valued still override the
/// defaults to None — authors can explicitly strip fill/stroke via
/// `fill: "null"`.
fn build_element(
    spec: &serde_json::Map<String, serde_json::Value>,
    store: &StateStore,
    ctx: &serde_json::Value,
    default_fill: Option<Fill>,
    default_stroke: Option<Stroke>,
) -> Option<Element> {
    let elem_type = spec.get("type").and_then(|v| v.as_str())?;
    match elem_type {
        "rect" => {
            let x = eval_number(spec.get("x"), store, ctx);
            let y = eval_number(spec.get("y"), store, ctx);
            let width = eval_number(spec.get("width"), store, ctx);
            let height = eval_number(spec.get("height"), store, ctx);
            let rx = eval_number(spec.get("rx"), store, ctx);
            let ry = eval_number(spec.get("ry"), store, ctx);
            let fill = resolve_fill_field(spec.get("fill"), store, ctx, default_fill);
            let stroke =
                resolve_stroke_field(spec.get("stroke"), store, ctx, default_stroke);
            Some(Element::Rect(RectElem {
                x,
                y,
                width,
                height,
                rx,
                ry,
                fill,
                stroke,
                common: CommonProps::default(),
                fill_gradient: None,
                stroke_gradient: None,
            }))
        }
        "line" => {
            let x1 = eval_number(spec.get("x1"), store, ctx);
            let y1 = eval_number(spec.get("y1"), store, ctx);
            let x2 = eval_number(spec.get("x2"), store, ctx);
            let y2 = eval_number(spec.get("y2"), store, ctx);
            let stroke =
                resolve_stroke_field(spec.get("stroke"), store, ctx, default_stroke);
            Some(Element::Line(LineElem {
                x1,
                y1,
                x2,
                y2,
                stroke,
                width_points: Vec::new(),
                common: CommonProps::default(),
                stroke_gradient: None,
            }))
        }

        // Other element types (ellipse, polygon, path, …) land
        // alongside their tool ports.
        _ => None,
    }
}

/// Resolve an optional `fill:` field to `Option<Fill>`.
/// - Field absent → `default`
/// - Field evaluates to `Value::Null` → `None`
/// - Field evaluates to `Value::Color` / `Value::Str(hex)` →
///   `Some(Fill::new(color))`; opacity stays at Fill::new's 1.0
fn resolve_fill_field(
    field: Option<&serde_json::Value>,
    store: &StateStore,
    ctx: &serde_json::Value,
    default: Option<Fill>,
) -> Option<Fill> {
    let Some(field) = field else {
        return default;
    };
    let v = evaluate_field_value(field, store, ctx);
    match v {
        Value::Null => None,
        Value::Color(c) => Color::from_hex(&c).map(Fill::new),
        Value::Str(s) => Color::from_hex(&s).map(Fill::new),
        _ => default,
    }
}

/// Resolve an optional `stroke:` field. Current shape accepts a color
/// (string / Value::Color) and uses `Stroke::new(color, 1.0)` —
/// width/caps/joins stay at Stroke::new's defaults. Tools needing
/// richer stroke spec (arrowheads, dashes, per-field overrides) will
/// extend this when they port.
fn resolve_stroke_field(
    field: Option<&serde_json::Value>,
    store: &StateStore,
    ctx: &serde_json::Value,
    default: Option<Stroke>,
) -> Option<Stroke> {
    let Some(field) = field else {
        return default;
    };
    let v = evaluate_field_value(field, store, ctx);
    match v {
        Value::Null => None,
        Value::Color(c) => Color::from_hex(&c).map(|col| Stroke::new(col, 1.0)),
        Value::Str(s) => Color::from_hex(&s).map(|col| Stroke::new(col, 1.0)),
        _ => default,
    }
}

/// Evaluate a field that may be a scalar literal or a string expression.
/// Shared by resolve_fill_field / resolve_stroke_field.
fn evaluate_field_value(
    field: &serde_json::Value,
    store: &StateStore,
    ctx: &serde_json::Value,
) -> Value {
    match field {
        serde_json::Value::Null => Value::Null,
        serde_json::Value::String(s) => eval_expr(s, store, ctx),
        _ => Value::from_json(field),
    }
}

/// Pull a list of paths out of a `doc.*` effect spec. Accepts
/// `{ paths: [<path-spec>, …] }` where each item is individually
/// extract_path-able. Items that don't resolve to a path are dropped.
fn extract_path_list(
    spec: &serde_json::Value,
    store: &StateStore,
    ctx: &serde_json::Value,
) -> Vec<Vec<usize>> {
    let mut out = Vec::new();
    if let Some(paths) = spec
        .as_object()
        .and_then(|o| o.get("paths"))
        .and_then(|v| v.as_array())
    {
        for item in paths {
            if let Some(p) = extract_path(item, store, ctx) {
                out.push(p);
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_set_effect() {
        let mut store = StateStore::new();
        store.set("x", serde_json::json!(0));
        let effects = vec![serde_json::json!({"set": {"x": "5"}})];
        run_effects(&effects, &serde_json::json!({}), &mut store, None, None, None);
        assert_eq!(store.get("x"), &serde_json::json!(5));
    }

    #[test]
    fn test_toggle_effect() {
        let mut store = StateStore::new();
        store.set("flag", serde_json::json!(true));
        let effects = vec![serde_json::json!({"toggle": "flag"})];
        run_effects(&effects, &serde_json::json!({}), &mut store, None, None, None);
        assert_eq!(store.get("flag"), &serde_json::json!(false));
    }

    #[test]
    fn test_swap_effect() {
        let mut store = StateStore::new();
        store.set("a", serde_json::json!("#ff0000"));
        store.set("b", serde_json::json!("#00ff00"));
        let effects = vec![serde_json::json!({"swap": ["a", "b"]})];
        run_effects(&effects, &serde_json::json!({}), &mut store, None, None, None);
        assert_eq!(store.get("a"), &serde_json::json!("#00ff00"));
        assert_eq!(store.get("b"), &serde_json::json!("#ff0000"));
    }

    #[test]
    fn test_if_true_branch() {
        let mut store = StateStore::new();
        store.set("flag", serde_json::json!(true));
        store.set("result", serde_json::json!(""));
        let effects = vec![serde_json::json!({
            "if": {
                "condition": "state.flag",
                "then": [{"set": {"result": "\"yes\""}}],
                "else": [{"set": {"result": "\"no\""}}]
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store, None, None, None);
        assert_eq!(store.get("result"), &serde_json::json!("yes"));
    }

    #[test]
    fn test_increment() {
        let mut store = StateStore::new();
        store.set("count", serde_json::json!(5));
        let effects = vec![serde_json::json!({"increment": {"key": "count", "by": 3}})];
        run_effects(&effects, &serde_json::json!({}), &mut store, None, None, None);
        assert_eq!(store.get("count"), &serde_json::json!(8.0));
    }

    #[test]
    fn test_dispatch() {
        let mut store = StateStore::new();
        store.set("x", serde_json::json!(0));
        let actions = serde_json::json!({
            "set_x": {"effects": [{"set": {"x": "42"}}]}
        });
        let effects = vec![serde_json::json!({"dispatch": "set_x"})];
        run_effects(&effects, &serde_json::json!({}), &mut store, None, Some(&actions), None);
        assert_eq!(store.get("x"), &serde_json::json!(42));
    }

    #[test]
    fn test_open_dialog_sets_defaults() {
        let mut store = StateStore::new();
        let dialogs = serde_json::json!({
            "simple": {
                "summary": "Simple",
                "state": {
                    "name": {"type": "string", "default": ""},
                },
                "content": {"type": "container"},
            }
        });
        let effects = vec![serde_json::json!({"open_dialog": {"id": "simple"}})];
        run_effects(&effects, &serde_json::json!({}), &mut store, None, None, Some(&dialogs));
        assert_eq!(store.dialog_id(), Some("simple"));
        assert_eq!(store.get_dialog("name"), &serde_json::json!(""));
    }

    #[test]
    fn test_open_dialog_with_params_and_init() {
        let mut store = StateStore::new();
        store.set("fill_color", serde_json::json!("#00ff00"));
        store.set("stroke_color", serde_json::json!("#0000ff"));
        let dialogs = serde_json::json!({
            "picker": {
                "summary": "Pick",
                "params": {"target": {"type": "enum", "values": ["fill", "stroke"]}},
                "state": {
                    "h": {"type": "number", "default": 0},
                    "color": {"type": "color", "default": "#ffffff"},
                },
                "init": {
                    "color": "if param.target == \"fill\" then state.fill_color else state.stroke_color",
                    "h": "hsb_h(dialog.color)",
                },
                "content": {"type": "container"},
            }
        });
        let effects = vec![serde_json::json!({
            "open_dialog": {"id": "picker", "params": {"target": "\"fill\""}}
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store, None, None, Some(&dialogs));
        assert_eq!(store.dialog_id(), Some("picker"));
        assert_eq!(store.get_dialog("color"), &serde_json::json!("#00ff00"));
        // hsb_h("#00ff00") = 120
        assert_eq!(store.get_dialog("h"), &serde_json::json!(120));
    }

    #[test]
    fn test_close_dialog() {
        let mut store = StateStore::new();
        let mut defaults = std::collections::HashMap::new();
        defaults.insert("x".to_string(), serde_json::json!(1));
        store.init_dialog("test", defaults, None);
        let effects = vec![serde_json::json!({"close_dialog": null})];
        run_effects(&effects, &serde_json::json!({}), &mut store, None, None, None);
        assert_eq!(store.dialog_id(), None);
    }

    // ── Preview snapshot/restore (Phase 0) ─────────────────────────

    #[test]
    fn test_open_dialog_captures_preview_snapshot() {
        let mut store = StateStore::new();
        store.set("left_indent", serde_json::json!(12));
        store.set("right_indent", serde_json::json!(0));
        let dialogs = serde_json::json!({
            "para_indent": {
                "summary": "Indents",
                "state": {
                    "left": {"type": "number", "default": 0},
                    "right": {"type": "number", "default": 0},
                },
                "preview_targets": {
                    "left": "left_indent",
                    "right": "right_indent",
                },
                "content": {"type": "container"},
            }
        });
        let effects = vec![serde_json::json!({"open_dialog": {"id": "para_indent"}})];
        run_effects(&effects, &serde_json::json!({}), &mut store, None, None, Some(&dialogs));
        let snap = store.dialog_snapshot().expect("snapshot should be captured on open");
        assert_eq!(snap.get("left_indent"), Some(&serde_json::json!(12)));
        assert_eq!(snap.get("right_indent"), Some(&serde_json::json!(0)));
    }

    #[test]
    fn test_open_dialog_without_preview_targets_no_snapshot() {
        let mut store = StateStore::new();
        let dialogs = serde_json::json!({
            "plain": {
                "summary": "Plain",
                "state": {"name": {"type": "string", "default": ""}},
                "content": {"type": "container"},
            }
        });
        let effects = vec![serde_json::json!({"open_dialog": {"id": "plain"}})];
        run_effects(&effects, &serde_json::json!({}), &mut store, None, None, Some(&dialogs));
        assert!(!store.has_dialog_snapshot());
    }

    #[test]
    fn test_close_dialog_restores_from_snapshot() {
        let mut store = StateStore::new();
        store.set("left_indent", serde_json::json!(12));
        let dialogs = serde_json::json!({
            "para_indent": {
                "summary": "Indents",
                "state": {"left": {"type": "number", "default": 0}},
                "preview_targets": {"left": "left_indent"},
                "content": {"type": "container"},
            }
        });
        // Open captures snapshot of left_indent = 12
        let open = vec![serde_json::json!({"open_dialog": {"id": "para_indent"}})];
        run_effects(&open, &serde_json::json!({}), &mut store, None, None, Some(&dialogs));
        // Simulate Preview live-applying an edit: state moves to 99
        store.set("left_indent", serde_json::json!(99));
        // Cancel (close_dialog with snapshot present) restores to 12
        let close = vec![serde_json::json!({"close_dialog": null})];
        run_effects(&close, &serde_json::json!({}), &mut store, None, None, None);
        assert_eq!(store.get("left_indent"), &serde_json::json!(12));
        assert_eq!(store.dialog_id(), None);
        assert!(!store.has_dialog_snapshot());
    }

    #[test]
    fn test_clear_dialog_snapshot_prevents_restore() {
        let mut store = StateStore::new();
        store.set("left_indent", serde_json::json!(12));
        let dialogs = serde_json::json!({
            "para_indent": {
                "summary": "Indents",
                "state": {"left": {"type": "number", "default": 0}},
                "preview_targets": {"left": "left_indent"},
                "content": {"type": "container"},
            }
        });
        let open = vec![serde_json::json!({"open_dialog": {"id": "para_indent"}})];
        run_effects(&open, &serde_json::json!({}), &mut store, None, None, Some(&dialogs));
        store.set("left_indent", serde_json::json!(99));
        // OK action equivalent: clear snapshot, then close
        let ok_then_close = vec![
            serde_json::json!({"clear_dialog_snapshot": null}),
            serde_json::json!({"close_dialog": null}),
        ];
        run_effects(&ok_then_close, &serde_json::json!({}), &mut store, None, None, None);
        // Without snapshot to restore from, the user's edit (99) survives
        assert_eq!(store.get("left_indent"), &serde_json::json!(99));
        assert_eq!(store.dialog_id(), None);
    }

    #[test]
    fn test_set_from_dialog_state() {
        let mut store = StateStore::new();
        store.set("fill_color", serde_json::json!(serde_json::Value::Null));
        let dialogs = serde_json::json!({
            "picker": {
                "summary": "Pick",
                "state": {"color": {"type": "color", "default": "#aabbcc"}},
                "content": {"type": "container"},
            }
        });
        // Open dialog
        let effects = vec![serde_json::json!({"open_dialog": {"id": "picker"}})];
        run_effects(&effects, &serde_json::json!({}), &mut store, None, None, Some(&dialogs));
        assert_eq!(store.get_dialog("color"), &serde_json::json!("#aabbcc"));
        // Set global state from dialog
        let effects = vec![serde_json::json!({"set": {"fill_color": "dialog.color"}})];
        run_effects(&effects, &serde_json::json!({}), &mut store, None, None, None);
        assert_eq!(store.get("fill_color"), &serde_json::json!("#aabbcc"));
    }

    // ── doc.* effect dispatch (Phase 1 of the Rust YAML tool runtime) ─
    //
    // Parallels jas_flask/tests/js/test_doc_effects.mjs. Each effect
    // is exercised in isolation via run_effects with a live Model.
    // Without a Model supplied, doc.* effects are silent no-ops —
    // matching Flask's observer-fallback behavior.

    use crate::document::controller::Controller;
    use crate::document::document::{Document, ElementSelection};
    use crate::document::model::Model;
    use crate::geometry::element::{
        Color, CommonProps, Element, Fill, LayerElem, RectElem,
    };

    fn make_model_two_rects() -> Model {
        let rect0 = Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0,
            rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        });
        let rect1 = Element::Rect(RectElem {
            x: 50.0, y: 50.0, width: 10.0, height: 10.0,
            rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        });
        let layer = Element::Layer(LayerElem {
            name: "L".to_string(),
            children: vec![
                std::rc::Rc::new(rect0),
                std::rc::Rc::new(rect1),
            ],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let doc = Document {
            layers: vec![layer],
            selected_layer: 0,
            selection: Vec::new(),
            ..Document::default()
        };
        Model::new(doc, None)
    }

    #[test]
    fn doc_snapshot_pushes_undo() {
        let mut store = StateStore::new();
        let mut model = Model::default();
        assert!(!model.can_undo());
        let effects = vec![serde_json::json!({"doc.snapshot": {}})];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        assert!(model.can_undo());
    }

    #[test]
    fn doc_snapshot_without_model_is_noop() {
        // No Model supplied — doc.snapshot must be silently skipped,
        // not dispatched to some phantom model and not crash.
        let mut store = StateStore::new();
        let effects = vec![serde_json::json!({"doc.snapshot": {}})];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            None, None, None);
        // If we reached here without panic, the no-op path worked.
    }

    #[test]
    fn doc_clear_selection_empties_selection() {
        let mut store = StateStore::new();
        let mut model = make_model_two_rects();
        Controller::select_element(&mut model, &vec![0, 0]);
        assert_eq!(model.document().selection.len(), 1);
        let effects = vec![serde_json::json!({"doc.clear_selection": {}})];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        assert_eq!(model.document().selection.len(), 0);
    }

    #[test]
    fn doc_set_selection_from_paths_list() {
        let mut store = StateStore::new();
        let mut model = make_model_two_rects();
        let effects = vec![serde_json::json!({
            "doc.set_selection": { "paths": [[0, 0], [0, 1]] }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let sel = &model.document().selection;
        assert_eq!(sel.len(), 2);
        assert_eq!(sel[0].path, vec![0, 0]);
        assert_eq!(sel[1].path, vec![0, 1]);
    }

    #[test]
    fn doc_set_selection_drops_invalid_paths() {
        let mut store = StateStore::new();
        let mut model = make_model_two_rects();
        let effects = vec![serde_json::json!({
            "doc.set_selection": { "paths": [[0, 0], [99, 99]] }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let sel = &model.document().selection;
        assert_eq!(sel.len(), 1);
        assert_eq!(sel[0].path, vec![0, 0]);
    }

    #[test]
    fn doc_add_to_selection_raw_array() {
        let mut store = StateStore::new();
        let mut model = make_model_two_rects();
        let effects = vec![serde_json::json!({"doc.add_to_selection": [0, 0]})];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        assert_eq!(model.document().selection.len(), 1);
        assert_eq!(model.document().selection[0].path, vec![0, 0]);
    }

    #[test]
    fn doc_add_to_selection_is_idempotent() {
        let mut store = StateStore::new();
        let mut model = make_model_two_rects();
        Controller::select_element(&mut model, &vec![0, 0]);
        let effects = vec![serde_json::json!({"doc.add_to_selection": [0, 0]})];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        assert_eq!(model.document().selection.len(), 1);
    }

    #[test]
    fn doc_toggle_selection_adds_when_absent() {
        let mut store = StateStore::new();
        let mut model = make_model_two_rects();
        let effects = vec![serde_json::json!({"doc.toggle_selection": [0, 0]})];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        assert_eq!(model.document().selection.len(), 1);
    }

    #[test]
    fn doc_toggle_selection_removes_when_present() {
        let mut store = StateStore::new();
        let mut model = make_model_two_rects();
        Controller::set_selection(
            &mut model,
            vec![ElementSelection::all(vec![0, 0])],
        );
        let effects = vec![serde_json::json!({"doc.toggle_selection": [0, 0]})];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        assert_eq!(model.document().selection.len(), 0);
    }

    #[test]
    fn doc_translate_selection_moves_rect() {
        let mut store = StateStore::new();
        let mut model = make_model_two_rects();
        Controller::select_element(&mut model, &vec![0, 0]);
        // Literal numeric args:
        let effects = vec![serde_json::json!({
            "doc.translate_selection": { "dx": 5, "dy": 7 }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let elem = &model.document().layers[0].children().unwrap()[0];
        if let Element::Rect(r) = &**elem {
            assert_eq!(r.x, 5.0);
            assert_eq!(r.y, 7.0);
        } else {
            panic!("expected Rect");
        }
    }

    #[test]
    fn doc_translate_selection_zero_delta_is_noop() {
        // Zero deltas skip the clone+replace machinery entirely.
        // We can't observe that directly but can confirm no panic
        // and no movement.
        let mut store = StateStore::new();
        let mut model = make_model_two_rects();
        Controller::select_element(&mut model, &vec![0, 0]);
        let effects = vec![serde_json::json!({
            "doc.translate_selection": { "dx": 0, "dy": 0 }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let elem = &model.document().layers[0].children().unwrap()[0];
        if let Element::Rect(r) = &**elem {
            assert_eq!(r.x, 0.0);
            assert_eq!(r.y, 0.0);
        }
    }

    #[test]
    fn doc_translate_selection_expression_args() {
        // dx / dy as string expressions that read from scope.
        let mut store = StateStore::new();
        store.set("offset_x", serde_json::json!(3));
        store.set("offset_y", serde_json::json!(4));
        let mut model = make_model_two_rects();
        Controller::select_element(&mut model, &vec![0, 0]);
        let effects = vec![serde_json::json!({
            "doc.translate_selection": {
                "dx": "state.offset_x",
                "dy": "state.offset_y"
            }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let elem = &model.document().layers[0].children().unwrap()[0];
        if let Element::Rect(r) = &**elem {
            assert_eq!(r.x, 3.0);
            assert_eq!(r.y, 4.0);
        }
    }

    #[test]
    fn doc_select_in_rect_covers_both() {
        // Rect covering both rects (0,0,10,10 and 50,50,10,10) at (0..60, 0..60)
        let mut store = StateStore::new();
        let mut model = make_model_two_rects();
        let effects = vec![serde_json::json!({
            "doc.select_in_rect": {
                "x1": 0, "y1": 0, "x2": 60, "y2": 60, "additive": false
            }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        assert_eq!(model.document().selection.len(), 2);
    }

    #[test]
    fn doc_select_in_rect_additive_extends_selection() {
        let mut store = StateStore::new();
        let mut model = make_model_two_rects();
        // Pre-select rect0
        Controller::select_element(&mut model, &vec![0, 0]);
        // Additive select rect covering only rect1
        let effects = vec![serde_json::json!({
            "doc.select_in_rect": {
                "x1": 45, "y1": 45, "x2": 65, "y2": 65, "additive": true
            }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        assert_eq!(model.document().selection.len(), 2);
    }

    #[test]
    fn doc_copy_selection_duplicates_element() {
        let mut store = StateStore::new();
        let mut model = make_model_two_rects();
        Controller::select_element(&mut model, &vec![0, 0]);
        let children_before = model.document().layers[0].children().unwrap().len();
        let effects = vec![serde_json::json!({
            "doc.copy_selection": { "dx": 100, "dy": 0 }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let children_after = model.document().layers[0].children().unwrap().len();
        assert_eq!(children_after, children_before + 1);
    }

    #[test]
    fn doc_path_extract_from_let_binding() {
        // Exercise the let-bound Path expression path: a handler builds
        // a Path value via hit_test-style primitives and binds it under
        // `hit`; doc.set_selection: { paths: [hit] } references it.
        //
        // Here we seed the scope directly with a Path value in ctx so
        // the string expression "hit" resolves without needing hit_test
        // primitives (those land in Phase 2).
        let mut store = StateStore::new();
        let mut model = make_model_two_rects();
        let ctx = serde_json::json!({
            "hit": { "__path__": [0, 0] }
        });
        let effects = vec![serde_json::json!({
            "doc.set_selection": { "paths": ["hit"] }
        })];
        run_effects(&effects, &ctx, &mut store, Some(&mut model), None, None);
        assert_eq!(model.document().selection.len(), 1);
        assert_eq!(model.document().selection[0].path, vec![0, 0]);
    }

    #[test]
    fn doc_effect_inside_if_then_branch() {
        // Recursive run_effects must thread Model through to doc.* effects
        // nested inside if/then/else branches.
        let mut store = StateStore::new();
        store.set("should_clear", serde_json::json!(true));
        let mut model = make_model_two_rects();
        Controller::select_element(&mut model, &vec![0, 0]);
        let effects = vec![serde_json::json!({
            "if": {
                "condition": "state.should_clear",
                "then": [{"doc.clear_selection": {}}],
                "else": []
            }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        assert_eq!(model.document().selection.len(), 0);
    }

    // ── Scope-routed `set:` targets ────────────────────────────────

    #[test]
    fn set_routes_tool_scoped_target() {
        // set: { "tool.selection.mode": "marquee" }
        //   → store.set_tool("selection", "mode", "marquee")
        let mut store = StateStore::new();
        let effects = vec![serde_json::json!({
            "set": { "tool.selection.mode": "\"marquee\"" }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            None, None, None);
        assert_eq!(
            store.get_tool("selection", "mode"),
            &serde_json::json!("marquee"),
        );
    }

    #[test]
    fn set_strips_leading_dollar_from_target() {
        let mut store = StateStore::new();
        let effects = vec![serde_json::json!({
            "set": { "$tool.selection.mode": "\"idle\"" }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            None, None, None);
        assert_eq!(
            store.get_tool("selection", "mode"),
            &serde_json::json!("idle"),
        );
    }

    #[test]
    fn set_routes_state_scoped_target() {
        let mut store = StateStore::new();
        let effects = vec![serde_json::json!({
            "set": { "state.fill_color": "\"#ff0000\"" }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            None, None, None);
        assert_eq!(store.get("fill_color"), &serde_json::json!("#ff0000"));
    }

    #[test]
    fn set_bare_key_stays_global_state() {
        // Backward compat: existing callers pass bare keys like "x"
        // and expect them in global state, not in a tool scope.
        let mut store = StateStore::new();
        let effects = vec![serde_json::json!({
            "set": { "x": "42" }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            None, None, None);
        assert_eq!(store.get("x"), &serde_json::json!(42));
        // And the tool scope stays empty.
        assert!(store.tool_scopes().is_empty());
    }

    #[test]
    fn set_panel_scoped_target_writes_to_active_panel() {
        let mut store = StateStore::new();
        let mut defaults = std::collections::HashMap::new();
        defaults.insert("mode".to_string(), serde_json::json!("hsb"));
        store.init_panel("color", defaults);
        store.set_active_panel(Some("color"));
        let effects = vec![serde_json::json!({
            "set": { "panel.mode": "\"rgb\"" }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            None, None, None);
        assert_eq!(store.get_panel("color", "mode"), &serde_json::json!("rgb"));
    }

    #[test]
    fn eval_context_reads_tool_scope() {
        // After a `set: { "tool.sel.mode": ... }`, the evaluator should
        // resolve `tool.sel.mode` through the scope built by
        // eval_context().
        let mut store = StateStore::new();
        let effects = vec![serde_json::json!({
            "set": { "tool.sel.mode": "\"drag\"" }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            None, None, None);
        let ctx = store.eval_context();
        assert_eq!(ctx["tool"]["sel"]["mode"], serde_json::json!("drag"));
    }

    #[test]
    fn tool_write_then_expression_read() {
        // End-to-end: handler writes $tool.sel.mode, a later expression
        // reads it. Uses the evaluator directly (not through a YAML
        // dispatch, that lands in Phase 3c).
        let mut store = StateStore::new();
        let effects = vec![serde_json::json!({
            "set": { "tool.sel.mode": "\"marquee\"" }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            None, None, None);
        let v = super::super::expr::eval(
            "tool.sel.mode == \"marquee\"",
            &store.eval_context(),
        );
        assert_eq!(v, Value::Bool(true));
    }

    // ── let / in ──────────────────────────────────────────────────

    #[test]
    fn let_binds_scope_for_in_block() {
        // Bind a value once; downstream effects read it as a bare name.
        let mut store = StateStore::new();
        let effects = vec![serde_json::json!({
            "let": { "x": "7 + 3" },
            "in": [
                { "set": { "result": "x * 2" } }
            ]
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            None, None, None);
        assert_eq!(store.get("result"), &serde_json::json!(20));
    }

    #[test]
    fn let_bindings_do_not_escape_in_block() {
        // After the let/in scope ends, the binding is gone.
        let mut store = StateStore::new();
        let effects = vec![
            serde_json::json!({
                "let": { "x": "5" },
                "in": [
                    { "set": { "captured": "x" } }
                ]
            }),
            // Outside the in-block, `x` resolves to the literal 0 fallback
            // (missing identifiers in this evaluator yield null, which
            // coerces through set's eval to null → Value::Null in store).
            serde_json::json!({ "set": { "after": "x" } }),
        ];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            None, None, None);
        assert_eq!(store.get("captured"), &serde_json::json!(5));
        assert_eq!(store.get("after"), &serde_json::Value::Null);
    }

    #[test]
    fn let_with_doc_primitive_binds_path_value() {
        // let: { hit: "hit_test(...)" } — the classic selection-tool
        // pattern. The bound Path value must flow into in-block effects.
        let mut store = StateStore::new();
        let mut model = make_model_two_rects();
        let effects = vec![serde_json::json!({
            "let": { "hit": "hit_test(event.x, event.y)" },
            "in": [
                { "if": {
                    "condition": "hit != null",
                    "then": [
                        { "doc.add_to_selection": "hit" }
                    ],
                    "else": []
                }}
            ]
        })];
        // Register the document so hit_test works.
        let _g = super::super::doc_primitives::register_document(
            model.document().clone());
        let ctx = serde_json::json!({
            "event": { "x": 5.0, "y": 5.0 }  // inside rect0 at (0,0,10,10)
        });
        run_effects(&effects, &ctx, &mut store, Some(&mut model), None, None);
        drop(_g);
        assert_eq!(model.document().selection.len(), 1);
        assert_eq!(model.document().selection[0].path, vec![0, 0]);
    }

    // ── doc.add_element ──────────────────────────────────────────

    #[test]
    fn doc_add_element_creates_rect_with_literal_fields() {
        let mut store = StateStore::new();
        // Start with a doc that has one empty layer so add_element has
        // somewhere to land.
        let mut model = make_model_with_empty_layer();
        let effects = vec![serde_json::json!({
            "doc.add_element": {
                "element": {
                    "type": "rect",
                    "x": 10, "y": 20,
                    "width": 100, "height": 50,
                }
            }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Rect(r) = &*children[0] {
            assert_eq!(r.x, 10.0);
            assert_eq!(r.y, 20.0);
            assert_eq!(r.width, 100.0);
            assert_eq!(r.height, 50.0);
        } else {
            panic!("expected Rect");
        }
    }

    #[test]
    fn doc_add_element_evaluates_string_expressions() {
        let mut store = StateStore::new();
        let mut model = make_model_with_empty_layer();
        let ctx = serde_json::json!({
            "event": { "x": 15, "y": 25 }
        });
        let effects = vec![serde_json::json!({
            "doc.add_element": {
                "element": {
                    "type": "rect",
                    "x": "event.x",
                    "y": "event.y",
                    "width": "50",
                    "height": "60",
                }
            }
        })];
        run_effects(&effects, &ctx, &mut store, Some(&mut model), None, None);
        if let Element::Rect(r) = &*model.document().layers[0].children().unwrap()[0] {
            assert_eq!(r.x, 15.0);
            assert_eq!(r.y, 25.0);
            assert_eq!(r.width, 50.0);
            assert_eq!(r.height, 60.0);
        } else {
            panic!("expected Rect");
        }
    }

    #[test]
    fn doc_add_element_uses_model_defaults_when_fill_omitted() {
        let mut store = StateStore::new();
        let mut model = make_model_with_empty_layer();
        model.default_fill = Some(Fill::new(Color::rgb(1.0, 0.0, 0.0)));
        model.default_stroke = Some(Stroke::new(Color::rgb(0.0, 0.0, 1.0), 3.0));
        let effects = vec![serde_json::json!({
            "doc.add_element": {
                "element": {
                    "type": "rect",
                    "x": 0, "y": 0, "width": 10, "height": 10,
                }
            }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let r = match &*model.document().layers[0].children().unwrap()[0] {
            Element::Rect(r) => r.clone(),
            _ => panic!("expected Rect"),
        };
        assert_eq!(r.fill, Some(Fill::new(Color::rgb(1.0, 0.0, 0.0))));
        // default_stroke is width 3, not Stroke::new's width 1 — the
        // Model default wins exactly, without resolve_stroke_field's
        // "width 1" fallback for explicit-color-string specs.
        assert_eq!(r.stroke, Some(Stroke::new(Color::rgb(0.0, 0.0, 1.0), 3.0)));
    }

    #[test]
    fn doc_add_element_explicit_fill_overrides_defaults() {
        let mut store = StateStore::new();
        let mut model = make_model_with_empty_layer();
        model.default_fill = Some(Fill::new(Color::rgb(1.0, 0.0, 0.0)));
        let effects = vec![serde_json::json!({
            "doc.add_element": {
                "element": {
                    "type": "rect",
                    "x": 0, "y": 0, "width": 10, "height": 10,
                    "fill": "'#00ff00'",
                }
            }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let r = match &*model.document().layers[0].children().unwrap()[0] {
            Element::Rect(r) => r.clone(),
            _ => panic!("expected Rect"),
        };
        assert_eq!(r.fill, Some(Fill::new(Color::rgb(0.0, 1.0, 0.0))));
    }

    #[test]
    fn doc_add_element_explicit_null_fill_strips_fill() {
        let mut store = StateStore::new();
        let mut model = make_model_with_empty_layer();
        model.default_fill = Some(Fill::new(Color::rgb(1.0, 0.0, 0.0)));
        let effects = vec![serde_json::json!({
            "doc.add_element": {
                "element": {
                    "type": "rect",
                    "x": 0, "y": 0, "width": 10, "height": 10,
                    "fill": null,
                }
            }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let r = match &*model.document().layers[0].children().unwrap()[0] {
            Element::Rect(r) => r.clone(),
            _ => panic!("expected Rect"),
        };
        assert_eq!(r.fill, None, "explicit null fill should strip fill");
    }

    #[test]
    fn doc_add_element_unknown_type_is_noop() {
        let mut store = StateStore::new();
        let mut model = make_model_with_empty_layer();
        let effects = vec![serde_json::json!({
            "doc.add_element": {
                "element": { "type": "not_a_real_element_type" }
            }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        assert_eq!(
            model.document().layers[0].children().unwrap().len(),
            0,
        );
    }

    fn make_model_with_empty_layer() -> Model {
        let layer = Element::Layer(crate::geometry::element::LayerElem {
            name: "L".to_string(),
            children: vec![],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let doc = crate::document::document::Document {
            layers: vec![layer],
            selected_layer: 0,
            selection: Vec::new(),
            ..crate::document::document::Document::default()
        };
        Model::new(doc, None)
    }

    #[test]
    fn set_routes_multiple_scopes_in_one_effect() {
        let mut store = StateStore::new();
        let effects = vec![serde_json::json!({
            "set": {
                "tool.sel.mode": "\"idle\"",
                "state.fill_color": "\"#000000\"",
                "recent_count": "5"
            }
        })];
        run_effects(
            &effects, &serde_json::json!({}), &mut store,
            None, None, None);
        assert_eq!(store.get_tool("sel", "mode"), &serde_json::json!("idle"));
        assert_eq!(store.get("fill_color"), &serde_json::json!("#000000"));
        assert_eq!(store.get("recent_count"), &serde_json::json!(5));
    }
}
