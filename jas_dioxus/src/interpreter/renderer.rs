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
use crate::workspace::workspace::PanelKind;

/// Shared context captured once per panel body render, passed to all
/// child element renderers so they don't need to call use_context
/// (which would violate the rules of hooks inside conditional branches).
///
/// `panel_kind` is set by `render_panel` when a panel element is
/// entered, so widget-level event handlers can dispatch panel-state
/// writes (set_panel_state, number_input/checkbox/text_input commit)
/// to the right per-panel state struct on AppState. `None` for
/// widgets rendered outside any panel (e.g., dialog contents,
/// toolbar).
#[derive(Clone)]
struct RenderCtx {
    app: AppHandle,
    revision: Signal<u64>,
    dialog_ctx: super::dialog_view::DialogCtx,
    timer_ctx: super::timer::TimerCtx,
    panel_kind: Option<PanelKind>,
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
        panel_kind: None,
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
    if let (Some(repeat), Some(template)) = (el.get("foreach"), el.get("do")) {
        return render_repeat(repeat, template, el, ctx, rctx);
    }

    // _template tag available for native widget overrides when needed.
    // Currently using generic rendering for all templates (matches Flask).

    let etype = el.get("type").and_then(|t| t.as_str()).unwrap_or("placeholder");

    match etype {
        "container" | "row" | "col" => render_container(el, ctx, rctx),
        "grid" => render_grid(el, ctx, rctx),
        "text" => render_text(el, ctx, rctx),
        "button" => render_button(el, ctx, rctx),
        "icon_button" => render_icon_button(el, ctx, rctx),
        "icon_button_group" => render_icon_button_group(el, ctx, rctx),
        "reference_point_widget" => render_reference_point_widget(el, ctx, rctx),
        "icon" => render_icon(el, ctx),
        "slider" => render_slider(el, ctx, rctx),
        "number_input" => render_number_input(el, ctx, rctx),
        "text_input" => render_text_input(el, ctx, rctx),
        "length_input" => render_length_input(el, ctx, rctx),
        "select" => render_select(el, ctx, rctx),
        "icon_select" => render_icon_select(el, ctx, rctx),
        "toggle" | "checkbox" => render_toggle(el, ctx, rctx),
        "radio" => render_radio(el, ctx, rctx),
        "radio_group" => render_radio_group(el, ctx, rctx),
        "combo_box" => render_combo_box(el, ctx, rctx),
        "color_swatch" => render_color_swatch(el, ctx, rctx),
        "gradient_tile" => render_gradient_tile(el, ctx, rctx),
        "gradient_slider" => render_gradient_slider(el, ctx, rctx),
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
        "tabs" => render_tabs(el, ctx, rctx),
        _ => render_placeholder(el, ctx, rctx),
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
fn render_repeat(
    repeat: &serde_json::Value,
    template: &serde_json::Value,
    el: &serde_json::Value,
    ctx: &serde_json::Value,
    rctx: &RenderCtx,
) -> Element {
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
        Value::Path(ref indices) => serde_json::json!({
            "__path__": indices.iter().map(|&i| i as u64).collect::<Vec<_>>()
        }),
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
        "save_swatch_library_confirm" => {
            // Save dialog 'name' field. Serialize the active swatch
            // library (selected_library) to JSON and trigger a
            // browser file download. The Flask-target test plan
            // expects a server-side write to workspace/swatches/;
            // in the Dioxus browser app this is a download.
            let name = dialog.get("name").and_then(|v| v.as_str()).unwrap_or("");
            if name.is_empty() {
                return;
            }
            let lib_id = st.swatches_panel.selected_library.clone();
            if let Some(lib) = st.swatch_libraries.get(&lib_id).cloned() {
                let mut out = lib;
                // Overwrite the saved library's name to match the
                // dialog input rather than the source file's name.
                if let Some(obj) = out.as_object_mut() {
                    obj.insert("name".into(), serde_json::Value::String(name.to_string()));
                }
                let json = serde_json::to_string_pretty(&out).unwrap_or_default();
                let filename = format!("{name}.json");
                // showSaveFilePicker requires user activation, but the
                // Save button's dispatch goes through Dioxus's spawn,
                // which detaches from the click and loses the
                // activation. Fall back to a normal browser download —
                // matches how SVG Save and PDF Export persist files in
                // the same app.
                crate::workspace::clipboard::download_file(&filename, &json);
            }
        }
        // Phase 8: Justification dialog OK. Commit the 11 dialog
        // fields as jas:* attributes onto every paragraph wrapper
        // tspan in the selection. Mixed-selection semantics: each
        // field writes to all selected wrappers (untouched fields
        // commit their displayed value too — the panel's mixed
        // aggregator already shows blank for disagree, so the
        // implementation can write the dialog's current value
        // unconditionally).
        "paragraph_justification_confirm" => {
            let f = |k: &str| dialog.get(k).and_then(|v| v.as_f64());
            let s = |k: &str| dialog.get(k).and_then(|v| v.as_str()).map(String::from);
            st.apply_justification_dialog_to_selection(JustificationDialogValues {
                word_spacing_min: f("word_spacing_min"),
                word_spacing_desired: f("word_spacing_desired"),
                word_spacing_max: f("word_spacing_max"),
                letter_spacing_min: f("letter_spacing_min"),
                letter_spacing_desired: f("letter_spacing_desired"),
                letter_spacing_max: f("letter_spacing_max"),
                glyph_scaling_min: f("glyph_scaling_min"),
                glyph_scaling_desired: f("glyph_scaling_desired"),
                glyph_scaling_max: f("glyph_scaling_max"),
                auto_leading: f("auto_leading"),
                single_word_justify: s("single_word_justify"),
            });
        }
        // Phase 9: Hyphenation dialog OK. Commits the master
        // checkbox + 7 jas:hyphenate-* attributes onto every
        // paragraph wrapper in the selection. The master mirrors
        // panel.hyphenate so the main panel's checkbox stays in
        // sync after the OK fires (panel.hyphenate read live from
        // the wrapper next time the panel renders).
        "paragraph_hyphenation_confirm" => {
            let f = |k: &str| dialog.get(k).and_then(|v| v.as_f64());
            let b = |k: &str| dialog.get(k).and_then(|v| v.as_bool());
            st.apply_hyphenation_dialog_to_selection(HyphenationDialogValues {
                hyphenate: b("hyphenate"),
                min_word: f("hyphenate_min_word"),
                min_before: f("hyphenate_min_before"),
                min_after: f("hyphenate_min_after"),
                limit: f("hyphenate_limit"),
                zone: f("hyphenate_zone"),
                bias: f("hyphenate_bias"),
                capitalized: b("hyphenate_capitalized"),
            });
        }
        // brush_options_confirm is handled by the
        // brush.options_confirm effect handler in effects.rs (the
        // Phase 7.6 unification). The Phase 7.3 stop-gap that
        // operated on AppState.brush_libraries was removed in
        // favour of the StateStore.data source-of-truth used by
        // the brush.* effect family.
        _ => {}
    }
}

fn apply_brush_options_confirm(
    dialog: &serde_json::Map<String, serde_json::Value>,
    st: &mut crate::workspace::app_state::AppState,
) {
    let mode = dialog.get("_param_mode").and_then(|v| v.as_str()).unwrap_or("create");
    let library = dialog.get("_param_library").and_then(|v| v.as_str()).unwrap_or("");
    let brush_slug = dialog.get("_param_brush_slug").and_then(|v| v.as_str()).unwrap_or("");
    let name = dialog.get("brush_name").and_then(|v| v.as_str()).unwrap_or("Brush").to_string();
    let brush_type = dialog.get("brush_type").and_then(|v| v.as_str()).unwrap_or("calligraphic");

    // Calligraphic params
    let angle = dialog.get("angle").and_then(|v| v.as_f64()).unwrap_or(0.0);
    let roundness = dialog.get("roundness").and_then(|v| v.as_f64()).unwrap_or(100.0);
    let size = dialog.get("size").and_then(|v| v.as_f64()).unwrap_or(5.0);
    let angle_var = dialog.get("angle_variation").cloned()
        .unwrap_or_else(|| serde_json::json!({ "mode": "fixed" }));
    let roundness_var = dialog.get("roundness_variation").cloned()
        .unwrap_or_else(|| serde_json::json!({ "mode": "fixed" }));
    let size_var = dialog.get("size_variation").cloned()
        .unwrap_or_else(|| serde_json::json!({ "mode": "fixed" }));

    let lib_key = if !library.is_empty() {
        library.to_string()
    } else {
        st.brush_libraries.as_object()
            .and_then(|m| m.keys().next().cloned())
            .unwrap_or_default()
    };
    if lib_key.is_empty() { return; }

    match mode {
        "create" => {
            // Slug from name: lowercase, replace non-alphanum with _
            let raw_slug: String = name.chars()
                .map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '_' })
                .collect();
            let lib = match st.brush_libraries.get_mut(&lib_key)
                .and_then(|l| l.get_mut("brushes"))
                .and_then(|b| b.as_array_mut()) {
                Some(b) => b,
                None => return,
            };
            // Make slug unique within the library.
            let mut slug = raw_slug.clone();
            let mut n = 2;
            let existing: std::collections::HashSet<String> = lib.iter()
                .filter_map(|b| b.get("slug").and_then(|s| s.as_str()).map(String::from))
                .collect();
            while existing.contains(&slug) {
                slug = format!("{raw_slug}_{n}");
                n += 1;
            }
            let mut brush = serde_json::Map::new();
            brush.insert("name".to_string(), serde_json::Value::String(name));
            brush.insert("slug".to_string(), serde_json::Value::String(slug));
            brush.insert("type".to_string(), serde_json::Value::String(brush_type.to_string()));
            if brush_type == "calligraphic" {
                brush.insert("angle".to_string(), serde_json::json!(angle));
                brush.insert("roundness".to_string(), serde_json::json!(roundness));
                brush.insert("size".to_string(), serde_json::json!(size));
                brush.insert("angle_variation".to_string(), angle_var);
                brush.insert("roundness_variation".to_string(), roundness_var);
                brush.insert("size_variation".to_string(), size_var);
            }
            lib.push(serde_json::Value::Object(brush));
        }
        "library_edit" => {
            if brush_slug.is_empty() { return; }
            let lib = match st.brush_libraries.get_mut(&lib_key)
                .and_then(|l| l.get_mut("brushes"))
                .and_then(|b| b.as_array_mut()) {
                Some(b) => b,
                None => return,
            };
            for b in lib.iter_mut() {
                if b.get("slug").and_then(|s| s.as_str()) != Some(brush_slug) { continue; }
                if let Some(map) = b.as_object_mut() {
                    map.insert("name".to_string(), serde_json::Value::String(name.clone()));
                    if brush_type == "calligraphic" {
                        map.insert("angle".to_string(), serde_json::json!(angle));
                        map.insert("roundness".to_string(), serde_json::json!(roundness));
                        map.insert("size".to_string(), serde_json::json!(size));
                        map.insert("angle_variation".to_string(), angle_var.clone());
                        map.insert("roundness_variation".to_string(), roundness_var.clone());
                        map.insert("size_variation".to_string(), size_var.clone());
                    }
                }
                break;
            }
        }
        "instance_edit" => {
            // Build a partial overrides JSON object from the
            // dialog's Calligraphic fields. The actual write to
            // the canvas selection happens via the existing
            // doc.set_attr_on_selection effect chain rather than
            // through here (apply_dialog_confirm is purely
            // AppState-scoped, no model handle). The dialog's OK
            // action chain should fire doc.set_attr_on_selection
            // with the assembled JSON immediately before
            // close_dialog. Phase 1 leaves this branch as a stub
            // that records the intended overrides on AppState for
            // a follow-up effect to consume.
            let overrides = serde_json::json!({
                "angle": angle,
                "roundness": roundness,
                "size": size,
            });
            let _ = serde_json::to_string(&overrides);
        }
        _ => {}
    }
}

/// 11 Justification-dialog field values, packed for one commit pass.
/// `None` means the dialog field was blank (mixed selection) and
/// should not write — the existing wrapper attr stays. Phase 8.
pub(crate) struct JustificationDialogValues {
    pub word_spacing_min: Option<f64>,
    pub word_spacing_desired: Option<f64>,
    pub word_spacing_max: Option<f64>,
    pub letter_spacing_min: Option<f64>,
    pub letter_spacing_desired: Option<f64>,
    pub letter_spacing_max: Option<f64>,
    pub glyph_scaling_min: Option<f64>,
    pub glyph_scaling_desired: Option<f64>,
    pub glyph_scaling_max: Option<f64>,
    pub auto_leading: Option<f64>,
    pub single_word_justify: Option<String>,
}

/// 8 Hyphenation-dialog field values (master + 7 sub-controls).
/// `None` means the dialog field was blank (mixed selection) and
/// should not write. Phase 9.
pub(crate) struct HyphenationDialogValues {
    pub hyphenate: Option<bool>,
    pub min_word: Option<f64>,
    pub min_before: Option<f64>,
    pub min_after: Option<f64>,
    pub limit: Option<f64>,
    pub zone: Option<f64>,
    pub bias: Option<f64>,
    pub capitalized: Option<bool>,
}

/// Dispatch a named action. Tries hardcoded handlers first, then falls
/// through to the YAML actions catalog for open_dialog, dispatch, etc.
/// Returns a list of deferred effects (open_dialog, close_dialog) that
/// must be applied outside the AppState borrow.
pub(crate) fn dispatch_action(action: &str, params: &serde_json::Map<String, serde_json::Value>, st: &mut crate::workspace::app_state::AppState) -> Vec<serde_json::Value> {
    // Native intercept: artboards_panel_select with shift/meta modifier.
    // The YAML action's else-branch is a no-op stub; native apps handle
    // range-extend (shift) and toggle (meta) directly. ARTBOARDS.md
    // §Panel Selection.
    if action == "artboards_panel_select" {
        let modifier = params.get("modifier").and_then(|v| v.as_str()).unwrap_or("none");
        if modifier == "shift" || modifier == "meta" {
            if let Some(target_id) = params.get("artboard_id").and_then(|v| v.as_str()) {
                apply_artboards_panel_select_modifier(st, target_id, modifier);
            }
            return Vec::new();
        }
    }

    // Native intercept: reference-aware Layers-panel delete (warn-then-orphan).
    // The panel delete (context-menu "Delete Selection" item AND the in-panel
    // Delete/Backspace key) both dispatch the YAML action
    // delete_layer_selection, which would delete unconditionally. Deleting
    // panel-selected elements can orphan live instances exactly like the
    // primary canvas delete, so gate it with the SAME pinned predicate
    // orphaned_references(doc, deletion_paths) — here deletion_paths is the
    // PANEL selection (st.layers_panel_selection), NOT doc.selection.
    // Empty -> fall through and run the action's effects unchanged (no dialog,
    // no regression). Non-empty -> open the delete_layer_orphan_confirm dialog
    // with the orphan count and SKIP the normal effects (no mutation). The
    // dialog's Delete button runs delete_layer_orphan_confirm_ok — a DISTINCT
    // action id, so this intercept does not re-fire (no recursion). The panel
    // selection is left intact (opening the dialog does not clear it), so the
    // OK action deletes exactly the same elements.
    if action == "delete_layer_selection" {
        let orphan_count: usize = {
            let paths: Vec<Vec<usize>> = st.layers_panel_selection.clone();
            match st.tabs.get(st.active_tab) {
                Some(tab) => crate::document::dependency_index::orphaned_references(
                    tab.model.document(),
                    &paths,
                )
                .len(),
                None => 0,
            }
        };
        if orphan_count > 0 {
            let mut dlg_params = serde_json::Map::new();
            dlg_params.insert("count".to_string(), serde_json::json!(orphan_count));
            return vec![serde_json::json!({
                "open_dialog": {
                    "id": "delete_layer_orphan_confirm",
                    "params": dlg_params,
                }
            })];
        }
        // orphan_count == 0: fall through to the YAML action (delete inline).
    }

    // Native intercept: track the Concepts-panel selection (CONCEPTS.md §6).
    // `concepts_panel_select` is BOTH a generic `set_panel_state` (which drives
    // the panel UI binding via the YAML catalog) AND the source of the native
    // `st.concepts_selected` that `place_concept_instance` reads. So set the
    // native field here and DO NOT return — fall through so the YAML effect
    // still runs (the "native in addition to set_panel_state" contract).
    if action == "concepts_panel_select" {
        st.concepts_selected = params
            .get("concept_id")
            .and_then(|v| v.as_str())
            .map(String::from);
    }

    // Native intercept: Symbols panel operations (SYMBOLS.md §7, §8).
    // These mint ids by the value-in-op rule (like the make_instance arm
    // in menu_bar.rs) and call the shared symbol Controller ops, so the
    // YAML actions are `log` stubs. Each takes a single snapshot so the
    // op is one undo step. After mutating, return [] (no further YAML
    // effects). Falls through to the YAML catalog only for unrelated
    // actions.
    if action == "new_symbol"
        || action == "place_instance"
        || action == "delete_symbol_action"
        || action == "delete_symbol_orphan_confirm_ok"
        // Concepts panel native verbs (CONCEPTS.md §6-10): each is a pure-native
        // mutator whose YAML action is a `log` stub, so it runs here and returns
        // [] (no further YAML effects). `concepts_panel_select` is NOT listed: it
        // must ALSO run its generic `set_panel_state` YAML effect, so it falls
        // through to the catalog and is tracked natively by a separate intercept.
        || action == "place_concept_instance"
        || action == "set_concept_param"
        || action == "apply_concept_operation"
        || action == "promote_to_concept"
    {
        use crate::document::artboard::generate_element_id;
        use crate::document::controller::Controller;

        // Gather every existing element id (layers + master store) so the
        // freshly minted ids avoid collisions, then mint a collision-free
        // id. Mirrors the make_instance mint loop.
        fn gather_ids(
            elem: &crate::geometry::element::Element,
            out: &mut std::collections::HashSet<String>,
        ) {
            if let Some(id) = elem.common().id.as_deref() {
                out.insert(id.to_string());
            }
            if let Some(children) = elem.children() {
                for c in children {
                    gather_ids(c, out);
                }
            }
        }
        fn existing_ids(
            model: &crate::document::model::Model,
        ) -> std::collections::HashSet<String> {
            let mut set = std::collections::HashSet::new();
            let doc = model.document();
            for layer in &doc.layers {
                gather_ids(layer, &mut set);
            }
            for master in &doc.symbols {
                gather_ids(master, &mut set);
            }
            set
        }
        fn mint(existing: &std::collections::HashSet<String>) -> Option<String> {
            for _ in 0..100 {
                let c = generate_element_id(None);
                if !existing.contains(&c) {
                    return Some(c);
                }
            }
            None
        }

        match action {
            // Promote the single selected canvas element to a master.
            "new_symbol" => {
                if let Some(tab) = st.tab_mut() {
                    use crate::document::document::SelectionKind;
                    // Enabled only when exactly ONE whole element is
                    // selected (kind = All), mirroring make_instance.
                    let sel = &tab.model.document().selection;
                    let [es] = sel.as_slice() else { return Vec::new(); };
                    if es.kind != SelectionKind::All {
                        return Vec::new();
                    }
                    let path = es.path.clone();
                    let mut existing = existing_ids(&tab.model);
                    let Some(master_id) = mint(&existing) else { return Vec::new(); };
                    existing.insert(master_id.clone());
                    let Some(ref_id) = mint(&existing) else { return Vec::new(); };
                    tab.model.with_txn(|m| Controller::make_symbol(m, &path, &master_id, &ref_id));
                    // Keep the new master panel-selected so Place/Delete
                    // target it immediately. make_symbol keeps an existing
                    // id as the master key; resolve which id actually
                    // became the master from the path's instance target.
                    let resolved = tab
                        .model
                        .document()
                        .get_element(&path)
                        .and_then(|e| match e {
                            crate::geometry::element::Element::Live(
                                crate::geometry::live::LiveVariant::Reference(r),
                            ) => Some(r.target.0.clone()),
                            _ => None,
                        })
                        .unwrap_or(master_id);
                    st.symbols_selected = Some(resolved);
                }
                return Vec::new();
            }
            // Place a new instance of the panel-selected master.
            "place_instance" => {
                let Some(master_id) = st.symbols_selected.clone() else {
                    return Vec::new();
                };
                if let Some(tab) = st.tab_mut() {
                    let existing = existing_ids(&tab.model);
                    let Some(ref_id) = mint(&existing) else { return Vec::new(); };
                    tab.model.with_txn(|m| Controller::place_instance(m, &master_id, &ref_id));
                }
                return Vec::new();
            }
            // ── Concepts panel (CONCEPTS.md §6) ──
            // (`concepts_panel_select` is handled by an early intercept above so
            // it can ALSO run its generic `set_panel_state` YAML effect.)
            // Place a generated instance of the panel-selected concept, with the
            // concept's declared default params, minting a fresh id (value-in-op).
            "place_concept_instance" => {
                let Some(concept_id) = st.concepts_selected.clone() else {
                    return Vec::new();
                };
                let params = crate::interpreter::workspace::Workspace::load()
                    .and_then(|w| w.concept(&concept_id).cloned())
                    .map(|c| {
                        let mut obj = serde_json::Map::new();
                        if let Some(ps) = c.get("params").and_then(|p| p.as_array()) {
                            for p in ps {
                                if let (Some(name), Some(def)) = (
                                    p.get("name").and_then(|n| n.as_str()),
                                    p.get("default"),
                                ) {
                                    obj.insert(name.to_string(), def.clone());
                                }
                            }
                        }
                        serde_json::Value::Object(obj)
                    })
                    .unwrap_or_else(|| serde_json::Value::Object(serde_json::Map::new()));
                if let Some(tab) = st.tab_mut() {
                    let existing = existing_ids(&tab.model);
                    let Some(elem_id) = mint(&existing) else { return Vec::new(); };
                    // Route through op_apply so the placement JOURNALS as a real
                    // `place_concept_instance` op (value-in-op: concept id +
                    // resolved default params + minted id), replayable like the
                    // sibling structural verbs. with_txn brackets one undo; the
                    // arm both mutates and records.
                    let op = serde_json::json!({
                        "op": "place_concept_instance",
                        "concept_id": concept_id,
                        "params": params,
                        "elem_id": elem_id,
                    });
                    tab.model.with_txn(|m| {
                        m.name_txn("place_concept_instance");
                        crate::document::op_apply::op_apply(m, &op);
                    });
                }
                return Vec::new();
            }
            // Set one param of the single selected generated instance and let it
            // re-generate live (Slice 2). The committed field value rides as
            // param.value (event.value); param.name is the parameter.
            "set_concept_param" => {
                let Some(name) = params
                    .get("name")
                    .and_then(|v| v.as_str())
                    .map(String::from)
                else {
                    return Vec::new();
                };
                let Some(value) = params.get("value").and_then(|v| {
                    v.as_f64()
                        .or_else(|| v.as_str().and_then(|s| s.parse::<f64>().ok()))
                }) else {
                    return Vec::new();
                };
                if let Some(tab) = st.tab_mut() {
                    let path = {
                        let sel = &tab.model.document().selection;
                        if sel.len() == 1 {
                            Some(sel[0].path.clone())
                        } else {
                            None
                        }
                    };
                    if let Some(path) = path {
                        // Route through op_apply so the edit JOURNALS as a real
                        // `set_concept_param` op (value-in-op: the resolved path,
                        // param name, and committed value), replayable like the
                        // sibling property verbs.
                        let op = serde_json::json!({
                            "op": "set_concept_param",
                            "path": path,
                            "name": name,
                            "value": value,
                        });
                        tab.model.with_txn(|m| {
                            m.name_txn("set_concept_param");
                            crate::document::op_apply::op_apply(m, &op);
                        });
                    }
                }
                return Vec::new();
            }
            // Apply a named concept operation to the single selected generated
            // instance (CONCEPTS.md §9). The operation's effect is RESOLVED here,
            // at production time: look the operation up in the registry by id,
            // evaluate its `set:` expressions with the instance's CURRENT params
            // bound under `param`, and bake the resulting `changes` map into the
            // op (value-in-op). Routed through op_apply inside the one-undo
            // bracket; replay merges `changes` and never re-evaluates.
            "apply_concept_operation" => {
                let Some(op_id) = params
                    .get("op_id")
                    .and_then(|v| v.as_str())
                    .map(String::from)
                else {
                    return Vec::new();
                };
                if let Some(tab) = st.tab_mut() {
                    let path = {
                        let sel = &tab.model.document().selection;
                        if sel.len() == 1 {
                            Some(sel[0].path.clone())
                        } else {
                            None
                        }
                    };
                    let Some(path) = path else { return Vec::new(); };
                    let Some(crate::geometry::element::Element::Live(
                        crate::geometry::live::LiveVariant::Generated(ge),
                    )) = tab.model.document().get_element(&path).cloned()
                    else {
                        return Vec::new();
                    };
                    // Resolve the operation's `set:` expressions over the
                    // instance's current params → the concrete `changes` map.
                    let changes = crate::interpreter::workspace::Workspace::load()
                        .and_then(|w| w.concept(&ge.concept_id).cloned())
                        .and_then(|c| {
                            let ops = c.get("operations")?.as_array()?;
                            let operation = ops.iter().find(|o| {
                                o.get("id").and_then(|v| v.as_str()) == Some(op_id.as_str())
                            })?;
                            let set = operation.get("set")?.as_object()?;
                            let mut ctx = serde_json::Map::new();
                            ctx.insert("param".to_string(), ge.params.clone());
                            let ctx = serde_json::Value::Object(ctx);
                            let mut changes = serde_json::Map::new();
                            for (name, expr_v) in set {
                                if let Some(src) = expr_v.as_str() {
                                    if let super::expr_types::Value::Number(n) =
                                        super::expr::eval(src, &ctx)
                                    {
                                        changes.insert(name.clone(), serde_json::json!(n));
                                    }
                                }
                            }
                            Some(changes)
                        });
                    if let Some(changes) = changes {
                        if !changes.is_empty() {
                            let op = serde_json::json!({
                                "op": "apply_concept_operation",
                                "path": path,
                                "op_id": op_id,
                                "changes": serde_json::Value::Object(changes),
                            });
                            tab.model.with_txn(|m| {
                                m.name_txn("apply_concept_operation");
                                crate::document::op_apply::op_apply(m, &op);
                            });
                        }
                    }
                }
                return Vec::new();
            }
            // Promote the single selected raw shape to a Generated concept
            // instance (CONCEPTS.md §10 — the fitter / promote). Extract the
            // element's world-space vertices, try each registered concept's
            // `fitter` over `shape.points`, and on the first match split its
            // result `[params..., cx, cy, rotation]` into the concept params
            // (first K, by declared order) and a placement transform
            // (translate · rotate). Everything is baked into the op value-in-op
            // and journaled via op_apply; a no-match is a silent no-op.
            "promote_to_concept" => {
                if let Some(tab) = st.tab_mut() {
                    let path = {
                        let sel = &tab.model.document().selection;
                        if sel.len() == 1 {
                            Some(sel[0].path.clone())
                        } else {
                            None
                        }
                    };
                    let Some(path) = path else { return Vec::new(); };
                    let Some(elem) = tab.model.document().get_element(&path).cloned() else {
                        return Vec::new();
                    };
                    // Only a Polygon / Polyline carries promotable vertices in v1.
                    let raw_points: Vec<(f64, f64)> = match &elem {
                        crate::geometry::element::Element::Polygon(p) => p.points.clone(),
                        crate::geometry::element::Element::Polyline(p) => p.points.clone(),
                        _ => return Vec::new(),
                    };
                    // Bake any element transform into the points so the fitter
                    // sees WORLD space (the promoted instance re-places via its
                    // own transform).
                    let pts: Vec<(f64, f64)> = match elem.common().transform.as_ref() {
                        Some(t) => raw_points
                            .iter()
                            .map(|(x, y)| t.apply_point(*x, *y))
                            .collect(),
                        None => raw_points,
                    };
                    let points_json = serde_json::Value::Array(
                        pts.iter().map(|(x, y)| serde_json::json!([*x, *y])).collect(),
                    );
                    let mut shape = serde_json::Map::new();
                    shape.insert("points".to_string(), points_json);
                    let mut ctx = serde_json::Map::new();
                    ctx.insert("shape".to_string(), serde_json::Value::Object(shape));
                    let ctx = serde_json::Value::Object(ctx);

                    // Try each registered concept's fitter in sorted-id order (a
                    // deterministic first-match); keep the first that matches.
                    let Some(ws) = crate::interpreter::workspace::Workspace::load() else {
                        return Vec::new();
                    };
                    let Some(registry) = ws.concepts() else { return Vec::new(); };
                    let mut ids: Vec<&String> = registry.keys().collect();
                    ids.sort();
                    let mut chosen: Option<(String, serde_json::Value, f64, f64, f64)> = None;
                    for id in ids {
                        let concept = &registry[id];
                        let Some(fitter) = concept.get("fitter").and_then(|v| v.as_str()) else {
                            continue;
                        };
                        let super::expr_types::Value::List(items) = super::expr::eval(fitter, &ctx)
                        else {
                            continue; // Null / non-list ⇒ no match for this concept
                        };
                        let param_names: Vec<String> = concept
                            .get("params")
                            .and_then(|v| v.as_array())
                            .map(|ps| {
                                ps.iter()
                                    .filter_map(|p| {
                                        p.get("name").and_then(|n| n.as_str()).map(String::from)
                                    })
                                    .collect()
                            })
                            .unwrap_or_default();
                        let k = param_names.len();
                        if items.len() < k + 3 {
                            continue; // malformed fitter output (need params + cx,cy,rot)
                        }
                        let nums: Vec<f64> =
                            items.iter().map(|v| v.as_f64().unwrap_or(0.0)).collect();
                        let mut params = serde_json::Map::new();
                        for (i, name) in param_names.iter().enumerate() {
                            params.insert(name.clone(), serde_json::json!(nums[i]));
                        }
                        chosen = Some((
                            id.clone(),
                            serde_json::Value::Object(params),
                            nums[k],
                            nums[k + 1],
                            nums[k + 2],
                        ));
                        break;
                    }
                    let Some((concept_id, params, cx, cy, rot)) = chosen else {
                        return Vec::new(); // nothing matched: no-op
                    };
                    // Placement: translate(cx,cy) * rotate(rot) — rotate then translate.
                    let t = crate::geometry::element::Transform::translate(cx, cy)
                        .multiply(&crate::geometry::element::Transform::rotate(rot));
                    let op = serde_json::json!({
                        "op": "promote_to_concept",
                        "path": path,
                        "concept_id": concept_id,
                        "params": params,
                        "transform": [t.a, t.b, t.c, t.d, t.e, t.f],
                    });
                    tab.model.with_txn(|m| {
                        m.name_txn("promote_to_concept");
                        crate::document::op_apply::op_apply(m, &op);
                    });
                }
                return Vec::new();
            }
            // Delete the panel-selected master. Reference-aware: warn via
            // a confirm dialog when it still has instances.
            "delete_symbol_action" => {
                let Some(master_id) = st.symbols_selected.clone() else {
                    return Vec::new();
                };
                let usage = st
                    .tabs
                    .get(st.active_tab)
                    .map(|tab| {
                        crate::document::dependency_index::dependency_index(
                            tab.model.document(),
                        )
                        .rdeps
                        .get(&master_id)
                        .map(|v| v.len())
                        .unwrap_or(0)
                    })
                    .unwrap_or(0);
                if usage > 0 {
                    // Open the reference-aware confirm; do not mutate yet.
                    // The dialog's Delete button fires the distinct
                    // delete_symbol_orphan_confirm_ok action below.
                    let mut dlg_params = serde_json::Map::new();
                    dlg_params.insert("count".to_string(), serde_json::json!(usage));
                    return vec![serde_json::json!({
                        "open_dialog": {
                            "id": "delete_symbol_orphan_confirm",
                            "params": dlg_params,
                        }
                    })];
                }
                // No instances: delete silently.
                if let Some(tab) = st.tab_mut() {
                    tab.model.with_txn(|m| Controller::delete_symbol(m, &master_id));
                }
                st.symbols_selected = None;
                return Vec::new();
            }
            // Confirmed delete from the warn dialog.
            "delete_symbol_orphan_confirm_ok" => {
                if let Some(master_id) = st.symbols_selected.clone() {
                    if let Some(tab) = st.tab_mut() {
                        tab.model.with_txn(|m| Controller::delete_symbol(m, &master_id));
                    }
                    st.symbols_selected = None;
                }
                return vec![serde_json::json!({ "close_dialog": null })];
            }
            _ => {}
        }
    }

    // Phase 4: open_layer_options is now pure YAML. It resolves the
    // target layer via element_at(path_from_id(param.layer_id)) and
    // packs its current state as open_dialog params.
    // Fall through to YAML actions catalog
    let ws = crate::interpreter::workspace::Workspace::load();
    if let Some(ws) = ws {
        if let Some(action_def) = ws.actions().get(action) {
            if let Some(serde_json::Value::Array(effects)) = action_def.get("effects") {
                // Merge action-declared param defaults into the
                // caller's params before building the eval ctx, so
                // effects that reference `param.anchor_x` (etc.)
                // resolve to the action spec's default rather than
                // Null when the caller omits the param. Without this,
                // `dispatch_action("zoom_in", &empty, ...)` -- the
                // path that fires from Cmd+= and from the menu --
                // sees param.anchor_x == Null in doc.zoom.apply, and
                // the -1 sentinel for "anchor at viewport center"
                // never fires; the action anchors at (0, 0) instead
                // (visible to the user as the upper-left corner).
                let mut merged: serde_json::Map<String, serde_json::Value>
                    = params.clone();
                if let Some(serde_json::Value::Object(action_params))
                    = action_def.get("params")
                {
                    for (name, spec) in action_params {
                        if merged.contains_key(name) { continue; }
                        let default = match spec {
                            serde_json::Value::Object(o) => o.get("default").cloned(),
                            other => Some(other.clone()),
                        };
                        if let Some(default) = default {
                            merged.insert(name.clone(), default);
                        }
                    }
                }
                let eval_ctx = build_appstate_ctx(&merged, st);
                // OP_LOG.md §9: name the transaction with the dispatched action
                // verb so every menu/keyboard/panel-driven undoable txn is
                // legible (closes the name=None hole on the primary action
                // surface). `action` is already in scope here.
                return run_yaml_effects_named(effects, &eval_ctx, st, Some(action));
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
    run_effects_with_ctx(effects, None, st)
}

/// Resolve a `dispatch` effect's params map. String values are
/// expression strings: evaluated against ctx, with the bare-identifier
/// fallback (`{ target: artboard }` resolves to the literal string
/// `"artboard"` rather than null). Mirrors the behavior in
/// `build_mouse_event_handler`.
fn resolve_dispatch_params(
    raw: &serde_json::Map<String, serde_json::Value>,
    ctx: &serde_json::Value,
) -> serde_json::Map<String, serde_json::Value> {
    let mut resolved = serde_json::Map::new();
    for (k, v) in raw {
        let val = if let Some(expr_str) = v.as_str() {
            let result = super::expr::eval(expr_str, ctx);
            match result {
                Value::Null => {
                    // Bare identifier (no dots / operators) → string literal,
                    // matching the convention used by click-handler params
                    // (e.g. `{ target: artboard }` means the string
                    // "artboard", not the variable `artboard`).
                    let bare = !expr_str.is_empty()
                        && expr_str.chars().all(|c| c.is_alphanumeric() || c == '_');
                    if bare {
                        serde_json::Value::String(expr_str.to_string())
                    } else {
                        serde_json::Value::Null
                    }
                }
                _ => super::effects::value_to_json(&result),
            }
        } else {
            v.clone()
        };
        resolved.insert(k.clone(), val);
    }
    resolved
}

/// As [`run_effects`] but with a caller-provided eval context (e.g. the
/// foreach-aware ctx captured at click time). Anything the caller
/// passes is merged into the AppState ctx so foreach iterator
/// variables (like `swatch._index`) resolve in `select.target`,
/// `set:` value expressions, etc.
fn run_effects_with_ctx(
    effects: &[serde_json::Value],
    extra_ctx: Option<&serde_json::Value>,
    st: &mut crate::workspace::app_state::AppState,
) -> Vec<serde_json::Value> {
    let mut dialog_effects = Vec::new();
    // Build an evaluation context once per call. Set-effect values are
    // expression strings (e.g. "not state.stroke_dashed"); they must
    // be evaluated before the schema validator looks at them, or the
    // unevaluated string is passed to the Bool / Number coercer and
    // the schema rejects it as a type_mismatch. Mirrors the
    // run_yaml_effects path.
    let mut eval_ctx = build_appstate_ctx(&serde_json::Map::new(), st);
    if let Some(extra) = extra_ctx {
        if let (serde_json::Value::Object(base), serde_json::Value::Object(more))
            = (&mut eval_ctx, extra)
        {
            for (k, v) in more {
                base.insert(k.clone(), v.clone());
            }
        }
    }
    for effect in effects {
        if let Some(set_map) = effect.get("set").and_then(|v| v.as_object()) {
            let mut evaluated = serde_json::Map::new();
            for (k, v) in set_map {
                let val = if let Some(expr_str) = v.as_str() {
                    super::effects::value_to_json(&super::expr::eval(expr_str, &eval_ctx))
                } else {
                    v.clone()
                };
                evaluated.insert(k.clone(), val);
            }
            apply_set_effects(&evaluated, st);
        }
        // set_panel_state: { key, value }
        if let Some(sps) = effect.get("set_panel_state").and_then(|v| v.as_object()) {
            apply_set_panel_state(sps, st);
        }
        // dispatch: <action_name> | { action: <name>, params: { ... } }
        // Generic indirection so YAML widgets can fire actions through
        // the dispatch_action pipeline. Used by the Align panel's
        // align / distribute buttons (see workspace/panels/align.yaml).
        if let Some(disp) = effect.get("dispatch") {
            let (action_name, params) = match disp {
                serde_json::Value::String(s) => (s.clone(), serde_json::Map::new()),
                serde_json::Value::Object(m) => {
                    let name = m.get("action").and_then(|v| v.as_str())
                        .unwrap_or("").to_string();
                    let raw_params = m.get("params").and_then(|p| p.as_object())
                        .cloned().unwrap_or_default();
                    let resolved = resolve_dispatch_params(&raw_params, &eval_ctx);
                    (name, resolved)
                }
                _ => continue,
            };
            if !action_name.is_empty() {
                dialog_effects.extend(dispatch_action(&action_name, &params, st));
            }
        }
        // select: { target, list, scope, scope_value, mode } — generic
        // tile-selection effect for swatch / brush / row panels.
        if let Some(spec) = effect.get("select").and_then(|v| v.as_object()) {
            apply_select_effect(spec, &eval_ctx, st);
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
        // pop: panel.field_name
        if let Some(target) = effect.get("pop").and_then(|v| v.as_str()) {
            if target == "panel.isolation_stack" {
                st.layers_isolation_stack.pop();
            }
        }
        // Defer dialog effects — they need the dialog signal, not AppState
        if effect.get("open_dialog").is_some() || effect.get("close_dialog").is_some() {
            dialog_effects.push(effect.clone());
        }
        // if: { condition, then, else } — used by the color picker's OK
        // button to branch between `set fill_color` and `set stroke_color`
        // based on `param.target`. Recursively run the chosen branch
        // through this same function so its set / close_dialog / etc.
        // effects are honored and any deferred dialog effects bubble up.
        if let Some(if_val) = effect.get("if") {
            let (cond_expr, then_arr, else_arr) = match if_val {
                serde_json::Value::String(s) => (
                    s.clone(),
                    effect.get("then").and_then(|v| v.as_array()).cloned().unwrap_or_default(),
                    effect.get("else").and_then(|v| v.as_array()).cloned().unwrap_or_default(),
                ),
                serde_json::Value::Object(obj) => (
                    obj.get("condition").and_then(|v| v.as_str()).unwrap_or("false").to_string(),
                    obj.get("then").and_then(|v| v.as_array()).cloned().unwrap_or_default(),
                    obj.get("else").and_then(|v| v.as_array()).cloned().unwrap_or_default(),
                ),
                _ => continue,
            };
            let took_then = super::expr::eval(&cond_expr, &eval_ctx).to_bool();
            let branch = if took_then { &then_arr } else { &else_arr };
            dialog_effects.extend(run_effects_with_ctx(branch, extra_ctx, st));
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
    let mut any_gradient_key = false;
    for (key, val) in pending {
        if key.starts_with("gradient_") { any_gradient_key = true; }
        set_app_state_field(key.as_str(), &val, st);
    }
    // Phase 5 follow-up: after any gradient_* write, apply the
    // updated panel state to the selected element(s).
    if any_gradient_key {
        st.apply_gradient_panel_to_selection();
    }
}

/// Apply a `select: { target, list, scope, scope_value, mode }` effect
/// to the active panel's state. Used by tile-style panels (swatches,
/// brushes) for click-to-select semantics with optional shift / ctrl
/// modifiers.
///
/// - `target`: expression for the list-item value to add (e.g. an
///   index, a slug).
/// - `list`: panel-state field name holding the selection list.
/// - `scope`: panel-state field name holding the scope identifier
///   (e.g. selected_library). Cleared and reset to `scope_value` if
///   the click is in a different scope.
/// - `scope_value`: expression for the new scope value.
/// - `mode`: "auto" (default), "single", "toggle", "extend". `auto`
///   reads `event.shift` / `event.ctrl` / `event.meta` to choose
///   between single, toggle, and extend.
fn apply_select_effect(
    spec: &serde_json::Map<String, serde_json::Value>,
    eval_ctx: &serde_json::Value,
    st: &mut crate::workspace::app_state::AppState,
) {
    let target_expr = spec.get("target").and_then(|v| v.as_str()).unwrap_or("");
    let list_field = spec.get("list").and_then(|v| v.as_str()).unwrap_or("");
    let scope_field = spec.get("scope").and_then(|v| v.as_str()).unwrap_or("");
    let scope_value_expr = spec.get("scope_value").and_then(|v| v.as_str()).unwrap_or("");
    let mode = spec.get("mode").and_then(|v| v.as_str()).unwrap_or("auto");
    if list_field.is_empty() {
        return;
    }
    let target = super::effects::value_to_json(&super::expr::eval(target_expr, eval_ctx));
    let scope_value = if scope_value_expr.is_empty() {
        serde_json::Value::Null
    } else {
        super::effects::value_to_json(&super::expr::eval(scope_value_expr, eval_ctx))
    };

    // Read modifier state from the event ctx if mode is auto.
    let event = eval_ctx.get("event");
    let shift = event.and_then(|e| e.get("shift")).and_then(|v| v.as_bool()).unwrap_or(false);
    let ctrl_or_meta = event.and_then(|e| e.get("ctrl")).and_then(|v| v.as_bool()).unwrap_or(false)
        || event.and_then(|e| e.get("meta")).and_then(|v| v.as_bool()).unwrap_or(false);
    let effective_mode = match mode {
        "auto" => {
            if shift { "extend" }
            else if ctrl_or_meta { "toggle" }
            else { "single" }
        }
        m => m,
    };

    // Currently the only typed panel that uses select: is Swatches.
    // When other panels adopt it, add their typed-state branches
    // here (or generalize via a panel-state trait).
    let target_idx = target.as_i64();
    if list_field == "selected_swatches" {
        let sp = &mut st.swatches_panel;
        // Scope check.
        if !scope_field.is_empty() {
            let new_scope = scope_value.as_str().unwrap_or("").to_string();
            if !new_scope.is_empty() && new_scope != sp.selected_library {
                sp.selected_library = new_scope;
                if let Some(idx) = target_idx {
                    sp.selected_swatches = vec![idx];
                }
                return;
            }
        }
        let Some(idx) = target_idx else { return };
        let cur = &sp.selected_swatches;
        let new_list = match effective_mode {
            "toggle" => {
                if cur.contains(&idx) {
                    cur.iter().copied().filter(|v| v != &idx).collect()
                } else {
                    let mut l = cur.clone();
                    l.push(idx);
                    l
                }
            }
            "extend" => {
                if let Some(&anchor) = cur.first() {
                    let (lo, hi) = if anchor <= idx { (anchor, idx) } else { (idx, anchor) };
                    (lo..=hi).collect()
                } else {
                    vec![idx]
                }
            }
            _ => vec![idx],
        };
        sp.selected_swatches = new_list;
    }
}

/// Write a single validated+coerced value to the appropriate AppState field.
fn set_app_state_field(
    key: &str,
    val: &serde_json::Value,
    st: &mut crate::workspace::app_state::AppState,
) {
    use crate::geometry::element::{Color, Fill, Stroke};

    match key {
        "fill_on_top" => {
            if let Some(b) = val.as_bool() { st.fill_on_top = b; }
        }
        "active_tool" => {
            if let Some(kind) = val.as_str().and_then(parse_tool_kind) {
                if st.active_tool != kind {
                    // Route through the tool lifecycle rather than a bare
                    // field write: deactivate the previous tool (on_leave)
                    // and activate the new one (init_tool resets its state
                    // defaults, then on_enter). A bare `st.active_tool = kind`
                    // left newly-selectable YAML tools un-activated, so their
                    // tool-local state was never initialized — the source of
                    // the inconsistent state read on first repaint.
                    st.set_tool(kind);
                    if let Some(tab) = st.tab_mut() {
                        if let Some(tool) = tab.tools.get_mut(&kind) {
                            tool.activate(&mut tab.model);
                        }
                    }
                }
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
                // Propagate to canvas selection so a swatch / hex /
                // color-bar click via the YAML set_active_color
                // action updates the selected element's fill — same
                // path AppState::set_active_color uses for the
                // Color-panel slider commits.
                if !tab.model.document().selection.is_empty() {
                    tab.model.with_txn(|m| {
                        crate::document::controller::Controller::set_selection_fill(m, new_fill);
                    });
                }
            }
        }
        "stroke_color" => {
            if val.is_null() {
                st.app_default_stroke = None;
                if let Some(tab) = st.tabs.get_mut(st.active_tab) {
                    tab.model.default_stroke = None;
                    if !tab.model.document().selection.is_empty() {
                        tab.model.with_txn(|m| {
                            crate::document::controller::Controller::set_selection_stroke(m, None);
                        });
                    }
                }
            } else if let Some(color) = val.as_str().and_then(Color::from_hex) {
                let width = st.app_default_stroke.map(|s| s.width).unwrap_or(1.0);
                let new_stroke = Some(Stroke::new(color, width));
                st.app_default_stroke = new_stroke;
                if let Some(tab) = st.tabs.get_mut(st.active_tab) {
                    let tab_width = tab.model.default_stroke.map(|s| s.width).unwrap_or(width);
                    let tab_stroke = Some(Stroke::new(color, tab_width));
                    tab.model.default_stroke = tab_stroke;
                    if !tab.model.document().selection.is_empty() {
                        tab.model.with_txn(|m| {
                            crate::document::controller::Controller::set_selection_stroke(m, tab_stroke);
                        });
                    }
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
        // Gradient panel fields (Phase 5 follow-up). Each write
        // also triggers apply_gradient_panel_to_selection below.
        "gradient_type" => { if let Some(s) = val.as_str() { st.gradient_panel.gtype = s.into(); } }
        "gradient_angle" => { if let Some(n) = val.as_f64() { st.gradient_panel.angle = n; } }
        "gradient_aspect_ratio" => { if let Some(n) = val.as_f64() { st.gradient_panel.aspect_ratio = n; } }
        "gradient_method" => { if let Some(s) = val.as_str() { st.gradient_panel.method = s.into(); } }
        "gradient_dither" => { if let Some(b) = val.as_bool() { st.gradient_panel.dither = b; } }
        "gradient_stroke_sub_mode" => { if let Some(s) = val.as_str() { st.gradient_panel.stroke_sub_mode = s.into(); } }
        // Align panel fields — mirrors of AlignPanelState per
        // ALIGN.md Panel state.
        "align_to" => {
            if let Some(s) = val.as_str() {
                if let Some(mode) = crate::workspace::app_state::AlignTo::from_str(s) {
                    st.align_panel.align_to = mode;
                }
            }
        }
        "align_key_object_path" => {
            st.align_panel.key_object_path = parse_path_value(val);
        }
        "align_distribute_spacing" => {
            if let Some(n) = val.as_f64() { st.align_panel.distribute_spacing = n; }
        }
        "align_use_preview_bounds" => {
            if let Some(b) = val.as_bool() { st.align_panel.use_preview_bounds = b; }
        }
        // Boolean panel fields — mirrors of BooleanPanelState per
        // BOOLEAN.md §Boolean Options dialog.
        "boolean_precision" => {
            if let Some(n) = val.as_f64() {
                st.boolean_panel.precision = n;
                st.workspace_layout.boolean_options.precision = n;
                st.workspace_layout.bump();
            }
        }
        "boolean_remove_redundant_points" => {
            if let Some(b) = val.as_bool() {
                st.boolean_panel.remove_redundant_points = b;
                st.workspace_layout.boolean_options.remove_redundant_points = b;
                st.workspace_layout.bump();
            }
        }
        "boolean_divide_remove_unpainted" => {
            if let Some(b) = val.as_bool() {
                st.boolean_panel.divide_remove_unpainted = b;
                st.workspace_layout.boolean_options.divide_remove_unpainted = b;
                st.workspace_layout.bump();
            }
        }
        "boolean_apply_simplify_after_op" => {
            if let Some(b) = val.as_bool() {
                st.boolean_panel.apply_simplify_after_op = b;
                st.workspace_layout.boolean_options.apply_simplify_after_op = b;
                st.workspace_layout.bump();
            }
        }
        "boolean_simplify_precision" => {
            if let Some(n) = val.as_f64() {
                st.boolean_panel.simplify_precision = n;
                st.workspace_layout.boolean_options.simplify_precision = n;
                st.workspace_layout.bump();
            }
        }
        "last_boolean_op" => {
            if val.is_null() {
                st.boolean_panel.last_op = None;
            } else if let Some(s) = val.as_str() {
                st.boolean_panel.last_op = Some(s.to_string());
            }
        }
        // Workspace layout visibility fields are managed by the generic StateStore,
        // not directly by AppState. A set: on these keys has no effect here.
        "toolbar_visible" | "canvas_visible" | "dock_visible"
        | "canvas_maximized" | "dock_collapsed"
        | "active_tab" | "tab_count" => {}
        _ => {}
    }
}

/// Parse a JSON value into an `Option<ElementPath>`. Accepts the
/// `{"__path__": [...]}` marker used by the expression evaluator,
/// `null` for an absent path, and passes through arrays for
/// plain-list paths.
fn parse_path_value(val: &serde_json::Value) -> Option<crate::document::document::ElementPath> {
    if val.is_null() {
        return None;
    }
    let arr = if let Some(obj) = val.as_object() {
        obj.get("__path__")?.as_array()?
    } else if let Some(a) = val.as_array() {
        a
    } else {
        return None;
    };
    let path: Vec<usize> = arr
        .iter()
        .filter_map(|v| v.as_u64().map(|n| n as usize))
        .collect();
    Some(path)
}

/// Apply `set_panel_state: { key, value }` effects to the stroke panel state.
fn apply_set_panel_state(
    sps: &serde_json::Map<String, serde_json::Value>,
    st: &mut crate::workspace::app_state::AppState,
) {
    apply_set_panel_state_with_ctx(sps, st, None);
}

/// As `apply_set_panel_state` but threads the action's eval ctx so
/// expressions like `param.artboard_id` resolve (ARTBOARDS.md
/// actions). When `ctx` is None, only ctx-independent expressions
/// (panel / state rollups) can resolve.
// ── Properties panel field editing (decision-5 Part B.2) ──────────────────
// Pure 2x3 transform math mirroring the Python reference (effects.py).

/// AABB (x, y, w, h) of `local_bbox`'s four corners mapped through `m`.
fn prop_aabb_through(
    local_bbox: (f64, f64, f64, f64),
    m: &crate::geometry::element::Transform,
) -> (f64, f64, f64, f64) {
    let (bx, by, bw, bh) = local_bbox;
    let mut min_x = f64::INFINITY;
    let mut min_y = f64::INFINITY;
    let mut max_x = f64::NEG_INFINITY;
    let mut max_y = f64::NEG_INFINITY;
    for (px, py) in [(bx, by), (bx + bw, by), (bx + bw, by + bh), (bx, by + bh)] {
        let (x, y) = m.apply_point(px, py);
        min_x = min_x.min(x);
        min_y = min_y.min(y);
        max_x = max_x.max(x);
        max_y = max_y.max(y);
    }
    (min_x, min_y, max_x - min_x, max_y - min_y)
}

/// Scale the element's LOCAL axes by (rx, ry) (post-multiply, preserving
/// rotation) keeping the evaluated bbox top-left fixed.
fn prop_scaled_transform(
    mat: crate::geometry::element::Transform,
    local_bbox: (f64, f64, f64, f64),
    rx: f64,
    ry: f64,
) -> crate::geometry::element::Transform {
    use crate::geometry::element::Transform;
    // mat.multiply(scale) applies scale first (local), then mat — i.e. M·S.
    let scaled = mat.multiply(&Transform { a: rx, b: 0.0, c: 0.0, d: ry, e: 0.0, f: 0.0 });
    let old = prop_aabb_through(local_bbox, &mat);
    let new = prop_aabb_through(local_bbox, &scaled);
    Transform { e: scaled.e + (old.0 - new.0), f: scaled.f + (old.1 - new.1), ..scaled }
}

/// Shear angle (degrees) of a 2x3 transform, from the
/// M = R(theta) . ShearX(k) . Scale(sx, sy) decomposition:
/// k = (a*c + b*d) / det, shear = atan(k). Returns 0 for any shear-free
/// matrix (agrees with the prior rotation-only behavior) and 0 when the
/// matrix is degenerate (zero first-column length or zero determinant).
fn prop_shear_angle_deg(mat: &crate::geometry::element::Transform) -> f64 {
    let sx = (mat.a * mat.a + mat.b * mat.b).sqrt();
    let det = mat.a * mat.d - mat.b * mat.c;
    if sx == 0.0 || det == 0.0 {
        return 0.0;
    }
    let k = (mat.a * mat.c + mat.b * mat.d) / det;
    k.atan().to_degrees()
}

/// Set the element's rotation to `deg`, keeping the decomposed scale AND
/// shear (M = R . ShearX . Scale), rotated about the evaluated bbox center
/// so the object stays in place. For a shear-free input (k = 0) this is
/// byte-identical to the prior rotate-and-scale matrix.
fn prop_rotated_transform(
    mat: crate::geometry::element::Transform,
    local_bbox: (f64, f64, f64, f64),
    deg: f64,
) -> crate::geometry::element::Transform {
    use crate::geometry::element::Transform;
    let sx = (mat.a * mat.a + mat.b * mat.b).sqrt();
    let det = mat.a * mat.d - mat.b * mat.c;
    let sy = if sx != 0.0 { det / sx } else { 0.0 };
    let k = if det != 0.0 { (mat.a * mat.c + mat.b * mat.d) / det } else { 0.0 };
    let rad = deg.to_radians();
    let (cos_a, sin_a) = (rad.cos(), rad.sin());
    let rotated = Transform {
        a: sx * cos_a,
        b: sx * sin_a,
        c: sy * (k * cos_a - sin_a),
        d: sy * (k * sin_a + cos_a),
        e: mat.e,
        f: mat.f,
    };
    let old = prop_aabb_through(local_bbox, &mat);
    let new = prop_aabb_through(local_bbox, &rotated);
    let (ocx, ocy) = (old.0 + old.2 / 2.0, old.1 + old.3 / 2.0);
    let (ncx, ncy) = (new.0 + new.2 / 2.0, new.1 + new.3 / 2.0);
    Transform { e: rotated.e + (ocx - ncx), f: rotated.f + (ocy - ncy), ..rotated }
}

/// Set the element's shear angle to `deg`, keeping the decomposed rotation
/// and scale (M = R . ShearX . Scale), re-anchored about the evaluated bbox
/// center so the object stays put.
fn prop_sheared_transform(
    mat: crate::geometry::element::Transform,
    local_bbox: (f64, f64, f64, f64),
    deg: f64,
) -> crate::geometry::element::Transform {
    use crate::geometry::element::Transform;
    let sx = (mat.a * mat.a + mat.b * mat.b).sqrt();
    if sx == 0.0 {
        return mat;
    }
    let theta = mat.b.atan2(mat.a);
    let det = mat.a * mat.d - mat.b * mat.c;
    let sy = det / sx;
    let k = deg.to_radians().tan();
    let (cos_t, sin_t) = (theta.cos(), theta.sin());
    let sheared = Transform {
        a: sx * cos_t,
        b: sx * sin_t,
        c: sy * (k * cos_t - sin_t),
        d: sy * (k * sin_t + cos_t),
        e: mat.e,
        f: mat.f,
    };
    let old = prop_aabb_through(local_bbox, &mat);
    let new = prop_aabb_through(local_bbox, &sheared);
    let (ocx, ocy) = (old.0 + old.2 / 2.0, old.1 + old.3 / 2.0);
    let (ncx, ncy) = (new.0 + new.2 / 2.0, new.1 + new.3 / 2.0);
    Transform { e: sheared.e + (ocx - ncx), f: sheared.f + (ocy - ncy), ..sheared }
}

/// Document-space horizontal shear by `deg` about the pivot (px, py), as a
/// 2x3 transform. Maps (x, y) -> (x + k*(y - py), y) with k = tan(deg). Used
/// to shear a multi-selection as a group about its bbox center (pre-multiplied
/// onto each element transform).
fn prop_shear_about_pivot(deg: f64, _px: f64, py: f64) -> crate::geometry::element::Transform {
    use crate::geometry::element::Transform;
    let k = deg.to_radians().tan();
    Transform { a: 1.0, b: 0.0, c: k, d: 1.0, e: -k * py, f: 0.0 }
}

/// Apply a Properties-panel field edit to the selection (decision-5 Part B.2).
/// x/y move (any selection); w/h scale local axes (single); rotation absolute
/// about bbox center (single); opacity/blend set on every selected element.
/// The prop_* keys are display-only (build_live_panel_overrides reads them from
/// the selection), so an edit mutates the selection here; the next render
/// re-reads the new value.
pub(crate) fn apply_properties_panel_field(
    st: &mut crate::workspace::app_state::AppState,
    key: &str,
    val: &serde_json::Value,
) {
    use crate::document::controller::Controller;
    use crate::geometry::element::Transform;
    let num = || -> Option<f64> {
        if let Some(n) = val.as_f64() {
            return Some(n);
        }
        if let Some(s) = val.as_str() {
            return super::effects::value_to_json(&super::expr::eval(s, &serde_json::json!({})))
                .as_f64();
        }
        None
    };
    let constrain = st.properties_constrain;
    let Some(tab) = st.tabs.get_mut(st.active_tab) else { return };
    let doc = tab.model.document().clone();
    if doc.selection.is_empty() {
        return;
    }
    let bbox = crate::canvas::render::selection_evaluated_bounds(&doc);
    match key {
        "prop_x" => {
            if let Some(v) = num() {
                Controller::move_selection(&mut tab.model, v - bbox.0, 0.0);
            }
        }
        "prop_y" => {
            if let Some(v) = num() {
                Controller::move_selection(&mut tab.model, 0.0, v - bbox.1);
            }
        }
        "prop_opacity" => {
            if let Some(v) = num() {
                let op = (v / 100.0).clamp(0.0, 1.0);
                let mut nd = doc.clone();
                for es in &doc.selection {
                    if let Some(e) = doc.get_element(&es.path) {
                        let mut ne = e.clone();
                        ne.common_mut().opacity = op;
                        nd = nd.replace_element(&es.path, ne);
                    }
                }
                tab.model.edit_document(nd);
            }
        }
        "prop_blend" => {
            if let Some(s) = val.as_str() {
                if let Ok(bm) = serde_json::from_value::<crate::geometry::element::BlendMode>(
                    serde_json::Value::String(s.to_string()),
                ) {
                    let mut nd = doc.clone();
                    for es in &doc.selection {
                        if let Some(e) = doc.get_element(&es.path) {
                            let mut ne = e.clone();
                            ne.common_mut().mode = bm;
                            nd = nd.replace_element(&es.path, ne);
                        }
                    }
                    tab.model.edit_document(nd);
                }
            }
        }
        "prop_w" | "prop_h" | "prop_rotation" | "prop_shear" => {
            if doc.selection.len() != 1 {
                // MULTI: transform the whole selection as a group about its
                // bbox (doc-space — no single local frame). W/H scale about
                // the bbox top-left; rotation rotates rigidly about the bbox
                // center by the delta from the first element's angle; shear
                // shears horizontally about the bbox center by the same delta.
                // Each element transform is pre-multiplied by the group.
                if doc.selection.is_empty() {
                    return;
                }
                let group = match key {
                    "prop_w" => {
                        let Some(v) = num() else { return };
                        if bbox.2 <= 0.0 {
                            return;
                        }
                        let r = v / bbox.2;
                        Transform::scale(r, if constrain { r } else { 1.0 })
                            .around_point(bbox.0, bbox.1)
                    }
                    "prop_h" => {
                        let Some(v) = num() else { return };
                        if bbox.3 <= 0.0 {
                            return;
                        }
                        let r = v / bbox.3;
                        Transform::scale(if constrain { r } else { 1.0 }, r)
                            .around_point(bbox.0, bbox.1)
                    }
                    "prop_shear" => {
                        let Some(v) = num() else { return };
                        let cur = doc.selection.first()
                            .and_then(|es| doc.get_element(&es.path))
                            .and_then(|e| e.transform().copied())
                            .map(|t| prop_shear_angle_deg(&t))
                            .unwrap_or(0.0);
                        let cx = bbox.0 + bbox.2 / 2.0;
                        let cy = bbox.1 + bbox.3 / 2.0;
                        prop_shear_about_pivot(v - cur, cx, cy)
                    }
                    _ => {
                        let Some(v) = num() else { return };
                        let cur = doc.selection.first()
                            .and_then(|es| doc.get_element(&es.path))
                            .and_then(|e| e.transform().copied())
                            .map(|t| t.b.atan2(t.a).to_degrees())
                            .unwrap_or(0.0);
                        let cx = bbox.0 + bbox.2 / 2.0;
                        let cy = bbox.1 + bbox.3 / 2.0;
                        Transform::rotate(v - cur).around_point(cx, cy)
                    }
                };
                let mut nd = doc.clone();
                for es in &doc.selection {
                    if let Some(e) = doc.get_element(&es.path) {
                        let old = e.transform().copied().unwrap_or(Transform::IDENTITY);
                        let mut ne = e.clone();
                        ne.common_mut().transform = Some(group.multiply(&old));
                        nd = nd.replace_element(&es.path, ne);
                    }
                }
                tab.model.edit_document(nd);
                return;
            }
            let es = &doc.selection[0];
            let Some(e) = doc.get_element(&es.path) else { return };
            let local = e.geometric_bounds();
            let mat = e.transform().copied().unwrap_or(Transform::IDENTITY);
            let new_t = match key {
                "prop_w" => {
                    let Some(v) = num() else { return };
                    if bbox.2 <= 0.0 {
                        return;
                    }
                    let r = v / bbox.2;
                    prop_scaled_transform(mat, local, r, if constrain { r } else { 1.0 })
                }
                "prop_h" => {
                    let Some(v) = num() else { return };
                    if bbox.3 <= 0.0 {
                        return;
                    }
                    let r = v / bbox.3;
                    prop_scaled_transform(mat, local, if constrain { r } else { 1.0 }, r)
                }
                "prop_shear" => {
                    let Some(v) = num() else { return };
                    prop_sheared_transform(mat, local, v)
                }
                _ => {
                    let Some(v) = num() else { return };
                    prop_rotated_transform(mat, local, v)
                }
            };
            let mut ne = e.clone();
            ne.common_mut().transform = Some(new_t);
            let nd = doc.replace_element(&es.path, ne);
            tab.model.edit_document(nd);
        }
        _ => {}
    }
}

fn apply_set_panel_state_with_ctx(
    sps: &serde_json::Map<String, serde_json::Value>,
    st: &mut crate::workspace::app_state::AppState,
    action_ctx: Option<&serde_json::Value>,
) {
    let key = sps.get("key").and_then(|v| v.as_str()).unwrap_or("");
    // Layers panel: layers_panel_selection lives on AppState, not the
    // stroke panel. Handle here so YAML actions can clear it.
    if key == "layers_panel_selection" {
        let val = sps.get("value").unwrap_or(&serde_json::Value::Null);
        let resolved = if let Some(expr_str) = val.as_str() {
            let ctx = serde_json::json!({});
            let result = super::expr::eval(expr_str, &ctx);
            super::effects::value_to_json(&result)
        } else {
            val.clone()
        };
        // Only accept an empty list (clear); richer updates not supported yet.
        if matches!(resolved, serde_json::Value::Array(ref a) if a.is_empty()) {
            st.layers_panel_selection.clear();
        }
        return;
    }
    // Align panel keys — AlignPanelState lives on AppState, not the
    // stroke panel. Each of the four fields writes to its typed
    // slot; expression values are evaluated against the current
    // align panel state.
    if matches!(key, "align_to" | "key_object_path"
                   | "distribute_spacing_value" | "use_preview_bounds") {
        let val = sps.get("value").unwrap_or(&serde_json::Value::Null);
        let resolved = if let Some(expr_str) = val.as_str() {
            let ap = &st.align_panel;
            let panel_json = serde_json::json!({
                "align_to": ap.align_to.as_str(),
                "key_object_path": ap.key_object_path.as_ref()
                    .map(|p| serde_json::json!({"__path__": p}))
                    .unwrap_or(serde_json::Value::Null),
                "distribute_spacing_value": ap.distribute_spacing,
                "use_preview_bounds": ap.use_preview_bounds,
            });
            let bp = &st.boolean_panel;
            let state_json = serde_json::json!({
                "align_to": ap.align_to.as_str(),
                "align_key_object_path": ap.key_object_path.as_ref()
                    .map(|p| serde_json::json!({"__path__": p}))
                    .unwrap_or(serde_json::Value::Null),
                "align_distribute_spacing": ap.distribute_spacing,
                "align_use_preview_bounds": ap.use_preview_bounds,
                "boolean_precision": bp.precision,
                "boolean_remove_redundant_points": bp.remove_redundant_points,
                "boolean_divide_remove_unpainted": bp.divide_remove_unpainted,
                "boolean_apply_simplify_after_op": bp.apply_simplify_after_op,
                "boolean_simplify_precision": bp.simplify_precision,
                "last_boolean_op": bp.last_op.as_ref()
                    .map(|s| serde_json::Value::String(s.clone()))
                    .unwrap_or(serde_json::Value::Null),
            });
            let ctx = serde_json::json!({"panel": panel_json, "state": state_json});
            let result = super::expr::eval(expr_str, &ctx);
            super::effects::value_to_json(&result)
        } else {
            val.clone()
        };
        match key {
            "align_to" => {
                if let Some(s) = resolved.as_str() {
                    if let Some(mode) = crate::workspace::app_state::AlignTo::from_str(s) {
                        st.align_panel.align_to = mode;
                    }
                }
            }
            "key_object_path" => {
                st.align_panel.key_object_path = parse_path_value(&resolved);
            }
            "distribute_spacing_value" => {
                if let Some(n) = resolved.as_f64() {
                    st.align_panel.distribute_spacing = n;
                }
            }
            "use_preview_bounds" => {
                if let Some(b) = resolved.as_bool() {
                    st.align_panel.use_preview_bounds = b;
                }
            }
            _ => {}
        }
        return;
    }
    // Properties panel constrain-proportions lock (Part B polish): a sticky
    // user toggle stored on AppState (the prop_* values are computed, so there
    // is no panel store to hold it). The set_panel_state value is the
    // "not panel.prop_constrain" expr, evaluated against the current flag.
    if key == "prop_constrain" {
        let val = sps.get("value").unwrap_or(&serde_json::Value::Null);
        let resolved = if let Some(expr) = val.as_str() {
            let ctx = serde_json::json!({"panel": {"prop_constrain": st.properties_constrain}});
            super::effects::value_to_json(&super::expr::eval(expr, &ctx))
        } else {
            val.clone()
        };
        if let Some(b) = resolved.as_bool() {
            st.properties_constrain = b;
        }
        return;
    }
    // Properties panel field edits (decision-5 Part B.2) — apply to the
    // selection. prop_* keys are display-only (fed by
    // build_live_panel_overrides from the selection), so an edit mutates the
    // selection here and the next render re-reads the new value.
    if matches!(key, "prop_x" | "prop_y" | "prop_w" | "prop_h"
                   | "prop_rotation" | "prop_shear" | "prop_opacity" | "prop_blend") {
        let val = sps.get("value").cloned().unwrap_or(serde_json::Value::Null);
        apply_properties_panel_field(st, key, &val);
        return;
    }
    // Artboards panel keys (ARTBOARDS.md §Selection semantics, §Rename).
    // Stored as AppState fields, not in a dedicated panel struct.
    if matches!(
        key,
        "artboards_panel_selection"
            | "panel_selection_anchor"
            | "renaming_artboard"
            | "reference_point"
            | "rearrange_dirty"
    ) {
        let val = sps.get("value").unwrap_or(&serde_json::Value::Null);
        // Expressions are evaluated against the active_document /
        // panel / param context already bound by the caller's YAML
        // action. Here we rebuild a compact artboard-view so
        // expressions like "[param.artboard_id]" can resolve.
        let resolved = if let Some(expr_str) = val.as_str() {
            let artboards_json: Vec<serde_json::Value> = st
                .tabs
                .get(st.active_tab)
                .map(|t| {
                    t.model
                        .document()
                        .artboards
                        .iter()
                        .enumerate()
                        .map(|(i, a)| {
                            serde_json::json!({
                                "id": a.id,
                                "name": a.name,
                                "number": i + 1,
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            let active_doc = serde_json::json!({
                "artboards": artboards_json,
                "artboards_panel_selection_ids": st.artboards_panel_selection.clone(),
            });
            let panel_json = serde_json::json!({
                "artboards_panel_selection": st.artboards_panel_selection.clone(),
                "reference_point": st.artboards_reference_point.clone(),
                "rearrange_dirty": st.artboards_rearrange_dirty,
            });
            // Seed with the action's ctx if provided (so `param.*` and
            // any `let:` bindings resolve), then overlay artboard-
            // specific panel/active_document namespaces so the
            // caller's minimal bindings win.
            let mut ctx_map = match action_ctx {
                Some(serde_json::Value::Object(m)) => m.clone(),
                _ => serde_json::Map::new(),
            };
            ctx_map.insert("panel".to_string(), panel_json);
            ctx_map.insert("state".to_string(), serde_json::Value::Object(Default::default()));
            ctx_map.insert("active_document".to_string(), active_doc);
            let ctx = serde_json::Value::Object(ctx_map);
            let result = super::expr::eval(expr_str, &ctx);
            super::effects::value_to_json(&result)
        } else {
            val.clone()
        };
        apply_artboards_panel_field(st, key, &resolved);
        return;
    }
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
            "dash_align_anchors": sp.dash_align_anchors,
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
                "dash_align_anchors" |
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
        "dash_align_anchors" => J::Bool(sp.dash_align_anchors),
        _ => J::Null,
    }
}

/// Set a stroke panel field from a JSON value.
/// Write a Character-panel field from a YAML-interpreted value. Keys
/// match the panel-local state declared in `workspace/panels/
/// character.yaml`. Unknown keys are silently ignored (mirrors
/// `set_stroke_field`).
fn set_character_field(
    cp: &mut crate::workspace::app_state::CharacterPanelState,
    key: &str,
    val: &serde_json::Value,
) {
    match key {
        "font_family"          => { if let Some(s) = val.as_str() { cp.font_family = s.into(); } }
        "style_name"           => { if let Some(s) = val.as_str() { cp.style_name = s.into(); } }
        "font_size"            => { if let Some(n) = val.as_f64() { cp.font_size = n; } }
        "leading"              => { if let Some(n) = val.as_f64() { cp.leading = n; } }
        "kerning"              => {
            // Accept either a string (named mode or numeric literal) or
            // a raw number (from the legacy number_input code path).
            if let Some(s) = val.as_str() { cp.kerning = s.into(); }
            else if let Some(n) = val.as_f64() { cp.kerning = n.to_string(); }
        }
        "tracking"             => { if let Some(n) = val.as_f64() { cp.tracking = n; } }
        "vertical_scale"       => { if let Some(n) = val.as_f64() { cp.vertical_scale = n; } }
        "horizontal_scale"     => { if let Some(n) = val.as_f64() { cp.horizontal_scale = n; } }
        "baseline_shift"       => { if let Some(n) = val.as_f64() { cp.baseline_shift = n; } }
        "character_rotation"   => { if let Some(n) = val.as_f64() { cp.character_rotation = n; } }
        "all_caps"             => { if let Some(b) = val.as_bool() { cp.all_caps = b; } }
        "small_caps"           => { if let Some(b) = val.as_bool() { cp.small_caps = b; } }
        "superscript"          => { if let Some(b) = val.as_bool() { cp.superscript = b; } }
        "subscript"            => { if let Some(b) = val.as_bool() { cp.subscript = b; } }
        "underline"            => { if let Some(b) = val.as_bool() { cp.underline = b; } }
        "strikethrough"        => { if let Some(b) = val.as_bool() { cp.strikethrough = b; } }
        "language"             => { if let Some(s) = val.as_str() { cp.language = s.into(); } }
        "anti_aliasing"        => { if let Some(s) = val.as_str() { cp.anti_aliasing = s.into(); } }
        "snap_to_glyph_visible"=> { if let Some(b) = val.as_bool() { cp.snap_to_glyph_visible = b; } }
        "snap_baseline"        => { if let Some(b) = val.as_bool() { cp.snap_baseline = b; } }
        "snap_x_height"        => { if let Some(b) = val.as_bool() { cp.snap_x_height = b; } }
        "snap_glyph_bounds"    => { if let Some(b) = val.as_bool() { cp.snap_glyph_bounds = b; } }
        "snap_proximity_guides"=> { if let Some(b) = val.as_bool() { cp.snap_proximity_guides = b; } }
        "snap_angular_guides"  => { if let Some(b) = val.as_bool() { cp.snap_angular_guides = b; } }
        "snap_anchor_point"    => { if let Some(b) = val.as_bool() { cp.snap_anchor_point = b; } }
        _ => {}
    }
}

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
        "dash_align_anchors" => { if let Some(b) = val.as_bool() { sp.dash_align_anchors = b; } }
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

/// Write a single Opacity-panel field from a YAML-interpreted value. Keys
/// match the panel-local state declared in `workspace/panels/opacity.yaml`.
/// Unknown keys are silently ignored (mirrors `set_stroke_field`). The
/// `blend_mode` key accepts a snake_case BlendMode id (e.g. `"color_burn"`);
/// the `opacity` key accepts a number in the 0-100 percent range.
fn set_opacity_field(
    op: &mut crate::workspace::app_state::OpacityPanelState,
    key: &str,
    val: &serde_json::Value,
) {
    use crate::geometry::element::BlendMode;
    match key {
        "blend_mode" => {
            if let Some(s) = val.as_str() {
                if let Ok(m) = serde_json::from_value::<BlendMode>(serde_json::json!(s)) {
                    op.blend_mode = m;
                }
            }
        }
        "opacity" => {
            if let Some(n) = val.as_f64() {
                op.opacity = n.clamp(0.0, 100.0);
            }
        }
        "thumbnails_hidden" => { if let Some(b) = val.as_bool() { op.thumbnails_hidden = b; } }
        "options_shown" => { if let Some(b) = val.as_bool() { op.options_shown = b; } }
        "new_masks_clipping" => { if let Some(b) = val.as_bool() { op.new_masks_clipping = b; } }
        "new_masks_inverted" => { if let Some(b) = val.as_bool() { op.new_masks_inverted = b; } }
        _ => {}
    }
}

/// Update a single paragraph panel field. Mutual exclusion side
/// effects: writing one alignment radio clears the other six;
/// writing a non-empty bullets value clears numbered_list (and vice
/// versa). Phase 4 setter; called from widget onchange handlers and
/// the toggle_hanging_punctuation action.
fn set_paragraph_field(
    pp: &mut crate::workspace::app_state::ParagraphPanelState,
    key: &str,
    val: &serde_json::Value,
) {
    fn clear_aligns(pp: &mut crate::workspace::app_state::ParagraphPanelState) {
        pp.align_left = false;
        pp.align_center = false;
        pp.align_right = false;
        pp.justify_left = false;
        pp.justify_center = false;
        pp.justify_right = false;
        pp.justify_all = false;
    }
    match key {
        "align_left"          => { if let Some(b) = val.as_bool() { if b { clear_aligns(pp); pp.align_left = true; } } }
        "align_center"        => { if let Some(b) = val.as_bool() { if b { clear_aligns(pp); pp.align_center = true; } } }
        "align_right"         => { if let Some(b) = val.as_bool() { if b { clear_aligns(pp); pp.align_right = true; } } }
        "justify_left"        => { if let Some(b) = val.as_bool() { if b { clear_aligns(pp); pp.justify_left = true; } } }
        "justify_center"      => { if let Some(b) = val.as_bool() { if b { clear_aligns(pp); pp.justify_center = true; } } }
        "justify_right"       => { if let Some(b) = val.as_bool() { if b { clear_aligns(pp); pp.justify_right = true; } } }
        "justify_all"         => { if let Some(b) = val.as_bool() { if b { clear_aligns(pp); pp.justify_all = true; } } }
        "bullets"             => {
            if let Some(s) = val.as_str() {
                pp.bullets = s.into();
                if !s.is_empty() { pp.numbered_list.clear(); }
            }
        }
        "numbered_list"       => {
            if let Some(s) = val.as_str() {
                pp.numbered_list = s.into();
                if !s.is_empty() { pp.bullets.clear(); }
            }
        }
        "left_indent"         => { if let Some(n) = val.as_f64() { pp.left_indent = n; } }
        "right_indent"        => { if let Some(n) = val.as_f64() { pp.right_indent = n; } }
        "first_line_indent"   => { if let Some(n) = val.as_f64() { pp.first_line_indent = n; } }
        "space_before"        => { if let Some(n) = val.as_f64() { pp.space_before = n; } }
        "space_after"         => { if let Some(n) = val.as_f64() { pp.space_after = n; } }
        "hyphenate"           => { if let Some(b) = val.as_bool() { pp.hyphenate = b; } }
        "hanging_punctuation" => { if let Some(b) = val.as_bool() { pp.hanging_punctuation = b; } }
        _ => {}
    }
}

/// Build an expression evaluation context from AppState + action params.
/// Build the outer scope to pass into `dialog_view::open_dialog_with_outer`
/// and `DialogState::eval_context_with_outer`. Exposes the panel +
/// active_document namespaces that dialog init / get / set
/// expressions may reference (most notably the Artboard Options
/// Dialogue's x_rp / y_rp reference-point transforms).
pub(crate) fn build_dialog_outer_scope(
    st: &crate::workspace::app_state::AppState,
) -> serde_json::Value {
    // Panel scope: only the artboards panel fields are exposed today
    // since that's the only dialog with panel-referencing init /
    // prop expressions. Extend as new dialogs need it.
    let panel = serde_json::json!({
        "reference_point": st.artboards_reference_point.clone(),
        "artboards_panel_selection": st.artboards_panel_selection.clone(),
    });
    serde_json::json!({
        "panel": panel,
        "active_document": build_active_document_view(st),
    })
}

fn build_appstate_ctx(
    params: &serde_json::Map<String, serde_json::Value>,
    st: &crate::workspace::app_state::AppState,
) -> serde_json::Value {
    let tool_name = st.active_tool.panel_state_name();
    let fill_color = match st.app_default_fill {
        None => serde_json::Value::Null,
        Some(f) => serde_json::Value::String(format!("#{}", f.color.to_hex())),
    };
    let stroke_color = match st.app_default_stroke {
        None => serde_json::Value::Null,
        Some(s) => serde_json::Value::String(format!("#{}", s.color.to_hex())),
    };
    // Expose every stroke-panel field that appears in YAML state.*
    // expressions (workspace/panels/stroke.yaml's state map at the
    // bottom of the file enumerates them). Without these,
    // "not state.stroke_dashed" evaluates against a null and toggling
    // is impossible. See AppState::stroke_panel for the canonical
    // source of truth on these values.
    let sp = &st.stroke_panel;
    let stroke_width = st.app_default_stroke.as_ref()
        .map(|s| s.width).unwrap_or(1.0);
    let state = serde_json::json!({
        "fill_on_top": st.fill_on_top,
        "fill_color": fill_color,
        "stroke_color": stroke_color,
        "active_tool": tool_name,
        // Tab bookkeeping — read by menu `enabled_when` (e.g.
        // "state.tab_count > 0") and the new_document action's
        // active_tab assignment. Without these the expressions evaluate
        // against null and silently disable items / no-op.
        "tab_count": st.tabs.len(),
        "active_tab": st.active_tab,
        "stroke_width": stroke_width,
        "stroke_cap": sp.cap,
        "stroke_join": sp.join,
        "stroke_miter_limit": sp.miter_limit,
        "stroke_align": sp.align,
        "stroke_dashed": sp.dashed,
        "stroke_dash_1": sp.dash_1,
        "stroke_gap_1": sp.gap_1,
        "stroke_dash_2": sp.dash_2,
        "stroke_gap_2": sp.gap_2,
        "stroke_dash_3": sp.dash_3,
        "stroke_gap_3": sp.gap_3,
        "stroke_dash_align_anchors": sp.dash_align_anchors,
        "stroke_start_arrowhead": sp.start_arrowhead,
        "stroke_end_arrowhead": sp.end_arrowhead,
        "stroke_start_arrowhead_scale": sp.start_arrowhead_scale,
        "stroke_end_arrowhead_scale": sp.end_arrowhead_scale,
        "stroke_link_arrowhead_scale": sp.link_arrowhead_scale,
        "stroke_arrow_align": sp.arrow_align,
        "stroke_profile": sp.profile,
        "stroke_profile_flipped": sp.profile_flipped,
    });
    // Panel namespace: expose layers_panel_selection as a list of path
    // markers so YAML actions (delete/duplicate_layer_selection) can
    // iterate it.
    let sel_paths: Vec<serde_json::Value> = st.layers_panel_selection.iter()
        .map(|p| serde_json::json!({
            "__path__": p.iter().map(|&i| i as u64).collect::<Vec<_>>()
        }))
        .collect();
    let panel = serde_json::json!({
        "layers_panel_selection": sel_paths,
        // Symbols panel: the panel-selected master id (or null). Needed so
        // the symbols actions' enabled_when ("panel.selected_symbol != null")
        // resolves when fired from the panel menu / dispatch path.
        "selected_symbol": st.symbols_selected.clone()
            .map(serde_json::Value::String)
            .unwrap_or(serde_json::Value::Null),
    });
    let mut ctx = serde_json::Map::new();
    ctx.insert("state".to_string(), state);
    ctx.insert("panel".to_string(), panel);
    ctx.insert("active_document".to_string(), build_active_document_view(st));
    // Expose preferences.* so YAML expressions like
    // preferences.viewport.zoom_step resolve against the workspace
    // YAML defaults. Used by the View actions (zoom_in, fit_*, etc.)
    // and the Zoom tool's gesture handlers.
    let prefs = crate::interpreter::workspace::Workspace::load()
        .and_then(|ws| ws.data().get("preferences").cloned())
        .unwrap_or(serde_json::Value::Null);
    ctx.insert("preferences".to_string(), prefs);
    if !params.is_empty() {
        ctx.insert("param".to_string(), serde_json::Value::Object(params.clone()));
    }
    serde_json::Value::Object(ctx)
}

/// Build the active_document ctx namespace (Phase 3 §7.2).
/// Exposes top_level_layers (list of dicts with path, name, common, ...)
/// and top_level_layer_paths (list of paths). Also computed properties
/// used by new_layer: next_layer_name, new_layer_insert_index.
/// Build the ``marks_and_bleed`` nested object exposed under
/// ``active_document.print_preferences``. Split out so the parent
/// json! macro stays under serde's recursion limit.
fn marks_and_bleed_view(
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

fn output_view(o: &crate::document::print_preferences::Output) -> serde_json::Value {
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

fn advanced_view(a: &crate::document::print_preferences::Advanced) -> serde_json::Value {
    serde_json::json!({
        "print_as_bitmap": a.print_as_bitmap,
        "overprint_flattener_preset": crate::document::print_preferences::flattener_preset_str(&a.overprint_flattener_preset),
    })
}

fn color_management_view(c: &crate::document::print_preferences::ColorManagement) -> serde_json::Value {
    serde_json::json!({
        "document_profile": c.document_profile,
        "color_handling": crate::document::print_preferences::color_handling_str(&c.color_handling),
        "printer_profile": c.printer_profile,
        "rendering_intent": crate::document::print_preferences::rendering_intent_str(&c.rendering_intent),
        "preserve_rgb_numbers": c.preserve_rgb_numbers,
    })
}

fn graphics_view(g: &crate::document::print_preferences::Graphics) -> serde_json::Value {
    serde_json::json!({
        "flatness": g.flatness,
        "font_download": crate::document::print_preferences::font_download_str(&g.font_download),
        "postscript_level": crate::document::print_preferences::postscript_level_str(&g.postscript_level),
        "data_format": crate::document::print_preferences::data_format_str(&g.data_format),
        "compatible_gradient_printing": g.compatible_gradient_printing,
        "raster_effects_resolution": g.raster_effects_resolution,
    })
}

/// Build `active_document.selected_concept` for a selected `Generated` instance:
/// the concept's display name + its declared param schema (name/min/max) merged
/// with the instance's current values (CONCEPTS.md §6.4, Slice 2). Null if the
/// concept is not registered.
fn build_selected_concept_view(
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
            if !super::expr::eval(check, &ctx).to_bool() {
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

pub(crate) fn build_active_document_view(
    st: &crate::workspace::app_state::AppState,
) -> serde_json::Value {
    use crate::geometry::element::{Element, Visibility};
    use std::collections::HashSet;
    let Some(tab) = st.tabs.get(st.active_tab) else {
        let mut empty = serde_json::json!({
            "top_level_layers": [],
            "top_level_layer_paths": [],
            "next_layer_name": "Layer 1",
            "new_layer_insert_index": 0,
            "layers_panel_selection_count": 0,
            "has_selection": false,
            "selection_count": 0,
            "selection_has_compound_shape": false,
            "element_selection": [],
            "artboards": [],
            "artboard_options": {
                "fade_region_outside_artboard": true,
                "update_while_dragging": true,
            },
            "document_setup": {
                "bleed_top": 0.0,
                "bleed_right": 0.0,
                "bleed_bottom": 0.0,
                "bleed_left": 0.0,
                "bleed_uniform": true,
                "show_images_outline": false,
                "highlight_substituted_glyphs": false,
                "grid_size": 72.0,
                "grid_color": "#cccccc",
                "paper_color": "#ffffff",
                "simulate_colored_paper": false,
                "transparency_flattener_preset": "medium_resolution",
                "discard_white_overprint": false,
            },
            "print_preferences": {
                "preset_name": "[Default]",
                "printer_name": serde_json::Value::Null,
                "copies": 1,
                "collate": false,
                "reverse_order": false,
                "artboard_range_mode": "all",
                "artboard_range": "",
                "ignore_artboards": false,
                "skip_blank_artboards": false,
                "media_size": "defined_by_driver",
                "media_width": 612.0,
                "media_height": 792.0,
                "orientation": "portrait",
                "auto_rotate": true,
                "transverse": false,
                "print_layers": "visible_printable",
                "placement_x": 0.0,
                "placement_y": 0.0,
                "scaling_mode": "do_not_scale",
                "custom_scale": 100.0,
                "tile_overlap_h": 0.0,
                "tile_overlap_v": 0.0,
                "tile_range": "",
                "marks_and_bleed": marks_and_bleed_view(
                    &crate::document::print_preferences::MarksAndBleed::default(),
                ),
                "output": output_view(
                    &crate::document::print_preferences::Output::default(),
                ),
                "graphics": graphics_view(
                    &crate::document::print_preferences::Graphics::default(),
                ),
                "color_management": color_management_view(
                    &crate::document::print_preferences::ColorManagement::default(),
                ),
                "advanced": advanced_view(
                    &crate::document::print_preferences::Advanced::default(),
                ),
            },
            "artboards_count": 0,
            "next_artboard_name": "Artboard 1",
            "current_artboard_id": serde_json::Value::Null,
            "current_artboard": {},
            "artboards_panel_selection_ids": st.artboards_panel_selection.clone(),
            "artboards_panel_anchor": st.artboards_panel_anchor.clone()
                .map(serde_json::Value::String)
                .unwrap_or(serde_json::Value::Null),
            "zoom_level": 1.0,
            "view_offset_x": 0.0,
            "view_offset_y": 0.0,
        });
        // Inserted outside the json! literal to keep the macro under the
        // recursion limit (the no-tab object is already at the ceiling).
        if let serde_json::Value::Object(m) = &mut empty {
            m.insert("symbols".to_string(), serde_json::json!([]));
        }
        return empty;
    };
    let mut top_level_layers = Vec::new();
    let mut top_level_layer_paths = Vec::new();
    let mut layer_names: HashSet<String> = HashSet::new();
    for (i, elem) in tab.model.document().layers.iter().enumerate() {
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
    let top_level_selected: Vec<usize> = st.layers_panel_selection.iter()
        .filter_map(|p| if p.len() == 1 { Some(p[0]) } else { None })
        .collect();
    let new_layer_insert_index = match top_level_selected.iter().min() {
        Some(&i) => i + 1,
        None => tab.model.document().layers.len(),
    };
    // Canvas selection rollup (Phase 0a, Align panel): scalar/boolean
    // plus path markers for downstream predicates and list operations.
    let canvas_selection = &tab.model.document().selection;
    let element_selection: Vec<serde_json::Value> = canvas_selection
        .iter()
        .map(|es| {
            let path_ints: Vec<u64> = es.path.iter().map(|&i| i as u64).collect();
            serde_json::json!({"__path__": path_ints})
        })
        .collect();
    // True if any selected element is an Element::Live (currently
    // only compound shapes). Consumed by the Boolean panel's Expand
    // button and Release/Expand Compound Shape menu items.
    let selection_has_compound_shape = canvas_selection
        .iter()
        .any(|es| {
            matches!(
                tab.model.document().get_element(&es.path),
                Some(Element::Live(_))
            )
        });
    // Concepts panel (Slice 2): when exactly one generated concept instance is
    // selected, expose its concept id + param schema merged with current values
    // so the panel switches to PARAMS mode; null otherwise.
    let selected_concept: serde_json::Value = if canvas_selection.len() == 1 {
        match tab.model.document().get_element(&canvas_selection[0].path) {
            Some(Element::Live(crate::geometry::live::LiveVariant::Generated(ge))) => {
                build_selected_concept_view(&ge.concept_id, &ge.params)
            }
            _ => serde_json::Value::Null,
        }
    } else {
        serde_json::Value::Null
    };
    // Artboard view (ARTBOARDS.md §Artboard data model).
    let doc = tab.model.document();
    let artboards_json: Vec<serde_json::Value> = doc
        .artboards
        .iter()
        .enumerate()
        .map(|(i, a)| {
            serde_json::json!({
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
        })
        .collect();
    // current_artboard: topmost panel-selected, else first.
    let sel_set: std::collections::HashSet<&str> = st
        .artboards_panel_selection
        .iter()
        .map(|s| s.as_str())
        .collect();
    let current: Option<&crate::document::artboard::Artboard> = doc
        .artboards
        .iter()
        .find(|a| sel_set.contains(a.id.as_str()))
        .or_else(|| doc.artboards.first());
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
    // Symbols view (SYMBOLS.md §8). One row per master in the off-canvas
    // store. `name` is the master's common.name, falling back to a
    // positional "Symbol N" label so every row shows something readable.
    // `usage_count` is the number of live instances of the master — the
    // length of its reverse-dependency list (rdeps) in the dependency
    // index, the same signal that gates the reference-aware delete.
    let dep_index = crate::document::dependency_index::dependency_index(&doc);
    let symbols_json: Vec<serde_json::Value> = doc
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
            serde_json::json!({
                "id": id,
                "name": name,
                "usage_count": usage_count,
            })
        })
        .collect();
    let mut view = serde_json::json!({
        "top_level_layers": top_level_layers,
        "top_level_layer_paths": top_level_layer_paths,
        "next_layer_name": next_layer_name,
        "new_layer_insert_index": new_layer_insert_index,
        "layers_panel_selection_count": st.layers_panel_selection.len(),
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
        "artboards_panel_selection_ids": st.artboards_panel_selection.clone(),
        "artboards_panel_anchor": st.artboards_panel_anchor.clone()
            .map(serde_json::Value::String)
            .unwrap_or(serde_json::Value::Null),
        "zoom_level": tab.model.zoom_level,
        "view_offset_x": tab.model.view_offset_x,
        "view_offset_y": tab.model.view_offset_y,
    });
    // Inserted after the json! literal: the populated active-document
    // object is already at the macro recursion ceiling, so the symbols
    // list is attached here (SYMBOLS.md §8).
    if let serde_json::Value::Object(m) = &mut view {
        m.insert("symbols".to_string(), serde_json::Value::Array(symbols_json));
        // Concepts panel Slice 2: attached here too (macro recursion ceiling).
        m.insert("selected_concept".to_string(), selected_concept);
    }
    view
}

/// Execute one YAML effect against AppState, returning any deferred dialog effects.
/// Run a list of YAML effects with lexical scope threading (Phase 3).
/// Each `let:` extends scope for subsequent siblings in the same list;
/// nested lists (then/else/do) get their own scope that doesn't leak.
fn run_yaml_effects(
    effects: &[serde_json::Value],
    ctx_in: &serde_json::Value,
    st: &mut crate::workspace::app_state::AppState,
) -> Vec<serde_json::Value> {
    run_yaml_effects_named(effects, ctx_in, st, None)
}

/// `run_yaml_effects` with the owning action's name threaded in (OP_LOG.md §9).
/// The batch owner stamps `name_txn(action)` just before `commit_txn` so every
/// menu/keyboard/panel-dispatched undoable transaction is named — closing the
/// `name=None` legibility hole for the primary action surface (not just the
/// tool-gesture dispatches). Re-entrant calls (foreach/branch bodies) pass
/// `None` so only the owner names, matching the effects.rs nested-call rule.
fn run_yaml_effects_named(
    effects: &[serde_json::Value],
    ctx_in: &serde_json::Value,
    st: &mut crate::workspace::app_state::AppState,
    action_name: Option<&str>,
) -> Vec<serde_json::Value> {
    let mut scope = ctx_in.clone();
    let mut deferred = Vec::new();
    // OP_LOG.md Increment 1, sub-step 6: a YAML action opens its undo
    // transaction via the `snapshot` effect; this loop owns it only if none was
    // open when it started (reentrancy-safe — foreach/branch bodies re-enter
    // run_yaml_effects, and doc.* effects delegate to effects.rs::run_effects
    // which has the same ownership rule). The owner commits once at the end so
    // the whole action is one undo step. commit_txn is a no-op if nothing opened.
    let owns_txn = st.tabs.get(st.active_tab).map_or(false, |t| !t.model.in_txn());
    for eff in effects {
        deferred.extend(run_yaml_effect(eff, &mut scope, st));
    }
    if owns_txn {
        if let Some(t) = st.tabs.get_mut(st.active_tab) {
            // Name every production transaction with its action verb before
            // committing (OP_LOG.md §9). `name_txn` is a no-op if nothing opened
            // a txn this batch, so a no-edit action stays anonymous.
            if let Some(action) = action_name {
                t.model.name_txn(action);
            }
            t.model.commit_txn();
        }
    }
    deferred
}

fn run_yaml_effect(
    eff: &serde_json::Value,
    eval_ctx: &mut serde_json::Value,
    st: &mut crate::workspace::app_state::AppState,
) -> Vec<serde_json::Value> {
    let mut deferred = Vec::new();

    // Extract optional `as: <name>` return-binding (PHASE3 §5.5). Effects
    // that return a value (doc.delete_at, doc.clone_at) store it in ctx
    // under this name; subsequent effects can reference it by identifier.
    let as_name: Option<String> = eff.get("as")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    // Bare-string effects: `- snapshot` → {snapshot: null}
    if let Some(name) = eff.as_str() {
        if name == "snapshot" {
            if let Some(tab) = st.tabs.get_mut(st.active_tab) {
                tab.model.begin_txn();
            }
        } else if name == "close_dialog" {
            // Dialog effects are applied outside the AppState borrow.
            deferred.push(serde_json::json!({"close_dialog": null}));
        }
        return deferred;
    }

    // let: { name: expr, ... } — PHASE3 §5.1
    if let Some(bindings) = eff.get("let").and_then(|v| v.as_object()) {
        for (name, expr_v) in bindings {
            let val_json = if let Some(expr_str) = expr_v.as_str() {
                let val = super::expr::eval(expr_str, &*eval_ctx);
                super::effects::value_to_json(&val)
            } else {
                expr_v.clone()
            };
            if let Some(map) = eval_ctx.as_object_mut() {
                map.insert(name.clone(), val_json);
            }
        }
        return deferred;
    }

    // snapshot — PHASE3 §5.2
    if eff.get("snapshot").is_some() {
        if let Some(tab) = st.tabs.get_mut(st.active_tab) {
            tab.model.begin_txn();
        }
        return deferred;
    }

    // reset_paragraph_panel — Phase 4. Restores defaults across all
    // Paragraph panel controls and removes the corresponding paragraph
    // attrs from every wrapper tspan in the selection (identity rule).
    if eff.get("reset_paragraph_panel").is_some() {
        st.reset_paragraph_panel();
        return deferred;
    }

    // reset_align_panel — Phase 2 Align implementation. Restores
    // defaults across the four AlignPanelState fields (the panel is
    // otherwise stateless — no selection-apply step needed).
    if eff.get("reset_align_panel").is_some() {
        st.reset_align_panel();
        return deferred;
    }

    // Align panel operations — Phase 2 Align implementation. Each of
    // the 14 Align / Distribute / Distribute Spacing buttons fires a
    // same-named platform effect; the handler builds an
    // AlignReference from panel state and applies the algorithm's
    // translations to the selection. See ALIGN.md and
    // algorithms/align.rs.
    for &op in &[
        "align_left", "align_horizontal_center", "align_right",
        "align_top", "align_vertical_center", "align_bottom",
        "distribute_left", "distribute_horizontal_center", "distribute_right",
        "distribute_top", "distribute_vertical_center", "distribute_bottom",
        "distribute_vertical_spacing", "distribute_horizontal_spacing",
    ] {
        if eff.get(op).is_some() {
            st.apply_align_operation(op);
            return deferred;
        }
    }

    // Boolean panel — compound-shape menu actions. See BOOLEAN.md
    // §Panel actions.
    if eff.get("make_compound_shape").is_some() {
        st.apply_make_compound_shape();
        return deferred;
    }
    if eff.get("release_compound_shape").is_some() {
        st.apply_release_compound_shape();
        return deferred;
    }
    if eff.get("expand_compound_shape").is_some() {
        st.apply_expand_compound_shape();
        return deferred;
    }

    // Boolean panel — destructive operations. All nine are wired.
    for &op in &[
        "union", "subtract_front", "intersection", "exclude",
        "divide", "trim", "merge", "crop", "subtract_back",
    ] {
        let key = format!("boolean_{op}");
        if eff.get(&key).is_some() {
            st.apply_boolean_operation(op);
            return deferred;
        }
    }

    // Boolean panel — compound-creating variants (Alt+click on the
    // four Shape Mode buttons).
    for &op in &["union", "subtract_front", "intersection", "exclude"] {
        let key = format!("boolean_{op}_compound");
        if eff.get(&key).is_some() {
            st.apply_compound_creation(op);
            return deferred;
        }
    }

    // Boolean panel — Repeat Boolean Operation. Reads
    // boolean_panel.last_op (populated by every destructive and
    // compound-creating action) and re-dispatches. No-op when
    // last_op is None.
    if eff.get("repeat_boolean_operation").is_some() {
        st.apply_repeat_boolean_operation();
        return deferred;
    }

    // Boolean panel — Reset Panel. Clears last_op (makes Repeat a
    // no-op until the next op click). Boolean Options values are
    // left alone; the dialog's own Defaults button resets those.
    if eff.get("reset_boolean_panel").is_some() {
        st.reset_boolean_panel();
        return deferred;
    }

    // toggle_paragraph_field: <field_name> — Phase 4. Flips the named
    // bool on the typed paragraph panel state, then re-applies. Used by
    // toggle_hanging_punctuation. Syncs from selection first so other
    // panel fields don't overwrite the wrapper with stale defaults.
    if let Some(name) = eff.get("toggle_paragraph_field").and_then(|v| v.as_str()) {
        st.sync_paragraph_panel_from_selection();
        let pp = &mut st.paragraph_panel;
        let cur = match name {
            "hyphenate" => pp.hyphenate,
            "hanging_punctuation" => pp.hanging_punctuation,
            _ => return deferred,
        };
        set_paragraph_field(pp, name, &serde_json::json!(!cur));
        st.apply_paragraph_panel_to_selection();
        return deferred;
    }


    // foreach: { source, as } do: [...] — PHASE3 §5.3
    if let Some(spec) = eff.get("foreach").and_then(|v| v.as_object()) {
        let source_expr = spec.get("source").and_then(|v| v.as_str()).unwrap_or("");
        let var_name = spec.get("as").and_then(|v| v.as_str()).unwrap_or("item");
        let body = eff.get("do")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        // Evaluate source in current scope
        let items_val = super::expr::eval(source_expr, &*eval_ctx);
        let items = match items_val {
            super::expr_types::Value::List(arr) => arr,
            _ => return deferred,
        };
        for (i, item) in items.iter().enumerate() {
            // Fresh iteration scope inheriting from outer
            let mut iter_ctx = eval_ctx.clone();
            if let Some(m) = iter_ctx.as_object_mut() {
                m.insert(var_name.to_string(), item.clone());
                m.insert("_index".to_string(), serde_json::json!(i));
            }
            deferred.extend(run_yaml_effects(&body, &iter_ctx, st));
        }
        return deferred;
    }

    // ── Artboard effects (ARTBOARDS.md) ─────────────────────────
    //
    // All seven mirror the Python doc.* handlers in
    // workspace_interpreter/effects.py. They clone the document,
    // mutate the artboards list via the Artboard module helpers,
    // then commit via tab.model.set_document() so undo/redo
    // snapshots record the change. Effects assume snapshot has
    // already been called upstream in the action's effects list.

    // doc.create_artboard: { [field]: expr, ... }  — OP_LOG.md §9 Phase P3.
    // Appends a new artboard. Optional field overrides (x, y, width, height,
    // fill, show_*, video_ruler_pixel_aspect_ratio, name) are evaluated and
    // applied on top of the default.
    //
    // VALUE-IN-OP id strategy: the id is MINTED HERE (the entropic collision-retry
    // mint — production captures the live id ONCE) and the default name is derived
    // HERE; then the MINTED id is written into the op as a LITERAL (`id`) alongside
    // the RESOLVED field overrides (a flat object, including the derived name when
    // no override supplies one), and the op routes through the SHARED `op_apply`
    // dispatcher (which calls `apply_create_artboard`). Replay reads the recorded
    // id + resolved fields VERBATIM and NEVER re-mints / NEVER taps entropy, so the
    // journal replays deterministically (checkpoint_equivalence). targets carry the
    // new artboard id.
    if let Some(spec) = eff.get("doc.create_artboard").and_then(|v| v.as_object()) {
        use crate::document::artboard::{generate_artboard_id, next_artboard_name};
        let Some(tab) = st.tabs.get_mut(st.active_tab) else { return deferred; };
        let doc = tab.model.document();
        // Collision-retry id mint (production entropy). This is the ONLY mint;
        // op_apply replays the recorded literal and never mints.
        let existing_ids: std::collections::HashSet<String> =
            doc.artboards.iter().map(|a| a.id.clone()).collect();
        let mut id = String::new();
        for _ in 0..100 {
            let c = generate_artboard_id(None);
            if !existing_ids.contains(&c) { id = c; break; }
        }
        if id.is_empty() { return deferred; }
        // Derive the default name HERE (a function of the live doc); a `name`
        // override in `spec` replaces it below. Build a RESOLVED flat `fields`
        // object: each YAML expr is evaluated to a literal before journaling
        // (replay has no eval context).
        let mut fields = serde_json::Map::new();
        fields.insert(
            "name".to_string(),
            serde_json::json!(next_artboard_name(&doc.artboards)),
        );
        for (k, v) in spec {
            let val = if let Some(s) = v.as_str() {
                super::expr::eval(s, &*eval_ctx)
            } else {
                super::expr_types::Value::from_json(v)
            };
            fields.insert(k.clone(), super::effects::value_to_json(&val));
        }
        let op = serde_json::json!({
            "op": "create_artboard",
            "id": id.clone(),
            "fields": serde_json::Value::Object(fields),
        });
        crate::document::op_apply::op_apply(&mut tab.model, &op);
        if let Some(as_n) = as_name {
            if let Some(map) = eval_ctx.as_object_mut() {
                map.insert(as_n, serde_json::json!(id));
            }
        }
        return deferred;
    }

    // doc.delete_artboard_by_id: id_expr  — OP_LOG.md §9 Phase P2.
    // Resolves the id expr to a literal, then routes through the SHARED
    // `op_apply` dispatcher so the deletion JOURNALS as a real op (replays
    // byte-identically; targets carry the deleted id). The transaction is
    // already owned/named/committed by `run_yaml_effects_named`.
    if let Some(id_expr_v) = eff.get("doc.delete_artboard_by_id") {
        let id_expr = id_expr_v.as_str().unwrap_or("");
        let val = super::expr::eval(id_expr, &*eval_ctx);
        let target = match val {
            super::expr_types::Value::Str(s) => s,
            _ => return deferred,
        };
        let op = serde_json::json!({ "op": "delete_artboard_by_id", "id": target });
        if let Some(tab) = st.tabs.get_mut(st.active_tab) {
            crate::document::op_apply::op_apply(&mut tab.model, &op);
        }
        return deferred;
    }

    // doc.duplicate_artboard: id_expr | { id, offset_x?, offset_y? }
    //   — OP_LOG.md §9 Phase P3.
    // Clones the source artboard (by resolved id) and appends it offset by
    // (offset_x, offset_y) (default 20.0 each). VALUE-IN-OP id strategy: the
    // new id is MINTED HERE (entropic collision-retry — production captures the
    // live id ONCE) and the new name is DERIVED HERE via next_artboard_name; both
    // are then written into the op as LITERALS (`new_id` / `name`) alongside the
    // resolved source id + offsets, and the op routes through the SHARED `op_apply`
    // dispatcher (which calls `apply_duplicate_artboard`). Replay reads the
    // recorded new_id + name + offsets VERBATIM and NEVER re-mints / NEVER
    // re-derives the name / NEVER taps entropy (checkpoint_equivalence). A missing
    // source is a no-op that journals nothing. targets carry the new id.
    if let Some(eff_val) = eff.get("doc.duplicate_artboard") {
        use crate::document::artboard::{generate_artboard_id, next_artboard_name};
        let (id_expr, ox_expr, oy_expr) = match eff_val {
            serde_json::Value::String(s) => (s.clone(), None, None),
            serde_json::Value::Object(m) => (
                m.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                m.get("offset_x").and_then(|v| v.as_str()).map(|s| s.to_string()),
                m.get("offset_y").and_then(|v| v.as_str()).map(|s| s.to_string()),
            ),
            _ => return deferred,
        };
        let id_val = super::expr::eval(&id_expr, &*eval_ctx);
        let target = match id_val {
            super::expr_types::Value::Str(s) => s,
            _ => return deferred,
        };
        let ox = ox_expr
            .as_ref()
            .map(|s| super::expr::eval(s, &*eval_ctx))
            .and_then(|v| if let super::expr_types::Value::Number(n) = v { Some(n) } else { None })
            .unwrap_or(20.0);
        let oy = oy_expr
            .as_ref()
            .map(|s| super::expr::eval(s, &*eval_ctx))
            .and_then(|v| if let super::expr_types::Value::Number(n) = v { Some(n) } else { None })
            .unwrap_or(20.0);
        let Some(tab) = st.tabs.get_mut(st.active_tab) else { return deferred; };
        let doc = tab.model.document();
        // Resolve the source up front: a missing source short-circuits BEFORE we
        // mint, so a no-op duplicate journals nothing (matching the op_apply arm).
        if !doc.artboards.iter().any(|a| a.id == target) {
            return deferred;
        }
        // Collision-retry id mint (production entropy) — the ONLY mint.
        let existing_ids: std::collections::HashSet<String> =
            doc.artboards.iter().map(|a| a.id.clone()).collect();
        let mut new_id = String::new();
        for _ in 0..100 {
            let c = generate_artboard_id(None);
            if !existing_ids.contains(&c) { new_id = c; break; }
        }
        if new_id.is_empty() { return deferred; }
        // Derive the new name HERE (a function of the live doc); journaled as a
        // literal so replay never re-derives it.
        let new_name = next_artboard_name(&doc.artboards);
        let op = serde_json::json!({
            "op": "duplicate_artboard",
            "id": target,
            "new_id": new_id,
            "name": new_name,
            "offset_x": ox,
            "offset_y": oy,
        });
        crate::document::op_apply::op_apply(&mut tab.model, &op);
        return deferred;
    }

    // doc.set_artboard_field: { id, field, value }  — OP_LOG.md §9 Phase P2.
    // Resolves the id + value exprs to literals, builds a `{op, id, field,
    // value}` op JSON, and routes through the SHARED `op_apply` dispatcher (which
    // calls `apply_set_artboard_field`). Routing through op_apply JOURNALS the
    // edit as a real op, so artboard_options_confirm — which chains ten of these
    // in one action — lands as ten distinct ops inside its single transaction
    // (one-op-per-field-call granularity), and each replays byte-identically.
    // targets carry the written artboard id.
    if let Some(spec) = eff.get("doc.set_artboard_field").and_then(|v| v.as_object()) {
        let id_expr = spec.get("id").and_then(|v| v.as_str()).unwrap_or("");
        let field = match spec.get("field").and_then(|v| v.as_str()) {
            Some(s) => s.to_string(),
            None => return deferred,
        };
        let value_val = match spec.get("value") {
            Some(serde_json::Value::String(s)) => super::expr::eval(s, &*eval_ctx),
            Some(v) => super::expr_types::Value::from_json(v),
            None => return deferred,
        };
        let id_val = super::expr::eval(id_expr, &*eval_ctx);
        let target = match id_val {
            super::expr_types::Value::Str(s) => s,
            _ => return deferred,
        };
        let value_json = super::effects::value_to_json(&value_val);
        let op = serde_json::json!({
            "op": "set_artboard_field",
            "id": target,
            "field": field,
            "value": value_json,
        });
        if let Some(tab) = st.tabs.get_mut(st.active_tab) {
            crate::document::op_apply::op_apply(&mut tab.model, &op);
        }
        return deferred;
    }

    // doc.set_artboard_options_field: { field, value }  — OP_LOG.md §9 Phase P2.
    // Document-global artboard options (bool fields). Routes through op_apply
    // (`apply_set_artboard_options_field`); journaled with EMPTY targets.
    if let Some(spec) = eff.get("doc.set_artboard_options_field").and_then(|v| v.as_object()) {
        let field = match spec.get("field").and_then(|v| v.as_str()) {
            Some(s) => s.to_string(),
            None => return deferred,
        };
        let value_val = match spec.get("value") {
            Some(serde_json::Value::String(s)) => super::expr::eval(s, &*eval_ctx),
            Some(v) => super::expr_types::Value::from_json(v),
            None => return deferred,
        };
        let value_json = super::effects::value_to_json(&value_val);
        let op = serde_json::json!({
            "op": "set_artboard_options_field",
            "field": field,
            "value": value_json,
        });
        if let Some(tab) = st.tabs.get_mut(st.active_tab) {
            crate::document::op_apply::op_apply(&mut tab.model, &op);
        }
        return deferred;
    }

    // geometry.export_pdf: { filename_hint }  — PRINT.md §1B.
    // Generates a PDF from the active document and triggers a browser
    // blob download. filename_hint is the suggested download name; if
    // unset or empty, derives one from the tab's filename via
    // pdf_filename_for_tab.
    if let Some(spec) = eff.get("geometry.export_pdf").and_then(|v| v.as_object()) {
        let Some(tab) = st.tabs.get(st.active_tab) else { return deferred; };
        let bytes = crate::geometry::pdf::document_to_pdf(tab.model.document());
        let hint = spec
            .get("filename_hint")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(String::from)
            .unwrap_or_else(|| pdf_filename_for_tab(&tab.model.filename));
        crate::workspace::clipboard::download_bytes(&hint, &bytes, "application/pdf");
        return deferred;
    }

    // The eight print-config field setters (PRINT.md §1–§6) — OP_LOG.md §9
    // Phase P1. Each evaluates its YAML `value` expr to a RESOLVED literal,
    // builds a `{op, field, value[, index]}` op JSON, and routes through the
    // SHARED `op_apply` dispatcher (which calls `apply_print_config_field`, the
    // same field-match + type-coerce + `edit_document` body the renderer used
    // inline before P1). Routing through `op_apply` JOURNALS the edit as a real
    // op so it replays byte-identically (the checkpoint_equivalence gate) and is
    // legible to capture/recipe/AI surfaces — the production proving ground for
    // the actions.yaml↔op_apply unification. `set_output_ink_field` also carries
    // an `index`; the others ignore it. The transaction is already owned/named/
    // committed by `run_yaml_effects_named` (the action emits `snapshot` first),
    // so the per-verb work is just: resolve → op JSON → op_apply.
    {
        // The renderer YAML verb → the op_apply verb (drop the `doc.` prefix).
        const PRINT_FIELD_EFFECTS: &[(&str, &str)] = &[
            ("doc.set_print_preferences_field", "set_print_preferences_field"),
            ("doc.set_marks_and_bleed_field", "set_marks_and_bleed_field"),
            ("doc.set_output_field", "set_output_field"),
            ("doc.set_output_ink_field", "set_output_ink_field"),
            ("doc.set_graphics_field", "set_graphics_field"),
            ("doc.set_color_management_field", "set_color_management_field"),
            ("doc.set_document_setup_field", "set_document_setup_field"),
            ("doc.set_advanced_field", "set_advanced_field"),
        ];
        for (yaml_key, op_verb) in PRINT_FIELD_EFFECTS {
            if let Some(spec) = eff.get(*yaml_key).and_then(|v| v.as_object()) {
                let field = match spec.get("field").and_then(|v| v.as_str()) {
                    Some(s) => s.to_string(),
                    None => return deferred,
                };
                // Resolve the value expr to a typed Value, then to a RESOLVED
                // JSON literal (op_apply replays without an eval context).
                let value_val = match spec.get("value") {
                    Some(serde_json::Value::String(s)) => super::expr::eval(s, &*eval_ctx),
                    Some(v) => super::expr_types::Value::from_json(v),
                    None => return deferred,
                };
                let value_json = super::effects::value_to_json(&value_val);
                // `index` only applies to set_output_ink_field; absent ⇒ 0
                // (the helper bounds-checks). A missing index on the ink verb
                // matched the old early-return — preserve by reading as u64.
                let mut op = serde_json::json!({
                    "op": op_verb,
                    "field": field,
                    "value": value_json,
                });
                if *op_verb == "set_output_ink_field" {
                    let index = match spec.get("index").and_then(|v| v.as_u64()) {
                        Some(n) => n,
                        None => return deferred,
                    };
                    op["index"] = serde_json::json!(index);
                }
                if let Some(tab) = st.tabs.get_mut(st.active_tab) {
                    crate::document::op_apply::op_apply(&mut tab.model, &op);
                }
                return deferred;
            }
        }
    }

    // doc.move_artboards_up: ids_expr  — OP_LOG.md §9 Phase P2.
    // Resolves the ids list expr, builds a `{op, ids}` op JSON, and routes
    // through op_apply (`apply_move_artboards_up`). Journaled with targets =
    // the moved ids; a boundary no-op (top artboard) journals nothing.
    if let Some(ids_expr_v) = eff.get("doc.move_artboards_up") {
        let ids_expr = ids_expr_v.as_str().unwrap_or("");
        let val = super::expr::eval(ids_expr, &*eval_ctx);
        let ids = extract_id_list(&val);
        let op = serde_json::json!({ "op": "move_artboards_up", "ids": ids });
        if let Some(tab) = st.tabs.get_mut(st.active_tab) {
            crate::document::op_apply::op_apply(&mut tab.model, &op);
        }
        return deferred;
    }

    // doc.move_artboards_down: ids_expr  — OP_LOG.md §9 Phase P2 (symmetric).
    if let Some(ids_expr_v) = eff.get("doc.move_artboards_down") {
        let ids_expr = ids_expr_v.as_str().unwrap_or("");
        let val = super::expr::eval(ids_expr, &*eval_ctx);
        let ids = extract_id_list(&val);
        let op = serde_json::json!({ "op": "move_artboards_down", "ids": ids });
        if let Some(tab) = st.tabs.get_mut(st.active_tab) {
            crate::document::op_apply::op_apply(&mut tab.model, &op);
        }
        return deferred;
    }

    // doc.create_layer: { name } — PHASE3 sub-tollgate 2
    // Factory returning a new Layer element (as JSON) bound via `as:`.
    if let Some(spec) = eff.get("doc.create_layer").and_then(|v| v.as_object()) {
        let name_expr = spec.get("name").and_then(|v| v.as_str()).unwrap_or("'Layer'");
        let name_val = super::expr::eval(name_expr, &*eval_ctx);
        let name = match name_val {
            super::expr_types::Value::Str(s) => s,
            super::expr_types::Value::Color(c) => c,
            _ => "Layer".to_string(),
        };
        let layer = crate::geometry::element::Element::Layer(
            crate::geometry::element::LayerElem {
                children: Vec::new(),
                common: crate::geometry::element::CommonProps {
                    name: Some(name),
                    ..Default::default()
                },
                isolated_blending: false,
                knockout_group: false,
            }
        );
        if let Some(as_n) = as_name {
            if let Some(map) = eval_ctx.as_object_mut() {
                if let Ok(json) = serde_json::to_value(&layer) {
                    map.insert(as_n, json);
                }
            }
        }
        return deferred;
    }

    // doc.delete_at: path_expr — PHASE3 §5.5 / OP_LOG.md §9 Phase P4.
    // Deletes the element at path; if `as:` is set, binds the deleted
    // element as JSON in ctx for subsequent effects. The deletion routes
    // through the SHARED `op_apply` dispatcher (which calls
    // `apply_delete_element_at`) so it JOURNALS as a real `delete_at` op
    // (replays byte-identically; targets carry the deleted element id when it
    // has one). The `as:`-bound removed element is resolved from the live doc
    // BEFORE op_apply mutates it, preserving the Phase-3 return-binding contract.
    if let Some(path_expr_v) = eff.get("doc.delete_at") {
        let path_expr = path_expr_v.as_str().unwrap_or("");
        let path_val = super::expr::eval(path_expr, &*eval_ctx);
        if let super::expr_types::Value::Path(indices) = path_val {
            // Resolve the to-be-removed element for the optional `as:` binding
            // before the mutation (op_apply has no return value).
            let removed_json = if as_name.is_some() {
                st.tabs.get(st.active_tab)
                    .and_then(|tab| tab.model.document().get_element(&indices).cloned())
                    .and_then(|e| serde_json::to_value(&e).ok())
            } else {
                None
            };
            let op = serde_json::json!({ "op": "delete_at", "path": indices });
            if let Some(tab) = st.tabs.get_mut(st.active_tab) {
                crate::document::op_apply::op_apply(&mut tab.model, &op);
            }
            if let Some(name) = as_name {
                if let Some(map) = eval_ctx.as_object_mut() {
                    map.insert(name, removed_json.unwrap_or(serde_json::Value::Null));
                }
            }
        }
        return deferred;
    }

    // doc.copy_selection_to_clipboard — copy the current selection to the
    // system clipboard (SVG) and the internal clipboard (cut OK path).
    // Mirrors the inline copy the menu/keyboard cut runs: write the
    // selection SVG to the system clipboard via clipboard_write, then
    // snapshot the selected GeoElements into tab.clipboard. This is a
    // non-document side effect (no snapshot needed), so the cut_orphan
    // OK action lists exactly one `snapshot` before the document-mutating
    // doc.delete_selection. The selection is preserved across opening the
    // confirm dialog, so this copies exactly what the user was about to cut.
    if eff.get("doc.copy_selection_to_clipboard").is_some() {
        if let Some(svg) = crate::workspace::clipboard::selection_to_svg(st) {
            crate::workspace::clipboard::clipboard_write(svg);
        }
        let elements: Vec<crate::geometry::element::Element> = {
            match st.tabs.get(st.active_tab) {
                Some(tab) => {
                    let doc = tab.model.document();
                    doc.selection
                        .iter()
                        .filter_map(|es| doc.get_element(&es.path).cloned())
                        .collect()
                }
                None => Vec::new(),
            }
        };
        if let Some(tab) = st.tabs.get_mut(st.active_tab) {
            tab.clipboard = elements;
        }
        return deferred;
    }

    // doc.delete_selection — delete every currently-selected element
    // (reference-aware delete OK path). Mirrors the inline delete the
    // menu/keyboard run when no orphan would result: snapshot is a
    // separate effect (the YAML action lists `snapshot` before this),
    // then delete_selection produces the new document and set_document
    // commits it. The selection is preserved across opening the confirm
    // dialog, so this deletes exactly what the user was about to delete.
    // Routes through the SHARED `op_apply` dispatcher (which calls
    // `apply_delete_selection`) so the deletion JOURNALS as a real
    // `delete_selection` op (replays byte-identically; targets carry the
    // pre-deletion selection ids) — OP_LOG.md §9 Phase P4.
    if eff.get("doc.delete_selection").is_some() {
        let op = serde_json::json!({ "op": "delete_selection" });
        if let Some(tab) = st.tabs.get_mut(st.active_tab) {
            crate::document::op_apply::op_apply(&mut tab.model, &op);
        }
        return deferred;
    }

    // doc.clone_at: path_expr — PHASE3 §5.5
    // Deep-clones the element at path (without mutating the doc) and
    // binds it as JSON in ctx under `as:` name.
    if let Some(path_expr_v) = eff.get("doc.clone_at") {
        let path_expr = path_expr_v.as_str().unwrap_or("");
        let path_val = super::expr::eval(path_expr, &*eval_ctx);
        if let super::expr_types::Value::Path(indices) = path_val {
            if let Some(name) = as_name {
                let cloned = clone_element_at(&indices, st);
                if let Some(map) = eval_ctx.as_object_mut() {
                    let json = cloned
                        .and_then(|e| serde_json::to_value(&e).ok())
                        .unwrap_or(serde_json::Value::Null);
                    map.insert(name, json);
                }
            }
        }
        return deferred;
    }

    // doc.insert_after: { path, element } — PHASE3 §5.5 / OP_LOG.md §9 Phase P4.
    // VALUE-IN-OP: the resolved element is serialized to JSON and carried WHOLE
    // in the op (replay deserializes and inserts it byte-identically, keeping
    // whatever id it had). The element comes from a preceding NON-JOURNALED
    // binder (`doc.clone_at` binds a clone as ctx JSON); only this insert
    // journals, so the composite `duplicate_layer_selection` journals as ONE
    // `insert_after` op per duplicate. Routes through the SHARED `op_apply`
    // dispatcher (which calls `apply_insert_element_after`); targets carry the
    // inserted element id when it has one.
    if let Some(spec) = eff.get("doc.insert_after").and_then(|v| v.as_object()) {
        let path_expr = spec.get("path").and_then(|v| v.as_str()).unwrap_or("");
        let path_val = super::expr::eval(path_expr, &*eval_ctx);
        let indices = match path_val {
            super::expr_types::Value::Path(idx) => idx,
            _ => return deferred,
        };
        let elem = resolve_element_arg(spec.get("element"), &*eval_ctx);
        if let Some(e) = elem {
            // Serialize the resolved element into the op as a LITERAL (value-in-op).
            if let Ok(element_json) = serde_json::to_value(&e) {
                let op = serde_json::json!({
                    "op": "insert_after",
                    "path": indices,
                    "element": element_json,
                });
                if let Some(tab) = st.tabs.get_mut(st.active_tab) {
                    crate::document::op_apply::op_apply(&mut tab.model, &op);
                }
            }
        }
        return deferred;
    }

    // doc.unpack_group_at: path_expr — PHASE3 sub-tollgate 3 / OP_LOG.md §9 Phase
    // P5. Replace a Group at path with its children in place (a non-Group target is
    // a no-op). Routes through the SHARED `op_apply` dispatcher (which calls
    // `apply_unpack_group_at`) so the multi-step extraction JOURNALS as ONE
    // `unpack_group_at` op carrying the RESOLVED plain index path — it replays
    // byte-identically (children keep their ids; no minting). The renderer resolves
    // the path expr to plain indices FIRST so op_apply parses uniformly.
    if let Some(path_expr_v) = eff.get("doc.unpack_group_at") {
        let path_expr = path_expr_v.as_str().unwrap_or("");
        let path_val = super::expr::eval(path_expr, &*eval_ctx);
        let indices = match path_val {
            super::expr_types::Value::Path(p) => p,
            _ => return deferred,
        };
        let op = serde_json::json!({ "op": "unpack_group_at", "path": indices });
        if let Some(tab) = st.tabs.get_mut(st.active_tab) {
            crate::document::op_apply::op_apply(&mut tab.model, &op);
        }
        return deferred;
    }

    // doc.wrap_in_layer: { paths, name } — PHASE3 sub-tollgate 3 / OP_LOG.md §9
    // Phase P5. Parallel to wrap_in_group but always appends a new top-level Layer.
    // Routes through the SHARED `op_apply` dispatcher (which calls
    // `apply_wrap_in_layer`) so the multi-step collect/reverse-delete/append
    // JOURNALS as ONE `wrap_in_layer` op. CRITICAL: the renderer evaluates the
    // `name` expr (e.g. `active_document.next_layer_name`) against the LIVE doc
    // FIRST and journals the RESOLVED name LITERAL — replay must NOT re-derive a
    // possibly-colliding name from the (now-mutated) tree. The `__path__` markers
    // are normalized to plain index arrays for the op so op_apply parses uniformly.
    if let Some(spec) = eff.get("doc.wrap_in_layer").and_then(|v| v.as_object()) {
        let paths_expr = spec.get("paths").and_then(|v| v.as_str()).unwrap_or("[]");
        let paths_val = super::expr::eval(paths_expr, &*eval_ctx);
        let raw_paths = match paths_val {
            super::expr_types::Value::List(items) => items,
            _ => return deferred,
        };
        let normalized = normalize_path_markers(&raw_paths);
        if normalized.is_empty() {
            return deferred;
        }
        // Resolve the name FIRST (against the live doc) and journal the LITERAL.
        let name_expr = spec.get("name").and_then(|v| v.as_str()).unwrap_or("'Layer'");
        let name_val = super::expr::eval(name_expr, &*eval_ctx);
        let name = match name_val {
            super::expr_types::Value::Str(s) => s,
            _ => "Layer".to_string(),
        };
        // Optional value-in-op container id: resolve to a literal if the action
        // assigns one (the production actions do not, so this is normally absent).
        let id = resolve_optional_id(spec.get("id"), &*eval_ctx);
        let mut op = serde_json::json!({
            "op": "wrap_in_layer",
            "paths": normalized,
            "name": name,
        });
        if let Some(id) = id {
            op["id"] = serde_json::Value::String(id);
        }
        if let Some(tab) = st.tabs.get_mut(st.active_tab) {
            crate::document::op_apply::op_apply(&mut tab.model, &op);
        }
        return deferred;
    }

    // doc.wrap_in_group: { paths } — PHASE3 sub-tollgate 3 / OP_LOG.md §9 Phase P5.
    // Wraps elements at the given paths in a new Group: sorted in document order;
    // deleted in reverse order; group inserted at the topmost-source position under
    // the shared parent. Routes through the SHARED `op_apply` dispatcher (which
    // calls `apply_wrap_in_group`) so the multi-step mutation JOURNALS as ONE
    // `wrap_in_group` op carrying the RESOLVED plain index arrays — it replays
    // byte-identically (child order + insertion index deterministic from the op).
    // An optional value-in-op container id is journaled as a literal when assigned.
    if let Some(spec) = eff.get("doc.wrap_in_group").and_then(|v| v.as_object()) {
        let paths_expr = spec.get("paths").and_then(|v| v.as_str()).unwrap_or("[]");
        let paths_val = super::expr::eval(paths_expr, &*eval_ctx);
        let raw_paths = match paths_val {
            super::expr_types::Value::List(items) => items,
            _ => return deferred,
        };
        let normalized = normalize_path_markers(&raw_paths);
        if normalized.is_empty() {
            return deferred;
        }
        let id = resolve_optional_id(spec.get("id"), &*eval_ctx);
        let mut op = serde_json::json!({
            "op": "wrap_in_group",
            "paths": normalized,
        });
        if let Some(id) = id {
            op["id"] = serde_json::Value::String(id);
        }
        if let Some(tab) = st.tabs.get_mut(st.active_tab) {
            crate::document::op_apply::op_apply(&mut tab.model, &op);
        }
        return deferred;
    }

    // doc.insert_at: { parent_path, index, element } — PHASE3 §5.5 /
    // OP_LOG.md §9 Phase P4. VALUE-IN-OP: the resolved element is serialized to
    // JSON and carried WHOLE in the op (replay deserializes and inserts it
    // byte-identically). The element comes from a preceding NON-JOURNALED binder
    // (`doc.create_layer`, a deterministic Layer factory bound as ctx JSON); only
    // this insert journals, so the composite `new_layer` journals as ONE
    // `insert_at` op. Routes through the SHARED `op_apply` dispatcher (which calls
    // `apply_insert_element_at`); targets carry the inserted element id when set.
    if let Some(spec) = eff.get("doc.insert_at").and_then(|v| v.as_object()) {
        let parent_expr = spec.get("parent_path").and_then(|v| v.as_str()).unwrap_or("path()");
        let parent_val = super::expr::eval(parent_expr, &*eval_ctx);
        let parent_indices = match parent_val {
            super::expr_types::Value::Path(idx) => idx,
            _ => return deferred,
        };
        let idx = match spec.get("index") {
            Some(serde_json::Value::String(s)) => {
                if let super::expr_types::Value::Number(n) = super::expr::eval(s, &*eval_ctx) {
                    n as usize
                } else { 0 }
            }
            Some(serde_json::Value::Number(n)) => n.as_u64().unwrap_or(0) as usize,
            _ => 0,
        };
        let elem = resolve_element_arg(spec.get("element"), &*eval_ctx);
        if let Some(e) = elem {
            // Serialize the resolved element into the op as a LITERAL (value-in-op).
            if let Ok(element_json) = serde_json::to_value(&e) {
                let op = serde_json::json!({
                    "op": "insert_at",
                    "parent_path": parent_indices,
                    "index": idx,
                    "element": element_json,
                });
                if let Some(tab) = st.tabs.get_mut(st.active_tab) {
                    crate::document::op_apply::op_apply(&mut tab.model, &op);
                }
            }
        }
        return deferred;
    }

    // doc.set: { path, fields } — PHASE3 §5.4
    if let Some(spec) = eff.get("doc.set").and_then(|v| v.as_object()) {
        let path_expr = spec.get("path").and_then(|v| v.as_str()).unwrap_or("");
        let path_val = super::expr::eval(path_expr, &*eval_ctx);
        let indices = match path_val {
            super::expr_types::Value::Path(idx) => idx,
            _ => return deferred,
        };
        if let Some(fields) = spec.get("fields").and_then(|v| v.as_object()) {
            for (dotted, expr_v) in fields {
                let val = if let Some(expr_str) = expr_v.as_str() {
                    super::expr::eval(expr_str, &*eval_ctx)
                } else {
                    super::expr_types::Value::from_json(expr_v)
                };
                apply_doc_set_field(&indices, dotted, &val, st);
            }
        }
        return deferred;
    }

    // if: { condition, then, else }
    if let Some(cond) = eff.get("if").and_then(|v| v.as_object()) {
        let condition = cond.get("condition").and_then(|v| v.as_str()).unwrap_or("false");
        let result = super::expr::eval(condition, &*eval_ctx);
        let branch = if result.to_bool() { "then" } else { "else" };
        if let Some(serde_json::Value::Array(branch_effs)) = cond.get(branch) {
            // Nested list: own scope, doesn't leak back
            deferred.extend(run_yaml_effects(branch_effs, eval_ctx, st));
        }
        return deferred;
    }

    // dispatch: <action_name> | { action: <name>, params: { ... } }
    // Generic indirection so YAML widgets can fire actions through
    // the dispatch_action pipeline. The Align panel uses this for
    // every align / distribute button click.
    if let Some(disp) = eff.get("dispatch") {
        let (action_name, params) = match disp {
            serde_json::Value::String(s) => (s.clone(), serde_json::Map::new()),
            serde_json::Value::Object(m) => {
                let name = m.get("action").and_then(|v| v.as_str())
                    .unwrap_or("").to_string();
                let raw_params = m.get("params").and_then(|p| p.as_object())
                    .cloned().unwrap_or_default();
                let resolved = resolve_dispatch_params(&raw_params, eval_ctx);
                (name, resolved)
            }
            _ => return deferred,
        };
        if !action_name.is_empty() {
            deferred.extend(dispatch_action(&action_name, &params, st));
        }
        return deferred;
    }

    // set: { key: expr_or_literal, ... }
    if let Some(set_map) = eff.get("set").and_then(|v| v.as_object()) {
        let mut evaluated = serde_json::Map::new();
        for (k, v) in set_map {
            let val = if let Some(expr_str) = v.as_str() {
                super::effects::value_to_json(&super::expr::eval(expr_str, eval_ctx))
            } else {
                v.clone()
            };
            evaluated.insert(k.clone(), val);
        }
        apply_set_effects(&evaluated, st);
        return deferred;
    }

    // select: { target, list, scope, scope_value, mode } — generic
    // list-selection effect for swatch / brush / row tile-style
    // panels. Plain click replaces the list with [target] and sets
    // the scope; mode "auto" reads event.shift / event.ctrl /
    // event.meta from the click ctx for shift-extend / ctrl-toggle
    // behaviors. The scope changes (panel.scope_field) reset the
    // selection when the user clicks into a different scope.
    if let Some(spec) = eff.get("select").and_then(|v| v.as_object()) {
        apply_select_effect(spec, eval_ctx, st);
        return deferred;
    }

    // swap: [key_a, key_b]
    if let Some(serde_json::Value::Array(keys)) = eff.get("swap") {
        if keys.len() == 2 {
            let a = keys[0].as_str().unwrap_or("").to_string();
            let b = keys[1].as_str().unwrap_or("").to_string();
            let a_val = get_app_state_field(&a, st);
            let b_val = get_app_state_field(&b, st);
            set_app_state_field(&a, &b_val, st);
            set_app_state_field(&b, &a_val, st);
        }
        return deferred;
    }

    // pop: panel.field_name
    if let Some(target) = eff.get("pop").and_then(|v| v.as_str()) {
        if target == "panel.isolation_stack" {
            st.layers_isolation_stack.pop();
        }
        return deferred;
    }

    // list_push: { target, value, unique, max_length }
    if let Some(lp) = eff.get("list_push").and_then(|v| v.as_object()) {
        let target = lp.get("target").and_then(|v| v.as_str()).unwrap_or("");
        if target == "panel.recent_colors" {
            let value_expr = lp.get("value").and_then(|v| v.as_str()).unwrap_or("null");
            let val = super::expr::eval(value_expr, eval_ctx);
            // Accept both Value::Color (e.g. from a `Color`-typed
            // bind) and Value::Str (already-stringified hex). The
            // recent_colors list is a Vec<String>.
            let hex_opt = match val {
                super::expr_types::Value::Str(s) => Some(s),
                super::expr_types::Value::Color(s) => Some(s),
                _ => None,
            };
            if let Some(hex) = hex_opt {
                let unique = lp.get("unique").and_then(|v| v.as_bool()).unwrap_or(false);
                let max_len = lp.get("max_length").and_then(|v| v.as_u64()).map(|n| n as usize);
                if let Some(tab) = st.tabs.get_mut(st.active_tab) {
                    if unique {
                        if let Some(pos) = tab.model.recent_colors.iter().position(|c| *c == hex) {
                            tab.model.recent_colors.remove(pos);
                        }
                    }
                    tab.model.recent_colors.insert(0, hex);
                    if let Some(max) = max_len {
                        tab.model.recent_colors.truncate(max);
                    }
                }
            }
        } else if target == "panel.isolation_stack" {
            // Push a Path value onto the layers isolation stack.
            let value_expr = lp.get("value").and_then(|v| v.as_str()).unwrap_or("null");
            let val = super::expr::eval(value_expr, eval_ctx);
            if let super::expr_types::Value::Path(indices) = val {
                st.layers_isolation_stack.push(indices);
            }
        }
        return deferred;
    }

    // set_panel_state: { key, value, panel? }
    if let Some(sps) = eff.get("set_panel_state").and_then(|v| v.as_object()) {
        apply_set_panel_state_with_ctx(sps, st, Some(&*eval_ctx));
        return deferred;
    }

    // swap_panel_state: [key_a, key_b]
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
        return deferred;
    }

    // open_dialog / close_dialog — defer for handling outside AppState borrow
    if eff.get("open_dialog").is_some() || eff.get("close_dialog").is_some() {
        let mut resolved = eff.clone();
        if let Some(od) = eff.get("open_dialog").and_then(|o| o.as_object()) {
            if let Some(eff_params) = od.get("params").and_then(|p| p.as_object()) {
                let mut rp = serde_json::Map::new();
                for (k, v) in eff_params {
                    let val = if let Some(s) = v.as_str() {
                        super::effects::value_to_json(&super::expr::eval(s, eval_ctx))
                    } else { v.clone() };
                    rp.insert(k.clone(), val);
                }
                let mut new_od = od.clone();
                new_od.insert("params".to_string(), serde_json::Value::Object(rp));
                resolved = serde_json::json!({"open_dialog": new_od});
            }
        }
        deferred.push(resolved);
    }

    // Fallback: route Model-level `doc.*` effects (doc.zoom.*,
    // doc.pan.*, doc.translate_selection, doc.add_element, etc.) to
    // the effects.rs dispatcher so view actions like
    // fit_active_artboard / zoom_to_actual_size — which are dispatched
    // from the menubar / shortcuts via dispatch_action and end up
    // here, NOT via a tool's on_event — actually move the canvas. The
    // AppState-level doc.* mutations above (create_artboard,
    // wrap_in_group, …) have already returned by this point, so any
    // unhandled `doc.*` key is by definition Model-level.
    let has_unhandled_doc_effect = eff
        .as_object()
        .map(|m| m.keys().any(|k| k.starts_with("doc.")))
        .unwrap_or(false);
    if has_unhandled_doc_effect {
        if let Some(tab) = st.tabs.get_mut(st.active_tab) {
            let mut store = super::state_store::StateStore::new();
            super::effects::run_effects(
                std::slice::from_ref(eff),
                &*eval_ctx,
                &mut store,
                Some(&mut tab.model),
                None,
                None,
                // OP_LOG.md §9: deliberately NOT named here — this is the
                // renderer.rs throwaway-StateStore delegation path (view
                // actions: fit_active_artboard, zoom_to_actual_size, …), not
                // the real tool on_event dispatch. Naming is wired at the
                // yaml_tool dispatch site instead.
                None,
            );
        }
    }

    deferred
}

/// Resolve a doc.* effect's `element:` argument to an Element.
/// Accepts either a raw JSON object (serialized Element) or a bare
/// identifier referring to a ctx-bound Element (from doc.clone_at/
/// delete_at's `as:`). Bypasses the Value-wrapping roundtrip that would
/// otherwise stringify a ctx'd JSON object.
fn resolve_element_arg(
    arg: Option<&serde_json::Value>,
    eval_ctx: &serde_json::Value,
) -> Option<crate::geometry::element::Element> {
    use crate::geometry::element::Element;
    match arg? {
        serde_json::Value::String(s) => {
            // Try direct ctx lookup for bare identifier
            if let Some(direct) = eval_ctx.get(s) {
                if let Ok(elem) = serde_json::from_value::<Element>(direct.clone()) {
                    return Some(elem);
                }
            }
            // Fallback: treat as an expression
            let val = super::expr::eval(s, eval_ctx);
            let json = super::effects::value_to_json(&val);
            serde_json::from_value::<Element>(json).ok()
        }
        other => serde_json::from_value::<Element>(other.clone()).ok(),
    }
}

/// Delete the element at path from the active tab's document.
/// Returns the removed element.
// ── Artboards panel-state setter (ARTBOARDS.md) ─────────────────────────
//
// Routes `set_panel_state { panel: artboards, key, value }` to the matching
// AppState field. Five keys mirror workspace/panels/artboards.yaml's state
// block: artboards_panel_selection, panel_selection_anchor,
// renaming_artboard, reference_point, rearrange_dirty.

/// Apply shift/meta modifier semantics to the artboards panel
/// selection. Shift extends the contiguous range from the anchor to
/// the target; meta toggles the target id in or out. Both update
/// `panel_selection_anchor` per ARTBOARDS.md §Panel Selection.
pub(crate) fn apply_artboards_panel_select_modifier(
    st: &mut crate::workspace::app_state::AppState,
    target_id: &str,
    modifier: &str,
) {
    let Some(tab) = st.tabs.get(st.active_tab) else { return; };
    let ids: Vec<String> = tab.model.document().artboards.iter()
        .map(|a| a.id.clone()).collect();
    let target_idx = ids.iter().position(|id| id == target_id);
    let Some(target_idx) = target_idx else { return; };

    match modifier {
        "shift" => {
            // Anchor falls back to first selected, then to target itself.
            let anchor = st.artboards_panel_anchor.clone()
                .or_else(|| st.artboards_panel_selection.first().cloned())
                .unwrap_or_else(|| target_id.to_string());
            let anchor_idx = ids.iter().position(|id| id == &anchor)
                .unwrap_or(target_idx);
            let (lo, hi) = if anchor_idx <= target_idx {
                (anchor_idx, target_idx)
            } else {
                (target_idx, anchor_idx)
            };
            st.artboards_panel_selection = ids[lo..=hi].to_vec();
            // Anchor stays put across shift-clicks (per spec).
            st.artboards_panel_anchor = Some(anchor);
        }
        "meta" => {
            if let Some(pos) = st.artboards_panel_selection
                .iter().position(|id| id == target_id)
            {
                st.artboards_panel_selection.remove(pos);
            } else {
                st.artboards_panel_selection.push(target_id.to_string());
            }
            st.artboards_panel_anchor = Some(target_id.to_string());
        }
        _ => {}
    }
}

pub(crate) fn apply_artboards_panel_field(
    st: &mut crate::workspace::app_state::AppState,
    key: &str,
    value: &serde_json::Value,
) {
    match key {
        "artboards_panel_selection" => {
            if let serde_json::Value::Array(arr) = value {
                st.artboards_panel_selection = arr
                    .iter()
                    .filter_map(|v| v.as_str().map(|s| s.to_string()))
                    .collect();
            }
        }
        "panel_selection_anchor" => {
            st.artboards_panel_anchor = match value {
                serde_json::Value::Null => None,
                serde_json::Value::String(s) => Some(s.clone()),
                _ => st.artboards_panel_anchor.clone(),
            };
        }
        "renaming_artboard" => {
            st.artboards_renaming = match value {
                serde_json::Value::Null => None,
                serde_json::Value::String(s) => Some(s.clone()),
                _ => st.artboards_renaming.clone(),
            };
        }
        "reference_point" => {
            if let Some(s) = value.as_str() {
                st.artboards_reference_point = s.to_string();
            }
        }
        "rearrange_dirty" => {
            if let Some(b) = value.as_bool() {
                st.artboards_rearrange_dirty = b;
            }
        }
        _ => {}
    }
}

// ── Artboard doc helpers (ARTBOARDS.md §Reordering) ────────────────────

// apply_artboard_override (the create/duplicate field-application) moved to
// op_apply.rs (OP_LOG.md §9 Phase P3) as `apply_artboard_field_in_place`, so the
// create path resolves each YAML expr to a JSON literal in the renderer, journals
// it in the op's `fields`, and op_apply applies the RESOLVED literals at the
// document layer (no interpreter import, mirroring P2 apply_set_artboard_field).

fn extract_id_list(val: &super::expr_types::Value) -> Vec<String> {
    match val {
        super::expr_types::Value::List(arr) => arr
            .iter()
            .filter_map(|v| v.as_str().map(|s| s.to_string()))
            .collect(),
        _ => Vec::new(),
    }
}

// move_artboards_up / move_artboards_down moved to op_apply.rs (OP_LOG.md §9
// Phase P2) as `move_artboards_up_in_place` / `move_artboards_down_in_place`
// (pure) + `apply_move_artboards_up` / `apply_move_artboards_down` (Model), so
// the production handler routes through op_apply and the harness shares the body.

// delete_element_at / insert_element_after / insert_element_at moved to
// op_apply.rs (OP_LOG.md §9 Phase P4/P5) as `apply_delete_element_at` /
// `apply_insert_element_after` / `apply_insert_element_at` (+ the P5 wrapping
// helpers `apply_wrap_in_group` / `apply_wrap_in_layer` / `apply_unpack_group_at`),
// so the structural production handlers route through op_apply (journaling a real
// op) and the replay harness shares the same mutation body. `clone_element_at`
// stays here as the NON-JOURNALED ctx binder.

/// Deep-clone the element at path without mutating the document.
fn clone_element_at(
    path: &[usize],
    st: &crate::workspace::app_state::AppState,
) -> Option<crate::geometry::element::Element> {
    let tab = st.tabs.get(st.active_tab)?;
    let path_vec = path.to_vec();
    tab.model.document().get_element(&path_vec).cloned()
}

/// Normalize a list of `{__path__:[..]}` marker JSON values (the
/// `Value::List`-of-`Value::Path` form the expression evaluator produces) into
/// plain index arrays for a wrapping op (OP_LOG.md §9 Phase P5). Items that are
/// not well-formed path markers are dropped; the result is sorted ascending so the
/// op carries paths in document order (the order both the collect and the
/// reverse-delete in op_apply depend on).
fn normalize_path_markers(raw_paths: &[serde_json::Value]) -> Vec<Vec<usize>> {
    let mut normalized: Vec<Vec<usize>> = Vec::new();
    for item in raw_paths {
        if let Some(obj) = item.as_object() {
            if let Some(arr) = obj.get("__path__").and_then(|v| v.as_array()) {
                let idx: Option<Vec<usize>> = arr
                    .iter()
                    .map(|n| n.as_u64().map(|u| u as usize))
                    .collect();
                if let Some(idx) = idx {
                    normalized.push(idx);
                }
            }
        }
    }
    normalized.sort();
    normalized
}

/// Resolve an optional value-in-op container `id` expr to a literal string
/// (OP_LOG.md §9 Phase P5). The production wrapping actions do not assign a
/// container id, so this is normally `None`; when present, the expr is evaluated
/// to a string literal that is journaled into the op (replay inserts the same id).
fn resolve_optional_id(
    id_spec: Option<&serde_json::Value>,
    eval_ctx: &serde_json::Value,
) -> Option<String> {
    let expr = id_spec?.as_str()?;
    match super::expr::eval(expr, eval_ctx) {
        super::expr_types::Value::Str(s) => Some(s),
        _ => None,
    }
}

/// Write a dotted-field value to the element at the given path (Phase 3 §5.4).
/// Supports `common.visibility`, `common.locked`, `common.opacity`, `name`
/// at minimum — the fields used by the Group A toggle actions.
fn apply_doc_set_field(
    path: &[usize],
    dotted_field: &str,
    value: &super::expr_types::Value,
    st: &mut crate::workspace::app_state::AppState,
) {
    use crate::geometry::element::{Element, Visibility};
    use super::expr_types::Value;

    let Some(tab) = st.tabs.get_mut(st.active_tab) else { return; };
    let mut new_doc = tab.model.document().clone();

    // Navigate to the element. Only top-level layers supported for now;
    // nested element traversal (for grouped layers) comes in a later Phase 3 step.
    if path.len() != 1 {
        return;
    }
    let idx = path[0];
    if idx >= new_doc.layers.len() {
        return;
    }

    // Write the field
    let elem = &mut new_doc.layers[idx];
    let written = match dotted_field {
        "common.visibility" => {
            let v = match value {
                Value::Str(s) => match s.as_str() {
                    "invisible" => Some(Visibility::Invisible),
                    "outline" => Some(Visibility::Outline),
                    "preview" => Some(Visibility::Preview),
                    _ => None,
                },
                _ => None,
            };
            if let Some(vis) = v {
                elem.common_mut().visibility = vis;
                true
            } else { false }
        }
        "common.locked" => {
            if let Value::Bool(b) = value {
                elem.common_mut().locked = *b;
                // Cascade: a container's lock state propagates
                // recursively to ALL descendants, not just direct
                // children — locking a Layer that contains a Group
                // should lock the Group AND the elements inside the
                // Group. Mirror semantics (no save+restore bookkeeping;
                // the row-level lock-icon click handler does that for
                // the panel UI). LYR-247.
                fn cascade_lock(
                    el: &mut crate::geometry::element::Element,
                    locked: bool,
                ) {
                    if let Some(children) = el.children_mut() {
                        for c in children.iter_mut() {
                            let inner = std::rc::Rc::make_mut(c);
                            inner.common_mut().locked = locked;
                            cascade_lock(inner, locked);
                        }
                    }
                }
                cascade_lock(elem, *b);
                true
            } else { false }
        }
        "common.opacity" => {
            if let Value::Number(n) = value {
                elem.common_mut().opacity = *n;
                true
            } else { false }
        }
        "name" => {
            if let (Element::Layer(le), Value::Str(s)) = (elem, value) {
                le.set_name(s.clone());
                true
            } else { false }
        }
        _ => false,
    };
    if written {
        tab.model.set_document(new_doc);
    }
}

/// Read a top-level AppState field as a JSON value (for use with swap:).
fn get_app_state_field(key: &str, st: &crate::workspace::app_state::AppState) -> serde_json::Value {
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
            serde_json::Value::String(st.active_tool.panel_state_name().to_string())
        }
        _ => {
            // Delegate stroke panel fields (stroke_cap, stroke_join, etc.)
            let panel_key = key.strip_prefix("stroke_").unwrap_or(key);
            get_stroke_field(&st.stroke_panel, panel_key)
        }
    }
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
///
/// `click_and_wait` is treated as an alias for `double_click` here.
/// The Artboards panel uses click-and-hold semantics in spec, but we
/// route it through double-click for now (rename UX matches Finder).
fn build_mouse_event_handler(
    el: &serde_json::Value,
    ctx: &serde_json::Value,
    rctx: &RenderCtx,
    event_name: &str,
) -> Option<EventHandler<Event<MouseData>>> {
    let behaviors = el.get("behavior").and_then(|b| b.as_array())?;
    let click_behaviors: Vec<&serde_json::Value> = behaviors.iter()
        .filter(|b| {
            let evt = b.get("event").and_then(|e| e.as_str()).unwrap_or("click");
            evt == event_name
                || (event_name == "double_click" && evt == "click_and_wait")
        })
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
                    Value::Path(indices) => {
                        resolved_params.insert(k.clone(), serde_json::json!({
                            "__path__": indices.iter().map(|&i| i as u64).collect::<Vec<_>>()
                        }));
                    }
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

    Some(EventHandler::new(move |evt: Event<MouseData>| {
        let app = app.clone();
        let actions = resolved_actions.clone();
        let mut ctx_snap = ctx_snapshot.clone();
        // Expose click-time modifier state to yaml condition
        // expressions as `event.alt` / `event.shift` / `event.meta` /
        // `event.ctrl`. The Boolean panel uses `event.alt` to route
        // Shape Mode buttons between destructive and compound-creating
        // dispatches; future panels can consume the same namespace.
        let mods = evt.data().modifiers();
        if let serde_json::Value::Object(obj) = &mut ctx_snap {
            obj.insert("event".to_string(), serde_json::json!({
                "alt": mods.alt(),
                "shift": mods.shift(),
                "meta": mods.meta(),
                "ctrl": mods.ctrl(),
            }));
        }
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
                    // Run effects (returns deferred dialog effects).
                    // Pass the click-time ctx so foreach iterator
                    // vars (e.g. `swatch._index`) resolve in select
                    // targets / scope_value / set: expressions.
                    if !effects.is_empty() {
                        let dialog_effs = run_effects_with_ctx(
                            effects, Some(&ctx_snap), &mut st);
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
                    let (live_state, outer_scope) = {
                        let st = app.borrow();
                        (
                            crate::workspace::dock_panel::build_live_state_map(&st),
                            build_dialog_outer_scope(&st),
                        )
                    };
                    super::dialog_view::open_dialog_with_outer(
                        &mut dialog_signal, dlg_id, &raw_params, &live_state, &outer_scope,
                    );
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


/// Parse a tool kind name from YAML (snake_case) to ToolKind.
fn parse_tool_kind(name: &str) -> Option<crate::tools::tool::ToolKind> {
    use crate::tools::tool::ToolKind;
    match name {
        "selection" => Some(ToolKind::Selection),
        "partial_selection" => Some(ToolKind::PartialSelection),
        "interior_selection" => Some(ToolKind::InteriorSelection),
        "magic_wand" => Some(ToolKind::MagicWand),
        "pen" => Some(ToolKind::Pen),
        "add_anchor" => Some(ToolKind::AddAnchorPoint),
        "delete_anchor" => Some(ToolKind::DeleteAnchorPoint),
        "anchor_point" => Some(ToolKind::AnchorPoint),
        "pencil" => Some(ToolKind::Pencil),
        "paintbrush" => Some(ToolKind::Paintbrush),
        "blob_brush" => Some(ToolKind::BlobBrush),
        "path_eraser" => Some(ToolKind::PathEraser),
        "smooth" => Some(ToolKind::Smooth),
        "type" => Some(ToolKind::Type),
        "type_on_path" => Some(ToolKind::TypeOnPath),
        "line" => Some(ToolKind::Line),
        "rect" => Some(ToolKind::Rect),
        "rounded_rect" => Some(ToolKind::RoundedRect),
        "ellipse" => Some(ToolKind::Ellipse),
        "polygon" => Some(ToolKind::Polygon),
        "star" => Some(ToolKind::Star),
        "lasso" => Some(ToolKind::Lasso),
        "scale" => Some(ToolKind::Scale),
        "rotate" => Some(ToolKind::Rotate),
        "shear" => Some(ToolKind::Shear),
        "hand" => Some(ToolKind::Hand),
        "zoom" => Some(ToolKind::Zoom),
        "artboard" => Some(ToolKind::Artboard),
        "eyedropper" => Some(ToolKind::Eyedropper),
        _ => None,
    }
}

/// Build a CSS style string from the element's style properties.
fn build_style(el: &serde_json::Value, ctx: &serde_json::Value) -> String {
    let Some(map) = el.get("style").and_then(|s| s.as_object()) else {
        return String::new();
    };
    let mut parts = Vec::new();

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
#[derive(Clone)]
enum BindTarget {
    Dialog(String),
    Panel(String),
    None,
}

/// Read the "value" bind expression from an element.
///
/// Supports two YAML forms:
///   `bind: "dialog.x"` — bare string (dialogs / templates often use this)
///   `bind: { value: "dialog.x" }` — object form (panels use this)
fn read_bind_value(el: &serde_json::Value) -> &str {
    el.get("bind")
        .and_then(|b| {
            b.get("value")
                .and_then(|v| v.as_str())
                .or_else(|| b.as_str())
        })
        .unwrap_or("")
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
    // bind.background — Artboards panel rows use this to highlight
    // the panel-selected rows from `active_document.artboards_panel_selection_ids`.
    // Expressions may embed `{{theme.colors.X}}` template segments
    // (string literals interpolated before the if/then/else evaluates),
    // so run eval_text first to substitute, then eval the result.
    let bind_bg = el
        .get("bind")
        .and_then(|b| b.get("background"))
        .and_then(|v| v.as_str())
        .map(|expr_str| {
            let substituted = expr::eval_text(expr_str, ctx);
            let val = expr::eval(&substituted, ctx);
            match val {
                Value::Str(s) => s,
                Value::Color(c) => c,
                _ => String::new(),
            }
        })
        .filter(|s| !s.is_empty())
        .map(|s| format!("background:{s};"))
        .unwrap_or_default();
    // Bootstrap grid: col: N → class="col-N", type: row → class="row"
    // Neutralize Bootstrap's gutter (--bs-gutter-x default 1.5rem = 24px,
    // which gives row margin-left: -12px and col padding-left: 12px). The
    // negative row margin makes col children overflow the parent's content
    // box on the left when the parent's padding is < 12px (e.g. cp_content
    // uses padding:4). Setting --bs-gutter-x:0 keeps the col flex sizing
    // (col-3 still = 25%) but removes the offset so cols sit flush with
    // the row's parent's content edge.
    let col_class = el.get("col").and_then(|c| c.as_u64())
        .map(|c| format!("col-{c}"))
        .unwrap_or_default();
    let row_class = if etype == "row" { "row" } else { "" };
    let gutter_reset = if etype == "row" { "--bs-gutter-x:0;" } else { "" };
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
        format!("{flex_dir}{pos_style}{color_default}{gutter_reset}{base_style};{bind_bg}")
    } else {
        format!("display:none;{pos_style}{color_default}{gutter_reset}{base_style};{bind_bg}")
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

fn render_text(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let content = el.get("content").and_then(|c| c.as_str()).unwrap_or("");
    let text = if content.contains("{{") {
        expr::eval_text(content, ctx)
    } else {
        content.to_string()
    };
    let style = build_style(el, ctx);
    let visibility_style = if is_visible(el, ctx) { "" } else { "display:none;" };

    // Only attach onclick when the element actually has click behavior;
    // adding a no-op onclick to every span widens the wbindgen surface
    // (each event listener registered with the DOM has overhead) without
    // gain. Clickable text rows pay for the handler; static labels do not.
    let on_click = build_click_handler(el, ctx, rctx);
    let on_dblclick = build_dblclick_handler(el, ctx, rctx);
    let interactive = on_click.is_some() || on_dblclick.is_some();
    if interactive {
        rsx! {
            span {
                id: "{id}",
                style: "cursor:pointer;{visibility_style}{style}",
                onclick: move |evt| { if let Some(ref h) = on_click { h.call(evt); } },
                ondoubleclick: move |evt| { if let Some(ref h) = on_dblclick { h.call(evt); } },
                "{text}"
            }
        }
    } else {
        rsx! {
            span {
                id: "{id}",
                style: "{visibility_style}{style}",
                "{text}"
            }
        }
    }
}

/// Render a non-interactive icon display. The icon name is looked up
/// in the icons map (ctx first, then the cached workspace), same as
/// `render_icon_button`. Use this for labels and decorative icons
/// (e.g. Character panel row markers).
fn render_icon(el: &serde_json::Value, ctx: &serde_json::Value) -> Element {
    let id = get_id(el);
    let style = build_style(el, ctx);
    let icon_name = el.get("name").and_then(|i| i.as_str()).unwrap_or("");
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
    rsx! {
        div {
            id: "{id}",
            style: "display:inline-flex;align-items:center;justify-content:center;{style}",
            dangerous_inner_html: "{icon_svg}",
        }
    }
}

fn render_button(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let static_label = el.get("label").and_then(|l| l.as_str()).unwrap_or("");
    // bind.label: expression whose evaluated string replaces the
    // static label. Used by op_make_mask to flip between "Make Mask"
    // and "Release" based on selection_has_mask. See OPACITY.md § States.
    let label: String = if let Some(expr_str) = el.get("bind").and_then(|b| b.get("label")).and_then(|v| v.as_str()) {
        match expr::eval(expr_str, ctx) {
            Value::Str(s) => s,
            _ => static_label.to_string(),
        }
    } else {
        static_label.to_string()
    };
    let style = build_style(el, ctx);
    let panel_kind = rctx.panel_kind;

    // Evaluate bind.disabled. When true, the button is rendered dimmed
    // and pointer-events are disabled so the click handler is inert.
    // Mirrors the render_icon_button pattern; used by dialog OK buttons
    // gated on a non-empty input (e.g. swatch_library_save).
    let bind_disabled = el.get("bind")
        .and_then(|b| b.get("disabled"))
        .and_then(|v| v.as_str())
        .map(|expr_str| expr::eval(expr_str, ctx).to_bool())
        .unwrap_or(false);
    let disabled_style = if bind_disabled {
        "opacity:0.35;pointer-events:none;"
    } else {
        ""
    };

    // Opacity panel: op_make_mask dispatches Controller::make or release
    // based on the current selection_has_mask predicate. Direct route
    // rather than yaml-actions because the target lives on the
    // selection's mask field, not on a panel-state key.
    if panel_kind == Some(PanelKind::Opacity) && id == "op_make_mask" {
        let selection_has_mask = expr::eval("selection_has_mask", ctx).to_bool();
        let app = rctx.app.clone();
        let mut revision = rctx.revision;
        let handler = EventHandler::new(move |_evt: Event<MouseData>| {
            let app = app.clone();
            spawn(async move {
                {
                    let mut st = app.borrow_mut();
                    if selection_has_mask {
                        if let Some(tab) = st.tab_mut() {
                            crate::document::controller::Controller::release_mask_on_selection(&mut tab.model);
                        }
                    } else {
                        let clip = st.opacity_panel.new_masks_clipping;
                        let invert = st.opacity_panel.new_masks_inverted;
                        if let Some(tab) = st.tab_mut() {
                            crate::document::controller::Controller::make_mask_on_selection(&mut tab.model, clip, invert);
                        }
                    }
                }
                revision += 1;
            });
        });
        return rsx! { button { id: "{id}", style: "{style}", onclick: handler, "{label}" } };
    }

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
                    // Evaluate string-valued params against the dialog
                    // state + the DIALOG's own params (not the button's
                    // own params) so `params: { show: "dialog.show",
                    // layer_id: "param.layer_id" }` resolves the strings
                    // to the values the user actually selected. Without
                    // this the action sees param.show = "dialog.show"
                    // (a non-empty string), always truthy — show=false
                    // never propagated.
                    let evaluated_params: serde_json::Map<String, serde_json::Value>
                        = if let Some(ref snap) = dialog_snapshot {
                            let mut dialog_obj = serde_json::Map::new();
                            let mut dialog_params_obj = serde_json::Map::new();
                            for (k, v) in snap {
                                if let Some(stripped) = k.strip_prefix("_param_") {
                                    dialog_params_obj.insert(stripped.to_string(), v.clone());
                                } else {
                                    dialog_obj.insert(k.clone(), v.clone());
                                }
                            }
                            let eval_ctx = serde_json::json!({
                                "dialog": dialog_obj,
                                "param": dialog_params_obj,
                            });
                            let mut out = serde_json::Map::new();
                            for (k, v) in &params {
                                let resolved = if let Some(s) = v.as_str() {
                                    super::effects::value_to_json(
                                        &super::expr::eval(s, &eval_ctx)
                                    )
                                } else {
                                    v.clone()
                                };
                                out.insert(k.clone(), resolved);
                            }
                            out
                        } else {
                            params.clone()
                        };
                    let mut deferred;
                    {
                        let mut st = app.borrow_mut();
                        // For confirm actions, apply dialog state to app state
                        if let Some(ref snap) = dialog_snapshot {
                            apply_dialog_confirm(&action, snap, &mut st);
                        }
                        deferred = dispatch_action(&action, &evaluated_params, &mut st);
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
        rsx! { button { id: "{id}", class: "jas-focusable", style: "{disabled_style}{style}", onclick: handler, "{label}" } }
    } else {
        rsx! { button { id: "{id}", class: "jas-focusable", style: "{disabled_style}{style}", "{label}" } }
    }
}

/// Where a tool's options live, resolved from the compiled bundle in
/// priority order. Double-clicking a toolbar tool button opens the
/// ACTIVE tool's options via one of these three mutually-exclusive
/// destinations:
///   1. `tool_options_panel`  → show the named panel (Magic Wand).
///   2. `tool_options_action` → invoke a one-shot action (Hand →
///      fit_active_artboard, Zoom → zoom_to_actual_size, Artboard →
///      fit_all_artboards).
///   3. `tool_options_dialog` → open a modal options dialog
///      (Paintbrush / Blob Brush / Scale / Rotate / Shear / Eyedropper).
/// A tool declaring none of these has no dblclick options (no-op).
#[derive(Debug, Clone, PartialEq, Eq)]
enum ToolOptionsDest {
    Panel(String),
    Action(String),
    Dialog(String),
}

/// Resolve the active tool's options destination from the compiled
/// bundle `tools` map, keyed by the tool's YAML id (the value of
/// `ToolKind::panel_state_name`). The lookup mirrors the pre-bundle
/// native toolbar: panel beats action beats dialog when more than one
/// is present, though the spec keeps them mutually exclusive. Returns
/// `None` when the tool isn't in the bundle or declares no options —
/// the toolbar dblclick is then a silent no-op. Builds the list from
/// the bundle, never a hardcoded tool table.
fn tool_options_dest_for_yaml_id(yaml_id: &str) -> Option<ToolOptionsDest> {
    let ws = super::workspace::Workspace::load()?;
    let tool = ws.data().get("tools")?.get(yaml_id)?;
    if let Some(p) = tool.get("tool_options_panel").and_then(|v| v.as_str()) {
        return Some(ToolOptionsDest::Panel(p.to_string()));
    }
    if let Some(a) = tool.get("tool_options_action").and_then(|v| v.as_str()) {
        return Some(ToolOptionsDest::Action(a.to_string()));
    }
    if let Some(d) = tool.get("tool_options_dialog").and_then(|v| v.as_str()) {
        return Some(ToolOptionsDest::Dialog(d.to_string()));
    }
    None
}

/// Map a YAML panel id (the value of `tool_options_panel`) to its
/// `PanelKind`. Returns `None` when the id matches no known panel — the
/// toolbar dblclick is then a silent no-op. Mirrors the pre-bundle
/// native toolbar's `panel_id_to_kind`.
fn panel_id_to_kind(id: &str) -> Option<PanelKind> {
    Some(match id {
        "magic_wand" => PanelKind::MagicWand,
        // Add other tool panels here as they gain tool_options_panel.
        _ => return None,
    })
}

/// True when this icon_button is a TOOLBAR TOOL SLOT — a button whose
/// `behavior` declares an `action: select_tool` (every layout toolbar
/// slot). This is the discriminator the dblclick-opens-tool-options
/// gesture is scoped to: panels' op_* buttons, dialog toggles, and the
/// long-press flyout items (which `set` active_tool + `close_dialog`
/// but carry no `select_tool` action) all return false and never get
/// the dblclick.
fn is_toolbar_tool_slot(el: &serde_json::Value) -> bool {
    el.get("behavior")
        .and_then(|b| b.as_array())
        .map(|behaviors| {
            behaviors.iter().any(|b| {
                b.get("action").and_then(|a| a.as_str()) == Some("select_tool")
            })
        })
        .unwrap_or(false)
}

fn render_icon_button(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let summary = el.get("summary").and_then(|s| s.as_str()).unwrap_or("");
    let style = build_style(el, ctx);
    let panel_kind = rctx.panel_kind;

    // Evaluate bind.checked for active/highlighted state
    let checked = if let Some(expr_str) = el.get("bind").and_then(|b| b.get("checked")).and_then(|v| v.as_str()) {
        expr::eval(expr_str, ctx).to_bool()
    } else {
        false
    };
    // Evaluate bind.disabled to grey the button out. Used by
    // op_link_indicator to disable while the selection has no mask.
    let disabled = if let Some(expr_str) = el.get("bind").and_then(|b| b.get("disabled")).and_then(|v| v.as_str()) {
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
    // Always emit `background:` explicitly so a checked→unchecked
    // transition actually clears the highlight in the DOM. With an
    // empty fallback Dioxus's style diff left the previous
    // background-color on the element (so e.g. all three Align-To
    // toggles looked checked once any had ever been checked).
    let bg_style = if checked {
        format!("background:{checked_bg};")
    } else {
        "background:transparent;".to_string()
    };

    // Resolve the icon name. Resolution order:
    //   1. ``bind.icon`` (yaml expression) — used by Opacity panel's
    //      op_link_indicator to flip glyphs based on mask.linked.
    //   2. ``alternates.items`` lookup by ``state.active_tool`` — for
    //      toolbar slots that share a button with multiple tools
    //      (shape / pen / pencil / arrow / text / hand). Without this
    //      the slot stays stuck on the default icon after picking a
    //      different alternate from the long-press menu.
    //   3. The static ``icon`` field on the element.
    let static_icon_raw = el.get("icon").and_then(|i| i.as_str()).unwrap_or("").to_string();
    // Evaluate {{...}} templates in the icon field so YAML can flip
    // icons via expressions (e.g. chain_linked / chain_broken on the
    // Artboard Options dialog's lock toggle).
    let static_icon = if static_icon_raw.contains("{{") {
        expr::eval_text(&static_icon_raw, ctx)
    } else {
        static_icon_raw
    };
    let icon_name: String = if let Some(expr_str) = el.get("bind").and_then(|b| b.get("icon")).and_then(|v| v.as_str()) {
        match expr::eval(expr_str, ctx) {
            Value::Str(s) => s,
            _ => static_icon.clone(),
        }
    } else if let Some(items) = el.get("alternates").and_then(|a| a.get("items")).and_then(|i| i.as_array()) {
        let active = match expr::eval("state.active_tool", ctx) {
            Value::Str(s) => s,
            _ => String::new(),
        };
        items.iter()
            .find_map(|item| {
                let id = item.get("id").and_then(|v| v.as_str())?;
                let icon = item.get("icon").and_then(|v| v.as_str())?;
                (id == active).then(|| icon.to_string())
            })
            .unwrap_or_else(|| static_icon.clone())
    } else {
        static_icon.clone()
    };
    let icon_name = icon_name.as_str();
    // Resolve icon pixel size from style.size (default 32, matching
    // Flask). The SVG renders at 0.75 × size so the icon has natural
    // padding inside the button — without this the icon stretches to
    // the button's content area, which balloons in dialogs that set
    // width:"100%" with no height (e.g. tool_alternates entries).
    let icon_size_px: f64 = el
        .get("style")
        .and_then(|s| s.get("size"))
        .map(|v| {
            if let Some(n) = v.as_f64() { n }
            else if let Some(s) = v.as_str() {
                let s = if s.contains("{{") { expr::eval_text(s, ctx) } else { s.to_string() };
                s.trim_end_matches("px").parse::<f64>().unwrap_or(32.0)
            } else { 32.0 }
        })
        .unwrap_or(32.0);
    // Tool buttons (toolbar slots + long-press flyout items) render the
    // glyph at the FULL literal style.size — toolbar 32, flyout 28 —
    // matching OCaml (toolbar honors the literal tool_button size; the
    // flyout uses its scoped 28 default). Every other icon_button (panel
    // op_* buttons, dialog toggles) keeps the 0.75 reduction so panel
    // icons stay at their smaller default. Detection is by behavior, not
    // panel_kind:
    //   • Toolbar slot — `action: select_tool` (every layout.yaml slot).
    //   • Flyout item  — a `set: { active_tool: ... }` effect AND a
    //     `close_dialog` effect (every tool_alternates.yaml item). The
    //     close_dialog clause excludes the color picker's `cp_eyedropper`
    //     button, which also sets active_tool but is a dialog control
    //     (it uses `action: dismiss_dialog`, no close_dialog effect) and
    //     must keep its 0.75-reduced size.
    let is_tool_button = el
        .get("behavior")
        .and_then(|b| b.as_array())
        .map(|behaviors| {
            behaviors.iter().any(|b| {
                // Toolbar slot: `action: select_tool`.
                let is_select_tool_action = b
                    .get("action")
                    .and_then(|a| a.as_str())
                    .map(|a| a == "select_tool")
                    .unwrap_or(false);
                // Flyout item: effects that BOTH set active_tool and
                // close the dialog.
                let (sets_active_tool, closes_dialog) = b
                    .get("effects")
                    .and_then(|e| e.as_array())
                    .map(|effects| {
                        let sets = effects.iter().any(|eff| {
                            eff.get("set")
                                .and_then(|s| s.get("active_tool"))
                                .is_some()
                        });
                        let closes = effects
                            .iter()
                            .any(|eff| eff.get("close_dialog").is_some());
                        (sets, closes)
                    })
                    .unwrap_or((false, false));
                is_select_tool_action || (sets_active_tool && closes_dialog)
            })
        })
        .unwrap_or(false);
    let svg_px = if is_tool_button {
        icon_size_px.round() as i64
    } else {
        (icon_size_px * 0.75).round() as i64
    };
    // Look up icon from ctx first, then fall back to cached workspace
    let ws_for_icons = super::workspace::Workspace::load();
    let icon_svg = if !icon_name.is_empty() {
        let icon_from_ctx = ctx.get("icons").and_then(|i| i.get(icon_name));
        let icon_from_ws = ws_for_icons.as_ref().and_then(|ws| ws.icons().get(icon_name));
        if let Some(icon_def) = icon_from_ctx.or(icon_from_ws) {
            let viewbox = icon_def.get("viewbox").and_then(|v| v.as_str()).unwrap_or("0 0 16 16");
            let svg_inner = icon_def.get("svg").and_then(|v| v.as_str()).unwrap_or("");
            format!(r#"<svg viewBox="{viewbox}" width="{svg_px}" height="{svg_px}" xmlns="http://www.w3.org/2000/svg">{svg_inner}</svg>"#)
        } else {
            String::new()
        }
    } else {
        String::new()
    };
    // Static label, rendered alongside the icon when present (the
    // tool_alternates flyout buttons specify both `icon` and `label`
    // and expect a row layout — see workspace/dialogs/tool_alternates.yaml).
    // Toolbar buttons omit `label` entirely and stay icon-only.
    let label_text = el.get("label").and_then(|l| l.as_str()).unwrap_or("").to_string();

    // Opacity panel: op_link_indicator click toggles mask.linked on
    // every selected mask via Controller. Same pattern as
    // op_make_mask in render_button. OPACITY.md §Document model.
    let opacity_link_click: Option<EventHandler<Event<MouseData>>> =
        if panel_kind == Some(PanelKind::Opacity) && id == "op_link_indicator" {
            let app = rctx.app.clone();
            let mut revision = rctx.revision;
            Some(EventHandler::new(move |_evt: Event<MouseData>| {
                let app = app.clone();
                spawn(async move {
                    let mut st = app.borrow_mut();
                    if let Some(tab) = st.tab_mut() {
                        crate::document::controller::Controller::toggle_mask_linked_on_selection(&mut tab.model);
                    }
                    revision += 1;
                });
            }))
        } else {
            None
        };

    let on_click = opacity_link_click.or_else(|| build_click_handler(el, ctx, rctx));
    let on_mousedown = build_mousedown_handler(el, ctx, rctx);
    let on_mouseup = build_mouseup_handler(el, ctx, rctx);

    // Double-clicking a TOOLBAR TOOL SLOT opens the ACTIVE tool's
    // options. The destination is active-tool-dynamic (it depends on
    // state.active_tool at click time, not on this button), so this is
    // a native handler reading AppState rather than a declarative
    // behavior. Scoped to toolbar tool slots only — panels' op_*
    // buttons, dialog toggles, and long-press flyout items return false
    // from is_toolbar_tool_slot and get no dblclick. This restores the
    // pre-bundle native toolbar's 3-path dispatch (panel/action/dialog).
    let tool_options_dblclick: Option<EventHandler<Event<MouseData>>> =
        if is_toolbar_tool_slot(el) {
            let app = rctx.app.clone();
            let mut revision = rctx.revision;
            let mut dialog_signal = rctx.dialog_ctx.0;
            Some(EventHandler::new(move |evt: Event<MouseData>| {
                evt.stop_propagation();
                let app = app.clone();
                spawn(async move {
                    // Resolve the active tool's options destination from
                    // the bundle. Read active_tool under a short borrow.
                    let dest = {
                        let st = app.borrow();
                        let yaml_id = st.active_tool.panel_state_name();
                        tool_options_dest_for_yaml_id(yaml_id)
                    };
                    let Some(dest) = dest else { return }; // no-op
                    match dest {
                        ToolOptionsDest::Panel(panel_id) => {
                            let Some(kind) = panel_id_to_kind(&panel_id) else { return };
                            {
                                let mut st = app.borrow_mut();
                                crate::workspace::layout_apply::layout_apply(
                                    &mut st.workspace_layout,
                                    &crate::workspace::layout_apply::op_show_panel(kind),
                                );
                                if kind == PanelKind::Color {
                                    // COLOR.md §Panel initialization:
                                    // mode resets to HSB on each reopen.
                                    st.color_panel_mode =
                                        crate::workspace::color_panel_view::ColorMode::Hsb;
                                }
                            }
                            revision += 1;
                        }
                        ToolOptionsDest::Action(action_id) => {
                            {
                                let mut st = app.borrow_mut();
                                let empty = serde_json::Map::new();
                                dispatch_action(&action_id, &empty, &mut st);
                            }
                            revision += 1;
                        }
                        ToolOptionsDest::Dialog(dlg_id) => {
                            let (live_state, outer_scope) = {
                                let st = app.borrow();
                                (
                                    crate::workspace::dock_panel::build_live_state_map(&st),
                                    build_dialog_outer_scope(&st),
                                )
                            };
                            let empty = serde_json::Map::new();
                            super::dialog_view::open_dialog_with_outer(
                                &mut dialog_signal, &dlg_id, &empty, &live_state, &outer_scope,
                            );
                            revision += 1;
                        }
                    }
                });
            }))
        } else {
            None
        };
    // Disabled styling: grey out + block pointer events so the
    // button doesn't respond to clicks. Opacity panel's
    // LINK_INDICATOR disables itself when the selection has no mask.
    // Both branches set the same properties so Dioxus's diff always
    // updates the style attribute on transition (empty fallback let
    // stale opacity:0.35 persist in the DOM when disabled flipped to
    // false).
    let disabled_style = if disabled {
        "opacity:0.35;pointer-events:none;"
    } else {
        "opacity:1;pointer-events:auto;"
    };

    let layout_style = if !label_text.is_empty() {
        // Icon + label flyout button (tool_alternates).
        "display:flex;align-items:center;"
    } else {
        // Icon-only toolbar button — keep flex centering so the icon
        // sits in the middle of the fixed-size button.
        "display:flex;align-items:center;justify-content:center;"
    };
    // Toolbar slots that declare `alternates:` show a small filled
    // triangle in the lower-right corner so the user knows long-press
    // reveals more tools. Mirrors Flask _render_icon_button.
    let has_alternates = el.get("alternates")
        .map(|v| !v.is_null())
        .unwrap_or(false);
    let triangle_html: String = if has_alternates {
        let tri = 5;
        format!(
            r#"<svg width="{tri}" height="{tri}" viewBox="0 0 {tri} {tri}" xmlns="http://www.w3.org/2000/svg"><path d="M {tri} {tri} L 0 {tri} L {tri} 0 Z" fill="var(--jas-text,#cccccc)"/></svg>"#
        )
    } else {
        String::new()
    };
    let position_style = if has_alternates {
        "position:relative;"
    } else {
        ""
    };
    // Keyboard activation: icon-button is a <div>, which doesn't get
    // keyboard focus or Enter/Space activation for free the way <button>
    // does. tabindex=0 makes it focusable (-1 when disabled drops it
    // out of the tab cycle); onkeydown re-dispatches a DOM .click() so
    // the same onclick handler runs. preventDefault on Space stops the
    // page from scrolling.
    let tabindex_val: &str = if disabled { "-1" } else { "0" };
    let id_for_keydown = id.clone();
    rsx! {
        div {
            id: "{id}",
            class: "jas-focusable",
            tabindex: "{tabindex_val}",
            style: "{position_style}{layout_style}cursor:pointer;{disabled_style}{bg_style}{style}",
            title: "{summary}",
            onclick: move |evt| { if let Some(ref h) = on_click { h.call(evt); } },
            onmousedown: move |evt| { if let Some(ref h) = on_mousedown { h.call(evt); } },
            onmouseup: move |evt| { if let Some(ref h) = on_mouseup { h.call(evt); } },
            ondoubleclick: move |evt| { if let Some(ref h) = tool_options_dblclick { h.call(evt); } },
            onkeydown: move |evt: Event<KeyboardData>| {
                if disabled { return; }
                let key = evt.data().key();
                let is_space = matches!(&key, dioxus::prelude::Key::Character(c) if c == " ");
                if key == dioxus::prelude::Key::Enter || is_space {
                    evt.prevent_default();
                    #[cfg(target_arch = "wasm32")]
                    {
                        use wasm_bindgen::JsCast;
                        if let Some(node) = web_sys::window()
                            .and_then(|w| w.document())
                            .and_then(|d| d.get_element_by_id(&id_for_keydown))
                            .and_then(|el| el.dyn_into::<web_sys::HtmlElement>().ok())
                        {
                            node.click();
                        }
                    }
                }
            },
            if !icon_svg.is_empty() {
                div {
                    style: "flex-shrink:0;display:inline-flex;",
                    dangerous_inner_html: "{icon_svg}",
                }
            }
            if !label_text.is_empty() {
                span { style: "font-size:12px;", "{label_text}" }
            } else if icon_svg.is_empty() {
                span { style: "font-size:10px;", "{summary}" }
            }
            if !triangle_html.is_empty() {
                span {
                    style: "position:absolute;right:0;bottom:0;line-height:0;pointer-events:none;",
                    dangerous_inner_html: "{triangle_html}",
                }
            }
        }
    }
}

/// Horizontal group of icon-only toggle buttons. Exactly one option
/// is highlighted at a time, determined by `bind.value`. Clicking an
/// option fires the `change` behavior with the option's value as
/// `event.value`. Used by the Artboard Options dialog's Orientation
/// row (portrait / landscape).
fn render_icon_button_group(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let style = build_style(el, ctx);
    let options = el.get("options").and_then(|o| o.as_array()).cloned().unwrap_or_default();
    let bind_expr = el.get("bind").and_then(|b| b.get("value")).and_then(|v| v.as_str()).unwrap_or("");
    let current_value = if bind_expr.is_empty() {
        String::new()
    } else {
        match expr::eval(bind_expr, ctx) {
            Value::Str(s) => s,
            _ => String::new(),
        }
    };
    let dlg_field = dialog_field(bind_expr);
    let mut dialog_signal = rctx.dialog_ctx.0;
    let app = rctx.app.clone();
    let mut revision = rctx.revision;
    let ws_for_icons = super::workspace::Workspace::load();
    let svg_px: i64 = 14;

    // Pre-compute behaviors for `change` events so each button can
    // dispatch them with its own `event.value` injected into ctx.
    let change_behaviors: Vec<serde_json::Value> = el.get("behavior")
        .and_then(|b| b.as_array())
        .map(|arr| {
            arr.iter()
                .filter(|b| b.get("event").and_then(|e| e.as_str()) == Some("change"))
                .cloned()
                .collect()
        })
        .unwrap_or_default();

    let buttons: Vec<Element> = options.iter().enumerate().map(|(i, opt)| {
        let icon_name = opt.get("icon").and_then(|v| v.as_str()).unwrap_or("");
        let value = opt.get("value")
            .and_then(|v| v.as_str().map(|s| s.to_string())
                .or_else(|| Some(v.to_string())))
            .unwrap_or_default();
        let icon_svg = ws_for_icons.as_ref()
            .and_then(|ws| ws.icons().get(icon_name))
            .map(|d| {
                let viewbox = d.get("viewbox").and_then(|v| v.as_str()).unwrap_or("0 0 16 16");
                let inner = d.get("svg").and_then(|v| v.as_str()).unwrap_or("");
                format!(r#"<svg viewBox="{viewbox}" width="{svg_px}" height="{svg_px}" xmlns="http://www.w3.org/2000/svg">{inner}</svg>"#)
            })
            .unwrap_or_default();
        let active = value == current_value;
        let bg = if active { "background:#505050;" } else { "" };
        let key = format!("{id}-{i}");
        let dlg_field = dlg_field.clone();
        let value_for_dlg = value.clone();
        let value_for_log = value.clone();
        let app_for_click = app.clone();
        let behaviors = change_behaviors.clone();
        let ctx_snapshot = ctx.clone();
        rsx! {
            div {
                key: "{key}",
                style: "display:flex;align-items:center;justify-content:center;width:24px;height:20px;border:1px solid var(--jas-border,#555);border-radius:2px;cursor:pointer;{bg}",
                onclick: move |_| {
                    // Dialog binding: write the chosen value into the dialog state.
                    if !dlg_field.is_empty() {
                        if let Some(mut ds) = dialog_signal() {
                            ds.set_value(&dlg_field, serde_json::json!(value_for_dlg));
                            dialog_signal.set(Some(ds));
                        }
                    }
                    // Behavior dispatch: inject event.value into ctx, then
                    // fire any matching change actions through dispatch_action.
                    let mut ctx_snap = ctx_snapshot.clone();
                    if let serde_json::Value::Object(obj) = &mut ctx_snap {
                        obj.insert("event".to_string(), serde_json::json!({
                            "value": value_for_log,
                        }));
                    }
                    let app = app_for_click.clone();
                    let behaviors = behaviors.clone();
                    spawn(async move {
                        let mut st = app.borrow_mut();
                        for b in &behaviors {
                            let action = b.get("action").and_then(|a| a.as_str()).map(|s| s.to_string());
                            let raw_params = b.get("params").and_then(|p| p.as_object()).cloned().unwrap_or_default();
                            let mut resolved_params = serde_json::Map::new();
                            for (k, v) in &raw_params {
                                let val = if let Some(s) = v.as_str() {
                                    super::effects::value_to_json(&super::expr::eval(s, &ctx_snap))
                                } else {
                                    v.clone()
                                };
                                resolved_params.insert(k.clone(), val);
                            }
                            if let Some(name) = action {
                                dispatch_action(&name, &resolved_params, &mut st);
                            }
                        }
                        revision += 1;
                    });
                },
                div { style: "display:inline-flex;", dangerous_inner_html: "{icon_svg}" }
            }
        }
    }).collect();

    rsx! {
        div {
            id: "{id}",
            style: "display:flex;flex-direction:row;gap:4px;{style}",
            for b in buttons { {b} }
        }
    }
}

/// 3×3 grid of anchor buttons. Exactly one is highlighted; clicking
/// another writes its value back via the `change` behavior. Used by
/// the Artboard Options dialog's reference-point picker. The values
/// are positional names: top_left, top_center, ..., bottom_right.
fn render_reference_point_widget(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let bind_expr = el.get("bind").and_then(|b| b.get("value")).and_then(|v| v.as_str()).unwrap_or("");
    let current_value = if bind_expr.is_empty() {
        "center".to_string()
    } else {
        match expr::eval(bind_expr, ctx) {
            Value::Str(s) => s,
            _ => "center".to_string(),
        }
    };
    let app = rctx.app.clone();
    let mut revision = rctx.revision;
    let change_behaviors: Vec<serde_json::Value> = el.get("behavior")
        .and_then(|b| b.as_array())
        .map(|arr| {
            arr.iter()
                .filter(|b| b.get("event").and_then(|e| e.as_str()) == Some("change"))
                .cloned()
                .collect()
        })
        .unwrap_or_default();

    let anchors = [
        ("top_left", 0, 0), ("top_center", 1, 0), ("top_right", 2, 0),
        ("middle_left", 0, 1), ("center", 1, 1), ("middle_right", 2, 1),
        ("bottom_left", 0, 2), ("bottom_center", 1, 2), ("bottom_right", 2, 2),
    ];
    let cells: Vec<Element> = anchors.iter().map(|(name, _cx, _cy)| {
        let active = *name == current_value;
        let key = format!("{id}-{name}");
        let value_str = name.to_string();
        let app_for_click = app.clone();
        let behaviors = change_behaviors.clone();
        let ctx_snapshot = ctx.clone();
        let bg = if active { "background:var(--jas-accent,#4a90d9);" } else { "background:transparent;" };
        rsx! {
            div {
                key: "{key}",
                title: "{name}",
                style: "width:8px;height:8px;border:1px solid var(--jas-border,#555);border-radius:1px;cursor:pointer;{bg}",
                onclick: move |_| {
                    let mut ctx_snap = ctx_snapshot.clone();
                    if let serde_json::Value::Object(obj) = &mut ctx_snap {
                        obj.insert("event".to_string(), serde_json::json!({
                            "value": value_str,
                        }));
                    }
                    let app = app_for_click.clone();
                    let behaviors = behaviors.clone();
                    spawn(async move {
                        let mut st = app.borrow_mut();
                        for b in &behaviors {
                            let action = b.get("action").and_then(|a| a.as_str()).map(|s| s.to_string());
                            let raw_params = b.get("params").and_then(|p| p.as_object()).cloned().unwrap_or_default();
                            let mut resolved_params = serde_json::Map::new();
                            for (k, v) in &raw_params {
                                let val = if let Some(s) = v.as_str() {
                                    super::effects::value_to_json(&super::expr::eval(s, &ctx_snap))
                                } else {
                                    v.clone()
                                };
                                resolved_params.insert(k.clone(), val);
                            }
                            if let Some(name) = action {
                                dispatch_action(&name, &resolved_params, &mut st);
                            }
                        }
                        revision += 1;
                    });
                },
            }
        }
    }).collect();

    rsx! {
        div {
            id: "{id}",
            style: "display:grid;grid-template-columns:repeat(3,8px);grid-template-rows:repeat(3,8px);gap:2px;",
            for c in cells { {c} }
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
            // Controlled `value:` so external state writes (hex
            // commit, swatch click, mode-equivalent recompute) move
            // the thumb. `initial_value:` would leave the input as
            // an uncontrolled element after first render, so the
            // thumb would stay stuck on the original value. A keyed
            // remount works for one-shot inputs (number_input) but
            // breaks slider drag — the DOM element is destroyed mid-
            // drag, the pointer capture is lost, and the user can't
            // continue the drag past the first oninput.
            value: "{value}",
            disabled: disabled,
            style: "flex:1;{style}",
            // oninput fires on every drag tick — use the "live"
            // setter that updates the canvas color but skips the
            // recent-colors push (CLR-070). onchange fires on
            // pointer-up and commits the final color (full
            // set_active_color, which dedupes + adds to recent).
            oninput: {
                let app = app.clone();
                let mut revision = revision;
                let panel = panel.clone();
                let panel_field = panel_field.clone();
                let dlg_field = dlg_field.clone();
                move |evt: Event<FormData>| {
                    let new_val: f64 = evt.value().parse().unwrap_or(0.0);
                    if !dlg_field.is_empty() {
                        if let Some(mut ds) = dialog_signal() {
                            ds.set_value(&dlg_field, serde_json::json!(new_val));
                            dialog_signal.set(Some(ds));
                        }
                        revision += 1;
                        return;
                    }
                    if panel_field.is_empty() { return; }
                    let color = compute_color_from_panel(&panel_field, new_val, &panel);
                    if let Some(color) = color {
                        let app = app.clone();
                        let mut revision = revision;
                        spawn(async move {
                            app.borrow_mut().set_active_color_live(color);
                            revision += 1;
                        });
                    }
                }
            },
            onchange: move |evt: Event<FormData>| {
                let new_val: f64 = evt.value().parse().unwrap_or(0.0);
                if !dlg_field.is_empty() { return; }
                if panel_field.is_empty() { return; }
                let color = compute_color_from_panel(&panel_field, new_val, &panel);
                if let Some(color) = color {
                    let app = app.clone();
                    let mut revision = revision;
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
    let min = el.get("min").and_then(|m| m.as_f64()).unwrap_or(0.0);
    let max = el.get("max").and_then(|m| m.as_f64()).unwrap_or(100.0);
    // Declared bounds drive clamp-on-commit. Undeclared → no clamp (e.g.
    // Tracking is signed and has no yaml-declared min/max).
    let min_clamp = el.get("min").and_then(|m| m.as_f64());
    let max_clamp = el.get("max").and_then(|m| m.as_f64());
    // HTML <input type="number"> defaults to step=1 (integers only).
    // Read the YAML step if present; fall back to "any" so fields
    // without an explicit step accept arbitrary decimals.
    let step_attr: String = match el.get("step").and_then(|s| s.as_f64()) {
        Some(n) => format!("{n}"),
        None => "any".to_string(),
    };
    let style = build_style(el, ctx);

    let bind_expr = read_bind_value(el);
    let value: f64 = if !bind_expr.is_empty() {
        let result = expr::eval(bind_expr, ctx);
        match result {
            Value::Number(n) => n,
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
    //
    // Dispatch the write to the correct per-panel state struct based on
    // the enclosing panel's kind (set by render_panel on rctx). Stroke
    // keeps its existing weight → app_default_stroke sync; Character
    // pushes changes through apply_character_panel_to_selection.
    let panel_kind = rctx.panel_kind;
    let panel_for_color = ctx.get("panel").cloned().unwrap_or(serde_json::Value::Null);
    let panel_handler = if let BindTarget::Panel(ref field) = bind_target {
        let f = field.clone();
        let app = app.clone();
        let mut revision = revision;
        let panel_ctx = panel_for_color.clone();
        Some(EventHandler::new(move |evt: Event<FormData>| {
            let mut new_val: f64 = evt.value().parse().unwrap_or(0.0);
            if let Some(lo) = min_clamp { if new_val < lo { new_val = lo; } }
            if let Some(hi) = max_clamp { if new_val > hi { new_val = hi; } }
            let f = f.clone();
            let app = app.clone();
            let mut revision = revision;
            let panel_ctx = panel_ctx.clone();
            spawn(async move {
                {
                    let mut st = app.borrow_mut();
                    match panel_kind {
                        Some(PanelKind::Character) => {
                            set_character_field(&mut st.character_panel, &f, &serde_json::json!(new_val));
                            st.character_panel_post_write(&f);
                            st.apply_character_panel_to_selection();
                        }
                        Some(PanelKind::Paragraph) => {
                            // Sync first so untouched fields hold the
                            // selection's current values, not stale
                            // panel state, before the new field is set
                            // and the whole panel is re-applied.
                            st.sync_paragraph_panel_from_selection();
                            set_paragraph_field(&mut st.paragraph_panel, &f, &serde_json::json!(new_val));
                            st.apply_paragraph_panel_to_selection();
                        }
                        Some(PanelKind::Stroke) | None => {
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
                        }
                        Some(PanelKind::Opacity) => {
                            set_opacity_field(&mut st.opacity_panel, &f, &serde_json::json!(new_val));
                            // Phase 1: panel-local only; selection sync deferred.
                        }
                        Some(PanelKind::Color) => {
                            // Slider value-box edits commit by
                            // mixing the typed channel with the
                            // other channels from current panel
                            // state, then routing through
                            // set_active_color (push-to-recent).
                            // The slider's own oninput uses
                            // set_active_color_live; this path is
                            // the type-Enter or Tab commit and
                            // matches a pointer-up.
                            if let Some(color) = compute_color_from_panel(&f, new_val, &panel_ctx) {
                                st.set_active_color(color);
                            }
                        }
                        Some(PanelKind::Align) => {
                            // Align panel's only number_input is the
                            // explicit-spacing pt value, used when
                            // Align To is Key Object and a key is
                            // designated. Field is
                            // distribute_spacing_value in the YAML
                            // but maps to AlignPanelState's
                            // distribute_spacing.
                            if f == "distribute_spacing_value"
                                || f == "distribute_spacing" {
                                st.align_panel.distribute_spacing = new_val;
                            }
                        }
                        // Artboards, Layers, Swatches, Properties:
                        // no-op for number_input writes until their per-panel state
                        // structs land. Drops the edit silently rather than
                        // corrupting stroke state.
                        _ => {}
                    }
                }
                // Bump revision after the state mutation completes so the
                // re-render reads the clamped value, not the pre-mutation one.
                revision += 1;
            });
        }))
    } else { None };

    if panel_handler.is_some() {
        rsx! {
            input {
                // Key on the state value forces remount whenever the bound
                // state changes, so clamp-on-commit and external writes
                // are reflected in the DOM `.value` (which HTML inputs
                // otherwise keep stuck on the typed text).
                key: "{id}-{value}",
                id: "{id}",
                class: "jas-focusable",
                r#type: "number",
                min: "{min}",
                max: "{max}",
                step: "{step_attr}",
                value: "{value}",
                // flex-shrink:0 — when the parent row sets `flex:1`
                // on the slider, the slider's flex-grow eats remaining
                // space but the default flex-shrink:1 on the
                // number_input lets it collapse to ~16px on narrow
                // rows. Pinning shrink to 0 keeps the input at its
                // declared yaml width regardless of row width.
                // box-sizing:border-box so the yaml `width` includes
                // the border + padding, matching the visual size the
                // author asked for.
                style: "flex-shrink:0;box-sizing:border-box;color:var(--jas-text,#ccc);background:var(--jas-pane-bg-dark,#333);border:1px solid var(--jas-border,#555);padding:1px 4px;{style}",
                onchange: move |evt: Event<FormData>| {
                    if let Some(ref h) = panel_handler { h.call(evt); }
                },
            }
        }
    } else {
        rsx! {
            input {
                id: "{id}",
                class: "jas-focusable",
                r#type: "number",
                min: "{min}",
                max: "{max}",
                step: "{step_attr}",
                value: "{value}",
                style: "min-width:0;color:var(--jas-text,#ccc);background:var(--jas-pane-bg-dark,#333);border:1px solid var(--jas-border,#555);{style}",
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

/// Unit-aware length input — see UNIT_INPUTS.md.
///
/// Stored value is a `f64` in pt; the input displays it formatted with
/// the field's `unit:` suffix. On change the entered string is parsed
/// (any supported unit), validated against `min:` / `max:` (in pt),
/// and routed to the same per-panel dispatch as `number_input`. An
/// empty entry on a `nullable: true` widget commits `None`; on a
/// non-nullable widget it reverts.
fn render_length_input(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    use super::length;

    let id = get_id(el);
    let unit = el.get("unit").and_then(|u| u.as_str()).unwrap_or("pt").to_string();
    let precision = el
        .get("precision")
        .and_then(|p| p.as_u64())
        .map(|p| p as usize)
        .unwrap_or(2);
    let placeholder = el.get("placeholder").and_then(|p| p.as_str()).unwrap_or("").to_string();
    let nullable = el.get("nullable").and_then(|n| n.as_bool()).unwrap_or(false);
    let min_clamp = el.get("min").and_then(|m| m.as_f64());
    let max_clamp = el.get("max").and_then(|m| m.as_f64());
    let style = build_style(el, ctx);

    let bind_expr = el
        .get("bind")
        .and_then(|b| b.get("value"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let pt_value: Option<f64> = if !bind_expr.is_empty() {
        match expr::eval(bind_expr, ctx) {
            Value::Number(n) => Some(n),
            Value::Null => None,
            _ => None,
        }
    } else {
        None
    };
    let display_value = length::format(pt_value, &unit, precision);

    let bind_target = classify_bind(bind_expr);
    let panel_kind = rctx.panel_kind;
    let app = rctx.app.clone();
    let mut revision = rctx.revision;

    // Identity-coupled key forces remount when the underlying pt value
    // changes (clamp-on-commit, external writes), pulling the displayed
    // string back in lockstep — same trick `render_number_input` uses.
    let key_value = pt_value
        .map(|n| format!("{n:.6}"))
        .unwrap_or_else(|| "null".into());
    let key = format!("{id}-{key_value}");

    // Prebuild the per-frame closure inputs so the handler doesn't
    // close over the whole RenderCtx.
    let panel_handler = if let BindTarget::Panel(ref field) = bind_target {
        let f = field.clone();
        let app = app.clone();
        let unit = unit.clone();
        let mut revision = revision;
        Some(EventHandler::new(move |evt: Event<FormData>| {
            let entered = evt.value();
            // Empty / whitespace path.
            let trimmed = entered.trim();
            if trimmed.is_empty() {
                if !nullable {
                    // Revert via revision bump — re-render reads the
                    // bound state's current value back into the input.
                    revision += 1;
                    return;
                }
                // Nullable: write None via the same per-panel dispatch
                // as a numeric write below.
                let f = f.clone();
                let app = app.clone();
                let mut revision = revision;
                spawn(async move {
                    {
                        let mut st = app.borrow_mut();
                        match panel_kind {
                            Some(PanelKind::Character) => {
                                // Character panel ``leading`` is Auto when
                                // the element's line_height is empty;
                                // clearing the field re-derives the
                                // Auto-tracked value (font_size × 1.2)
                                // and the apply pipeline writes it back
                                // out as the empty element attribute. No
                                // other Character field is nullable yet.
                                if f == "leading" {
                                    st.character_panel.leading =
                                        st.character_panel.font_size * 1.2;
                                    st.apply_character_panel_to_selection();
                                }
                            }
                            Some(PanelKind::Stroke) | None => {
                                set_stroke_field(&mut st.stroke_panel, &f, &serde_json::Value::Null);
                                st.apply_stroke_panel_to_selection();
                            }
                            _ => {}
                        }
                    }
                    revision += 1;
                });
                return;
            }
            let Some(mut new_val) = length::parse(&entered, &unit) else {
                // Reject — bump revision so the input redisplays the
                // bound state's current value.
                revision += 1;
                return;
            };
            if let Some(lo) = min_clamp { if new_val < lo { new_val = lo; } }
            if let Some(hi) = max_clamp { if new_val > hi { new_val = hi; } }
            let f = f.clone();
            let app = app.clone();
            let mut revision = revision;
            spawn(async move {
                {
                    let mut st = app.borrow_mut();
                    match panel_kind {
                        Some(PanelKind::Character) => {
                            set_character_field(&mut st.character_panel, &f, &serde_json::json!(new_val));
                            st.character_panel_post_write(&f);
                            st.apply_character_panel_to_selection();
                        }
                        Some(PanelKind::Paragraph) => {
                            st.sync_paragraph_panel_from_selection();
                            set_paragraph_field(&mut st.paragraph_panel, &f, &serde_json::json!(new_val));
                            st.apply_paragraph_panel_to_selection();
                        }
                        Some(PanelKind::Stroke) | None => {
                            // Weight is the canonical "stroke width"
                            // path — mirror the number_input branch's
                            // app_default_stroke / per-tab.default_stroke
                            // sync so newly-drawn strokes inherit the
                            // edited weight.
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
                            } else {
                                set_stroke_field(&mut st.stroke_panel, &f, &serde_json::json!(new_val));
                            }
                            st.apply_stroke_panel_to_selection();
                        }
                        Some(PanelKind::Opacity) => {
                            set_opacity_field(&mut st.opacity_panel, &f, &serde_json::json!(new_val));
                        }
                        _ => {}
                    }
                }
                revision += 1;
            });
        }))
    } else {
        None
    };

    if panel_handler.is_some() {
        rsx! {
            input {
                key: "{key}",
                id: "{id}",
                r#type: "text",
                placeholder: "{placeholder}",
                value: "{display_value}",
                style: "min-width:0;color:var(--jas-text,#ccc);background:var(--jas-pane-bg-dark,#333);border:1px solid var(--jas-border,#555);{style}",
                onchange: move |evt: Event<FormData>| {
                    if let Some(ref h) = panel_handler { h.call(evt); }
                },
            }
        }
    } else {
        // Non-panel binding (dialog, none) — render read-only display.
        // Dialog support for length_input lands when the first dialog
        // length field needs it; for now treat as a passive display.
        rsx! {
            input {
                id: "{id}",
                r#type: "text",
                placeholder: "{placeholder}",
                value: "{display_value}",
                readonly: true,
                style: "min-width:0;color:var(--jas-text,#ccc);background:var(--jas-pane-bg-dark,#333);border:1px solid var(--jas-border,#555);{style}",
                oninput: move |_evt: Event<FormData>| {
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
    let visibility_style = if is_visible(el, ctx) { "" } else { "display:none;" };

    let bind_expr = read_bind_value(el);
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

    let bind_target = classify_bind(bind_expr);
    let mut dialog_signal = rctx.dialog_ctx.0;
    let mut revision = rctx.revision;
    let app = rctx.app.clone();
    let app_for_input = app.clone();
    let panel_kind = rctx.panel_kind;
    // Special case: layers panel search binding
    let is_search = bind_expr == "panel.search_query";
    // Read live value from AppState if search
    let value = if is_search {
        app.borrow().layers_search_query.clone()
    } else {
        value
    };

    // Artboards rename input: special-cased Enter/Escape/blur
    // handlers since the generic onchange path can't discover the
    // ab.id needed for confirm_artboard_rename. The YAML behavior
    // block declares the actions but the renderer fills params from
    // ctx (artboard_id) and from the input value (new_name).
    let is_artboard_rename = panel_kind == Some(PanelKind::Artboards) && id == "ap_name_edit";
    let rename_artboard_id: Option<String> = if is_artboard_rename {
        ctx.get("ab")
            .and_then(|a| a.get("id"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    } else {
        None
    };
    let app_for_keydown = app.clone();
    let app_for_blur = app.clone();
    let mut revision_keydown = revision;
    let mut revision_blur = revision;
    let rename_id_keydown = rename_artboard_id.clone();
    let rename_id_blur = rename_artboard_id.clone();

    rsx! {
        input {
            // Identity-coupled key forces remount when the bound
            // value changes externally (e.g. slider drag updates
            // the hex string via the live state map). Without this
            // the input keeps its DOM .value from first render and
            // the displayed text drifts out of sync with state.
            // While the user is actively typing, no state change
            // fires (text inputs commit on Enter/blur, not per
            // keystroke), so the remount only happens on external
            // updates and doesn't interrupt typing.
            key: "{id}-{value}",
            id: "{id}",
            r#type: "text",
            placeholder: "{placeholder}",
            initial_value: "{value}",
            autofocus: is_artboard_rename,
            style: "min-width:0;color:var(--jas-text,#ccc);background:var(--jas-pane-bg-dark,#333);border:1px solid var(--jas-border,#555);{visibility_style}{style}",
            onkeydown: move |evt: Event<KeyboardData>| {
                if !is_artboard_rename { return; }
                let key = evt.data().key();
                let Some(ref ab_id) = rename_id_keydown else { return; };
                if key == dioxus::prelude::Key::Enter {
                    let app = app_for_keydown.clone();
                    let id = ab_id.clone();
                    #[cfg(target_arch = "wasm32")]
                    let new_val = web_sys::window()
                        .and_then(|w| w.document())
                        .and_then(|d| d.get_element_by_id("ap_name_edit"))
                        .and_then(|el| js_sys::Reflect::get(&el, &"value".into()).ok())
                        .and_then(|v| v.as_string())
                        .unwrap_or_default();
                    #[cfg(not(target_arch = "wasm32"))]
                    let new_val = String::new();
                    spawn(async move {
                        let mut st = app.borrow_mut();
                        let mut params = serde_json::Map::new();
                        params.insert("artboard_id".into(), serde_json::Value::String(id));
                        params.insert("new_name".into(), serde_json::Value::String(new_val));
                        dispatch_action("confirm_artboard_rename", &params, &mut st);
                        revision_keydown += 1;
                    });
                } else if key == dioxus::prelude::Key::Escape {
                    let app = app_for_keydown.clone();
                    spawn(async move {
                        let mut st = app.borrow_mut();
                        let params = serde_json::Map::new();
                        dispatch_action("cancel_artboard_rename", &params, &mut st);
                        revision_keydown += 1;
                    });
                }
            },
            onblur: move |_: Event<FocusData>| {
                if !is_artboard_rename { return; }
                let Some(ref ab_id) = rename_id_blur else { return; };
                let app = app_for_blur.clone();
                let id = ab_id.clone();
                #[cfg(target_arch = "wasm32")]
                let new_val = web_sys::window()
                    .and_then(|w| w.document())
                    .and_then(|d| d.get_element_by_id("ap_name_edit"))
                    .and_then(|el| js_sys::Reflect::get(&el, &"value".into()).ok())
                    .and_then(|v| v.as_string())
                    .unwrap_or_default();
                #[cfg(not(target_arch = "wasm32"))]
                let new_val = String::new();
                spawn(async move {
                    let mut st = app.borrow_mut();
                    let mut params = serde_json::Map::new();
                    params.insert("artboard_id".into(), serde_json::Value::String(id));
                    params.insert("new_name".into(), serde_json::Value::String(new_val));
                    dispatch_action("confirm_artboard_rename", &params, &mut st);
                    revision_blur += 1;
                });
            },
            onchange: move |evt: Event<FormData>| {
                let new_val = evt.value();
                if is_search {
                    // search updates live via oninput below; change event is a no-op
                    return;
                }
                match &bind_target {
                    BindTarget::Dialog(field) => {
                        if let Some(mut ds) = dialog_signal() {
                            ds.set_value(field, serde_json::json!(new_val));
                            dialog_signal.set(Some(ds));
                        }
                        revision += 1;
                    }
                    BindTarget::Panel(field) => {
                        let f = field.clone();
                        let v = new_val.clone();
                        let app = app.clone();
                        let mut revision = revision;
                        spawn(async move {
                            {
                                let mut st = app.borrow_mut();
                                match panel_kind {
                                    Some(PanelKind::Character) => {
                                        set_character_field(&mut st.character_panel, &f, &serde_json::json!(v));
                                        st.character_panel_post_write(&f);
                                        st.apply_character_panel_to_selection();
                                    }
                                    Some(PanelKind::Paragraph) => {
                                        st.sync_paragraph_panel_from_selection();
                                        set_paragraph_field(&mut st.paragraph_panel, &f, &serde_json::json!(v));
                                        st.apply_paragraph_panel_to_selection();
                                    }
                                    Some(PanelKind::Stroke) | None => {
                                        set_stroke_field(&mut st.stroke_panel, &f, &serde_json::json!(v));
                                    }
                                    Some(PanelKind::Color) if f == "hex" => {
                                        // The Color panel's hex input is the only
                                        // text_input in that panel; commit it as
                                        // an active-color write so the canvas, the
                                        // sliders, and the recent-colors list all
                                        // pick up the change. Strip a leading '#'
                                        // (the YAML omits it from the bound value
                                        // but tolerate paste) and bail on invalid
                                        // input to avoid a no-op rebuild.
                                        let trimmed = v.trim().trim_start_matches('#');
                                        if let Some(mut color) = crate::geometry::element::Color::from_hex(trimmed) {
                                            // Web Safe RGB mode: snap each
                                            // channel to the nearest multiple
                                            // of 51 (0/51/102/153/204/255)
                                            // before commit. The sliders are
                                            // already step=51 but the hex
                                            // input is unrestricted, so the
                                            // snap has to happen here.
                                            if st.color_panel_mode == crate::workspace::color_panel_view::ColorMode::WebSafeRgb {
                                                let (r, g, b, _) = color.to_rgba();
                                                let snap = |c: f64| -> f64 {
                                                    let q = ((c * 255.0).round() / 51.0).round() * 51.0;
                                                    q / 255.0
                                                };
                                                color = crate::geometry::element::Color::rgb(
                                                    snap(r), snap(g), snap(b));
                                            }
                                            st.set_active_color(color);
                                        }
                                    }
                                    // Artboards, Layers, Swatches, Properties,
                                    // remaining Color fields: no-op until their
                                    // per-panel state lands.
                                    _ => {}
                                }
                            }
                            // Bump revision AFTER state mutation so the
                            // re-render sees the new state. Bumping
                            // outside the spawn would race with the
                            // async write and the renderer would pick
                            // up the pre-commit values.
                            revision += 1;
                        });
                    }
                    BindTarget::None => {
                        revision += 1;
                    }
                }
            },
            oninput: move |evt: Event<FormData>| {
                // The layers-panel search input still commits live, so
                // the tree filters as the user types. All other text
                // inputs commit on change (Enter / blur) to match the
                // number_input convention.
                if is_search {
                    let a = app_for_input.clone();
                    let v = evt.value();
                    spawn(async move {
                        a.borrow_mut().layers_search_query = v;
                        revision += 1;
                    });
                }
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
    let panel_kind = rctx.panel_kind;

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
                            match panel_kind {
                                Some(PanelKind::Character) => {
                                    set_character_field(&mut st.character_panel, &f, &serde_json::json!(v));
                                    st.character_panel_post_write(&f);
                                    st.apply_character_panel_to_selection();
                                }
                                Some(PanelKind::Paragraph) => {
                                    st.sync_paragraph_panel_from_selection();
                                    set_paragraph_field(&mut st.paragraph_panel, &f, &serde_json::json!(v));
                                    st.apply_paragraph_panel_to_selection();
                                }
                                Some(PanelKind::Stroke) | None => {
                                    set_stroke_field(&mut st.stroke_panel, &f, &serde_json::json!(v));
                                    st.apply_stroke_panel_to_selection();
                                }
                                Some(PanelKind::Opacity) => {
                                    set_opacity_field(&mut st.opacity_panel, &f, &serde_json::json!(v));
                                    // Phase 1: panel-local only; selection sync deferred.
                                }
                                // Artboards, Layers, Color, Swatches, Properties:
                                // no-op until their per-panel state lands.
                                _ => {}
                            }
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

/// `icon_select`: an icon-button-sized chooser that visually shows
/// the selected option's `glyph` (a single Unicode marker), with a
/// transparent native `<select>` overlaid for click-to-popup. The
/// OS handles the dropdown rendering, click-outside dismissal, and
/// keyboard nav for free.
///
/// Each option must carry: `value`, `label` (full readable text in
/// the native popup), and `glyph` (the icon-sized character shown
/// when collapsed). Falls back to first non-space char of `label`
/// when `glyph` is missing.
fn render_icon_select(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let summary = el.get("summary").and_then(|s| s.as_str()).unwrap_or("");
    let style = build_style(el, ctx);
    let options = el.get("options").and_then(|o| o.as_array()).cloned().unwrap_or_default();

    let bind_expr = el.get("bind").and_then(|b| b.get("value")).and_then(|v| v.as_str()).unwrap_or("");
    let current_value = if !bind_expr.is_empty() {
        match expr::eval(bind_expr, ctx) {
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

    // Resolve the visible glyph from the currently-selected option.
    let visible_glyph = options.iter()
        .find(|o| o.get("value").and_then(|v| v.as_str()) == Some(current_value.as_str()))
        .and_then(|o| {
            o.get("glyph").and_then(|v| v.as_str()).map(String::from).or_else(|| {
                o.get("label").and_then(|v| v.as_str()).and_then(|l| {
                    l.split_whitespace().next().map(String::from)
                })
            })
        })
        .unwrap_or_else(|| "—".to_string());

    // Optional SVG icon for the button face — when present, it
    // takes precedence over the per-option glyph so the button
    // identity matches the widget's purpose (e.g. para_bullets
    // always renders the "list of bullets" pictogram regardless
    // of which bullet is currently selected).
    let icon_name = el.get("icon").and_then(|i| i.as_str()).unwrap_or("");
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

    let bind_target = classify_bind(bind_expr);
    let mut dialog_signal = rctx.dialog_ctx.0;
    let app = rctx.app.clone();
    let mut revision = rctx.revision;
    let cv = current_value.clone();
    let panel_kind = rctx.panel_kind;

    let dim = if disabled { "opacity:0.4;cursor:not-allowed;" } else { "" };
    let select_cursor = if disabled { "not-allowed" } else { "pointer" };

    rsx! {
        div {
            id: "{id}",
            class: "jas-icon-toggle",
            title: "{summary}",
            style: "position:relative;display:inline-flex;align-items:center;justify-content:center;cursor:pointer;user-select:none;border-radius:2px;overflow:hidden;{dim}{style}",
            // Native select FIRST in source order so it sits at the
            // base of the stacking context; visible glyph div on top
            // with pointer-events:none so clicks pass through to the
            // select. The OS then handles the popup natively.
            select {
                value: "{current_value}",
                disabled: disabled,
                style: "position:absolute;inset:0;width:100%;height:100%;opacity:0;cursor:{select_cursor};border:none;background:transparent;font-size:11px;",
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
                                match panel_kind {
                                    Some(PanelKind::Character) => {
                                        set_character_field(&mut st.character_panel, &f, &serde_json::json!(v));
                                        st.character_panel_post_write(&f);
                                        st.apply_character_panel_to_selection();
                                    }
                                    Some(PanelKind::Paragraph) => {
                                        st.sync_paragraph_panel_from_selection();
                                        set_paragraph_field(&mut st.paragraph_panel, &f, &serde_json::json!(v));
                                        st.apply_paragraph_panel_to_selection();
                                    }
                                    Some(PanelKind::Stroke) | None => {
                                        set_stroke_field(&mut st.stroke_panel, &f, &serde_json::json!(v));
                                        st.apply_stroke_panel_to_selection();
                                    }
                                    _ => {}
                                }
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
            // Visible face sits ABOVE the select; pointer-events:none
            // so clicks reach the select underneath. Two layouts:
            //   - SVG icon present: 14x14 svg + tiny chevron
            //   - Glyph fallback: text glyph + tiny chevron
            div {
                style: "position:absolute;inset:0;display:flex;align-items:center;justify-content:center;gap:3px;color:var(--jas-text,#ccc);pointer-events:none;line-height:1;",
                if !icon_svg.is_empty() {
                    div {
                        style: "width:16px;height:16px;display:flex;align-items:center;justify-content:center;",
                        dangerous_inner_html: "{icon_svg}",
                    }
                } else {
                    span { style: "font-size:18px;", "{visible_glyph}" }
                }
                span { style: "font-size:9px;opacity:0.65;", "▾" }
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
    let panel_kind = rctx.panel_kind;

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
                                // Parse as number when possible (for
                                // scale percentages, stroke-arrowhead
                                // preset selections). Named values
                                // stay as strings (kerning Auto /
                                // Optical / Metrics).
                                let json_val = if let Ok(n) = v.parse::<f64>() {
                                    serde_json::json!(n)
                                } else {
                                    serde_json::json!(v)
                                };
                                match panel_kind {
                                    Some(PanelKind::Character) => {
                                        set_character_field(&mut st.character_panel, &f, &json_val);
                                        st.character_panel_post_write(&f);
                                        st.apply_character_panel_to_selection();
                                    }
                                    Some(PanelKind::Paragraph) => {
                                        st.sync_paragraph_panel_from_selection();
                                        set_paragraph_field(&mut st.paragraph_panel, &f, &json_val);
                                        st.apply_paragraph_panel_to_selection();
                                    }
                                    Some(PanelKind::Stroke) | None => {
                                        set_stroke_field(&mut st.stroke_panel, &f, &json_val);
                                        st.apply_stroke_panel_to_selection();
                                    }
                                    // Other panels: no-op until their
                                    // per-panel state structs land.
                                    _ => {}
                                }
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
    let summary = el.get("summary").and_then(|s| s.as_str()).unwrap_or("");
    let style = build_style(el, ctx);

    // Accept either bind.value, bind.checked, or a bare-string bind;
    // panels prefer object form with `value`, dialog YAML often uses
    // a bare-string form (`bind: "dialog.x"`).
    let bind_expr = el.get("bind").and_then(|b| b.get("value")).and_then(|v| v.as_str())
        .or_else(|| el.get("bind").and_then(|b| b.get("checked")).and_then(|v| v.as_str()))
        .or_else(|| el.get("bind").and_then(|b| b.as_str()))
        .unwrap_or("");
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
    let bind_expr_owned = bind_expr.to_string();
    let mut dialog_signal = rctx.dialog_ctx.0;
    let app = rctx.app.clone();
    let mut revision = rctx.revision;
    let on_click = build_click_handler(el, ctx, rctx);
    let panel_kind = rctx.panel_kind;

    // Optional icon field: when present the toggle renders as a
    // square icon button (matching icon_toggle semantics per
    // CHARACTER.md) instead of a checkbox-plus-label row.
    let icon_name = el.get("icon").and_then(|i| i.as_str()).unwrap_or("");
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

    let bg_style = if checked {
        "background:var(--jas-button-checked,#505050);".to_string()
    } else {
        String::new()
    };
    let dim = if disabled { "opacity:0.4;" } else { "" };

    let onclick = move |evt: Event<MouseData>| {
        if disabled { return; }
        if let Some(ref handler) = on_click {
            handler.call(evt);
            return;
        }
        let new_val = !checked;
        // Opacity panel selection-mask bindings: `selection_mask_clip` /
        // `selection_mask_invert` route directly to Controller methods
        // (the flag lives on the selected element's mask, not on the
        // panel-local state). See OPACITY.md § States.
        if panel_kind == Some(PanelKind::Opacity) {
            let handled = match bind_expr_owned.as_str() {
                "selection_mask_clip" => {
                    let app = app.clone();
                    spawn(async move {
                        let mut st = app.borrow_mut();
                        if let Some(tab) = st.tab_mut() {
                            crate::document::controller::Controller::set_mask_clip_on_selection(&mut tab.model, new_val);
                        }
                    });
                    true
                }
                "selection_mask_invert" => {
                    let app = app.clone();
                    spawn(async move {
                        let mut st = app.borrow_mut();
                        if let Some(tab) = st.tab_mut() {
                            crate::document::controller::Controller::set_mask_invert_on_selection(&mut tab.model, new_val);
                        }
                    });
                    true
                }
                _ => false,
            };
            if handled {
                revision += 1;
                return;
            }
        }
        match &bind_target {
            BindTarget::Dialog(field) => {
                if let Some(mut ds) = dialog_signal() {
                    ds.set_value(field, serde_json::json!(new_val));
                    // Color-picker "Only Web Colors": when toggled on,
                    // snap the working color to the nearest web-safe
                    // (each RGB channel rounded to multiples of 51).
                    // Use get_value (not ds.state) so the read goes
                    // through the YAML get-lambdas — the stored R/G/B
                    // are init-only and go stale once the user edits
                    // color via the gradient/hue bar/hex.
                    if field == "web_only" && new_val {
                        let snap = |x: i64| -> i64 {
                            let v = ((x as f64) / 51.0).round() * 51.0;
                            v.clamp(0.0, 255.0) as i64
                        };
                        let to_i = |v: serde_json::Value| -> i64 {
                            v.as_i64()
                                .or_else(|| v.as_f64().map(|n| n.round() as i64))
                                .unwrap_or(0)
                        };
                        let cur_r = to_i(ds.get_value("r"));
                        let cur_g = to_i(ds.get_value("g"));
                        let cur_bl = to_i(ds.get_value("bl"));
                        ds.set_value("r", serde_json::json!(snap(cur_r)));
                        ds.set_value("g", serde_json::json!(snap(cur_g)));
                        ds.set_value("bl", serde_json::json!(snap(cur_bl)));
                    }
                    dialog_signal.set(Some(ds));
                }
            }
            BindTarget::Panel(field) => {
                let f = field.clone();
                let app = app.clone();
                let mut rev_signal = revision;
                spawn(async move {
                    {
                        let mut st = app.borrow_mut();
                        match panel_kind {
                            Some(PanelKind::Character) => {
                                set_character_field(&mut st.character_panel, &f, &serde_json::json!(new_val));
                                st.character_panel_post_write(&f);
                                st.apply_character_panel_to_selection();
                            }
                            Some(PanelKind::Paragraph) => {
                                // Sync first so untouched fields hold the
                                // selection's current values, not stale
                                // panel state, before the new field is set
                                // and the whole panel is re-applied.
                                st.sync_paragraph_panel_from_selection();
                                set_paragraph_field(&mut st.paragraph_panel, &f, &serde_json::json!(new_val));
                                st.apply_paragraph_panel_to_selection();
                            }
                            Some(PanelKind::Stroke) | None => {
                                set_stroke_field(&mut st.stroke_panel, &f, &serde_json::json!(new_val));
                            }
                            _ => {}
                        }
                    }
                    // Bump revision *after* the state mutation so the
                    // re-render sees the new panel state. Bumping
                    // synchronously outside spawn fires a render before
                    // the async block runs — first click looks like a
                    // no-op, second click renders the first click's
                    // state.
                    rev_signal += 1;
                });
                return;
            }
            BindTarget::None => {}
        }
        revision += 1;
    };

    if !icon_svg.is_empty() {
        rsx! {
            div {
                id: "{id}",
                class: "jas-icon-toggle",
                title: "{summary}",
                style: "display:inline-flex;align-items:center;justify-content:center;cursor:pointer;user-select:none;border-radius:2px;{bg_style}{dim}{style}",
                onclick: onclick,
                div {
                    style: "width:100%;height:100%;display:flex;align-items:center;justify-content:center;pointer-events:none;",
                    dangerous_inner_html: "{icon_svg}",
                }
            }
        }
    } else {
        let check_icon = if checked { "\u{2611}" } else { "\u{2610}" };
        rsx! {
            div {
                id: "{id}",
                title: "{summary}",
                style: "display:flex;align-items:center;gap:4px;font-size:11px;color:var(--jas-text,#ccc);cursor:pointer;user-select:none;{dim}{style}",
                onclick: onclick,
                span { style: "font-size:14px;", "{check_icon}" }
                "{label_text}"
            }
        }
    }
}

/// Partition a radio's `on_check` effects into live-dialog writes and
/// residual effects.
///
/// `set: { dialog.<field>: <expr> }` pairs are pulled out and returned as
/// `(field, evaluated_value)` so the caller can route them straight to the
/// live `DialogState` (the same path every dialog widget uses). The dialog
/// values are expression STRINGS ("true"/"false") and are evaluated here
/// against `ctx`. Every other effect (and any non-`dialog.` keys inside a
/// `set:` map) is returned verbatim in the second vec to run through the
/// normal AppState effect runner. Mirrors the dialog arm of
/// `effects.rs::set_by_scoped_target` for the live Dioxus dialog signal.
fn partition_on_check_effects(
    on_check: &[serde_json::Value],
    ctx: &serde_json::Value,
) -> (Vec<(String, serde_json::Value)>, Vec<serde_json::Value>) {
    let mut dialog_writes: Vec<(String, serde_json::Value)> = Vec::new();
    let mut other_effects: Vec<serde_json::Value> = Vec::new();
    for effect in on_check {
        if let Some(set_map) = effect.get("set").and_then(|v| v.as_object()) {
            let mut residual_set = serde_json::Map::new();
            for (k, v) in set_map {
                let target = k.strip_prefix('$').unwrap_or(k);
                if let Some(field) = target.strip_prefix("dialog.") {
                    let val = if let Some(s) = v.as_str() {
                        super::effects::value_to_json(&expr::eval(s, ctx))
                    } else {
                        v.clone()
                    };
                    dialog_writes.push((field.to_string(), val));
                } else {
                    residual_set.insert(k.clone(), v.clone());
                }
            }
            if !residual_set.is_empty() {
                other_effects.push(serde_json::json!({ "set": residual_set }));
            }
        } else {
            other_effects.push(effect.clone());
        }
    }
    (dialog_writes, other_effects)
}

/// Render a single radio button: a circular indicator filled when
/// `bind.checked` is truthy, followed by a label. Clicking (when not
/// disabled) runs the element's `on_check` effects — a standard effects
/// list, e.g. `[{ set: { dialog.uniform: "true" } }]`. The Scale / Shear
/// option dialogs use it for the Uniform / Non-Uniform mode selector
/// (the Python/Swift/OCaml renderers match it).
///
/// The circular indicator reuses the native `<input type="radio">` (as
/// `render_radio_group` does) so the filled / hollow state is the browser's
/// radio glyph driven by the evaluated `bind.checked` expression. Clicking
/// the row routes any `set: { dialog.<field> }` directly to the live dialog
/// state (`DialogState::set_value`) — the same path every dialog widget
/// uses — and runs any remaining effects through the AppState effect runner.
/// `bind.disabled` (when truthy) suppresses the click and dims the row.
fn render_radio(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let label = el.get("label").and_then(|l| l.as_str()).unwrap_or("").to_string();

    let checked_expr = el.get("bind").and_then(|b| b.get("checked")).and_then(|v| v.as_str()).unwrap_or("");
    let checked = if checked_expr.is_empty() {
        false
    } else {
        expr::eval(checked_expr, ctx).to_bool()
    };
    let checked_attr = if checked { "true" } else { "false" };

    let disabled = el.get("bind")
        .and_then(|b| b.get("disabled"))
        .and_then(|v| v.as_str())
        .map(|e| expr::eval(e, ctx).to_bool())
        .unwrap_or(false);

    // on_check is a standard effects list. Snapshot it for the click handler.
    let on_check: Vec<serde_json::Value> = el.get("on_check")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    let mut dialog_signal = rctx.dialog_ctx.0;
    let app = rctx.app.clone();
    let mut revision = rctx.revision;
    let ctx_snapshot = ctx.clone();
    let extra_style = build_style(el, ctx);

    let dim = if disabled { "opacity:0.4;" } else { "" };
    let cursor = if disabled { "default" } else { "pointer" };

    let onclick = move |_evt: Event<MouseData>| {
        if disabled { return; }
        if on_check.is_empty() { return; }
        let on_check = on_check.clone();
        let ctx_snap = ctx_snapshot.clone();
        let app = app.clone();
        spawn(async move {
            // Partition each `set:` map into dialog-scoped writes (routed to
            // the live DialogState) and everything else (routed through the
            // AppState effect runner). on_check values are expression STRINGS
            // ("true"/"false"), evaluated by the helper just like every other
            // set value.
            let (dialog_writes, other_effects) =
                partition_on_check_effects(&on_check, &ctx_snap);

            // Apply dialog-scoped writes to the live dialog state.
            if !dialog_writes.is_empty() {
                if let Some(mut ds) = dialog_signal() {
                    for (field, val) in &dialog_writes {
                        ds.set_value(field, val.clone());
                    }
                    dialog_signal.set(Some(ds));
                }
            }

            // Run any remaining (non-dialog) effects through the normal runner.
            if !other_effects.is_empty() {
                let mut st = app.borrow_mut();
                run_effects_with_ctx(&other_effects, Some(&ctx_snap), &mut st);
            }

            revision += 1;
        });
    };

    rsx! {
        label {
            id: "{id}",
            style: "display:inline-flex;align-items:center;gap:6px;margin:0;cursor:{cursor};{dim}{extra_style}",
            onclick: onclick,
            input {
                r#type: "radio",
                checked: "{checked_attr}",
                disabled: disabled,
                // The wrapping label drives the click; keep the native glyph
                // purely presentational so the row click is the single source.
                style: "pointer-events:none;margin:0;",
            }
            if !label.is_empty() {
                span { style: "color:var(--jas-text,#ccc);", "{label}" }
            }
        }
    }
}

/// Render a group of radio buttons sharing a single bound value.
///
/// Each entry in `options` is `{id, label}`; when `option.id` equals the
/// current bind value the radio is checked. Click sets the bind to the
/// option's id. The Color Picker uses one option per row to select
/// which channel maps to the colorbar axis (see workspace YAML
/// `radio_field_row` template + `color_picker` dialog).
fn render_radio_group(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let bind_expr = el.get("bind").and_then(|b| b.as_str()).unwrap_or("");
    let current = match expr::eval(bind_expr, ctx) {
        Value::Str(s) => s,
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        _ => String::new(),
    };

    let options: Vec<(String, String)> = el.get("options")
        .and_then(|o| o.as_array())
        .map(|arr| arr.iter().map(|opt| {
            let oid = opt.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string();
            let lbl = opt.get("label").and_then(|v| v.as_str()).unwrap_or("").to_string();
            (oid, lbl)
        }).collect())
        .unwrap_or_default();

    let bind_target = classify_bind(bind_expr);
    let mut dialog_signal = rctx.dialog_ctx.0;
    let app = rctx.app.clone();
    let mut revision = rctx.revision;

    let group_name = if bind_expr.is_empty() { id.clone() } else { bind_expr.to_string() };

    let _ = app;
    let radios: Vec<Element> = options.into_iter().map(|(oid, label)| {
        let checked = oid == current;
        let checked_attr = if checked { "true" } else { "false" };
        let input_id = format!("{}_{}", id, oid);
        let oid_for_click = oid.clone();
        let bind_target = bind_target.clone();
        let group = group_name.clone();
        rsx! {
            label {
                style: "display:inline-flex;align-items:center;gap:4px;margin:0;cursor:pointer;",
                input {
                    r#type: "radio",
                    name: "{group}",
                    id: "{input_id}",
                    value: "{oid}",
                    checked: "{checked_attr}",
                    onchange: move |_| {
                        let oid = oid_for_click.clone();
                        if let BindTarget::Dialog(field) = &bind_target {
                            if let Some(mut ds) = dialog_signal() {
                                ds.set_value(field, serde_json::json!(oid));
                                dialog_signal.set(Some(ds));
                            }
                        }
                        revision += 1;
                    },
                }
                if !label.is_empty() {
                    span { "{label}" }
                }
            }
        }
    }).collect();

    let extra_style = build_style(el, ctx);
    rsx! {
        span {
            id: "{id}",
            style: "display:inline-flex;gap:6px;align-items:center;{extra_style}",
            for r in radios {
                {r}
            }
        }
    }
}

fn render_color_swatch(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    // Size resolution: top-level `size: "<small|medium|large>"` (used by
    // library swatches whose size follows panel.thumbnail_size) takes
    // precedence over `style: { size: N }` (used by the fixed-size
    // recent-colors row and other tile widgets). Element-level
    // attributes aren't auto-interpolated, so resolve `{{...}}` templates
    // here.
    let size: u64 = if let Some(raw) = el.get("size").and_then(|v| v.as_str()) {
        let resolved = if raw.contains("{{") {
            expr::eval_text(raw, ctx)
        } else {
            raw.to_string()
        };
        match resolved.as_str() {
            "small" => 16,
            "medium" => 32,
            "large" => 64,
            _ => 16,
        }
    } else {
        el.get("style")
            .and_then(|s| s.get("size"))
            .and_then(|s| s.as_u64())
            .unwrap_or(16)
    };

    // Returns (color_string, explicit_none). explicit_none=true marks
    // the "intentionally no fill / no stroke" case (eval returns the
    // empty string), distinct from "missing bind / unset slot" which
    // also returns empty but should render as a hollow placeholder
    // rather than the red-diagonal "no fill" indicator. Bare hex
    // strings without a leading '#' (recent_colors stores them that
    // way) are also valid colors and need a '#' prepended.
    let (color, explicit_none) = if let Some(bind_color) = el.get("bind").and_then(|b| b.get("color")).and_then(|v| v.as_str()) {
        // Handle "#expr" pattern: "#dialog.hex" means "#" + eval("dialog.hex")
        if bind_color.starts_with('#') && bind_color.contains('.') {
            let inner = &bind_color[1..];
            let result = expr::eval(inner, ctx);
            match result {
                Value::Str(s) if !s.is_empty() => (format!("#{s}"), false),
                Value::Color(c) => (c, false),
                Value::Str(_) => (String::new(), true),
                _ => (String::new(), false),
            }
        } else {
            let result = expr::eval(bind_color, ctx);
            match result {
                Value::Color(c) => (c, false),
                Value::Str(s) if s.starts_with('#') => (s, false),
                Value::Str(s) if !s.is_empty() => (format!("#{s}"), false),
                Value::Str(_) => (String::new(), true),
                _ => (String::new(), false),
            }
        }
    } else {
        (String::new(), false)
    };

    let bg = if color.is_empty() { "transparent".to_string() } else { color.clone() };
    let border = if color.is_empty() { "1px dashed var(--jas-border,#555)" } else { "1px solid var(--jas-border,#666)" };
    // hollow may be a static attribute OR a bind expression. The Color
    // panel's stroke swatch uses bind.hollow = "not state.fill_on_top"
    // so the active swatch renders as a solid filled square (visually
    // dominating the inactive one) and the inactive renders as the
    // standard hollow ring.
    let hollow = el.get("bind")
        .and_then(|b| b.get("hollow"))
        .and_then(|v| v.as_str())
        .map(|expr| expr::eval(expr, ctx).to_bool())
        .unwrap_or_else(|| el.get("hollow").and_then(|h| h.as_bool()).unwrap_or(false));

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

    // bind.selected_in: <list-expr> — when present, the renderer
    // evaluates both the list and the widget's per-item identity (read
    // from the click behavior's first `select.target` so authors don't
    // have to repeat it). If the identity is in the list, draw a 2px
    // accent outline. Falls back to the regular border otherwise.
    let selected = el.get("bind")
        .and_then(|b| b.get("selected_in"))
        .and_then(|v| v.as_str())
        .map(|list_expr| {
            let list_val = expr::eval(list_expr, ctx);
            let id_expr = el.get("behavior")
                .and_then(|b| b.as_array())
                .and_then(|behaviors| {
                    behaviors.iter().find_map(|b| {
                        let effects = b.get("effects").and_then(|v| v.as_array())?;
                        effects.iter().find_map(|e| {
                            e.get("select")
                                .and_then(|s| s.get("target"))
                                .and_then(|v| v.as_str())
                                .map(|s| s.to_string())
                        })
                    })
                });
            let id_val = id_expr.map(|expr| expr::eval(&expr, ctx));
            list_contains_value(&list_val, id_val.as_ref())
        })
        .unwrap_or(false);

    // Selected: 2px macOS-system-blue (#007aff) outline replacing
    // the 1px border. Matches JasSwift's renderColorSwatch which
    // uses SwiftUI.Color.accentColor (defaults to #007aff on macOS
    // across light/dark mode). Cross-port parity: the same selection
    // color appears in both ports regardless of theme appearance.
    let final_border = if selected {
        "2px solid #007aff"
    } else {
        border
    };
    let selected_halo = "";

    // Diagonal "no fill" indicator only when the bind explicitly
    // resolved to an empty color (FillSummary::Uniform(None) etc.).
    // Empty / unbound recent slots stay as plain hollow placeholders.
    let is_none = explicit_none;
    // Make "no fill / no stroke" swatches white so the red diagonal
    // reads against a clean background (matches Illustrator /
    // Photoshop / OCaml + Python ports). Without this the swatch was
    // a transparent rectangle that just inherited the toolbar bg.
    let none_bg = if is_none { "#fff" } else { bg.as_str() };
    let style = if hollow {
        // Hollow ("stroke") swatch: a thick colored border around a
        // transparent center. When stroke is None, render the border
        // as white (instead of transparent + invisible) so the user
        // sees a hollow ring with the red diagonal across it —
        // matches Illustrator's no-stroke indicator.
        let hollow_border = if is_none { "#fff" } else { bg.as_str() };
        format!("width:{size}px;height:{size}px;background:transparent;border:6px solid {hollow_border};cursor:pointer;box-sizing:border-box;position:relative;{z_style}{extra_style}")
    } else {
        format!("width:{size}px;height:{size}px;background:{none_bg};border:{final_border};{selected_halo}cursor:pointer;box-sizing:border-box;position:relative;{z_style}{extra_style}")
    };

    let on_click = build_click_handler(el, ctx, rctx);
    let on_dblclick = build_dblclick_handler(el, ctx, rctx);

    // Diagonal "no fill" indicator — drawn via dangerous_inner_html
    // since Dioxus rsx! emits SVG tags into the HTML namespace by
    // default and the browser would ignore them.
    const NONE_DIAG_SVG: &str = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100' preserveAspectRatio='none' style='position:absolute;top:0;left:0;width:100%;height:100%;pointer-events:none;'><line x1='0' y1='100' x2='100' y2='0' stroke='red' stroke-width='8'/></svg>";

    rsx! {
        div {
            id: "{id}",
            class: "jas-swatch-tile",
            style: "{style}",
            onclick: move |evt| { if let Some(ref h) = on_click { h.call(evt); } },
            ondoubleclick: move |evt| { if let Some(ref h) = on_dblclick { h.call(evt); } },
            if is_none {
                div {
                    style: "position:absolute;top:0;left:0;width:100%;height:100%;pointer-events:none;",
                    dangerous_inner_html: "{NONE_DIAG_SVG}",
                }
            }
        }
    }
}

/// Test whether `id` is a member of the list `list`. Used by the
/// `selected_in` bind on `color_swatch` and other tile widgets.
fn list_contains_value(list: &Value, id: Option<&Value>) -> bool {
    let Some(id) = id else { return false; };
    let id_json = super::effects::value_to_json(id);
    match list {
        Value::List(items) => items.iter().any(|item| item == &id_json),
        _ => false,
    }
}

/// Evaluate a bind expression and parse its result back to a JSON value.
///
/// The expression language serializes objects (like a gradient value) to a
/// JSON string via `Value::Str`. This helper reverses that so widget code
/// can read structured fields back out.
fn eval_bind_object(expr: &str, ctx: &serde_json::Value) -> Option<serde_json::Value> {
    let v = expr::eval(expr, ctx);
    match v {
        Value::Str(s) => serde_json::from_str::<serde_json::Value>(&s).ok(),
        Value::List(items) => Some(serde_json::Value::Array(items)),
        _ => None,
    }
}

/// Build a CSS background from a gradient JSON value.
fn gradient_css_background(gradient: &serde_json::Value) -> Option<String> {
    let stops = gradient.get("stops")?.as_array()?;
    if stops.len() < 2 {
        return None;
    }
    let mut stop_strs = Vec::new();
    for s in stops {
        let color = s.get("color").and_then(|v| v.as_str()).unwrap_or("#000000");
        let loc = s.get("location").and_then(|v| v.as_f64()).unwrap_or(0.0);
        let opacity = s.get("opacity").and_then(|v| v.as_f64()).unwrap_or(100.0);
        let color_css = if opacity < 100.0 && color.starts_with('#') && color.len() == 7 {
            let r = u8::from_str_radix(&color[1..3], 16).unwrap_or(0);
            let g = u8::from_str_radix(&color[3..5], 16).unwrap_or(0);
            let b = u8::from_str_radix(&color[5..7], 16).unwrap_or(0);
            format!("rgba({},{},{},{:.3})", r, g, b, opacity / 100.0)
        } else {
            color.to_string()
        };
        stop_strs.push(format!("{} {}%", color_css, loc));
    }
    let gtype = gradient.get("type").and_then(|v| v.as_str()).unwrap_or("linear");
    if gtype == "radial" {
        Some(format!("radial-gradient(circle, {})", stop_strs.join(", ")))
    } else {
        let angle = gradient.get("angle").and_then(|v| v.as_f64()).unwrap_or(0.0);
        // Our angle convention: 0 = horizontal (to-right). CSS linear-gradient
        // angle: 0deg is bottom-to-top, 90deg is left-to-right. So CSS angle =
        // 90 - angle.
        let css_angle = ((90.0 - angle).rem_euclid(360.0)) as i64;
        Some(format!("linear-gradient({}deg, {})", css_angle, stop_strs.join(", ")))
    }
}

/// gradient_tile — clickable gradient preview; click fires the behavior list.
fn render_gradient_tile(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let size_key = el.get("size").and_then(|v| v.as_str()).unwrap_or("large");
    let sz: i64 = match size_key { "small" => 16, "medium" => 32, _ => 64 };

    let gradient_expr = el.get("bind")
        .and_then(|b| b.get("gradient"))
        .and_then(|v| v.as_str());
    let bg = gradient_expr
        .and_then(|e| eval_bind_object(e, ctx))
        .and_then(|g| gradient_css_background(&g))
        .unwrap_or_else(|| "#888".to_string());

    let on_click = build_click_handler(el, ctx, rctx);

    let data_bind = gradient_expr.map(|s| s.to_string()).unwrap_or_default();

    rsx! {
        div {
            id: "{id}",
            class: "jas-gradient-tile",
            "data-type": "gradient-tile",
            "data-bind-gradient": "{data_bind}",
            style: "width:{sz}px;height:{sz}px;background:{bg};border:1px solid var(--jas-border,#555);box-sizing:border-box;cursor:pointer;",
            onclick: move |evt| { if let Some(ref h) = on_click { h.call(evt); } },
        }
    }
}

/// gradient_slider — 1-D color-stops editor.
///
/// Phase 0 scope: renders the bar + stop markers + midpoint markers with
/// click / dblclick handlers. Full pointer drag state machine (drag, drag
/// past neighbor, drag-off-bar delete) is deferred to Phase 5 when the
/// action pipeline is wired. Keyboard handlers are similarly deferred.
fn render_gradient_slider(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let stops_expr = el.get("bind").and_then(|b| b.get("stops")).and_then(|v| v.as_str());
    let sel_stop_expr = el.get("bind").and_then(|b| b.get("selected_stop_index")).and_then(|v| v.as_str());
    let sel_mid_expr = el.get("bind").and_then(|b| b.get("selected_midpoint_index")).and_then(|v| v.as_str());

    let stops = stops_expr.and_then(|e| eval_bind_object(e, ctx));
    let stops_arr: Vec<serde_json::Value> = stops
        .as_ref()
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    let sel_stop: i64 = sel_stop_expr
        .map(|e| match expr::eval(e, ctx) { Value::Number(n) => n as i64, _ => -1 })
        .unwrap_or(-1);
    let sel_mid: i64 = sel_mid_expr
        .map(|e| match expr::eval(e, ctx) { Value::Number(n) => n as i64, _ => -1 })
        .unwrap_or(-1);

    // Build a linear preview of the stops for the bar background.
    let bar_bg = if stops_arr.len() >= 2 {
        let preview = serde_json::json!({
            "type": "linear",
            "angle": 0,
            "stops": stops_arr.clone(),
        });
        gradient_css_background(&preview).unwrap_or_else(|| "#888".to_string())
    } else {
        "#888".to_string()
    };

    let on_click = build_click_handler(el, ctx, rctx);

    let stops_bind = stops_expr.map(|s| s.to_string()).unwrap_or_default();
    let sel_stop_bind = sel_stop_expr.map(|s| s.to_string()).unwrap_or_default();
    let sel_mid_bind = sel_mid_expr.map(|s| s.to_string()).unwrap_or_default();

    // Build midpoint and stop markers as Element lists so the rsx! macro can
    // splice them in.
    let mut midpoint_markers: Vec<Element> = Vec::new();
    for i in 0..stops_arr.len().saturating_sub(1) {
        let left = stops_arr[i].get("location").and_then(|v| v.as_f64()).unwrap_or(0.0);
        let right = stops_arr[i + 1].get("location").and_then(|v| v.as_f64()).unwrap_or(100.0);
        let pct = stops_arr[i].get("midpoint_to_next").and_then(|v| v.as_f64()).unwrap_or(50.0);
        let mid_loc = left + (right - left) * (pct / 100.0);
        let sel_class = if sel_mid == i as i64 { " jas-gradient-midpoint-selected" } else { "" };
        midpoint_markers.push(rsx! {
            div {
                class: "jas-gradient-midpoint{sel_class}",
                "data-role": "midpoint",
                "data-midpoint-index": "{i}",
                style: "position:absolute;left:calc({mid_loc}% - 5px);top:2px;width:10px;height:10px;transform:rotate(45deg);background:#888;border:1px solid #333;box-sizing:border-box;cursor:grab;",
            }
        });
    }

    let mut stop_markers: Vec<Element> = Vec::new();
    for (i, s) in stops_arr.iter().enumerate() {
        let loc = s.get("location").and_then(|v| v.as_f64()).unwrap_or(0.0);
        let color = s.get("color").and_then(|v| v.as_str()).unwrap_or("#000000").to_string();
        let sel_class = if sel_stop == i as i64 { " jas-gradient-stop-selected" } else { "" };
        stop_markers.push(rsx! {
            div {
                class: "jas-gradient-stop{sel_class}",
                "data-role": "stop",
                "data-stop-index": "{i}",
                style: "position:absolute;left:calc({loc}% - 7px);top:30px;width:14px;height:14px;border-radius:50%;background:{color};border:1.5px solid #333;box-sizing:border-box;cursor:grab;",
            }
        });
    }

    rsx! {
        div {
            id: "{id}",
            class: "jas-gradient-slider",
            "data-type": "gradient-slider",
            "data-bind-stops": "{stops_bind}",
            "data-bind-selected-stop-index": "{sel_stop_bind}",
            "data-bind-selected-midpoint-index": "{sel_mid_bind}",
            tabindex: "0",
            style: "position:relative;width:100%;height:44px;box-sizing:border-box;outline:none;",
            onclick: move |evt| { if let Some(ref h) = on_click { h.call(evt); } },
            div {
                class: "jas-gradient-slider-bar",
                "data-role": "bar",
                style: "position:absolute;left:0;right:0;top:14px;height:16px;background:{bar_bg};border:1px solid var(--jas-border,#555);box-sizing:border-box;cursor:crosshair;",
            }
            {midpoint_markers.into_iter()}
            {stop_markers.into_iter()}
        }
    }
}

fn render_color_bar(_el: &serde_json::Value, _ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    use crate::geometry::element::Color;

    let data_uri = crate::workspace::color_panel_view::build_color_bar_data_uri();
    let app = rctx.app.clone();
    let mut revision = rctx.revision;

    // Maps an (x, y) inside the bar to an HSB color following the
    // same gradient convention as build_color_bar_data_uri.
    let xy_to_color = |x: f64, y: f64, width: f64| -> Color {
        let height = 64.0_f64;
        let hue = (360.0 * x / width.max(1.0)).clamp(0.0, 360.0);
        let mid_y = height / 2.0;
        let (sat, br) = if y <= mid_y {
            let t = (y / mid_y).clamp(0.0, 1.0);
            (t * 100.0, 100.0 - t * 20.0)
        } else {
            let t = ((y - mid_y) / (height - mid_y)).clamp(0.0, 1.0);
            (100.0, 80.0 * (1.0 - t))
        };
        let (r, g, b) = crate::interpreter::color_util::hsb_to_rgb(hue, sat, br);
        Color::rgb(r as f64 / 255.0, g as f64 / 255.0, b as f64 / 255.0)
    };

    let read_width = || -> f64 {
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

    let app_down = app.clone();
    let app_move = app.clone();
    let app_up = app.clone();
    let mut rev_down = revision;
    let mut rev_move = revision;
    let mut rev_up = revision;

    rsx! {
        div {
            id: "jas-yaml-color-bar",
            style: "width:100%;height:64px;cursor:crosshair;border:1px solid var(--jas-border,#555);border-radius:1px;background-image:url('{data_uri}');background-size:100% 100%;background-repeat:no-repeat;user-select:none;-webkit-user-drag:none;",
            // Pointer-driven drag: down → set_active_color_live, move
            // (with button held) → live updates, up → final
            // set_active_color which pushes to recent. The element is
            // a div (not an img) so the browser doesn't intercept the
            // drag with native image-drag.
            onmousedown: move |evt: Event<MouseData>| {
                evt.stop_propagation();
                let coords = evt.data().element_coordinates();
                let color = xy_to_color(coords.x, coords.y, read_width());
                let app = app_down.clone();
                spawn(async move {
                    app.borrow_mut().set_active_color_live(color);
                    rev_down += 1;
                });
            },
            onmousemove: move |evt: Event<MouseData>| {
                if !evt.data().held_buttons().contains(dioxus::html::input_data::MouseButton::Primary) {
                    return;
                }
                let coords = evt.data().element_coordinates();
                let color = xy_to_color(coords.x, coords.y, read_width());
                let app = app_move.clone();
                spawn(async move {
                    app.borrow_mut().set_active_color_live(color);
                    rev_move += 1;
                });
            },
            onmouseup: move |evt: Event<MouseData>| {
                let coords = evt.data().element_coordinates();
                let color = xy_to_color(coords.x, coords.y, read_width());
                let app = app_up.clone();
                spawn(async move {
                    app.borrow_mut().set_active_color(color);
                    rev_up += 1;
                });
            },
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

    let _ = rctx.app.clone();
    let mut dialog_signal = rctx.dialog_ctx.0;
    let mut rev_down = rctx.revision;
    let mut rev_move = rctx.revision;

    let xy_to_sb = move |x: f64, y: f64| -> (f64, f64) {
        let width = 180.0_f64;
        let height = 180.0_f64;
        let sat = (x / width * 100.0).clamp(0.0, 100.0);
        let bri = ((1.0 - y / height) * 100.0).clamp(0.0, 100.0);
        (sat, bri)
    };

    let on_mousedown = move |evt: Event<MouseData>| {
        let coords = evt.data().element_coordinates();
        let (sat, bri) = xy_to_sb(coords.x, coords.y);
        if let Some(mut ds) = dialog_signal() {
            ds.set_value("s", serde_json::json!(sat.round() as i64));
            ds.set_value("b", serde_json::json!(bri.round() as i64));
            dialog_signal.set(Some(ds));
            rev_down += 1;
        }
    };

    let on_mousemove = move |evt: Event<MouseData>| {
        if !evt.data().held_buttons().contains(dioxus::html::input_data::MouseButton::Primary) {
            return;
        }
        let coords = evt.data().element_coordinates();
        let (sat, bri) = xy_to_sb(coords.x, coords.y);
        if let Some(mut ds) = dialog_signal() {
            ds.set_value("s", serde_json::json!(sat.round() as i64));
            ds.set_value("b", serde_json::json!(bri.round() as i64));
            dialog_signal.set(Some(ds));
            rev_move += 1;
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
            style: "width:180px;height:180px;background:{bg};border:1px solid var(--jas-border,#555);cursor:crosshair;position:relative;user-select:none;-webkit-user-drag:none;{style}",
            onmousedown: on_mousedown,
            onmousemove: on_mousemove,
            // Position indicator circle
            div {
                style: "position:absolute;left:{cursor_x - 5.0}px;top:{cursor_y - 5.0}px;width:10px;height:10px;border:2px solid #fff;border-radius:50%;pointer-events:none;box-sizing:border-box;box-shadow:0 0 2px rgba(0,0,0,0.5);",
            }
        }
    }
}

/// Render a vertical hue bar for the color picker dialog.
///
/// The bar's gradient and value channel are driven by
/// `dialog.radio_channel` (h / s / b / r / g / bl). For H the bar is a
/// hue rainbow; for the other channels it ramps that one channel from
/// 0 to its max while holding the others at their current values.
fn render_color_hue_bar(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let style = build_style(el, ctx);

    // Active radio channel determines the bar's appearance + value.
    let channel = match expr::eval("dialog.radio_channel", ctx) {
        Value::Str(s) => s,
        _ => "h".to_string(),
    };

    // Read current color components for the gradient (non-target
    // channels stay fixed; target channel is what the bar selects).
    let get_num = |expr_str: &str, default: f64| -> f64 {
        match expr::eval(expr_str, ctx) {
            Value::Number(n) => n,
            _ => default,
        }
    };
    let h = get_num("dialog.h", 0.0);
    let s = get_num("dialog.s", 100.0);
    let b = get_num("dialog.b", 100.0);
    let r = get_num("dialog.r", 255.0) as u8;
    let g = get_num("dialog.g", 0.0) as u8;
    let bl = get_num("dialog.bl", 0.0) as u8;

    use crate::interpreter::color_util::hsb_to_rgb;

    // Helper: format a HSB triple as `rgb(R,G,B)`.
    let hsb_css = |h: f64, s: f64, b: f64| -> String {
        let (rr, gg, bb) = hsb_to_rgb(h, s, b);
        format!("rgb({rr},{gg},{bb})")
    };

    // Build the gradient + value range for the active channel.
    let (bg, current_value, max_value) = match channel.as_str() {
        "s" => {
            // Saturation ramp at current h+b — top (high sat) to bottom (low).
            let top = hsb_css(h, 100.0, b);
            let bot = hsb_css(h, 0.0, b);
            (format!("linear-gradient(to bottom, {top}, {bot})"), s, 100.0)
        }
        "b" => {
            // Brightness ramp at current h+s — top (high) to bottom (black).
            let top = hsb_css(h, s, 100.0);
            let bot = hsb_css(h, s, 0.0);
            (format!("linear-gradient(to bottom, {top}, {bot})"), b, 100.0)
        }
        "r" => {
            // Red ramp at current g+bl — top (255 red) to bottom (0 red).
            (format!("linear-gradient(to bottom, rgb(255,{g},{bl}), rgb(0,{g},{bl}))"), r as f64, 255.0)
        }
        "g" => {
            (format!("linear-gradient(to bottom, rgb({r},255,{bl}), rgb({r},0,{bl}))"), g as f64, 255.0)
        }
        "bl" => {
            (format!("linear-gradient(to bottom, rgb({r},{g},255), rgb({r},{g},0))"), bl as f64, 255.0)
        }
        // Default H: rainbow hue gradient, top=0° to bottom=360°.
        _ => (
            "linear-gradient(to bottom, #f00, #ff0, #0f0, #0ff, #00f, #f0f, #f00)".to_string(),
            h,
            359.0,
        ),
    };

    let mut dialog_signal = rctx.dialog_ctx.0;
    let mut rev_down = rctx.revision;
    let mut rev_move = rctx.revision;
    let channel_for_handler = channel.clone();

    // For top-is-max channels (every channel here), y=0 is max and
    // y=height is 0. Convert pointer y → channel value.
    let max_val_for_handler = max_value;
    let channel_for_down = channel_for_handler.clone();
    let channel_for_move = channel_for_handler.clone();
    let y_to_val = move |y: f64, max: f64| -> f64 {
        let height = 180.0_f64;
        (max - y / height * max).clamp(0.0, max)
    };

    let on_mousedown = move |evt: Event<MouseData>| {
        let new_val = y_to_val(evt.data().element_coordinates().y, max_val_for_handler);
        if let Some(mut ds) = dialog_signal() {
            ds.set_value(&channel_for_down, serde_json::json!(new_val.round() as i64));
            dialog_signal.set(Some(ds));
            rev_down += 1;
        }
    };

    let on_mousemove = move |evt: Event<MouseData>| {
        if !evt.data().held_buttons().contains(dioxus::html::input_data::MouseButton::Primary) {
            return;
        }
        let new_val = y_to_val(evt.data().element_coordinates().y, max_val_for_handler);
        if let Some(mut ds) = dialog_signal() {
            ds.set_value(&channel_for_move, serde_json::json!(new_val.round() as i64));
            dialog_signal.set(Some(ds));
            rev_move += 1;
        }
    };

    // Indicator y from current channel value (top = max).
    let indicator_y = (max_value - current_value) / max_value * 180.0;

    rsx! {
        div {
            id: "{id}",
            style: "width:32px;height:180px;background:{bg};border:1px solid var(--jas-border,#555);cursor:crosshair;position:relative;user-select:none;-webkit-user-drag:none;{style}",
            onmousedown: on_mousedown,
            onmousemove: on_mousemove,
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
        // Route widget events inside this panel to the correct per-panel
        // state struct on AppState. The mapping keys match the content
        // ids produced by interpreter::workspace::panel_kind_to_content_id.
        let panel_kind = el.get("id").and_then(|v| v.as_str()).and_then(|id| match id {
            "layers_panel_content"     => Some(PanelKind::Layers),
            "color_panel_content"      => Some(PanelKind::Color),
            "swatches_panel_content"   => Some(PanelKind::Swatches),
            "stroke_panel_content"     => Some(PanelKind::Stroke),
            "properties_panel_content" => Some(PanelKind::Properties),
            "character_panel_content"  => Some(PanelKind::Character),
            "paragraph_panel_content"  => Some(PanelKind::Paragraph),
            "artboards_panel_content"  => Some(PanelKind::Artboards),
            "opacity_panel_content"    => Some(PanelKind::Opacity),
            "align_panel_content"      => Some(PanelKind::Align),
            "boolean_panel_content"    => Some(PanelKind::Boolean),
            "magic_wand_panel_content" => Some(PanelKind::MagicWand),
            "symbols_panel_content"    => Some(PanelKind::Symbols),
            _ => None,
        });
        let mut child = rctx.clone();
        child.panel_kind = panel_kind;
        // Path B preview: render this panel from the shared canonical layout
        // pass (absolute rects) instead of framework flex. Opt-in via the
        // JAS_PATH_B=1 env var and restricted to the panels the cross-app
        // byte-gate covers (everything except color / gradient / layers, whose
        // composite widgets the v1 pass cannot size yet), so it is zero-risk to
        // shipped panels. This is the Phase-1 "render each app from the pass
        // behind a flag" mechanism from PATH_B_DESIGN.md; broadens with the corpus.
        let pid = el.get("id").and_then(|v| v.as_str()).unwrap_or("");
        let path_b_unsupported = matches!(
            pid,
            "color_panel_content" | "gradient_panel_content" | "layers_panel_content"
        );
        if path_b_enabled() && !pid.is_empty() && !path_b_unsupported {
            return render_panel_absolute(el, content, ctx, &child);
        }
        render_el(content, ctx, &child)
    } else {
        render_placeholder(el, ctx, rctx)
    }
}

/// Whether to render panels from the shared Path B layout pass (preview).
///
/// The app runs as wasm in the browser, where there is no process env, so the
/// toggle is the `?path_b=1` URL query param (no rebuild needed to flip it). A
/// native build (if ever) falls back to the `JAS_PATH_B=1` env var used by the
/// other apps.
fn path_b_enabled() -> bool {
    #[cfg(target_arch = "wasm32")]
    {
        web_sys::window()
            .and_then(|w| w.location().search().ok())
            .map(|s| s.contains("path_b=1"))
            .unwrap_or(false)
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        std::env::var("JAS_PATH_B").map(|v| v == "1").unwrap_or(false)
    }
}

/// Render a panel from the canonical Path B layout pass: each leaf widget is
/// placed in an absolutely-positioned box at its computed rect, inside a
/// position:relative panel of the computed height. Containers contribute
/// layout only (no box). Width is the canonical content width (dock 240 - 12).
fn render_panel_absolute(
    panel_el: &serde_json::Value,
    _content: &serde_json::Value,
    ctx: &serde_json::Value,
    rctx: &RenderCtx,
) -> Element {
    const AVAIL_W: i64 = 228;
    // Path B preview: render from the shared pass with the live eval scope `ctx`
    // so foreach lists + text bindings resolve to real data. avail_h=0 keeps the
    // panel content-height in the preview. `render_plan` carries each leaf's node
    // AND its (child) scope, so foreach-expanded rows render with their per-row
    // scope — a flat `node_at_path` over `children` cannot resolve a foreach row,
    // whose node comes from the `do` template, not from `children[i]`.
    let plan = crate::interpreter::panel_layout::render_plan(panel_el, AVAIL_W, 0, ctx);
    let panel_h = plan.height;

    let mut leaves: Vec<Element> = Vec::new();
    for leaf in &plan.leaves {
        let (x, y, w, h) = (leaf.x, leaf.y, leaf.w, leaf.h);
        // Render the leaf node with ITS scope (the child/per-row ctx).
        let inner = render_el(&leaf.node, &leaf.ctx, rctx);
        let st = format!(
            "position:absolute;left:{x}px;top:{y}px;width:{w}px;height:{h}px;overflow:hidden;"
        );
        leaves.push(rsx! { div { style: "{st}", {inner} } });
    }

    let outer = format!("position:relative;width:{AVAIL_W}px;height:{panel_h}px;color:var(--jas-text,#ccc);");
    rsx! {
        div {
            style: "{outer}",
            for leaf in leaves {
                {leaf}
            }
        }
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

// ─── Tree view helpers ────────────────────────────────────────
//
// Hoisted from render_tree_view so the main function focuses on
// interaction / rsx! assembly rather than data-flattening plumbing.
// Pure utilities: no AppState, no closures — only element geometry,
// paths, and icon lookup.

use crate::geometry::element::{Element as GeoElement, Visibility};
use std::collections::HashSet as TreeHashSet;

const LAYER_COLORS: [&str; 9] = [
    "#4a90d9", "#d94a4a", "#4ad94a", "#4a4ad9", "#d9d94a",
    "#d94ad9", "#4ad9d9", "#b0b0b0", "#2a7a2a",
];

fn tree_icon_svg(icon_name: &str) -> String {
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

fn tree_type_label(elem: &GeoElement) -> &'static str {
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
        GeoElement::Live(v) => match v {
            crate::geometry::live::LiveVariant::CompoundShape(_) => "Compound Shape",
            crate::geometry::live::LiveVariant::Reference(_) => "Reference",
            crate::geometry::live::LiveVariant::Recorded(_) => "Recorded",
            crate::geometry::live::LiveVariant::Generated(_) => "Generated",
        },
    }
}

/// Build a fitted-viewBox SVG thumbnail for a single element.
/// Returns an empty string for zero-extent or degenerate bounds.
fn tree_preview_svg(elem: &GeoElement) -> String {
    let (x, y, w, h) = elem.bounds();
    if !(w.is_finite() && h.is_finite()) || w <= 0.0 || h <= 0.0 {
        return String::new();
    }
    // element_svg() applies a pt → px scale (96/72 ≈ 1.333) to every
    // coordinate, since its primary callers export to standard SVG
    // files. The viewBox needs the same scale so the inner geometry
    // sits inside the declared box — otherwise content extends 1.333×
    // past the right/bottom and the SVG viewport clips it to the
    // upper-left of the thumbnail container.
    const PT_TO_PX: f64 = 96.0 / 72.0;
    let (x, y, w, h) = (x * PT_TO_PX, y * PT_TO_PX, w * PT_TO_PX, h * PT_TO_PX);
    let pad = (w.max(h) * 0.02).max(0.5);
    let vb = format!("{} {} {} {}", x - pad, y - pad, w + 2.0 * pad, h + 2.0 * pad);
    let inner = crate::geometry::svg::element_svg(elem, "");
    format!(
        r#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" preserveAspectRatio="xMidYMid meet" style="display:block;width:100%;height:100%;">{inner}</svg>"#
    )
}

fn tree_elem_display_name(elem: &GeoElement) -> (String, bool) {
    // Every element's name lives in common.name. The bracket-type
    // fallback shows when the name is unset.
    if let Some(n) = elem.common().name.as_deref() {
        if !n.is_empty() {
            return (n.to_string(), true);
        }
    }
    (format!("<{}>", tree_type_label(elem)), false)
}

fn tree_flatten_rc_children(
    children: &[std::rc::Rc<GeoElement>],
    depth: usize,
    path_prefix: &[usize],
    layer_color: &str,
    selected_paths: &TreeHashSet<Vec<usize>>,
    collapsed_paths: &TreeHashSet<Vec<usize>>,
    panel_selection: &[Vec<usize>],
    renaming_path: &Option<Vec<usize>>,
    inherited_visibility: Visibility,
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

        // Effective visibility = most restrictive of ancestor + self,
        // matching Document::effective_visibility (Preview > Outline >
        // Invisible). The eye icon and visibility_str reflect what the
        // user actually sees on canvas, so a child of an invisible
        // group renders an invisible eye even if the child's own
        // setting is Preview.
        let effective_vis = std::cmp::min(inherited_visibility, child.visibility());
        let vis_str = match effective_vis {
            Visibility::Preview => "preview",
            Visibility::Outline => "outline",
            Visibility::Invisible => "invisible",
        };
        let eye_icon = match effective_vis {
            Visibility::Preview => "eye_preview",
            Visibility::Outline => "eye_outline",
            Visibility::Invisible => "eye_invisible",
        };
        let lock_icon = if child.locked() { "lock_locked" } else { "lock_unlocked" };

        let twirl_svg = if is_container {
            tree_icon_svg(if is_collapsed { "twirl_closed" } else { "twirl_open" })
        } else {
            String::new()
        };
        let (display_name, is_named) = tree_elem_display_name(child);

        let preview_svg = tree_preview_svg(child);
        rows.push(TreeRow {
            path: path.clone(),
            depth,
            eye_icon_svg: tree_icon_svg(eye_icon),
            lock_icon_svg: tree_icon_svg(lock_icon),
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

        if !is_collapsed {
            if let Some(grandchildren) = child.children() {
                tree_flatten_rc_children(
                    grandchildren, depth + 1, &path, &current_layer_color,
                    selected_paths, collapsed_paths, panel_selection, renaming_path,
                    effective_vis, rows,
                );
            }
        }
    }
}

fn tree_flatten_layers(
    layers: &[GeoElement],
    selected_paths: &TreeHashSet<Vec<usize>>,
    collapsed_paths: &TreeHashSet<Vec<usize>>,
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
            tree_icon_svg(if is_collapsed { "twirl_closed" } else { "twirl_open" })
        } else {
            String::new()
        };
        let (display_name, is_named) = tree_elem_display_name(elem);

        let preview_svg = tree_preview_svg(elem);
        rows.push(TreeRow {
            path: path.clone(),
            depth: 0,
            eye_icon_svg: tree_icon_svg(eye_icon),
            lock_icon_svg: tree_icon_svg(lock_icon),
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

        if !is_collapsed {
            if let Some(children) = elem.children() {
                // Inherit the layer's visibility into the child walk so
                // descendants render the cascaded eye state (an
                // invisible layer makes every child row's eye render
                // invisible too).
                tree_flatten_rc_children(
                    children, 1, &path, &layer_color,
                    selected_paths, collapsed_paths, panel_selection, renaming_path,
                    elem.visibility(), &mut rows,
                );
            }
        }
    }
    rows
}

// ──────────────────────────────────────────────────────────────

/// Schedule a focus + select on the inline rename input for `path`,
/// after Dioxus has rendered the input element. The input has
/// `autofocus: true` but the browser blocks autofocus when another
/// element already has focus (the layers panel container, in
/// practice) — so we have to call .focus() explicitly. Uses
/// requestAnimationFrame so the call lands after the next paint when
/// the input element exists in the DOM.
#[cfg(target_arch = "wasm32")]
fn schedule_focus_rename_input(path: &[usize]) {
    use wasm_bindgen::prelude::*;
    use wasm_bindgen::JsCast;
    let id = format!(
        "lp_rename_{}",
        path.iter().map(|i| i.to_string()).collect::<Vec<_>>().join("_"),
    );
    let cb = Closure::once(Box::new(move || {
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            if let Some(el) = doc.get_element_by_id(&id) {
                if let Ok(input) = el.dyn_into::<web_sys::HtmlInputElement>() {
                    let _ = input.focus();
                    input.select();
                }
            }
        }
    }) as Box<dyn FnOnce()>);
    if let Some(win) = web_sys::window() {
        let _ = win.request_animation_frame(cb.as_ref().unchecked_ref());
    }
    cb.forget();
}

#[cfg(not(target_arch = "wasm32"))]
fn schedule_focus_rename_input(_path: &[usize]) {}

/// Render a tree_view widget showing the live document element tree.
///
/// Reads the active document from AppState and renders each element as
/// an interactive row with visibility, lock, twirl-down, preview, name,
/// and selection indicator. Clicking the eye cycles visibility; clicking
/// the lock toggles lock state.
fn render_tree_view(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let style = build_style(el, ctx);

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
                        crate::geometry::element::Element::Layer(le) if !le.name().is_empty() => le.name().to_string(),
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
            tree_flatten_layers(&doc.layers, &selected_paths, collapsed_paths, panel_selection, &renaming_path)
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
    // Dialog signal for the in-panel Delete/Backspace path: the
    // reference-aware delete intercept in dispatch_action may return a
    // deferred open_dialog effect (delete_layer_orphan_confirm) when the
    // panel delete would orphan live instances; we must apply it here, just
    // as the panel context-menu path does.
    let mut kb_dialog_signal = rctx.dialog_ctx.0;
    let on_keydown = move |evt: Event<KeyboardData>| {
        let key = evt.data().key();
        let a = kb_app.clone();
        // Skip the panel-level shortcuts when an inline rename input
        // is active OR the key event is targeting an editable element
        // (search box, text input). Without this guard, Backspace
        // inside the rename input bubbles up here and runs
        // delete_layer_selection — destroying the layer the user
        // is renaming.
        let active_is_input = {
            #[cfg(target_arch = "wasm32")]
            {
                web_sys::window()
                    .and_then(|w| w.document())
                    .and_then(|d| d.active_element())
                    .map(|el| {
                        let tag = el.tag_name().to_uppercase();
                        matches!(tag.as_str(), "INPUT" | "TEXTAREA" | "SELECT")
                    })
                    .unwrap_or(false)
            }
            #[cfg(not(target_arch = "wasm32"))]
            { false }
        };
        let skip_panel_shortcuts = {
            let st = kb_app.borrow();
            st.layers_renaming.is_some()
        } || active_is_input;
        if skip_panel_shortcuts {
            return;
        }
        match key {
            dioxus::prelude::Key::Delete | dioxus::prelude::Key::Backspace => {
                spawn(async move {
                    let deferred = {
                        let mut st = a.borrow_mut();
                        let params = serde_json::Map::new();
                        dispatch_action("delete_layer_selection", &params, &mut st)
                    };
                    // If deleting the panel selection would orphan live
                    // instances, the intercept returns a deferred open_dialog
                    // for delete_layer_orphan_confirm; open it (mirrors the
                    // panel context-menu deferred-effect handling). When the
                    // delete ran inline (no orphan), `deferred` is empty.
                    for eff in deferred {
                        if let Some(od) = eff.get("open_dialog") {
                            let dlg_id = od
                                .get("id")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string();
                            let raw_params = od
                                .get("params")
                                .and_then(|p| p.as_object())
                                .cloned()
                                .unwrap_or_default();
                            let (live_state, outer_scope) = {
                                let st = a.borrow();
                                (
                                    crate::workspace::dock_panel::build_live_state_map(&st),
                                    build_dialog_outer_scope(&st),
                                )
                            };
                            super::dialog_view::open_dialog_with_outer(
                                &mut kb_dialog_signal,
                                &dlg_id,
                                &raw_params,
                                &live_state,
                                &outer_scope,
                            );
                        }
                    }
                    kb_rev += 1;
                });
            }
            dioxus::prelude::Key::ArrowDown | dioxus::prelude::Key::ArrowUp => {
                // Move panel selection to the next / previous visible row
                // in display order (mirrors tree_flatten_layers' rev-order
                // traversal so the visual top-to-bottom matches).
                let dir_down = matches!(key, dioxus::prelude::Key::ArrowDown);
                spawn(async move {
                    let mut st = a.borrow_mut();
                    fn collect_visible(
                        elem: &crate::geometry::element::Element,
                        path: &[usize],
                        collapsed: &std::collections::HashSet<Vec<usize>>,
                        out: &mut Vec<Vec<usize>>,
                    ) {
                        if let Some(children) = elem.children() {
                            for (i, child) in children.iter().enumerate().rev() {
                                let mut cp = path.to_vec();
                                cp.push(i);
                                out.push(cp.clone());
                                if !collapsed.contains(&cp) {
                                    collect_visible(child, &cp, collapsed, out);
                                }
                            }
                        }
                    }
                    let visible: Vec<Vec<usize>> = {
                        let collapsed = st.layers_collapsed.clone();
                        let mut out = Vec::new();
                        if let Some(tab) = st.tab() {
                            let doc = tab.model.document();
                            for (li, layer) in doc.layers.iter().enumerate().rev() {
                                let p = vec![li];
                                out.push(p.clone());
                                if !collapsed.contains(&p) {
                                    collect_visible(layer, &p, &collapsed, &mut out);
                                }
                            }
                        }
                        out
                    };
                    if visible.is_empty() {
                        return;
                    }
                    let cur_idx = st.layers_panel_selection.last()
                        .and_then(|p| visible.iter().position(|v| v == p));
                    let next_idx = match (cur_idx, dir_down) {
                        (Some(i), true) => (i + 1).min(visible.len() - 1),
                        (Some(i), false) => i.saturating_sub(1),
                        (None, true) => 0,
                        (None, false) => visible.len() - 1,
                    };
                    st.layers_panel_selection = vec![visible[next_idx].clone()];
                    kb_rev += 1;
                });
            }
            dioxus::prelude::Key::Escape => {
                // Priority: cancel an in-progress drag first (LYR-131);
                // else pop one isolation level (LYR-186); else no-op.
                spawn(async move {
                    let mut st = a.borrow_mut();
                    let drag_active = st.layers_drag_source.is_some()
                        || st.layers_drag_target.is_some();
                    if drag_active {
                        st.layers_drag_source = None;
                        st.layers_drag_target = None;
                    } else if !st.layers_isolation_stack.is_empty() {
                        st.layers_isolation_stack.pop();
                    }
                    kb_rev += 1;
                });
            }
            dioxus::prelude::Key::F2 => {
                // F2 starts inline rename on the active row. Without a
                // separate focus concept, "active" is the last panel-
                // selected row. Any element type is renameable now
                // that common.name backs the data.
                spawn(async move {
                    let mut st = a.borrow_mut();
                    let target = st.layers_panel_selection.last().cloned();
                    if let Some(path) = target {
                        st.layers_renaming = Some(path.clone());
                        kb_rev += 1;
                        schedule_focus_rename_input(&path);
                    }
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
                                        tab.model.begin_txn();
                                        let mut doc = tab.model.document().clone();
                                        for (sp, vis) in &saved {
                                            if let Some(elem) = doc.get_element_mut(sp) {
                                                elem.common_mut().visibility = *vis;
                                            }
                                        }
                                        tab.model.set_document(doc);
                                        tab.model.commit_txn();
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
                                        tab.model.begin_txn();
                                        let mut doc = tab.model.document().clone();
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
                                        tab.model.set_document(doc);
                                        tab.model.commit_txn();
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
                                    tab.model.begin_txn();
                                    let mut doc = tab.model.document().clone();
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
                                    tab.model.set_document(doc);
                                    tab.model.commit_txn();
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
                                tab.model.begin_txn();
                                // One clone -> all three lock mutations -> one commit, so the
                                // whole lock toggle is a single undo step / one index update.
                                let mut doc = tab.model.document().clone();
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
                                    doc.selection.retain(|es| {
                                        !(es.path == path || es.path.starts_with(&path))
                                    });
                                }
                                tab.model.set_document(doc);
                                tab.model.commit_txn();
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
                                let mut doc = tab.model.document().clone();
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
                                tab.model.set_document_unbracketed(doc);
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
                        // Accept either Cmd (macOS) or Ctrl (Windows /
                        // Linux) for the toggle gesture; mirrors the
                        // pattern used elsewhere in this file.
                        let meta = evt.data().modifiers().meta()
                            || evt.data().modifiers().ctrl();
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
                            // Sync doc.selected_layer to the top-level
                            // ancestor of the most-recently selected
                            // panel row. Controller::add_element appends
                            // new shapes into doc.selected_layer, so this
                            // makes "draw a rect" land in the layer the
                            // user just clicked.
                            if let Some(last) = st.layers_panel_selection.last().cloned() {
                                if let Some(layer_idx) = last.first().copied() {
                                    if let Some(tab) = st.tab_mut() {
                                        let mut new_doc = tab.model.document().clone();
                                        if layer_idx < new_doc.layers.len() {
                                            new_doc.selected_layer = layer_idx;
                                            tab.model.set_document(new_doc);
                                        }
                                    }
                                }
                            }
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
                                // Track the press row in BOTH source
                                // and target. on_mouseenter overwrites
                                // target to the new row when the mouse
                                // crosses into a different row; if no
                                // mouseenter fires (a pure click), the
                                // target stays equal to source and
                                // on_mouseup treats it as a no-drag.
                                let mut st = a.borrow_mut();
                                st.layers_drag_target = Some(p.clone());
                                st.layers_drag_source = Some(p);
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
                            // Bail out if target == source: that means
                            // the mouse never crossed into a different
                            // row between mousedown and mouseup — it
                            // was a click, not a drag. Without this,
                            // a Cmd-click on an already-selected row
                            // would invoke the drag-and-drop reorder
                            // path and silently move siblings around.
                            let source = st.layers_drag_source.take();
                            let drag_target = st.layers_drag_target.take();
                            let true_drag = matches!(
                                (&source, &drag_target),
                                (Some(s), Some(t)) if s != t,
                            );
                            if true_drag {
                                // Move all panel-selected elements to a position
                                // determined by the target row.
                                let sources = st.layers_panel_selection.clone();
                                let search_active = !st.layers_search_query.is_empty();
                                // Determine drop semantics based on target type AND
                                // whether any source is a Layer (Layers always sibling-
                                // insert because they can't nest inside containers):
                                //   - non-Layer source + container target: drop INTO
                                //     the container as the first child.
                                //   - Layer source, OR leaf target: sibling-insert at
                                //     target's index in its parent.
                                let (effective_parent, insert_index, target_is_container) = {
                                    let is_container = st.tab()
                                        .and_then(|t| t.model.document().get_element(&target))
                                        .map(|e| e.is_group_or_layer())
                                        .unwrap_or(false);
                                    let any_source_is_layer = st.tab()
                                        .map(|t| {
                                            let doc = t.model.document();
                                            st.layers_panel_selection.iter().any(|s| {
                                                doc.get_element(s)
                                                    .map(|e| e.is_layer()).unwrap_or(false)
                                            })
                                        })
                                        .unwrap_or(false);
                                    if is_container && !any_source_is_layer {
                                        // Container drop: indicator sits just below
                                        // the row header; visually the new child
                                        // appears at the top of the container's
                                        // children. Children render in reverse doc
                                        // order, so visually-top corresponds to the
                                        // LAST index in the document children list.
                                        let child_count = st.tab()
                                            .and_then(|t| t.model.document().get_element(&target))
                                            .and_then(|e| e.children().map(|c| c.len()))
                                            .unwrap_or(0);
                                        (target.clone(), child_count, true)
                                    } else {
                                        let parent = target[..target.len()-1].to_vec();
                                        let idx = *target.last().unwrap();
                                        (parent, idx, false)
                                    }
                                };
                                let allowed = {
                                    if search_active {
                                        // Reject reorder while a search filter is active —
                                        // the visible row set is a non-contiguous subset
                                        // of the document. Per LYR-103.
                                        false
                                    } else if sources.is_empty() || sources.contains(&target) {
                                        false
                                    } else if let Some(tab) = st.tab() {
                                        let doc = tab.model.document();
                                        // Check: no source is an ancestor of target.
                                        let no_cycle = !sources.iter().any(|src| {
                                            target.len() >= src.len() && target.starts_with(src)
                                        });
                                        // Check: effective parent isn't locked (i.e.,
                                        // can't add a child to a locked container).
                                        let parent_unlocked = if effective_parent.is_empty() {
                                            true
                                        } else {
                                            doc.get_element(&effective_parent)
                                                .map(|e| !e.locked())
                                                .unwrap_or(true)
                                        };
                                        // Check: layers can only live at the top level.
                                        // Reject if any source is a Layer and the
                                        // effective parent isn't the doc root. Per
                                        // LYR-122 (Layer into Group) + LYR-123 (Layer
                                        // into Layer body).
                                        let any_source_is_layer = sources.iter().any(|s| {
                                            doc.get_element(s)
                                                .map(|e| e.is_layer()).unwrap_or(false)
                                        });
                                        let layer_constraint_ok = !any_source_is_layer
                                            || effective_parent.is_empty();
                                        // Reject sibling-insert into top-level position
                                        // for non-Layer sources: top-level slots are
                                        // for layers only. (target_is_container=false +
                                        // effective_parent.is_empty() = trying to drop
                                        // a non-Layer at top-level next to a layer.)
                                        let non_layer_top_ok = if !target_is_container
                                            && effective_parent.is_empty()
                                        {
                                            // The only top-level non-container case is
                                            // "drop on a layer's child but somehow at
                                            // top level" — which can't happen. Permit.
                                            true
                                        } else if target_is_container && effective_parent.is_empty() {
                                            // target is a top-level Layer; non-Layer
                                            // sources will drop INTO it (handled above).
                                            true
                                        } else { true };
                                        no_cycle && parent_unlocked
                                            && layer_constraint_ok && non_layer_top_ok
                                    } else {
                                        false
                                    }
                                };
                                if allowed {
                                    if let Some(tab) = st.tab_mut() {
                                        tab.model.begin_txn();
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
                                        // Build insert path: effective_parent + insert_index.
                                        let mut insert_path = effective_parent.clone();
                                        insert_path.push(insert_index);
                                        let mut new_paths = Vec::new();
                                        for (_, elem) in elements {
                                            doc = doc.insert_element_at(&insert_path, elem);
                                            new_paths.push(insert_path.clone());
                                            let last = insert_path.len() - 1;
                                            insert_path[last] += 1;
                                        }
                                        doc.selection = new_paths.iter()
                                            .map(|p| crate::document::document::ElementSelection::all(p.clone()))
                                            .collect();
                                        tab.model.set_document(doc);
                                        tab.model.commit_txn();
                                        st.layers_panel_selection = new_paths;
                                    }
                                } else {
                                    st.layers_panel_selection.clear();
                                }
                            }
                            drag_up_rev += 1;
                        });
                    };

                    // Drop indicator. The line position signals where the
                    // dropped row will land:
                    //   - Container target (Group / Layer): indicator appears
                    //     just BELOW the row, signalling "drop into as the
                    //     first child" (visually the new row appears just
                    //     below the container's header, indented).
                    //   - Leaf target: indicator appears at the TOP of the
                    //     row, signalling "insert above as a sibling".
                    // (Layer source on Layer target is a sibling reorder,
                    // also drawn as a top-border per the leaf rule below.)
                    let is_drag_target = {
                        let st = rctx.app.borrow();
                        st.layers_drag_target.as_ref() == Some(&row.path) &&
                        !st.layers_panel_selection.contains(&row.path)
                    };
                    let drop_indicator = if is_drag_target {
                        let st = rctx.app.borrow();
                        let any_source_is_layer = st.tab()
                            .map(|t| {
                                let doc = t.model.document();
                                st.layers_panel_selection.iter().any(|s| {
                                    doc.get_element(s)
                                        .map(|e| e.is_layer()).unwrap_or(false)
                                })
                            })
                            .unwrap_or(false);
                        if row.is_container && !any_source_is_layer {
                            "border-bottom:2px solid var(--jas-accent,#3a7bd5);"
                        } else {
                            "border-top:2px solid var(--jas-accent,#3a7bd5);"
                        }
                    } else {
                        ""
                    };

                    let row_dom_id = format!("lp_row_{}", row.path.iter().map(|i| i.to_string()).collect::<Vec<_>>().join("_"));
                    // Row-level double-click: enter isolation mode for
                    // container rows (Layer / Group). Per LYR-182. The
                    // name span has its own dblclick handler that stops
                    // propagation so it triggers rename instead.
                    let dblclick_path = row.path.clone();
                    let dblclick_app = app.clone();
                    let mut dblclick_rev = revision;
                    let dblclick_is_container = row.is_container;
                    let on_row_dblclick = move |_: Event<MouseData>| {
                        if !dblclick_is_container {
                            return;
                        }
                        let p = dblclick_path.clone();
                        let a = dblclick_app.clone();
                        spawn(async move {
                            let mut st = a.borrow_mut();
                            // Make the target container the panel selection
                            // so enter_isolation_mode resolves to it.
                            st.layers_panel_selection = vec![p];
                            let params = serde_json::Map::new();
                            dispatch_action("enter_isolation_mode", &params, &mut st);
                            dblclick_rev += 1;
                        });
                    };
                    rsx! {
                        div {
                            id: "{row_dom_id}",
                            style: "display:flex;align-items:center;height:24px;padding:0 4px;gap:2px;font-size:11px;color:var(--jas-text,#ccc);cursor:default;user-select:none;{row_bg}{drop_indicator}",
                            onclick: on_row_click,
                            oncontextmenu: on_row_contextmenu,
                            onmousedown: on_mousedown,
                            onmouseenter: on_mouseenter,
                            onmouseup: on_mouseup,
                            ondoubleclick: on_row_dblclick,
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
                            // Preview thumbnail — fitted SVG of the element.
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
                                    let blur_path = row.path.clone();
                                    let blur_app = app.clone();
                                    let mut blur_rev = revision;
                                    let cancel_app = app.clone();
                                    let mut cancel_rev = revision;
                                    let initial_name = if row.is_named { row.display_name.clone() } else { String::new() };
                                    let input_id = format!(
                                        "lp_rename_{}",
                                        row.path.iter().map(|i| i.to_string())
                                            .collect::<Vec<_>>().join("_"),
                                    );
                                    let input_id_for_blur = input_id.clone();
                                    rsx! {
                                        input {
                                            id: "{input_id}",
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
                                                                    tab.model.begin_txn();
                                                                    let mut doc = tab.model.document().clone();
                                                                    if let Some(elem) = doc.get_element_mut(&p) {
                                                                        // Write to common.name for any
                                                                        // element type (LYR-091); Layers
                                                                        // also keep LayerElem.name in
                                                                        // sync for back-compat.
                                                                        elem.common_mut().name = if val_inner.is_empty() {
                                                                            None
                                                                        } else {
                                                                            Some(val_inner.clone())
                                                                        };
                                                                        // Layer.name is now backed by
                                                                        // common.name (LYR-091 merge);
                                                                        // the assignment above already
                                                                        // covers Layer along with every
                                                                        // other element type.
                                                                        let _ = val_inner;
                                                                    }
                                                                    tab.model.set_document(doc);
                                                                    tab.model.commit_txn();
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
                                            // Blur (focus loss) commits like Enter, per LYR-073.
                                            // Read value from the input by id since
                                            // active_element on blur is whatever the user
                                            // just clicked, not the input.
                                            onblur: move |_: Event<FocusData>| {
                                                #[cfg(target_arch = "wasm32")]
                                                {
                                                    let p = blur_path.clone();
                                                    let a = blur_app.clone();
                                                    let id = input_id_for_blur.clone();
                                                    let val_inner: String = web_sys::window()
                                                        .and_then(|w| w.document())
                                                        .and_then(|d| d.get_element_by_id(&id))
                                                        .and_then(|el| {
                                                            js_sys::Reflect::get(&el, &"value".into())
                                                                .ok()
                                                                .and_then(|v| v.as_string())
                                                        })
                                                        .unwrap_or_default();
                                                    spawn(async move {
                                                        let mut st = a.borrow_mut();
                                                        if st.layers_renaming.as_ref() == Some(&p) {
                                                            if let Some(tab) = st.tab_mut() {
                                                                tab.model.begin_txn();
                                                                let mut doc = tab.model.document().clone();
                                                                if let Some(elem) = doc.get_element_mut(&p) {
                                                                    elem.common_mut().name = if val_inner.is_empty() {
                                                                        None
                                                                    } else {
                                                                        Some(val_inner.clone())
                                                                    };
                                                                    // Layer.name backed by common.name
                                                                    // (LYR-091); covered above.
                                                                    let _ = val_inner;
                                                                }
                                                                tab.model.set_document(doc);
                                                                tab.model.commit_txn();
                                                            }
                                                            st.layers_renaming = None;
                                                            blur_rev += 1;
                                                        }
                                                    });
                                                }
                                                #[cfg(not(target_arch = "wasm32"))]
                                                { let _ = (&blur_path, &blur_app, &input_id_for_blur); }
                                            },
                                        }
                                    }
                                }
                            } else {
                                {
                                    let name_path = row.path.clone();
                                    let name_app = app.clone();
                                    let mut name_rev = revision;
                                    // Any element row can be renamed — common.name backs
                                    // the persistence (LYR-091). Was layer-only before
                                    // common.name landed.
                                    let can_rename = true;
                                    rsx! {
                                        span {
                                            style: "{name_style}",
                                            ondoubleclick: move |evt: Event<MouseData>| {
                                                // Stop propagation so the row-level
                                                // dblclick (which enters isolation) does
                                                // not also fire and immediately overwrite
                                                // the rename state.
                                                evt.stop_propagation();
                                                if can_rename {
                                                    let p = name_path.clone();
                                                    let a = name_app.clone();
                                                    spawn(async move {
                                                        a.borrow_mut().layers_renaming = Some(p.clone());
                                                        name_rev += 1;
                                                        schedule_focus_rename_input(&p);
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
                                        let (live_state, outer_scope) = {
                                            let st = a2.borrow();
                                            (
                                                crate::workspace::dock_panel::build_live_state_map(&st),
                                                build_dialog_outer_scope(&st),
                                            )
                                        };
                                        super::dialog_view::open_dialog_with_outer(
                                            &mut ctx_dialog_signal, &dlg_id, &raw_params, &live_state, &outer_scope,
                                        );
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
        return render_placeholder(el, ctx, rctx);
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
                                    let v_for_key = v.clone();
                                    let checked = !hidden_types.contains(&v);
                                    let check_mark = if checked { "☑" } else { "☐" };
                                    rsx! {
                                        div {
                                            key: "{v_for_key}",
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

/// Strip a known filename extension and append `.pdf`. Mirrors the
/// menu_bar helper but lives here so the YAML effect handler doesn't
/// need to reach into workspace::menu_bar.
fn pdf_filename_for_tab(filename: &str) -> String {
    let trimmed = filename.trim();
    if trimmed.is_empty() {
        return "Untitled.pdf".to_string();
    }
    for ext in [".svg", ".pdf", ".jas"] {
        if let Some(stem) = trimmed.strip_suffix(ext) {
            return format!("{}.pdf", stem);
        }
    }
    format!("{}.pdf", trimmed)
}

/// Tabs widget — left-rail tab list plus a content area showing the
/// active tab. Active tab is read from `bind.value` (typically
/// `dialog.<field>`); clicking a tab writes its `id` back through the
/// dialog signal. When no bind or the bound value is empty, the first
/// tab is active and the widget is read-only.
///
/// YAML:
/// ```text
/// - id: print_tabs
///   type: tabs
///   layout: left_rail            # default; only left_rail in Phase 1B
///   bind: { value: "dialog.active_tab" }
///   tabs:
///     - { id: general, label: "General",
///         content: { type: container, children: [...] } }
///     - { id: marks_and_bleed, label: "Marks and Bleed",
///         content: { type: text, content: "Available in Phase 2" } }
///     ...
/// ```
fn render_tabs(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let style = build_style(el, ctx);
    let tabs = el.get("tabs").and_then(|t| t.as_array()).cloned().unwrap_or_default();
    if tabs.is_empty() {
        return rsx! { div { id: "{id}", style: "{style}" } };
    }

    let first_id = tabs[0]
        .get("id")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let bind_expr = el
        .get("bind")
        .and_then(|b| b.get("value"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let active_id: String = if bind_expr.is_empty() {
        first_id.clone()
    } else {
        match expr::eval(bind_expr, ctx) {
            Value::Str(s) if !s.is_empty() => s,
            _ => first_id.clone(),
        }
    };

    let bind_field: Option<String> = match classify_bind(bind_expr) {
        BindTarget::Dialog(f) => Some(f),
        _ => None,
    };

    // Render the active tab's content. Inactive tabs aren't rendered
    // at all (matches the spec's expectation that only General is
    // populated in Phase 1B; placeholder tabs simply swap in their
    // text content node when activated).
    let active_content = tabs
        .iter()
        .find(|t| t.get("id").and_then(|v| v.as_str()) == Some(active_id.as_str()))
        .and_then(|t| t.get("content"))
        .map(|c| render_el(c, ctx, rctx))
        .unwrap_or_else(|| rsx! { div {} });

    // Snapshot the per-tab nav data once so the rsx loop doesn't
    // borrow `tabs` again.
    let nav: Vec<(String, String, bool)> = tabs
        .iter()
        .map(|t| {
            let tid = t
                .get("id")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let label = t
                .get("label")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let active = tid == active_id;
            (tid, label, active)
        })
        .collect();

    let dialog_signal = rctx.dialog_ctx.0;
    let revision = rctx.revision;

    rsx! {
        div {
            id: "{id}",
            style: "display:flex;flex-direction:row;align-items:stretch;gap:0;{style}",
            // Left rail.
            div {
                style: "display:flex;flex-direction:column;min-width:140px;border-right:1px solid var(--jas-border,#555);padding:4px 0;background:var(--jas-pane-bg-dark,#2a2a2a);",
                for (tid, label, active) in nav {
                    {
                        let target = tid.clone();
                        let bind_field2 = bind_field.clone();
                        let mut sig = dialog_signal;
                        let mut rev = revision;
                        let bg = if active { "background:var(--jas-pane-bg,#3a3a3a);" } else { "" };
                        let weight = if active { "font-weight:600;" } else { "" };
                        rsx! {
                            div {
                                key: "{target}",
                                style: "padding:6px 12px;cursor:pointer;font-size:12px;color:var(--jas-text,#ccc);user-select:none;{bg}{weight}",
                                onmousedown: move |evt: Event<MouseData>| {
                                    evt.stop_propagation();
                                    if let Some(field) = &bind_field2 {
                                        if let Some(mut ds) = sig() {
                                            ds.set_value(field, serde_json::json!(target.clone()));
                                            sig.set(Some(ds));
                                        }
                                        rev += 1;
                                    }
                                },
                                "{label}"
                            }
                        }
                    }
                }
            }
            // Content area.
            div {
                style: "flex:1;padding:12px;",
                {active_content}
            }
        }
    }
}

fn render_placeholder(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let summary = el.get("summary")
        .or_else(|| el.get("type"))
        .and_then(|s| s.as_str())
        .unwrap_or("?");
    let panel_kind = rctx.panel_kind;

    // Opacity panel previews (OPACITY.md §Preview interactions):
    // op_preview and op_mask_preview handle click to switch the
    // editing target (content vs mask subtree) and render a
    // persistent highlight on the active target.
    let is_opacity_preview =
        panel_kind == Some(PanelKind::Opacity)
        && (id == "op_preview" || id == "op_mask_preview");
    if is_opacity_preview {
        let editing_mask = expr::eval("editing_target_is_mask", ctx).to_bool();
        let has_mask = expr::eval("selection_has_mask", ctx).to_bool();
        let is_mask_preview = id == "op_mask_preview";
        // Highlight the preview that matches the current editing
        // target: op_preview when not in mask-editing, op_mask_preview
        // when in mask-editing.
        let highlight = editing_mask == is_mask_preview;
        let border = if highlight { "2px solid #4a90d9" } else { "2px solid transparent" };
        // Clicking MASK_PREVIEW requires the selection to have a
        // mask; otherwise the click is a no-op (mirrors the
        // "Requires element.mask to be present" clause in the spec).
        let click_enabled = !is_mask_preview || has_mask;
        let app = rctx.app.clone();
        let mut revision = rctx.revision;
        let target_is_mask = is_mask_preview;
        // MASK_PREVIEW supports modifier-clicks per OPACITY.md
        // §Preview interactions:
        //   * plain click → enter mask-editing mode (routed above)
        //   * Alt/Option-click → toggle mask isolation (render only
        //     the mask subtree on the canvas)
        //   * Shift-click → toggle mask.disabled
        let on_click = EventHandler::new(move |evt: Event<MouseData>| {
            if !click_enabled {
                return;
            }
            let mods = evt.data().modifiers();
            let alt = mods.alt();
            let shift = mods.shift();
            let app = app.clone();
            spawn(async move {
                use crate::workspace::app_state::EditingTarget;
                let mut st = app.borrow_mut();
                if target_is_mask && shift {
                    // Shift-click: toggle mask.disabled on every
                    // selected mask via the existing Controller.
                    if let Some(tab) = st.tab_mut() {
                        crate::document::controller::Controller::toggle_mask_disabled_on_selection(&mut tab.model);
                    }
                } else if target_is_mask && alt {
                    // Alt-click: toggle mask isolation on the first
                    // selected element's mask. Enters isolation if
                    // off; exits otherwise.
                    if let Some(tab) = st.tab_mut() {
                        let first_path = tab.model.document().selection.first()
                            .map(|es| es.path.clone());
                        tab.model.mask_isolation_path = match (&tab.model.mask_isolation_path, first_path) {
                            (Some(_), _) => None,
                            (None, Some(p)) => Some(p),
                            (None, None) => None,
                        };
                    }
                } else {
                    // Plain click: flip editing target between
                    // content and the first selected element's mask
                    // subtree.
                    if let Some(tab) = st.tab_mut() {
                        tab.model.editing_target = if target_is_mask {
                            tab.model.document().selection.first()
                                .map(|es| EditingTarget::Mask(es.path.clone()))
                                .unwrap_or(EditingTarget::Content)
                        } else {
                            EditingTarget::Content
                        };
                    }
                }
                revision += 1;
            });
        });
        let cursor = if click_enabled { "pointer" } else { "default" };
        return rsx! {
            div {
                id: "{id}",
                style: "padding:12px;color:var(--jas-text-dim,#999);font-size:12px;text-align:center;min-height:30px;outline:{border};outline-offset:-2px;cursor:{cursor};",
                title: "{summary}",
                onclick: move |evt| on_click.call(evt),
                "[{summary}]"
            }
        };
    }

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

    // ── radio widget: on_check partitioning ───────────────────
    //
    // render_radio returns a Dioxus Element (needs component context), so
    // the headless test target is the pure partitioning helper that the
    // click handler delegates to. It mirrors the dialog arm of
    // effects.rs::set_by_scoped_target for the live dialog signal.

    #[test]
    fn radio_on_check_routes_dialog_set_to_dialog_writes() {
        // The Scale dialog's Uniform radio: `on_check: [{ set: { dialog.uniform:
        // "true" } }]`. The value is an expression STRING and must evaluate to
        // a bool, and the dialog.<field> target must be pulled out as a live
        // dialog write (not left as a residual AppState effect).
        let on_check = vec![serde_json::json!({
            "set": { "dialog.uniform": "true" }
        })];
        let (dialog_writes, other) =
            partition_on_check_effects(&on_check, &serde_json::json!({}));
        assert_eq!(dialog_writes.len(), 1);
        assert_eq!(dialog_writes[0].0, "uniform");
        assert_eq!(dialog_writes[0].1, serde_json::json!(true));
        assert!(other.is_empty(), "dialog.* set must not leak into AppState effects");

        // The Non-Uniform sibling flips it back via the "false" expression.
        let on_check = vec![serde_json::json!({
            "set": { "dialog.uniform": "false" }
        })];
        let (dialog_writes, _) =
            partition_on_check_effects(&on_check, &serde_json::json!({}));
        assert_eq!(dialog_writes[0].1, serde_json::json!(false));
    }

    #[test]
    fn radio_on_check_keeps_non_dialog_effects_as_residual() {
        // A non-dialog set key stays in the residual effects list (routed
        // through the AppState runner), while the dialog.* key is extracted.
        let on_check = vec![serde_json::json!({
            "set": { "dialog.uniform": "true", "state.scale_uniform": "true" }
        })];
        let (dialog_writes, other) =
            partition_on_check_effects(&on_check, &serde_json::json!({}));
        assert_eq!(dialog_writes.len(), 1);
        assert_eq!(dialog_writes[0].0, "uniform");
        assert_eq!(other.len(), 1);
        let residual = other[0].get("set").and_then(|v| v.as_object()).unwrap();
        assert!(residual.contains_key("state.scale_uniform"));
        assert!(!residual.contains_key("dialog.uniform"));
    }

    // ── Phase 3: Group A toggle actions ───────────────────────
    //
    // These build a minimal AppState with some top-level layers, dispatch
    // the action name (which falls through to the YAML effects catalog),
    // and verify the layers' common.visibility / common.locked changed.

    use crate::geometry::element::{Element, LayerElem, CommonProps, Visibility};

    fn make_state_with_layers(layers: Vec<(String, Visibility, bool)>) -> AppState {
        use crate::workspace::app_state::TabState;
        let mut st = AppState::new();
        // Ensure there's at least one tab (AppState::new may return empty tabs)
        if st.tabs.is_empty() {
            st.tabs.push(TabState::new());
            st.active_tab = 0;
        }
        let doc_layers: Vec<Element> = layers.into_iter().map(|(name, vis, locked)| {
            Element::Layer(LayerElem {
                children: Vec::new(),
                isolated_blending: false,
                knockout_group: false,
                common: CommonProps {
                    opacity: 1.0,
                    mode: crate::geometry::element::BlendMode::Normal,
                    transform: None,
                    locked,
                    visibility: vis,
                    mask: None,
                    tool_origin: None,
                    name: Some(name),
                    id: None,
                },
            })
        }).collect();
        let mut new_doc = st.tabs[st.active_tab].model.document().clone();
        new_doc.layers = doc_layers;
        st.tabs[st.active_tab].model.set_document_unbracketed(new_doc);
        st
    }

    fn tab_layer(st: &AppState, idx: usize) -> &LayerElem {
        match &st.tabs[st.active_tab].model.document().layers[idx] {
            Element::Layer(le) => le,
            _ => panic!("expected Layer at {}", idx),
        }
    }

    #[test]
    fn toggle_all_layers_visibility_any_visible_all_become_invisible() {
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, false),
            ("B".into(), Visibility::Invisible, false),
        ]);
        let params = serde_json::Map::new();
        dispatch_action("toggle_all_layers_visibility", &params, &mut st);
        assert_eq!(tab_layer(&st, 0).common.visibility, Visibility::Invisible);
        assert_eq!(tab_layer(&st, 1).common.visibility, Visibility::Invisible);
    }

    #[test]
    fn toggle_all_layers_visibility_all_invisible_become_preview() {
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Invisible, false),
            ("B".into(), Visibility::Invisible, false),
        ]);
        let params = serde_json::Map::new();
        dispatch_action("toggle_all_layers_visibility", &params, &mut st);
        assert_eq!(tab_layer(&st, 0).common.visibility, Visibility::Preview);
        assert_eq!(tab_layer(&st, 1).common.visibility, Visibility::Preview);
    }

    #[test]
    fn toggle_all_layers_outline_any_preview_become_outline() {
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, false),
            ("B".into(), Visibility::Outline, false),
        ]);
        let params = serde_json::Map::new();
        dispatch_action("toggle_all_layers_outline", &params, &mut st);
        assert_eq!(tab_layer(&st, 0).common.visibility, Visibility::Outline);
        assert_eq!(tab_layer(&st, 1).common.visibility, Visibility::Outline);
    }

    #[test]
    fn toggle_all_layers_outline_all_outline_become_preview() {
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Outline, false),
            ("B".into(), Visibility::Outline, false),
        ]);
        let params = serde_json::Map::new();
        dispatch_action("toggle_all_layers_outline", &params, &mut st);
        assert_eq!(tab_layer(&st, 0).common.visibility, Visibility::Preview);
        assert_eq!(tab_layer(&st, 1).common.visibility, Visibility::Preview);
    }

    #[test]
    fn toggle_all_layers_lock_any_unlocked_all_become_locked() {
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, false),
            ("B".into(), Visibility::Preview, true),
        ]);
        let params = serde_json::Map::new();
        dispatch_action("toggle_all_layers_lock", &params, &mut st);
        assert!(tab_layer(&st, 0).common.locked);
        assert!(tab_layer(&st, 1).common.locked);
    }

    #[test]
    fn toggle_all_layers_lock_all_locked_become_unlocked() {
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, true),
            ("B".into(), Visibility::Preview, true),
        ]);
        let params = serde_json::Map::new();
        dispatch_action("toggle_all_layers_lock", &params, &mut st);
        assert!(!tab_layer(&st, 0).common.locked);
        assert!(!tab_layer(&st, 1).common.locked);
    }

    #[test]
    fn dispatch_action_supplies_action_param_defaults_when_caller_omits() {
        // Ensures dispatch_action populates `param.<name>` with the
        // action spec's `default` value for each param the caller
        // didn't supply -- so effects like
        //   doc.zoom.apply: { anchor_x: "param.anchor_x" }
        // see the spec default (-1 = viewport center for zoom_in)
        // instead of Null (which eval_number coerces to 0.0, putting
        // the anchor at the canvas's upper-left corner).
        let mut st = make_state_with_layers(vec![
            ("L1".into(), Visibility::Preview, false),
        ]);
        let tab = &mut st.tabs[st.active_tab];
        tab.model.viewport_w    = 800.0;
        tab.model.viewport_h    = 600.0;
        tab.model.zoom_level    = 1.0;
        // Place the doc origin somewhere obviously off-center; the
        // pre-fix code anchored at (0, 0) so view_offset would shift
        // to a value derived from that anchor and we could check.
        tab.model.view_offset_x = 94.0;
        tab.model.view_offset_y = -96.0;

        let params = serde_json::Map::new();
        dispatch_action("zoom_in", &params, &mut st);

        let m = &st.tabs[st.active_tab].model;
        // Anchor at viewport center (400, 300): the document point
        // currently under (400, 300) must remain under (400, 300)
        // after the zoom. Pre-fix this would have anchored at (0, 0)
        // and the doc point under viewport center would have shifted.
        let doc_under_center = (
            (400.0 - m.view_offset_x) / m.zoom_level,
            (300.0 - m.view_offset_y) / m.zoom_level,
        );
        // Pre-zoom: doc point under (400,300) = (306, 396).
        assert!(
            (doc_under_center.0 - 306.0).abs() < 0.5
            && (doc_under_center.1 - 396.0).abs() < 0.5,
            "viewport-center anchor not preserved: doc point under \
             screen (400, 300) is now {:?} (expected ≈ (306, 396)); \
             view_offset=({}, {}), zoom={}",
            doc_under_center,
            m.view_offset_x, m.view_offset_y, m.zoom_level,
        );
    }

    // ── Action dispatch routing Model-level doc.* effects ──────
    //
    // Actions like fit_active_artboard / zoom_to_actual_size are
    // dispatched from menubar / shortcuts via dispatch_action, NOT via
    // a tool's on_event. Their effect lists contain `doc.zoom.*` keys
    // that live in effects.rs (Model dispatch), not in renderer.rs's
    // own AppState handlers. Without a fallback that bridges the two,
    // these actions are silently no-ops -- visible to the user as
    // Cmd+0 doing nothing and the Hand-icon dblclick doing nothing.

    #[test]
    fn fit_active_artboard_action_changes_view_state() {
        // Default tab has at least one artboard (per the at-least-one
        // invariant) and zoom_level = 1.0 with view_offset_x/y = 0.
        // Set a known viewport so the fit math has something to work
        // with, then dispatch the action and assert the model's view
        // state actually changed -- the specific output isn't the
        // point; that the model was touched at all is what proves the
        // doc.zoom.fit_rect dispatch reached effects.rs.
        let mut st = make_state_with_layers(vec![
            ("L1".into(), Visibility::Preview, false),
        ]);
        let tab = &mut st.tabs[st.active_tab];
        tab.model.viewport_w = 800.0;
        tab.model.viewport_h = 600.0;
        tab.model.zoom_level    = 0.5;
        tab.model.view_offset_x = 999.0;
        tab.model.view_offset_y = 999.0;

        let params = serde_json::Map::new();
        dispatch_action("fit_active_artboard", &params, &mut st);

        let m = &st.tabs[st.active_tab].model;
        let touched = m.zoom_level != 0.5
            || m.view_offset_x != 999.0
            || m.view_offset_y != 999.0;
        assert!(
            touched,
            "fit_active_artboard must mutate Model view state \
             (zoom={}, off=({},{}))",
            m.zoom_level, m.view_offset_x, m.view_offset_y,
        );
    }

    // ── OP_LOG.md §9: dispatch_action names its transaction ─────────
    //
    // dispatch_action → run_yaml_effects_named is the primary action surface
    // (menu / keyboard / panel). Before §9 it called run_yaml_effects with no
    // action name, so every undoable menu/keyboard/panel transaction committed
    // with name=None — the legibility hole §9 closes for ALL actions, not just
    // the three op-journaled verbs. This pins that a YAML action dispatched
    // through dispatch_action commits a transaction NAMED with its action verb.
    #[test]
    fn dispatch_action_names_the_committed_transaction() {
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, false),
        ]);
        let before = st.tabs[st.active_tab].model.journal().len();
        // `new_layer` is a YAML action (snapshot + doc.create_layer +
        // doc.insert_at) routed through the catalog fallback — not a hardcoded
        // handler — so it exercises the run_yaml_effects_named path.
        let params = serde_json::Map::new();
        dispatch_action("new_layer", &params, &mut st);

        let model = &st.tabs[st.active_tab].model;
        // The action committed exactly one new transaction...
        assert_eq!(model.journal().len(), before + 1,
            "new_layer commits one transaction");
        // ...named with its action verb (the §9 invariant for the primary
        // action surface).
        assert_eq!(model.journal().last().and_then(|t| t.name.as_deref()),
            Some("new_layer"),
            "dispatch_action stamps the transaction with the action name");
        // And it is a real undoable step.
        assert!(model.can_undo(), "new_layer is undoable");
    }

    // OP_LOG.md §9 Phase P1 — production-route proof for the print-config
    // setters. Drives the REAL renderer.rs production handler
    // (`run_yaml_effects_named`) for a representative print-config verb against a
    // real AppState/Model, and asserts:
    //   (1) the committed Transaction journals the verb op with the RESOLVED
    //       field + value (the production eval → literal path, NOT the YAML
    //       expr string) and EMPTY targets (document-global config);
    //   (2) checkpoint_equivalence: replaying the journaled op via `op_apply`
    //       from a fresh copy of the pre-edit document is byte-identical to the
    //       live snapshot-path document. This proves the production param-
    //       building matches what replay expects.
    // This is the production-side counterpart to the operations-fixture proof in
    // cross_language_test.rs (which drives op_apply directly via the harness).
    #[test]
    fn production_route_journals_print_config_setter() {
        use crate::geometry::test_json::document_to_test_json;
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, false),
        ]);
        // Snapshot the pre-edit document so we can replay the journal onto a
        // fresh copy for the checkpoint_equivalence gate.
        let pre_doc = st.tabs[st.active_tab].model.document().clone();
        let before = st.tabs[st.active_tab].model.journal().len();

        // Mirror the real `document_setup_confirm` action: a `snapshot` opens
        // the txn, then the field setter runs through the production handler.
        // `run_yaml_effects_named` owns + names + commits the transaction.
        let eval_ctx = serde_json::json!({});
        let effects = vec![
            serde_json::json!("snapshot"),
            serde_json::json!({
                "doc.set_document_setup_field": { "field": "grid_size", "value": "42" }
            }),
        ];
        run_yaml_effects_named(&effects, &eval_ctx, &mut st, Some("document_setup_confirm"));

        let model = &st.tabs[st.active_tab].model;
        // (1a) exactly one new, named transaction.
        assert_eq!(model.journal().len(), before + 1,
            "the print-config action commits one transaction");
        let txn = model.journal().last().expect("a committed transaction");
        assert_eq!(txn.name.as_deref(), Some("document_setup_confirm"),
            "the transaction is named with its action verb");
        // (1b) it journals the verb op with the RESOLVED field + value.
        assert_eq!(txn.ops.len(), 1, "exactly one print-config op journaled");
        let op = &txn.ops[0];
        assert_eq!(op.op, "set_document_setup_field", "the journaled verb");
        assert_eq!(op.params["field"], serde_json::json!("grid_size"),
            "the resolved field name");
        // The YAML value "42" is a STRING expr; the production path evaluates it
        // to the number 42 and journals that RESOLVED literal (replay has no
        // eval context, so the param MUST be the literal, not the expr string).
        assert_eq!(op.params["value"], serde_json::json!(42),
            "the journaled value is the RESOLVED literal, not the YAML expr");
        // (1c) document-global config ⇒ empty targets.
        assert!(op.targets.is_empty(),
            "print-config ops carry empty targets (document-global)");
        // The mutation actually landed.
        assert_eq!(model.document().document_setup.grid_size, 42.0,
            "grid_size was set on the live document");

        // (2) checkpoint_equivalence: replay the journal op from the pre-edit
        // document and byte-compare to the live snapshot-path document.
        let snapshot_doc = document_to_test_json(model.document());
        let mut replay = crate::document::model::Model::new(pre_doc, None);
        for t in model.journal() {
            for o in &t.ops {
                crate::document::op_apply::op_apply(&mut replay, &o.params);
            }
        }
        let replay_doc = document_to_test_json(replay.document());
        assert_eq!(replay_doc, snapshot_doc,
            "checkpoint_equivalence: journal replay == snapshot path");
    }

    // OP_LOG.md §9 Phase P2 — production-route proofs for the artboard doc.*
    // setters. These drive the REAL renderer.rs production handler
    // (`run_yaml_effects_named`) for representative artboard verbs against a real
    // AppState/Model carrying two known-id artboards, and assert (per verb):
    //   (1) the committed Transaction journals the verb op with the RESOLVED
    //       params (the production eval → literal path, NOT the YAML expr string)
    //       and the ARTBOARD-ID targets (set_artboard_field → [id];
    //       delete_artboard_by_id → [deleted id]);
    //   (2) checkpoint_equivalence: replaying the journaled op via `op_apply`
    //       from a fresh copy of the pre-edit document is byte-identical to the
    //       live snapshot-path document.
    // Counterpart to the operations-fixture proof in cross_language_test.rs
    // (which drives op_apply directly via the harness).

    /// Build an AppState whose active document carries two artboards with known
    /// ids ("ab1", "ab2"), so the production artboard verbs have something to
    /// write. Re-uses make_state_with_layers for the tab/layer scaffolding.
    fn make_state_with_two_artboards() -> AppState {
        use crate::document::artboard::Artboard;
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, false),
        ]);
        let mut new_doc = st.tabs[st.active_tab].model.document().clone();
        new_doc.artboards = vec![
            Artboard::default_with_id("ab1".into()),
            Artboard::default_with_id("ab2".into()),
        ];
        st.tabs[st.active_tab].model.set_document_unbracketed(new_doc);
        st
    }

    /// Replay the whole journal onto a fresh model seeded from `pre_doc` and
    /// byte-compare to the live document — the checkpoint_equivalence gate.
    fn assert_artboard_checkpoint_equivalence(
        st: &AppState,
        pre_doc: crate::document::document::Document,
    ) {
        use crate::geometry::test_json::document_to_test_json;
        let model = &st.tabs[st.active_tab].model;
        let snapshot_doc = document_to_test_json(model.document());
        let mut replay = crate::document::model::Model::new(pre_doc, None);
        for t in model.journal() {
            for o in &t.ops {
                crate::document::op_apply::op_apply(&mut replay, &o.params);
            }
        }
        let replay_doc = document_to_test_json(replay.document());
        assert_eq!(replay_doc, snapshot_doc,
            "checkpoint_equivalence: journal replay == snapshot path");
    }

    #[test]
    fn production_route_journals_set_artboard_field() {
        let mut st = make_state_with_two_artboards();
        let pre_doc = st.tabs[st.active_tab].model.document().clone();
        let before = st.tabs[st.active_tab].model.journal().len();

        // Mirror artboard_options_confirm: a `snapshot` opens the txn, then the
        // field setter runs through the production handler. The YAML `value` and
        // `id` are STRING exprs (the production eval resolves them to literals).
        let eval_ctx = serde_json::json!({});
        let effects = vec![
            serde_json::json!("snapshot"),
            serde_json::json!({
                "doc.set_artboard_field": { "id": "'ab2'", "field": "x", "value": "100" }
            }),
        ];
        run_yaml_effects_named(&effects, &eval_ctx, &mut st, Some("artboard_options_confirm"));

        let model = &st.tabs[st.active_tab].model;
        assert_eq!(model.journal().len(), before + 1,
            "the artboard action commits one transaction");
        let txn = model.journal().last().expect("a committed transaction");
        assert_eq!(txn.name.as_deref(), Some("artboard_options_confirm"));
        assert_eq!(txn.ops.len(), 1, "exactly one artboard op journaled");
        let op = &txn.ops[0];
        assert_eq!(op.op, "set_artboard_field");
        assert_eq!(op.params["id"], serde_json::json!("ab2"),
            "the resolved artboard id (not the expr string)");
        assert_eq!(op.params["field"], serde_json::json!("x"));
        // "100" is a STRING expr; production evals it to the number 100 and
        // journals that RESOLVED literal (replay has no eval context).
        assert_eq!(op.params["value"], serde_json::json!(100),
            "the journaled value is the RESOLVED literal, not the YAML expr");
        // P2 targets model: the artboard id(s) written.
        assert_eq!(op.targets, vec!["ab2".to_string()],
            "set_artboard_field targets carry the written artboard id");
        // The mutation landed on the right artboard.
        let ab2 = model.document().artboards.iter().find(|a| a.id == "ab2").unwrap();
        assert_eq!(ab2.x, 100.0);

        assert_artboard_checkpoint_equivalence(&st, pre_doc);
    }

    #[test]
    fn production_route_journals_delete_artboard_by_id() {
        let mut st = make_state_with_two_artboards();
        let pre_doc = st.tabs[st.active_tab].model.document().clone();
        let before = st.tabs[st.active_tab].model.journal().len();

        let eval_ctx = serde_json::json!({});
        let effects = vec![
            serde_json::json!("snapshot"),
            serde_json::json!({ "doc.delete_artboard_by_id": "'ab1'" }),
        ];
        run_yaml_effects_named(&effects, &eval_ctx, &mut st, Some("delete_artboard_from_dialog"));

        let model = &st.tabs[st.active_tab].model;
        assert_eq!(model.journal().len(), before + 1);
        let txn = model.journal().last().expect("a committed transaction");
        assert_eq!(txn.ops.len(), 1, "exactly one delete op journaled");
        let op = &txn.ops[0];
        assert_eq!(op.op, "delete_artboard_by_id");
        assert_eq!(op.params["id"], serde_json::json!("ab1"),
            "the resolved artboard id");
        assert_eq!(op.targets, vec!["ab1".to_string()],
            "delete targets carry the deleted artboard id");
        assert_eq!(model.document().artboards.len(), 1);
        assert_eq!(model.document().artboards[0].id, "ab2");

        assert_artboard_checkpoint_equivalence(&st, pre_doc);
    }

    #[test]
    fn production_route_set_artboard_options_field_empty_targets() {
        let mut st = make_state_with_two_artboards();
        let pre_doc = st.tabs[st.active_tab].model.document().clone();

        // The default is `true`; set `false` so the edit is a real change (a
        // no-net-change txn would be dropped by the commit-time no-op rule).
        let eval_ctx = serde_json::json!({});
        let effects = vec![
            serde_json::json!("snapshot"),
            serde_json::json!({
                "doc.set_artboard_options_field": { "field": "fade_region_outside_artboard", "value": "false" }
            }),
        ];
        run_yaml_effects_named(&effects, &eval_ctx, &mut st, Some("artboard_options_confirm"));

        let model = &st.tabs[st.active_tab].model;
        let txn = model.journal().last().expect("a committed transaction");
        assert_eq!(txn.ops.len(), 1);
        let op = &txn.ops[0];
        assert_eq!(op.op, "set_artboard_options_field");
        assert_eq!(op.params["value"], serde_json::json!(false),
            "the resolved bool literal");
        // Document-global config ⇒ empty targets.
        assert!(op.targets.is_empty(),
            "set_artboard_options_field carries empty targets (document-global)");
        assert!(!model.document().artboard_options.fade_region_outside_artboard);

        assert_artboard_checkpoint_equivalence(&st, pre_doc);
    }

    // OP_LOG.md §9 Phase P3 — production-route proofs for the TWO id-minting
    // artboard verbs (`create_artboard` / `duplicate_artboard`). These drive the
    // REAL renderer.rs production handler (`run_yaml_effects_named`) against a
    // real AppState/Model and assert the VALUE-IN-OP id strategy end to end:
    //   (1) the committed Transaction journals the verb op carrying a LITERAL
    //       id/new_id (a base36 string, NOT a YAML expr) plus RESOLVED params
    //       (fields / name / offsets), with targets == [new_id];
    //   (2) the live document has the new artboard with that exact id;
    //   (3) checkpoint_equivalence: replaying the journal from a fresh copy of the
    //       PRE-edit document is byte-identical to the live (minted) document —
    //       proving the captured-id replay reproduces the entropic mint without
    //       re-minting. (op_apply NEVER taps entropy on replay.)
    // Counterpart to the operations-fixture proof in cross_language_test.rs.

    /// True iff `s` is a plausible minted artboard id: a non-empty base36 token
    /// that is NOT a leftover YAML expr (no quotes / spaces / `doc.` / parens).
    /// The production path must journal the MINTED literal, never the expr string.
    fn looks_like_minted_id(s: &str) -> bool {
        !s.is_empty()
            && s.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
    }

    #[test]
    fn production_route_journals_create_artboard() {
        let mut st = make_state_with_two_artboards();
        let pre_doc = st.tabs[st.active_tab].model.document().clone();
        let before = st.tabs[st.active_tab].model.journal().len();
        let count_before = pre_doc.artboards.len();

        // Mirror the real `new_artboard` action: a `snapshot` opens the txn, then
        // create_artboard mints an id (production entropy) and journals it as a
        // LITERAL. The `x`/`name` field values are STRING exprs (production evals
        // them to literals before journaling).
        let eval_ctx = serde_json::json!({});
        let effects = vec![
            serde_json::json!("snapshot"),
            serde_json::json!({
                "doc.create_artboard": { "name": "'Cover'", "x": "500", "width": "400" }
            }),
        ];
        run_yaml_effects_named(&effects, &eval_ctx, &mut st, Some("new_artboard"));

        let model = &st.tabs[st.active_tab].model;
        assert_eq!(model.journal().len(), before + 1,
            "create_artboard commits one transaction");
        let txn = model.journal().last().expect("a committed transaction");
        assert_eq!(txn.name.as_deref(), Some("new_artboard"));
        assert_eq!(txn.ops.len(), 1, "exactly one create op journaled");
        let op = &txn.ops[0];
        assert_eq!(op.op, "create_artboard");
        // (1) the op carries a LITERAL minted id, not an expr.
        let minted = op.params["id"].as_str().expect("id is a string literal");
        assert!(looks_like_minted_id(minted),
            "the journaled id is a MINTED literal, not a YAML expr: {minted:?}");
        // RESOLVED field overrides (the production eval → literal path).
        assert_eq!(op.params["fields"]["name"], serde_json::json!("Cover"),
            "the resolved name field (not the expr string)");
        assert_eq!(op.params["fields"]["x"], serde_json::json!(500),
            "the resolved x field (RESOLVED literal, not the YAML expr)");
        assert_eq!(op.params["fields"]["width"], serde_json::json!(400));
        // targets carry the created artboard id.
        assert_eq!(op.targets, vec![minted.to_string()],
            "create targets carry the new artboard id");
        // (2) the live document has the new artboard with that id + fields.
        assert_eq!(model.document().artboards.len(), count_before + 1);
        let created = model.document().artboards.iter()
            .find(|a| a.id == minted).expect("the created artboard is in the doc");
        assert_eq!(created.name, "Cover");
        assert_eq!(created.x, 500.0);
        assert_eq!(created.width, 400.0);

        // (3) checkpoint_equivalence: replay from the pre-edit doc reproduces the
        // live (minted) doc byte-identically — the captured-id replay matches the
        // minted-id production (replay never re-mints).
        assert_artboard_checkpoint_equivalence(&st, pre_doc);
    }

    #[test]
    fn production_route_journals_duplicate_artboard() {
        let mut st = make_state_with_two_artboards();
        // Make ab1 distinctive so we can prove the clone copied source geometry.
        {
            let mut d = st.tabs[st.active_tab].model.document().clone();
            if let Some(ab) = d.artboards.iter_mut().find(|a| a.id == "ab1") {
                ab.x = 10.0;
                ab.y = 20.0;
                ab.width = 333.0;
            }
            st.tabs[st.active_tab].model.set_document_unbracketed(d);
        }
        // Snapshot the pre-edit document AFTER the setup write, so replay starts
        // from the same baseline the live edit does.
        let pre_doc = st.tabs[st.active_tab].model.document().clone();
        let before = st.tabs[st.active_tab].model.journal().len();
        let count_before = pre_doc.artboards.len();

        // Mirror the real `duplicate_artboard` action: { id, offset_x, offset_y }.
        let eval_ctx = serde_json::json!({});
        let effects = vec![
            serde_json::json!("snapshot"),
            serde_json::json!({
                "doc.duplicate_artboard": { "id": "'ab1'", "offset_x": "5", "offset_y": "7" }
            }),
        ];
        run_yaml_effects_named(&effects, &eval_ctx, &mut st, Some("duplicate_artboard"));

        let model = &st.tabs[st.active_tab].model;
        assert_eq!(model.journal().len(), before + 1,
            "duplicate_artboard commits one transaction");
        let txn = model.journal().last().expect("a committed transaction");
        assert_eq!(txn.name.as_deref(), Some("duplicate_artboard"));
        assert_eq!(txn.ops.len(), 1, "exactly one duplicate op journaled");
        let op = &txn.ops[0];
        assert_eq!(op.op, "duplicate_artboard");
        // The source id is the resolved literal, not the expr.
        assert_eq!(op.params["id"], serde_json::json!("ab1"),
            "the resolved source id");
        // (1) the op carries a LITERAL minted new_id, not an expr.
        let minted = op.params["new_id"].as_str().expect("new_id is a string literal");
        assert!(looks_like_minted_id(minted),
            "the journaled new_id is a MINTED literal, not a YAML expr: {minted:?}");
        assert_ne!(minted, "ab1", "the duplicate gets a fresh id");
        // RESOLVED derived name + offsets are journaled as literals.
        assert!(op.params["name"].as_str().expect("name literal").starts_with("Artboard "),
            "the RESOLVED next-artboard name is journaled (not re-derived on replay)");
        assert_eq!(op.params["offset_x"], serde_json::json!(5.0),
            "the resolved offset_x literal");
        assert_eq!(op.params["offset_y"], serde_json::json!(7.0),
            "the resolved offset_y literal");
        // targets carry the new (duplicated) artboard id.
        assert_eq!(op.targets, vec![minted.to_string()],
            "duplicate targets carry the new artboard id");
        // (2) the live document has the clone with copied geometry + offset.
        assert_eq!(model.document().artboards.len(), count_before + 1);
        let dup = model.document().artboards.iter()
            .find(|a| a.id == minted).expect("the duplicated artboard is in the doc");
        assert_eq!(dup.x, 15.0, "source x (10) + offset_x (5)");
        assert_eq!(dup.y, 27.0, "source y (20) + offset_y (7)");
        assert_eq!(dup.width, 333.0, "source width copied");

        // (3) checkpoint_equivalence: replay from the pre-edit doc reproduces the
        // live minted doc byte-identically.
        assert_artboard_checkpoint_equivalence(&st, pre_doc);
    }

    // OP_LOG.md §9 Phase P4 — production-route proofs for the structural
    // tree-mutation verbs. These drive the REAL renderer.rs production handler
    // (`dispatch_action` → `run_yaml_effects_named`) for the COMPOSITE actions
    // against a real AppState/Model, and assert (per action):
    //   (1) the committed Transaction journals the structural op(s) — crucially,
    //       the composites journal as ONE insert op (the preceding clone_at /
    //       create_layer binders are NON-JOURNALED — they only bind ctx values);
    //   (2) the live document reflects the mutation;
    //   (3) checkpoint_equivalence: replaying the journal via `op_apply` from a
    //       fresh copy of the pre-edit document is byte-identical to the live
    //       snapshot-path document — INCLUDING the inserted element with its
    //       value-in-op id, the heart of P4.
    // Counterpart to the operations-fixture proof in cross_language_test.rs.

    /// `duplicate_layer_selection` = `clone_at` (NON-JOURNALED ctx binder) →
    /// `insert_after` (the ONLY journaled op). Per duplicated path it journals
    /// exactly ONE `insert_after` op carrying the WHOLE clone element as literal
    /// JSON (value-in-op). Proves the clone_at binder journals NOTHING.
    #[test]
    fn production_route_duplicate_layer_selection_journals_one_insert_after() {
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, false),
            ("B".into(), Visibility::Preview, false),
        ]);
        // Select the second layer (path [1]) so duplicate inserts one clone.
        st.layers_panel_selection = vec![vec![1]];
        let pre_doc = st.tabs[st.active_tab].model.document().clone();
        let before = st.tabs[st.active_tab].model.journal().len();

        let params = serde_json::Map::new();
        dispatch_action("duplicate_layer_selection", &params, &mut st);

        let model = &st.tabs[st.active_tab].model;
        // (1) exactly one new, named transaction journaling exactly ONE op...
        assert_eq!(model.journal().len(), before + 1,
            "duplicate_layer_selection commits one transaction");
        let txn = model.journal().last().expect("a committed transaction");
        assert_eq!(txn.name.as_deref(), Some("duplicate_layer_selection"));
        // ...and that ONE op is the insert_after — the clone_at binder is
        // NON-JOURNALED (it only binds the clone JSON into ctx).
        assert_eq!(txn.ops.len(), 1,
            "exactly ONE op journaled (clone_at is non-journaled; only insert_after journals)");
        let op = &txn.ops[0];
        assert_eq!(op.op, "insert_after", "the journaled verb is insert_after");
        // The op carries the WHOLE element as literal JSON (value-in-op): it must
        // deserialize back to a valid Element (a Layer named "B").
        let carried: crate::geometry::element::Element =
            serde_json::from_value(op.params["element"].clone())
                .expect("the op carries a deserializable element (value-in-op)");
        let carried_name = match &carried {
            crate::geometry::element::Element::Layer(le) => le.name().to_string(),
            other => panic!("expected the carried element to be a Layer, got {other:?}"),
        };
        assert_eq!(carried_name, "B", "the carried element is the clone of layer B");
        // targets carry the inserted element id ONLY when it has one. The clone of
        // an id-less layer B is id-less, so targets is empty (Fork 4 metadata; the
        // byte-gate ignores it).
        assert_eq!(op.targets, carried.common().id.clone().into_iter().collect::<Vec<_>>(),
            "targets carry the inserted element id when set, else empty");
        // (2) the live doc has the duplicate: A, B, B.
        let layers = &model.document().layers;
        assert_eq!(layers.len(), 3);
        assert_eq!(tab_layer(&st, 0).name(), "A");
        assert_eq!(tab_layer(&st, 1).name(), "B");
        assert_eq!(tab_layer(&st, 2).name(), "B");
        // (3) checkpoint_equivalence.
        assert_artboard_checkpoint_equivalence(&st, pre_doc);
    }

    /// `new_layer` = `create_layer` (NON-JOURNALED deterministic Layer factory,
    /// bound as ctx JSON) → `insert_at` (the ONLY journaled op). Journals exactly
    /// ONE `insert_at` op carrying the created Layer as literal JSON. Proves the
    /// create_layer binder journals NOTHING.
    #[test]
    fn production_route_new_layer_journals_one_insert_at() {
        let mut st = make_state_with_layers(vec![
            ("Layer 1".into(), Visibility::Preview, false),
        ]);
        st.layers_panel_selection = vec![];
        let pre_doc = st.tabs[st.active_tab].model.document().clone();
        let before = st.tabs[st.active_tab].model.journal().len();

        let params = serde_json::Map::new();
        dispatch_action("new_layer", &params, &mut st);

        let model = &st.tabs[st.active_tab].model;
        // (1) exactly one new, named transaction journaling exactly ONE op...
        assert_eq!(model.journal().len(), before + 1,
            "new_layer commits one transaction");
        let txn = model.journal().last().expect("a committed transaction");
        assert_eq!(txn.name.as_deref(), Some("new_layer"));
        // ...and that ONE op is insert_at — create_layer is NON-JOURNALED.
        assert_eq!(txn.ops.len(), 1,
            "exactly ONE op journaled (create_layer is non-journaled; only insert_at journals)");
        let op = &txn.ops[0];
        assert_eq!(op.op, "insert_at", "the journaled verb is insert_at");
        // The op carries the created Layer as literal JSON (value-in-op).
        let carried: crate::geometry::element::Element =
            serde_json::from_value(op.params["element"].clone())
                .expect("the op carries a deserializable element (value-in-op)");
        assert!(matches!(carried, crate::geometry::element::Element::Layer(_)),
            "the carried element is a Layer (from the create_layer factory)");
        // (2) the live doc has the new auto-named layer at the end.
        let layers = &model.document().layers;
        assert_eq!(layers.len(), 2);
        assert_eq!(tab_layer(&st, 1).name(), "Layer 2");
        // (3) checkpoint_equivalence.
        assert_artboard_checkpoint_equivalence(&st, pre_doc);
    }

    /// `delete_layer_selection` routes its `doc.delete_at` per path through
    /// op_apply. Drives the composite and proves the deletes journal as
    /// `delete_at` ops + the gate holds. (The reference-aware `delete_selection`
    /// variant is exercised by the operations fixture; here we use the panel
    /// delete which is the production surface for delete_at.)
    #[test]
    fn production_route_delete_selection_journals_through_op_apply() {
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, false),
            ("B".into(), Visibility::Preview, false),
            ("C".into(), Visibility::Preview, false),
        ]);
        // Select an element on the canvas so doc.delete_selection has an operand.
        // delete_clean_confirm_ok is the reference-aware delete OK path:
        // snapshot + doc.delete_selection. Build the selection directly.
        {
            use crate::document::document::ElementSelection;
            let mut d = st.tabs[st.active_tab].model.document().clone();
            d.selection = vec![ElementSelection::all(vec![1])];
            st.tabs[st.active_tab].model.set_document_unbracketed(d);
        }
        let pre_doc = st.tabs[st.active_tab].model.document().clone();
        let before = st.tabs[st.active_tab].model.journal().len();

        // Drive the production doc.delete_selection handler (the reference-aware
        // delete OK path), which now routes through op_apply.
        let eval_ctx = serde_json::json!({});
        let effects = vec![
            serde_json::json!("snapshot"),
            serde_json::json!({"doc.delete_selection": null}),
        ];
        run_yaml_effects_named(&effects, &eval_ctx, &mut st, Some("delete_clean_confirm_ok"));

        let model = &st.tabs[st.active_tab].model;
        assert_eq!(model.journal().len(), before + 1,
            "delete_selection commits one transaction");
        let txn = model.journal().last().expect("a committed transaction");
        assert_eq!(txn.ops.len(), 1, "exactly one delete_selection op journaled");
        assert_eq!(txn.ops[0].op, "delete_selection", "the journaled verb");
        // The live doc dropped layer B.
        let layers = &model.document().layers;
        assert_eq!(layers.len(), 2);
        assert_eq!(tab_layer(&st, 0).name(), "A");
        assert_eq!(tab_layer(&st, 1).name(), "C");
        // checkpoint_equivalence.
        assert_artboard_checkpoint_equivalence(&st, pre_doc);
    }

    /// OP_LOG.md §9 — the NATIVE no-orphan Delete/Cut gesture (`menu_bar.rs` +
    /// `keyboard.rs` fast path) routes through `op_apply` via the shared
    /// `journal_delete_selection` helper, so it journals a real
    /// `delete_selection` op (parity with the YAML orphan-confirm path and the
    /// sibling apps) while staying exactly one undo step. Drives the REAL helper
    /// the four production sites call.
    #[test]
    fn production_route_native_delete_selection_journals_through_op_apply() {
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, false),
            ("B".into(), Visibility::Preview, false),
            ("C".into(), Visibility::Preview, false),
        ]);
        {
            use crate::document::document::ElementSelection;
            let mut d = st.tabs[st.active_tab].model.document().clone();
            d.selection = vec![ElementSelection::all(vec![1])];
            st.tabs[st.active_tab].model.set_document_unbracketed(d);
        }
        let pre_doc = st.tabs[st.active_tab].model.document().clone();
        let before = st.tabs[st.active_tab].model.journal().len();

        crate::document::op_apply::journal_delete_selection(
            &mut st.tabs[st.active_tab].model, "delete_selection");

        let model = &st.tabs[st.active_tab].model;
        assert_eq!(model.journal().len(), before + 1,
            "the native delete commits exactly one transaction");
        let txn = model.journal().last().expect("a committed transaction");
        assert_eq!(txn.ops.len(), 1, "exactly one delete_selection op journaled");
        assert_eq!(txn.ops[0].op, "delete_selection", "the journaled verb");
        assert_eq!(txn.name.as_deref(), Some("delete_selection"),
            "the txn is named with the gesture verb");
        // The live doc dropped layer B.
        let layers = &model.document().layers;
        assert_eq!(layers.len(), 2);
        assert_eq!(tab_layer(&st, 0).name(), "A");
        assert_eq!(tab_layer(&st, 1).name(), "C");
        // checkpoint_equivalence: replay == snapshot path, byte-identical.
        assert_artboard_checkpoint_equivalence(&st, pre_doc);
        // One undo step restores the deletion (one gesture = one undo step).
        st.tabs[st.active_tab].model.undo();
        assert_eq!(st.tabs[st.active_tab].model.document().layers.len(), 3,
            "a single undo restores all three layers");
    }

    // OP_LOG.md §9 Phase P5 — production-route proofs for the THREE group/layer
    // wrapping verbs. These drive the REAL renderer.rs production handler
    // (`dispatch_action` → the composite action) against a real AppState/Model and
    // assert (per verb): (1) exactly ONE op journaled with the RESOLVED flat params
    // (plain `[[..],..]` paths; wrap_in_layer carrying the LITERAL resolved name —
    // NOT the next_layer_name expr); (2) the live tree mutated correctly via the
    // multi-step reconstruction; (3) targets; (4) checkpoint_equivalence — the
    // journal replays byte-identically to the snapshot path, proving the multi-step
    // reconstructs the EXACT tree (child order + insertion index) from the op alone.

    /// `new_group` drives `doc.wrap_in_group` over the panel selection. Journals
    /// exactly ONE `wrap_in_group` op carrying the RESOLVED plain index arrays; the
    /// live tree gets a new Group at the topmost source index wrapping both
    /// selections in document order.
    #[test]
    fn production_route_new_group_journals_one_wrap_in_group() {
        use crate::geometry::element::Element;
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, false),
            ("B".into(), Visibility::Preview, false),
            ("C".into(), Visibility::Preview, false),
        ]);
        // Select top-level layers 0 and 2 (paths [0] and [2]).
        st.layers_panel_selection = vec![vec![0], vec![2]];
        let pre_doc = st.tabs[st.active_tab].model.document().clone();
        let before = st.tabs[st.active_tab].model.journal().len();

        let params = serde_json::Map::new();
        dispatch_action("new_group", &params, &mut st);

        let model = &st.tabs[st.active_tab].model;
        // (1) exactly one named transaction journaling exactly ONE wrap_in_group op
        // carrying the RESOLVED plain index arrays.
        assert_eq!(model.journal().len(), before + 1,
            "new_group commits one transaction");
        let txn = model.journal().last().expect("a committed transaction");
        assert_eq!(txn.name.as_deref(), Some("new_group"));
        assert_eq!(txn.ops.len(), 1,
            "exactly ONE op journaled (the multi-step wrap is ONE op)");
        let op = &txn.ops[0];
        assert_eq!(op.op, "wrap_in_group", "the journaled verb is wrap_in_group");
        assert_eq!(op.params["paths"], serde_json::json!([[0], [2]]),
            "the op carries the RESOLVED plain index arrays (sorted document order)");
        // (2) the live doc: new Group at idx 0 (topmost source) wrapping A + C; B
        // survives at idx 1.
        let layers = &model.document().layers;
        assert_eq!(layers.len(), 2);
        match &layers[0] {
            Element::Group(g) => {
                assert_eq!(g.children.len(), 2, "the group wraps both selections");
                assert_eq!(g.children[0].common().name.as_deref(), Some("A"));
                assert_eq!(g.children[1].common().name.as_deref(), Some("C"));
            }
            other => panic!("expected Group at idx 0, got {other:?}"),
        }
        assert_eq!(tab_layer(&st, 1).name(), "B");
        // (3) targets: A and C are id-less, no container id assigned ⇒ empty.
        assert!(op.targets.is_empty(),
            "id-less wrapped elements + no assigned id ⇒ empty targets");
        // (4) checkpoint_equivalence.
        assert_artboard_checkpoint_equivalence(&st, pre_doc);
    }

    /// `collect_in_new_layer` drives `doc.wrap_in_layer` with
    /// `name: active_document.next_layer_name`. The CRITICAL P5 proof: the renderer
    /// evaluates `next_layer_name` against the LIVE doc FIRST and journals the
    /// RESOLVED LITERAL — NOT the expr. The setup is rigged so re-deriving the name
    /// on replay (from the mutated tree) would yield a DIFFERENT name: with two
    /// existing layers "Layer 1"/"Layer 2", `next_layer_name` resolves to "Layer 3";
    /// after both are wrapped, the only surviving layer is the new "Layer 3", so a
    /// re-derivation would pick "Layer 1". Pinning the journaled literal to "Layer 3"
    /// + the checkpoint_equivalence gate together prove replay reuses the literal.
    #[test]
    fn production_route_collect_in_new_layer_journals_resolved_name_literal() {
        use crate::geometry::element::Element;
        let mut st = make_state_with_layers(vec![
            ("Layer 1".into(), Visibility::Preview, false),
            ("Layer 2".into(), Visibility::Preview, false),
        ]);
        // Compute the name the renderer SHOULD resolve, BEFORE the mutation, the
        // same way the eval ctx derives it (smallest "Layer N" not already taken).
        let resolved_name_before = {
            let existing: std::collections::HashSet<String> = st.tabs[st.active_tab]
                .model.document().layers.iter()
                .filter_map(|e| match e {
                    Element::Layer(le) => Some(le.name().to_string()),
                    _ => None,
                })
                .collect();
            let mut n = 1usize;
            loop {
                let cand = format!("Layer {n}");
                if !existing.contains(&cand) { break cand; }
                n += 1;
            }
        };
        assert_eq!(resolved_name_before, "Layer 3",
            "with Layer 1 + Layer 2 present, next_layer_name resolves to Layer 3");

        st.layers_panel_selection = vec![vec![0], vec![1]];
        let pre_doc = st.tabs[st.active_tab].model.document().clone();
        let before = st.tabs[st.active_tab].model.journal().len();

        let params = serde_json::Map::new();
        dispatch_action("collect_in_new_layer", &params, &mut st);

        let model = &st.tabs[st.active_tab].model;
        // (1) exactly one wrap_in_layer op.
        assert_eq!(model.journal().len(), before + 1,
            "collect_in_new_layer commits one transaction");
        let txn = model.journal().last().expect("a committed transaction");
        assert_eq!(txn.name.as_deref(), Some("collect_in_new_layer"));
        assert_eq!(txn.ops.len(), 1, "exactly ONE wrap_in_layer op journaled");
        let op = &txn.ops[0];
        assert_eq!(op.op, "wrap_in_layer");
        assert_eq!(op.params["paths"], serde_json::json!([[0], [1]]),
            "the op carries the RESOLVED plain index arrays");
        // THE P5 CRUX: the op carries the RESOLVED name LITERAL — equal to what
        // next_layer_name returned BEFORE the mutation ("Layer 3"), NOT the expr
        // string "active_document.next_layer_name".
        assert_eq!(op.params["name"], serde_json::json!(resolved_name_before),
            "wrap_in_layer journals the RESOLVED name literal, not the expr");
        assert_eq!(op.params["name"], serde_json::json!("Layer 3"));
        assert_ne!(op.params["name"], serde_json::json!("active_document.next_layer_name"),
            "the op must NOT carry the name expr (replay has no eval context)");
        // (2) the live doc: both originals collected into ONE new top-level layer.
        let layers = &model.document().layers;
        assert_eq!(layers.len(), 1, "both layers collected into one new layer");
        match &layers[0] {
            Element::Layer(le) => {
                assert_eq!(le.name(), "Layer 3", "the new layer carries the resolved name");
                assert_eq!(le.children.len(), 2, "it wraps both collected layers");
            }
            other => panic!("expected Layer at idx 0, got {other:?}"),
        }
        // (3) targets: id-less collected layers + no assigned id ⇒ empty.
        assert!(op.targets.is_empty());
        // (4) checkpoint_equivalence: replay reuses the LITERAL "Layer 3" (a
        // re-derivation would have produced "Layer 1" — the gate would catch it).
        assert_artboard_checkpoint_equivalence(&st, pre_doc);
    }

    /// `flatten_artwork` drives `doc.unpack_group_at` per panel-selected path.
    /// Journals exactly ONE `unpack_group_at` op (single selection) carrying the
    /// RESOLVED plain index path; the live tree replaces the group with its
    /// children at the vacated position, ascending. Children keep their identities.
    #[test]
    fn production_route_flatten_artwork_journals_one_unpack_group_at() {
        use crate::geometry::element::{Element, GroupElem, LayerElem, CommonProps};
        use std::rc::Rc;
        let mut st = make_state_with_layers(vec![
            ("Layer 1".into(), Visibility::Preview, false),
        ]);
        // Build [Layer A, Group(c1, c2), Layer B] at the top level.
        let mk_layer = |name: &str| Element::Layer(LayerElem {
            children: Vec::new(), isolated_blending: false, knockout_group: false,
            common: CommonProps { name: Some(name.into()), ..Default::default() },
        });
        let group = Element::Group(GroupElem {
            children: vec![Rc::new(mk_layer("c1")), Rc::new(mk_layer("c2"))],
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        });
        {
            let mut new_doc = st.tabs[st.active_tab].model.document().clone();
            new_doc.layers = vec![mk_layer("A"), group, mk_layer("B")];
            st.tabs[st.active_tab].model.set_document_unbracketed(new_doc);
        }
        // Select the group (path [1]).
        st.layers_panel_selection = vec![vec![1]];
        let pre_doc = st.tabs[st.active_tab].model.document().clone();
        let before = st.tabs[st.active_tab].model.journal().len();

        let params = serde_json::Map::new();
        dispatch_action("flatten_artwork", &params, &mut st);

        let model = &st.tabs[st.active_tab].model;
        // (1) exactly one unpack_group_at op carrying the RESOLVED plain path.
        assert_eq!(model.journal().len(), before + 1,
            "flatten_artwork commits one transaction");
        let txn = model.journal().last().expect("a committed transaction");
        assert_eq!(txn.name.as_deref(), Some("flatten_artwork"));
        assert_eq!(txn.ops.len(), 1, "exactly ONE unpack_group_at op journaled");
        let op = &txn.ops[0];
        assert_eq!(op.op, "unpack_group_at");
        assert_eq!(op.params["path"], serde_json::json!([1]),
            "the op carries the RESOLVED plain index path");
        // (2) the live doc: group dissolved into c1, c2 at the vacated position.
        let names: Vec<String> = model.document().layers.iter().map(|e| match e {
            Element::Layer(le) => le.name().to_string(),
            other => format!("{other:?}"),
        }).collect();
        assert_eq!(names, vec!["A", "c1", "c2", "B"]);
        // (3) targets: the unpacked children are id-less ⇒ empty.
        assert!(op.targets.is_empty());
        // (4) checkpoint_equivalence.
        assert_artboard_checkpoint_equivalence(&st, pre_doc);
    }

    // ── Phase 3 Group B: doc.delete_at / doc.clone_at / doc.insert_after

    #[test]
    fn doc_delete_at_top_level() {
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, false),
            ("B".into(), Visibility::Preview, false),
            ("C".into(), Visibility::Preview, false),
        ]);
        let eval_ctx = serde_json::json!({});
        // Mirror real actions: a doc.* mutation rides a `snapshot` txn.
        let effects = vec![
            serde_json::json!("snapshot"),
            serde_json::json!({"doc.delete_at": "path(1)"}),
        ];
        run_yaml_effects(&effects, &eval_ctx, &mut st);
        let layers = &st.tabs[st.active_tab].model.document().layers;
        assert_eq!(layers.len(), 2);
        assert_eq!(tab_layer(&st, 0).name(), "A");
        assert_eq!(tab_layer(&st, 1).name(), "C");
    }

    #[test]
    fn doc_clone_at_then_insert_after_duplicates() {
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, false),
            ("B".into(), Visibility::Preview, false),
        ]);
        let eval_ctx = serde_json::json!({});
        let effects = vec![
            serde_json::json!("snapshot"),
            serde_json::json!({"doc.clone_at": "path(0)", "as": "clone"}),
            serde_json::json!({"doc.insert_after": {"path": "path(0)", "element": "clone"}}),
        ];
        run_yaml_effects(&effects, &eval_ctx, &mut st);
        let layers = &st.tabs[st.active_tab].model.document().layers;
        assert_eq!(layers.len(), 3);
        assert_eq!(tab_layer(&st, 0).name(), "A");
        assert_eq!(tab_layer(&st, 1).name(), "A");   // clone
        assert_eq!(tab_layer(&st, 2).name(), "B");
    }

    #[test]
    fn delete_layer_selection_action_via_yaml() {
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, false),
            ("B".into(), Visibility::Preview, false),
            ("C".into(), Visibility::Preview, false),
        ]);
        st.layers_panel_selection = vec![vec![0], vec![2]];
        let params = serde_json::Map::new();
        dispatch_action("delete_layer_selection", &params, &mut st);
        let layers = &st.tabs[st.active_tab].model.document().layers;
        assert_eq!(layers.len(), 1);
        assert_eq!(tab_layer(&st, 0).name(), "B");
        assert_eq!(st.layers_panel_selection.len(), 0);
    }

    #[test]
    fn flatten_artwork_unpacks_panel_selected_groups() {
        use crate::geometry::element::{Element, GroupElem, LayerElem, CommonProps};
        use std::rc::Rc;
        let mut st = AppState::new();
        if st.tabs.is_empty() {
            use crate::workspace::app_state::TabState;
            st.tabs.push(TabState::new());
            st.active_tab = 0;
        }
        // Construct a doc: [Layer A, Group G(child1, child2), Layer B]
        let layer_a = Element::Layer(LayerElem { children: Vec::new(),
            isolated_blending: false, knockout_group: false,
            common: CommonProps { name: Some("A".into()), ..Default::default() },
        });
        let child1 = Element::Layer(LayerElem { children: Vec::new(),
            isolated_blending: false, knockout_group: false,
            common: CommonProps { name: Some("c1".into()), ..Default::default() },
        });
        let child2 = Element::Layer(LayerElem { children: Vec::new(),
            isolated_blending: false, knockout_group: false,
            common: CommonProps { name: Some("c2".into()), ..Default::default() },
        });
        let group = Element::Group(GroupElem {
            children: vec![Rc::new(child1), Rc::new(child2)],
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        });
        let layer_b = Element::Layer(LayerElem { children: Vec::new(),
            isolated_blending: false, knockout_group: false,
            common: CommonProps { name: Some("B".into()), ..Default::default() },
        });
        let mut new_doc = st.tabs[st.active_tab].model.document().clone();
        new_doc.layers = vec![layer_a, group, layer_b];
        st.tabs[st.active_tab].model.set_document_unbracketed(new_doc);
        st.layers_panel_selection = vec![vec![1]];
        let params = serde_json::Map::new();
        dispatch_action("flatten_artwork", &params, &mut st);
        let layers = &st.tabs[st.active_tab].model.document().layers;
        assert_eq!(layers.len(), 4);
        // Children c1 and c2 are NOT Layers but are held as Rc<Element>;
        // the unpacker dereferences. After unpack: A, c1, c2, B.
        let names: Vec<String> = layers.iter().map(|e| match e {
            Element::Layer(le) => le.name().to_string(),
            _ => format!("{:?}", e),
        }).collect();
        assert_eq!(names, vec!["A", "c1", "c2", "B"]);
    }

    #[test]
    fn collect_in_new_layer_wraps_selection_at_end() {
        use crate::geometry::element::Element;
        let mut st = make_state_with_layers(vec![
            ("Layer 1".into(), Visibility::Preview, false),
            ("Layer 2".into(), Visibility::Preview, false),
            ("Layer 3".into(), Visibility::Preview, false),
        ]);
        st.layers_panel_selection = vec![vec![0], vec![2]];
        let params = serde_json::Map::new();
        dispatch_action("collect_in_new_layer", &params, &mut st);
        let layers = &st.tabs[st.active_tab].model.document().layers;
        assert_eq!(layers.len(), 2);
        // Layer 2 (not in selection) survives at idx 0;
        // new auto-named Layer 4 at idx 1 with Layer 1 + Layer 3 as children.
        assert_eq!(tab_layer(&st, 0).name(), "Layer 2");
        match &layers[1] {
            Element::Layer(le) => {
                assert_eq!(le.name(), "Layer 4");
                assert_eq!(le.children.len(), 2);
            }
            other => panic!("expected Layer at idx 1, got {:?}", other),
        }
    }

    #[test]
    fn new_group_action_wraps_top_level_layers() {
        // The YAML migration now allows wrapping top-level layers into
        // a Group (which the pre-Phase-3 Rust arm disallowed).
        use crate::geometry::element::{Element, GroupElem};
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, false),
            ("B".into(), Visibility::Preview, false),
            ("C".into(), Visibility::Preview, false),
        ]);
        st.layers_panel_selection = vec![vec![0], vec![2]];
        let params = serde_json::Map::new();
        dispatch_action("new_group", &params, &mut st);
        let layers = &st.tabs[st.active_tab].model.document().layers;
        assert_eq!(layers.len(), 2);
        // New Group at idx 0 (topmost source), B remains at idx 1
        match &layers[0] {
            Element::Group(g) => {
                assert_eq!(g.children.len(), 2);
            }
            other => panic!("expected Group at idx 0, got {:?}", other),
        }
        assert_eq!(tab_layer(&st, 1).name(), "B");
    }

    #[test]
    fn enter_isolation_mode_via_yaml_with_container_id() {
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, false),
        ]);
        assert!(st.layers_isolation_stack.is_empty());
        let mut params = serde_json::Map::new();
        params.insert("container_id".into(), serde_json::Value::String("0".into()));
        dispatch_action("enter_isolation_mode", &params, &mut st);
        assert_eq!(st.layers_isolation_stack.len(), 1);
        assert_eq!(st.layers_isolation_stack[0], vec![0]);
    }

    #[test]
    fn enter_isolation_mode_via_yaml_fallback_to_selection() {
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, false),
            ("B".into(), Visibility::Preview, false),
        ]);
        st.layers_panel_selection = vec![vec![1]];
        let params = serde_json::Map::new();
        dispatch_action("enter_isolation_mode", &params, &mut st);
        assert_eq!(st.layers_isolation_stack.len(), 1);
        assert_eq!(st.layers_isolation_stack[0], vec![1]);
    }

    #[test]
    fn new_layer_action_via_yaml_no_selection() {
        let mut st = make_state_with_layers(vec![
            ("Layer 1".into(), Visibility::Preview, false),
        ]);
        st.layers_panel_selection = vec![];
        let params = serde_json::Map::new();
        dispatch_action("new_layer", &params, &mut st);
        let layers = &st.tabs[st.active_tab].model.document().layers;
        assert_eq!(layers.len(), 2);
        // Auto-generated name skips Layer 1
        assert_eq!(tab_layer(&st, 1).name(), "Layer 2");
    }

    #[test]
    fn new_layer_action_via_yaml_with_selection_inserts_above() {
        let mut st = make_state_with_layers(vec![
            ("Layer 1".into(), Visibility::Preview, false),
            ("Layer 2".into(), Visibility::Preview, false),
            ("Layer 3".into(), Visibility::Preview, false),
        ]);
        st.layers_panel_selection = vec![vec![1]];
        let params = serde_json::Map::new();
        dispatch_action("new_layer", &params, &mut st);
        let layers = &st.tabs[st.active_tab].model.document().layers;
        assert_eq!(layers.len(), 4);
        // Inserted at index 2 (selection 1 + 1); next unused name is Layer 4
        assert_eq!(tab_layer(&st, 2).name(), "Layer 4");
        // Layer 3 shifted to index 3
        assert_eq!(tab_layer(&st, 3).name(), "Layer 3");
    }

    #[test]
    fn duplicate_layer_selection_action_via_yaml() {
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, false),
            ("B".into(), Visibility::Preview, false),
        ]);
        st.layers_panel_selection = vec![vec![1]];
        let params = serde_json::Map::new();
        dispatch_action("duplicate_layer_selection", &params, &mut st);
        let layers = &st.tabs[st.active_tab].model.document().layers;
        assert_eq!(layers.len(), 3);
        assert_eq!(tab_layer(&st, 0).name(), "A");
        assert_eq!(tab_layer(&st, 1).name(), "B");
        assert_eq!(tab_layer(&st, 2).name(), "B");
    }

    #[test]
    fn open_layer_options_edit_mode_passes_layer_state() {
        let mut st = make_state_with_layers(vec![
            ("Target".into(), Visibility::Outline, true),
        ]);
        let mut params = serde_json::Map::new();
        params.insert("mode".into(), serde_json::Value::String("edit".into()));
        params.insert("layer_id".into(), serde_json::Value::String("0".into()));
        let deferred = dispatch_action("open_layer_options", &params, &mut st);
        // open_dialog is deferred with dialog params derived from the layer.
        let od = deferred.iter()
            .find_map(|e| e.get("open_dialog"))
            .and_then(|v| v.as_object())
            .expect("expected deferred open_dialog");
        let dlg_params = od.get("params").and_then(|p| p.as_object())
            .expect("open_dialog with params");
        assert_eq!(dlg_params.get("mode").and_then(|v| v.as_str()), Some("edit"));
        assert_eq!(dlg_params.get("layer_id").and_then(|v| v.as_str()), Some("0"));
        assert_eq!(dlg_params.get("name").and_then(|v| v.as_str()), Some("Target"));
        assert_eq!(dlg_params.get("lock").and_then(|v| v.as_bool()), Some(true));
        // visibility=outline → show=true (not invisible), preview=false
        assert_eq!(dlg_params.get("show").and_then(|v| v.as_bool()), Some(true));
        assert_eq!(dlg_params.get("preview").and_then(|v| v.as_bool()), Some(false));
    }

    #[test]
    fn open_layer_options_create_mode_passes_defaults() {
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, false),
        ]);
        let mut params = serde_json::Map::new();
        params.insert("mode".into(), serde_json::Value::String("create".into()));
        params.insert("layer_id".into(), serde_json::Value::Null);
        let deferred = dispatch_action("open_layer_options", &params, &mut st);
        let od = deferred.iter()
            .find_map(|e| e.get("open_dialog"))
            .and_then(|v| v.as_object())
            .expect("expected deferred open_dialog");
        let dlg_params = od.get("params").and_then(|p| p.as_object()).unwrap();
        // Create mode: layer_elem is null, so name defaults to empty,
        // lock to false, show/preview to true.
        assert_eq!(dlg_params.get("name").and_then(|v| v.as_str()), Some(""));
        assert_eq!(dlg_params.get("lock").and_then(|v| v.as_bool()), Some(false));
        assert_eq!(dlg_params.get("show").and_then(|v| v.as_bool()), Some(true));
        assert_eq!(dlg_params.get("preview").and_then(|v| v.as_bool()), Some(true));
    }

    #[test]
    fn layer_options_confirm_edit_mode_updates_layer() {
        let mut st = make_state_with_layers(vec![
            ("Old".into(), Visibility::Preview, false),
        ]);
        let mut params = serde_json::Map::new();
        params.insert("layer_id".into(), serde_json::Value::String("0".into()));
        params.insert("name".into(), serde_json::Value::String("Renamed".into()));
        params.insert("lock".into(), serde_json::Value::Bool(true));
        params.insert("show".into(), serde_json::Value::Bool(true));
        params.insert("preview".into(), serde_json::Value::Bool(false));
        let deferred = dispatch_action("layer_options_confirm", &params, &mut st);
        // Edit-mode YAML ends with close_dialog which is deferred.
        assert!(deferred.iter().any(|e| e.get("close_dialog").is_some()));
        let layer = tab_layer(&st, 0);
        assert_eq!(layer.name(), "Renamed");
        assert!(layer.common.locked);
        assert_eq!(layer.common.visibility, Visibility::Outline);
    }

    #[test]
    fn layer_options_confirm_show_off_sets_invisible() {
        // LYR-244: Show=false should set the layer's visibility to
        // Invisible regardless of preview.
        let mut st = make_state_with_layers(vec![
            ("L".into(), Visibility::Preview, false),
        ]);
        let mut params = serde_json::Map::new();
        params.insert("layer_id".into(), serde_json::Value::String("0".into()));
        params.insert("name".into(), serde_json::Value::String("L".into()));
        params.insert("lock".into(), serde_json::Value::Bool(false));
        params.insert("show".into(), serde_json::Value::Bool(false));
        params.insert("preview".into(), serde_json::Value::Bool(true));
        dispatch_action("layer_options_confirm", &params, &mut st);
        assert_eq!(
            tab_layer(&st, 0).common.visibility,
            Visibility::Invisible,
            "show=false should map to Invisible visibility",
        );
    }

    #[test]
    fn layer_options_confirm_create_mode_inserts_layer() {
        let mut st = make_state_with_layers(vec![
            ("Existing".into(), Visibility::Preview, false),
        ]);
        st.layers_panel_selection = vec![];
        let mut params = serde_json::Map::new();
        params.insert("layer_id".into(), serde_json::Value::Null);
        params.insert("name".into(), serde_json::Value::String("Brand New".into()));
        params.insert("lock".into(), serde_json::Value::Bool(false));
        params.insert("show".into(), serde_json::Value::Bool(true));
        params.insert("preview".into(), serde_json::Value::Bool(true));
        dispatch_action("layer_options_confirm", &params, &mut st);
        let layers = &st.tabs[st.active_tab].model.document().layers;
        assert_eq!(layers.len(), 2);
        assert_eq!(tab_layer(&st, 1).name(), "Brand New");
        assert_eq!(tab_layer(&st, 1).common.visibility, Visibility::Preview);
    }

    #[test]
    fn doc_delete_at_reverse_order_via_foreach() {
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, false),
            ("B".into(), Visibility::Preview, false),
            ("C".into(), Visibility::Preview, false),
            ("D".into(), Visibility::Preview, false),
        ]);
        let eval_ctx = serde_json::json!({});
        let effects = vec![
            serde_json::json!("snapshot"),
            serde_json::json!({
                "foreach": {"source": "[path(2), path(0)]", "as": "p"},
                "do": [{"doc.delete_at": "p"}]
            }),
        ];
        run_yaml_effects(&effects, &eval_ctx, &mut st);
        let layers = &st.tabs[st.active_tab].model.document().layers;
        assert_eq!(layers.len(), 2);
        assert_eq!(tab_layer(&st, 0).name(), "B");
        assert_eq!(tab_layer(&st, 1).name(), "D");
    }

    // ── Phase 4: Paragraph panel writes ─────────────────────────

    #[test]
    fn set_paragraph_field_radio_clears_others() {
        use crate::workspace::app_state::ParagraphPanelState;
        let mut pp = ParagraphPanelState::default();
        // Default has align_left=true. Click justify_center.
        set_paragraph_field(&mut pp, "justify_center", &serde_json::json!(true));
        assert!(!pp.align_left);
        assert!(pp.justify_center);
        assert!(!pp.align_center);
        assert!(!pp.justify_left);
    }

    #[test]
    fn set_paragraph_field_bullets_clears_numbered_list() {
        use crate::workspace::app_state::ParagraphPanelState;
        let mut pp = ParagraphPanelState::default();
        pp.numbered_list = "num-decimal".into();
        set_paragraph_field(&mut pp, "bullets", &serde_json::json!("bullet-disc"));
        assert_eq!(pp.bullets, "bullet-disc");
        assert_eq!(pp.numbered_list, "");
    }

    #[test]
    fn set_paragraph_field_numbered_clears_bullets() {
        use crate::workspace::app_state::ParagraphPanelState;
        let mut pp = ParagraphPanelState::default();
        pp.bullets = "bullet-disc".into();
        set_paragraph_field(&mut pp, "numbered_list", &serde_json::json!("num-decimal"));
        assert_eq!(pp.numbered_list, "num-decimal");
        assert_eq!(pp.bullets, "");
    }

    #[test]
    fn set_paragraph_field_empty_string_does_not_clear_other() {
        use crate::workspace::app_state::ParagraphPanelState;
        let mut pp = ParagraphPanelState::default();
        pp.numbered_list = "num-decimal".into();
        // Setting bullets to "" (the "None" option) shouldn't blow away
        // the user's chosen numbered_list value.
        set_paragraph_field(&mut pp, "bullets", &serde_json::json!(""));
        assert_eq!(pp.bullets, "");
        assert_eq!(pp.numbered_list, "num-decimal");
    }

    #[test]
    fn set_paragraph_field_indents_and_space() {
        use crate::workspace::app_state::ParagraphPanelState;
        let mut pp = ParagraphPanelState::default();
        set_paragraph_field(&mut pp, "left_indent", &serde_json::json!(18.0));
        set_paragraph_field(&mut pp, "right_indent", &serde_json::json!(9.0));
        set_paragraph_field(&mut pp, "first_line_indent", &serde_json::json!(-12.0));
        set_paragraph_field(&mut pp, "space_before", &serde_json::json!(6.0));
        set_paragraph_field(&mut pp, "space_after", &serde_json::json!(3.0));
        assert_eq!(pp.left_indent, 18.0);
        assert_eq!(pp.right_indent, 9.0);
        assert_eq!(pp.first_line_indent, -12.0);
        assert_eq!(pp.space_before, 6.0);
        assert_eq!(pp.space_after, 3.0);
    }

    fn select_first_text(st: &mut AppState) {
        use crate::workspace::app_state::TabState;
        use crate::document::document::ElementSelection;
        use crate::geometry::tspan::Tspan;
        if st.tabs.is_empty() {
            st.tabs.push(TabState::new());
            st.active_tab = 0;
        }
        // Build an area-text element with one paragraph wrapper and
        // one body tspan. Start from empty_text_elem so the string
        // fields default sanely.
        let mut t = crate::tools::text_edit::empty_text_elem(0.0, 0.0, 200.0, 100.0);
        let wrapper = Tspan {
            id: 0, content: String::new(),
            jas_role: Some("paragraph".into()),
            ..Default::default()
        };
        let body = Tspan { id: 1, content: "hello".into(), ..Default::default() };
        t.tspans = vec![wrapper, body];
        let text_with_tspans = Element::Text(t);
        // Place the text inside the first layer.
        let mut new_doc = st.tabs[st.active_tab].model.document().clone();
        if let Some(Element::Layer(layer)) = new_doc.layers.get_mut(0) {
            layer.children = vec![std::rc::Rc::new(text_with_tspans)];
        }
        new_doc.selection = vec![ElementSelection::all(vec![0, 0])];
        st.tabs[st.active_tab].model.set_document_unbracketed(new_doc);
    }

    #[test]
    fn apply_paragraph_panel_writes_indents_to_wrapper() {
        let mut st = AppState::new();
        select_first_text(&mut st);
        st.paragraph_panel.left_indent = 18.0;
        st.paragraph_panel.right_indent = 9.0;
        st.apply_paragraph_panel_to_selection();
        let elem = st.tabs[st.active_tab].model.document().get_element(&vec![0usize, 0]).unwrap();
        if let crate::geometry::element::Element::Text(t) = elem {
            let w = &t.tspans[0];
            assert_eq!(w.jas_role.as_deref(), Some("paragraph"));
            assert_eq!(w.jas_left_indent, Some(18.0));
            assert_eq!(w.jas_right_indent, Some(9.0));
        } else {
            panic!("expected Text");
        }
    }

    #[test]
    fn apply_paragraph_panel_omits_defaults() {
        let mut st = AppState::new();
        select_first_text(&mut st);
        // Defaults (everything 0 / false / empty) should produce all
        // None on the wrapper — identity-value rule.
        st.apply_paragraph_panel_to_selection();
        let elem = st.tabs[st.active_tab].model.document().get_element(&vec![0usize, 0]).unwrap();
        if let crate::geometry::element::Element::Text(t) = elem {
            let w = &t.tspans[0];
            assert_eq!(w.jas_left_indent, None);
            assert_eq!(w.jas_right_indent, None);
            assert_eq!(w.jas_space_before, None);
            assert_eq!(w.jas_space_after, None);
            assert_eq!(w.jas_hyphenate, None);
            assert_eq!(w.jas_hanging_punctuation, None);
            assert_eq!(w.jas_list_style, None);
            assert_eq!(w.text_align, None);  // align_left (default) → omit
            assert_eq!(w.text_align_last, None);
        }
    }

    #[test]
    fn apply_paragraph_panel_alignment_radio() {
        let mut st = AppState::new();
        select_first_text(&mut st);
        // Set justify_center via setter (clears align_left).
        set_paragraph_field(&mut st.paragraph_panel, "justify_center", &serde_json::json!(true));
        st.apply_paragraph_panel_to_selection();
        let elem = st.tabs[st.active_tab].model.document().get_element(&vec![0usize, 0]).unwrap();
        if let crate::geometry::element::Element::Text(t) = elem {
            assert_eq!(t.tspans[0].text_align.as_deref(), Some("justify"));
            assert_eq!(t.tspans[0].text_align_last.as_deref(), Some("center"));
        }
    }

    #[test]
    fn reset_paragraph_panel_clears_wrapper_attrs() {
        let mut st = AppState::new();
        select_first_text(&mut st);
        // First populate wrapper with attrs.
        st.paragraph_panel.left_indent = 24.0;
        st.paragraph_panel.hyphenate = true;
        st.paragraph_panel.bullets = "bullet-disc".into();
        st.apply_paragraph_panel_to_selection();
        // Then reset.
        st.reset_paragraph_panel();
        let elem = st.tabs[st.active_tab].model.document().get_element(&vec![0usize, 0]).unwrap();
        if let crate::geometry::element::Element::Text(t) = elem {
            let w = &t.tspans[0];
            assert_eq!(w.jas_left_indent, None);
            assert_eq!(w.jas_hyphenate, None);
            assert_eq!(w.jas_list_style, None);
        }
        // Panel state itself reset to defaults.
        assert_eq!(st.paragraph_panel.left_indent, 0.0);
        assert!(!st.paragraph_panel.hyphenate);
        assert_eq!(st.paragraph_panel.bullets, "");
        assert!(st.paragraph_panel.align_left);  // back to default
    }

    fn select_first_rect(st: &mut AppState, fill_gradient: Option<crate::geometry::element::Gradient>) {
        use crate::workspace::app_state::TabState;
        use crate::document::document::ElementSelection;
        use crate::geometry::element::{
            CommonProps, Color, Fill, RectElem,
        };
        if st.tabs.is_empty() {
            st.tabs.push(TabState::new());
            st.active_tab = 0;
        }
        let r = Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 100.0, height: 50.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::rgb(1.0, 0.0, 0.0))),
            stroke: None,
            common: CommonProps::default(),
            fill_gradient: fill_gradient.map(Box::new),
            stroke_gradient: None,
        });
        let mut new_doc = st.tabs[st.active_tab].model.document().clone();
        if let Some(Element::Layer(layer)) = new_doc.layers.get_mut(0) {
            layer.children = vec![std::rc::Rc::new(r)];
        }
        new_doc.selection = vec![ElementSelection::all(vec![0, 0])];
        st.tabs[st.active_tab].model.set_document_unbracketed(new_doc);
    }

    // ── Part B.2: Properties panel field editing ──────────────────────
    #[test]
    fn props_apply_x_moves() {
        let mut st = AppState::new();
        select_first_rect(&mut st, None); // rect (0,0,100,50)
        apply_properties_panel_field(&mut st, "prop_x", &serde_json::json!(40.0));
        let doc = st.tab().unwrap().model.document();
        assert!((crate::canvas::render::selection_evaluated_bounds(doc).0 - 40.0).abs() < 1e-6);
    }

    #[test]
    fn props_apply_w_scales() {
        let mut st = AppState::new();
        select_first_rect(&mut st, None);
        apply_properties_panel_field(&mut st, "prop_w", &serde_json::json!(200.0));
        let doc = st.tab().unwrap().model.document();
        let (_, _, w, h) = crate::canvas::render::selection_evaluated_bounds(doc);
        assert!((w - 200.0).abs() < 1e-6, "w={}", w);
        assert!((h - 50.0).abs() < 1e-6, "h={}", h);
    }

    #[test]
    fn props_w_with_constrain_scales_both() {
        let mut st = AppState::new();
        select_first_rect(&mut st, None); // 100x50
        st.properties_constrain = true;
        apply_properties_panel_field(&mut st, "prop_w", &serde_json::json!(200.0));
        let doc = st.tab().unwrap().model.document();
        let (_, _, w, h) = crate::canvas::render::selection_evaluated_bounds(doc);
        assert!((w - 200.0).abs() < 1e-6, "w={}", w);
        assert!((h - 100.0).abs() < 1e-6, "h={}", h); // H follows (×2)
    }

    #[test]
    fn props_apply_rotation_swaps_extents() {
        let mut st = AppState::new();
        select_first_rect(&mut st, None); // 100x50
        apply_properties_panel_field(&mut st, "prop_rotation", &serde_json::json!(90.0));
        let doc = st.tab().unwrap().model.document();
        let (_, _, w, h) = crate::canvas::render::selection_evaluated_bounds(doc);
        assert!((w - 50.0).abs() < 1e-4, "w={}", w);
        assert!((h - 100.0).abs() < 1e-4, "h={}", h);
    }

    #[test]
    fn props_apply_opacity_and_blend() {
        use crate::geometry::element::BlendMode;
        let mut st = AppState::new();
        select_first_rect(&mut st, None);
        apply_properties_panel_field(&mut st, "prop_opacity", &serde_json::json!(40.0));
        apply_properties_panel_field(&mut st, "prop_blend", &serde_json::json!("multiply"));
        let doc = st.tab().unwrap().model.document();
        let e = doc.get_element(&vec![0, 0]).unwrap();
        assert!((e.opacity() - 0.4).abs() < 1e-6);
        assert_eq!(e.mode(), BlendMode::Multiply);
    }

    #[test]
    fn props_w_multi_selection_scales_group() {
        use crate::document::document::ElementSelection;
        let mut st = AppState::new();
        select_first_rect(&mut st, None); // rect (0,0,100,50)
        // Add a second rect at x=200 and select both -> union bbox W = 300.
        {
            let mut nd = st.tabs[st.active_tab].model.document().clone();
            if let Some(Element::Layer(layer)) = nd.layers.get_mut(0) {
                layer.children.push(std::rc::Rc::new(Element::Rect(
                    crate::geometry::element::RectElem {
                        x: 200.0, y: 0.0, width: 100.0, height: 50.0, rx: 0.0, ry: 0.0,
                        fill: None, stroke: None,
                        common: crate::geometry::element::CommonProps::default(),
                        fill_gradient: None, stroke_gradient: None,
                    })));
            }
            nd.selection = vec![ElementSelection::all(vec![0, 0]),
                                ElementSelection::all(vec![0, 1])];
            st.tabs[st.active_tab].model.set_document_unbracketed(nd);
        }
        // Set W=600 -> group scales 2x about the bbox top-left (x only).
        apply_properties_panel_field(&mut st, "prop_w", &serde_json::json!(600.0));
        let (x, _, w, h) = crate::canvas::render::selection_evaluated_bounds(
            st.tab().unwrap().model.document());
        assert!((w - 600.0).abs() < 1e-6, "w={}", w);
        assert!((x - 0.0).abs() < 1e-6, "x={}", x);   // bbox top-left preserved
        assert!((h - 50.0).abs() < 1e-6, "h={}", h);  // H unchanged
    }

    // ── SHEAR-FIELD: shear apply (single / preserves-shear / multi) ────────
    /// Decompose a transform's shear angle (degrees) directly, mirroring the
    /// reference read-back: shear = atan((a*c + b*d) / (a*d - b*c)).
    fn decomposed_shear_deg(t: &crate::geometry::element::Transform) -> f64 {
        let det = t.a * t.d - t.b * t.c;
        ((t.a * t.c + t.b * t.d) / det).atan().to_degrees()
    }

    #[test]
    fn props_apply_shear() {
        // T2: rect 100x50 at origin, apply shear 30 -> decomposed shear ~= 30.
        let mut st = AppState::new();
        select_first_rect(&mut st, None); // rect (0,0,100,50)
        apply_properties_panel_field(&mut st, "prop_shear", &serde_json::json!(30.0));
        let doc = st.tab().unwrap().model.document();
        let e = doc.get_element(&vec![0, 0]).unwrap();
        let t = e.transform().expect("transform set by shear");
        assert!((decomposed_shear_deg(t) - 30.0).abs() < 1e-4,
            "shear={}", decomposed_shear_deg(t));
    }

    #[test]
    fn props_rotation_preserves_shear() {
        // T3: apply shear 30 THEN rotation 45 -> decomposed shear ~= 30 AND
        // rotation atan2(b,a) ~= 45 (the rotation upgrade keeps the shear).
        let mut st = AppState::new();
        select_first_rect(&mut st, None); // rect (0,0,100,50)
        apply_properties_panel_field(&mut st, "prop_shear", &serde_json::json!(30.0));
        apply_properties_panel_field(&mut st, "prop_rotation", &serde_json::json!(45.0));
        let doc = st.tab().unwrap().model.document();
        let e = doc.get_element(&vec![0, 0]).unwrap();
        let t = e.transform().expect("transform set");
        assert!((decomposed_shear_deg(t) - 30.0).abs() < 1e-4,
            "shear={}", decomposed_shear_deg(t));
        let rot = t.b.atan2(t.a).to_degrees();
        assert!((rot - 45.0).abs() < 1e-4, "rot={}", rot);
    }

    #[test]
    fn props_shear_multi_selection_shears_group() {
        // T4: two 10x10 rects at x=0 and x=100 (union (0,0,110,10), center
        // (55,5)); apply shear 45 -> evaluated bounds w~=120, h~=10, x~=-5.
        use crate::document::document::ElementSelection;
        let mut st = AppState::new();
        select_first_rect(&mut st, None); // we replace both children below
        {
            let mut nd = st.tabs[st.active_tab].model.document().clone();
            if let Some(Element::Layer(layer)) = nd.layers.get_mut(0) {
                let mk = |x: f64| std::rc::Rc::new(Element::Rect(
                    crate::geometry::element::RectElem {
                        x, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
                        fill: None, stroke: None,
                        common: crate::geometry::element::CommonProps::default(),
                        fill_gradient: None, stroke_gradient: None,
                    }));
                layer.children = vec![mk(0.0), mk(100.0)];
            }
            nd.selection = vec![ElementSelection::all(vec![0, 0]),
                                ElementSelection::all(vec![0, 1])];
            st.tabs[st.active_tab].model.set_document_unbracketed(nd);
        }
        apply_properties_panel_field(&mut st, "prop_shear", &serde_json::json!(45.0));
        let (x, _, w, h) = crate::canvas::render::selection_evaluated_bounds(
            st.tab().unwrap().model.document());
        assert!((w - 120.0).abs() < 1e-4, "w={}", w);
        assert!((h - 10.0).abs() < 1e-4, "h={}", h);
        assert!((x + 5.0).abs() < 1e-4, "x={}", x);
    }

    #[test]
    fn props_shear_no_selection_no_crash() {
        // Empty selection must be a no-op (mirrors the sibling guards).
        let mut st = AppState::new();
        if st.tabs.is_empty() {
            st.tabs.push(crate::workspace::app_state::TabState::new());
            st.active_tab = 0;
        }
        apply_properties_panel_field(&mut st, "prop_shear", &serde_json::json!(30.0));
    }

    #[test]
    fn sync_gradient_panel_uniform_with_gradient() {
        use crate::geometry::element::{
            Color, Gradient, GradientStop, GradientType, GradientMethod, StrokeSubMode,
        };
        let g = Gradient {
            gtype: GradientType::Radial,
            angle: 30.0,
            aspect_ratio: 200.0,
            method: GradientMethod::Smooth,
            dither: true,
            stroke_sub_mode: StrokeSubMode::Within,
            stops: vec![
                GradientStop { color: Color::rgb(0.0, 1.0, 0.0), opacity: 100.0, location: 0.0,   midpoint_to_next: 50.0 },
                GradientStop { color: Color::rgb(0.0, 0.0, 1.0), opacity: 100.0, location: 100.0, midpoint_to_next: 50.0 },
            ],
            nodes: Vec::new(),
        };
        let mut st = AppState::new();
        st.fill_on_top = true;
        select_first_rect(&mut st, Some(g.clone()));
        st.sync_gradient_panel_from_selection();
        assert_eq!(st.gradient_panel.gtype, "radial");
        assert_eq!(st.gradient_panel.angle, 30.0);
        assert_eq!(st.gradient_panel.aspect_ratio, 200.0);
        assert_eq!(st.gradient_panel.method, "smooth");
        assert!(st.gradient_panel.dither);
        assert_eq!(st.gradient_panel.stops.len(), 2);
        assert!(!st.gradient_panel.preview_state);
    }

    #[test]
    fn sync_gradient_panel_solid_seeds_preview() {
        use crate::geometry::element::Color;
        let mut st = AppState::new();
        st.fill_on_top = true;
        // Selected element has a solid red fill, no gradient.
        select_first_rect(&mut st, None);
        st.sync_gradient_panel_from_selection();
        // Preview state set; first stop seeded from the solid color.
        assert!(st.gradient_panel.preview_state);
        assert_eq!(st.gradient_panel.gtype, "linear");
        assert_eq!(st.gradient_panel.stops.len(), 2);
        assert_eq!(st.gradient_panel.stops[0].color, Color::rgb(1.0, 0.0, 0.0));
        // Second stop is the conventional white per fill-type-coupling rule.
        assert_eq!(st.gradient_panel.stops[1].color, Color::WHITE);
    }

    #[test]
    fn apply_gradient_panel_writes_fill_gradient() {
        use crate::geometry::element::{
            Color, Element, GradientStop, GradientType, GradientMethod, StrokeSubMode,
        };
        let mut st = AppState::new();
        st.fill_on_top = true;
        select_first_rect(&mut st, None);
        // Configure panel state, then apply.
        st.gradient_panel.gtype = "radial".into();
        st.gradient_panel.angle = 90.0;
        st.gradient_panel.aspect_ratio = 150.0;
        st.gradient_panel.method = "smooth".into();
        st.gradient_panel.dither = true;
        st.gradient_panel.stroke_sub_mode = "across".into();
        st.gradient_panel.stops = vec![
            GradientStop { color: Color::rgb(1.0, 0.0, 0.0), opacity: 100.0, location: 0.0,   midpoint_to_next: 50.0 },
            GradientStop { color: Color::rgb(0.0, 1.0, 0.0), opacity: 100.0, location: 100.0, midpoint_to_next: 50.0 },
        ];
        st.gradient_panel.preview_state = true; // pretend we're promoting
        st.apply_gradient_panel_to_selection();
        // Preview-state cleared after first edit.
        assert!(!st.gradient_panel.preview_state);
        // Element gained a fill_gradient with the panel values.
        let elem = st.tabs[st.active_tab].model.document().get_element(&vec![0usize, 0]).unwrap();
        let g = elem.fill_gradient().expect("fill_gradient should be set");
        assert_eq!(g.gtype, GradientType::Radial);
        assert_eq!(g.angle, 90.0);
        assert_eq!(g.aspect_ratio, 150.0);
        assert_eq!(g.method, GradientMethod::Smooth);
        assert!(g.dither);
        assert_eq!(g.stroke_sub_mode, StrokeSubMode::Across);
        assert_eq!(g.stops.len(), 2);
    }

    #[test]
    fn demote_gradient_panel_clears_fill_gradient() {
        use crate::geometry::element::{
            Color, Gradient, GradientStop, GradientType, GradientMethod, StrokeSubMode,
        };
        let g = Gradient {
            gtype: GradientType::Linear,
            angle: 0.0,
            aspect_ratio: 100.0,
            method: GradientMethod::Classic,
            dither: false,
            stroke_sub_mode: StrokeSubMode::Within,
            stops: vec![
                GradientStop { color: Color::rgb(1.0, 0.0, 0.0), opacity: 100.0, location: 0.0,   midpoint_to_next: 50.0 },
                GradientStop { color: Color::WHITE, opacity: 100.0, location: 100.0, midpoint_to_next: 50.0 },
            ],
            nodes: Vec::new(),
        };
        let mut st = AppState::new();
        st.fill_on_top = true;
        select_first_rect(&mut st, Some(g));
        // Sanity: gradient is set.
        let elem = st.tabs[st.active_tab].model.document().get_element(&vec![0usize, 0]).unwrap();
        assert!(elem.fill_gradient().is_some());
        st.demote_gradient_panel_selection();
        // After demote, fill_gradient is None.
        let elem = st.tabs[st.active_tab].model.document().get_element(&vec![0usize, 0]).unwrap();
        assert!(elem.fill_gradient().is_none());
        // The element's solid fill is untouched.
        assert!(elem.fill().is_some());
    }

    #[test]
    fn sync_gradient_panel_no_selection_keeps_defaults() {
        let mut st = AppState::new();
        st.fill_on_top = true;
        // Set up a tab without selecting anything.
        if st.tabs.is_empty() {
            use crate::workspace::app_state::TabState;
            st.tabs.push(TabState::new());
            st.active_tab = 0;
        }
        // Mutate the panel so we can detect that sync didn't touch it.
        st.gradient_panel.gtype = "radial".into();
        st.sync_gradient_panel_from_selection();
        assert_eq!(st.gradient_panel.gtype, "radial");
    }

    #[test]
    fn sync_paragraph_panel_reads_wrapper_into_typed_struct() {
        use crate::geometry::element::Element;
        let mut st = AppState::new();
        select_first_text(&mut st);
        // Hand-craft wrapper with attrs without going through apply.
        let path = vec![0, 0];
        let doc = st.tabs[st.active_tab].model.document().clone();
        let new_elem = if let Some(Element::Text(t)) = doc.get_element(&path) {
            let mut new_t = t.clone();
            new_t.tspans[0].jas_left_indent = Some(36.0);
            new_t.tspans[0].text_align = Some("justify".into());
            new_t.tspans[0].text_align_last = Some("right".into());
            new_t.tspans[0].jas_list_style = Some("num-decimal".into());
            Element::Text(new_t)
        } else { panic!() };
        let new_doc = doc.replace_element(&path, new_elem);
        st.tabs[st.active_tab].model.set_document_unbracketed(new_doc);
        st.sync_paragraph_panel_from_selection();
        assert_eq!(st.paragraph_panel.left_indent, 36.0);
        assert!(st.paragraph_panel.justify_right);
        assert!(!st.paragraph_panel.align_left);
        assert_eq!(st.paragraph_panel.numbered_list, "num-decimal");
        assert_eq!(st.paragraph_panel.bullets, "");
    }

    // ── Phase 8: Justification dialog OK commit ──────────────

    #[test]
    fn apply_justification_dialog_writes_non_default_attrs() {
        let mut st = AppState::new();
        select_first_text(&mut st);
        st.apply_justification_dialog_to_selection(JustificationDialogValues {
            word_spacing_min: Some(75.0),
            word_spacing_desired: Some(95.0),
            word_spacing_max: Some(150.0),
            letter_spacing_min: Some(-5.0),
            letter_spacing_desired: Some(0.0),  // default → omitted
            letter_spacing_max: Some(10.0),
            glyph_scaling_min: Some(95.0),
            glyph_scaling_desired: Some(100.0),  // default → omitted
            glyph_scaling_max: Some(105.0),
            auto_leading: Some(140.0),
            single_word_justify: Some("left".into()),
        });
        let elem = st.tabs[st.active_tab].model.document()
            .get_element(&vec![0usize, 0]).unwrap();
        if let crate::geometry::element::Element::Text(t) = elem {
            let w = &t.tspans[0];
            assert_eq!(w.jas_word_spacing_min, Some(75.0));
            assert_eq!(w.jas_word_spacing_desired, Some(95.0));
            assert_eq!(w.jas_word_spacing_max, Some(150.0));
            assert_eq!(w.jas_letter_spacing_min, Some(-5.0));
            assert_eq!(w.jas_letter_spacing_desired, None);  // identity-omit
            assert_eq!(w.jas_letter_spacing_max, Some(10.0));
            assert_eq!(w.jas_glyph_scaling_min, Some(95.0));
            assert_eq!(w.jas_glyph_scaling_desired, None);  // identity-omit
            assert_eq!(w.jas_glyph_scaling_max, Some(105.0));
            assert_eq!(w.jas_auto_leading, Some(140.0));
            assert_eq!(w.jas_single_word_justify.as_deref(), Some("left"));
        }
    }

    #[test]
    fn apply_justification_dialog_all_defaults_writes_nothing() {
        // All spec defaults → every wrapper attr stays None per the
        // identity-value rule.
        let mut st = AppState::new();
        select_first_text(&mut st);
        st.apply_justification_dialog_to_selection(JustificationDialogValues {
            word_spacing_min: Some(80.0),
            word_spacing_desired: Some(100.0),
            word_spacing_max: Some(133.0),
            letter_spacing_min: Some(0.0),
            letter_spacing_desired: Some(0.0),
            letter_spacing_max: Some(0.0),
            glyph_scaling_min: Some(100.0),
            glyph_scaling_desired: Some(100.0),
            glyph_scaling_max: Some(100.0),
            auto_leading: Some(120.0),
            single_word_justify: Some("justify".into()),
        });
        let elem = st.tabs[st.active_tab].model.document()
            .get_element(&vec![0usize, 0]).unwrap();
        if let crate::geometry::element::Element::Text(t) = elem {
            let w = &t.tspans[0];
            assert_eq!(w.jas_word_spacing_min, None);
            assert_eq!(w.jas_word_spacing_desired, None);
            assert_eq!(w.jas_word_spacing_max, None);
            assert_eq!(w.jas_letter_spacing_min, None);
            assert_eq!(w.jas_letter_spacing_desired, None);
            assert_eq!(w.jas_letter_spacing_max, None);
            assert_eq!(w.jas_glyph_scaling_min, None);
            assert_eq!(w.jas_glyph_scaling_desired, None);
            assert_eq!(w.jas_glyph_scaling_max, None);
            assert_eq!(w.jas_auto_leading, None);
            assert_eq!(w.jas_single_word_justify, None);
        }
    }

    // ── Phase 9: Hyphenation dialog OK commit ────────────────

    #[test]
    fn apply_hyphenation_dialog_writes_non_default_attrs() {
        let mut st = AppState::new();
        select_first_text(&mut st);
        st.apply_hyphenation_dialog_to_selection(HyphenationDialogValues {
            hyphenate: Some(true),
            min_word: Some(6.0),
            min_before: Some(3.0),
            min_after: Some(1.0),  // default → omitted
            limit: Some(2.0),
            zone: Some(36.0),
            bias: Some(0.0),  // default → omitted
            capitalized: Some(true),
        });
        let elem = st.tabs[st.active_tab].model.document()
            .get_element(&vec![0usize, 0]).unwrap();
        if let crate::geometry::element::Element::Text(t) = elem {
            let w = &t.tspans[0];
            assert_eq!(w.jas_hyphenate, Some(true));
            assert_eq!(w.jas_hyphenate_min_word, Some(6.0));
            assert_eq!(w.jas_hyphenate_min_before, Some(3.0));
            assert_eq!(w.jas_hyphenate_min_after, None);  // identity-omit
            assert_eq!(w.jas_hyphenate_limit, Some(2.0));
            assert_eq!(w.jas_hyphenate_zone, Some(36.0));
            assert_eq!(w.jas_hyphenate_bias, None);  // identity-omit
            assert_eq!(w.jas_hyphenate_capitalized, Some(true));
        }
        // Master mirror: panel.hyphenate updated to dialog value.
        assert!(st.paragraph_panel.hyphenate);
    }

    #[test]
    fn apply_hyphenation_dialog_all_defaults_writes_nothing() {
        // All spec defaults → every wrapper attr stays None per the
        // identity-value rule.
        let mut st = AppState::new();
        select_first_text(&mut st);
        st.apply_hyphenation_dialog_to_selection(HyphenationDialogValues {
            hyphenate: Some(false),
            min_word: Some(3.0),
            min_before: Some(1.0),
            min_after: Some(1.0),
            limit: Some(0.0),
            zone: Some(0.0),
            bias: Some(0.0),
            capitalized: Some(false),
        });
        let elem = st.tabs[st.active_tab].model.document()
            .get_element(&vec![0usize, 0]).unwrap();
        if let crate::geometry::element::Element::Text(t) = elem {
            let w = &t.tspans[0];
            assert_eq!(w.jas_hyphenate, None);
            assert_eq!(w.jas_hyphenate_min_word, None);
            assert_eq!(w.jas_hyphenate_min_before, None);
            assert_eq!(w.jas_hyphenate_min_after, None);
            assert_eq!(w.jas_hyphenate_limit, None);
            assert_eq!(w.jas_hyphenate_zone, None);
            assert_eq!(w.jas_hyphenate_bias, None);
            assert_eq!(w.jas_hyphenate_capitalized, None);
        }
    }

    // ── active_document canvas-selection view ─────────────────
    //
    // Exposes has_selection / selection_count / element_selection for
    // bind.disabled predicates (Align panel Phase 0a).

    use crate::document::document::ElementSelection;

    #[test]
    fn active_document_view_no_tabs_yields_no_selection() {
        let mut st = AppState::new();
        st.tabs.clear();
        st.active_tab = 0;
        let view = build_active_document_view(&st);
        assert_eq!(view["has_selection"], serde_json::json!(false));
        assert_eq!(view["selection_count"], serde_json::json!(0));
        assert_eq!(view["element_selection"], serde_json::json!([]));
    }

    #[test]
    fn active_document_view_empty_selection_yields_no_selection() {
        let st = make_state_with_layers(vec![("A".into(), Visibility::Preview, false)]);
        let view = build_active_document_view(&st);
        assert_eq!(view["has_selection"], serde_json::json!(false));
        assert_eq!(view["selection_count"], serde_json::json!(0));
        assert_eq!(view["element_selection"], serde_json::json!([]));
    }

    #[test]
    fn active_document_view_selection_count_matches_selection_length() {
        let mut st = make_state_with_layers(vec![("A".into(), Visibility::Preview, false)]);
        let mut doc = st.tabs[st.active_tab].model.document().clone();
        doc.selection = vec![
            ElementSelection::all(vec![0]),
            ElementSelection::all(vec![0, 1]),
            ElementSelection::all(vec![0, 2]),
        ];
        st.tabs[st.active_tab].model.set_document_unbracketed(doc);
        let view = build_active_document_view(&st);
        assert_eq!(view["has_selection"], serde_json::json!(true));
        assert_eq!(view["selection_count"], serde_json::json!(3));
    }

    #[test]
    fn active_document_view_element_selection_contains_path_markers() {
        let mut st = make_state_with_layers(vec![("A".into(), Visibility::Preview, false)]);
        let mut doc = st.tabs[st.active_tab].model.document().clone();
        doc.selection = vec![
            ElementSelection::all(vec![0]),
            ElementSelection::all(vec![0, 2]),
        ];
        st.tabs[st.active_tab].model.set_document_unbracketed(doc);
        let view = build_active_document_view(&st);
        let expected = serde_json::json!([
            {"__path__": [0]},
            {"__path__": [0, 2]},
        ]);
        assert_eq!(view["element_selection"], expected);
    }

    #[test]
    fn active_document_view_selected_concept_present_for_single_generated() {
        // Concepts panel Slice 2 (piece A): with exactly one Generated
        // instance selected, active_document.selected_concept is the concept's
        // param schema merged with the instance's current values; null
        // otherwise (CONCEPTS.md §6.4).
        let mut st = make_state_with_layers(vec![("A".into(), Visibility::Preview, false)]);
        // Nothing selected → null.
        assert_eq!(
            build_active_document_view(&st)["selected_concept"],
            serde_json::Value::Null
        );
        // Place a Generated instance (place selects it).
        let params = serde_json::json!({ "radius": 50.0, "sides": 6.0 });
        crate::document::controller::Controller::place_concept_instance(
            &mut st.tabs[st.active_tab].model,
            "regular_polygon",
            params,
            "g1",
        );
        let view = build_active_document_view(&st);
        let sc = &view["selected_concept"];
        assert_eq!(sc["concept_id"], serde_json::json!("regular_polygon"));
        // params is the schema list, each carrying the instance's value.
        let plist = sc["params"].as_array().expect("params array");
        let sides = plist
            .iter()
            .find(|p| p["name"] == serde_json::json!("sides"))
            .expect("sides param");
        assert_eq!(sides["value"], serde_json::json!(6.0));
        // operations (CONCEPTS.md §9): the concept's named edit verbs, so the
        // panel can render a button per operation.
        let ops = sc["operations"].as_array().expect("operations array");
        let ids: Vec<&str> = ops.iter().filter_map(|o| o["id"].as_str()).collect();
        assert!(
            ids.contains(&"add_side") && ids.contains(&"remove_side"),
            "selected_concept.operations lists the concept's verbs: {ids:?}"
        );
        // violations (CONCEPTS.md §11): valid params (sides 6, radius 50) ⇒ none.
        assert_eq!(
            sc["violations"].as_array().expect("violations array").len(),
            0,
            "a valid instance has no constraint violations"
        );
    }

    #[test]
    fn active_document_view_selected_concept_reports_constraint_violations() {
        // CONCEPTS.md §11: a Generated whose params break an invariant surfaces
        // the violated constraint (id + message) in selected_concept.violations.
        let mut st = make_state_with_layers(vec![("A".into(), Visibility::Preview, false)]);
        // sides = 2 violates min_sides (needs >= 3); radius is fine.
        let params = serde_json::json!({ "radius": 50.0, "sides": 2.0 });
        crate::document::controller::Controller::place_concept_instance(
            &mut st.tabs[st.active_tab].model,
            "regular_polygon",
            params,
            "g1",
        );
        let view = build_active_document_view(&st);
        let vios = view["selected_concept"]["violations"]
            .as_array()
            .expect("violations array");
        let ids: Vec<&str> = vios.iter().filter_map(|v| v["id"].as_str()).collect();
        assert_eq!(ids, vec!["min_sides"], "min_sides is flagged: {ids:?}");
        assert!(
            vios[0]["message"].as_str().unwrap_or("").contains("at least 3 sides"),
            "the violation carries its human-readable message"
        );
    }

    #[test]
    fn promote_action_detects_and_replaces_with_generated() {
        // CONCEPTS.md §10 — the full promote flow through dispatch_action: a
        // selected regular hexagon is detected by the regular_polygon fitter and
        // replaced with a Generated{sides:6, radius:50} at ~identity placement.
        use crate::geometry::element::{CommonProps, Element, PolygonElem};
        let mut st = make_state_with_layers(vec![("A".into(), Visibility::Preview, false)]);
        // A regular hexagon (radius 50), centred at origin, first vertex on +x —
        // exactly what regular_polygon{sides:6, radius:50} generates.
        let pts: Vec<(f64, f64)> = (0..6)
            .map(|i| {
                let a = (60.0 * i as f64).to_radians();
                (50.0 * a.cos(), 50.0 * a.sin())
            })
            .collect();
        let hex = Element::Polygon(PolygonElem {
            points: pts,
            fill: None,
            stroke: None,
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        });
        crate::document::controller::Controller::add_element(
            &mut st.tabs[st.active_tab].model,
            hex,
        );
        // Select the hexagon, then promote the selection.
        crate::document::controller::Controller::set_selection(
            &mut st.tabs[st.active_tab].model,
            vec![crate::document::document::ElementSelection::all(vec![0, 0])],
        );
        let empty = serde_json::Map::new();
        dispatch_action("promote_to_concept", &empty, &mut st);

        let el = st.tabs[st.active_tab]
            .model
            .document()
            .get_element(&vec![0, 0])
            .cloned()
            .expect("element at [0,0]");
        let Element::Live(crate::geometry::live::LiveVariant::Generated(g)) = el else {
            panic!("expected promote to produce a Generated, got {el:?}");
        };
        assert_eq!(g.concept_id, "regular_polygon");
        assert!(
            (g.params.get("sides").and_then(|v| v.as_f64()).unwrap() - 6.0).abs() < 1e-9,
            "recovered sides = 6"
        );
        assert!(
            (g.params.get("radius").and_then(|v| v.as_f64()).unwrap() - 50.0).abs() < 1e-9,
            "recovered radius = 50"
        );
        // Canonical placement (cx=cy=rotation≈0) ⇒ ~identity transform.
        let t = g.common.transform.expect("placement transform");
        assert!(
            t.e.abs() < 1e-6 && t.f.abs() < 1e-6,
            "canonical hexagon places at the origin: {t:?}"
        );
    }

    #[test]
    fn place_concept_instance_via_dispatch_creates_generated() {
        // CONCEPTS.md §6 — the full place flow through dispatch_action (the path
        // panel buttons take at renderer.rs:4736): select a concept, then
        // dispatch place_concept_instance, and a Generated is appended. This is a
        // regression guard for the dispatch-gate bug — the native concept verbs
        // were inside a `match` gated to symbol actions only, so they never fired.
        let mut st = make_state_with_layers(vec![("A".into(), Visibility::Preview, false)]);
        let mut sel_params = serde_json::Map::new();
        sel_params.insert("concept_id".to_string(), serde_json::json!("regular_polygon"));
        dispatch_action("concepts_panel_select", &sel_params, &mut st);
        let empty = serde_json::Map::new();
        dispatch_action("place_concept_instance", &empty, &mut st);

        let el = st.tabs[st.active_tab]
            .model
            .document()
            .get_element(&vec![0, 0])
            .cloned();
        assert!(
            matches!(
                el,
                Some(crate::geometry::element::Element::Live(
                    crate::geometry::live::LiveVariant::Generated(_)
                ))
            ),
            "place_concept_instance via dispatch_action should append a Generated, got {el:?}"
        );
    }

    // ─────────────────────────────────────────────────────────────
    // Artboard YAML-action integration (ARTBOARDS.md)
    // ─────────────────────────────────────────────────────────────
    //
    // These exercise the full pipeline: load workspace/actions.yaml
    // (compiled into workspace.json and include_str!'d at build),
    // dispatch each action, and assert the document-model side
    // effects landed.

    use crate::document::artboard::{Artboard, ArtboardFill};

    fn make_state_with_artboards(ids: &[&str]) -> AppState {
        use crate::workspace::app_state::TabState;
        let mut st = AppState::new();
        if st.tabs.is_empty() {
            st.tabs.push(TabState::new());
            st.active_tab = 0;
        }
        let mut doc = st.tabs[st.active_tab].model.document().clone();
        doc.artboards = ids
            .iter()
            .enumerate()
            .map(|(i, id)| {
                let mut a = Artboard::default_with_id((*id).to_string());
                a.name = format!("Artboard {}", i + 1);
                a
            })
            .collect();
        st.tabs[st.active_tab].model.set_document_unbracketed(doc);
        st
    }

    fn dispatch(st: &mut AppState, action: &str, params: serde_json::Map<String, serde_json::Value>) {
        dispatch_action(action, &params, st);
    }

    #[test]
    fn new_artboard_action_appends_one() {
        let mut st = make_state_with_artboards(&["aaa00001"]);
        dispatch(&mut st, "new_artboard", serde_json::Map::new());
        let doc = st.tabs[st.active_tab].model.document();
        assert_eq!(doc.artboards.len(), 2);
        // Default name pattern: the second artboard is "Artboard 2".
        assert_eq!(doc.artboards[1].name, "Artboard 2");
        assert_ne!(doc.artboards[1].id, doc.artboards[0].id);
    }

    #[test]
    fn new_artboard_sets_rearrange_dirty() {
        let mut st = make_state_with_artboards(&["aaa00001"]);
        assert!(!st.artboards_rearrange_dirty);
        dispatch(&mut st, "new_artboard", serde_json::Map::new());
        assert!(st.artboards_rearrange_dirty);
    }

    #[test]
    fn delete_artboards_action_removes_selection() {
        let mut st = make_state_with_artboards(&["aaa", "bbb", "ccc"]);
        st.artboards_panel_selection = vec!["bbb".to_string()];
        dispatch(&mut st, "delete_artboards", serde_json::Map::new());
        let doc = st.tabs[st.active_tab].model.document();
        let ids: Vec<&str> = doc.artboards.iter().map(|a| a.id.as_str()).collect();
        assert_eq!(ids, vec!["aaa", "ccc"]);
        // Action clears panel-selection after delete.
        assert!(st.artboards_panel_selection.is_empty());
    }

    #[test]
    fn duplicate_artboards_action_preserves_count_plus_one() {
        let mut st = make_state_with_artboards(&["aaa"]);
        st.artboards_panel_selection = vec!["aaa".to_string()];
        dispatch(&mut st, "duplicate_artboards", serde_json::Map::new());
        let doc = st.tabs[st.active_tab].model.document();
        assert_eq!(doc.artboards.len(), 2);
        assert_eq!(doc.artboards[0].id, "aaa");
        assert_ne!(doc.artboards[1].id, "aaa");
        assert_eq!(doc.artboards[1].name, "Artboard 2");
        assert_eq!(doc.artboards[1].x, 20.0);
        assert_eq!(doc.artboards[1].y, 20.0);
    }

    #[test]
    fn move_artboard_up_action_applies_swap_rule() {
        let mut st = make_state_with_artboards(&["aaa", "bbb", "ccc"]);
        st.artboards_panel_selection = vec!["bbb".to_string()];
        dispatch(&mut st, "move_artboard_up", serde_json::Map::new());
        let ids: Vec<&str> = st
            .tabs[st.active_tab]
            .model
            .document()
            .artboards
            .iter()
            .map(|a| a.id.as_str())
            .collect();
        assert_eq!(ids, vec!["bbb", "aaa", "ccc"]);
    }

    #[test]
    fn move_artboard_up_discontiguous_1_3_5() {
        // ART-103 canonical example: selection {1, 3, 5} → [1, 3, 2, 5, 4].
        let mut st = make_state_with_artboards(&["a1", "a2", "a3", "a4", "a5"]);
        st.artboards_panel_selection = vec![
            "a1".to_string(),
            "a3".to_string(),
            "a5".to_string(),
        ];
        dispatch(&mut st, "move_artboard_up", serde_json::Map::new());
        let ids: Vec<&str> = st
            .tabs[st.active_tab]
            .model
            .document()
            .artboards
            .iter()
            .map(|a| a.id.as_str())
            .collect();
        assert_eq!(ids, vec!["a1", "a3", "a2", "a5", "a4"]);
    }

    #[test]
    fn rename_artboard_action_sets_renaming_field() {
        let mut st = make_state_with_artboards(&["aaa"]);
        st.artboards_panel_selection = vec!["aaa".to_string()];
        let mut params = serde_json::Map::new();
        params.insert(
            "artboard_id".to_string(),
            serde_json::json!("aaa"),
        );
        dispatch(&mut st, "rename_artboard", params);
        assert_eq!(st.artboards_renaming, Some("aaa".to_string()));
    }

    #[test]
    fn confirm_artboard_rename_writes_name() {
        let mut st = make_state_with_artboards(&["aaa"]);
        st.artboards_renaming = Some("aaa".to_string());
        let mut params = serde_json::Map::new();
        params.insert("artboard_id".to_string(), serde_json::json!("aaa"));
        params.insert("new_name".to_string(), serde_json::json!("Cover"));
        dispatch(&mut st, "confirm_artboard_rename", params);
        let doc = st.tabs[st.active_tab].model.document();
        assert_eq!(doc.artboards[0].name, "Cover");
        assert_eq!(st.artboards_renaming, None);
    }

    #[test]
    fn reset_artboards_panel_restores_reference_point() {
        let mut st = make_state_with_artboards(&["aaa"]);
        st.artboards_panel_selection = vec!["aaa".to_string()];
        st.artboards_reference_point = "top_left".to_string();
        dispatch(&mut st, "reset_artboards_panel", serde_json::Map::new());
        assert_eq!(st.artboards_reference_point, "center");
        assert!(st.artboards_panel_selection.is_empty());
    }

    #[test]
    fn move_artboards_up_helper_canonical_example() {
        // Unit-test the pure helper too.
        let mut abs = vec![
            Artboard::default_with_id("a1".into()),
            Artboard::default_with_id("a2".into()),
            Artboard::default_with_id("a3".into()),
            Artboard::default_with_id("a4".into()),
            Artboard::default_with_id("a5".into()),
        ];
        let selected = vec!["a1".into(), "a3".into(), "a5".into()];
        let changed = crate::document::op_apply::move_artboards_up_in_place(&mut abs, &selected);
        assert!(changed);
        let ids: Vec<&str> = abs.iter().map(|a| a.id.as_str()).collect();
        assert_eq!(ids, vec!["a1", "a3", "a2", "a5", "a4"]);
    }

    /// The create-path field application (formerly `apply_artboard_override`,
    /// moved to op_apply.rs as `apply_artboard_field_in_place`, OP_LOG.md §9
    /// Phase P3). Exercised here through the public `apply_create_artboard` Model
    /// helper: the RESOLVED `fields` literals coerce onto the appended artboard.
    #[test]
    fn apply_create_artboard_applies_all_fields() {
        let doc = crate::document::document::Document::default();
        let mut model = crate::document::model::Model::new(doc, None);
        let fields = serde_json::json!({
            "name": "Cover",
            "x": 100.0,
            "y": 200.0,
            "width": 400.0,
            "fill": "#ff0000",
            "show_center_mark": true,
        });
        crate::document::op_apply::apply_create_artboard(&mut model, "aaa", &fields);
        let ab = model.document().artboards.iter()
            .find(|a| a.id == "aaa").expect("the created artboard");
        assert_eq!(ab.name, "Cover");
        assert_eq!(ab.x, 100.0);
        assert_eq!(ab.y, 200.0);
        assert_eq!(ab.width, 400.0);
        assert_eq!(ab.fill, ArtboardFill::Color("#ff0000".into()));
        assert!(ab.show_center_mark);
    }

    // ─────────────────────────────────────────────────────────────
    // Artboard Options Dialogue — expression-evaluator integration
    // (ARTBOARDS.md §Artboard Options Dialogue)
    // ─────────────────────────────────────────────────────────────
    //
    // The Dioxus open_dialog path needs a Signal and can't be unit-
    // tested here. These tests exercise the two pieces that matter
    // independently:
    //   1. anchor_offset_x / anchor_offset_y builtins produce the
    //      right numbers for all 9 anchor positions.
    //   2. DialogState computed-property get/set with an outer
    //      scope round-trips through the reference-point transform
    //      without mutating the stored top-left.

    #[test]
    fn anchor_offset_x_center_half_width() {
        let ctx = serde_json::json!({});
        let v = super::super::expr::eval("anchor_offset_x('center', 612)", &ctx);
        assert_eq!(v, super::super::expr_types::Value::Number(306.0));
    }

    #[test]
    fn anchor_offset_x_top_left_zero() {
        let ctx = serde_json::json!({});
        let v = super::super::expr::eval("anchor_offset_x('top_left', 612)", &ctx);
        assert_eq!(v, super::super::expr_types::Value::Number(0.0));
    }

    #[test]
    fn anchor_offset_x_bottom_right_full_size() {
        let ctx = serde_json::json!({});
        let v = super::super::expr::eval("anchor_offset_x('bottom_right', 612)", &ctx);
        assert_eq!(v, super::super::expr_types::Value::Number(612.0));
    }

    #[test]
    fn anchor_offset_y_center_half_height() {
        let ctx = serde_json::json!({});
        let v = super::super::expr::eval("anchor_offset_y('center', 792)", &ctx);
        assert_eq!(v, super::super::expr_types::Value::Number(396.0));
    }

    #[test]
    fn dialog_computed_prop_x_rp_center() {
        // ART-199 in ARTBOARDS_TESTS.md: with reference_point=center
        // on a default 612×792 artboard at origin, the Dialogue's
        // X field reads 306 (= 0 + width/2).
        use super::super::dialog_view::DialogState;
        use std::collections::HashMap;

        let mut state = HashMap::new();
        state.insert("x_stored".to_string(), serde_json::json!(0));
        state.insert("y_stored".to_string(), serde_json::json!(0));
        state.insert("width".to_string(), serde_json::json!(612));
        state.insert("height".to_string(), serde_json::json!(792));

        let mut props = HashMap::new();
        props.insert(
            "x_rp".to_string(),
            serde_json::json!({
                "get": "x_stored + anchor_offset_x(panel.reference_point, width)",
            }),
        );
        props.insert(
            "y_rp".to_string(),
            serde_json::json!({
                "get": "y_stored + anchor_offset_y(panel.reference_point, height)",
            }),
        );

        let ds = DialogState {
            id: "test".to_string(),
            state,
            params: HashMap::new(),
            anchor: None,
            props,
        };

        let outer = serde_json::json!({
            "panel": { "reference_point": "center" },
        });

        let x_rp = ds.get_value_with_outer("x_rp", Some(&outer));
        let y_rp = ds.get_value_with_outer("y_rp", Some(&outer));
        // value_to_json normalizes whole f64 to i64 — compare ints.
        assert_eq!(x_rp, serde_json::json!(306));
        assert_eq!(y_rp, serde_json::json!(396));
    }

    #[test]
    fn dialog_computed_prop_x_rp_top_left_shows_raw() {
        use super::super::dialog_view::DialogState;
        use std::collections::HashMap;

        let mut state = HashMap::new();
        state.insert("x_stored".to_string(), serde_json::json!(100));
        state.insert("y_stored".to_string(), serde_json::json!(200));
        state.insert("width".to_string(), serde_json::json!(612));
        state.insert("height".to_string(), serde_json::json!(792));

        let mut props = HashMap::new();
        props.insert(
            "x_rp".to_string(),
            serde_json::json!({
                "get": "x_stored + anchor_offset_x(panel.reference_point, width)",
            }),
        );

        let ds = DialogState {
            id: "test".to_string(),
            state,
            params: HashMap::new(),
            anchor: None,
            props,
        };

        let outer = serde_json::json!({
            "panel": { "reference_point": "top_left" },
        });
        let x_rp = ds.get_value_with_outer("x_rp", Some(&outer));
        // top_left anchor: displayed X equals stored x (100).
        assert_eq!(x_rp, serde_json::json!(100));
    }

    #[test]
    fn dialog_computed_prop_set_x_rp_writes_top_left() {
        use super::super::dialog_view::DialogState;
        use std::collections::HashMap;

        let mut state = HashMap::new();
        state.insert("x_stored".to_string(), serde_json::json!(0));
        state.insert("width".to_string(), serde_json::json!(612));

        let mut props = HashMap::new();
        props.insert(
            "x_rp".to_string(),
            serde_json::json!({
                "get": "x_stored + anchor_offset_x(panel.reference_point, width)",
                "set": "fun new -> x_stored <- new - anchor_offset_x(panel.reference_point, width)",
            }),
        );

        let mut ds = DialogState {
            id: "test".to_string(),
            state,
            params: HashMap::new(),
            anchor: None,
            props,
        };

        let outer = serde_json::json!({
            "panel": { "reference_point": "center" },
        });
        // User types X=406 with center anchor on a 612-wide artboard.
        // Stored top-left should become 406 - 306 = 100.
        ds.set_value_with_outer(
            "x_rp",
            serde_json::json!(406.0),
            Some(&outer),
        );
        assert_eq!(
            ds.state.get("x_stored"),
            Some(&serde_json::json!(100))
        );
    }

    #[test]
    fn build_dialog_outer_scope_has_panel_and_active_document() {
        let mut st = make_state_with_artboards(&["aaa00001"]);
        st.artboards_reference_point = "top_left".to_string();
        st.artboards_panel_selection = vec!["aaa00001".to_string()];
        let outer = super::build_dialog_outer_scope(&st);
        assert_eq!(
            outer["panel"]["reference_point"],
            serde_json::json!("top_left")
        );
        let ids = outer["active_document"]["artboards_panel_selection_ids"]
            .as_array()
            .unwrap();
        assert_eq!(ids.len(), 1);
        assert_eq!(ids[0], serde_json::json!("aaa00001"));
        assert_eq!(
            outer["active_document"]["artboards_count"],
            serde_json::json!(1)
        );
    }

    // ── set_opacity_field (Phase 1.5 wiring) ─────────────────

    #[test]
    fn set_opacity_field_blend_mode_accepts_snake_case_id() {
        use crate::geometry::element::BlendMode;
        let mut op = crate::workspace::app_state::OpacityPanelState::default();
        super::set_opacity_field(&mut op, "blend_mode", &serde_json::json!("multiply"));
        assert_eq!(op.blend_mode, BlendMode::Multiply);
        super::set_opacity_field(&mut op, "blend_mode", &serde_json::json!("color_burn"));
        assert_eq!(op.blend_mode, BlendMode::ColorBurn);
        super::set_opacity_field(&mut op, "blend_mode", &serde_json::json!("luminosity"));
        assert_eq!(op.blend_mode, BlendMode::Luminosity);
    }

    #[test]
    fn set_opacity_field_blend_mode_ignores_unknown_value() {
        use crate::geometry::element::BlendMode;
        let mut op = crate::workspace::app_state::OpacityPanelState::default();
        op.blend_mode = BlendMode::Multiply;
        super::set_opacity_field(&mut op, "blend_mode", &serde_json::json!("not_a_mode"));
        // Ignored — field keeps its prior value.
        assert_eq!(op.blend_mode, BlendMode::Multiply);
    }

    #[test]
    fn set_opacity_field_opacity_clamps_to_0_100() {
        let mut op = crate::workspace::app_state::OpacityPanelState::default();
        super::set_opacity_field(&mut op, "opacity", &serde_json::json!(42.0));
        assert_eq!(op.opacity, 42.0);
        super::set_opacity_field(&mut op, "opacity", &serde_json::json!(150.0));
        assert_eq!(op.opacity, 100.0);
        super::set_opacity_field(&mut op, "opacity", &serde_json::json!(-5.0));
        assert_eq!(op.opacity, 0.0);
    }

    #[test]
    fn set_opacity_field_bool_toggles_flow_through() {
        let mut op = crate::workspace::app_state::OpacityPanelState::default();
        super::set_opacity_field(&mut op, "thumbnails_hidden", &serde_json::json!(true));
        assert!(op.thumbnails_hidden);
        super::set_opacity_field(&mut op, "options_shown", &serde_json::json!(true));
        assert!(op.options_shown);
        super::set_opacity_field(&mut op, "new_masks_clipping", &serde_json::json!(false));
        assert!(!op.new_masks_clipping);
        super::set_opacity_field(&mut op, "new_masks_inverted", &serde_json::json!(true));
        assert!(op.new_masks_inverted);
    }

    #[test]
    fn set_opacity_field_unknown_key_is_noop() {
        use crate::geometry::element::BlendMode;
        let mut op = crate::workspace::app_state::OpacityPanelState::default();
        super::set_opacity_field(&mut op, "nonexistent", &serde_json::json!("anything"));
        // Defaults are preserved.
        assert_eq!(op.blend_mode, BlendMode::Normal);
        assert_eq!(op.opacity, 100.0);
        assert!(!op.thumbnails_hidden);
        assert!(op.new_masks_clipping);
    }

    // ---- Toolbar dblclick → active tool's options (3-path lookup) ----

    #[test]
    fn tool_options_dest_panel_for_magic_wand() {
        // magic_wand declares tool_options_panel: magic_wand.
        assert_eq!(
            super::tool_options_dest_for_yaml_id("magic_wand"),
            Some(super::ToolOptionsDest::Panel("magic_wand".to_string()))
        );
    }

    #[test]
    fn tool_options_dest_action_for_hand_and_zoom() {
        assert_eq!(
            super::tool_options_dest_for_yaml_id("hand"),
            Some(super::ToolOptionsDest::Action("fit_active_artboard".to_string()))
        );
        assert_eq!(
            super::tool_options_dest_for_yaml_id("zoom"),
            Some(super::ToolOptionsDest::Action("zoom_to_actual_size".to_string()))
        );
    }

    #[test]
    fn tool_options_dest_dialog_for_dialog_tools() {
        // Every tool the prompt lists as a tool_options_dialog tool.
        for (yaml_id, dlg) in [
            ("paintbrush", "paintbrush_tool_options"),
            ("blob_brush", "blob_brush_tool_options"),
            ("scale", "scale_options"),
            ("rotate", "rotate_options"),
            ("shear", "shear_options"),
            ("eyedropper", "eyedropper_tool_options"),
        ] {
            assert_eq!(
                super::tool_options_dest_for_yaml_id(yaml_id),
                Some(super::ToolOptionsDest::Dialog(dlg.to_string())),
                "tool {yaml_id} should resolve to dialog {dlg}"
            );
        }
    }

    #[test]
    fn tool_options_dest_none_for_tool_without_options() {
        // Selection declares no tool_options_* → dblclick is a no-op.
        assert_eq!(super::tool_options_dest_for_yaml_id("selection"), None);
        // Unknown id → None as well.
        assert_eq!(super::tool_options_dest_for_yaml_id("not_a_tool"), None);
    }

    #[test]
    fn tool_options_dest_lookup_is_bundle_driven() {
        // The lookup is built from the bundle, not a hardcoded table:
        // iterate every tool the bundle declares and confirm the
        // resolved destination matches that entry's fields in the
        // documented priority order (panel > action > dialog).
        let ws = super::super::workspace::Workspace::load().unwrap();
        let tools = ws
            .data()
            .get("tools")
            .and_then(|t| t.as_object())
            .expect("bundle has a tools map");
        // The bundle must actually declare some options-bearing tools,
        // otherwise this test would vacuously pass.
        let mut saw_some = false;
        for (yaml_id, tool) in tools {
            let dest = super::tool_options_dest_for_yaml_id(yaml_id);
            let panel = tool.get("tool_options_panel").and_then(|v| v.as_str());
            let action = tool.get("tool_options_action").and_then(|v| v.as_str());
            let dialog = tool.get("tool_options_dialog").and_then(|v| v.as_str());
            let expected = if let Some(p) = panel {
                Some(super::ToolOptionsDest::Panel(p.to_string()))
            } else if let Some(a) = action {
                Some(super::ToolOptionsDest::Action(a.to_string()))
            } else if let Some(d) = dialog {
                Some(super::ToolOptionsDest::Dialog(d.to_string()))
            } else {
                None
            };
            if expected.is_some() {
                saw_some = true;
            }
            assert_eq!(dest, expected, "tool {yaml_id}: lookup must match bundle");
        }
        assert!(saw_some, "bundle should declare at least one options-bearing tool");
    }

    #[test]
    fn panel_id_to_kind_maps_magic_wand() {
        assert_eq!(super::panel_id_to_kind("magic_wand"), Some(PanelKind::MagicWand));
        assert_eq!(super::panel_id_to_kind("unknown_panel"), None);
    }

    #[test]
    fn is_toolbar_tool_slot_true_only_for_select_tool_buttons() {
        // Toolbar slot: behavior has action: select_tool.
        let slot = serde_json::json!({
            "type": "icon_button",
            "behavior": [{ "event": "click", "action": "select_tool",
                           "params": { "tool": "selection" } }]
        });
        assert!(super::is_toolbar_tool_slot(&slot));

        // Long-press flyout item: sets active_tool + close_dialog, but
        // NO select_tool action → must NOT get the dblclick.
        let flyout = serde_json::json!({
            "type": "icon_button",
            "behavior": [{ "event": "click", "effects": [
                { "set": { "active_tool": "paintbrush" } },
                { "close_dialog": null }
            ] }]
        });
        assert!(!super::is_toolbar_tool_slot(&flyout));

        // Panel op_* button: a plain action, not select_tool.
        let op_btn = serde_json::json!({
            "type": "icon_button",
            "behavior": [{ "event": "click", "action": "op_make_mask" }]
        });
        assert!(!super::is_toolbar_tool_slot(&op_btn));

        // No behavior at all.
        let bare = serde_json::json!({ "type": "icon_button" });
        assert!(!super::is_toolbar_tool_slot(&bare));
    }
}


