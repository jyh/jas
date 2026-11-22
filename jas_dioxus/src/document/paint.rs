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
use crate::painter::element_render::{emit_element, OpaqueShape};
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
/// items, rows 192 B1 and 209).
///
/// * `page_isolated_blending` — the layers composite into ONE fresh transparent
///   layer (the A6 op `push_isolated_layer`, alpha 1 and Normal) that lands on
///   the target once, so a blended layer blends with the layers beneath it but
///   never with the page the host painted (the artboard fill).
/// * `page_knockout_group` — the layers are the children of ONE knockout group
///   (AMENDMENT A7): each top-level layer is a child, emitted twice — first as
///   its SHAPE, through [`OpaqueShape`], inside `push_knockout_shape` /
///   `pop_knockout_shape`, then as its body — so each layer composites against
///   the page's initial backdrop `B0` (what the host painted), never against
///   the layers beneath it.
/// * both — the knockout bracket inside the isolated layer, where `B0` is
///   transparent.
///
/// Per-group `knockout_group` stays storage-only: only the page is lowered.
fn emit_layers(p: &mut dyn Painter, doc: &Document) {
    let isolated = doc.document_setup.page_isolated_blending;
    let knockout = doc.document_setup.page_knockout_group;
    if isolated {
        p.push_isolated_layer(1.0, crate::painter::BlendMode::Normal);
    }
    if knockout {
        p.push_knockout_layer();
    }
    for layer in &doc.layers {
        if knockout {
            p.push_knockout_shape();
            emit_element(&mut OpaqueShape::new(p), layer, 1.0);
            p.pop_knockout_shape();
        }
        emit_element(p, layer, 1.0);
    }
    if knockout {
        p.pop_knockout_layer();
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

/// THE `a7_knockout` SCENE (design block §5), shared by every Rust arm that
/// renders it: the recorder golden here, the Canvas2D arms
/// (`canvas::render`, `painter::canvas2d`) and the Direct2D arm.
///
/// Backdrop `B0 = (0.8, 0.8, 0.2)` opaque, painted by the HOST before the
/// walk (not white, not saturated: over white "knockout" and "both" coincide,
/// and a saturated channel hides mutant 6's brightening). Layer 1: an opaque
/// red rect, x ∈ [0, 20). Layer 2: one leaf, colour (0, 0.5, 1), element
/// opacity 0.5, blend Multiply, x ∈ [10, 30): half over layer 1, half over
/// bare backdrop. The alpha and the blend sit on the LEAF (a container's own
/// mode is inert, and C2 dies only if the alpha is inside the child).
///
/// ⛔ THE BLOCK'S §5 TABLE IS NEVER TYPED HERE. [`expect`] computes every
/// expectation from these inputs by the law; see its doc comment.
#[cfg(test)]
pub(crate) mod a7_fixture {
    use crate::document::document::Document;
    use crate::geometry::element::{BlendMode, Color, CommonProps, Element, Fill, RectElem};
    use std::rc::Rc;

    pub const W: u32 = 40;
    pub const H: u32 = 10;
    pub const B0: [f64; 3] = [0.8, 0.8, 0.2];
    pub const RED: [f64; 3] = [1.0, 0.0, 0.0];
    pub const LEAF: [f64; 3] = [0.0, 0.5, 1.0];
    pub const LEAF_OPACITY: f64 = 0.5;
    /// Sample pixels (device x, at y = 5): over layer 1, over bare backdrop,
    /// and outside every shape (mutant 6's pixel).
    pub const OVERLAP_X: u32 = 15;
    pub const LEAF_X: u32 = 25;
    pub const OUTSIDE_X: u32 = 35;
    pub const Y: u32 = 5;
    /// The edge arms: layer 2 starting at x = 10.5, so pixel 10 is half
    /// covered, over layer 1's opaque red.
    pub const EDGE_X: u32 = 10;
    pub const BLUE: [f64; 3] = [0.0, 0.0, 1.0];

    /// Layer 2 of each edge arm (addendum A7.1 §4): (name, colour, element
    /// opacity, blend). E1 separates A7.1 from the ratified child term but
    /// EQUALS ordinary compositing, so a no-op bracket passes it; E2 and E3
    /// separate all three (see [`assert_edge_arms_separate`]).
    pub const EDGES: [(&str, [f64; 3], f64, BlendMode); 3] = [
        ("E1 opaque Normal blue", BLUE, 1.0, BlendMode::Normal),
        ("E2 Normal blue at 0.5", BLUE, 0.5, BlendMode::Normal),
        ("E3 the Multiply leaf at 0.5", LEAF, LEAF_OPACITY, BlendMode::Multiply),
    ];

    fn rect(x: f64, w: f64, color: [f64; 3], opacity: f64, mode: BlendMode) -> Element {
        Element::Rect(RectElem {
            x, y: 0.0, width: w, height: H as f64, rx: 0.0, ry: 0.0,
            fill: Some(Fill { color: Color::rgb(color[0], color[1], color[2]), opacity: 1.0 }),
            stroke: None,
            common: CommonProps { opacity, mode, ..CommonProps::default() },
            fill_gradient: None, stroke_gradient: None,
        })
    }

    fn two_layers(l1: Element, l2: Element, isolated: bool, knockout: bool) -> Document {
        let mut doc = Document::default();
        let second = doc.layers[0].clone();
        doc.layers.push(second);
        doc.layers[0].children_mut().unwrap().push(Rc::new(l1));
        doc.layers[1].children_mut().unwrap().push(Rc::new(l2));
        doc.document_setup.page_isolated_blending = isolated;
        doc.document_setup.page_knockout_group = knockout;
        doc
    }

    /// The §5 scene under the page flags.
    pub fn document(isolated: bool, knockout: bool) -> Document {
        two_layers(
            rect(0.0, 20.0, RED, 1.0, BlendMode::Normal),
            rect(10.0, 20.0, LEAF, LEAF_OPACITY, BlendMode::Multiply),
            isolated, knockout,
        )
    }

    /// An edge arm's scene: layer 1 opaque red, layer 2 the arm's leaf
    /// ([`EDGES`]) with its left edge on a half pixel.
    pub fn edge_document(arm: usize, isolated: bool, knockout: bool) -> Document {
        let (_, c, opacity, mode) = EDGES[arm];
        two_layers(
            rect(0.0, 20.0, RED, 1.0, BlendMode::Normal),
            rect(10.5, 19.5, c, opacity, mode),
            isolated, knockout,
        )
    }

    /// The four regimes, in (isolated, knockout) order.
    pub const REGIMES: [(&str, bool, bool); 4] = [
        ("neither", false, false),
        ("isolated", true, false),
        ("knockout", false, true),
        ("both", true, true),
    ];

    type P = [f64; 4];

    /// Source `c` (straight colour) at alpha `a` composited onto premultiplied
    /// `dst` under `blend` — the W3C compositing formula, premultiplied:
    /// `co = cs·(1 − αb) + cb·(1 − αs) + αs·αb·B(Cb, Cs)`,
    /// `αo = αs + αb·(1 − αs)`, with `B(Cb, Cs) = Cs` for Normal and
    /// `Cb·Cs` for Multiply (`Cb` the backdrop's straight colour).
    fn composite(dst: P, c: [f64; 3], a: f64, blend: BlendMode) -> P {
        let ab = dst[3];
        let cb = |i: usize| if ab > 0.0 { dst[i] / ab } else { 0.0 };
        let mut out = [0.0; 4];
        for i in 0..3 {
            let mixed = match blend {
                BlendMode::Multiply => cb(i) * c[i],
                _ => c[i],
            };
            out[i] = a * c[i] * (1.0 - ab) + dst[i] * (1.0 - a) + a * ab * mixed;
        }
        out[3] = a + ab * (1.0 - a);
        out
    }

    /// `src` (premultiplied) source-over `dst` (premultiplied).
    fn over(src: P, dst: P) -> P {
        let k = 1.0 - src[3];
        [src[0] + k * dst[0], src[1] + k * dst[1], src[2] + k * dst[2], src[3] + k * dst[3]]
    }

    /// One child at one pixel: straight colour, element opacity, blend, and
    /// geometric coverage of the pixel.
    pub type Child = ([f64; 3], f64, BlendMode, f64);

    /// The knockout child term: the law of record, or the superseded one.
    #[derive(Clone, Copy, PartialEq, Eq, Debug)]
    pub enum ChildTerm {
        /// A7.1 (ratified 11-22): `S ← (1 − f)·S + [T − (1 − f)·B0]`.
        A71,
        /// A7 as first ratified: `S ← (1 − f)·S + f·T`. `T` already holds
        /// the body at coverage `f`, so this counts `f` twice and leaves
        /// `f·(1 − f)·B0` on every antialiased edge. Kept ONLY so the edge
        /// arms can prove they separate it (mutant M8); nothing renders it.
        Ratified,
    }

    /// ⭐ THE EXPECTATION, DERIVED BY THE LAW (never typed). Per pixel,
    /// premultiplied, `B0` opaque:
    ///
    /// * NEITHER: every child composites onto the live surface, `S ← c(S, E_i)`
    ///   (its effective alpha is opacity × coverage).
    /// * ISOLATED (A6): the children composite onto a transparent `L`, then
    ///   `L` source-over `B0`.
    /// * KNOCKOUT (A7.1): `S ← B0`, then for each child
    ///   `T_i = c(B0, E_i)` and `S ← (1 − f_i)·S + [T_i − (1 − f_i)·B0]`,
    ///   `f_i` = coverage (a SHAPE, never the alpha). The bracket is `f·T*`,
    ///   the body at alpha `α/f` weighted by its shape (addendum A7.1 §1):
    ///   coverage counts ONCE. Interior pixels (`f ∈ {0, 1}`) equal A7's.
    /// * BOTH: the knockout law with `B0` transparent, the result source-over
    ///   the real `B0`.
    ///
    /// Returns 0–255 straight RGB, rounded, as a canvas read-back reports it
    /// for an opaque pixel.
    pub fn expect(isolated: bool, knockout: bool, children: &[Child]) -> [i32; 3] {
        expect_by(isolated, knockout, children, ChildTerm::A71)
    }

    /// [`expect`] under a chosen child term.
    pub fn expect_by(isolated: bool, knockout: bool, children: &[Child], term: ChildTerm) -> [i32; 3] {
        let b0: P = [B0[0], B0[1], B0[2], 1.0];
        let start: P = if isolated { [0.0; 4] } else { b0 };
        let mut s = start;
        for &(c, opacity, blend, cov) in children {
            let a = opacity * cov;
            if knockout {
                let t = composite(start, c, a, blend);
                for i in 0..4 {
                    s[i] = match term {
                        ChildTerm::A71 => (1.0 - cov) * s[i] + t[i] - (1.0 - cov) * start[i],
                        ChildTerm::Ratified => (1.0 - cov) * s[i] + cov * t[i],
                    };
                }
            } else {
                s = composite(s, c, a, blend);
            }
        }
        let out = if isolated { over(s, b0) } else { s };
        let a = out[3];
        [0, 1, 2].map(|i| ((out[i] / a).clamp(0.0, 1.0) * 255.0).round() as i32)
    }

    /// The children at each §5 sample pixel.
    pub fn children_at(x: u32) -> Vec<Child> {
        let mut v = Vec::new();
        let cx = x as f64 + 0.5;
        if (0.0..20.0).contains(&cx) {
            v.push((RED, 1.0, BlendMode::Normal, 1.0));
        } else {
            // Layer 1 does not cover the pixel: a child with an EMPTY shape,
            // which under knockout leaves S unchanged (f = 0).
            v.push((RED, 1.0, BlendMode::Normal, 0.0));
        }
        let cov = if (10.0..30.0).contains(&cx) { 1.0 } else { 0.0 };
        v.push((LEAF, LEAF_OPACITY, BlendMode::Multiply, cov));
        v
    }

    /// The children at an edge arm's pixel: layer 1 covers it, layer 2 (the
    /// arm's leaf) covers HALF of it.
    pub fn edge_children(arm: usize) -> Vec<Child> {
        let (_, c, opacity, mode) = EDGES[arm];
        vec![(RED, 1.0, BlendMode::Normal, 1.0), (c, opacity, mode, 0.5)]
    }

    /// ⭐ THE EDGE ARMS' POWER, asserted rather than inferred (addendum A7.1
    /// §4): at EDGE_X, under the knockout regime, E1 separates A7.1 from the
    /// ratified child term, and E2 and E3 each separate all three of
    /// ordinary, A7.1 and ratified pairwise, by more than twice the arm's
    /// tolerance, so a read-back within TOL of one cannot be within TOL of
    /// another. Run natively by `a7_the_derivation_separates_the_regimes`.
    pub fn assert_edge_arms_separate() {
        for (arm, &(name, ..)) in EDGES.iter().enumerate() {
            let ch = edge_children(arm);
            let ordinary = expect(false, false, &ch);
            let a71 = expect(false, true, &ch);
            let ratified = expect_by(false, true, &ch, ChildTerm::Ratified);
            assert!(off(a71, ratified) > 2 * TOL,
                    "{name}: A7.1 {a71:?} and the ratified term {ratified:?} are not separable");
            if arm > 0 {
                assert!(off(a71, ordinary) > 2 * TOL && off(ordinary, ratified) > 2 * TOL,
                        "{name}: ordinary {ordinary:?}, A7.1 {a71:?}, ratified {ratified:?} \
                         are not pairwise separable");
            }
        }
    }

    /// Largest per-channel distance between a read-back and an expectation.
    pub fn off(got: [i32; 3], want: [i32; 3]) -> i32 {
        (0..3).map(|i| (got[i] - want[i]).abs()).max().unwrap()
    }

    /// The tolerance every pixel arm uses: 8-bit stores round at each of the
    /// bracket's passes (design block §2).
    pub const TOL: i32 = 3;

    /// ⭐ THE SELF-TEST OF THE DERIVATION: the four regimes are pairwise
    /// distinct at the overlap pixel and the leaf pixel taken together, and
    /// "knockout" differs from "both" (which a white backdrop would
    /// collapse). Run natively by `a7_the_derivation_separates_the_regimes`.
    pub fn assert_regimes_distinct() {
        let rows: Vec<(&str, [i32; 3], [i32; 3])> = REGIMES.iter()
            .map(|&(n, i, k)| (n, expect(i, k, &children_at(OVERLAP_X)), expect(i, k, &children_at(LEAF_X))))
            .collect();
        for a in 0..rows.len() {
            for b in a + 1..rows.len() {
                let d = off(rows[a].1, rows[b].1).max(off(rows[a].2, rows[b].2));
                assert!(d > 2 * TOL, "{} and {} are not separable by the arm ({d}): {rows:?}",
                        rows[a].0, rows[b].0);
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

    // ═══════════════════════════════════════════════════════════════════════
    // A7 — THE PAGE KNOCKOUT GROUP (row 209). The recorder arms: bracket
    // order and opaque shape artwork. They see no pixels, so they are never
    // the only arm (the pixel arms are in canvas::render, painter::canvas2d,
    // painter::direct2d and JasSwift's PageKnockoutTests).
    // ═══════════════════════════════════════════════════════════════════════

    use super::a7_fixture;

    /// The A6/A7 bracket ops in a command list, in order.
    fn brackets(cmds: &[Command]) -> Vec<&'static str> {
        cmds.iter().filter_map(|c| Some(match c {
            Command::PushIsolatedLayer { .. } => "push_isolated",
            Command::PopIsolatedLayer => "pop_isolated",
            Command::PushKnockoutLayer => "push_knockout",
            Command::PushKnockoutShape => "push_shape",
            Command::PopKnockoutShape => "pop_shape",
            Command::PopKnockoutLayer => "pop_knockout",
            _ => return None,
        })).collect()
    }

    /// Every paint op's (brush alpha, paint alpha) and every group's
    /// (alpha, blend), so a span can be asserted opaque or not.
    fn alphas(cmds: &[Command]) -> Vec<String> {
        let brush_a = |b: &crate::painter::Brush| match b {
            crate::painter::Brush::Solid(c) => c.to_rgba().3,
            _ => -1.0,
        };
        cmds.iter().filter_map(|c| match c {
            Command::FillRect { brush, paint_alpha, .. }
            | Command::FillPath { brush, paint_alpha, .. } => Some(format!("paint({},{})", brush_a(brush), paint_alpha)),
            Command::PushGroup { alpha, blend } => Some(format!("group({alpha},{blend:?})")),
            _ => None,
        }).collect()
    }

    /// The spans between `push_knockout_shape` and `pop_knockout_shape` (the
    /// shapes) and between `pop_knockout_shape` and the next shape push or the
    /// layer's pop (the bodies).
    fn spans(cmds: &[Command]) -> (Vec<Vec<Command>>, Vec<Vec<Command>>) {
        let (mut shapes, mut bodies) = (Vec::new(), Vec::new());
        let mut cur: Option<(bool, Vec<Command>)> = None;
        for c in cmds {
            match c {
                Command::PushKnockoutShape | Command::PopKnockoutLayer => {
                    if let Some((false, b)) = cur.take() { bodies.push(b); }
                    if matches!(c, Command::PushKnockoutShape) { cur = Some((true, Vec::new())); }
                }
                Command::PopKnockoutShape => {
                    if let Some((true, sh)) = cur.take() { shapes.push(sh); }
                    cur = Some((false, Vec::new()));
                }
                other => if let Some((_, v)) = cur.as_mut() { v.push(other.clone()); },
            }
        }
        (shapes, bodies)
    }

    /// ⭐ THE DERIVATION SEPARATES THE FOUR REGIMES (design block §5: "the four
    /// rows differ as pairs"). Computed from the scene's inputs by the law in
    /// `a7_fixture::expect`, never typed; printed so a reader can hold it
    /// against the block's own arithmetic.
    #[test]
    fn a7_the_derivation_separates_the_regimes() {
        for (name, iso, ko) in a7_fixture::REGIMES {
            eprintln!("a7 {name}: overlap {:?} leaf {:?} outside {:?} edge {:?}",
                a7_fixture::expect(iso, ko, &a7_fixture::children_at(a7_fixture::OVERLAP_X)),
                a7_fixture::expect(iso, ko, &a7_fixture::children_at(a7_fixture::LEAF_X)),
                a7_fixture::expect(iso, ko, &a7_fixture::children_at(a7_fixture::OUTSIDE_X)),
                a7_fixture::expect(iso, ko, &a7_fixture::edge_children(0)));
        }
        for (arm, &(name, ..)) in a7_fixture::EDGES.iter().enumerate() {
            let ch = a7_fixture::edge_children(arm);
            eprintln!("a7.1 {name}: ordinary {:?} A7.1 {:?} ratified {:?} both {:?}",
                a7_fixture::expect(false, false, &ch),
                a7_fixture::expect(false, true, &ch),
                a7_fixture::expect_by(false, true, &ch, a7_fixture::ChildTerm::Ratified),
                a7_fixture::expect(true, true, &ch));
        }
        a7_fixture::assert_regimes_distinct();
        a7_fixture::assert_edge_arms_separate();
        // The knockout overlap is the leaf over B0, which is the NEITHER row's
        // leaf pixel: the arm's whole claim (nothing of layer 1 survives).
        assert_eq!(a7_fixture::expect(false, true, &a7_fixture::children_at(a7_fixture::OVERLAP_X)),
                   a7_fixture::expect(false, false, &a7_fixture::children_at(a7_fixture::LEAF_X)));
    }

    /// The page knockout group: ONE bracket around the layer loop, one child
    /// per top-level layer (shape, then body), A7 INSIDE A6 when both flags
    /// are set, and nothing at all when the flag is false.
    #[test]
    fn page_knockout_brackets_one_child_per_layer_inside_the_isolated_layer() {
        let child = ["push_shape", "pop_shape"];
        let ko: Vec<&str> = std::iter::once("push_knockout")
            .chain(child).chain(child).chain(std::iter::once("pop_knockout")).collect();
        for (name, iso, knock) in a7_fixture::REGIMES {
            let mut rec = RecordingPainter::new();
            emit_document(&mut rec, &a7_fixture::document(iso, knock), DEFAULT_PRECISION);
            let mut want: Vec<&str> = Vec::new();
            if iso { want.push("push_isolated"); }
            if knock { want.extend(ko.iter().copied()); }
            if iso { want.push("pop_isolated"); }
            assert_eq!(brackets(rec.commands()), want, "{name}: {:?}", rec.commands());
            if knock {
                assert!(matches!(rec.commands().last(),
                                 Some(Command::PopKnockoutLayer | Command::PopIsolatedLayer)),
                        "{name}: the bracket closes last");
            }
        }
    }

    /// ⛔ THE SHAPE IS THE CALLER'S, AND IT IS OPAQUE: every paint inside a
    /// shape span carries brush alpha 1 and paint alpha 1 and no group blend,
    /// while the body after it is the layer's ordinary emission (the 0.5 and
    /// the Multiply). The shape must also be the SAME GEOMETRY as the body.
    #[test]
    fn each_knockout_shape_is_its_bodys_geometry_forced_opaque() {
        let mut rec = RecordingPainter::new();
        emit_document(&mut rec, &a7_fixture::document(false, true), DEFAULT_PRECISION);
        let (shapes, bodies) = spans(rec.commands());
        assert_eq!((shapes.len(), bodies.len()), (2, 2), "{:?}", rec.commands());
        for (i, (sh, body)) in shapes.iter().zip(&bodies).enumerate() {
            for a in alphas(sh) {
                assert!(a == "paint(1,1)" || a == "group(1,Normal)",
                        "child {i}: a shape op is not opaque: {a} in {sh:?}");
            }
            let geo = |v: &[Command]| v.iter().filter_map(|c| match c {
                Command::FillRect { rect, .. } => Some(format!("{rect:?}")),
                Command::FillPath { path, .. } => Some(format!("{path:?}")),
                _ => None,
            }).collect::<Vec<_>>();
            assert!(!geo(sh).is_empty(), "child {i}: the shape paints nothing");
            assert_eq!(geo(sh), geo(body), "child {i}: the shape is not the body's geometry");
        }
        // CONTROL: the body of layer 2 is NOT opaque, so the check above can fail.
        let body2 = alphas(&bodies[1]);
        assert!(body2.iter().any(|a| a.contains("0.5") || a.contains("Multiply")),
                "CONTROL: layer 2's body carries its 0.5 and its Multiply: {body2:?}");
    }

    /// ⚖️ A MASK DOES NOT REDUCE SHAPE (ratified with A7): a masked element's
    /// shape is its own geometry, the mask bracket and artwork dropped, while
    /// the body keeps the mask.
    #[test]
    fn a_masked_layers_shape_drops_the_mask() {
        let (mut doc, _) = masked_document();
        doc.document_setup.page_knockout_group = true;
        let mut rec = RecordingPainter::new();
        emit_document(&mut rec, &doc, DEFAULT_PRECISION);
        let (shapes, bodies) = spans(rec.commands());
        let masks = |v: &[Command]| v.iter().filter(|c| matches!(c, Command::PushMaskLayer { .. })).count();
        assert_eq!(masks(&bodies[0]), 1, "CONTROL: the body keeps its mask: {:?}", bodies[0]);
        assert_eq!(masks(&shapes[0]), 0, "the shape carries no mask: {:?}", shapes[0]);
        assert_eq!(fills(&shapes[0]), 2, "the shape is both rects' geometry, the mask's not: {:?}", shapes[0]);
    }

    const A7_KNOCKOUT: &str = include_str!("../painter/testdata/a7_knockout.json");

    /// THE CORPUS SCENE IS THE WALK'S OUTPUT: `a7_knockout.json` is the page
    /// knockout walk of the §5 scene, recorded, so every backend's corpus lane
    /// replays exactly what the native walk emits (the host's backdrop is not
    /// in it: `B0` is what the target holds when the bracket opens).
    #[test]
    fn the_a7_corpus_scene_is_the_page_knockout_walk() {
        let mut rec = RecordingPainter::new();
        emit_document(&mut rec, &a7_fixture::document(false, true), DEFAULT_PRECISION);
        assert_eq!(rec.to_canonical_json().trim(), A7_KNOCKOUT.trim());
    }

    #[test]
    #[ignore = "regeneration tool, not a gate"]
    fn regenerate_a7_corpus_scene() {
        let mut rec = RecordingPainter::new();
        emit_document(&mut rec, &a7_fixture::document(false, true), DEFAULT_PRECISION);
        let mut json = rec.to_canonical_json();
        json.push('\n');
        std::fs::write(concat!(env!("CARGO_MANIFEST_DIR"), "/src/painter/testdata/a7_knockout.json"), json)
            .expect("write the A7 corpus scene");
    }
}
