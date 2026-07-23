//! The recorder wiring: a lightweight, always-compiled-but-dormant
//! global handle behind the four capture seams, plus the wasm
//! activation surface (`?record=<seam>:<family>` URL param and the
//! CDP-drivable `window.jas_record_start` / `window.jas_record_stop` /
//! `window.jas_record_status` functions) and the emission path (the
//! existing browser download used by Save / PDF export).
//!
//! Every hook is a no-op unless a recording is armed, so the live app
//! pays one thread-local check per event when dormant.

use crate::document::model::Model;
use crate::recorder::core::{Recorder, Seam};
use crate::tools::tool::ToolKind;
use serde_json::{Map, Value};
use std::cell::{Cell, RefCell};

thread_local! {
    /// The armed recorder, if any (wasm is single-threaded; native
    /// tests each own their thread-local).
    static RECORDER: RefCell<Option<Recorder>> = const { RefCell::new(None) };
    /// `dispatch_action` re-entrancy depth: only depth-0 dispatches are
    /// user intents (nested dispatches are the outer action's own
    /// effects and replay implicitly through it).
    static ACTION_DEPTH: Cell<u32> = const { Cell::new(0) };
}

/// The YAML tool id for a `ToolKind` — the id the registration in
/// `workspace/app_state.rs` loads the tool spec under, and the id the
/// gesture corpus's `tool` field names. `None` for the permanently
/// NATIVE tools (Type / Type-on-Path), whose pointer traffic is not
/// representable in the YAML-tool replay path.
fn yaml_tool_id(kind: ToolKind) -> Option<&'static str> {
    match kind {
        ToolKind::Type | ToolKind::TypeOnPath => None,
        // The registration ids differ from `panel_state_name` only for
        // the anchor-point add/remove pair.
        ToolKind::AddAnchorPoint => Some("add_anchor_point"),
        ToolKind::DeleteAnchorPoint => Some("delete_anchor_point"),
        other => Some(other.panel_state_name()),
    }
}

/// Arm a recording. Returns false (and leaves any existing recording
/// armed) if a recording is already in progress.
pub fn start(seam: Seam, family: &str, model: &Model) -> bool {
    RECORDER.with(|r| {
        let mut r = r.borrow_mut();
        if r.is_some() {
            return false;
        }
        *r = Some(Recorder::new(seam, family, model));
        true
    })
}

/// Stop the armed recording: finish the envelope, stamp the record-stop
/// fidelity verdicts (each case replayed through the corpus code path
/// and byte-compared against the live oracle), and return it. `None`
/// when no recording was armed. The recorder is disarmed BEFORE the
/// fidelity replay runs, so replay traffic through the hooked seams is
/// never re-recorded.
pub fn stop(model: &Model) -> Option<Value> {
    let rec = RECORDER.with(|r| r.borrow_mut().take())?;
    let mut env = rec.finish(model);
    super::fidelity::stamp(&mut env);
    Some(env)
}

/// `"<seam>:<family>"` while a recording is armed, else `""`.
pub fn status() -> String {
    RECORDER.with(|r| {
        r.borrow()
            .as_ref()
            .map(|rec| format!("{}:{}", rec.seam().as_str(), rec.family()))
            .unwrap_or_default()
    })
}

/// Canvas pointer hook — call BEFORE the tool dispatch (the conversion
/// must use the view AT this event, and the tool may change it).
/// Pointer traffic on a permanently native tool (no YAML replay path)
/// is a segmentation boundary instead of a recordable event.
#[allow(clippy::too_many_arguments)] // mirrors the CanvasTool seam signature plus capture context
pub fn pointer_event(
    kind: &str,
    x: f64,
    y: f64,
    shift: bool,
    alt: bool,
    dragging: bool,
    tool: ToolKind,
    app_state: &Map<String, Value>,
    model: &Model,
) {
    RECORDER.with(|r| {
        if let Some(rec) = r.borrow_mut().as_mut() {
            match yaml_tool_id(tool) {
                Some(tool_id) => rec.record_pointer_event(
                    kind, x, y, shift, alt, dragging, tool_id, app_state, model,
                ),
                None => rec.segment(model),
            }
        }
    });
}

/// Keyboard hook — call where the normalized chord is resolved
/// (`resolve_key`), recording the chord for the key seam.
pub fn key_event(chord: &crate::workspace::resolve_key::KeyChord) {
    RECORDER.with(|r| {
        if let Some(rec) = r.borrow_mut().as_mut() {
            rec.record_key(&chord.key, chord.ctrl, chord.shift, chord.alt, chord.meta);
        }
    });
}

/// History-navigation hook — call BEFORE `model.undo()` / `redo()` at
/// the UI call sites (the pre-nav document is the segment oracle).
pub fn history_nav(model: &Model) {
    RECORDER.with(|r| {
        if let Some(rec) = r.borrow_mut().as_mut() {
            rec.note_history_nav(model);
        }
    });
}

/// RAII guard for `dispatch_action`: tracks re-entrancy depth and, at
/// depth 0 with a recording armed, records the dispatch (action seam)
/// or segments the open case (gesture seam). Construct as the FIRST
/// statement of `dispatch_action`.
pub struct ActionGuard;

impl ActionGuard {
    pub(crate) fn enter(
        action: &str,
        params: &Map<String, Value>,
        st: &crate::workspace::app_state::AppState,
    ) -> ActionGuard {
        let depth = ACTION_DEPTH.with(|d| {
            let v = d.get();
            d.set(v + 1);
            v
        });
        if depth == 0 {
            RECORDER.with(|r| {
                if let Some(rec) = r.borrow_mut().as_mut() {
                    if let Some(tab) = st.tab() {
                        rec.record_action(action, params, &tab.model);
                    }
                }
            });
        }
        ActionGuard
    }
}

impl Drop for ActionGuard {
    fn drop(&mut self) {
        ACTION_DEPTH.with(|d| d.set(d.get().saturating_sub(1)));
    }
}

// ---------------------------------------------------------------------------
// wasm activation + emission surface
// ---------------------------------------------------------------------------

#[cfg(target_arch = "wasm32")]
mod wasm_api {
    use super::*;
    use crate::workspace::app_state::AppHandle;
    use wasm_bindgen::prelude::*;

    /// Start/stop against the app's active-tab model via the installed
    /// handle. Returns None when no app handle / no tab.
    fn with_active_model<T>(app: &AppHandle, f: impl FnOnce(&Model) -> T) -> Option<T> {
        let st = app.try_borrow().ok()?;
        let tab = st.tab()?;
        Some(f(&tab.model))
    }

    fn start_str(app: &AppHandle, seam: &str, family: &str) -> bool {
        let Some(seam) = Seam::parse(seam) else {
            web_sys::console::warn_1(
                &format!("jas_record_start: unknown seam '{seam}' (gesture|action|key|journal)")
                    .into(),
            );
            return false;
        };
        // A family name becomes fixture/case file names; keep it a safe
        // identifier.
        if family.is_empty()
            || !family
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
        {
            web_sys::console::warn_1(
                &format!("jas_record_start: family '{family}' must be [a-z0-9_]+").into(),
            );
            return false;
        }
        with_active_model(app, |m| super::start(seam, family, m)).unwrap_or(false)
    }

    fn stop_and_emit(app: &AppHandle) -> String {
        let Some(env) = with_active_model(app, super::stop).flatten() else {
            return String::new();
        };
        let family = env["family"].as_str().unwrap_or("recording");
        let json = serde_json::to_string_pretty(&env).unwrap_or_default();
        // Emit through the existing browser download path (the same
        // one Save / PDF export use); the CDP driver can ALSO read the
        // returned JSON directly from the evaluate result.
        crate::workspace::clipboard::download_bytes(
            &format!("{family}.recording.json"),
            json.as_bytes(),
            "application/json",
        );
        json
    }

    /// Install the recorder's window API (`window.jas_record_start/
    /// stop/status`) and honor a `?record=<seam>:<family>` URL query
    /// param. Called once from App mount with the shared state handle.
    pub fn install(app: AppHandle) {
        // window.jas_record_start(seam, family) -> bool
        {
            let app = app.clone();
            let cb = Closure::<dyn Fn(String, String) -> bool>::new(move |seam: String, family: String| {
                start_str(&app, &seam, &family)
            });
            let _ = js_sys::Reflect::set(
                &js_sys::global(),
                &"jas_record_start".into(),
                cb.as_ref(),
            );
            cb.forget();
        }
        // window.jas_record_stop() -> String (the fidelity-stamped
        // recording envelope; also triggers the .recording.json download)
        {
            let app = app.clone();
            let cb = Closure::<dyn Fn() -> String>::new(move || stop_and_emit(&app));
            let _ = js_sys::Reflect::set(
                &js_sys::global(),
                &"jas_record_stop".into(),
                cb.as_ref(),
            );
            cb.forget();
        }
        // window.jas_record_status() -> String ("<seam>:<family>" | "")
        {
            let cb = Closure::<dyn Fn() -> String>::new(super::status);
            let _ = js_sys::Reflect::set(
                &js_sys::global(),
                &"jas_record_status".into(),
                cb.as_ref(),
            );
            cb.forget();
        }
        // URL activation: ?record=<seam>:<family> arms at app start.
        if let Some(search) = js_sys::eval("window.location.search")
            .ok()
            .and_then(|v| v.as_string())
        {
            if let Some(spec) = search
                .trim_start_matches('?')
                .split('&')
                .find_map(|kv| kv.strip_prefix("record="))
            {
                if let Some((seam, family)) = spec.split_once(':') {
                    let ok = start_str(&app, seam, family);
                    web_sys::console::log_1(
                        &format!("jas recorder: ?record={spec} -> armed={ok}").into(),
                    );
                }
            }
        }
    }
}

/// Install the wasm activation surface (no-op on native builds).
#[cfg(target_arch = "wasm32")]
pub(crate) fn install(app: crate::workspace::app_state::AppHandle) {
    wasm_api::install(app);
}

/// Native builds have no activation surface (the `wasm_api` module is
/// cfg'd out), but the capture core still compiles and unit-tests
/// there. This never-called root references the wasm-only entry points
/// so native dead-code analysis doesn't flag the (wasm-live) recorder
/// pipeline behind them.
#[cfg(not(target_arch = "wasm32"))]
#[allow(dead_code)] // liveness root, deliberately never called
fn native_liveness_root() {
    let _ = start as fn(Seam, &str, &Model) -> bool;
    let _ = stop as fn(&Model) -> Option<Value>;
    let _ = status as fn() -> String;
    let _ = Seam::parse as fn(&str) -> Option<Seam>;
    let _ = Seam::as_str as fn(&Seam) -> &'static str;
}
