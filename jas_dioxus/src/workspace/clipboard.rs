//! Clipboard and file I/O functions extracted from `app.rs`.
//!
//! These are free functions that take `Rc<RefCell<AppState>>` and `Signal<u64>`
//! as parameters; they do not use Dioxus context.

use std::cell::RefCell;
use std::rc::Rc;

use dioxus::prelude::*;
use wasm_bindgen::prelude::*;
use wasm_bindgen::JsCast;

use super::app_state::{AppState, TabState};
use crate::document::document::Document;
use crate::document::document::ElementSelection;
use crate::document::model::Model;
use crate::geometry::element::{translate_element, CommonProps, LayerElem, Element as GeoElement};
use crate::geometry::svg::{document_to_svg, svg_to_document};

/// Write text to the system clipboard (fire-and-forget async).
pub(crate) fn clipboard_write(text: String) {
    if let Some(_window) = web_sys::window() {
        // Fire and forget — spawn to avoid blocking
        wasm_bindgen_futures::spawn_local(async move {
            if let Some(window) = web_sys::window() {
                let _ = wasm_bindgen_futures::JsFuture::from(
                    window.navigator().clipboard().write_text(&text)
                ).await;
            }
        });
    }
}

/// Read text from the system clipboard, then call the callback with it.
pub(crate) fn clipboard_read_and_paste(app: Rc<RefCell<AppState>>, mut revision: Signal<u64>, offset: f64) {
    wasm_bindgen_futures::spawn_local(async move {
        let clipboard_text = async {
            let window = web_sys::window()?;
            let clipboard = window.navigator().clipboard();
            let promise = clipboard.read_text();
            let val = wasm_bindgen_futures::JsFuture::from(promise).await.ok()?;
            val.as_string()
        }.await;

        let mut st = app.borrow_mut();
        if st.tab().is_none() {
            return;
        }

        // If a tool is in a text-editing session, send the plain text there.
        let active_kind = st.active_tool;
        let editing = st
            .tab()
            .and_then(|tab| tab.tools.get(&active_kind).map(|t| t.is_editing()))
            .unwrap_or(false);
        if editing
            && let Some(text) = clipboard_text.clone() {
                let Some(tab) = st.tab_mut() else { return; };
                if let Some(tool) = tab.tools.get_mut(&active_kind)
                    && tool.paste_text(&mut tab.model, &text) {
                        drop(st);
                        revision += 1;
                        return;
                    }
            }

        let Some(tab) = st.tab_mut() else { return; };

        // Check if clipboard contains SVG
        if let Some(text) = &clipboard_text {
            let trimmed = text.trim();
            if trimmed.starts_with("<?xml") || trimmed.starts_with("<svg") {
                let pasted_doc = svg_to_document(text);
                tab.model.snapshot();
                let mut doc = tab.model.document().clone();
                let idx = doc.selected_layer;
                let mut new_selection = Vec::new();
                let base = doc.layers[idx].children().map_or(0, |c| c.len());
                let mut j = 0;
                for layer in &pasted_doc.layers {
                    if let Some(children) = layer.children() {
                        for child in children {
                            let translated = translate_element(child, offset, offset);
                            let path = vec![idx, base + j];
                            new_selection.push(ElementSelection::all(path));
                            if let Some(layer_children) = doc.layers[idx].children_mut() {
                                layer_children.push(Rc::new(translated));
                            }
                            j += 1;
                        }
                    }
                }
                if j > 0 {
                    doc.selection = new_selection;
                    tab.model.set_document(doc);
                    drop(st);
                    revision += 1;
                    return;
                }
            }
        }

        // Fall back to internal clipboard
        if tab.clipboard.is_empty() {
            return;
        }
        tab.model.snapshot();
        let mut doc = tab.model.document().clone();
        let idx = doc.selected_layer;
        let mut new_selection = Vec::new();
        let base = doc.layers[idx].children().map_or(0, |c| c.len());
        for (j, elem) in tab.clipboard.iter().enumerate() {
            let translated = translate_element(elem, offset, offset);
            let path = vec![idx, base + j];
            new_selection.push(ElementSelection::all(path));
            if let Some(children) = doc.layers[idx].children_mut() {
                children.push(Rc::new(translated));
            }
        }
        doc.selection = new_selection;
        tab.model.set_document(doc);
        drop(st);
        revision += 1;
    });
}

/// Build SVG string from selected elements for clipboard export.
pub(crate) fn selection_to_svg(st: &AppState) -> Option<String> {
    let tab = st.tab()?;
    let doc = tab.model.document();
    if doc.selection.is_empty() {
        return None;
    }
    let mut elements = Vec::new();
    for es in &doc.selection {
        if let Some(elem) = doc.get_element(&es.path) {
            elements.push(elem.clone());
        }
    }
    if elements.is_empty() {
        return None;
    }
    let temp_doc = Document {
        layers: vec![GeoElement::Layer(LayerElem {
            children: elements.into_iter().map(Rc::new).collect(),
            name: String::new(),
            common: CommonProps::default(),
        })],
        selected_layer: 0,
        selection: Vec::new(),
    };
    Some(document_to_svg(&temp_doc))
}

/// Download a string as a file in the browser.
pub(crate) fn download_file(filename: &str, content: &str) {
    let window = match web_sys::window() {
        Some(w) => w,
        None => return,
    };
    let document = match window.document() {
        Some(d) => d,
        None => return,
    };
    let parts = js_sys::Array::new();
    parts.push(&content.into());
    let opts = web_sys::BlobPropertyBag::new();
    opts.set_type("image/svg+xml");
    let blob = match web_sys::Blob::new_with_str_sequence_and_options(&parts, &opts) {
        Ok(b) => b,
        Err(_) => return,
    };
    let url = match web_sys::Url::create_object_url_with_blob(&blob) {
        Ok(u) => u,
        Err(_) => return,
    };
    let a: web_sys::HtmlAnchorElement = match document.create_element("a") {
        Ok(el) => el.unchecked_into(),
        Err(_) => return,
    };
    a.set_href(&url);
    a.set_download(filename);
    a.click();
    let _ = web_sys::Url::revoke_object_url(&url);
}

/// Trigger a file open dialog and load the file into a new tab.
pub(crate) fn open_file_dialog(app: Rc<RefCell<AppState>>, revision: Signal<u64>) {
    let window = match web_sys::window() {
        Some(w) => w,
        None => return,
    };
    let document = match window.document() {
        Some(d) => d,
        None => return,
    };
    let input: web_sys::HtmlInputElement = match document.create_element("input") {
        Ok(el) => el.unchecked_into(),
        Err(_) => return,
    };
    input.set_type("file");
    input.set_attribute("accept", ".svg,image/svg+xml").ok();

    let app2 = app.clone();
    let revision2 = revision;
    let input2 = input.clone();
    let onchange = Closure::wrap(Box::new(move |_evt: web_sys::Event| {
        let files = match input2.files() {
            Some(f) => f,
            None => return,
        };
        let file = match files.get(0) {
            Some(f) => f,
            None => return,
        };
        let filename = file.name();
        let reader = match web_sys::FileReader::new() {
            Ok(r) => r,
            Err(_) => return,
        };
        let reader2 = reader.clone();
        let app3 = app2.clone();
        let mut revision3 = revision2;
        let onload = Closure::wrap(Box::new(move |_evt: web_sys::Event| {
            let result = match reader2.result() {
                Ok(r) => r,
                Err(_) => return,
            };
            let text = match result.as_string() {
                Some(s) => s,
                None => return,
            };
            let doc = svg_to_document(&text);
            let model = Model::new(doc, Some(filename.clone()));
            let mut st = app3.borrow_mut();
            st.add_tab(TabState::with_model(model));
            drop(st);
            revision3 += 1;
        }) as Box<dyn FnMut(web_sys::Event)>);
        reader.set_onload(Some(onload.as_ref().unchecked_ref()));
        onload.forget();
        reader.read_as_text(&file).ok();
    }) as Box<dyn FnMut(web_sys::Event)>);
    input.set_onchange(Some(onchange.as_ref().unchecked_ref()));
    onchange.forget();
    input.click();
}

/// Find the address of a panel kind in the layout (first occurrence).
pub(crate) fn find_panel(layout: &super::workspace::WorkspaceLayout, kind: super::workspace::PanelKind) -> Option<super::workspace::PanelAddr> {
    for (_, dock) in &layout.anchored {
        for (gi, group) in dock.groups.iter().enumerate() {
            if let Some(pi) = group.panels.iter().position(|&k| k == kind) {
                return Some(super::workspace::PanelAddr {
                    group: super::workspace::GroupAddr { dock_id: dock.id, group_idx: gi },
                    panel_idx: pi,
                });
            }
        }
    }
    for fd in &layout.floating {
        for (gi, group) in fd.dock.groups.iter().enumerate() {
            if let Some(pi) = group.panels.iter().position(|&k| k == kind) {
                return Some(super::workspace::PanelAddr {
                    group: super::workspace::GroupAddr { dock_id: fd.dock.id, group_idx: gi },
                    panel_idx: pi,
                });
            }
        }
    }
    None
}
