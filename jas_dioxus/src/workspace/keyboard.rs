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

/// Build the `onkeydown` closure for the main application.
pub(crate) fn make_keydown_handler(
    act: Rc<RefCell<dyn FnMut(Box<dyn FnOnce(&mut AppState)>)>>,
    app: Rc<RefCell<AppState>>,
    revision: Signal<u64>,
) -> impl FnMut(Event<KeyboardData>) {
    let app_for_keys = app;
    let revision_for_keys = revision;
    move |evt: Event<KeyboardData>| {
        let key = evt.data().key();
        let mods = evt.data().modifiers();
        let cmd = mods.meta() || mods.ctrl();

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
                );
                return;
            }
        }

        match key {
            // --- Panel focus navigation ---
            Key::Tab if !tool_captures => {
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
                        if let Some(tab) = st.tab_mut() { tab.model.redo(); }
                    }));
                } else {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() { tab.model.undo(); }
                    }));
                }
            }
            Key::Character(ref c) if (c == "c" || c == "C") && cmd => {
                evt.prevent_default();
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    if st.tab().is_none() { return; }
                    // Write SVG to system clipboard
                    if let Some(svg) = selection_to_svg(st) {
                        clipboard_write(svg);
                    }
                    // Also update internal clipboard
                    let elements = {
                        let Some(tab) = st.tab() else { return; };
                        let doc = tab.model.document();
                        doc.selection.iter()
                            .filter_map(|es| doc.get_element(&es.path).cloned())
                            .collect::<Vec<_>>()
                    };
                    let Some(tab) = st.tab_mut() else { return; };
                    tab.clipboard = elements;
                }));
            }
            Key::Character(ref c) if (c == "x" || c == "X") && cmd => {
                evt.prevent_default();
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    if st.tab().is_none() { return; }
                    // Write SVG to system clipboard
                    if let Some(svg) = selection_to_svg(st) {
                        clipboard_write(svg);
                    }
                    // Update internal clipboard and delete
                    let elements = {
                        let Some(tab) = st.tab() else { return; };
                        let doc = tab.model.document();
                        doc.selection.iter()
                            .filter_map(|es| doc.get_element(&es.path).cloned())
                            .collect::<Vec<_>>()
                    };
                    let Some(tab) = st.tab_mut() else { return; };
                    tab.clipboard = elements;
                    tab.model.snapshot();
                    let new_doc = tab.model.document().delete_selection();
                    tab.model.set_document(new_doc);
                }));
            }
            Key::Character(ref c) if (c == "v" || c == "V") && cmd => {
                evt.prevent_default();
                let offset = if mods.shift() { 0.0 } else { PASTE_OFFSET };
                // Try async clipboard read first, fall back to internal
                clipboard_read_and_paste(
                    app_for_keys.clone(),
                    revision_for_keys,
                    offset,
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
                            tab.model.snapshot();
                            Controller::unlock_all(&mut tab.model);
                        }
                    }));
                } else {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.snapshot();
                            Controller::lock_selection(&mut tab.model);
                        }
                    }));
                }
            }
            Key::Character(ref c) if (c == "3") && cmd => {
                evt.prevent_default();
                if mods.alt() {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.snapshot();
                            Controller::show_all(&mut tab.model);
                        }
                    }));
                } else {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.snapshot();
                            Controller::hide_selection(&mut tab.model);
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
                            tab.model.snapshot();
                            Controller::ungroup_selection(&mut tab.model);
                        }
                    }));
                } else {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.snapshot();
                            Controller::group_selection(&mut tab.model);
                        }
                    }));
                }
            }
            // --- View shortcuts (Ctrl+=/-, Ctrl+0) ---
            Key::Character(ref c) if (c == "=" || c == "+") && cmd => {
                evt.prevent_default();
                log::info!("[action] zoom_in (tier 3 stub)");
            }
            Key::Character(ref c) if (c == "-" || c == "_") && cmd => {
                evt.prevent_default();
                log::info!("[action] zoom_out (tier 3 stub)");
            }
            Key::Character(ref c) if c == "0" && cmd => {
                evt.prevent_default();
                log::info!("[action] fit_in_window (tier 3 stub)");
            }
            // --- Tool shortcuts (bare keys, no modifier) ---
            Key::Character(ref c) if c == "v" || c == "V" => {
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    st.set_tool(ToolKind::Selection);
                }));
            }
            Key::Character(ref c) if c == "a" || c == "A" => {
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    st.set_tool(ToolKind::PartialSelection);
                }));
            }
            Key::Character(ref c) if c == "p" || c == "P" => {
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    st.set_tool(ToolKind::Pen);
                }));
            }
            Key::Character(ref c) if c == "=" || c == "+" => {
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    st.set_tool(ToolKind::AddAnchorPoint);
                }));
            }
            Key::Character(ref c) if c == "-" || c == "_" => {
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    st.set_tool(ToolKind::DeleteAnchorPoint);
                }));
            }
            Key::Character(ref c) if c == "C" => {
                // Shift+C for Anchor Point tool
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    st.set_tool(ToolKind::AnchorPoint);
                }));
            }
            Key::Character(ref c) if c == "n" || c == "N" => {
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    st.set_tool(ToolKind::Pencil);
                }));
            }
            Key::Character(ref c) if c == "E" => {
                // Shift+E for Path Eraser tool
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    st.set_tool(ToolKind::PathEraser);
                }));
            }
            Key::Character(ref c) if c == "t" || c == "T" => {
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    st.set_tool(ToolKind::Type);
                }));
            }
            Key::Character(ref c) if c == "l" || c == "L" => {
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    st.set_tool(ToolKind::Line);
                }));
            }
            Key::Character(ref c) if c == "m" || c == "M" => {
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    st.set_tool(ToolKind::Rect);
                }));
            }
            Key::Escape | Key::Enter => {
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    let kind = st.active_tool;
                    if let Some(tab) = st.tab_mut()
                        && let Some(tool) = tab.tools.get_mut(&kind) {
                            tool.on_key(&mut tab.model, "Escape");
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
                (act.borrow_mut())(Box::new(|st: &mut AppState| {
                    if let Some(tab) = st.tab_mut() {
                        tab.model.snapshot();
                        let new_doc = tab.model.document().delete_selection();
                        tab.model.set_document(new_doc);
                    }
                }));
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
                    let kind = st.active_tool;
                    if let Some(tab) = st.tab_mut()
                        && let Some(tool) = tab.tools.get_mut(&kind) {
                            tool.on_key_up(&mut tab.model, " ");
                        }
                }));
            }
            _ => {}
        }
    }
}
