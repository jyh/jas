//! The selection highlight's GEOMETRY: where each control-point square goes
//! and how much to counter-scale the outline pen. Pure functions of the
//! document, moved here from the web-only `canvas::render` (re-exported there)
//! so the native frame draws the same squares the web canvas does -- the same
//! move `evaluated_bounds` made for the same reason.

use crate::document::document::Document;
use crate::geometry::element::{Element, Transform};
use crate::tool_consts::HANDLE_DRAW_SIZE;

/// Document-space control-point handle rects `(x, y, w, h)` for the element
/// at `path`.
///
/// Each rect is centered at the element-transformed control point and is a
/// constant `HANDLE_DRAW_SIZE` square, so an element's transform MOVES the
/// handles but never SCALES the handle glyphs (they stay a fixed grab size).
/// Returns `[]` for containers (Group / Layer) and Text / TextPath, which
/// carry no control-point squares (mirrors the in-transform overlay draw).
/// The caller draws these under the VIEW (pan/zoom) transform only, NOT the
/// element transform. Mirrors the Python reference `selection_handle_rects`.
pub fn selection_handle_rects(
    doc: &Document,
    path: &[usize],
) -> Vec<(f64, f64, f64, f64)> {
    if path.is_empty() {
        return Vec::new();
    }
    // Resolve the element + collect ancestor transforms (outermost first):
    // the root layer, then each intervening group on the path.
    let mut node = match doc.layers.get(path[0]) {
        Some(n) => n,
        None => return Vec::new(),
    };
    let mut ancestors: Vec<Option<Transform>> = Vec::new();
    if path.len() > 1 {
        ancestors.push(node.transform().copied()); // layer
        for &idx in &path[1..path.len() - 1] {
            node = match node.children().and_then(|c| c.get(idx)) {
                Some(n) => n,
                None => return Vec::new(),
            };
            ancestors.push(node.transform().copied());
        }
        node = match node.children().and_then(|c| c.get(path[path.len() - 1])) {
            Some(n) => n,
            None => return Vec::new(),
        };
    }
    let elem = node;
    if matches!(
        elem,
        Element::Text(_) | Element::TextPath(_) | Element::Group(_) | Element::Layer(_)
    ) {
        return Vec::new();
    }
    // Apply transforms innermost-first: the element's own transform, then each
    // ancestor outward (layer last) — matching the rendered combined CTM.
    let mut chain: Vec<Transform> = Vec::new();
    if let Some(t) = elem.transform() {
        chain.push(*t);
    }
    for t in ancestors.iter().rev() {
        if let Some(t) = t {
            chain.push(*t);
        }
    }
    let half = HANDLE_DRAW_SIZE / 2.0;
    // RESOLVED: a symbol instance measures its TARGET, so the resolver-less
    // `control_points` collapsed its four corners onto the document origin —
    // the selection BOX resolved (it goes through `element_evaluated_bbox`)
    // while its handles sat in the corner of the canvas.
    let index = crate::document::id_index::rebuild_id_index(doc);
    let resolver = crate::document::id_index::IndexResolver(&index);
    crate::geometry::element::control_points_with(elem, &resolver)
        .into_iter()
        .map(|(mut px, mut py)| {
            for t in &chain {
                let (nx, ny) = t.apply_point(px, py);
                px = nx;
                py = ny;
            }
            (px - half, py - half, HANDLE_DRAW_SIZE, HANDLE_DRAW_SIZE)
        })
        .collect()
}

/// Combined transform SCALE of the element at `path` — the geometric mean of
/// the linear part, `sqrt(|det|)`, multiplied over the element's own transform
/// and every ancestor (layer/group) transform. `det = a*d - b*c`.
///
/// The selection OUTLINE trace is drawn UNDER the element transform; dividing
/// its fixed pen width by this factor cancels the element transform's scaling,
/// so it renders at a constant size (still scaled by zoom, like the handle
/// squares). Returns `1.0` when there is no transform.
///
/// `det` is multiplicative, so the chain order does not matter — we just
/// multiply `sqrt(|det|)` of each non-identity transform on the path. Exact for
/// uniform scale, geometric-mean (acceptable) under non-uniform/shear. Mirrors
/// the Python reference `selection_outline_scale`.
pub fn selection_outline_scale(doc: &Document, path: &[usize]) -> f64 {
    if path.is_empty() {
        return 1.0;
    }
    let mut node = match doc.layers.get(path[0]) {
        Some(n) => n,
        None => return 1.0,
    };
    // Collect the element's own transform plus every ancestor (layer/group)
    // transform on the path, mirroring the Python walk.
    let mut transforms: Vec<Option<Transform>> = Vec::new();
    if path.len() > 1 {
        transforms.push(node.transform().copied()); // layer
        for &idx in &path[1..path.len() - 1] {
            node = match node.children().and_then(|c| c.get(idx)) {
                Some(n) => n,
                None => return 1.0,
            };
            transforms.push(node.transform().copied());
        }
        node = match node.children().and_then(|c| c.get(path[path.len() - 1])) {
            Some(n) => n,
            None => return 1.0,
        };
    }
    transforms.push(node.transform().copied()); // the element itself
    let mut scale = 1.0_f64;
    for t in transforms.into_iter().flatten() {
        let det = (t.a * t.d - t.b * t.c).abs();
        if det > 0.0 {
            scale *= det.sqrt();
        }
    }
    scale
}
