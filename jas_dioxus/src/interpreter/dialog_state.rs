//! A dialog's state, and how a dialog OPENS: the definition's defaults, the
//! resolved params and the init expressions, evaluated once.
//!
//! NOT web-gated. The web view holds the opened state in a signal
//! (`dialog_view`), and a runner without a window (the action corpus's FFI
//! lane, the engine) needs the same opened state to assert against. Moved
//! out of `dialog_view`, which is behind `feature = "web"`, so there is one
//! open law and not two.

use serde_json;
use std::collections::HashMap;

use super::expr;
use super::expr_types::Value;
use super::workspace::Workspace;

/// A dialog's state once opened. The web view holds it in a signal
/// (`dialog_view::DialogCtx`).
#[derive(Clone, Debug)]
pub struct DialogState {
    /// Dialog ID (matches a key in workspace dialogs).
    pub id: String,
    /// Dialog-local state values (only plain/canonical variables).
    pub state: HashMap<String, serde_json::Value>,
    /// Parameters passed when the dialog was opened.
    pub params: HashMap<String, serde_json::Value>,
    /// Anchor position (page coords) for non-modal popover dialogs.
    pub anchor: Option<(f64, f64)>,
    /// Property definitions from the dialog's state section.
    /// Each entry maps a variable name to its JSON definition
    /// (which may contain "get" and/or "set" expression strings).
    pub props: HashMap<String, serde_json::Value>,
}

impl DialogState {
    /// Get a dialog value, evaluating the getter if present.
    ///
    /// Dialog getters may reference cross-scope bindings (panel,
    /// state, active_document, param) — pass them via `outer`.
    /// When `None`, only dialog-local state is available, which is
    /// fine for simple getters but insufficient for the Artboard
    /// Options reference-point transforms (ARTBOARDS.md §Coordinates
    /// and units).
    pub fn get_value_with_outer(
        &self,
        key: &str,
        outer: Option<&serde_json::Value>,
    ) -> serde_json::Value {
        if let Some(prop) = self.props.get(key) {
            if let Some(get_expr) = prop.get("get").and_then(|v| v.as_str()) {
                let ctx = self.build_local_ctx(outer, None);
                let result = super::expr::eval(get_expr, &ctx);
                return super::effects::value_to_json(&result);
            }
        }
        self.state.get(key).cloned().unwrap_or(serde_json::Value::Null)
    }

    /// Get a dialog value with no outer scope (backwards-compatible).
    pub fn get_value(&self, key: &str) -> serde_json::Value {
        self.get_value_with_outer(key, None)
    }

    /// Set a dialog value, running the setter lambda if present.
    ///
    /// `outer` gives the setter access to panel / state /
    /// active_document / param — needed for Artboard Options
    /// reference-point transforms.
    pub fn set_value_with_outer(
        &mut self,
        key: &str,
        value: serde_json::Value,
        outer: Option<&serde_json::Value>,
    ) {
        if let Some(prop) = self.props.get(key).cloned() {
            if let Some(set_expr) = prop.get("set").and_then(|v| v.as_str()) {
                self._run_setter_pragmatic(set_expr, &value, outer);
                return;
            }
            if prop.get("get").is_some() {
                return; // read-only — has get but no set
            }
        }
        self.state.insert(key.to_string(), value);
    }

    /// Set a dialog value without a cross-scope context (backwards-
    /// compatible).
    pub fn set_value(&mut self, key: &str, value: serde_json::Value) {
        self.set_value_with_outer(key, value, None);
    }

    /// Pragmatic setter: parse "fun param -> body", eval body with param bound,
    /// and intercept Assign nodes to write back to state.
    fn _run_setter_pragmatic(
        &mut self,
        set_expr: &str,
        value: &serde_json::Value,
        outer: Option<&serde_json::Value>,
    ) {
        // Parse the set expression to extract param name and body
        let expr_str = set_expr.trim();
        if !expr_str.starts_with("fun ") {
            return;
        }
        let arrow_pos = match expr_str.find("->") {
            Some(p) => p,
            None => return,
        };
        let param_part = expr_str[4..arrow_pos].trim();
        let param = param_part.trim_matches(|c: char| c == '(' || c == ')').trim();
        let body_str = expr_str[arrow_pos + 2..].trim();

        // Build context: cross-scope bindings (outer) + dialog state
        // + the lambda's param.
        let ctx = self.build_local_ctx(outer, Some((param, value)));

        // Evaluate the body expression. For <- assignments, we use the
        // eval_with_store function that collects assignments.
        let assignments = super::expr::eval_with_store(body_str, &ctx);

        // Apply assignments to state
        for (target, val) in assignments {
            self.state.insert(target, super::effects::value_to_json(&val));
        }
    }

    /// Build the local evaluation context for get/set expressions:
    /// cross-scope bindings (panel / state / active_document / param)
    /// merged into a scope where dialog state fields are in scope
    /// by bare name. An optional lambda-param binding can be added
    /// last to shadow dialog-state fields with the same name.
    fn build_local_ctx(
        &self,
        outer: Option<&serde_json::Value>,
        lambda_param: Option<(&str, &serde_json::Value)>,
    ) -> serde_json::Value {
        let mut local = serde_json::Map::new();
        // Start with any outer namespaces (panel, state,
        // active_document, param). This lets get/set bodies
        // reference things like `panel.reference_point`.
        if let Some(serde_json::Value::Object(m)) = outer {
            for (k, v) in m {
                local.insert(k.clone(), v.clone());
            }
        }
        // Dialog state fields in scope by bare name.
        for (k, v) in &self.state {
            local.insert(k.clone(), v.clone());
        }
        // Lambda param (for set expressions) shadows any collision.
        if let Some((param, value)) = lambda_param {
            local.insert(param.to_string(), value.clone());
        }
        serde_json::Value::Object(local)
    }

    /// Build an eval context with computed getters for all properties.
    /// Cross-scope bindings (panel / state / active_document / param)
    /// are only visible to the getters if `outer` is provided.
    pub fn eval_context_with_outer(
        &self,
        outer: Option<&serde_json::Value>,
    ) -> serde_json::Map<String, serde_json::Value> {
        let mut result = serde_json::Map::new();
        // Start with stored values
        for (k, v) in &self.state {
            result.insert(k.clone(), v.clone());
        }
        // Override with computed getters
        for (k, prop) in &self.props {
            if prop.get("get").and_then(|v| v.as_str()).is_some() {
                result.insert(k.clone(), self.get_value_with_outer(k, outer));
            }
        }
        result
    }

    /// Back-compat: eval context without cross-scope bindings.
    pub fn eval_context(&self) -> serde_json::Map<String, serde_json::Value> {
        self.eval_context_with_outer(None)
    }
}

/// Open dialog `dialog_id`: its definition's state defaults, `raw_params`
/// resolved against `live_state`, then its init expressions, which see
/// `outer_scope`'s top-level keys (e.g. `panel`, `active_document`) beside
/// `state`, `dialog` and `param`. `None` when the workspace does not define
/// the dialog. `dialog_view::open_dialog_with_outer` sets its signal from
/// this; a runner without a window asserts against it.
pub fn build_dialog_state(
    dialog_id: &str,
    raw_params: &serde_json::Map<String, serde_json::Value>,
    live_state: &serde_json::Map<String, serde_json::Value>,
    outer_scope: &serde_json::Value,
) -> Option<DialogState> {
    let ws = match Workspace::load() {
        Some(ws) => ws,
        None => return None,
    };
    let dlg_def = match ws.dialog(dialog_id) {
        Some(d) => d,
        None => return None,
    };

    // Extract state defaults and property definitions (get/set)
    let mut defaults = HashMap::new();
    let mut props = HashMap::new();
    if let Some(serde_json::Value::Object(state_defs)) = dlg_def.get("state") {
        for (key, defn) in state_defs {
            if let serde_json::Value::Object(d) = defn {
                let has_get = d.contains_key("get");
                let has_set = d.contains_key("set");
                if has_get || has_set {
                    props.insert(key.clone(), defn.clone());
                }
                // Only store default for plain vars (no get)
                if !has_get {
                    defaults.insert(key.clone(), d.get("default").cloned().unwrap_or(serde_json::Value::Null));
                }
            } else {
                defaults.insert(key.clone(), defn.clone());
            }
        }
    }

    // Resolve param expressions against current state.
    // Values that look like expressions (contain dots, keywords, operators)
    // are evaluated; plain literal strings are passed through as-is.
    let mut resolved_params = HashMap::new();
    let state_ctx = serde_json::json!({"state": serde_json::Value::Object(live_state.clone())});
    for (k, v) in raw_params {
        if let Some(expr_str) = v.as_str() {
            let looks_like_expr = expr_str.contains('.') || expr_str.contains('(')
                || expr_str.contains(' ');
            if looks_like_expr {
                let result = expr::eval(expr_str, &state_ctx);
                if matches!(result, super::expr_types::Value::Null) {
                    // Expression evaluated to null — keep the original string
                    // (it may have been a pre-resolved concrete value)
                    resolved_params.insert(k.clone(), v.clone());
                } else {
                    resolved_params.insert(k.clone(), value_to_json(&result));
                }
            } else {
                // Plain string literal — pass through directly
                resolved_params.insert(k.clone(), v.clone());
            }
        } else {
            resolved_params.insert(k.clone(), v.clone());
        }
    }

    // Build init context: state + param + dialog (defaults so far)
    let mut dialog_state = defaults.clone();

    // Evaluate init expressions with access to any outer-scope
    // namespaces (panel / active_document) the caller knows about.
    if let Some(serde_json::Value::Object(init_map)) = dlg_def.get("init") {
        for (key, init_expr) in init_map {
            let expr_str = init_expr.as_str().unwrap_or("");
            let dialog_map: serde_json::Map<String, serde_json::Value> =
                dialog_state.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
            let param_map: serde_json::Map<String, serde_json::Value> =
                resolved_params.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
            let mut init_ctx_map = serde_json::Map::new();
            if let serde_json::Value::Object(m) = outer_scope {
                for (k, v) in m {
                    init_ctx_map.insert(k.clone(), v.clone());
                }
            }
            // state / dialog / param always win over outer's same-named
            // namespaces (if any).
            init_ctx_map.insert(
                "state".to_string(),
                serde_json::Value::Object(live_state.clone()),
            );
            init_ctx_map.insert(
                "dialog".to_string(),
                serde_json::Value::Object(dialog_map),
            );
            init_ctx_map.insert(
                "param".to_string(),
                serde_json::Value::Object(param_map),
            );
            let init_ctx = serde_json::Value::Object(init_ctx_map);
            let result = expr::eval(expr_str, &init_ctx);
            dialog_state.insert(key.clone(), value_to_json(&result));
        }
    }

    // Post-init: if _init_color was set, decompose it into color components
    if let Some(color_val) = dialog_state.get("_init_color").cloned() {
        if let Some(hex_str) = color_val.as_str() {
            if !hex_str.is_empty() {
                use super::color_util::*;
                let (r, g, b) = parse_hex(hex_str);
                let (h, s, bri) = rgb_to_hsb(r, g, b);
                let (c, m, y, k) = rgb_to_cmyk(r, g, b);
                let hex = hex_str.trim_start_matches('#').to_lowercase();
                dialog_state.insert("h".into(), serde_json::json!(h));
                dialog_state.insert("s".into(), serde_json::json!(s));
                dialog_state.insert("b".into(), serde_json::json!(bri));
                dialog_state.insert("r".into(), serde_json::json!(r as i32));
                dialog_state.insert("g".into(), serde_json::json!(g as i32));
                dialog_state.insert("bl".into(), serde_json::json!(b as i32));
                dialog_state.insert("c".into(), serde_json::json!(c));
                dialog_state.insert("m".into(), serde_json::json!(m));
                dialog_state.insert("y".into(), serde_json::json!(y));
                dialog_state.insert("k".into(), serde_json::json!(k));
                dialog_state.insert("hex".into(), serde_json::json!(hex));
            }
        }
        dialog_state.remove("_init_color");
    }

    Some(DialogState {
        id: dialog_id.to_string(),
        state: dialog_state,
        params: resolved_params,
        anchor: None,
        props,
    })
}

fn value_to_json(v: &Value) -> serde_json::Value {
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A dialog opens with its params resolved and its init applied: Layer
    /// Options' `init` copies `param.name` into `name`.
    #[test]
    fn a_dialog_opens_with_its_params_and_its_init() {
        let mut params = serde_json::Map::new();
        params.insert("mode".into(), serde_json::json!("create"));
        params.insert("name".into(), serde_json::json!("Lyr"));
        let ds = build_dialog_state("layer_options", &params, &serde_json::Map::new(), &serde_json::Value::Null)
            .expect("layer_options is a dialog");
        assert_eq!(ds.id, "layer_options");
        assert_eq!(ds.params.get("mode"), Some(&serde_json::json!("create")));
        assert_eq!(ds.state.get("name"), Some(&serde_json::json!("Lyr")), "{:?}", ds.state);
        assert_eq!(ds.anchor, None);
    }

    /// An id the workspace does not define opens nothing.
    #[test]
    fn an_unknown_dialog_opens_nothing() {
        let none = serde_json::Map::new();
        assert!(build_dialog_state("zz_no_such_dialog", &none, &none, &serde_json::Value::Null).is_none());
    }
}
