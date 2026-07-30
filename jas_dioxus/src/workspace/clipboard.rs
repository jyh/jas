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
use crate::document::op_apply::apply_paste_clipboard_text;
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

/// THE COPY PAYLOAD — the Rust half, after the internal clipboard was deleted.
///
/// LAYER_STRUCTURE.md §8 confirmed the internal clipboard and found the
/// divergence D4/D5 that killed it (ratified 2026-07-28: Swift is canon).
/// `TabState.clipboard` is gone, so these probes no longer characterize a
/// `Vec<Element>` payload — they characterize the ONE payload Rust now writes,
/// `selection_to_svg`, which is the same shape Swift's `copySelection` writes.
///
/// **§8.5 recorded a mutation-proof gap: the order probe REPRODUCED the copy
/// expression rather than calling it, so a change at any of the five copy sites
/// would not be caught. That gap is CLOSED here** — there is no expression left
/// to reproduce, and both probes drive the production `selection_to_svg`
/// through a real `AppState`.
///
/// **NAMED GAP, still open and stated before the evidence.** The clipboard READ
/// in `clipboard_read_and_paste` remains unreachable from `cargo test --lib`:
/// it sits in a `spawn_local` closure (a wasm-only executor) over an
/// `Rc<RefCell<AppState>>` and a Dioxus `Signal`, neither constructible outside
/// a Dioxus runtime. Everything BELOW that read is now
/// `op_apply::paste_clipboard_text_into`, which the shared corpus family
/// `paste_clipboard_text.json` drives in both ports. So what is unwatched in
/// Rust is exactly: "does the string handed to the dispatch come from the
/// system clipboard". Swift's equivalent IS watched — its pasteboard is
/// injectable (`ClipboardTextPasteTests`).
#[cfg(test)]
mod copy_payload_tests {
    use super::*;
    use crate::document::document::{Document, ElementSelection};
    // `translate_element` moved out of the module-level imports when the paste
    // sink became a thin caller (it is `paste_fragment_into`'s business now);
    // these probes still drive it directly, so they import it themselves.
    use crate::geometry::element::translate_element;
    use crate::geometry::element::{
        Color, CommonProps, Element, Fill, LayerElem, RectElem,
    };

    /// Drive the PRODUCTION copy payload: build a real `AppState` around `doc`
    /// and call `selection_to_svg`, the single expression every copy site now
    /// hands to `clipboard_write`.
    fn copy_payload_svg(doc: Document) -> String {
        let mut st = AppState::new();
        st.tabs.clear();
        st.tabs.push(TabState::with_model(Model::new(doc, None)));
        st.active_tab = 0;
        selection_to_svg(&st).expect("a non-empty selection produces a payload")
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

    /// The x-coordinates a copy payload round-trips to, in payload order.
    /// The SVG codec scales pt -> px (x4/3) and back at 4 decimals, so a
    /// coordinate returns within ~2.5e-5 — the tolerance below is DERIVED from
    /// that, not guessed (LAYER_STRUCTURE.md §8.3, "a transport property").
    fn payload_xs(doc: Document) -> Vec<f64> {
        let back = crate::geometry::svg::svg_to_document(&copy_payload_svg(doc));
        assert_eq!(
            back.layers.len(),
            1,
            "the copy payload must be ONE layer; got {}",
            back.layers.len()
        );
        assert!(
            back.layers[0].common().name.as_deref().unwrap_or("").is_empty(),
            "the copy payload's layer is named {:?}; an in-app copy must emit an \
             UNNAMED layer, which is why 'Paste, preserving layers' cannot bite \
             on it",
            back.layers[0].common().name
        );
        back.layers[0]
            .children()
            .expect("a layer has children")
            .iter()
            .map(|c| match &**c {
                Element::Rect(r) => r.x,
                _ => f64::NAN,
            })
            .collect()
    }

    /// THE FINDING THAT SETTLES Q2/Q3 FOR RUST, now measured on the ONLY
    /// payload Rust writes. A copy spanning two NAMED layers produces ONE
    /// UNNAMED layer holding both elements — the payload has nowhere to record
    /// which layer each came from, so the flattening is total at COPY and no
    /// paste-side mode can undo it. Identical in shape to Swift's
    /// `copySelection`, which builds `Document(layers: [Layer(children:)])`.
    #[test]
    fn copy_payload_is_one_unnamed_layer_carrying_no_layer_identity() {
        let xs = payload_xs(two_layer_doc());
        // MANDATORY VALUE ASSERTION: say which elements, by geometry, so this
        // cannot pass on an empty or wrong-shaped payload.
        assert_eq!(xs.len(), 2, "expected both selected elements, got {xs:?}");
        for (got, want) in xs.iter().zip([0.0_f64, 100.0]) {
            assert!(
                (got - want).abs() < 1e-3,
                "payload x-coordinates {xs:?}; expected [0, 100] in SELECTION order"
            );
        }
    }

    /// THE CROSS-PORT CONTRAST, and a recorded divergence (D6).
    /// Rust's `Selection` is `Vec<ElementSelection>` (`document.rs:207`), so the
    /// payload order is the selection's stored order and is DETERMINISTIC across
    /// runs. Swift's is `Set<ElementSelection>` (`Document.swift:175`), so its
    /// payload comes out in per-process hash order — measured at ten different
    /// orders in ten `swift test` processes. Same gesture, different stacking.
    /// Banked for a ruling; this half of the pair is the stable one.
    #[test]
    fn copy_payload_order_is_deterministic_selection_order() {
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
            let xs = payload_xs(doc.clone());
            assert_eq!(xs.len(), 5, "payload lost elements: {xs:?}");
            for (got, want) in xs.iter().zip([0.0_f64, 10.0, 20.0, 30.0, 40.0]) {
                assert!(
                    (got - want).abs() < 1e-3,
                    "payload order moved: {xs:?}"
                );
            }
        }
    }

    /// §19's GATE, and the reason it is written HERE rather than beside
    /// `Controller::copy_selection`: the selection a duplicate leaves is an
    /// INTERNAL fact until a subsequent Copy emits it. **A gate that checked
    /// the selection and not the clipboard would pass on a fix that left the
    /// leak in place**, because `selection_to_svg` walks `doc.selection` in
    /// stored order and writes the elements in exactly that order.
    ///
    /// Alt-drag-duplicate the NON-CONTIGUOUS pair b=[0,1] and d=[0,3] of four
    /// rects, then Copy. The duplicate's descending walk is load-bearing and
    /// stays, so the document is
    ///
    ///     a@0  b@10  b'@16  c@20  d@30  d'@36
    ///
    /// and the payload must be the two COPIES, front-to-back: **[16, 36]**.
    ///
    /// THE FOUR OUTCOMES, so the assertion cannot be read as merely tidy:
    ///   * `[30, 16]` — what shipped. Reverse document order AND it carries d,
    ///     the SOURCE, because the byproduct recorded `[0,4]` before the later
    ///     insertion at [0,1] shifted d up to index 4.
    ///   * `[16, 30]` — sorted the stale paths. Order fixed, still a source.
    ///   * `[36, 16]` — fixed the paths, kept the descending order.
    ///   * `[16, 36]` — RULED.
    ///
    /// This drives the PRODUCTION mutator and the PRODUCTION payload
    /// expression, so it is the artist's gesture pair and not a reconstruction.
    #[test]
    fn a_duplicate_then_copy_emits_the_copies_in_document_order() {
        use crate::document::controller::Controller;

        let children: Vec<Rc<Element>> = (0..4)
            .map(|i| Rc::new(rect(i as f64 * 10.0, 0.0, &format!("r{i}"))))
            .collect();
        let doc = Document {
            layers: vec![Element::Layer(LayerElem {
                children,
                ..LayerElem::default()
            })],
            selected_layer: 0,
            selection: vec![
                ElementSelection::all(vec![0, 1]),
                ElementSelection::all(vec![0, 3]),
            ],
            ..Document::default()
        };
        let mut model = Model::new(doc, None);
        Controller::copy_selection(&mut model, 6.0, 0.0);

        let xs = payload_xs(model.document().clone());
        assert_eq!(
            xs.len(),
            2,
            "a duplicate of two elements must put two elements on the \
             clipboard; got {xs:?}",
        );
        for (got, want) in xs.iter().zip([16.0_f64, 36.0]) {
            assert!(
                (got - want).abs() < 1e-3,
                "clipboard payload is {xs:?}; expected [16, 36] — the two \
                 COPIES in document order. [30, 16] is the shipped defect \
                 (reverse order, and the second entry is the SOURCE d).",
            );
        }
    }

    /// Q5. The paste body applies `translate_element(elem, offset, offset)`, and
    /// `translate_element` is `..e.clone()` — id included. `clear_ids` exists
    /// and is deliberately NOT called there (`element.rs:2247`), so after
    /// copy+paste two live elements claim one id. Under the cardinality law a
    /// paste is 0 -> N and should mint. When that fix lands, invert this probe.
    #[test]
    fn paste_keeps_the_source_id_so_identity_is_duplicated() {
        let src = rect(0.0, 0.0, "keel-1");
        let pasted = translate_element(&src, 24.0, 24.0);
        assert_eq!(
            pasted.common().id.as_deref(),
            Some("keel-1"),
            "the paste minted or dropped an id; TODAY it copies verbatim"
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

    /// Q6. The offset the paste body applies, and `paste_in_place`'s explicit
    /// "no offset". The cross-language `paste_translate` family already pins
    /// `translate_element` itself; this pins the two CALL shapes production uses
    /// — `PASTE_OFFSET` and `0.0` — against the same helper.
    #[test]
    fn paste_offsets_and_paste_in_place_does_not() {
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
/// **D4/D5 landed here as a DELETION** (ratified 2026-07-28; Swift is canon).
/// This function used to test for SVG and, failing that, fall back to
/// `TabState.clipboard` — an internal buffer holding the last in-app copy. So
/// pasting NON-SVG TEXT re-pasted stale artwork the artist had not copied and
/// silently discarded the text they had, and pasting with an EMPTY clipboard
/// pasted artwork too. Where a paste came from was decided by INVISIBLE STATE,
/// which is ruling R2 one level up. The fallback is gone and the internal
/// clipboard with it: `TabState.clipboard` had exactly one reader — this — and
/// five writers, so removing the reader left a write-only field, and the five
/// copy sites now write only the system clipboard, exactly as Swift's one does.
///
/// THIN CALLER, deliberately. Everything below the clipboard read is one call to
/// `paste_clipboard_text_into`. LAYER_STRUCTURE.md §8.4 named this function's
/// tail as an unreachable gap — `spawn_local` over an `Rc<RefCell<AppState>>`
/// and a Dioxus `Signal` cannot be driven from `cargo test --lib` — so the lines
/// that decided where pasted artwork lands were asserted on a READING. They are
/// gone from here; both the layer targeting AND the payload dispatch now sit in
/// pure functions the `paste` op verb drives from the shared corpus
/// (`paste_layers.json` and `paste_clipboard_text.json`). What is left here, and
/// still NOT reachable from `cargo test --lib`, is the clipboard read itself.
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

        // THE WHOLE DECISION, in one call. `apply_paste_clipboard_text` takes
        // the clipboard payload EXACTLY as read — `None` for an unreadable
        // clipboard, `Some("")` for an empty one — and either edits the document
        // or answers `false`.
        //
        // `apply_paste_clipboard_text`, NOT the pure `paste_clipboard_text_into`
        // it wraps: the CUMULATIVE-OFFSET RUN (`actions.yaml` §paste, "Repeated
        // pastes stack with cumulative offsets") lives in the Model-level
        // wrapper, so calling the pure body here would leave the corpus green
        // while production pasted every copy on the same spot. That is the exact
        // decoy the `paste` op verb was built to rule out, one layer up.
        //
        // One paste = one undo step (OP_LOG.md Increment 1): the wrapper writes
        // through `edit_document`, which self-brackets — begin captures the
        // pre-paste document AND the pre-paste run, commit clears redo — exactly
        // as the explicit bracket here used to.
        if !apply_paste_clipboard_text(
            &mut tab.model,
            clipboard_text.as_deref(),
            offset,
            preserve_layers,
        ) {
            return;
        }
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
/// The filename a Save should offer, given the model's current one.
///
/// Mirrors the `"save"` menu arm's rule so Save and Save As cannot disagree
/// about what a document is called.
pub(crate) fn svg_filename_for(current: &str) -> String {
    let base = if current.trim().is_empty() { "drawing" } else { current.trim() };
    if base.to_ascii_lowercase().ends_with(".svg") {
        base.to_string()
    } else {
        format!("{base}.svg")
    }
}

/// Apply the OUTCOME of a Save As to the model. `chosen` is `None` when the
/// artist cancelled — the picker dialog, or the fallback name prompt.
///
/// Returns whether anything changed.
///
/// A CANCELLED SAVE MUST CHANGE NOTHING, and that is the whole reason this is a
/// separate function with its own tests. `save_file_via_picker` was
/// fire-and-forget: it could not tell success from cancellation, so the naive
/// wiring — call the picker, then `mark_saved()` — would mark a document saved
/// that was never written. That silently disarms the unsaved-changes guard, and
/// the artist loses work at the next close. JasSwift has always had this right,
/// because `NSSavePanel.runModal()` returns and it checks the result.
///
/// On success both fields move, matching JasSwift's `saveModelAs`: the document
/// is clean AND it is now called what the artist called it.
pub(crate) fn apply_save_as_outcome(st: &mut AppState, chosen: Option<&str>) -> bool {
    let Some(name) = chosen else { return false };
    let name = svg_filename_for(name);
    let Some(tab) = st.tab_mut() else { return false };
    tab.model.filename = name;
    tab.model.mark_saved();
    true
}

/// File > Save As.
///
/// Wired 2026-07-30 (council O1.1). Until then this port's Save As did
/// NOTHING: `menu_bar.rs` routed it through the pass-through arm into
/// `dispatch_action`, whose declared effect is a bare `- log:`. JasSwift
/// implemented it fully the whole time, so it was a one-port, artist-visible
/// divergence — and `save_file_via_picker` below had been sitting complete and
/// called from nowhere.
///
/// TWO PATHS, ONE SEMANTICS. Chromium has `showSaveFilePicker`, so the artist
/// gets a real OS dialog and the file is written where they choose. Firefox and
/// Safari do not, so they are asked for a NAME and the file lands in Downloads.
/// Both paths mean the same thing: name it and it saves, cancel and nothing
/// happens. Nothing escapes the browser sandbox in either case.
///
/// THE CANCEL IS THE WHOLE DIFFICULTY. The picker is asynchronous, so this
/// awaits it rather than firing and forgetting, and applies the outcome through
/// [`apply_save_as_outcome`] — which is separately tested, because marking a
/// cancelled save as saved would disarm the unsaved-changes guard and lose the
/// artist's work at the next close.
#[cfg(feature = "web")]
pub(crate) fn save_document_as(app: Rc<RefCell<AppState>>, mut revision: Signal<u64>) {
    let (svg, suggested) = {
        let st = app.borrow();
        let Some(tab) = st.tab() else { return };
        (
            document_to_svg(tab.model.document()),
            svg_filename_for(&tab.model.filename),
        )
    };

    wasm_bindgen_futures::spawn_local(async move {
        let chosen = pick_save_target(&suggested, &svg).await;
        if chosen.is_none() {
            return; // cancelled: the document stays exactly as it was
        }
        let mut st = app.borrow_mut();
        if apply_save_as_outcome(&mut st, chosen.as_deref()) {
            drop(st);
            revision += 1;
        }
    });
}

/// Ask the browser for a save target, write the content, and answer with the
/// chosen name — or `None` if the artist cancelled.
///
/// Returns the NAME rather than a path: the File System Access API never
/// discloses the directory, and the download fallback has no path at all. The
/// name is what the artist typed and what the title bar should show, which is
/// the same thing JasSwift stores (it keeps `url.path`, so the two ports agree
/// on the leaf name and differ only in what they can know).
#[cfg(feature = "web")]
async fn pick_save_target(suggested: &str, content: &str) -> Option<String> {
    use wasm_bindgen_futures::JsFuture;

    let window = web_sys::window()?;
    let has_picker = js_sys::Reflect::get(&window, &JsValue::from_str("showSaveFilePicker"))
        .map(|v| v.is_function())
        .unwrap_or(false);

    if !has_picker {
        // Firefox / Safari: no OS dialog exists, so ask for the name instead
        // and download under it. Degraded in DESTINATION, not in meaning.
        let typed = window
            .prompt_with_message_and_default("Save as", suggested)
            .ok()
            .flatten()?;
        let name = typed.trim().to_string();
        if name.is_empty() {
            return None;
        }
        let name = svg_filename_for(&name);
        download_file(&name, content);
        return Some(name);
    }

    let opts = js_sys::Object::new();
    js_sys::Reflect::set(&opts, &"suggestedName".into(), &suggested.into()).ok()?;
    let picker = js_sys::Reflect::get(&window, &JsValue::from_str("showSaveFilePicker")).ok()?;
    let picker: js_sys::Function = picker.dyn_into().ok()?;
    let promise: js_sys::Promise = picker.call1(&window, &opts).ok()?.dyn_into().ok()?;

    // A rejected promise is the artist pressing Cancel (an AbortError). It is
    // not an error condition and must not be reported as one.
    let handle = JsFuture::from(promise).await.ok()?;

    let create = js_sys::Reflect::get(&handle, &"createWritable".into()).ok()?;
    let create: js_sys::Function = create.dyn_into().ok()?;
    let writable = JsFuture::from(
        create.call0(&handle).ok()?.dyn_into::<js_sys::Promise>().ok()?,
    )
    .await
    .ok()?;

    let write = js_sys::Reflect::get(&writable, &"write".into()).ok()?;
    let write: js_sys::Function = write.dyn_into().ok()?;
    JsFuture::from(
        write
            .call1(&writable, &JsValue::from_str(content))
            .ok()?
            .dyn_into::<js_sys::Promise>()
            .ok()?,
    )
    .await
    .ok()?;

    let close = js_sys::Reflect::get(&writable, &"close".into()).ok()?;
    let close: js_sys::Function = close.dyn_into().ok()?;
    JsFuture::from(close.call0(&writable).ok()?.dyn_into::<js_sys::Promise>().ok()?)
        .await
        .ok()?;

    // The handle knows the leaf name the artist chose; fall back to the
    // suggestion if the property is missing on some implementation.
    let name = js_sys::Reflect::get(&handle, &"name".into())
        .ok()
        .and_then(|v| v.as_string())
        .unwrap_or_else(|| suggested.to_string());
    Some(name)
}

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

#[cfg(test)]
mod save_as_tests {
    use super::*;

    /// SAVE AS IS THE ONE FILE OPERATION THAT CAN LOSE WORK BY SUCCEEDING TOO
    /// EAGERLY.
    ///
    /// `save_file_via_picker` shipped complete and called from nowhere, so File
    /// > Save As did nothing at all in this port while JasSwift implemented it
    /// fully (council O1.1, 2026-07-30). The tempting wiring is one line — call
    /// the picker, then `mark_saved()`. It is wrong: the picker is asynchronous
    /// and the artist may cancel it, and a document marked saved that was never
    /// written will close without warning and take the work with it.
    ///
    /// So the outcome is applied from a function that is told whether a name
    /// was actually chosen, and these tests pin both answers. The browser
    /// halves — the File System Access picker, and the `prompt` fallback for
    /// Firefox/Safari — cannot be reached from a unit test and are verified by
    /// hand; that is exactly why the decision logic is separated out to where a
    /// test CAN reach it.
    /// A one-tab AppState holding a fresh model, built the way
    /// `copy_payload_tests` builds one: `AppState::new()` alone carries no tab.
    fn state_with_tab(filename: &str) -> AppState {
        let mut st = AppState::new();
        st.tabs.clear();
        let mut model = Model::new(Document::default(), None);
        model.filename = filename.to_string();
        st.tabs.push(TabState::with_model(model));
        st.active_tab = 0;
        st
    }

    /// Commit a real edit, so `is_modified` is true. Setting a default document
    /// over a default document moves no transaction and modifies nothing.
    fn dirty(st: &mut AppState) {
        let doc = Document {
            layers: vec![GeoElement::Layer(LayerElem {
                children: vec![],
                common: CommonProps::default(),
                isolated_blending: false,
                knockout_group: false,
            })],
            ..Document::default()
        };
        st.tab_mut().unwrap().model.with_txn(|m| m.set_document(doc.clone()));
    }

    #[test]
    fn a_cancelled_save_as_changes_nothing() {
        let mut st = state_with_tab("hull.svg");
        dirty(&mut st);
        let before = st.tab().unwrap().model.filename.clone();
        assert!(st.tab().unwrap().model.is_modified(),
                "fixture must start modified or it proves nothing");

        let changed = apply_save_as_outcome(&mut st, None);

        assert!(!changed, "a cancelled Save As must report no change");
        assert_eq!(st.tab().unwrap().model.filename, before, "the name must not move");
        assert!(st.tab().unwrap().model.is_modified(),
                "a cancelled Save As must leave the document MODIFIED -- marking it \
                 clean disarms the close-without-saving guard and loses the work");
    }

    /// The other half, so the rule cannot become "never mark saved".
    #[test]
    fn a_completed_save_as_renames_and_cleans() {
        let mut st = state_with_tab("hull.svg");
        dirty(&mut st);
        assert!(st.tab().unwrap().model.is_modified(), "fixture must start modified");

        let changed = apply_save_as_outcome(&mut st, Some("hull study"));

        assert!(changed);
        assert_eq!(st.tab().unwrap().model.filename, "hull study.svg",
                   "the document takes the artist's name, with the extension \
                    supplied -- JasSwift's saveModelAs sets model.filename too");
        assert!(!st.tab().unwrap().model.is_modified(),
                "a completed Save As leaves the document clean");
    }

    /// Save and Save As must not disagree about what a document is called.
    #[test]
    fn the_extension_rule_matches_the_save_arm() {
        assert_eq!(svg_filename_for("drawing"), "drawing.svg");
        assert_eq!(svg_filename_for("drawing.svg"), "drawing.svg");
        // Case-insensitively, so an artist typing .SVG does not get .SVG.svg.
        assert_eq!(svg_filename_for("Drawing.SVG"), "Drawing.SVG");
        // An empty or whitespace name is not a name.
        assert_eq!(svg_filename_for(""), "drawing.svg");
        assert_eq!(svg_filename_for("   "), "drawing.svg");
        assert_eq!(svg_filename_for("  hull  "), "hull.svg");
    }
}
