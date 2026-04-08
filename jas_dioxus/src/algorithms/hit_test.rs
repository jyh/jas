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

    use crate::geometry::element::{LineElem, RectElem, CommonProps};

    #[test]
    fn line_element_intersects_rect_overlapping() {
        let line = Element::Line(LineElem {
            common: CommonProps::default(),
            x1: -5.0, y1: 5.0, x2: 15.0, y2: 5.0,
            stroke: None,
        });
        assert!(element_intersects_rect(&line, 0.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn line_element_outside_rect() {
        let line = Element::Line(LineElem {
            common: CommonProps::default(),
            x1: 20.0, y1: 0.0, x2: 30.0, y2: 0.0,
            stroke: None,
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
}
