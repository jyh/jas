//! The hit test's law: a click hits what is painted, not a bounding box.
//!
//! The statement is `transcripts/SELECTION_TOOL.md` § Hit test: painted
//! geometry; the executable meaning is the reference's
//! `workspace_interpreter/hit_law.py`, which this module mirrors function
//! for function (as does JasSwift `HitLaw.swift`). `doc_primitives::hit_test`
//! and `hit_test_deep` walk the document and ask [`painted_hit`] /
//! [`deep_hit`] about each element.

use std::f64::consts::PI;

use crate::geometry::element::{Element, FillRule, PathCommand, StrokeAlign, Visibility};
use crate::geometry::live::{LiveVariant, DEFAULT_PRECISION};

/// How far from a painted edge a click still hits, in document units.
pub const HIT_TOLERANCE: f64 = 3.0;

/// Line segments per Bezier segment; the path flattener's own count.
const CURVE_STEPS: usize = 20;

/// Sides of the polygon that stands in for an ellipse outline.
const ELLIPSE_SIDES: usize = 64;

/// One flattened subpath: its points and whether it is closed.
type Polyline = (Vec<(f64, f64)>, bool);

// ── Geometry helpers ─────────────────────────────────────

fn dist_to_segment(px: f64, py: f64, ax: f64, ay: f64, bx: f64, by: f64) -> f64 {
    let (dx, dy) = (bx - ax, by - ay);
    let len2 = dx * dx + dy * dy;
    if len2 == 0.0 {
        return (px - ax).hypot(py - ay);
    }
    let t = (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0);
    (px - (ax + t * dx)).hypot(py - (ay + t * dy))
}

/// Distance to the nearest segment of any polyline.
fn dist_to_outline(px: f64, py: f64, polylines: &[Polyline]) -> f64 {
    let mut best = f64::INFINITY;
    for (pts, closed) in polylines {
        let n = pts.len();
        if n == 1 {
            best = best.min((px - pts[0].0).hypot(py - pts[0].1));
            continue;
        }
        let last = if *closed { n } else { n.saturating_sub(1) };
        for i in 0..last {
            let (ax, ay) = pts[i];
            let (bx, by) = pts[(i + 1) % n];
            best = best.min(dist_to_segment(px, py, ax, ay, bx, by));
        }
    }
    best
}

/// Winding number of `ring` (implicitly closed) around the point.
fn winding(px: f64, py: f64, ring: &[(f64, f64)]) -> i32 {
    let mut w = 0;
    let n = ring.len();
    for i in 0..n {
        let (ax, ay) = ring[i];
        let (bx, by) = ring[(i + 1) % n];
        let cross = (bx - ax) * (py - ay) - (px - ax) * (by - ay);
        if ay <= py {
            if by > py && cross > 0.0 {
                w += 1;
            }
        } else if by <= py && cross < 0.0 {
            w -= 1;
        }
    }
    w
}

fn inside_rings(px: f64, py: f64, outline: &[Polyline], even_odd: bool) -> bool {
    let total: i32 = outline
        .iter()
        .filter(|(pts, _)| pts.len() >= 3)
        .map(|(pts, _)| winding(px, py, pts))
        .sum();
    if even_odd {
        total % 2 != 0
    } else {
        total != 0
    }
}

fn ellipse_polygon(cx: f64, cy: f64, rx: f64, ry: f64) -> Vec<(f64, f64)> {
    (0..ELLIPSE_SIDES)
        .map(|k| {
            let a = 2.0 * PI * k as f64 / ELLIPSE_SIDES as f64;
            (cx + rx * a.cos(), cy + ry * a.sin())
        })
        .collect()
}

/// Flatten path commands to one polyline per subpath. Unlike
/// `flatten_path_commands`, a MoveTo starts a NEW polyline, so nothing is
/// drawn between one subpath's end and the next one's start. Smooth curves
/// and arcs go straight to their end point, as in the path flattener.
pub fn path_subpaths(d: &[PathCommand]) -> Vec<Polyline> {
    let mut out: Vec<Polyline> = Vec::new();
    let mut cur: Vec<(f64, f64)> = Vec::new();
    let (mut cx, mut cy, mut sx, mut sy) = (0.0, 0.0, 0.0, 0.0);
    for cmd in d {
        match *cmd {
            PathCommand::MoveTo { x, y } => {
                if !cur.is_empty() {
                    out.push((std::mem::take(&mut cur), false));
                }
                cur.push((x, y));
                (cx, cy, sx, sy) = (x, y, x, y);
            }
            PathCommand::ClosePath => {
                if !cur.is_empty() {
                    out.push((std::mem::take(&mut cur), true));
                }
                (cx, cy) = (sx, sy);
            }
            _ => {
                if cur.is_empty() {
                    cur.push((cx, cy));
                }
                let (x, y) = match *cmd {
                    PathCommand::CurveTo { x1, y1, x2, y2, x, y } => {
                        for i in 1..=CURVE_STEPS {
                            let t = i as f64 / CURVE_STEPS as f64;
                            let mt = 1.0 - t;
                            cur.push((
                                mt.powi(3) * cx + 3.0 * mt.powi(2) * t * x1
                                    + 3.0 * mt * t.powi(2) * x2 + t.powi(3) * x,
                                mt.powi(3) * cy + 3.0 * mt.powi(2) * t * y1
                                    + 3.0 * mt * t.powi(2) * y2 + t.powi(3) * y,
                            ));
                        }
                        (x, y)
                    }
                    PathCommand::QuadTo { x1, y1, x, y } => {
                        for i in 1..=CURVE_STEPS {
                            let t = i as f64 / CURVE_STEPS as f64;
                            let mt = 1.0 - t;
                            cur.push((
                                mt.powi(2) * cx + 2.0 * mt * t * x1 + t.powi(2) * x,
                                mt.powi(2) * cy + 2.0 * mt * t * y1 + t.powi(2) * y,
                            ));
                        }
                        (x, y)
                    }
                    PathCommand::LineTo { x, y }
                    | PathCommand::SmoothCurveTo { x, y, .. }
                    | PathCommand::SmoothQuadTo { x, y }
                    | PathCommand::ArcTo { x, y, .. } => {
                        cur.push((x, y));
                        (x, y)
                    }
                    PathCommand::MoveTo { .. } | PathCommand::ClosePath => unreachable!(),
                };
                (cx, cy) = (x, y);
            }
        }
    }
    if !cur.is_empty() {
        out.push((cur, false));
    }
    out
}

// ── The law ──────────────────────────────────────────────

/// Polylines for a leaf, or `None` when the leaf is hit by its bounding
/// box instead (text, and the resolver-backed live kinds).
fn outline(elem: &Element) -> Option<Vec<Polyline>> {
    match elem {
        Element::Line(e) => Some(vec![(vec![(e.x1, e.y1), (e.x2, e.y2)], false)]),
        Element::Rect(e) => {
            let (x, y, w, h) = (e.x, e.y, e.width, e.height);
            Some(vec![(vec![(x, y), (x + w, y), (x + w, y + h), (x, y + h)], true)])
        }
        Element::Ellipse(e) => Some(vec![(ellipse_polygon(e.cx, e.cy, e.rx, e.ry), true)]),
        Element::Polyline(e) => Some(vec![(e.points.clone(), false)]),
        Element::Polygon(e) => Some(vec![(e.points.clone(), true)]),
        Element::Path(e) => Some(path_subpaths(&e.d)),
        Element::Live(LiveVariant::CompoundShape(cs)) => Some(
            cs.evaluate(DEFAULT_PRECISION)
                .into_iter()
                .map(|ring| (ring, true))
                .collect(),
        ),
        _ => None,
    }
}

fn inside_fill(elem: &Element, outline: &[Polyline], px: f64, py: f64) -> bool {
    match elem {
        Element::Line(_) => false,
        Element::Rect(e) => {
            e.x <= px && px <= e.x + e.width && e.y <= py && py <= e.y + e.height
        }
        Element::Ellipse(e) => {
            if e.rx <= 0.0 || e.ry <= 0.0 {
                return false;
            }
            let (nx, ny) = ((px - e.cx) / e.rx, (py - e.cy) / e.ry);
            nx * nx + ny * ny <= 1.0
        }
        Element::Path(e) => inside_rings(px, py, outline, e.fill_rule == FillRule::EvenOdd),
        Element::Live(LiveVariant::CompoundShape(_)) => inside_rings(px, py, outline, true),
        _ => inside_rings(px, py, outline, false),
    }
}

fn box_contains(elem: &Element, px: f64, py: f64) -> bool {
    let (bx, by, bw, bh) = elem.bounds();
    bx <= px && px <= bx + bw && by <= py && py <= by + bh
}

/// Map a point from the parent's coordinates into `elem`'s own; `None`
/// when the element's transform cannot be inverted.
pub fn to_local(elem: &Element, px: f64, py: f64) -> Option<(f64, f64)> {
    match elem.transform() {
        None => Some((px, py)),
        Some(t) => t.inverse().map(|inv| inv.apply_point(px, py)),
    }
}

/// Whether a non-container element is hit at (px, py), given in its
/// PARENT's coordinates.
pub fn leaf_painted_hit(elem: &Element, px: f64, py: f64, outline_mode: bool) -> bool {
    let Some((px, py)) = to_local(elem, px, py) else {
        return false;
    };
    let Some(outline) = outline(elem) else {
        return box_contains(elem, px, py);
    };
    if outline_mode {
        return dist_to_outline(px, py, &outline) <= HIT_TOLERANCE;
    }
    let has_fill = elem.fill().is_some() || elem.fill_gradient().is_some();
    if has_fill && inside_fill(elem, &outline, px, py) {
        return true;
    }
    if let Some(s) = elem.stroke() {
        let reach = if s.align == StrokeAlign::Center { s.width / 2.0 } else { s.width };
        return dist_to_outline(px, py, &outline) <= reach + HIT_TOLERANCE;
    }
    false
}

/// The effective visibility of `elem` under `cap`, or `None` when the
/// element (and everything inside it) cannot be hit.
pub fn blocks_hit(elem: &Element, cap: Visibility) -> Option<Visibility> {
    if elem.locked() {
        return None;
    }
    let vis = std::cmp::min(cap, elem.visibility());
    (vis != Visibility::Invisible).then_some(vis)
}

/// Whether `elem` is hit at (px, py), given in its PARENT's coordinates,
/// under the inherited visibility `cap`. A group is hit when any child is.
pub fn painted_hit(elem: &Element, px: f64, py: f64, cap: Visibility) -> bool {
    let Some(vis) = blocks_hit(elem, cap) else {
        return false;
    };
    if let (true, Some(children)) = (elem.is_group_or_layer(), elem.children()) {
        let Some((lx, ly)) = to_local(elem, px, py) else {
            return false;
        };
        return children.iter().rev().any(|c| painted_hit(c, lx, ly, vis));
    }
    leaf_painted_hit(elem, px, py, vis == Visibility::Outline)
}

/// The deepest painted leaf under (px, py) inside `elem`, as a path.
/// Coordinates are in `elem`'s PARENT's space.
pub fn deep_hit(
    elem: &Element,
    path: Vec<usize>,
    px: f64,
    py: f64,
    cap: Visibility,
) -> Option<Vec<usize>> {
    let vis = blocks_hit(elem, cap)?;
    if let (true, Some(children)) = (elem.is_group_or_layer(), elem.children()) {
        let (lx, ly) = to_local(elem, px, py)?;
        for (i, child) in children.iter().enumerate().rev() {
            let mut p = path.clone();
            p.push(i);
            if let Some(r) = deep_hit(child, p, lx, ly, vis) {
                return Some(r);
            }
        }
        return None;
    }
    leaf_painted_hit(elem, px, py, vis == Visibility::Outline).then_some(path)
}

#[cfg(test)]
mod tests {
    use crate::geometry::test_json::test_json_to_document;
    use crate::interpreter::doc_primitives::{hit_test, hit_test_deep, register_document};
    use crate::interpreter::expr_types::Value;

    /// Replays `test_fixtures/algorithms/painted_hit.json`, the corpus the
    /// reference writes from its hand-derived expectations
    /// (`workspace_interpreter/tests/test_hit_law.py`).
    #[test]
    fn the_shared_painted_hit_corpus() {
        let text = std::fs::read_to_string("../test_fixtures/algorithms/painted_hit.json")
            .expect("painted_hit.json");
        let corpus: serde_json::Value = serde_json::from_str(&text).unwrap();
        let cases = corpus["cases"].as_array().unwrap();
        // Anti-vacuity: the corpus is the reference's 49 rows (a floor).
        assert!(cases.len() >= 49, "corpus has {} rows", cases.len());
        let mut failures = Vec::new();
        for case in cases {
            let doc = test_json_to_document(&case["document"].to_string());
            let (x, y) = (case["x"].as_f64().unwrap(), case["y"].as_f64().unwrap());
            let got = {
                let _g = register_document(doc);
                if case["deep"].as_bool().unwrap() { hit_test_deep(x, y) } else { hit_test(x, y) }
            };
            let expect = match case["expect"].as_array() {
                None => Value::Null,
                Some(p) => Value::Path(p.iter().map(|v| v.as_u64().unwrap() as usize).collect()),
            };
            if got != expect {
                failures.push(format!("{}: got {:?}, law says {:?}", case["name"], got, expect));
            }
        }
        assert!(failures.is_empty(), "{} of {} rows:\n{}", failures.len(), cases.len(), failures.join("\n"));
    }

    /// A compound's own fill, which the corpus cannot carry (test_json omits
    /// a compound's paint in every port). Mirrors the reference's
    /// `test_a_compound_shape_hits_its_evaluated_area`.
    #[test]
    fn a_compound_shape_hits_its_evaluated_area() {
        use super::painted_hit;
        use crate::geometry::element::{Color, CommonProps, Element, Fill, RectElem, Visibility};
        use crate::geometry::live::{CompoundOperation, CompoundShape, LiveVariant};
        let rect = |x: f64, w: f64| {
            std::rc::Rc::new(Element::Rect(RectElem {
                x, y: x, width: w, height: w, rx: 0.0, ry: 0.0,
                fill: Some(Fill::new(Color::BLACK)), stroke: None,
                common: CommonProps::default(), fill_gradient: None, stroke_gradient: None,
            }))
        };
        let cs = Element::Live(LiveVariant::CompoundShape(CompoundShape {
            operation: CompoundOperation::SubtractFront,
            operands: vec![rect(0.0, 40.0), rect(10.0, 20.0)],
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
            common: CommonProps::default(),
        }));
        assert!(painted_hit(&cs, 5.0, 5.0, Visibility::Preview));
        assert!(!painted_hit(&cs, 20.0, 20.0, Visibility::Preview), "the hole");
    }
}
