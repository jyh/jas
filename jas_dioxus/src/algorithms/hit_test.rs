//! Geometry helpers for precise hit-testing.
//!
//! Pure-geometry functions used by the controller for marquee selection,
//! element intersection tests, and control-point queries.  These do not
//! depend on the document model — only on element geometry, plus (for the
//! `_with` entry points) an [`ElementResolver`] supplied by the caller.
//!
//! ## Why some kinds need a resolver (RESOLVEDHIT)
//!
//! Most elements carry their own coordinates. Three live kinds do not:
//! `Reference` (a symbol instance) holds only a target id, `Recorded` holds a
//! replayable recipe over other elements, and `Generated` holds a concept id
//! plus params. Each one's geometry exists only once something resolves that
//! id — which is why `LiveElement::bounds()` answers `(0,0,0,0)` for all three
//! and `segments_of_element` answers `vec![]`.
//!
//! The canvas already resolves them (`canvas/render.rs`), so an instance is
//! DRAWN. Hit-testing had no resolver, so an instance was not SELECTABLE. Each
//! function below therefore comes in two forms:
//!
//! * the plain form — the shared cross-language verb, resolver-less. It keeps
//!   answering `false` for these three kinds, and that is the CORRECT answer
//!   for the question it is asked: with no document behind it, a reference is
//!   dangling, and a dangling reference evaluates to empty
//!   (REFERENCE_GRAPH.md §3).
//! * the `_with` form — takes a resolver, and is what document-level callers
//!   (marquee, lasso, direct-select marquee) use.

use crate::geometry::element::{flatten_path_commands, Element};
use crate::geometry::live::{
    ElementResolver, LiveVariant, NullResolver, VisitSet, DEFAULT_PRECISION,
};

// ---------------------------------------------------------------------------
// Primitive geometry
// ---------------------------------------------------------------------------

pub fn point_in_rect(px: f64, py: f64, rx: f64, ry: f64, rw: f64, rh: f64) -> bool {
    rx <= px && px <= rx + rw && ry <= py && py <= ry + rh
}

fn cross(ox: f64, oy: f64, ax: f64, ay: f64, bx: f64, by: f64) -> f64 {
    (ax - ox) * (by - oy) - (ay - oy) * (bx - ox)
}

fn on_segment(px1: f64, py1: f64, px2: f64, py2: f64, qx: f64, qy: f64) -> bool {
    qx >= px1.min(px2) && qx <= px1.max(px2) && qy >= py1.min(py2) && qy <= py1.max(py2)
}

pub fn segments_intersect(
    ax1: f64, ay1: f64, ax2: f64, ay2: f64, bx1: f64, by1: f64, bx2: f64, by2: f64,
) -> bool {
    let d1 = cross(bx1, by1, bx2, by2, ax1, ay1);
    let d2 = cross(bx1, by1, bx2, by2, ax2, ay2);
    let d3 = cross(ax1, ay1, ax2, ay2, bx1, by1);
    let d4 = cross(ax1, ay1, ax2, ay2, bx2, by2);
    if ((d1 > 0.0 && d2 < 0.0) || (d1 < 0.0 && d2 > 0.0))
        && ((d3 > 0.0 && d4 < 0.0) || (d3 < 0.0 && d4 > 0.0))
    {
        return true;
    }
    let eps = 1e-10;
    if d1.abs() < eps && on_segment(bx1, by1, bx2, by2, ax1, ay1) { return true; }
    if d2.abs() < eps && on_segment(bx1, by1, bx2, by2, ax2, ay2) { return true; }
    if d3.abs() < eps && on_segment(ax1, ay1, ax2, ay2, bx1, by1) { return true; }
    if d4.abs() < eps && on_segment(ax1, ay1, ax2, ay2, bx2, by2) { return true; }
    false
}

pub fn segment_intersects_rect(
    x1: f64, y1: f64, x2: f64, y2: f64, rx: f64, ry: f64, rw: f64, rh: f64,
) -> bool {
    if point_in_rect(x1, y1, rx, ry, rw, rh) || point_in_rect(x2, y2, rx, ry, rw, rh) {
        return true;
    }
    let edges = [
        (rx, ry, rx + rw, ry),
        (rx + rw, ry, rx + rw, ry + rh),
        (rx + rw, ry + rh, rx, ry + rh),
        (rx, ry + rh, rx, ry),
    ];
    edges
        .iter()
        .any(|&(ex1, ey1, ex2, ey2)| segments_intersect(x1, y1, x2, y2, ex1, ey1, ex2, ey2))
}

pub fn rects_intersect(
    ax: f64, ay: f64, aw: f64, ah: f64, bx: f64, by: f64, bw: f64, bh: f64,
) -> bool {
    ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by
}

// ---------------------------------------------------------------------------
// Polygon geometry
// ---------------------------------------------------------------------------

/// Ray-casting (even-odd) point-in-polygon test.
pub fn point_in_polygon(px: f64, py: f64, poly: &[(f64, f64)]) -> bool {
    let n = poly.len();
    if n < 3 {
        return false;
    }
    let mut inside = false;
    let mut j = n - 1;
    for i in 0..n {
        let (xi, yi) = poly[i];
        let (xj, yj) = poly[j];
        if ((yi > py) != (yj > py)) && (px < (xj - xi) * (py - yi) / (yj - yi) + xi) {
            inside = !inside;
        }
        j = i;
    }
    inside
}

pub fn segment_intersects_polygon(
    x1: f64, y1: f64, x2: f64, y2: f64, poly: &[(f64, f64)],
) -> bool {
    if point_in_polygon(x1, y1, poly) || point_in_polygon(x2, y2, poly) {
        return true;
    }
    let n = poly.len();
    for i in 0..n {
        let j = (i + 1) % n;
        if segments_intersect(x1, y1, x2, y2, poly[i].0, poly[i].1, poly[j].0, poly[j].1) {
            return true;
        }
    }
    false
}

// Called by the cross-language corpus runner and `bin/algorithm_roundtrip`,
// neither of which the cdylib half of this crate's `crate-type` can see.
#[allow(dead_code)]
pub fn element_intersects_polygon(elem: &Element, poly: &[(f64, f64)]) -> bool {
    element_intersects_polygon_with(elem, poly, &NullResolver)
}

/// [`element_intersects_polygon`], resolving live kinds through `resolver`.
pub fn element_intersects_polygon_with(
    elem: &Element,
    poly: &[(f64, f64)],
    resolver: &dyn ElementResolver,
) -> bool {
    if let Some(t) = elem.transform() {
        if let Some(inv) = t.inverse() {
            let local_poly: Vec<(f64, f64)> = poly.iter()
                .map(|&(x, y)| inv.apply_point(x, y))
                .collect();
            return element_intersects_polygon_local(elem, &local_poly, resolver);
        }
        return false;
    }
    element_intersects_polygon_local(elem, poly, resolver)
}

/// Polygon hit-test against an element's raw (untransformed) coordinates.
fn element_intersects_polygon_local(
    elem: &Element,
    poly: &[(f64, f64)],
    resolver: &dyn ElementResolver,
) -> bool {
    match elem {
        Element::Line(e) => {
            segment_intersects_polygon(e.x1, e.y1, e.x2, e.y2, poly)
        }
        Element::Rect(e) => {
            if e.fill.is_some() {
                // Filled rect: check if any rect corner is in polygon,
                // any polygon vertex is in rect, or any edges cross.
                let corners = [
                    (e.x, e.y),
                    (e.x + e.width, e.y),
                    (e.x + e.width, e.y + e.height),
                    (e.x, e.y + e.height),
                ];
                if corners.iter().any(|&(cx, cy)| point_in_polygon(cx, cy, poly)) {
                    return true;
                }
                if poly.iter().any(|&(px, py)| point_in_rect(px, py, e.x, e.y, e.width, e.height)) {
                    return true;
                }
                let segs = segments_of_element_with(elem, resolver);
                segs.iter().any(|&(x1, y1, x2, y2)| segment_intersects_polygon(x1, y1, x2, y2, poly))
            } else {
                segments_of_element_with(elem, resolver)
                    .iter()
                    .any(|&(x1, y1, x2, y2)| segment_intersects_polygon(x1, y1, x2, y2, poly))
            }
        }
        // 2bb65ca6 (2026-04-10, "All: transform-aware hit-testing for marquee
        // and polygon selection") is the commit that created this gap — by
        // fixing a different one. Before it, both entry points tested an
        // element's RAW coordinates, so a transformed element could not be
        // marquee-selected at all. That commit inverse-maps the selection
        // geometry into element-local space, which is right, and then routes
        // the transformed RECT case in here, which is also right: the inverse
        // image of a marquee is a parallelogram, not a box, so only a polygon
        // test can answer it. What it did not do is check that this function
        // covered every kind the rect function covered. It did not. Ellipse
        // has a real arm over there (`ellipse_intersects_rect`) and had none
        // here, so from that day forward giving an ellipse a transform — any
        // transform, including the identity — swapped its exact answer for the
        // catch-all's, which cannot see an ellipse at all:
        // `segments_of_element` yields nothing for one, so the unfilled branch
        // returned false for EVERY region, and the filled branch could only
        // answer true when a region vertex happened to fall inside the local
        // bounding box. Hence the two-way failure the corpus pins — a marquee
        // that wholly ENCLOSES a transformed ellipse missed it (no vertex
        // inside), while a marquee tucked into the empty corner of its
        // bounding box hit it (vertex inside, no paint there).
        //
        // The class is a second dispatch path that does not enumerate the same
        // universe as the first: the same shape as DISPATCHLEDGER, where
        // element-dispatching functions were each missing the container kinds.
        // A new path added beside an old one inherits the old one's
        // obligations, and nothing in the type system says so — the catch-all
        // absorbs the omission and answers plausibly instead of failing.
        //
        // Answered here the way the rect path answers it, by normalising away
        // the radii, NOT by flattening the ellipse into segments: segments
        // would answer a polygon's question rather than an ellipse's, and the
        // answer would then drift with the flattening precision.
        Element::Ellipse(e) => {
            ellipse_intersects_polygon(e.cx, e.cy, e.rx, e.ry, poly, e.fill.is_some())
        }
        Element::Text(_) | Element::TextPath(_) | Element::Group(_) | Element::Layer(_) => {
            let (bx, by, bw, bh) = resolved_bounds(elem, resolver);
            let corners = [
                (bx, by), (bx + bw, by), (bx + bw, by + bh), (bx, by + bh),
            ];
            if corners.iter().any(|&(cx, cy)| point_in_polygon(cx, cy, poly)) {
                return true;
            }
            if poly.iter().any(|&(px, py)| point_in_rect(px, py, bx, by, bw, bh)) {
                return true;
            }
            let rect_segs = [
                (bx, by, bx + bw, by),
                (bx + bw, by, bx + bw, by + bh),
                (bx + bw, by + bh, bx, by + bh),
                (bx, by + bh, bx, by),
            ];
            rect_segs.iter().any(|&(x1, y1, x2, y2)| segment_intersects_polygon(x1, y1, x2, y2, poly))
        }
        _ => {
            if elem.fill().is_some() {
                let segs = segments_of_element_with(elem, resolver);
                let endpoints: Vec<(f64, f64)> = segs
                    .iter()
                    .flat_map(|&(x1, y1, x2, y2)| vec![(x1, y1), (x2, y2)])
                    .collect();
                if endpoints.iter().any(|&(px, py)| point_in_polygon(px, py, poly)) {
                    return true;
                }
                if poly.iter().any(|&(px, py)| {
                    let b = resolved_bounds(elem, resolver);
                    point_in_rect(px, py, b.0, b.1, b.2, b.3)
                }) {
                    return true;
                }
                segs.iter()
                    .any(|&(x1, y1, x2, y2)| segment_intersects_polygon(x1, y1, x2, y2, poly))
            } else {
                segments_of_element_with(elem, resolver)
                    .iter()
                    .any(|&(x1, y1, x2, y2)| segment_intersects_polygon(x1, y1, x2, y2, poly))
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Circle / ellipse geometry
// ---------------------------------------------------------------------------

pub fn circle_intersects_rect(
    cx: f64, cy: f64, r: f64, rx: f64, ry: f64, rw: f64, rh: f64, filled: bool,
) -> bool {
    let closest_x = rx.max(cx.min(rx + rw));
    let closest_y = ry.max(cy.min(ry + rh));
    let dist_sq = (cx - closest_x).powi(2) + (cy - closest_y).powi(2);
    if !filled {
        let corners = [(rx, ry), (rx + rw, ry), (rx + rw, ry + rh), (rx, ry + rh)];
        let max_dist_sq = corners
            .iter()
            .map(|&(px, py)| (cx - px).powi(2) + (cy - py).powi(2))
            .fold(f64::NEG_INFINITY, f64::max);
        return dist_sq <= r * r && r * r <= max_dist_sq;
    }
    dist_sq <= r * r
}

pub fn ellipse_intersects_rect(
    cx: f64, cy: f64, erx: f64, ery: f64, rx: f64, ry: f64, rw: f64, rh: f64, filled: bool,
) -> bool {
    if erx == 0.0 || ery == 0.0 {
        return false;
    }
    circle_intersects_rect(
        cx / erx, cy / ery, 1.0, rx / erx, ry / ery, rw / erx, rh / ery, filled,
    )
}

/// Squared distance from a point to the CLOSED segment (x1,y1)-(x2,y2).
/// A zero-length segment degrades to the point-to-point distance.
fn point_segment_dist_sq(px: f64, py: f64, x1: f64, y1: f64, x2: f64, y2: f64) -> f64 {
    let dx = x2 - x1;
    let dy = y2 - y1;
    let len_sq = dx * dx + dy * dy;
    let t = if len_sq <= 0.0 {
        0.0
    } else {
        (((px - x1) * dx + (py - y1) * dy) / len_sq).clamp(0.0, 1.0)
    };
    let qx = x1 + t * dx;
    let qy = y1 + t * dy;
    (px - qx).powi(2) + (py - qy).powi(2)
}

/// The polygon-region counterpart of [`circle_intersects_rect`], with the
/// same two semantics: `filled` asks whether the DISC meets the region,
/// `!filled` asks whether the stroked RING does.
///
/// Both reduce to the same two numbers the rect version uses, only measured
/// against a polygon instead of a box:
///
/// * `min_dist_sq` — the distance from the centre to the nearest point of the
///   region. Zero when the centre is inside it, otherwise the distance to the
///   nearest boundary edge. (The rect version gets this from a per-axis clamp,
///   which is the same quantity for a box.)
/// * `max_dist_sq` — the distance to the farthest point of the region, which
///   is always attained at a polygon VERTEX: the region sits inside the convex
///   hull of its vertices, distance-to-a-point is convex, and every vertex is
///   itself in the region. (The rect version maxes over the four corners, the
///   same statement for a box.)
///
/// A filled disc meets the region exactly when `min_dist_sq <= r²`. The ring
/// meets it exactly when `min_dist_sq <= r² <= max_dist_sq`: the region then
/// holds a point at most r from the centre and a point at least r from it, so
/// — the region being connected — it holds one at exactly r, which is on the
/// ring. A region swallowed whole by the disc fails the right-hand test, which
/// is the "marquee inside the outline, touching nothing" miss.
pub fn circle_intersects_polygon(
    cx: f64, cy: f64, r: f64, poly: &[(f64, f64)], filled: bool,
) -> bool {
    if poly.is_empty() {
        return false;
    }
    let mut min_dist_sq = if point_in_polygon(cx, cy, poly) { 0.0 } else { f64::INFINITY };
    if min_dist_sq > 0.0 {
        let n = poly.len();
        for i in 0..n {
            let j = (i + 1) % n;
            let d = point_segment_dist_sq(cx, cy, poly[i].0, poly[i].1, poly[j].0, poly[j].1);
            if d < min_dist_sq {
                min_dist_sq = d;
            }
        }
    }
    if !filled {
        let max_dist_sq = poly
            .iter()
            .map(|&(px, py)| (cx - px).powi(2) + (cy - py).powi(2))
            .fold(f64::NEG_INFINITY, f64::max);
        return min_dist_sq <= r * r && r * r <= max_dist_sq;
    }
    min_dist_sq <= r * r
}

/// Polygon-region counterpart of [`ellipse_intersects_rect`], derived the same
/// way: divide both the ellipse and the region by the radii so the ellipse
/// becomes the unit circle, then ask the circle question. An affine map of a
/// polygon is a polygon, so nothing about the region is approximated.
pub fn ellipse_intersects_polygon(
    cx: f64, cy: f64, erx: f64, ery: f64, poly: &[(f64, f64)], filled: bool,
) -> bool {
    if erx == 0.0 || ery == 0.0 {
        return false;
    }
    let unit: Vec<(f64, f64)> = poly.iter().map(|&(x, y)| (x / erx, y / ery)).collect();
    circle_intersects_polygon(cx / erx, cy / ery, 1.0, &unit, filled)
}

// ---------------------------------------------------------------------------
// Element-level queries
// ---------------------------------------------------------------------------

// Corpus verb; see `element_intersects_polygon`.
#[allow(dead_code)]
pub fn segments_of_element(elem: &Element) -> Vec<(f64, f64, f64, f64)> {
    segments_of_element_with(elem, &NullResolver)
}

/// Append `ring`'s edges (closed) to `segs`. The shared tail of every arm that
/// turns an evaluated [`PolygonSet`](crate::algorithms::boolean::PolygonSet)
/// into hit-test segments, so the resolver-needing live kinds and
/// `CompoundShape` cannot drift in how they close a ring.
fn push_ring_segments(ring: &[(f64, f64)], segs: &mut Vec<(f64, f64, f64, f64)>) {
    if ring.len() < 2 {
        return;
    }
    for w in ring.windows(2) {
        segs.push((w[0].0, w[0].1, w[1].0, w[1].1));
    }
    let last = *ring.last().unwrap();
    let first = *ring.first().unwrap();
    segs.push((last.0, last.1, first.0, first.1));
}

/// The evaluated rings of a live kind whose geometry lives behind a resolver
/// (`Reference` / `Recorded` / `Generated`), or `None` for anything else.
/// A dangling target, an unknown concept, or a cycle yields `Some(empty)` —
/// never a panic (REFERENCE_GRAPH.md §3).
fn resolved_rings(
    elem: &Element,
    resolver: &dyn ElementResolver,
) -> Option<crate::algorithms::boolean::PolygonSet> {
    let Element::Live(v) = elem else { return None };
    let mut visiting = VisitSet::new();
    match v {
        LiveVariant::Reference(r) => {
            Some(r.evaluate_with(DEFAULT_PRECISION, resolver, &mut visiting))
        }
        LiveVariant::Recorded(rec) => {
            Some(rec.evaluate_with(DEFAULT_PRECISION, resolver, &mut visiting))
        }
        LiveVariant::Generated(g) => {
            Some(g.evaluate_with(DEFAULT_PRECISION, resolver, &mut visiting))
        }
        // CompoundShape owns its operands, so it needs no resolver and is
        // already answered exactly by `segments_of_element`.
        LiveVariant::CompoundShape(_) => None,
    }
}

/// `elem.bounds()`, except for the resolver-needing live kinds, whose own
/// `bounds()` is a hard-coded `(0,0,0,0)` — for those, the bounding box of the
/// RESOLVED rings. Used by the filled arms, which compare against a bounding
/// box: an instance carrying a paint override took those arms and compared
/// against a degenerate box at the origin.
fn resolved_bounds(
    elem: &Element,
    resolver: &dyn ElementResolver,
) -> (f64, f64, f64, f64) {
    let Some(rings) = resolved_rings(elem, resolver) else {
        return elem.bounds();
    };
    let mut pts = rings.iter().flatten();
    let Some(&(x0, y0)) = pts.next() else {
        // Dangling / cyclic / unknown: no geometry, and a zero box at the
        // origin would be a false claim about where it is. Report the same
        // degenerate box `bounds()` does, so nothing downstream changes for
        // the case that genuinely has nothing to show.
        return elem.bounds();
    };
    let (mut minx, mut miny, mut maxx, mut maxy) = (x0, y0, x0, y0);
    for &(x, y) in pts {
        minx = minx.min(x);
        miny = miny.min(y);
        maxx = maxx.max(x);
        maxy = maxy.max(y);
    }
    (minx, miny, maxx - minx, maxy - miny)
}

/// [`segments_of_element`], resolving live kinds through `resolver`.
pub fn segments_of_element_with(
    elem: &Element,
    resolver: &dyn ElementResolver,
) -> Vec<(f64, f64, f64, f64)> {
    if let Some(rings) = resolved_rings(elem, resolver) {
        let mut segs = Vec::new();
        for ring in &rings {
            push_ring_segments(ring, &mut segs);
        }
        return segs;
    }
    match elem {
        Element::Line(e) => vec![(e.x1, e.y1, e.x2, e.y2)],
        Element::Rect(e) => vec![
            (e.x, e.y, e.x + e.width, e.y),
            (e.x + e.width, e.y, e.x + e.width, e.y + e.height),
            (e.x + e.width, e.y + e.height, e.x, e.y + e.height),
            (e.x, e.y + e.height, e.x, e.y),
        ],
        Element::Polyline(e) if e.points.len() >= 2 => e
            .points
            .windows(2)
            .map(|w| (w[0].0, w[0].1, w[1].0, w[1].1))
            .collect(),
        Element::Polygon(e) if e.points.len() >= 2 => {
            let mut segs: Vec<_> = e
                .points
                .windows(2)
                .map(|w| (w[0].0, w[0].1, w[1].0, w[1].1))
                .collect();
            let last = e.points.last().unwrap();
            let first = e.points.first().unwrap();
            segs.push((last.0, last.1, first.0, first.1));
            segs
        }
        Element::Path(e) => {
            let pts = flatten_path_commands(&e.d);
            if pts.len() >= 2 {
                pts.windows(2)
                    .map(|w| (w[0].0, w[0].1, w[1].0, w[1].1))
                    .collect()
            } else {
                vec![]
            }
        }
        Element::Live(v) => match v {
            LiveVariant::CompoundShape(cs) => {
                let ps = cs.evaluate(DEFAULT_PRECISION);
                let mut segs = Vec::new();
                for ring in &ps {
                    push_ring_segments(ring, &mut segs);
                }
                segs
            }
            // Unreachable from `segments_of_element_with`: `resolved_rings`
            // takes these three first, whatever the resolver. Reached only
            // through the resolver-less verb, where empty is the right answer
            // (see the module header) — and left as an explicit arm rather
            // than folded into the catch-all so adding a fifth live kind has
            // to state which side of that line it falls on.
            LiveVariant::Reference(_)
            | LiveVariant::Recorded(_)
            | LiveVariant::Generated(_) => vec![],
        },
        _ => vec![],
    }
}

// Corpus verb; see `element_intersects_polygon`.
#[allow(dead_code)]
pub fn element_intersects_rect(elem: &Element, rx: f64, ry: f64, rw: f64, rh: f64) -> bool {
    element_intersects_rect_with(elem, rx, ry, rw, rh, &NullResolver)
}

/// [`element_intersects_rect`], resolving live kinds through `resolver`.
pub fn element_intersects_rect_with(
    elem: &Element,
    rx: f64,
    ry: f64,
    rw: f64,
    rh: f64,
    resolver: &dyn ElementResolver,
) -> bool {
    if let Some(t) = elem.transform() {
        if let Some(inv) = t.inverse() {
            let corners = [
                inv.apply_point(rx, ry),
                inv.apply_point(rx + rw, ry),
                inv.apply_point(rx + rw, ry + rh),
                inv.apply_point(rx, ry + rh),
            ];
            return element_intersects_polygon_local(elem, &corners, resolver);
        }
        return false; // singular transform — element is invisible
    }
    element_intersects_rect_local(elem, rx, ry, rw, rh, resolver)
}

/// Rect hit-test against an element's raw (untransformed) coordinates.
fn element_intersects_rect_local(
    elem: &Element,
    rx: f64,
    ry: f64,
    rw: f64,
    rh: f64,
    resolver: &dyn ElementResolver,
) -> bool {
    match elem {
        Element::Line(e) => {
            segment_intersects_rect(e.x1, e.y1, e.x2, e.y2, rx, ry, rw, rh)
        }
        Element::Rect(e) => {
            if e.fill.is_some() {
                rects_intersect(e.x, e.y, e.width, e.height, rx, ry, rw, rh)
            } else {
                segments_of_element_with(elem, resolver)
                    .iter()
                    .any(|&(x1, y1, x2, y2)| segment_intersects_rect(x1, y1, x2, y2, rx, ry, rw, rh))
            }
        }
        Element::Ellipse(e) => {
            ellipse_intersects_rect(e.cx, e.cy, e.rx, e.ry, rx, ry, rw, rh, e.fill.is_some())
        }
        // A filled polyline paints as though its last point were joined back
        // to its first, so its painted area is not the open run the segments
        // describe: [[0,0],[0,100],[100,100],[100,0]] strokes as a U but fills
        // as the whole 100x100 square. The bounding box is the arm the
        // reference (jas/algorithms/hit_test.py, `case Polyline()`) and
        // JasSwift's `.polyline` case both use; without this Rust fell into
        // the segments-based catch-all and missed a marquee lying wholly
        // inside the fill. Unfilled polylines keep the segments test.
        Element::Polyline(e) => {
            if e.fill.is_some() {
                let b = resolved_bounds(elem, resolver);
                rects_intersect(b.0, b.1, b.2, b.3, rx, ry, rw, rh)
            } else {
                segments_of_element_with(elem, resolver)
                    .iter()
                    .any(|&(x1, y1, x2, y2)| segment_intersects_rect(x1, y1, x2, y2, rx, ry, rw, rh))
            }
        }
        Element::Text(_) | Element::TextPath(_) => {
            let b = resolved_bounds(elem, resolver);
            rects_intersect(b.0, b.1, b.2, b.3, rx, ry, rw, rh)
        }
        Element::Group(_) | Element::Layer(_) => {
            let b = resolved_bounds(elem, resolver);
            rects_intersect(b.0, b.1, b.2, b.3, rx, ry, rw, rh)
        }
        _ => {
            if elem.fill().is_some() {
                let segs = segments_of_element_with(elem, resolver);
                let endpoints: Vec<(f64, f64)> = segs
                    .iter()
                    .flat_map(|&(x1, y1, x2, y2)| vec![(x1, y1), (x2, y2)])
                    .collect();
                if endpoints
                    .iter()
                    .any(|&(px, py)| point_in_rect(px, py, rx, ry, rw, rh))
                {
                    return true;
                }
                // The marquee may lie WHOLLY INSIDE the fill: dropped in the
                // middle of a filled polygon or path it touches no vertex and
                // crosses no segment, yet every point of it is painted. The
                // polygon-local twin of this arm has always carried that
                // clause (`poly.iter().any(point_in_rect(bounds))`) and this
                // one did not — so the corpus's `..._marquee_inside_fill`
                // control pairs split on nothing but whether `transform` was
                // present: the identity leg went through the polygon path and
                // HIT, the null leg came here and MISSED.
                //
                // Same class as the ellipse gap in the polygon-local function
                // above — two dispatch tables answering one question, one of
                // them short a clause — and turned up by the same corpus. The
                // comparand is the bounding box on both sides, so the two
                // paths now agree by construction rather than by coincidence;
                // a later move to a true point-in-fill test has to be made on
                // both at once, deliberately.
                let b = resolved_bounds(elem, resolver);
                let corners = [
                    (rx, ry), (rx + rw, ry), (rx + rw, ry + rh), (rx, ry + rh),
                ];
                if corners.iter().any(|&(px, py)| point_in_rect(px, py, b.0, b.1, b.2, b.3)) {
                    return true;
                }
                segs.iter()
                    .any(|&(x1, y1, x2, y2)| segment_intersects_rect(x1, y1, x2, y2, rx, ry, rw, rh))
            } else {
                segments_of_element_with(elem, resolver)
                    .iter()
                    .any(|&(x1, y1, x2, y2)| segment_intersects_rect(x1, y1, x2, y2, rx, ry, rw, rh))
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // ---- point_in_rect ----

    #[test]
    fn point_in_rect_interior() {
        assert!(point_in_rect(5.0, 5.0, 0.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn point_in_rect_outside() {
        assert!(!point_in_rect(15.0, 5.0, 0.0, 0.0, 10.0, 10.0));
        assert!(!point_in_rect(-1.0, 5.0, 0.0, 0.0, 10.0, 10.0));
        assert!(!point_in_rect(5.0, 15.0, 0.0, 0.0, 10.0, 10.0));
        assert!(!point_in_rect(5.0, -1.0, 0.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn point_in_rect_on_edge() {
        // Edges count as inside (closed-interval test).
        assert!(point_in_rect(0.0, 5.0, 0.0, 0.0, 10.0, 10.0));
        assert!(point_in_rect(10.0, 5.0, 0.0, 0.0, 10.0, 10.0));
        assert!(point_in_rect(5.0, 0.0, 0.0, 0.0, 10.0, 10.0));
        assert!(point_in_rect(5.0, 10.0, 0.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn point_in_rect_on_corner() {
        assert!(point_in_rect(0.0, 0.0, 0.0, 0.0, 10.0, 10.0));
        assert!(point_in_rect(10.0, 10.0, 0.0, 0.0, 10.0, 10.0));
    }

    // ---- segments_intersect ----

    #[test]
    fn segments_intersect_crossing() {
        assert!(segments_intersect(0.0, 0.0, 10.0, 10.0, 0.0, 10.0, 10.0, 0.0));
    }

    #[test]
    fn segments_intersect_parallel_no() {
        assert!(!segments_intersect(0.0, 0.0, 10.0, 0.0, 0.0, 1.0, 10.0, 1.0));
    }

    #[test]
    fn segments_intersect_separate() {
        assert!(!segments_intersect(0.0, 0.0, 1.0, 1.0, 5.0, 5.0, 6.0, 6.0));
    }

    #[test]
    fn segments_intersect_touching_at_endpoint() {
        // Sharing an endpoint counts as intersecting.
        assert!(segments_intersect(0.0, 0.0, 5.0, 5.0, 5.0, 5.0, 10.0, 10.0));
    }

    #[test]
    fn segments_intersect_t_intersection() {
        // T: one segment ends where another passes through.
        assert!(segments_intersect(0.0, 5.0, 10.0, 5.0, 5.0, 5.0, 5.0, 0.0));
    }

    // ---- segment_intersects_rect ----

    #[test]
    fn segment_inside_rect() {
        // Endpoint inside ⇒ true.
        assert!(segment_intersects_rect(2.0, 2.0, 8.0, 8.0, 0.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn segment_outside_rect() {
        assert!(!segment_intersects_rect(20.0, 0.0, 30.0, 0.0, 0.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn segment_crosses_rect() {
        // Diagonal crossing fully through.
        assert!(segment_intersects_rect(-5.0, 5.0, 15.0, 5.0, 0.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn segment_one_endpoint_inside() {
        assert!(segment_intersects_rect(5.0, 5.0, 20.0, 20.0, 0.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn segment_endpoint_on_edge() {
        // Endpoint exactly on the edge.
        assert!(segment_intersects_rect(10.0, 5.0, 20.0, 5.0, 0.0, 0.0, 10.0, 10.0));
    }

    // ---- rects_intersect ----

    #[test]
    fn rects_intersect_overlapping() {
        assert!(rects_intersect(0.0, 0.0, 10.0, 10.0, 5.0, 5.0, 10.0, 10.0));
    }

    #[test]
    fn rects_intersect_separate() {
        assert!(!rects_intersect(0.0, 0.0, 10.0, 10.0, 20.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn rects_intersect_contained() {
        assert!(rects_intersect(0.0, 0.0, 100.0, 100.0, 25.0, 25.0, 50.0, 50.0));
    }

    #[test]
    fn rects_intersect_edge_touching() {
        // Edge-touching rects do NOT intersect (open-interval rule).
        assert!(!rects_intersect(0.0, 0.0, 10.0, 10.0, 10.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn rects_intersect_corner_touching() {
        assert!(!rects_intersect(0.0, 0.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0));
    }

    #[test]
    fn rects_intersect_identical() {
        assert!(rects_intersect(0.0, 0.0, 10.0, 10.0, 0.0, 0.0, 10.0, 10.0));
    }

    // ---- element_intersects_rect on simple elements ----
    //
    // These exercise the dispatch into element-specific helpers via the
    // public Element type. The fixtures use the smallest possible
    // element constructors so the tests focus on the hit-test logic
    // rather than the element model.

    use crate::geometry::element::{LineElem, RectElem, CommonProps, Transform};

    #[test]
    fn line_element_intersects_rect_overlapping() {
        let line = Element::Line(LineElem {
            common: CommonProps::default(),
            x1: -5.0, y1: 5.0, x2: 15.0, y2: 5.0,
            stroke: None,
            width_points: vec![],
                    stroke_gradient: None,
        });
        assert!(element_intersects_rect(&line, 0.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn line_element_outside_rect() {
        let line = Element::Line(LineElem {
            common: CommonProps::default(),
            x1: 20.0, y1: 0.0, x2: 30.0, y2: 0.0,
            stroke: None,
            width_points: vec![],
                    stroke_gradient: None,
        });
        assert!(!element_intersects_rect(&line, 0.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn rect_element_overlapping_rect() {
        let rect = Element::Rect(RectElem {
            common: CommonProps::default(),
            x: 5.0, y: 5.0, width: 10.0, height: 10.0,
            rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
                    fill_gradient: None,
            stroke_gradient: None,
        });
        assert!(element_intersects_rect(&rect, 0.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn rect_element_outside_rect() {
        let rect = Element::Rect(RectElem {
            common: CommonProps::default(),
            x: 20.0, y: 20.0, width: 5.0, height: 5.0,
            rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
                    fill_gradient: None,
            stroke_gradient: None,
        });
        assert!(!element_intersects_rect(&rect, 0.0, 0.0, 10.0, 10.0));
    }

    // ---- filled polyline: the fill closes the point list implicitly ----
    //
    // A `<polyline>` with a fill paints as though the last point were joined
    // back to the first — filling an open subpath closes it implicitly (SVG /
    // canvas fill semantics), and `painter::element_render` does emit a fill
    // over an UNCLOSED path for this element (`polyline_painter_inputs` →
    // `poly_path(&e.points, false)` plus `conv_fill`). So the filled region is
    // NOT the stroked open run. `[[0,0],[0,100],[100,100],[100,0]]`
    // strokes as a U but FILLS as the full 100x100 square, and a marquee
    // dropped in the U's opening lands inside that fill. The reference
    // (jas/algorithms/hit_test.py, `case Polyline()`) and JasSwift both answer
    // this with the bounding box; these tests pin Rust to the same arm.
    //
    // The last test is the one that distinguishes bbox from fill: an OPEN
    // triangle's bbox corner is outside its closed fill, and the reference
    // still says true there. That is the arm's semantics, recorded so a later
    // change to a true point-in-fill test is a deliberate ruling, not a drift.

    use crate::geometry::element::PolylineElem;

    fn red_fill() -> Option<Fill> {
        Some(Fill {
            color: Color::Rgb { r: 255.0, g: 0.0, b: 0.0, a: 1.0 },
            opacity: 1.0,
        })
    }

    fn polyline(points: Vec<(f64, f64)>, fill: Option<Fill>) -> Element {
        Element::Polyline(PolylineElem {
            common: CommonProps::default(),
            points,
            fill,
            stroke: None,
            fill_gradient: None,
            stroke_gradient: None,
        })
    }

    #[test]
    fn filled_polyline_marquee_inside_implicit_close() {
        let u = polyline(
            vec![(0.0, 0.0), (0.0, 100.0), (100.0, 100.0), (100.0, 0.0)],
            red_fill(),
        );
        assert!(element_intersects_rect(&u, 40.0, 20.0, 20.0, 20.0));
    }

    #[test]
    fn unfilled_polyline_marquee_inside_open_run() {
        // Same point list with no fill: nothing is painted in the opening, so
        // only the segments can be hit — and none reach (40,20)-(60,40).
        let u = polyline(
            vec![(0.0, 0.0), (0.0, 100.0), (100.0, 100.0), (100.0, 0.0)],
            None,
        );
        assert!(!element_intersects_rect(&u, 40.0, 20.0, 20.0, 20.0));
    }

    #[test]
    fn filled_polyline_marquee_outside_bounds() {
        let u = polyline(
            vec![(0.0, 0.0), (0.0, 100.0), (100.0, 100.0), (100.0, 0.0)],
            red_fill(),
        );
        assert!(!element_intersects_rect(&u, 200.0, 200.0, 10.0, 10.0));
    }

    #[test]
    fn filled_polyline_marquee_in_bbox_outside_closed_fill() {
        let tri = polyline(vec![(0.0, 0.0), (100.0, 0.0), (100.0, 100.0)], red_fill());
        assert!(element_intersects_rect(&tri, 5.0, 60.0, 10.0, 10.0));
    }

    // ---- point_in_polygon ----

    #[test]
    fn point_in_polygon_interior() {
        let tri = [(0.0, 0.0), (10.0, 0.0), (5.0, 10.0)];
        assert!(point_in_polygon(5.0, 3.0, &tri));
    }

    #[test]
    fn point_in_polygon_outside() {
        let tri = [(0.0, 0.0), (10.0, 0.0), (5.0, 10.0)];
        assert!(!point_in_polygon(20.0, 5.0, &tri));
    }

    #[test]
    fn point_in_polygon_concave() {
        // L-shaped polygon
        let poly = [
            (0.0, 0.0), (10.0, 0.0), (10.0, 5.0),
            (5.0, 5.0), (5.0, 10.0), (0.0, 10.0),
        ];
        assert!(point_in_polygon(2.0, 8.0, &poly));   // in the lower part
        assert!(point_in_polygon(8.0, 2.0, &poly));   // in the upper-right arm
        assert!(!point_in_polygon(8.0, 8.0, &poly));  // in the concave notch
    }

    #[test]
    fn point_in_polygon_degenerate() {
        assert!(!point_in_polygon(0.0, 0.0, &[]));
        assert!(!point_in_polygon(0.0, 0.0, &[(0.0, 0.0), (1.0, 1.0)]));
    }

    // ---- segment_intersects_polygon ----

    #[test]
    fn segment_inside_polygon() {
        let sq = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        assert!(segment_intersects_polygon(2.0, 2.0, 8.0, 8.0, &sq));
    }

    #[test]
    fn segment_crossing_polygon() {
        let sq = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        assert!(segment_intersects_polygon(-5.0, 5.0, 15.0, 5.0, &sq));
    }

    #[test]
    fn segment_outside_polygon() {
        let sq = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        assert!(!segment_intersects_polygon(20.0, 0.0, 30.0, 0.0, &sq));
    }

    // ---- element_intersects_polygon ----

    #[test]
    fn line_element_intersects_polygon() {
        let line = Element::Line(LineElem {
            common: CommonProps::default(),
            x1: -5.0, y1: 5.0, x2: 15.0, y2: 5.0,
            stroke: None,
            width_points: vec![],
                    stroke_gradient: None,
        });
        let sq = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        assert!(element_intersects_polygon(&line, &sq));
    }

    #[test]
    fn line_element_outside_polygon() {
        let line = Element::Line(LineElem {
            common: CommonProps::default(),
            x1: 20.0, y1: 0.0, x2: 30.0, y2: 0.0,
            stroke: None,
            width_points: vec![],
                    stroke_gradient: None,
        });
        let sq = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        assert!(!element_intersects_polygon(&line, &sq));
    }

    #[test]
    fn filled_rect_inside_polygon() {
        use crate::geometry::element::{Color, Fill};
        let rect = Element::Rect(RectElem {
            common: CommonProps::default(),
            x: 2.0, y: 2.0, width: 3.0, height: 3.0,
            rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
                    fill_gradient: None,
            stroke_gradient: None,
        });
        let sq = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        assert!(element_intersects_polygon(&rect, &sq));
    }

    #[test]
    fn rect_element_outside_polygon() {
        let rect = Element::Rect(RectElem {
            common: CommonProps::default(),
            x: 20.0, y: 20.0, width: 5.0, height: 5.0,
            rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
                    fill_gradient: None,
            stroke_gradient: None,
        });
        let sq = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        assert!(!element_intersects_polygon(&rect, &sq));
    }

    // ---- transform-aware hit-testing ----

    #[test]
    fn translated_line_intersects_rect() {
        // Line at (0,5)→(10,5) translated by (100, 0) → visual (100,5)→(110,5)
        let line = Element::Line(LineElem {
            common: CommonProps {
                transform: Some(Transform::translate(100.0, 0.0)),
                ..CommonProps::default()
            },
            x1: 0.0, y1: 5.0, x2: 10.0, y2: 5.0,
            stroke: None,
            width_points: vec![],
            stroke_gradient: None,
        });
        // Selection rect around the visual position should hit
        assert!(element_intersects_rect(&line, 95.0, 0.0, 20.0, 10.0));
        // Selection rect around the raw position should miss
        assert!(!element_intersects_rect(&line, 0.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn rotated_rect_intersects_rect() {
        // A 10x10 rect at origin, rotated 45°. Its visual bounding box extends
        // beyond the raw rect.
        let rect = Element::Rect(RectElem {
            common: CommonProps {
                transform: Some(Transform::rotate(45.0)),
                ..CommonProps::default()
            },
            x: 0.0, y: 0.0, width: 10.0, height: 10.0,
            rx: 0.0, ry: 0.0,
            fill: Some(crate::geometry::element::Fill::new(crate::geometry::element::Color::BLACK)),
            stroke: None,
            fill_gradient: None,
            stroke_gradient: None,
        });
        // After 45° rotation, point (10,0) maps to about (7.07, 7.07).
        // A selection rect near (7, 7) should intersect the rotated rect.
        assert!(element_intersects_rect(&rect, 6.0, 6.0, 2.0, 2.0));
        // A rect at (12, 0) should miss — outside the rotated shape.
        assert!(!element_intersects_rect(&rect, 12.0, 0.0, 2.0, 2.0));
    }

    #[test]
    fn scaled_line_intersects_rect() {
        // Line at (0,0)→(5,0) scaled 2x → visual (0,0)→(10,0)
        let line = Element::Line(LineElem {
            common: CommonProps {
                transform: Some(Transform::scale(2.0, 2.0)),
                ..CommonProps::default()
            },
            x1: 0.0, y1: 0.0, x2: 5.0, y2: 0.0,
            stroke: None,
            width_points: vec![],
            stroke_gradient: None,
        });
        // A rect at x=8..12 should hit the scaled line (which reaches x=10)
        assert!(element_intersects_rect(&line, 8.0, -1.0, 4.0, 2.0));
        // A rect at x=6..8 in raw coords (line only goes to x=5) should also hit
        // because after scaling the line reaches x=10
        assert!(element_intersects_rect(&line, 6.0, -1.0, 2.0, 2.0));
    }

    #[test]
    fn singular_transform_returns_false() {
        // Scale(0,0) is singular — element is invisible
        let line = Element::Line(LineElem {
            common: CommonProps {
                transform: Some(Transform::scale(0.0, 0.0)),
                ..CommonProps::default()
            },
            x1: 0.0, y1: 0.0, x2: 10.0, y2: 0.0,
            stroke: None,
            width_points: vec![],
            stroke_gradient: None,
        });
        assert!(!element_intersects_rect(&line, 0.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn no_transform_still_works() {
        // Regression: elements without a transform should still work
        let line = Element::Line(LineElem {
            common: CommonProps::default(),
            x1: 0.0, y1: 5.0, x2: 10.0, y2: 5.0,
            stroke: None,
            width_points: vec![],
                    stroke_gradient: None,
        });
        assert!(element_intersects_rect(&line, 0.0, 0.0, 10.0, 10.0));
        assert!(!element_intersects_rect(&line, 20.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn translated_line_intersects_polygon() {
        let line = Element::Line(LineElem {
            common: CommonProps {
                transform: Some(Transform::translate(100.0, 0.0)),
                ..CommonProps::default()
            },
            x1: 0.0, y1: 5.0, x2: 10.0, y2: 5.0,
            stroke: None,
            width_points: vec![],
            stroke_gradient: None,
        });
        let sq = [(95.0, 0.0), (115.0, 0.0), (115.0, 10.0), (95.0, 10.0)];
        assert!(element_intersects_polygon(&line, &sq));
        let sq2 = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        assert!(!element_intersects_polygon(&line, &sq2));
    }

    // ---- circle_intersects_rect ----

    #[test]
    fn filled_circle_overlaps_rect() {
        assert!(circle_intersects_rect(5.0, 5.0, 3.0, 0.0, 0.0, 10.0, 10.0, true));
    }

    #[test]
    fn filled_circle_outside_rect() {
        assert!(!circle_intersects_rect(20.0, 20.0, 3.0, 0.0, 0.0, 10.0, 10.0, true));
    }

    #[test]
    fn unfilled_circle_ring_intersects_rect() {
        // Rect is inside the circle but doesn't touch the ring
        assert!(!circle_intersects_rect(5.0, 5.0, 100.0, 4.0, 4.0, 2.0, 2.0, false));
    }

    #[test]
    fn unfilled_circle_ring_hit_by_rect() {
        // Rect straddles the circle boundary
        assert!(circle_intersects_rect(5.0, 5.0, 5.0, 9.0, 4.0, 3.0, 2.0, false));
    }

    // ---- ellipse_intersects_rect ----

    #[test]
    fn ellipse_intersects_rect_basic() {
        assert!(ellipse_intersects_rect(5.0, 5.0, 10.0, 3.0, 0.0, 0.0, 10.0, 10.0, true));
    }

    #[test]
    fn ellipse_outside_rect() {
        assert!(!ellipse_intersects_rect(5.0, 5.0, 2.0, 2.0, 20.0, 20.0, 5.0, 5.0, true));
    }

    #[test]
    fn ellipse_zero_radius_returns_false() {
        assert!(!ellipse_intersects_rect(5.0, 5.0, 0.0, 5.0, 0.0, 0.0, 10.0, 10.0, true));
    }

    // ---- element-level circle/ellipse hit-testing ----

    use crate::geometry::element::{EllipseElem, Color, Fill};

    #[test]
    fn circle_element_intersects_rect_filled() {
        let circle = Element::Ellipse(EllipseElem {
            common: CommonProps::default(),
            cx: 5.0, cy: 5.0, rx: 3.0, ry: 3.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
                    fill_gradient: None,
            stroke_gradient: None,
        });
        assert!(element_intersects_rect(&circle, 0.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn circle_element_outside_rect() {
        let circle = Element::Ellipse(EllipseElem {
            common: CommonProps::default(),
            cx: 20.0, cy: 20.0, rx: 3.0, ry: 3.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
                    fill_gradient: None,
            stroke_gradient: None,
        });
        assert!(!element_intersects_rect(&circle, 0.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn unfilled_circle_element_ring_miss() {
        let circle = Element::Ellipse(EllipseElem {
            common: CommonProps::default(),
            cx: 5.0, cy: 5.0, rx: 100.0, ry: 100.0,
            fill: None,
            stroke: None,
                    fill_gradient: None,
            stroke_gradient: None,
        });
        // Rect fully inside the circle -- stroke-only ring not hit
        assert!(!element_intersects_rect(&circle, 4.0, 4.0, 2.0, 2.0));
    }

    #[test]
    fn ellipse_element_intersects_rect_filled() {
        let ellipse = Element::Ellipse(EllipseElem {
            common: CommonProps::default(),
            cx: 5.0, cy: 5.0, rx: 10.0, ry: 3.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
                    fill_gradient: None,
            stroke_gradient: None,
        });
        assert!(element_intersects_rect(&ellipse, 0.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn ellipse_element_outside_rect() {
        let ellipse = Element::Ellipse(EllipseElem {
            common: CommonProps::default(),
            cx: 5.0, cy: 5.0, rx: 2.0, ry: 2.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
                    fill_gradient: None,
            stroke_gradient: None,
        });
        assert!(!element_intersects_rect(&ellipse, 20.0, 20.0, 5.0, 5.0));
    }

    // ---- the transform-blind gap: an ellipse on the polygon-local path ----
    //
    // The identity/null pairs below are the load-bearing ones. Each pair is
    // the SAME ellipse and the SAME region, differing only in whether
    // `transform` is present — and `Transform::IDENTITY` moves no point, so
    // an answer that differs across a pair is an answer about a struct field,
    // not about geometry. Before the Ellipse arm existed they did differ:
    // the identity leg was routed to `element_intersects_polygon_local`, whose
    // catch-all cannot see an ellipse.

    fn ellipse_at(
        cx: f64, cy: f64, rx: f64, ry: f64, fill: Option<Fill>, transform: Option<Transform>,
    ) -> Element {
        Element::Ellipse(EllipseElem {
            common: CommonProps { transform, ..CommonProps::default() },
            cx, cy, rx, ry,
            fill,
            stroke: None,
            fill_gradient: None,
            stroke_gradient: None,
        })
    }

    #[test]
    fn filled_ellipse_enclosing_marquee_same_under_identity_and_none() {
        // Ellipse (10,10) r 6x4 occupies [4,16]x[6,14]; the marquee swallows it.
        let none = ellipse_at(10.0, 10.0, 6.0, 4.0, red_fill(), None);
        let ident = ellipse_at(10.0, 10.0, 6.0, 4.0, red_fill(), Some(Transform::IDENTITY));
        assert!(element_intersects_rect(&none, 0.0, 0.0, 20.0, 20.0));
        assert!(element_intersects_rect(&ident, 0.0, 0.0, 20.0, 20.0));
    }

    #[test]
    fn filled_ellipse_bbox_corner_is_not_a_hit_under_identity_or_none() {
        // The marquee [4,5]x[6,7] sits in the bbox corner, outside the fill:
        // ((4.5-10)/6)^2 + ((6.5-10)/4)^2 well over 1 at every point of it.
        // The catch-all used to answer TRUE here (a region vertex is inside
        // the local bbox), inverting the truth.
        let none = ellipse_at(10.0, 10.0, 6.0, 4.0, red_fill(), None);
        let ident = ellipse_at(10.0, 10.0, 6.0, 4.0, red_fill(), Some(Transform::IDENTITY));
        assert!(!element_intersects_rect(&none, 4.0, 6.0, 1.0, 1.0));
        assert!(!element_intersects_rect(&ident, 4.0, 6.0, 1.0, 1.0));
    }

    #[test]
    fn unfilled_ellipse_ring_crossed_by_marquee_same_under_identity_and_none() {
        // Marquee straddles the right vertex (16,10): min distance 0 (inside),
        // farthest corner outside the ring.
        let none = ellipse_at(10.0, 10.0, 6.0, 4.0, None, None);
        let ident = ellipse_at(10.0, 10.0, 6.0, 4.0, None, Some(Transform::IDENTITY));
        assert!(element_intersects_rect(&none, 14.0, 9.0, 4.0, 2.0));
        assert!(element_intersects_rect(&ident, 14.0, 9.0, 4.0, 2.0));
    }

    #[test]
    fn unfilled_ellipse_marquee_inside_outline_misses_under_identity_and_none() {
        // Wholly inside the ring, touching nothing painted.
        let none = ellipse_at(10.0, 10.0, 6.0, 4.0, None, None);
        let ident = ellipse_at(10.0, 10.0, 6.0, 4.0, None, Some(Transform::IDENTITY));
        assert!(!element_intersects_rect(&none, 9.0, 9.0, 2.0, 2.0));
        assert!(!element_intersects_rect(&ident, 9.0, 9.0, 2.0, 2.0));
    }

    #[test]
    fn scaled_filled_ellipse_enclosing_marquee_hits() {
        // scale(2): the drawn ellipse is centre (20,20), semi-axes 12 and 8.
        let e = ellipse_at(10.0, 10.0, 6.0, 4.0, red_fill(), Some(Transform::scale(2.0, 2.0)));
        assert!(element_intersects_rect(&e, 0.0, 0.0, 40.0, 40.0));
        // ... and the empty corner of its bounding box is still empty.
        assert!(!element_intersects_rect(&e, 8.0, 12.0, 2.0, 2.0));
    }

    #[test]
    fn filled_ellipse_lasso_encloses() {
        let e = ellipse_at(10.0, 10.0, 6.0, 4.0, red_fill(), None);
        let lasso = [(0.0, 0.0), (20.0, 0.0), (20.0, 20.0), (0.0, 20.0)];
        assert!(element_intersects_polygon(&e, &lasso));
    }

    #[test]
    fn unfilled_ellipse_lasso_inside_outline_misses() {
        let e = ellipse_at(10.0, 10.0, 6.0, 4.0, None, None);
        let lasso = [(9.0, 9.0), (11.0, 9.0), (11.0, 11.0), (9.0, 11.0)];
        assert!(!element_intersects_polygon(&e, &lasso));
    }

    #[test]
    fn zero_radius_ellipse_never_hits_a_polygon() {
        let e = ellipse_at(10.0, 10.0, 0.0, 4.0, red_fill(), None);
        let lasso = [(0.0, 0.0), (20.0, 0.0), (20.0, 20.0), (0.0, 20.0)];
        assert!(!element_intersects_polygon(&e, &lasso));
    }

    // ---- circle_intersects_polygon agrees with circle_intersects_rect ----

    #[test]
    fn circle_polygon_matches_circle_rect_on_a_box() {
        let box_poly = |rx: f64, ry: f64, rw: f64, rh: f64| {
            [(rx, ry), (rx + rw, ry), (rx + rw, ry + rh), (rx, ry + rh)]
        };
        let cases = [
            (5.0, 5.0, 3.0, 0.0, 0.0, 10.0, 10.0),   // box around a small disc
            (20.0, 20.0, 3.0, 0.0, 0.0, 10.0, 10.0), // far away
            (5.0, 5.0, 100.0, 4.0, 4.0, 2.0, 2.0),   // box swallowed by the disc
            (5.0, 5.0, 5.0, 9.0, 4.0, 3.0, 2.0),     // box straddling the ring
        ];
        for &(cx, cy, r, rx, ry, rw, rh) in &cases {
            for &filled in &[true, false] {
                assert_eq!(
                    circle_intersects_polygon(cx, cy, r, &box_poly(rx, ry, rw, rh), filled),
                    circle_intersects_rect(cx, cy, r, rx, ry, rw, rh, filled),
                    "circle ({cx},{cy}) r{r} vs box ({rx},{ry},{rw},{rh}) filled={filled}",
                );
            }
        }
    }

    // ---- the second gap: a marquee wholly inside a filled catch-all shape ----

    use crate::geometry::element::PolygonElem;

    fn filled_square(transform: Option<Transform>) -> Element {
        Element::Polygon(PolygonElem {
            common: CommonProps { transform, ..CommonProps::default() },
            points: vec![(0.0, 0.0), (20.0, 0.0), (20.0, 20.0), (0.0, 20.0)],
            fill: red_fill(),
            stroke: None,
            fill_gradient: None,
            stroke_gradient: None,
        })
    }

    #[test]
    fn marquee_inside_filled_polygon_same_under_identity_and_none() {
        // Touches no vertex, crosses no edge — but every point of it is painted.
        assert!(element_intersects_rect(&filled_square(None), 5.0, 5.0, 4.0, 4.0));
        assert!(element_intersects_rect(
            &filled_square(Some(Transform::IDENTITY)), 5.0, 5.0, 4.0, 4.0
        ));
    }

    #[test]
    fn marquee_outside_filled_polygon_still_misses() {
        assert!(!element_intersects_rect(&filled_square(None), 50.0, 50.0, 4.0, 4.0));
        assert!(!element_intersects_rect(
            &filled_square(Some(Transform::IDENTITY)), 50.0, 50.0, 4.0, 4.0
        ));
    }

    #[test]
    fn marquee_inside_unfilled_polygon_still_misses() {
        let mut hollow = filled_square(None);
        if let Element::Polygon(p) = &mut hollow { p.fill = None; }
        assert!(!element_intersects_rect(&hollow, 5.0, 5.0, 4.0, 4.0));
    }

    // ── RESOLVEDHIT: the resolver-less verb's contract, pinned ──────────────
    //
    // The tempting "fix" for an unhittable symbol instance is to give the
    // resolver-less path something to chew on — flatten the instance, cache
    // geometry on it, widen the catch-all. Each would make the SHARED verb
    // answer a question it cannot actually see: with no document behind it,
    // there is no fact about where a target id is.
    //
    // These pin the boundary, so the shortcut cannot land later and look green.
    // Same shape as CONTAINERPAINT's guard on `Element::fill()`: the repair is
    // replaceable, the guard against the wrong repair is not.

    fn bare_reference() -> Element {
        use crate::geometry::element::CommonProps;
        use crate::geometry::live::{ElementRef, ReferenceElem};
        Element::Live(LiveVariant::Reference(ReferenceElem::new(
            ElementRef("m1".into()),
            CommonProps::default(),
        )))
    }

    #[test]
    fn the_resolverless_verb_keeps_answering_false_for_a_reference() {
        let r = bare_reference();
        assert!(!element_intersects_rect(&r, -1000.0, -1000.0, 2000.0, 2000.0));
        let big = [
            (-1000.0, -1000.0), (1000.0, -1000.0), (1000.0, 1000.0), (-1000.0, 1000.0),
        ];
        assert!(!element_intersects_polygon(&r, &big));
        assert!(segments_of_element(&r).is_empty());
    }

    #[test]
    fn a_resolver_that_resolves_nothing_agrees_with_the_resolverless_verb() {
        // NullResolver is not a special case in the `_with` path — it is the
        // ordinary dangling answer. If these two ever disagree, the `_with`
        // form has grown geometry out of nothing.
        let r = bare_reference();
        assert_eq!(
            element_intersects_rect_with(&r, -1000.0, -1000.0, 2000.0, 2000.0, &NullResolver),
            element_intersects_rect(&r, -1000.0, -1000.0, 2000.0, 2000.0),
        );
        assert_eq!(resolved_bounds(&r, &NullResolver), r.bounds());
    }

    #[test]
    fn a_resolver_that_resolves_the_target_sees_the_masters_geometry() {
        // The algorithm-level half of the controller tests: same element, two
        // resolvers, opposite answers — so the repair demonstrably turns on
        // resolution and not on anything else about the element.
        use crate::geometry::element::{CommonProps, PolygonElem};
        use crate::geometry::live::{ElementRef, ElementResolver};
        use std::rc::Rc;

        struct One(Rc<Element>);
        impl ElementResolver for One {
            fn resolve(&self, id: &ElementRef) -> Option<Rc<Element>> {
                (id.0 == "m1").then(|| self.0.clone())
            }
        }
        let master = Rc::new(Element::Polygon(PolygonElem {
            common: CommonProps { id: Some("m1".into()), ..CommonProps::default() },
            points: vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)],
            fill: red_fill(),
            stroke: None,
            fill_gradient: None,
            stroke_gradient: None,
        }));
        let r = bare_reference();

        assert!(element_intersects_rect_with(&r, -1.0, -1.0, 12.0, 12.0, &One(master)));
        assert!(!element_intersects_rect(&r, -1.0, -1.0, 12.0, 12.0));
    }
}
