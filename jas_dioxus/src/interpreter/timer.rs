//! Timer management for start_timer/cancel_timer effects.
//!
//! Uses web_sys setTimeout/clearTimeout for delayed effect execution.
//! Timers are stored by ID so they can be cancelled.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use dioxus::prelude::*;
use wasm_bindgen::prelude::*;
use wasm_bindgen::JsCast;

/// Shared timer registry provided via Dioxus context.
#[derive(Clone)]
pub struct TimerCtx(pub Rc<RefCell<HashMap<String, i32>>>);

/// Start a delayed timer that runs effects after delay_ms.
///
/// If a timer with the same id already exists, it is cancelled first.
/// The callback runs the given effects via the dialog/action system.
pub fn start_timer(
    timer_ctx: &TimerCtx,
    timer_id: &str,
    delay_ms: u32,
    effects: Vec<serde_json::Value>,
    app: crate::workspace::app_state::AppHandle,
    mut dialog_signal: Signal<Option<super::dialog_view::DialogState>>,
    mut revision: Signal<u64>,
) {
    // Cancel existing timer with same id
    cancel_timer(timer_ctx, timer_id);

    let timer_id_owned = timer_id.to_string();
    let timers = timer_ctx.0.clone();

    // Create JS closure for the timeout callback
    let closure = Closure::once(move || {
        // Remove timer from registry
        timers.borrow_mut().remove(&timer_id_owned);

        // Process effects
        let mut deferred_dialog_effects = Vec::new();
        {
            let mut st = app.borrow_mut();
            for eff in &effects {
                if eff.get("open_dialog").is_some() || eff.get("close_dialog").is_some() {
                    deferred_dialog_effects.push(eff.clone());
                }
                // Handle set effects
                if let Some(set_map) = eff.get("set").and_then(|v| v.as_object()) {
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
            }
        }

        // Apply deferred dialog effects
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
                super::dialog_view::open_dialog(
                    &mut dialog_signal, dlg_id, &raw_params, &live_state,
                );
            }
        }
        revision += 1;
    });

    // Set the timeout via web_sys
    let window = web_sys::window().expect("no window");
    let handle = window.set_timeout_with_callback_and_timeout_and_arguments_0(
        closure.as_ref().unchecked_ref(),
        delay_ms as i32,
    ).unwrap_or(-1);

    // Store the timer handle
    timer_ctx.0.borrow_mut().insert(timer_id.to_string(), handle);

    // Prevent the closure from being dropped (it needs to live until the timeout fires)
    closure.forget();
}

/// Cancel a pending timer by ID.
pub fn cancel_timer(timer_ctx: &TimerCtx, timer_id: &str) {
    if let Some(handle) = timer_ctx.0.borrow_mut().remove(timer_id) {
        if let Some(window) = web_sys::window() {
            window.clear_timeout_with_handle(handle);
        }
    }
}
