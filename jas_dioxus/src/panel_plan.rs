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
//!  "unjoined":   [{"path": [...], "key": "..."}...],
//!  "withheld":   [{"path": [...], "key": "..."}...],  a value that resolved to a
//!                             template, a templated display string or id:
//!                             named, never sent raw
//!  "icons":      {"<name>": {"viewbox": "...", "svg": "..."}, ...},
//!  "icons_missing": ["<name>", ...]}
//! entry = {"path": [...], "rect": {x,y,w,h}, "type": "...", "id": "...",
//!          "values": {"<bind_values key>": "<resolved value>", ...},
//!          "static": {"<STATIC_KEYS key>": "<the node's literal>", ...}}
//! ```
//!
//! # What a person reads (W2-5a)
//!
//! `values` holds only what `bind_values` resolves, and that pass emits no row
//! for a LITERAL string. So until W2-5a a `text` leaf reached the shell with
//! no text and an `icon_button` with no icon and no tooltip. `static` carries
//! each entry's allow-listed literal display strings ([`STATIC_KEYS`]); a
//! templated one other than `content`/`label` is named in `withheld`. `icons`
//! carries, for every icon an entry names (a static `icon`, an `icon` node's
//! `name`, a resolved `bind.icon`), the workspace's own `viewbox` and `svg`,
//! and `icons_missing` names each one the workspace does not define. The
//! precedent is `jas_menu_structure`, which carries the menubar's static
//! labels. ⚠️ A `bind.icon` that a later tick moves to a name outside this map
//! is not sent by the tick: the shell falls back to text for it.
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

/// The node keys whose LITERAL string a shell may display (W2-5a).
///
/// ⛔ AN ALLOW-LIST, NEVER "every string key". A node also carries expression
/// strings (`enabled_when`, `disabled`, a `style` value) and prose
/// (`description`), and a shell that received those would be handed something
/// to evaluate or would show a paragraph where a label belongs. Measured on the
/// compiled workspace (W2-5a): these eight are the display strings panel
/// widgets carry.
pub const STATIC_KEYS: [&str; 8] =
    ["content", "label", "summary", "icon", "name", "unit", "suffix", "placeholder"];

/// A node's allow-listed LITERAL display strings, plus the allow-listed keys it
/// carries as a TEMPLATE that the plan does not resolve.
///
/// A `{{`-bearing `content`/`label` is not withheld: `bind_values` resolves
/// those two and the value is in the entry's `values`. Any other templated
/// display string (a `summary`, measured on three widgets) is withheld and
/// named, so a shell shows its fallback knowingly rather than a raw template.
fn static_of(node: &Value) -> (Map<String, Value>, Vec<&'static str>) {
    let mut out = Map::new();
    let mut withheld = vec![];
    for key in STATIC_KEYS {
        let Some(s) = node.get(key).and_then(Value::as_str) else { continue };
        if !s.contains("{{") {
            out.insert(key.to_string(), Value::String(s.to_string()));
        } else if !matches!(key, "content" | "label") {
            withheld.push(key);
        }
    }
    (out, withheld)
}

/// The icon names an entry displays: its static `icon`, an `icon` node's
/// `name`, and the resolved `bind.icon` row.
fn icon_names(entry: &Value, out: &mut Vec<String>) {
    let st = &entry["static"];
    let mut push = |v: &Value| {
        if let Some(n) = v.as_str().filter(|n| !n.is_empty()) {
            if !out.iter().any(|o| o == n) {
                out.push(n.to_string());
            }
        }
    };
    push(&st["icon"]);
    if entry["type"] == "icon" {
        push(&st["name"]);
    }
    push(&entry["values"]["bind.icon"]);
}

fn entry(item: &RenderLeaf, values: Map<String, Value>, withheld: &mut Vec<Value>) -> Value {
    // A templated id is not resolved by any port and a foreach widget is not
    // addressable by id (D12), so it is sent empty and named, never raw.
    let mut id = item.node.get("id").and_then(Value::as_str).unwrap_or("");
    if id.contains("{{") {
        id = "";
        withheld.push(json!({"path": item.path, "key": "id"}));
    }
    let (st, held) = static_of(&item.node);
    withheld.extend(held.into_iter().map(|key| json!({"path": item.path, "key": key})));
    json!({
        "path": item.path,
        "rect": {"x": item.x, "y": item.y, "w": item.w, "h": item.h},
        "type": item.node.get("type").and_then(Value::as_str).unwrap_or(""),
        "id": id,
        "values": values,
        "static": st,
    })
}

/// Build a panel's plan in `ctx` (see the module docs for the shape).
///
/// Returns `(plan, rows)`: `rows` is the `bind_values` output the plan was
/// joined from, handed back so a caller that must also record it (the
/// engine's panel registry) does not walk the panel a second time.
pub fn panel_plan(
    panel_node: &Value,
    avail_w: i64,
    avail_h: i64,
    ctx: &Value,
    icon_defs: &Value,
) -> (Value, Value) {
    let rows = bind_values(panel_node, ctx);
    let (plan, omitted) = render_plan_with_omitted(panel_node, avail_w, avail_h, ctx);

    // A row whose RESOLVED value is itself a template (a binding that yields
    // `{{theme.colors.selection}}`) is withheld by path and key. Its entry is
    // still keyed, so the partition and the join do not move.
    let mut withheld: Vec<Value> = vec![];
    let mut by_path: HashMap<Vec<i64>, Map<String, Value>> = HashMap::new();
    for r in rows.as_array().into_iter().flatten() {
        let key = r["key"].as_str().unwrap_or("").to_string();
        let values = by_path.entry(path_of(&r["path"])).or_default();
        if r["value"].as_str().is_some_and(|v| v.contains("{{")) {
            withheld.push(json!({"path": r["path"], "key": key}));
        } else {
            values.insert(key, r["value"].clone());
        }
    }

    let chrome: Vec<Value> = plan
        .chrome
        .iter()
        .map(|it| entry(it, by_path.remove(&it.path).unwrap_or_default(), &mut withheld))
        .collect();
    let leaves: Vec<Value> = plan
        .leaves
        .iter()
        .map(|it| entry(it, by_path.remove(&it.path).unwrap_or_default(), &mut withheld))
        .collect();
    let containers: Vec<Value> = omitted
        .iter()
        .filter_map(|it| by_path.remove(&it.path).map(|v| entry(it, v, &mut withheld)))
        .collect();
    // Whatever is left joined nothing. Reported in row order.
    let unjoined: Vec<Value> = rows
        .as_array()
        .into_iter()
        .flatten()
        .filter(|r| by_path.contains_key(&path_of(&r["path"])))
        .map(|r| json!({"path": r["path"], "key": r["key"]}))
        .collect();

    // Every icon an entry names, in entry order: its workspace definition
    // verbatim (the two fields a shell draws from), or its name in
    // `icons_missing` when the workspace defines no such icon.
    let mut names: Vec<String> = vec![];
    for e in chrome.iter().chain(&leaves).chain(&containers) {
        icon_names(e, &mut names);
    }
    let mut icons = Map::new();
    let mut icons_missing: Vec<Value> = vec![];
    for n in names {
        match icon_defs.get(&n) {
            Some(def) => {
                icons.insert(n, json!({"viewbox": def["viewbox"], "svg": def["svg"]}));
            }
            None => icons_missing.push(Value::String(n)),
        }
    }

    let out = json!({
        "height": plan.height,
        "chrome": chrome,
        "leaves": leaves,
        "containers": containers,
        "unjoined": unjoined,
        "withheld": withheld,
        "icons": icons,
        "icons_missing": icons_missing,
    });
    (out, rows)
}

/// The panels a shell can offer (W2b-2): `[{"id": "<content id>", "summary":
/// "<the panel's summary>"}...]`, one row per panel the compiled workspace
/// carries, sorted by content id.
///
/// `id` is what `jas_panel_plan` takes. `summary` is the panel's display
/// name, and it is `null` when the panel has none, or when it is a template
/// (the plan's rule for a templated display string: never sent raw). A shell
/// shows its own fallback for a `null`, knowingly.
pub fn panel_list(panels: &Value) -> Value {
    let Some(map) = panels.as_object() else { return json!([]) };
    let mut ids: Vec<&String> = map.keys().collect();
    ids.sort_unstable();
    Value::Array(
        ids.into_iter()
            .map(|id| {
                let summary = map[id]
                    .get("summary")
                    .and_then(Value::as_str)
                    .filter(|s| !s.contains("{{"))
                    .map_or(Value::Null, |s| Value::String(s.to_string()));
                json!({"id": id, "summary": summary})
            })
            .collect(),
    )
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

    /// The spec node a plan path names, walked from the panel's `content` by
    /// the path scheme alone (a declared child is `children[i]`; under a
    /// `foreach` every index names the `do` template). An independent route to
    /// the node, so a check reading it does not agree with the plan by
    /// construction.
    pub(crate) fn node_at<'a>(panel: &'a Value, path: &Value) -> Option<&'a Value> {
        let mut cur = panel.get("content")?;
        for i in path.as_array()? {
            let i = usize::try_from(i.as_i64()?).ok()?;
            cur = if cur.get("foreach").is_some_and(Value::is_object) {
                cur.get("do")?
            } else {
                cur.get("children")?.get(i)?
            };
        }
        Some(cur)
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
        let mut withheld_total = 0usize;
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
                    let (plan, joined_from) = panel_plan(spec, w, h, ctx, ws.icons());
                    let at = format!("{pid} {sname} {w}x{h}");
                    assert_eq!(joined_from, rows, "{at}: the plan must be joined from bind_values' rows");
                    let (values, n) = checks::plan_values(&plan);
                    // A row whose value is a template is WITHHELD, not carried;
                    // every other row is carried exactly once.
                    let mut want = checks::row_values(&rows);
                    let before = want.len();
                    want.retain(|_, v| !v.contains("{{"));
                    let held: BTreeSet<String> = plan["withheld"].as_array().unwrap().iter()
                        .map(|w| format!("{}|{}", w["path"], w["key"].as_str().unwrap_or("")))
                        .collect();
                    for r in rows.as_array().unwrap() {
                        if r["value"].as_str().is_some_and(|v| v.contains("{{")) {
                            let k = format!("{}|{}", r["path"], r["key"].as_str().unwrap_or(""));
                            assert!(held.contains(&k), "{at}: templated row {k} is not withheld");
                            withheld_total += 1;
                        }
                    }
                    assert_eq!(n, want.len(), "{at}: values carried != bind rows ({before} rows)");
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
                            if rec["id"].as_str().is_some_and(|i| i.contains("{{")) {
                                assert_eq!(e["id"], "", "{at}: {list} {p} templated id crossed");
                                assert!(held.contains(&format!("{p}|id")), "{at}: {p} id not withheld");
                                withheld_total += 1;
                            } else {
                                assert_eq!(e["id"], rec["id"], "{at}: {list} {p} id");
                            }
                            if list == "containers" {
                                containers_total += 1;
                                assert!(!rp_paths.contains(&p), "{at}: container {p} is also a render_plan item");
                                assert!(
                                    !e["values"].as_object().unwrap().is_empty()
                                        || held.iter().any(|h| h.starts_with(&format!("{p}|"))),
                                    "{at}: container {p} carries no value and withholds none"
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
        // The real workspace carries both withheld shapes (brushes' templated
        // tile id, concepts' templated background), so the branches above ran.
        assert!(withheld_total > 0, "vacuous: nothing was withheld on the real workspace");
    }

    /// ⭐ THE PARTITION, AGAINST A PREDICATE THAT DOES NOT COME FROM `render_plan`.
    ///
    /// Q1 takes its leaf and chrome lists FROM `render_plan`, so a defect in
    /// `render_plan`'s own partition moves the oracle with the subject. Mutation
    /// found exactly that: sending every chrome container to the omitted list
    /// survived every other arm, because the oracle's chrome list emptied too.
    /// Here the partition is re-derived from `widget_tree`'s records (type,
    /// style keys, bind keys) over `layout_panel`'s paths: a layout-only type
    /// with a border/background is chrome; any other type is a leaf; a
    /// layout-only type without chrome is a container exactly when it has a
    /// bound row.
    #[test]
    fn the_plan_partition_follows_an_independent_predicate() {
        const LAYOUT_ONLY: [&str; 6] = ["container", "row", "col", "grid", "panel", "disclosure"];
        let has = |keys: &Value, k: &str| keys.as_array().is_some_and(|a| a.iter().any(|x| x == k));
        let ws = Workspace::load().expect("workspace");
        let (mut chrome_total, mut leaves_total, mut containers_total) = (0usize, 0usize, 0usize);
        for pid in &panel_ids(&ws) {
            let spec = ws.panel(pid).unwrap();
            for (sname, ctx) in &scopes() {
                let wt: BTreeMap<String, Value> = widget_tree(spec, ctx)
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|r| (r["path"].to_string(), r.clone()))
                    .collect();
                let bound: BTreeSet<String> = bind_values(spec, ctx)
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|r| r["path"].to_string())
                    .collect();
                for (w, h) in SIZES {
                    let at = format!("{pid} {sname} {w}x{h}");
                    let (mut chrome, mut leaves, mut containers) = (vec![], vec![], vec![]);
                    for e in layout_panel(spec, w, h, ctx).as_array().unwrap() {
                        let p = e["path"].to_string();
                        let rec = &wt[&p];
                        let t = rec["type"].as_str().unwrap_or("");
                        if !LAYOUT_ONLY.contains(&t) {
                            leaves.push(p);
                        } else if ["border", "background", "bg"].iter().any(|k| has(&rec["style"], k))
                            || has(&rec["bind"], "background")
                        {
                            chrome.push(p);
                        } else if bound.contains(&p) {
                            containers.push(p);
                        }
                    }
                    let (plan, _) = panel_plan(spec, w, h, ctx, ws.icons());
                    let paths = |list: &str| -> Vec<String> {
                        plan[list].as_array().unwrap().iter().map(|e| e["path"].to_string()).collect()
                    };
                    assert_eq!(paths("chrome"), chrome, "{at}: chrome");
                    assert_eq!(paths("leaves"), leaves, "{at}: leaves");
                    assert_eq!(paths("containers"), containers, "{at}: containers");
                    chrome_total += chrome.len();
                    leaves_total += leaves.len();
                    containers_total += containers.len();
                }
            }
        }
        assert!(
            chrome_total > 0 && leaves_total > 0 && containers_total > 0,
            "vacuous partition: chrome={chrome_total} leaves={leaves_total} containers={containers_total}"
        );
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
        let (plan, _) = panel_plan(&panel, 228, 0, &ctx, &Value::Null);
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
        let (plan, _) = panel_plan(spec, 228, 0, &ctx, ws.icons());
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
        let (plan, _) = panel_plan(spec, 228, 0, &engine_scope(), ws.icons());
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
        let (plan_a, _) = panel_plan(spec, 228, 600, &a, ws.icons());
        let (plan_b, _) = panel_plan(spec, 228, 600, &b, ws.icons());

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

    // -----------------------------------------------------------------------
    // W2-5a -- WHAT A PERSON READS. RED FIRST: written against a plan that
    // carried no display text at all (the dump that found it: 22 align leaves,
    // three `text` leaves with `values: {}`, no icon name and no summary on any
    // of the 17 buttons).
    // -----------------------------------------------------------------------

    /// Every node in a spec, depth-first, with its type (an independent walk:
    /// the counts below do not come from the plan).
    fn count_types(node: &Value, out: &mut BTreeMap<String, usize>) {
        if let Some(t) = node.get("type").and_then(Value::as_str) {
            *out.entry(t.to_string()).or_default() += 1;
        }
        for k in ["children", "do"] {
            match node.get(k) {
                Some(Value::Array(a)) => a.iter().for_each(|c| count_types(c, out)),
                Some(c @ Value::Object(_)) => count_types(c, out),
                _ => {}
            }
        }
    }

    /// ⭐ THE ALIGN PLAN CARRIES WHAT A PERSON READS. Every `text` leaf carries
    /// its literal `content`, every `icon_button` its `summary` and `icon`, and
    /// the plan carries each named icon's workspace definition verbatim.
    #[test]
    fn the_align_plan_carries_its_display_text_and_its_icons() {
        let ws = Workspace::load().expect("workspace");
        let spec = ws.panel("align_panel_content").expect("align");
        let (plan, _) = panel_plan(spec, 228, 0, &engine_scope(), ws.icons());
        let leaves = plan["leaves"].as_array().expect("leaves");
        // The artifact's own first leaf, as the dump printed it.
        assert_eq!(leaves[0]["static"], json!({"content": "Align Objects:"}), "{}", leaves[0]);

        let mut want = BTreeMap::new();
        count_types(&spec["content"], &mut want);
        let (mut texts, mut buttons) = (0usize, 0usize);
        let mut named = BTreeSet::new();
        for e in leaves {
            let node = checks::node_at(spec, &e["path"]).expect("a plan path names a spec node");
            match e["type"].as_str() {
                Some("text") => {
                    texts += 1;
                    let c = node["content"].as_str().expect("a literal content");
                    assert!(!c.is_empty(), "{e}");
                    assert_eq!(e["static"], json!({"content": c}), "{e}");
                }
                Some("icon_button") => {
                    buttons += 1;
                    let name = node["icon"].as_str().expect("an icon name");
                    assert_eq!(
                        e["static"],
                        json!({"icon": name, "summary": node["summary"]}),
                        "{e}"
                    );
                    let def = &ws.icons()[name];
                    assert_eq!(
                        plan["icons"][name],
                        json!({"viewbox": def["viewbox"], "svg": def["svg"]}),
                        "{name}"
                    );
                    named.insert(name.to_string());
                }
                _ => {}
            }
        }
        assert!(texts > 0 && buttons > 0, "vacuous: texts={texts} buttons={buttons}");
        assert_eq!(Some(&texts), want.get("text"), "every text node is a leaf: {want:?}");
        assert_eq!(Some(&buttons), want.get("icon_button"), "every button is a leaf: {want:?}");
        let keys: BTreeSet<String> =
            plan["icons"].as_object().expect("icons map").keys().cloned().collect();
        assert_eq!(keys, named, "the map holds exactly the icons the plan names");
        assert_eq!(plan["icons_missing"], json!([]), "{plan}");
        assert_eq!(plan["withheld"], json!([]), "{plan}");
    }

    /// The allow-list, in both directions, on one synthetic node: every listed
    /// literal crosses, and an expression, a prose field, a style value and a
    /// templated string do not. A templated `summary` is WITHHELD by path and key
    /// (bind_values resolves only `content`/`label`); a templated `content` is a
    /// value, not static and not withheld.
    #[test]
    fn static_carries_only_allowlisted_literals_and_withholds_a_templated_one() {
        let panel = json!({"content": {"type": "col", "children": [
            {"type": "icon_button", "id": "b", "icon": "zz_icon", "summary": "Hint {{panel.a}}",
             "description": "prose", "enabled_when": "panel.a", "disabled": "panel.a",
             "label": "Go", "unit": "pt", "suffix": "%", "placeholder": "type",
             "style": {"size": 20}},
            {"type": "text", "id": "t", "content": "{{panel.a}}"},
            {"type": "icon", "id": "i", "name": "zz_icon"},
        ]}});
        let icons = json!({"zz_icon": {"viewbox": "0 0 1 1", "svg": "<rect/>", "extra": "x"}});
        let ctx = json!({"panel": {"a": "x"}});
        let (plan, _) = panel_plan(&panel, 228, 0, &ctx, &icons);
        let l = &plan["leaves"];
        assert_eq!(
            l[0]["static"],
            json!({"icon": "zz_icon", "label": "Go", "unit": "pt", "suffix": "%", "placeholder": "type"}),
            "{plan}"
        );
        assert_eq!(l[1]["static"], json!({}), "{plan}");
        assert_eq!(l[1]["values"], json!({"content": "x"}), "{plan}");
        assert_eq!(l[2]["static"], json!({"name": "zz_icon"}), "{plan}");
        assert_eq!(plan["withheld"], json!([{"path": [0], "key": "summary"}]), "{plan}");
        assert_eq!(
            plan["icons"],
            json!({"zz_icon": {"viewbox": "0 0 1 1", "svg": "<rect/>"}}),
            "only the two fields a shell draws from"
        );
        checks::nothing_interpretable(&serde_json::to_string(&plan).unwrap())
            .expect("nothing interpretable crossed");
    }

    /// ⛔ A TEMPLATED `id` NEVER CROSSES RAW. Found by the every-scope arm below
    /// on the real workspace: under a corpus scope, brushes' foreach tiles
    /// (`bp_tile_{{lib.id}}_{{brush.slug}}`) put a raw template in the plan's
    /// `id`, which the engine-scope Q2 arm could not see (the engine's foreach
    /// sources are empty). No port resolves an id (the web renderer uses it
    /// raw), and a foreach widget is not addressable by id (D12), so the id is
    /// sent empty and named in `withheld`.
    #[test]
    fn a_templated_id_is_withheld_not_sent_raw() {
        let panel = json!({"content": {"type": "col", "children": [
            {"type": "text", "id": "t_{{panel.a}}", "content": "hi"},
            {"type": "text", "id": "plain", "content": "hi"},
        ]}});
        let (plan, _) = panel_plan(&panel, 228, 0, &json!({"panel": {"a": "x"}}), &Value::Null);
        assert_eq!(plan["leaves"][0]["id"], "", "{plan}");
        assert_eq!(plan["withheld"], json!([{"path": [0], "key": "id"}]), "{plan}");
        // The control: a literal id crosses as itself.
        assert_eq!(plan["leaves"][1]["id"], "plain", "{plan}");
        checks::nothing_interpretable(&serde_json::to_string(&plan).unwrap())
            .expect("nothing interpretable crossed");
    }

    /// ⛔ A VALUE THAT RESOLVES TO A TEMPLATE NEVER CROSSES RAW EITHER. Found
    /// the same way: concepts' rows carry `bind.background` =
    /// `{{theme.colors.selection}}` under a corpus scope, a binding whose
    /// RESULT is a template the web renderer interpolates a second time. The
    /// plan withholds the value by path and key, and keeps the entry.
    #[test]
    fn a_value_that_resolves_to_a_template_is_withheld() {
        let panel = json!({"content": {"type": "col", "children": [
            {"type": "container", "style": {"border": "1px"}, "bind": {"background": "panel.bg"},
             "children": [{"type": "text", "content": "x"}]},
            {"type": "text", "id": "v", "content": "x", "bind": {"value": "panel.plain"}},
        ]}});
        let ctx = json!({"panel": {"bg": "{{theme.colors.selection}}", "plain": "ok"}});
        let (plan, rows) = panel_plan(&panel, 228, 0, &ctx, &Value::Null);
        assert!(rows.to_string().contains("{{theme"), "the fixture must reproduce the row: {rows}");
        assert_eq!(plan["chrome"][0]["path"], json!([0]), "{plan}");
        assert_eq!(plan["chrome"][0]["values"], json!({}), "{plan}");
        assert_eq!(plan["withheld"], json!([{"path": [0], "key": "bind.background"}]), "{plan}");
        // The control: a plain value on a sibling crosses.
        assert_eq!(plan["leaves"][1]["values"], json!({"bind.value": "ok"}), "{plan}");
        checks::nothing_interpretable(&serde_json::to_string(&plan).unwrap())
            .expect("nothing interpretable crossed");
    }

    /// Four shapes the real workspace does not carry today, each found by a
    /// surviving mutant (W2-5a round 2):
    /// * a value whose template is MID-string (M17: a `starts_with` test passed
    ///   every real row, because concepts' value begins with the braces);
    /// * a layout-only container whose ONLY bound row is withheld (M18: its
    ///   entry must stay listed, or the shell never learns the visibility it
    ///   cannot know);
    /// * a chrome entry that names an icon (M21: icons were collected from
    ///   leaves alone, and nothing noticed);
    /// * an empty icon name (M22: it would be listed as a missing icon named "").
    #[test]
    fn withheld_and_icons_hold_for_shapes_the_workspace_lacks_today() {
        let panel = json!({"content": {"type": "col", "children": [
            {"type": "text", "id": "mid", "content": "x", "bind": {"value": "panel.mid"}},
            {"type": "container", "id": "veiled", "bind": {"visible": "panel.veil"},
             "children": [{"type": "text", "content": "inside"}]},
            {"type": "container", "id": "framed", "style": {"border": "1px"}, "icon": "zz_chrome",
             "children": [{"type": "text", "content": "framed"}]},
            {"type": "icon_button", "id": "blank", "icon": "", "summary": "s"},
        ]}});
        let icons = json!({"zz_chrome": {"viewbox": "0 0 1 1", "svg": "<c/>"}});
        let ctx = json!({"panel": {"mid": "pre {{theme.x}}", "veil": "{{theme.y}}"}});
        let (plan, _) = panel_plan(&panel, 228, 0, &ctx, &icons);
        assert_eq!(plan["leaves"][0]["values"], json!({}), "{plan}");
        let containers = plan["containers"].as_array().expect("containers");
        assert!(
            containers.iter().any(|c| c["path"] == json!([1]) && c["values"] == json!({})),
            "the veiled container must stay listed with its value withheld: {plan}"
        );
        let held: BTreeSet<String> = plan["withheld"].as_array().unwrap().iter()
            .map(|w| format!("{}|{}", w["path"], w["key"].as_str().unwrap()))
            .collect();
        assert!(held.contains("[0]|bind.value"), "mid-string template not withheld: {plan}");
        assert!(held.contains("[1]|bind.visible"), "container value not withheld: {plan}");
        assert_eq!(plan["chrome"][0]["static"], json!({"icon": "zz_chrome"}), "{plan}");
        assert_eq!(plan["icons"], json!({"zz_chrome": {"viewbox": "0 0 1 1", "svg": "<c/>"}}), "{plan}");
        // An EMPTY icon name names nothing (M22): not an icon, not a missing one.
        assert_eq!(plan["icons_missing"], json!([]), "{plan}");
        checks::nothing_interpretable(&serde_json::to_string(&plan).unwrap())
            .expect("nothing interpretable crossed");
    }

    /// An icon the workspace does not define is NAMED, never dropped; a bound
    /// icon is resolved from the row that names it; `name` is an icon only on
    /// an `icon` node.
    #[test]
    fn an_undefined_icon_is_named_missing_and_a_bound_icon_is_resolved() {
        let panel = json!({"content": {"type": "col", "children": [
            {"type": "icon_button", "id": "gone", "icon": "zz_nowhere", "summary": "s"},
            {"type": "icon_button", "id": "gone_again", "icon": "zz_nowhere", "summary": "s"},
            {"type": "icon_button", "id": "bound", "icon": "zz_static", "summary": "s",
             "bind": {"icon": "panel.which"}},
            {"type": "text_input", "id": "n", "name": "zz_not_an_icon", "placeholder": "p"},
        ]}});
        let def = |v: &str| json!({"viewbox": v, "svg": "<g/>"});
        let icons = json!({"zz_static": def("0 0 1 1"), "zz_bound": def("0 0 2 2"),
                           "zz_not_an_icon": def("0 0 3 3")});
        let ctx = json!({"panel": {"which": "zz_bound"}});
        let (plan, _) = panel_plan(&panel, 228, 0, &ctx, &icons);
        // Named by two buttons, listed ONCE (mutation M11 survived without the
        // second button).
        assert_eq!(plan["icons_missing"], json!(["zz_nowhere"]), "{plan}");
        assert_eq!(
            plan["icons"],
            json!({"zz_static": def("0 0 1 1"), "zz_bound": def("0 0 2 2")}),
            "{plan}"
        );
        // The control: the bound row is what named `zz_bound`.
        assert_eq!(plan["leaves"][2]["values"]["bind.icon"], json!("zz_bound"), "{plan}");
    }

    /// ⭐ ON EVERY PANEL, IN EVERY SCOPE, AT EVERY SIZE: every static entry is
    /// an allow-listed key whose value is the spec node's own literal; every
    /// allow-listed literal on a placed node is carried (none dropped); every
    /// named icon is in `icons` or `icons_missing`, never both; and nothing
    /// interpretable crossed.
    #[test]
    fn static_and_icons_are_complete_and_exact_on_every_panel() {
        let ws = Workspace::load().expect("workspace");
        let defs = ws.icons().as_object().expect("icons map");
        let (mut carried, mut icons_seen, mut missing_seen) = (0usize, 0usize, 0usize);
        for pid in panel_ids(&ws) {
            let spec = ws.panel(&pid).unwrap();
            for (sname, ctx) in scopes() {
                for (w, h) in SIZES {
                    let at = format!("{pid} {sname} {w}x{h}");
                    let (plan, _) = panel_plan(spec, w, h, &ctx, ws.icons());
                    checks::nothing_interpretable(&serde_json::to_string(&plan).unwrap())
                        .unwrap_or_else(|err| panic!("{at}: {err}"));
                    let mut named = BTreeSet::new();
                    for list in checks::LISTS {
                        for e in plan[list].as_array().unwrap() {
                            let node = checks::node_at(spec, &e["path"])
                                .unwrap_or_else(|| panic!("{at}: {} names no node", e["path"]));
                            let st = e["static"].as_object()
                                .unwrap_or_else(|| panic!("{at}: no static map on {e}"));
                            for (k, v) in st {
                                assert!(super::STATIC_KEYS.contains(&k.as_str()), "{at}: {k} crossed");
                                assert_eq!(Some(v), node.get(k), "{at}: {k} is not the node's own");
                                carried += 1;
                            }
                            for k in super::STATIC_KEYS {
                                if let Some(s) = node.get(k).and_then(Value::as_str) {
                                    if !s.contains("{{") {
                                        assert!(st.contains_key(k), "{at}: literal {k} dropped from {e}");
                                    }
                                }
                            }
                            if let Some(n) = st.get("icon").and_then(Value::as_str) {
                                named.insert(n.to_string());
                            }
                            if e["type"] == "icon" {
                                if let Some(n) = st.get("name").and_then(Value::as_str) {
                                    named.insert(n.to_string());
                                }
                            }
                            if let Some(n) = e["values"]["bind.icon"].as_str() {
                                named.insert(n.to_string());
                            }
                        }
                    }
                    let icons = plan["icons"].as_object().unwrap();
                    let missing: BTreeSet<String> = plan["icons_missing"].as_array().unwrap()
                        .iter().map(|v| v.as_str().unwrap().to_string()).collect();
                    for n in &named {
                        match (icons.get(n), missing.contains(n)) {
                            (Some(d), false) => {
                                assert_eq!(d["svg"], defs[n]["svg"], "{at}: {n}");
                                assert_eq!(d["viewbox"], defs[n]["viewbox"], "{at}: {n}");
                                icons_seen += 1;
                            }
                            (None, true) => {
                                assert!(!defs.contains_key(n), "{at}: {n} is defined");
                                missing_seen += 1;
                            }
                            other => panic!("{at}: {n} is {other:?}"),
                        }
                    }
                    assert_eq!(icons.len() + missing.len(), named.len(), "{at}: an unnamed icon crossed");
                }
            }
        }
        assert!(carried > 0 && icons_seen > 0 && missing_seen > 0,
            "vacuous: carried={carried} icons={icons_seen} missing={missing_seen}");
    }

    /// W2b-2: the list is sorted by content id, whatever order the map
    /// iterates in, and each row carries exactly `id` and `summary`.
    ///
    /// ⚠️ A `serde_json::Map` built without `preserve_order` iterates sorted
    /// already, so the input order below may not reach the function. The
    /// explicit sort is what makes the order independent of that feature, and
    /// the mutant that drops it is recorded as surviving in this build if it
    /// does.
    #[test]
    fn panel_list_rows_are_sorted_by_id_with_the_literal_summary() {
        let panels = json!({
            "b_panel_content": {"summary": "Bee", "content": {}},
            "a_panel_content": {"summary": "Ay"},
            "c_panel_content": {"summary": "Sea"},
        });
        assert_eq!(
            super::panel_list(&panels),
            json!([
                {"id": "a_panel_content", "summary": "Ay"},
                {"id": "b_panel_content", "summary": "Bee"},
                {"id": "c_panel_content", "summary": "Sea"},
            ])
        );
    }

    /// W2b-2: a summary the shell cannot show as written is `null`, never
    /// raw: a template (the plan's rule for a templated display string), a
    /// non-string, and an absent key. The row itself is still listed, since
    /// the panel still opens.
    #[test]
    fn panel_list_sends_null_for_a_summary_it_will_not_send_raw() {
        let panels = json!({
            "t_panel_content": {"summary": "Hi {{panel.name}}"},
            "n_panel_content": {"summary": 7},
            "x_panel_content": {},
            "ok_panel_content": {"summary": "Fine"},
        });
        let got = super::panel_list(&panels);
        let by_id: BTreeMap<String, Value> = got
            .as_array()
            .expect("an array")
            .iter()
            .map(|r| (r["id"].as_str().expect("a string id").to_string(), r["summary"].clone()))
            .collect();
        assert_eq!(by_id.len(), 4, "every panel is listed: {got}");
        assert_eq!(by_id["t_panel_content"], Value::Null, "{got}");
        assert_eq!(by_id["n_panel_content"], Value::Null, "{got}");
        assert_eq!(by_id["x_panel_content"], Value::Null, "{got}");
        // The control: the same function sends a literal summary as written, so
        // the three nulls above are the rule and not a function that sends none.
        assert_eq!(by_id["ok_panel_content"], json!("Fine"), "{got}");
        assert!(!got.to_string().contains("{{"), "a template crossed: {got}");
    }

    /// W2b-2: anything but a map of panels is an empty list, not a panic.
    #[test]
    fn panel_list_of_a_non_map_is_empty() {
        assert_eq!(super::panel_list(&Value::Null), json!([]));
        assert_eq!(super::panel_list(&json!(["a_panel_content"])), json!([]));
    }
}
