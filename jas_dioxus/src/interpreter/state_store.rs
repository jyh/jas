//! Reactive state store — Rust port of workspace_interpreter/state_store.py.
//!
//! Manages global state, panel-scoped state, and change notifications.
//! Uses callbacks (closures) for reactivity — the Dioxus layer connects
//! these to signal updates.

use std::collections::HashMap;
use serde_json;
use super::expr_types::Value;

/// Reactive state store for global, panel-scoped, and dialog-scoped state.
pub struct StateStore {
    state: HashMap<String, serde_json::Value>,
    panels: HashMap<String, HashMap<String, serde_json::Value>>,
    active_panel: Option<String>,
    dialog: Option<HashMap<String, serde_json::Value>>,
    dialog_id: Option<String>,
    dialog_params: Option<HashMap<String, serde_json::Value>>,
    /// Captured original values of state keys named in the open dialog's
    /// `preview_targets`. Restored on close_dialog unless first cleared
    /// by the `clear_dialog_snapshot` effect (used by OK actions).
    dialog_snapshot: Option<HashMap<String, serde_json::Value>>,
}

impl StateStore {
    pub fn new() -> Self {
        StateStore {
            state: HashMap::new(),
            panels: HashMap::new(),
            active_panel: None,
            dialog: None,
            dialog_id: None,
            dialog_params: None,
            dialog_snapshot: None,
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

    // ── Dialog state ─────────────────────────────────────

    pub fn init_dialog(
        &mut self,
        dialog_id: &str,
        defaults: HashMap<String, serde_json::Value>,
        params: Option<HashMap<String, serde_json::Value>>,
    ) {
        self.dialog_id = Some(dialog_id.to_string());
        self.dialog = Some(defaults);
        self.dialog_params = params;
    }

    pub fn get_dialog(&self, key: &str) -> &serde_json::Value {
        self.dialog.as_ref()
            .and_then(|d| d.get(key))
            .unwrap_or(&serde_json::Value::Null)
    }

    pub fn set_dialog(&mut self, key: &str, value: serde_json::Value) {
        if let Some(ref mut d) = self.dialog {
            d.insert(key.to_string(), value);
        }
    }

    pub fn dialog_id(&self) -> Option<&str> {
        self.dialog_id.as_deref()
    }

    pub fn dialog_params(&self) -> Option<&HashMap<String, serde_json::Value>> {
        self.dialog_params.as_ref()
    }

    pub fn close_dialog(&mut self) {
        self.dialog_id = None;
        self.dialog = None;
        self.dialog_params = None;
    }

    /// Capture the current value of every state key referenced by a
    /// dialog's `preview_targets`. Phase 0 supports only top-level state
    /// keys (no dots in the path); deep paths are silently skipped and
    /// will land alongside their first real consumer in Phase 8/9.
    /// `targets` maps `dialog_state_key` → `state_key`.
    pub fn capture_dialog_snapshot(&mut self, targets: &HashMap<String, String>) {
        let mut snap = HashMap::new();
        for state_key in targets.values() {
            if !state_key.contains('.') {
                snap.insert(state_key.clone(), self.get(state_key).clone());
            }
        }
        self.dialog_snapshot = Some(snap);
    }

    pub fn dialog_snapshot(&self) -> Option<&HashMap<String, serde_json::Value>> {
        self.dialog_snapshot.as_ref()
    }

    pub fn clear_dialog_snapshot(&mut self) {
        self.dialog_snapshot = None;
    }

    pub fn has_dialog_snapshot(&self) -> bool {
        self.dialog_snapshot.is_some()
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
    /// When a dialog is open, includes "dialog" and "param" keys.
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

        // Dialog state
        if let Some(ref dialog) = self.dialog {
            let dialog_obj: serde_json::Value = serde_json::Value::Object(
                dialog.iter()
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect()
            );
            ctx.insert("dialog".to_string(), dialog_obj);
        }

        // Dialog params
        if let Some(ref params) = self.dialog_params {
            let params_obj: serde_json::Value = serde_json::Value::Object(
                params.iter()
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect()
            );
            ctx.insert("param".to_string(), params_obj);
        }

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

    #[test]
    fn dialog_init_and_get() {
        let mut store = StateStore::new();
        let mut defaults = HashMap::new();
        defaults.insert("h".to_string(), serde_json::json!(0));
        defaults.insert("color".to_string(), serde_json::json!("#ffffff"));
        let mut params = HashMap::new();
        params.insert("target".to_string(), serde_json::json!("fill"));
        store.init_dialog("color_picker", defaults, Some(params));
        assert_eq!(store.dialog_id(), Some("color_picker"));
        assert_eq!(store.get_dialog("h"), &serde_json::json!(0));
        assert_eq!(store.get_dialog("color"), &serde_json::json!("#ffffff"));
        assert_eq!(
            store.dialog_params().unwrap().get("target"),
            Some(&serde_json::json!("fill"))
        );
    }

    #[test]
    fn dialog_set() {
        let mut store = StateStore::new();
        let mut defaults = HashMap::new();
        defaults.insert("name".to_string(), serde_json::json!(""));
        store.init_dialog("test", defaults, None);
        store.set_dialog("name", serde_json::json!("hello"));
        assert_eq!(store.get_dialog("name"), &serde_json::json!("hello"));
    }

    #[test]
    fn dialog_close() {
        let mut store = StateStore::new();
        let mut defaults = HashMap::new();
        defaults.insert("x".to_string(), serde_json::json!(1));
        store.init_dialog("test", defaults, None);
        store.close_dialog();
        assert_eq!(store.dialog_id(), None);
        assert_eq!(store.get_dialog("x"), &serde_json::Value::Null);
    }

    #[test]
    fn eval_context_with_dialog() {
        let mut store = StateStore::new();
        store.set("fill_color", serde_json::json!("#ff0000"));
        let mut defaults = HashMap::new();
        defaults.insert("h".to_string(), serde_json::json!(180));
        let mut params = HashMap::new();
        params.insert("target".to_string(), serde_json::json!("fill"));
        store.init_dialog("picker", defaults, Some(params));
        let ctx = store.eval_context();
        assert_eq!(ctx["state"]["fill_color"], serde_json::json!("#ff0000"));
        assert_eq!(ctx["dialog"]["h"], serde_json::json!(180));
        assert_eq!(ctx["param"]["target"], serde_json::json!("fill"));
    }

    #[test]
    fn eval_context_no_dialog() {
        let store = StateStore::new();
        let ctx = store.eval_context();
        assert!(ctx.get("dialog").is_none());
        assert!(ctx.get("param").is_none());
    }

    #[test]
    fn dialog_and_panel_coexist() {
        let mut store = StateStore::new();
        let mut panel = HashMap::new();
        panel.insert("mode".to_string(), serde_json::json!("hsb"));
        store.init_panel("color", panel);
        store.set_active_panel(Some("color"));
        let mut dialog = HashMap::new();
        dialog.insert("h".to_string(), serde_json::json!(270));
        store.init_dialog("picker", dialog, None);
        let ctx = store.eval_context();
        assert_eq!(ctx["panel"]["mode"], serde_json::json!("hsb"));
        assert_eq!(ctx["dialog"]["h"], serde_json::json!(270));
    }

    // ── Preview snapshot/restore (Phase 0) ─────────────────────────
    //
    // capture_dialog_snapshot copies the current value of every state key
    // referenced by a dialog's preview_targets. Phase 0 supports only
    // top-level state keys (no path traversal); deep paths are skipped
    // and will be added in Phase 8/9 alongside their first real consumer.

    #[test]
    fn dialog_snapshot_capture_and_get() {
        let mut store = StateStore::new();
        store.set("left_indent", serde_json::json!(12));
        store.set("right_indent", serde_json::json!(0));
        let mut targets = HashMap::new();
        targets.insert("dlg_left".to_string(), "left_indent".to_string());
        targets.insert("dlg_right".to_string(), "right_indent".to_string());
        store.capture_dialog_snapshot(&targets);
        let snap = store.dialog_snapshot().expect("snapshot should be present");
        assert_eq!(snap.get("left_indent"), Some(&serde_json::json!(12)));
        assert_eq!(snap.get("right_indent"), Some(&serde_json::json!(0)));
        assert!(store.has_dialog_snapshot());
    }

    #[test]
    fn dialog_snapshot_clear_drops_it() {
        let mut store = StateStore::new();
        store.set("x", serde_json::json!(1));
        let mut targets = HashMap::new();
        targets.insert("k".to_string(), "x".to_string());
        store.capture_dialog_snapshot(&targets);
        assert!(store.has_dialog_snapshot());
        store.clear_dialog_snapshot();
        assert!(!store.has_dialog_snapshot());
        assert!(store.dialog_snapshot().is_none());
    }

    #[test]
    fn dialog_snapshot_skips_deep_paths_for_phase0() {
        let mut store = StateStore::new();
        store.set("flat", serde_json::json!(1));
        let mut targets = HashMap::new();
        targets.insert("a".to_string(), "flat".to_string());
        targets.insert("b".to_string(), "selection.deep.path".to_string());
        store.capture_dialog_snapshot(&targets);
        let snap = store.dialog_snapshot().expect("snapshot should be present");
        assert!(snap.contains_key("flat"));
        assert!(!snap.contains_key("selection.deep.path"));
    }
}
