//! Workspace loader — parses compiled JSON and extracts panel specs,
//! actions, state defaults, and theme.

use serde_json;
use std::collections::HashMap;
use std::sync::OnceLock;

/// Compiled workspace JSON, embedded at build time.
///
/// This file is regenerated from `workspace/*.yaml` by:
///   python -m workspace_interpreter.compile workspace/ workspace/workspace.json
const WORKSPACE_JSON: &str = include_str!("../../../workspace/workspace.json");

/// Cached parsed workspace data (parsed once, reused forever).
static WORKSPACE_CACHE: OnceLock<serde_json::Value> = OnceLock::new();

/// Parsed workspace data.
pub struct Workspace {
    data: &'static serde_json::Value,
}

impl Workspace {
    /// Load the workspace from the cached parsed JSON.
    pub fn load() -> Option<Self> {
        let data = WORKSPACE_CACHE.get_or_init(|| {
            serde_json::from_str(WORKSPACE_JSON).unwrap_or(serde_json::Value::Null)
        });
        if data.is_null() { return None; }
        Some(Workspace { data })
    }

    /// Get the full workspace data.
    pub fn data(&self) -> &serde_json::Value {
        &self.data
    }

    /// Get the panels map.
    pub fn panels(&self) -> &serde_json::Value {
        self.data.get("panels").unwrap_or(&serde_json::Value::Null)
    }

    /// Get a specific panel spec by content id -- or, when no panel has that
    /// id, a PANE of the layout that does (the toolbar, `toolbar_pane`). A pane
    /// carries `id` and `content` exactly as a panel does, so a native shell
    /// plans and drives it through the same calls, with nothing pane-specific.
    pub fn panel(&self, content_id: &str) -> Option<&serde_json::Value> {
        if let Some(p) = self.data.get("panels").and_then(|ps| ps.get(content_id)) {
            return Some(p);
        }
        self.layout_pane(content_id)
    }

    /// The canvas tab's label TEMPLATE: the `content` of the text under
    /// `canvas_tab_bar`'s `do:` (layout.yaml). The spec owns the rule for what
    /// a tab says (its name, and its modified mark), so the web's native tab
    /// bar evaluates this rather than restating it. None if the layout lacks it.
    pub fn canvas_tab_label_template(&self) -> Option<&str> {
        self.canvas_tab_bar()?.get("do")?.get("children")?.as_array()?.iter()
            .find(|k| k.get("type").and_then(|v| v.as_str()) == Some("text"))?
            .get("content")?.as_str()
    }

    /// The layout's `canvas_tab_bar` node (layout.yaml): the `foreach` over
    /// `workspace.open_documents` whose `do:` is one tab. None if absent.
    pub fn canvas_tab_bar(&self) -> Option<&serde_json::Value> {
        fn find<'a>(node: &'a serde_json::Value, id: &str) -> Option<&'a serde_json::Value> {
            if node.get("id").and_then(|v| v.as_str()) == Some(id) {
                return Some(node);
            }
            if let Some(kids) = node.get("children").and_then(|v| v.as_array()) {
                if let Some(found) = kids.iter().find_map(|k| find(k, id)) {
                    return Some(found);
                }
            }
            node.get("content").and_then(|c| find(c, id))
        }
        find(self.data.get("layout")?, "canvas_tab_bar")
    }

    /// A direct child of the layout root with this `id` that has `content`.
    pub fn layout_pane(&self, id: &str) -> Option<&serde_json::Value> {
        self.data.get("layout")?.get("children")?.as_array()?.iter().find(|c| {
            c.get("id").and_then(|v| v.as_str()) == Some(id) && c.get("content").is_some()
        })
    }

    /// Get a concept pack by id from the concept registry (CONCEPTS.md):
    /// the spec carries `params`, `closed`, and the `generator` expression.
    pub fn concept(&self, id: &str) -> Option<&serde_json::Value> {
        self.data.get("concepts")?.get(id)
    }

    /// The whole concept registry (id -> spec), for code that must iterate
    /// every concept — e.g. `promote` trying each concept's `fitter` detector
    /// (CONCEPTS.md §10).
    pub fn concepts(&self) -> Option<&serde_json::Map<String, serde_json::Value>> {
        self.data.get("concepts")?.as_object()
    }

    /// Get the icons map.
    pub fn icons(&self) -> &serde_json::Value {
        self.data.get("icons").unwrap_or(&serde_json::Value::Null)
    }

    /// Get the actions map.
    pub fn actions(&self) -> &serde_json::Value {
        self.data.get("actions").unwrap_or(&serde_json::Value::Null)
    }

    /// Get the state definitions.
    pub fn state_defs(&self) -> &serde_json::Value {
        self.data.get("state").unwrap_or(&serde_json::Value::Null)
    }

    /// Extract default values from state definitions.
    pub fn state_defaults(&self) -> HashMap<String, serde_json::Value> {
        let mut defaults = HashMap::new();
        if let serde_json::Value::Object(map) = self.state_defs() {
            for (key, defn) in map {
                let default_val = if let serde_json::Value::Object(d) = defn {
                    d.get("default").cloned().unwrap_or(serde_json::Value::Null)
                } else {
                    defn.clone()
                };
                defaults.insert(key.clone(), default_val);
            }
        }
        // Launch state read from the preferences (state.yaml: "initialised at
        // startup from preferences.brushes.persistent_libraries").
        if let Some(v) = defaults.get_mut("brushes_open_libraries") {
            let prefs = crate::interpreter::preferences::current();
            *v = crate::interpreter::preferences::open_libraries_at_launch(
                &prefs["brushes"]["persistent_libraries"]);
        }
        defaults
    }

    /// Extract default values from a panel's state section.
    pub fn panel_state_defaults(&self, content_id: &str) -> HashMap<String, serde_json::Value> {
        let mut defaults = HashMap::new();
        if let Some(panel) = self.panel(content_id) {
            if let Some(serde_json::Value::Object(state)) = panel.get("state") {
                for (key, defn) in state {
                    let default_val = if let serde_json::Value::Object(d) = defn {
                        d.get("default").cloned().unwrap_or(serde_json::Value::Null)
                    } else {
                        defn.clone()
                    };
                    defaults.insert(key.clone(), default_val);
                }
            }
        }
        defaults
    }

    /// Get the panel menu items for a content id.
    pub fn panel_menu(&self, content_id: &str) -> Vec<serde_json::Value> {
        self.panel(content_id)
            .and_then(|p| p.get("menu"))
            .and_then(|m| m.as_array())
            .cloned()
            .unwrap_or_default()
    }

    /// Get the panel content element tree for a content id.
    pub fn panel_content(&self, content_id: &str) -> Option<&serde_json::Value> {
        self.panel(content_id)?.get("content")
    }

    /// Get the theme data.
    pub fn theme(&self) -> &serde_json::Value {
        self.data.get("theme").unwrap_or(&serde_json::Value::Null)
    }

    /// Get the dialogs map.
    pub fn dialogs(&self) -> &serde_json::Value {
        self.data.get("dialogs").unwrap_or(&serde_json::Value::Null)
    }

    /// Get a specific dialog spec by id.
    pub fn dialog(&self, id: &str) -> Option<&serde_json::Value> {
        self.data.get("dialogs")?.get(id)
    }

    /// Extract default values from a dialog's state section.
    pub fn dialog_state_defaults(&self, id: &str) -> HashMap<String, serde_json::Value> {
        let mut defaults = HashMap::new();
        if let Some(dialog) = self.dialog(id) {
            if let Some(serde_json::Value::Object(state)) = dialog.get("state") {
                for (key, defn) in state {
                    let default_val = if let serde_json::Value::Object(d) = defn {
                        d.get("default").cloned().unwrap_or(serde_json::Value::Null)
                    } else {
                        defn.clone()
                    };
                    defaults.insert(key.clone(), default_val);
                }
            }
        }
        defaults
    }
}

/// Map PanelKind to YAML content id.
#[cfg(feature = "web")]
pub fn panel_kind_to_content_id(kind: crate::workspace::workspace::PanelKind) -> &'static str {
    use crate::workspace::workspace::PanelKind;
    match kind {
        PanelKind::Layers => "layers_panel_content",
        PanelKind::Color => "color_panel_content",
        PanelKind::Swatches => "swatches_panel_content",
        PanelKind::Brushes => "brushes_panel_content",
        PanelKind::Stroke => "stroke_panel_content",
        PanelKind::Properties => "properties_panel_content",
        PanelKind::Character => "character_panel_content",
        PanelKind::Paragraph => "paragraph_panel_content",
        PanelKind::Artboards => "artboards_panel_content",
        PanelKind::Align => "align_panel_content",
        PanelKind::Boolean => "boolean_panel_content",
        PanelKind::Opacity => "opacity_panel_content",
        PanelKind::MagicWand => "magic_wand_panel_content",
        PanelKind::Symbols => "symbols_panel_content",
        PanelKind::Gradient => "gradient_panel_content",
        PanelKind::Concepts => "concepts_panel_content",
    }
}

/// The concept-pack registry as a sorted list of `{id, name, description}` for
/// the Concepts panel's `foreach source: "data.concepts"` (CONCEPTS.md §6).
/// Derived from the compiled workspace `concepts` registry; `Workspace::load`
/// is cached, so this is cheap. It reads only the workspace, so it is
/// web-free: the web's `data` and the engine's scope both call it (W2b-15).
pub fn concepts_list() -> serde_json::Value {
    let Some(ws) = Workspace::load() else {
        return serde_json::Value::Array(Vec::new());
    };
    let Some(map) = ws.data().get("concepts").and_then(|c| c.as_object()) else {
        return serde_json::Value::Array(Vec::new());
    };
    let mut ids: Vec<&String> = map.keys().collect();
    ids.sort();
    let list: Vec<serde_json::Value> = ids
        .into_iter()
        .map(|id| {
            let c = &map[id];
            serde_json::json!({
                "id": id,
                "name": c.get("name").cloned()
                    .unwrap_or_else(|| serde_json::Value::String(id.clone())),
                "description": c.get("description").cloned()
                    .unwrap_or(serde_json::Value::Null),
            })
        })
        .collect();
    serde_json::Value::Array(list)
}

/// What a canvas tab says for a document (row 115): the spec's
/// `canvas_tab_bar` label evaluated with `doc = {name, is_modified}`, the same
/// entry `workspace.open_documents` carries. Falls back to the bare name only
/// if the compiled layout has no template.
pub fn canvas_tab_label(name: &str, is_modified: bool) -> String {
    let Some(ws) = Workspace::load() else { return name.to_string() };
    let Some(template) = ws.canvas_tab_label_template() else { return name.to_string() };
    let ctx = serde_json::json!({ "doc": { "name": name, "is_modified": is_modified } });
    crate::interpreter::expr::eval_text(template, &ctx)
}

/// The ids a canvas tab strip carries (row 302, ruling 1054's twin): one
/// `(tab, close)` pair per open document, `docs` as `(name, is_modified)` in tab
/// order. The spec's `canvas_tab_bar` today gives `canvas_tab_<i>` and
/// `canvas_tab_close_<i>`. A web or Mac strip that draws its tabs NATIVELY sets
/// these as its element ids, so it names each tab and its close button exactly
/// as the engine's plan does. Empty when the compiled layout has no tab bar.
pub fn canvas_tab_ids(docs: &[(String, bool)]) -> Vec<(String, String)> {
    let Some(ws) = Workspace::load() else { return vec![] };
    let Some(bar) = ws.canvas_tab_bar() else { return vec![] };
    canvas_strip_ids(bar, docs)
}

/// [`canvas_tab_ids`] for a given tab-bar node. The rows come from the
/// engine's own expansion ([`row_scopes`](super::foreach::row_scopes)) over a
/// `workspace.open_documents` shaped as the engine holds it
/// (`panel_scope::workspace_facts`: `index`, `is_modified`, `name`), so a row
/// here is the row the plan resolves in. Each id then follows the plan's three
/// rules: a template resolves only from the row's own variable
/// ([`row_id`](super::foreach::row_id)), else it is withheld (`""`); a static
/// id is carried as it is; and a collision a resolved id takes part in is
/// withheld from every carrier
/// ([`duplicate_resolved_ids`](super::foreach::duplicate_resolved_ids)).
/// ⚠️ SCOPE: the collision census is the STRIP, which is all a native strip
/// draws; the engine's plan counts the whole canvas pane.
pub fn canvas_strip_ids(bar: &serde_json::Value, docs: &[(String, bool)]) -> Vec<(String, String)> {
    use super::foreach::{duplicate_resolved_ids, row_id, row_scopes};
    let open: Vec<serde_json::Value> = docs.iter().enumerate()
        .map(|(i, (name, m))| serde_json::json!({"index": i, "is_modified": m, "name": name}))
        .collect();
    let ctx = serde_json::json!({"workspace": {"open_documents": open}});
    let Some(rows) = row_scopes(bar, &ctx) else { return vec![] };
    let tab = bar.get("do");
    let close = tab.and_then(|t| t.get("children")).and_then(|v| v.as_array()).and_then(|kids| kids.iter().find(|k| {
        k.get("type").and_then(|v| v.as_str()) == Some("icon_button")
            && k.get("icon").and_then(|v| v.as_str()) == Some("close")
    }));
    let raw = |n: Option<&serde_json::Value>| n.and_then(|n| n.get("id")).and_then(|v| v.as_str()).unwrap_or("").to_string();
    let (tab_raw, close_raw) = (raw(tab), raw(close));
    // (id, resolved) for one raw id in one row.
    let one = |raw: &str, row: &serde_json::Value| -> (String, bool) {
        if !raw.contains("{{") {
            return (raw.to_string(), false);
        }
        match row_id(raw, row) {
            Some(s) => (s, true),
            None => (String::new(), false),
        }
    };
    let pairs: Vec<((String, bool), (String, bool))> = rows.iter()
        .map(|row| (one(&tab_raw, row), one(&close_raw, row)))
        .collect();
    let dup = duplicate_resolved_ids(pairs.iter().flat_map(|(t, c)| [(t.0.as_str(), t.1), (c.0.as_str(), c.1)]));
    let keep = |id: &String| if dup.contains(id) { String::new() } else { id.clone() };
    pairs.iter().map(|(t, c)| (keep(&t.0), keep(&c.0))).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // Row 115: the canvas tab shows the document's modified mark, from the
    // spec. Twin of JasSwift/Tests/Canvas/CanvasTabLabelTests.swift.
    #[test]
    fn canvas_tab_label_is_the_bare_name_when_clean() {
        assert_eq!(canvas_tab_label("a.svg", false), "a.svg");
    }

    #[test]
    fn canvas_tab_label_marks_a_modified_document() {
        assert_eq!(canvas_tab_label("a.svg", true), "a.svg *");
    }

    #[test]
    fn canvas_tab_label_comes_from_the_spec() {
        let ws = Workspace::load().expect("workspace");
        let template = ws.canvas_tab_label_template().expect("the compiled layout carries the tab label");
        assert!(template.contains("doc.is_modified"), "the spec names the mark: {template}");
    }

    /// Row 302 (ruling 1054's twin): a NATIVE canvas tab strip carries the ids
    /// the engine's plan carries, `canvas_tab_<i>` and `canvas_tab_close_<i>`,
    /// resolved from the spec's own templates by the engine's own expansion and
    /// resolver. Twin of JasSwift/Tests/Canvas/CanvasTabIdsTests.swift.
    #[test]
    fn canvas_tab_ids_come_from_the_spec_one_pair_per_document() {
        let docs = [("a.svg".to_string(), false), ("b.svg".to_string(), true)];
        assert_eq!(canvas_tab_ids(&docs), [
            ("canvas_tab_0".to_string(), "canvas_tab_close_0".to_string()),
            ("canvas_tab_1".to_string(), "canvas_tab_close_1".to_string()),
        ]);
        assert!(canvas_tab_ids(&[]).is_empty(), "no document, no tab");
    }

    /// The strip's rules are the plan's, driven on synthetic templates the
    /// shipped spec never writes: a template reading anything but the row's
    /// own variable is withheld (""); a static id is carried as is; a resolved
    /// id carried twice (two rows naming the same document name) is withheld
    /// from BOTH carriers, never sent twice.
    #[test]
    fn canvas_strip_ids_follow_the_plans_three_rules() {
        let bar = |tab: &str, close: &str| json!({
            "id": "canvas_tab_bar",
            "foreach": {"source": "workspace.open_documents", "as": "doc"},
            "do": {"id": tab, "type": "row", "children": [
                {"type": "text", "content": "{{doc.name}}"},
                {"id": close, "type": "icon_button", "icon": "close"},
            ]},
        });
        let docs = [("a".to_string(), false), ("a".to_string(), false), ("b".to_string(), false)];
        let s = |v: &[(String, String)]| v.iter().map(|(t, c)| format!("{t}|{c}")).collect::<Vec<_>>();
        assert_eq!(s(&canvas_strip_ids(&bar("t_{{doc.index}}", "c_{{state.x}}"), &docs)),
                   ["t_0|", "t_1|", "t_2|"], "condition 1: a state read is withheld");
        assert_eq!(s(&canvas_strip_ids(&bar("t_{{doc.name}}", "c_{{doc.index}}"), &docs)),
                   ["|c_0", "|c_1", "t_b|c_2"], "condition 3: 'a' twice is withheld from both rows");
        assert_eq!(s(&canvas_strip_ids(&bar("tab", "c_{{doc._index}}"), &docs)),
                   ["tab|c_0", "tab|c_1", "tab|c_2"], "a static id is carried as is, even repeated");
        assert_eq!(s(&canvas_strip_ids(&bar("c_1", "c_{{doc.index}}"), &docs)),
                   ["|c_0", "|", "|c_2"], "condition 3: a static id equal to a resolved one is withheld from both");
    }

    #[test]
    fn load_workspace() {
        let ws = Workspace::load().expect("Failed to load workspace");
        assert!(ws.panels().is_object());
        assert!(ws.actions().is_object());
    }

    #[test]
    fn panel_specs_present() {
        let ws = Workspace::load().unwrap();
        assert!(ws.panel("color_panel_content").is_some());
        assert!(ws.panel("layers_panel_content").is_some());
    }

    #[test]
    fn concept_registry_loads_and_evaluates() {
        let ws = Workspace::load().unwrap();
        // The concept packs are bundled into workspace.json (CONCEPTS.md 3a).
        let gear = ws.concept("gear").expect("gear concept registered");
        assert_eq!(gear.get("closed").and_then(|v| v.as_bool()), Some(true));
        assert!(gear.get("generator").and_then(|v| v.as_str()).unwrap_or("").contains("mod("));
        assert!(ws.concept("no_such_concept").is_none());

        // Registry -> evaluator round-trip: the bundled generator yields geometry.
        let poly = ws.concept("regular_polygon").unwrap();
        let generator = poly.get("generator").and_then(|v| v.as_str()).unwrap();
        let ctx = serde_json::json!({ "param": { "sides": 4, "radius": 10 } });
        match crate::interpreter::expr::eval(generator, &ctx) {
            crate::interpreter::expr_types::Value::List(items) => {
                assert_eq!(items.len(), 4);
            }
            other => panic!("expected a list of points, got {other:?}"),
        }
    }

    #[test]
    fn color_panel_has_menu() {
        let ws = Workspace::load().unwrap();
        let menu = ws.panel_menu("color_panel_content");
        assert!(!menu.is_empty());
    }

    #[test]
    fn color_panel_has_content() {
        let ws = Workspace::load().unwrap();
        assert!(ws.panel_content("color_panel_content").is_some());
    }

    #[test]
    fn state_defaults_extracted() {
        let ws = Workspace::load().unwrap();
        let defaults = ws.state_defaults();
        assert!(defaults.contains_key("active_tool"));
        assert!(defaults.contains_key("fill_color"));
    }

    #[test]
    fn panel_state_defaults_extracted() {
        let ws = Workspace::load().unwrap();
        let defaults = ws.panel_state_defaults("color_panel_content");
        assert!(defaults.contains_key("mode"));
        assert!(defaults.contains_key("h"));
    }

    #[test]
    fn dialogs_present() {
        let ws = Workspace::load().unwrap();
        assert!(ws.dialogs().is_object());
        assert!(ws.dialogs().as_object().unwrap().len() > 0);
    }

    #[test]
    fn color_picker_dialog_exists() {
        let ws = Workspace::load().unwrap();
        let dialog = ws.dialog("color_picker");
        assert!(dialog.is_some());
        let dialog = dialog.unwrap();
        assert_eq!(dialog.get("summary").and_then(|v| v.as_str()), Some("Select Color"));
        assert!(dialog.get("state").is_some());
        assert!(dialog.get("init").is_some());
        assert!(dialog.get("content").is_some());
    }

    #[test]
    fn dialog_state_defaults_extracted() {
        let ws = Workspace::load().unwrap();
        let defaults = ws.dialog_state_defaults("color_picker");
        // color is a plain stored variable with a default
        assert!(defaults.contains_key("color"));
        assert_eq!(defaults.get("color"), Some(&serde_json::json!("#ffffff")));
        // h has a get expression, so no default in defaults
        // (it's computed from color)
    }

    #[test]
    fn workspace_save_as_dialog() {
        let ws = Workspace::load().unwrap();
        let dialog = ws.dialog("workspace_save_as");
        assert!(dialog.is_some());
        let defaults = ws.dialog_state_defaults("workspace_save_as");
        assert!(defaults.contains_key("name"));
    }

    #[test]
    fn color_panel_slider_visibility() {
        use super::super::expr;
        let ws = Workspace::load().unwrap();
        let content = ws.panel_content("color_panel_content").unwrap();
        let state_map: serde_json::Map<String, serde_json::Value> =
            ws.state_defaults().into_iter().collect();
        let panel_map: serde_json::Map<String, serde_json::Value> =
            ws.panel_state_defaults("color_panel_content").into_iter().collect();
        let ctx = serde_json::json!({"state": state_map, "panel": panel_map});

        // Find slider containers by walking children
        fn find_bind_visible(el: &serde_json::Value, results: &mut Vec<(String, String)>) {
            if let Some(id) = el.get("id").and_then(|v| v.as_str()) {
                if let Some(vis) = el.get("bind")
                    .and_then(|b| b.get("visible"))
                    .and_then(|v| v.as_str())
                {
                    results.push((id.to_string(), vis.to_string()));
                }
            }
            if let Some(children) = el.get("children").and_then(|c| c.as_array()) {
                for child in children {
                    find_bind_visible(child, results);
                }
            }
        }

        let mut bindings = Vec::new();
        find_bind_visible(content, &mut bindings);

        // Default mode is "hsb" — only HSB should be visible
        let mut hsb_visible = false;
        let mut others_hidden = true;
        for (id, vis_expr) in &bindings {
            let result = expr::eval(vis_expr, &ctx);
            let visible = result.to_bool();
            // {id}: expr={vis_expr} -> {result:?} visible={visible}
            if id.contains("hsb") {
                hsb_visible = visible;
            } else {
                if visible {
                    others_hidden = false;
                }
            }
        }
        assert!(!bindings.is_empty(), "should find bind:visible expressions");
        assert!(hsb_visible, "HSB sliders should be visible");
        assert!(others_hidden, "non-HSB sliders should be hidden");
    }
}
