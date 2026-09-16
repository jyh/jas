//! The panel PLAN a native shell materializes: the layout pass's rects joined,
//! in the engine, with the bind pass's resolved values (wave 2, A5).
//!
//! # Why the join is here and not in the shell
//!
//! The shell evaluates nothing (the wave-1 law). It needs, per widget, WHERE to
//! put a native control and WHAT that control displays. The first comes from
//! `panel_layout::render_plan`, the second from `bind_values`. Joining them
//! across the boundary would make the shell hold two walks' worth of rows and a
//! join rule. Here it is one call, and nothing interpretable leaves the engine:
//! no node, no expression, no behavior, no scope.
//!
//! # The join key is the PATH, never the id
//!
//! A foreach template repeats its ids by construction, so an id names a
//! template, not a widget. The two walks share one path scheme (root `[]`,
//! declared child `[i]`, foreach expansion `[..., i]`), and that agreement was
//! MEASURED on the whole compiled workspace before this join was written (the
//! stop-2 test below).
//!
//! # Output
//!
//! ```text
//! {"height": h,
//!  "chrome":     [entry...],  layout-only containers with a border/background
//!  "leaves":     [entry...],  one per renderable widget, render_plan's order
//!  "containers": [entry...],  layout-only containers render_plan omits, that
//!                             carry at least one bound value
//!  "unjoined":   [{"path": [...], "key": "..."}...]}
//! entry = {"path": [...], "rect": {x,y,w,h}, "type": "...", "id": "...",
//!          "values": {"<bind_values key>": "<resolved value>", ...}}
//! ```
//!
//! `containers` exists because the measurement found bound rows on nodes that
//! draw nothing: a container's dynamic `visible` and a disclosure's header.
//! Dropping them would show a hidden group, or a header with no label, and
//! report success. `unjoined` names any bound row whose node the layout pass
//! never placed (a static `visible: false`, today). It is empty on every panel
//! in the workspace. It is reported rather than dropped, so a new panel that
//! breaks the join says so.
//!
//! A value is the row's canonical STRING. The row's value `type` is not carried.

use std::collections::HashMap;

use serde_json::{json, Map, Value};

use crate::interpreter::bind_values::bind_values;
use crate::interpreter::panel_layout::{render_plan_with_omitted, RenderLeaf};

fn path_of(v: &Value) -> Vec<i64> {
    v.as_array()
        .map(|a| a.iter().filter_map(Value::as_i64).collect())
        .unwrap_or_default()
}

fn entry(item: &RenderLeaf, values: Map<String, Value>) -> Value {
    json!({
        "path": item.path,
        "rect": {"x": item.x, "y": item.y, "w": item.w, "h": item.h},
        "type": item.node.get("type").and_then(Value::as_str).unwrap_or(""),
        "id": item.node.get("id").and_then(Value::as_str).unwrap_or(""),
        "values": values,
    })
}

/// Build a panel's plan in `ctx` (see the module docs for the shape).
///
/// Returns `(plan, rows)`: `rows` is the `bind_values` output the plan was
/// joined from, handed back so a caller that must also record it (the
/// engine's panel registry) does not walk the panel a second time.
pub fn panel_plan(panel_node: &Value, avail_w: i64, avail_h: i64, ctx: &Value) -> (Value, Value) {
    let rows = bind_values(panel_node, ctx);
    let (plan, omitted) = render_plan_with_omitted(panel_node, avail_w, avail_h, ctx);

    let mut by_path: HashMap<Vec<i64>, Map<String, Value>> = HashMap::new();
    for r in rows.as_array().into_iter().flatten() {
        let key = r["key"].as_str().unwrap_or("").to_string();
        by_path.entry(path_of(&r["path"])).or_default().insert(key, r["value"].clone());
    }

    let chrome: Vec<Value> = plan
        .chrome
        .iter()
        .map(|it| entry(it, by_path.remove(&it.path).unwrap_or_default()))
        .collect();
    let leaves: Vec<Value> = plan
        .leaves
        .iter()
        .map(|it| entry(it, by_path.remove(&it.path).unwrap_or_default()))
        .collect();
    let containers: Vec<Value> = omitted
        .iter()
        .filter_map(|it| by_path.remove(&it.path).map(|v| entry(it, v)))
        .collect();
    // Whatever is left joined nothing. Reported in row order.
    let unjoined: Vec<Value> = rows
        .as_array()
        .into_iter()
        .flatten()
        .filter(|r| by_path.contains_key(&path_of(&r["path"])))
        .map(|r| json!({"path": r["path"], "key": r["key"]}))
        .collect();

    let out = json!({
        "height": plan.height,
        "chrome": chrome,
        "leaves": leaves,
        "containers": containers,
        "unjoined": unjoined,
    });
    (out, rows)
}


/// The observables' oracles, shared by this module's tests and the ABI tests in
/// `ffi.rs`. Each returns `Err` naming what it found, so a negative control can
/// assert WHICH defect was reported, not merely that something was.
#[cfg(test)]
pub(crate) mod checks {
    use serde_json::Value;
    use std::collections::HashMap;

    use crate::interpreter::panel_layout::RenderPlan;

    /// The three entry lists a plan carries, in the order they are checked.
    pub(crate) const LISTS: [&str; 3] = ["chrome", "leaves", "containers"];

    fn paths(list: &Value) -> Vec<String> {
        list.as_array()
            .map(|a| a.iter().map(|e| e["path"].to_string()).collect())
            .unwrap_or_default()
    }

    /// **Q1.** Every `(path, rect)` the plan carries equals `layout_panel`'s entry
    /// at that path, compared as serialized bytes; the plan's `height` is
    /// `render_plan`'s; and every `render_plan` leaf and chrome entry appears, in
    /// order. Returns the number of entries whose rect was compared.
    pub(crate) fn plan_matches_layout(
        plan: &Value,
        layout: &Value,
        rp: &RenderPlan,
    ) -> Result<usize, String> {
        let lay: HashMap<String, String> = layout
            .as_array()
            .ok_or("layout_panel returned no array")?
            .iter()
            .map(|e| (e["path"].to_string(), e["rect"].to_string()))
            .collect();
        let mut errs: Vec<String> = vec![];
        let mut compared = 0usize;
        for list in LISTS {
            let Some(entries) = plan[list].as_array() else {
                errs.push(format!("plan has no `{list}` array"));
                continue;
            };
            for e in entries {
                let p = e["path"].to_string();
                match lay.get(&p) {
                    None => errs.push(format!("{list} path {p} has no layout_panel entry")),
                    Some(r) if *r != e["rect"].to_string() => errs.push(format!(
                        "{list} path {p}: plan rect {} != layout_panel rect {r}",
                        e["rect"]
                    )),
                    Some(_) => compared += 1,
                }
            }
        }
        if plan["height"].as_i64() != Some(rp.height) {
            errs.push(format!("plan height {} != render_plan height {}", plan["height"], rp.height));
        }
        for (list, want) in [("leaves", &rp.leaves), ("chrome", &rp.chrome)] {
            let got = paths(&plan[list]);
            let exp: Vec<String> =
                want.iter().map(|l| serde_json::json!(l.path).to_string()).collect();
            if got != exp {
                for p in exp.iter().filter(|p| !got.contains(p)) {
                    errs.push(format!("render_plan {list} path {p} is missing from the plan"));
                }
                for p in got.iter().filter(|p| !exp.contains(p)) {
                    errs.push(format!("plan {list} path {p} is not a render_plan {list} path"));
                }
                if got.len() == exp.len() {
                    errs.push(format!("plan {list} order differs from render_plan's"));
                }
            }
        }
        if errs.is_empty() { Ok(compared) } else { Err(errs.join("; ")) }
    }

    /// Keys a plan must never carry: the raw node, its behavior, its binding
    /// map, and the scope it would be evaluated in. Any of them would hand the
    /// shell something to interpret.
    pub(crate) const FORBIDDEN_KEYS: [&str; 4] = ["node", "behavior", "bind", "ctx"];

    /// **Q2.** The plan bytes contain no `{{` and no forbidden key at any depth.
    pub(crate) fn nothing_interpretable(bytes: &str) -> Result<(), String> {
        let mut errs: Vec<String> = vec![];
        if let Some(i) = bytes.find("{{") {
            errs.push(format!("unevaluated `{{{{` at byte {i}"));
        }
        let v: Value = serde_json::from_str(bytes).map_err(|e| format!("plan is not JSON: {e}"))?;
        fn walk(v: &Value, at: &str, errs: &mut Vec<String>) {
            match v {
                Value::Object(m) => {
                    for (k, c) in m {
                        if FORBIDDEN_KEYS.contains(&k.as_str()) {
                            errs.push(format!("forbidden key {k:?} at {at}"));
                        }
                        walk(c, &format!("{at}.{k}"), errs);
                    }
                }
                Value::Array(a) => {
                    for (i, c) in a.iter().enumerate() {
                        walk(c, &format!("{at}[{i}]"), errs);
                    }
                }
                _ => {}
            }
        }
        walk(&v, "$", &mut errs);
        if errs.is_empty() { Ok(()) } else { Err(errs.join("; ")) }
    }

    /// The plan's values flattened to `path|key -> value`, over all three lists,
    /// plus the number of values seen (a duplicate would make the two differ).
    pub(crate) fn plan_values(plan: &Value) -> (HashMap<String, String>, usize) {
        let mut out = HashMap::new();
        let mut n = 0usize;
        for list in LISTS {
            for e in plan[list].as_array().into_iter().flatten() {
                for (k, v) in e["values"].as_object().into_iter().flatten() {
                    n += 1;
                    out.insert(format!("{}|{k}", e["path"]), v.as_str().unwrap_or("<non-string>").to_string());
                }
            }
        }
        (out, n)
    }

    /// `bind_values` rows flattened the same way.
    pub(crate) fn row_values(rows: &Value) -> HashMap<String, String> {
        rows.as_array()
            .into_iter()
            .flatten()
            .map(|r| {
                (
                    format!("{}|{}", r["path"], r["key"].as_str().unwrap_or("")),
                    r["value"].as_str().unwrap_or("<non-string>").to_string(),
                )
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{json, Value};
    use std::collections::{BTreeMap, BTreeSet};

    use super::checks;
    use super::panel_plan;
    use crate::interpreter::bind_values::bind_values;
    use crate::interpreter::panel_layout::{layout_panel, render_plan};
    use crate::interpreter::widget_tree::widget_tree;
    use crate::interpreter::workspace::Workspace;

    const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../test_fixtures");

    /// The panel list, DERIVED from the compiled workspace the engine embeds.
    pub(crate) fn panel_ids(ws: &Workspace) -> Vec<String> {
        ws.panels()
            .as_object()
            .expect("the compiled workspace has a panels map")
            .keys()
            .cloned()
            .collect()
    }

    fn engine_scope() -> Value {
        crate::panel_scope::PanelState::default()
            .scope(&crate::document::document::Document::default())
    }

    /// Every scope the walks use: the engine's own (what the ABI uses) plus every
    /// `ctx` the three panel corpora carry, de-duplicated. The corpus scopes are
    /// what put rows under a `foreach`: the engine's slice leaves most foreach
    /// sources empty.
    fn scopes() -> Vec<(String, Value)> {
        let mut out = vec![("engine".to_string(), engine_scope())];
        let mut seen = BTreeSet::new();
        for f in ["panel_layout", "panel_widget_tree", "panel_bind_values"] {
            let raw = std::fs::read_to_string(format!("{FIXTURES}/algorithms/{f}.json"))
                .expect("panel corpus");
            let cases: Value = serde_json::from_str(&raw).expect("corpus JSON");
            for tc in cases.as_array().expect("array") {
                if let Some(ctx) = tc["args"].get("ctx") {
                    if seen.insert(ctx.to_string()) {
                        out.push((format!("{f}:{}", tc["name"].as_str().unwrap_or("?")), ctx.clone()));
                    }
                }
            }
        }
        out
    }

    const SIZES: [(i64, i64); 3] = [(228, 0), (228, 600), (0, 0)];

    fn sorted_keys(v: Option<&Value>) -> Value {
        let mut k: Vec<String> = v
            .and_then(|x| x.as_object())
            .map(|m| m.keys().cloned().collect())
            .unwrap_or_default();
        k.sort();
        json!(k)
    }

    /// ⛔ STOP 2, MEASURED BEFORE ANY JOIN WAS WRITTEN, AND KEPT AS A TEST.
    ///
    /// `bind_values` paths follow `widget_tree`'s walk; `render_plan` paths follow
    /// the layout pass's. A join by path is sound only if a path names THE SAME
    /// NODE, IN THE SAME SCOPE, in both. Two methods, both on the real workspace:
    ///
    /// 1. **Structure.** Every `render_plan` item's node has the `type`, `id` and
    ///    sorted `bind` keys that `widget_tree` records at that path.
    /// 2. **Value.** Every bind row whose path is a `render_plan` item is
    ///    REPRODUCED by re-evaluating that item's own node in that item's own
    ///    scope. A foreach row carries its per-item scope, so a path that named
    ///    the right template under the wrong item would fail here even though (1)
    ///    passed.
    ///
    /// Measured at the first run (16 panels x 16 scopes x 3 sizes): **0
    /// disagreements**; 14,034 rows reproduced, 306 of them under a foreach.
    /// **564 rows matched no `render_plan` item, and every one sits on a
    /// layout-only container that `render_plan` omits because it has no chrome:**
    /// a container's `bind.visible` (colour x5, concepts x4, opacity x1) and a
    /// disclosure's `label` + `bind.collapsed` (brushes, swatches, under a
    /// foreach). None was "not laid out". That is why the plan carries a
    /// `containers` list: without it those rows would be dropped silently.
    #[test]
    fn stop2_bind_paths_and_layout_paths_name_the_same_node() {
        let ws = Workspace::load().expect("workspace");
        let panels = panel_ids(&ws);
        let scopes = scopes();
        assert!(!panels.is_empty() && scopes.len() > 1, "vacuous walk");

        let mut disagreements: Vec<String> = vec![];
        let mut joined = 0usize;
        let mut joined_in_foreach = 0usize;
        let mut unmatched: BTreeMap<String, usize> = BTreeMap::new();
        let mut per_panel: BTreeMap<String, (usize, usize, usize)> = BTreeMap::new();

        for pid in &panels {
            let spec = ws.panel(pid).unwrap();
            for (sname, ctx) in &scopes {
                let wt: BTreeMap<String, Value> = widget_tree(spec, ctx)
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|r| (r["path"].to_string(), r.clone()))
                    .collect();
                let rows = bind_values(spec, ctx);
                let rows = rows.as_array().unwrap();
                for (w, h) in SIZES {
                    let plan = render_plan(spec, w, h, ctx);
                    let layout: BTreeSet<String> = layout_panel(spec, w, h, ctx)
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|r| r["path"].to_string())
                        .collect();
                    let mut items: BTreeMap<String, (&Value, &Value)> = BTreeMap::new();
                    for it in plan.leaves.iter().chain(plan.chrome.iter()) {
                        let key = json!(it.path).to_string();
                        if items.insert(key.clone(), (&it.node, &it.ctx)).is_some() {
                            disagreements.push(format!("{pid} {sname} {w}x{h}: duplicate plan path {key}"));
                        }
                        match wt.get(&key) {
                            None => disagreements.push(format!(
                                "{pid} {sname} {w}x{h}: plan path {key} is not in widget_tree"
                            )),
                            Some(rec) => {
                                let t = it.node.get("type").cloned().unwrap_or(json!(""));
                                let id = it.node.get("id").cloned().unwrap_or(json!(""));
                                if rec["type"] != t
                                    || rec["id"] != id
                                    || rec["bind"] != sorted_keys(it.node.get("bind"))
                                {
                                    disagreements.push(format!(
                                        "{pid} {sname} {w}x{h}: path {key} names {t}/{id} in the plan and {}/{} in widget_tree",
                                        rec["type"], rec["id"]
                                    ));
                                }
                            }
                        }
                    }
                    let entry = per_panel.entry(pid.clone()).or_default();
                    for row in rows {
                        let key = row["path"].to_string();
                        match items.get(&key) {
                            Some((node, item_ctx)) => {
                                let again = bind_values(&json!({"content": node}), item_ctx);
                                let hit = again.as_array().unwrap().iter().find(|r| {
                                    r["path"] == json!([]) && r["key"] == row["key"]
                                });
                                let ok = hit.is_some_and(|r| {
                                    r["id"] == row["id"] && r["type"] == row["type"] && r["value"] == row["value"]
                                });
                                if ok {
                                    joined += 1;
                                    entry.0 += 1;
                                    if *item_ctx != ctx {
                                        joined_in_foreach += 1;
                                        entry.1 += 1;
                                    }
                                } else {
                                    disagreements.push(format!(
                                        "{pid} {sname} {w}x{h}: row {row} is not reproduced by the plan item at {key}: {hit:?}"
                                    ));
                                }
                            }
                            None => {
                                entry.2 += 1;
                                let cause = if layout.contains(&key) {
                                    "laid out, omitted from the plan"
                                } else {
                                    "not laid out"
                                };
                                let t = wt.get(&key).map(|r| r["type"].to_string()).unwrap_or_default();
                                *unmatched
                                    .entry(format!("{cause} | {pid} {key} {t} {}", row["key"]))
                                    .or_default() += 1;
                            }
                        }
                    }
                }
            }
        }

        println!("STOP2 panels={} scopes={} sizes={}", panels.len(), scopes.len(), SIZES.len());
        for (p, (j, f, u)) in &per_panel {
            println!("STOP2 panel {p}: joined={j} joined_in_foreach={f} unmatched={u}");
        }
        for (k, n) in &unmatched {
            println!("STOP2 unmatched x{n}: {k}");
        }
        println!(
            "STOP2 joined={joined} joined_in_foreach={joined_in_foreach} unmatched={} disagreements={}",
            unmatched.values().sum::<usize>(),
            disagreements.len()
        );
        for d in disagreements.iter().take(40) {
            println!("STOP2 DISAGREE {d}");
        }
        assert!(joined > 0 && joined_in_foreach > 0, "vacuous: nothing joined under a foreach");
        assert!(disagreements.is_empty(), "{} disagreements", disagreements.len());
        assert!(
            unmatched.keys().all(|k| k.starts_with("laid out, omitted")),
            "a bound row is on a node the layout pass never placed: {unmatched:?}"
        );
    }

    /// ⭐ NO BOUND ROW IS DROPPED, AND NONE IS COUNTED TWICE. On every panel, in
    /// every scope, at every size: the plan's values number exactly the bind
    /// rows, `unjoined` is empty, every entry's `type`/`id` is what
    /// `widget_tree` records at its path, and a `containers` entry is a
    /// layout-only node that `render_plan` omitted and that carries a value.
    #[test]
    fn every_bound_row_is_joined_exactly_once_on_every_panel() {
        let ws = Workspace::load().expect("workspace");
        let panels = panel_ids(&ws);
        let (mut rows_total, mut containers_total, mut walks) = (0usize, 0usize, 0usize);
        for pid in &panels {
            let spec = ws.panel(pid).unwrap();
            for (sname, ctx) in &scopes() {
                let rows = bind_values(spec, ctx);
                let wt: BTreeMap<String, Value> = widget_tree(spec, ctx)
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|r| (r["path"].to_string(), r.clone()))
                    .collect();
                for (w, h) in SIZES {
                    let (plan, joined_from) = panel_plan(spec, w, h, ctx);
                    let at = format!("{pid} {sname} {w}x{h}");
                    assert_eq!(joined_from, rows, "{at}: the plan must be joined from bind_values' rows");
                    let (values, n) = checks::plan_values(&plan);
                    let want = checks::row_values(&rows);
                    assert_eq!(n, want.len(), "{at}: values carried != bind rows");
                    assert_eq!(values, want, "{at}: joined values differ from bind_values");
                    assert_eq!(plan["unjoined"], json!([]), "{at}: a bound row joined nothing");
                    let rp = render_plan(spec, w, h, ctx);
                    let rp_paths: BTreeSet<String> = rp
                        .leaves
                        .iter()
                        .chain(rp.chrome.iter())
                        .map(|l| json!(l.path).to_string())
                        .collect();
                    for list in checks::LISTS {
                        for e in plan[list].as_array().unwrap() {
                            let p = e["path"].to_string();
                            let rec = &wt[&p];
                            assert_eq!(e["type"], rec["type"], "{at}: {list} {p} type");
                            assert_eq!(e["id"], rec["id"], "{at}: {list} {p} id");
                            if list == "containers" {
                                containers_total += 1;
                                assert!(!rp_paths.contains(&p), "{at}: container {p} is also a render_plan item");
                                assert!(
                                    !e["values"].as_object().unwrap().is_empty(),
                                    "{at}: container {p} carries no value"
                                );
                            }
                        }
                    }
                    rows_total += n;
                    walks += 1;
                }
            }
        }
        assert!(walks > 0 && rows_total > 0, "vacuous: walks={walks} rows={rows_total}");
        assert!(containers_total > 0, "vacuous: no container ever carried a value");
    }

    /// A bound widget the layout pass never places (a static `visible: false`)
    /// is REPORTED in `unjoined` by path and key, never dropped. No panel in the
    /// workspace has one today (the stop-2 measurement), so this is synthetic.
    #[test]
    fn a_bound_row_with_no_laid_out_node_is_reported_unjoined() {
        let panel = json!({"content": {"type": "col", "children": [
            {"type": "text", "id": "shown", "content": "{{panel.a}}"},
            {"type": "text", "id": "hidden", "visible": false, "bind": {"value": "panel.a"}},
        ]}});
        let ctx = json!({"panel": {"a": "x"}});
        let (plan, _) = panel_plan(&panel, 228, 0, &ctx);
        assert_eq!(
            plan["unjoined"],
            json!([{"path": [1], "key": "bind.value"}]),
            "{plan}"
        );
        // The control: the visible sibling IS joined, so the report is about
        // the hidden node rather than a join that joined nothing.
        assert_eq!(plan["leaves"][0]["values"], json!({"content": "x"}), "{plan}");
    }

    /// Q1's negative control: shift ONE leaf's path onto a neighbour that the
    /// layout pass also placed (so an existence-only check would pass) and the
    /// oracle must fail, naming that path.
    #[test]
    fn q1_oracle_fails_on_a_shifted_leaf_path_and_names_it() {
        let ws = Workspace::load().expect("workspace");
        let spec = ws.panel("align_panel_content").expect("align");
        let ctx = engine_scope();
        let (plan, _) = panel_plan(spec, 228, 0, &ctx);
        let layout = layout_panel(spec, 228, 0, &ctx);
        let rp = render_plan(spec, 228, 0, &ctx);
        let n = checks::plan_matches_layout(&plan, &layout, &rp).expect("the unmutated plan passes");
        assert!(n > 0, "vacuous: no rect compared");

        let lay: BTreeMap<String, String> = layout
            .as_array()
            .unwrap()
            .iter()
            .map(|e| (e["path"].to_string(), e["rect"].to_string()))
            .collect();
        let leaves = plan["leaves"].as_array().unwrap();
        let (k, shifted) = leaves
            .iter()
            .enumerate()
            .find_map(|(k, e)| {
                let mut p: Vec<i64> =
                    e["path"].as_array()?.iter().filter_map(Value::as_i64).collect();
                *p.last_mut()? += 1;
                let key = json!(p).to_string();
                (lay.get(&key).is_some_and(|r| *r != e["rect"].to_string())).then_some((k, p))
            })
            .expect("a leaf whose shifted path is laid out with a different rect");
        let mut bad = plan.clone();
        bad["leaves"][k]["path"] = json!(shifted);
        let err = checks::plan_matches_layout(&bad, &layout, &rp).expect_err("a shifted path must fail");
        assert!(err.contains(&json!(shifted).to_string()), "the failure must name {shifted:?}: {err}");
    }

    /// Q2's negative controls, one per forbidden thing, each planted alone into a
    /// copy of a real plan, so each clause is shown to fire by itself.
    #[test]
    fn q2_oracle_fails_on_each_planted_interpretable() {
        let ws = Workspace::load().expect("workspace");
        let spec = ws.panel("color_panel_content").expect("color");
        let (plan, _) = panel_plan(spec, 228, 0, &engine_scope());
        let clean = serde_json::to_string(&plan).unwrap();
        checks::nothing_interpretable(&clean).expect("the unmutated plan passes");
        assert!(plan["leaves"].as_array().is_some_and(|a| !a.is_empty()), "vacuous plan: {clean}");

        let raw_node = spec["content"].clone();
        for key in checks::FORBIDDEN_KEYS {
            let mut bad = plan.clone();
            bad["leaves"][0][key] = raw_node.clone();
            let err = checks::nothing_interpretable(&serde_json::to_string(&bad).unwrap())
                .expect_err("a planted key must fail");
            assert!(err.contains(&format!("{key:?}")), "must name {key:?}: {err}");
        }
        let mut bad = plan.clone();
        bad["leaves"][0]["values"]["planted"] = json!("{{panel.hex}}");
        let err = checks::nothing_interpretable(&serde_json::to_string(&bad).unwrap())
            .expect_err("a planted expression must fail");
        assert!(err.contains("`{{`"), "must name the braces: {err}");
    }

    /// **Q3, the pure half, on the S-C pin's own scope** (the one
    /// `cross_language_test::bind_values_separates_equal_length_hex_*` builds).
    /// At `664040` the plan's values ARE `bind_values`' rows; at `664141`
    /// exactly one value moves, and it is the row that pin names.
    #[test]
    fn q3_plan_values_at_the_sc_seed_equal_bind_values_and_move_in_the_pinned_row() {
        let ws = Workspace::load().expect("workspace");
        let spec = ws.panel("color_panel_content").expect("color");
        let ctx_of = |hex: &str| {
            json!({
                "state": {"fill_color": "#664040", "fill_on_top": true},
                "panel": {"mode": "hsb", "hex": hex},
            })
        };
        let (a, b) = (ctx_of("664040"), ctx_of("664141"));
        let (plan_a, _) = panel_plan(spec, 228, 600, &a);
        let (plan_b, _) = panel_plan(spec, 228, 600, &b);

        let (va, na) = checks::plan_values(&plan_a);
        let want = checks::row_values(&bind_values(spec, &a));
        assert!(na > 0, "vacuous: no value joined");
        assert_eq!(na, want.len(), "every row joined exactly once");
        assert_eq!(va, want, "the plan's values are bind_values' rows");

        let (vb, _) = checks::plan_values(&plan_b);
        let moved: Vec<(&String, &String, Option<&String>)> = va
            .iter()
            .filter(|(k, v)| vb.get(*k) != Some(*v))
            .map(|(k, v)| (k, v, vb.get(k)))
            .collect();
        assert_eq!(moved.len(), 1, "exactly one value moves: {moved:?}");
        let (k, before, after) = moved[0];
        assert!(k.ends_with("|bind.value"), "{k}");
        assert_eq!((before.as_str(), after.map(String::as_str)), ("664040", Some("664141")));
        let path = k.split('|').next().unwrap();
        let entry = checks::LISTS
            .iter()
            .flat_map(|l| plan_a[*l].as_array().unwrap().iter())
            .find(|e| e["path"].to_string() == path)
            .expect("the moved value's entry");
        assert_eq!(entry["id"], "cp_hex", "the moved row is the pin's row");

        // The rects are blind to the equal-length change, as the pin says.
        for list in checks::LISTS {
            let rects = |p: &Value| -> Vec<String> {
                p[list].as_array().unwrap().iter().map(|e| e["rect"].to_string()).collect()
            };
            assert_eq!(rects(&plan_a), rects(&plan_b), "{list} rects moved");
        }
    }
}
