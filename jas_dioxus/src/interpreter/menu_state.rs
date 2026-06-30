//! Shared canonical menu enabled/checked evaluation (TESTING_STRATEGY.md chrome
//! seam).
//!
//! Rust port of `workspace_interpreter/menu_state.py`, the structural sibling of
//! `widget_tree::widget_tree`.  Where the widget-tree pass snapshots the panel
//! widget structure, this pass performs a pure, headless evaluation of every
//! menubar item's `enabled_when` / `checked_when` predicate against a supplied
//! context, producing a language-neutral per-item `{path, action, enabled,
//! checked}` record.  This is the cross-app byte-gate behind the menu's DYNAMIC
//! state: all apps build the same context and evaluate the same bundle
//! expressions to the same booleans, so a menu item that grays out (or shows a
//! check mark) in one app does so in every app.
//!
//! Determinism / portability mirrors `widget_tree`: every field is read straight
//! from the compiled bundle `menubar`, and the ONLY thing evaluated is each
//! item's `enabled_when` / `checked_when` expression (no live widgets).
//!
//! The context namespaces (the live renderers build these from real app state;
//! the corpus seeds them directly):
//!   * `state.tab_count`           — open-document count
//!   * `active_document.{has_selection, selection_count, can_undo, can_redo,
//!       is_modified, has_filename}`
//!   * `workspace.has_saved_layout`
//!   * `panels.<panel_id>`         — bool, the panel's current visibility
//!   * `panes.<pane_id>`           — bool, the pane's current visibility

use serde_json::{json, Value};

use super::expr::eval;

/// Evaluate `expr` against `ctx` and coerce to bool via the shared expression
/// evaluator's truthiness (`eval` never raises — it returns `Value::Null` on
/// error, which `to_bool` reports as `false`).
//
// The cross-app byte-gate (`cross_language_test::algorithm_menu_state_vectors`)
// is the sole caller (this pass is not yet wired into a render path), so it
// reads as dead without the test cfg.
#[allow(dead_code)] // Reachable only through `menu_state` (test-only caller).
fn eval_bool(expr: &str, ctx: &Value) -> bool {
    eval(expr, ctx).to_bool()
}

/// Walk the compiled `menubar` and evaluate each action item's `enabled_when` /
/// `checked_when` against `ctx`.
///
/// Returns a flat pre-order JSON array of `{path, action, enabled, checked}` for
/// every action item.  Separators (bare `"separator"` strings) and the submenu
/// nodes themselves are NOT emitted; a separator still consumes its index, and
/// submenu CHILDREN are walked with an extended path `[m, i, j]` so their
/// predicates (e.g. `workspace.has_saved_layout` on Revert to Saved) are
/// covered.  `enabled` defaults to `true` when there is no `enabled_when`;
/// `checked` is the evaluated bool when `checked_when` is present, else `null`.
//
// The cross-app byte-gate (`cross_language_test::algorithm_menu_state_vectors`)
// is the sole caller (this pass is not yet wired into a render path), so it
// reads as dead without the test cfg.
#[allow(dead_code)]
pub fn menu_state(menubar: &Value, ctx: &Value) -> Value {
    let mut out: Vec<Value> = vec![];
    if let Some(menus) = menubar.as_array() {
        for (m, menu) in menus.iter().enumerate() {
            if let Some(items) = menu.get("items").and_then(|v| v.as_array()) {
                walk(items, &[m as i64], ctx, &mut out);
            }
        }
    }
    Value::Array(out)
}

/// Pre-order walk of one item list under `prefix`. Mirrors the Python
/// reference's `_walk` exactly: bare strings (separators) consume an index but
/// emit nothing; submenu nodes (objects with an `items` key) recurse into their
/// children with the extended path; action items emit a record.
#[allow(dead_code)] // Reachable only through `menu_state` (test-only caller).
fn walk(items: &[Value], prefix: &[i64], ctx: &Value, out: &mut Vec<Value>) {
    for (i, item) in items.iter().enumerate() {
        let mut path = prefix.to_vec();
        path.push(i as i64);
        // A bare "separator" string (or any non-object) consumes its index but
        // emits nothing.
        let obj = match item.as_object() {
            Some(o) => o,
            None => continue,
        };
        // A submenu node: recurse into its children with the extended path; the
        // submenu node itself is not emitted.
        if let Some(children) = obj.get("items").and_then(|v| v.as_array()) {
            walk(children, &path, ctx, out);
            continue;
        }
        let enabled = match obj.get("enabled_when").and_then(|v| v.as_str()) {
            Some(ew) if !ew.is_empty() => eval_bool(ew, ctx),
            _ => true,
        };
        let checked = match obj.get("checked_when").and_then(|v| v.as_str()) {
            Some(cw) if !cw.is_empty() => Value::Bool(eval_bool(cw, ctx)),
            _ => Value::Null,
        };
        let action = obj.get("action").and_then(|v| v.as_str()).unwrap_or("");
        out.push(json!({
            "path": path,
            "action": action,
            "enabled": enabled,
            "checked": checked,
        }));
    }
}
