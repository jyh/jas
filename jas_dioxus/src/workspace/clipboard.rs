//! Clipboard and file I/O functions extracted from `app.rs`.
//!
//! These are free functions that take `Rc<RefCell<AppState>>` and `Signal<u64>`
//! as parameters; they do not use Dioxus context.
//!
//! # Rich clipboard
//!
//! The browser's async clipboard API reliably supports only `text/plain`
//! for cross-app transfer; writing custom MIME types (such as
//! `application/x-jas-tspans`) requires user activation plus browser-
//! specific permission flows and often fails silently. To still deliver
//! cross-element rich paste within one tab, we keep an app-global
//! [`RICH_CLIPBOARD`] cache (the flat text plus the source tspan list)
//! alongside the OS clipboard's plain text. Paste flow:
//!
//! 1. System clipboard supplies the flat text string.
//! 2. If the cache's flat text matches, paste the cached tspans.
//! 3. Otherwise fall back to flat insert.
//!
//! Cross-tab / cross-app paste stays plain text; the serializers in
//! `geometry::tspan` (`tspans_to_json_clipboard` / `tspans_to_svg_fragment`)
//! are kept ready for the follow-up that wires the Web Clipboard API's
//! multi-format write once the feature-flag churn is worth it.

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
use crate::geometry::tspan::Tspan;

thread_local! {
    /// App-global cache of the last rich-copied selection. Key is the
    /// flat text of the copy; value is the tspan list with all
    /// per-range overrides preserved. Consumed on paste when the OS
    /// clipboard's flat text still matches. Unlike the session-scoped
    /// tspan clipboard on `TextEditSession`, this one survives
    /// session boundaries — copy from one Text element, end the
    /// session, click into another element, paste still preserves
    /// overrides.
    static RICH_CLIPBOARD: RefCell<Option<(String, Vec<Tspan>)>> = RefCell::new(None);
}

/// Publish a rich-clipboard payload: the flat text (mirrored to the
/// OS clipboard) plus the source tspan list. Callers cut/copy from
/// the type tool. Cross-app paste will see only the flat text; same-
/// app paste can reconstruct the tspans.
pub(crate) fn rich_clipboard_write(flat: String, tspans: Vec<Tspan>) {
    RICH_CLIPBOARD.with(|c| *c.borrow_mut() = Some((flat, tspans)));
}

/// Try to retrieve a rich-clipboard tspan list matching `flat`. Used
/// by the paste pipeline: when the OS clipboard's plain-text content
/// matches the most recent rich copy, we splice the cached tspans
/// instead of flat-inserting. Returns `None` on any mismatch.
pub(crate) fn rich_clipboard_read_matching(flat: &str) -> Option<Vec<Tspan>> {
    RICH_CLIPBOARD.with(|c| {
        c.borrow().as_ref().and_then(|(f, t)| {
            if f == flat { Some(t.clone()) } else { None }
        })
    })
}

#[cfg(test)]
pub(crate) fn _clear_rich_clipboard_for_test() {
    RICH_CLIPBOARD.with(|c| *c.borrow_mut() = None);
}

#[cfg(test)]
mod rich_clipboard_tests {
    use super::*;
    use crate::geometry::tspan::Tspan;

    fn bold(s: &str) -> Tspan {
        Tspan {
            content: s.into(),
            font_weight: Some("bold".into()),
            ..Tspan::default_tspan()
        }
    }

    #[test]
    fn write_then_read_matching_returns_tspans() {
        _clear_rich_clipboard_for_test();
        let tspans = vec![bold("X")];
        rich_clipboard_write("X".into(), tspans.clone());
        let back = rich_clipboard_read_matching("X").expect("hit");
        assert_eq!(back.len(), 1);
        assert_eq!(back[0].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn read_matching_none_for_mismatched_text() {
        _clear_rich_clipboard_for_test();
        rich_clipboard_write("foo".into(), vec![bold("foo")]);
        assert!(rich_clipboard_read_matching("bar").is_none());
    }

    #[test]
    fn read_matching_none_when_empty() {
        _clear_rich_clipboard_for_test();
        assert!(rich_clipboard_read_matching("anything").is_none());
    }

    #[test]
    fn later_write_replaces_earlier() {
        _clear_rich_clipboard_for_test();
        rich_clipboard_write("a".into(), vec![bold("a")]);
        rich_clipboard_write("b".into(), vec![bold("b")]);
        assert!(rich_clipboard_read_matching("a").is_none());
        assert_eq!(
            rich_clipboard_read_matching("b").unwrap()[0].content,
            "b"
        );
    }
}

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
