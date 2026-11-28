//! The ONE expansion of a `foreach` node into its rows (W2b-16, the block's S8:
//! plan rows and behavior rows must expand from one scope).
//!
//! The plan's layout (`panel_layout`), its bound values (`bind_values`) and the
//! engine's path resolver (`panel_behavior`) all call [`row_scopes`], so a path
//! `[..., i]` names the same row, bound to the same item, in all three.

use std::collections::{HashMap, HashSet};

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
        // Ruling 1054: the row's OWN loop variable, innermost wins, so a
        // foreach widget's id template may resolve from it and nothing else.
        child.insert(ROW_AS.to_string(), json!(var));
        Value::Object(child)
    }).collect())
}

/// The scope key naming a row's OWN loop variable, innermost wins (ruling 1054).
/// [`row_scopes`] writes it; [`row_id`] reads it.
pub const ROW_AS: &str = "_row_as";

/// Ruling 1054 (D12's withholding half, narrowed): a foreach widget's id
/// template resolves per row when EVERY `{{...}}` in it is a plain path from
/// the row's own loop variable ([`ROW_AS`], innermost) to a non-empty string or
/// a number. Anything else (state, an outer loop's variable, a missing key, an
/// expression) is None, and the id stays withheld and named. The ONE resolver:
/// the engine's plan (`panel_plan`) and the web's native canvas tab strip call
/// it, and the Swift twin (`rowId`, RowId.swift) ports it arm for arm (row 302).
pub fn row_id(template: &str, ctx: &Value) -> Option<String> {
    let var = ctx.get(ROW_AS)?.as_str()?;
    let row = ctx.get(var)?;
    let mut out = String::new();
    let mut rest = template;
    while let Some(i) = rest.find("{{") {
        out.push_str(&rest[..i]);
        let j = rest[i..].find("}}")?;
        let expr = rest[i + 2..i + j].trim();
        let mut parts = expr.split('.');
        if parts.next()? != var {
            return None;
        }
        let mut v = row;
        let mut depth = 0;
        for p in parts {
            if p.is_empty() || !p.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
                return None;
            }
            v = v.get(p)?;
            depth += 1;
        }
        if depth == 0 {
            return None;
        }
        match v {
            Value::String(s) if !s.is_empty() => out.push_str(s),
            Value::Number(n) => out.push_str(&n.to_string()),
            _ => return None,
        }
        rest = &rest[i + j + 2..];
    }
    out.push_str(rest);
    Some(out)
}

/// Ruling 1054 condition 3: given every id one plan carries, each paired with
/// whether that carrier RESOLVED it, the ids to withhold from EVERY carrier:
/// a non-empty id carried more than once when at least one carrier resolved
/// it. Two static carriers of one id, with no resolution among them, are not
/// this rule's subject and keep their ids. One rule for the engine's plan and
/// the native strips (row 302).
pub fn duplicate_resolved_ids<'a>(carried: impl IntoIterator<Item = (&'a str, bool)>) -> HashSet<String> {
    let mut count: HashMap<&str, usize> = HashMap::new();
    let mut resolved: HashSet<&str> = HashSet::new();
    for (id, was_resolved) in carried {
        if id.is_empty() {
            continue;
        }
        *count.entry(id).or_default() += 1;
        if was_resolved {
            resolved.insert(id);
        }
    }
    resolved.into_iter().filter(|id| count[id] > 1).map(str::to_string).collect()
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

    /// Row 302 / ruling 1054: `row_id` is the ONE resolver of a foreach
    /// widget's id template (the engine plan, the web and the Mac call it or
    /// port it). Each row of this table is one law; the Swift twin is
    /// `RowIdTests.swift`, row for row.
    fn scope(var: &str, row: Value) -> Value {
        json!({"state": {"q": "z"}, "g": {"k": "G"}, var: row, ROW_AS: var})
    }

    #[test]
    fn row_id_resolves_only_plain_paths_from_the_rows_own_variable() {
        let row = json!({"k": "a", "n": 0, "f": 1.5, "e": "", "b": true, "o": {"p": "deep"}, "_index": 3});
        let s = scope("it", row);
        let cases: &[(&str, Option<&str>)] = &[
            ("b_{{it.k}}_{{it.n}}", Some("b_a_0")),   // a string and an integer
            ("x{{ it.k }}", Some("xa")),              // spaces inside the braces
            ("{{it.o.p}}", Some("deep")),             // a nested plain path
            ("t_{{it._index}}", Some("t_3")),         // the row's own index
            ("f_{{it.f}}", Some("f_1.5")),            // a float prints as serde prints it
            ("s_{{state.q}}", None),                  // state is not the row's variable
            ("o_{{g.k}}", None),                      // nor is an outer loop's
            ("m_{{it.nope}}", None),                  // a missing key
            ("e_{{it.e}}", None),                     // an empty string
            ("b_{{it.b}}", None),                     // a boolean
            ("o_{{it.o}}", None),                     // an object
            ("v_{{it}}", None),                       // the variable itself (depth 0)
            ("p_{{it.k|x}}", None),                   // anything but a plain path
            ("p_{{it.k + 1}}", None),
            ("u_{{it.k", None),                       // an unclosed brace
        ];
        for (t, want) in cases {
            assert_eq!(row_id(t, &s).as_deref(), *want, "template {t:?}");
        }
        assert_eq!(row_id("b_{{it.k}}", &json!({"it": {"k": "a"}})), None, "no row variable recorded, no resolution");
    }

    #[test]
    fn row_scopes_record_the_innermost_variable_for_row_id() {
        let node = json!({"foreach": {"source": "gs", "as": "g"}, "do": {"type": "text"}});
        let outer = row_scopes(&node, &json!({"gs": [{"k": "G"}]})).unwrap().remove(0);
        let inner_node = json!({"foreach": {"source": "g.items", "as": "it"}, "do": {"type": "text"}});
        let mut ctx = outer.clone();
        ctx["g"]["items"] = json!([{"k": "a"}]);
        let inner = row_scopes(&inner_node, &ctx).unwrap().remove(0);
        assert_eq!(row_id("{{g.k}}", &outer).as_deref(), Some("G"), "in the outer row, g is the row's own");
        assert_eq!(row_id("{{g.k}}", &inner), None, "in the inner row, g is an outer loop");
        assert_eq!(row_id("{{it.k}}", &inner).as_deref(), Some("a"));
    }

    /// Ruling 1054 condition 3, the rule's population: an id carried more than
    /// once is withheld from every carrier when at least one carrier RESOLVED
    /// it. Two STATIC carriers of one id are not this rule's, and the shipped
    /// plans carry many: a static id in a foreach template repeats once per row
    /// (Artboards' `ap_number`), so withholding them would strip real ids.
    #[test]
    fn duplicate_resolved_ids_names_only_collisions_a_resolution_took_part_in() {
        let got = duplicate_resolved_ids([
            ("d_x", false), ("d_x", true),   // static and resolved
            ("d_y", true), ("d_y", true),    // two rows
            ("s", false), ("s", false),      // two statics: not this rule's
            ("u", true),                     // resolved once
            ("", true), ("", true),          // a withheld id is no id
        ]);
        let mut got: Vec<String> = got.into_iter().collect();
        got.sort();
        assert_eq!(got, ["d_x", "d_y"]);
    }
}
