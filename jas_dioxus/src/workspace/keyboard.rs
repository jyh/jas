//! Keyboard event handlers extracted from `app.rs`.
//!
//! Provides `make_keydown_handler` and `make_keyup_handler` which return
//! closures suitable for `onkeydown` / `onkeyup` in the main `App` component.

use std::cell::RefCell;
use std::rc::Rc;

use dioxus::prelude::*;

use super::app_state::AppState;
use super::clipboard::{
    clipboard_read_and_paste, clipboard_write, download_file, open_file_dialog, selection_to_svg,
};
use crate::document::controller::Controller;
use crate::geometry::svg::document_to_svg;
use crate::tools::tool::{ToolKind, PASTE_OFFSET};

/// Check if the keyboard event originated from a text input element.
/// When true, non-modifier keys (Backspace, Delete, letters) should
/// be left to the input — not intercepted as app shortcuts.
fn event_targets_input(evt: &Event<KeyboardData>) -> bool {
    #[cfg(target_arch = "wasm32")]
    {
        use wasm_bindgen::JsCast;
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            if let Some(el) = doc.active_element() {
                let tag = el.tag_name().to_uppercase();
                return matches!(tag.as_str(), "INPUT" | "TEXTAREA" | "SELECT");
            }
        }
    }
    false
}

/// The DOM id of the root wrapper div that carries `onkeydown` / `onkeyup`
/// (see `app.rs`). It is the app's primary keyboard surface: it holds
/// `tabindex="0"`, and clicking the canvas — or any non-focusable chrome —
/// moves focus here, because the browser focuses the nearest focusable
/// ancestor.
pub(crate) const APP_ROOT_ID: &str = "jas-app-root";

/// The DOM id of the drawing canvas (see `app.rs`). It carries no `tabindex`
/// today, so it cannot itself be the active element; it is named here so the
/// app's keyboard surfaces are stated by INTENT rather than left to depend on
/// that fact staying true.
pub(crate) const CANVAS_ID: &str = "jas-canvas";

/// Pure half of [`focus_on_app_surface`]: given the focused element's tag name
/// and id, is that one of the app's OWN keyboard surfaces — an element with no
/// native action of its own for the keys this handler claims?
///
/// An ALLOWLIST of two named surfaces, deliberately, rather than a blocklist of
/// the elements that DO own a key: a blocklist has to enumerate `<button>`,
/// `<a href>`, `<summary>`, `contenteditable`, `<input>`/`<textarea>`/`<select>`
/// … and silently steals the key from whatever it forgets. The allowlist can
/// only ever be too conservative, which costs a browser default the app did not
/// need — never a widget's own behavior.
// The wasm focus read below is the only production caller and it is compiled
// out on the host, so a host build sees this as dead outside its tests.
#[cfg_attr(not(target_arch = "wasm32"), allow(dead_code))]
fn is_app_key_surface(tag: &str, id: &str) -> bool {
    if id == APP_ROOT_ID || id == CANVAS_ID {
        return true;
    }
    // Nothing focused: focus sits at the document default, where no element
    // owns a default action, so there is none to take away.
    matches!(tag.to_ascii_uppercase().as_str(), "BODY" | "HTML")
}

/// Does focus rest on one of the app's own keyboard surfaces?
///
/// The guard on suppressing a key's browser default: the default action of a
/// key belongs to whatever element has focus, so the app may claim it only
/// where the focused element has no default action of its own. See
/// [`is_app_key_surface`] for why this is an allowlist.
fn focus_on_app_surface() -> bool {
    #[cfg(target_arch = "wasm32")]
    {
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            return match doc.active_element() {
                Some(el) => is_app_key_surface(&el.tag_name(), &el.id()),
                // No active element at all — as with body focus, nothing owns
                // the key.
                None => true,
            };
        }
    }
    // Native builds have no browser default action to suppress.
    false
}

/// Check if any specific element currently holds focus (i.e. not just
/// the document body fallback). The app-wide Tab handler uses this to
/// decide whether to call preventDefault — if a real element has
/// focus, let the browser walk Tab to the next focusable widget; only
/// run our panel-cycling code when no widget is focused. The wrapper
/// div in App::render carries tabindex=0 so it counts here too — Tab
/// from the wrapper advances into the first dock widget naturally
/// instead of getting trapped by the panel-cycling intercept.
fn focus_on_widget() -> bool {
    #[cfg(target_arch = "wasm32")]
    {
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            if let Some(el) = doc.active_element() {
                let tag = el.tag_name().to_uppercase();
                // Body / HTML is the default focus when nothing else
                // has it — treat that as "no widget focused" so the
                // panel cycle fires from a cold start. Everything else
                // (inputs, buttons, .jas-focusable divs, the app
                // wrapper with tabindex=0) is a focusable widget the
                // browser should walk Tab through.
                return !matches!(tag.as_str(), "BODY" | "HTML");
            }
        }
    }
    false
}

/// Build the `onkeydown` closure for the main application.
pub(crate) fn make_keydown_handler(
    act: Rc<RefCell<dyn FnMut(Box<dyn FnOnce(&mut AppState)>)>>,
    app: Rc<RefCell<AppState>>,
    revision: Signal<u64>,
    dialog_sig: Signal<Option<crate::interpreter::dialog_view::DialogState>>,
) -> impl FnMut(Event<KeyboardData>) {
    let app_for_keys = app;
    let revision_for_keys = revision;
    move |evt: Event<KeyboardData>| {
        let key = evt.data().key();
        let mods = evt.data().modifiers();
        let cmd = mods.meta() || mods.ctrl();

        // If a text input / textarea / select has DOM focus, let it
        // handle non-modifier keys before any in-canvas tool session
        // claims them. Otherwise clicking a panel field while a Type
        // Tool session is open would route the keystroke into the
        // canvas instead of the panel input. Cmd/Ctrl shortcuts
        // (Cmd+Z, Cmd+C, …) still pass through to the app handler.
        if event_targets_input(&evt) && !cmd {
            return;
        }

        // Enter and Escape are keys this app acts on: below, both commit or
        // cancel the active tool's session, and Escape steps out of mask
        // isolation / mask editing. The other keys this handler claims also
        // suppress the browser's default action — the Cmd chords, Tab
        // panel-cycling, every key the text-session path just below consumes —
        // while these two did not. Suppress it here too, so a key the app
        // handles is consistently a key the browser does not also act on.
        //
        // BUT ONLY ON THE APP'S OWN KEYBOARD SURFACE, and that gate is the
        // load-bearing part. The default action of a key belongs to whatever
        // element has focus, so the app may claim it only where the focused
        // element has no default action of its own. Both halves of that law
        // were MEASURED on this app, not assumed:
        //
        //   * a focused <button> — a dialog's OK, a dialog's close X, a
        //     pane Restore button (app.rs) — is activated by Enter NATIVELY.
        //     (Document tabs are non-focusable divs, so they are not in this
        //     set.) Suppressing
        //     the default while one has focus fires no click at all: File ▸
        //     Document Setup with OK focused reported defaultPrevented=true,
        //     zero click events, and the dialog would not close from the
        //     keyboard. (`scripts/gui_checks.py::button_enter_activates` pins
        //     exactly this, and `--regress enter_default_stolen` re-injects the
        //     over-broad claim.)
        //   * a focused field commits through its `change` event, and in Chrome
        //     that event is part of the DEFAULT ACTION of the Enter keypress:
        //     with the default prevented, a length input keeps the raw text "3"
        //     and no `change` ever fires, where an untouched Enter commits and
        //     the field redisplays "3 pt".
        //
        // The gate covers both, and covers the Cmd/Ctrl+Enter field chords that
        // KEYBOARD_SHORTCUTS.md §Transform panel specifies (Shift/Alt/Ctrl +
        // Enter apply a value with the field focused) — those skip the
        // input-focus return above, because it exempts `!cmd` only, and reach
        // here with a field focused, where the gate declines.
        if matches!(key, Key::Enter | Key::Escape) && focus_on_app_surface() {
            evt.prevent_default();
        }

        // If the active tool is in a text-editing session, route the
        // event there first. The tool's `on_key_event` consumes printable
        // characters, navigation, deletion, and the in-session shortcuts
        // (Cmd+A/C/X/Z). Cmd+V still goes through the async clipboard
        // path below; we then call `paste_text` on the tool.
        let tool_captures = {
            let st = app_for_keys.borrow();
            st.tab().and_then(|tab| {
                tab.tools.get(&st.active_tool).map(|t| t.captures_keyboard())
            }).unwrap_or(false)
        };
        if tool_captures {
            // Cmd+V is handled by the async clipboard path so the tool
            // can receive the actual text.
            let is_paste = (matches!(key, Key::Character(ref c) if c == "v" || c == "V")) && cmd;
            if !is_paste {
                let key_str: String = match &key {
                    Key::Character(c) => c.clone(),
                    Key::Enter => "Enter".to_string(),
                    Key::Escape => "Escape".to_string(),
                    Key::Backspace => "Backspace".to_string(),
                    Key::Delete => "Delete".to_string(),
                    Key::ArrowLeft => "ArrowLeft".to_string(),
                    Key::ArrowRight => "ArrowRight".to_string(),
                    Key::ArrowUp => "ArrowUp".to_string(),
                    Key::ArrowDown => "ArrowDown".to_string(),
                    Key::Home => "Home".to_string(),
                    Key::End => "End".to_string(),
                    Key::Tab => "Tab".to_string(),
                    _ => String::new(),
                };
                if !key_str.is_empty() {
                    evt.prevent_default();
                    let km = crate::tools::tool::KeyMods {
                        shift: mods.shift(),
                        ctrl: mods.ctrl(),
                        alt: mods.alt(),
                        meta: mods.meta(),
                    };
                    (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                        let kind = st.active_tool;
                        if let Some(tab) = st.tab_mut()
                            && let Some(tool) = tab.tools.get_mut(&kind) {
                                tool.on_key_event(&mut tab.model, &key_str, km);
                            }
                    }));
                    return;
                }
            } else {
                evt.prevent_default();
                clipboard_read_and_paste(
                    app_for_keys.clone(),
                    revision_for_keys,
                    0.0,
                    false,
                );
                return;
            }
        }

        match key {
            // --- Modifier-key tracking for tools ---
            // Modifier keys (Alt, Shift, Ctrl, Meta) by themselves don't
            // dispatch through the standard tool key path, but tools
            // that flip cursor / overlay state on modifier press want
            // to know. Route bare Alt / Shift / Ctrl / Meta down to the
            // active tool's on_keydown handler so YAML can react. The
            // matching keyup case is in `make_keyup_handler`.
            Key::Alt | Key::Shift | Key::Control | Key::Meta => {
                let key_str: String = match &key {
                    Key::Alt     => "Alt".into(),
                    Key::Shift   => "Shift".into(),
                    Key::Control => "Control".into(),
                    Key::Meta    => "Meta".into(),
                    _            => String::new(),
                };
                let km = crate::tools::tool::KeyMods {
                    shift: mods.shift(),
                    ctrl: mods.ctrl(),
                    alt: mods.alt(),
                    meta: mods.meta(),
                };
                (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                    let kind = st.active_tool;
                    if let Some(tab) = st.tab_mut()
                        && let Some(tool) = tab.tools.get_mut(&kind) {
                            tool.on_key_event(&mut tab.model, &key_str, km);
                        }
                }));
            }
            // --- Panel focus navigation ---
            // Tab on a widget (input, button, .jas-focusable div) is
            // for browser-native focus traversal — let it through. Only
            // intercept Tab for panel-cycling when focus is on the
            // canvas / body, where there's no widget to walk to.
            Key::Tab if !tool_captures && !focus_on_widget() => {
                evt.prevent_default();
                if mods.shift() {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.workspace_layout.focus_prev_panel();
                    }));
                } else {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.workspace_layout.focus_next_panel();
                    }));
                }
            }
            // --- Modifier shortcuts ---
            Key::Character(ref c) if (c == "z" || c == "Z") && cmd => {
                evt.prevent_default();
                if mods.shift() {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            // Recorder: history nav segments an open
                            // gesture case (pre-nav doc is the oracle).
                            crate::recorder::hooks::history_nav(&tab.model);
                            tab.model.redo();
                        }
                    }));
                } else {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            crate::recorder::hooks::history_nav(&tab.model);
                            tab.model.undo();
                        }
                    }));
                }
            }
            Key::Character(ref c) if (c == "c" || c == "C") && cmd => {
                evt.prevent_default();
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    if st.tab().is_none() { return; }
                    // The SYSTEM clipboard is the only clipboard (D4/D5,
                    // ratified 2026-07-28). This site used to also snapshot the
                    // selection into `TabState.clipboard`; see `TabState` for
                    // why that buffer is gone.
                    if let Some(svg) = selection_to_svg(st) {
                        clipboard_write(svg);
                    }
                }));
            }
            Key::Character(ref c) if (c == "x" || c == "X") && cmd => {
                evt.prevent_default();
                // Reference-aware cut (warn-then-orphan). Cut is
                // copy-to-clipboard + delete, so it can orphan live
                // instances exactly like delete; gate it identically to the
                // Delete/Backspace handler. Empty -> cut inline exactly as
                // before (copy + snapshot + delete, no dialog). Non-empty ->
                // open the confirm dialog with the orphan count and return
                // WITHOUT mutating the clipboard or document; the dialog's
                // Cut button runs copy + snapshot + delete_selection, so
                // Cancel is a true no-op. Selection is left intact so the OK
                // action cuts the same elements.
                let orphan_count: usize = {
                    let st = app_for_keys.borrow();
                    match st.tab() {
                        Some(tab) => {
                            let doc = tab.model.document();
                            let paths: Vec<Vec<usize>> = doc
                                .selection
                                .iter()
                                .map(|es| es.path.clone())
                                .collect();
                            crate::document::dependency_index::orphaned_references(
                                doc, &paths,
                            )
                            .len()
                        }
                        None => 0,
                    }
                };
                if orphan_count == 0 {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.tab().is_none() { return; }
                        // Copy to the SYSTEM clipboard (the only clipboard —
                        // D4/D5, see `TabState`), then delete.
                        if let Some(svg) = selection_to_svg(st) {
                            clipboard_write(svg);
                        }
                        let Some(tab) = st.tab_mut() else { return; };
                        crate::document::op_apply::journal_delete_selection(
                            &mut tab.model, "cut_selection");
                    }));
                } else {
                    let live_state = {
                        let st = app_for_keys.borrow();
                        crate::workspace::dock_panel::build_live_state_map(&st)
                    };
                    let mut params = serde_json::Map::new();
                    params.insert("count".to_string(), serde_json::json!(orphan_count));
                    let mut sig = dialog_sig;
                    crate::interpreter::dialog_view::open_dialog(
                        &mut sig,
                        "cut_orphan_confirm",
                        &params,
                        &live_state,
                    );
                }
            }
            Key::Character(ref c) if (c == "v" || c == "V") && cmd => {
                evt.prevent_default();
                let offset = if mods.shift() { 0.0 } else { PASTE_OFFSET };
                // Try async clipboard read first, fall back to internal
                // R2: the keyboard paste is always the FLATTENING one. R3 is
                // menu-only by design (see workspace/shortcuts.yaml).
                clipboard_read_and_paste(
                    app_for_keys.clone(),
                    revision_for_keys,
                    offset,
                    false,
                );
            }
            Key::Character(ref c) if (c == "a" || c == "A") && cmd => {
                evt.prevent_default();
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    if let Some(tab) = st.tab_mut() { Controller::select_all(&mut tab.model); }
                }));
            }
            Key::Character(ref c) if (c == "2") && cmd => {
                evt.prevent_default();
                if mods.alt() {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.with_txn(|m| Controller::unlock_all(m));
                        }
                    }));
                } else {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.with_txn(|m| Controller::lock_selection(m));
                        }
                    }));
                }
            }
            Key::Character(ref c) if (c == "3") && cmd => {
                evt.prevent_default();
                if mods.alt() {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.with_txn(|m| Controller::show_all(m));
                        }
                    }));
                } else {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.with_txn(|m| Controller::hide_selection(m));
                        }
                    }));
                }
            }
            Key::Character(ref c) if (c == "s" || c == "S") && cmd => {
                evt.prevent_default();
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    if let Some(tab) = st.tab_mut() {
                        let svg = document_to_svg(tab.model.document());
                        let filename = if tab.model.filename.ends_with(".svg") {
                            tab.model.filename.clone()
                        } else {
                            format!("{}.svg", tab.model.filename)
                        };
                        download_file(&filename, &svg);
                        tab.model.mark_saved();
                    }
                }));
            }
            Key::Character(ref c) if (c == "o" || c == "O") && cmd => {
                evt.prevent_default();
                open_file_dialog(app_for_keys.clone(), revision_for_keys);
            }
            Key::Character(ref c) if (c == "n" || c == "N") && cmd => {
                evt.prevent_default();
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    st.add_tab(super::app_state::TabState::new());
                }));
            }
            Key::Character(ref c) if (c == "w" || c == "W") && cmd => {
                evt.prevent_default();
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    let idx = st.active_tab;
                    st.close_tab(idx);
                }));
            }
            Key::Character(ref c) if (c == "g" || c == "G") && cmd => {
                evt.prevent_default();
                if mods.shift() {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.with_txn(|m| Controller::ungroup_selection(m));
                        }
                    }));
                } else {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.with_txn(|m| Controller::group_selection(m));
                        }
                    }));
                }
            }
            // --- View shortcuts (Ctrl+=/-, Ctrl+0, Ctrl+Alt+0, Ctrl+1)
            // ---
            // Per ZOOM_TOOL.md §Keyboard shortcuts and actions.
            Key::Character(ref c) if (c == "=" || c == "+") && cmd => {
                evt.prevent_default();
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    let empty = serde_json::Map::new();
                    crate::interpreter::renderer::dispatch_action(
                        "zoom_in", &empty, st,
                    );
                }));
            }
            Key::Character(ref c) if (c == "-" || c == "_") && cmd => {
                evt.prevent_default();
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    let empty = serde_json::Map::new();
                    crate::interpreter::renderer::dispatch_action(
                        "zoom_out", &empty, st,
                    );
                }));
            }
            // Cmd+0 / Cmd+Alt+0 — fit active artboard / fit all
            // artboards. macOS rewrites Option+0 to the degree
            // sign "º", and other layouts produce other characters,
            // so we can't just match on "0". Match by Code instead
            // -- KeyCode 48 is the digit-0 row (always the same
            // physical key regardless of modifiers / layout).
            Key::Character(ref c) if (c == "0" || c == "º") && cmd => {
                evt.prevent_default();
                if mods.alt() {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        let empty = serde_json::Map::new();
                        crate::interpreter::renderer::dispatch_action(
                            "fit_all_artboards", &empty, st,
                        );
                    }));
                } else {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        let empty = serde_json::Map::new();
                        crate::interpreter::renderer::dispatch_action(
                            "fit_active_artboard", &empty, st,
                        );
                    }));
                }
            }
            Key::Character(ref c) if c == "1" && cmd => {
                evt.prevent_default();
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    let empty = serde_json::Map::new();
                    crate::interpreter::renderer::dispatch_action(
                        "zoom_to_actual_size", &empty, st,
                    );
                }));
            }
            // --- Tool shortcuts ---
            // The hardcoded per-tool arms were replaced by a single
            // bundle-driven fallback at the end of this match (§5 rec 3):
            // it normalizes the character + modifiers into a KeyChord and
            // resolves it against the shared `shortcuts` table via
            // `resolve_key`. Placing it at the END keeps the special-character
            // arms above (Space, d/x/X) ahead of it. See the `Key::Character
            // (ref c) if !cmd` arm below.
            // --- Spacebar pass-through to Hand (HAND_TOOL.md
            // §Spacebar pass-through) ---
            // On Space-down, if Hand isn't already active, save the
            // current tool to prior_tool_for_spacebar and switch to
            // Hand. Suppressed when a text input has focus (handled
            // earlier in this function via event_targets_input). The
            // matching keyup is in make_keyup_handler.
            Key::Character(ref c) if c == " " => {
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    if st.active_tool == ToolKind::Hand { return; }
                    if st.prior_tool_for_spacebar.is_some() { return; }
                    st.prior_tool_for_spacebar = Some(st.active_tool);
                    st.set_tool(ToolKind::Hand);
                }));
            }
            Key::Escape | Key::Enter => {
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    let kind = st.active_tool;
                    if let Some(tab) = st.tab_mut() {
                        if let Some(tool) = tab.tools.get_mut(&kind) {
                            tool.on_key(&mut tab.model, "Escape");
                        }
                        // OPACITY.md §Preview interactions: Escape
                        // exits mask-isolation first (if active);
                        // otherwise exits mask-editing mode back to
                        // content-mode.
                        use crate::document::model::EditingTarget;
                        if tab.model.mask_isolation_path.is_some() {
                            tab.model.mask_isolation_path = None;
                        } else if let EditingTarget::Mask(_) = tab.model.editing_target {
                            tab.model.editing_target = EditingTarget::Content;
                        }
                    }
                }));
            }
            // --- Fill/Stroke shortcuts ---
            Key::Character(ref c) if c == "d" || c == "D" => {
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    st.reset_fill_stroke_defaults();
                }));
            }
            Key::Character(ref c) if c == "x" && !cmd => {
                // Toggle fill/stroke stacking
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    st.toggle_fill_on_top();
                }));
            }
            Key::Character(ref c) if c == "X" && !cmd => {
                // Shift+X: swap fill/stroke colors
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    st.swap_fill_stroke();
                }));
            }
            Key::Delete | Key::Backspace => {
                // Reference-aware delete (warn-then-orphan). Phase A:
                // compute the pure orphaned_references predicate over the
                // current selection. Empty -> delete inline exactly as
                // before (no dialog). Non-empty -> open the confirm dialog
                // with the orphan count and return WITHOUT mutating; the
                // dialog's Delete button runs the snapshot + delete_selection.
                // Selection is left intact so the OK action deletes the same
                // elements.
                let orphan_count: usize = {
                    let st = app_for_keys.borrow();
                    match st.tab() {
                        Some(tab) => {
                            let doc = tab.model.document();
                            let paths: Vec<Vec<usize>> = doc
                                .selection
                                .iter()
                                .map(|es| es.path.clone())
                                .collect();
                            crate::document::dependency_index::orphaned_references(
                                doc, &paths,
                            )
                            .len()
                        }
                        None => 0,
                    }
                };
                if orphan_count == 0 {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            crate::document::op_apply::journal_delete_selection(
                                &mut tab.model, "delete_selection");
                        }
                    }));
                } else {
                    let live_state = {
                        let st = app_for_keys.borrow();
                        crate::workspace::dock_panel::build_live_state_map(&st)
                    };
                    let mut params = serde_json::Map::new();
                    params.insert("count".to_string(), serde_json::json!(orphan_count));
                    let mut sig = dialog_sig;
                    crate::interpreter::dialog_view::open_dialog(
                        &mut sig,
                        "delete_orphan_confirm",
                        &params,
                        &live_state,
                    );
                }
            }
            // --- Tool shortcuts (bundle-driven, §5 rec 3) ---
            // Any bare/Shift character key not consumed by a special arm
            // above is normalized into a KeyChord and resolved against the
            // shared bundle `shortcuts` table. The `!cmd` guard leaves
            // Ctrl/Meta menu chords to their own arms; only `select_tool`
            // results are acted on (menu/fill verbs are handled above), and
            // the resolved tool id is dispatched through the same
            // `select_tool` action the toolbar uses — so a single table now
            // drives both the toolbar and the keyboard.
            Key::Character(ref c) if !cmd => {
                let chord = crate::workspace::resolve_key::KeyChord::new(
                    c,
                    false,
                    mods.shift(),
                    mods.alt(),
                    false,
                );
                // Recorder seam hook (dormant unless armed): the KEY
                // seam captures the normalized chord at the resolution
                // point, whatever it resolves to (incl. null).
                crate::recorder::hooks::key_event(&chord);
                if let Some(resolved) = crate::workspace::resolve_key::resolve_key(&chord) {
                    if resolved.action == "select_tool" {
                        let params = resolved.params.clone();
                        (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                            crate::interpreter::renderer::dispatch_action(
                                "select_tool",
                                &params,
                                st,
                            );
                        }));
                    }
                }
            }
            _ => {}
        }
    }
}

/// Build the `onkeyup` closure for the main application.
pub(crate) fn make_keyup_handler(
    act: Rc<RefCell<dyn FnMut(Box<dyn FnOnce(&mut AppState)>)>>,
) -> impl FnMut(Event<KeyboardData>) {
    move |evt: Event<KeyboardData>| {
        let key = evt.data().key();
        match key {
            Key::Character(ref c) if c == " " => {
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    // Spacebar pass-through restore: if a prior tool
                    // was saved on Space-down, restore it on
                    // Space-up. Per HAND_TOOL.md §Spacebar
                    // pass-through.
                    if let Some(prior) = st.prior_tool_for_spacebar.take() {
                        st.set_tool(prior);
                        return;
                    }
                    let kind = st.active_tool;
                    if let Some(tab) = st.tab_mut()
                        && let Some(tool) = tab.tools.get_mut(&kind) {
                            tool.on_key_up(&mut tab.model, " ");
                        }
                }));
            }
            // Mirror the keydown path: route bare modifier-key release
            // to the active tool so cursor / overlay state can clear
            // (e.g. Zoom cursor flips back to "+" on Alt release).
            Key::Alt | Key::Shift | Key::Control | Key::Meta => {
                let key_str: String = match &key {
                    Key::Alt     => "Alt".into(),
                    Key::Shift   => "Shift".into(),
                    Key::Control => "Control".into(),
                    Key::Meta    => "Meta".into(),
                    _            => String::new(),
                };
                (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                    let kind = st.active_tool;
                    if let Some(tab) = st.tab_mut()
                        && let Some(tool) = tab.tools.get_mut(&kind) {
                            tool.on_key_up(&mut tab.model, &key_str);
                        }
                }));
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // The allowlist's two members, and the reason each is on it.
    #[test]
    fn the_root_wrapper_and_the_canvas_are_app_surfaces() {
        assert!(is_app_key_surface("DIV", APP_ROOT_ID));
        assert!(is_app_key_surface("CANVAS", CANVAS_ID));
    }

    #[test]
    fn no_focused_element_is_an_app_surface() {
        // Body / HTML is where focus sits before anything claims it; no
        // element owns a default action there, so there is none to take.
        assert!(is_app_key_surface("BODY", ""));
        assert!(is_app_key_surface("HTML", ""));
        assert!(is_app_key_surface("body", ""));   // tag case is normalized
    }

    // THE REGRESSION PIN. A focused <button> activates on Enter natively —
    // that is how the keyboard clicks a dialog's OK, a dialog's close X, a
    // native button (e.g. the pane Restore button). NOT an app surface, so the
    // handler must leave
    // Enter's default alone while it has focus.
    #[test]
    fn a_focused_button_is_not_an_app_surface() {
        assert!(!is_app_key_surface("BUTTON", ""));          // dialog OK/Cancel
        assert!(!is_app_key_surface("BUTTON", "pane_restore")); // a native button
        assert!(!is_app_key_surface("A", "help_link"));      // links activate too
        assert!(!is_app_key_surface("SUMMARY", ""));         // and <details>
    }

    #[test]
    fn focused_fields_are_not_app_surfaces() {
        // The same law that keeps a field's commit-on-Enter working: Chrome
        // delivers the field's `change` as part of Enter's default action.
        assert!(!is_app_key_surface("INPUT", "stk_weight"));
        assert!(!is_app_key_surface("TEXTAREA", ""));
        assert!(!is_app_key_surface("SELECT", "stk_end_arrowhead"));
    }

    #[test]
    fn a_focusable_panel_div_is_not_an_app_surface() {
        // Icon-buttons are focusable divs that synthesize their own click.
        // They are not on the allowlist: only the two named surfaces are, so
        // a widget kind added later cannot silently lose its own key handling.
        assert!(!is_app_key_surface("DIV", "stk_link_arrowhead_scale"));
        assert!(!is_app_key_surface("DIV", ""));
    }
}
