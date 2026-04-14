//! YAML-interpreted dialog component.
//!
//! Renders a modal dialog from workspace YAML definitions. The dialog
//! specification is loaded from the compiled workspace JSON, and the
//! content element tree is rendered via the shared YAML renderer.

use dioxus::prelude::*;
use serde_json;
use std::collections::HashMap;

use super::expr;
use super::expr_types::Value;
use super::workspace::Workspace;
use crate::workspace::theme::*;

/// Dialog state held in a Dioxus signal.
#[derive(Clone, Debug)]
pub struct DialogState {
    /// Dialog ID (matches a key in workspace dialogs).
    pub id: String,
    /// Dialog-local state values.
    pub state: HashMap<String, serde_json::Value>,
    /// Parameters passed when the dialog was opened.
    pub params: HashMap<String, serde_json::Value>,
    /// Anchor position (page coords) for non-modal popover dialogs.
    pub anchor: Option<(f64, f64)>,
}

/// Signal wrapper for providing dialog state via context.
#[derive(Clone)]
pub struct DialogCtx(pub Signal<Option<DialogState>>);

/// Open a dialog by ID, initializing its state from the workspace definition.
///
/// Resolves parameters, extracts state defaults, evaluates init expressions,
/// and sets the dialog signal.
pub fn open_dialog(
    dialog_signal: &mut Signal<Option<DialogState>>,
    dialog_id: &str,
    raw_params: &serde_json::Map<String, serde_json::Value>,
    live_state: &serde_json::Map<String, serde_json::Value>,
) {
    let ws = match Workspace::load() {
        Some(ws) => ws,
        None => return,
    };
    let dlg_def = match ws.dialog(dialog_id) {
        Some(d) => d,
        None => return,
    };

    // Extract state defaults
    let mut defaults = HashMap::new();
    if let Some(serde_json::Value::Object(state_defs)) = dlg_def.get("state") {
        for (key, defn) in state_defs {
            let default_val = if let serde_json::Value::Object(d) = defn {
                d.get("default").cloned().unwrap_or(serde_json::Value::Null)
            } else {
                defn.clone()
            };
            defaults.insert(key.clone(), default_val);
        }
    }

    // Resolve param expressions against current state
    let mut resolved_params = HashMap::new();
    let state_ctx = serde_json::json!({"state": serde_json::Value::Object(live_state.clone())});
    for (k, v) in raw_params {
        if let Some(expr_str) = v.as_str() {
            let result = expr::eval(expr_str, &state_ctx);
            resolved_params.insert(k.clone(), value_to_json(&result));
        } else {
            resolved_params.insert(k.clone(), v.clone());
        }
    }

    // Build init context: state + param + dialog (defaults so far)
    let mut dialog_state = defaults.clone();

    // Evaluate init expressions
    if let Some(serde_json::Value::Object(init_map)) = dlg_def.get("init") {
        for (key, init_expr) in init_map {
            let expr_str = init_expr.as_str().unwrap_or("");
            let dialog_map: serde_json::Map<String, serde_json::Value> =
                dialog_state.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
            let param_map: serde_json::Map<String, serde_json::Value> =
                resolved_params.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
            let init_ctx = serde_json::json!({
                "state": serde_json::Value::Object(live_state.clone()),
                "dialog": serde_json::Value::Object(dialog_map),
                "param": serde_json::Value::Object(param_map),
            });
            let result = expr::eval(expr_str, &init_ctx);
            dialog_state.insert(key.clone(), value_to_json(&result));
        }
    }

    dialog_signal.set(Some(DialogState {
        id: dialog_id.to_string(),
        state: dialog_state,
        params: resolved_params,
        anchor: None,
    }));
}

/// Open a dialog with an anchor position for popover placement.
pub fn open_dialog_at(
    dialog_signal: &mut Signal<Option<DialogState>>,
    dialog_id: &str,
    raw_params: &serde_json::Map<String, serde_json::Value>,
    live_state: &serde_json::Map<String, serde_json::Value>,
    anchor: (f64, f64),
) {
    open_dialog(dialog_signal, dialog_id, raw_params, live_state);
    // Set anchor on the dialog state
    if let Some(mut ds) = dialog_signal() {
        ds.anchor = Some(anchor);
        dialog_signal.set(Some(ds));
    }
}

/// Close the currently open dialog.
pub fn close_dialog(dialog_signal: &mut Signal<Option<DialogState>>) {
    dialog_signal.set(None);
}

fn value_to_json(v: &Value) -> serde_json::Value {
    match v {
        Value::Null => serde_json::Value::Null,
        Value::Bool(b) => serde_json::json!(*b),
        Value::Number(n) => {
            if *n == (*n as i64) as f64 {
                serde_json::json!(*n as i64)
            } else {
                serde_json::json!(*n)
            }
        }
        Value::Str(s) => serde_json::json!(s),
        Value::Color(c) => serde_json::json!(c),
        Value::List(l) => serde_json::Value::Array(l.clone()),
    }
}

/// Dioxus component that renders the active YAML dialog as a modal overlay.
#[component]
pub fn YamlDialogView(dialog_ctx: Signal<Option<DialogState>>) -> Element {
    let Some(ds) = dialog_ctx() else {
        return rsx! {};
    };

    let ws = match Workspace::load() {
        Some(ws) => ws,
        None => return rsx! {},
    };
    let dlg_def = match ws.dialog(&ds.id) {
        Some(d) => d,
        None => return rsx! {},
    };

    let summary = dlg_def.get("summary")
        .and_then(|s| s.as_str())
        .unwrap_or(&ds.id);

    // Build eval context with dialog and param namespaces
    let dialog_map: serde_json::Map<String, serde_json::Value> =
        ds.state.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    let param_map: serde_json::Map<String, serde_json::Value> =
        ds.params.iter().map(|(k, v)| (k.clone(), v.clone())).collect();

    // Get live state from app
    let app = use_context::<crate::workspace::app_state::AppHandle>();
    let st = app.borrow();
    let live_state = crate::workspace::dock_panel::build_live_state_map(&st);
    drop(st);

    let icons = ws.icons().clone();
    let eval_ctx = serde_json::json!({
        "state": live_state,
        "dialog": serde_json::Value::Object(dialog_map),
        "param": serde_json::Value::Object(param_map),
        "icons": icons,
    });

    let content = dlg_def.get("content").cloned().unwrap_or(serde_json::json!({}));

    // Check if this is a modal or popover dialog
    let is_modal = dlg_def.get("modal").and_then(|m| m.as_bool()).unwrap_or(true);
    let anchor = ds.anchor;

    // Optional width from dialog spec
    let width_style = if let Some(w) = dlg_def.get("width").and_then(|w| w.as_f64()) {
        format!("width:{w}px;")
    } else {
        String::new()
    };

    // Backdrop and container styles differ for modal vs popover
    let (backdrop_style, container_pos_style) = if !is_modal {
        if let Some((ax, ay)) = anchor {
            // Popover: transparent backdrop, positioned near anchor
            (
                "position:fixed; inset:0; z-index:2000;".to_string(),
                format!("position:absolute; left:{ax}px; top:{ay}px;"),
            )
        } else {
            // Non-modal without anchor: light backdrop, centered
            (
                "position:fixed; inset:0; z-index:2000; display:flex; align-items:center; justify-content:center;".to_string(),
                String::new(),
            )
        }
    } else {
        // Modal: dimmed backdrop, centered
        (
            "position:fixed; inset:0; background:rgba(0,0,0,0.15); z-index:2000; display:flex; align-items:center; justify-content:center;".to_string(),
            String::new(),
        )
    };

    // Popover dialogs: compact style, no title bar
    let show_title_bar = is_modal;

    rsx! {
        // Backdrop (clicks outside dismiss)
        div {
            style: "{backdrop_style}",
            onmousedown: move |evt: Event<MouseData>| {
                evt.stop_propagation();
                dialog_ctx.set(None);
            },

            // Dialog container
            div {
                style: "background:{THEME_BG}; border:1px solid {THEME_BORDER}; border-radius:8px; box-shadow:0 8px 32px rgba(0,0,0,0.25); {width_style} {container_pos_style}",
                onmousedown: move |evt: Event<MouseData>| {
                    evt.stop_propagation();
                },

                // Title bar (modal dialogs only)
                if show_title_bar {
                    div {
                        style: "display:flex; align-items:center; padding:8px 12px; border-bottom:1px solid {THEME_BORDER}; background:{THEME_TITLE_BAR_BG}; border-radius:8px 8px 0 0;",

                        // Brand logo
                        span {
                            style: "display:inline-block; width:28px; height:14px; color:{BRAND_COLOR}; flex-shrink:0; margin-right:6px;",
                            dangerous_inner_html: BRAND_LOGO_SVG,
                        }

                        // Title
                        span {
                            style: "color:{THEME_TITLE_BAR_TEXT}; font-size:13px; font-weight:500; flex:1;",
                            "{summary}"
                        }

                        // Close button
                        button {
                            style: "background:none; border:none; color:{THEME_TEXT_DIM}; font-size:16px; cursor:pointer; padding:2px 6px; line-height:1;",
                            onclick: move |_| {
                                dialog_ctx.set(None);
                            },
                            "\u{00d7}"
                        }
                    }
                }

                // Dialog body — rendered from YAML content tree
                div {
                    style: "padding:0;",
                    {super::renderer::render_element(&content, &eval_ctx)}
                }
            }
        }
    }
}
