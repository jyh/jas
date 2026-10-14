//! YAML-interpreted dialog component.
//!
//! Renders a modal dialog from workspace YAML definitions. The dialog
//! specification is loaded from the compiled workspace JSON, and the
//! content element tree is rendered via the shared YAML renderer.

use dioxus::prelude::*;
use serde_json;

use super::workspace::Workspace;
use crate::workspace::theme::*;

pub use super::dialog_state::DialogState;

/// Signal wrapper for providing dialog state via context.
#[derive(Clone)]
pub struct DialogCtx(pub Signal<Option<DialogState>>);

/// Open a dialog by ID, initializing its state from the workspace definition.
///
/// Resolves parameters, extracts state defaults, evaluates init expressions,
/// and sets the dialog signal. Back-compatible shim that calls
/// `open_dialog_with_outer` without extra scope — dialog init expressions
/// that reference `panel.*` / `active_document.*` should call the
/// `_with_outer` variant.
pub fn open_dialog(
    dialog_signal: &mut Signal<Option<DialogState>>,
    dialog_id: &str,
    raw_params: &serde_json::Map<String, serde_json::Value>,
    live_state: &serde_json::Map<String, serde_json::Value>,
) {
    open_dialog_with_outer(
        dialog_signal,
        dialog_id,
        raw_params,
        live_state,
        &serde_json::Value::Null,
    )
}

/// As `open_dialog` but threads an `outer_scope` JSON object whose
/// top-level keys (e.g. `panel`, `active_document`) are visible to
/// init expressions alongside `state`, `dialog`, `param`. Required
/// by the Artboard Options Dialogue whose init expressions call
/// `filter(active_document.artboards, …)` and
/// `panel.reference_point`.
pub fn open_dialog_with_outer(
    dialog_signal: &mut Signal<Option<DialogState>>,
    dialog_id: &str,
    raw_params: &serde_json::Map<String, serde_json::Value>,
    live_state: &serde_json::Map<String, serde_json::Value>,
    outer_scope: &serde_json::Value,
) {
    open_dialog_over(dialog_signal, dialog_id, raw_params, live_state, outer_scope, None)
}

/// As `open_dialog_with_outer`, with the opener's resolved `result_to`. When
/// it names a field of the dialog that is OPEN now (`dialog.<key>`), the new
/// dialog is opened OVER it (nested): the open one is kept as its parent, and
/// closing the new one with a result writes that field and returns to it.
/// Anything else replaces the open dialog, as before. The reference's
/// `open_dialog` with `result_to`.
pub fn open_dialog_over(
    dialog_signal: &mut Signal<Option<DialogState>>,
    dialog_id: &str,
    raw_params: &serde_json::Map<String, serde_json::Value>,
    live_state: &serde_json::Map<String, serde_json::Value>,
    outer_scope: &serde_json::Value,
    result_to: Option<&str>,
) {
    if let Some(mut ds) = super::dialog_state::build_dialog_state(
        dialog_id, raw_params, live_state, outer_scope)
    {
        if let Some(open) = dialog_signal() {
            nest_over(&mut ds, open, result_to);
        }
        dialog_signal.set(Some(ds));
    }
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
    close_dialog_with_result(dialog_signal, None);
}

/// Close the open dialog. A nested one returns to its parent, with
/// `result` (the closing dialog's `close_dialog: {result: ...}`, already
/// evaluated) written into the parent field its opener named; otherwise no
/// dialog is left open.
pub fn close_dialog_with_result(
    dialog_signal: &mut Signal<Option<DialogState>>,
    result: Option<serde_json::Value>,
) {
    let next = dialog_signal().and_then(|ds| return_to_parent(ds, result));
    dialog_signal.set(next);
}

/// Open `child` over `open` when `result_to` names one of `open`'s fields
/// (`dialog.<key>`): `open` becomes the child's parent and `<key>` its result
/// field. Anything else leaves the child standalone, replacing `open`.
pub(crate) fn nest_over(child: &mut DialogState, open: DialogState, result_to: Option<&str>) {
    if let Some(key) = result_to.and_then(|r| r.strip_prefix("dialog.")).filter(|k| !k.is_empty()) {
        child.parent = Some(Box::new(open));
        child.result_to = Some(key.to_string());
    }
}

/// The dialog left open when `closing` closes: its parent, with `result`
/// written into the field the opener named, or none.
pub(crate) fn return_to_parent(closing: DialogState, result: Option<serde_json::Value>) -> Option<DialogState> {
    let key = closing.result_to;
    closing.parent.map(|parent| {
        let mut parent = *parent;
        if let (Some(key), Some(result)) = (key, result) {
            parent.state.insert(key, result);
        }
        parent
    })
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

    // Get live state + panel/active_document namespaces so dialog
    // computed props (e.g. Artboard Options x_rp / y_rp) can reach
    // panel.reference_point and active_document.current_artboard.
    let app = use_context::<crate::workspace::app_state::AppHandle>();
    let st = app.borrow();
    let live_state = crate::workspace::dock_panel::build_live_state_map(&st);
    let outer_scope = super::renderer::build_dialog_outer_scope(&st);
    drop(st);

    // Build eval context — dialog map includes computed getters
    // evaluated with the outer scope in view.
    let dialog_map: serde_json::Map<String, serde_json::Value> =
        ds.eval_context_with_outer(Some(&outer_scope));
    let param_map: serde_json::Map<String, serde_json::Value> =
        ds.params.iter().map(|(k, v)| (k.clone(), v.clone())).collect();

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
