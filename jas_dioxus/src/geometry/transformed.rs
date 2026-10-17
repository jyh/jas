//! Geometry for the live transform operation (council 2026-10-16, ruling 4).
//!
//! Pure helpers shared by the renderer (`painter::element_render`'s
//! `MappedGeometry`, the Scale Strokes OFF drawing) and by Release Transform
//! (`TransformedElem::released`), so the two cannot disagree about what a
//! mapped arc or a mapped ellipse is.

use std::rc::Rc;

use super::element::{Element, PathCommand, PathElem, Stroke, Transform};
use super::live::LiveVariant;

/// The axes of an ellipse's image under the linear part of `m`.
///
/// The ellipse is `A·(cos t, sin t)` with `A = L·R(rotation)·diag(rx, ry)`. A
/// mirroring `L` (det < 0) is first made rotation-only by
/// `A·(cos t, sin t) = (A·F)·(cos −t, sin −t)` with `F = diag(1, −1)`, which
/// negates the angles and flips the sweep. Then `A = R(φ)·diag(s1, s2)·R(θ)`
/// (the closed-form 2×2 SVD), so the image has radii `s1 ≥ s2`, rotation `φ`,
/// and a point at angle `t` lands at angle `t + θ` (after the negation, when
/// mirrored). Returns `(s1, s2, φ, θ, mirrored)`. JasSwift's
/// `ellipseAxesThrough` is the same derivation.
pub fn ellipse_axes_through(m: &Transform, rx: f64, ry: f64, rotation: f64) -> (f64, f64, f64, f64, bool) {
    let (cr, sr) = (rotation.cos(), rotation.sin());
    // A = L · R(rot) · diag(rx, ry), as [[a, b], [c, d]] (row-major).
    let (a, mut b, c, mut d) = (
        (m.a * cr + m.c * sr) * rx,
        (-m.a * sr + m.c * cr) * ry,
        (m.b * cr + m.d * sr) * rx,
        (-m.b * sr + m.d * cr) * ry,
    );
    let mirrored = a * d - b * c < 0.0;
    if mirrored {
        // A·F negates A's second column.
        b = -b;
        d = -d;
    }
    let (e, f, g, h) = ((a + d) / 2.0, (a - d) / 2.0, (c + b) / 2.0, (c - b) / 2.0);
    let (q, r) = ((e * e + h * h).sqrt(), (f * f + g * g).sqrt());
    let (a1, a2) = (g.atan2(f), h.atan2(e));
    (q + r, (q - r).max(0.0), (a2 + a1) / 2.0, (a2 - a1) / 2.0, mirrored)
}

/// Every coordinate of `path` mapped through `m`. Exact for every command: an
/// affine map preserves the reflections smooth segments imply, and an
/// elliptical arc's image is an elliptical arc (new axes from
/// [`ellipse_axes_through`], the same large-arc choice, the sweep flipped by
/// a mirror).
pub fn map_path_commands(path: &[PathCommand], m: &Transform) -> Vec<PathCommand> {
    let pt = |x: f64, y: f64| m.apply_point(x, y);
    path.iter()
        .map(|c| match *c {
            PathCommand::MoveTo { x, y } => {
                let (x, y) = pt(x, y);
                PathCommand::MoveTo { x, y }
            }
            PathCommand::LineTo { x, y } => {
                let (x, y) = pt(x, y);
                PathCommand::LineTo { x, y }
            }
            PathCommand::CurveTo { x1, y1, x2, y2, x, y } => {
                let ((x1, y1), (x2, y2), (x, y)) = (pt(x1, y1), pt(x2, y2), pt(x, y));
                PathCommand::CurveTo { x1, y1, x2, y2, x, y }
            }
            PathCommand::QuadTo { x1, y1, x, y } => {
                let ((x1, y1), (x, y)) = (pt(x1, y1), pt(x, y));
                PathCommand::QuadTo { x1, y1, x, y }
            }
            PathCommand::SmoothCurveTo { x2, y2, x, y } => {
                let ((x2, y2), (x, y)) = (pt(x2, y2), pt(x, y));
                PathCommand::SmoothCurveTo { x2, y2, x, y }
            }
            PathCommand::SmoothQuadTo { x, y } => {
                let (x, y) = pt(x, y);
                PathCommand::SmoothQuadTo { x, y }
            }
            PathCommand::ArcTo { rx, ry, x_rotation, large_arc, sweep, x, y } => {
                let (rx, ry, rot, _, mirrored) = ellipse_axes_through(m, rx, ry, x_rotation.to_radians());
                let (x, y) = pt(x, y);
                PathCommand::ArcTo { rx, ry, x_rotation: rot.to_degrees(), large_arc, sweep: sweep != mirrored, x, y }
            }
            PathCommand::ClosePath => PathCommand::ClosePath,
        })
        .collect()
}

/// √|det| of a transform: the uniform stroke scale it applies.
pub fn uniform_scale(t: &Transform) -> f64 {
    (t.a * t.d - t.b * t.c).abs().sqrt()
}

fn scaled_stroke(s: &Option<Stroke>, k: f64) -> Option<Stroke> {
    let mut s = (*s)?;
    if k != 1.0 {
        s.width *= k;
        for d in s.dash_pattern.iter_mut() {
            *d *= k;
        }
    }
    Some(s)
}

/// `elem` with `m` BAKED INTO ITS COORDINATES and its stroke left at the
/// authored width: the Scale Strokes OFF drawing as a static element (Release
/// Transform, OFF). The picture is unchanged, and the element keeps its kind
/// wherever its kind can hold the result:
///
/// * a rect under an AXIS-ALIGNED matrix stays a rect (its corner radii scale
///   per axis); under a rotation or shear it becomes a path (a parallelogram is
///   not a rect);
/// * an ellipse stays an ellipse under ANY matrix: its image's axes come from
///   [`ellipse_axes_through`], and a rotation (which scales no stroke) goes on
///   its transform;
/// * lines, polylines, polygons and paths map their points;
/// * a group maps its children;
/// * text keeps its glyphs and takes the matrix on its transform.
///
/// The element's OWN transform is folded into the mapping first, and it scales
/// the stroke by its √|det| (`k`), exactly as the renderer's `MappedGeometry`
/// does: exact when that transform is uniform, the stated limit when not.
pub fn map_element_geometry(elem: &Element, m: &Transform) -> Element {
    map_with(elem, m, 1.0)
}

fn map_with(elem: &Element, m_in: &Transform, k_in: f64) -> Element {
    let (m, k) = match elem.transform() {
        Some(t) => (m_in.multiply(t), k_in * uniform_scale(t)),
        None => (*m_in, k_in),
    };
    let axis_aligned = m.b == 0.0 && m.c == 0.0;
    match elem {
        Element::Rect(e) if axis_aligned => {
            let (x0, y0) = m.apply_point(e.x, e.y);
            let (x1, y1) = m.apply_point(e.x + e.width, e.y + e.height);
            let mut r = e.clone();
            (r.x, r.y, r.width, r.height) = (x0.min(x1), y0.min(y1), (x1 - x0).abs(), (y1 - y0).abs());
            (r.rx, r.ry) = (e.rx * m.a.abs(), e.ry * m.d.abs());
            r.stroke = scaled_stroke(&e.stroke, k);
            r.common.transform = None;
            Element::Rect(r)
        }
        Element::Rect(e) => {
            let d = crate::painter::element_render::rect_geometry_path(e);
            Element::Path(PathElem {
                d: map_path_commands(&d, &m),
                fill: e.fill,
                stroke: scaled_stroke(&e.stroke, k),
                width_points: Vec::new(),
                common: super::element::CommonProps { transform: None, ..e.common.clone() },
                fill_gradient: e.fill_gradient.clone(),
                stroke_gradient: e.stroke_gradient.clone(),
                fill_rule: Default::default(),
                stroke_brush: None,
                stroke_brush_overrides: None,
            })
        }
        Element::Ellipse(e) => {
            let (rx, ry, rot, _, _) = ellipse_axes_through(&m, e.rx, e.ry, 0.0);
            let (cx, cy) = m.apply_point(e.cx, e.cy);
            let mut out = e.clone();
            (out.cx, out.cy, out.rx, out.ry) = (cx, cy, rx, ry);
            out.stroke = scaled_stroke(&e.stroke, k);
            out.common.transform = if rot == 0.0 {
                None
            } else {
                Some(Transform::rotate(rot.to_degrees()).around_point(cx, cy))
            };
            Element::Ellipse(out)
        }
        Element::Line(e) => {
            let mut out = e.clone();
            ((out.x1, out.y1), (out.x2, out.y2)) = (m.apply_point(e.x1, e.y1), m.apply_point(e.x2, e.y2));
            out.stroke = scaled_stroke(&e.stroke, k);
            out.common.transform = None;
            Element::Line(out)
        }
        Element::Polyline(e) => {
            let mut out = e.clone();
            out.points = e.points.iter().map(|&(x, y)| m.apply_point(x, y)).collect();
            out.stroke = scaled_stroke(&e.stroke, k);
            out.common.transform = None;
            Element::Polyline(out)
        }
        Element::Polygon(e) => {
            let mut out = e.clone();
            out.points = e.points.iter().map(|&(x, y)| m.apply_point(x, y)).collect();
            out.stroke = scaled_stroke(&e.stroke, k);
            out.common.transform = None;
            Element::Polygon(out)
        }
        Element::Path(e) => {
            let mut out = e.clone();
            out.d = map_path_commands(&e.d, &m);
            out.stroke = scaled_stroke(&e.stroke, k);
            out.common.transform = None;
            Element::Path(out)
        }
        Element::Group(g) => {
            let mut out = g.clone();
            out.children = g.children.iter().map(|c| Rc::new(map_with(c, &m, k))).collect();
            out.common.transform = None;
            Element::Group(out)
        }
        Element::Layer(l) => {
            let mut out = l.clone();
            out.children = l.children.iter().map(|c| Rc::new(map_with(c, &m, k))).collect();
            out.common.transform = None;
            Element::Layer(out)
        }
        // A wrapper inside: an OFF one composes into one OFF wrapper (exact);
        // an ON one scales what it holds by its √|det|, the renderer's rule.
        Element::Live(LiveVariant::Transformed(t)) => {
            if t.scale_strokes {
                map_with(&t.child, &m.multiply(&t.matrix), k * uniform_scale(&t.matrix))
            } else {
                let mut out = t.clone();
                out.matrix = m.multiply(&t.matrix);
                out.common.transform = None;
                Element::Live(LiveVariant::Transformed(out))
            }
        }
        // Text keeps its glyphs; a compound, reference, recorded or generated
        // element keeps its own model. All take the matrix on their transform.
        // ⚠️ LIMIT: a stroke there is then scaled by it.
        _ => {
            let mut out = elem.clone();
            out.common_mut().transform = Some(m);
            out
        }
    }
}
