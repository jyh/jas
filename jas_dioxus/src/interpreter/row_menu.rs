//! A panel row's `context_menu:` as a shell draws it (STATUS-jas rows 141 and
//! 257). The web's renderer draws it and the engine's FFI exports it to a native
//! shell, so it is NOT gated behind `web`.

use serde_json::{Map, Value};

/// One declared entry of a row's `context_menu:`. `index` is its position in
/// the DECLARED list, the value the engine's pick takes (`panel_behavior`,
/// `event: "context_menu"`); `params` are the item's DECLARED params, which the
/// engine resolves at the pick and the web resolves itself.
#[derive(Debug, Clone, PartialEq)]
pub enum RowMenuEntry {
    Separator { index: usize },
    Item { index: usize, label: String, enabled: bool, action: String, params: Map<String, Value> },
}

impl RowMenuEntry {
    pub fn index(&self) -> usize {
        match self {
            RowMenuEntry::Separator { index } | RowMenuEntry::Item { index, .. } => *index,
        }
    }
}

/// The `context_menu:` of `holder` (`lp_tree`) for row `path`, read in that
/// row's scope: `node` is bound by the holder's own foreach, the expansion the
/// tree draws. Labels and actions are interpolated and `enabled_when` is
/// evaluated (an item without one is enabled). Returns the entries and the
/// row's scope, or `None` when the holder declares no menu or the row is not
/// one of its rows. An entry that is neither "separator" nor an object is
/// skipped, and no later index moves.
pub fn row_menu(holder: &Value, ctx: &Value, path: &[usize]) -> Option<(Vec<RowMenuEntry>, Value)> {
    let items = holder.get("context_menu")?.as_array()?;
    let var = holder.get("foreach").and_then(|f| f.get("as")).and_then(|v| v.as_str()).unwrap_or("item");
    let want: Vec<Value> = path.iter().map(|&i| serde_json::json!(i)).collect();
    let scope = crate::interpreter::foreach::row_scopes(holder, ctx)?.into_iter().find(|r| {
        let p = &r[var]["path"];
        let p = p.get("__path__").unwrap_or(p);
        p.as_array().is_some_and(|a| a.as_slice() == want.as_slice())
    })?;
    let empty = Map::new();
    let entries = items.iter().enumerate().filter_map(|(index, raw)| {
        if raw.as_str() == Some("separator") {
            return Some(RowMenuEntry::Separator { index });
        }
        let item = raw.as_object()?;
        let text = |k: &str| item.get(k).and_then(|v| v.as_str())
            .map(|t| crate::interpreter::expr::eval_text(t, &scope)).unwrap_or_default();
        let enabled = item.get("enabled_when").and_then(|v| v.as_str())
            .map_or(true, |c| crate::interpreter::expr::eval(c, &scope).to_bool());
        let params = item.get("params").and_then(|p| p.as_object()).unwrap_or(&empty).clone();
        Some(RowMenuEntry::Item { index, label: text("label"), enabled, action: text("action"), params })
    }).collect();
    Some((entries, scope))
}

#[cfg(test)]
mod tests {
    use super::{row_menu, RowMenuEntry};

    /// `lp_tree` as the workspace declares it, and a scope with the shared
    /// element_tree fixture's first case (rows [1] Front, [0] Back, [0,1] G,
    /// [0,1,0] a leaf) and the panel's declared defaults. The web arms
    /// (`renderer.rs`, `layers_row_menu_tests`) read the same holder and scope.
    fn holder_and_ctx() -> (serde_json::Value, serde_json::Value) {
        let ws = crate::interpreter::workspace::Workspace::load().expect("workspace loads");
        fn find(n: &serde_json::Value) -> Option<serde_json::Value> {
            if n.get("id").and_then(|v| v.as_str()) == Some("lp_tree") {
                return Some(n.clone());
            }
            match n {
                serde_json::Value::Object(m) => m.values().find_map(find),
                serde_json::Value::Array(a) => a.iter().find_map(find),
                _ => None,
            }
        }
        let holder = find(&ws.panel("layers_panel_content").expect("layers panel")["content"]).expect("lp_tree");
        let raw = include_str!(concat!("../../../test_fixtures/", "layers/element_tree.json"));
        let fixture: serde_json::Value = serde_json::from_str(raw).unwrap();
        let rows = fixture["cases"][0]["expected"].clone();
        let panel: serde_json::Map<String, serde_json::Value> =
            ws.panel_state_defaults("layers_panel_content").into_iter().collect();
        (holder, serde_json::json!({"panel": panel, "active_document": {"element_tree": rows}}))
    }

    fn labels(es: &[RowMenuEntry]) -> Vec<String> {
        es.iter().map(|e| match e {
            RowMenuEntry::Separator { .. } => "-".to_string(),
            RowMenuEntry::Item { label, .. } => label.clone(),
        }).collect()
    }

    #[test]
    fn the_row_menu_is_the_yamls_menu_in_the_rows_scope() {
        let (holder, ctx) = holder_and_ctx();
        let (es, _) = row_menu(&holder, &ctx, &[0]).expect("row [0] has a menu");
        assert_eq!(labels(&es), ["Options for Layer...", "Duplicate", "Delete Selection", "-",
                                 "Enter Isolation Mode", "-", "Flatten Artwork", "Collect in New Layer"]);
        let enabled = |es: &[RowMenuEntry], l: &str| es.iter().find_map(|e| match e {
            RowMenuEntry::Item { label, enabled, .. } if label == l => Some(*enabled), _ => None });
        assert_eq!(enabled(&es, "Options for Layer..."), Some(true), "a layer row enables the layer-only item");
        let (group, _) = row_menu(&holder, &ctx, &[0, 1]).expect("row [0,1] has a menu");
        assert_eq!(enabled(&group, "Options for Layer..."), Some(false), "a group row does not");
    }

    /// The index is what the engine's pick takes (`panel_behavior`: `items.get(at)`
    /// over the DECLARED list, separators included), so every entry carries its
    /// declared position.
    #[test]
    fn every_entry_carries_its_declared_index() {
        let (holder, ctx) = holder_and_ctx();
        let (es, _) = row_menu(&holder, &ctx, &[0]).expect("row [0] has a menu");
        let idx: Vec<usize> = es.iter().map(RowMenuEntry::index).collect();
        assert_eq!(idx, (0..es.len()).collect::<Vec<_>>());
    }

    /// An entry that is neither "separator" nor an item is skipped WITHOUT
    /// moving the index of any entry after it: a shifted index would make a
    /// native shell's pick run a different item than the one it drew.
    #[test]
    fn a_malformed_entry_shifts_no_later_index() {
        let (mut holder, ctx) = holder_and_ctx();
        let menu = holder["context_menu"].as_array_mut().expect("lp_tree declares a menu");
        menu.insert(1, serde_json::json!(42));
        let (es, _) = row_menu(&holder, &ctx, &[0]).expect("row [0] has a menu");
        let dup = es.iter().find_map(|e| match e {
            RowMenuEntry::Item { label, index, .. } if label == "Duplicate" => Some(*index), _ => None });
        assert_eq!(dup, Some(2), "Duplicate is declared at 2 after the insert: {es:?}");
    }

    #[test]
    fn a_row_that_is_not_in_the_tree_has_no_menu() {
        let (holder, ctx) = holder_and_ctx();
        assert!(row_menu(&holder, &ctx, &[7]).is_none());
    }
}
