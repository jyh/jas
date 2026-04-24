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
            // fill/stroke spec fields are handled like doc.add_element:
            // omitted → model defaults; explicit → resolver parses
            // the Value.
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
                let default_fill = model.default_fill;
                let default_stroke = model.default_stroke;
                let fill = resolve_fill_field(
                    args.get("fill"), store, ctx, default_fill);
                let stroke = resolve_stroke_field(
                    args.get("stroke"), store, ctx, default_stroke);
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
