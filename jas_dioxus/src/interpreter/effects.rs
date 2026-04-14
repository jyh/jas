//! Effects interpreter — Rust port of workspace_interpreter/effects.py.
//!
//! Executes effect lists from actions and behaviors. Each effect is a
//! JSON object with a single key identifying the effect type.

use serde_json;
use super::expr::eval;
use super::expr_types::Value;
use super::state_store::StateStore;

/// Execute a list of effects.
pub fn run_effects(
    effects: &[serde_json::Value],
    ctx: &serde_json::Value,
    store: &mut StateStore,
    actions: Option<&serde_json::Value>,
    dialogs: Option<&serde_json::Value>,
) {
    for effect in effects {
        if let serde_json::Value::Object(map) = effect {
            run_one(map, ctx, store, actions, dialogs);
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
    }
}

fn run_one(
    effect: &serde_json::Map<String, serde_json::Value>,
    ctx: &serde_json::Value,
    store: &mut StateStore,
    actions: Option<&serde_json::Value>,
    dialogs: Option<&serde_json::Value>,
) {
    // set: { key: expr, ... }
    if let Some(serde_json::Value::Object(pairs)) = effect.get("set") {
        for (key, expr) in pairs {
            let expr_str = expr.as_str().unwrap_or("");
            let value = eval_expr(expr_str, store, ctx);
            store.set(key, value_to_json(&value));
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

    // if: { condition, then, else }
    if let Some(serde_json::Value::Object(cond)) = effect.get("if") {
        let condition = cond.get("condition")
            .and_then(|v| v.as_str())
            .unwrap_or("false");
        let result = eval_expr(condition, store, ctx);
        if result.to_bool() {
            if let Some(serde_json::Value::Array(then_effects)) = cond.get("then") {
                run_effects(then_effects, ctx, store, actions, dialogs);
            }
        } else if let Some(serde_json::Value::Array(else_effects)) = cond.get("else") {
            run_effects(else_effects, ctx, store, actions, dialogs);
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
                    run_effects(action_effects, &dispatch_ctx, store, actions, dialogs);
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
        return;
    }

    // close_dialog: null or dialog_id
    if effect.contains_key("close_dialog") {
        store.close_dialog();
        return;
    }

    // log: message (debug only)
    if effect.contains_key("log") {
        return;
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
        run_effects(&effects, &serde_json::json!({}), &mut store, None, None);
        assert_eq!(store.get("x"), &serde_json::json!(5));
    }

    #[test]
    fn test_toggle_effect() {
        let mut store = StateStore::new();
        store.set("flag", serde_json::json!(true));
        let effects = vec![serde_json::json!({"toggle": "flag"})];
        run_effects(&effects, &serde_json::json!({}), &mut store, None, None);
        assert_eq!(store.get("flag"), &serde_json::json!(false));
    }

    #[test]
    fn test_swap_effect() {
        let mut store = StateStore::new();
        store.set("a", serde_json::json!("#ff0000"));
        store.set("b", serde_json::json!("#00ff00"));
        let effects = vec![serde_json::json!({"swap": ["a", "b"]})];
        run_effects(&effects, &serde_json::json!({}), &mut store, None, None);
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
        run_effects(&effects, &serde_json::json!({}), &mut store, None, None);
        assert_eq!(store.get("result"), &serde_json::json!("yes"));
    }

    #[test]
    fn test_increment() {
        let mut store = StateStore::new();
        store.set("count", serde_json::json!(5));
        let effects = vec![serde_json::json!({"increment": {"key": "count", "by": 3}})];
        run_effects(&effects, &serde_json::json!({}), &mut store, None, None);
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
        run_effects(&effects, &serde_json::json!({}), &mut store, Some(&actions), None);
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
        run_effects(&effects, &serde_json::json!({}), &mut store, None, Some(&dialogs));
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
                    "color": "param.target == \"fill\" ? state.fill_color : state.stroke_color",
                    "h": "hsb_h(dialog.color)",
                },
                "content": {"type": "container"},
            }
        });
        let effects = vec![serde_json::json!({
            "open_dialog": {"id": "picker", "params": {"target": "\"fill\""}}
        })];
        run_effects(&effects, &serde_json::json!({}), &mut store, None, Some(&dialogs));
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
        run_effects(&effects, &serde_json::json!({}), &mut store, None, None);
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
        run_effects(&effects, &serde_json::json!({}), &mut store, None, Some(&dialogs));
        assert_eq!(store.get_dialog("color"), &serde_json::json!("#aabbcc"));
        // Set global state from dialog
        let effects = vec![serde_json::json!({"set": {"fill_color": "dialog.color"}})];
        run_effects(&effects, &serde_json::json!({}), &mut store, None, None);
        assert_eq!(store.get("fill_color"), &serde_json::json!("#aabbcc"));
    }
}
