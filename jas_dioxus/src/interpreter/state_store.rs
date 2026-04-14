//! Reactive state store — Rust port of workspace_interpreter/state_store.py.
//!
//! Manages global state, panel-scoped state, and change notifications.
//! Uses callbacks (closures) for reactivity — the Dioxus layer connects
//! these to signal updates.

use std::collections::HashMap;
use serde_json;
use super::expr_types::Value;

/// Reactive state store for global and panel-scoped state.
pub struct StateStore {
    state: HashMap<String, serde_json::Value>,
    panels: HashMap<String, HashMap<String, serde_json::Value>>,
    active_panel: Option<String>,
}

impl StateStore {
    pub fn new() -> Self {
        StateStore {
            state: HashMap::new(),
            panels: HashMap::new(),
            active_panel: None,
        }
    }

    pub fn from_defaults(defaults: &serde_json::Value) -> Self {
        let mut store = Self::new();
        if let serde_json::Value::Object(map) = defaults {
            for (key, defn) in map {
                let default_val = if let serde_json::Value::Object(d) = defn {
                    d.get("default").cloned().unwrap_or(serde_json::Value::Null)
                } else {
                    defn.clone()
                };
                store.state.insert(key.clone(), default_val);
            }
        }
        store
    }

    // ── Global state ─────────────────────────────────────

    pub fn get(&self, key: &str) -> &serde_json::Value {
        self.state.get(key).unwrap_or(&serde_json::Value::Null)
    }

    pub fn set(&mut self, key: &str, value: serde_json::Value) {
        self.state.insert(key.to_string(), value);
    }

    pub fn get_all(&self) -> &HashMap<String, serde_json::Value> {
        &self.state
    }

    // ── Panel state ──────────────────────────────────────

    pub fn init_panel(&mut self, panel_id: &str, defaults: HashMap<String, serde_json::Value>) {
        self.panels.insert(panel_id.to_string(), defaults);
    }

    pub fn get_panel(&self, panel_id: &str, key: &str) -> &serde_json::Value {
        self.panels.get(panel_id)
            .and_then(|p| p.get(key))
            .unwrap_or(&serde_json::Value::Null)
    }

    pub fn set_panel(&mut self, panel_id: &str, key: &str, value: serde_json::Value) {
        if let Some(scope) = self.panels.get_mut(panel_id) {
            scope.insert(key.to_string(), value);
        }
    }

    pub fn set_active_panel(&mut self, panel_id: Option<&str>) {
        self.active_panel = panel_id.map(|s| s.to_string());
    }

    pub fn active_panel_id(&self) -> Option<&str> {
        self.active_panel.as_deref()
    }

    pub fn destroy_panel(&mut self, panel_id: &str) {
        self.panels.remove(panel_id);
        if self.active_panel.as_deref() == Some(panel_id) {
            self.active_panel = None;
        }
    }

    // ── List operations ──────────────────────────────────

    pub fn list_push(
        &mut self, panel_id: &str, key: &str, value: serde_json::Value,
        unique: bool, max_length: Option<usize>,
    ) {
        let scope = match self.panels.get_mut(panel_id) {
            Some(s) => s,
            None => return,
        };
        let lst = scope.entry(key.to_string())
            .or_insert_with(|| serde_json::Value::Array(vec![]));
        if let serde_json::Value::Array(arr) = lst {
            if unique {
                arr.retain(|item| item != &value);
            }
            arr.insert(0, value);
            if let Some(max) = max_length {
                arr.truncate(max);
            }
        }
    }

    // ── Context for expression evaluation ────────────────

    /// Build a serde_json::Value context for the expression evaluator.
    pub fn eval_context(&self) -> serde_json::Value {
        let mut ctx = serde_json::Map::new();

        // Global state
        let state_obj: serde_json::Value = serde_json::Value::Object(
            self.state.iter()
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect()
        );
        ctx.insert("state".to_string(), state_obj);

        // Active panel state
        let panel_state = if let Some(pid) = &self.active_panel {
            if let Some(scope) = self.panels.get(pid) {
                serde_json::Value::Object(
                    scope.iter()
                        .map(|(k, v)| (k.clone(), v.clone()))
                        .collect()
                )
            } else {
                serde_json::Value::Object(serde_json::Map::new())
            }
        } else {
            serde_json::Value::Object(serde_json::Map::new())
        };
        ctx.insert("panel".to_string(), panel_state);

        serde_json::Value::Object(ctx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn get_set() {
        let mut store = StateStore::new();
        store.set("x", serde_json::json!(5));
        assert_eq!(store.get("x"), &serde_json::json!(5));
    }

    #[test]
    fn missing_returns_null() {
        let store = StateStore::new();
        assert_eq!(store.get("missing"), &serde_json::Value::Null);
    }

    #[test]
    fn panel_scoping() {
        let mut store = StateStore::new();
        let mut c = HashMap::new();
        c.insert("mode".to_string(), serde_json::json!("hsb"));
        store.init_panel("color", c);

        let mut s = HashMap::new();
        s.insert("mode".to_string(), serde_json::json!("grid"));
        store.init_panel("swatches", s);

        assert_eq!(store.get_panel("color", "mode"), &serde_json::json!("hsb"));
        assert_eq!(store.get_panel("swatches", "mode"), &serde_json::json!("grid"));
    }

    #[test]
    fn eval_context_includes_panel() {
        let mut store = StateStore::new();
        store.set("fill_color", serde_json::json!("#ff0000"));
        let mut c = HashMap::new();
        c.insert("mode".to_string(), serde_json::json!("hsb"));
        store.init_panel("color", c);
        store.set_active_panel(Some("color"));

        let ctx = store.eval_context();
        assert_eq!(ctx["state"]["fill_color"], serde_json::json!("#ff0000"));
        assert_eq!(ctx["panel"]["mode"], serde_json::json!("hsb"));
    }

    #[test]
    fn list_push_unique() {
        let mut store = StateStore::new();
        let mut c = HashMap::new();
        c.insert("recent".to_string(), serde_json::json!(["a", "b", "c"]));
        store.init_panel("color", c);

        store.list_push("color", "recent", serde_json::json!("b"), true, Some(3));
        let result = store.get_panel("color", "recent");
        assert_eq!(result, &serde_json::json!(["b", "a", "c"]));
    }

    #[test]
    fn destroy_panel() {
        let mut store = StateStore::new();
        let mut c = HashMap::new();
        c.insert("x".to_string(), serde_json::json!(1));
        store.init_panel("test", c);
        store.destroy_panel("test");
        assert_eq!(store.get_panel("test", "x"), &serde_json::Value::Null);
    }
}
