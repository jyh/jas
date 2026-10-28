//! Views of the document that a panel binds under `active_document.*`, built
//! web-free so the web view (`renderer::build_active_document_view`) and the
//! engine's scope (`panel_scope::engine_scope`) call ONE definition (W2b-15).
//! They read only the document and the workspace.

use serde_json::{json, Value};

use crate::document::document::Document;
use crate::geometry::element::Element;
use crate::geometry::live::LiveVariant;

/// The Brushes panel's two gates (BRUSHES.md § Bottom toolbar;
/// runtime_contexts.yaml): `(selection_has_brushed_stroke,
/// selection_is_single_brushed_stroke)`. A selected element is a brushed stroke
/// when it is a path carrying a non-empty `stroke_brush`; only the selected
/// elements are read, never their descendants. A stale selection path counts as
/// nothing, never a panic.
pub fn brushed_stroke_facts(doc: &Document) -> (bool, bool) {
    let brushed = doc.selection.iter().filter(|es| matches!(
        doc.get_element(&es.path),
        Some(Element::Path(p)) if p.stroke_brush.as_deref().is_some_and(|b| !b.is_empty())
    )).count();
    (brushed > 0, doc.selection.len() == 1 && brushed == 1)
}

/// Symbols view (SYMBOLS.md §8). One row per master in the off-canvas
/// store. `name` is the master's common.name, falling back to a
/// positional "Symbol N" label so every row shows something readable.
/// `usage_count` is the number of live instances of the master — the
/// length of its reverse-dependency list (rdeps) in the dependency
/// index, the same signal that gates the reference-aware delete.
pub fn symbols_view(doc: &Document) -> Value {
    let dep_index = crate::document::dependency_index::dependency_index(doc);
    let rows: Vec<Value> = doc
        .symbols
        .iter()
        .enumerate()
        .map(|(i, m)| {
            let id = m.common().id.clone().unwrap_or_default();
            let name = match m.common().name.as_deref() {
                Some(n) if !n.is_empty() => n.to_string(),
                _ => format!("Symbol {}", i + 1),
            };
            let usage_count = dep_index
                .rdeps
                .get(&id)
                .map(|v| v.len())
                .unwrap_or(0);
            json!({
                "id": id,
                "name": name,
                "usage_count": usage_count,
            })
        })
        .collect();
    Value::Array(rows)
}

/// `active_document.selected_concept`: when exactly one `Generated` concept
/// instance is selected, its concept's view ([`concept_view`]); `null` otherwise,
/// so the Concepts panel switches to PARAMS mode only then.
pub fn selected_concept_view(doc: &Document) -> Value {
    if doc.selection.len() != 1 {
        return Value::Null;
    }
    match doc.get_element(&doc.selection[0].path) {
        Some(Element::Live(LiveVariant::Generated(ge))) => concept_view(&ge.concept_id, &ge.params),
        _ => Value::Null,
    }
}

/// Build `active_document.selected_concept` for a selected `Generated` instance:
/// the concept's display name + its declared param schema (name/min/max) merged
/// with the instance's current values (CONCEPTS.md §6.4, Slice 2). Null if the
/// concept is not registered.
pub fn concept_view(
    concept_id: &str,
    instance_params: &serde_json::Value,
) -> serde_json::Value {
    let Some(ws) = crate::interpreter::workspace::Workspace::load() else {
        return serde_json::Value::Null;
    };
    let Some(concept) = ws.concept(concept_id) else {
        return serde_json::Value::Null;
    };
    let name = concept
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or(concept_id);
    let mut params_out: Vec<serde_json::Value> = Vec::new();
    if let Some(schema) = concept.get("params").and_then(|v| v.as_array()) {
        for p in schema {
            let Some(pname) = p.get("name").and_then(|v| v.as_str()) else {
                continue;
            };
            let value = instance_params
                .get(pname)
                .cloned()
                .or_else(|| p.get("default").cloned())
                .unwrap_or(serde_json::Value::Null);
            let mut entry = serde_json::json!({ "name": pname, "value": value });
            if let Some(min) = p.get("min") {
                entry["min"] = min.clone();
            }
            if let Some(max) = p.get("max") {
                entry["max"] = max.clone();
            }
            params_out.push(entry);
        }
    }
    // The concept's named operations (CONCEPTS.md §9): id + label + description,
    // so the panel can render a button per operation. Empty when the concept
    // declares no `operations:`.
    let mut operations_out: Vec<serde_json::Value> = Vec::new();
    if let Some(ops) = concept.get("operations").and_then(|v| v.as_array()) {
        for o in ops {
            let Some(oid) = o.get("id").and_then(|v| v.as_str()) else {
                continue;
            };
            operations_out.push(serde_json::json!({
                "id": oid,
                "label": o.get("label").and_then(|v| v.as_str()).unwrap_or(oid),
                "description": o.get("description").and_then(|v| v.as_str()).unwrap_or(""),
            }));
        }
    }
    // The concept's VIOLATED constraints (CONCEPTS.md §11): evaluate each
    // constraint's `check` over the instance's params; collect the ones that are
    // NOT truthy (`to_bool`, the same truthiness `if` uses), in declared order.
    // Advisory + read-only — the panel surfaces these as a warning. Empty when
    // the concept declares no `constraints:` or all hold.
    let mut violations_out: Vec<serde_json::Value> = Vec::new();
    if let Some(cons) = concept.get("constraints").and_then(|v| v.as_array()) {
        let mut ctx = serde_json::Map::new();
        ctx.insert("param".to_string(), instance_params.clone());
        let ctx = serde_json::Value::Object(ctx);
        for c in cons {
            let Some(cid) = c.get("id").and_then(|v| v.as_str()) else {
                continue;
            };
            let Some(check) = c.get("check").and_then(|v| v.as_str()) else {
                continue;
            };
            if !crate::interpreter::expr::eval(check, &ctx).to_bool() {
                violations_out.push(serde_json::json!({
                    "id": cid,
                    "message": c.get("message").and_then(|v| v.as_str()).unwrap_or(""),
                }));
            }
        }
    }
    serde_json::json!({
        "concept_id": concept_id,
        "name": name,
        "params": params_out,
        "operations": operations_out,
        "violations": violations_out,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The shared fixture (`test_fixtures/layers/element_tree.json`), as the
    /// reference reads it (STATUS-jas item 38 step 1).
    #[test]
    fn element_tree_rows_match_the_shared_fixture() {
        let raw = include_str!(concat!("../../../test_fixtures/", "layers/element_tree.json"));
        let fx: Value = serde_json::from_str(raw).unwrap();
        let cases = fx["cases"].as_array().unwrap();
        assert!(cases.len() >= 2, "the fixture is not vacuous");
        for case in cases {
            let doc = crate::geometry::test_json::test_json_to_document(&case["document"].to_string());
            assert_eq!(element_tree(&doc), case["expected"], "{}", case["name"]);
        }
    }

    /// `lp_tree`'s row template keys its binds by PATH (item 38 step 3). flask
    /// §602 measured every row showing its rename box when they compared
    /// `node.id` (null on every row) with a null `panel.renaming_element`.
    /// Twin of the reference's `test_layers_row_template.py`.
    #[test]
    fn the_layers_row_template_reads_paths() {
        let ws = crate::interpreter::workspace::Workspace::load().expect("the bundle");
        fn find<'a>(v: &'a Value, id: &str) -> Option<&'a Value> {
            if v.get("id").and_then(Value::as_str) == Some(id) { return Some(v); }
            match v {
                Value::Object(m) => m.values().find_map(|c| find(c, id)),
                Value::Array(a) => a.iter().find_map(|c| find(c, id)),
                _ => None,
            }
        }
        let tree = find(&ws.data()["panels"]["layers_panel_content"], "lp_tree").expect("lp_tree").clone();
        let raw = include_str!(concat!("../../../test_fixtures/", "layers/element_tree.json"));
        let fx: Value = serde_json::from_str(raw).unwrap();
        let rows = fx["cases"][0]["expected"].clone();
        let widget = |id: &str| tree["do"]["children"].as_array().unwrap().iter()
            .find(|c| c["id"] == id).unwrap_or_else(|| panic!("{id}")).clone();
        let visible = |ctx: &Value, id: &str| -> Vec<bool> {
            let src = tree["foreach"]["source"].as_str().unwrap();
            let crate::interpreter::expr_types::Value::List(expanded) = crate::interpreter::expr::eval(src, ctx) else {
                panic!("the foreach source is not a list");
            };
            let expr = widget(id)["bind"]["visible"].as_str().unwrap().to_string();
            expanded.iter().map(|r| {
                let mut c = ctx.clone();
                c["node"] = r.clone();
                crate::interpreter::expr::eval(&expr, &c).to_bool()
            }).collect()
        };
        let ctx = |renaming: Value, collapsed: Value| json!({
            "active_document": {"element_tree": rows},
            "panel": {"layers_panel_selection": [], "isolation_stack": [],
                      "collapsed_paths": collapsed, "renaming_element": renaming},
        });
        let n = rows.as_array().unwrap().len();
        let idle = ctx(Value::Null, json!([]));
        assert_eq!(visible(&idle, "lp_name"), vec![true; n], "every name shows");
        assert_eq!(visible(&idle, "lp_name_edit"), vec![false; n], "no rename box");
        let renaming = ctx(rows[2]["path"].clone(), json!([]));
        assert_eq!(visible(&renaming, "lp_name_edit").iter().filter(|b| **b).count(), 1);
        let collapsed = ctx(Value::Null, json!([[0, 1]]));
        assert_eq!(visible(&collapsed, "lp_name").len(), n - 1, "the collapsed group hides its child");
    }

    /// flask §603: the render plan sent the expanded `lp_tree` as a leaf of type
    /// `tree_view` as well as its rows, so the shell drew a placeholder behind
    /// them. An expanded tree is layout-only, like any foreach container.
    #[test]
    fn the_expanded_tree_is_not_also_drawn_as_a_leaf() {
        let ws = crate::interpreter::workspace::Workspace::load().expect("the bundle");
        let raw = include_str!(concat!("../../../test_fixtures/", "layers/element_tree.json"));
        let fx: Value = serde_json::from_str(raw).unwrap();
        let ctx = json!({
            "active_document": {"element_tree": fx["cases"][0]["expected"]},
            "panel": {"layers_panel_selection": [], "isolation_stack": [],
                      "collapsed_paths": [], "renaming_element": null},
        });
        let plan = crate::interpreter::panel_layout::render_plan(
            &ws.data()["panels"]["layers_panel_content"], 228, 600, &ctx);
        let kinds: Vec<&str> = plan.leaves.iter().filter_map(|l| l.node["type"].as_str()).collect();
        assert!(!kinds.contains(&"tree_view"), "{kinds:?}");
        assert!(kinds.iter().filter(|k| **k == "icon_button").count() >= 10, "the control: the rows' leaves");
    }

    /// The same cases through the expression language: `layers.yaml`
    /// `lp_tree`'s foreach source calls `tree_visible_rows`, and the panel
    /// selection arrives as path markers (STATUS-jas item 38).
    #[test]
    fn tree_visible_rows_through_the_evaluator() {
        let raw = include_str!(concat!("../../../test_fixtures/", "layers/element_tree.json"));
        let fx: Value = serde_json::from_str(raw).unwrap();
        let cases = fx["visible_cases"].as_array().unwrap();
        assert!(cases.len() >= 4, "the fixture is not vacuous");
        for case in cases {
            let doc = crate::geometry::test_json::test_json_to_document(&case["document"].to_string());
            let b = &case["binds"];
            let psel: Vec<Value> = b["panel_selection"].as_array().unwrap().iter()
                .map(|p| json!({"__path__": p})).collect();
            let ctx = json!({
                "active_document": {"element_tree": element_tree(&doc)},
                "panel": {"layers_panel_selection": psel},
                "collapsed": b["collapsed"], "renaming": b["renaming"],
            });
            let got = crate::interpreter::expr::eval(
                "tree_visible_rows(active_document.element_tree, collapsed, panel.layers_panel_selection, renaming)",
                &ctx);
            assert_eq!(got, crate::interpreter::expr_types::Value::List(
                case["expected"].as_array().unwrap().clone()), "{}", case["name"]);
        }
    }

    /// Step 1b: the rows to draw, resolved from `element_tree` and the
    /// widget's binds (the fixture's `visible_cases`, flask §591).
    #[test]
    fn tree_visible_rows_match_the_shared_fixture() {
        let raw = include_str!(concat!("../../../test_fixtures/", "layers/element_tree.json"));
        let fx: Value = serde_json::from_str(raw).unwrap();
        let cases = fx["visible_cases"].as_array().unwrap();
        assert!(cases.len() >= 4, "the fixture is not vacuous");
        let paths = |v: &Value| -> Vec<Vec<usize>> {
            serde_json::from_value(v.clone()).unwrap()
        };
        for case in cases {
            let doc = crate::geometry::test_json::test_json_to_document(&case["document"].to_string());
            let b = &case["binds"];
            let renaming: Option<Vec<usize>> = serde_json::from_value(b["renaming"].clone()).unwrap();
            let got = tree_visible_rows(&element_tree(&doc), &paths(&b["collapsed"]),
                &paths(&b["panel_selection"]), renaming.as_deref());
            assert_eq!(got, case["expected"], "{}", case["name"]);
        }
    }
    use crate::document::test_fixture::{brushed_path as path, model_with, rect};

    const B: Option<&str> = Some("default_brushes/flat_10");

    /// A Transformed wrapper is a container one can ENTER (route 4 slice 3b):
    /// isolating it is how its child is edited. It is not a group, so it
    /// does not light Flatten Artwork's `has_group`.
    #[test]
    fn a_transformed_wrapper_is_a_container_and_not_a_group() {
        use crate::geometry::live::{LiveVariant, TransformedElem};
        let w = TransformedElem::new(std::rc::Rc::new(rect(0.0, 0.0, 10.0, 10.0)),
            crate::geometry::element::Transform::scale(2.0, 2.0), false);
        let m = model_with(vec![Element::Live(LiveVariant::Transformed(w)), rect(0.0, 0.0, 5.0, 5.0)], &[]);
        let v = active_document_view(&m, &[vec![0, 0]], &[], None);
        assert_eq!(v["layers_panel_selection_is_container"], serde_json::json!(true));
        assert_eq!(v["layers_panel_selection_has_group"], serde_json::json!(false));
        let v = active_document_view(&m, &[vec![0, 1]], &[], None);
        assert_eq!(v["layers_panel_selection_is_container"], serde_json::json!(false), "control: a rect");
    }

    /// W2b-18: the reference's table (`test_brush_panel_spec.py::CASES`), row
    /// for row: (name, children, selected, has, single).
    #[test]
    fn brushed_stroke_facts_match_the_reference_table() {
        let cases: Vec<(&str, Vec<Element>, Vec<usize>, bool, bool)> = vec![
            ("one brushed path", vec![path(0.0, B)], vec![0], true, true),
            ("one plain path", vec![path(0.0, None)], vec![0], false, false),
            ("brushed + plain selected", vec![path(0.0, B), path(60.0, None)], vec![0, 1], true, false),
            ("two brushed selected", vec![path(0.0, B), path(60.0, B)], vec![0, 1], true, false),
            ("brushed but NOT selected", vec![path(0.0, B), path(60.0, None)], vec![1], false, false),
            ("a rect", vec![rect(0.0, 0.0, 10.0, 10.0)], vec![0], false, false),
            ("empty brush id", vec![path(0.0, Some(""))], vec![0], false, false),
            ("nothing selected", vec![path(0.0, B)], vec![], false, false),
            ("a stale selection path", vec![path(0.0, B)], vec![7], false, false),
        ];
        for (name, children, sel, has, single) in cases {
            let m = model_with(children, &sel);
            assert_eq!(brushed_stroke_facts(m.document()), (has, single), "{name}");
        }
    }
}

/// The `active_document` namespace (Phase 3 §7.2) for one open document: the
/// layer tree (`top_level_layers`, which `element_at` reads), the selection
/// rollups, the artboards, `artboard_options`, `document_setup`,
/// `print_preferences`, the symbols, the save state. The web view
/// (`renderer::build_active_document_view`) and the engine's scope
/// (`panel_scope::engine_scope`) both call it; until 2026-10-14 only the web
/// had it, and a dialog opened on the engine's route read nulls where the
/// document had values. `layers_sel`, `artboards_sel` and `artboards_anchor`
/// are the Layers and Artboards panels' selections, which each caller holds in
/// its own place.
/// `active_document.symbol_usage` (runtime_contexts.yaml): every master's id
/// mapped to how many live references target it (its `rdeps` length), 0 for
/// an unused one, so `symbol_usage[id] > 0` reads a number for any master.
/// `delete_symbol_action` asks before it empties an instance. The one
/// definition every Rust view calls; the reference's `_symbol_usage`.
pub fn symbol_usage(doc: &crate::document::document::Document) -> serde_json::Value {
    if doc.symbols.is_empty() {
        return serde_json::json!({});
    }
    let rdeps = crate::document::dependency_index::dependency_index(doc).rdeps;
    let m: serde_json::Map<String, serde_json::Value> = doc.symbols.iter()
        .filter_map(|e| e.common().id.clone())
        .map(|id| {
            let n = rdeps.get(&id).map_or(0, Vec::len);
            (id, n.into())
        })
        .collect();
    serde_json::Value::Object(m)
}

/// `active_document.selection_orphan_count` (runtime_contexts.yaml): how many
/// live references deleting the canvas selection would leave pointing at a
/// deleted target. `delete_selection` in actions.yaml asks before a delete
/// that strands one. The one definition every Rust view calls.
pub fn selection_orphan_count(doc: &crate::document::document::Document) -> usize {
    let paths: Vec<Vec<usize>> = doc.selection.iter().map(|es| es.path.clone()).collect();
    if paths.is_empty() {
        return 0;
    }
    crate::document::dependency_index::orphaned_references(doc, &paths).len()
}

/// The Layers tree's display label for an element (the renderer's tree and
/// `element_tree` share it).
pub fn tree_type_label(elem: &Element) -> &'static str {
    match elem {
        Element::Line(_) => "Line",
        Element::Rect(_) => "Rectangle",
        Element::Ellipse(e) if e.rx == e.ry => "Circle",
        Element::Ellipse(_) => "Ellipse",
        Element::Polyline(_) => "Polyline",
        Element::Polygon(_) => "Polygon",
        Element::Path(_) => "Path",
        Element::Text(_) => "Text",
        Element::TextPath(_) => "Text Path",
        Element::Group(_) => "Group",
        Element::Layer(_) => "Layer",
        Element::Live(v) => match v {
            LiveVariant::CompoundShape(_) => "Compound Shape",
            LiveVariant::Reference(_) => "Reference",
            LiveVariant::Recorded(_) => "Recorded",
            LiveVariant::Generated(_) => "Generated",
            LiveVariant::Transformed(_) => "Transformed",
        },
    }
}

/// An element's test-JSON `type`, which the row template compares
/// (`node.type == 'layer'`).
fn tree_type_name(elem: &Element) -> &'static str {
    match elem {
        Element::Line(_) => "line",
        Element::Rect(_) => "rect",
        Element::Ellipse(_) => "ellipse",
        Element::Polyline(_) => "polyline",
        Element::Polygon(_) => "polygon",
        Element::Path(_) => "path",
        Element::Text(_) => "text",
        Element::TextPath(_) => "text_path",
        Element::Group(_) => "group",
        Element::Layer(_) => "layer",
        Element::Live(_) => "live",
    }
}

/// `active_document.element_tree` (STATUS-jas item 38): the document's rows
/// for the Layers panel's `tree_view`, topmost first (REVERSE z) and depth
/// first, as the web tree walks it (`renderer::tree_flatten_layers`). A row is
/// selected when its path is at or under a selected path. Collapse, panel
/// selection, renaming, filters and isolation are the widget's own binds
/// (`layers.yaml` `lp_tree`), not rows' fields. The shared fixture is
/// `test_fixtures/layers/element_tree.json`.
pub fn element_tree(doc: &Document) -> Value {
    use crate::geometry::element::Visibility;
    fn walk(children: &[&Element], prefix: &[usize], depth: usize,
            selected: &std::collections::HashSet<Vec<usize>>, rows: &mut Vec<Value>) {
        for (i, elem) in children.iter().enumerate().rev() {
            let mut path = prefix.to_vec();
            path.push(i);
            let c = elem.common();
            let visibility = match c.visibility {
                Visibility::Invisible => "invisible",
                Visibility::Outline => "outline",
                Visibility::Preview => "preview",
            };
            rows.push(json!({
                "path": path, "depth": depth, "id": c.id.clone(),
                "name": c.name.clone().unwrap_or_default(),
                "type": tree_type_name(elem), "type_label": tree_type_label(elem),
                "visibility": visibility, "locked": c.locked,
                "is_container": elem.is_group_or_layer(),
                "element_selected": crate::document::controller::path_is_selected_or_under(selected, &path),
            }));
            if let Some(kids) = elem.children() {
                let kids: Vec<&Element> = kids.iter().map(|k| &**k).collect();
                walk(&kids, &path, depth + 1, selected, rows);
            }
        }
    }
    let mut rows = Vec::new();
    let top: Vec<&Element> = doc.layers.iter().collect();
    walk(&top, &[], 0, &doc.selected_paths(), &mut rows);
    Value::Array(rows)
}

/// The Layers tree's ROWS TO DRAW (STATUS-jas item 38 step 1b, flask §591):
/// `element_tree`'s rows resolved against the `tree_view` widget's binds, in
/// the core, so a materializer draws them verbatim. A row under a collapsed
/// CONTAINER is hidden; the container keeps its row. Each row gains
/// `collapsed` (true only on a container), `panel_selected` and `renaming`
/// (exact path matches). The binds are PATHS, as both ports key them; a leaf
/// or a path no row has in `collapsed` is inert. Mirrors the reference's
/// `tree_visible_rows`; the shared fixture is `element_tree.json`'s
/// `visible_cases`.
pub fn tree_visible_rows(
    rows: &Value,
    collapsed: &[Vec<usize>],
    panel_selection: &[Vec<usize>],
    renaming: Option<&[usize]>,
) -> Value {
    let mut hidden_under: Vec<Vec<usize>> = Vec::new();
    let mut out = Vec::new();
    for row in rows.as_array().map(|a| a.as_slice()).unwrap_or(&[]) {
        let path: Vec<usize> = row["path"].as_array().map(|p| {
            p.iter().filter_map(|i| i.as_u64().map(|i| i as usize)).collect()
        }).unwrap_or_default();
        if hidden_under.iter().any(|h| path.starts_with(h)) {
            continue;
        }
        let folded = row["is_container"].as_bool().unwrap_or(false)
            && collapsed.contains(&path);
        let mut r = row.clone();
        r["collapsed"] = Value::Bool(folded);
        r["panel_selected"] = Value::Bool(panel_selection.contains(&path));
        r["renaming"] = Value::Bool(renaming == Some(path.as_slice()));
        if folded {
            hidden_under.push(path);
        }
        out.push(r);
    }
    Value::Array(out)
}

pub fn active_document_view(
    model: &crate::document::model::Model,
    layers_sel: &[Vec<usize>],
    artboards_sel: &[String],
    artboards_anchor: Option<&str>,
) -> Value {
    use crate::geometry::element::Visibility;
    use std::collections::HashSet;
    let mut top_level_layers = Vec::new();
    let mut top_level_layer_paths = Vec::new();
    let mut layer_names: HashSet<String> = HashSet::new();
    for (i, elem) in model.document().layers.iter().enumerate() {
        if let Element::Layer(le) = elem {
            let vis = match le.common.visibility {
                Visibility::Invisible => "invisible",
                Visibility::Outline => "outline",
                Visibility::Preview => "preview",
            };
            let path_json = serde_json::json!({"__path__": [i as u64]});
            top_level_layers.push(serde_json::json!({
                "kind": "Layer",
                "name": le.name(),
                "common": {
                    "visibility": vis,
                    "locked": le.common.locked,
                    "opacity": le.common.opacity,
                },
                "path": path_json.clone(),
            }));
            top_level_layer_paths.push(path_json);
            layer_names.insert(le.name().to_string());
        }
    }
    // next_layer_name: smallest "Layer N" not already taken
    let mut n = 1usize;
    loop {
        let candidate = format!("Layer {n}");
        if !layer_names.contains(&candidate) { break; }
        n += 1;
    }
    let next_layer_name = format!("Layer {n}");
    // new_layer_insert_index: min(selected top-level indices) + 1, else end
    let top_level_selected: Vec<usize> = layers_sel.iter()
        .filter_map(|p| if p.len() == 1 { Some(p[0]) } else { None })
        .collect();
    let new_layer_insert_index = match top_level_selected.iter().min() {
        Some(&i) => i + 1,
        None => model.document().layers.len(),
    };
    // runtime_contexts.yaml's two layers-panel rollups — "the sole selected
    // layer item is a container (group or layer)" and "at least one selected
    // layer item is a group". Declared there, read by layers.yaml's Enter
    // Isolation Mode / Flatten Artwork rows (and those actions' own
    // `enabled_when`), and built by NO port until the panel-menu
    // `enabled_when` went live and the read census found both unpublished:
    // they had evaluated null wherever anything evaluated them at all.
    let layers_panel_selection_is_container = layers_sel.len() == 1
        && matches!(
            model.document().get_element(&layers_sel[0]),
            Some(Element::Group(_)) | Some(Element::Layer(_))
                // A Transformed wrapper is entered to edit its child (route 4
                // slice 3b). JasSwift `ActiveDocumentView` agrees.
                | Some(Element::Live(crate::geometry::live::LiveVariant::Transformed(_)))
        );
    let layers_panel_selection_has_group = layers_sel.iter().any(|p| {
        matches!(model.document().get_element(p), Some(Element::Group(_)))
    });
    // Canvas selection rollup (Phase 0a, Align panel): scalar/boolean
    // plus path markers for downstream predicates and list operations.
    let canvas_selection = &model.document().selection;
    let element_selection: Vec<serde_json::Value> = canvas_selection
        .iter()
        .map(|es| {
            let path_ints: Vec<u64> = es.path.iter().map(|&i| i as u64).collect();
            serde_json::json!({"__path__": path_ints})
        })
        .collect();
    // Consumed by the Boolean panel's Expand button. The one definition
    // lives in `boolean_host`, which the engine's scope also calls.
    let selection_has_compound_shape =
        crate::interpreter::boolean_host::selection_has_compound_shape(model.document());
    // The Brushes panel's two gates (W2b-18), from the one definition the
    // engine's scope also calls.
    let (has_brushed_stroke, single_brushed_stroke) =
        crate::interpreter::document_views::brushed_stroke_facts(model.document());
    // Concepts panel (Slice 2): when exactly one generated concept instance is
    // selected, expose its concept id + param schema merged with current values
    // so the panel switches to PARAMS mode; null otherwise.
    let selected_concept =
        crate::interpreter::document_views::selected_concept_view(model.document());
    // Artboard view (ARTBOARDS.md §Artboard data model).
    let doc = model.document();
    let artboards_json: Vec<serde_json::Value> = doc
        .artboards
        .iter()
        .enumerate()
        .map(|(i, a)| artboard_row(i, a))
        .collect();
    // current_artboard: topmost panel-selected, else first. THE shared rule
    // (document::artboard::current_artboard), not a second copy of it — this
    // used to be the only place the rule was written, so every other site that
    // wanted "the current artboard" reached for `artboards.first()`.
    let current: Option<&crate::document::artboard::Artboard> =
        crate::document::artboard::current_artboard(
            &doc.artboards, artboards_sel,
        );
    let current_artboard_json = match current {
        Some(a) => serde_json::json!({
            "id": a.id,
            "name": a.name,
            "x": a.x,
            "y": a.y,
            "width": a.width,
            "height": a.height,
        }),
        None => serde_json::json!({}),
    };
    let current_id = current.map(|a| serde_json::Value::String(a.id.clone())).unwrap_or(serde_json::Value::Null);
    // next_artboard_name: smallest N not used by any "Artboard N" pattern name.
    let next_artboard_name = crate::document::artboard::next_artboard_name(&doc.artboards);
    let symbols_json = crate::interpreter::document_views::symbols_view(&doc);
    let mut view = serde_json::json!({
        "top_level_layers": top_level_layers,
        "top_level_layer_paths": top_level_layer_paths,
        "next_layer_name": next_layer_name,
        "new_layer_insert_index": new_layer_insert_index,
        "layers_panel_selection_count": layers_sel.len(),
        "has_selection": !canvas_selection.is_empty(),
        "selection_count": canvas_selection.len(),
        "selection_has_compound_shape": selection_has_compound_shape,
        "element_selection": element_selection,
        "artboards": artboards_json,
        "artboard_options": {
            "fade_region_outside_artboard": doc.artboard_options.fade_region_outside_artboard,
            "update_while_dragging": doc.artboard_options.update_while_dragging,
        },
        "document_setup": {
            "bleed_top": doc.document_setup.bleed_top,
            "bleed_right": doc.document_setup.bleed_right,
            "bleed_bottom": doc.document_setup.bleed_bottom,
            "bleed_left": doc.document_setup.bleed_left,
            "bleed_uniform": doc.document_setup.bleed_uniform,
            "show_images_outline": doc.document_setup.show_images_outline,
            "highlight_substituted_glyphs": doc.document_setup.highlight_substituted_glyphs,
            "grid_size": doc.document_setup.grid_size,
            "grid_color": doc.document_setup.grid_color.clone(),
            "paper_color": doc.document_setup.paper_color.clone(),
            "simulate_colored_paper": doc.document_setup.simulate_colored_paper,
            "transparency_flattener_preset": crate::document::print_preferences::flattener_preset_str(
                &doc.document_setup.transparency_flattener_preset),
            "discard_white_overprint": doc.document_setup.discard_white_overprint,
        },
        "print_preferences": {
            "preset_name": doc.print_preferences.preset_name.clone(),
            "printer_name": doc.print_preferences.printer_name.clone()
                .map(serde_json::Value::String).unwrap_or(serde_json::Value::Null),
            "copies": doc.print_preferences.copies,
            "collate": doc.print_preferences.collate,
            "reverse_order": doc.print_preferences.reverse_order,
            "artboard_range_mode": crate::document::print_preferences::artboard_range_mode_str(&doc.print_preferences.artboard_range_mode),
            "artboard_range": doc.print_preferences.artboard_range.clone(),
            "ignore_artboards": doc.print_preferences.ignore_artboards,
            "skip_blank_artboards": doc.print_preferences.skip_blank_artboards,
            "media_size": crate::document::print_preferences::media_size_str(&doc.print_preferences.media_size),
            "media_width": doc.print_preferences.media_width,
            "media_height": doc.print_preferences.media_height,
            "orientation": crate::document::print_preferences::orientation_str(&doc.print_preferences.orientation),
            "auto_rotate": doc.print_preferences.auto_rotate,
            "transverse": doc.print_preferences.transverse,
            "print_layers": crate::document::print_preferences::print_layers_str(&doc.print_preferences.print_layers),
            "placement_x": doc.print_preferences.placement_x,
            "placement_y": doc.print_preferences.placement_y,
            "scaling_mode": crate::document::print_preferences::scaling_mode_str(&doc.print_preferences.scaling_mode),
            "custom_scale": doc.print_preferences.custom_scale,
            "tile_overlap_h": doc.print_preferences.tile_overlap_h,
            "tile_overlap_v": doc.print_preferences.tile_overlap_v,
            "tile_range": doc.print_preferences.tile_range.clone(),
            "marks_and_bleed": marks_and_bleed_view(&doc.print_preferences.marks_and_bleed),
            "output": output_view(&doc.print_preferences.output),
            "graphics": graphics_view(&doc.print_preferences.graphics),
            "color_management": color_management_view(&doc.print_preferences.color_management),
            "advanced": advanced_view(&doc.print_preferences.advanced),
        },
        "artboards_count": doc.artboards.len(),
        "next_artboard_name": next_artboard_name,
        "current_artboard_id": current_id,
        "current_artboard": current_artboard_json,
        "artboards_panel_selection_ids": artboards_sel.to_vec(),
        "artboards_panel_anchor": artboards_anchor.map(|s| serde_json::Value::String(s.to_string()))
            .unwrap_or(serde_json::Value::Null),
        "zoom_level": model.zoom_level,
        "view_offset_x": model.view_offset_x,
        "view_offset_y": model.view_offset_y,
    });
    // The Layers tree's rows (STATUS-jas item 38), outside the macro: one more
    // key there exceeds `json!`'s recursion limit.
    view["element_tree"] = element_tree(&doc);
    // Inserted outside the json! literal to keep the macro under the
    // recursion limit (the tab-branch object is at the ceiling too).
    if let serde_json::Value::Object(m) = &mut view {
        m.insert("layers_panel_selection_is_container".to_string(),
                 serde_json::Value::Bool(layers_panel_selection_is_container));
        m.insert("layers_panel_selection_has_group".to_string(),
                 serde_json::Value::Bool(layers_panel_selection_has_group));
        for (k, v) in layer_facts(&doc.layers) {
            m.insert(k.to_string(), serde_json::Value::Bool(v));
        }
    }
    // Inserted after the json! literal: the populated active-document
    // object is already at the macro recursion ceiling, so the symbols
    // list is attached here (SYMBOLS.md §8).
    if let serde_json::Value::Object(m) = &mut view {
        m.insert("selection_has_brushed_stroke".to_string(), has_brushed_stroke.into());
        m.insert("selection_is_single_brushed_stroke".to_string(), single_brushed_stroke.into());
        m.insert("selection_orphan_count".to_string(), selection_orphan_count(doc).into());
        m.insert("symbol_usage".to_string(), symbol_usage(doc));
        m.insert("symbols".to_string(), symbols_json);
        // Concepts panel Slice 2: attached here too (macro recursion ceiling).
        m.insert("selected_concept".to_string(), selected_concept);
        // The ids `delete_empty_artboards` may remove — already filtered by the
        // preserve-position-1 rule, so the action's `foreach` stays a plain
        // mirror of `delete_artboards`. See
        // `document::evaluated_bounds::deletable_empty_artboard_ids`.
        m.insert(
            "deletable_empty_artboard_ids".to_string(),
            serde_json::Value::Array(
                crate::document::evaluated_bounds::deletable_empty_artboard_ids(doc)
                    .into_iter()
                    .map(serde_json::Value::String)
                    .collect(),
            ),
        );
    }
    // The per-document recent colours, the one writable document list
    // (`runtime_contexts.yaml`), which Color and Swatches both read.
    if let Some(m) = view.as_object_mut() {
        m.insert("recent_colors".to_string(), serde_json::json!(model.recent_colors));
        // The document's save state (`runtime_contexts.yaml`), as the menu
        // context has it (`menu_bar.rs`). Until 2026-10-14 only menus saw it,
        // so `close_tab`'s `if active_document.is_modified` was always false
        // and an edited tab closed without the Save Changes prompt.
        // `filename` is the name the tab shows (`Untitled-N` until a save);
        // `has_filename` says whether it has been saved.
        m.insert("is_modified".to_string(), serde_json::json!(model.is_modified()));
        // `any_modified`: whether ANY open document has unsaved changes, which
        // `quit` asks (`actions.yaml`). This view sees one document, so it
        // answers for that one; a host holding several overrides it
        // (`renderer::build_active_document_view`). Until 2026-10-15 no port
        // built it, so `quit` never offered to save.
        m.insert("any_modified".to_string(), serde_json::json!(model.is_modified()));
        // The selected paragraphs' Justification and Hyphenation values, which
        // both dialogs' `init:` read (`paragraph_host::paragraph_dialog_values`).
        m.insert("paragraph_wrappers".to_string(), serde_json::Value::Object(
            crate::interpreter::paragraph_host::paragraph_dialog_values(model.document())));
        m.insert("has_filename".to_string(), serde_json::json!(!model.filename.starts_with("Untitled-")));
        m.insert("filename".to_string(), serde_json::json!(model.filename));
    }
    view
}

/// Build the ``marks_and_bleed`` nested object exposed under
/// ``active_document.print_preferences``. Split out so the parent
/// json! macro stays under serde's recursion limit.
pub(crate) fn marks_and_bleed_view(
    m: &crate::document::print_preferences::MarksAndBleed,
) -> serde_json::Value {
    serde_json::json!({
        "all_printer_marks": m.all_printer_marks,
        "trim_marks": m.trim_marks,
        "registration_marks": m.registration_marks,
        "color_bars": m.color_bars,
        "page_information": m.page_information,
        "printer_mark_type": crate::document::print_preferences::printer_mark_type_str(&m.printer_mark_type),
        "trim_mark_weight": m.trim_mark_weight,
        "mark_offset": m.mark_offset,
        "use_document_bleed": m.use_document_bleed,
        "bleed_top": m.bleed_top,
        "bleed_right": m.bleed_right,
        "bleed_bottom": m.bleed_bottom,
        "bleed_left": m.bleed_left,
    })
}

fn ink_override_view(ink: &crate::document::print_preferences::InkOverride) -> serde_json::Value {
    serde_json::json!({
        "name": ink.name,
        "print": ink.print,
        "frequency": ink.frequency,
        "angle": ink.angle,
        "dot_shape": crate::document::print_preferences::dot_shape_str(&ink.dot_shape),
    })
}

pub(crate) fn output_view(o: &crate::document::print_preferences::Output) -> serde_json::Value {
    let inks: Vec<serde_json::Value> = o.inks.iter().map(ink_override_view).collect();
    serde_json::json!({
        "mode": crate::document::print_preferences::output_mode_str(&o.mode),
        "emulsion": crate::document::print_preferences::emulsion_str(&o.emulsion),
        "image_polarity": crate::document::print_preferences::image_polarity_str(&o.image_polarity),
        "printer_resolution": o.printer_resolution,
        "convert_spot_to_process": o.convert_spot_to_process,
        "overprint_black": o.overprint_black,
        "inks": inks,
    })
}

pub(crate) fn advanced_view(a: &crate::document::print_preferences::Advanced) -> serde_json::Value {
    serde_json::json!({
        "print_as_bitmap": a.print_as_bitmap,
        "overprint_flattener_preset": crate::document::print_preferences::flattener_preset_str(&a.overprint_flattener_preset),
    })
}

pub(crate) fn color_management_view(c: &crate::document::print_preferences::ColorManagement) -> serde_json::Value {
    serde_json::json!({
        "document_profile": c.document_profile,
        "color_handling": crate::document::print_preferences::color_handling_str(&c.color_handling),
        "printer_profile": c.printer_profile,
        "rendering_intent": crate::document::print_preferences::rendering_intent_str(&c.rendering_intent),
        "preserve_rgb_numbers": c.preserve_rgb_numbers,
    })
}

pub(crate) fn graphics_view(g: &crate::document::print_preferences::Graphics) -> serde_json::Value {
    serde_json::json!({
        "flatness": g.flatness,
        "font_download": crate::document::print_preferences::font_download_str(&g.font_download),
        "postscript_level": crate::document::print_preferences::postscript_level_str(&g.postscript_level),
        "data_format": crate::document::print_preferences::data_format_str(&g.data_format),
        "compatible_gradient_printing": g.compatible_gradient_printing,
        "raster_effects_resolution": g.raster_effects_resolution,
    })
}

/// One row of `active_document.artboards`: the artboard's fields under the
/// canonical form's names, and its 1-based `number`. The web view and the
/// engine's panel scope both build the list from this, so a dialog's init
/// (`filter(active_document.artboards, …)[0].width`) reads the same row on
/// both routes; until 2026-10-14 the engine's rows carried `id`, `name` and
/// `number` only.
pub fn artboard_row(i: usize, a: &crate::document::artboard::Artboard) -> Value {
    json!({
        "id": a.id,
        "name": a.name,
        "number": i + 1,
        "x": a.x,
        "y": a.y,
        "width": a.width,
        "height": a.height,
        "fill": a.fill.as_canonical(),
        "show_center_mark": a.show_center_mark,
        "show_cross_hairs": a.show_cross_hairs,
        "show_video_safe_areas": a.show_video_safe_areas,
        "video_ruler_pixel_aspect_ratio": a.video_ruler_pixel_aspect_ratio,
    })
}

/// The Layers menu's three toggle-all facts over the top-level layers
/// (`runtime_contexts.yaml`): any layer not invisible, any layer in preview,
/// any layer unlocked; all false with no layers. The labels read them
/// (`layers.yaml`), so the menu walk resolves "Hide All Layers" / "Show All
/// Layers" with no native table. The reference's `_layer_facts`, Swift's
/// `layerFacts`.
pub fn layer_facts(layers: &[crate::geometry::element::Element]) -> [(&'static str, bool); 3] {
    use crate::geometry::element::Visibility;
    [
        ("any_layer_visible", layers.iter().any(|l| l.visibility() != Visibility::Invisible)),
        ("any_layer_preview", layers.iter().any(|l| l.visibility() == Visibility::Preview)),
        ("any_layer_unlocked", layers.iter().any(|l| !l.locked())),
    ]
}
