//! THE NATIVE DOCUMENT WALK — paint a whole `Document` through the Painter
//! seam with this document's PAINT CONTEXT installed.
//!
//! ⭐ WHY THIS EXISTS, AND IT IS NOT "TIDINESS". `canvas::render::render()` is
//! the web walk's document entry, and its very first act is to install the
//! render-scoped paint context (`install_ref_index(id_index.clone(),
//! precision)`) so that every by-id reference underneath it resolves. The
//! native walk's document entry — `ffi_paint::paint_document_into`, the Windows
//! app's ONLY renderer — installed nothing and looped `emit_element` over the
//! layers directly.
//!
//! ⛔ THAT WAS HARMLESS ONLY WHILE LIVE ELEMENTS WERE LEGACY-ONLY, AND ROW CV
//! ENDS THAT. Before this row `element_needs_legacy` answered YES for every
//! `Element::Live`, so `first_unpaintable` REFUSED any document carrying one
//! and the missing install could not be observed. The moment the router lets
//! live geometry through, a native walk with no context installed resolves
//! every reference against an EMPTY index — and under the uniform failure rule
//! (LIVE_ELEMENTS.md §2) that is not a crash, it is silence: the document
//! paints with its live elements missing and the seam returns `JAS_PAINT_OK`.
//!
//! ⇒ 🔑 **THAT IS THE EXACT FAILURE CLASS `first_unpaintable` WAS WRITTEN TO
//! PREVENT, ARRIVING THROUGH A DIFFERENT DOOR.** The refusal asks "can every
//! element be lowered"; it cannot ask "will the lowering have the state it
//! needs". A capability check cannot see a missing install, so the install has
//! to be part of the walk rather than a duty left to each caller — which is
//! what this module is. This is flask's finding stated precisely: *the services
//! exist; the element router doesn't use them.*
//!
//! WHY IT LIVES IN `document` AND NOT IN `painter`. `painter/` has NO dependency
//! on the document model and keeping it that way is the seam's whole value — a
//! backend author never sees a `Document`. What this function does is DOCUMENT
//! policy (build this document's index, install it, walk its layers), so it
//! sits one layer above the painter, exactly as the web walk `canvas::render`
//! does. The dependency direction is `document → painter`, the same direction
//! `canvas → painter` already runs.

use crate::document::document::Document;
use crate::document::id_index::{install_paint_context, rebuild_id_index};
use crate::painter::element_render::emit_element;
use crate::painter::Painter;

/// Paint every layer of `doc` through [`emit_element`], with this document's
/// paint context installed for the duration.
///
/// `precision` is the tessellation tolerance live geometry evaluates at — the
/// same ambient input `canvas::render` threads from the Boolean panel. It is a
/// PARAMETER rather than a constant chosen here so that a host which acquires a
/// precision control later passes it, and so that a host which has none names
/// the default at its own call site instead of inheriting it silently.
///
/// ⚠️ THE INDEX IS REBUILT, NOT BORROWED, and that is a deliberate difference
/// from the web walk. `render()` receives the `Model`'s persistent index (an
/// O(1) rpds clone, never rebuilt per paint); the native seam is handed a bare
/// `Document` with no `Model` behind it, so there is nothing to borrow. The
/// VALUE is the same one — the Model's own gate asserts its index equals
/// `rebuild_id_index(doc)` — but the COST is not: this is O(document) per
/// paint. Named here rather than discovered later; a host that paints every
/// frame from a persistent model should grow a borrowing entry beside this one.
///
/// Each root layer starts from alpha 1.0: the layers are siblings with no
/// enclosing group, each carrying its own opacity. A page with
/// `page_isolated_blending` set wraps them in one isolated layer
/// ([`emit_layers`]).
pub fn emit_document(p: &mut dyn Painter, doc: &Document, precision: f64) {
    let _paint_context = install_paint_context(rebuild_id_index(doc), precision);
    emit_layers(p, doc);
}

/// The top-level layers, under the page's compositing (OPACITY.md §Page-level
/// items, row 192 B1). With `page_isolated_blending` the layers composite into
/// ONE fresh transparent layer (the A6 op `push_isolated_layer`, alpha 1 and
/// Normal) that lands on the target once, so a blended layer blends with the
/// layers beneath it but never with the page the host painted (the artboard
/// fill). `page_knockout_group` is stored and NOT composited here: knockout
/// needs an op the frozen contract does not have (the A7 amendment, row 192).
fn emit_layers(p: &mut dyn Painter, doc: &Document) {
    let isolated = doc.document_setup.page_isolated_blending;
    if isolated {
        p.push_isolated_layer(1.0, crate::painter::BlendMode::Normal);
    }
    for layer in &doc.layers {
        emit_element(p, layer, 1.0);
    }
    if isolated {
        p.pop_isolated_layer();
    }
}

/// [`emit_document`] under the model's MASK ISOLATION (row 185;
/// OPACITY.md §Preview interactions: an Alt-click on the mask preview
/// "isolate[s] the mask on the canvas (show only mask contents)").
///
/// With `Some(path)` only the mask subtree of the element at `path` is drawn,
/// and the rest of the document is hidden, as the web walk's layer 3 does
/// (`canvas::render::render`). A path naming no element, or an element with no
/// mask, draws nothing, also as on the web. `None` is [`emit_document`].
///
/// The isolation lives on the `Model`, not the `Document`, so the caller
/// passes it; the paint context is installed either way, because a mask
/// subtree may hold a by-id reference too.
pub fn emit_document_isolated(
    p: &mut dyn Painter,
    doc: &Document,
    precision: f64,
    mask_isolation_path: Option<&[usize]>,
) {
    emit_document_with_index(p, doc, rebuild_id_index(doc), precision, mask_isolation_path)
}

/// [`emit_document_isolated`] with the document's index BORROWED rather than
/// rebuilt (row 202): a host that paints every frame from a persistent
/// `Model` passes `Model::id_index().clone()`, an O(1) rpds clone, as the web
/// walk does (`render()` installs the Model's index), instead of paying
/// O(document) per paint. `index` must be the document's own: the Model's gate
/// keeps it equal to `rebuild_id_index(doc)`, and a debug build asserts that
/// here, so a stale or foreign index is loud in every test rather than a
/// reference silently resolving to the wrong element.
pub fn emit_document_with_index(
    p: &mut dyn Painter,
    doc: &Document,
    index: crate::document::id_index::IdIndex,
    precision: f64,
    mask_isolation_path: Option<&[usize]>,
) {
    debug_assert!(index == rebuild_id_index(doc),
        "emit_document_with_index: the index is not this document's own");
    let _paint_context = install_paint_context(index, precision);
    match mask_isolation_path {
        None => emit_layers(p, doc),
        Some(path) => {
            if let Some(mask) = doc.get_element(&path.to_vec()).and_then(|e| e.common().mask.as_deref()) {
                emit_element(p, &mask.subtree, 1.0);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::element::{Color, CommonProps, Element, Fill, RectElem};
    use crate::geometry::live::{ElementRef, LiveVariant, ReferenceElem, DEFAULT_PRECISION};
    use crate::painter::recording::{Command, RecordingPainter};
    use std::rc::Rc;

    fn white() -> Option<Fill> {
        Some(Fill { color: Color::WHITE, opacity: 1.0 })
    }

    fn ided_rect(id: &str) -> Element {
        Element::Rect(RectElem {
            x: 10.0, y: 20.0, width: 30.0, height: 40.0, rx: 0.0, ry: 0.0,
            fill: white(), stroke: None,
            common: CommonProps { id: Some(id.into()), ..CommonProps::default() },
            fill_gradient: None, stroke_gradient: None,
        })
    }

    fn reference_to(id: &str) -> Element {
        Element::Live(LiveVariant::Reference(ReferenceElem {
            target: ElementRef(id.into()),
            transform: None,
            fill: white(),
            stroke: None,
            common: CommonProps::default(),
        }))
    }

    fn fills(cmds: &[Command]) -> usize {
        cmds.iter().filter(|c| matches!(c, Command::FillPath { .. } | Command::FillRect { .. })).count()
    }

    /// Row 202: the BORROWING entry paints what the rebuilding one paints
    /// when it is handed the document's own index, and a foreign index is
    /// loud in a debug build (the reference would otherwise resolve against
    /// the wrong document, or not at all).
    #[test]
    fn the_borrowing_walk_paints_as_the_rebuilding_walk_and_refuses_a_foreign_index() {
        let mut doc = Document::default();
        doc.layers[0].children_mut().unwrap().push(Rc::new(ided_rect("m1")));
        doc.layers[0].children_mut().unwrap().push(Rc::new(reference_to("m1")));
        let mut rebuilt = RecordingPainter::new();
        emit_document(&mut rebuilt, &doc, DEFAULT_PRECISION);
        let mut borrowed = RecordingPainter::new();
        emit_document_with_index(&mut borrowed, &doc, rebuild_id_index(&doc), DEFAULT_PRECISION, None);
        assert_eq!(fills(rebuilt.commands()), 2, "CONTROL: the rect and the reference paint");
        assert_eq!(format!("{:?}", borrowed.commands()), format!("{:?}", rebuilt.commands()));
        if cfg!(debug_assertions) {
            let foreign = std::panic::catch_unwind(|| {
                let mut p = RecordingPainter::new();
                emit_document_with_index(&mut p, &doc, crate::document::id_index::IdIndex::new(),
                                         DEFAULT_PRECISION, None);
            });
            assert!(foreign.is_err(), "a foreign (empty) index is loud in a debug build");
        }
    }

    /// A document whose ONLY live element is a reference to a sibling: it paints
    /// only if the walk installed this document's index. This is the whole row's
    /// second half in one assertion.
    #[test]
    fn the_document_walk_installs_this_documents_paint_context() {
        let mut doc = Document::default();
        {
            let kids = doc.layers[0].children_mut().expect("the root layer holds children");
            kids.push(Rc::new(ided_rect("m1")));
            kids.push(Rc::new(reference_to("m1")));
        }
        let mut rec = RecordingPainter::new();
        emit_document(&mut rec, &doc, DEFAULT_PRECISION);
        assert_eq!(
            fills(rec.commands()), 2,
            "the rect AND its reference must both paint; one fill means the \
             reference resolved against an empty index and vanished SILENTLY: {:?}",
            rec.commands()
        );
    }

    /// ⛔ AND THE INSTALL IS SCOPED. The guard must restore the prior context on
    /// return, or one native paint leaks its index into whatever paints next —
    /// including a nested paint, where a stale index resolves an id to the WRONG
    /// element rather than to none.
    #[test]
    fn the_document_walks_install_does_not_outlive_it() {
        let mut doc = Document::default();
        doc.layers[0].children_mut().unwrap().push(Rc::new(ided_rect("m1")));
        let mut rec = RecordingPainter::new();
        emit_document(&mut rec, &doc, DEFAULT_PRECISION);

        // Outside the walk nothing is installed again (row 202: painting a
        // live element uninstalled now asserts, so the claim is read
        // directly), and an empty install does not know the id.
        assert!(!crate::document::id_index::paint_context_installed(),
                "the document walk's context escaped its own call");
        let _empty = crate::document::id_index::install_paint_context(
            crate::document::id_index::IdIndex::new(), DEFAULT_PRECISION);
        let mut after = RecordingPainter::new();
        emit_element(&mut after, &reference_to("m1"), 1.0);
        assert_eq!(
            fills(after.commands()), 0,
            "the walk's index is not the next install's: {:?}",
            after.commands()
        );
    }

    /// STATUS-jas row 195: the native walk carried a blend ONLY inside the A6
    /// mask bracket, so every backend it feeds (Windows, through
    /// `jas_paint_document`) drew an unmasked Multiply shape as Normal, while
    /// the web walk (`render.rs`, per-element `globalCompositeOperation`) and
    /// Swift (`setBlendMode`) apply it. A leaf's own mode now rides the
    /// existing NON-isolated `push_group(1.0, mode)`, which is the per-primitive
    /// semantics both of them have (the Painter contract's "somewhere to land"
    /// for today's per-element composite op). A group's own mode stays inert
    /// (D3): on the web its children override it.
    fn groups(cmds: &[Command]) -> Vec<String> {
        cmds.iter().filter_map(|c| match c {
            Command::PushGroup { alpha, blend } => Some(format!("push({alpha},{blend:?})")),
            Command::PopGroup => Some("pop".into()),
            _ => None,
        }).collect()
    }

    fn doc_with(children: Vec<Element>, layer_mode: crate::painter::BlendMode) -> Document {
        let mut doc = Document::default();
        doc.layers[0].common_mut().mode = layer_mode;
        let kids = doc.layers[0].children_mut().unwrap();
        for c in children { kids.push(Rc::new(c)); }
        doc
    }

    fn with_mode(mut e: Element, m: crate::painter::BlendMode) -> Element {
        e.common_mut().mode = m;
        e
    }

    #[test]
    fn an_unmasked_leafs_blend_mode_reaches_the_painter() {
        use crate::painter::BlendMode as B;
        let doc = doc_with(vec![with_mode(rect_at(0.0, Color::rgb(1.0, 0.0, 0.0)), B::Multiply)], B::Normal);
        let mut rec = RecordingPainter::new();
        emit_document(&mut rec, &doc, DEFAULT_PRECISION);
        assert_eq!(groups(rec.commands()), vec!["push(1,Multiply)".to_string(), "pop".into()],
                   "a Multiply rect must be bracketed by push_group(1.0, Multiply): {:?}", rec.commands());
        assert_eq!(fills(rec.commands()), 1, "the rect still paints once");
    }

    #[test]
    fn a_normal_leaf_emits_no_group() {
        use crate::painter::BlendMode as B;
        let doc = doc_with(vec![rect_at(0.0, Color::rgb(1.0, 0.0, 0.0))], B::Normal);
        let mut rec = RecordingPainter::new();
        emit_document(&mut rec, &doc, DEFAULT_PRECISION);
        assert!(groups(rec.commands()).is_empty(), "Normal is today's command list, unchanged: {:?}", rec.commands());
    }

    #[test]
    fn a_containers_own_mode_stays_inert_and_its_childs_does_not() {
        use crate::painter::BlendMode as B;
        let doc = doc_with(vec![rect_at(0.0, Color::rgb(1.0, 0.0, 0.0)),
                                with_mode(rect_at(20.0, Color::rgb(0.0, 0.0, 1.0)), B::Screen)], B::Multiply);
        let mut rec = RecordingPainter::new();
        emit_document(&mut rec, &doc, DEFAULT_PRECISION);
        assert_eq!(groups(rec.commands()), vec!["push(1,Screen)".to_string(), "pop".into()],
                   "the Multiply layer brackets nothing (D3); the Screen child is bracketed: {:?}", rec.commands());
    }

    fn rect_at(x: f64, color: Color) -> Element {
        Element::Rect(RectElem {
            x, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill { color, opacity: 1.0 }), stroke: None,
            common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        })
    }

    /// Layer 0 holds a red rect masked by a green one, then a blue rect.
    fn masked_document() -> (Document, Element) {
        use crate::geometry::element::Mask;
        let subtree = rect_at(50.0, Color::rgb(0.0, 1.0, 0.0));
        let mut red = rect_at(0.0, Color::rgb(1.0, 0.0, 0.0));
        if let Element::Rect(r) = &mut red {
            r.common.mask = Some(Box::new(Mask {
                subtree: Box::new(subtree.clone()),
                clip: true, invert: false, disabled: false, linked: true, unlink_transform: None,
            }));
        }
        let mut doc = Document::default();
        let kids = doc.layers[0].children_mut().unwrap();
        kids.push(Rc::new(red));
        kids.push(Rc::new(rect_at(20.0, Color::rgb(0.0, 0.0, 1.0))));
        (doc, subtree)
    }

    /// Row 185 (OPACITY.md §Preview interactions; the web walk's layer 3 in
    /// `canvas::render::render`): in mask isolation the canvas shows ONLY the
    /// isolated element's mask subtree, and everything else is hidden. The
    /// native walk read no isolation state and drew the whole document.
    #[test]
    fn mask_isolation_paints_only_the_isolated_elements_mask_subtree() {
        let (doc, subtree) = masked_document();
        let mut want = RecordingPainter::new();
        emit_element(&mut want, &subtree, 1.0);
        assert_eq!(fills(want.commands()), 1, "the control: the subtree alone is one fill");

        let mut rec = RecordingPainter::new();
        emit_document_isolated(&mut rec, &doc, DEFAULT_PRECISION, Some(&[0, 0]));
        assert_eq!(rec.commands(), want.commands(), "isolation draws the mask subtree and nothing else");
    }

    /// With no isolation the walk is `emit_document`'s, byte for byte.
    #[test]
    fn no_isolation_is_the_whole_document() {
        let (doc, _) = masked_document();
        let mut whole = RecordingPainter::new();
        emit_document(&mut whole, &doc, DEFAULT_PRECISION);
        let mut rec = RecordingPainter::new();
        emit_document_isolated(&mut rec, &doc, DEFAULT_PRECISION, None);
        assert_eq!(rec.commands(), whole.commands());
        assert!(fills(whole.commands()) >= 2, "the control: the whole document draws both rects");
    }

    /// As on the web: an isolation path that names an element with no mask, or
    /// no element at all, hides the document and draws nothing.
    #[test]
    fn isolating_an_unmasked_or_missing_path_draws_nothing() {
        let (doc, _) = masked_document();
        for path in [&[0usize, 1][..], &[0, 9][..], &[3][..]] {
            let mut rec = RecordingPainter::new();
            emit_document_isolated(&mut rec, &doc, DEFAULT_PRECISION, Some(path));
            assert!(rec.commands().is_empty(), "{path:?}: {:?}", rec.commands());
        }
    }

    /// The isolated-layer brackets in a command list, in order.
    fn isolated(cmds: &[Command]) -> Vec<String> {
        cmds.iter().filter_map(|c| match c {
            Command::PushIsolatedLayer { alpha, blend } => Some(format!("push_isolated({alpha},{blend:?})")),
            Command::PopIsolatedLayer => Some("pop_isolated".into()),
            _ => None,
        }).collect()
    }

    fn page_doc(isolated: bool, knockout: bool) -> Document {
        use crate::painter::BlendMode as B;
        let mut doc = doc_with(vec![with_mode(rect_at(0.0, Color::rgb(0.0, 0.5, 1.0)), B::Multiply)], B::Normal);
        doc.document_setup.page_isolated_blending = isolated;
        doc.document_setup.page_knockout_group = knockout;
        doc
    }

    /// Row 192 B1 (OPACITY.md §Page Isolated Blending): with the page
    /// isolated, the layers composite into ONE fresh transparent layer that
    /// lands on the host's target once, so a blended layer cannot blend with
    /// the page (the artboard fill the host painted beneath). The bracket is
    /// the FIRST and LAST command, around every layer, at alpha 1 and Normal.
    #[test]
    fn page_isolated_blending_brackets_every_layer_in_one_isolated_layer() {
        for walk in ["rebuild", "borrow"] {
            let doc = page_doc(true, false);
            let mut rec = RecordingPainter::new();
            match walk {
                "rebuild" => emit_document(&mut rec, &doc, DEFAULT_PRECISION),
                _ => emit_document_with_index(&mut rec, &doc, rebuild_id_index(&doc), DEFAULT_PRECISION, None),
            }
            let c = rec.commands();
            assert_eq!(isolated(c), vec!["push_isolated(1,Normal)".to_string(), "pop_isolated".into()],
                       "{walk}: one page bracket: {c:?}");
            assert!(matches!(c.first(), Some(Command::PushIsolatedLayer { .. })), "{walk}: opens first: {c:?}");
            assert!(matches!(c.last(), Some(Command::PopIsolatedLayer)), "{walk}: closes last: {c:?}");
            assert_eq!(fills(c), 1, "{walk}: the rect still paints once");
        }
    }

    /// The default page (the flag false, every old file) is today's command
    /// list: no isolated layer at all.
    #[test]
    fn a_page_that_is_not_isolated_emits_no_isolated_layer() {
        for (iso, ko) in [(false, false), (false, true)] {
            let doc = page_doc(iso, ko);
            let mut rec = RecordingPainter::new();
            emit_document(&mut rec, &doc, DEFAULT_PRECISION);
            assert!(isolated(rec.commands()).is_empty(),
                    "isolated={iso} knockout={ko}: {:?}", rec.commands());
        }
    }

    /// Mask isolation draws one mask subtree, not the page composite, so the
    /// page bracket is not applied there.
    #[test]
    fn mask_isolation_is_not_bracketed_by_the_page() {
        let (mut doc, _) = masked_document();
        doc.document_setup.page_isolated_blending = true;
        let mut rec = RecordingPainter::new();
        emit_document_isolated(&mut rec, &doc, DEFAULT_PRECISION, Some(&[0, 0]));
        assert_eq!(fills(rec.commands()), 1, "the mask subtree drew: {:?}", rec.commands());
        assert!(isolated(rec.commands()).is_empty(), "{:?}", rec.commands());
    }

    /// An empty document emits nothing at all — no stray install artefact, no
    /// bracket. (`Document::default()` is one empty root layer.)
    #[test]
    fn an_empty_document_emits_no_ops() {
        let mut rec = RecordingPainter::new();
        emit_document(&mut rec, &Document::default(), DEFAULT_PRECISION);
        assert!(rec.commands().is_empty(), "{:?}", rec.commands());
    }
}
