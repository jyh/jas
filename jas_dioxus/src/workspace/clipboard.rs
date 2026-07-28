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
use crate::document::model::Model;
use crate::document::op_apply::paste_fragment_into;
use crate::geometry::element::{CommonProps, LayerElem, Element as GeoElement};
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

/// THE INTERNAL CLIPBOARD, CONFIRMED — the Rust half.
///
/// `transcripts/LAYER_STRUCTURE.md` §7 admitted a blind spot: only the SVG paste
/// path had been read, and JYH's ratification rode on confirming the
/// internal-clipboard path. These are the Rust measurements.
///
/// **NAMED GAP, stated before the evidence.** The internal paste SINK —
/// `clipboard_read_and_paste`'s tail, `clipboard.rs:213-234` — is unreachable
/// from `cargo test --lib`: its body sits inside a `spawn_local` closure (a
/// wasm-only executor) over an `Rc<RefCell<AppState>>` and a Dioxus `Signal`,
/// neither constructible outside a Dioxus runtime. So the sink is established by
/// READING, and what these tests drive is the SOURCE — the payload the five copy
/// sites store — plus `translate_element`, the one helper the sink calls. That
/// split is deliberate: the payload is where the layer question is actually
/// decided, because a payload that never recorded a layer cannot have one
/// restored downstream.
///
/// The five copy sites store byte-identical payloads:
/// `keyboard.rs:327` (Cmd+C), `keyboard.rs:376` (Cmd+X), `menu_bar.rs:129`
/// (menu Cut), `menu_bar.rs:166` (menu Copy), `renderer.rs:3572`
/// (`doc.copy_selection_to_clipboard`). Each is
/// `doc.selection.iter().filter_map(|es| doc.get_element(&es.path).cloned()).collect()`
/// — reproduced verbatim in `copy_payload` below.
#[cfg(test)]
mod internal_clipboard_confirm_tests {
    use super::*;
    use crate::document::document::{Document, ElementSelection};
    // `translate_element` moved out of the module-level imports when the paste
    // sink became a thin caller (it is `paste_fragment_into`'s business now);
    // these probes still drive it directly, so they import it themselves.
    use crate::geometry::element::translate_element;
    use crate::geometry::element::{
        Color, CommonProps, Element, Fill, LayerElem, RectElem,
    };

    /// The copy payload, verbatim from the five production copy sites.
    fn copy_payload(doc: &Document) -> Vec<GeoElement> {
        doc.selection
            .iter()
            .filter_map(|es| doc.get_element(&es.path).cloned())
            .collect()
    }

    fn rect(x: f64, y: f64, id: &str) -> Element {
        Element::Rect(RectElem {
            x,
            y,
            width: 10.0,
            height: 10.0,
            rx: 0.0,
            ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
            common: CommonProps {
                id: Some(id.to_string()),
                ..CommonProps::default()
            },
            fill_gradient: None,
            stroke_gradient: None,
        })
    }

    /// Two NAMED layers, one element each, both selected — the shape the brief's
    /// central claim is about.
    fn two_layer_doc() -> Document {
        let sky = Element::Layer(LayerElem {
            children: vec![Rc::new(rect(0.0, 0.0, "r-sky"))],
            common: CommonProps {
                name: Some("Sky".to_string()),
                ..CommonProps::default()
            },
            ..LayerElem::default()
        });
        let ground = Element::Layer(LayerElem {
            children: vec![Rc::new(rect(100.0, 100.0, "r-ground"))],
            common: CommonProps {
                name: Some("Ground".to_string()),
                ..CommonProps::default()
            },
            ..LayerElem::default()
        });
        Document {
            layers: vec![sky, ground],
            selected_layer: 0,
            selection: vec![
                ElementSelection::all(vec![0, 0]),
                ElementSelection::all(vec![1, 0]),
            ],
            ..Document::default()
        }
    }

    /// THE FINDING THAT SETTLES Q2/Q3 FOR RUST, and it is settled at the SOURCE.
    /// `TabState.clipboard` is `Vec<Element>` (`app_state.rs:68`). A cross-layer
    /// copy yields two ELEMENTS and no layer at all — the payload has nowhere to
    /// record which layer each came from. So the flattening is not a choice the
    /// paste sink makes; it is already total by the time the sink runs, and no
    /// sink could undo it. The brief's central claim holds for the internal path.
    #[test]
    fn internal_copy_payload_is_flat_elements_carrying_no_layer_identity() {
        let doc = two_layer_doc();
        let payload = copy_payload(&doc);
        assert_eq!(payload.len(), 2, "expected both selected elements");
        for (i, e) in payload.iter().enumerate() {
            assert!(
                !matches!(e, Element::Layer(_)),
                "payload[{i}] is a Layer; the internal clipboard is supposed to \
                 hold elements, and a layer here would be the only way it could \
                 carry layer identity"
            );
        }
        // MANDATORY VALUE ASSERTION: say which elements, by geometry, so this
        // cannot pass on an empty or wrong-shaped payload.
        let xs: Vec<f64> = payload
            .iter()
            .map(|e| match e {
                Element::Rect(r) => r.x,
                _ => f64::NAN,
            })
            .collect();
        assert_eq!(
            xs,
            vec![0.0, 100.0],
            "payload x-coordinates {xs:?}; expected [0, 100] in SELECTION order"
        );
    }

    /// THE CROSS-PORT CONTRAST, and an unrecorded divergence.
    /// Rust's `Selection` is `Vec<ElementSelection>` (`document.rs:207`), so the
    /// payload order is the selection's stored order and is DETERMINISTIC across
    /// runs. Swift's is `Set<ElementSelection>` (`Document.swift:175`), so its
    /// payload comes out in per-process hash order — measured at ten different
    /// orders in ten `swift test` processes. Same gesture, different stacking.
    #[test]
    fn internal_copy_payload_order_is_deterministic_selection_order() {
        let mut children = Vec::new();
        for i in 0..5 {
            children.push(Rc::new(rect(i as f64 * 10.0, 0.0, &format!("r{i}"))));
        }
        let layer = Element::Layer(LayerElem {
            children,
            ..LayerElem::default()
        });
        let doc = Document {
            layers: vec![layer],
            selected_layer: 0,
            selection: (0..5).map(|i| ElementSelection::all(vec![0, i])).collect(),
            ..Document::default()
        };
        // Run it repeatedly: a Vec cannot reorder, and saying so by measurement
        // is the point of the twin.
        for _ in 0..10 {
            let xs: Vec<f64> = copy_payload(&doc)
                .iter()
                .map(|e| match e {
                    Element::Rect(r) => r.x,
                    _ => f64::NAN,
                })
                .collect();
            assert_eq!(
                xs,
                vec![0.0, 10.0, 20.0, 30.0, 40.0],
                "payload order moved: {xs:?}"
            );
        }
    }

    /// Q5. The sink pastes `translate_element(elem, offset, offset)`, and
    /// `translate_element` is `..e.clone()` — id included. `clear_ids` exists
    /// and is deliberately NOT called here (`element.rs:2247`). So the internal
    /// path duplicates identity exactly as the SVG path does: after copy+paste
    /// two live elements claim one id. Under the cardinality law a paste is
    /// 0 -> N and should mint. When that fix lands, invert this probe.
    #[test]
    fn internal_paste_keeps_the_source_id_so_identity_is_duplicated() {
        let src = rect(0.0, 0.0, "keel-1");
        let pasted = translate_element(&src, 24.0, 24.0);
        assert_eq!(
            pasted.common().id.as_deref(),
            Some("keel-1"),
            "the internal paste minted or dropped an id; TODAY it copies verbatim"
        );
        // MANDATORY VALUE ASSERTION: it is a genuinely different element in a
        // different place sharing one identity — which is why it matters.
        match pasted {
            Element::Rect(r) => {
                assert_eq!((r.x, r.y), (24.0, 24.0), "the paste did not move");
            }
            other => panic!("expected a Rect back, got {other:?}"),
        }
    }

    /// Q6. The offset the sink applies, and `paste_in_place`'s explicit "no
    /// offset". The cross-language `paste_translate` family already pins
    /// `translate_element` itself; this pins the two CALL shapes the sink uses —
    /// `PASTE_OFFSET` and `0.0` — against the same helper.
    #[test]
    fn internal_paste_offsets_and_paste_in_place_does_not() {
        let src = rect(7.0, 11.0, "r-1");
        match translate_element(&src, 24.0, 24.0) {
            Element::Rect(r) => assert_eq!(
                (r.x, r.y),
                (31.0, 35.0),
                "paste should offset (7,11) by 24 to (31,35)"
            ),
            other => panic!("expected a Rect, got {other:?}"),
        }
        match translate_element(&src, 0.0, 0.0) {
            Element::Rect(r) => assert_eq!(
                (r.x, r.y),
                (7.0, 11.0),
                "paste_in_place moved the element"
            ),
            other => panic!("expected a Rect, got {other:?}"),
        }
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

/// Read text from the system clipboard and paste it into the active tab.
///
/// `offset` is applied to every pasted element in both axes (`paste_in_place`
/// passes 0). `preserve_layers` selects R3 ("Paste, preserving layers") over R2
/// (plain Paste) — see [`crate::document::op_apply::paste_fragment_into`], which
/// holds the whole layer-targeting decision. It is a PARAMETER, not a stored
/// preference: R3 is an explicit command, and a persistent mode that silently
/// changed what Cmd+V does would be the very defect R2 rejects.
///
/// THIN CALLER, deliberately. Everything below the clipboard read is a lookup
/// plus one call to `paste_fragment_into`. LAYER_STRUCTURE.md §8.4 named this
/// function's tail as an unreachable gap — `spawn_local` over an
/// `Rc<RefCell<AppState>>` and a Dioxus `Signal` cannot be driven from
/// `cargo test --lib` — so the twenty lines that decided where pasted artwork
/// lands were asserted on a READING. They are gone from here; what remains is
/// wiring, and the decision now sits in a pure function the `paste` op verb
/// drives from the shared corpus.
pub(crate) fn clipboard_read_and_paste(
    app: Rc<RefCell<AppState>>,
    mut revision: Signal<u64>,
    offset: f64,
    preserve_layers: bool,
) {
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
                // SVG payload: the fragment's top level IS its layers, so R3 has
                // names to work with. This is the path an ordinary in-app
                // copy/paste takes in BOTH ports (LAYER_STRUCTURE.md §8.0), and
                // the only path Swift has.
                let fragment = svg_to_document(text).layers;
                if let Some(new_doc) =
                    paste_fragment_into(tab.model.document(), &fragment, offset, preserve_layers)
                {
                    // One paste = one undo step (OP_LOG.md Increment 1). begin_txn
                    // captures the pre-paste document; commit clears redo.
                    tab.model.begin_txn();
                    tab.model.set_document(new_doc);
                    tab.model.commit_txn();
                    drop(st);
                    revision += 1;
                    return;
                }
            }
        }

        // Fall back to the internal clipboard — a Rust-only construct, reached
        // only when the system clipboard is unreadable or holds non-SVG text
        // (LAYER_STRUCTURE.md §8.3, D4/D5: that fallback is itself a live
        // divergence from Swift and is BANKED for a ruling, not touched here).
        // Its payload is BARE ELEMENTS: `Vec<Element>` has nowhere to record a
        // layer, so the flattening is already total at COPY and no paste-side
        // mode can undo it. `paste_fragment_into` normalizes a bare element to
        // "no layer name", which makes preserve mode degenerate to R2 here —
        // correctly, since there is nothing to preserve.
        if tab.clipboard.is_empty() {
            return;
        }
        let fragment = std::mem::take(&mut tab.clipboard);
        let pasted =
            paste_fragment_into(tab.model.document(), &fragment, offset, preserve_layers);
        tab.clipboard = fragment;
        let Some(new_doc) = pasted else {
            return;
        };
        // One paste = one undo step (OP_LOG.md Increment 1).
        tab.model.begin_txn();
        tab.model.set_document(new_doc);
        tab.model.commit_txn();
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
            common: CommonProps::default(),
            isolated_blending: false,
            knockout_group: false,
        })],
        selected_layer: 0,
        selection: Vec::new(),
     ..Document::default()};
    Some(document_to_svg(&temp_doc))
}

/// Save a string to a user-chosen file path via the File System Access
/// API (`window.showSaveFilePicker`). The user picks the destination
/// folder + filename; the file is written directly without going
/// through Downloads. Falls back to `download_file`-style anchor click
/// on browsers without `showSaveFilePicker` (Firefox, Safari).
pub(crate) fn save_file_via_picker(filename: &str, content: &str, mime_type: &str) {
    let fname_json = serde_json::to_string(filename).unwrap_or_else(|_| "\"download\"".into());
    let data_json = serde_json::to_string(content).unwrap_or_else(|_| "\"\"".into());
    let mime_json = serde_json::to_string(mime_type).unwrap_or_else(|_| "\"application/octet-stream\"".into());
    let script = format!(r#"
        (async () => {{
            const fname = {fname_json};
            const data = {data_json};
            const mime = {mime_json};
            if (!window.showSaveFilePicker) {{
                // Fallback: trigger a normal download.
                const blob = new Blob([data], {{type: mime}});
                const url = URL.createObjectURL(blob);
                const a = document.createElement('a');
                a.href = url;
                a.download = fname;
                a.click();
                URL.revokeObjectURL(url);
                return;
            }}
            try {{
                const dot = fname.lastIndexOf('.');
                const ext = dot >= 0 ? fname.slice(dot) : '';
                const handle = await window.showSaveFilePicker({{
                    suggestedName: fname,
                    types: ext ? [{{
                        description: ext.slice(1).toUpperCase() + ' file',
                        accept: {{[mime]: [ext]}}
                    }}] : []
                }});
                const writable = await handle.createWritable();
                await writable.write(data);
                await writable.close();
            }} catch (e) {{
                // User cancelled or a permission error — leave silently.
                console.log('save cancelled or failed:', e);
            }}
        }})();
    "#);
    let _ = js_sys::eval(&script);
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

/// Download a binary blob (e.g. PDF) as a file in the browser.
pub(crate) fn download_bytes(filename: &str, content: &[u8], mime_type: &str) {
    let window = match web_sys::window() {
        Some(w) => w,
        None => return,
    };
    let document = match window.document() {
        Some(d) => d,
        None => return,
    };
    let u8_arr = js_sys::Uint8Array::new_with_length(content.len() as u32);
    u8_arr.copy_from(content);
    let parts = js_sys::Array::new();
    parts.push(&u8_arr.into());
    let opts = web_sys::BlobPropertyBag::new();
    opts.set_type(mime_type);
    let blob = match web_sys::Blob::new_with_u8_array_sequence_and_options(&parts, &opts) {
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
            // SVG has no artboards concept; svg_to_document leaves the
            // artboards list empty by design. Restore the
            // at-least-one-artboard invariant here per ARTBOARDS.md
            // — without it, current_artboard is {} after open and
            // fit_active_artboard / Cmd+0 silently no-op against a
            // zero rect, making the document look like it has no
            // canvas to zoom against. (Session restore in session.rs
            // does the same repair on its load path.)
            let mut doc = svg_to_document(&text);
            crate::document::artboard::ensure_artboards_invariant(
                &mut doc.artboards, None,
            );
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
