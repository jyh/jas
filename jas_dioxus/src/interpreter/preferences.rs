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

/// `state.brushes_open_libraries` at startup (state.yaml; STATUS-jas item
/// 37): one open, expanded section per slug of
/// `preferences.brushes.persistent_libraries`, in order, or the declared
/// fallback when the list is empty. Mirrors the reference's
/// `open_libraries_at_launch`; shared fixture
/// `test_fixtures/preferences/open_libraries_at_launch.json`.
pub fn open_libraries_at_launch(slugs: &Value) -> Value {
    let mut slugs: Vec<&str> = slugs.as_array()
        .map(|a| a.iter().filter_map(Value::as_str).collect()).unwrap_or_default();
    if slugs.is_empty() {
        slugs.push("default_brushes");
    }
    Value::Array(slugs.into_iter()
        .map(|s| serde_json::json!({"id": s, "collapsed": false})).collect())
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

    /// The launch half (state.yaml: `brushes_open_libraries` is initialised
    /// at startup from the preference), against the shared fixture.
    #[test]
    fn open_libraries_at_launch_matches_the_shared_fixture() {
        let raw = include_str!(concat!("../../../test_fixtures/", "preferences/open_libraries_at_launch.json"));
        let fx: Value = serde_json::from_str(raw).unwrap();
        let cases = fx["cases"].as_array().unwrap();
        assert!(cases.len() >= 4, "the fixture is not vacuous");
        for case in cases {
            assert_eq!(open_libraries_at_launch(&case["persistent_libraries"]), case["expected"], "{}", case["name"]);
        }
    }

    #[test]
    fn the_state_defaults_open_the_current_preferences_libraries() {
        let ws = crate::interpreter::workspace::Workspace::load().expect("the bundle");
        let open = |ws: &crate::interpreter::workspace::Workspace| ws.state_defaults()["brushes_open_libraries"].clone();
        assert_eq!(open(&ws), serde_json::json!([{"id": "default_brushes", "collapsed": false}]), "the bundle");
        let lib = serde_json::json!("a_library_not_in_the_bundle");
        assert!(toggle_member("brushes.persistent_libraries", &lib));
        let got = open(&ws);
        assert!(toggle_member("brushes.persistent_libraries", &lib), "restore");
        assert_eq!(got, serde_json::json!([
            {"id": "default_brushes", "collapsed": false},
            {"id": "a_library_not_in_the_bundle", "collapsed": false}]), "the override is read");
    }

    #[test]
    fn the_toggle_refuses_a_key_that_is_not_a_bundled_list() {
        let before = current();
        assert!(!toggle_member("viewport.zoom_step", &serde_json::json!(2)));
        assert!(!toggle_member("brushes.no_such_list", &serde_json::json!("x")));
        assert_eq!(current(), before);
    }
}
