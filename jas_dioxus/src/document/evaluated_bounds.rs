//! Transform-aware (EVALUATED) bounding boxes.
//!
//! `Element::bounds` and `Element::geometric_bounds` report an element's own
//! coordinate-space box and ignore `common.transform` entirely. The box the
//! Properties panel shows is this one: the geometric box's four corners mapped
//! through the element's own transform and every ancestor (group / layer)
//! transform, then axis-aligned. It walks the same ancestor chain as
//! `selection_handle_rects`, which is what keeps the panel's numbers agreeing
//! with the drawn selection box.
//!
//! The logic lived in `canvas::render`, which is `feature = "web"` — so it was
//! structurally unreachable from the native `algorithm_roundtrip` binary and
//! therefore ungated across the ports (CORPUS_CENSUS.md 5.1). It is native
//! here; `canvas::render` re-exports `selection_evaluated_bounds` so existing
//! call sites are unchanged, and the `element_evaluated_bounds` corpus family
//! drives `element_evaluated_bbox` in both ports.

use crate::document::document::Document;
use crate::geometry::element::Transform;

/// Axis-aligned bounding box `(x, y, w, h)` of the element at `path` in
/// DOCUMENT space: its geometric bbox corners mapped through its own transform
/// and every ancestor (group / layer) transform, then axis-aligned. Mirrors the
/// `selection_handle_rects` ancestor walk (so the Properties panel numbers match
/// the visible selection box) but applies to the four geometric-bounds corners
/// of EVERY element kind (groups / text contribute their bounds). Returns `None`
/// when `path` does not resolve.
pub fn element_evaluated_bbox(doc: &Document, path: &[usize]) -> Option<(f64, f64, f64, f64)> {
    if path.is_empty() {
        return None;
    }
    let index = crate::document::id_index::rebuild_id_index(doc);
    let mut node = doc.layers.get(path[0])?;
    let mut ancestors: Vec<Option<Transform>> = Vec::new();
    if path.len() > 1 {
        ancestors.push(node.transform().copied()); // layer
        for &idx in &path[1..path.len() - 1] {
            node = node.children().and_then(|c| c.get(idx))?;
            ancestors.push(node.transform().copied());
        }
        node = node.children().and_then(|c| c.get(path[path.len() - 1]))?;
    }
    let elem = node;
    // RESOLVEDBOUNDS: resolve the kinds whose geometry lives behind an id, so a
    // placed symbol instance reports the box it OCCUPIES rather than the
    // `(0,0,0,0)` its own struct carries. `doc` is the whole document, so the
    // index is built here rather than threaded in; this is the Properties-panel
    // path, not a per-frame one.
    let resolver = crate::document::id_index::IndexResolver(&index);
    let (bx, by, bw, bh) = match crate::geometry::element::resolved_geometric_bounds(elem, &resolver)
    {
        Some(b) => b,
        // Occupies nothing (a dangling instance, or a group of them). There is
        // no honest box to report, and `(0,0,0,0)` is what this function has
        // always returned for "nothing to show" — kept, so only the resolvable
        // case changes.
        None => (0.0, 0.0, 0.0, 0.0),
    };
    // Apply innermost-first: the element's own transform, then each ancestor
    // outward (layer last) — matching the rendered combined CTM.
    let mut chain: Vec<Transform> = Vec::new();
    if let Some(t) = elem.transform() {
        chain.push(*t);
    }
    for t in ancestors.iter().rev() {
        if let Some(t) = t {
            chain.push(*t);
        }
    }
    let mut min_x = f64::INFINITY;
    let mut min_y = f64::INFINITY;
    let mut max_x = f64::NEG_INFINITY;
    let mut max_y = f64::NEG_INFINITY;
    for (mut px, mut py) in [(bx, by), (bx + bw, by), (bx + bw, by + bh), (bx, by + bh)] {
        for t in &chain {
            let (nx, ny) = t.apply_point(px, py);
            px = nx;
            py = ny;
        }
        min_x = min_x.min(px);
        min_y = min_y.min(py);
        max_x = max_x.max(px);
        max_y = max_y.max(py);
    }
    Some((min_x, min_y, max_x - min_x, max_y - min_y))
}

/// Union `(x, y, w, h)` of every selected element's evaluated geometric bbox
/// (see [`element_evaluated_bbox`]) in DOCUMENT space — the post-transform
/// values the Properties panel shows. `(0, 0, 0, 0)` when the selection is empty
/// or nothing resolves. Mirrors the Python `selection_evaluated_bounds`.
pub fn selection_evaluated_bounds(doc: &Document) -> (f64, f64, f64, f64) {
    let mut min_x = f64::INFINITY;
    let mut min_y = f64::INFINITY;
    let mut max_x = f64::NEG_INFINITY;
    let mut max_y = f64::NEG_INFINITY;
    let mut any = false;
    for es in &doc.selection {
        if let Some((x, y, w, h)) = element_evaluated_bbox(doc, &es.path) {
            any = true;
            min_x = min_x.min(x);
            min_y = min_y.min(y);
            max_x = max_x.max(x + w);
            max_y = max_y.max(y + h);
        }
    }
    if !any {
        return (0.0, 0.0, 0.0, 0.0);
    }
    (min_x, min_y, max_x - min_x, max_y - min_y)
}

/// Ids of the artboards that hold NO artwork, in document order, already
/// filtered by the preserve-one rule — i.e. exactly what
/// `delete_empty_artboards` may remove.
///
/// The semantics are the action's own, in `workspace/actions.yaml`: *"Native
/// ports compute intersection against the element tree and delete artboards
/// with no intersecting geometry, preserving position 1 if all are empty."*
///
/// WHY A SHALLOW WALK IS CORRECT. Only each layer's top-level children are
/// tested, not every descendant. A container's evaluated box CONTAINS its
/// members' — so if a top-level element's box misses an artboard, nothing
/// inside it can hit that artboard either. Testing parents is a sound
/// over-approximation of testing the whole tree, and a cheaper one.
///
/// WHY THE PRESERVE-ONE RULE LIVES HERE and not in the YAML that consumes this:
/// a `foreach` deleting by id has no way to say "unless this is the last one".
/// Encoding it in the derivation keeps the effect list a plain mirror of
/// `delete_artboards` and makes the rule testable on its own.
// STEP 1 OF 2, and deliberately not wired yet. Exposing this in
// `active_document` and flipping `delete_empty_artboards`'s YAML must happen in
// the SAME change as JasSwift's twin: the action's effects would become a
// `foreach` over this list, and a port without the read iterates nothing and
// silently deletes nothing. Landing the YAML half alone would MANUFACTURE the
// divergence this work exists to close.
#[allow(dead_code)]
pub fn deletable_empty_artboard_ids(doc: &Document) -> Vec<String> {
    let occupied: Vec<(f64, f64, f64, f64)> = doc
        .layers
        .iter()
        .enumerate()
        .flat_map(|(li, layer)| {
            let n = layer.children().map(|c| c.len()).unwrap_or(0);
            (0..n).filter_map(move |ci| element_evaluated_bbox(doc, &[li, ci]))
        })
        .collect();

    let empty: Vec<String> = doc
        .artboards
        .iter()
        .filter(|ab| {
            !occupied.iter().any(|&(x, y, w, h)| {
                // Half-open overlap, the same predicate `rects_intersect` uses:
                // an element merely TOUCHING an artboard edge occupies no area
                // inside it and must not keep the artboard alive.
                x < ab.x + ab.width
                    && x + w > ab.x
                    && y < ab.y + ab.height
                    && y + h > ab.y
            })
        })
        .map(|ab| ab.id.clone())
        .collect();

    // Preserve position 1 when EVERY artboard is empty: a document always has
    // at least one artboard (`ensure_artboards_invariant`), so deleting them
    // all would break that invariant rather than tidy the document.
    if !doc.artboards.is_empty() && empty.len() == doc.artboards.len() {
        return empty[1..].to_vec();
    }
    empty
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::element::{CommonProps, Element, LayerElem, RectElem};
    use crate::geometry::live::{ElementRef, LiveVariant, ReferenceElem};
    use std::rc::Rc;

    /// A master rect at (5,7,10,20) in `doc.symbols`, one instance of it at
    /// [0,0]. The instance carries no coordinates of its own.
    fn doc_with_instance() -> Document {
        let master = Element::Rect(RectElem {
            x: 5.0, y: 7.0, width: 10.0, height: 20.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, fill_gradient: None, stroke_gradient: None,
            common: CommonProps { id: Some("m1".into()), ..CommonProps::default() },
        });
        let instance = Element::Live(LiveVariant::Reference(ReferenceElem::new(
            ElementRef("m1".into()),
            CommonProps { id: Some("i1".into()), ..CommonProps::default() },
        )));
        let mut doc = Document::default();
        doc.symbols.push(master);
        doc.layers = vec![Element::Layer(LayerElem {
            children: vec![Rc::new(instance)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        })];
        doc
    }

    /// A group holding that same instance plus a rect at (100,100,10,10).
    /// GROUPPHANTOM: the OUTLINE a selected container draws. A group's box is
    /// the union of its children, so an instance child's zero box is not
    /// absent — it is a phantom point AT THE ORIGIN that the union swallows,
    /// and the group's outline stretches back across empty canvas to (0,0).
    /// This is the value `draw_selection_overlays` strokes for a container.
    #[test]
    fn a_selected_group_holding_an_instance_does_not_stretch_to_the_origin() {
        let doc = doc_with_group_holding_instance();
        let group = doc.get_element(&vec![0, 0]).expect("the group");
        let index = crate::document::id_index::rebuild_id_index(&doc);
        let resolver = crate::document::id_index::IndexResolver(&index);

        let resolved = crate::geometry::element::resolved_bounds_with(
            group, &resolver, Element::bounds,
        )
        .expect("a group with drawn members has a box");
        // Members: the instance at (5,7,10,20) and a rect at (100,100,10,10).
        assert_eq!(
            resolved,
            (5.0, 7.0, 105.0, 103.0),
            "the outline bounds what is DRAWN, and reaches the origin only if \
             something is drawn there"
        );
        // The un-resolved union is what shipped, and it starts at the origin.
        let (bx, by, _, _) = group.bounds();
        assert_eq!(
            (bx, by),
            (0.0, 0.0),
            "the narrow form still answers from the origin — that is why the \
             overlay must ask the resolved one"
        );
    }

    /// HANDLEPHANTOM: the four resize handles a selected instance shows.
    ///
    /// `selection_evaluated_bounds` resolves (it goes through
    /// `element_evaluated_bbox`), so the selection BOX lands on the artwork.
    /// The HANDLES come from `control_points`, whose catch-all reads the
    /// resolver-less `bounds()` — so they stack on top of each other at the
    /// document origin while the box sits correctly around the shape.
    #[test]
    fn a_selected_instance_gets_handles_on_its_artwork_not_at_the_origin() {
        let doc = doc_with_instance();
        let instance = doc.get_element(&vec![0, 0]).expect("the instance");
        let box_ = element_evaluated_bbox(&doc, &[0, 0]).expect("a resolved box");
        assert_eq!(box_, (5.0, 7.0, 10.0, 20.0), "the selection box resolves");

        let index = crate::document::id_index::rebuild_id_index(&doc);
        let resolver = crate::document::id_index::IndexResolver(&index);
        let cps = crate::geometry::element::control_points_with(instance, &resolver);
        assert_eq!(
            cps,
            vec![(5.0, 7.0), (15.0, 7.0), (15.0, 27.0), (5.0, 27.0)],
            "the handles sit on the corners of the box the artist can see"
        );
    }

    /// FITPHANTOM: what `Fit in Window` actually sees. The document holds ONE
    /// symbol instance whose master is a rect at (5,7,10,20) — so the artwork
    /// occupies exactly that box and nothing is anywhere near the origin.
    #[test]
    fn document_bounds_must_not_invent_a_point_at_the_origin() {
        let doc = doc_with_instance();
        let (x, y, w, h) = doc.bounds();
        assert_eq!(
            (x, y, w, h),
            (5.0, 7.0, 10.0, 20.0),
            "Fit in Window frames the ARTWORK; a live element that answers \
             (0,0,0,0) drags the frame back to the origin"
        );
    }

    /// And the union case: an instance beside a distant rect must not stretch
    /// the frame back to (0,0), and a dangling reference must contribute
    /// nothing rather than the origin.
    #[test]
    fn document_bounds_union_skips_what_resolves_to_nothing() {
        let mut doc = doc_with_instance();
        let dangling = Element::Live(LiveVariant::Reference(ReferenceElem::new(
            ElementRef("gone".into()),
            CommonProps { id: Some("i2".into()), ..CommonProps::default() },
        )));
        let far = Element::Rect(RectElem {
            x: 100.0, y: 100.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, fill_gradient: None, stroke_gradient: None,
            common: CommonProps::default(),
        });
        if let Element::Layer(l) = &mut doc.layers[0] {
            l.children.push(Rc::new(dangling));
            l.children.push(Rc::new(far));
        }
        assert_eq!(
            doc.bounds(),
            (5.0, 7.0, 105.0, 103.0),
            "the resolved instance and the far rect bound it; a dangling \
             reference contributes nothing, not the origin"
        );
    }

    fn doc_with_group_holding_instance() -> Document {
        let mut doc = doc_with_instance();
        let sibling = Element::Rect(RectElem {
            x: 100.0, y: 100.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, fill_gradient: None, stroke_gradient: None,
            common: CommonProps::default(),
        });
        let inner = doc.layers[0].children().unwrap()[0].clone();
        let group = Element::Group(crate::geometry::element::GroupElem {
            children: vec![inner, Rc::new(sibling)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        doc.layers = vec![Element::Layer(LayerElem {
            children: vec![Rc::new(group)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        })];
        doc
    }

    #[test]
    fn a_placed_symbol_instance_reports_the_box_it_occupies() {
        // Measured before the repair: (0,0,0,0) — the Properties panel showed
        // X/Y/W/H all zero for a shape plainly sitting at (5,7).
        let doc = doc_with_instance();
        let got = element_evaluated_bbox(&doc, &[0, 0]).expect("instance resolves");
        for (g, w) in [(got.0, 5.0), (got.1, 7.0), (got.2, 10.0), (got.3, 20.0)] {
            assert!((g - w).abs() < 1e-9, "expected (5,7,10,20), got {got:?}");
        }
    }

    #[test]
    fn a_group_holding_an_instance_is_not_stretched_back_to_the_origin() {
        // Measured before the repair: (0,0,110,110). The instance contributed a
        // zero box AT THE ORIGIN, and the union swallowed it — so the group's
        // selection box reached back to (0,0) across empty canvas.
        let doc = doc_with_group_holding_instance();
        let got = element_evaluated_bbox(&doc, &[0, 0]).expect("group resolves");
        for (g, w) in [(got.0, 5.0), (got.1, 7.0), (got.2, 105.0), (got.3, 103.0)] {
            assert!((g - w).abs() < 1e-9, "expected (5,7,105,103), got {got:?}");
        }
    }

    #[test]
    fn a_dangling_instance_still_reports_nothing() {
        // REFERENCE_GRAPH.md §3: an unresolvable target evaluates to empty. It
        // draws nothing, so there is no honest box — and this function has
        // always answered (0,0,0,0) for "nothing to show". Unchanged, so only
        // the RESOLVABLE case moved.
        let mut doc = doc_with_instance();
        doc.symbols.clear();
        assert_eq!(element_evaluated_bbox(&doc, &[0, 0]), Some((0.0, 0.0, 0.0, 0.0)));
    }

    #[test]
    fn a_group_of_only_dangling_instances_does_not_claim_the_origin() {
        // The union must SKIP what occupies nothing rather than fold in a point
        // at (0,0) — otherwise the group claims a corner of the canvas that
        // nothing is drawn in.
        let mut doc = doc_with_group_holding_instance();
        doc.symbols.clear();
        let got = element_evaluated_bbox(&doc, &[0, 0]).expect("group resolves");
        for (g, w) in [(got.0, 100.0), (got.1, 100.0), (got.2, 10.0), (got.3, 10.0)] {
            assert!((g - w).abs() < 1e-9, "expected the sibling alone, got {got:?}");
        }
    }

    #[test]
    fn the_resolverless_methods_keep_answering_zero_for_an_instance() {
        // The forbidden fix, pinned (same guard as CONTAINERPAINT and
        // RESOLVEDHIT): widening `Element::bounds` / `geometric_bounds` would
        // make them answer a question they cannot see. They stay resolver-less
        // and they stay AGREEING WITH EACH OTHER.
        let doc = doc_with_instance();
        let inst = &doc.layers[0].children().unwrap()[0];
        assert_eq!(inst.bounds(), (0.0, 0.0, 0.0, 0.0));
        assert_eq!(inst.geometric_bounds(), (0.0, 0.0, 0.0, 0.0));
    }

    // ── delete_empty_artboards: the derivation the action consumes ──────────

    use crate::document::artboard::Artboard;

    fn ab(id: &str, x: f64, y: f64) -> Artboard {
        Artboard { id: id.into(), name: id.into(), x, y, width: 100.0, height: 100.0,
                   ..Artboard::default_with_id(id.into()) }
    }

    fn doc_with(artboards: Vec<Artboard>, elements: Vec<Element>) -> Document {
        let mut doc = Document::default();
        doc.artboards = artboards;
        doc.layers = vec![Element::Layer(LayerElem {
            children: elements.into_iter().map(Rc::new).collect(),
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        })];
        doc
    }

    fn rect_at(x: f64, y: f64) -> Element {
        Element::Rect(RectElem {
            x, y, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, fill_gradient: None, stroke_gradient: None,
            common: CommonProps::default(),
        })
    }

    #[test]
    fn an_artboard_holding_artwork_is_not_deletable() {
        let doc = doc_with(vec![ab("a", 0.0, 0.0)], vec![rect_at(5.0, 5.0)]);
        assert!(deletable_empty_artboard_ids(&doc).is_empty());
    }

    #[test]
    fn an_artboard_holding_nothing_is_deletable() {
        // Artwork sits on "a"; "b" is 500 away and holds nothing.
        let doc = doc_with(vec![ab("a", 0.0, 0.0), ab("b", 500.0, 0.0)],
                           vec![rect_at(5.0, 5.0)]);
        assert_eq!(deletable_empty_artboard_ids(&doc), vec!["b".to_string()]);
    }

    #[test]
    fn when_every_artboard_is_empty_position_one_survives() {
        // The action's own rule: "preserving position 1 if all are empty".
        // A document must keep at least one artboard, so emptying them all is
        // not a tidy-up, it is a broken invariant.
        let doc = doc_with(vec![ab("a", 0.0, 0.0), ab("b", 500.0, 0.0), ab("c", 900.0, 0.0)],
                           vec![]);
        assert_eq!(deletable_empty_artboard_ids(&doc),
                   vec!["b".to_string(), "c".to_string()]);
    }

    #[test]
    fn an_element_merely_touching_an_edge_does_not_occupy_the_artboard() {
        // Artboard "b" spans x 500..600; the rect ends exactly at x=500 and so
        // covers no area inside it. Half-open, matching `rects_intersect`.
        let doc = doc_with(vec![ab("a", 0.0, 0.0), ab("b", 500.0, 0.0)],
                           vec![rect_at(490.0, 5.0)]);
        assert_eq!(deletable_empty_artboard_ids(&doc), vec!["b".to_string()]);
    }

    #[test]
    fn a_transformed_element_is_found_where_it_is_drawn() {
        // The whole reason this reads element_evaluated_bbox rather than
        // `bounds()`: a rect authored at the origin but TRANSFORMED onto "b"
        // occupies "b", and leaves "a" empty.
        let mut moved = rect_at(0.0, 0.0);
        moved.common_mut().transform = Some(Transform { a: 1.0, b: 0.0, c: 0.0, d: 1.0,
                                                        e: 520.0, f: 20.0 });
        let doc = doc_with(vec![ab("a", 0.0, 0.0), ab("b", 500.0, 0.0)], vec![moved]);
        assert_eq!(deletable_empty_artboard_ids(&doc), vec!["a".to_string()]);
    }
}
