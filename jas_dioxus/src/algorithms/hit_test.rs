//! Geometry helpers for precise hit-testing.
//!
//! Pure-geometry functions used by the controller for marquee selection,
//! element intersection tests, and control-point queries.  These do not
//! depend on the document model — only on element geometry.

use crate::geometry::element::{flatten_path_commands, Element};

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

pub fn element_intersects_polygon(elem: &Element, poly: &[(f64, f64)]) -> bool {
    if let Some(t) = elem.transform() {
        if let Some(inv) = t.inverse() {
            let local_poly: Vec<(f64, f64)> = poly.iter()
                .map(|&(x, y)| inv.apply_point(x, y))
                .collect();
            return element_intersects_polygon_local(elem, &local_poly);
        }
        return false;
    }
    element_intersects_polygon_local(elem, poly)
}

/// Polygon hit-test against an element's raw (untransformed) coordinates.
fn element_intersects_polygon_local(elem: &Element, poly: &[(f64, f64)]) -> bool {
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
                let segs = segments_of_element(elem);
                segs.iter().any(|&(x1, y1, x2, y2)| segment_intersects_polygon(x1, y1, x2, y2, poly))
            } else {
                segments_of_element(elem)
                    .iter()
                    .any(|&(x1, y1, x2, y2)| segment_intersects_polygon(x1, y1, x2, y2, poly))
            }
        }
        Element::Text(_) | Element::TextPath(_) | Element::Group(_) | Element::Layer(_) => {
            let (bx, by, bw, bh) = elem.bounds();
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
                let segs = segments_of_element(elem);
                let endpoints: Vec<(f64, f64)> = segs
                    .iter()
                    .flat_map(|&(x1, y1, x2, y2)| vec![(x1, y1), (x2, y2)])
                    .collect();
                if endpoints.iter().any(|&(px, py)| point_in_polygon(px, py, poly)) {
                    return true;
                }
                if poly.iter().any(|&(px, py)| {
                    let b = elem.bounds();
                    point_in_rect(px, py, b.0, b.1, b.2, b.3)
                }) {
                    return true;
                }
                segs.iter()
                    .any(|&(x1, y1, x2, y2)| segment_intersects_polygon(x1, y1, x2, y2, poly))
            } else {
                segments_of_element(elem)
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

// ---------------------------------------------------------------------------
// Element-level queries
// ---------------------------------------------------------------------------

pub fn segments_of_element(elem: &Element) -> Vec<(f64, f64, f64, f64)> {
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
        _ => vec![],
    }
}

pub fn element_intersects_rect(elem: &Element, rx: f64, ry: f64, rw: f64, rh: f64) -> bool {
    if let Some(t) = elem.transform() {
        if let Some(inv) = t.inverse() {
            let corners = [
                inv.apply_point(rx, ry),
                inv.apply_point(rx + rw, ry),
                inv.apply_point(rx + rw, ry + rh),
                inv.apply_point(rx, ry + rh),
            ];
            return element_intersects_polygon_local(elem, &corners);
        }
        return false; // singular transform — element is invisible
    }
    element_intersects_rect_local(elem, rx, ry, rw, rh)
}

/// Rect hit-test against an element's raw (untransformed) coordinates.
fn element_intersects_rect_local(elem: &Element, rx: f64, ry: f64, rw: f64, rh: f64) -> bool {
    match elem {
        Element::Line(e) => {
            segment_intersects_rect(e.x1, e.y1, e.x2, e.y2, rx, ry, rw, rh)
        }
        Element::Rect(e) => {
            if e.fill.is_some() {
                rects_intersect(e.x, e.y, e.width, e.height, rx, ry, rw, rh)
            } else {
                segments_of_element(elem)
                    .iter()
                    .any(|&(x1, y1, x2, y2)| segment_intersects_rect(x1, y1, x2, y2, rx, ry, rw, rh))
            }
        }
        Element::Circle(e) => {
            circle_intersects_rect(e.cx, e.cy, e.r, rx, ry, rw, rh, e.fill.is_some())
        }
        Element::Ellipse(e) => {
            ellipse_intersects_rect(e.cx, e.cy, e.rx, e.ry, rx, ry, rw, rh, e.fill.is_some())
        }
        Element::Text(_) | Element::TextPath(_) => {
            let b = elem.bounds();
            rects_intersect(b.0, b.1, b.2, b.3, rx, ry, rw, rh)
        }
        Element::Group(_) | Element::Layer(_) => {
            let b = elem.bounds();
            rects_intersect(b.0, b.1, b.2, b.3, rx, ry, rw, rh)
        }
        _ => {
            if elem.fill().is_some() {
                let segs = segments_of_element(elem);
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
                segs.iter()
                    .any(|&(x1, y1, x2, y2)| segment_intersects_rect(x1, y1, x2, y2, rx, ry, rw, rh))
            } else {
                segments_of_element(elem)
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
        });
        assert!(!element_intersects_rect(&rect, 0.0, 0.0, 10.0, 10.0));
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

    use crate::geometry::element::{CircleElem, EllipseElem, Color, Fill};

    #[test]
    fn circle_element_intersects_rect_filled() {
        let circle = Element::Circle(CircleElem {
            common: CommonProps::default(),
            cx: 5.0, cy: 5.0, r: 3.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
        });
        assert!(element_intersects_rect(&circle, 0.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn circle_element_outside_rect() {
        let circle = Element::Circle(CircleElem {
            common: CommonProps::default(),
            cx: 20.0, cy: 20.0, r: 3.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
        });
        assert!(!element_intersects_rect(&circle, 0.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn unfilled_circle_element_ring_miss() {
        let circle = Element::Circle(CircleElem {
            common: CommonProps::default(),
            cx: 5.0, cy: 5.0, r: 100.0,
            fill: None,
            stroke: None,
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
        });
        assert!(!element_intersects_rect(&ellipse, 20.0, 20.0, 5.0, 5.0));
    }
}
