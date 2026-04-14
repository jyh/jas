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

fn render_el(
    el: &serde_json::Value,
    ctx: &serde_json::Value,
    rctx: &RenderCtx,
) -> Element {
    // Handle repeat directive: expand template for each item in source
    if el.get("repeat").is_some() && el.get("template").is_some() {
        return render_repeat(el, ctx, rctx);
    }

    let etype = el.get("type").and_then(|t| t.as_str()).unwrap_or("placeholder");

    match etype {
        "container" | "row" | "col" => render_container(el, ctx, rctx),
        "grid" => render_grid(el, ctx, rctx),
        "text" => render_text(el, ctx),
        "button" => render_button(el, ctx, rctx),
        "icon_button" => render_icon_button(el, ctx, rctx),
        "slider" => render_slider(el, ctx, rctx),
        "number_input" => render_number_input(el, ctx),
        "text_input" => render_text_input(el, ctx),
        "color_swatch" => render_color_swatch(el, ctx, rctx),
        "fill_stroke_widget" => render_fill_stroke_widget(el, ctx, rctx),
        "color_bar" => render_color_bar(el, ctx, rctx),
        "color_gradient" => render_color_gradient(el, ctx, rctx),
        "color_hue_bar" => render_color_hue_bar(el, ctx, rctx),
        "separator" => render_separator(el, ctx),
        "spacer" => render_spacer(el, ctx),
        "disclosure" => render_disclosure(el, ctx, rctx),
        "panel" => render_panel(el, ctx, rctx),
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
    let repeat = el.get("repeat").unwrap();
    let template = el.get("template").unwrap();
    let source_expr = repeat.get("source").and_then(|s| s.as_str()).unwrap_or("");
    let var_name = repeat.get("as").and_then(|s| s.as_str()).unwrap_or("item");

    // Build scope from context and evaluate source
    let scope = super::scope::Scope::from_json(ctx);
    let items = eval_to_json(source_expr, ctx);

    let style = build_style(el, ctx);
    let layout = el.get("layout").and_then(|l| l.as_str()).unwrap_or("column");
    let dir_style = match layout {
        "wrap" => format!("display:flex;flex-wrap:wrap;{style}"),
        "row"  => format!("display:flex;flex-direction:row;{style}"),
        _      => format!("display:flex;flex-direction:column;{style}"),
    };

    let mut children = Vec::new();
    if let Some(arr) = items.as_array() {
        for (i, item) in arr.iter().enumerate() {
            // Build item data with _index
            let mut item_obj = item.as_object().cloned().unwrap_or_default();
            item_obj.insert("_index".into(), serde_json::json!(i));

            // Push a child scope with the loop variable — parent is unchanged
            let child_scope = scope.extend(std::collections::HashMap::from([
                (var_name.to_string(), serde_json::Value::Object(item_obj)),
            ]));
            let child_ctx = child_scope.to_json();

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
    }
}

// ── Generic behavior dispatch ──────────────────────────────────

/// Dispatch a named action with resolved params on AppState.
fn dispatch_action(action: &str, params: &serde_json::Map<String, serde_json::Value>, st: &mut crate::workspace::app_state::AppState) {
    use crate::geometry::element::Color;
    match action {
        "set_active_color" => {
            if let Some(color_val) = params.get("color").and_then(|v| v.as_str()) {
                if let Some(c) = parse_hex_color(color_val) {
                    st.set_active_color(c);
                }
            }
        }
        "set_active_color_none" => st.set_active_to_none(),
        "swap_fill_stroke" => st.swap_fill_stroke(),
        "reset_fill_stroke" => st.reset_fill_stroke_defaults(),
        _ => {}
    }
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
            for (key, val) in set_map {
                match key.as_str() {
                    "fill_on_top" => {
                        if let Some(b) = val.as_bool() {
                            st.fill_on_top = b;
                        }
                    }
                    _ => {}
                }
            }
        }
        // Defer dialog effects — they need the dialog signal, not AppState
        if effect.get("open_dialog").is_some() || effect.get("close_dialog").is_some() {
            dialog_effects.push(effect.clone());
        }
    }
    dialog_effects
}

/// Build an onclick handler from an element's behavior declarations.
/// Returns None if the element has no click behaviors.
fn build_click_handler(
    el: &serde_json::Value,
    ctx: &serde_json::Value,
    rctx: &RenderCtx,
) -> Option<EventHandler<Event<MouseData>>> {
    let behaviors = el.get("behavior").and_then(|b| b.as_array())?;
    let click_behaviors: Vec<&serde_json::Value> = behaviors.iter()
        .filter(|b| b.get("event").and_then(|e| e.as_str()).unwrap_or("click") == "click")
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
                    Value::Null => { resolved_params.insert(k.clone(), serde_json::Value::Null); }
                    Value::List(l) => { resolved_params.insert(k.clone(), serde_json::Value::Array(l)); }
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
                            dispatch_action(action_name, params, &mut st);
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

// ── Element renderers ────────────────────────────────────────

fn render_container(el: &serde_json::Value, ctx: &serde_json::Value, rctx: &RenderCtx) -> Element {
    let id = get_id(el);
    let layout = el.get("layout").and_then(|l| l.as_str()).unwrap_or("column");
    let etype = el.get("type").and_then(|t| t.as_str()).unwrap_or("container");
    let dir = if layout == "row" || etype == "row" { "row" } else { "column" };
    let base_style = build_style(el, ctx);
    // Apply default text color if not explicitly set in the element's style
    let has_color = el.get("style")
        .and_then(|s| s.as_object())
        .map_or(false, |m| m.contains_key("color"));
    let color_default = if has_color { "" } else { "color:var(--jas-text,#ccc);" };
    let visible = is_visible(el, ctx);
    let style = if visible {
        format!("display:flex;flex-direction:{dir};{color_default}{base_style}")
    } else {
        format!("display:none;flex-direction:{dir};{color_default}{base_style}")
    };
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
    let on_click = build_click_handler(el, ctx, rctx);

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

    // Look up icon SVG from the icons map in ctx
    let icon_name = el.get("icon").and_then(|i| i.as_str()).unwrap_or("");
    let icon_svg = if !icon_name.is_empty() {
        if let Some(icon_def) = ctx.get("icons").and_then(|i| i.get(icon_name)) {
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
            style: "cursor:pointer;{style}",
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

    // Get bind field name (e.g. "panel.h" → "h")
    let bind_expr = el.get("bind").and_then(|b| b.get("value")).and_then(|v| v.as_str()).unwrap_or("");
    let field = bind_expr.strip_prefix("panel.").or_else(|| {
        bind_expr.strip_prefix("{{panel.").and_then(|s| s.strip_suffix("}}"))
    }).unwrap_or("").to_string();

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
                if field.is_empty() { return; }
                let new_val: f64 = evt.value().parse().unwrap_or(0.0);
                let color = compute_color_from_panel(&field, new_val, &panel);
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

fn render_number_input(el: &serde_json::Value, ctx: &serde_json::Value) -> Element {
    let id = get_id(el);
    let min = el.get("min").and_then(|m| m.as_i64()).unwrap_or(0);
    let max = el.get("max").and_then(|m| m.as_i64()).unwrap_or(100);
    let style = build_style(el, ctx);

    let value = if let Some(bind_val) = el.get("bind").and_then(|b| b.get("value")).and_then(|v| v.as_str()) {
        let result = expr::eval(bind_val, ctx);
        match result {
            Value::Number(n) => n as i64,
            _ => min,
        }
    } else {
        min
    };

    rsx! {
        input {
            id: "{id}",
            r#type: "number",
            min: "{min}",
            max: "{max}",
            value: "{value}",
            style: "width:45px;color:var(--jas-text,#ccc);background:var(--jas-pane-bg-dark,#333);border:1px solid var(--jas-border,#555);{style}",
        }
    }
}

fn render_text_input(el: &serde_json::Value, ctx: &serde_json::Value) -> Element {
    let id = get_id(el);
    let placeholder = el.get("placeholder").and_then(|p| p.as_str()).unwrap_or("");
    let style = build_style(el, ctx);

    rsx! {
        input {
            id: "{id}",
            r#type: "text",
            placeholder: "{placeholder}",
            style: "color:var(--jas-text,#ccc);background:var(--jas-pane-bg-dark,#333);border:1px solid var(--jas-border,#555);{style}",
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
        let result = expr::eval(bind_color, ctx);
        match result {
            Value::Color(c) => c,
            Value::Str(s) if s.starts_with('#') => s,
            _ => String::new(),
        }
    } else {
        String::new()
    };

    let bg = if color.is_empty() { "transparent".to_string() } else { color.clone() };
    let border = if color.is_empty() { "1px dashed var(--jas-border,#555)" } else { "1px solid var(--jas-border,#666)" };
    let hollow = el.get("hollow").and_then(|h| h.as_bool()).unwrap_or(false);

    let style = if hollow {
        format!("width:{size}px;height:{size}px;background:transparent;border:6px solid {bg};cursor:pointer;box-sizing:border-box;")
    } else {
        format!("width:{size}px;height:{size}px;background:{bg};border:{border};cursor:pointer;box-sizing:border-box;")
    };

    let on_click = build_click_handler(el, ctx, rctx);

    if let Some(handler) = on_click {
        rsx! {
            div {
                id: "{id}",
                style: "{style}",
                onclick: handler,
            }
        }
    } else {
        rsx! {
            div {
                id: "{id}",
                style: "{style}",
            }
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
            ds.state.insert("s".to_string(), serde_json::json!(sat.round() as i64));
            ds.state.insert("b".to_string(), serde_json::json!(bri.round() as i64));
            // Recompute color from HSB
            let h = ds.state.get("h").and_then(|v| v.as_f64()).unwrap_or(0.0);
            let (cr, cg, cb) = crate::interpreter::color_util::hsb_to_rgb(h, sat, bri);
            let hex = format!("#{:02x}{:02x}{:02x}", cr, cg, cb);
            ds.state.insert("color".to_string(), serde_json::json!(hex));
            ds.state.insert("hex".to_string(), serde_json::json!(&hex[1..]));
            ds.state.insert("r".to_string(), serde_json::json!(cr as i64));
            ds.state.insert("g".to_string(), serde_json::json!(cg as i64));
            ds.state.insert("bl".to_string(), serde_json::json!(cb as i64));
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
            ds.state.insert("h".to_string(), serde_json::json!(new_hue.round() as i64));
            // Recompute color from HSB
            let s = ds.state.get("s").and_then(|v| v.as_f64()).unwrap_or(100.0);
            let b = ds.state.get("b").and_then(|v| v.as_f64()).unwrap_or(100.0);
            let (cr, cg, cb) = crate::interpreter::color_util::hsb_to_rgb(new_hue, s, b);
            let hex = format!("#{:02x}{:02x}{:02x}", cr, cg, cb);
            ds.state.insert("color".to_string(), serde_json::json!(hex));
            ds.state.insert("hex".to_string(), serde_json::json!(&hex[1..]));
            ds.state.insert("r".to_string(), serde_json::json!(cr as i64));
            ds.state.insert("g".to_string(), serde_json::json!(cg as i64));
            ds.state.insert("bl".to_string(), serde_json::json!(cb as i64));
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
