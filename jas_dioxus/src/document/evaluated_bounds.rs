//! Transform-aware (EVALUATED) bounding boxes.
//!
//! `Element::bounds` and `Element::geometric_bounds` report an element's own
//! coordinate-space box and ignore `common.transform` entirely. The box the
//! Properties panel shows, and the one the selection highlight is drawn
//! around, is this one: the geometric box's four corners mapped through the
//! element's own transform and every ancestor (group / layer) transform, then
//! axis-aligned.
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
    let (bx, by, bw, bh) = elem.geometric_bounds();
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
