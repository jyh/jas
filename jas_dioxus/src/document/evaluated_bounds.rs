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
}
