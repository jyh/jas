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
        "icon" => render_icon(el, ctx),
        "slider" => render_slider(el, ctx, rctx),
        "number_input" => render_number_input(el, ctx, rctx),
        "text_input" => render_text_input(el, ctx, rctx),
        "length_input" => render_length_input(el, ctx, rctx),
        "select" => render_select(el, ctx, rctx),
        "icon_select" => render_icon_select(el, ctx, rctx),
        "toggle" | "checkbox" => render_toggle(el, ctx, rctx),
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
    // Phase 4: open_layer_options is now pure YAML. It resolves the
    // target layer via element_at(path_from_id(param.layer_id)) and
    // packs its current state as open_dialog params.
    // Fall through to YAML actions catalog
    let ws = crate::interpreter::workspace::Workspace::load();
    if let Some(ws) = ws {
        if let Some(action_def) = ws.actions().get(action) {
            if let Some(serde_json::Value::Array(effects)) = action_def.get("effects") {
                let eval_ctx = build_appstate_ctx(params, st);
                return run_yaml_effects(effects, &eval_ctx, st);
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
                // Propagate to canvas selection so a swatch / hex /
                // color-bar click via the YAML set_active_color
                // action updates the selected element's fill — same
                // path AppState::set_active_color uses for the
                // Color-panel slider commits.
                if !tab.model.document().selection.is_empty() {
                    tab.model.snapshot();
                    crate::document::controller::Controller::set_selection_fill(
                        &mut tab.model, new_fill);
                }
            }
        }
        "stroke_color" => {
            if val.is_null() {
                st.app_default_stroke = None;
                if let Some(tab) = st.tabs.get_mut(st.active_tab) {
                    tab.model.default_stroke = None;
                    if !tab.model.document().selection.is_empty() {
                        tab.model.snapshot();
                        crate::document::controller::Controller::set_selection_stroke(
                            &mut tab.model, None);
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
                        tab.model.snapshot();
                        crate::document::controller::Controller::set_selection_stroke(
                            &mut tab.model, tab_stroke);
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
            if let Some(n) = val.as_f64() { st.boolean_panel.precision = n; }
        }
        "boolean_remove_redundant_points" => {
            if let Some(b) = val.as_bool() { st.boolean_panel.remove_redundant_points = b; }
        }
        "boolean_divide_remove_unpainted" => {
            if let Some(b) = val.as_bool() { st.boolean_panel.divide_remove_unpainted = b; }
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
    use crate::tools::tool::ToolKind;
    let tool_name = match st.active_tool {
        ToolKind::Selection => "selection",
        ToolKind::PartialSelection => "partial_selection",
        ToolKind::InteriorSelection => "interior_selection",
        ToolKind::MagicWand => "magic_wand",
        ToolKind::Pen => "pen",
        ToolKind::AddAnchorPoint => "add_anchor",
        ToolKind::DeleteAnchorPoint => "delete_anchor",
        ToolKind::AnchorPoint => "anchor_point",
        ToolKind::Pencil => "pencil",
        ToolKind::Paintbrush => "paintbrush",
        ToolKind::BlobBrush => "blob_brush",
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
        ToolKind::Scale => "scale",
        ToolKind::Rotate => "rotate",
        ToolKind::Shear => "shear",
        ToolKind::Hand => "hand",
        ToolKind::Zoom => "zoom",
        ToolKind::Artboard => "artboard",
        ToolKind::Eyedropper => "eyedropper",
    };
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
fn build_active_document_view(
    st: &crate::workspace::app_state::AppState,
) -> serde_json::Value {
    use crate::geometry::element::{Element, Visibility};
    use std::collections::HashSet;
    let Some(tab) = st.tabs.get(st.active_tab) else {
        return serde_json::json!({
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
                "name": le.name,
                "common": {
                    "visibility": vis,
                    "locked": le.common.locked,
                    "opacity": le.common.opacity,
                },
                "path": path_json.clone(),
            }));
            top_level_layer_paths.push(path_json);
            layer_names.insert(le.name.clone());
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
    serde_json::json!({
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
    })
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
    let mut scope = ctx_in.clone();
    let mut deferred = Vec::new();
    for eff in effects {
        deferred.extend(run_yaml_effect(eff, &mut scope, st));
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
                tab.model.snapshot();
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
            tab.model.snapshot();
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

    // doc.create_artboard: { [field]: expr, ... }
    // Appends a new artboard. Optional field overrides (x, y, width,
    // height, fill, show_*, video_ruler_pixel_aspect_ratio, name)
    // are evaluated and applied on top of the default.
    if let Some(spec) = eff.get("doc.create_artboard").and_then(|v| v.as_object()) {
        use crate::document::artboard::{
            generate_artboard_id, next_artboard_name, Artboard,
        };
        let Some(tab) = st.tabs.get_mut(st.active_tab) else { return deferred; };
        let mut new_doc = tab.model.document().clone();
        // Collision-retry id mint.
        let existing_ids: std::collections::HashSet<String> =
            new_doc.artboards.iter().map(|a| a.id.clone()).collect();
        let mut id = String::new();
        for _ in 0..100 {
            let c = generate_artboard_id(None);
            if !existing_ids.contains(&c) { id = c; break; }
        }
        if id.is_empty() { return deferred; }
        let default_name = next_artboard_name(&new_doc.artboards);
        let mut ab = Artboard::default_with_id(id.clone());
        ab.name = default_name;
        for (k, v) in spec {
            let val = if let Some(s) = v.as_str() {
                super::expr::eval(s, &*eval_ctx)
            } else {
                super::expr_types::Value::from_json(v)
            };
            apply_artboard_override(&mut ab, k, &val);
        }
        let new_id = ab.id.clone();
        new_doc.artboards.push(ab);
        tab.model.set_document(new_doc);
        if let Some(as_n) = as_name {
            if let Some(map) = eval_ctx.as_object_mut() {
                map.insert(as_n, serde_json::json!(new_id));
            }
        }
        return deferred;
    }

    // doc.delete_artboard_by_id: id_expr
    if let Some(id_expr_v) = eff.get("doc.delete_artboard_by_id") {
        let id_expr = id_expr_v.as_str().unwrap_or("");
        let val = super::expr::eval(id_expr, &*eval_ctx);
        let target = match val {
            super::expr_types::Value::Str(s) => s,
            _ => return deferred,
        };
        let Some(tab) = st.tabs.get_mut(st.active_tab) else { return deferred; };
        let mut new_doc = tab.model.document().clone();
        let before = new_doc.artboards.len();
        new_doc.artboards.retain(|a| a.id != target);
        if new_doc.artboards.len() < before {
            tab.model.set_document(new_doc);
        }
        return deferred;
    }

    // doc.duplicate_artboard: id_expr | { id, offset_x?, offset_y? }
    if let Some(eff_val) = eff.get("doc.duplicate_artboard") {
        use crate::document::artboard::{
            generate_artboard_id, next_artboard_name, Artboard,
        };
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
        let mut new_doc = tab.model.document().clone();
        let Some(source) = new_doc.artboards.iter().find(|a| a.id == target).cloned() else {
            return deferred;
        };
        let existing_ids: std::collections::HashSet<String> =
            new_doc.artboards.iter().map(|a| a.id.clone()).collect();
        let mut id = String::new();
        for _ in 0..100 {
            let c = generate_artboard_id(None);
            if !existing_ids.contains(&c) { id = c; break; }
        }
        if id.is_empty() { return deferred; }
        let mut dup = Artboard { id, ..source };
        dup.name = next_artboard_name(&new_doc.artboards);
        dup.x += ox;
        dup.y += oy;
        new_doc.artboards.push(dup);
        tab.model.set_document(new_doc);
        return deferred;
    }

    // doc.set_artboard_field: { id, field, value }
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
        let Some(tab) = st.tabs.get_mut(st.active_tab) else { return deferred; };
        let mut new_doc = tab.model.document().clone();
        if let Some(ab) = new_doc.artboards.iter_mut().find(|a| a.id == target) {
            apply_artboard_override(ab, &field, &value_val);
            tab.model.set_document(new_doc);
        }
        return deferred;
    }

    // doc.set_artboard_options_field: { field, value }
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
        let Some(tab) = st.tabs.get_mut(st.active_tab) else { return deferred; };
        let mut new_doc = tab.model.document().clone();
        let flag = match value_val {
            super::expr_types::Value::Bool(b) => b,
            _ => return deferred,
        };
        match field.as_str() {
            "fade_region_outside_artboard" => {
                new_doc.artboard_options.fade_region_outside_artboard = flag;
            }
            "update_while_dragging" => {
                new_doc.artboard_options.update_while_dragging = flag;
            }
            _ => return deferred,
        }
        tab.model.set_document(new_doc);
        return deferred;
    }

    // doc.move_artboards_up: ids_expr
    if let Some(ids_expr_v) = eff.get("doc.move_artboards_up") {
        let ids_expr = ids_expr_v.as_str().unwrap_or("");
        let val = super::expr::eval(ids_expr, &*eval_ctx);
        let ids = extract_id_list(&val);
        let Some(tab) = st.tabs.get_mut(st.active_tab) else { return deferred; };
        let mut new_doc = tab.model.document().clone();
        if move_artboards_up(&mut new_doc.artboards, &ids) {
            tab.model.set_document(new_doc);
        }
        return deferred;
    }

    // doc.move_artboards_down: ids_expr
    if let Some(ids_expr_v) = eff.get("doc.move_artboards_down") {
        let ids_expr = ids_expr_v.as_str().unwrap_or("");
        let val = super::expr::eval(ids_expr, &*eval_ctx);
        let ids = extract_id_list(&val);
        let Some(tab) = st.tabs.get_mut(st.active_tab) else { return deferred; };
        let mut new_doc = tab.model.document().clone();
        if move_artboards_down(&mut new_doc.artboards, &ids) {
            tab.model.set_document(new_doc);
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
                name,
                children: Vec::new(),
                common: crate::geometry::element::CommonProps::default(),
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

    // doc.delete_at: path_expr — PHASE3 §5.5
    // Deletes the element at path; if `as:` is set, binds the deleted
    // element as JSON in ctx for subsequent effects.
    if let Some(path_expr_v) = eff.get("doc.delete_at") {
        let path_expr = path_expr_v.as_str().unwrap_or("");
        let path_val = super::expr::eval(path_expr, &*eval_ctx);
        if let super::expr_types::Value::Path(indices) = path_val {
            let removed = delete_element_at(&indices, st);
            if let Some(name) = as_name {
                if let Some(map) = eval_ctx.as_object_mut() {
                    let json = removed
                        .and_then(|e| serde_json::to_value(&e).ok())
                        .unwrap_or(serde_json::Value::Null);
                    map.insert(name, json);
                }
            }
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

    // doc.insert_after: { path, element } — PHASE3 §5.5
    if let Some(spec) = eff.get("doc.insert_after").and_then(|v| v.as_object()) {
        let path_expr = spec.get("path").and_then(|v| v.as_str()).unwrap_or("");
        let path_val = super::expr::eval(path_expr, &*eval_ctx);
        let indices = match path_val {
            super::expr_types::Value::Path(idx) => idx,
            _ => return deferred,
        };
        let elem = resolve_element_arg(spec.get("element"), &*eval_ctx);
        if let Some(e) = elem {
            insert_element_after(&indices, e, st);
        }
        return deferred;
    }

    // doc.unpack_group_at: path_expr — PHASE3 sub-tollgate 3
    // Replace a Group at path with its children in place. Non-Group
    // targets no-op.
    if let Some(path_expr_v) = eff.get("doc.unpack_group_at") {
        use crate::geometry::element::Element;
        let path_expr = path_expr_v.as_str().unwrap_or("");
        let path_val = super::expr::eval(path_expr, &*eval_ctx);
        let indices = match path_val {
            super::expr_types::Value::Path(p) => p,
            _ => return deferred,
        };
        // Check the target is a Group
        let group_children: Option<Vec<Element>> = {
            let Some(tab) = st.tabs.get(st.active_tab) else { return deferred; };
            match tab.model.document().get_element(&indices) {
                Some(Element::Group(g)) => {
                    Some(g.children.iter().map(|rc| (**rc).clone()).collect())
                }
                _ => None,
            }
        };
        let Some(children) = group_children else { return deferred; };
        {
            let Some(tab) = st.tabs.get_mut(st.active_tab) else { return deferred; };
            let mut new_doc = tab.model.document().clone();
            new_doc = new_doc.delete_element(&indices);
            // Insert children at the vacated position, ascending indices
            let mut insert_path = indices.clone();
            for child in children {
                new_doc = new_doc.insert_element_at(&insert_path, child);
                let last = insert_path.len() - 1;
                insert_path[last] += 1;
            }
            tab.model.set_document(new_doc);
        }
        return deferred;
    }

    // doc.wrap_in_layer: { paths, name } — PHASE3 sub-tollgate 3
    // Parallel to wrap_in_group but always appends a new top-level Layer
    // at the end of the document's layers array.
    if let Some(spec) = eff.get("doc.wrap_in_layer").and_then(|v| v.as_object()) {
        let paths_expr = spec.get("paths").and_then(|v| v.as_str()).unwrap_or("[]");
        let paths_val = super::expr::eval(paths_expr, &*eval_ctx);
        let raw_paths = match paths_val {
            super::expr_types::Value::List(items) => items,
            _ => return deferred,
        };
        let mut normalized: Vec<Vec<usize>> = Vec::new();
        for item in &raw_paths {
            if let Some(obj) = item.as_object() {
                if let Some(arr) = obj.get("__path__").and_then(|v| v.as_array()) {
                    let idx: Option<Vec<usize>> = arr.iter()
                        .map(|n| n.as_u64().map(|u| u as usize))
                        .collect();
                    if let Some(idx) = idx {
                        normalized.push(idx);
                    }
                }
            }
        }
        if normalized.is_empty() {
            return deferred;
        }
        normalized.sort();
        // Name expression
        let name_expr = spec.get("name").and_then(|v| v.as_str()).unwrap_or("'Layer'");
        let name_val = super::expr::eval(name_expr, &*eval_ctx);
        let name = match name_val {
            super::expr_types::Value::Str(s) => s,
            _ => "Layer".to_string(),
        };
        use crate::geometry::element::{Element, LayerElem, CommonProps};
        use std::rc::Rc;
        let mut children: Vec<Rc<Element>> = Vec::new();
        if let Some(tab) = st.tabs.get(st.active_tab) {
            for p in &normalized {
                if let Some(elem) = tab.model.document().get_element(p) {
                    children.push(Rc::new(elem.clone()));
                }
            }
        }
        if children.is_empty() {
            return deferred;
        }
        {
            let Some(tab) = st.tabs.get_mut(st.active_tab) else { return deferred; };
            let mut new_doc = tab.model.document().clone();
            for p in normalized.iter().rev() {
                new_doc = new_doc.delete_element(p);
            }
            let new_layer = Element::Layer(LayerElem {
                name,
                children,
                common: CommonProps::default(),
                isolated_blending: false,
                knockout_group: false,
            });
            new_doc.layers.push(new_layer);
            tab.model.set_document(new_doc);
        }
        return deferred;
    }

    // doc.wrap_in_group: { paths } — PHASE3 sub-tollgate 3
    // Wraps elements at the given paths in a new Group. Sorted in
    // document order; deleted in reverse order; group inserted at the
    // topmost-source position under the shared parent.
    if let Some(spec) = eff.get("doc.wrap_in_group").and_then(|v| v.as_object()) {
        let paths_expr = spec.get("paths").and_then(|v| v.as_str()).unwrap_or("[]");
        let paths_val = super::expr::eval(paths_expr, &*eval_ctx);
        let raw_paths = match paths_val {
            super::expr_types::Value::List(items) => items,
            _ => return deferred,
        };
        // Normalize: each item should be a __path__ marker JSON object
        // (Value.PATH serialized). Decode to Vec<usize>.
        let mut normalized: Vec<Vec<usize>> = Vec::new();
        for item in &raw_paths {
            if let Some(obj) = item.as_object() {
                if let Some(arr) = obj.get("__path__").and_then(|v| v.as_array()) {
                    let idx: Option<Vec<usize>> = arr.iter()
                        .map(|n| n.as_u64().map(|u| u as usize))
                        .collect();
                    if let Some(idx) = idx {
                        normalized.push(idx);
                    }
                }
            }
        }
        if normalized.is_empty() {
            return deferred;
        }
        normalized.sort();
        // Split the topmost path into parent + final index
        let first = &normalized[0];
        if first.is_empty() { return deferred; }
        let insert_parent: Vec<usize> = first[..first.len() - 1].to_vec();
        let insert_index = first[first.len() - 1];
        // Collect clones in document order
        use crate::geometry::element::{Element, GroupElem, CommonProps};
        use std::rc::Rc;
        let mut children: Vec<Rc<Element>> = Vec::new();
        if let Some(tab) = st.tabs.get(st.active_tab) {
            for p in &normalized {
                if let Some(elem) = tab.model.document().get_element(p) {
                    children.push(Rc::new(elem.clone()));
                }
            }
        }
        if children.is_empty() {
            return deferred;
        }
        // Delete in reverse order
        {
            let Some(tab) = st.tabs.get_mut(st.active_tab) else { return deferred; };
            let mut new_doc = tab.model.document().clone();
            for p in normalized.iter().rev() {
                new_doc = new_doc.delete_element(p);
            }
            tab.model.set_document(new_doc);
        }
        // Build and insert group
        let group = Element::Group(GroupElem {
            children,
            common: CommonProps::default(),
            isolated_blending: false,
            knockout_group: false,
        });
        insert_element_at(&insert_parent, insert_index, group, st);
        return deferred;
    }

    // doc.insert_at: { parent_path, index, element } — PHASE3 §5.5
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
            insert_element_at(&parent_indices, idx, e, st);
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

fn apply_artboard_override(
    ab: &mut crate::document::artboard::Artboard,
    field: &str,
    val: &super::expr_types::Value,
) {
    use super::expr_types::Value;
    use crate::document::artboard::ArtboardFill;
    match field {
        "name" => if let Value::Str(s) = val { ab.name = s.clone(); }
        "x" => if let Value::Number(n) = val { ab.x = *n; }
        "y" => if let Value::Number(n) = val { ab.y = *n; }
        "width" => if let Value::Number(n) = val { ab.width = *n; }
        "height" => if let Value::Number(n) = val { ab.height = *n; }
        "fill" => match val {
            Value::Str(s) => ab.fill = ArtboardFill::from_canonical(s),
            Value::Color(s) => ab.fill = ArtboardFill::from_canonical(s),
            _ => {}
        },
        "show_center_mark" => if let Value::Bool(b) = val { ab.show_center_mark = *b; }
        "show_cross_hairs" => if let Value::Bool(b) = val { ab.show_cross_hairs = *b; }
        "show_video_safe_areas" => if let Value::Bool(b) = val { ab.show_video_safe_areas = *b; }
        "video_ruler_pixel_aspect_ratio" => {
            if let Value::Number(n) = val { ab.video_ruler_pixel_aspect_ratio = *n; }
        }
        _ => {}
    }
}

fn extract_id_list(val: &super::expr_types::Value) -> Vec<String> {
    match val {
        super::expr_types::Value::List(arr) => arr
            .iter()
            .filter_map(|v| v.as_str().map(|s| s.to_string()))
            .collect(),
        _ => Vec::new(),
    }
}

/// Swap-with-neighbor-skipping-selected for Move Up
/// (ARTBOARDS.md §Reordering). Returns true if any swap occurred.
fn move_artboards_up(
    artboards: &mut Vec<crate::document::artboard::Artboard>,
    selected_ids: &[String],
) -> bool {
    let selected: std::collections::HashSet<&str> =
        selected_ids.iter().map(|s| s.as_str()).collect();
    let mut changed = false;
    for i in 0..artboards.len() {
        if !selected.contains(artboards[i].id.as_str()) {
            continue;
        }
        if i == 0 {
            continue;
        }
        if selected.contains(artboards[i - 1].id.as_str()) {
            continue;
        }
        artboards.swap(i - 1, i);
        changed = true;
    }
    changed
}

fn move_artboards_down(
    artboards: &mut Vec<crate::document::artboard::Artboard>,
    selected_ids: &[String],
) -> bool {
    let selected: std::collections::HashSet<&str> =
        selected_ids.iter().map(|s| s.as_str()).collect();
    let mut changed = false;
    let n = artboards.len();
    for i in (0..n).rev() {
        if !selected.contains(artboards[i].id.as_str()) {
            continue;
        }
        if i + 1 >= n {
            continue;
        }
        if selected.contains(artboards[i + 1].id.as_str()) {
            continue;
        }
        artboards.swap(i, i + 1);
        changed = true;
    }
    changed
}

fn delete_element_at(
    path: &[usize],
    st: &mut crate::workspace::app_state::AppState,
) -> Option<crate::geometry::element::Element> {
    let tab = st.tabs.get_mut(st.active_tab)?;
    let doc = tab.model.document().clone();
    let path_vec = path.to_vec();
    let removed = doc.get_element(&path_vec).cloned();
    let new_doc = doc.delete_element(&path_vec);
    tab.model.set_document(new_doc);
    removed
}

/// Deep-clone the element at path without mutating the document.
fn clone_element_at(
    path: &[usize],
    st: &crate::workspace::app_state::AppState,
) -> Option<crate::geometry::element::Element> {
    let tab = st.tabs.get(st.active_tab)?;
    let path_vec = path.to_vec();
    tab.model.document().get_element(&path_vec).cloned()
}

/// Insert element immediately after the element at path.
fn insert_element_after(
    path: &[usize],
    element: crate::geometry::element::Element,
    st: &mut crate::workspace::app_state::AppState,
) {
    let Some(tab) = st.tabs.get_mut(st.active_tab) else { return; };
    let path_vec = path.to_vec();
    let new_doc = tab.model.document().clone().insert_element_after(&path_vec, element);
    tab.model.set_document(new_doc);
}

/// Insert element at a position under a parent path.
fn insert_element_at(
    parent_path: &[usize],
    index: usize,
    element: crate::geometry::element::Element,
    st: &mut crate::workspace::app_state::AppState,
) {
    let Some(tab) = st.tabs.get_mut(st.active_tab) else { return; };
    let mut new_doc = tab.model.document().clone();
    if parent_path.is_empty() {
        // Top-level: insert into layers array at index
        let idx = index.min(new_doc.layers.len());
        new_doc.layers.insert(idx, element);
    } else {
        // Nested: build insertion path = parent_path + [index]
        let mut insert_path = parent_path.to_vec();
        insert_path.push(index);
        new_doc = new_doc.insert_element_at(&insert_path, element);
    }
    tab.model.set_document(new_doc);
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
                le.name = s.clone();
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
                ToolKind::MagicWand => "magic_wand",
                ToolKind::Pen => "pen",
                ToolKind::AddAnchorPoint => "add_anchor",
                ToolKind::DeleteAnchorPoint => "delete_anchor",
                ToolKind::AnchorPoint => "anchor_point",
                ToolKind::Pencil => "pencil",
                ToolKind::Paintbrush => "paintbrush",
                ToolKind::BlobBrush => "blob_brush",
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
                ToolKind::Scale => "scale",
                ToolKind::Rotate => "rotate",
                ToolKind::Shear => "shear",
                ToolKind::Hand => "hand",
                ToolKind::Zoom => "zoom",
                ToolKind::Artboard => "artboard",
                ToolKind::Eyedropper => "eyedropper",
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
    let bg_style = if checked {
        format!("background:{checked_bg};")
    } else {
        String::new()
    };

    // Resolve the icon name. ``bind.icon`` (yaml expression) wins
    // when present so widgets like the Opacity panel's
    // op_link_indicator can flip between glyphs as mask.linked
    // changes; falls back to the static ``icon`` field otherwise.
    let icon_name: String = if let Some(expr_str) = el.get("bind").and_then(|b| b.get("icon")).and_then(|v| v.as_str()) {
        match expr::eval(expr_str, ctx) {
            Value::Str(s) => s,
            _ => el.get("icon").and_then(|i| i.as_str()).unwrap_or("").to_string(),
        }
    } else {
        el.get("icon").and_then(|i| i.as_str()).unwrap_or("").to_string()
    };
    let icon_name = icon_name.as_str();
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
    // Disabled styling: grey out + block pointer events so the
    // button doesn't respond to clicks. Opacity panel's
    // LINK_INDICATOR disables itself when the selection has no mask.
    let disabled_style = if disabled {
        "opacity:0.35;pointer-events:none;"
    } else {
        ""
    };

    rsx! {
        div {
            id: "{id}",
            style: "cursor:pointer;{disabled_style}{bg_style}{style}",
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
    // Declared bounds drive clamp-on-commit. Undeclared → no clamp (e.g.
    // Tracking is signed and has no yaml-declared min/max).
    let min_clamp = el.get("min").and_then(|m| m.as_f64());
    let max_clamp = el.get("max").and_then(|m| m.as_f64());
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
    //
    // Dispatch the write to the correct per-panel state struct based on
    // the enclosing panel's kind (set by render_panel on rctx). Stroke
    // keeps its existing weight → app_default_stroke sync; Character
    // pushes changes through apply_character_panel_to_selection.
    let panel_kind = rctx.panel_kind;
    let panel_handler = if let BindTarget::Panel(ref field) = bind_target {
        let f = field.clone();
        let app = app.clone();
        let mut revision = revision;
        Some(EventHandler::new(move |evt: Event<FormData>| {
            let mut new_val: f64 = evt.value().parse().unwrap_or(0.0);
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
                        // Artboards, Layers, Color, Swatches, Properties:
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
                r#type: "number",
                min: "{min}",
                max: "{max}",
                value: "{value}",
                style: "min-width:0;color:var(--jas-text,#ccc);background:var(--jas-pane-bg-dark,#333);border:1px solid var(--jas-border,#555);{style}",
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

    rsx! {
        input {
            id: "{id}",
            r#type: "text",
            placeholder: "{placeholder}",
            initial_value: "{value}",
            style: "color:var(--jas-text,#ccc);background:var(--jas-pane-bg-dark,#333);border:1px solid var(--jas-border,#555);{style}",
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
                                // Artboards, Layers, Color, Swatches, Properties:
                                // no-op until their per-panel state lands.
                                _ => {}
                            }
                        });
                    }
                    BindTarget::None => {}
                }
                revision += 1;
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

    // Accept either bind.value or bind.checked; panels prefer `value`
    // (matches the convention used elsewhere), dialog binds have
    // historically used `checked`. We fall back cleanly.
    let bind_expr = el.get("bind").and_then(|b| b.get("value")).and_then(|v| v.as_str())
        .or_else(|| el.get("bind").and_then(|b| b.get("checked")).and_then(|v| v.as_str()))
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
                    dialog_signal.set(Some(ds));
                }
            }
            BindTarget::Panel(field) => {
                let f = field.clone();
                let app = app.clone();
                spawn(async move {
                    let mut st = app.borrow_mut();
                    match panel_kind {
                        Some(PanelKind::Character) => {
                            set_character_field(&mut st.character_panel, &f, &serde_json::json!(new_val));
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
                });
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

    // Selected: 2px accent outline replacing the 1px border. Shifted
    // border via box-shadow keeps the visual size consistent.
    let final_border = if selected {
        "2px solid var(--jas-accent,#4a90d9)"
    } else {
        border
    };

    let style = if hollow {
        format!("width:{size}px;height:{size}px;background:transparent;border:6px solid {bg};cursor:pointer;box-sizing:border-box;{z_style}{extra_style}")
    } else {
        format!("width:{size}px;height:{size}px;background:{bg};border:{final_border};cursor:pointer;box-sizing:border-box;{z_style}{extra_style}")
    };

    let on_click = build_click_handler(el, ctx, rctx);
    let on_dblclick = build_dblclick_handler(el, ctx, rctx);

    rsx! {
        div {
            id: "{id}",
            class: "jas-swatch-tile",
            style: "{style}",
            onclick: move |evt| { if let Some(ref h) = on_click { h.call(evt); } },
            ondoubleclick: move |evt| { if let Some(ref h) = on_dblclick { h.call(evt); } },
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
            _ => None,
        });
        let mut child = rctx.clone();
        child.panel_kind = panel_kind;
        render_el(content, ctx, &child)
    } else {
        render_placeholder(el, ctx, rctx)
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
    let pad = (w.max(h) * 0.02).max(0.5);
    let vb = format!("{} {} {} {}", x - pad, y - pad, w + 2.0 * pad, h + 2.0 * pad);
    let inner = crate::geometry::svg::element_svg(elem, "");
    format!(
        r#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" width="100%" height="100%" preserveAspectRatio="xMidYMid meet">{inner}</svg>"#
    )
}

fn tree_elem_display_name(elem: &GeoElement) -> (String, bool) {
    if let GeoElement::Layer(le) = elem {
        if !le.name.is_empty() {
            return (le.name.clone(), true);
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
                tree_flatten_rc_children(grandchildren, depth + 1, &path, &current_layer_color, selected_paths, collapsed_paths, panel_selection, renaming_path, rows);
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
                tree_flatten_rc_children(children, 1, &path, &layer_color, selected_paths, collapsed_paths, panel_selection, renaming_path, &mut rows);
            }
        }
    }
    rows
}

// ──────────────────────────────────────────────────────────────

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
                name,
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
                },
            })
        }).collect();
        let mut new_doc = st.tabs[st.active_tab].model.document().clone();
        new_doc.layers = doc_layers;
        st.tabs[st.active_tab].model.set_document(new_doc);
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

    // ── Phase 3 Group B: doc.delete_at / doc.clone_at / doc.insert_after

    #[test]
    fn doc_delete_at_top_level() {
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, false),
            ("B".into(), Visibility::Preview, false),
            ("C".into(), Visibility::Preview, false),
        ]);
        let eval_ctx = serde_json::json!({});
        let effects = vec![serde_json::json!({"doc.delete_at": "path(1)"})];
        run_yaml_effects(&effects, &eval_ctx, &mut st);
        let layers = &st.tabs[st.active_tab].model.document().layers;
        assert_eq!(layers.len(), 2);
        assert_eq!(tab_layer(&st, 0).name, "A");
        assert_eq!(tab_layer(&st, 1).name, "C");
    }

    #[test]
    fn doc_clone_at_then_insert_after_duplicates() {
        let mut st = make_state_with_layers(vec![
            ("A".into(), Visibility::Preview, false),
            ("B".into(), Visibility::Preview, false),
        ]);
        let eval_ctx = serde_json::json!({});
        let effects = vec![
            serde_json::json!({"doc.clone_at": "path(0)", "as": "clone"}),
            serde_json::json!({"doc.insert_after": {"path": "path(0)", "element": "clone"}}),
        ];
        run_yaml_effects(&effects, &eval_ctx, &mut st);
        let layers = &st.tabs[st.active_tab].model.document().layers;
        assert_eq!(layers.len(), 3);
        assert_eq!(tab_layer(&st, 0).name, "A");
        assert_eq!(tab_layer(&st, 1).name, "A");   // clone
        assert_eq!(tab_layer(&st, 2).name, "B");
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
        assert_eq!(tab_layer(&st, 0).name, "B");
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
        let layer_a = Element::Layer(LayerElem {
            name: "A".into(), children: Vec::new(),
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        });
        let child1 = Element::Layer(LayerElem {
            name: "c1".into(), children: Vec::new(),
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        });
        let child2 = Element::Layer(LayerElem {
            name: "c2".into(), children: Vec::new(),
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        });
        let group = Element::Group(GroupElem {
            children: vec![Rc::new(child1), Rc::new(child2)],
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        });
        let layer_b = Element::Layer(LayerElem {
            name: "B".into(), children: Vec::new(),
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        });
        let mut new_doc = st.tabs[st.active_tab].model.document().clone();
        new_doc.layers = vec![layer_a, group, layer_b];
        st.tabs[st.active_tab].model.set_document(new_doc);
        st.layers_panel_selection = vec![vec![1]];
        let params = serde_json::Map::new();
        dispatch_action("flatten_artwork", &params, &mut st);
        let layers = &st.tabs[st.active_tab].model.document().layers;
        assert_eq!(layers.len(), 4);
        // Children c1 and c2 are NOT Layers but are held as Rc<Element>;
        // the unpacker dereferences. After unpack: A, c1, c2, B.
        let names: Vec<String> = layers.iter().map(|e| match e {
            Element::Layer(le) => le.name.clone(),
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
        assert_eq!(tab_layer(&st, 0).name, "Layer 2");
        match &layers[1] {
            Element::Layer(le) => {
                assert_eq!(le.name, "Layer 4");
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
        assert_eq!(tab_layer(&st, 1).name, "B");
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
        assert_eq!(tab_layer(&st, 1).name, "Layer 2");
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
        assert_eq!(tab_layer(&st, 2).name, "Layer 4");
        // Layer 3 shifted to index 3
        assert_eq!(tab_layer(&st, 3).name, "Layer 3");
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
        assert_eq!(tab_layer(&st, 0).name, "A");
        assert_eq!(tab_layer(&st, 1).name, "B");
        assert_eq!(tab_layer(&st, 2).name, "B");
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
        assert_eq!(layer.name, "Renamed");
        assert!(layer.common.locked);
        assert_eq!(layer.common.visibility, Visibility::Outline);
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
        assert_eq!(tab_layer(&st, 1).name, "Brand New");
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
        let effects = vec![serde_json::json!({
            "foreach": {"source": "[path(2), path(0)]", "as": "p"},
            "do": [{"doc.delete_at": "p"}]
        })];
        run_yaml_effects(&effects, &eval_ctx, &mut st);
        let layers = &st.tabs[st.active_tab].model.document().layers;
        assert_eq!(layers.len(), 2);
        assert_eq!(tab_layer(&st, 0).name, "B");
        assert_eq!(tab_layer(&st, 1).name, "D");
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
        st.tabs[st.active_tab].model.set_document(new_doc);
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
        st.tabs[st.active_tab].model.set_document(new_doc);
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
        st.tabs[st.active_tab].model.set_document(new_doc);
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
        st.tabs[st.active_tab].model.set_document(doc);
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
        st.tabs[st.active_tab].model.set_document(doc);
        let view = build_active_document_view(&st);
        let expected = serde_json::json!([
            {"__path__": [0]},
            {"__path__": [0, 2]},
        ]);
        assert_eq!(view["element_selection"], expected);
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
        st.tabs[st.active_tab].model.set_document(doc);
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
        let changed = super::move_artboards_up(&mut abs, &selected);
        assert!(changed);
        let ids: Vec<&str> = abs.iter().map(|a| a.id.as_str()).collect();
        assert_eq!(ids, vec!["a1", "a3", "a2", "a5", "a4"]);
    }

    #[test]
    fn apply_artboard_override_all_fields() {
        let mut ab = Artboard::default_with_id("aaa".into());
        super::apply_artboard_override(&mut ab, "name", &super::super::expr_types::Value::Str("Cover".into()));
        super::apply_artboard_override(&mut ab, "x", &super::super::expr_types::Value::Number(100.0));
        super::apply_artboard_override(&mut ab, "y", &super::super::expr_types::Value::Number(200.0));
        super::apply_artboard_override(&mut ab, "width", &super::super::expr_types::Value::Number(400.0));
        super::apply_artboard_override(&mut ab, "fill", &super::super::expr_types::Value::Str("#ff0000".into()));
        super::apply_artboard_override(&mut ab, "show_center_mark", &super::super::expr_types::Value::Bool(true));
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
}
