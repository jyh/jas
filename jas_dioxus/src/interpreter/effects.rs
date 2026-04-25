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
use crate::algorithms::fit_curve::fit_curve;
use crate::geometry::element::{
    Color, CommonProps, Element, Fill, LineElem, PathCommand, PathElem,
    PolygonElem, RectElem, Stroke,
};
use crate::geometry::regular_shapes::{regular_polygon_points, star_points};

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

    // buffer.push: { buffer: <name>, x: <expr>, y: <expr> }
    //   Append a point to a thread-local named buffer. Used by tools
    //   that accumulate sequences during a drag (Lasso, Pencil).
    if let Some(serde_json::Value::Object(bp)) = effect.get("buffer.push") {
        let name = bp.get("buffer").and_then(|v| v.as_str()).unwrap_or("");
        if !name.is_empty() {
            let x = eval_number(bp.get("x"), store, ctx);
            let y = eval_number(bp.get("y"), store, ctx);
            super::point_buffers::push(name, x, y);
        }
        return;
    }

    // buffer.clear: { buffer: <name> }
    if let Some(serde_json::Value::Object(bc)) = effect.get("buffer.clear") {
        if let Some(name) = bc.get("buffer").and_then(|v| v.as_str()) {
            if !name.is_empty() {
                super::point_buffers::clear(name);
            }
        }
        return;
    }

    // anchor.push: { buffer: <name>, x: <expr>, y: <expr> }
    //   Append a corner-kind anchor at (x, y) with both handles
    //   coincident to the anchor position. Used by Pen's click-to-place.
    if let Some(serde_json::Value::Object(ap)) = effect.get("anchor.push") {
        let name = ap.get("buffer").and_then(|v| v.as_str()).unwrap_or("");
        if !name.is_empty() {
            let x = eval_number(ap.get("x"), store, ctx);
            let y = eval_number(ap.get("y"), store, ctx);
            super::anchor_buffers::push(name, x, y);
        }
        return;
    }

    // anchor.set_last_out: { buffer: <name>, hx: <expr>, hy: <expr> }
    //   Write the out-handle of the most-recently-pushed anchor and
    //   mirror the in-handle around the anchor. Flips the anchor to
    //   smooth=true. Used by Pen's click-drag.
    if let Some(serde_json::Value::Object(ah)) = effect.get("anchor.set_last_out") {
        let name = ah.get("buffer").and_then(|v| v.as_str()).unwrap_or("");
        if !name.is_empty() {
            let hx = eval_number(ah.get("hx"), store, ctx);
            let hy = eval_number(ah.get("hy"), store, ctx);
            super::anchor_buffers::set_last_out_handle(name, hx, hy);
        }
        return;
    }

    // anchor.pop: { buffer: <name> }
    //   Drop the last anchor. Used on double-click to remove the
    //   extra anchor the second mousedown pushed before the
    //   double-click dispatched.
    if let Some(serde_json::Value::Object(ap)) = effect.get("anchor.pop") {
        if let Some(name) = ap.get("buffer").and_then(|v| v.as_str()) {
            if !name.is_empty() {
                super::anchor_buffers::pop(name);
            }
        }
        return;
    }

    // anchor.clear: { buffer: <name> }
    if let Some(serde_json::Value::Object(ac)) = effect.get("anchor.clear") {
        if let Some(name) = ac.get("buffer").and_then(|v| v.as_str()) {
            if !name.is_empty() {
                super::anchor_buffers::clear(name);
            }
        }
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
        "data.set" => {
            // Spec: { path, value }. Writes a value at a dotted path
            // inside store.data. Mirrors the JS Phase 1.13 effect.
            if let serde_json::Value::Object(args) = spec {
                let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
                if !path.is_empty() {
                    let value = resolve_value_or_expr(args.get("value"), store, ctx);
                    store.set_data_path(path, value);
                }
            }
        }
        "data.list_append" => {
            if let serde_json::Value::Object(args) = spec {
                let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
                if !path.is_empty() {
                    let value = resolve_value_or_expr(args.get("value"), store, ctx);
                    let cur = store.get_data_path(path);
                    let mut next = match cur {
                        serde_json::Value::Array(a) => a,
                        _ => Vec::new(),
                    };
                    next.push(value);
                    store.set_data_path(path, serde_json::Value::Array(next));
                }
            }
        }
        "data.list_remove" => {
            if let serde_json::Value::Object(args) = spec {
                let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
                let index = eval_number(args.get("index"), store, ctx) as usize;
                if !path.is_empty() {
                    if let serde_json::Value::Array(mut arr) = store.get_data_path(path) {
                        if index < arr.len() {
                            arr.remove(index);
                            store.set_data_path(path, serde_json::Value::Array(arr));
                        }
                    }
                }
            }
        }
        "data.list_insert" => {
            if let serde_json::Value::Object(args) = spec {
                let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
                let index = eval_number(args.get("index"), store, ctx) as usize;
                if !path.is_empty() {
                    let value = resolve_value_or_expr(args.get("value"), store, ctx);
                    let cur = store.get_data_path(path);
                    let mut arr = match cur {
                        serde_json::Value::Array(a) => a,
                        _ => Vec::new(),
                    };
                    let i = index.min(arr.len());
                    arr.insert(i, value);
                    store.set_data_path(path, serde_json::Value::Array(arr));
                }
            }
        }
        "brush.options_confirm" => {
            // Per-mode dispatch reading dialog state. Phase 1
            // Calligraphic only. Mirrors the Swift / OCaml / Python
            // brush.options_confirm handlers.
            brush_options_confirm_dispatch(store, model);
        }
        "brush.delete_selected" => {
            // Spec: { library, slugs } — filter library.brushes
            // against the selected slug list, clear panel selection.
            // After mutation, sync the canvas brush registry.
            if let serde_json::Value::Object(args) = spec {
                let lib_id = eval_string(args.get("library"), store, ctx);
                let slugs = eval_string_list(args.get("slugs"), store, ctx);
                if !lib_id.is_empty() && !slugs.is_empty() {
                    brush_filter_library_by_slug(store, &lib_id, &slugs, /*keep_unmatched*/ true);
                    store.set_panel("brushes", "selected_brushes",
                                    serde_json::Value::Array(vec![]));
                    sync_canvas_brushes(store);
                }
            }
        }
        "brush.duplicate_selected" => {
            if let serde_json::Value::Object(args) = spec {
                let lib_id = eval_string(args.get("library"), store, ctx);
                let slugs = eval_string_list(args.get("slugs"), store, ctx);
                if !lib_id.is_empty() && !slugs.is_empty() {
                    let new_slugs = brush_duplicate_in_library(store, &lib_id, &slugs);
                    store.set_panel("brushes", "selected_brushes",
                                    serde_json::Value::Array(
                                        new_slugs.into_iter()
                                            .map(serde_json::Value::String)
                                            .collect()));
                    sync_canvas_brushes(store);
                }
            }
        }
        "brush.append" => {
            if let serde_json::Value::Object(args) = spec {
                let lib_id = eval_string(args.get("library"), store, ctx);
                let brush = resolve_value_or_expr(args.get("brush"), store, ctx);
                if !lib_id.is_empty() && brush.is_object() {
                    brush_append_to_library(store, &lib_id, brush);
                    sync_canvas_brushes(store);
                }
            }
        }
        "brush.update" => {
            if let serde_json::Value::Object(args) = spec {
                let lib_id = eval_string(args.get("library"), store, ctx);
                let slug = eval_string(args.get("slug"), store, ctx);
                let patch = resolve_value_or_expr(args.get("patch"), store, ctx);
                if !lib_id.is_empty() && !slug.is_empty() && patch.is_object() {
                    brush_update_in_library(store, &lib_id, &slug, patch);
                    sync_canvas_brushes(store);
                }
            }
        }
        "doc.set_attr_on_selection" => {
            // Spec: { attr: <name>, value: <expr> }
            // Phase 1 supports brush attributes only; other attrs log
            // and ignore. Used by apply_brush_to_selection /
            // remove_brush_from_selection in actions.yaml. Mirrors
            // the JS Phase 1.8 effect.
            if let serde_json::Value::Object(args) = spec {
                let attr = args
                    .get("attr")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                let value_str = args.get("value")
                    .and_then(|v| match v {
                        serde_json::Value::String(s) => {
                            match eval_expr(s, store, ctx) {
                                Value::Str(rs) if !rs.is_empty() => Some(rs),
                                _ => None,
                            }
                        }
                        _ => None,
                    });
                match attr {
                    "stroke_brush" =>
                        Controller::set_selection_stroke_brush(model, value_str),
                    "stroke_brush_overrides" =>
                        Controller::set_selection_stroke_brush_overrides(model, value_str),
                    _ => {} // Phase 1: only brush attrs supported
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
        "doc.add_path_from_anchor_buffer" => {
            // Converts a named anchor buffer into a Bezier Path
            // element and appends it to the document. Each pair of
            // consecutive anchors becomes one cubic-Bezier CurveTo
            // using the prev-out and curr-in handles. When `closed`
            // is true, a final CurveTo back to the first anchor plus
            // a ClosePath are emitted.
            //
            // Mirrors PenTool::finish. The near-first-point
            // auto-close check the native tool did happens in YAML
            // (on_mousedown-near-first-anchor → commit closed); this
            // effect just honors the `closed` flag the handler sets.
            if let serde_json::Value::Object(args) = spec {
                let name = args
                    .get("buffer")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                if name.is_empty() {
                    return;
                }
                let closed = eval_bool(args.get("closed"), store, ctx);
                let default_fill = model.default_fill;
                let default_stroke = model.default_stroke;
                let fill = resolve_fill_field(
                    args.get("fill"), store, ctx, default_fill);
                let stroke = resolve_stroke_field(
                    args.get("stroke"), store, ctx, default_stroke);

                let anchors: Vec<super::anchor_buffers::Anchor> =
                    super::anchor_buffers::with_anchors(
                        name, |a| a.to_vec());
                if anchors.len() < 2 {
                    return;
                }
                let mut cmds: Vec<PathCommand> = Vec::new();
                cmds.push(PathCommand::MoveTo {
                    x: anchors[0].x,
                    y: anchors[0].y,
                });
                for i in 1..anchors.len() {
                    let prev = &anchors[i - 1];
                    let curr = &anchors[i];
                    cmds.push(PathCommand::CurveTo {
                        x1: prev.hx_out, y1: prev.hy_out,
                        x2: curr.hx_in,  y2: curr.hy_in,
                        x: curr.x, y: curr.y,
                    });
                }
                if closed {
                    let last = &anchors[anchors.len() - 1];
                    let p0 = &anchors[0];
                    cmds.push(PathCommand::CurveTo {
                        x1: last.hx_out, y1: last.hy_out,
                        x2: p0.hx_in,    y2: p0.hy_in,
                        x: p0.x, y: p0.y,
                    });
                    cmds.push(PathCommand::ClosePath);
                }
                let elem = Element::Path(PathElem {
                    d: cmds,
                    fill,
                    stroke,
                    width_points: Vec::new(),
                    common: CommonProps::default(),
                    fill_gradient: None,
                    stroke_gradient: None,
                    stroke_brush: None,
                    stroke_brush_overrides: None,
                });
                Controller::add_element(model, elem);
            }
        }
        "doc.add_path_from_buffer" => {
            // Runs fit_curve on the named buffer's points and
            // appends the resulting cubic-Bezier path to the
            // document. Mirrors PencilTool::finish. Pops only when
            // the buffer has >= 2 points; otherwise no-ops.
            //
            // Fit-error controls smoothing vs fidelity (smaller =
            // more accurate, more segments). The field `fit_error`
            // defaults to 4.0 to match native FIT_ERROR.
            //
            // Pencil-style callers pass only `buffer` / `fit_error`
            // / `fill` / `stroke`. Paintbrush-style callers also pass
            // `stroke_brush` (even `null`), which switches the stroke
            // computation to the PAINTBRUSH_TOOL.md §Fill and stroke
            // rules: state.stroke_color for color, brush.size (or
            // state.stroke_width fallback) for width. `fill_new_strokes`
            // opts into a state.fill_color fill; `close` appends a
            // ClosePath; `stroke_brush_overrides` is passed through.
            if let serde_json::Value::Object(args) = spec {
                let name = args
                    .get("buffer")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                if name.is_empty() {
                    return;
                }
                let fit_error_val = args.get("fit_error");
                let fit_error = if fit_error_val.is_some() {
                    eval_number(fit_error_val, store, ctx)
                } else {
                    4.0
                };

                let has_stroke_brush_arg = args.contains_key("stroke_brush");
                let stroke_brush_slug = args.get("stroke_brush")
                    .and_then(|v| match v {
                        serde_json::Value::String(s) => {
                            match eval_expr(s, store, ctx) {
                                Value::Str(rs) if !rs.is_empty() => Some(rs),
                                _ => None,
                            }
                        }
                        _ => None,
                    });
                let stroke_brush_overrides = args.get("stroke_brush_overrides")
                    .and_then(|v| match v {
                        serde_json::Value::String(s) => {
                            match eval_expr(s, store, ctx) {
                                Value::Str(rs) if !rs.is_empty() => Some(rs),
                                _ => None,
                            }
                        }
                        _ => None,
                    });

                // Fill: fill_new_strokes takes precedence when present
                // (Paintbrush rule); else fall back to pencil-style
                // resolver.
                let fill = if args.contains_key("fill_new_strokes") {
                    if eval_bool(args.get("fill_new_strokes"), store, ctx) {
                        match eval_expr("state.fill_color", store, ctx) {
                            Value::Color(c) => Color::from_hex(&c).map(Fill::new),
                            Value::Str(s) => Color::from_hex(&s).map(Fill::new),
                            _ => None,
                        }
                    } else {
                        None
                    }
                } else {
                    let default_fill = model.default_fill;
                    resolve_fill_field(args.get("fill"), store, ctx, default_fill)
                };

                // Stroke: presence of stroke_brush key (even =null)
                // signals Paintbrush semantics — compute from state.
                // Pencil-style callers use resolve_stroke_field as before.
                let stroke = if has_stroke_brush_arg {
                    let color = match eval_expr("state.stroke_color", store, ctx) {
                        Value::Color(c) => Color::from_hex(&c).unwrap_or(Color::BLACK),
                        Value::Str(s) => Color::from_hex(&s).unwrap_or(Color::BLACK),
                        _ => Color::BLACK,
                    };
                    let width = paintbrush_stroke_width(
                        stroke_brush_slug.as_deref(),
                        stroke_brush_overrides.as_deref(),
                        store,
                        ctx,
                    );
                    Some(Stroke::new(color, width))
                } else {
                    let default_stroke = model.default_stroke;
                    resolve_stroke_field(args.get("stroke"), store, ctx, default_stroke)
                };

                let points: Vec<(f64, f64)> = super::point_buffers::with_points(
                    name, |pts| pts.to_vec());
                if points.len() < 2 {
                    return;
                }
                let segments = fit_curve(&points, fit_error);
                if segments.is_empty() {
                    return;
                }
                let mut cmds: Vec<PathCommand> = Vec::new();
                cmds.push(PathCommand::MoveTo {
                    x: segments[0].0,
                    y: segments[0].1,
                });
                for seg in &segments {
                    cmds.push(PathCommand::CurveTo {
                        x1: seg.2, y1: seg.3,
                        x2: seg.4, y2: seg.5,
                        x: seg.6, y: seg.7,
                    });
                }
                if eval_bool(args.get("close"), store, ctx) {
                    cmds.push(PathCommand::ClosePath);
                }

                let elem = Element::Path(PathElem {
                    d: cmds,
                    fill,
                    stroke,
                    width_points: Vec::new(),
                    common: CommonProps::default(),
                    fill_gradient: None,
                    stroke_gradient: None,
                    stroke_brush: stroke_brush_slug,
                    stroke_brush_overrides,
                });
                Controller::add_element(model, elem);
            }
        }
        "doc.path.probe_anchor_hit" => {
            // AnchorPoint's dispatch layer. Hit-test in order:
            //   1. bezier control handle  -> tool.anchor_point.mode = "pressed_handle"
            //   2. smooth anchor point    -> tool.anchor_point.mode = "pressed_smooth"
            //   3. corner anchor point    -> tool.anchor_point.mode = "pressed_corner"
            //   4. nothing                -> tool.anchor_point.mode = "idle"
            // On hit, also stashes tool.anchor_point.hit_path (as a
            // serialized Path value) and hit_anchor_idx. For handle
            // hits, additionally writes handle_type ("in" or "out").
            // The YAML commit handler branches on mode to apply the
            // right mutation on mouseup.
            if let serde_json::Value::Object(args) = spec {
                let x = eval_number(args.get("x"), store, ctx);
                let y = eval_number(args.get("y"), store, ctx);
                let hit_radius = eval_number(args.get("hit_radius"), store, ctx);
                let radius = if hit_radius == 0.0 { 8.0 } else { hit_radius };
                path_probe_anchor_hit(model, store, x, y, radius);
            }
        }
        "doc.path.commit_anchor_edit" => {
            // Reads the latched hit (tool.anchor_point.hit_path +
            // hit_anchor_idx + optional handle_type) and applies the
            // mutation corresponding to tool.anchor_point.mode:
            //   pressed_smooth → convert_smooth_to_corner
            //   pressed_corner → convert_corner_to_smooth at (target_x, target_y)
            //   pressed_handle → move_path_handle_independent by delta
            // Snapshots once on commit. No-op when mode is "idle".
            if let serde_json::Value::Object(args) = spec {
                let target_x = eval_number(args.get("target_x"), store, ctx);
                let target_y = eval_number(args.get("target_y"), store, ctx);
                let origin_x = eval_number(args.get("origin_x"), store, ctx);
                let origin_y = eval_number(args.get("origin_y"), store, ctx);
                path_commit_anchor_edit(model, store, origin_x, origin_y, target_x, target_y);
            }
        }
        "doc.path.probe_partial_hit" => {
            // Partial Selection tool's press-time dispatcher. Hit-test
            // priority:
            //   1. Bezier handle on a selected Path → mode = "handle",
            //      writes tool.partial_selection.{handle_path,
            //      handle_anchor_idx, handle_type}
            //   2. Control point on any unlocked element → mode =
            //      "moving_pending". Also updates selection: shift-
            //      toggles if the CP isn't already selected, plain
            //      click selects just that CP (unless already
            //      selected — keeps the existing selection so a drag
            //      moves the group).
            //   3. No hit → mode = "marquee".
            if let serde_json::Value::Object(args) = spec {
                let x = eval_number(args.get("x"), store, ctx);
                let y = eval_number(args.get("y"), store, ctx);
                let hit_radius = eval_number(args.get("hit_radius"), store, ctx);
                let radius = if hit_radius == 0.0 { 8.0 } else { hit_radius };
                let shift = eval_bool(args.get("shift"), store, ctx);
                path_probe_partial_hit(model, store, x, y, radius, shift);
            }
        }
        "doc.move_path_handle" => {
            // Reads tool.partial_selection.{handle_path,
            // handle_anchor_idx, handle_type} and applies a handle
            // move by (dx, dy). No-op if no handle is latched.
            if let serde_json::Value::Object(args) = spec {
                let dx = eval_number(args.get("dx"), store, ctx);
                let dy = eval_number(args.get("dy"), store, ctx);
                path_move_latched_handle(model, store, dx, dy);
            }
        }
        "doc.path.commit_partial_marquee" => {
            // Called on mouseup when the Partial Selection tool was in
            // marquee mode. Converts the marquee rect into a
            // partial_select_rect call; empty-ish rects without shift
            // clear the selection (click-in-empty-space semantics).
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
                if rw > 1.0 || rh > 1.0 {
                    model.snapshot();
                    Controller::partial_select_rect(model, rx, ry, rw, rh, additive);
                } else if !additive {
                    Controller::set_selection(model, Vec::new());
                }
            }
        }
        "doc.path.erase_at_rect" => {
            // Sweeps a rectangular eraser from (last_x, last_y) to
            // (x, y) expanded by eraser_size (half-extent), intersecting
            // every unlocked Path in every layer. Paths whose bounding
            // box fits inside the eraser are deleted entirely; intersected
            // paths are split via De Casteljau-preserving geometry. The
            // YAML handler is responsible for calling doc.snapshot once
            // at mousedown — this effect mutates the document directly
            // on every call. Mirrors the deleted PathEraserTool::erase_at.
            if let serde_json::Value::Object(args) = spec {
                let last_x = eval_number(args.get("last_x"), store, ctx);
                let last_y = eval_number(args.get("last_y"), store, ctx);
                let x = eval_number(args.get("x"), store, ctx);
                let y = eval_number(args.get("y"), store, ctx);
                let er_sz = eval_number(args.get("eraser_size"), store, ctx);
                let eraser_size = if er_sz == 0.0 { 2.0 } else { er_sz };
                path_erase_at_rect(model, last_x, last_y, x, y, eraser_size);
            }
        }
        "doc.paintbrush.edit_start" => {
            // Paintbrush edit-gesture target selection. See
            // PAINTBRUSH_TOOL.md §Edit gesture. If any selected Path
            // has a flat point within `within` px of (x, y), switches
            // tool.paintbrush.mode to 'edit' and stashes the target
            // path + entry flat-index in tool state. Otherwise
            // leaves tool state untouched (mode stays 'drawing').
            if let serde_json::Value::Object(args) = spec {
                let x = eval_number(args.get("x"), store, ctx);
                let y = eval_number(args.get("y"), store, ctx);
                let within = eval_number(args.get("within"), store, ctx);
                path_paintbrush_edit_start(&*model, store, x, y, within);
            }
        }
        "doc.paintbrush.edit_commit" => {
            // Paintbrush edit-gesture splice. Reads target + entry_idx
            // stashed by doc.paintbrush.edit_start, computes exit_idx
            // on the target's flat polyline from the final drag point,
            // and replaces the affected command range with a cubic-
            // Bezier fit of the drag buffer. Preserves all non-`d`
            // attributes. See PAINTBRUSH_TOOL.md §Edit gesture.
            if let serde_json::Value::Object(args) = spec {
                let buffer = args.get("buffer").and_then(|v| v.as_str())
                    .unwrap_or("").to_string();
                if buffer.is_empty() {
                    return;
                }
                let fit_error = {
                    let fe = eval_number(args.get("fit_error"), store, ctx);
                    if fe == 0.0 { 4.0 } else { fe }
                };
                let within = eval_number(args.get("within"), store, ctx);
                path_paintbrush_edit_commit(model, store, &buffer, fit_error, within);
            }
        }
        "doc.blob_brush.commit_painting" => {
            // Blob Brush painting-mode commit. Takes the accumulated
            // sweep buffer, generates dabs at arc-length intervals,
            // unions them into a swept region, merges with qualifying
            // existing blob-brush elements (per BLOB_BRUSH_TOOL.md
            // §Merge condition + §Multi-element merge), simplifies
            // the boundary, and commits as a single filled Path.
            if let serde_json::Value::Object(args) = spec {
                let buffer = args.get("buffer").and_then(|v| v.as_str())
                    .unwrap_or("").to_string();
                if buffer.is_empty() {
                    return;
                }
                let epsilon = eval_number(args.get("fidelity_epsilon"), store, ctx);
                let merge_only_with_selection = eval_bool(
                    args.get("merge_only_with_selection"), store, ctx);
                let keep_selected = eval_bool(
                    args.get("keep_selected"), store, ctx);
                blob_brush_commit_painting(
                    model, store, ctx, &buffer, epsilon,
                    merge_only_with_selection, keep_selected);
            }
        }
        "doc.blob_brush.commit_erasing" => {
            // Blob Brush erasing-mode commit. Same sweep-region
            // generation as painting; then boolean_subtract the region
            // from each overlapping jas:tool-origin == blob_brush
            // element (fill match not required). Empty results delete;
            // non-empty update in place. See BLOB_BRUSH_TOOL.md
            // §Erase gesture.
            if let serde_json::Value::Object(args) = spec {
                let buffer = args.get("buffer").and_then(|v| v.as_str())
                    .unwrap_or("").to_string();
                if buffer.is_empty() {
                    return;
                }
                let epsilon = eval_number(args.get("fidelity_epsilon"), store, ctx);
                blob_brush_commit_erasing(
                    model, store, ctx, &buffer, epsilon);
            }
        }
        "doc.scale.apply" => {
            // Scale tool apply per SCALE_TOOL.md §Apply behavior.
            // Two calling conventions:
            //   - drag path (from scale.yaml on_mouseup): press_x/y +
            //     cursor_x/y + shift → derive (sx, sy)
            //   - dialog path (from scale_options_confirm action):
            //     sx + sy directly
            // Reference point comes from state.transform_reference_point
            // (when set) or the selection's union bbox center.
            if let serde_json::Value::Object(args) = spec {
                let copy = eval_bool(args.get("copy"), store, ctx);
                let (sx, sy) = if args.contains_key("sx") {
                    let sx = eval_number(args.get("sx"), store, ctx);
                    let sy = eval_number(args.get("sy"), store, ctx);
                    (sx, sy)
                } else {
                    let (rx, ry) = resolve_reference_point(model, store, ctx);
                    let px = eval_number(args.get("press_x"), store, ctx);
                    let py = eval_number(args.get("press_y"), store, ctx);
                    let cx = eval_number(args.get("cursor_x"), store, ctx);
                    let cy = eval_number(args.get("cursor_y"), store, ctx);
                    let shift = eval_bool(args.get("shift"), store, ctx);
                    drag_to_scale_factors(px, py, cx, cy, rx, ry, shift)
                };
                scale_apply(model, store, ctx, sx, sy, copy);
            }
        }
        "doc.rotate.apply" => {
            // Rotate tool apply per ROTATE_TOOL.md §Apply behavior.
            // Two calling conventions:
            //   - drag path: press_x/y + cursor_x/y + shift → derive θ
            //   - dialog path: angle directly
            if let serde_json::Value::Object(args) = spec {
                let copy = eval_bool(args.get("copy"), store, ctx);
                let theta_deg = if args.contains_key("angle") {
                    eval_number(args.get("angle"), store, ctx)
                } else {
                    let (rx, ry) = resolve_reference_point(model, store, ctx);
                    let px = eval_number(args.get("press_x"), store, ctx);
                    let py = eval_number(args.get("press_y"), store, ctx);
                    let cx = eval_number(args.get("cursor_x"), store, ctx);
                    let cy = eval_number(args.get("cursor_y"), store, ctx);
                    let shift = eval_bool(args.get("shift"), store, ctx);
                    drag_to_rotate_angle(px, py, cx, cy, rx, ry, shift)
                };
                rotate_apply(model, store, ctx, theta_deg, copy);
            }
        }
        "doc.shear.apply" => {
            // Shear tool apply per SHEAR_TOOL.md §Apply behavior.
            // Two calling conventions:
            //   - drag path: press_x/y + cursor_x/y + shift → derive
            //     (angle, axis, axis_angle)
            //   - dialog path: angle + axis + axis_angle directly
            if let serde_json::Value::Object(args) = spec {
                let copy = eval_bool(args.get("copy"), store, ctx);
                let (angle_deg, axis, axis_angle_deg) =
                    if args.contains_key("angle") && args.contains_key("axis")
                {
                    let a = eval_number(args.get("angle"), store, ctx);
                    let ax = eval_string(args.get("axis"), store, ctx);
                    let aa = eval_number(args.get("axis_angle"), store, ctx);
                    (a, ax, aa)
                } else {
                    let (rx, ry) = resolve_reference_point(model, store, ctx);
                    let px = eval_number(args.get("press_x"), store, ctx);
                    let py = eval_number(args.get("press_y"), store, ctx);
                    let cx = eval_number(args.get("cursor_x"), store, ctx);
                    let cy = eval_number(args.get("cursor_y"), store, ctx);
                    let shift = eval_bool(args.get("shift"), store, ctx);
                    drag_to_shear_params(px, py, cx, cy, rx, ry, shift)
                };
                shear_apply(model, store, ctx, angle_deg, &axis, axis_angle_deg, copy);
            }
        }
        "doc.magic_wand.apply" => {
            // Magic Wand selection per MAGIC_WAND_TOOL.md §Predicate.
            // Reads the seed path + mode (replace / add / subtract)
            // from the spec, walks the document, applies the
            // eligibility filter and the AND-of-enabled-criteria
            // predicate, mutates the selection accordingly.
            if let serde_json::Value::Object(args) = spec {
                let Some(seed_path) =
                    args.get("seed").and_then(|v| extract_path(v, store, ctx))
                else { return; };
                let mode_raw = eval_string(args.get("mode"), store, ctx);
                let mode = if mode_raw.is_empty() {
                    "replace".to_string()
                } else { mode_raw };
                magic_wand_apply(model, store, ctx, &seed_path, &mode);
            }
        }
        "doc.path.smooth_at_cursor" => {
            // Iterates *selected* unlocked Path elements, finds the
            // contiguous flat-polyline range within `radius` of (x, y),
            // and re-fits that range via algorithms::fit_curve with the
            // given error tolerance (defaults to 8.0 — native
            // SMOOTH_ERROR). The YAML handler is responsible for
            // doc.snapshot on mousedown. Mirrors SmoothTool::smooth_at.
            if let serde_json::Value::Object(args) = spec {
                let x = eval_number(args.get("x"), store, ctx);
                let y = eval_number(args.get("y"), store, ctx);
                let radius = eval_number(args.get("radius"), store, ctx);
                let r = if radius == 0.0 { 100.0 } else { radius };
                let fit_error = eval_number(args.get("fit_error"), store, ctx);
                let e = if fit_error == 0.0 { 8.0 } else { fit_error };
                path_smooth_at_cursor(model, x, y, r, e);
            }
        }
        "doc.path.insert_anchor_on_segment_near" => {
            // Mirrors the native AddAnchorPointTool's click-to-insert
            // case. Walks all unlocked Path elements in the document,
            // finds the closest (segment, t) to the cursor, and inserts
            // a new anchor there if within hit_radius of any segment.
            //
            // MVP scope: just click-to-insert. Native also supported
            // Alt+click-to-toggle-smooth/corner (covered by the
            // AnchorPoint tool now) and Space+drag reposition (dropped).
            if let serde_json::Value::Object(args) = spec {
                let x = eval_number(args.get("x"), store, ctx);
                let y = eval_number(args.get("y"), store, ctx);
                let hit_radius = eval_number(args.get("hit_radius"), store, ctx);
                let radius = if hit_radius == 0.0 { 8.0 } else { hit_radius };
                path_insert_anchor_on_segment_near(model, x, y, radius);
            }
        }
        "doc.path.delete_anchor_near" => {
            // Find the anchor under (x, y) within hit_radius on any
            // unlocked Path in the document (searches layers +
            // one level of Group nesting). If found, snapshot the
            // document, delete the anchor via
            // geometry::path_ops::delete_anchor_from_path, and
            // either replace the path element or (if the resulting
            // path has < 2 anchors) delete it entirely. Mirrors the
            // native DeleteAnchorPointTool.
            if let serde_json::Value::Object(args) = spec {
                let x = eval_number(args.get("x"), store, ctx);
                let y = eval_number(args.get("y"), store, ctx);
                let hit_radius = eval_number(args.get("hit_radius"), store, ctx);
                let radius = if hit_radius == 0.0 { 8.0 } else { hit_radius };
                path_delete_anchor_near(model, x, y, radius);
            }
        }
        "doc.select_polygon_from_buffer" => {
            // Uses the named point buffer as a free-form polygon and
            // selects every element whose bounds intersect it. Mirrors
            // the Lasso tool's Controller::select_polygon call.
            if let serde_json::Value::Object(args) = spec {
                let name = args
                    .get("buffer")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                if name.is_empty() {
                    return;
                }
                let additive = eval_bool(args.get("additive"), store, ctx);
                let points: Vec<(f64, f64)> =
                    super::point_buffers::with_points(name, |pts| pts.to_vec());
                if points.len() >= 3 {
                    Controller::select_polygon(model, &points, additive);
                }
            }
        }
        "doc.partial_select_in_rect" => {
            // Same shape as doc.select_in_rect but routes through
            // Controller::partial_select_rect so selection entries
            // are SelectionKind::Partial (individual control points)
            // instead of SelectionKind::All (whole-element). Used by
            // the Partial Selection and Interior Selection tools.
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
                Controller::partial_select_rect(model, rx, ry, rw, rh, additive);
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
/// Resolve a YAML value field. Strings are evaluated as expressions
/// (matching the doc.set_attr / set: convention); non-strings are
/// used verbatim. Lets data.list_append etc. accept inline JSON
/// object literals where the expression language has no object
/// literal syntax. Mirrors the JS _resolveValueOrExpr helper.
fn resolve_value_or_expr(
    spec: Option<&serde_json::Value>,
    store: &StateStore,
    ctx: &serde_json::Value,
) -> serde_json::Value {
    match spec {
        None | Some(serde_json::Value::Null) => serde_json::Value::Null,
        Some(serde_json::Value::String(s)) => value_to_json(&eval_expr(s, store, ctx)),
        Some(v) => v.clone(),
    }
}

/// Evaluate an arg as a string. Returns "" on null / missing /
/// non-string result.
fn eval_string(
    arg: Option<&serde_json::Value>,
    store: &StateStore,
    ctx: &serde_json::Value,
) -> String {
    match arg {
        None | Some(serde_json::Value::Null) => String::new(),
        Some(serde_json::Value::String(s)) => match eval_expr(s, store, ctx) {
            Value::Str(rs) => rs,
            _ => String::new(),
        },
        _ => String::new(),
    }
}

/// Evaluate an arg as a list of strings. Accepts a JSON array
/// literal or a string expression that evaluates to a List of Str.
fn eval_string_list(
    arg: Option<&serde_json::Value>,
    store: &StateStore,
    ctx: &serde_json::Value,
) -> Vec<String> {
    match arg {
        Some(serde_json::Value::Array(items)) => items
            .iter()
            .filter_map(|v| v.as_str().map(String::from))
            .collect(),
        Some(serde_json::Value::String(s)) => match eval_expr(s, store, ctx) {
            Value::List(items) => items
                .iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect(),
            _ => Vec::new(),
        },
        _ => Vec::new(),
    }
}

/// Filter a library's brushes against `slugs`. When `keep_unmatched`
/// is true, removes brushes whose slug is in the list (delete);
/// Paintbrush-tool stroke-width commit rule. Returns the effective
/// stroke-width for a new path being committed by the Paintbrush tool
/// with the given brush reference.
///
/// Per PAINTBRUSH_TOOL.md §Fill and stroke:
/// - No brush slug → state.stroke_width.
/// - Brush with a `size` field (Calligraphic / Scatter / Bristle) →
///   effective size (overrides.size first, else brush.size).
/// - Brush with no `size` field (Art / Pattern) → state.stroke_width.
fn paintbrush_stroke_width(
    stroke_brush_slug: Option<&str>,
    overrides_json: Option<&str>,
    store: &StateStore,
    ctx: &serde_json::Value,
) -> f64 {
    let state_width = match eval_expr("state.stroke_width", store, ctx) {
        Value::Number(n) => n,
        _ => 1.0,
    };

    let Some(slug) = stroke_brush_slug else {
        return state_width;
    };

    if let Some(ovr_json) = overrides_json {
        if let Ok(ovr) = serde_json::from_str::<serde_json::Value>(ovr_json) {
            if let Some(size) = ovr.get("size").and_then(|s| s.as_f64()) {
                return size;
            }
        }
    }

    let (lib_id, brush_slug) = match slug.split_once('/') {
        Some(pair) => pair,
        None => return state_width,
    };
    let path = format!("brush_libraries.{}.brushes", lib_id);
    let brushes = match store.get_data_path(&path) {
        serde_json::Value::Array(b) => b,
        _ => return state_width,
    };
    brushes
        .iter()
        .find(|b| b.get("slug").and_then(|s| s.as_str()) == Some(brush_slug))
        .and_then(|b| b.get("size").and_then(|s| s.as_f64()))
        .unwrap_or(state_width)
}

/// otherwise keeps only matching brushes.
fn brush_filter_library_by_slug(
    store: &mut StateStore,
    lib_id: &str,
    slugs: &[String],
    keep_unmatched: bool,
) {
    let path = format!("brush_libraries.{}.brushes", lib_id);
    if let serde_json::Value::Array(brushes) = store.get_data_path(&path) {
        let slug_set: std::collections::HashSet<&str> =
            slugs.iter().map(String::as_str).collect();
        let next: Vec<serde_json::Value> = brushes
            .into_iter()
            .filter(|b| {
                let slug = b.get("slug").and_then(|s| s.as_str()).unwrap_or("");
                if keep_unmatched {
                    !slug_set.contains(slug)
                } else {
                    slug_set.contains(slug)
                }
            })
            .collect();
        store.set_data_path(&path, serde_json::Value::Array(next));
    }
}

/// Duplicate brushes whose slug is in `slugs` within library
/// `lib_id`. Each copy gets a unique <orig>_copy[_N] slug and
/// " copy" appended to the name. Returns the new slug list (in
/// insertion order).
fn brush_duplicate_in_library(
    store: &mut StateStore,
    lib_id: &str,
    slugs: &[String],
) -> Vec<String> {
    let path = format!("brush_libraries.{}.brushes", lib_id);
    let mut new_slugs = Vec::new();
    let brushes = match store.get_data_path(&path) {
        serde_json::Value::Array(b) => b,
        _ => return new_slugs,
    };
    let mut existing_slugs: std::collections::HashSet<String> = brushes
        .iter()
        .filter_map(|b| b.get("slug").and_then(|s| s.as_str()).map(String::from))
        .collect();
    let mut next: Vec<serde_json::Value> = Vec::with_capacity(brushes.len());
    for b in brushes {
        next.push(b.clone());
        let slug = b.get("slug").and_then(|s| s.as_str()).unwrap_or("").to_string();
        if !slugs.contains(&slug) {
            continue;
        }
        let mut copy = match b.as_object() {
            Some(map) => map.clone(),
            None => continue,
        };
        let name = copy.get("name").and_then(|n| n.as_str()).unwrap_or("Brush").to_string();
        copy.insert("name".to_string(), serde_json::Value::String(format!("{} copy", name)));
        let mut new_slug = format!("{}_copy", slug);
        let mut n = 2;
        while existing_slugs.contains(&new_slug) {
            new_slug = format!("{}_copy_{}", slug, n);
            n += 1;
        }
        existing_slugs.insert(new_slug.clone());
        copy.insert("slug".to_string(), serde_json::Value::String(new_slug.clone()));
        new_slugs.push(new_slug);
        next.push(serde_json::Value::Object(copy));
    }
    store.set_data_path(&path, serde_json::Value::Array(next));
    new_slugs
}

/// Append a new brush to the named library.
fn brush_append_to_library(
    store: &mut StateStore,
    lib_id: &str,
    brush: serde_json::Value,
) {
    let path = format!("brush_libraries.{}.brushes", lib_id);
    let mut brushes = match store.get_data_path(&path) {
        serde_json::Value::Array(b) => b,
        _ => Vec::new(),
    };
    brushes.push(brush);
    store.set_data_path(&path, serde_json::Value::Array(brushes));
}

/// Patch an existing master brush in place, merging fields from
/// `patch` onto the brush identified by `slug`.
fn brush_update_in_library(
    store: &mut StateStore,
    lib_id: &str,
    slug: &str,
    patch: serde_json::Value,
) {
    let path = format!("brush_libraries.{}.brushes", lib_id);
    let mut brushes = match store.get_data_path(&path) {
        serde_json::Value::Array(b) => b,
        _ => return,
    };
    let patch_map = match patch.as_object() {
        Some(p) => p.clone(),
        None => return,
    };
    for b in brushes.iter_mut() {
        let matches = b.get("slug").and_then(|s| s.as_str()) == Some(slug);
        if !matches {
            continue;
        }
        if let Some(map) = b.as_object_mut() {
            for (k, v) in &patch_map {
                map.insert(k.clone(), v.clone());
            }
        }
        break;
    }
    store.set_data_path(&path, serde_json::Value::Array(brushes));
}

/// Push the current data.brush_libraries through to the canvas
/// renderer's brush registry so the next paint sees the updates.
fn sync_canvas_brushes(store: &StateStore) {
    let libs = store.get_data_path("brush_libraries");
    let _guard = crate::canvas::render::register_brush_libraries(libs);
    // The guard restores the prior registry on Drop. For mutation
    // syncing we want the new value to stick, so we deliberately
    // forget the guard.
    std::mem::forget(_guard);
}

/// Dispatch brush_options_confirm — read dialog state, dispatch
/// per mode (create / library_edit / instance_edit). Phase 1
/// Calligraphic only. Reads dialog state via Store_dialog
/// accessors (assumed to exist — falls back to log if not).
fn brush_options_confirm_dispatch(store: &mut StateStore, model: &mut Model) {
    let mode = store.dialog_params()
        .and_then(|p| p.get("mode"))
        .and_then(|v| v.as_str())
        .unwrap_or("create").to_string();
    let library = store.dialog_params()
        .and_then(|p| p.get("library"))
        .and_then(|v| v.as_str())
        .unwrap_or("").to_string();
    let brush_slug = store.dialog_params()
        .and_then(|p| p.get("brush_slug"))
        .and_then(|v| v.as_str())
        .unwrap_or("").to_string();
    let name = store.get_dialog("brush_name").as_str().unwrap_or("Brush").to_string();
    let brush_type = store.get_dialog("brush_type").as_str().unwrap_or("calligraphic").to_string();
    let angle = store.get_dialog("angle").as_f64().unwrap_or(0.0);
    let roundness = store.get_dialog("roundness").as_f64().unwrap_or(100.0);
    let size = store.get_dialog("size").as_f64().unwrap_or(5.0);
    let angle_var = match store.get_dialog("angle_variation") {
        serde_json::Value::Null => serde_json::json!({"mode": "fixed"}),
        v => v.clone(),
    };
    let roundness_var = match store.get_dialog("roundness_variation") {
        serde_json::Value::Null => serde_json::json!({"mode": "fixed"}),
        v => v.clone(),
    };
    let size_var = match store.get_dialog("size_variation") {
        serde_json::Value::Null => serde_json::json!({"mode": "fixed"}),
        v => v.clone(),
    };

    let lib_key = if !library.is_empty() {
        library
    } else {
        match store.get_data_path("brush_libraries") {
            serde_json::Value::Object(map) => map.keys().next().cloned().unwrap_or_default(),
            _ => String::new(),
        }
    };
    if lib_key.is_empty() { return; }

    match mode.as_str() {
        "create" => {
            let raw: String = name.chars()
                .map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '_' })
                .collect();
            let path = format!("brush_libraries.{}.brushes", lib_key);
            let existing: std::collections::HashSet<String> = match store.get_data_path(&path) {
                serde_json::Value::Array(a) => a.iter()
                    .filter_map(|b| b.get("slug").and_then(|s| s.as_str()).map(String::from))
                    .collect(),
                _ => std::collections::HashSet::new(),
            };
            let mut slug = raw.clone();
            let mut n = 2;
            while existing.contains(&slug) {
                slug = format!("{raw}_{n}");
                n += 1;
            }
            let mut brush = serde_json::Map::new();
            brush.insert("name".to_string(), serde_json::Value::String(name));
            brush.insert("slug".to_string(), serde_json::Value::String(slug));
            brush.insert("type".to_string(), serde_json::Value::String(brush_type.clone()));
            if brush_type == "calligraphic" {
                brush.insert("angle".to_string(), serde_json::json!(angle));
                brush.insert("roundness".to_string(), serde_json::json!(roundness));
                brush.insert("size".to_string(), serde_json::json!(size));
                brush.insert("angle_variation".to_string(), angle_var);
                brush.insert("roundness_variation".to_string(), roundness_var);
                brush.insert("size_variation".to_string(), size_var);
            }
            brush_append_to_library(store, &lib_key, serde_json::Value::Object(brush));
            sync_canvas_brushes(store);
        }
        "library_edit" if !brush_slug.is_empty() => {
            let mut patch = serde_json::Map::new();
            patch.insert("name".to_string(), serde_json::Value::String(name));
            if brush_type == "calligraphic" {
                patch.insert("angle".to_string(), serde_json::json!(angle));
                patch.insert("roundness".to_string(), serde_json::json!(roundness));
                patch.insert("size".to_string(), serde_json::json!(size));
                patch.insert("angle_variation".to_string(), angle_var);
                patch.insert("roundness_variation".to_string(), roundness_var);
                patch.insert("size_variation".to_string(), size_var);
            }
            brush_update_in_library(store, &lib_key, &brush_slug, serde_json::Value::Object(patch));
            sync_canvas_brushes(store);
        }
        "instance_edit" => {
            let overrides = serde_json::json!({
                "angle": angle, "roundness": roundness, "size": size,
            });
            let s = serde_json::to_string(&overrides).unwrap_or_default();
            crate::document::controller::Controller::set_selection_stroke_brush_overrides(
                model, Some(s));
        }
        _ => {}
    }
}

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
        "polygon" => {
            // Regular N-gon with the first edge from (x1, y1) to (x2, y2).
            // `sides` defaults to 5, matching native POLYGON_SIDES.
            let x1 = eval_number(spec.get("x1"), store, ctx);
            let y1 = eval_number(spec.get("y1"), store, ctx);
            let x2 = eval_number(spec.get("x2"), store, ctx);
            let y2 = eval_number(spec.get("y2"), store, ctx);
            let sides = eval_number(spec.get("sides"), store, ctx) as usize;
            let sides = if sides == 0 { 5 } else { sides };
            let fill = resolve_fill_field(spec.get("fill"), store, ctx, default_fill);
            let stroke =
                resolve_stroke_field(spec.get("stroke"), store, ctx, default_stroke);
            let points = regular_polygon_points(x1, y1, x2, y2, sides);
            Some(Element::Polygon(PolygonElem {
                points,
                fill,
                stroke,
                common: CommonProps::default(),
                fill_gradient: None,
                stroke_gradient: None,
            }))
        }

        "star" => {
            // Star inscribed in the axis-aligned bounding box between
            // (x1, y1) and (x2, y2). `points` defaults to 5.
            let x1 = eval_number(spec.get("x1"), store, ctx);
            let y1 = eval_number(spec.get("y1"), store, ctx);
            let x2 = eval_number(spec.get("x2"), store, ctx);
            let y2 = eval_number(spec.get("y2"), store, ctx);
            let points_n = eval_number(spec.get("points"), store, ctx) as usize;
            let points_n = if points_n == 0 { 5 } else { points_n };
            let fill = resolve_fill_field(spec.get("fill"), store, ctx, default_fill);
            let stroke =
                resolve_stroke_field(spec.get("stroke"), store, ctx, default_stroke);
            let pts = star_points(x1, y1, x2, y2, points_n);
            Some(Element::Polygon(PolygonElem {
                points: pts,
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

/// Walk the document layer by layer (including one level of Group
/// nesting) looking for a Path whose command list has an anchor
/// within `radius` of `(x, y)`. Returns (element path, command index).
fn find_path_anchor_near(
    doc: &crate::document::document::Document,
    x: f64, y: f64, radius: f64,
) -> Option<(ElementPath, usize)> {
    for (li, layer) in doc.layers.iter().enumerate() {
        if let Some(children) = layer.children() {
            for (ci, child) in children.iter().enumerate() {
                if let Element::Path(pe) = &**child {
                    if let Some(idx) = anchor_index_near(pe, x, y, radius) {
                        return Some((vec![li, ci], idx));
                    }
                }
                if let Element::Group(g) = &**child {
                    if child.common().locked {
                        continue;
                    }
                    for (gi, gc) in g.children.iter().enumerate() {
                        if let Element::Path(pe) = &**gc {
                            if let Some(idx) = anchor_index_near(pe, x, y, radius) {
                                return Some((vec![li, ci, gi], idx));
                            }
                        }
                    }
                }
            }
        }
    }
    None
}

/// Find the command-index of the anchor on `pe` closest to `(x, y)`
/// within `radius`. Only MoveTo/LineTo/CurveTo count as anchors.
fn anchor_index_near(
    pe: &crate::geometry::element::PathElem,
    x: f64, y: f64, radius: f64,
) -> Option<usize> {
    use crate::geometry::element::PathCommand;
    for (i, cmd) in pe.d.iter().enumerate() {
        let (ax, ay) = match cmd {
            PathCommand::MoveTo { x, y } => (*x, *y),
            PathCommand::LineTo { x, y } => (*x, *y),
            PathCommand::CurveTo { x, y, .. } => (*x, *y),
            _ => continue,
        };
        if (x - ax).hypot(y - ay) <= radius {
            return Some(i);
        }
    }
    None
}

/// Hit-test a bezier control handle on any Path element in the
/// document. Returns (element path, PathElem clone, anchor index,
/// "in" | "out").
fn find_path_handle_near(
    doc: &crate::document::document::Document,
    x: f64, y: f64, radius: f64,
) -> Option<(ElementPath, crate::geometry::element::PathElem, usize, &'static str)> {
    use crate::geometry::element::{path_handle_positions, control_points};
    fn check(
        pe: &crate::geometry::element::PathElem,
        path: &[usize],
        x: f64, y: f64, radius: f64,
    ) -> Option<(ElementPath, crate::geometry::element::PathElem, usize, &'static str)> {
        let anchors = control_points(&Element::Path(pe.clone()));
        for (ai, _) in anchors.iter().enumerate() {
            let (h_in, h_out) = path_handle_positions(&pe.d, ai);
            if let Some((hx, hy)) = h_in {
                if (x - hx).hypot(y - hy) < radius {
                    return Some((path.to_vec(), pe.clone(), ai, "in"));
                }
            }
            if let Some((hx, hy)) = h_out {
                if (x - hx).hypot(y - hy) < radius {
                    return Some((path.to_vec(), pe.clone(), ai, "out"));
                }
            }
        }
        None
    }
    for (li, layer) in doc.layers.iter().enumerate() {
        if let Some(children) = layer.children() {
            for (ci, child) in children.iter().enumerate() {
                if let Element::Path(pe) = &**child {
                    if let Some(r) = check(pe, &[li, ci], x, y, radius) {
                        return Some(r);
                    }
                }
                if let Element::Group(g) = &**child {
                    if child.common().locked { continue; }
                    for (gi, gc) in g.children.iter().enumerate() {
                        if let Element::Path(pe) = &**gc {
                            if let Some(r) = check(pe, &[li, ci, gi], x, y, radius) {
                                return Some(r);
                            }
                        }
                    }
                }
            }
        }
    }
    None
}

/// Hit-test a path anchor using the control_points() enumeration.
/// Returns (element path, PathElem clone, anchor index).
fn find_path_anchor_by_cp_index(
    doc: &crate::document::document::Document,
    x: f64, y: f64, radius: f64,
) -> Option<(ElementPath, crate::geometry::element::PathElem, usize)> {
    use crate::geometry::element::control_points;
    fn check(
        pe: &crate::geometry::element::PathElem,
        path: &[usize],
        x: f64, y: f64, radius: f64,
    ) -> Option<(ElementPath, crate::geometry::element::PathElem, usize)> {
        let anchors = control_points(&Element::Path(pe.clone()));
        for (i, &(ax, ay)) in anchors.iter().enumerate() {
            if (x - ax).hypot(y - ay) < radius {
                return Some((path.to_vec(), pe.clone(), i));
            }
        }
        None
    }
    for (li, layer) in doc.layers.iter().enumerate() {
        if let Some(children) = layer.children() {
            for (ci, child) in children.iter().enumerate() {
                if let Element::Path(pe) = &**child {
                    if let Some(r) = check(pe, &[li, ci], x, y, radius) {
                        return Some(r);
                    }
                }
                if let Element::Group(g) = &**child {
                    if child.common().locked { continue; }
                    for (gi, gc) in g.children.iter().enumerate() {
                        if let Element::Path(pe) = &**gc {
                            if let Some(r) = check(pe, &[li, ci, gi], x, y, radius) {
                                return Some(r);
                            }
                        }
                    }
                }
            }
        }
    }
    None
}

/// Write a serialized Path into a tool-scope field under the
/// anchor_point tool id.
fn set_tool_anchor_point_path(
    store: &mut StateStore,
    key: &str,
    path: &ElementPath,
) {
    let ids: Vec<serde_json::Value> = path
        .iter()
        .map(|&i| serde_json::json!(i as u64))
        .collect();
    store.set_tool(
        "anchor_point", key,
        serde_json::json!({"__path__": ids}),
    );
}

/// Read a serialized Path from the anchor_point tool scope. Returns
/// None when the field is missing or malformed.
fn get_tool_anchor_point_path(
    store: &StateStore, key: &str,
) -> Option<ElementPath> {
    let v = store.get_tool("anchor_point", key);
    let arr = v.as_object()?.get("__path__")?.as_array()?;
    let mut out = Vec::with_capacity(arr.len());
    for n in arr {
        out.push(n.as_u64()? as usize);
    }
    Some(out)
}

/// Implementation of doc.path.probe_anchor_hit.
fn path_probe_anchor_hit(
    model: &Model,
    store: &mut StateStore,
    x: f64, y: f64, radius: f64,
) {
    use crate::geometry::element::is_smooth_point;
    // 1. handle hit
    if let Some((path, _pe, anchor_idx, handle_type)) =
        find_path_handle_near(model.document(), x, y, radius)
    {
        store.set_tool("anchor_point", "mode",
            serde_json::json!("pressed_handle"));
        store.set_tool("anchor_point", "handle_type",
            serde_json::json!(handle_type));
        store.set_tool("anchor_point", "hit_anchor_idx",
            serde_json::json!(anchor_idx));
        set_tool_anchor_point_path(store, "hit_path", &path);
        return;
    }
    // 2. anchor hit — branch on smooth vs corner
    if let Some((path, pe, anchor_idx)) =
        find_path_anchor_by_cp_index(model.document(), x, y, radius)
    {
        let mode = if is_smooth_point(&pe.d, anchor_idx) {
            "pressed_smooth"
        } else {
            "pressed_corner"
        };
        store.set_tool("anchor_point", "mode",
            serde_json::json!(mode));
        store.set_tool("anchor_point", "hit_anchor_idx",
            serde_json::json!(anchor_idx));
        set_tool_anchor_point_path(store, "hit_path", &path);
        return;
    }
    store.set_tool("anchor_point", "mode", serde_json::json!("idle"));
}

/// Implementation of doc.path.commit_anchor_edit.
fn path_commit_anchor_edit(
    model: &mut Model,
    store: &StateStore,
    origin_x: f64, origin_y: f64,
    target_x: f64, target_y: f64,
) {
    use crate::geometry::element::{
        convert_corner_to_smooth, convert_smooth_to_corner,
        move_path_handle_independent, PathElem,
    };
    let mode = store.get_tool("anchor_point", "mode")
        .as_str().unwrap_or("idle").to_string();
    if mode == "idle" {
        return;
    }
    let path = match get_tool_anchor_point_path(store, "hit_path") {
        Some(p) => p,
        None => return,
    };
    let anchor_idx = store
        .get_tool("anchor_point", "hit_anchor_idx")
        .as_u64()
        .unwrap_or(0) as usize;
    let pe: PathElem = match model.document().get_element(&path) {
        Some(Element::Path(pe)) => pe.clone(),
        _ => return,
    };
    match mode.as_str() {
        "pressed_smooth" => {
            model.snapshot();
            let new_pe = convert_smooth_to_corner(&pe, anchor_idx);
            let doc = model.document().replace_element(
                &path, Element::Path(new_pe));
            model.set_document(doc);
        }
        "pressed_corner" => {
            // Only commit when the drag moved past a tiny threshold
            // (matches native's > 1 px guard). A plain click on a
            // corner anchor was historically a no-op.
            let moved = (target_x - origin_x).hypot(target_y - origin_y);
            if moved <= 1.0 {
                return;
            }
            model.snapshot();
            let new_pe = convert_corner_to_smooth(
                &pe, anchor_idx, target_x, target_y);
            let doc = model.document().replace_element(
                &path, Element::Path(new_pe));
            model.set_document(doc);
        }
        "pressed_handle" => {
            let handle_type = store
                .get_tool("anchor_point", "handle_type")
                .as_str().unwrap_or("").to_string();
            let dx = target_x - origin_x;
            let dy = target_y - origin_y;
            if dx.abs() <= 0.5 && dy.abs() <= 0.5 {
                return;
            }
            model.snapshot();
            let new_pe = move_path_handle_independent(
                &pe, anchor_idx, &handle_type, dx, dy);
            let doc = model.document().replace_element(
                &path, Element::Path(new_pe));
            model.set_document(doc);
        }
        _ => {}
    }
}

/// Implementation of doc.path.probe_partial_hit.
fn path_probe_partial_hit(
    model: &mut Model,
    store: &mut StateStore,
    x: f64, y: f64, radius: f64,
    shift: bool,
) {
    use crate::geometry::element::{
        control_point_count, control_points, path_handle_positions,
        PathElem, Visibility,
    };
    // 1. Handle hit on a selected Path element.
    {
        let doc = model.document().clone();
        for es in &doc.selection {
            if let Some(Element::Path(pe)) = doc.get_element(&es.path) {
                let pe: &PathElem = &pe;
                let anchors = control_points(&Element::Path(pe.clone()));
                for (ai, _) in anchors.iter().enumerate() {
                    let (h_in, h_out) = path_handle_positions(&pe.d, ai);
                    if let Some((hx, hy)) = h_in {
                        if (x - hx).hypot(y - hy) < radius {
                            store.set_tool("partial_selection", "mode",
                                serde_json::json!("handle"));
                            store.set_tool("partial_selection", "handle_anchor_idx",
                                serde_json::json!(ai));
                            store.set_tool("partial_selection", "handle_type",
                                serde_json::json!("in"));
                            let ids: Vec<serde_json::Value> = es.path.iter()
                                .map(|&i| serde_json::json!(i as u64))
                                .collect();
                            store.set_tool("partial_selection", "handle_path",
                                serde_json::json!({"__path__": ids}));
                            return;
                        }
                    }
                    if let Some((hx, hy)) = h_out {
                        if (x - hx).hypot(y - hy) < radius {
                            store.set_tool("partial_selection", "mode",
                                serde_json::json!("handle"));
                            store.set_tool("partial_selection", "handle_anchor_idx",
                                serde_json::json!(ai));
                            store.set_tool("partial_selection", "handle_type",
                                serde_json::json!("out"));
                            let ids: Vec<serde_json::Value> = es.path.iter()
                                .map(|&i| serde_json::json!(i as u64))
                                .collect();
                            store.set_tool("partial_selection", "handle_path",
                                serde_json::json!({"__path__": ids}));
                            return;
                        }
                    }
                }
            }
        }
    }

    // 2. Control-point hit on any unlocked element (recurses into groups).
    fn cp_recursive(
        elem: &Element, path: &[usize], ancestor_vis: Visibility,
        x: f64, y: f64, radius: f64,
    ) -> Option<(Vec<usize>, usize)> {
        let eff = std::cmp::min(ancestor_vis, elem.visibility());
        if eff == Visibility::Invisible { return None; }
        if elem.is_group_or_layer() {
            if let Some(children) = elem.children() {
                for (i, child) in children.iter().enumerate().rev() {
                    if child.locked() { continue; }
                    let mut child_path = path.to_vec();
                    child_path.push(i);
                    if let Some(r) = cp_recursive(child, &child_path, eff, x, y, radius) {
                        return Some(r);
                    }
                }
            }
            return None;
        }
        let cps = control_points(elem);
        for (i, &(px, py)) in cps.iter().enumerate() {
            if (x - px).hypot(y - py) < radius {
                return Some((path.to_vec(), i));
            }
        }
        None
    }
    let cp_hit = {
        let doc = model.document();
        let mut hit: Option<(Vec<usize>, usize)> = None;
        'outer: for (li, layer) in doc.layers.iter().enumerate() {
            let layer_vis = layer.visibility();
            if layer_vis == Visibility::Invisible { continue; }
            if let Some(children) = layer.children() {
                for (ci, child) in children.iter().enumerate().rev() {
                    if child.locked() { continue; }
                    let child_vis = std::cmp::min(layer_vis, child.visibility());
                    if child_vis == Visibility::Invisible { continue; }
                    if let Some(r) = cp_recursive(child, &[li, ci], child_vis, x, y, radius) {
                        hit = Some(r);
                        break 'outer;
                    }
                }
            }
        }
        hit
    };

    if let Some((path, cp_idx)) = cp_hit {
        let already_selected = model.document().selection.iter()
            .any(|es| es.path == path && es.kind.contains(cp_idx));
        if !already_selected || shift {
            model.snapshot();
            if shift {
                use crate::document::document::{SelectionKind, SortedCps, ElementSelection};
                let doc = model.document();
                let mut sel = doc.selection.clone();
                if let Some(pos) = sel.iter().position(|es| es.path == path) {
                    let es = &sel[pos];
                    let total = model.document().get_element(&path)
                        .map(control_point_count).unwrap_or(0);
                    let mut cps: Vec<usize> = es.kind.to_sorted(total).iter().collect();
                    if let Some(p) = cps.iter().position(|&i| i == cp_idx) {
                        cps.remove(p);
                    } else {
                        cps.push(cp_idx);
                    }
                    sel[pos] = ElementSelection {
                        path: path.clone(),
                        kind: SelectionKind::Partial(SortedCps::from_iter(cps)),
                    };
                } else {
                    sel.push(ElementSelection::partial(path.clone(), [cp_idx]));
                }
                Controller::set_selection(model, sel);
            } else {
                Controller::select_control_point(model, &path, cp_idx);
            }
        }
        store.set_tool("partial_selection", "mode",
            serde_json::json!("moving_pending"));
        return;
    }

    // 3. No hit — marquee.
    store.set_tool("partial_selection", "mode", serde_json::json!("marquee"));
}

/// Implementation of doc.move_path_handle.
fn path_move_latched_handle(
    model: &mut Model,
    store: &StateStore,
    dx: f64, dy: f64,
) {
    let handle_path_val = store.get_tool("partial_selection", "handle_path");
    let path: Vec<usize> = match handle_path_val.as_object()
        .and_then(|o| o.get("__path__"))
        .and_then(|v| v.as_array())
    {
        Some(arr) => arr.iter()
            .filter_map(|v| v.as_u64().map(|u| u as usize))
            .collect(),
        None => return,
    };
    if path.is_empty() { return; }
    let anchor_idx = store
        .get_tool("partial_selection", "handle_anchor_idx")
        .as_u64().unwrap_or(0) as usize;
    let handle_type = store
        .get_tool("partial_selection", "handle_type")
        .as_str().unwrap_or("").to_string();
    Controller::move_path_handle(model, &path, anchor_idx, &handle_type, dx, dy);
}

/// Implementation of doc.path.erase_at_rect.
fn path_erase_at_rect(
    model: &mut Model,
    last_x: f64, last_y: f64,
    x: f64, y: f64,
    eraser_size: f64,
) {
    use std::rc::Rc;
    use crate::geometry::element::{flatten_path_commands, PathCommand, PathElem};
    use crate::geometry::path_ops::{find_eraser_hit, split_path_at_eraser};

    let doc = model.document().clone();
    let mut new_doc = doc.clone();
    let half = eraser_size;
    let min_x = last_x.min(x) - half;
    let min_y = last_y.min(y) - half;
    let max_x = last_x.max(x) + half;
    let max_y = last_y.max(y) + half;

    let mut changed = false;
    for (li, layer) in doc.layers.iter().enumerate() {
        let children = match layer.children() {
            Some(c) => c,
            None => continue,
        };
        for ci in (0..children.len()).rev() {
            let child = &children[ci];
            let path_elem = match child.as_ref() {
                Element::Path(pe) => pe,
                _ => continue,
            };
            if child.locked() {
                continue;
            }
            let flat = flatten_path_commands(&path_elem.d);
            if flat.len() < 2 {
                continue;
            }
            let hit = match find_eraser_hit(&flat, min_x, min_y, max_x, max_y) {
                Some(h) => h,
                None => continue,
            };
            let bounds = child.bounds();
            if bounds.2 <= eraser_size * 2.0 && bounds.3 <= eraser_size * 2.0 {
                if let Some(layer_children) =
                    new_doc.layers[li].children_mut()
                {
                    layer_children.remove(ci);
                    changed = true;
                }
                continue;
            }
            let is_closed = path_elem
                .d
                .iter()
                .any(|c| matches!(c, PathCommand::ClosePath));
            let results = split_path_at_eraser(&path_elem.d, &hit, is_closed);
            if let Some(layer_children) = new_doc.layers[li].children_mut() {
                layer_children.remove(ci);
                for cmds in results.into_iter().rev() {
                    if cmds.len() >= 2 {
                        let new_path = Element::Path(PathElem {
                            d: cmds,
                            fill: path_elem.fill,
                            stroke: path_elem.stroke,
                            width_points: path_elem.width_points.clone(),
                            common: crate::geometry::element::CommonProps::default(),
                            fill_gradient: None,
                            stroke_gradient: None,
                            stroke_brush: path_elem.stroke_brush.clone(),
                            stroke_brush_overrides: path_elem.stroke_brush_overrides.clone(),
                        });
                        layer_children.insert(ci, Rc::new(new_path));
                    }
                }
                changed = true;
            }
        }
    }
    if changed {
        new_doc.selection.clear();
        model.set_document(new_doc);
    }
}

/// Store a document element-path in a tool scope under `key`.
/// Shared shape with set_tool_anchor_point_path but generic over
/// tool id. Keeps paintbrush and anchor_point separate for now.
fn set_tool_path_generic(
    store: &mut StateStore,
    tool_id: &str,
    key: &str,
    path: &ElementPath,
) {
    let ids: Vec<serde_json::Value> = path
        .iter()
        .map(|&i| serde_json::json!(i as u64))
        .collect();
    store.set_tool(tool_id, key,
        serde_json::json!({"__path__": ids}));
}

/// Read a document element-path stashed by set_tool_path_generic.
/// Returns None when the field is missing or malformed.
fn get_tool_path_generic(
    store: &StateStore,
    tool_id: &str,
    key: &str,
) -> Option<ElementPath> {
    let v = store.get_tool(tool_id, key);
    let arr = v.as_object()?.get("__path__")?.as_array()?;
    let mut out = Vec::with_capacity(arr.len());
    for n in arr {
        out.push(n.as_u64()? as usize);
    }
    Some(out)
}

/// Implementation of doc.paintbrush.edit_start.
///
/// Iterates the document's selected Path elements. For each, flattens
/// the path and finds the closest flat point to (x, y). The selected
/// Path whose closest flat point is nearest — and within `within` px
/// — becomes the edit target; its flat-point index is the entry_idx.
/// Stashes target path + entry_idx + mode='edit' into tool state.
/// No-op when no selected Path is within range.
fn path_paintbrush_edit_start(
    model: &Model,
    store: &mut StateStore,
    x: f64, y: f64, within: f64,
) {
    use crate::geometry::element::Element;
    use crate::geometry::path_ops::flatten_with_cmd_map;

    let within_sq = within * within;
    // (path, entry_idx, dsq)
    let mut best: Option<(ElementPath, usize, f64)> = None;

    for es in &model.document().selection {
        let elem = match model.document().get_element(&es.path) {
            Some(e) => e,
            None => continue,
        };
        if elem.locked() {
            continue;
        }
        let path_elem = match elem {
            Element::Path(pe) => pe,
            _ => continue,
        };
        if path_elem.d.len() < 2 {
            continue;
        }
        let (flat, _cmd_map) = flatten_with_cmd_map(&path_elem.d);
        if flat.is_empty() {
            continue;
        }
        for (i, &(fx, fy)) in flat.iter().enumerate() {
            let dx = fx - x;
            let dy = fy - y;
            let dsq = dx * dx + dy * dy;
            if dsq > within_sq {
                continue;
            }
            match &best {
                Some((_, _, bdsq)) if *bdsq <= dsq => {}
                _ => best = Some((es.path.clone(), i, dsq)),
            }
        }
    }

    if let Some((path, entry_idx, _)) = best {
        store.set_tool("paintbrush", "mode",
            serde_json::json!("edit"));
        set_tool_path_generic(store, "paintbrush", "edit_target_path", &path);
        store.set_tool("paintbrush", "edit_entry_idx",
            serde_json::json!(entry_idx as u64));
    }
}

/// Implementation of doc.paintbrush.edit_commit.
///
/// Reads `edit_target_path` + `edit_entry_idx` from tool state, finds
/// the exit_idx on the target's flat polyline closest to the buffer's
/// last point, and if within range, splices fit_curve output over the
/// target's command range [c0..c1]. Preserves all non-`d` attributes
/// (fill, stroke, stroke-width, stroke_brush, stroke_brush_overrides).
/// No-op when target missing, exit out-of-range, or range degenerate.
fn path_paintbrush_edit_commit(
    model: &mut Model,
    store: &StateStore,
    buffer_name: &str,
    fit_error: f64,
    within: f64,
) {
    use crate::algorithms::fit_curve::fit_curve;
    use crate::geometry::element::{Element, PathCommand, PathElem};
    use crate::geometry::path_ops::{cmd_start_point, flatten_with_cmd_map};

    let Some(target_path) = get_tool_path_generic(
        store, "paintbrush", "edit_target_path") else {
        return;
    };
    let entry_idx = match store.get_tool("paintbrush", "edit_entry_idx") {
        serde_json::Value::Number(n) => n.as_u64().unwrap_or(0) as usize,
        _ => return,
    };

    let drag_points: Vec<(f64, f64)> = super::point_buffers::with_points(
        buffer_name, |pts| pts.to_vec());
    if drag_points.len() < 2 {
        return;
    }

    let doc = model.document().clone();
    let target_elem = match doc.get_element(&target_path) {
        Some(e) => e,
        None => return,
    };
    if target_elem.locked() {
        return;
    }
    let target_path_elem = match target_elem {
        Element::Path(pe) => pe.clone(),
        _ => return,
    };
    if target_path_elem.d.len() < 2 {
        return;
    }

    let (flat, cmd_map) = flatten_with_cmd_map(&target_path_elem.d);
    if flat.is_empty() || entry_idx >= flat.len() {
        return;
    }

    // Exit index: closest flat point to the final drag position.
    let (last_x, last_y) = *drag_points.last().unwrap();
    let within_sq = within * within;
    let mut best: Option<(usize, f64)> = None;
    for (i, &(fx, fy)) in flat.iter().enumerate() {
        let dx = fx - last_x;
        let dy = fy - last_y;
        let dsq = dx * dx + dy * dy;
        match best {
            Some((_, bdsq)) if bdsq <= dsq => {}
            _ => best = Some((i, dsq)),
        }
    }
    let (exit_idx, exit_dsq) = match best {
        Some(t) => t,
        None => return,
    };
    if exit_dsq > within_sq {
        return;
    }
    if exit_idx == entry_idx {
        return; // degenerate range
    }

    let lo_flat = entry_idx.min(exit_idx);
    let hi_flat = entry_idx.max(exit_idx);
    let c0 = cmd_map[lo_flat];
    let c1 = cmd_map[hi_flat];
    if c0 >= c1 || c1 >= target_path_elem.d.len() {
        return;
    }

    // Prepend c0's start-point to the buffer, reversing the drag
    // direction when the user dragged back-to-front so the splice
    // matches the path's flow.
    let start_point = cmd_start_point(&target_path_elem.d, c0);
    let drag_iter: Vec<(f64, f64)> = if exit_idx < entry_idx {
        drag_points.iter().rev().cloned().collect()
    } else {
        drag_points.clone()
    };
    let mut points_to_fit = vec![start_point];
    points_to_fit.extend_from_slice(&drag_iter);
    if points_to_fit.len() < 2 {
        return;
    }

    let segments = fit_curve(&points_to_fit, fit_error);
    if segments.is_empty() {
        return;
    }

    // Splice: target[..c0] + fit output + target[c1+1..]
    let mut new_cmds: Vec<PathCommand> = Vec::new();
    for cmd in &target_path_elem.d[..c0] {
        new_cmds.push(*cmd);
    }
    for seg in &segments {
        new_cmds.push(PathCommand::CurveTo {
            x1: seg.2, y1: seg.3,
            x2: seg.4, y2: seg.5,
            x: seg.6, y: seg.7,
        });
    }
    for cmd in &target_path_elem.d[c1 + 1..] {
        new_cmds.push(*cmd);
    }

    // Preserve all non-`d` attributes per §Edit gesture preservation
    // rules.
    let new_elem = Element::Path(PathElem {
        d: new_cmds,
        fill: target_path_elem.fill,
        stroke: target_path_elem.stroke,
        width_points: target_path_elem.width_points.clone(),
        common: target_path_elem.common.clone(),
        fill_gradient: None,
        stroke_gradient: None,
        stroke_brush: target_path_elem.stroke_brush.clone(),
        stroke_brush_overrides: target_path_elem.stroke_brush_overrides.clone(),
    });
    let new_doc = doc.replace_element(&target_path, new_elem);
    model.set_document(new_doc);
}

// ── Blob Brush commit helpers + effects ──────────────────────

/// Resolve the effective tip shape (size pt, angle deg, roundness
/// percent) at commit time per BLOB_BRUSH_TOOL.md §Runtime tip
/// resolution. When state.stroke_brush points to a Calligraphic
/// library brush, its size/angle/roundness drive the tip (with
/// state.stroke_brush_overrides layered on top). Otherwise the
/// dialog defaults state.blob_brush_* are used.
///
/// Variation modes other than `fixed` are evaluated as the base
/// value in Phase 1 (matches the Paintbrush Phase 1 decision for
/// pressure/tilt/bearing).
fn blob_brush_effective_tip(
    store: &StateStore, ctx: &serde_json::Value,
) -> (f64, f64, f64) {
    let default_size = match eval_expr("state.blob_brush_size", store, ctx) {
        Value::Number(n) => n, _ => 10.0,
    };
    let default_angle = match eval_expr("state.blob_brush_angle", store, ctx) {
        Value::Number(n) => n, _ => 0.0,
    };
    let default_roundness = match eval_expr("state.blob_brush_roundness", store, ctx) {
        Value::Number(n) => n, _ => 100.0,
    };

    let slug = match eval_expr("state.stroke_brush", store, ctx) {
        Value::Str(s) if !s.is_empty() => s,
        _ => return (default_size, default_angle, default_roundness),
    };
    let (lib_id, brush_slug) = match slug.split_once('/') {
        Some(pair) => pair,
        None => return (default_size, default_angle, default_roundness),
    };
    let path = format!("brush_libraries.{}.brushes", lib_id);
    let brushes = match store.get_data_path(&path) {
        serde_json::Value::Array(b) => b,
        _ => return (default_size, default_angle, default_roundness),
    };
    let brush = brushes.iter().find(|b| {
        b.get("slug").and_then(|s| s.as_str()) == Some(brush_slug)
    });
    let brush = match brush {
        Some(b) => b,
        None => return (default_size, default_angle, default_roundness),
    };
    if brush.get("type").and_then(|t| t.as_str()) != Some("calligraphic") {
        return (default_size, default_angle, default_roundness);
    }
    let size = brush.get("size").and_then(|v| v.as_f64()).unwrap_or(default_size);
    let angle = brush.get("angle").and_then(|v| v.as_f64()).unwrap_or(default_angle);
    let roundness = brush.get("roundness").and_then(|v| v.as_f64()).unwrap_or(default_roundness);

    // Apply state.stroke_brush_overrides (compact JSON) if present.
    let overrides_raw = match eval_expr("state.stroke_brush_overrides", store, ctx) {
        Value::Str(s) if !s.is_empty() => s,
        _ => return (size, angle, roundness),
    };
    if let Ok(ovr) = serde_json::from_str::<serde_json::Value>(&overrides_raw) {
        let size = ovr.get("size").and_then(|v| v.as_f64()).unwrap_or(size);
        let angle = ovr.get("angle").and_then(|v| v.as_f64()).unwrap_or(angle);
        let roundness = ovr.get("roundness").and_then(|v| v.as_f64()).unwrap_or(roundness);
        return (size, angle, roundness);
    }
    (size, angle, roundness)
}

/// Generate a 16-segment polygon ring approximating an ellipse
/// centered at (cx, cy) with horizontal axis = size/2, vertical
/// axis = size × roundness/100 / 2, rotated by `angle_deg`.
fn blob_brush_oval_ring(
    cx: f64, cy: f64,
    size: f64, angle_deg: f64, roundness_pct: f64,
) -> Vec<(f64, f64)> {
    const SEGMENTS: usize = 16;
    let rx = size * 0.5;
    let ry = size * (roundness_pct / 100.0) * 0.5;
    let rad = angle_deg * std::f64::consts::PI / 180.0;
    let (cs, sn) = (rad.cos(), rad.sin());
    let mut out = Vec::with_capacity(SEGMENTS);
    for i in 0..SEGMENTS {
        let t = 2.0 * std::f64::consts::PI * (i as f64) / (SEGMENTS as f64);
        let lx = rx * t.cos();
        let ly = ry * t.sin();
        let x = cx + lx * cs - ly * sn;
        let y = cy + lx * sn + ly * cs;
        out.push((x, y));
    }
    out
}

/// Arc-length resample a point sequence at uniform `spacing`
/// intervals, interpolating between input points so consecutive
/// output dabs are at most `spacing` apart regardless of input
/// density. Always keeps the first and last points.
fn blob_brush_arc_length_subsample(
    points: &[(f64, f64)], spacing: f64,
) -> Vec<(f64, f64)> {
    if points.len() < 2 || spacing <= 0.0 {
        return points.to_vec();
    }
    let mut out = vec![points[0]];
    // remaining_to_next: how much arc length must elapse before we
    // emit the next sample.
    let mut remaining = spacing;
    for window in points.windows(2) {
        let (ax, ay) = window[0];
        let (bx, by) = window[1];
        let dx = bx - ax;
        let dy = by - ay;
        let seg_len = (dx * dx + dy * dy).sqrt();
        if seg_len <= 0.0 {
            continue;
        }
        // Walk along this segment, emitting a sample every time
        // the cumulative distance reaches `remaining`.
        let mut t_at = 0.0; // distance already consumed on segment
        while t_at + remaining <= seg_len {
            t_at += remaining;
            let t = t_at / seg_len;
            out.push((ax + dx * t, ay + dy * t));
            remaining = spacing;
        }
        remaining -= seg_len - t_at;
    }
    let tail = *points.last().unwrap();
    if out.last() != Some(&tail) {
        out.push(tail);
    }
    out
}

/// Build the swept region from buffer points and tip params.
/// Subsamples the buffer at ½ × min tip dimension, places an oval
/// at each sample, and unions all ovals via boolean_union.
fn blob_brush_sweep_region(
    points: &[(f64, f64)], tip: (f64, f64, f64),
) -> Vec<Vec<(f64, f64)>> {
    use crate::algorithms::boolean::boolean_union;
    let (size, angle, roundness) = tip;
    let min_dim = size.min(size * roundness / 100.0);
    let spacing = (min_dim * 0.5).max(0.5);
    let samples = blob_brush_arc_length_subsample(points, spacing);
    let mut region: Vec<Vec<(f64, f64)>> = Vec::new();
    for (cx, cy) in samples {
        let oval: Vec<Vec<(f64, f64)>> = vec![blob_brush_oval_ring(
            cx, cy, size, angle, roundness)];
        if region.is_empty() {
            region = oval;
        } else {
            region = boolean_union(&region, &oval);
        }
    }
    region
}

/// Compare two Fill values for merge purposes per BLOB_BRUSH_TOOL.md
/// §Merge condition. Returns true iff both are solid colors with
/// matching sRGB hex and opacity, neither is a gradient or None.
fn blob_brush_fill_matches(a: &Option<Fill>, b: &Option<Fill>) -> bool {
    match (a, b) {
        (Some(fa), Some(fb)) => {
            fa.color.to_hex().to_lowercase() == fb.color.to_hex().to_lowercase()
                && (fa.opacity - fb.opacity).abs() < 1e-9
        }
        _ => false,
    }
}

/// Implementation of doc.blob_brush.commit_painting.
/// See BLOB_BRUSH_TOOL.md §Commit pipeline + §Multi-element merge.
fn blob_brush_commit_painting(
    model: &mut Model, store: &StateStore, ctx: &serde_json::Value,
    buffer_name: &str,
    _fidelity_epsilon: f64, // RDP simplify deferred to follow-up
    merge_only_with_selection: bool,
    _keep_selected: bool, // Selection update deferred; future follow-up
) {
    use crate::algorithms::boolean::boolean_union;
    use crate::geometry::element::{Element, PathElem, CommonProps};
    use crate::geometry::path_ops::{path_to_polygon_set, polygon_set_to_path};

    let points: Vec<(f64, f64)> = super::point_buffers::with_points(
        buffer_name, |p| p.to_vec());
    if points.len() < 2 {
        return;
    }

    let tip = blob_brush_effective_tip(store, ctx);
    let swept = blob_brush_sweep_region(&points, tip);
    if swept.is_empty() {
        return;
    }

    // Resolve fill from state.fill_color.
    let fill_color = match eval_expr("state.fill_color", store, ctx) {
        Value::Color(c) | Value::Str(c) => Color::from_hex(&c),
        _ => None,
    };
    let new_fill = fill_color.map(Fill::new);

    // Find matching existing blob-brush elements in the top-level
    // layer's children. Matching == jas:tool-origin == "blob_brush"
    // + fill matches new_fill + (optional) selection-scoped.
    let doc = model.document().clone();
    let selected: std::collections::HashSet<Vec<usize>> = doc.selection.iter()
        .map(|es| es.path.clone()).collect();
    let mut matches: Vec<Vec<usize>> = Vec::new();
    let mut unified = swept.clone();
    for (li, layer) in doc.layers.iter().enumerate() {
        let children = match layer.children() {
            Some(c) => c,
            None => continue,
        };
        for (ci, child) in children.iter().enumerate() {
            let pe = match &**child {
                Element::Path(pe) => pe,
                _ => continue,
            };
            if pe.common.tool_origin.as_deref() != Some("blob_brush") {
                continue;
            }
            if !blob_brush_fill_matches(&pe.fill, &new_fill) {
                continue;
            }
            let path = vec![li, ci];
            if merge_only_with_selection && !selected.contains(&path) {
                continue;
            }
            let existing = path_to_polygon_set(&pe.d);
            // Cheap reject: union-check via is_empty-after-intersect
            use crate::algorithms::boolean::boolean_intersect;
            let intersection = boolean_intersect(&unified, &existing);
            if intersection.is_empty() {
                continue;
            }
            unified = boolean_union(&unified, &existing);
            matches.push(path);
        }
    }

    // Insertion z = lowest matching (layer, child); default append.
    let (insert_layer, insert_idx) = if matches.is_empty() {
        // Default: append to the top-level layer 0 (first layer).
        (0, None)
    } else {
        // matches is in document order (layer then child); lowest is
        // the earliest entry.
        let lowest = matches[0].clone();
        (lowest[0], Some(lowest[1]))
    };

    let new_d = polygon_set_to_path(&unified);
    if new_d.is_empty() {
        return;
    }
    let mut common = CommonProps::default();
    common.tool_origin = Some("blob_brush".to_string());
    let new_elem = Element::Path(PathElem {
        d: new_d,
        fill: new_fill,
        stroke: None,
        width_points: Vec::new(),
        common,
        fill_gradient: None,
        stroke_gradient: None,
        stroke_brush: None,
        stroke_brush_overrides: None,
    });

    // Build a new document: remove matches (in reverse order so
    // earlier indices stay valid), then insert the unified element.
    let mut new_doc = doc.clone();
    let mut sorted_matches = matches.clone();
    sorted_matches.sort();
    for path in sorted_matches.iter().rev() {
        new_doc = new_doc.delete_element(path);
    }
    let insert_path = if let Some(idx) = insert_idx {
        // Lowest matching (layer, child). After deletions above, the
        // layer may be shorter, but the lowest match's child index
        // is still a valid insertion point (elements above it moved
        // down if deleted, but the lowest itself was deleted too —
        // insert at the same child index in the same layer).
        vec![insert_layer, idx]
    } else {
        // No matches — append as a top-level child of layer 0.
        let child_count = new_doc.layers.get(insert_layer)
            .and_then(|l| l.children().map(|c| c.len()))
            .unwrap_or(0);
        vec![insert_layer, child_count]
    };
    new_doc = new_doc.insert_element_at(&insert_path, new_elem);
    model.set_document(new_doc);
}

/// Implementation of doc.blob_brush.commit_erasing.
/// See BLOB_BRUSH_TOOL.md §Erase gesture → Commit.
fn blob_brush_commit_erasing(
    model: &mut Model, store: &StateStore, ctx: &serde_json::Value,
    buffer_name: &str,
    _fidelity_epsilon: f64,
) {
    use crate::algorithms::boolean::{boolean_intersect, boolean_subtract};
    use crate::geometry::element::{Element, PathElem};
    use crate::geometry::path_ops::{path_to_polygon_set, polygon_set_to_path};

    let points: Vec<(f64, f64)> = super::point_buffers::with_points(
        buffer_name, |p| p.to_vec());
    if points.len() < 2 {
        return;
    }

    let tip = blob_brush_effective_tip(store, ctx);
    let swept = blob_brush_sweep_region(&points, tip);
    if swept.is_empty() {
        return;
    }

    // Per-element subtract; collect updates / deletions.
    let doc = model.document().clone();
    let mut new_doc = doc.clone();
    // Iterate in reverse order so deletions don't invalidate earlier
    // indices.
    for li in (0..doc.layers.len()).rev() {
        let children = match doc.layers[li].children() {
            Some(c) => c,
            None => continue,
        };
        for ci in (0..children.len()).rev() {
            let pe = match &*children[ci] {
                Element::Path(pe) => pe,
                _ => continue,
            };
            if pe.common.tool_origin.as_deref() != Some("blob_brush") {
                continue;
            }
            let existing = path_to_polygon_set(&pe.d);
            let intersection = boolean_intersect(&existing, &swept);
            if intersection.is_empty() {
                continue;
            }
            let remainder = boolean_subtract(&existing, &swept);
            let path = vec![li, ci];
            let new_d = polygon_set_to_path(&remainder);
            if new_d.is_empty() {
                new_doc = new_doc.delete_element(&path);
            } else {
                let new_elem = Element::Path(PathElem {
                    d: new_d,
                    ..pe.clone()
                });
                new_doc = new_doc.replace_element(&path, new_elem);
            }
        }
    }
    model.set_document(new_doc);
}

// ── Magic Wand effect ─────────────────────────────────────

/// Implementation of doc.magic_wand.apply. See
/// MAGIC_WAND_TOOL.md §Predicate + §Eligibility filter.
fn magic_wand_apply(
    model: &mut Model,
    store: &StateStore,
    ctx: &serde_json::Value,
    seed_path: &[usize],
    mode: &str,
) {
    use crate::algorithms::magic_wand::{magic_wand_match, MagicWandConfig};
    use crate::document::controller::Controller;
    use crate::document::document::ElementSelection;

    // Resolve the seed element. If the path doesn't resolve we
    // bail — defensive against stale paths from a now-changed
    // document.
    let doc = model.document().clone();
    let seed_path_vec_for_get = seed_path.to_vec();
    let Some(seed_elem) = doc.get_element(&seed_path_vec_for_get)
        .map(|e| (*e).clone())
    else { return; };

    // Read the nine state.magic_wand_* keys into a config.
    let cfg = read_magic_wand_config(store, ctx);

    // Walk the document and collect every element path that is
    // (a) eligible per §Eligibility filter, and (b) similar to
    // the seed under cfg.
    let mut matches: Vec<Vec<usize>> = Vec::new();
    let seed_path_vec = seed_path.to_vec();
    walk_eligible(&doc, &mut Vec::new(), &mut |path, candidate| {
        // The seed itself is always part of its own wand result,
        // regardless of self-match (e.g. Fill enabled at tol 0
        // on a None-fill seed).
        if path == seed_path_vec.as_slice() {
            matches.push(path.to_vec());
            return;
        }
        if magic_wand_match(&seed_elem, candidate, &cfg) {
            matches.push(path.to_vec());
        }
    });

    let new_set: Vec<ElementSelection> = matches.into_iter()
        .map(ElementSelection::all)
        .collect();

    match mode {
        "add" => {
            let mut existing = doc.selection.clone();
            for es in &new_set {
                if !existing.iter().any(|x| x.path == es.path) {
                    existing.push(es.clone());
                }
            }
            Controller::set_selection(model, existing);
        }
        "subtract" => {
            let to_remove: std::collections::HashSet<Vec<usize>> =
                new_set.iter().map(|es| es.path.clone()).collect();
            let kept: Vec<ElementSelection> = doc.selection.iter()
                .filter(|es| !to_remove.contains(&es.path))
                .cloned()
                .collect();
            Controller::set_selection(model, kept);
        }
        _ => {
            // "replace" (default).
            Controller::set_selection(model, new_set);
        }
    }
}

/// Read the nine `state.magic_wand_*` keys into a MagicWandConfig.
/// Falls back to the spec defaults when a key is missing.
fn read_magic_wand_config(
    store: &StateStore, ctx: &serde_json::Value,
) -> crate::algorithms::magic_wand::MagicWandConfig {
    use crate::algorithms::magic_wand::MagicWandConfig;
    let mut cfg = MagicWandConfig::default();
    let bool_at = |key: &str, fallback: bool| -> bool {
        match eval_expr(&format!("state.{}", key), store, ctx) {
            Value::Bool(b) => b, _ => fallback,
        }
    };
    let num_at = |key: &str, fallback: f64| -> f64 {
        match eval_expr(&format!("state.{}", key), store, ctx) {
            Value::Number(n) => n, _ => fallback,
        }
    };
    cfg.fill_color = bool_at("magic_wand_fill_color", cfg.fill_color);
    cfg.fill_tolerance = num_at("magic_wand_fill_tolerance", cfg.fill_tolerance);
    cfg.stroke_color = bool_at("magic_wand_stroke_color", cfg.stroke_color);
    cfg.stroke_tolerance = num_at("magic_wand_stroke_tolerance", cfg.stroke_tolerance);
    cfg.stroke_weight = bool_at("magic_wand_stroke_weight", cfg.stroke_weight);
    cfg.stroke_weight_tolerance =
        num_at("magic_wand_stroke_weight_tolerance", cfg.stroke_weight_tolerance);
    cfg.opacity = bool_at("magic_wand_opacity", cfg.opacity);
    cfg.opacity_tolerance = num_at("magic_wand_opacity_tolerance", cfg.opacity_tolerance);
    cfg.blending_mode = bool_at("magic_wand_blending_mode", cfg.blending_mode);
    cfg
}

/// Walk the document and invoke `visit(path, element)` for every
/// leaf element that passes the §Eligibility filter — locked /
/// hidden / mask-subtree / Compound Shape operands / containers
/// (Group / Layer themselves) are skipped. Containers descend
/// into their children.
fn walk_eligible<F: FnMut(&[usize], &Element)>(
    doc: &crate::document::document::Document,
    cur_path: &mut Vec<usize>,
    visit: &mut F,
) {
    for (li, layer) in doc.layers.iter().enumerate() {
        cur_path.push(li);
        walk_eligible_in(layer, cur_path, visit);
        cur_path.pop();
    }
}

fn walk_eligible_in<F: FnMut(&[usize], &Element)>(
    elem: &Element, cur_path: &mut Vec<usize>, visit: &mut F,
) {
    use crate::geometry::element::Visibility;
    if elem.locked() { return; }
    if elem.visibility() == Visibility::Invisible { return; }
    match elem {
        Element::Group(g) => {
            for (i, child) in g.children.iter().enumerate() {
                cur_path.push(i);
                walk_eligible_in(child, cur_path, visit);
                cur_path.pop();
            }
        }
        Element::Layer(l) => {
            for (i, child) in l.children.iter().enumerate() {
                cur_path.push(i);
                walk_eligible_in(child, cur_path, visit);
                cur_path.pop();
            }
        }
        // Mask-subtree elements aren't reachable through
        // doc.layers iteration — masks are stored on common.mask
        // and never appear as document children. CompoundShape
        // operands likewise live inside the live-element field
        // and aren't iterated as candidates here. So the implicit
        // policy is: a leaf reachable through doc.layers is
        // eligible.
        _ => {
            visit(cur_path, elem);
        }
    }
}

/// Implementation of doc.path.smooth_at_cursor.
fn path_smooth_at_cursor(
    model: &mut Model,
    x: f64, y: f64,
    radius: f64,
    fit_error: f64,
) {
    use crate::algorithms::fit_curve::fit_curve;
    use crate::geometry::element::{Element, PathCommand, PathElem};
    use crate::geometry::path_ops::{
        cmd_start_point, flatten_with_cmd_map,
    };

    let doc = model.document().clone();
    let mut new_doc = doc.clone();
    let radius_sq = radius * radius;
    let mut changed = false;

    for es in &doc.selection {
        let path = &es.path;
        let elem = match doc.get_element(path) {
            Some(e) => e,
            None => continue,
        };
        let path_elem = match elem {
            Element::Path(pe) => pe,
            _ => continue,
        };
        if elem.locked() {
            continue;
        }
        if path_elem.d.len() < 2 {
            continue;
        }
        let (flat, cmd_map) = flatten_with_cmd_map(&path_elem.d);
        if flat.len() < 2 {
            continue;
        }
        let mut first_hit: Option<usize> = None;
        let mut last_hit: Option<usize> = None;
        for (i, &(px, py)) in flat.iter().enumerate() {
            let dx = px - x;
            let dy = py - y;
            if dx * dx + dy * dy <= radius_sq {
                if first_hit.is_none() {
                    first_hit = Some(i);
                }
                last_hit = Some(i);
            }
        }
        let (first_flat, last_flat) = match (first_hit, last_hit) {
            (Some(f), Some(l)) => (f, l),
            _ => continue,
        };
        let first_cmd = cmd_map[first_flat];
        let last_cmd = cmd_map[last_flat];
        if first_cmd >= last_cmd {
            continue;
        }
        let range_flat: Vec<(f64, f64)> = flat
            .iter()
            .enumerate()
            .filter(|(i, _)| {
                let ci = cmd_map[*i];
                ci >= first_cmd && ci <= last_cmd
            })
            .map(|(_, &p)| p)
            .collect();
        let start_point = cmd_start_point(&path_elem.d, first_cmd);
        let mut points_to_fit = vec![start_point];
        points_to_fit.extend_from_slice(&range_flat);
        if points_to_fit.len() < 2 {
            continue;
        }
        let segments = fit_curve(&points_to_fit, fit_error);
        if segments.is_empty() {
            continue;
        }
        let mut new_cmds: Vec<PathCommand> = Vec::new();
        for cmd in &path_elem.d[..first_cmd] {
            new_cmds.push(*cmd);
        }
        for seg in &segments {
            new_cmds.push(PathCommand::CurveTo {
                x1: seg.2, y1: seg.3,
                x2: seg.4, y2: seg.5,
                x: seg.6, y: seg.7,
            });
        }
        for cmd in &path_elem.d[last_cmd + 1..] {
            new_cmds.push(*cmd);
        }
        if new_cmds.len() >= path_elem.d.len() {
            continue;
        }
        let new_elem = Element::Path(PathElem {
            d: new_cmds,
            fill: path_elem.fill,
            stroke: path_elem.stroke,
            width_points: path_elem.width_points.clone(),
            common: path_elem.common.clone(),
            fill_gradient: None,
            stroke_gradient: None,
            stroke_brush: path_elem.stroke_brush.clone(),
            stroke_brush_overrides: path_elem.stroke_brush_overrides.clone(),
        });
        new_doc = new_doc.replace_element(path, new_elem);
        changed = true;
    }
    if changed {
        model.set_document(new_doc);
    }
}

/// Implementation of doc.path.insert_anchor_on_segment_near.
///
/// For each unlocked Path in the document, computes the best
/// (segment, t) projection and tracks the one with the smallest
/// distance across all paths. If that minimum is within `radius`,
/// snapshots and inserts the anchor there.
fn path_insert_anchor_on_segment_near(
    model: &mut Model, x: f64, y: f64, radius: f64,
) {
    use crate::geometry::path_ops::{closest_segment_and_t, insert_point_in_path};
    use crate::geometry::element::PathElem;

    // Scan all paths, keep the best (element-path, seg_idx, t, distance).
    let mut best: Option<(ElementPath, usize, f64, f64)> = None;
    fn try_path(
        best: &mut Option<(ElementPath, usize, f64, f64)>,
        pe: &PathElem,
        doc_path: &[usize],
        x: f64, y: f64,
    ) {
        if let Some((seg_idx, t)) = closest_segment_and_t(&pe.d, x, y) {
            // Reproject to compute the actual distance for comparison.
            // closest_segment_and_t returned the best, but we need the
            // distance value to compare across paths — re-eval once.
            let mut cx = 0.0_f64;
            let mut cy = 0.0_f64;
            let mut dist = f64::INFINITY;
            for (i, cmd) in pe.d.iter().enumerate() {
                use crate::geometry::element::PathCommand;
                match cmd {
                    PathCommand::MoveTo { x: mx, y: my } => { cx = *mx; cy = *my; }
                    PathCommand::LineTo { x: lx, y: ly } => {
                        if i == seg_idx {
                            let (d, _) =
                                crate::geometry::path_ops::closest_on_line(
                                    cx, cy, *lx, *ly, x, y);
                            dist = d;
                        }
                        cx = *lx; cy = *ly;
                    }
                    PathCommand::CurveTo {
                        x1, y1, x2, y2, x: cxe, y: cye,
                    } => {
                        if i == seg_idx {
                            let (d, _) =
                                crate::geometry::path_ops::closest_on_cubic(
                                    cx, cy, *x1, *y1, *x2, *y2, *cxe, *cye,
                                    x, y);
                            dist = d;
                        }
                        cx = *cxe; cy = *cye;
                    }
                    _ => {}
                }
            }
            match best {
                Some((_, _, _, best_dist)) if *best_dist <= dist => {}
                _ => {
                    *best = Some((doc_path.to_vec(), seg_idx, t, dist));
                }
            }
        }
    }

    {
        let doc = model.document();
        for (li, layer) in doc.layers.iter().enumerate() {
            if let Some(children) = layer.children() {
                for (ci, child) in children.iter().enumerate() {
                    if let Element::Path(pe) = &**child {
                        try_path(&mut best, pe, &[li, ci], x, y);
                    }
                    if let Element::Group(g) = &**child {
                        if child.common().locked { continue; }
                        for (gi, gc) in g.children.iter().enumerate() {
                            if let Element::Path(pe) = &**gc {
                                try_path(&mut best, pe, &[li, ci, gi], x, y);
                            }
                        }
                    }
                }
            }
        }
    }

    let (path, seg_idx, t, dist) = match best {
        Some(b) => b,
        None => return,
    };
    if dist > radius {
        return;
    }
    let pe = match model.document().get_element(&path) {
        Some(Element::Path(pe)) => pe.clone(),
        _ => return,
    };
    model.snapshot();
    let ins = insert_point_in_path(&pe.d, seg_idx, t);
    let new_pe = crate::geometry::element::PathElem {
        d: ins.commands,
        fill: pe.fill,
        stroke: pe.stroke,
        width_points: pe.width_points.clone(),
        common: pe.common.clone(),
        fill_gradient: pe.fill_gradient.clone(),
        stroke_gradient: pe.stroke_gradient.clone(),
        stroke_brush: pe.stroke_brush.clone(),
        stroke_brush_overrides: pe.stroke_brush_overrides.clone(),
    };
    let doc = model.document().replace_element(
        &path, Element::Path(new_pe));
    model.set_document(doc);
}

/// Implementation of doc.path.delete_anchor_near.
fn path_delete_anchor_near(model: &mut Model, x: f64, y: f64, radius: f64) {
    use crate::geometry::path_ops::delete_anchor_from_path;
    let (path, anchor_idx) = match find_path_anchor_near(model.document(), x, y, radius) {
        Some(hit) => hit,
        None => return,
    };
    // Capture the existing PathElem for its non-command fields (fill,
    // stroke, width_points, common).
    let pe = match model.document().get_element(&path) {
        Some(Element::Path(pe)) => pe.clone(),
        _ => return,
    };
    model.snapshot();
    match delete_anchor_from_path(&pe.d, anchor_idx) {
        Some(new_cmds) => {
            let new_pe = crate::geometry::element::PathElem {
                d: new_cmds,
                fill: pe.fill,
                stroke: pe.stroke,
                width_points: pe.width_points.clone(),
                common: pe.common.clone(),
                fill_gradient: pe.fill_gradient.clone(),
                stroke_gradient: pe.stroke_gradient.clone(),
                stroke_brush: pe.stroke_brush.clone(),
                stroke_brush_overrides: pe.stroke_brush_overrides.clone(),
            };
            let new_elem = Element::Path(new_pe);
            let mut doc = model.document().replace_element(&path, new_elem);
            // Reselect: matching Delete-anchor behavior native had.
            doc.selection.retain(|es| es.path != path);
            doc.selection.push(
                crate::document::document::ElementSelection::all(path.clone()),
            );
            model.set_document(doc);
        }
        None => {
            // Path too small — remove the element entirely.
            let doc = model.document().delete_element(&path);
            model.set_document(doc);
        }
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

// ──────────────────────────────────────────────────────────────────
// Transform tools (Scale / Rotate / Shear) apply effects.
// See SCALE_TOOL.md / ROTATE_TOOL.md / SHEAR_TOOL.md §Apply behavior.
// ──────────────────────────────────────────────────────────────────

/// Resolve the active reference point for a transform-tool apply.
///
/// Reads `state.transform_reference_point` — when it's a list of
/// two numbers, returns those as `(rx, ry)`. Otherwise falls back
/// to the union bounding-box center of the current selection.
fn resolve_reference_point(
    model: &Model,
    store: &StateStore,
    ctx: &serde_json::Value,
) -> (f64, f64) {
    use crate::algorithms::align;
    // Custom reference point — Value::List wraps a Vec<serde_json::Value>.
    if let Value::List(items) = eval_expr("state.transform_reference_point", store, ctx) {
        if items.len() >= 2 {
            if let (Some(rx), Some(ry)) = (items[0].as_f64(), items[1].as_f64()) {
                return (rx, ry);
            }
        }
    }
    // Fallback: selection union bbox center.
    let doc = model.document();
    let elements: Vec<&crate::geometry::element::Element> = doc.selection.iter()
        .filter_map(|es| doc.get_element(&es.path))
        .collect();
    if elements.is_empty() {
        return (0.0, 0.0);
    }
    let (x, y, w, h) = align::union_bounds(&elements, align::geometric_bounds);
    (x + w / 2.0, y + h / 2.0)
}

/// Convert drag inputs (press, cursor, ref) to scale factors per
/// SCALE_TOOL.md §Gestures: `sx = (cx-rx)/(px-rx)`,
/// `sy = (cy-ry)/(py-ry)`. Shift forces the signed geometric mean
/// onto both axes (uniform).
fn drag_to_scale_factors(
    px: f64, py: f64, cx: f64, cy: f64, rx: f64, ry: f64, shift: bool,
) -> (f64, f64) {
    let denom_x = px - rx;
    let denom_y = py - ry;
    let sx = if denom_x.abs() < 1e-9 { 1.0 } else { (cx - rx) / denom_x };
    let sy = if denom_y.abs() < 1e-9 { 1.0 } else { (cy - ry) / denom_y };
    if shift {
        let prod = sx * sy;
        let sign = if prod >= 0.0 { 1.0 } else { -1.0 };
        let mag = prod.abs().sqrt();
        let s = sign * mag;
        (s, s)
    } else {
        (sx, sy)
    }
}

/// Convert drag inputs to a rotation angle in degrees per
/// ROTATE_TOOL.md §Gestures: `θ = atan2(c−ref) − atan2(p−ref)`.
/// Shift snaps to the nearest 45° tick.
fn drag_to_rotate_angle(
    px: f64, py: f64, cx: f64, cy: f64, rx: f64, ry: f64, shift: bool,
) -> f64 {
    let theta_press = (py - ry).atan2(px - rx);
    let theta_cursor = (cy - ry).atan2(cx - rx);
    let mut theta_deg = (theta_cursor - theta_press).to_degrees();
    if shift {
        theta_deg = (theta_deg / 45.0).round() * 45.0;
    }
    theta_deg
}

/// Convert drag inputs to (angle_deg, axis, axis_angle_deg) for
/// the Shear tool per SHEAR_TOOL.md §Gestures.
///
/// The press point and reference point together define the shear
/// axis (vector `press − ref`); cursor displacement perpendicular
/// to that axis sets the shear factor `k`. The shear angle in
/// degrees is then `atan(k)`.
///
/// When Shift is held, the axis is constrained to whichever of
/// horizontal / vertical the press → cursor motion is closer to;
/// the axis_angle is unused for those two cases.
fn drag_to_shear_params(
    px: f64, py: f64, cx: f64, cy: f64, rx: f64, ry: f64, shift: bool,
) -> (f64, String, f64) {
    let dx = cx - px;
    let dy = cy - py;

    if shift {
        // Constrain to horizontal or vertical based on dominant
        // motion. Horizontal shear: cursor moves predominantly
        // along x; the shear factor is dx / |press_y − ref_y|.
        if dx.abs() >= dy.abs() {
            let denom = (py - ry).abs().max(1e-9);
            let k = dx / denom;
            return (k.atan().to_degrees(), "horizontal".to_string(), 0.0);
        } else {
            let denom = (px - rx).abs().max(1e-9);
            let k = dy / denom;
            return (k.atan().to_degrees(), "vertical".to_string(), 0.0);
        }
    }

    // Custom-axis: axis = press − ref.
    let ax = px - rx;
    let ay = py - ry;
    let axis_len = (ax * ax + ay * ay).sqrt().max(1e-9);
    let axis_unit_x = ax / axis_len;
    let axis_unit_y = ay / axis_len;
    // Perpendicular (rotated +90°): (-y, x).
    let perp_x = -axis_unit_y;
    let perp_y = axis_unit_x;
    let perp_dist = (cx - px) * perp_x + (cy - py) * perp_y;
    let k = perp_dist / axis_len;
    let axis_angle_deg = ay.atan2(ax).to_degrees();
    (k.atan().to_degrees(), "custom".to_string(), axis_angle_deg)
}

/// Scale apply implementation. Walks the selection (deduped by
/// tree-path identity) and pre-multiplies each element's existing
/// transform with the scale matrix. Honors `state.scale_strokes`
/// (multiplies stroke-width by the geometric mean) and
/// `state.scale_corners` (scales rounded_rect rx / ry).
///
/// `copy: true` is not yet wired (Phase 1.4b); for now the
/// transformation is applied to the original selection regardless.
fn scale_apply(
    model: &mut Model,
    store: &StateStore,
    ctx: &serde_json::Value,
    sx: f64,
    sy: f64,
    _copy: bool,
) {
    use crate::algorithms::transform_apply;
    if (sx - 1.0).abs() < 1e-9 && (sy - 1.0).abs() < 1e-9 {
        return; // Identity — nothing to do.
    }
    let (rx, ry) = resolve_reference_point(model, store, ctx);
    let matrix = transform_apply::scale_matrix(sx, sy, rx, ry);

    let scale_strokes = match eval_expr("state.scale_strokes", store, ctx) {
        Value::Bool(b) => b, _ => true,
    };
    let scale_corners = match eval_expr("state.scale_corners", store, ctx) {
        Value::Bool(b) => b, _ => false,
    };
    let stroke_factor = transform_apply::stroke_width_factor(sx, sy);

    let paths: Vec<Vec<usize>> = model.document().selection.iter()
        .map(|es| es.path.clone()).collect();
    let mut new_doc = model.document().clone();
    for path in &paths {
        if let Some(elem) = new_doc.get_element_mut(path) {
            // Compose: new_matrix * existing.
            let current = elem.common().transform.unwrap_or_default();
            elem.common_mut().transform = Some(matrix.multiply(&current));
            // Stroke width — applied to the in-place stroke field.
            if scale_strokes {
                scale_element_stroke_width(elem, stroke_factor);
            }
            // Rounded-rect corners — only meaningful for RoundedRect-
            // shaped Rect variants (rx / ry on RectElem).
            if scale_corners {
                scale_element_corners(elem, sx.abs(), sy.abs());
            }
        }
    }
    model.set_document(new_doc);
}

/// Rotate apply implementation. Mirrors scale_apply with a rotation
/// matrix; rotation is rigid so there are no stroke / corner
/// options.
fn rotate_apply(
    model: &mut Model,
    store: &StateStore,
    ctx: &serde_json::Value,
    theta_deg: f64,
    _copy: bool,
) {
    use crate::algorithms::transform_apply;
    if theta_deg.abs() < 1e-9 {
        return;
    }
    let (rx, ry) = resolve_reference_point(model, store, ctx);
    let matrix = transform_apply::rotate_matrix(theta_deg, rx, ry);

    let paths: Vec<Vec<usize>> = model.document().selection.iter()
        .map(|es| es.path.clone()).collect();
    let mut new_doc = model.document().clone();
    for path in &paths {
        if let Some(elem) = new_doc.get_element_mut(path) {
            let current = elem.common().transform.unwrap_or_default();
            elem.common_mut().transform = Some(matrix.multiply(&current));
        }
    }
    model.set_document(new_doc);
}

/// Shear apply implementation. Pure shear has determinant 1 so
/// strokes are preserved naturally; there are no stroke or corner
/// options.
fn shear_apply(
    model: &mut Model,
    store: &StateStore,
    ctx: &serde_json::Value,
    angle_deg: f64,
    axis: &str,
    axis_angle_deg: f64,
    _copy: bool,
) {
    use crate::algorithms::transform_apply;
    if angle_deg.abs() < 1e-9 {
        return;
    }
    let (rx, ry) = resolve_reference_point(model, store, ctx);
    let matrix = transform_apply::shear_matrix(angle_deg, axis, axis_angle_deg, rx, ry);

    let paths: Vec<Vec<usize>> = model.document().selection.iter()
        .map(|es| es.path.clone()).collect();
    let mut new_doc = model.document().clone();
    for path in &paths {
        if let Some(elem) = new_doc.get_element_mut(path) {
            let current = elem.common().transform.unwrap_or_default();
            elem.common_mut().transform = Some(matrix.multiply(&current));
        }
    }
    model.set_document(new_doc);
}

/// Multiply the element's stroke-width by `factor` in place.
/// No-op on elements without a stroke.
fn scale_element_stroke_width(
    elem: &mut crate::geometry::element::Element,
    factor: f64,
) {
    use crate::geometry::element::Element;
    let strokes = match elem {
        Element::Line(e) => e.stroke.as_mut(),
        Element::Rect(e) => e.stroke.as_mut(),
        Element::Circle(e) => e.stroke.as_mut(),
        Element::Ellipse(e) => e.stroke.as_mut(),
        Element::Polyline(e) => e.stroke.as_mut(),
        Element::Polygon(e) => e.stroke.as_mut(),
        Element::Path(e) => e.stroke.as_mut(),
        Element::Text(e) => e.stroke.as_mut(),
        Element::TextPath(e) => e.stroke.as_mut(),
        _ => None,
    };
    if let Some(s) = strokes {
        s.width *= factor;
    }
}

/// Scale a rounded_rect's rx / ry by `(sx_abs, sy_abs)`. No-op on
/// other element types — corner radii are only modeled on the
/// RectElem variant via its rx/ry fields. Per SCALE_TOOL.md
/// §Apply behavior, scale_corners is axis-independent (rx scales
/// by |sx|, ry scales by |sy|).
fn scale_element_corners(
    elem: &mut crate::geometry::element::Element,
    sx_abs: f64,
    sy_abs: f64,
) {
    use crate::geometry::element::Element;
    if let Element::Rect(e) = elem {
        e.rx *= sx_abs;
        e.ry *= sy_abs;
    }
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

    // ── doc.add_path_from_buffer (Paintbrush commit) ──
    //
    // Tests cover the Paintbrush-tool commit extensions per
    // PAINTBRUSH_TOOL.md §Fill and stroke and §Gestures:
    // - fill_new_strokes conditional fill
    // - stroke-width commit rule (state, brush.size, overrides)
    // - close flag appending ClosePath
    // - stroke_brush_overrides pass-through
    //
    // Each test seeds a small buffer, runs the effect, and inspects
    // the committed PathElem on the model's empty layer.

    fn seed_buffer_square(name: &str) {
        super::super::point_buffers::clear(name);
        super::super::point_buffers::push(name, 0.0, 0.0);
        super::super::point_buffers::push(name, 10.0, 0.0);
        super::super::point_buffers::push(name, 10.0, 10.0);
        super::super::point_buffers::push(name, 0.0, 10.0);
    }

    fn committed_path(model: &Model) -> &PathElem {
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1, "expected one committed element");
        match &*children[0] {
            Element::Path(p) => p,
            _ => panic!("expected Path"),
        }
    }

    #[test]
    fn add_path_from_buffer_pencil_path_has_no_stroke_brush() {
        // Pencil-style call (no stroke_brush arg) must NOT switch on
        // the Paintbrush stroke rule. Stroke falls back to model
        // defaults via resolve_stroke_field.
        seed_buffer_square("tst1");
        let mut store = StateStore::new();
        let mut model = make_model_with_empty_layer();
        let effects = vec![serde_json::json!({
            "doc.add_path_from_buffer": { "buffer": "tst1" }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let p = committed_path(&model);
        assert!(p.stroke_brush.is_none());
    }

    #[test]
    fn add_path_from_buffer_threads_stroke_brush_slug() {
        seed_buffer_square("tst2");
        let mut store = StateStore::new();
        store.set("stroke_brush", serde_json::json!("mylib/flat_1"));
        store.set("stroke_color", serde_json::json!("#112233"));
        store.set("stroke_width", serde_json::json!(1.0));
        let mut model = make_model_with_empty_layer();
        let effects = vec![serde_json::json!({
            "doc.add_path_from_buffer": {
                "buffer": "tst2",
                "stroke_brush": "state.stroke_brush"
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let p = committed_path(&model);
        assert_eq!(p.stroke_brush.as_deref(), Some("mylib/flat_1"));
    }

    #[test]
    fn add_path_from_buffer_fill_new_strokes_true_uses_state_fill_color() {
        seed_buffer_square("tst3");
        let mut store = StateStore::new();
        store.set("fill_color", serde_json::json!("#abcdef"));
        store.set("stroke_color", serde_json::json!("#000000"));
        store.set("stroke_width", serde_json::json!(1.0));
        let mut model = make_model_with_empty_layer();
        let effects = vec![serde_json::json!({
            "doc.add_path_from_buffer": {
                "buffer": "tst3",
                "stroke_brush": "null",
                "fill_new_strokes": "true"
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let p = committed_path(&model);
        let fill = p.fill.as_ref().expect("expected fill");
        assert_eq!(fill.color, Color::from_hex("#abcdef").unwrap());
    }

    #[test]
    fn add_path_from_buffer_fill_new_strokes_false_produces_no_fill() {
        seed_buffer_square("tst4");
        let mut store = StateStore::new();
        store.set("fill_color", serde_json::json!("#abcdef"));
        store.set("stroke_color", serde_json::json!("#000000"));
        store.set("stroke_width", serde_json::json!(1.0));
        let mut model = make_model_with_empty_layer();
        let effects = vec![serde_json::json!({
            "doc.add_path_from_buffer": {
                "buffer": "tst4",
                "stroke_brush": "null",
                "fill_new_strokes": "false"
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let p = committed_path(&model);
        assert!(p.fill.is_none());
    }

    #[test]
    fn add_path_from_buffer_close_appends_close_path() {
        seed_buffer_square("tst5");
        let mut store = StateStore::new();
        let mut model = make_model_with_empty_layer();
        let effects = vec![serde_json::json!({
            "doc.add_path_from_buffer": {
                "buffer": "tst5",
                "close": "true"
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let p = committed_path(&model);
        assert!(matches!(p.d.last().unwrap(), PathCommand::ClosePath));
    }

    #[test]
    fn add_path_from_buffer_no_close_omits_close_path() {
        seed_buffer_square("tst5b");
        let mut store = StateStore::new();
        let mut model = make_model_with_empty_layer();
        let effects = vec![serde_json::json!({
            "doc.add_path_from_buffer": { "buffer": "tst5b" }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let p = committed_path(&model);
        assert!(!matches!(p.d.last().unwrap(), PathCommand::ClosePath));
    }

    #[test]
    fn add_path_from_buffer_stroke_width_from_state_when_no_brush() {
        seed_buffer_square("tst6");
        let mut store = StateStore::new();
        store.set("stroke_brush", serde_json::Value::Null);
        store.set("stroke_color", serde_json::json!("#000000"));
        store.set("stroke_width", serde_json::json!(3.5));
        let mut model = make_model_with_empty_layer();
        let effects = vec![serde_json::json!({
            "doc.add_path_from_buffer": {
                "buffer": "tst6",
                "stroke_brush": "state.stroke_brush"
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let p = committed_path(&model);
        let s = p.stroke.as_ref().expect("expected stroke");
        assert_eq!(s.width, 3.5);
    }

    #[test]
    fn add_path_from_buffer_stroke_width_from_brush_size() {
        seed_buffer_square("tst7");
        let mut store = StateStore::new();
        store.set("stroke_brush", serde_json::json!("lib_a/cal_1"));
        store.set("stroke_color", serde_json::json!("#000000"));
        store.set("stroke_width", serde_json::json!(1.0));
        // Seed a library brush with size=8.0
        store.set_data_path(
            "brush_libraries.lib_a.brushes",
            serde_json::json!([
                { "slug": "cal_1", "name": "Cal 1", "type": "calligraphic", "size": 8.0 }
            ]),
        );
        let mut model = make_model_with_empty_layer();
        let effects = vec![serde_json::json!({
            "doc.add_path_from_buffer": {
                "buffer": "tst7",
                "stroke_brush": "state.stroke_brush"
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let p = committed_path(&model);
        let s = p.stroke.as_ref().expect("expected stroke");
        assert_eq!(s.width, 8.0);
    }

    #[test]
    fn add_path_from_buffer_stroke_width_falls_back_when_brush_has_no_size() {
        // Art / Pattern brushes have no `size` field — Paintbrush
        // commits use state.stroke_width.
        seed_buffer_square("tst8");
        let mut store = StateStore::new();
        store.set("stroke_brush", serde_json::json!("lib_b/art_1"));
        store.set("stroke_color", serde_json::json!("#000000"));
        store.set("stroke_width", serde_json::json!(2.25));
        store.set_data_path(
            "brush_libraries.lib_b.brushes",
            serde_json::json!([
                { "slug": "art_1", "name": "Art 1", "type": "art" }
            ]),
        );
        let mut model = make_model_with_empty_layer();
        let effects = vec![serde_json::json!({
            "doc.add_path_from_buffer": {
                "buffer": "tst8",
                "stroke_brush": "state.stroke_brush"
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let p = committed_path(&model);
        let s = p.stroke.as_ref().expect("expected stroke");
        assert_eq!(s.width, 2.25);
    }

    #[test]
    fn add_path_from_buffer_stroke_brush_overrides_size_wins() {
        // When stroke_brush_overrides contains `size`, it takes
        // precedence over the library brush's size.
        seed_buffer_square("tst9");
        let mut store = StateStore::new();
        store.set("stroke_brush", serde_json::json!("lib_c/cal_2"));
        store.set("stroke_brush_overrides", serde_json::json!("{\"size\":12.0}"));
        store.set("stroke_color", serde_json::json!("#000000"));
        store.set("stroke_width", serde_json::json!(1.0));
        store.set_data_path(
            "brush_libraries.lib_c.brushes",
            serde_json::json!([
                { "slug": "cal_2", "name": "Cal 2", "type": "calligraphic", "size": 4.0 }
            ]),
        );
        let mut model = make_model_with_empty_layer();
        let effects = vec![serde_json::json!({
            "doc.add_path_from_buffer": {
                "buffer": "tst9",
                "stroke_brush": "state.stroke_brush",
                "stroke_brush_overrides": "state.stroke_brush_overrides"
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let p = committed_path(&model);
        let s = p.stroke.as_ref().expect("expected stroke");
        assert_eq!(s.width, 12.0);
        assert_eq!(p.stroke_brush_overrides.as_deref(), Some("{\"size\":12.0}"));
    }

    // ── doc.paintbrush.edit_start / edit_commit ──
    //
    // Tests cover the Paintbrush edit-gesture per PAINTBRUSH_TOOL.md
    // §Edit gesture: target selection at mousedown, splice at mouseup,
    // preservation rules, edge cases (no-selection, too-far, degenerate).

    fn make_model_with_selected_path() -> Model {
        use crate::geometry::element::{LayerElem, PathElem, StrokeAlign, LineCap, LineJoin, Arrowhead, ArrowAlign};
        use crate::document::document::{Document, ElementSelection};
        // Path: MoveTo(0,0) LineTo(50,0) LineTo(100,0).
        let path_elem = Element::Path(PathElem {
            d: vec![
                PathCommand::MoveTo { x: 0.0, y: 0.0 },
                PathCommand::LineTo { x: 50.0, y: 0.0 },
                PathCommand::LineTo { x: 100.0, y: 0.0 },
            ],
            fill: None,
            stroke: Some(Stroke {
                color: Color::BLACK, width: 1.0,
                linecap: LineCap::Butt, linejoin: LineJoin::Miter,
                miter_limit: 10.0, align: StrokeAlign::Center,
                dash_pattern: [0.0; 6], dash_len: 0,
                start_arrow: Arrowhead::None, end_arrow: Arrowhead::None,
                start_arrow_scale: 100.0, end_arrow_scale: 100.0,
                arrow_align: ArrowAlign::TipAtEnd, opacity: 1.0,
            }),
            width_points: Vec::new(),
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
            stroke_brush: Some("mylib/flat_1".to_string()),
            stroke_brush_overrides: None,
        });
        let layer = Element::Layer(LayerElem {
            name: "L".to_string(),
            children: vec![std::rc::Rc::new(path_elem)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let doc = Document {
            layers: vec![layer],
            selected_layer: 0,
            selection: vec![ElementSelection::all(vec![0, 0])],
            ..Document::default()
        };
        Model::new(doc, None)
    }

    #[test]
    fn edit_start_with_selection_within_range_sets_mode() {
        let mut store = StateStore::new();
        let mut model = make_model_with_selected_path();
        // Press near middle of the path (50, 0). Within 12 px.
        let effects = vec![serde_json::json!({
            "doc.paintbrush.edit_start": {
                "x": 50, "y": 0, "within": 12
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        assert_eq!(store.get_tool("paintbrush", "mode"),
            &serde_json::json!("edit"));
        // entry_idx is some non-zero flat index near the press.
        let entry = store.get_tool("paintbrush", "edit_entry_idx");
        assert!(entry.as_u64().is_some());
    }

    #[test]
    fn edit_start_too_far_from_path_is_noop() {
        let mut store = StateStore::new();
        let mut model = make_model_with_selected_path();
        // Press far from the path.
        let effects = vec![serde_json::json!({
            "doc.paintbrush.edit_start": {
                "x": 500, "y": 500, "within": 12
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        // mode was untouched — default is Null.
        assert_eq!(store.get_tool("paintbrush", "mode"),
            &serde_json::Value::Null);
    }

    #[test]
    fn edit_start_with_empty_selection_is_noop() {
        let mut store = StateStore::new();
        // Empty model, no selection.
        let mut model = make_model_with_empty_layer();
        let effects = vec![serde_json::json!({
            "doc.paintbrush.edit_start": {
                "x": 0, "y": 0, "within": 12
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        assert_eq!(store.get_tool("paintbrush", "mode"),
            &serde_json::Value::Null);
    }

    #[test]
    fn edit_commit_splices_middle_and_preserves_brush() {
        // Scenario: press at (50, 0), drag down to (75, 40), release
        // at (100, 0). Splice replaces the second-line-segment range
        // with a curve that bulges downward. jas:stroke-brush must be
        // preserved.
        let mut store = StateStore::new();
        let mut model = make_model_with_selected_path();

        let effects = vec![serde_json::json!({
            "doc.paintbrush.edit_start": {
                "x": 50, "y": 0, "within": 12
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        assert_eq!(store.get_tool("paintbrush", "mode"),
            &serde_json::json!("edit"));

        super::super::point_buffers::clear("paintbrush");
        super::super::point_buffers::push("paintbrush", 50.0, 0.0);
        super::super::point_buffers::push("paintbrush", 75.0, 40.0);
        super::super::point_buffers::push("paintbrush", 100.0, 0.0);

        let effects = vec![serde_json::json!({
            "doc.paintbrush.edit_commit": {
                "buffer": "paintbrush",
                "fit_error": "4",
                "within": 12
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);

        // Verify path was modified: d should no longer be exactly the
        // 3 original commands (MoveTo + 2 LineTos).
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        let p = match &*children[0] {
            Element::Path(pe) => pe,
            _ => panic!("expected Path"),
        };
        // Preservation: jas:stroke-brush kept.
        assert_eq!(p.stroke_brush.as_deref(), Some("mylib/flat_1"));
        // Splice occurred: the path now contains at least one CurveTo.
        let has_curve = p.d.iter().any(|c| matches!(c, PathCommand::CurveTo {..}));
        assert!(has_curve, "expected splice to introduce at least one CurveTo");
    }

    #[test]
    fn edit_commit_without_edit_start_is_noop() {
        // Without edit_start priming, there's no target/entry_idx in
        // tool state. The commit must gracefully no-op.
        let mut store = StateStore::new();
        let mut model = make_model_with_selected_path();
        let orig_cmds = match &*model.document().layers[0].children().unwrap()[0] {
            Element::Path(pe) => pe.d.clone(),
            _ => panic!(),
        };
        super::super::point_buffers::clear("paintbrush");
        super::super::point_buffers::push("paintbrush", 0.0, 0.0);
        super::super::point_buffers::push("paintbrush", 10.0, 10.0);
        let effects = vec![serde_json::json!({
            "doc.paintbrush.edit_commit": {
                "buffer": "paintbrush",
                "fit_error": "4",
                "within": 12
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let new_cmds = match &*model.document().layers[0].children().unwrap()[0] {
            Element::Path(pe) => pe.d.clone(),
            _ => panic!(),
        };
        assert_eq!(orig_cmds, new_cmds, "edit_commit without target should not modify path");
    }

    #[test]
    fn edit_commit_exit_too_far_aborts() {
        // Edit starts at (50, 0), but the drag ends at (500, 500)
        // which is > within from the target. Commit should abort.
        let mut store = StateStore::new();
        let mut model = make_model_with_selected_path();
        let orig_cmds = match &*model.document().layers[0].children().unwrap()[0] {
            Element::Path(pe) => pe.d.clone(),
            _ => panic!(),
        };
        let effects = vec![serde_json::json!({
            "doc.paintbrush.edit_start": {
                "x": 50, "y": 0, "within": 12
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        assert_eq!(store.get_tool("paintbrush", "mode"),
            &serde_json::json!("edit"));
        super::super::point_buffers::clear("paintbrush");
        super::super::point_buffers::push("paintbrush", 50.0, 0.0);
        super::super::point_buffers::push("paintbrush", 500.0, 500.0);
        let effects = vec![serde_json::json!({
            "doc.paintbrush.edit_commit": {
                "buffer": "paintbrush",
                "fit_error": "4",
                "within": 12
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let new_cmds = match &*model.document().layers[0].children().unwrap()[0] {
            Element::Path(pe) => pe.d.clone(),
            _ => panic!(),
        };
        assert_eq!(orig_cmds, new_cmds,
            "exit beyond within-distance must abort the splice");
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

    // ── Blob Brush commit tests ──

    fn seed_blob_brush_sweep() {
        super::super::point_buffers::clear("blob_brush");
        // Short horizontal sweep; 6 points spanning 50 pt.
        for i in 0..=5 {
            super::super::point_buffers::push(
                "blob_brush", i as f64 * 10.0, 0.0);
        }
    }

    fn blob_brush_state_defaults(store: &mut StateStore) {
        store.set("fill_color", serde_json::json!("#ff0000"));
        store.set("blob_brush_size", serde_json::json!(10.0));
        store.set("blob_brush_angle", serde_json::json!(0.0));
        store.set("blob_brush_roundness", serde_json::json!(100.0));
    }

    #[test]
    fn blob_brush_commit_painting_creates_tagged_path() {
        let mut store = StateStore::new();
        blob_brush_state_defaults(&mut store);
        let mut model = make_model_with_empty_layer();
        seed_blob_brush_sweep();
        let effects = vec![serde_json::json!({
            "doc.blob_brush.commit_painting": {
                "buffer": "blob_brush",
                "fidelity_epsilon": "5.0",
                "merge_only_with_selection": "false",
                "keep_selected": "false"
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        let elem = &*children[0];
        match elem {
            Element::Path(pe) => {
                assert_eq!(pe.common.tool_origin.as_deref(),
                    Some("blob_brush"));
                assert!(pe.fill.is_some());
                assert!(pe.stroke.is_none());
                // At least one MoveTo + multiple LineTos + ClosePath.
                assert!(pe.d.len() >= 3);
            }
            _ => panic!("expected Path"),
        }
    }

    #[test]
    fn blob_brush_commit_erasing_deletes_fully_covered_element() {
        use crate::geometry::element::{LayerElem, PathElem, PathCommand,
            CommonProps, Fill, Color};
        use crate::document::document::Document;

        // Seed doc with a tiny blob-brush square fully inside the
        // sweep's coverage area (sweep = 50pt horizontal, 10pt tip).
        let mut common = CommonProps::default();
        common.tool_origin = Some("blob_brush".to_string());
        let target_path = Element::Path(PathElem {
            d: vec![
                PathCommand::MoveTo { x: 23.0, y: -1.0 },
                PathCommand::LineTo { x: 27.0, y: -1.0 },
                PathCommand::LineTo { x: 27.0, y:  1.0 },
                PathCommand::LineTo { x: 23.0, y:  1.0 },
                PathCommand::ClosePath,
            ],
            fill: Some(Fill::new(Color::from_hex("#ff0000").unwrap())),
            stroke: None,
            width_points: Vec::new(),
            common,
            fill_gradient: None, stroke_gradient: None,
            stroke_brush: None, stroke_brush_overrides: None,
        });
        let layer = Element::Layer(LayerElem {
            name: "L".to_string(),
            children: vec![std::rc::Rc::new(target_path)],
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
        let mut model = Model::new(doc, None);

        let mut store = StateStore::new();
        blob_brush_state_defaults(&mut store);
        seed_blob_brush_sweep();

        let effects = vec![serde_json::json!({
            "doc.blob_brush.commit_erasing": {
                "buffer": "blob_brush",
                "fidelity_epsilon": "5.0"
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);

        // The 20-30 square with tip size 10 swept 0-50: fully covered.
        // Expect the element removed.
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 0, "erasing should delete fully-covered element");
    }

    #[test]
    fn blob_brush_commit_erasing_ignores_non_blob_brush() {
        use crate::geometry::element::{LayerElem, PathElem, PathCommand,
            CommonProps, Fill, Color};
        use crate::document::document::Document;

        // Same square but WITHOUT jas:tool-origin. Erase should skip.
        let target_path = Element::Path(PathElem {
            d: vec![
                PathCommand::MoveTo { x: 20.0, y: -2.0 },
                PathCommand::LineTo { x: 30.0, y: -2.0 },
                PathCommand::LineTo { x: 30.0, y:  2.0 },
                PathCommand::LineTo { x: 20.0, y:  2.0 },
                PathCommand::ClosePath,
            ],
            fill: Some(Fill::new(Color::from_hex("#ff0000").unwrap())),
            stroke: None,
            width_points: Vec::new(),
            common: CommonProps::default(), // tool_origin = None
            fill_gradient: None, stroke_gradient: None,
            stroke_brush: None, stroke_brush_overrides: None,
        });
        let layer = Element::Layer(LayerElem {
            name: "L".to_string(),
            children: vec![std::rc::Rc::new(target_path)],
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
        let mut model = Model::new(doc, None);

        let mut store = StateStore::new();
        blob_brush_state_defaults(&mut store);
        seed_blob_brush_sweep();

        let effects = vec![serde_json::json!({
            "doc.blob_brush.commit_erasing": {
                "buffer": "blob_brush",
                "fidelity_epsilon": "5.0"
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);

        // Element lacks jas:tool-origin → erase skips it entirely.
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1, "erasing must not touch non-blob-brush elements");
    }

    // ── doc.magic_wand.apply ─────────────────────────────────────

    /// Build a model with three rects in one layer:
    ///   - rect 0: red fill
    ///   - rect 1: red fill (matches rect 0 by color)
    ///   - rect 2: blue fill
    fn make_model_three_rects_red_red_blue() -> Model {
        use crate::geometry::element::Stroke;
        let red_fill = Fill::new(Color::rgb(1.0, 0.0, 0.0));
        let blue_fill = Fill::new(Color::rgb(0.0, 0.0, 1.0));
        let stroke = Stroke::new(Color::BLACK, 1.0);
        let make = |fill: Fill, x: f64| Element::Rect(RectElem {
            x, y: 0.0, width: 10.0, height: 10.0,
            rx: 0.0, ry: 0.0,
            fill: Some(fill),
            stroke: Some(stroke.clone()),
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        });
        let layer = Element::Layer(LayerElem {
            name: "L".to_string(),
            children: vec![
                std::rc::Rc::new(make(red_fill.clone(), 0.0)),
                std::rc::Rc::new(make(red_fill, 20.0)),
                std::rc::Rc::new(make(blue_fill, 40.0)),
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

    fn magic_wand_state_defaults(store: &mut StateStore) {
        store.set("magic_wand_fill_color", serde_json::json!(true));
        store.set("magic_wand_fill_tolerance", serde_json::json!(32));
        store.set("magic_wand_stroke_color", serde_json::json!(true));
        store.set("magic_wand_stroke_tolerance", serde_json::json!(32));
        store.set("magic_wand_stroke_weight", serde_json::json!(true));
        store.set("magic_wand_stroke_weight_tolerance", serde_json::json!(5.0));
        store.set("magic_wand_opacity", serde_json::json!(true));
        store.set("magic_wand_opacity_tolerance", serde_json::json!(5));
        store.set("magic_wand_blending_mode", serde_json::json!(false));
    }

    #[test]
    fn magic_wand_replace_selects_seed_plus_similar() {
        let mut model = make_model_three_rects_red_red_blue();
        let mut store = StateStore::new();
        magic_wand_state_defaults(&mut store);
        // Seed = rect 0 (red). Expected: rects 0 and 1 selected;
        // rect 2 (blue) excluded.
        let effects = vec![serde_json::json!({
            "doc.magic_wand.apply": {
                "seed": [0, 0],
                "mode": "'replace'",
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let paths: std::collections::HashSet<Vec<usize>> = model.document()
            .selection.iter().map(|es| es.path.clone()).collect();
        assert!(paths.contains(&vec![0, 0]), "seed always included");
        assert!(paths.contains(&vec![0, 1]), "matching candidate included");
        assert!(!paths.contains(&vec![0, 2]),
                "non-matching candidate excluded");
        assert_eq!(paths.len(), 2);
    }

    #[test]
    fn magic_wand_add_unions_with_existing_selection() {
        let mut model = make_model_three_rects_red_red_blue();
        let mut store = StateStore::new();
        magic_wand_state_defaults(&mut store);
        // Pre-select rect 2 (blue). Wand-add from rect 0 (red).
        // Expected: {2} ∪ {0, 1} = {0, 1, 2}.
        crate::document::controller::Controller::set_selection(
            &mut model, vec![ElementSelection::all(vec![0, 2])]);
        let effects = vec![serde_json::json!({
            "doc.magic_wand.apply": {
                "seed": [0, 0],
                "mode": "'add'",
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let paths: std::collections::HashSet<Vec<usize>> = model.document()
            .selection.iter().map(|es| es.path.clone()).collect();
        assert_eq!(paths.len(), 3);
        assert!(paths.contains(&vec![0, 0]));
        assert!(paths.contains(&vec![0, 1]));
        assert!(paths.contains(&vec![0, 2]));
    }

    #[test]
    fn magic_wand_subtract_removes_wand_result_from_selection() {
        let mut model = make_model_three_rects_red_red_blue();
        let mut store = StateStore::new();
        magic_wand_state_defaults(&mut store);
        // Pre-select all three. Wand-subtract from rect 0 (red).
        // Wand result = {0, 1}. Expected post: {0,1,2} \ {0,1} = {2}.
        crate::document::controller::Controller::set_selection(
            &mut model, vec![
                ElementSelection::all(vec![0, 0]),
                ElementSelection::all(vec![0, 1]),
                ElementSelection::all(vec![0, 2]),
            ]);
        let effects = vec![serde_json::json!({
            "doc.magic_wand.apply": {
                "seed": [0, 0],
                "mode": "'subtract'",
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let paths: std::collections::HashSet<Vec<usize>> = model.document()
            .selection.iter().map(|es| es.path.clone()).collect();
        assert_eq!(paths.len(), 1);
        assert!(paths.contains(&vec![0, 2]));
    }

    #[test]
    fn magic_wand_skips_locked_and_hidden_elements() {
        use crate::geometry::element::{Stroke, Visibility};
        // Three red rects: index 0 normal (seed), 1 locked, 2 hidden.
        // Expected wand result on a replace from index 0: only {0}
        // (the seed itself is always included; 1 and 2 filter out).
        let red_fill = Fill::new(Color::rgb(1.0, 0.0, 0.0));
        let stroke = Stroke::new(Color::BLACK, 1.0);
        let make = |x: f64, locked: bool, vis: Visibility| Element::Rect(RectElem {
            x, y: 0.0, width: 10.0, height: 10.0,
            rx: 0.0, ry: 0.0,
            fill: Some(red_fill.clone()),
            stroke: Some(stroke.clone()),
            common: CommonProps {
                locked, visibility: vis,
                ..CommonProps::default()
            },
            fill_gradient: None,
            stroke_gradient: None,
        });
        let layer = Element::Layer(LayerElem {
            name: "L".to_string(),
            children: vec![
                std::rc::Rc::new(make(0.0, false, Visibility::Preview)),
                std::rc::Rc::new(make(20.0, true, Visibility::Preview)),
                std::rc::Rc::new(make(40.0, false, Visibility::Invisible)),
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
        let mut model = Model::new(doc, None);
        let mut store = StateStore::new();
        magic_wand_state_defaults(&mut store);
        let effects = vec![serde_json::json!({
            "doc.magic_wand.apply": {
                "seed": [0, 0],
                "mode": "'replace'",
            }
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store,
            Some(&mut model), None, None);
        let paths: std::collections::HashSet<Vec<usize>> = model.document()
            .selection.iter().map(|es| es.path.clone()).collect();
        assert_eq!(paths.len(), 1);
        assert!(paths.contains(&vec![0, 0]));
    }
}
