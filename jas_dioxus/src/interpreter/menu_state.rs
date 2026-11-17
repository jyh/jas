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

use super::expr::{eval, eval_text};

/// Evaluate `expr` against `ctx` and coerce to bool via the shared expression
/// evaluator's truthiness (`eval` never raises — it returns `Value::Null` on
/// error, which `to_bool` reports as `false`).
///
/// LIVE, and deliberately shared rather than re-derived: the panel hamburger
/// menu's check marks resolve through this exact function
/// (`panels::panel_menu::is_checked_from_yaml`), so a panel-menu
/// `checked_when` and a menubar `checked_when` cannot answer the same
/// expression differently. A control beside the instrument validates nothing;
/// this is the instrument.
pub(crate) fn eval_bool(expr: &str, ctx: &Value) -> bool {
    eval(expr, ctx).to_bool()
}

/// Walk the compiled `menubar` and evaluate each action item's `enabled_when` /
/// `checked_when` against `ctx`.
///
/// Returns a flat pre-order JSON array of `{path, action, label, enabled,
/// checked}` for every action item.  Separators (bare `"separator"` strings) and the submenu
/// nodes themselves are NOT emitted; a separator still consumes its index, and
/// submenu CHILDREN are walked with an extended path `[m, i, j]` so their
/// predicates (e.g. `workspace.has_saved_layout` on Revert to Saved) are
/// covered.  `enabled` defaults to `true` when there is no `enabled_when`;
/// `checked` is the evaluated bool when `checked_when` is present, else `null`.
/// `label` is the item's label with each `{{expr}}` region evaluated against
/// `ctx` ([`eval_text`]), so a label that says what its action will do (the
/// Layers panel's "Hide All Layers" / "Show All Layers") is resolved by the
/// walk every port shares; `null` when the item has no label.
//
// ⭐ LIVE SINCE W1 (2026-09-08): `ffi::jas_menu_state` is this pass's FIRST
// production caller in any port, so the `#[allow(dead_code)]` this carried is
// gone. It said "not yet wired into a render path", which was true for two
// months and stopped being true without anything noticing — the allow is what
// would have kept it invisible.
//
// ⚠️ AND THE THING THAT IS STILL OPEN, RECORDED WHERE THE NEXT READER IS: the
// live Dioxus menubar does NOT come through here. It evaluates the same
// predicates independently (`workspace/menu_bar.rs:783`, "Same eval the
// menu_state gate pins") against a ctx it builds itself (`:880-883`). The two
// are pinned to agree only by the corpus, which SEEDS its context — so whether
// a live Dioxus ctx and an engine-assembled ctx produce the same booleans is
// UNMEASURED, and it is now a two-consumer question rather than a one-consumer
// one.
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

/// Walk the compiled `menubar` and emit its STATIC shape — **the half
/// [`menu_state`] deliberately does not emit.**
///
/// ⭐ WHY THIS EXISTS, AND IT IS A GAP THAT WAS INVISIBLE FOR A GOOD REASON.
/// [`menu_state`] returns `{path, action, enabled, checked}` and drops
/// separators and submenu nodes — correctly, because it is the DYNAMIC half and
/// the cross-app byte-gate pins exactly that. Every port that draws a menubar
/// today gets the STATIC half (labels, shortcuts, dividers, submenu titles) by
/// projecting the compiled bundle **in-process**, because every port that draws
/// one is an interpreter: `JasSwift/Sources/Menu/MenuBarModel.swift` says so in
/// its own header, and the Dioxus menubar does the same.
///
/// **The WinUI shell is the first consumer that is NOT an interpreter.** It has
/// no bundle access, and giving it one would be authoring a second menubar —
/// precisely what [`menu_state`] exists to prevent. So the static half needs a
/// pass of its own, and this is it.
///
/// Returns a flat pre-order array over EVERY node — `menu`, `submenu`, `item`
/// and `separator` — carrying `{path, kind, id, label, action, shortcut,
/// dynamic}`. **Nothing here is evaluated**: no `enabled_when`, no
/// `checked_when`, no context. That separation is the design, not an omission —
/// a consumer joins the two passes on `path`, and the join law (every state
/// row's path is an `item` here) is pinned by `ffi.rs`'s W1b arm (a).
///
/// ⛔ A NON-OBJECT THAT IS NOT THE STRING `"separator"` IS EMITTED AS
/// `"unknown"`, NOT GUESSED AT. [`menu_state`] can skip such a node because it
/// emits nothing for it either way; a structure pass cannot, and labelling an
/// unrecognised node `separator` would draw a divider where the bundle meant
/// something else. Measured at `workspace/menubar.yaml`: all 11 bare strings are
/// `"separator"`, so `unknown` is empty today and is a refusal, not a category.
pub fn menu_structure(menubar: &Value) -> Value {
    let mut out: Vec<Value> = vec![];
    if let Some(menus) = menubar.as_array() {
        for (m, menu) in menus.iter().enumerate() {
            let path = vec![m as i64];
            out.push(json!({
                "path": path,
                "kind": "menu",
                "id": menu.get("id").cloned().unwrap_or(Value::Null),
                "label": menu.get("label").cloned().unwrap_or(Value::Null),
                "action": Value::Null,
                "shortcut": Value::Null,
                "dynamic": Value::Null,
            }));
            if let Some(items) = menu.get("items").and_then(|v| v.as_array()) {
                walk_structure(items, &path, &mut out);
            }
        }
    }
    Value::Array(out)
}

/// Pre-order walk of one item list under `prefix`, emitting every node.
///
/// Indexing is IDENTICAL to [`walk`]'s — a separator consumes its index, a
/// submenu's children extend the path — which is what makes the two passes
/// joinable on `path`. Any divergence here is a divergence in the join law, so
/// the two walks live in one file deliberately.
fn walk_structure(items: &[Value], prefix: &[i64], out: &mut Vec<Value>) {
    for (i, item) in items.iter().enumerate() {
        let mut path = prefix.to_vec();
        path.push(i as i64);
        let obj = match item.as_object() {
            Some(o) => o,
            None => {
                let kind = if item.as_str() == Some("separator") {
                    "separator"
                } else {
                    "unknown"
                };
                out.push(json!({
                    "path": path,
                    "kind": kind,
                    "id": Value::Null,
                    "label": Value::Null,
                    "action": Value::Null,
                    "shortcut": Value::Null,
                    "dynamic": Value::Null,
                }));
                continue;
            }
        };
        let id = obj.get("id").cloned().unwrap_or(Value::Null);
        let label = obj.get("label").cloned().unwrap_or(Value::Null);
        if let Some(children) = obj.get("items").and_then(|v| v.as_array()) {
            // A submenu node IS emitted here (menu_state drops it), and it
            // carries `dynamic` because a dynamic submenu's static children are
            // a placeholder the app fills at runtime — a shell that drew them as
            // final would show stale entries with no way to know.
            out.push(json!({
                "path": path,
                "kind": "submenu",
                "id": id,
                "label": label,
                "action": Value::Null,
                "shortcut": Value::Null,
                "dynamic": obj.get("dynamic").cloned().unwrap_or(Value::Null),
            }));
            walk_structure(children, &path, out);
            continue;
        }
        out.push(json!({
            "path": path,
            "kind": "item",
            "id": id,
            "label": label,
            "action": obj.get("action").cloned().unwrap_or(Value::Null),
            "shortcut": obj.get("shortcut").cloned().unwrap_or(Value::Null),
            "dynamic": Value::Null,
        }));
    }
}

/// Pre-order walk of one item list under `prefix`. Mirrors the Python
/// reference's `_walk` exactly: bare strings (separators) consume an index but
/// emit nothing; submenu nodes (objects with an `items` key) recurse into their
/// children with the extended path; action items emit a record.
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
        let label = obj.get("label").and_then(|v| v.as_str())
            .map_or(Value::Null, |l| Value::String(eval_text(l, ctx)));
        out.push(json!({
            "path": path,
            "action": action,
            "label": label,
            "enabled": enabled,
            "checked": checked,
        }));
    }
}

/// The default layout's name. Every session falls back to it, so the
/// Workspace submenu never lists it (Reset to Default reaches it).
pub use crate::workspace::workspace::WORKSPACE_LAYOUT_NAME as DEFAULT_LAYOUT_NAME;

/// The appearance in force when none is stored.
pub const DEFAULT_APPEARANCE_NAME: &str = "dark_gray";

/// The Workspace submenu's layout entries (menubar.yaml `menu_workspace`):
/// every saved layout but the default one, in saved order, labelled by its
/// name, the active one checked, as `[{name, label, checked}]`. Mirrors the
/// reference's `workspace_entries`; pinned by `submenu_entries.json`.
pub fn workspace_entries(saved: &[String], active: &str) -> Value {
    Value::Array(saved.iter().filter(|n| n.as_str() != DEFAULT_LAYOUT_NAME)
        .map(|n| json!({"name": n, "label": n, "checked": n == active}))
        .collect())
}

/// The Appearance submenu's entries (menubar.yaml `menu_appearance`): every
/// available `(name, label)` in order, the active one checked, and no stored
/// appearance means the default one is active. Mirrors the reference's
/// `appearance_entries`; pinned by `submenu_entries.json`.
pub fn appearance_entries(appearances: &[(String, String)], active: Option<&str>) -> Value {
    let current = active.unwrap_or(DEFAULT_APPEARANCE_NAME);
    Value::Array(appearances.iter()
        .map(|(name, label)| json!({"name": name, "label": label, "checked": name == current}))
        .collect())
}

/// A dynamic submenu's rows from its declared `items_from` (the generic form
/// of the two functions above; the brush-library design, A.2). `source` is
/// evaluated against `ctx`; for each element, bound to `as` (default `item`)
/// in a COPY of `ctx`, the row is `{label, action, params, enabled, checked}`:
/// `label` a `{{}}` template, every string `params` value an expression (any
/// other value verbatim), `enabled` true without `enabled_when`, `checked`
/// null without `checked_when`, `action` verbatim. A source that is not a list
/// gives no rows. Mirrors the reference's `items_from_entries` and Swift's
/// `itemsFromEntries`.
pub fn items_from_entries(spec: &Value, ctx: &Value) -> Value {
    let source = spec.get("source").and_then(|v| v.as_str()).unwrap_or("null");
    let elements = match eval(source, ctx) {
        super::expr_types::Value::List(items) => items,
        _ => return json!([]),
    };
    let name = spec.get("as").and_then(|v| v.as_str()).filter(|s| !s.is_empty()).unwrap_or("item");
    let empty = serde_json::Map::new();
    let item = spec.get("item").and_then(|v| v.as_object()).unwrap_or(&empty);
    let mut rows = Vec::new();
    for element in elements {
        let mut bound = ctx.as_object().cloned().unwrap_or_default();
        bound.insert(name.to_string(), element);
        let bound = Value::Object(bound);
        let label = item.get("label").and_then(|v| v.as_str())
            .map_or(Value::Null, |l| Value::String(eval_text(l, &bound)));
        let params: serde_json::Map<String, Value> = item.get("params").and_then(|v| v.as_object())
            .map(|p| p.iter().map(|(k, v)| {
                let resolved = match v.as_str() {
                    Some(expr) => super::effects::value_to_json(&eval(expr, &bound)),
                    None => v.clone(),
                };
                (k.clone(), resolved)
            }).collect())
            .unwrap_or_default();
        let enabled = match item.get("enabled_when").and_then(|v| v.as_str()) {
            Some(ew) if !ew.is_empty() => eval_bool(ew, &bound),
            _ => true,
        };
        let checked = match item.get("checked_when").and_then(|v| v.as_str()) {
            Some(cw) if !cw.is_empty() => Value::Bool(eval_bool(cw, &bound)),
            _ => Value::Null,
        };
        rows.push(json!({
            "label": label,
            "action": item.get("action").and_then(|v| v.as_str()).unwrap_or(""),
            "params": params,
            "enabled": enabled,
            "checked": checked,
        }));
    }
    Value::Array(rows)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // ── items_from (the brush-library design, A.2) ──
    // Row for row with the reference's test_menu_items_from.py and Swift's
    // MenuItemsFromTests.

    fn items_from_spec() -> Value {
        json!({
            "source": "keys(data.brush_libraries)",
            "as": "lib",
            "item": {
                "label": "{{data.brush_libraries[lib].name}}",
                "action": "toggle_brush_library_open",
                "params": {"library": "lib"},
                "checked_when": "any(panel.open_libraries, fun o -> o.id == lib)",
            },
        })
    }

    fn items_from_ctx() -> Value {
        json!({
            "data": {"brush_libraries": {
                "zeta": {"name": "Zeta Brushes"},
                "default_brushes": {"name": "Default Brushes"},
            }},
            "panel": {"open_libraries": [{"id": "default_brushes", "collapsed": false}]},
        })
    }

    #[test]
    fn items_from_gives_one_row_per_source_element_in_source_order() {
        let rows = items_from_entries(&items_from_spec(), &items_from_ctx());
        assert_eq!(rows, json!([
            {"label": "Default Brushes", "action": "toggle_brush_library_open",
             "params": {"library": "default_brushes"}, "enabled": true, "checked": true},
            {"label": "Zeta Brushes", "action": "toggle_brush_library_open",
             "params": {"library": "zeta"}, "enabled": true, "checked": false},
        ]));
        // The control: the two rows' `checked` differ, so a predicate
        // evaluated once (not per element) cannot pass the arm above.
        assert_ne!(rows[0]["checked"], rows[1]["checked"]);
    }

    #[test]
    fn items_from_evaluates_enabled_when_per_element() {
        let mut spec = items_from_spec();
        spec["item"]["enabled_when"] = json!("lib != \"zeta\"");
        let rows = items_from_entries(&spec, &items_from_ctx());
        assert_eq!([rows[0]["enabled"].clone(), rows[1]["enabled"].clone()], [json!(true), json!(false)]);
    }

    #[test]
    fn items_from_without_checked_when_checks_nothing() {
        let mut spec = items_from_spec();
        spec["item"].as_object_mut().unwrap().remove("checked_when");
        let rows = items_from_entries(&spec, &items_from_ctx());
        assert_eq!([rows[0]["checked"].clone(), rows[1]["checked"].clone()], [Value::Null, Value::Null]);
    }

    #[test]
    fn items_from_params_are_expressions() {
        let mut spec = items_from_spec();
        spec["item"]["params"] = json!({"library": "lib + \"/x\"", "n": "1 + 1"});
        assert_eq!(items_from_entries(&spec, &items_from_ctx())[0]["params"],
                   json!({"library": "default_brushes/x", "n": 2}), "an integral number is an integer, as the reference gives");
    }

    #[test]
    fn items_from_a_non_list_or_empty_source_gives_no_rows() {
        for src in ["data.brush_libraries", "null", "3"] {
            let mut spec = items_from_spec();
            spec["source"] = json!(src);
            assert_eq!(items_from_entries(&spec, &items_from_ctx()), json!([]), "{src}");
        }
        assert_eq!(items_from_entries(&items_from_spec(),
                                      &json!({"data": {"brush_libraries": {}}, "panel": {}})), json!([]));
    }

    /// ⭐ THE ARM THE REAL BUNDLE CANNOT DRIVE, AND THAT IS EXACTLY WHY IT IS
    /// HERE. `workspace/menubar.yaml` contains 11 bare strings and all 11 are
    /// `"separator"`, so the `unknown` branch is unreachable from production
    /// data — and an unreachable branch with no test is indistinguishable from
    /// a branch that mislabels. A synthetic bundle is the only way to show that
    /// an unrecognised bare node REFUSES a category rather than being drawn as
    /// a divider in the wrong place.
    #[test]
    fn an_unrecognised_bare_node_is_unknown_and_not_silently_a_separator() {
        let menubar = json!([{
            "id": "m", "label": "&M",
            "items": ["separator", "somethingelse",
                      {"id": "i", "label": "&I", "action": "a"}]
        }]);
        let rows = menu_structure(&menubar);
        let rows = rows.as_array().expect("array");

        let kinds: Vec<&str> = rows.iter().map(|r| r["kind"].as_str().unwrap()).collect();
        assert_eq!(kinds, vec!["menu", "separator", "unknown", "item"], "{rows:#?}");

        // AND THE INDEXING IS UNAFFECTED, which is the half that would break the
        // join law silently: an unrecognised node still consumes its index, so
        // the item after it keeps the path `menu_state` would give it.
        assert_eq!(rows[3]["path"], json!([0, 2]), "an unknown node must consume its index");
    }

    /// The two walks index IDENTICALLY, asserted on a bundle small enough to
    /// read. The join law arm in `ffi.rs` tests this against the real menubar;
    /// this one shows WHY it holds — separators and submenu nodes consume their
    /// index in both passes, and only the emission differs.
    #[test]
    fn the_two_walks_agree_on_every_item_path() {
        let menubar = json!([{
            "id": "m", "label": "&M",
            "items": [
                {"id": "a", "label": "&A", "action": "a"},
                "separator",
                {"id": "sub", "label": "&Sub", "items": [
                    {"id": "b", "label": "&B", "action": "b"}
                ]},
                {"id": "c", "label": "&C", "action": "c"}
            ]
        }]);
        let state = menu_state(&menubar, &json!({}));
        let structure = menu_structure(&menubar);

        let state_paths: Vec<String> = state.as_array().unwrap()
            .iter().map(|r| r["path"].to_string()).collect();
        let item_paths: Vec<String> = structure.as_array().unwrap()
            .iter().filter(|r| r["kind"] == "item")
            .map(|r| r["path"].to_string()).collect();

        assert_eq!(state_paths.len(), 3, "the fixture must have three action items");
        assert_eq!(state_paths, item_paths, "the two walks disagree on item paths");
        // The submenu CHILD is at a three-element path in both.
        assert!(state_paths.contains(&"[0,2,0]".to_string()), "{state_paths:?}");
    }
}
