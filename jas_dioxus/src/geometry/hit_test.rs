//! Geometry helpers for precise hit-testing.
//!
//! Pure-geometry functions used by the controller for marquee selection,
//! element intersection tests, and control-point queries.  These do not
//! depend on the document model — only on element geometry.

use std::collections::HashSet;

use super::element::{control_point_count, flatten_path_commands, Element};

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

pub fn all_cps(elem: &Element) -> HashSet<usize> {
    (0..control_point_count(elem)).collect()
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
