//! A tile's selection outline: `bind.selected_in` (the accent outline on a
//! `color_swatch` and on the brush-tile `container`).
//!
//! NOT gated on `web`. The web's renderer reads it, and so will the engine's
//! panel plan, which a shell with no expression evaluator draws from.
//! Pinned for every port by `test_fixtures/algorithms/tile_selected_in.json`.

use super::expr;
use super::expr_types::Value;

/// True when the tile is selected. Its identity is its click behaviour's
/// first `select.target`, so authors do not repeat it. The tile is selected
/// when that identity is a member of the `selected_in` list, AND, when that
/// `select` names a `scope` (a panel key) with a `scope_value`, when
/// `panel.<scope>` equals the tile's `scope_value`. The scope clause is the
/// `select` effect's own: it resets the list whenever the scope changes
/// (`effects::apply_select`), so the list's indices belong to that scope
/// alone, and the same index in another library is a different swatch.
pub fn selected_in(el: &serde_json::Value, ctx: &serde_json::Value) -> bool {
    let Some(list_expr) = el.get("bind").and_then(|b| b.get("selected_in")).and_then(|v| v.as_str()) else {
        return false;
    };
    let Some(select) = first_select(el) else { return false };
    let Some(target) = select.get("target").and_then(|v| v.as_str()) else { return false };
    let id_val = expr::eval(target, ctx);
    if !list_contains_value(&expr::eval(list_expr, ctx), Some(&id_val)) {
        return false;
    }
    match select.get("scope").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
        None => true,
        Some(scope) => {
            let scope_value = select.get("scope_value").and_then(|v| v.as_str()).unwrap_or("");
            let current = super::effects::value_to_json(&expr::eval(&format!("panel.{scope}"), ctx));
            let mine = super::effects::value_to_json(&expr::eval(scope_value, ctx));
            !current.is_null() && current == mine
        }
    }
}

/// The click behaviour's first `select` effect that names a `target`.
fn first_select(el: &serde_json::Value) -> Option<&serde_json::Map<String, serde_json::Value>> {
    el.get("behavior")?.as_array()?.iter().find_map(|b| {
        b.get("effects")?.as_array()?.iter().find_map(|e| {
            e.get("select").and_then(|s| s.as_object()).filter(|s| s.get("target").and_then(|v| v.as_str()).is_some())
        })
    })
}

/// Test whether `id` is a member of the list `list`.
fn list_contains_value(list: &Value, id: Option<&Value>) -> bool {
    let Some(id) = id else { return false; };
    let id_json = super::effects::value_to_json(id);
    match list {
        Value::List(items) => items.iter().any(|item| item == &id_json),
        _ => false,
    }
}
