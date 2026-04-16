//! Shape recognition: classify a freehand path as the nearest geometric
//! primitive (line, scribble, triangle, rectangle, rounded rectangle,
//! circle, ellipse, filled-arrow outline, or lemniscate).
//!
//! The recognizer is a pure function on `&[(f64, f64)]`. It does not
//! depend on `Element`, `Model`, or any UI state — `recognize_path` and
//! `recognized_to_element` are thin adapters for callers that work with
//! the document model.
//!
//! Design constraints:
//!   - Output shapes are axis-aligned. Rotated inputs return `None`.
//!   - Strict: if no candidate fits within tolerance, return `None`.
//!   - Accepts both raw pencil polylines and Bezier paths (via flatten).

use crate::geometry::element::{
    flatten_path_commands, CircleElem, CommonProps, Element, EllipseElem, Fill, LineElem,
    PathCommand, PathElem, PolygonElem, PolylineElem, RectElem, Stroke,
};

pub type Pt = (f64, f64);

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Tag-only classification of a recognized shape. Returned by
/// [`recognize_element`] alongside the replacement `Element`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ShapeKind {
    Line,
    Triangle,
    Rectangle,
    Square,
    RoundRect,
    Circle,
    Ellipse,
    Arrow,
    Lemniscate,
    Scribble,
}

#[derive(Debug, Clone, PartialEq)]
pub enum RecognizedShape {
    Line {
        a: Pt,
        b: Pt,
    },
    Triangle {
        pts: [Pt; 3],
    },
    /// Square is emitted as `Rectangle { w == h }` — no separate variant.
    Rectangle {
        x: f64,
        y: f64,
        w: f64,
        h: f64,
    },
    RoundRect {
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        r: f64,
    },
    Circle {
        cx: f64,
        cy: f64,
        r: f64,
    },
    Ellipse {
        cx: f64,
        cy: f64,
        rx: f64,
        ry: f64,
    },
    /// Outline of a filled arrow with axis-aligned shaft.
    Arrow {
        tail: Pt,
        tip: Pt,
        head_len: f64,
        head_half_width: f64,
        shaft_half_width: f64,
    },
    /// Bernoulli's lemniscate, axis-aligned.
    Lemniscate {
        center: Pt,
        a: f64,
        horizontal: bool,
    },
    /// Zigzag scribble: an open polyline of straight segments with at
    /// least a few back-and-forth direction reversals. Vertices are the
    /// RDP-simplified turning points.
    Scribble {
        points: Vec<Pt>,
    },
}

impl RecognizedShape {
    pub fn kind(&self) -> ShapeKind {
        match self {
            RecognizedShape::Line { .. } => ShapeKind::Line,
            RecognizedShape::Triangle { .. } => ShapeKind::Triangle,
            RecognizedShape::Rectangle { w, h, .. } => {
                if (w - h).abs() < 1e-9 {
                    ShapeKind::Square
                } else {
                    ShapeKind::Rectangle
                }
            }
            RecognizedShape::RoundRect { .. } => ShapeKind::RoundRect,
            RecognizedShape::Circle { .. } => ShapeKind::Circle,
            RecognizedShape::Ellipse { .. } => ShapeKind::Ellipse,
            RecognizedShape::Arrow { .. } => ShapeKind::Arrow,
            RecognizedShape::Lemniscate { .. } => ShapeKind::Lemniscate,
            RecognizedShape::Scribble { .. } => ShapeKind::Scribble,
        }
    }
}

#[derive(Debug, Clone)]
pub struct RecognizeConfig {
    /// Max mean fit residual (as fraction of bbox diagonal).
    pub tolerance: f64,
    /// Endpoint gap below this fraction of arc length → treat as closed.
    pub close_gap_frac: f64,
    /// Min turning angle (deg) at a single sample to count as a corner.
    pub corner_angle_deg: f64,
    /// `|w-h| / max(w,h)` below this → emit as a square (`w == h`).
    pub square_aspect_eps: f64,
    /// `min(rx,ry) / max(rx,ry)` above this → emit as a circle.
    pub circle_eccentricity_eps: f64,
    /// Number of samples to resample to before analysis.
    pub resample_n: usize,
}

impl Default for RecognizeConfig {
    fn default() -> Self {
        Self {
            tolerance: 0.05,
            close_gap_frac: 0.10,
            corner_angle_deg: 35.0,
            square_aspect_eps: 0.10,
            circle_eccentricity_eps: 0.92,
            resample_n: 64,
        }
    }
}

/// Closed-shape fits (rect, ellipse, triangle) are rejected when the bbox
/// aspect ratio falls below this. Without it, very thin inputs (a flat
/// triangle, a near-line) succeed as zero-residual rectangles because
/// almost every point sits on the thin bbox perimeter.
const MIN_CLOSED_BBOX_ASPECT: f64 = 0.10;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Recognize from a raw polyline.
pub fn recognize(points: &[Pt], cfg: &RecognizeConfig) -> Option<RecognizedShape> {
    if points.len() < 3 {
        return None;
    }
    let pts = resample(points, cfg.resample_n);
    let diag = bbox_diag_of(&pts);
    if diag < 1e-9 {
        return None;
    }
    let closed = is_closed(&pts, cfg.close_gap_frac);
    let tol_abs = cfg.tolerance * diag;

    let mut candidates: Vec<(f64, RecognizedShape)> = Vec::new();

    // Line is always a valid candidate (open or closed).
    if let Some((a, b, res)) = fit_line(&pts)
        && res <= tol_abs {
            candidates.push((res, RecognizedShape::Line { a, b }));
        }

    // Scribble (open paths only). A true zigzag has many direction
    // reversals, which random noise on a straight stroke does not.
    if !closed
        && let Some((segs, res)) = fit_scribble(&pts, diag)
            && res <= tol_abs {
                candidates.push((res, RecognizedShape::Scribble { points: segs }));
            }

    if closed {
        // Ellipse (axis-aligned, bbox-based). Snap to circle when nearly so.
        if let Some((cx, cy, rx, ry, res)) = fit_ellipse_aa(&pts)
            && res <= tol_abs {
                let ratio = rx.min(ry) / rx.max(ry);
                let shape = if ratio >= cfg.circle_eccentricity_eps {
                    let r = (rx + ry) / 2.0;
                    RecognizedShape::Circle { cx, cy, r }
                } else {
                    RecognizedShape::Ellipse { cx, cy, rx, ry }
                };
                candidates.push((res, shape));
            }

        // Rectangle (axis-aligned, bbox-based). Snap to square when nearly so.
        let rect_fit = fit_rect_aa(&pts);
        if let Some((x, y, w, h, res)) = rect_fit
            && res <= tol_abs {
                let aspect = (w - h).abs() / w.max(h);
                let (w, h) = if aspect <= cfg.square_aspect_eps {
                    let m = (w + h) / 2.0;
                    (m, m)
                } else {
                    (w, h)
                };
                candidates.push((res, RecognizedShape::Rectangle { x, y, w, h }));
            }

        // Round rectangle. Two guards prevent false positives:
        //   1. r/short ∈ (0.05, 0.45) — outside this band the plain rect or
        //      the ellipse handles the shape better.
        //   2. The round-rect residual must be substantially below the plain
        //      rect residual (< 0.5×). Otherwise we're just absorbing noise
        //      into a fictitious corner radius on a true rectangle.
        if let Some((x, y, w, h, r, res)) = fit_round_rect(&pts) {
            let short = w.min(h);
            let rect_rms = rect_fit.map(|f| f.4).unwrap_or(f64::INFINITY);
            if res <= tol_abs
                && r / short > 0.05
                && r / short < 0.45
                && res < 0.5 * rect_rms
            {
                candidates.push((res, RecognizedShape::RoundRect { x, y, w, h, r }));
            }
        }

        // Triangle.
        if let Some((verts, res)) = fit_triangle(&pts)
            && res <= tol_abs {
                candidates.push((res, RecognizedShape::Triangle { pts: verts }));
            }

        // Lemniscate. Only attempted when the path crosses itself, which
        // is the defining topological feature of the figure-8.
        if count_self_intersections(&pts) >= 1
            && let Some((cx, cy, a, horizontal, res)) = fit_lemniscate(&pts)
                && res <= tol_abs {
                    candidates.push((
                        res,
                        RecognizedShape::Lemniscate {
                            center: (cx, cy),
                            a,
                            horizontal,
                        },
                    ));
                }

        // Arrow outline (closed, 7-corner silhouette of a filled arrow).
        // Run on the un-resampled input so corner positions are preserved.
        if let Some((tail, tip, head_len, head_half_width, shaft_half_width, res)) =
            fit_arrow(points, diag)
            && res <= tol_abs {
                candidates.push((
                    res,
                    RecognizedShape::Arrow {
                        tail,
                        tip,
                        head_len,
                        head_half_width,
                        shaft_half_width,
                    },
                ));
            }
    }

    candidates.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    candidates.into_iter().next().map(|(_, s)| s)
}

/// Recognize from a path that may contain Beziers — flattens via
/// [`flatten_path_commands`] then calls [`recognize`].
pub fn recognize_path(d: &[PathCommand], cfg: &RecognizeConfig) -> Option<RecognizedShape> {
    let pts = flatten_path_commands(d);
    recognize(&pts, cfg)
}

/// Try to recognize an `Element` as a cleaner geometric shape, returning
/// the shape kind and replacement element if successful. Returns `None`
/// (do nothing) when:
///   - The element is already a clean primitive (Line, Rect, Circle,
///     Ellipse, Polygon, Text, TextPath, Group, Layer).
///   - The element cannot be interpreted as a drawable path (Text, Group, …).
///
/// Only `Path` and `Polyline` elements are candidates for recognition.
pub fn recognize_element(element: &Element, cfg: &RecognizeConfig) -> Option<(ShapeKind, Element)> {
    let pts: Vec<Pt> = match element {
        // Path (Beziers / freehand): flatten to polyline then recognize.
        Element::Path(p) => flatten_path_commands(&p.d),
        // Polyline (raw pencil stroke): use points directly.
        Element::Polyline(p) => p.points.clone(),
        // Everything else is already a clean shape or not path-like.
        Element::Line(_)
        | Element::Rect(_)
        | Element::Circle(_)
        | Element::Ellipse(_)
        | Element::Polygon(_)
        | Element::Text(_)
        | Element::TextPath(_)
        | Element::Group(_)
        | Element::Layer(_) => return None,
    };
    let shape = recognize(&pts, cfg)?;
    let kind = shape.kind();
    Some((kind, recognized_to_element(&shape, element)))
}

/// Extract `(fill, stroke, common)` from any element variant that has them.
/// Used by [`recognized_to_element`] to inherit the template's appearance.
fn template_appearance(e: &Element) -> (Option<Fill>, Option<Stroke>, CommonProps) {
    match e {
        Element::Line(l) => (None, l.stroke, l.common.clone()),
        Element::Rect(r) => (r.fill, r.stroke, r.common.clone()),
        Element::Circle(c) => (c.fill, c.stroke, c.common.clone()),
        Element::Ellipse(e) => (e.fill, e.stroke, e.common.clone()),
        Element::Polyline(p) => (p.fill, p.stroke, p.common.clone()),
        Element::Polygon(p) => (p.fill, p.stroke, p.common.clone()),
        Element::Path(p) => (p.fill, p.stroke, p.common.clone()),
        _ => (None, None, CommonProps::default()),
    }
}

/// Build a clean primitive `Element` from a recognized shape, inheriting
/// the template element's stroke, fill, and common props.
pub fn recognized_to_element(shape: &RecognizedShape, template: &Element) -> Element {
    let (fill, stroke, common) = template_appearance(template);
    match *shape {
        RecognizedShape::Line { a, b } => Element::Line(LineElem {
            x1: a.0,
            y1: a.1,
            x2: b.0,
            y2: b.1,
            stroke,
            width_points: vec![],
            common,
        }),
        RecognizedShape::Triangle { pts } => Element::Polygon(PolygonElem {
            points: pts.to_vec(),
            fill,
            stroke,
            common,
        }),
        RecognizedShape::Rectangle { x, y, w, h } => Element::Rect(RectElem {
            x,
            y,
            width: w,
            height: h,
            rx: 0.0,
            ry: 0.0,
            fill,
            stroke,
            common,
        }),
        RecognizedShape::RoundRect { x, y, w, h, r } => Element::Rect(RectElem {
            x,
            y,
            width: w,
            height: h,
            rx: r,
            ry: r,
            fill,
            stroke,
            common,
        }),
        RecognizedShape::Circle { cx, cy, r } => Element::Circle(CircleElem {
            cx,
            cy,
            r,
            fill,
            stroke,
            common,
        }),
        RecognizedShape::Ellipse { cx, cy, rx, ry } => Element::Ellipse(EllipseElem {
            cx,
            cy,
            rx,
            ry,
            fill,
            stroke,
            common,
        }),
        RecognizedShape::Arrow {
            tail,
            tip,
            head_len,
            head_half_width,
            shaft_half_width,
        } => {
            // Reconstruct the 7-corner outline. The shaft is axis-aligned;
            // pick perpendicular based on which axis is active.
            let dx = tip.0 - tail.0;
            let dy = tip.1 - tail.1;
            let len = (dx * dx + dy * dy).sqrt();
            let (ux, uy) = if len > 1e-9 { (dx / len, dy / len) } else { (1.0, 0.0) };
            let (px, py) = (-uy, ux); // perpendicular
            let shaft_end = (tip.0 - ux * head_len, tip.1 - uy * head_len);
            let p = |c: Pt, s: f64| (c.0 + px * s, c.1 + py * s);
            let points = vec![
                p(tail, -shaft_half_width),
                p(shaft_end, -shaft_half_width),
                p(shaft_end, -head_half_width),
                tip,
                p(shaft_end, head_half_width),
                p(shaft_end, shaft_half_width),
                p(tail, shaft_half_width),
            ];
            Element::Polygon(PolygonElem {
                points,
                fill,
                stroke,
                common,
            })
        }
        RecognizedShape::Scribble { ref points } => Element::Polyline(PolylineElem {
            points: points.clone(),
            fill: None,
            stroke,
            common,
        }),
        RecognizedShape::Lemniscate { center, a, horizontal } => {
            // Sample the Gerono parametrization densely as a closed
            // polyline emitted as a Path of MoveTo + LineTo commands.
            let n = 96;
            let mut d: Vec<PathCommand> = Vec::with_capacity(n + 2);
            for i in 0..=n {
                let t = 2.0 * std::f64::consts::PI * i as f64 / n as f64;
                let s = t.sin();
                let c = t.cos();
                let denom = 1.0 + s * s;
                let lx = a * c / denom;
                let ly = a * s * c / denom;
                let (x, y) = if horizontal {
                    (center.0 + lx, center.1 + ly)
                } else {
                    (center.0 + ly, center.1 + lx)
                };
                if i == 0 {
                    d.push(PathCommand::MoveTo { x, y });
                } else {
                    d.push(PathCommand::LineTo { x, y });
                }
            }
            d.push(PathCommand::ClosePath);
            Element::Path(PathElem {
                d,
                fill,
                stroke,
                width_points: vec![],
                common,
            })
        }
    }
}

// ---------------------------------------------------------------------------
// Geometric helpers
// ---------------------------------------------------------------------------

fn dist(a: Pt, b: Pt) -> f64 {
    ((a.0 - b.0).powi(2) + (a.1 - b.1).powi(2)).sqrt()
}

/// (xmin, ymin, xmax, ymax)
fn bbox_of(pts: &[Pt]) -> (f64, f64, f64, f64) {
    let mut xmin = f64::INFINITY;
    let mut ymin = f64::INFINITY;
    let mut xmax = f64::NEG_INFINITY;
    let mut ymax = f64::NEG_INFINITY;
    for &(x, y) in pts {
        if x < xmin { xmin = x; }
        if x > xmax { xmax = x; }
        if y < ymin { ymin = y; }
        if y > ymax { ymax = y; }
    }
    (xmin, ymin, xmax, ymax)
}

fn bbox_diag_of(pts: &[Pt]) -> f64 {
    let (xmin, ymin, xmax, ymax) = bbox_of(pts);
    ((xmax - xmin).powi(2) + (ymax - ymin).powi(2)).sqrt()
}

fn arc_length(pts: &[Pt]) -> f64 {
    pts.windows(2).map(|w| dist(w[0], w[1])).sum()
}

fn is_closed(pts: &[Pt], frac: f64) -> bool {
    if pts.len() < 2 {
        return false;
    }
    let total = arc_length(pts);
    if total < 1e-12 {
        return false;
    }
    let gap = dist(pts[0], *pts.last().unwrap());
    gap / total <= frac
}

/// Resample to `n` points uniformly along arc length.
fn resample(pts: &[Pt], n: usize) -> Vec<Pt> {
    if pts.len() < 2 || n < 2 {
        return pts.to_vec();
    }
    let mut cum = Vec::with_capacity(pts.len());
    cum.push(0.0);
    for i in 1..pts.len() {
        cum.push(cum[i - 1] + dist(pts[i - 1], pts[i]));
    }
    let total = *cum.last().unwrap();
    if total < 1e-12 {
        return pts.to_vec();
    }
    let step = total / (n - 1) as f64;
    let mut out = Vec::with_capacity(n);
    out.push(pts[0]);
    let mut idx = 1;
    for k in 1..(n - 1) {
        let target = step * k as f64;
        while idx < pts.len() - 1 && cum[idx] < target {
            idx += 1;
        }
        let seg_start = cum[idx - 1];
        let seg_len = cum[idx] - seg_start;
        let t = if seg_len > 1e-12 {
            ((target - seg_start) / seg_len).clamp(0.0, 1.0)
        } else {
            0.0
        };
        let x = pts[idx - 1].0 + t * (pts[idx].0 - pts[idx - 1].0);
        let y = pts[idx - 1].1 + t * (pts[idx].1 - pts[idx - 1].1);
        out.push((x, y));
    }
    out.push(*pts.last().unwrap());
    out
}

/// Distance from point `p` to line segment `(a, b)`.
fn point_to_segment_dist(p: Pt, a: Pt, b: Pt) -> f64 {
    let dx = b.0 - a.0;
    let dy = b.1 - a.1;
    let len2 = dx * dx + dy * dy;
    if len2 < 1e-12 {
        return dist(p, a);
    }
    let t = ((p.0 - a.0) * dx + (p.1 - a.1) * dy) / len2;
    let t = t.clamp(0.0, 1.0);
    let qx = a.0 + t * dx;
    let qy = a.1 + t * dy;
    ((p.0 - qx).powi(2) + (p.1 - qy).powi(2)).sqrt()
}

/// Perpendicular distance from `p` to the infinite line through `(a, b)`.
fn point_to_line_dist(p: Pt, a: Pt, b: Pt) -> f64 {
    let dx = b.0 - a.0;
    let dy = b.1 - a.1;
    let len = (dx * dx + dy * dy).sqrt();
    if len < 1e-12 {
        return dist(p, a);
    }
    ((p.0 - a.0) * dy - (p.1 - a.1) * dx).abs() / len
}

// ---------------------------------------------------------------------------
// Fits
// ---------------------------------------------------------------------------

/// Total least squares (PCA) line fit. Returns endpoints (projected min/max
/// along the principal direction) and mean orthogonal residual.
fn fit_line(pts: &[Pt]) -> Option<(Pt, Pt, f64)> {
    let n = pts.len() as f64;
    if pts.len() < 2 {
        return None;
    }
    let cx = pts.iter().map(|p| p.0).sum::<f64>() / n;
    let cy = pts.iter().map(|p| p.1).sum::<f64>() / n;
    let mut sxx = 0.0;
    let mut syy = 0.0;
    let mut sxy = 0.0;
    for &(x, y) in pts {
        sxx += (x - cx).powi(2);
        syy += (y - cy).powi(2);
        sxy += (x - cx) * (y - cy);
    }
    // Eigenvector of [[sxx, sxy],[sxy, syy]] with largest eigenvalue.
    let trace = sxx + syy;
    let det = sxx * syy - sxy * sxy;
    let disc = ((trace * trace / 4.0) - det).max(0.0).sqrt();
    let lambda1 = trace / 2.0 + disc;
    let (dx, dy) = if sxy.abs() > 1e-12 {
        (lambda1 - syy, sxy)
    } else if sxx >= syy {
        (1.0, 0.0)
    } else {
        (0.0, 1.0)
    };
    let len = (dx * dx + dy * dy).sqrt();
    if len < 1e-12 {
        return None;
    }
    let dx = dx / len;
    let dy = dy / len;
    let mut tmin = f64::INFINITY;
    let mut tmax = f64::NEG_INFINITY;
    let mut sq_sum = 0.0;
    for &(x, y) in pts {
        let t = (x - cx) * dx + (y - cy) * dy;
        if t < tmin { tmin = t; }
        if t > tmax { tmax = t; }
        let perp = (x - cx) * (-dy) + (y - cy) * dx;
        sq_sum += perp * perp;
    }
    let rms = (sq_sum / n).sqrt();
    let a = (cx + tmin * dx, cy + tmin * dy);
    let b = (cx + tmax * dx, cy + tmax * dy);
    Some((a, b, rms))
}

/// Axis-aligned ellipse fit via the bounding box. Center = bbox center;
/// `rx`, `ry` = bbox half-extents. Residual is mean approximate distance
/// to the ellipse perimeter.
fn fit_ellipse_aa(pts: &[Pt]) -> Option<(f64, f64, f64, f64, f64)> {
    let (xmin, ymin, xmax, ymax) = bbox_of(pts);
    let rx = (xmax - xmin) / 2.0;
    let ry = (ymax - ymin) / 2.0;
    if rx <= 1e-9 || ry <= 1e-9 {
        return None;
    }
    if rx.min(ry) / rx.max(ry) < MIN_CLOSED_BBOX_ASPECT {
        return None;
    }
    let cx = (xmin + xmax) / 2.0;
    let cy = (ymin + ymax) / 2.0;
    let scale = rx.min(ry);
    let mut sq_sum = 0.0;
    for &(x, y) in pts {
        let nx = (x - cx) / rx;
        let ny = (y - cy) / ry;
        let r = (nx * nx + ny * ny).sqrt();
        let d = (r - 1.0) * scale;
        sq_sum += d * d;
    }
    let rms = (sq_sum / pts.len() as f64).sqrt();
    Some((cx, cy, rx, ry, rms))
}

/// Axis-aligned rectangle fit via the bounding box. Residual is mean
/// distance from each point to the nearest of the four edges. For a true
/// rectangle the residual is ~0; for a tilted square the residual is large
/// because many points lie far inside the bbox.
fn fit_rect_aa(pts: &[Pt]) -> Option<(f64, f64, f64, f64, f64)> {
    let (xmin, ymin, xmax, ymax) = bbox_of(pts);
    let w = xmax - xmin;
    let h = ymax - ymin;
    if w <= 1e-9 || h <= 1e-9 {
        return None;
    }
    if w.min(h) / w.max(h) < MIN_CLOSED_BBOX_ASPECT {
        return None;
    }
    let mut sq_sum = 0.0;
    for &(x, y) in pts {
        let dx = (x - xmin).abs().min((x - xmax).abs());
        let dy = (y - ymin).abs().min((y - ymax).abs());
        let d = dx.min(dy);
        sq_sum += d * d;
    }
    let rms = (sq_sum / pts.len() as f64).sqrt();
    Some((xmin, ymin, w, h, rms))
}

/// Distance from `p` to the perimeter of an axis-aligned rounded rect
/// with origin `(x, y)`, dimensions `(w, h)`, and corner radius `r`.
fn dist_to_round_rect(p: Pt, x: f64, y: f64, w: f64, h: f64, r: f64) -> f64 {
    // Reflect into the top-left quadrant of the bbox so we only handle
    // one corner and one pair of straight edges.
    let px = p.0 - x;
    let py = p.1 - y;
    let qx = if px > w / 2.0 { w - px } else { px };
    let qy = if py > h / 2.0 { h - py } else { py };
    if qx >= r && qy >= r {
        // Far from any corner — closest is whichever straight side is nearer.
        qx.min(qy)
    } else if qx >= r {
        // qy < r: point is in the strip alongside the top straight edge.
        // The top edge runs from (r, 0) to (w-r, 0); since qx ∈ [r, w/2],
        // its perpendicular foot is on the edge. Distance is qy.
        qy
    } else if qy >= r {
        // Symmetric case: left edge runs from (0, r) to (0, h-r).
        qx
    } else {
        // Both qx < r and qy < r: corner sub-region. Closest is the arc.
        let dx = qx - r;
        let dy = qy - r;
        let d_to_center = (dx * dx + dy * dy).sqrt();
        (d_to_center - r).abs()
    }
}

/// RMS residual of `pts` against a rounded-rect outline.
fn round_rect_rms(pts: &[Pt], x: f64, y: f64, w: f64, h: f64, r: f64) -> f64 {
    let mut sq_sum = 0.0;
    for &p in pts {
        let d = dist_to_round_rect(p, x, y, w, h, r);
        sq_sum += d * d;
    }
    (sq_sum / pts.len() as f64).sqrt()
}

/// Round-rect fit. Bbox gives `x/y/w/h`; the optimal corner radius is
/// found by a coarse 1D scan followed by golden-section refinement on
/// the RMS residual.
fn fit_round_rect(pts: &[Pt]) -> Option<(f64, f64, f64, f64, f64, f64)> {
    let (xmin, ymin, xmax, ymax) = bbox_of(pts);
    let w = xmax - xmin;
    let h = ymax - ymin;
    if w <= 1e-9 || h <= 1e-9 {
        return None;
    }
    if w.min(h) / w.max(h) < MIN_CLOSED_BBOX_ASPECT {
        return None;
    }
    let r_max = w.min(h) / 2.0;
    let n_steps = 40;
    let mut best_r = 0.0;
    let mut best_rms = f64::INFINITY;
    for i in 0..=n_steps {
        let r = r_max * i as f64 / n_steps as f64;
        let rms = round_rect_rms(pts, xmin, ymin, w, h, r);
        if rms < best_rms {
            best_rms = rms;
            best_r = r;
        }
    }
    let step = r_max / n_steps as f64;
    let mut lo = (best_r - step).max(0.0);
    let mut hi = (best_r + step).min(r_max);
    for _ in 0..30 {
        let m1 = lo + (hi - lo) * 0.382;
        let m2 = lo + (hi - lo) * 0.618;
        let r1 = round_rect_rms(pts, xmin, ymin, w, h, m1);
        let r2 = round_rect_rms(pts, xmin, ymin, w, h, m2);
        if r1 < r2 {
            hi = m2;
        } else {
            lo = m1;
        }
    }
    let r = (lo + hi) / 2.0;
    let rms = round_rect_rms(pts, xmin, ymin, w, h, r);
    Some((xmin, ymin, w, h, r, rms))
}

/// Ramer–Douglas–Peucker polyline simplification. Returns the kept
/// vertices in order; always includes the first and last input points.
fn rdp(pts: &[Pt], epsilon: f64) -> Vec<Pt> {
    if pts.len() < 3 {
        return pts.to_vec();
    }
    let mut keep = vec![false; pts.len()];
    keep[0] = true;
    *keep.last_mut().unwrap() = true;
    rdp_recurse(pts, 0, pts.len() - 1, epsilon, &mut keep);
    pts.iter()
        .enumerate()
        .filter_map(|(i, p)| if keep[i] { Some(*p) } else { None })
        .collect()
}

fn rdp_recurse(pts: &[Pt], start: usize, end: usize, eps: f64, keep: &mut [bool]) {
    if end <= start + 1 {
        return;
    }
    let a = pts[start];
    let b = pts[end];
    let mut max_d = 0.0;
    let mut max_i = start;
    for i in (start + 1)..end {
        let d = point_to_segment_dist(pts[i], a, b);
        if d > max_d {
            max_d = d;
            max_i = i;
        }
    }
    if max_d > eps {
        keep[max_i] = true;
        rdp_recurse(pts, start, max_i, eps, keep);
        rdp_recurse(pts, max_i, end, eps, keep);
    }
}

/// Filled-arrow outline fit. Expects a closed 7-corner silhouette with
/// an axis-aligned shaft.
///
/// Returns `(tail, tip, head_len, head_half_width, shaft_half_width, rms)`.
fn fit_arrow(pts: &[Pt], diag: f64) -> Option<(Pt, Pt, f64, f64, f64, f64)> {
    if pts.len() < 7 {
        return None;
    }
    // Try a few RDP eps levels: a coarse pass tolerates noise, while finer
    // passes handle thin shafts where the bbox-diagonal scale is too loose.
    let mut corners: Vec<Pt> = Vec::new();
    for &frac in &[0.04, 0.02, 0.01, 0.005] {
        let eps = frac * diag;
        let mut s = rdp(pts, eps);
        if s.len() >= 2 && dist(s[0], *s.last().unwrap()) < eps.max(1e-6) {
            s.pop();
        }
        if s.len() == 7 {
            corners = s;
            break;
        }
    }
    let n = corners.len();
    if n != 7 {
        return None;
    }

    // Convexity sign at each corner: positive cross product = one orientation,
    // negative = the other. A 7-corner arrow outline has 5 corners of one sign
    // (the tip, the two head-back corners, and the two tail corners) and 2 of
    // the opposite sign (the shaft-junction corners where the head meets the
    // shaft, which are the concave indents).
    let cross_signs: Vec<f64> = (0..n)
        .map(|i| {
            let prev = corners[(i + n - 1) % n];
            let curr = corners[i];
            let next = corners[(i + 1) % n];
            let v1 = (prev.0 - curr.0, prev.1 - curr.1);
            let v2 = (next.0 - curr.0, next.1 - curr.1);
            v2.0 * v1.1 - v2.1 * v1.0
        })
        .collect();
    let positives = cross_signs.iter().filter(|&&s| s > 0.0).count();
    let negatives = n - positives;
    if positives.max(negatives) != 5 || positives.min(negatives) != 2 {
        return None;
    }
    let majority_positive = positives > negatives;

    // The tip is the unique majority-sign corner whose BOTH neighbors are
    // also majority sign. Every other majority-sign corner (the head-back
    // and tail corners) has at least one concave neighbor adjacent to a
    // shaft junction.
    let is_majority = |s: f64| (s > 0.0) == majority_positive;
    let mut tip_idx_opt = None;
    for i in 0..n {
        if is_majority(cross_signs[i])
            && is_majority(cross_signs[(i + n - 1) % n])
            && is_majority(cross_signs[(i + 1) % n])
        {
            if tip_idx_opt.is_some() {
                return None; // ambiguous: more than one such corner
            }
            tip_idx_opt = Some(i);
        }
    }
    let tip_idx = tip_idx_opt?;
    let tip = corners[tip_idx];

    // Index helper that walks the cyclic corner list relative to the tip.
    let c = |k: i32| -> Pt {
        let idx = ((tip_idx as i32 + k).rem_euclid(n as i32)) as usize;
        corners[idx]
    };

    // Pair corners symmetrically across the tip:
    //   ±1 = head-back corners (the wide part of the arrow head)
    //   ±2 = shaft-end corners (where head meets shaft)
    //   ±3 = tail corners (back of the shaft)
    let head_back_a = c(-1);
    let head_back_b = c(1);
    let shaft_end_a = c(-2);
    let shaft_end_b = c(2);
    let tail_a = c(-3);
    let tail_b = c(3);

    // Tail point = midpoint of the two tail corners (lies on symmetry axis).
    let tail = ((tail_a.0 + tail_b.0) / 2.0, (tail_a.1 + tail_b.1) / 2.0);

    // Verify the tip-tail axis is axis-aligned (≥ 0.95 cosine alignment).
    let dx = tip.0 - tail.0;
    let dy = tip.1 - tail.1;
    let len = (dx * dx + dy * dy).sqrt();
    if len < 1e-9 {
        return None;
    }
    let nx = (dx / len).abs();
    let ny = (dy / len).abs();
    if nx.max(ny) < 0.95 {
        return None;
    }

    // Dimensions.
    let shaft_half_width = dist(tail_a, tail_b) / 2.0;
    let head_half_width = dist(head_back_a, head_back_b) / 2.0;
    let shaft_end_mid = (
        (shaft_end_a.0 + shaft_end_b.0) / 2.0,
        (shaft_end_a.1 + shaft_end_b.1) / 2.0,
    );
    let head_len = dist(tip, shaft_end_mid);

    // Geometric sanity: head wider than shaft, head & shaft non-degenerate.
    if head_half_width <= shaft_half_width {
        return None;
    }
    if shaft_half_width < 1e-6 || head_len < 1e-6 {
        return None;
    }

    // Residual: mean distance from each input point to the recovered
    // arrow polygon perimeter.
    let arrow_corners = [
        tail_a, shaft_end_a, head_back_a, tip, head_back_b, shaft_end_b, tail_b,
    ];
    let edges: Vec<(Pt, Pt)> = (0..7)
        .map(|i| (arrow_corners[i], arrow_corners[(i + 1) % 7]))
        .collect();
    let mut sq_sum = 0.0;
    for &p in pts {
        let mut min_d = f64::INFINITY;
        for &(e0, e1) in &edges {
            let d = point_to_segment_dist(p, e0, e1);
            if d < min_d {
                min_d = d;
            }
        }
        sq_sum += min_d * min_d;
    }
    let rms = (sq_sum / pts.len() as f64).sqrt();

    Some((tail, tip, head_len, head_half_width, shaft_half_width, rms))
}

/// Count strict (non-collinear, non-endpoint) self-intersections of a
/// polyline. Adjacent segments — and the closure pair (last, first) for
/// closed paths — are skipped.
fn count_self_intersections(pts: &[Pt]) -> usize {
    fn ccw(a: Pt, b: Pt, c: Pt) -> f64 {
        (b.0 - a.0) * (c.1 - a.1) - (b.1 - a.1) * (c.0 - a.0)
    }
    fn segments_intersect(a1: Pt, a2: Pt, b1: Pt, b2: Pt) -> bool {
        let d1 = ccw(b1, b2, a1);
        let d2 = ccw(b1, b2, a2);
        let d3 = ccw(a1, a2, b1);
        let d4 = ccw(a1, a2, b2);
        d1 * d2 < 0.0 && d3 * d4 < 0.0
    }
    let n = pts.len();
    if n < 4 {
        return 0;
    }
    let n_segs = n - 1;
    let mut count = 0;
    for i in 0..n_segs {
        for j in (i + 2)..n_segs {
            // Skip the wraparound adjacency for closed paths.
            if i == 0 && j == n_segs - 1 {
                let close_gap = dist(pts[0], *pts.last().unwrap());
                if close_gap < 1e-6 {
                    continue;
                }
            }
            if segments_intersect(pts[i], pts[i + 1], pts[j], pts[j + 1]) {
                count += 1;
            }
        }
    }
    count
}

/// Lemniscate fit (Gerono parametrization, axis-aligned). Returns
/// `(cx, cy, a, horizontal, rms_residual)`.
///
/// Strategy: center = bbox center; orientation chosen so the long axis
/// of the bbox is the long axis of the figure-8; `a` = long half-extent.
/// An aspect sanity check (cross extent must be ≈ `a·√2/2`) rejects
/// inputs whose bbox doesn't look like a figure-8 at all. Residual is
/// computed against a dense parametric sample.
fn fit_lemniscate(pts: &[Pt]) -> Option<(f64, f64, f64, bool, f64)> {
    let (xmin, ymin, xmax, ymax) = bbox_of(pts);
    let w = xmax - xmin;
    let h = ymax - ymin;
    if w <= 1e-9 || h <= 1e-9 {
        return None;
    }
    let cx = (xmin + xmax) / 2.0;
    let cy = (ymin + ymax) / 2.0;
    let horizontal = w >= h;
    let a = if horizontal { w / 2.0 } else { h / 2.0 };
    let cross = if horizontal { h } else { w };
    let expected_cross = a * std::f64::consts::SQRT_2 / 2.0;
    if (cross / expected_cross - 1.0).abs() > 0.20 {
        return None;
    }

    // Dense parametric sample of the ideal lemniscate.
    let n_samples = 200;
    let mut samples = Vec::with_capacity(n_samples);
    for i in 0..n_samples {
        let t = 2.0 * std::f64::consts::PI * i as f64 / n_samples as f64;
        let s = t.sin();
        let c = t.cos();
        let denom = 1.0 + s * s;
        let lx = a * c / denom;
        let ly = a * s * c / denom;
        if horizontal {
            samples.push((cx + lx, cy + ly));
        } else {
            samples.push((cx + ly, cy + lx));
        }
    }

    let mut sq_sum = 0.0;
    for &p in pts {
        let mut min_d_sq = f64::INFINITY;
        for &s in &samples {
            let dx = p.0 - s.0;
            let dy = p.1 - s.1;
            let d2 = dx * dx + dy * dy;
            if d2 < min_d_sq {
                min_d_sq = d2;
            }
        }
        sq_sum += min_d_sq;
    }
    let rms = (sq_sum / pts.len() as f64).sqrt();
    Some((cx, cy, a, horizontal, rms))
}

/// Scribble (zigzag) fit. Uses RDP to simplify the path into straight
/// segments. A scribble must have:
///   1. at least 5 vertices (≥4 segments after simplification),
///   2. at least 2 turn-direction sign changes (back-and-forth),
///   3. path arc length substantially exceeds a straight-line span.
///
/// Returns `(simplified_vertices, rms_residual)`.
fn fit_scribble(pts: &[Pt], diag: f64) -> Option<(Vec<Pt>, f64)> {
    if pts.len() < 6 {
        return None;
    }
    // Path must meander: arc length at least 1.5× the bbox diagonal.
    let total_arc = arc_length(pts);
    if total_arc < 1.5 * diag {
        return None;
    }
    let eps = 0.05 * diag;
    let simplified = rdp(pts, eps);
    if simplified.len() < 5 {
        return None;
    }
    // Count turn-direction sign changes to verify zigzag pattern.
    let mut sign_changes = 0;
    let mut last_sign = 0.0f64;
    for i in 1..simplified.len() - 1 {
        let prev = simplified[i - 1];
        let curr = simplified[i];
        let next = simplified[i + 1];
        let v1 = (curr.0 - prev.0, curr.1 - prev.1);
        let v2 = (next.0 - curr.0, next.1 - curr.1);
        let cross = v1.0 * v2.1 - v1.1 * v2.0;
        if cross.abs() < 1e-9 {
            continue;
        }
        let sign = cross.signum();
        if last_sign != 0.0 && sign != last_sign {
            sign_changes += 1;
        }
        last_sign = sign;
    }
    if sign_changes < 2 {
        return None;
    }
    // Residual: RMS distance from each input point to the nearest
    // segment of the simplified polyline.
    let mut sq_sum = 0.0;
    for &p in pts {
        let mut min_d = f64::INFINITY;
        for w in simplified.windows(2) {
            let d = point_to_segment_dist(p, w[0], w[1]);
            if d < min_d {
                min_d = d;
            }
        }
        sq_sum += min_d * min_d;
    }
    let rms = (sq_sum / pts.len() as f64).sqrt();
    Some((simplified, rms))
}

/// Triangle fit by the "max-pair + farthest perpendicular" heuristic.
/// Rejects degenerate (flat) triangles so flat inputs fall through to Line.
fn fit_triangle(pts: &[Pt]) -> Option<([Pt; 3], f64)> {
    if pts.len() < 3 {
        return None;
    }
    // Find pair of input points with maximum distance.
    let mut max_d = 0.0;
    let mut ai = 0;
    let mut bi = 0;
    for i in 0..pts.len() {
        for j in (i + 1)..pts.len() {
            let d = dist(pts[i], pts[j]);
            if d > max_d {
                max_d = d;
                ai = i;
                bi = j;
            }
        }
    }
    if max_d < 1e-9 {
        return None;
    }
    let pa = pts[ai];
    let pb = pts[bi];
    // Find third vertex: input point with max perpendicular distance from line ab.
    let mut max_perp = 0.0;
    let mut ci = 0;
    for (i, &p) in pts.iter().enumerate() {
        if i == ai || i == bi {
            continue;
        }
        let d = point_to_line_dist(p, pa, pb);
        if d > max_perp {
            max_perp = d;
            ci = i;
        }
    }
    if max_perp < 1e-9 {
        return None;
    }
    // Reject very flat triangles — they should be classified as Line instead.
    if max_perp / max_d < 0.05 {
        return None;
    }
    let pc = pts[ci];
    let verts = [pa, pb, pc];
    let edges = [(pa, pb), (pb, pc), (pc, pa)];
    let mut sq_sum = 0.0;
    for &p in pts {
        let mut min_d = f64::INFINITY;
        for &(e0, e1) in &edges {
            let d = point_to_segment_dist(p, e0, e1);
            if d < min_d {
                min_d = d;
            }
        }
        sq_sum += min_d * min_d;
    }
    let rms = (sq_sum / pts.len() as f64).sqrt();
    Some((verts, rms))
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::f64::consts::PI;

    // -----------------------------------------------------------------------
    // Deterministic PRNG (seeded LCG, returns f64 in [-1, 1])
    // -----------------------------------------------------------------------

    fn lcg(seed: &mut u64) -> f64 {
        // Numerical Recipes constants
        *seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
        let v = (*seed >> 11) as f64 / (1u64 << 53) as f64; // [0,1)
        2.0 * v - 1.0
    }

    // -----------------------------------------------------------------------
    // Synthetic generators
    // -----------------------------------------------------------------------

    fn sample_line(a: Pt, b: Pt, n: usize) -> Vec<Pt> {
        assert!(n >= 2);
        (0..n)
            .map(|i| {
                let t = i as f64 / (n - 1) as f64;
                (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
            })
            .collect()
    }

    fn sample_triangle(a: Pt, b: Pt, c: Pt, n_per_side: usize) -> Vec<Pt> {
        let mut pts = Vec::new();
        for (p, q) in [(a, b), (b, c), (c, a)] {
            // Skip the last point of each side to avoid duplicates at corners
            // (the next side starts there).
            let side = sample_line(p, q, n_per_side);
            pts.extend_from_slice(&side[..side.len() - 1]);
        }
        // Close the loop by repeating the first vertex.
        pts.push(a);
        pts
    }

    fn sample_rect(x: f64, y: f64, w: f64, h: f64, n_per_side: usize) -> Vec<Pt> {
        sample_triangle((x, y), (x + w, y), (x + w, y + h), n_per_side); // type-check helper unused
        let p0 = (x, y);
        let p1 = (x + w, y);
        let p2 = (x + w, y + h);
        let p3 = (x, y + h);
        let mut pts = Vec::new();
        for (p, q) in [(p0, p1), (p1, p2), (p2, p3), (p3, p0)] {
            let side = sample_line(p, q, n_per_side);
            pts.extend_from_slice(&side[..side.len() - 1]);
        }
        pts.push(p0);
        pts
    }

    fn sample_round_rect(x: f64, y: f64, w: f64, h: f64, r: f64, n: usize) -> Vec<Pt> {
        // Walk the perimeter: 4 straight sides + 4 quarter-arcs.
        // n is approximate total point count.
        assert!(r * 2.0 < w && r * 2.0 < h);
        let arc_n = (n / 16).max(4);
        let side_n = (n / 8).max(4);
        let mut pts = Vec::new();

        // Helper: append an arc from start_angle to end_angle (radians) on
        // circle centered at (cx, cy) radius r, k samples (excluding final).
        let mut arc = |pts: &mut Vec<Pt>, cx: f64, cy: f64, a0: f64, a1: f64, k: usize| {
            for i in 0..k {
                let t = i as f64 / k as f64;
                let a = a0 + (a1 - a0) * t;
                pts.push((cx + r * a.cos(), cy + r * a.sin()));
            }
        };
        // Helper: straight side from (x0,y0) to (x1,y1), k samples (excluding final).
        let line = |pts: &mut Vec<Pt>, x0: f64, y0: f64, x1: f64, y1: f64, k: usize| {
            for i in 0..k {
                let t = i as f64 / k as f64;
                pts.push((x0 + (x1 - x0) * t, y0 + (y1 - y0) * t));
            }
        };

        // Start at top-left straight edge start (after top-left corner).
        // Top side: from (x+r, y) to (x+w-r, y)
        line(&mut pts, x + r, y, x + w - r, y, side_n);
        // Top-right corner: arc from -PI/2 to 0, center (x+w-r, y+r)
        arc(&mut pts, x + w - r, y + r, -PI / 2.0, 0.0, arc_n);
        // Right side: (x+w, y+r) to (x+w, y+h-r)
        line(&mut pts, x + w, y + r, x + w, y + h - r, side_n);
        // Bottom-right corner: arc from 0 to PI/2, center (x+w-r, y+h-r)
        arc(&mut pts, x + w - r, y + h - r, 0.0, PI / 2.0, arc_n);
        // Bottom side: (x+w-r, y+h) to (x+r, y+h)
        line(&mut pts, x + w - r, y + h, x + r, y + h, side_n);
        // Bottom-left corner: arc from PI/2 to PI, center (x+r, y+h-r)
        arc(&mut pts, x + r, y + h - r, PI / 2.0, PI, arc_n);
        // Left side: (x, y+h-r) to (x, y+r)
        line(&mut pts, x, y + h - r, x, y + r, side_n);
        // Top-left corner: arc from PI to 3PI/2, center (x+r, y+r)
        arc(&mut pts, x + r, y + r, PI, 3.0 * PI / 2.0, arc_n);
        // Close
        pts.push((x + r, y));
        pts
    }

    fn sample_circle(cx: f64, cy: f64, r: f64, n: usize) -> Vec<Pt> {
        (0..=n)
            .map(|i| {
                let a = 2.0 * PI * i as f64 / n as f64;
                (cx + r * a.cos(), cy + r * a.sin())
            })
            .collect()
    }

    fn sample_ellipse(cx: f64, cy: f64, rx: f64, ry: f64, n: usize) -> Vec<Pt> {
        (0..=n)
            .map(|i| {
                let a = 2.0 * PI * i as f64 / n as f64;
                (cx + rx * a.cos(), cy + ry * a.sin())
            })
            .collect()
    }

    /// Outline of a filled arrow with axis-aligned shaft pointing from
    /// `tail` to `tip`. Produces the classic 7-corner silhouette:
    /// shaft-bottom-left, shaft-bottom-right, head-bottom, tip,
    /// head-top, shaft-top-right, shaft-top-left, back to start.
    fn sample_arrow_outline(
        tail: Pt,
        tip: Pt,
        head_len: f64,
        head_half_w: f64,
        shaft_half_w: f64,
    ) -> Vec<Pt> {
        // Only horizontal or vertical shafts supported in the generator.
        let dx = tip.0 - tail.0;
        let dy = tip.1 - tail.1;
        assert!(dx.abs() < 1e-9 || dy.abs() < 1e-9, "shaft must be axis-aligned");

        let corners: [Pt; 7] = if dy.abs() < 1e-9 {
            // Horizontal arrow
            let dir = dx.signum();
            let shaft_end_x = tip.0 - dir * head_len;
            [
                (tail.0, tail.1 - shaft_half_w),
                (shaft_end_x, tail.1 - shaft_half_w),
                (shaft_end_x, tail.1 - head_half_w),
                (tip.0, tip.1),
                (shaft_end_x, tail.1 + head_half_w),
                (shaft_end_x, tail.1 + shaft_half_w),
                (tail.0, tail.1 + shaft_half_w),
            ]
        } else {
            // Vertical arrow
            let dir = dy.signum();
            let shaft_end_y = tip.1 - dir * head_len;
            [
                (tail.0 - shaft_half_w, tail.1),
                (tail.0 - shaft_half_w, shaft_end_y),
                (tail.0 - head_half_w, shaft_end_y),
                (tip.0, tip.1),
                (tail.0 + head_half_w, shaft_end_y),
                (tail.0 + shaft_half_w, shaft_end_y),
                (tail.0 + shaft_half_w, tail.1),
            ]
        };

        // Walk the corners with ~10 points per edge.
        let mut pts = Vec::new();
        for i in 0..corners.len() {
            let p = corners[i];
            let q = corners[(i + 1) % corners.len()];
            let side = sample_line(p, q, 10);
            pts.extend_from_slice(&side[..side.len() - 1]);
        }
        pts.push(corners[0]);
        pts
    }

    /// Bernoulli's lemniscate sampled in polar form: r² = a² · cos(2θ)
    /// (horizontal) or sin(2θ) variant (vertical).
    fn sample_lemniscate(cx: f64, cy: f64, a: f64, horizontal: bool, n: usize) -> Vec<Pt> {
        // Parametrize via t ∈ [0, 2π) using:
        //   x = a · cos(t) / (1 + sin²(t))
        //   y = a · sin(t) · cos(t) / (1 + sin²(t))
        // (Gerono lemniscate parametrization — produces the classic figure-8.)
        let mut pts = Vec::with_capacity(n + 1);
        for i in 0..=n {
            let t = 2.0 * PI * i as f64 / n as f64;
            let s = t.sin();
            let c = t.cos();
            let denom = 1.0 + s * s;
            let lx = a * c / denom;
            let ly = a * s * c / denom;
            if horizontal {
                pts.push((cx + lx, cy + ly));
            } else {
                pts.push((cx + ly, cy + lx));
            }
        }
        pts
    }

    fn jitter(pts: &[Pt], seed: u64, amplitude: f64) -> Vec<Pt> {
        let mut s = seed;
        pts.iter()
            .map(|&(x, y)| (x + amplitude * lcg(&mut s), y + amplitude * lcg(&mut s)))
            .collect()
    }

    /// Drop the last `frac` fraction of points to leave an open gap.
    fn open_gap(pts: &[Pt], frac: f64) -> Vec<Pt> {
        let n = pts.len();
        let keep = ((n as f64) * (1.0 - frac)) as usize;
        pts[..keep.max(2)].to_vec()
    }

    fn bbox_diag(pts: &[Pt]) -> f64 {
        let mut xmin = f64::INFINITY;
        let mut xmax = f64::NEG_INFINITY;
        let mut ymin = f64::INFINITY;
        let mut ymax = f64::NEG_INFINITY;
        for &(x, y) in pts {
            if x < xmin { xmin = x; }
            if x > xmax { xmax = x; }
            if y < ymin { ymin = y; }
            if y > ymax { ymax = y; }
        }
        ((xmax - xmin).powi(2) + (ymax - ymin).powi(2)).sqrt()
    }

    fn rotate_pts(pts: &[Pt], cx: f64, cy: f64, theta: f64) -> Vec<Pt> {
        let (s, c) = theta.sin_cos();
        pts.iter()
            .map(|&(x, y)| {
                let dx = x - cx;
                let dy = y - cy;
                (cx + dx * c - dy * s, cy + dx * s + dy * c)
            })
            .collect()
    }

    fn assert_close(a: f64, b: f64, tol: f64, name: &str) {
        assert!(
            (a - b).abs() <= tol,
            "{name}: expected {b}, got {a}, tol {tol}"
        );
    }

    // -----------------------------------------------------------------------
    // Sanity checks on the generators themselves
    // -----------------------------------------------------------------------

    #[test]
    fn generator_circle_has_expected_radius() {
        let pts = sample_circle(50.0, 50.0, 30.0, 64);
        for &(x, y) in &pts {
            let r = ((x - 50.0).powi(2) + (y - 50.0).powi(2)).sqrt();
            assert!((r - 30.0).abs() < 1e-9);
        }
    }

    #[test]
    fn generator_round_rect_runs_without_panic() {
        let pts = sample_round_rect(0.0, 0.0, 100.0, 60.0, 10.0, 200);
        assert!(pts.len() > 50);
    }

    #[test]
    fn generator_lemniscate_passes_through_origin_offset() {
        // The Gerono parametrization at t=0 gives (a, 0) relative to center.
        let pts = sample_lemniscate(100.0, 100.0, 40.0, true, 64);
        let p0 = pts[0];
        assert!((p0.0 - 140.0).abs() < 1e-9);
        assert!((p0.1 - 100.0).abs() < 1e-9);
    }

    #[test]
    fn jitter_is_deterministic() {
        let pts = sample_circle(0.0, 0.0, 10.0, 32);
        let a = jitter(&pts, 42, 0.5);
        let b = jitter(&pts, 42, 0.5);
        assert_eq!(a, b);
    }

    // -----------------------------------------------------------------------
    // Step 2: positive ID, clean inputs
    // -----------------------------------------------------------------------

    #[test]
    fn recognize_clean_line() {
        let pts = sample_line((10.0, 20.0), (110.0, 20.0), 32);
        let cfg = RecognizeConfig::default();
        match recognize(&pts, &cfg) {
            Some(RecognizedShape::Line { a, b }) => {
                let diag = bbox_diag(&pts);
                let tol = 0.02 * diag;
                assert_close(a.0.min(b.0), 10.0, tol, "x_min");
                assert_close(a.0.max(b.0), 110.0, tol, "x_max");
                assert_close(a.1, 20.0, tol, "y");
                assert_close(b.1, 20.0, tol, "y");
            }
            other => panic!("expected Line, got {other:?}"),
        }
    }

    #[test]
    fn recognize_clean_triangle() {
        let pts = sample_triangle((0.0, 0.0), (100.0, 0.0), (50.0, 86.6), 20);
        let cfg = RecognizeConfig::default();
        match recognize(&pts, &cfg) {
            Some(RecognizedShape::Triangle { .. }) => {}
            other => panic!("expected Triangle, got {other:?}"),
        }
    }

    #[test]
    fn recognize_clean_rectangle() {
        let pts = sample_rect(10.0, 20.0, 100.0, 60.0, 16);
        let cfg = RecognizeConfig::default();
        match recognize(&pts, &cfg) {
            Some(RecognizedShape::Rectangle { x, y, w, h }) => {
                let tol = 0.02 * bbox_diag(&pts);
                assert_close(x, 10.0, tol, "x");
                assert_close(y, 20.0, tol, "y");
                assert_close(w, 100.0, tol, "w");
                assert_close(h, 60.0, tol, "h");
            }
            other => panic!("expected Rectangle, got {other:?}"),
        }
    }

    #[test]
    fn recognize_clean_square_emits_rectangle_with_equal_sides() {
        let pts = sample_rect(0.0, 0.0, 80.0, 80.0, 16);
        let cfg = RecognizeConfig::default();
        match recognize(&pts, &cfg) {
            Some(RecognizedShape::Rectangle { w, h, .. }) => {
                assert!((w - h).abs() < 1e-6, "square should have w == h, got {w} vs {h}");
            }
            other => panic!("expected Rectangle, got {other:?}"),
        }
    }

    #[test]
    fn recognize_clean_round_rect() {
        let pts = sample_round_rect(0.0, 0.0, 120.0, 80.0, 15.0, 256);
        let cfg = RecognizeConfig::default();
        match recognize(&pts, &cfg) {
            Some(RecognizedShape::RoundRect { x, y, w, h, r }) => {
                let tol = 0.04 * bbox_diag(&pts);
                assert_close(x, 0.0, tol, "x");
                assert_close(y, 0.0, tol, "y");
                assert_close(w, 120.0, tol, "w");
                assert_close(h, 80.0, tol, "h");
                assert_close(r, 15.0, tol, "r");
            }
            other => panic!("expected RoundRect, got {other:?}"),
        }
    }

    #[test]
    fn recognize_clean_circle() {
        let pts = sample_circle(50.0, 50.0, 30.0, 64);
        let cfg = RecognizeConfig::default();
        match recognize(&pts, &cfg) {
            Some(RecognizedShape::Circle { cx, cy, r }) => {
                let tol = 0.02 * bbox_diag(&pts);
                assert_close(cx, 50.0, tol, "cx");
                assert_close(cy, 50.0, tol, "cy");
                assert_close(r, 30.0, tol, "r");
            }
            other => panic!("expected Circle, got {other:?}"),
        }
    }

    #[test]
    fn recognize_clean_ellipse() {
        let pts = sample_ellipse(50.0, 50.0, 60.0, 30.0, 64);
        let cfg = RecognizeConfig::default();
        match recognize(&pts, &cfg) {
            Some(RecognizedShape::Ellipse { cx, cy, rx, ry }) => {
                let tol = 0.02 * bbox_diag(&pts);
                assert_close(cx, 50.0, tol, "cx");
                assert_close(cy, 50.0, tol, "cy");
                assert_close(rx, 60.0, tol, "rx");
                assert_close(ry, 30.0, tol, "ry");
            }
            other => panic!("expected Ellipse, got {other:?}"),
        }
    }

    #[test]
    fn recognize_clean_arrow_outline() {
        let pts = sample_arrow_outline((0.0, 50.0), (100.0, 50.0), 25.0, 20.0, 8.0);
        let cfg = RecognizeConfig::default();
        match recognize(&pts, &cfg) {
            Some(RecognizedShape::Arrow { tail, tip, head_len, head_half_width, shaft_half_width }) => {
                let tol = 0.05 * bbox_diag(&pts);
                assert_close(tail.0, 0.0, tol, "tail.x");
                assert_close(tip.0, 100.0, tol, "tip.x");
                assert_close(head_len, 25.0, tol, "head_len");
                assert_close(head_half_width, 20.0, tol, "head_hw");
                assert_close(shaft_half_width, 8.0, tol, "shaft_hw");
            }
            other => panic!("expected Arrow, got {other:?}"),
        }
    }

    #[test]
    fn recognize_clean_lemniscate_horizontal() {
        let pts = sample_lemniscate(100.0, 100.0, 50.0, true, 128);
        let cfg = RecognizeConfig::default();
        match recognize(&pts, &cfg) {
            Some(RecognizedShape::Lemniscate { center, a, horizontal }) => {
                let tol = 0.05 * bbox_diag(&pts);
                assert_close(center.0, 100.0, tol, "cx");
                assert_close(center.1, 100.0, tol, "cy");
                assert_close(a, 50.0, tol, "a");
                assert!(horizontal);
            }
            other => panic!("expected Lemniscate, got {other:?}"),
        }
    }

    #[test]
    fn recognize_clean_lemniscate_vertical() {
        let pts = sample_lemniscate(0.0, 0.0, 30.0, false, 128);
        let cfg = RecognizeConfig::default();
        match recognize(&pts, &cfg) {
            Some(RecognizedShape::Lemniscate { horizontal, .. }) => {
                assert!(!horizontal);
            }
            other => panic!("expected Lemniscate, got {other:?}"),
        }
    }

    // -----------------------------------------------------------------------
    // Step 3: noisy positive ID
    // -----------------------------------------------------------------------

    #[test]
    fn recognize_noisy_circle() {
        let clean = sample_circle(50.0, 50.0, 30.0, 64);
        let amp = 0.03 * bbox_diag(&clean);
        let pts = jitter(&clean, 1, amp);
        let cfg = RecognizeConfig::default();
        match recognize(&pts, &cfg) {
            Some(RecognizedShape::Circle { cx, cy, r }) => {
                let tol = 0.05 * bbox_diag(&clean);
                assert_close(cx, 50.0, tol, "cx");
                assert_close(cy, 50.0, tol, "cy");
                assert_close(r, 30.0, tol, "r");
            }
            other => panic!("expected Circle, got {other:?}"),
        }
    }

    #[test]
    fn recognize_noisy_rectangle() {
        let clean = sample_rect(0.0, 0.0, 100.0, 60.0, 16);
        let pts = jitter(&clean, 2, 0.03 * bbox_diag(&clean));
        let cfg = RecognizeConfig::default();
        assert!(matches!(recognize(&pts, &cfg), Some(RecognizedShape::Rectangle { .. })));
    }

    #[test]
    fn recognize_noisy_ellipse() {
        let clean = sample_ellipse(0.0, 0.0, 60.0, 30.0, 64);
        let pts = jitter(&clean, 3, 0.03 * bbox_diag(&clean));
        let cfg = RecognizeConfig::default();
        assert!(matches!(recognize(&pts, &cfg), Some(RecognizedShape::Ellipse { .. })));
    }

    #[test]
    fn recognize_noisy_triangle() {
        let clean = sample_triangle((0.0, 0.0), (100.0, 0.0), (50.0, 86.6), 20);
        let pts = jitter(&clean, 4, 0.03 * bbox_diag(&clean));
        let cfg = RecognizeConfig::default();
        assert!(matches!(recognize(&pts, &cfg), Some(RecognizedShape::Triangle { .. })));
    }

    // -----------------------------------------------------------------------
    // Step 4: closed/open dispatch
    // -----------------------------------------------------------------------

    #[test]
    fn nearly_closed_polyline_treated_as_closed() {
        let clean = sample_rect(0.0, 0.0, 100.0, 60.0, 16);
        let pts = open_gap(&clean, 0.05);
        let cfg = RecognizeConfig::default();
        assert!(matches!(recognize(&pts, &cfg), Some(RecognizedShape::Rectangle { .. })));
    }

    #[test]
    fn clearly_open_polyline_not_rectangle() {
        let clean = sample_rect(0.0, 0.0, 100.0, 60.0, 16);
        let pts = open_gap(&clean, 0.25);
        let cfg = RecognizeConfig::default();
        match recognize(&pts, &cfg) {
            Some(RecognizedShape::Rectangle { .. }) => {
                panic!("clearly open path should not classify as Rectangle");
            }
            _ => {}
        }
    }

    #[test]
    fn recognize_path_via_bezier_input() {
        // A square traced as Beziers — flatten + recognize should still find it.
        let d = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 100.0, y: 0.0 },
            PathCommand::LineTo { x: 100.0, y: 100.0 },
            PathCommand::LineTo { x: 0.0, y: 100.0 },
            PathCommand::ClosePath,
        ];
        let cfg = RecognizeConfig::default();
        assert!(matches!(recognize_path(&d, &cfg), Some(RecognizedShape::Rectangle { .. })));
    }

    // -----------------------------------------------------------------------
    // Step 5: disambiguation edge cases
    // -----------------------------------------------------------------------

    #[test]
    fn square_with_aspect_1_04_is_square() {
        // w/h = 1.04 → within square_aspect_eps (0.10) → emit equal sides.
        let pts = sample_rect(0.0, 0.0, 104.0, 100.0, 16);
        let cfg = RecognizeConfig::default();
        match recognize(&pts, &cfg) {
            Some(RecognizedShape::Rectangle { w, h, .. }) => {
                assert!((w - h).abs() < 1e-6, "near-square should snap to w == h, got {w} vs {h}");
            }
            other => panic!("expected Rectangle, got {other:?}"),
        }
    }

    #[test]
    fn rect_with_aspect_1_15_is_not_square() {
        let pts = sample_rect(0.0, 0.0, 115.0, 100.0, 16);
        let cfg = RecognizeConfig::default();
        match recognize(&pts, &cfg) {
            Some(RecognizedShape::Rectangle { w, h, .. }) => {
                assert!((w - h).abs() > 1.0, "1.15 aspect should NOT snap to square");
            }
            other => panic!("expected Rectangle, got {other:?}"),
        }
    }

    #[test]
    fn nearly_circular_ellipse_is_circle() {
        // rx/ry = 30/29.5 → ratio 0.983 > 0.92 → Circle.
        let pts = sample_ellipse(0.0, 0.0, 30.0, 29.5, 64);
        let cfg = RecognizeConfig::default();
        assert!(matches!(recognize(&pts, &cfg), Some(RecognizedShape::Circle { .. })));
    }

    #[test]
    fn clearly_elliptical_is_ellipse() {
        // rx/ry = 30/15 → ratio 0.5 < 0.92 → Ellipse.
        let pts = sample_ellipse(0.0, 0.0, 30.0, 15.0, 64);
        let cfg = RecognizeConfig::default();
        assert!(matches!(recognize(&pts, &cfg), Some(RecognizedShape::Ellipse { .. })));
    }

    #[test]
    fn tiny_corner_radius_is_plain_rect() {
        let pts = sample_round_rect(0.0, 0.0, 100.0, 60.0, 1.0, 256);
        let cfg = RecognizeConfig::default();
        assert!(matches!(recognize(&pts, &cfg), Some(RecognizedShape::Rectangle { .. })));
    }

    #[test]
    fn flat_triangle_is_line() {
        // A "triangle" with one vertex barely off the baseline → essentially a line.
        let pts = sample_triangle((0.0, 0.0), (100.0, 0.0), (50.0, 0.5), 20);
        let cfg = RecognizeConfig::default();
        assert!(matches!(recognize(&pts, &cfg), Some(RecognizedShape::Line { .. })));
    }

    #[test]
    fn random_scribble_returns_none() {
        // 64 random points in a 100x100 box — nothing should fit.
        let mut s = 99u64;
        let pts: Vec<Pt> = (0..64)
            .map(|_| (50.0 + 50.0 * lcg(&mut s), 50.0 + 50.0 * lcg(&mut s)))
            .collect();
        let cfg = RecognizeConfig::default();
        assert!(recognize(&pts, &cfg).is_none());
    }

    #[test]
    fn nearly_straight_arrow_outline_still_recognized() {
        // Long thin arrow — the head still has to win over Line/Rectangle.
        let pts = sample_arrow_outline((0.0, 50.0), (200.0, 50.0), 20.0, 15.0, 4.0);
        let cfg = RecognizeConfig::default();
        assert!(matches!(recognize(&pts, &cfg), Some(RecognizedShape::Arrow { .. })));
    }

    #[test]
    fn tilted_square_returns_none() {
        // Rotated 30° → no axis-aligned fit → None (per the no-rotation rule).
        let clean = sample_rect(-50.0, -50.0, 100.0, 100.0, 16);
        let pts = rotate_pts(&clean, 0.0, 0.0, 30f64.to_radians());
        let cfg = RecognizeConfig::default();
        match recognize(&pts, &cfg) {
            None => {}
            Some(RecognizedShape::Rectangle { .. }) => {
                // Acceptable IF the bounding box happens to look like a rectangle
                // and the residual stays within tolerance — but typically not.
                // We pin "None" here as the locked behavior.
                panic!("tilted square should NOT classify as axis-aligned Rectangle");
            }
            other => panic!("expected None, got {other:?}"),
        }
    }

    #[test]
    fn lemniscate_off_center_crossing_returns_none() {
        // Take a clean lemniscate and translate one lobe to break symmetry.
        let pts = sample_lemniscate(0.0, 0.0, 50.0, true, 128);
        let skewed: Vec<Pt> = pts
            .iter()
            .map(|&(x, y)| if x > 0.0 { (x + 30.0, y) } else { (x, y) })
            .collect();
        let cfg = RecognizeConfig::default();
        let got = recognize(&skewed, &cfg);
        assert!(got.is_none(), "expected None, got {got:?}");
    }

    #[test]
    fn recognized_to_element_preserves_stroke_and_common() {
        use crate::geometry::element::{Color, CommonProps, PathElem, Stroke, Visibility};
        let template = Element::Path(PathElem {
            d: vec![],
            fill: None,
            stroke: Some(Stroke::new(Color::BLACK, 2.5)),
            width_points: Vec::new(),
            common: CommonProps {
                opacity: 0.7,
                transform: None,
                locked: false,
                visibility: Visibility::Preview,
            },
        });
        let shape = RecognizedShape::Rectangle {
            x: 10.0,
            y: 20.0,
            w: 30.0,
            h: 40.0,
        };
        match recognized_to_element(&shape, &template) {
            Element::Rect(r) => {
                assert_eq!(r.x, 10.0);
                assert_eq!(r.width, 30.0);
                assert_eq!(r.height, 40.0);
                assert_eq!(r.rx, 0.0);
                let s = r.stroke.expect("stroke inherited");
                assert!((s.width - 2.5).abs() < 1e-9);
                assert!((r.common.opacity - 0.7).abs() < 1e-9);
            }
            other => panic!("expected Rect, got {other:?}"),
        }
    }

    #[test]
    fn recognized_to_element_round_rect_sets_rx_ry() {
        let template = Element::Path(PathElem {
            d: vec![],
            fill: None,
            stroke: None,
            width_points: Vec::new(),
            common: CommonProps::default(),
        });
        let shape = RecognizedShape::RoundRect {
            x: 0.0,
            y: 0.0,
            w: 100.0,
            h: 60.0,
            r: 12.0,
        };
        match recognized_to_element(&shape, &template) {
            Element::Rect(r) => {
                assert_eq!(r.rx, 12.0);
                assert_eq!(r.ry, 12.0);
            }
            other => panic!("expected Rect, got {other:?}"),
        }
    }

    #[test]
    fn recognized_to_element_arrow_emits_polygon() {
        let template = Element::Path(PathElem {
            d: vec![],
            fill: None,
            stroke: None,
            width_points: Vec::new(),
            common: CommonProps::default(),
        });
        let shape = RecognizedShape::Arrow {
            tail: (0.0, 0.0),
            tip: (100.0, 0.0),
            head_len: 25.0,
            head_half_width: 20.0,
            shaft_half_width: 8.0,
        };
        match recognized_to_element(&shape, &template) {
            Element::Polygon(p) => {
                assert_eq!(p.points.len(), 7);
                // Tip is the 4th corner.
                assert!((p.points[3].0 - 100.0).abs() < 1e-9);
                assert!((p.points[3].1 - 0.0).abs() < 1e-9);
            }
            other => panic!("expected Polygon, got {other:?}"),
        }
    }

    // -----------------------------------------------------------------------
    // Scribble (zigzag) tests
    // -----------------------------------------------------------------------

    /// Generate a horizontal zigzag: alternating up/down strokes along x.
    fn sample_zigzag(
        x_start: f64,
        y_center: f64,
        x_step: f64,
        y_amplitude: f64,
        n_zags: usize,
        pts_per_seg: usize,
    ) -> Vec<Pt> {
        let mut vertices = Vec::with_capacity(n_zags + 1);
        for i in 0..=n_zags {
            let x = x_start + x_step * i as f64;
            let y = if i % 2 == 0 {
                y_center - y_amplitude
            } else {
                y_center + y_amplitude
            };
            vertices.push((x, y));
        }
        // Densely sample between vertices.
        let mut pts = Vec::new();
        for w in vertices.windows(2) {
            let seg = sample_line(w[0], w[1], pts_per_seg);
            pts.extend_from_slice(&seg[..seg.len() - 1]);
        }
        pts.push(*vertices.last().unwrap());
        pts
    }

    #[test]
    fn recognize_clean_zigzag_scribble() {
        // 8 zags, clear zigzag pattern.
        let pts = sample_zigzag(0.0, 50.0, 20.0, 30.0, 8, 10);
        let cfg = RecognizeConfig::default();
        match recognize(&pts, &cfg) {
            Some(RecognizedShape::Scribble { points }) => {
                // Simplified polyline should have roughly n_zags+1 vertices.
                assert!(points.len() >= 5, "expected ≥5 vertices, got {}", points.len());
            }
            other => panic!("expected Scribble, got {other:?}"),
        }
    }

    #[test]
    fn recognize_noisy_zigzag_scribble() {
        let clean = sample_zigzag(0.0, 50.0, 15.0, 25.0, 10, 10);
        let pts = jitter(&clean, 7, 0.02 * bbox_diag(&clean));
        let cfg = RecognizeConfig::default();
        assert!(matches!(recognize(&pts, &cfg), Some(RecognizedShape::Scribble { .. })));
    }

    #[test]
    fn straight_line_not_scribble() {
        let pts = sample_line((0.0, 0.0), (200.0, 0.0), 64);
        let cfg = RecognizeConfig::default();
        match recognize(&pts, &cfg) {
            Some(RecognizedShape::Scribble { .. }) => {
                panic!("straight line should not be classified as Scribble");
            }
            Some(RecognizedShape::Line { .. }) => {}
            other => panic!("expected Line, got {other:?}"),
        }
    }

    #[test]
    fn diagonal_line_not_scribble() {
        let pts = sample_line((0.0, 0.0), (100.0, 80.0), 64);
        let cfg = RecognizeConfig::default();
        assert!(matches!(recognize(&pts, &cfg), Some(RecognizedShape::Line { .. })));
    }

    #[test]
    fn recognized_to_element_scribble_emits_polyline() {
        let template = Element::Path(PathElem {
            d: vec![],
            fill: None,
            stroke: None,
            width_points: Vec::new(),
            common: CommonProps::default(),
        });
        let shape = RecognizedShape::Scribble {
            points: vec![(0.0, 0.0), (10.0, 20.0), (20.0, 0.0), (30.0, 20.0), (40.0, 0.0)],
        };
        match recognized_to_element(&shape, &template) {
            Element::Polyline(p) => {
                assert_eq!(p.points.len(), 5);
            }
            other => panic!("expected Polyline, got {other:?}"),
        }
    }

    // -----------------------------------------------------------------------
    // recognize_element: skip already-clean shapes
    // -----------------------------------------------------------------------

    #[test]
    fn recognize_element_skips_line() {
        let elem = Element::Line(LineElem {
            x1: 0.0, y1: 0.0, x2: 100.0, y2: 0.0,
            stroke: None, width_points: Vec::new(), common: CommonProps::default(),
        });
        assert!(recognize_element(&elem, &RecognizeConfig::default()).is_none());
    }

    #[test]
    fn recognize_element_skips_rect() {
        let elem = Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 100.0, height: 60.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, common: CommonProps::default(),
        });
        assert!(recognize_element(&elem, &RecognizeConfig::default()).is_none());
    }

    #[test]
    fn recognize_element_skips_circle() {
        let elem = Element::Circle(CircleElem {
            cx: 50.0, cy: 50.0, r: 30.0,
            fill: None, stroke: None, common: CommonProps::default(),
        });
        assert!(recognize_element(&elem, &RecognizeConfig::default()).is_none());
    }

    #[test]
    fn recognize_element_skips_polygon() {
        let elem = Element::Polygon(PolygonElem {
            points: vec![(0.0, 0.0), (100.0, 0.0), (50.0, 86.6)],
            fill: None, stroke: None, common: CommonProps::default(),
        });
        assert!(recognize_element(&elem, &RecognizeConfig::default()).is_none());
    }

    #[test]
    fn recognize_element_converts_path_circle() {
        // A circle drawn as a Path should be recognized.
        let pts = sample_circle(50.0, 50.0, 30.0, 64);
        let d: Vec<PathCommand> = pts.iter().enumerate().map(|(i, &(x, y))| {
            if i == 0 { PathCommand::MoveTo { x, y } }
            else { PathCommand::LineTo { x, y } }
        }).collect();
        let elem = Element::Path(PathElem {
            d, fill: None, stroke: None, width_points: Vec::new(), common: CommonProps::default(),
        });
        match recognize_element(&elem, &RecognizeConfig::default()) {
            Some((kind, Element::Circle(_))) => {
                assert_eq!(kind, ShapeKind::Circle);
            }
            other => panic!("expected (Circle, Circle), got {other:?}"),
        }
    }

    #[test]
    fn recognize_element_square_returns_square_kind() {
        let pts = sample_rect(0.0, 0.0, 80.0, 80.0, 16);
        let d: Vec<PathCommand> = pts.iter().enumerate().map(|(i, &(x, y))| {
            if i == 0 { PathCommand::MoveTo { x, y } }
            else { PathCommand::LineTo { x, y } }
        }).collect();
        let elem = Element::Path(PathElem {
            d, fill: None, stroke: None, width_points: Vec::new(), common: CommonProps::default(),
        });
        match recognize_element(&elem, &RecognizeConfig::default()) {
            Some((kind, Element::Rect(_))) => {
                assert_eq!(kind, ShapeKind::Square);
            }
            other => panic!("expected (Square, Rect), got {other:?}"),
        }
    }
}
