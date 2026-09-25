//! The ONE expansion of a `foreach` node into its rows (W2b-16, the block's S8:
//! plan rows and behavior rows must expand from one scope).
//!
//! The plan's layout (`panel_layout`), its bound values (`bind_values`) and the
//! engine's path resolver (`panel_behavior`) all call [`row_scopes`], so a path
//! `[..., i]` names the same row, bound to the same item, in all three.

use serde_json::{json, Map, Value};

use super::expr::eval;
use super::expr_types::Value as EVal;

/// The per-row scopes a `foreach` node expands to, in order. Row `i` is `ctx`
/// with the node's `as` variable (default `item`) bound to item `i` of
/// `eval(foreach.source, ctx)`: an object item as it is, any other item as
/// `{"_value": item}`, and either one with `_index: i`. `None` when the node is
/// not a foreach (no `foreach` object, or no `do` template). A source that does
/// not evaluate to a list has no rows.
pub fn row_scopes(node: &Value, ctx: &Value) -> Option<Vec<Value>> {
    let spec = node.get("foreach").filter(|v| v.is_object())?;
    node.get("do").filter(|v| !v.is_null())?;
    let src = spec.get("source").and_then(|v| v.as_str()).unwrap_or("");
    let var = spec.get("as").and_then(|v| v.as_str()).unwrap_or("item");
    let items: Vec<Value> = match eval(src, ctx) {
        EVal::List(v) => v,
        _ => vec![],
    };
    let base = ctx.as_object().cloned().unwrap_or_default();
    Some(items.into_iter().enumerate().map(|(i, item)| {
        let mut data = match item {
            Value::Object(m) => m,
            other => {
                let mut m = Map::new();
                m.insert("_value".to_string(), other);
                m
            }
        };
        data.insert("_index".to_string(), json!(i));
        let mut child = base.clone();
        child.insert(var.to_string(), Value::Object(data));
        Value::Object(child)
    }).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_row_binds_its_item_and_index_under_the_declared_name() {
        let node = json!({"foreach": {"source": "things", "as": "t"}, "do": {"type": "text"}});
        let ctx = json!({"things": [{"n": "a"}, 7], "keep": 1});
        let rows = row_scopes(&node, &ctx).expect("a foreach");
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["t"], json!({"n": "a", "_index": 0}));
        assert_eq!(rows[1]["t"], json!({"_value": 7, "_index": 1}), "a non-object item");
        assert_eq!(rows[1]["keep"], 1, "the outer scope is kept");
    }

    #[test]
    fn a_node_without_both_halves_is_not_a_foreach_and_a_non_list_has_no_rows() {
        assert!(row_scopes(&json!({"do": {}}), &json!({})).is_none());
        assert!(row_scopes(&json!({"foreach": {"source": "x"}}), &json!({})).is_none());
        let node = json!({"foreach": {"source": "x"}, "do": {"type": "text"}});
        assert_eq!(row_scopes(&node, &json!({"x": 3})), Some(vec![]));
        let rows = row_scopes(&node, &json!({"x": [1]})).unwrap();
        assert_eq!(rows[0]["item"]["_value"], 1, "the default name is `item`");
    }
}
