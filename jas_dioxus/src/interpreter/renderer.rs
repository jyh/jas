//! YAML element tree to Dioxus component renderer.
//!
//! Interprets workspace YAML element specs and builds corresponding
//! Dioxus virtual DOM nodes. Since Dioxus renders to HTML/DOM, this
//! is structurally similar to the Flask HTML renderer.

use dioxus::prelude::*;
use serde_json;
use std::cell::RefCell;
use std::rc::Rc;

use super::expr;
use super::expr_types::Value;
use crate::workspace::app_state::AppHandle;

/// Shared context captured once per panel body render, passed to all
/// child element renderers so they don't need to call use_context
/// (which would violate the rules of hooks inside conditional branches).
#[derive(Clone)]
struct RenderCtx {
    app: AppHandle,
    revision: Signal<u64>,
    dialog_ctx: super::dialog_view::DialogCtx,
    timer_ctx: super::timer::TimerCtx,
}

/// Render a YAML element spec into a Dioxus Element.
///
/// The element spec is a serde_json::Value object with fields like
/// `type`, `id`, `style`, `bind`, `behavior`, `children`, `content`.
/// This is the public entry point — call it from a component context.
/// It captures use_context hooks once and passes them through.
pub fn render_element(
    el: &serde_json::Value,
    ctx: &serde_json::Value,
) -> Element {
    // Capture hooks ONCE at the top level — never inside conditionals.
    let rctx = RenderCtx {
        app: use_context::<AppHandle>(),
        revision: use_context::<Signal<u64>>(),
        dialog_ctx: use_context::<super::dialog_view::DialogCtx>(),
        timer_ctx: use_context::<super::timer::TimerCtx>(),
    };
    render_el(el, ctx, &rctx)
}

/// Memoized YAML element component. Only re-renders when el or ctx change.
/// Use this for elements that appear in frequently-rerendering parents
/// (like toolbar elements inside the App component).
#[component]
pub fn MemoYamlElement(el: serde_json::Value, ctx: serde_json::Value) -> Element {
    render_element(&el, &ctx)
}

fn render_el(
    el: &serde_json::Value,
    ctx: &serde_json::Value,
    rctx: &RenderCtx,
) -> Element {
    // Handle repeat directive: expand template for each item in source
    if el.get("foreach").is_some() && el.get("do").is_some() {
        return render_repeat(el, ctx, rctx);
    }

    // _template tag available for native widget overrides when needed.
    // Currently using generic rendering for all templates (matches Flask).

    let etype = el.get("type").and_then(|t| t.as_str()).unwrap_or("placeholder");

    match etype {
        "container" | "row" | "col" => render_container(el, ctx, rctx),
        "grid" => render_grid(el, ctx, rctx),
        "text" => render_text(el, ctx),
        "button" => render_button(el, ctx, rctx),
        "icon_button" => render_icon_button(el, ctx, rctx),
        "slider" => render_slider(el, ctx, rctx),
        "number_input" => render_number_input(el, ctx, rctx),
        "text_input" => render_text_input(el, ctx, rctx),
        "select" => render_select(el, ctx, rctx),
        "toggle" | "checkbox" => render_toggle(el, ctx, rctx),
        "combo_box" => render_combo_box(el, ctx, rctx),
        "color_swatch" => render_color_swatch(el, ctx, rctx),
        "fill_stroke_widget" => render_fill_stroke_widget(el, ctx, rctx),
        "color_bar" => render_color_bar(el, ctx, rctx),
        "color_gradient" => render_color_gradient(el, ctx, rctx),
        "color_hue_bar" => render_color_hue_bar(el, ctx, rctx),
        "separator" => render_separator(el, ctx),
        "spacer" => render_spacer(el, ctx),
        "disclosure" => render_disclosure(el, ctx, rctx),
        "panel" => render_panel(el, ctx, rctx),
        "tree_view" => render_tree_view(el, ctx, rctx),
        "element_preview" => render_element_preview(el, ctx, rctx),
        "dropdown" => render_layers_filter_dropdown(el, ctx, rctx),
        _ => render_placeholder(el, ctx),
    }
}

/// Render children of an element.
fn render_children(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Vec<Element> {
    let mut elements = Vec::new();
    if let Some(children) = el.get("children").and_then(|c| c.as_array()) {
        for child in children {
            elements.push(render_el(child, ctx, rctx));
        }
    }
    if let Some(content) = el.get("content") {
        if content.is_object() {
            elements.push(render_el(content, ctx, rctx));
        }
    }
    elements
}

/// Expand a repeat directive: evaluate the source, then render the template
/// once per item with the loop variable injected via Scope.
fn render_repeat(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let repeat = el.get("foreach").unwrap();
    let template = el.get("do").unwrap();
    let source_expr = repeat.get("source").and_then(|s| s.as_str()).unwrap_or("");
    let var_name = repeat.get("as").and_then(|s| s.as_str()).unwrap_or("item");

    let items = eval_to_json(source_expr, ctx);

    let style = build_style(el, ctx);
    let layout = el.get("layout").and_then(|l| l.as_str()).unwrap_or("column");
    let dir_style = match layout {
        "wrap" => format!("display:flex;flex-wrap:wrap;{style}"),
        "row"  => format!("display:flex;flex-direction:row;{style}"),
        _      => format!("display:flex;flex-direction:column;{style}"),
    };

    // Build a lightweight base context for iteration. Heavy keys like
    // "data" (which may contain the full swatch library) are only included
    // if the template actually references them. The loop variable and any
    // outer loop variables are always included.
    let full_map = ctx.as_object().cloned().unwrap_or_default();
    let template_json = serde_json::to_string(template).unwrap_or_default();
    let mut base_map = serde_json::Map::new();
    for (k, v) in &full_map {
        // Always include small keys; skip heavy keys unless the template references them
        let is_heavy = k == "data" || k == "icons";
        if !is_heavy || template_json.contains(k.as_str()) {
            base_map.insert(k.clone(), v.clone());
        }
    }

    let mut children = Vec::new();
    if let Some(arr) = items.as_array() {
        for (i, item) in arr.iter().enumerate() {
            let mut item_obj = item.as_object().cloned().unwrap_or_default();
            item_obj.insert("_index".into(), serde_json::json!(i));

            let mut child_map = base_map.clone();
            child_map.insert(var_name.into(), serde_json::Value::Object(item_obj));
            let child_ctx = serde_json::Value::Object(child_map);

            children.push(render_el(template, &child_ctx, rctx));
        }
    }

    let id = get_id(el);
    rsx! {
        div {
            id: "{id}",
            style: "{dir_style}",
            for child in children {
                {child}
            }
        }
    }
}

/// Evaluate a path expression and return the result as a serde_json::Value.
/// Walks the JSON context directly, handling bracket notation for dynamic keys.
fn eval_to_json(source: &str, ctx: &serde_json::Value) -> serde_json::Value {
    // Parse and evaluate via the expression evaluator to resolve dynamic
    // paths like data.swatch_libraries[lib.id].swatches
    let result = expr::eval(source, ctx);

    // The expression evaluator returns Value::Str for JSON objects/arrays
    // (serialized). Try to parse it back to serde_json.
    match result {
        Value::Null => serde_json::Value::Null,
        Value::Str(ref s) => {
            // Might be serialized JSON (object or array)
            serde_json::from_str(s).unwrap_or_else(|_| serde_json::Value::String(s.clone()))
        }
        Value::Number(n) => serde_json::json!(n),
        Value::Bool(b) => serde_json::json!(b),
        Value::Color(ref c) => serde_json::Value::String(c.clone()),
        Value::List(ref items) => {
            serde_json::Value::Array(items.clone())
        }
        Value::Closure { .. } => serde_json::Value::Null,
    }
}

// ── Generic behavior dispatch ──────────────────────────────────

/// Apply dialog state when a confirm action is dispatched.
/// This handles swatch_options_confirm by updating or creating a swatch.
fn apply_dialog_confirm(
    action: &str,
    dialog: &serde_json::Map<String, serde_json::Value>,
    st: &mut crate::workspace::app_state::AppState,
) {
    match action {
        "swatch_options_confirm" => {
            let mode = dialog.get("_param_mode").and_then(|v| v.as_str()).unwrap_or("edit");
            let library = dialog.get("_param_library").and_then(|v| v.as_str()).unwrap_or("");
            let index = dialog.get("_param_index").and_then(|v| v.as_f64()).map(|n| n as usize);
            let name = dialog.get("swatch_name").and_then(|v| v.as_str()).unwrap_or("");
            let color_mode = dialog.get("color_mode").and_then(|v| v.as_str()).unwrap_or("rgb");
            // Build hex color from the dialog's computed hex value
            let hex = dialog.get("hex").and_then(|v| v.as_str()).unwrap_or("ffffff");
            let color = format!("#{hex}");

            let swatch = serde_json::json!({
                "name": name,
                "color": color,
                "color_mode": color_mode,
                "color_type": "process",
                "global": false,
            });

            if mode == "edit" {
                if let (Some(idx), Some(lib)) = (index, st.swatch_libraries.get_mut(library)) {
                    if let Some(swatches) = lib.get_mut("swatches").and_then(|s| s.as_array_mut()) {
                        if idx < swatches.len() {
                            swatches[idx] = swatch;
                        }
                    }
                }
            } else if mode == "create" {
                // Find a target library; use the first one if none specified
                let lib_key = if !library.is_empty() {
                    library.to_string()
                } else {
                    st.swatch_libraries.as_object()
                        .and_then(|m| m.keys().next().cloned())
                        .unwrap_or_default()
                };
                if let Some(lib) = st.swatch_libraries.get_mut(&lib_key) {
                    if let Some(swatches) = lib.get_mut("swatches").and_then(|s| s.as_array_mut()) {
                        swatches.push(swatch);
                    }
                }
            }
        }
        _ => {}
    }
}

/// Dispatch a named action. Tries hardcoded handlers first, then falls
/// through to the YAML actions catalog for open_dialog, dispatch, etc.
/// Returns a list of deferred effects (open_dialog, close_dialog) that
/// must be applied outside the AppState borrow.
fn dispatch_action(action: &str, params: &serde_json::Map<String, serde_json::Value>, st: &mut crate::workspace::app_state::AppState) -> Vec<serde_json::Value> {
    use crate::geometry::element::Color;
    match action {
        "set_active_color" => {
            if let Some(color_val) = params.get("color").and_then(|v| v.as_str()) {
                if let Some(c) = parse_hex_color(color_val) {
                    st.set_active_color(c);
                }
            }
            return vec![];
        }
        "set_active_color_none" => { st.set_active_to_none(); return vec![]; }
        "swap_fill_stroke" => { st.swap_fill_stroke(); return vec![]; }
        "reset_fill_stroke" => { st.reset_fill_stroke_defaults(); return vec![]; }
        "select_tool" => {
            if let Some(tool_name) = params.get("tool").and_then(|v| v.as_str()) {
                if let Some(kind) = parse_tool_kind(tool_name) {
                    st.set_tool(kind);
                }
            }
            return vec![];
        }
        "enter_isolation_mode" => {
            let layer_id = params.get("layer_id").and_then(|v| v.as_str()).map(String::from);
            let path: Option<Vec<usize>> = layer_id.as_ref().and_then(|s| {
                s.split(',').map(|p| p.parse::<usize>().ok()).collect()
            });
            let target_path = path.or_else(|| {
                // Fall back to the single panel-selected container
                if st.layers_panel_selection.len() == 1 {
                    let p = &st.layers_panel_selection[0];
                    if let Some(tab) = st.tab() {
                        if let Some(elem) = tab.model.document().get_element(p) {
                            if elem.is_group_or_layer() {
                                return Some(p.clone());
                            }
                        }
                    }
                }
                None
            });
            if let Some(p) = target_path {
                st.layers_isolation_stack.push(p);
            }
            return vec![];
        }
        "exit_isolation_mode" => {
            st.layers_isolation_stack.pop();
            return vec![];
        }
        "layer_options_confirm" => {
            use crate::geometry::element::{Element as E, LayerElem, Visibility};
            // Read dialog state from params (passed by the confirm button)
            let layer_id = params.get("layer_id").and_then(|v| v.as_str()).map(String::from);
            let path: Option<Vec<usize>> = layer_id.as_ref().and_then(|s| {
                s.split(',').map(|p| p.parse::<usize>().ok()).collect()
            });
            let name = params.get("name").and_then(|v| v.as_str()).unwrap_or("Layer").to_string();
            let lock = params.get("lock").and_then(|v| v.as_bool()).unwrap_or(false);
            let show = params.get("show").and_then(|v| v.as_bool()).unwrap_or(true);
            let preview = params.get("preview").and_then(|v| v.as_bool()).unwrap_or(true);
            let vis = if !show { Visibility::Invisible }
                else if preview { Visibility::Preview }
                else { Visibility::Outline };
            if let Some(p) = path {
                if let Some(tab) = st.tab_mut() {
                    tab.model.snapshot();
                    let mut new_doc = tab.model.document().clone();
                    if let Some(elem) = new_doc.get_element_mut(&p) {
                        if let E::Layer(le) = elem {
                            *le = LayerElem {
                                name,
                                children: le.children.clone(),
                                common: crate::geometry::element::CommonProps {
                                    locked: lock,
                                    visibility: vis,
                                    ..le.common.clone()
                                },
                            };
                        }
                    }
                    tab.model.set_document(new_doc);
                }
            }
            return vec![serde_json::json!({"close_dialog": null})];
        }
        "open_layer_options" => {
            use crate::geometry::element::Element as E;
            let layer_id = params.get("layer_id").and_then(|v| v.as_str()).map(String::from);
            // Parse layer_id as path e.g. "0,1" or just "0"
            let path: Option<Vec<usize>> = layer_id.as_ref().and_then(|s| {
                s.split(',').map(|p| p.parse::<usize>().ok()).collect()
            });
            // Build dialog params from the layer's properties
            let mut dlg_params = serde_json::Map::new();
            dlg_params.insert("mode".into(), serde_json::Value::String("edit".into()));
            if let Some(ref p) = path {
                dlg_params.insert("layer_id".into(), serde_json::Value::String(
                    p.iter().map(|i| i.to_string()).collect::<Vec<_>>().join(",")
                ));
                if let Some(tab) = st.tab() {
                    if let Some(elem) = tab.model.document().get_element(p) {
                        if let E::Layer(le) = elem {
                            dlg_params.insert("name".into(), serde_json::Value::String(le.name.clone()));
                            dlg_params.insert("color".into(), serde_json::Value::String("#4a90d9".into()));
                            dlg_params.insert("color_preset".into(), serde_json::Value::String("light_blue".into()));
                            dlg_params.insert("lock".into(), serde_json::Value::Bool(le.common.locked));
                            use crate::geometry::element::Visibility;
                            let show = le.common.visibility != Visibility::Invisible;
                            let preview = le.common.visibility == Visibility::Preview;
                            dlg_params.insert("show".into(), serde_json::Value::Bool(show));
                            dlg_params.insert("preview".into(), serde_json::Value::Bool(preview));
                            dlg_params.insert("dim_images".into(), serde_json::Value::Bool(false));
                            dlg_params.insert("dim_percentage".into(), serde_json::Value::from(50));
                        }
                    }
                }
            }
            return vec![serde_json::json!({
                "open_dialog": {
                    "id": "layer_options",
                    "params": dlg_params
                }
            })];
        }
        "new_layer" => {
            use crate::geometry::element::{Element as E, LayerElem, CommonProps};
            let panel_sel = st.layers_panel_selection.clone();
            if let Some(tab) = st.tab_mut() {
                tab.model.snapshot();
                let doc = tab.model.document().clone();
                let used: std::collections::HashSet<String> = doc.layers.iter()
                    .filter_map(|l| if let E::Layer(le) = l { Some(le.name.clone()) } else { None })
                    .collect();
                let mut n = 1;
                let name = loop {
                    let candidate = format!("Layer {n}");
                    if !used.contains(&candidate) { break candidate; }
                    n += 1;
                };
                let new_layer = E::Layer(LayerElem {
                    name,
                    children: Vec::new(),
                    common: CommonProps::default(),
                });
                let insert_pos = panel_sel.iter()
                    .filter(|p| p.len() == 1)
                    .map(|p| p[0])
                    .min()
                    .map(|i| i + 1)
                    .unwrap_or(doc.layers.len());
                let mut new_doc = doc;
                new_doc.layers.insert(insert_pos, new_layer);
                tab.model.set_document(new_doc);
            }
            return vec![];
        }
        "delete_layer_selection" => {
            let paths = st.layers_panel_selection.clone();
            if paths.is_empty() { return vec![]; }
            if let Some(tab) = st.tab_mut() {
                let doc = tab.model.document().clone();
                let layer_count = doc.layers.len();
                let top_level_deletes = paths.iter().filter(|p| p.len() == 1).count();
                if top_level_deletes >= layer_count { return vec![]; }
                tab.model.snapshot();
                let mut sorted_paths = paths.clone();
                sorted_paths.sort();
                sorted_paths.reverse();
                let mut new_doc = doc;
                for path in &sorted_paths {
                    new_doc = new_doc.delete_element(path);
                }
                tab.model.set_document(new_doc);
            }
            st.layers_panel_selection.clear();
            return vec![];
        }
        "duplicate_layer_selection" => {
            let paths = st.layers_panel_selection.clone();
            if paths.is_empty() { return vec![]; }
            if let Some(tab) = st.tab_mut() {
                tab.model.snapshot();
                let mut new_doc = tab.model.document().clone();
                let mut sorted_paths = paths.clone();
                sorted_paths.sort();
                sorted_paths.reverse();
                for path in &sorted_paths {
                    if let Some(elem) = new_doc.get_element(path) {
                        let dup = elem.clone();
                        new_doc = new_doc.insert_element_after(path, dup);
                    }
                }
                tab.model.set_document(new_doc);
            }
            return vec![];
        }
        "new_group" => {
            use crate::geometry::element::{Element as E, GroupElem, CommonProps};
            use std::rc::Rc;
            let paths = st.layers_panel_selection.clone();
            if paths.is_empty() { return vec![]; }
            let parent_prefix: Vec<usize> = paths[0][..paths[0].len()-1].to_vec();
            if !paths.iter().all(|p| p[..p.len()-1] == parent_prefix[..]) { return vec![]; }
            if parent_prefix.is_empty() { return vec![]; }
            if let Some(tab) = st.tab_mut() {
                tab.model.snapshot();
                let doc = tab.model.document().clone();
                let mut children: Vec<Rc<E>> = Vec::new();
                for path in &paths {
                    if let Some(elem) = doc.get_element(path) {
                        children.push(Rc::new(elem.clone()));
                    }
                }
                let new_group = E::Group(GroupElem {
                    children,
                    common: CommonProps::default(),
                });
                let mut sorted_paths = paths.clone();
                sorted_paths.sort();
                let top_path = sorted_paths[0].clone();
                sorted_paths.reverse();
                let mut new_doc = doc;
                for path in &sorted_paths {
                    new_doc = new_doc.delete_element(path);
                }
                new_doc = new_doc.insert_element_at(&top_path, new_group);
                tab.model.set_document(new_doc);
                st.layers_panel_selection = vec![top_path];
            }
            return vec![];
        }
        "toggle_all_layers_visibility" => {
            use crate::geometry::element::{Element as E, Visibility};
            if let Some(tab) = st.tab_mut() {
                let mut new_doc = tab.model.document().clone();
                let any_visible = new_doc.layers.iter()
                    .any(|l| l.visibility() != Visibility::Invisible);
                let target = if any_visible { Visibility::Invisible } else { Visibility::Preview };
                tab.model.snapshot();
                for i in 0..new_doc.layers.len() {
                    if let E::Layer(_) = new_doc.layers[i] {
                        new_doc.layers[i].common_mut().visibility = target;
                    }
                }
                tab.model.set_document(new_doc);
            }
            return vec![];
        }
        "toggle_all_layers_outline" => {
            use crate::geometry::element::{Element as E, Visibility};
            if let Some(tab) = st.tab_mut() {
                let mut new_doc = tab.model.document().clone();
                let any_preview = new_doc.layers.iter()
                    .any(|l| l.visibility() == Visibility::Preview);
                let target = if any_preview { Visibility::Outline } else { Visibility::Preview };
                tab.model.snapshot();
                for i in 0..new_doc.layers.len() {
                    if let E::Layer(_) = new_doc.layers[i] {
                        new_doc.layers[i].common_mut().visibility = target;
                    }
                }
                tab.model.set_document(new_doc);
            }
            return vec![];
        }
        "toggle_all_layers_lock" => {
            use crate::geometry::element::Element as E;
            if let Some(tab) = st.tab_mut() {
                let mut new_doc = tab.model.document().clone();
                let any_unlocked = new_doc.layers.iter().any(|l| !l.locked());
                let target = any_unlocked;
                tab.model.snapshot();
                for i in 0..new_doc.layers.len() {
                    if let E::Layer(_) = new_doc.layers[i] {
                        new_doc.layers[i].common_mut().locked = target;
                    }
                }
                tab.model.set_document(new_doc);
            }
            return vec![];
        }
        "flatten_artwork" => {
            use crate::geometry::element::Element as E;
            use std::rc::Rc;
            let paths = st.layers_panel_selection.clone();
            if paths.is_empty() { return vec![]; }
            if let Some(tab) = st.tab_mut() {
                tab.model.snapshot();
                let doc = tab.model.document().clone();
                // Recursively unpack groups: for each panel-selected path,
                // if it's a Group, replace it with its children in place.
                let mut new_doc = doc;
                // Process in reverse so earlier paths stay valid
                let mut sorted = paths.clone();
                sorted.sort();
                sorted.reverse();
                for path in &sorted {
                    if let Some(E::Group(g)) = new_doc.get_element(path).cloned().as_ref() {
                        let children: Vec<E> = g.children.iter().map(|rc| (**rc).clone()).collect();
                        new_doc = new_doc.delete_element(path);
                        let mut insert_path = path.clone();
                        for child in children.into_iter().rev() {
                            new_doc = new_doc.insert_element_at(&insert_path, child);
                            let last = insert_path.len() - 1;
                            insert_path[last] += 1;
                        }
                    }
                }
                tab.model.set_document(new_doc);
            }
            st.layers_panel_selection.clear();
            return vec![];
        }
        "collect_in_new_layer" => {
            use crate::geometry::element::{Element as E, LayerElem, CommonProps};
            let paths = st.layers_panel_selection.clone();
            if paths.is_empty() { return vec![]; }
            if let Some(tab) = st.tab_mut() {
                tab.model.snapshot();
                let doc = tab.model.document().clone();
                let used: std::collections::HashSet<String> = doc.layers.iter()
                    .filter_map(|l| if let E::Layer(le) = l { Some(le.name.clone()) } else { None })
                    .collect();
                let mut n = 1;
                let name = loop {
                    let candidate = format!("Layer {n}");
                    if !used.contains(&candidate) { break candidate; }
                    n += 1;
                };
                // Collect elements in document order
                let mut sorted_paths = paths.clone();
                sorted_paths.sort();
                let mut elems: Vec<E> = Vec::new();
                for path in &sorted_paths {
                    if let Some(e) = doc.get_element(path) {
                        elems.push(e.clone());
                    }
                }
                // Delete originals in reverse
                let mut new_doc = doc;
                let mut rev_paths = sorted_paths.clone();
                rev_paths.reverse();
                for path in &rev_paths {
                    new_doc = new_doc.delete_element(path);
                }
                let children = elems.into_iter().map(std::rc::Rc::new).collect();
                let new_layer = E::Layer(LayerElem {
                    name,
                    children,
                    common: CommonProps::default(),
                });
                new_doc.layers.push(new_layer);
                tab.model.set_document(new_doc);
                let new_path = vec![st.tab().map(|t| t.model.document().layers.len() - 1).unwrap_or(0)];
                st.layers_panel_selection = vec![new_path];
            }
            return vec![];
        }
        _ => {}
    }
    // Fall through to YAML actions catalog
    let ws = crate::interpreter::workspace::Workspace::load();
    if let Some(ws) = ws {
        if let Some(action_def) = ws.actions().get(action) {
            if let Some(serde_json::Value::Array(effects)) = action_def.get("effects") {
                let mut deferred = Vec::new();
                let mut ctx = serde_json::Map::new();
                if !params.is_empty() {
                    ctx.insert("param".to_string(), serde_json::Value::Object(params.clone()));
                }
                for eff in effects {
                    if eff.get("open_dialog").is_some() || eff.get("close_dialog").is_some() {
                        // Resolve param expressions in the effect
                        let mut resolved_eff = eff.clone();
                        if let Some(od) = eff.get("open_dialog").and_then(|o| o.as_object()) {
                            if let Some(eff_params) = od.get("params").and_then(|p| p.as_object()) {
                                let mut resolved_params = serde_json::Map::new();
                                let eval_ctx = serde_json::json!({"param": serde_json::Value::Object(params.clone())});
                                for (k, v) in eff_params {
                                    if let Some(expr_str) = v.as_str() {
                                        let result = super::expr::eval(expr_str, &eval_ctx);
                                        resolved_params.insert(k.clone(), super::effects::value_to_json(&result));
                                    } else {
                                        resolved_params.insert(k.clone(), v.clone());
                                    }
                                }
                                let mut new_od = od.clone();
                                new_od.insert("params".to_string(), serde_json::Value::Object(resolved_params));
                                resolved_eff = serde_json::json!({"open_dialog": new_od});
                            }
                        }
                        deferred.push(resolved_eff);
                    }
                    // Handle set effects
                    if let Some(set_map) = eff.get("set").and_then(|v| v.as_object()) {
                        apply_set_effects(set_map, st);
                    }
                    // Handle set_panel_state effects
                    if let Some(sps) = eff.get("set_panel_state").and_then(|v| v.as_object()) {
                        apply_set_panel_state(sps, st);
                    }
                    // Handle swap effects
                    if let Some(serde_json::Value::Array(keys)) = eff.get("swap") {
                        if keys.len() == 2 {
                            let a = keys[0].as_str().unwrap_or("").to_string();
                            let b = keys[1].as_str().unwrap_or("").to_string();
                            let a_val = get_app_state_field(&a, st);
                            let b_val = get_app_state_field(&b, st);
                            set_app_state_field(&a, &b_val, st);
                            set_app_state_field(&b, &a_val, st);
                        }
                    }
                    // Handle swap_panel_state effects
                    if let Some(serde_json::Value::Array(keys)) = eff.get("swap_panel_state") {
                        if keys.len() == 2 {
                            let a = keys[0].as_str().unwrap_or("");
                            let b = keys[1].as_str().unwrap_or("");
                            let sp = &mut st.stroke_panel;
                            let a_val = get_stroke_field(sp, a);
                            let b_val = get_stroke_field(sp, b);
                            set_stroke_field(sp, a, &b_val);
                            set_stroke_field(sp, b, &a_val);
                        }
                    }
                }
                return deferred;
            }
        }
    }
    vec![]
}

/// Run effects (e.g., `set: { fill_on_top: true }`).
/// Returns a list of deferred dialog effects (open_dialog/close_dialog)
/// that must be applied outside the AppState borrow.
fn run_effects(
    effects: &[serde_json::Value],
    st: &mut crate::workspace::app_state::AppState,
) -> Vec<serde_json::Value> {
    let mut dialog_effects = Vec::new();
    for effect in effects {
        if let Some(set_map) = effect.get("set").and_then(|v| v.as_object()) {
            apply_set_effects(set_map, st);
        }
        // set_panel_state: { key, value }
        if let Some(sps) = effect.get("set_panel_state").and_then(|v| v.as_object()) {
            apply_set_panel_state(sps, st);
        }
        // swap_panel_state: [key_a, key_b]
        if let Some(serde_json::Value::Array(keys)) = effect.get("swap_panel_state") {
            if keys.len() == 2 {
                let a = keys[0].as_str().unwrap_or("");
                let b = keys[1].as_str().unwrap_or("");
                let sp = &mut st.stroke_panel;
                let a_val = get_stroke_field(sp, a);
                let b_val = get_stroke_field(sp, b);
                set_stroke_field(sp, a, &b_val);
                set_stroke_field(sp, b, &a_val);
            }
        }
        // swap: [state_key_a, state_key_b]
        if let Some(serde_json::Value::Array(keys)) = effect.get("swap") {
            if keys.len() == 2 {
                let a = keys[0].as_str().unwrap_or("").to_string();
                let b = keys[1].as_str().unwrap_or("").to_string();
                let a_val = get_app_state_field(&a, st);
                let b_val = get_app_state_field(&b, st);
                set_app_state_field(&a, &b_val, st);
                set_app_state_field(&b, &a_val, st);
            }
        }
        // Defer dialog effects — they need the dialog signal, not AppState
        if effect.get("open_dialog").is_some() || effect.get("close_dialog").is_some() {
            dialog_effects.push(effect.clone());
        }
    }
    dialog_effects
}

/// Apply `set: { key: value, ... }` effects to AppState (schema-driven).
///
/// Validates each key against the schema, coerces the value, and dispatches
/// to the appropriate AppState setter. Writes are applied as a batch — all
/// coercions run before any writes are committed.
fn apply_set_effects(
    set_map: &serde_json::Map<String, serde_json::Value>,
    st: &mut crate::workspace::app_state::AppState,
) {
    use super::schema::{get_entry, coerce_value, Diagnostic};

    let mut pending: Vec<(String, serde_json::Value)> = Vec::new();
    let mut diagnostics: Vec<Diagnostic> = Vec::new();

    for (key, val) in set_map {
        match get_entry(key.as_str()) {
            None => {
                diagnostics.push(Diagnostic::warning(key, "unknown_key"));
            }
            Some(entry) => {
                if !entry.writable {
                    diagnostics.push(Diagnostic::warning(key, "field_not_writable"));
                    continue;
                }
                match coerce_value(val, &entry) {
                    Err(reason) => {
                        diagnostics.push(Diagnostic::error(key, reason));
                    }
                    Ok(coerced) => {
                        pending.push((key.clone(), coerced));
                    }
                }
            }
        }
    }

    // Log diagnostics (use web_sys::console::warn_1 in web context, else eprintln)
    for d in &diagnostics {
        #[cfg(target_arch = "wasm32")]
        {
            let msg = format!("[set:] {} key={:?} reason={}", d.level, d.key, d.reason);
            web_sys::console::warn_1(&msg.into());
        }
        #[cfg(not(target_arch = "wasm32"))]
        {
            eprintln!("[set:] {} key={:?} reason={}", d.level, d.key, d.reason);
        }
    }

    // Apply all successful writes as a batch
    for (key, val) in pending {
        set_app_state_field(key.as_str(), &val, st);
    }
}

/// Write a single validated+coerced value to the appropriate AppState field.
fn set_app_state_field(
    key: &str,
    val: &serde_json::Value,
    st: &mut crate::workspace::app_state::AppState,
) {
    use crate::geometry::element::{Color, Fill, Stroke};
    use crate::tools::tool::ToolKind;

    match key {
        "fill_on_top" => {
            if let Some(b) = val.as_bool() { st.fill_on_top = b; }
        }
        "active_tool" => {
            if let Some(kind) = val.as_str().and_then(parse_tool_kind) {
                st.active_tool = kind;
            }
        }
        "fill_color" => {
            let new_fill = if val.is_null() {
                None
            } else {
                val.as_str().and_then(Color::from_hex).map(Fill::new)
            };
            st.app_default_fill = new_fill;
            if let Some(tab) = st.tabs.get_mut(st.active_tab) {
                tab.model.default_fill = new_fill;
            }
        }
        "stroke_color" => {
            if val.is_null() {
                st.app_default_stroke = None;
                if let Some(tab) = st.tabs.get_mut(st.active_tab) {
                    tab.model.default_stroke = None;
                }
            } else if let Some(color) = val.as_str().and_then(Color::from_hex) {
                let width = st.app_default_stroke.map(|s| s.width).unwrap_or(1.0);
                let new_stroke = Some(Stroke::new(color, width));
                st.app_default_stroke = new_stroke;
                if let Some(tab) = st.tabs.get_mut(st.active_tab) {
                    let tab_width = tab.model.default_stroke.map(|s| s.width).unwrap_or(width);
                    tab.model.default_stroke = Some(Stroke::new(color, tab_width));
                }
            }
        }
        "stroke_width" => {
            if let Some(w) = val.as_f64() {
                if let Some(ref mut s) = st.app_default_stroke {
                    s.width = w;
                }
                if let Some(tab) = st.tabs.get_mut(st.active_tab) {
                    if let Some(ref mut s) = tab.model.default_stroke {
                        s.width = w;
                    }
                }
            }
        }
        // Stroke panel fields
        "stroke_cap" => { if let Some(s) = val.as_str() { st.stroke_panel.cap = s.into(); } }
        "stroke_join" => { if let Some(s) = val.as_str() { st.stroke_panel.join = s.into(); } }
        "stroke_miter_limit" => { if let Some(n) = val.as_f64() { st.stroke_panel.miter_limit = n; } }
        "stroke_align" => { if let Some(s) = val.as_str() { st.stroke_panel.align = s.into(); } }
        "stroke_dashed" => { if let Some(b) = val.as_bool() { st.stroke_panel.dashed = b; } }
        "stroke_dash_1" => { if let Some(n) = val.as_f64() { st.stroke_panel.dash_1 = n; } }
        "stroke_gap_1" => { if let Some(n) = val.as_f64() { st.stroke_panel.gap_1 = n; } }
        "stroke_dash_2" => { st.stroke_panel.dash_2 = val.as_f64(); }
        "stroke_gap_2" => { st.stroke_panel.gap_2 = val.as_f64(); }
        "stroke_dash_3" => { st.stroke_panel.dash_3 = val.as_f64(); }
        "stroke_gap_3" => { st.stroke_panel.gap_3 = val.as_f64(); }
        "stroke_start_arrowhead" => { if let Some(s) = val.as_str() { st.stroke_panel.start_arrowhead = s.into(); } }
        "stroke_end_arrowhead" => { if let Some(s) = val.as_str() { st.stroke_panel.end_arrowhead = s.into(); } }
        "stroke_start_arrowhead_scale" => { if let Some(n) = val.as_f64() { st.stroke_panel.start_arrowhead_scale = n; } }
        "stroke_end_arrowhead_scale" => { if let Some(n) = val.as_f64() { st.stroke_panel.end_arrowhead_scale = n; } }
        "stroke_link_arrowhead_scale" => { if let Some(b) = val.as_bool() { st.stroke_panel.link_arrowhead_scale = b; } }
        "stroke_arrow_align" => { if let Some(s) = val.as_str() { st.stroke_panel.arrow_align = s.into(); } }
        "stroke_profile" => { if let Some(s) = val.as_str() { st.stroke_panel.profile = s.into(); } }
        "stroke_profile_flipped" => { if let Some(b) = val.as_bool() { st.stroke_panel.profile_flipped = b; } }
        // Workspace layout visibility fields are managed by the generic StateStore,
        // not directly by AppState. A set: on these keys has no effect here.
        "toolbar_visible" | "canvas_visible" | "dock_visible"
        | "canvas_maximized" | "dock_collapsed"
        | "active_tab" | "tab_count" => {}
        _ => {}
    }
}

/// Apply `set_panel_state: { key, value }` effects to the stroke panel state.
fn apply_set_panel_state(
    sps: &serde_json::Map<String, serde_json::Value>,
    st: &mut crate::workspace::app_state::AppState,
) {
    let key = sps.get("key").and_then(|v| v.as_str()).unwrap_or("");
    let val = sps.get("value").unwrap_or(&serde_json::Value::Null);
    // Evaluate expression values
    let resolved = if let Some(expr_str) = val.as_str() {
        // Build minimal eval context
        let sp = &st.stroke_panel;
        let panel_json = serde_json::json!({
            "cap": sp.cap, "join": sp.join, "miter_limit": sp.miter_limit,
            "align_stroke": sp.align, "dashed": sp.dashed,
            "dash_1": sp.dash_1, "gap_1": sp.gap_1,
            "weight": st.app_default_stroke.as_ref().map(|s| s.width).unwrap_or(1.0),
            "start_arrowhead": sp.start_arrowhead, "end_arrowhead": sp.end_arrowhead,
            "start_arrowhead_scale": sp.start_arrowhead_scale,
            "end_arrowhead_scale": sp.end_arrowhead_scale,
            "link_arrowhead_scale": sp.link_arrowhead_scale,
            "arrow_align": sp.arrow_align, "profile": sp.profile,
            "profile_flipped": sp.profile_flipped,
        });
        let ctx = serde_json::json!({"panel": panel_json, "state": {}});
        let result = super::expr::eval(expr_str, &ctx);
        super::effects::value_to_json(&result)
    } else {
        val.clone()
    };
    set_stroke_field(&mut st.stroke_panel, key, &resolved);
    // Also sync stroke_width when weight changes
    if key == "weight" {
        if let Some(w) = resolved.as_f64() {
            if let Some(ref mut stroke) = st.app_default_stroke {
                stroke.width = w;
            }
            if let Some(tab) = st.tabs.get_mut(st.active_tab) {
                if let Some(ref mut stroke) = tab.model.default_stroke {
                    stroke.width = w;
                }
            }
        }
    }
    // Propagate rendering-affecting changes to selected elements
    if matches!(key, "cap" | "join" | "weight" | "miter_limit" |
                "dashed" | "dash_1" | "gap_1" | "dash_2" | "gap_2" | "dash_3" | "gap_3" |
                "align_stroke" | "start_arrowhead" | "end_arrowhead" |
                "start_arrowhead_scale" | "end_arrowhead_scale" | "arrow_align" |
                "profile" | "profile_flipped") {
        st.apply_stroke_panel_to_selection();
    }
}

/// Get a stroke panel field as a JSON value.
fn get_stroke_field(sp: &crate::workspace::app_state::StrokePanelState, key: &str) -> serde_json::Value {
    use serde_json::Value as J;
    match key {
        "cap" => J::String(sp.cap.clone()),
        "join" => J::String(sp.join.clone()),
        "miter_limit" => serde_json::json!(sp.miter_limit),
        "align_stroke" => J::String(sp.align.clone()),
        "dashed" => J::Bool(sp.dashed),
        "dash_1" => serde_json::json!(sp.dash_1),
        "gap_1" => serde_json::json!(sp.gap_1),
        "dash_2" => sp.dash_2.map_or(J::Null, |v| serde_json::json!(v)),
        "gap_2" => sp.gap_2.map_or(J::Null, |v| serde_json::json!(v)),
        "dash_3" => sp.dash_3.map_or(J::Null, |v| serde_json::json!(v)),
        "gap_3" => sp.gap_3.map_or(J::Null, |v| serde_json::json!(v)),
        "start_arrowhead" => J::String(sp.start_arrowhead.clone()),
        "end_arrowhead" => J::String(sp.end_arrowhead.clone()),
        "start_arrowhead_scale" => serde_json::json!(sp.start_arrowhead_scale),
        "end_arrowhead_scale" => serde_json::json!(sp.end_arrowhead_scale),
        "link_arrowhead_scale" => J::Bool(sp.link_arrowhead_scale),
        "arrow_align" => J::String(sp.arrow_align.clone()),
        "profile" => J::String(sp.profile.clone()),
        "profile_flipped" => J::Bool(sp.profile_flipped),
        _ => J::Null,
    }
}

/// Set a stroke panel field from a JSON value.
fn set_stroke_field(sp: &mut crate::workspace::app_state::StrokePanelState, key: &str, val: &serde_json::Value) {
    match key {
        "cap" => { if let Some(s) = val.as_str() { sp.cap = s.into(); } }
        "join" => { if let Some(s) = val.as_str() { sp.join = s.into(); } }
        "miter_limit" => { if let Some(n) = val.as_f64() { sp.miter_limit = n; } }
        "align_stroke" => { if let Some(s) = val.as_str() { sp.align = s.into(); } }
        "dashed" => { if let Some(b) = val.as_bool() { sp.dashed = b; } }
        "dash_1" => { if let Some(n) = val.as_f64() { sp.dash_1 = n; } }
        "gap_1" => { if let Some(n) = val.as_f64() { sp.gap_1 = n; } }
        "dash_2" => { sp.dash_2 = val.as_f64(); }
        "gap_2" => { sp.gap_2 = val.as_f64(); }
        "dash_3" => { sp.dash_3 = val.as_f64(); }
        "gap_3" => { sp.gap_3 = val.as_f64(); }
        "start_arrowhead" => { if let Some(s) = val.as_str() { sp.start_arrowhead = s.into(); } }
        "end_arrowhead" => { if let Some(s) = val.as_str() { sp.end_arrowhead = s.into(); } }
        "start_arrowhead_scale" => { if let Some(n) = val.as_f64() { sp.start_arrowhead_scale = n; } }
        "end_arrowhead_scale" => { if let Some(n) = val.as_f64() { sp.end_arrowhead_scale = n; } }
        "link_arrowhead_scale" => { if let Some(b) = val.as_bool() { sp.link_arrowhead_scale = b; } }
        "arrow_align" => { if let Some(s) = val.as_str() { sp.arrow_align = s.into(); } }
        "profile" => { if let Some(s) = val.as_str() { sp.profile = s.into(); } }
        "profile_flipped" => { if let Some(b) = val.as_bool() { sp.profile_flipped = b; } }
        "weight" => {
            // weight is not on StrokePanelState — handled by caller via Stroke.width
        }
        _ => {}
    }
}

/// Read a top-level AppState field as a JSON value (for use with swap:).
fn get_app_state_field(key: &str, st: &crate::workspace::app_state::AppState) -> serde_json::Value {
    use crate::tools::tool::ToolKind;
    match key {
        "fill_color" => match st.app_default_fill {
            None => serde_json::Value::Null,
            Some(f) => serde_json::Value::String(format!("#{}", f.color.to_hex())),
        },
        "stroke_color" => match st.app_default_stroke {
            None => serde_json::Value::Null,
            Some(s) => serde_json::Value::String(format!("#{}", s.color.to_hex())),
        },
        "fill_on_top" => serde_json::Value::Bool(st.fill_on_top),
        "active_tool" => {
            let name = match st.active_tool {
                ToolKind::Selection => "selection",
                ToolKind::PartialSelection => "partial_selection",
                ToolKind::InteriorSelection => "interior_selection",
                ToolKind::Pen => "pen",
                ToolKind::AddAnchorPoint => "add_anchor",
                ToolKind::DeleteAnchorPoint => "delete_anchor",
                ToolKind::AnchorPoint => "anchor_point",
                ToolKind::Pencil => "pencil",
                ToolKind::PathEraser => "path_eraser",
                ToolKind::Smooth => "smooth",
                ToolKind::Type => "type",
                ToolKind::TypeOnPath => "type_on_path",
                ToolKind::Line => "line",
                ToolKind::Rect => "rect",
                ToolKind::RoundedRect => "rounded_rect",
                ToolKind::Polygon => "polygon",
                ToolKind::Star => "star",
                ToolKind::Lasso => "lasso",
            };
            serde_json::Value::String(name.to_string())
        }
        _ => {
            // Delegate stroke panel fields (stroke_cap, stroke_join, etc.)
            let panel_key = key.strip_prefix("stroke_").unwrap_or(key);
            get_stroke_field(&st.stroke_panel, panel_key)
        }
    }
}

/// Get/set stroke state fields using the `state.stroke_*` naming convention (legacy, unused).
fn get_stroke_state_field(sp: &crate::workspace::app_state::StrokePanelState, key: &str) -> serde_json::Value {
    let panel_key = key.strip_prefix("stroke_").unwrap_or(key);
    get_stroke_field(sp, panel_key)
}

fn set_stroke_state_field(sp: &mut crate::workspace::app_state::StrokePanelState, key: &str, val: &serde_json::Value) {
    let panel_key = key.strip_prefix("stroke_").unwrap_or(key);
    set_stroke_field(sp, panel_key, val);
}

/// Build an onclick handler from an element's behavior declarations.
/// Returns None if the element has no click behaviors.
fn build_click_handler(
    el: &serde_json::Value,
    ctx: &serde_json::Value,
    rctx: &RenderCtx,
) -> Option<EventHandler<Event<MouseData>>> {
    build_mouse_event_handler(el, ctx, rctx, "click")
}

/// Build an ondoubleclick handler from an element's behavior declarations.
fn build_dblclick_handler(
    el: &serde_json::Value,
    ctx: &serde_json::Value,
    rctx: &RenderCtx,
) -> Option<EventHandler<Event<MouseData>>> {
    build_mouse_event_handler(el, ctx, rctx, "double_click")
}

/// Build a mouse event handler for a specific event type.
fn build_mouse_event_handler(
    el: &serde_json::Value,
    ctx: &serde_json::Value,
    rctx: &RenderCtx,
    event_name: &str,
) -> Option<EventHandler<Event<MouseData>>> {
    let behaviors = el.get("behavior").and_then(|b| b.as_array())?;
    let click_behaviors: Vec<&serde_json::Value> = behaviors.iter()
        .filter(|b| b.get("event").and_then(|e| e.as_str()).unwrap_or("click") == event_name)
        .collect();
    if click_behaviors.is_empty() {
        return None;
    }

    // Pre-resolve params and snapshot what we need for the closure
    let mut resolved_actions: Vec<(Option<String>, serde_json::Map<String, serde_json::Value>, Vec<serde_json::Value>, Option<String>)> = Vec::new();
    for b in &click_behaviors {
        let action = b.get("action").and_then(|a| a.as_str()).map(|s| s.to_string());
        let condition = b.get("condition").and_then(|c| c.as_str()).map(|s| s.to_string());
        let effects = b.get("effects").and_then(|e| e.as_array()).cloned().unwrap_or_default();

        // Resolve params against context
        let raw_params = b.get("params").and_then(|p| p.as_object()).cloned().unwrap_or_default();
        let mut resolved_params = serde_json::Map::new();
        for (k, v) in &raw_params {
            if let Some(expr_str) = v.as_str() {
                let result = expr::eval(expr_str, ctx);
                match result {
                    Value::Color(c) => { resolved_params.insert(k.clone(), serde_json::Value::String(c)); }
                    Value::Str(s) => { resolved_params.insert(k.clone(), serde_json::Value::String(s)); }
                    Value::Number(n) => { resolved_params.insert(k.clone(), serde_json::json!(n)); }
                    Value::Bool(b) => { resolved_params.insert(k.clone(), serde_json::json!(b)); }
                    Value::Null => {
                        // If expression evaluated to null but the original was a bare
                        // identifier (no dots/operators), treat it as a literal string.
                        // YAML `{ tool: selection }` means param is the string "selection".
                        if expr_str.chars().all(|c| c.is_alphanumeric() || c == '_') && !expr_str.is_empty() {
                            resolved_params.insert(k.clone(), serde_json::Value::String(expr_str.to_string()));
                        } else {
                            resolved_params.insert(k.clone(), serde_json::Value::Null);
                        }
                    }
                    Value::List(l) => { resolved_params.insert(k.clone(), serde_json::Value::Array(l)); }
                    Value::Closure { .. } => { resolved_params.insert(k.clone(), serde_json::Value::Null); }
                };
            } else {
                resolved_params.insert(k.clone(), v.clone());
            }
        }
        resolved_actions.push((action, resolved_params, effects, condition));
    }

    let app = rctx.app.clone();
    let mut revision = rctx.revision;
    let ctx_snapshot = ctx.clone();
    let mut dialog_signal = rctx.dialog_ctx.0;

    Some(EventHandler::new(move |_evt: Event<MouseData>| {
        let app = app.clone();
        let actions = resolved_actions.clone();
        let ctx_snap = ctx_snapshot.clone();
        spawn(async move {
            let mut deferred_dialog_effects = Vec::new();
            {
                let mut st = app.borrow_mut();
                for (action, params, effects, condition) in &actions {
                    // Check condition
                    if let Some(cond_expr) = condition {
                        let result = expr::eval(cond_expr, &ctx_snap);
                        if !result.to_bool() {
                            continue;
                        }
                    }
                    // Run effects (returns deferred dialog effects)
                    if !effects.is_empty() {
                        let dialog_effs = run_effects(effects, &mut st);
                        deferred_dialog_effects.extend(dialog_effs);
                    }
                    // Dispatch action
                    if let Some(action_name) = action {
                        if action_name == "dismiss_dialog" {
                            deferred_dialog_effects.push(serde_json::json!({"close_dialog": null}));
                        } else {
                            let action_deferred = dispatch_action(action_name, params, &mut st);
                            deferred_dialog_effects.extend(action_deferred);
                        }
                    }
                }
            } // drop st borrow

            // Apply deferred dialog effects (outside AppState borrow)
            for eff in &deferred_dialog_effects {
                if eff.get("close_dialog").is_some() {
                    dialog_signal.set(None);
                }
                if let Some(od) = eff.get("open_dialog") {
                    let dlg_id = od.get("id").and_then(|v| v.as_str()).unwrap_or("");
                    let raw_params = od.get("params").and_then(|p| p.as_object()).cloned().unwrap_or_default();
                    let live_state = {
                        let st = app.borrow();
                        crate::workspace::dock_panel::build_live_state_map(&st)
                    };
                    super::dialog_view::open_dialog(&mut dialog_signal, dlg_id, &raw_params, &live_state);
                }
            }
            revision += 1;
        });
    }))
}

/// Build a mousedown handler that processes start_timer effects.
fn build_mousedown_handler(
    el: &serde_json::Value,
    ctx: &serde_json::Value,
    rctx: &RenderCtx,
) -> Option<EventHandler<Event<MouseData>>> {
    let behaviors = el.get("behavior").and_then(|b| b.as_array())?;
    let md_behaviors: Vec<&serde_json::Value> = behaviors.iter()
        .filter(|b| b.get("event").and_then(|e| e.as_str()) == Some("mouse_down"))
        .collect();
    if md_behaviors.is_empty() {
        return None;
    }

    let mut timer_specs: Vec<(String, u32, Vec<serde_json::Value>)> = Vec::new();
    for b in &md_behaviors {
        if let Some(effects) = b.get("effects").and_then(|e| e.as_array()) {
            for eff in effects {
                if let Some(st) = eff.get("start_timer").and_then(|s| s.as_object()) {
                    let id = st.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string();
                    let delay = st.get("delay_ms").and_then(|v| v.as_u64()).unwrap_or(250) as u32;
                    let nested = st.get("effects").and_then(|e| e.as_array()).cloned().unwrap_or_default();
                    timer_specs.push((id, delay, nested));
                }
            }
        }
    }

    if timer_specs.is_empty() {
        return None;
    }

    let timer_ctx = rctx.timer_ctx.clone();
    let app = rctx.app.clone();
    let dialog_signal = rctx.dialog_ctx.0;
    let revision = rctx.revision;

    Some(EventHandler::new(move |evt: Event<MouseData>| {
        // Capture mouse position for popover anchoring
        let coords = evt.data().page_coordinates();
        let anchor = (coords.x, coords.y);
        for (id, delay, effects) in &timer_specs {
            super::timer::start_timer(
                &timer_ctx, id, *delay, effects.clone(),
                app.clone(), dialog_signal, revision,
                Some(anchor),
            );
        }
    }))
}

/// Build a mouseup handler that processes cancel_timer effects.
fn build_mouseup_handler(
    el: &serde_json::Value,
    _ctx: &serde_json::Value,
    rctx: &RenderCtx,
) -> Option<EventHandler<Event<MouseData>>> {
    let behaviors = el.get("behavior").and_then(|b| b.as_array())?;
    let mu_behaviors: Vec<&serde_json::Value> = behaviors.iter()
        .filter(|b| b.get("event").and_then(|e| e.as_str()) == Some("mouse_up"))
        .collect();
    if mu_behaviors.is_empty() {
        return None;
    }

    let mut cancel_ids: Vec<String> = Vec::new();
    for b in &mu_behaviors {
        if let Some(effects) = b.get("effects").and_then(|e| e.as_array()) {
            for eff in effects {
                if let Some(ct) = eff.get("cancel_timer") {
                    if let Some(id) = ct.as_str() {
                        cancel_ids.push(id.to_string());
                    }
                }
            }
        }
    }

    if cancel_ids.is_empty() {
        return None;
    }

    let timer_ctx = rctx.timer_ctx.clone();

    Some(EventHandler::new(move |_evt: Event<MouseData>| {
        for id in &cancel_ids {
            super::timer::cancel_timer(&timer_ctx, id);
        }
    }))
}

/// Parse a hex color string (#rgb or #rrggbb) into a Color.
fn parse_hex_color(s: &str) -> Option<crate::geometry::element::Color> {
    let s = s.trim_start_matches('#');
    let (r, g, b) = if s.len() == 3 {
        let r = u8::from_str_radix(&s[0..1], 16).ok()?;
        let g = u8::from_str_radix(&s[1..2], 16).ok()?;
        let b = u8::from_str_radix(&s[2..3], 16).ok()?;
        (r * 17, g * 17, b * 17)
    } else if s.len() == 6 {
        let r = u8::from_str_radix(&s[0..2], 16).ok()?;
        let g = u8::from_str_radix(&s[2..4], 16).ok()?;
        let b = u8::from_str_radix(&s[4..6], 16).ok()?;
        (r, g, b)
    } else {
        return None;
    };
    Some(crate::geometry::element::Color::rgb(r as f64 / 255.0, g as f64 / 255.0, b as f64 / 255.0))
}

/// Parse a tool kind name from YAML (snake_case) to ToolKind.
fn parse_tool_kind(name: &str) -> Option<crate::tools::tool::ToolKind> {
    use crate::tools::tool::ToolKind;
    match name {
        "selection" => Some(ToolKind::Selection),
        "partial_selection" => Some(ToolKind::PartialSelection),
        "interior_selection" => Some(ToolKind::InteriorSelection),
        "pen" => Some(ToolKind::Pen),
        "add_anchor" => Some(ToolKind::AddAnchorPoint),
        "delete_anchor" => Some(ToolKind::DeleteAnchorPoint),
        "anchor_point" => Some(ToolKind::AnchorPoint),
        "pencil" => Some(ToolKind::Pencil),
        "path_eraser" => Some(ToolKind::PathEraser),
        "smooth" => Some(ToolKind::Smooth),
        "type" => Some(ToolKind::Type),
        "type_on_path" => Some(ToolKind::TypeOnPath),
        "line" => Some(ToolKind::Line),
        "rect" => Some(ToolKind::Rect),
        "rounded_rect" => Some(ToolKind::RoundedRect),
        "polygon" => Some(ToolKind::Polygon),
        "star" => Some(ToolKind::Star),
        "lasso" => Some(ToolKind::Lasso),
        _ => None,
    }
}

/// Build a CSS style string from the element's style properties.
fn build_style(el: &serde_json::Value, ctx: &serde_json::Value) -> String {
    let style = match el.get("style") {
        Some(s) if s.is_object() => s,
        _ => return String::new(),
    };
    let mut parts = Vec::new();
    let map = style.as_object().unwrap();

    for (key, val) in map {
        let resolved = if let Some(s) = val.as_str() {
            if s.contains("{{") {
                expr::eval_text(s, ctx)
            } else {
                s.to_string()
            }
        } else {
            val.to_string()
        };

        match key.as_str() {
            "background" => parts.push(format!("background:{resolved}")),
            "color" => parts.push(format!("color:{resolved}")),
            "border" => parts.push(format!("border:{resolved}")),
            "border_radius" => parts.push(format!("border-radius:{resolved}px")),
            "padding" => parts.push(format!("padding:{}",  pad_value(&resolved))),
            "margin" => parts.push(format!("margin:{}", pad_value(&resolved))),
            "gap" => parts.push(format!("gap:{resolved}px")),
            "width" => parts.push(format!("width:{}",  px_value(&resolved))),
            "height" => parts.push(format!("height:{}", px_value(&resolved))),
            "min_width" => parts.push(format!("min-width:{}", px_value(&resolved))),
            "min_height" => parts.push(format!("min-height:{}", px_value(&resolved))),
            "max_width" => parts.push(format!("max-width:{}", px_value(&resolved))),
            "max_height" => parts.push(format!("max-height:{}", px_value(&resolved))),
            "flex" => parts.push(format!("flex:{resolved}")),
            "opacity" => parts.push(format!("opacity:{resolved}")),
            "overflow" | "overflow_y" => {
                let css_key = key.replace('_', "-");
                parts.push(format!("{css_key}:{resolved}"));
            }
            "z_index" => parts.push(format!("z-index:{resolved}")),
            "font_size" => parts.push(format!("font-size:{resolved}px")),
            "flex_shrink" => parts.push(format!("flex-shrink:{resolved}")),
            "align_self" => {
                let v = match resolved.as_str() {
                    "start" => "flex-start",
                    "end" => "flex-end",
                    "center" => "center",
                    "stretch" => "stretch",
                    _ => &resolved,
                };
                parts.push(format!("align-self:{v}"));
            }
            "size" => {
                parts.push(format!("width:{resolved}px;height:{resolved}px"));
            }
            "alignment" => {
                let v = match resolved.as_str() {
                    "start" => "flex-start",
                    "end" => "flex-end",
                    "center" => "center",
                    "stretch" => "stretch",
                    _ => &resolved,
                };
                parts.push(format!("align-items:{v}"));
            }
            "justify" => {
                let v = match resolved.as_str() {
                    "start" => "flex-start",
                    "end" => "flex-end",
                    "center" => "center",
                    "between" => "space-between",
                    _ => &resolved,
                };
                parts.push(format!("justify-content:{v}"));
            }
            "position" => {
                // position: {x, y} → absolute positioning within parent
                if let Some(obj) = val.as_object() {
                    let x = obj.get("x").and_then(|v| v.as_f64()).unwrap_or(0.0);
                    let y = obj.get("y").and_then(|v| v.as_f64()).unwrap_or(0.0);
                    parts.push(format!("position:absolute;left:{x}px;top:{y}px"));
                } else {
                    // position: "relative" etc.
                    parts.push(format!("position:{resolved}"));
                }
            }
            _ => {}
        }
    }
    parts.join(";")
}

fn px_value(v: &str) -> String {
    if v.parse::<f64>().is_ok() {
        format!("{v}px")
    } else {
        v.to_string()
    }
}

fn pad_value(v: &str) -> String {
    let parts: Vec<&str> = v.split_whitespace().collect();
    parts.iter()
        .map(|p| if p.parse::<f64>().is_ok() { format!("{p}px") } else { p.to_string() })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Evaluate a bind expression and return initial visibility.
fn is_visible(el: &serde_json::Value, ctx: &serde_json::Value) -> bool {
    if let Some(bind) = el.get("bind").and_then(|b| b.as_object()) {
        if let Some(vis_expr) = bind.get("visible").and_then(|v| v.as_str()) {
            let result = expr::eval(vis_expr, ctx);
            return result.to_bool();
        }
    }
    true
}

/// Get the element ID attribute.
fn get_id(el: &serde_json::Value) -> String {
    el.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string()
}

/// Extract the dialog state field name from a bind expression like "dialog.field".
fn dialog_field(bind_expr: &str) -> String {
    bind_expr.strip_prefix("dialog.").unwrap_or("").to_string()
}

/// Classify a bind expression as dialog, panel, or state field.
enum BindTarget {
    Dialog(String),
    Panel(String),
    None,
}

fn classify_bind(bind_expr: &str) -> BindTarget {
    if let Some(field) = bind_expr.strip_prefix("dialog.") {
        BindTarget::Dialog(field.to_string())
    } else if let Some(field) = bind_expr.strip_prefix("panel.") {
        BindTarget::Panel(field.to_string())
    } else {
        BindTarget::None
    }
}

// ── Element renderers ────────────────────────────────────────

fn render_container(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let layout = el.get("layout").and_then(|l| l.as_str()).unwrap_or("column");
    let etype = el.get("type").and_then(|t| t.as_str()).unwrap_or("container");
    let dir = if layout == "row" || etype == "row" { "row" } else { "column" };
    let base_style = build_style(el, ctx);
    // Bootstrap grid: col: N → class="col-N", type: row → class="row"
    let col_class = el.get("col").and_then(|c| c.as_u64())
        .map(|c| format!("col-{c}"))
        .unwrap_or_default();
    let row_class = if etype == "row" { "row" } else { "" };
    // If any child uses position: {x, y}, this container needs position:relative
    let has_abs_children = el.get("children")
        .and_then(|c| c.as_array())
        .map_or(false, |children| {
            children.iter().any(|c| {
                c.get("style")
                    .and_then(|s| s.get("position"))
                    .map_or(false, |p| p.is_object())
            })
        });
    let pos_style = if has_abs_children { "position:relative;" } else { "" };
    // Apply default text color if not explicitly set in the element's style
    let has_color = el.get("style")
        .and_then(|s| s.as_object())
        .map_or(false, |m| m.contains_key("color"));
    let color_default = if has_color { "" } else { "color:var(--jas-text,#ccc);" };
    let visible = is_visible(el, ctx);
    let flex_dir = if !col_class.is_empty() {
        // col elements don't override display — Bootstrap handles it
        String::new()
    } else {
        format!("display:flex;flex-direction:{dir};")
    };
    let style = if visible {
        format!("{flex_dir}{pos_style}{color_default}{base_style}")
    } else {
        format!("display:none;{pos_style}{color_default}{base_style}")
    };
    let css_class = format!("{row_class} {col_class}").trim().to_string();
    let children = render_children(el, ctx, rctx);

    rsx! {
        div {
            id: "{id}",
            class: "{css_class}",
            style: "{style}",
            for child in children {
                {child}
            }
        }
    }
}

fn render_grid(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let cols = el.get("cols").and_then(|c| c.as_u64()).unwrap_or(2);
    let gap = el.get("gap").and_then(|g| g.as_u64()).unwrap_or(0);
    let base_style = build_style(el, ctx);
    let style = format!(
        "display:grid;grid-template-columns:repeat({cols},1fr);gap:{gap}px;{base_style}"
    );
    let children = render_children(el, ctx, rctx);

    rsx! {
        div {
            id: "{id}",
            style: "{style}",
            for child in children {
                {child}
            }
        }
    }
}

fn render_text(el: &serde_json::Value, ctx: &serde_json::Value) -> Element {
    let id = get_id(el);
    let content = el.get("content").and_then(|c| c.as_str()).unwrap_or("");
    let text = if content.contains("{{") {
        expr::eval_text(content, ctx)
    } else {
        content.to_string()
    };
    let style = build_style(el, ctx);

    rsx! {
        span {
            id: "{id}",
            style: "{style}",
            "{text}"
        }
    }
}

fn render_button(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let label = el.get("label").and_then(|l| l.as_str()).unwrap_or("");
    let style = build_style(el, ctx);

    // Try behavior array first, then shorthand action property
    let on_click = build_click_handler(el, ctx, rctx).or_else(|| {
        let action = el.get("action").and_then(|a| a.as_str())?.to_string();
        let app = rctx.app.clone();
        let mut revision = rctx.revision;
        let mut dialog_signal = rctx.dialog_ctx.0;
        let params = el.get("params").and_then(|p| p.as_object()).cloned().unwrap_or_default();
        Some(EventHandler::new(move |_evt: Event<MouseData>| {
            let app = app.clone();
            let action = action.clone();
            let params = params.clone();
            spawn(async move {
                if action == "dismiss_dialog" {
                    dialog_signal.set(None);
                } else {
                    // Snapshot dialog state before dispatching (for confirm actions)
                    let dialog_snapshot = dialog_signal().map(|ds| {
                        let mut snap = serde_json::Map::new();
                        // Include computed values via eval_context
                        for (k, v) in ds.eval_context() {
                            snap.insert(k, v);
                        }
                        // Include dialog params (mode, library, index, etc.)
                        for (k, v) in &ds.params {
                            snap.insert(format!("_param_{k}"), v.clone());
                        }
                        snap
                    });
                    let mut deferred;
                    {
                        let mut st = app.borrow_mut();
                        // For confirm actions, apply dialog state to app state
                        if let Some(ref snap) = dialog_snapshot {
                            apply_dialog_confirm(&action, snap, &mut st);
                        }
                        deferred = dispatch_action(&action, &params, &mut st);
                    }
                    for eff in &deferred {
                        if eff.get("close_dialog").is_some() {
                            dialog_signal.set(None);
                        }
                    }
                }
                revision += 1;
            });
        }))
    });

    if let Some(handler) = on_click {
        rsx! { button { id: "{id}", style: "{style}", onclick: handler, "{label}" } }
    } else {
        rsx! { button { id: "{id}", style: "{style}", "{label}" } }
    }
}

fn render_icon_button(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let summary = el.get("summary").and_then(|s| s.as_str()).unwrap_or("");
    let style = build_style(el, ctx);

    // Evaluate bind.checked for active/highlighted state
    let checked = if let Some(expr_str) = el.get("bind").and_then(|b| b.get("checked")).and_then(|v| v.as_str()) {
        expr::eval(expr_str, ctx).to_bool()
    } else {
        false
    };

    // Get checked_bg from style spec, resolve template expressions
    let checked_bg = if let Some(raw) = el.get("style").and_then(|s| s.get("checked_bg")).and_then(|v| v.as_str()) {
        let resolved = if raw.contains("{{") { expr::eval_text(raw, ctx) } else { raw.to_string() };
        if resolved.is_empty() || resolved.contains("{{") {
            "#505050".to_string()
        } else {
            resolved
        }
    } else {
        "#505050".to_string()
    };
    let bg_style = if checked {
        format!("background:{checked_bg};")
    } else {
        String::new()
    };

    // Look up icon SVG from the icons map in ctx
    let icon_name = el.get("icon").and_then(|i| i.as_str()).unwrap_or("");
    // Look up icon from ctx first, then fall back to cached workspace
    let ws_for_icons = super::workspace::Workspace::load();
    let icon_svg = if !icon_name.is_empty() {
        let icon_from_ctx = ctx.get("icons").and_then(|i| i.get(icon_name));
        let icon_from_ws = ws_for_icons.as_ref().and_then(|ws| ws.icons().get(icon_name));
        if let Some(icon_def) = icon_from_ctx.or(icon_from_ws) {
            let viewbox = icon_def.get("viewbox").and_then(|v| v.as_str()).unwrap_or("0 0 16 16");
            let svg_inner = icon_def.get("svg").and_then(|v| v.as_str()).unwrap_or("");
            format!(r#"<svg viewBox="{viewbox}" width="100%" height="100%" xmlns="http://www.w3.org/2000/svg">{svg_inner}</svg>"#)
        } else {
            String::new()
        }
    } else {
        String::new()
    };

    let on_click = build_click_handler(el, ctx, rctx);
    let on_mousedown = build_mousedown_handler(el, ctx, rctx);
    let on_mouseup = build_mouseup_handler(el, ctx, rctx);

    rsx! {
        div {
            id: "{id}",
            style: "cursor:pointer;{bg_style}{style}",
            title: "{summary}",
            onclick: move |evt| { if let Some(ref h) = on_click { h.call(evt); } },
            onmousedown: move |evt| { if let Some(ref h) = on_mousedown { h.call(evt); } },
            onmouseup: move |evt| { if let Some(ref h) = on_mouseup { h.call(evt); } },
            if !icon_svg.is_empty() {
                div {
                    style: "width:100%;height:100%;",
                    dangerous_inner_html: "{icon_svg}",
                }
            } else {
                span { style: "font-size:10px;", "{summary}" }
            }
        }
    }
}

fn render_slider(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let min = el.get("min").and_then(|m| m.as_i64()).unwrap_or(0);
    let max = el.get("max").and_then(|m| m.as_i64()).unwrap_or(100);
    let step = el.get("step").and_then(|s| s.as_i64()).unwrap_or(1);
    let style = build_style(el, ctx);

    let bind_expr = el.get("bind").and_then(|b| b.get("value")).and_then(|v| v.as_str()).unwrap_or("");
    let panel_field = bind_expr.strip_prefix("panel.").or_else(|| {
        bind_expr.strip_prefix("{{panel.").and_then(|s| s.strip_suffix("}}"))
    }).unwrap_or("").to_string();
    let dlg_field = dialog_field(bind_expr);

    // Get initial value from bind
    let value = if !bind_expr.is_empty() {
        let result = expr::eval(bind_expr, ctx);
        match result {
            Value::Number(n) => n as i64,
            _ => min,
        }
    } else {
        min
    };

    let disabled = if let Some(dis_expr) = el.get("bind").and_then(|b| b.get("disabled")).and_then(|v| v.as_str()) {
        expr::eval(dis_expr, ctx).to_bool()
    } else {
        false
    };

    let app = rctx.app.clone();
    let mut revision = rctx.revision;
    let mut dialog_signal = rctx.dialog_ctx.0;
    let panel = ctx.get("panel").cloned().unwrap_or(serde_json::Value::Null);

    rsx! {
        input {
            id: "{id}",
            r#type: "range",
            min: "{min}",
            max: "{max}",
            step: "{step}",
            initial_value: "{value}",
            disabled: disabled,
            style: "flex:1;{style}",
            oninput: move |evt: Event<FormData>| {
                let new_val: f64 = evt.value().parse().unwrap_or(0.0);
                // Dialog binding
                if !dlg_field.is_empty() {
                    if let Some(mut ds) = dialog_signal() {
                        ds.set_value(&dlg_field, serde_json::json!(new_val));
                        dialog_signal.set(Some(ds));
                    }
                    revision += 1;
                    return;
                }
                // Panel binding
                if panel_field.is_empty() { return; }
                let color = compute_color_from_panel(&panel_field, new_val, &panel);
                if let Some(color) = color {
                    let app = app.clone();
                    spawn(async move {
                        app.borrow_mut().set_active_color(color);
                        revision += 1;
                    });
                }
            },
        }
    }
}

/// Compute a color from panel state with one field changed.
fn compute_color_from_panel(field: &str, new_val: f64, panel: &serde_json::Value) -> Option<crate::geometry::element::Color> {
    use crate::interpreter::color_util::hsb_to_rgb;
    use crate::geometry::element::Color;

    let pf = |name: &str| -> f64 {
        if name == field { return new_val; }
        panel.get(name).and_then(|v| v.as_f64()).unwrap_or(0.0)
    };

    let mode = panel.get("mode").and_then(|v| v.as_str()).unwrap_or("hsb");

    let color = match mode {
        "hsb" => {
            let (r, g, b) = hsb_to_rgb(pf("h"), pf("s"), pf("b"));
            Color::rgb(r as f64 / 255.0, g as f64 / 255.0, b as f64 / 255.0)
        }
        "rgb" | "web_safe_rgb" => {
            Color::rgb(pf("r") / 255.0, pf("g") / 255.0, pf("bl") / 255.0)
        }
        "grayscale" => {
            let v = 1.0 - pf("k") / 100.0;
            Color::rgb(v, v, v)
        }
        "cmyk" => {
            let c = pf("c") / 100.0;
            let m = pf("m") / 100.0;
            let y = pf("y") / 100.0;
            let k = pf("k") / 100.0;
            let r = (1.0 - c) * (1.0 - k);
            let g = (1.0 - m) * (1.0 - k);
            let b = (1.0 - y) * (1.0 - k);
            Color::rgb(r, g, b)
        }
        _ => return None,
    };
    Some(color)
}

fn render_number_input(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let min = el.get("min").and_then(|m| m.as_i64()).unwrap_or(0);
    let max = el.get("max").and_then(|m| m.as_i64()).unwrap_or(100);
    let style = build_style(el, ctx);

    let bind_expr = el.get("bind").and_then(|b| b.get("value")).and_then(|v| v.as_str()).unwrap_or("");
    let value = if !bind_expr.is_empty() {
        let result = expr::eval(bind_expr, ctx);
        match result {
            Value::Number(n) => n as i64,
            _ => min,
        }
    } else {
        min
    };

    let bind_target = classify_bind(bind_expr);
    let mut dialog_signal = rctx.dialog_ctx.0;
    let app = rctx.app.clone();
    let mut revision = rctx.revision;

    // Panel bindings: commit on Enter/blur only, don't fight with re-renders.
    // Dialog bindings: controlled value with live updates.
    let panel_handler = if let BindTarget::Panel(ref field) = bind_target {
        let f = field.clone();
        let app = app.clone();
        let mut revision = revision;
        Some(EventHandler::new(move |evt: Event<FormData>| {
            let new_val: f64 = evt.value().parse().unwrap_or(0.0);
            let f = f.clone();
            let app = app.clone();
            spawn(async move {
                let mut st = app.borrow_mut();
                set_stroke_field(&mut st.stroke_panel, &f, &serde_json::json!(new_val));
                if f == "weight" {
                    if let Some(ref mut stroke) = st.app_default_stroke {
                        stroke.width = new_val;
                    }
                    let idx = st.active_tab;
                    if let Some(tab) = st.tabs.get_mut(idx) {
                        if let Some(ref mut stroke) = tab.model.default_stroke {
                            stroke.width = new_val;
                        }
                    }
                }
                st.apply_stroke_panel_to_selection();
            });
            revision += 1;
        }))
    } else { None };

    if panel_handler.is_some() {
        rsx! {
            input {
                id: "{id}",
                r#type: "number",
                min: "{min}",
                max: "{max}",
                initial_value: "{value}",
                style: "width:45px;color:var(--jas-text,#ccc);background:var(--jas-pane-bg-dark,#333);border:1px solid var(--jas-border,#555);{style}",
                onchange: move |evt: Event<FormData>| {
                    if let Some(ref h) = panel_handler { h.call(evt); }
                },
            }
        }
    } else {
        rsx! {
            input {
                id: "{id}",
                r#type: "number",
                min: "{min}",
                max: "{max}",
                value: "{value}",
                style: "width:45px;color:var(--jas-text,#ccc);background:var(--jas-pane-bg-dark,#333);border:1px solid var(--jas-border,#555);{style}",
                oninput: move |evt: Event<FormData>| {
                    let new_val: f64 = evt.value().parse().unwrap_or(0.0);
                    if let BindTarget::Dialog(ref field) = bind_target {
                        if let Some(mut ds) = dialog_signal() {
                            ds.set_value(field, serde_json::json!(new_val));
                            dialog_signal.set(Some(ds));
                        }
                    }
                    revision += 1;
                },
            }
        }
    }
}

fn render_text_input(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let placeholder = el.get("placeholder").and_then(|p| p.as_str()).unwrap_or("");
    let style = build_style(el, ctx);

    let bind_expr = el.get("bind").and_then(|b| b.get("value")).and_then(|v| v.as_str()).unwrap_or("");
    let value = if !bind_expr.is_empty() {
        let result = expr::eval(bind_expr, ctx);
        match result {
            Value::Str(s) => s,
            Value::Color(c) => c,
            Value::Number(n) => format!("{n}"),
            _ => String::new(),
        }
    } else {
        String::new()
    };

    let field = dialog_field(bind_expr);
    let mut dialog_signal = rctx.dialog_ctx.0;
    let mut revision = rctx.revision;
    let app = rctx.app.clone();
    // Special case: layers panel search binding
    let is_search = bind_expr == "panel.search_query";
    // Read live value from AppState if search
    let value = if is_search {
        app.borrow().layers_search_query.clone()
    } else {
        value
    };

    rsx! {
        input {
            id: "{id}",
            r#type: "text",
            placeholder: "{placeholder}",
            initial_value: "{value}",
            style: "color:var(--jas-text,#ccc);background:var(--jas-pane-bg-dark,#333);border:1px solid var(--jas-border,#555);{style}",
            oninput: move |evt: Event<FormData>| {
                let new_val = evt.value();
                if is_search {
                    let a = app.clone();
                    let v = new_val.clone();
                    spawn(async move {
                        a.borrow_mut().layers_search_query = v;
                        revision += 1;
                    });
                    return;
                }
                if field.is_empty() { return; }
                if let Some(mut ds) = dialog_signal() {
                    ds.set_value(&field, serde_json::json!(new_val));
                    dialog_signal.set(Some(ds));
                }
                revision += 1;
            },
        }
    }
}

fn render_select(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let style = build_style(el, ctx);
    let options = el.get("options").and_then(|o| o.as_array()).cloned().unwrap_or_default();

    let bind_expr = el.get("bind").and_then(|b| b.get("value")).and_then(|v| v.as_str()).unwrap_or("");
    let current_value = if !bind_expr.is_empty() {
        let result = expr::eval(bind_expr, ctx);
        match result {
            Value::Str(s) => s,
            _ => String::new(),
        }
    } else {
        String::new()
    };

    let disabled = if let Some(dis_expr) = el.get("bind").and_then(|b| b.get("disabled")).and_then(|v| v.as_str()) {
        expr::eval(dis_expr, ctx).to_bool()
    } else {
        false
    };

    let bind_target = classify_bind(bind_expr);
    let mut dialog_signal = rctx.dialog_ctx.0;
    let app = rctx.app.clone();
    let mut revision = rctx.revision;
    let cv = current_value.clone();

    rsx! {
        select {
            id: "{id}",
            value: "{current_value}",
            disabled: disabled,
            style: "color:var(--jas-text,#ccc);background:var(--jas-pane-bg-dark,#333);border:1px solid var(--jas-border,#555);font-size:11px;padding:2px 4px;{style}",
            onchange: move |evt: Event<FormData>| {
                let new_val = evt.value();
                match &bind_target {
                    BindTarget::Dialog(field) => {
                        if let Some(mut ds) = dialog_signal() {
                            ds.set_value(field, serde_json::json!(new_val));
                            dialog_signal.set(Some(ds));
                        }
                    }
                    BindTarget::Panel(field) => {
                        let f = field.clone();
                        let v = new_val.clone();
                        let app = app.clone();
                        spawn(async move {
                            let mut st = app.borrow_mut();
                            set_stroke_field(&mut st.stroke_panel, &f, &serde_json::json!(v));
                            st.apply_stroke_panel_to_selection();
                        });
                    }
                    BindTarget::None => { return; }
                }
                revision += 1;
            },
            for opt in options.iter() {
                {render_select_option(opt, &cv)}
            }
        }
    }
}

fn render_select_option(opt: &serde_json::Value, current_value: &str) -> Element {
    if let Some(obj) = opt.as_object() {
        let value = obj.get("value")
            .and_then(|v| v.as_str())
            .or_else(|| obj.get("id").and_then(|v| v.as_str()))
            .unwrap_or("");
        let label = obj.get("label").and_then(|v| v.as_str()).unwrap_or(value);
        let selected = value == current_value;
        rsx! {
            option {
                value: "{value}",
                selected: selected,
                "{label}"
            }
        }
    } else {
        let value = opt.as_str().unwrap_or("");
        let selected = value == current_value;
        rsx! {
            option {
                value: "{value}",
                selected: selected,
                "{value}"
            }
        }
    }
}

fn render_combo_box(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let style = build_style(el, ctx);
    let options = el.get("options").and_then(|o| o.as_array()).cloned().unwrap_or_default();
    let list_id = format!("{id}_opts");

    let bind_expr = el.get("bind").and_then(|b| b.get("value")).and_then(|v| v.as_str()).unwrap_or("");
    let current_value = if !bind_expr.is_empty() {
        let result = expr::eval(bind_expr, ctx);
        match result {
            Value::Str(s) => s,
            Value::Number(n) => n.to_string(),
            _ => String::new(),
        }
    } else {
        String::new()
    };

    let disabled = if let Some(dis_expr) = el.get("bind").and_then(|b| b.get("disabled")).and_then(|v| v.as_str()) {
        expr::eval(dis_expr, ctx).to_bool()
    } else {
        false
    };

    let bind_target = classify_bind(bind_expr);
    let mut dialog_signal = rctx.dialog_ctx.0;
    let app = rctx.app.clone();
    let mut revision = rctx.revision;

    rsx! {
        span {
            style: "display:inline-flex;{style}",
            input {
                id: "{id}",
                r#type: "text",
                list: "{list_id}",
                value: "{current_value}",
                disabled: disabled,
                style: "color:var(--jas-text,#ccc);background:var(--jas-pane-bg-dark,#333);border:1px solid var(--jas-border,#555);font-size:11px;padding:2px 4px;width:100%",
                onchange: move |evt: Event<FormData>| {
                    let new_val = evt.value();
                    match &bind_target {
                        BindTarget::Dialog(field) => {
                            if let Some(mut ds) = dialog_signal() {
                                ds.set_value(field, serde_json::json!(new_val));
                                dialog_signal.set(Some(ds));
                            }
                        }
                        BindTarget::Panel(field) => {
                            let f = field.clone();
                            let v = new_val.clone();
                            let app = app.clone();
                            spawn(async move {
                                let mut st = app.borrow_mut();
                                // Parse as number if possible (for scale percentages)
                                let json_val = if let Ok(n) = v.parse::<f64>() {
                                    serde_json::json!(n)
                                } else {
                                    serde_json::json!(v)
                                };
                                set_stroke_field(&mut st.stroke_panel, &f, &json_val);
                            });
                        }
                        BindTarget::None => { return; }
                    }
                    revision += 1;
                },
            }
            datalist {
                id: "{list_id}",
                for opt in options.iter() {
                    {render_combo_box_option(opt)}
                }
            }
        }
    }
}

fn render_combo_box_option(opt: &serde_json::Value) -> Element {
    if let Some(obj) = opt.as_object() {
        let value = obj.get("value")
            .map(|v| if let Some(n) = v.as_f64() { n.to_string() } else { v.as_str().unwrap_or("").to_string() })
            .unwrap_or_default();
        let label = obj.get("label").and_then(|v| v.as_str()).unwrap_or(&value);
        rsx! {
            option {
                value: "{value}",
                "{label}"
            }
        }
    } else {
        let value = opt.as_str().unwrap_or("");
        rsx! {
            option {
                value: "{value}",
            }
        }
    }
}

fn render_toggle(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let label_text = el.get("label").and_then(|l| l.as_str()).unwrap_or("");
    let style = build_style(el, ctx);

    let bind_expr = el.get("bind").and_then(|b| b.get("checked")).and_then(|v| v.as_str()).unwrap_or("");
    let checked = if !bind_expr.is_empty() {
        expr::eval(bind_expr, ctx).to_bool()
    } else {
        false
    };

    let disabled = if let Some(dis_expr) = el.get("bind").and_then(|b| b.get("disabled")).and_then(|v| v.as_str()) {
        expr::eval(dis_expr, ctx).to_bool()
    } else {
        false
    };

    let bind_target = classify_bind(bind_expr);
    let mut dialog_signal = rctx.dialog_ctx.0;
    let app = rctx.app.clone();
    let mut revision = rctx.revision;
    let on_click = build_click_handler(el, ctx, rctx);

    let check_icon = if checked { "\u{2611}" } else { "\u{2610}" };
    rsx! {
        div {
            id: "{id}",
            style: "display:flex;align-items:center;gap:4px;font-size:11px;color:var(--jas-text,#ccc);cursor:pointer;user-select:none;{style}",
            onclick: move |evt| {
                if disabled { return; }
                if let Some(ref handler) = on_click {
                    handler.call(evt);
                } else {
                    let new_val = !checked;
                    match &bind_target {
                        BindTarget::Dialog(field) => {
                            if let Some(mut ds) = dialog_signal() {
                                ds.set_value(field, serde_json::json!(new_val));
                                dialog_signal.set(Some(ds));
                            }
                        }
                        BindTarget::Panel(field) => {
                            let f = field.clone();
                            let app = app.clone();
                            spawn(async move {
                                let mut st = app.borrow_mut();
                                set_stroke_field(&mut st.stroke_panel, &f, &serde_json::json!(new_val));
                            });
                        }
                        BindTarget::None => {}
                    }
                    revision += 1;
                }
            },
            span { style: "font-size:14px;", "{check_icon}" }
            "{label_text}"
        }
    }
}

fn render_color_swatch(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let size = el.get("style")
        .and_then(|s| s.get("size"))
        .and_then(|s| s.as_u64())
        .unwrap_or(16);

    let color = if let Some(bind_color) = el.get("bind").and_then(|b| b.get("color")).and_then(|v| v.as_str()) {
        // Handle "#expr" pattern: "#dialog.hex" means "#" + eval("dialog.hex")
        if bind_color.starts_with('#') && bind_color.contains('.') {
            let inner = &bind_color[1..];
            let result = expr::eval(inner, ctx);
            match result {
                Value::Str(s) => format!("#{s}"),
                Value::Color(c) => c,
                _ => String::new(),
            }
        } else {
            let result = expr::eval(bind_color, ctx);
            match result {
                Value::Color(c) => c,
                Value::Str(s) if s.starts_with('#') => s,
                _ => String::new(),
            }
        }
    } else {
        String::new()
    };

    let bg = if color.is_empty() { "transparent".to_string() } else { color.clone() };
    let border = if color.is_empty() { "1px dashed var(--jas-border,#555)" } else { "1px solid var(--jas-border,#666)" };
    let hollow = el.get("hollow").and_then(|h| h.as_bool()).unwrap_or(false);

    // Build positioning from style (handles position: {x, y} → absolute)
    let extra_style = build_style(el, ctx);

    // Evaluate bind.z_index for dynamic z-ordering (fill/stroke swap)
    let z_style = el.get("bind")
        .and_then(|b| b.get("z_index"))
        .and_then(|v| v.as_str())
        .map(|expr| {
            let result = expr::eval(expr, ctx);
            match result {
                Value::Number(n) => format!("z-index:{};", n as i64),
                _ => String::new(),
            }
        })
        .unwrap_or_default();

    let style = if hollow {
        format!("width:{size}px;height:{size}px;background:transparent;border:6px solid {bg};cursor:pointer;box-sizing:border-box;{z_style}{extra_style}")
    } else {
        format!("width:{size}px;height:{size}px;background:{bg};border:{border};cursor:pointer;box-sizing:border-box;{z_style}{extra_style}")
    };

    let on_click = build_click_handler(el, ctx, rctx);
    let on_dblclick = build_dblclick_handler(el, ctx, rctx);

    rsx! {
        div {
            id: "{id}",
            style: "{style}",
            onclick: move |evt| { if let Some(ref h) = on_click { h.call(evt); } },
            ondoubleclick: move |evt| { if let Some(ref h) = on_dblclick { h.call(evt); } },
        }
    }
}

fn render_color_bar(_el: &serde_json::Value, _ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    use crate::geometry::element::Color;

    let data_uri = crate::workspace::color_panel_view::build_color_bar_data_uri();
    let app = rctx.app.clone();
    let mut revision = rctx.revision;

    let on_click = move |evt: Event<MouseData>| {
        let coords = evt.data().element_coordinates();
        let x = coords.x;
        let y = coords.y;
        // Read the element's CSS width from the DOM
        let width: f64 = {
            #[cfg(target_arch = "wasm32")]
            {
                web_sys::window()
                    .and_then(|w| w.document())
                    .and_then(|d| d.get_element_by_id("jas-yaml-color-bar"))
                    .map(|el| el.client_width() as f64)
                    .unwrap_or(200.0)
            }
            #[cfg(not(target_arch = "wasm32"))]
            { 200.0 }
        };
        let height = 64.0_f64;

        let hue = 360.0 * x / width;
        let mid_y = height / 2.0;
        let (sat, br) = if y <= mid_y {
            let t = y / mid_y;
            (t * 100.0, 100.0 - t * 20.0)
        } else {
            let t = (y - mid_y) / (height - mid_y);
            (100.0, 80.0 * (1.0 - t))
        };

        let (r, g, b) = crate::interpreter::color_util::hsb_to_rgb(hue, sat, br);
        let color = Color::rgb(r as f64 / 255.0, g as f64 / 255.0, b as f64 / 255.0);
        let app = app.clone();
        spawn(async move {
            app.borrow_mut().set_active_color(color);
            revision += 1;
        });
    };

    rsx! {
        img {
            id: "jas-yaml-color-bar",
            src: "{data_uri}",
            style: "width:100%;height:64px;cursor:crosshair;border:1px solid var(--jas-border,#555);border-radius:1px;",
            onclick: on_click,
        }
    }
}

/// Render a 2D color gradient for the color picker dialog.
/// Shows saturation (X) x brightness (Y) gradient colored by the current hue.
fn render_color_gradient(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let style = build_style(el, ctx);

    // Get hue from bind expression
    let hue = el.get("bind")
        .and_then(|b| b.get("hue"))
        .and_then(|v| v.as_str())
        .map(|e| match expr::eval(e, ctx) { Value::Number(n) => n, _ => 0.0 })
        .unwrap_or(0.0);

    // Build CSS for the SB gradient at this hue
    let (r, g, b) = crate::interpreter::color_util::hsb_to_rgb(hue, 100.0, 100.0);
    let hue_css = format!("rgb({r},{g},{b})");

    // The gradient: white->hue on X, transparent->black on Y
    let bg = format!(
        "linear-gradient(to bottom, transparent, #000), linear-gradient(to right, #fff, {hue_css})"
    );

    let app = rctx.app.clone();
    let mut dialog_signal = rctx.dialog_ctx.0;
    let mut revision = rctx.revision;

    let on_click = move |evt: Event<MouseData>| {
        let coords = evt.data().element_coordinates();
        let x = coords.x;
        let y = coords.y;
        // Assume 180x180 element size
        let width = 180.0_f64;
        let height = 180.0_f64;
        let sat = (x / width * 100.0).clamp(0.0, 100.0);
        let bri = ((1.0 - y / height) * 100.0).clamp(0.0, 100.0);

        if let Some(mut ds) = dialog_signal() {
            // Use set_value — triggers setter which updates color via <-
            ds.set_value("s", serde_json::json!(sat.round() as i64));
            ds.set_value("b", serde_json::json!(bri.round() as i64));
            dialog_signal.set(Some(ds));
            revision += 1;
        }
    };

    // Cursor position from current S and B
    let sat = el.get("bind")
        .and_then(|b| b.get("saturation"))
        .and_then(|v| v.as_str())
        .map(|e| match expr::eval(e, ctx) { Value::Number(n) => n, _ => 0.0 })
        .unwrap_or(0.0);
    let bri = el.get("bind")
        .and_then(|b| b.get("brightness"))
        .and_then(|v| v.as_str())
        .map(|e| match expr::eval(e, ctx) { Value::Number(n) => n, _ => 100.0 })
        .unwrap_or(100.0);
    let cursor_x = sat / 100.0 * 180.0;
    let cursor_y = (1.0 - bri / 100.0) * 180.0;

    rsx! {
        div {
            id: "{id}",
            style: "width:180px;height:180px;background:{bg};border:1px solid var(--jas-border,#555);cursor:crosshair;position:relative;{style}",
            onclick: on_click,
            // Position indicator circle
            div {
                style: "position:absolute;left:{cursor_x - 5.0}px;top:{cursor_y - 5.0}px;width:10px;height:10px;border:2px solid #fff;border-radius:50%;pointer-events:none;box-sizing:border-box;box-shadow:0 0 2px rgba(0,0,0,0.5);",
            }
        }
    }
}

/// Render a vertical hue bar for the color picker dialog.
/// Shows a rainbow gradient; click to select hue (0-360).
fn render_color_hue_bar(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let style = build_style(el, ctx);

    // Rainbow hue gradient
    let bg = "linear-gradient(to bottom, #f00, #ff0, #0f0, #0ff, #00f, #f0f, #f00)";

    // Current hue for position indicator
    let hue = el.get("bind")
        .and_then(|b| b.get("value"))
        .and_then(|v| v.as_str())
        .map(|e| match expr::eval(e, ctx) { Value::Number(n) => n, _ => 0.0 })
        .unwrap_or(0.0);

    let mut dialog_signal = rctx.dialog_ctx.0;
    let mut revision = rctx.revision;

    let on_click = move |evt: Event<MouseData>| {
        let coords = evt.data().element_coordinates();
        let y = coords.y;
        // Bar height from style or default 180
        let height = 180.0_f64;
        let new_hue = (y / height * 360.0).clamp(0.0, 359.0);

        if let Some(mut ds) = dialog_signal() {
            // Use set_value — triggers setter which updates color via <-
            ds.set_value("h", serde_json::json!(new_hue.round() as i64));
            dialog_signal.set(Some(ds));
            revision += 1;
        }
    };

    // Position indicator
    let indicator_y = hue / 360.0 * 180.0;

    rsx! {
        div {
            id: "{id}",
            style: "width:32px;height:180px;background:{bg};border:1px solid var(--jas-border,#555);cursor:crosshair;position:relative;{style}",
            onclick: on_click,
            // Position indicator arrow
            div {
                style: "position:absolute;left:-2px;right:-2px;top:{indicator_y - 1.0}px;height:3px;background:#fff;border:1px solid #000;pointer-events:none;box-sizing:border-box;",
            }
        }
    }
}

fn render_separator(el: &serde_json::Value, _ctx: &serde_json::Value) -> Element {
    let orientation = el.get("orientation").and_then(|o| o.as_str()).unwrap_or("horizontal");
    let style = if orientation == "vertical" {
        "width:1px;background:var(--jas-border,#555);align-self:stretch;"
    } else {
        "height:1px;background:var(--jas-border,#555);width:100%;"
    };
    rsx! { div { style: "{style}" } }
}

fn render_spacer(_el: &serde_json::Value, _ctx: &serde_json::Value) -> Element {
    rsx! { div { style: "flex:1;" } }
}

fn render_disclosure(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let label = el.get("label").and_then(|l| l.as_str()).unwrap_or("");
    let label_text = if label.contains("{{") {
        expr::eval_text(label, ctx)
    } else {
        label.to_string()
    };
    let id = get_id(el);
    let children = render_children(el, ctx, rctx);

    rsx! {
        details {
            id: "{id}",
            open: true,
            summary {
                style: "cursor:pointer;font-weight:bold;font-size:11px;padding:2px 4px;color:var(--jas-text,#ccc);",
                "{label_text}"
            }
            for child in children {
                {child}
            }
        }
    }
}

fn render_fill_stroke_widget(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    use crate::document::controller::{
        FillSummary, StrokeSummary,
        selection_fill_summary, selection_stroke_summary,
    };
    use crate::geometry::element::Stroke;
    use crate::geometry::element::Color;

    let app = rctx.app.clone();

    let (fill_summary, stroke_summary, default_fill, default_stroke, fill_on_top) = {
        let st = app.borrow();
        let fill_on_top = st.fill_on_top;
        if let Some(tab) = st.tab() {
            let doc = tab.model.document();
            (
                selection_fill_summary(doc),
                selection_stroke_summary(doc),
                tab.model.default_fill,
                tab.model.default_stroke,
                fill_on_top,
            )
        } else {
            (
                FillSummary::NoSelection,
                StrokeSummary::NoSelection,
                None,
                Some(Stroke::new(Color::BLACK, 1.0)),
                fill_on_top,
            )
        }
    };

    let wrapper_style = build_style(el, ctx);
    rsx! {
        div {
            style: "{wrapper_style}",
            crate::workspace::fill_stroke_widget::FillStrokeWidgetView {
                fill_summary,
                stroke_summary,
                default_fill,
                default_stroke,
                fill_on_top,
            }
        }
    }
}

fn render_panel(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    if let Some(content) = el.get("content") {
        render_el(content, ctx, rctx)
    } else {
        render_placeholder(el, ctx)
    }
}

/// A flattened row from the document tree, ready for rendering.
#[derive(Clone)]
struct TreeRow {
    path: Vec<usize>,
    depth: usize,
    eye_icon_svg: String,
    lock_icon_svg: String,
    twirl_svg: String,     // empty for leaf elements
    preview_svg: String,   // fitted-viewBox SVG fragment for the thumbnail
    is_container: bool,
    display_name: String,
    is_named: bool,
    is_selected: bool,
    is_renaming: bool,
    is_layer: bool,
    is_collapsed: bool,
    is_panel_selected: bool,
    layer_color: String,
    visibility_str: String, // "preview", "outline", "invisible"
}

/// Render a tree_view widget showing the live document element tree.
///
/// Reads the active document from AppState and renders each element as
/// an interactive row with visibility, lock, twirl-down, preview, name,
/// and selection indicator. Clicking the eye cycles visibility; clicking
/// the lock toggles lock state.
fn render_tree_view(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    use crate::geometry::element::{Element as GeoElement, Visibility};
    use std::collections::HashSet;

    let id = get_id(el);
    let style = build_style(el, ctx);

    const LAYER_COLORS: [&str; 9] = [
        "#4a90d9", "#d94a4a", "#4ad94a", "#4a4ad9", "#d9d94a",
        "#d94ad9", "#4ad9d9", "#b0b0b0", "#2a7a2a",
    ];

    fn icon_svg(icon_name: &str) -> String {
        let ws = super::workspace::Workspace::load();
        if let Some(ws) = &ws {
            if let Some(icon_def) = ws.icons().get(icon_name) {
                let viewbox = icon_def.get("viewbox").and_then(|v| v.as_str()).unwrap_or("0 0 16 16");
                let svg_inner = icon_def.get("svg").and_then(|v| v.as_str()).unwrap_or("");
                return format!(
                    r#"<svg viewBox="{viewbox}" width="14" height="14" xmlns="http://www.w3.org/2000/svg">{svg_inner}</svg>"#
                );
            }
        }
        String::new()
    }

    fn type_label(elem: &GeoElement) -> &'static str {
        match elem {
            GeoElement::Line(_) => "Line",
            GeoElement::Rect(_) => "Rectangle",
            GeoElement::Circle(_) => "Circle",
            GeoElement::Ellipse(_) => "Ellipse",
            GeoElement::Polyline(_) => "Polyline",
            GeoElement::Polygon(_) => "Polygon",
            GeoElement::Path(_) => "Path",
            GeoElement::Text(_) => "Text",
            GeoElement::TextPath(_) => "Text Path",
            GeoElement::Group(_) => "Group",
            GeoElement::Layer(_) => "Layer",
        }
    }

    /// Build a fitted-viewBox SVG thumbnail for a single element.
    /// Returns an empty string for zero-extent or degenerate bounds.
    fn build_preview_svg(elem: &GeoElement) -> String {
        let (x, y, w, h) = elem.bounds();
        if !(w.is_finite() && h.is_finite()) || w <= 0.0 || h <= 0.0 {
            return String::new();
        }
        let pad = (w.max(h) * 0.02).max(0.5);
        let vb = format!("{} {} {} {}", x - pad, y - pad, w + 2.0 * pad, h + 2.0 * pad);
        let inner = crate::geometry::svg::element_svg(elem, "");
        format!(
            r#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" width="100%" height="100%" preserveAspectRatio="xMidYMid meet">{inner}</svg>"#
        )
    }

    fn elem_display_name(elem: &GeoElement) -> (String, bool) {
        if let GeoElement::Layer(le) = elem {
            if !le.name.is_empty() {
                return (le.name.clone(), true);
            }
        }
        (format!("<{}>", type_label(elem)), false)
    }

    fn flatten_rc_children(
        children: &[std::rc::Rc<GeoElement>],
        depth: usize,
        path_prefix: &[usize],
        layer_color: &str,
        selected_paths: &HashSet<Vec<usize>>,
        collapsed_paths: &HashSet<Vec<usize>>,
        panel_selection: &[Vec<usize>],
        renaming_path: &Option<Vec<usize>>,
        rows: &mut Vec<TreeRow>,
    ) {
        for (i, child_rc) in children.iter().enumerate().rev() {
            let child = child_rc.as_ref();
            let mut path = path_prefix.to_vec();
            path.push(i);

            let is_container = child.is_group_or_layer();
            let is_selected = selected_paths.contains(&path);
            let is_renaming = renaming_path.as_ref() == Some(&path);
            let is_layer = child.is_layer();
            let is_collapsed = collapsed_paths.contains(&path);
            let is_panel_selected = panel_selection.contains(&path);

            let current_layer_color = if is_layer {
                if path.len() == 1 { LAYER_COLORS[i % LAYER_COLORS.len()].to_string() } else { layer_color.to_string() }
            } else {
                layer_color.to_string()
            };

            let vis_str = match child.visibility() {
                Visibility::Preview => "preview",
                Visibility::Outline => "outline",
                Visibility::Invisible => "invisible",
            };
            let eye_icon = match child.visibility() {
                Visibility::Preview => "eye_preview",
                Visibility::Outline => "eye_outline",
                Visibility::Invisible => "eye_invisible",
            };
            let lock_icon = if child.locked() { "lock_locked" } else { "lock_unlocked" };

            let twirl_svg = if is_container {
                icon_svg(if is_collapsed { "twirl_closed" } else { "twirl_open" })
            } else {
                String::new()
            };
            let (display_name, is_named) = elem_display_name(child);

            let preview_svg = build_preview_svg(child);
            rows.push(TreeRow {
                path: path.clone(),
                depth,
                eye_icon_svg: icon_svg(eye_icon),
                lock_icon_svg: icon_svg(lock_icon),
                twirl_svg,
                preview_svg,
                is_container,
                display_name,
                is_named,
                is_selected,
                is_renaming,
                is_layer,
                is_collapsed,
                is_panel_selected,
                layer_color: current_layer_color.clone(),
                visibility_str: vis_str.to_string(),
            });

            // Only recurse if expanded
            if !is_collapsed {
                if let Some(grandchildren) = child.children() {
                    flatten_rc_children(grandchildren, depth + 1, &path, &current_layer_color, selected_paths, collapsed_paths, panel_selection, renaming_path, rows);
                }
            }
        }
    }

    fn flatten_layers(
        layers: &[GeoElement],
        selected_paths: &HashSet<Vec<usize>>,
        collapsed_paths: &HashSet<Vec<usize>>,
        panel_selection: &[Vec<usize>],
        renaming_path: &Option<Vec<usize>>,
    ) -> Vec<TreeRow> {
        let mut rows = Vec::new();
        for (i, elem) in layers.iter().enumerate().rev() {
            let path = vec![i];
            let is_container = elem.is_group_or_layer();
            let is_selected = selected_paths.contains(&path);
            let is_renaming = renaming_path.as_ref() == Some(&path);
            let is_layer = elem.is_layer();
            let is_collapsed = collapsed_paths.contains(&path);
            let is_panel_selected = panel_selection.contains(&path);
            let layer_color = LAYER_COLORS[i % LAYER_COLORS.len()].to_string();

            let vis_str = match elem.visibility() {
                Visibility::Preview => "preview",
                Visibility::Outline => "outline",
                Visibility::Invisible => "invisible",
            };
            let eye_icon = match elem.visibility() {
                Visibility::Preview => "eye_preview",
                Visibility::Outline => "eye_outline",
                Visibility::Invisible => "eye_invisible",
            };
            let lock_icon = if elem.locked() { "lock_locked" } else { "lock_unlocked" };
            let twirl_svg = if is_container {
                icon_svg(if is_collapsed { "twirl_closed" } else { "twirl_open" })
            } else {
                String::new()
            };
            let (display_name, is_named) = elem_display_name(elem);

            let preview_svg = build_preview_svg(elem);
            rows.push(TreeRow {
                path: path.clone(),
                depth: 0,
                eye_icon_svg: icon_svg(eye_icon),
                lock_icon_svg: icon_svg(lock_icon),
                twirl_svg,
                preview_svg,
                is_container,
                display_name,
                is_named,
                is_selected,
                is_renaming,
                is_layer,
                is_collapsed,
                is_panel_selected,
                layer_color: layer_color.clone(),
                visibility_str: vis_str.to_string(),
            });

            // Only recurse if expanded
            if !is_collapsed {
                if let Some(children) = elem.children() {
                    flatten_rc_children(children, 1, &path, &layer_color, selected_paths, collapsed_paths, panel_selection, renaming_path, &mut rows);
                }
            }
        }
        rows
    }

    // Read search query from AppState (populated by the search input handler)
    let search_query: String = rctx.app.borrow().layers_search_query.to_lowercase();

    // Read isolation stack — if non-empty, only show rows that are descendants
    // of the deepest isolated container.
    let isolation_root: Option<Vec<usize>> = rctx.app.borrow()
        .layers_isolation_stack.last().cloned();

    // Build breadcrumb data for the isolation header
    let breadcrumb: Vec<(Vec<usize>, String)> = {
        let st = rctx.app.borrow();
        let stack = st.layers_isolation_stack.clone();
        let doc = st.tab().map(|t| t.model.document().clone());
        let mut out = Vec::new();
        if let Some(doc) = doc {
            for p in &stack {
                if let Some(elem) = doc.get_element(p) {
                    let label = match elem {
                        crate::geometry::element::Element::Layer(le) if !le.name.is_empty() => le.name.clone(),
                        _ => format!("<{}>", match elem {
                            crate::geometry::element::Element::Group(_) => "Group",
                            crate::geometry::element::Element::Layer(_) => "Layer",
                            _ => "?",
                        }),
                    };
                    out.push((p.clone(), label));
                }
            }
        }
        out
    };

    // Auto-expand ancestors of element-selected paths so selected elements
    // are always visible in the tree (without this, selecting an element
    // on the canvas inside a collapsed group would hide it).
    let first_selected_path: Option<Vec<usize>> = {
        let mut st = rctx.app.borrow_mut();
        let selected_paths: Vec<Vec<usize>> = st.tab()
            .map(|t| {
                let doc = t.model.document();
                let mut paths: Vec<Vec<usize>> = doc.selection.iter().map(|es| es.path.clone()).collect();
                paths.sort();
                paths
            })
            .unwrap_or_default();
        for p in &selected_paths {
            for i in 1..p.len() {
                let ancestor = p[..i].to_vec();
                st.layers_collapsed.remove(&ancestor);
            }
        }
        selected_paths.into_iter().next()
    };

    // Schedule a scroll-into-view for the first selected row after render
    #[cfg(target_arch = "wasm32")]
    if let Some(ref p) = first_selected_path {
        let row_id = format!("lp_row_{}", p.iter().map(|i| i.to_string()).collect::<Vec<_>>().join("_"));
        spawn(async move {
            // Small delay to let the DOM settle
            if let Some(win) = web_sys::window() {
                if let Some(doc) = win.document() {
                    if let Some(el) = doc.get_element_by_id(&row_id) {
                        let opts = web_sys::ScrollIntoViewOptions::new();
                        opts.set_block(web_sys::ScrollLogicalPosition::Nearest);
                        el.scroll_into_view_with_scroll_into_view_options(&opts);
                    }
                }
            }
        });
    }
    let _ = &first_selected_path; // suppress unused warning on non-wasm

    // Build flat row list from the live document
    let mut rows: Vec<TreeRow> = {
        let st = rctx.app.borrow();
        if let Some(tab) = st.tab() {
            let doc = tab.model.document();
            let selected_paths = doc.selected_paths();
            let renaming_path = st.layers_renaming.clone();
            let collapsed_paths = &st.layers_collapsed;
            let panel_selection = &st.layers_panel_selection;
            flatten_layers(&doc.layers, &selected_paths, collapsed_paths, panel_selection, &renaming_path)
        } else {
            Vec::new()
        }
    };

    // Apply type filter: hide rows whose element type is in hidden_types.
    // Ancestor containers are preserved so descendants of visible types
    // remain reachable.
    let hidden_types: std::collections::HashSet<String> = rctx.app.borrow()
        .layers_hidden_types.iter().cloned().collect();
    if !hidden_types.is_empty() {
        fn type_value(tl: &str) -> &'static str {
            match tl {
                "Line" => "line", "Rectangle" => "rectangle", "Circle" => "circle",
                "Ellipse" => "ellipse", "Polyline" => "polyline", "Polygon" => "polygon",
                "Path" => "path", "Text" => "text", "Text Path" => "text_path",
                "Group" => "group", "Layer" => "layer", _ => "",
            }
        }
        // Determine which paths to keep: rows whose type is not hidden,
        // plus ancestor paths of those rows.
        let visible_paths: std::collections::HashSet<Vec<usize>> = rows.iter()
            .filter(|r| {
                // Use the display_name's content to find the type label.
                // display_name is either "<Layer>" or "Layer 1", so check both.
                let type_hint = if r.is_layer { "layer" } else {
                    // Extract from display_name if it's in angle brackets
                    let n = &r.display_name;
                    if n.starts_with('<') && n.ends_with('>') {
                        let inner = &n[1..n.len()-1];
                        type_value(inner)
                    } else {
                        // Named layer already checked
                        ""
                    }
                };
                !hidden_types.contains(type_hint)
            })
            .map(|r| r.path.clone())
            .collect();
        let mut keep = visible_paths.clone();
        for p in &visible_paths {
            for i in 1..p.len() {
                keep.insert(p[..i].to_vec());
            }
        }
        rows.retain(|r| keep.contains(&r.path));
    }

    // Apply isolation filter: keep only rows that are strict descendants of
    // the isolated root (not the root itself).
    if let Some(ref root) = isolation_root {
        rows.retain(|r| r.path.len() > root.len() && r.path.starts_with(root));
        // Decrement depth so isolated content starts at depth 0
        let d = root.len();
        for r in rows.iter_mut() {
            r.depth = r.depth.saturating_sub(d);
        }
    }

    // Apply search filter: keep rows whose name matches, plus their ancestors.
    if !search_query.is_empty() {
        let matching_paths: std::collections::HashSet<Vec<usize>> = rows.iter()
            .filter(|r| r.display_name.to_lowercase().contains(&search_query))
            .map(|r| r.path.clone())
            .collect();
        // Include all ancestor paths of matching rows
        let mut include: std::collections::HashSet<Vec<usize>> = matching_paths.clone();
        for p in &matching_paths {
            for i in 1..p.len() {
                include.insert(p[..i].to_vec());
            }
        }
        rows.retain(|r| include.contains(&r.path));
    }

    let app = rctx.app.clone();
    let mut revision = rctx.revision;
    let btn_style = "width:16px;height:16px;display:flex;align-items:center;justify-content:center;flex-shrink:0;cursor:pointer";

    // Read current context menu state from AppState
    let context_menu_state = rctx.app.borrow().layers_context_menu.clone();

    let kb_app = app.clone();
    let mut kb_rev = revision;
    let on_keydown = move |evt: Event<KeyboardData>| {
        let key = evt.data().key();
        let a = kb_app.clone();
        match key {
            dioxus::prelude::Key::Delete | dioxus::prelude::Key::Backspace => {
                spawn(async move {
                    let mut st = a.borrow_mut();
                    let params = serde_json::Map::new();
                    dispatch_action("delete_layer_selection", &params, &mut st);
                    kb_rev += 1;
                });
            }
            dioxus::prelude::Key::Character(c) if c == "a" || c == "A" => {
                if evt.data().modifiers().meta() || evt.data().modifiers().ctrl() {
                    spawn(async move {
                        let mut st = a.borrow_mut();
                        // Collect all element paths in the document
                        if let Some(tab) = st.tab() {
                            let doc = tab.model.document();
                            let mut all_paths = Vec::new();
                            fn collect(elements: &[crate::geometry::element::Element], prefix: &[usize], out: &mut Vec<Vec<usize>>) {
                                for (i, elem) in elements.iter().enumerate() {
                                    let mut p = prefix.to_vec();
                                    p.push(i);
                                    out.push(p.clone());
                                    if let Some(children) = elem.children() {
                                        fn collect_rc(children: &[std::rc::Rc<crate::geometry::element::Element>], prefix: &[usize], out: &mut Vec<Vec<usize>>) {
                                            for (i, c) in children.iter().enumerate() {
                                                let mut p = prefix.to_vec();
                                                p.push(i);
                                                out.push(p.clone());
                                                if let Some(gc) = c.children() {
                                                    collect_rc(gc, &p, out);
                                                }
                                            }
                                        }
                                        collect_rc(children, &p, out);
                                    }
                                }
                            }
                            collect(&doc.layers, &[], &mut all_paths);
                            st.layers_panel_selection = all_paths;
                        }
                        kb_rev += 1;
                    });
                }
            }
            _ => {}
        }
    };

    rsx! {
        div {
            id: "{id}",
            style: "display:flex;flex-direction:column;flex:1;min-height:0;outline:none;{style}",
            tabindex: 0,
            onkeydown: on_keydown,

            // Breadcrumb bar (isolation mode only)
            if !breadcrumb.is_empty() {
                {
                    let home_app = app.clone();
                    let mut home_rev = revision;
                    rsx! {
                        div {
                            style: "display:flex;align-items:center;gap:4px;padding:2px 6px;background:var(--jas-pane-bg-dark,#2a2a2a);border-bottom:1px solid var(--jas-border,#555);font-size:10px;color:var(--jas-text-dim,#999);flex-shrink:0;",
                            span {
                                style: "cursor:pointer;color:var(--jas-text,#ccc);",
                                onclick: move |_: Event<MouseData>| {
                                    let a = home_app.clone();
                                    spawn(async move {
                                        a.borrow_mut().layers_isolation_stack.clear();
                                        home_rev += 1;
                                    });
                                },
                                "⌂"
                            }
                            for (idx, (bp, bl)) in breadcrumb.iter().enumerate() {
                                {
                                    let bp = bp.clone();
                                    let bl = bl.clone();
                                    let exit_to = idx + 1;
                                    let b_app = app.clone();
                                    let mut b_rev = revision;
                                    rsx! {
                                        span { "> " }
                                        span {
                                            key: "{bp:?}",
                                            style: "cursor:pointer;color:var(--jas-text,#ccc);",
                                            onclick: move |_: Event<MouseData>| {
                                                let a = b_app.clone();
                                                let target = exit_to;
                                                spawn(async move {
                                                    let mut st = a.borrow_mut();
                                                    st.layers_isolation_stack.truncate(target);
                                                    b_rev += 1;
                                                });
                                            },
                                            "{bl}"
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            div {
                style: "overflow-y:auto;flex:1;min-height:0;",
            for row in rows.iter() {
                {
                    let indent_px = row.depth * 16;
                    let indent_style = format!("width:{}px;flex-shrink:0;display:inline-block", indent_px);
                    let name_color = if row.is_named { "var(--jas-text,#ccc)" } else { "var(--jas-text-dim,#999)" };
                    let name_style = format!("flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0;color:{name_color}");
                    let sq_bg = if row.is_selected { &row.layer_color } else { "transparent" };
                    let sq_style = format!("width:12px;height:12px;border:1px solid var(--jas-border,#555);flex-shrink:0;background:{sq_bg}");
                    let eye_svg = row.eye_icon_svg.clone();
                    let lock_svg = row.lock_icon_svg.clone();
                    let twirl_svg = row.twirl_svg.clone();

                    // Click handlers
                    let eye_path = row.path.clone();
                    let eye_app = app.clone();
                    let mut eye_rev = revision;
                    let on_eye_click = move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        let p = eye_path.clone();
                        let a = eye_app.clone();
                        let alt = evt.data().modifiers().alt();
                        spawn(async move {
                            use crate::geometry::element::Visibility;
                            let mut st = a.borrow_mut();
                            if alt {
                                // Option-click: solo/unsolo among siblings
                                let parent_prefix: Vec<usize> = p[..p.len()-1].to_vec();
                                // Gather all sibling paths
                                let sibling_paths: Vec<Vec<usize>> = if let Some(tab) = st.tab() {
                                    let doc = tab.model.document();
                                    if parent_prefix.is_empty() {
                                        (0..doc.layers.len()).map(|i| vec![i]).collect()
                                    } else if let Some(parent) = doc.get_element(&parent_prefix) {
                                        if let Some(children) = parent.children() {
                                            (0..children.len()).map(|i| {
                                                let mut pp = parent_prefix.clone();
                                                pp.push(i);
                                                pp
                                            }).collect()
                                        } else { Vec::new() }
                                    } else { Vec::new() }
                                } else { Vec::new() };

                                let is_already_soloed = matches!(
                                    &st.layers_solo_state,
                                    Some(s) if s.soloed_path == p
                                );

                                if is_already_soloed {
                                    // Restore saved visibilities
                                    let saved = st.layers_solo_state.as_ref().unwrap().saved.clone();
                                    if let Some(tab) = st.tab_mut() {
                                        tab.model.snapshot();
                                        let doc = tab.model.document_mut();
                                        for (sp, vis) in &saved {
                                            if let Some(elem) = doc.get_element_mut(sp) {
                                                elem.common_mut().visibility = *vis;
                                            }
                                        }
                                    }
                                    st.layers_solo_state = None;
                                } else {
                                    // Save current visibilities of siblings != p, then set them invisible
                                    let mut saved = std::collections::HashMap::new();
                                    let doc_read = st.tab().map(|t| t.model.document().clone());
                                    if let Some(doc) = doc_read {
                                        for sp in &sibling_paths {
                                            if sp != &p {
                                                if let Some(elem) = doc.get_element(sp) {
                                                    saved.insert(sp.clone(), elem.visibility());
                                                }
                                            }
                                        }
                                    }
                                    if let Some(tab) = st.tab_mut() {
                                        tab.model.snapshot();
                                        let doc = tab.model.document_mut();
                                        // Ensure soloed element is visible
                                        if let Some(elem) = doc.get_element_mut(&p) {
                                            if elem.visibility() == Visibility::Invisible {
                                                elem.common_mut().visibility = Visibility::Preview;
                                            }
                                        }
                                        for sp in &sibling_paths {
                                            if sp != &p {
                                                if let Some(elem) = doc.get_element_mut(sp) {
                                                    elem.common_mut().visibility = Visibility::Invisible;
                                                }
                                            }
                                        }
                                    }
                                    st.layers_solo_state = Some(crate::workspace::app_state::LayerSoloState {
                                        soloed_path: p.clone(),
                                        saved,
                                    });
                                }
                            } else {
                                // Regular click: cycle visibility
                                // Clicking normally discards any pending solo restore state
                                st.layers_solo_state = None;
                                if let Some(tab) = st.tab_mut() {
                                    tab.model.snapshot();
                                    let doc = tab.model.document_mut();
                                    if let Some(elem) = doc.get_element_mut(&p) {
                                        let new_vis = match elem.visibility() {
                                            Visibility::Preview => Visibility::Outline,
                                            Visibility::Outline => Visibility::Invisible,
                                            Visibility::Invisible => Visibility::Preview,
                                        };
                                        elem.common_mut().visibility = new_vis;
                                        if new_vis == Visibility::Invisible {
                                            let path = p.clone();
                                            doc.selection.retain(|es| {
                                                !(es.path == path || es.path.starts_with(&path))
                                            });
                                        }
                                    }
                                }
                            }
                            eye_rev += 1;
                        });
                    };

                    let lock_path = row.path.clone();
                    let lock_app = app.clone();
                    let mut lock_rev = revision;
                    let on_lock_click = move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        let p = lock_path.clone();
                        let a = lock_app.clone();
                        spawn(async move {
                            let mut st = a.borrow_mut();
                            // Read current lock + container info from doc
                            let (was_unlocked, is_container, child_count) = {
                                if let Some(tab) = st.tab() {
                                    let doc = tab.model.document();
                                    if let Some(elem) = doc.get_element(&p) {
                                        let child_count = elem.children().map(|c| c.len()).unwrap_or(0);
                                        (!elem.locked(), elem.is_group_or_layer(), child_count)
                                    } else { (false, false, 0) }
                                } else { (false, false, 0) }
                            };

                            if is_container && was_unlocked {
                                // Save direct children's lock states before locking container
                                let mut saved = Vec::with_capacity(child_count);
                                if let Some(tab) = st.tab() {
                                    let doc = tab.model.document();
                                    if let Some(elem) = doc.get_element(&p) {
                                        if let Some(children) = elem.children() {
                                            for c in children {
                                                saved.push(c.locked());
                                            }
                                        }
                                    }
                                }
                                st.layers_saved_lock_states.insert(p.clone(), saved);
                            }

                            // Take the saved state out before the tab borrow so we can use
                            // it inside the tab_mut block without a second borrow of st.
                            let saved_to_restore = if is_container && !was_unlocked {
                                st.layers_saved_lock_states.remove(&p)
                            } else {
                                None
                            };

                            if let Some(tab) = st.tab_mut() {
                                tab.model.snapshot();
                                let doc = tab.model.document_mut();
                                if let Some(elem) = doc.get_element_mut(&p) {
                                    elem.common_mut().locked = was_unlocked;
                                    // When locking a container, also lock all direct children
                                    if is_container && was_unlocked {
                                        if let Some(children) = elem.children_mut() {
                                            for c in children.iter_mut() {
                                                std::rc::Rc::make_mut(c).common_mut().locked = true;
                                            }
                                        }
                                    }
                                }
                                // Restore saved child lock states on unlock
                                if let Some(saved) = saved_to_restore {
                                    let doc = tab.model.document_mut();
                                    if let Some(elem) = doc.get_element_mut(&p) {
                                        if let Some(children) = elem.children_mut() {
                                            for (i, c) in children.iter_mut().enumerate() {
                                                if let Some(&saved_locked) = saved.get(i) {
                                                    std::rc::Rc::make_mut(c).common_mut().locked = saved_locked;
                                                }
                                            }
                                        }
                                    }
                                }
                                // Locking an element removes it and its descendants from selection
                                if was_unlocked {
                                    let path = p.clone();
                                    let doc = tab.model.document_mut();
                                    doc.selection.retain(|es| {
                                        !(es.path == path || es.path.starts_with(&path))
                                    });
                                }
                            }
                            lock_rev += 1;
                        });
                    };

                    let sel_path = row.path.clone();
                    let sel_app = app.clone();
                    let mut sel_rev = revision;
                    let on_select_click = move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        let p = sel_path.clone();
                        let a = sel_app.clone();
                        let meta = evt.data().modifiers().meta();
                        spawn(async move {
                            use crate::document::document::ElementSelection;

                            /// Collect all descendant paths of a container element.
                            fn collect_descendants(
                                elem: &crate::geometry::element::Element,
                                path: &[usize],
                                out: &mut Vec<Vec<usize>>,
                            ) {
                                if let Some(children) = elem.children() {
                                    for (i, child) in children.iter().enumerate() {
                                        let mut child_path = path.to_vec();
                                        child_path.push(i);
                                        out.push(child_path.clone());
                                        collect_descendants(child, &child_path, out);
                                    }
                                }
                            }

                            let mut st = a.borrow_mut();
                            if let Some(tab) = st.tab_mut() {
                                let doc = tab.model.document_mut();
                                // Build the list of paths to select: the element itself
                                // plus all descendants if it's a container.
                                let mut paths_to_select = vec![p.clone()];
                                if let Some(elem) = doc.get_element(&p) {
                                    if elem.is_group_or_layer() {
                                        collect_descendants(elem, &p, &mut paths_to_select);
                                    }
                                }
                                if meta {
                                    // Cmd-click: toggle all paths in/out of selection
                                    let any_selected = paths_to_select.iter()
                                        .any(|pp| doc.selection.iter().any(|es| &es.path == pp));
                                    if any_selected {
                                        let path_set: std::collections::HashSet<&Vec<usize>> =
                                            paths_to_select.iter().collect();
                                        doc.selection.retain(|es| !path_set.contains(&es.path));
                                    } else {
                                        for pp in paths_to_select {
                                            if !doc.selection.iter().any(|es| es.path == pp) {
                                                doc.selection.push(ElementSelection::all(pp));
                                            }
                                        }
                                    }
                                } else {
                                    // Click: select these elements, deselect all others
                                    doc.selection = paths_to_select.into_iter()
                                        .map(ElementSelection::all)
                                        .collect();
                                }
                            }
                            sel_rev += 1;
                        });
                    };

                    let row_path = row.path.clone();
                    let row_app = app.clone();
                    let mut row_rev = revision;
                    let row_bg = if row.is_panel_selected {
                        "background:rgba(51,122,183,0.4);"
                    } else {
                        ""
                    };
                    // Snapshot the current rows' ordered paths for shift-range selection
                    let row_all_paths: Vec<Vec<usize>> = rows.iter().map(|r| r.path.clone()).collect();
                    let on_row_click = move |evt: Event<MouseData>| {
                        let p = row_path.clone();
                        let a = row_app.clone();
                        let meta = evt.data().modifiers().meta();
                        let shift = evt.data().modifiers().shift();
                        let all_paths = row_all_paths.clone();
                        spawn(async move {
                            let mut st = a.borrow_mut();
                            if shift && !st.layers_panel_selection.is_empty() {
                                // Range-select in visual order from the last panel-selected
                                // to the clicked row.
                                let anchor = st.layers_panel_selection.last().unwrap().clone();
                                let anchor_idx = all_paths.iter().position(|pp| *pp == anchor);
                                let clicked_idx = all_paths.iter().position(|pp| *pp == p);
                                if let (Some(a_idx), Some(c_idx)) = (anchor_idx, clicked_idx) {
                                    let (lo, hi) = if a_idx <= c_idx { (a_idx, c_idx) } else { (c_idx, a_idx) };
                                    st.layers_panel_selection = all_paths[lo..=hi].to_vec();
                                }
                            } else if meta {
                                if let Some(idx) = st.layers_panel_selection.iter().position(|pp| *pp == p) {
                                    st.layers_panel_selection.remove(idx);
                                } else {
                                    st.layers_panel_selection.push(p);
                                }
                            } else {
                                st.layers_panel_selection = vec![p];
                            }
                            st.layers_context_menu = None;
                            row_rev += 1;
                        });
                    };

                    // Right-click: show context menu at cursor, select if not selected
                    let ctx_path = row.path.clone();
                    let ctx_app = app.clone();
                    let mut ctx_rev = revision;
                    let on_row_contextmenu = move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        evt.prevent_default();
                        let coords = evt.data().client_coordinates();
                        let p = ctx_path.clone();
                        let a = ctx_app.clone();
                        spawn(async move {
                            let mut st = a.borrow_mut();
                            if !st.layers_panel_selection.contains(&p) {
                                st.layers_panel_selection = vec![p.clone()];
                            }
                            st.layers_context_menu = Some((coords.x, coords.y, p));
                            ctx_rev += 1;
                        });
                    };

                    // Drag handlers
                    let drag_down_path = row.path.clone();
                    let drag_down_app = app.clone();
                    let drag_down_selected = row.is_panel_selected;
                    let on_mousedown = move |evt: Event<MouseData>| {
                        if drag_down_selected {
                            evt.stop_propagation();
                            let a = drag_down_app.clone();
                            let p = drag_down_path.clone();
                            spawn(async move {
                                // Mark drag as active by setting target to the source path initially
                                a.borrow_mut().layers_drag_target = Some(p);
                            });
                        }
                    };

                    let drag_enter_path = row.path.clone();
                    let drag_enter_app = app.clone();
                    let mut drag_enter_rev = revision;
                    let drag_enter_is_container = row.is_container;
                    let drag_enter_is_collapsed = row.is_collapsed;
                    let on_mouseenter = move |_: Event<MouseData>| {
                        let a = drag_enter_app.clone();
                        let p = drag_enter_path.clone();
                        let is_container = drag_enter_is_container;
                        let is_collapsed = drag_enter_is_collapsed;
                        spawn(async move {
                            let mut st = a.borrow_mut();
                            if st.layers_drag_target.is_some() {
                                st.layers_drag_target = Some(p.clone());
                                drag_enter_rev += 1;
                            } else {
                                return;
                            }
                            drop(st);

                            // If hovering a collapsed container during drag, schedule
                            // an auto-expand after 500ms of continuous hover.
                            if is_container && is_collapsed {
                                #[cfg(target_arch = "wasm32")]
                                {
                                    use wasm_bindgen::prelude::*;
                                    use wasm_bindgen::JsCast;
                                    let a_for_cb = a.clone();
                                    let p_for_cb = p.clone();
                                    let mut rev_for_cb = drag_enter_rev;
                                    let cb = Closure::once(move || {
                                        let mut st = a_for_cb.borrow_mut();
                                        // Only expand if still hovering the same row during drag
                                        if st.layers_drag_target.as_ref() == Some(&p_for_cb) {
                                            st.layers_collapsed.remove(&p_for_cb);
                                            rev_for_cb += 1;
                                        }
                                    });
                                    if let Some(win) = web_sys::window() {
                                        let _ = win.set_timeout_with_callback_and_timeout_and_arguments_0(
                                            cb.as_ref().unchecked_ref(),
                                            500,
                                        );
                                        cb.forget();
                                    }
                                }
                            }
                        });
                    };

                    let drag_up_path = row.path.clone();
                    let drag_up_app = app.clone();
                    let mut drag_up_rev = revision;
                    let on_mouseup = move |_: Event<MouseData>| {
                        let a = drag_up_app.clone();
                        let target = drag_up_path.clone();
                        spawn(async move {
                            let mut st = a.borrow_mut();
                            if let Some(_drag_target) = st.layers_drag_target.take() {
                                // Move all panel-selected elements to before the target
                                let sources = st.layers_panel_selection.clone();
                                // Validate drag constraints
                                let target_parent: Vec<usize> = target[..target.len()-1].to_vec();
                                let allowed = {
                                    if sources.is_empty() || sources.contains(&target) {
                                        false
                                    } else if let Some(tab) = st.tab() {
                                        let doc = tab.model.document();
                                        // Check: no source is an ancestor of target (no drop into self/descendant)
                                        let no_cycle = !sources.iter().any(|src| {
                                            target.len() >= src.len() && target.starts_with(src)
                                        });
                                        // Check: target's parent isn't locked (can't drop into locked)
                                        let parent_unlocked = if target_parent.is_empty() {
                                            true
                                        } else {
                                            doc.get_element(&target_parent)
                                                .map(|e| !e.locked())
                                                .unwrap_or(true)
                                        };
                                        no_cycle && parent_unlocked
                                    } else {
                                        false
                                    }
                                };
                                if allowed {
                                    if let Some(tab) = st.tab_mut() {
                                        tab.model.snapshot();
                                        // Collect elements, delete from old positions (reverse order),
                                        // then insert at target position
                                        let mut elements: Vec<(Vec<usize>, crate::geometry::element::Element)> = Vec::new();
                                        let doc = tab.model.document();
                                        for src in &sources {
                                            if let Some(elem) = doc.get_element(src) {
                                                elements.push((src.clone(), elem.clone()));
                                            }
                                        }
                                        // Delete in reverse order to preserve indices
                                        let mut sorted_sources = sources.clone();
                                        sorted_sources.sort();
                                        sorted_sources.reverse();
                                        let mut doc = tab.model.document().clone();
                                        for src in &sorted_sources {
                                            doc = doc.delete_element(src);
                                        }
                                        // Insert at target — adjust target path for deleted elements
                                        let mut insert_path = target.clone();
                                        let mut new_paths = Vec::new();
                                        for (_, elem) in elements {
                                            doc = doc.insert_element_at(&insert_path, elem);
                                            new_paths.push(insert_path.clone());
                                            // Next element goes after this one
                                            let last = insert_path.len() - 1;
                                            insert_path[last] += 1;
                                        }
                                        // Update element selection to track moved elements
                                        doc.selection = new_paths.iter()
                                            .map(|p| crate::document::document::ElementSelection::all(p.clone()))
                                            .collect();
                                        tab.model.set_document(doc);
                                        // Update panel selection to new positions
                                        st.layers_panel_selection = new_paths;
                                    }
                                } else {
                                    st.layers_panel_selection.clear();
                                }
                            }
                            drag_up_rev += 1;
                        });
                    };

                    // Drop indicator
                    let is_drag_target = {
                        let st = rctx.app.borrow();
                        st.layers_drag_target.as_ref() == Some(&row.path) &&
                        !st.layers_panel_selection.contains(&row.path)
                    };
                    let drop_indicator = if is_drag_target {
                        "border-top:2px solid var(--jas-accent,#3a7bd5);"
                    } else {
                        ""
                    };

                    let row_dom_id = format!("lp_row_{}", row.path.iter().map(|i| i.to_string()).collect::<Vec<_>>().join("_"));
                    rsx! {
                        div {
                            id: "{row_dom_id}",
                            style: "display:flex;align-items:center;height:24px;padding:0 4px;gap:2px;font-size:11px;color:var(--jas-text,#ccc);cursor:default;user-select:none;{row_bg}{drop_indicator}",
                            onclick: on_row_click,
                            oncontextmenu: on_row_contextmenu,
                            onmousedown: on_mousedown,
                            onmouseenter: on_mouseenter,
                            onmouseup: on_mouseup,
                            // Indent
                            span { style: "{indent_style}" }
                            // Eye button
                            div {
                                style: "{btn_style}",
                                onclick: on_eye_click,
                                div { style: "width:100%;height:100%", dangerous_inner_html: "{eye_svg}" }
                            }
                            // Lock button
                            div {
                                style: "{btn_style}",
                                onclick: on_lock_click,
                                div { style: "width:100%;height:100%", dangerous_inner_html: "{lock_svg}" }
                            }
                            // Twirl or gap
                            if row.is_container {
                                {
                                    let twirl_path = row.path.clone();
                                    let twirl_app = app.clone();
                                    let mut twirl_rev = revision;
                                    rsx! {
                                        div {
                                            style: "{btn_style}",
                                            onclick: move |evt: Event<MouseData>| {
                                                evt.stop_propagation();
                                                let p = twirl_path.clone();
                                                let a = twirl_app.clone();
                                                spawn(async move {
                                                    let mut st = a.borrow_mut();
                                                    if st.layers_collapsed.contains(&p) {
                                                        st.layers_collapsed.remove(&p);
                                                    } else {
                                                        st.layers_collapsed.insert(p);
                                                    }
                                                    twirl_rev += 1;
                                                });
                                            },
                                            div { style: "width:100%;height:100%", dangerous_inner_html: "{twirl_svg}" }
                                        }
                                    }
                                }
                            } else {
                                div { style: "width:16px;flex-shrink:0" }
                            }
                            // Preview thumbnail — fitted SVG of the element
                            {
                                let preview_svg = row.preview_svg.clone();
                                rsx! {
                                    div {
                                        style: "width:24px;height:24px;background:#fff;border:1px solid var(--jas-border,#555);border-radius:1px;flex-shrink:0;overflow:hidden;",
                                        dangerous_inner_html: "{preview_svg}",
                                    }
                                }
                            }
                            // Name — inline input when renaming, otherwise span with double-click
                            if row.is_renaming {
                                {
                                    let confirm_path = row.path.clone();
                                    let confirm_app = app.clone();
                                    let mut confirm_rev = revision;
                                    let cancel_app = app.clone();
                                    let mut cancel_rev = revision;
                                    let initial_name = if row.is_named { row.display_name.clone() } else { String::new() };
                                    rsx! {
                                        input {
                                            r#type: "text",
                                            value: "{initial_name}",
                                            style: "flex:1;font-size:11px;background:var(--jas-input-bg,#333);color:var(--jas-text,#ccc);border:1px solid var(--jas-accent,#3a7bd5);outline:none;padding:0 2px;min-width:0",
                                            autofocus: true,
                                            onkeydown: move |evt: Event<KeyboardData>| {
                                                let key = evt.data().key();
                                                if key == dioxus::prelude::Key::Enter {
                                                    // Read value from DOM and commit rename
                                                    #[cfg(target_arch = "wasm32")]
                                                    {
                                                        let p = confirm_path.clone();
                                                        let a = confirm_app.clone();
                                                        if let Some(el) = web_sys::window()
                                                            .and_then(|w| w.document())
                                                            .and_then(|d| d.active_element())
                                                        {
                                                            let val = el.get_attribute("value").unwrap_or_default();
                                                            let val_inner: String = js_sys::Reflect::get(&el, &"value".into())
                                                                .ok()
                                                                .and_then(|v| v.as_string())
                                                                .unwrap_or(val);
                                                            spawn(async move {
                                                                let mut st = a.borrow_mut();
                                                                if let Some(tab) = st.tab_mut() {
                                                                    tab.model.snapshot();
                                                                    let doc = tab.model.document_mut();
                                                                    if let Some(crate::geometry::element::Element::Layer(le)) = doc.get_element_mut(&p) {
                                                                        le.name = val_inner;
                                                                    }
                                                                }
                                                                st.layers_renaming = None;
                                                                confirm_rev += 1;
                                                            });
                                                        }
                                                    }
                                                    #[cfg(not(target_arch = "wasm32"))]
                                                    {
                                                        let a = confirm_app.clone();
                                                        spawn(async move {
                                                            a.borrow_mut().layers_renaming = None;
                                                            confirm_rev += 1;
                                                        });
                                                    }
                                                } else if key == dioxus::prelude::Key::Escape {
                                                    let a = cancel_app.clone();
                                                    spawn(async move {
                                                        a.borrow_mut().layers_renaming = None;
                                                        cancel_rev += 1;
                                                    });
                                                }
                                            },
                                        }
                                    }
                                }
                            } else {
                                {
                                    let name_path = row.path.clone();
                                    let name_app = app.clone();
                                    let mut name_rev = revision;
                                    let can_rename = row.is_layer;
                                    rsx! {
                                        span {
                                            style: "{name_style}",
                                            ondoubleclick: move |_: Event<MouseData>| {
                                                if can_rename {
                                                    let p = name_path.clone();
                                                    let a = name_app.clone();
                                                    spawn(async move {
                                                        a.borrow_mut().layers_renaming = Some(p);
                                                        name_rev += 1;
                                                    });
                                                }
                                            },
                                            "{row.display_name}"
                                        }
                                    }
                                }
                            }
                            // Select square
                            div {
                                style: "{sq_style};cursor:pointer",
                                onclick: on_select_click,
                            }
                        }
                    }
                }
            }
            } // close inner scrolling div
            // Context menu overlay
            if let Some((cx, cy, cpath)) = context_menu_state.clone() {
                {
                    let menu_style = format!(
                        "position:fixed;left:{}px;top:{}px;background:var(--jas-pane-bg,#2a2a2a);border:1px solid var(--jas-border,#555);border-radius:2px;padding:2px 0;min-width:160px;z-index:10000;box-shadow:0 2px 8px rgba(0,0,0,0.5);",
                        cx, cy
                    );
                    let is_container = {
                        let st = app.borrow();
                        st.tab().and_then(|t| t.model.document().get_element(&cpath))
                            .map(|e| e.is_group_or_layer()).unwrap_or(false)
                    };
                    let is_layer = {
                        let st = app.borrow();
                        st.tab().and_then(|t| t.model.document().get_element(&cpath))
                            .map(|e| e.is_layer()).unwrap_or(false)
                    };
                    let item_style = "padding:4px 12px;font-size:11px;color:var(--jas-text,#ccc);cursor:pointer;";
                    let item_style_disabled = "padding:4px 12px;font-size:11px;color:var(--jas-text-dim,#777);";

                    let close_app1 = app.clone();
                    let mut close_rev1 = revision;
                    let close_app2 = app.clone();
                    let mut close_rev2 = revision;

                    let cpath_for_action = cpath.clone();
                    let mut ctx_dialog_signal = rctx.dialog_ctx.0;
                    let do_action = |action: &'static str| {
                        let a = app.clone();
                        let mut r = revision;
                        let path_str = cpath_for_action.iter().map(|i| i.to_string()).collect::<Vec<_>>().join(",");
                        move |_: Event<MouseData>| {
                            let a2 = a.clone();
                            let ps = path_str.clone();
                            spawn(async move {
                                let deferred = {
                                    let mut st = a2.borrow_mut();
                                    let mut params = serde_json::Map::new();
                                    params.insert("layer_id".into(), serde_json::Value::String(ps));
                                    let d = dispatch_action(action, &params, &mut st);
                                    st.layers_context_menu = None;
                                    d
                                };
                                for eff in deferred {
                                    if let Some(od) = eff.get("open_dialog") {
                                        let dlg_id = od.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string();
                                        let raw_params = od.get("params").and_then(|p| p.as_object()).cloned().unwrap_or_default();
                                        let live_state = {
                                            let st = a2.borrow();
                                            crate::workspace::dock_panel::build_live_state_map(&st)
                                        };
                                        super::dialog_view::open_dialog(&mut ctx_dialog_signal, &dlg_id, &raw_params, &live_state);
                                    }
                                }
                                r += 1;
                            });
                        }
                    };

                    rsx! {
                        // Backdrop to close menu on click
                        div {
                            style: "position:fixed;inset:0;z-index:9999;",
                            onclick: move |_: Event<MouseData>| {
                                let a = close_app1.clone();
                                spawn(async move {
                                    a.borrow_mut().layers_context_menu = None;
                                    close_rev1 += 1;
                                });
                            },
                            oncontextmenu: move |evt: Event<MouseData>| {
                                evt.prevent_default();
                                let a = close_app2.clone();
                                spawn(async move {
                                    a.borrow_mut().layers_context_menu = None;
                                    close_rev2 += 1;
                                });
                            },
                        }
                        div {
                            style: "{menu_style}",
                            div {
                                style: if is_layer { item_style } else { item_style_disabled },
                                onclick: do_action("open_layer_options"),
                                "Options for Layer..."
                            }
                            div {
                                style: "{item_style}",
                                onclick: do_action("duplicate_layer_selection"),
                                "Duplicate"
                            }
                            div {
                                style: "{item_style}",
                                onclick: do_action("delete_layer_selection"),
                                "Delete Selection"
                            }
                            div { style: "height:1px;background:var(--jas-border,#555);margin:2px 0;" }
                            div {
                                style: if is_container { item_style } else { item_style_disabled },
                                onclick: do_action("enter_isolation_mode"),
                                "Enter Isolation Mode"
                            }
                            div { style: "height:1px;background:var(--jas-border,#555);margin:2px 0;" }
                            div {
                                style: "{item_style}",
                                onclick: do_action("flatten_artwork"),
                                "Flatten Artwork"
                            }
                            div {
                                style: "{item_style}",
                                onclick: do_action("collect_in_new_layer"),
                                "Collect in New Layer"
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Render an element_preview widget as a placeholder thumbnail square.
fn render_element_preview(el: &serde_json::Value, ctx: &serde_json::Value, _rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let sz = el.get("style").and_then(|s| s.get("size")).and_then(|v| v.as_u64()).unwrap_or(32);
    let style = build_style(el, ctx);
    rsx! {
        div {
            id: "{id}",
            style: "width:{sz}px;height:{sz}px;background:#fff;border:1px solid var(--jas-border,#555);border-radius:1px;flex-shrink:0;{style}",
        }
    }
}

/// Render the layers panel's type filter dropdown. For other dropdowns
/// (none exist yet), falls through to placeholder.
fn render_layers_filter_dropdown(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    if id != "lp_filter_button" {
        return render_placeholder(el, ctx);
    }

    let style = build_style(el, ctx);
    let icon_svg = {
        let ws = super::workspace::Workspace::load();
        ws.and_then(|ws| {
            ws.icons().get("filter").map(|def| {
                let viewbox = def.get("viewbox").and_then(|v| v.as_str()).unwrap_or("0 0 16 16");
                let inner = def.get("svg").and_then(|v| v.as_str()).unwrap_or("");
                format!(r#"<svg viewBox="{viewbox}" width="14" height="14" xmlns="http://www.w3.org/2000/svg">{inner}</svg>"#)
            })
        }).unwrap_or_default()
    };

    let is_open = rctx.app.borrow().layers_filter_dropdown_open;

    let items: Vec<(String, String)> = el.get("items")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(|item| {
            let label = item.get("label").and_then(|v| v.as_str())?;
            let value = item.get("value").and_then(|v| v.as_str())?;
            Some((label.to_string(), value.to_string()))
        }).collect())
        .unwrap_or_default();

    let toggle_app = rctx.app.clone();
    let mut toggle_rev = rctx.revision;
    let on_toggle_open = move |evt: Event<MouseData>| {
        evt.stop_propagation();
        let a = toggle_app.clone();
        spawn(async move {
            let mut st = a.borrow_mut();
            st.layers_filter_dropdown_open = !st.layers_filter_dropdown_open;
            toggle_rev += 1;
        });
    };

    let hidden_types: std::collections::HashSet<String> = rctx.app.borrow()
        .layers_hidden_types.iter().cloned().collect();

    let close_app = rctx.app.clone();
    let mut close_rev = rctx.revision;

    rsx! {
        div {
            id: "{id}",
            style: "position:relative;display:inline-flex;{style}",
            div {
                style: "width:20px;height:20px;display:flex;align-items:center;justify-content:center;cursor:pointer;color:var(--jas-text,#ccc);",
                onclick: on_toggle_open,
                div { style: "width:14px;height:14px;", dangerous_inner_html: "{icon_svg}" }
            }
            if is_open {
                {
                    // Backdrop
                    let bd_app = close_app.clone();
                    let mut bd_rev = close_rev;
                    rsx! {
                        div {
                            style: "position:fixed;inset:0;z-index:9999;",
                            onclick: move |_: Event<MouseData>| {
                                let a = bd_app.clone();
                                spawn(async move {
                                    a.borrow_mut().layers_filter_dropdown_open = false;
                                    bd_rev += 1;
                                });
                            },
                        }
                        div {
                            style: "position:absolute;top:22px;right:0;background:var(--jas-pane-bg,#2a2a2a);border:1px solid var(--jas-border,#555);border-radius:2px;padding:4px 0;min-width:140px;z-index:10000;box-shadow:0 2px 8px rgba(0,0,0,0.5);",
                            for (label, value) in items.iter() {
                                {
                                    let item_app = rctx.app.clone();
                                    let mut item_rev = close_rev;
                                    let v = value.clone();
                                    let checked = !hidden_types.contains(&v);
                                    let check_mark = if checked { "☑" } else { "☐" };
                                    rsx! {
                                        div {
                                            key: "{v}",
                                            style: "padding:3px 12px;font-size:11px;color:var(--jas-text,#ccc);cursor:pointer;display:flex;align-items:center;gap:6px;",
                                            onclick: move |evt: Event<MouseData>| {
                                                evt.stop_propagation();
                                                let a = item_app.clone();
                                                let vv = v.clone();
                                                spawn(async move {
                                                    let mut st = a.borrow_mut();
                                                    if st.layers_hidden_types.contains(&vv) {
                                                        st.layers_hidden_types.remove(&vv);
                                                    } else {
                                                        st.layers_hidden_types.insert(vv);
                                                    }
                                                    item_rev += 1;
                                                });
                                            },
                                            span { "{check_mark}" }
                                            span { "{label}" }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

fn render_placeholder(el: &serde_json::Value, _ctx: &serde_json::Value) -> Element {
    let summary = el.get("summary")
        .or_else(|| el.get("type"))
        .and_then(|s| s.as_str())
        .unwrap_or("?");
    rsx! {
        div {
            style: "padding:12px;color:var(--jas-text-dim,#999);font-size:12px;text-align:center;min-height:30px;",
            "[{summary}]"
        }
    }
}

/// Top-level component that renders a panel from its YAML spec.
///
/// Call this from the dock panel rendering code, passing the panel
/// spec's content element and the evaluation context.
#[component]
pub fn YamlPanelBody(content: serde_json::Value, eval_ctx: serde_json::Value) -> Element {
    render_element(&content, &eval_ctx)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::element::{Color, Fill, Stroke};
    use crate::workspace::app_state::AppState;

    fn make_state_with_colors(fill_hex: &str, stroke_hex: &str) -> AppState {
        let mut st = AppState::new();
        st.app_default_fill = Color::from_hex(fill_hex).map(Fill::new);
        st.app_default_stroke = Color::from_hex(stroke_hex).map(|c| Stroke::new(c, 1.0));
        st
    }

    #[test]
    fn get_app_state_field_fill_color() {
        let st = make_state_with_colors("ff0000", "0000ff");
        assert_eq!(
            get_app_state_field("fill_color", &st),
            serde_json::Value::String("#ff0000".to_string())
        );
    }

    #[test]
    fn get_app_state_field_stroke_color() {
        let st = make_state_with_colors("ff0000", "0000ff");
        assert_eq!(
            get_app_state_field("stroke_color", &st),
            serde_json::Value::String("#0000ff".to_string())
        );
    }

    #[test]
    fn get_app_state_field_null_fill() {
        let mut st = AppState::new();
        st.app_default_fill = None;
        assert_eq!(get_app_state_field("fill_color", &st), serde_json::Value::Null);
    }

    #[test]
    fn swap_fill_stroke_via_run_effects() {
        let mut st = make_state_with_colors("ff0000", "0000ff");
        let effects = vec![serde_json::json!({"swap": ["fill_color", "stroke_color"]})];
        run_effects(&effects, &mut st);
        // After swap: fill should be the old stroke color, stroke should be old fill color
        let fill_hex = st.app_default_fill.map(|f| format!("#{}", f.color.to_hex()));
        let stroke_hex = st.app_default_stroke.map(|s| format!("#{}", s.color.to_hex()));
        assert_eq!(fill_hex, Some("#0000ff".to_string()));
        assert_eq!(stroke_hex, Some("#ff0000".to_string()));
    }

    #[test]
    fn swap_fill_stroke_null_fill() {
        let mut st = AppState::new();
        st.app_default_fill = None;
        st.app_default_stroke = Color::from_hex("0000ff").map(|c| Stroke::new(c, 2.0));
        let effects = vec![serde_json::json!({"swap": ["fill_color", "stroke_color"]})];
        run_effects(&effects, &mut st);
        let fill_hex = st.app_default_fill.map(|f| format!("#{}", f.color.to_hex()));
        assert_eq!(fill_hex, Some("#0000ff".to_string()));
        assert!(st.app_default_stroke.is_none());
    }
}
