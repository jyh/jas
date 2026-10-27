//! The `preferences` namespace: the bundle's defaults
//! (`workspace/preferences.yaml`, compiled into `workspace.json`) with the
//! user's overrides applied (STATUS-jas item 37). Mirrors the reference's
//! `StateStore.preferences` / `toggle_preference_member`.
//!
//! The overrides are per thread: the app's UI thread (web and desktop) and the
//! engine each run on one, and a test thread sees only its own. Persisting
//! them across launches is the launch half of item 37, not built here.

use std::cell::RefCell;
use std::collections::BTreeMap;

use serde_json::Value;

thread_local! {
    static OVERRIDES: RefCell<BTreeMap<String, Value>> = RefCell::new(BTreeMap::new());
}

fn bundled() -> Value {
    crate::interpreter::workspace::Workspace::load()
        .and_then(|ws| ws.data().get("preferences").cloned())
        .unwrap_or(Value::Null)
}

fn at<'a>(v: &'a Value, key: &str) -> Option<&'a Value> {
    key.split('.').try_fold(v, |node, p| node.get(p))
}

/// The bundle's preferences with this thread's overrides applied; Null when
/// there is no bundle.
pub fn current() -> Value {
    let mut prefs = bundled();
    if prefs.is_null() {
        return prefs;
    }
    OVERRIDES.with(|o| {
        for (key, value) in o.borrow().iter() {
            let mut node = &mut prefs;
            let parts: Vec<&str> = key.split('.').collect();
            for p in &parts[..parts.len() - 1] {
                node = &mut node[*p];
            }
            node[parts[parts.len() - 1]] = value.clone();
        }
    });
    prefs
}

/// Add `value` to the LIST preference at `key` when absent, remove it when
/// present, as an override; an override equal to the bundle's default is
/// dropped. Refuses (false) a key the bundle does not declare as a list.
pub fn toggle_member(key: &str, value: &Value) -> bool {
    let bundle = bundled();
    let Some(Value::Array(default)) = at(&bundle, key) else { return false };
    let Some(Value::Array(current)) = at(&current(), key).cloned() else { return false };
    let next: Vec<Value> = if current.contains(value) {
        current.into_iter().filter(|v| v != value).collect()
    } else {
        current.into_iter().chain(std::iter::once(value.clone())).collect()
    };
    OVERRIDES.with(|o| {
        let mut o = o.borrow_mut();
        if &next == default {
            o.remove(key);
        } else {
            o.insert(key.to_string(), Value::Array(next));
        }
    });
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    fn list(v: &Value) -> Vec<Value> {
        at(v, "brushes.persistent_libraries").and_then(Value::as_array).cloned().unwrap_or_default()
    }

    #[test]
    fn the_persistent_toggle_runs_its_yaml_and_the_menu_check_follows() {
        let ws = crate::interpreter::workspace::Workspace::load().expect("the bundle");
        let effects = ws.actions()["toggle_brush_library_persistent"]["effects"]
            .as_array().cloned().expect("the action's effects");
        let bundled = list(&bundled());
        assert!(!bundled.is_empty(), "the control: the bundle names a persistent library");
        let lib = Value::String("a_library_not_in_the_bundle".into());
        let mut store = crate::interpreter::state_store::StateStore::new();
        let ctx = serde_json::json!({"panel": {"selected_library": lib}});
        crate::interpreter::effects::run_effects(&effects, &ctx, &mut store, None, None, None, None);
        let mut with = bundled.clone();
        with.push(lib.clone());
        assert_eq!(list(&current()), with, "toggled on");
        crate::interpreter::effects::run_effects(&effects, &ctx, &mut store, None, None, None, None);
        assert_eq!(list(&current()), bundled, "toggled off: the override is dropped");
        assert_eq!(list(&super::bundled()), bundled, "the bundle is never written");
    }

    #[test]
    fn the_toggle_refuses_a_key_that_is_not_a_bundled_list() {
        let before = current();
        assert!(!toggle_member("viewport.zoom_step", &serde_json::json!(2)));
        assert!(!toggle_member("brushes.no_such_list", &serde_json::json!("x")));
        assert_eq!(current(), before);
    }
}
