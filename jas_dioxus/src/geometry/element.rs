//! Immutable document elements conforming to SVG element types.
//!
//! All elements are immutable value objects. To modify an element, create a new
//! one with the desired changes. Element types and attributes follow the SVG 1.1
//! specification.

use std::rc::Rc;

/// Line segments per Bezier curve when flattening paths.
pub const FLATTEN_STEPS: usize = 20;

/// Average character width as a fraction of font size.
pub const APPROX_CHAR_WIDTH_FACTOR: f64 = 0.6;

// ---------------------------------------------------------------------------
// SVG presentation attributes
// ---------------------------------------------------------------------------

/// RGBA color with components in [0, 1].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Color {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub a: f64,
}

impl Color {
    pub const fn new(r: f64, g: f64, b: f64, a: f64) -> Self {
        Self { r, g, b, a }
    }

    pub const fn rgb(r: f64, g: f64, b: f64) -> Self {
        Self { r, g, b, a: 1.0 }
    }

    pub const BLACK: Self = Self::rgb(0.0, 0.0, 0.0);
    pub const WHITE: Self = Self::rgb(1.0, 1.0, 1.0);
}

impl Default for Color {
    fn default() -> Self {
        Self::BLACK
    }
}

/// SVG stroke-linecap.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum LineCap {
    #[default]
    Butt,
    Round,
    Square,
}

/// SVG stroke-linejoin.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum LineJoin {
    #[default]
    Miter,
    Round,
    Bevel,
}

/// SVG fill presentation attribute.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Fill {
    pub color: Color,
}

impl Fill {
    pub const fn new(color: Color) -> Self {
        Self { color }
    }
}

/// SVG stroke presentation attributes.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Stroke {
    pub color: Color,
    pub width: f64,
    pub linecap: LineCap,
    pub linejoin: LineJoin,
}

impl Stroke {
    pub fn new(color: Color, width: f64) -> Self {
        Self {
            color,
            width,
            linecap: LineCap::Butt,
            linejoin: LineJoin::Miter,
        }
    }
}

/// SVG transform as a 2D affine matrix [a b c d e f].
///
/// Represents the matrix:
///     | a c e |
///     | b d f |
///     | 0 0 1 |
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Transform {
    pub a: f64,
    pub b: f64,
    pub c: f64,
    pub d: f64,
    pub e: f64,
    pub f: f64,
}

impl Default for Transform {
    fn default() -> Self {
        Self::IDENTITY
    }
}

impl Transform {
    pub const IDENTITY: Self = Self {
        a: 1.0,
        b: 0.0,
        c: 0.0,
        d: 1.0,
        e: 0.0,
        f: 0.0,
    };

    pub fn translate(tx: f64, ty: f64) -> Self {
        Self {
            e: tx,
            f: ty,
            ..Self::IDENTITY
        }
    }

    pub fn scale(sx: f64, sy: f64) -> Self {
        Self {
            a: sx,
            d: sy,
            ..Self::IDENTITY
        }
    }

    pub fn rotate(angle_deg: f64) -> Self {
        let rad = angle_deg.to_radians();
        let cos_a = rad.cos();
        let sin_a = rad.sin();
        Self {
            a: cos_a,
            b: sin_a,
            c: -sin_a,
            d: cos_a,
            ..Self::IDENTITY
        }
    }
}

// ---------------------------------------------------------------------------
// SVG path commands (the 'd' attribute)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PathCommand {
    /// M x y
    MoveTo { x: f64, y: f64 },
    /// L x y
    LineTo { x: f64, y: f64 },
    /// C x1 y1 x2 y2 x y (cubic Bezier)
    CurveTo {
        x1: f64,
        y1: f64,
        x2: f64,
        y2: f64,
        x: f64,
        y: f64,
    },
    /// S x2 y2 x y (smooth cubic Bezier)
    SmoothCurveTo { x2: f64, y2: f64, x: f64, y: f64 },
    /// Q x1 y1 x y (quadratic Bezier)
    QuadTo { x1: f64, y1: f64, x: f64, y: f64 },
    /// T x y (smooth quadratic Bezier)
    SmoothQuadTo { x: f64, y: f64 },
    /// A rx ry x-rotation large-arc-flag sweep-flag x y
    ArcTo {
        rx: f64,
        ry: f64,
        x_rotation: f64,
        large_arc: bool,
        sweep: bool,
        x: f64,
        y: f64,
    },
    /// Z
    ClosePath,
}

// ---------------------------------------------------------------------------
// Bounding box
// ---------------------------------------------------------------------------

/// Axis-aligned bounding box (x, y, width, height).
pub type Bounds = (f64, f64, f64, f64);

/// Expand bounding box (x, y, w, h) by half-stroke-width on each side.
fn inflate_bounds(bbox: Bounds, stroke: Option<&Stroke>) -> Bounds {
    match stroke {
        None => bbox,
        Some(s) => {
            let half = s.width / 2.0;
            (
                bbox.0 - half,
                bbox.1 - half,
                bbox.2 + 2.0 * half,
                bbox.3 + 2.0 * half,
            )
        }
    }
}

// ---------------------------------------------------------------------------
// SVG Elements
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub enum Element {
    Line(LineElem),
    Rect(RectElem),
    Circle(CircleElem),
    Ellipse(EllipseElem),
    Polyline(PolylineElem),
    Polygon(PolygonElem),
    Path(PathElem),
    Text(TextElem),
    TextPath(TextPathElem),
    Group(GroupElem),
    Layer(LayerElem),
}

/// Common properties shared by all visible elements.
#[derive(Debug, Clone, PartialEq)]
pub struct CommonProps {
    pub opacity: f64,
    pub transform: Option<Transform>,
    pub locked: bool,
}

impl Default for CommonProps {
    fn default() -> Self {
        Self {
            opacity: 1.0,
            transform: None,
            locked: false,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct LineElem {
    pub x1: f64,
    pub y1: f64,
    pub x2: f64,
    pub y2: f64,
    pub stroke: Option<Stroke>,
    pub common: CommonProps,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RectElem {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub rx: f64,
    pub ry: f64,
    pub fill: Option<Fill>,
    pub stroke: Option<Stroke>,
    pub common: CommonProps,
}

#[derive(Debug, Clone, PartialEq)]
pub struct CircleElem {
    pub cx: f64,
    pub cy: f64,
    pub r: f64,
    pub fill: Option<Fill>,
    pub stroke: Option<Stroke>,
    pub common: CommonProps,
}

#[derive(Debug, Clone, PartialEq)]
pub struct EllipseElem {
    pub cx: f64,
    pub cy: f64,
    pub rx: f64,
    pub ry: f64,
    pub fill: Option<Fill>,
    pub stroke: Option<Stroke>,
    pub common: CommonProps,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PolylineElem {
    pub points: Vec<(f64, f64)>,
    pub fill: Option<Fill>,
    pub stroke: Option<Stroke>,
    pub common: CommonProps,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PolygonElem {
    pub points: Vec<(f64, f64)>,
    pub fill: Option<Fill>,
    pub stroke: Option<Stroke>,
    pub common: CommonProps,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PathElem {
    pub d: Vec<PathCommand>,
    pub fill: Option<Fill>,
    pub stroke: Option<Stroke>,
    pub common: CommonProps,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TextElem {
    pub x: f64,
    pub y: f64,
    pub content: String,
    pub font_family: String,
    pub font_size: f64,
    pub font_weight: String,
    pub font_style: String,
    pub text_decoration: String,
    pub width: f64,
    pub height: f64,
    pub fill: Option<Fill>,
    pub stroke: Option<Stroke>,
    pub common: CommonProps,
}

impl TextElem {
    pub fn is_area_text(&self) -> bool {
        self.width > 0.0 && self.height > 0.0
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct TextPathElem {
    pub d: Vec<PathCommand>,
    pub content: String,
    pub start_offset: f64,
    pub font_family: String,
    pub font_size: f64,
    pub font_weight: String,
    pub font_style: String,
    pub text_decoration: String,
    pub fill: Option<Fill>,
    pub stroke: Option<Stroke>,
    pub common: CommonProps,
}

#[derive(Debug, Clone, PartialEq)]
pub struct GroupElem {
    pub children: Vec<Rc<Element>>,
    pub common: CommonProps,
}

#[derive(Debug, Clone, PartialEq)]
pub struct LayerElem {
    pub name: String,
    pub children: Vec<Rc<Element>>,
    pub common: CommonProps,
}

// ---------------------------------------------------------------------------
// Element accessors
// ---------------------------------------------------------------------------

impl Element {
    pub fn common(&self) -> &CommonProps {
        match self {
            Element::Line(e) => &e.common,
            Element::Rect(e) => &e.common,
            Element::Circle(e) => &e.common,
            Element::Ellipse(e) => &e.common,
            Element::Polyline(e) => &e.common,
            Element::Polygon(e) => &e.common,
            Element::Path(e) => &e.common,
            Element::Text(e) => &e.common,
            Element::TextPath(e) => &e.common,
            Element::Group(e) => &e.common,
            Element::Layer(e) => &e.common,
        }
    }

    pub fn common_mut(&mut self) -> &mut CommonProps {
        match self {
            Element::Line(e) => &mut e.common,
            Element::Rect(e) => &mut e.common,
            Element::Circle(e) => &mut e.common,
            Element::Ellipse(e) => &mut e.common,
            Element::Polyline(e) => &mut e.common,
            Element::Polygon(e) => &mut e.common,
            Element::Path(e) => &mut e.common,
            Element::Text(e) => &mut e.common,
            Element::TextPath(e) => &mut e.common,
            Element::Group(e) => &mut e.common,
            Element::Layer(e) => &mut e.common,
        }
    }

    pub fn locked(&self) -> bool {
        self.common().locked
    }

    pub fn opacity(&self) -> f64 {
        self.common().opacity
    }

    pub fn transform(&self) -> Option<&Transform> {
        self.common().transform.as_ref()
    }

    pub fn children(&self) -> Option<&[Rc<Element>]> {
        match self {
            Element::Group(g) => Some(&g.children),
            Element::Layer(l) => Some(&l.children),
            _ => None,
        }
    }

    pub fn children_mut(&mut self) -> Option<&mut Vec<Rc<Element>>> {
        match self {
            Element::Group(g) => Some(&mut g.children),
            Element::Layer(l) => Some(&mut l.children),
            _ => None,
        }
    }

    pub fn is_group(&self) -> bool {
        matches!(self, Element::Group(_))
    }

    pub fn is_layer(&self) -> bool {
        matches!(self, Element::Layer(_))
    }

    pub fn is_group_or_layer(&self) -> bool {
        matches!(self, Element::Group(_) | Element::Layer(_))
    }

    pub fn fill(&self) -> Option<&Fill> {
        match self {
            Element::Rect(e) => e.fill.as_ref(),
            Element::Circle(e) => e.fill.as_ref(),
            Element::Ellipse(e) => e.fill.as_ref(),
            Element::Polyline(e) => e.fill.as_ref(),
            Element::Polygon(e) => e.fill.as_ref(),
            Element::Path(e) => e.fill.as_ref(),
            Element::Text(e) => e.fill.as_ref(),
            Element::TextPath(e) => e.fill.as_ref(),
            _ => None,
        }
    }

    pub fn stroke(&self) -> Option<&Stroke> {
        match self {
            Element::Line(e) => e.stroke.as_ref(),
            Element::Rect(e) => e.stroke.as_ref(),
            Element::Circle(e) => e.stroke.as_ref(),
            Element::Ellipse(e) => e.stroke.as_ref(),
            Element::Polyline(e) => e.stroke.as_ref(),
            Element::Polygon(e) => e.stroke.as_ref(),
            Element::Path(e) => e.stroke.as_ref(),
            Element::Text(e) => e.stroke.as_ref(),
            Element::TextPath(e) => e.stroke.as_ref(),
            _ => None,
        }
    }

    /// Return the bounding box as (x, y, width, height).
    pub fn bounds(&self) -> Bounds {
        match self {
            Element::Line(e) => {
                let min_x = e.x1.min(e.x2);
                let min_y = e.y1.min(e.y2);
                inflate_bounds(
                    (min_x, min_y, (e.x2 - e.x1).abs(), (e.y2 - e.y1).abs()),
                    e.stroke.as_ref(),
                )
            }
            Element::Rect(e) => {
                inflate_bounds((e.x, e.y, e.width, e.height), e.stroke.as_ref())
            }
            Element::Circle(e) => inflate_bounds(
                (e.cx - e.r, e.cy - e.r, e.r * 2.0, e.r * 2.0),
                e.stroke.as_ref(),
            ),
            Element::Ellipse(e) => inflate_bounds(
                (e.cx - e.rx, e.cy - e.ry, e.rx * 2.0, e.ry * 2.0),
                e.stroke.as_ref(),
            ),
            Element::Polyline(e) => points_bounds(&e.points, e.stroke.as_ref()),
            Element::Polygon(e) => points_bounds(&e.points, e.stroke.as_ref()),
            Element::Path(e) => inflate_bounds(path_bounds(&e.d), e.stroke.as_ref()),
            Element::Text(e) => {
                if e.is_area_text() {
                    (e.x, e.y, e.width, e.height)
                } else {
                    let approx_width = e.content.len() as f64 * e.font_size * APPROX_CHAR_WIDTH_FACTOR;
                    (e.x, e.y - e.font_size, approx_width, e.font_size)
                }
            }
            Element::TextPath(e) => inflate_bounds(path_bounds(&e.d), e.stroke.as_ref()),
            Element::Group(g) => children_bounds(&g.children),
            Element::Layer(l) => children_bounds(&l.children),
        }
    }
}

fn points_bounds(points: &[(f64, f64)], stroke: Option<&Stroke>) -> Bounds {
    if points.is_empty() {
        return (0.0, 0.0, 0.0, 0.0);
    }
    let min_x = points.iter().map(|p| p.0).fold(f64::INFINITY, f64::min);
    let min_y = points.iter().map(|p| p.1).fold(f64::INFINITY, f64::min);
    let max_x = points.iter().map(|p| p.0).fold(f64::NEG_INFINITY, f64::max);
    let max_y = points.iter().map(|p| p.1).fold(f64::NEG_INFINITY, f64::max);
    inflate_bounds((min_x, min_y, max_x - min_x, max_y - min_y), stroke)
}

/// Return t-values in (0,1) where a cubic Bezier is at an extremum.
fn cubic_extrema(p0: f64, p1: f64, p2: f64, p3: f64) -> Vec<f64> {
    let a = -3.0 * p0 + 9.0 * p1 - 9.0 * p2 + 3.0 * p3;
    let b = 6.0 * p0 - 12.0 * p1 + 6.0 * p2;
    let c = -3.0 * p0 + 3.0 * p1;
    let mut ts = Vec::new();
    if a.abs() < 1e-12 {
        if b.abs() > 1e-12 {
            let t = -c / b;
            if t > 0.0 && t < 1.0 {
                ts.push(t);
            }
        }
    } else {
        let disc = b * b - 4.0 * a * c;
        if disc >= 0.0 {
            let sq = disc.sqrt();
            for t in [(-b + sq) / (2.0 * a), (-b - sq) / (2.0 * a)] {
                if t > 0.0 && t < 1.0 {
                    ts.push(t);
                }
            }
        }
    }
    ts
}

fn quadratic_extremum(p0: f64, p1: f64, p2: f64) -> Vec<f64> {
    let denom = p0 - 2.0 * p1 + p2;
    if denom.abs() < 1e-12 {
        return vec![];
    }
    let t = (p0 - p1) / denom;
    if t > 0.0 && t < 1.0 { vec![t] } else { vec![] }
}

fn cubic_eval(p0: f64, p1: f64, p2: f64, p3: f64, t: f64) -> f64 {
    let u = 1.0 - t;
    u * u * u * p0 + 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t * p3
}

fn quadratic_eval(p0: f64, p1: f64, p2: f64, t: f64) -> f64 {
    let u = 1.0 - t;
    u * u * p0 + 2.0 * u * t * p1 + t * t * p2
}

fn path_bounds(d: &[PathCommand]) -> Bounds {
    let mut xs = Vec::new();
    let mut ys = Vec::new();
    let (mut cx, mut cy) = (0.0, 0.0);
    let (mut sx, mut sy) = (0.0, 0.0);
    let (mut prev_x2, mut prev_y2) = (0.0, 0.0);
    let mut prev_is_curve = false;
    for cmd in d {
        match cmd {
            PathCommand::MoveTo { x, y } => {
                xs.push(*x); ys.push(*y);
                cx = *x; cy = *y; sx = *x; sy = *y;
            }
            PathCommand::LineTo { x, y } => {
                xs.push(*x); ys.push(*y);
                cx = *x; cy = *y;
            }
            PathCommand::CurveTo { x1, y1, x2, y2, x, y } => {
                xs.push(cx); xs.push(*x); ys.push(cy); ys.push(*y);
                for t in cubic_extrema(cx, *x1, *x2, *x) {
                    xs.push(cubic_eval(cx, *x1, *x2, *x, t));
                }
                for t in cubic_extrema(cy, *y1, *y2, *y) {
                    ys.push(cubic_eval(cy, *y1, *y2, *y, t));
                }
                prev_x2 = *x2; prev_y2 = *y2;
                cx = *x; cy = *y;
                prev_is_curve = true;
                continue;
            }
            PathCommand::SmoothCurveTo { x2, y2, x, y } => {
                let (rx1, ry1) = if prev_is_curve {
                    (2.0 * cx - prev_x2, 2.0 * cy - prev_y2)
                } else {
                    (cx, cy)
                };
                xs.push(cx); xs.push(*x); ys.push(cy); ys.push(*y);
                for t in cubic_extrema(cx, rx1, *x2, *x) {
                    xs.push(cubic_eval(cx, rx1, *x2, *x, t));
                }
                for t in cubic_extrema(cy, ry1, *y2, *y) {
                    ys.push(cubic_eval(cy, ry1, *y2, *y, t));
                }
                prev_x2 = *x2; prev_y2 = *y2;
                cx = *x; cy = *y;
                prev_is_curve = true;
                continue;
            }
            PathCommand::QuadTo { x1, y1, x, y } => {
                xs.push(cx); xs.push(*x); ys.push(cy); ys.push(*y);
                for t in quadratic_extremum(cx, *x1, *x) {
                    xs.push(quadratic_eval(cx, *x1, *x, t));
                }
                for t in quadratic_extremum(cy, *y1, *y) {
                    ys.push(quadratic_eval(cy, *y1, *y, t));
                }
                cx = *x; cy = *y;
            }
            PathCommand::SmoothQuadTo { x, y } => {
                xs.push(*x); ys.push(*y);
                cx = *x; cy = *y;
            }
            PathCommand::ArcTo { x, y, .. } => {
                xs.push(*x); ys.push(*y);
                cx = *x; cy = *y;
            }
            PathCommand::ClosePath => {
                cx = sx; cy = sy;
            }
        }
        prev_is_curve = false;
    }
    if xs.is_empty() {
        return (0.0, 0.0, 0.0, 0.0);
    }
    let min_x = xs.iter().copied().fold(f64::INFINITY, f64::min);
    let min_y = ys.iter().copied().fold(f64::INFINITY, f64::min);
    let max_x = xs.iter().copied().fold(f64::NEG_INFINITY, f64::max);
    let max_y = ys.iter().copied().fold(f64::NEG_INFINITY, f64::max);
    (min_x, min_y, max_x - min_x, max_y - min_y)
}

fn children_bounds(children: &[Rc<Element>]) -> Bounds {
    if children.is_empty() {
        return (0.0, 0.0, 0.0, 0.0);
    }
    let all: Vec<Bounds> = children.iter().map(|c| c.bounds()).collect();
    let min_x = all.iter().map(|b| b.0).fold(f64::INFINITY, f64::min);
    let min_y = all.iter().map(|b| b.1).fold(f64::INFINITY, f64::min);
    let max_x = all
        .iter()
        .map(|b| b.0 + b.2)
        .fold(f64::NEG_INFINITY, f64::max);
    let max_y = all
        .iter()
        .map(|b| b.1 + b.3)
        .fold(f64::NEG_INFINITY, f64::max);
    (min_x, min_y, max_x - min_x, max_y - min_y)
}

// ---------------------------------------------------------------------------
// Control points
// ---------------------------------------------------------------------------

/// Return the number of control points for an element.
pub fn control_point_count(elem: &Element) -> usize {
    match elem {
        Element::Line(_) => 2,
        Element::Rect(_) | Element::Circle(_) | Element::Ellipse(_) => 4,
        Element::Polygon(e) => e.points.len(),
        Element::Path(e) => path_anchor_points(&e.d).len(),
        Element::TextPath(e) => path_anchor_points(&e.d).len(),
        _ => 4, // bounding box corners
    }
}

/// Return the (x, y) positions of each control point.
pub fn control_points(elem: &Element) -> Vec<(f64, f64)> {
    match elem {
        Element::Line(e) => vec![(e.x1, e.y1), (e.x2, e.y2)],
        Element::Rect(e) => vec![
            (e.x, e.y),
            (e.x + e.width, e.y),
            (e.x + e.width, e.y + e.height),
            (e.x, e.y + e.height),
        ],
        Element::Circle(e) => vec![
            (e.cx, e.cy - e.r),
            (e.cx + e.r, e.cy),
            (e.cx, e.cy + e.r),
            (e.cx - e.r, e.cy),
        ],
        Element::Ellipse(e) => vec![
            (e.cx, e.cy - e.ry),
            (e.cx + e.rx, e.cy),
            (e.cx, e.cy + e.ry),
            (e.cx - e.rx, e.cy),
        ],
        Element::Polygon(e) => e.points.clone(),
        Element::Path(e) => path_anchor_points(&e.d),
        Element::TextPath(e) => path_anchor_points(&e.d),
        _ => {
            let (bx, by, bw, bh) = elem.bounds();
            vec![
                (bx, by),
                (bx + bw, by),
                (bx + bw, by + bh),
                (bx, by + bh),
            ]
        }
    }
}

/// Extract anchor points from path commands.
pub fn path_anchor_points(d: &[PathCommand]) -> Vec<(f64, f64)> {
    let mut pts = Vec::new();
    for cmd in d {
        match cmd {
            PathCommand::MoveTo { x, y } | PathCommand::LineTo { x, y } => {
                pts.push((*x, *y));
            }
            PathCommand::CurveTo { x, y, .. }
            | PathCommand::SmoothCurveTo { x, y, .. }
            | PathCommand::QuadTo { x, y, .. }
            | PathCommand::SmoothQuadTo { x, y } => {
                pts.push((*x, *y));
            }
            PathCommand::ArcTo { x, y, .. } => {
                pts.push((*x, *y));
            }
            PathCommand::ClosePath => {}
        }
    }
    pts
}

// ---------------------------------------------------------------------------
// Path flattening (for hit-testing and text-on-path)
// ---------------------------------------------------------------------------

/// Flatten path commands into a polyline by evaluating Bezier curves.
pub fn flatten_path_commands(d: &[PathCommand]) -> Vec<(f64, f64)> {
    let mut pts = Vec::new();
    let mut cx = 0.0_f64;
    let mut cy = 0.0_f64;
    let steps = FLATTEN_STEPS;
    for cmd in d {
        match cmd {
            PathCommand::MoveTo { x, y } => {
                pts.push((*x, *y));
                cx = *x;
                cy = *y;
            }
            PathCommand::LineTo { x, y } => {
                pts.push((*x, *y));
                cx = *x;
                cy = *y;
            }
            PathCommand::CurveTo {
                x1, y1, x2, y2, x, y,
            } => {
                for i in 1..=steps {
                    let t = i as f64 / steps as f64;
                    let mt = 1.0 - t;
                    let px = mt.powi(3) * cx
                        + 3.0 * mt.powi(2) * t * x1
                        + 3.0 * mt * t.powi(2) * x2
                        + t.powi(3) * x;
                    let py = mt.powi(3) * cy
                        + 3.0 * mt.powi(2) * t * y1
                        + 3.0 * mt * t.powi(2) * y2
                        + t.powi(3) * y;
                    pts.push((px, py));
                }
                cx = *x;
                cy = *y;
            }
            PathCommand::QuadTo { x1, y1, x, y } => {
                for i in 1..=steps {
                    let t = i as f64 / steps as f64;
                    let mt = 1.0 - t;
                    let px = mt.powi(2) * cx + 2.0 * mt * t * x1 + t.powi(2) * x;
                    let py = mt.powi(2) * cy + 2.0 * mt * t * y1 + t.powi(2) * y;
                    pts.push((px, py));
                }
                cx = *x;
                cy = *y;
            }
            PathCommand::ClosePath => {
                if let Some(&first) = pts.first() {
                    pts.push(first);
                }
            }
            other => {
                // SmoothCurveTo, SmoothQuadTo, ArcTo — approximate as line
                let (x, y) = match other {
                    PathCommand::SmoothCurveTo { x, y, .. }
                    | PathCommand::SmoothQuadTo { x, y }
                    | PathCommand::ArcTo { x, y, .. } => (*x, *y),
                    _ => continue,
                };
                pts.push((x, y));
                cx = x;
                cy = y;
            }
        }
    }
    pts
}

// ---------------------------------------------------------------------------
// Move control points
// ---------------------------------------------------------------------------

use std::collections::HashSet;

/// Return a new element with the specified control points moved by (dx, dy).
pub fn move_control_points(
    elem: &Element,
    indices: &HashSet<usize>,
    dx: f64,
    dy: f64,
) -> Element {
    match elem {
        Element::Line(e) => {
            let mut new = e.clone();
            if indices.contains(&0) {
                new.x1 += dx;
                new.y1 += dy;
            }
            if indices.contains(&1) {
                new.x2 += dx;
                new.y2 += dy;
            }
            Element::Line(new)
        }
        Element::Rect(e) => {
            if indices.len() >= 4
                && indices.contains(&0)
                && indices.contains(&1)
                && indices.contains(&2)
                && indices.contains(&3)
            {
                let mut new = e.clone();
                new.x += dx;
                new.y += dy;
                Element::Rect(new)
            } else {
                // Convert to polygon when individual corners are moved
                let mut pts = vec![
                    (e.x, e.y),
                    (e.x + e.width, e.y),
                    (e.x + e.width, e.y + e.height),
                    (e.x, e.y + e.height),
                ];
                for i in 0..4 {
                    if indices.contains(&i) {
                        pts[i].0 += dx;
                        pts[i].1 += dy;
                    }
                }
                Element::Polygon(PolygonElem {
                    points: pts,
                    fill: e.fill,
                    stroke: e.stroke,
                    common: e.common.clone(),
                })
            }
        }
        Element::Circle(e) => {
            if indices.len() >= 4 {
                let mut new = e.clone();
                new.cx += dx;
                new.cy += dy;
                Element::Circle(new)
            } else {
                let mut cps = vec![
                    (e.cx, e.cy - e.r),
                    (e.cx + e.r, e.cy),
                    (e.cx, e.cy + e.r),
                    (e.cx - e.r, e.cy),
                ];
                for i in 0..4 {
                    if indices.contains(&i) {
                        cps[i].0 += dx;
                        cps[i].1 += dy;
                    }
                }
                let ncx = (cps[1].0 + cps[3].0) / 2.0;
                let ncy = (cps[0].1 + cps[2].1) / 2.0;
                let nr = (cps[1].0 - ncx).abs().max((cps[0].1 - ncy).abs());
                let mut new = e.clone();
                new.cx = ncx;
                new.cy = ncy;
                new.r = nr;
                Element::Circle(new)
            }
        }
        Element::Ellipse(e) => {
            if indices.len() >= 4 {
                let mut new = e.clone();
                new.cx += dx;
                new.cy += dy;
                Element::Ellipse(new)
            } else {
                let mut cps = vec![
                    (e.cx, e.cy - e.ry),
                    (e.cx + e.rx, e.cy),
                    (e.cx, e.cy + e.ry),
                    (e.cx - e.rx, e.cy),
                ];
                for i in 0..4 {
                    if indices.contains(&i) {
                        cps[i].0 += dx;
                        cps[i].1 += dy;
                    }
                }
                let mut new = e.clone();
                new.cx = (cps[1].0 + cps[3].0) / 2.0;
                new.cy = (cps[0].1 + cps[2].1) / 2.0;
                new.rx = (cps[1].0 - new.cx).abs();
                new.ry = (cps[0].1 - new.cy).abs();
                Element::Ellipse(new)
            }
        }
        Element::Polygon(e) => {
            let mut new_pts = e.points.clone();
            for i in 0..new_pts.len() {
                if indices.contains(&i) {
                    new_pts[i].0 += dx;
                    new_pts[i].1 += dy;
                }
            }
            Element::Polygon(PolygonElem {
                points: new_pts,
                ..e.clone()
            })
        }
        Element::Path(e) => {
            let new_d = move_path_command_points(&e.d, indices, dx, dy);
            Element::Path(PathElem {
                d: new_d,
                ..e.clone()
            })
        }
        Element::TextPath(e) => {
            let new_d = move_path_command_points(&e.d, indices, dx, dy);
            Element::TextPath(TextPathElem {
                d: new_d,
                ..e.clone()
            })
        }
        _ => elem.clone(),
    }
}

// ---------------------------------------------------------------------------
// Path handle positions and manipulation
// ---------------------------------------------------------------------------

/// Map anchor indices to command indices (skipping ClosePath).
fn cmd_indices_for_path(d: &[PathCommand]) -> Vec<usize> {
    d.iter()
        .enumerate()
        .filter(|(_, cmd)| !matches!(cmd, PathCommand::ClosePath))
        .map(|(i, _)| i)
        .collect()
}

/// Return (incoming_handle, outgoing_handle) for a path anchor.
/// Returns None for a handle that doesn't exist or coincides with its anchor.
pub fn path_handle_positions(
    d: &[PathCommand],
    anchor_idx: usize,
) -> (Option<(f64, f64)>, Option<(f64, f64)>) {
    let indices = cmd_indices_for_path(d);
    if anchor_idx >= indices.len() {
        return (None, None);
    }
    let ci = indices[anchor_idx];
    let cmd = &d[ci];

    // Get anchor position
    let (ax, ay) = match cmd {
        PathCommand::MoveTo { x, y } | PathCommand::LineTo { x, y } => (*x, *y),
        PathCommand::CurveTo { x, y, .. } => (*x, *y),
        _ => return (None, None),
    };

    // Incoming handle: (x2, y2) of this CurveTo
    let h_in = if let PathCommand::CurveTo { x2, y2, .. } = cmd {
        if (*x2 - ax).abs() > 0.01 || (*y2 - ay).abs() > 0.01 {
            Some((*x2, *y2))
        } else {
            None
        }
    } else {
        None
    };

    // Outgoing handle: (x1, y1) of next CurveTo
    let h_out = if ci + 1 < d.len() {
        if let PathCommand::CurveTo { x1, y1, .. } = &d[ci + 1] {
            if (*x1 - ax).abs() > 0.01 || (*y1 - ay).abs() > 0.01 {
                Some((*x1, *y1))
            } else {
                None
            }
        } else {
            None
        }
    } else {
        None
    };

    (h_in, h_out)
}

/// Rotate the opposite handle to be collinear, preserving its distance.
fn reflect_handle_keep_distance(
    ax: f64, ay: f64,
    new_hx: f64, new_hy: f64,
    opp_hx: f64, opp_hy: f64,
) -> (f64, f64) {
    let dist_new = ((new_hx - ax).powi(2) + (new_hy - ay).powi(2)).sqrt();
    let dist_opp = ((opp_hx - ax).powi(2) + (opp_hy - ay).powi(2)).sqrt();
    if dist_new < 1e-6 {
        return (opp_hx, opp_hy);
    }
    let scale = -dist_opp / dist_new;
    (ax + (new_hx - ax) * scale, ay + (new_hy - ay) * scale)
}

/// Move a specific handle ('in' or 'out') of a path anchor by (dx, dy).
pub fn move_path_handle(
    elem: &PathElem,
    anchor_idx: usize,
    handle_type: &str,
    dx: f64,
    dy: f64,
) -> PathElem {
    let d = &elem.d;
    let indices = cmd_indices_for_path(d);
    if anchor_idx >= indices.len() {
        return elem.clone();
    }
    let ci = indices[anchor_idx];
    let cmd = &d[ci];

    let (ax, ay) = match cmd {
        PathCommand::MoveTo { x, y } | PathCommand::LineTo { x, y } => (*x, *y),
        PathCommand::CurveTo { x, y, .. } => (*x, *y),
        _ => return elem.clone(),
    };

    let mut new_cmds = d.clone();

    if handle_type == "in" {
        if let PathCommand::CurveTo { x1, y1, x2, y2, x, y } = d[ci] {
            let new_hx = x2 + dx;
            let new_hy = y2 + dy;
            new_cmds[ci] = PathCommand::CurveTo { x1, y1, x2: new_hx, y2: new_hy, x, y };
            // Rotate opposite (out) handle
            if ci + 1 < d.len() {
                if let PathCommand::CurveTo { x1: nx1, y1: ny1, x2: nx2, y2: ny2, x: nx, y: ny } = d[ci + 1] {
                    let (rx, ry) = reflect_handle_keep_distance(ax, ay, new_hx, new_hy, nx1, ny1);
                    new_cmds[ci + 1] = PathCommand::CurveTo { x1: rx, y1: ry, x2: nx2, y2: ny2, x: nx, y: ny };
                }
            }
        }
    } else if handle_type == "out" {
        if ci + 1 < d.len() {
            if let PathCommand::CurveTo { x1: nx1, y1: ny1, x2: nx2, y2: ny2, x: nx, y: ny } = d[ci + 1] {
                let new_hx = nx1 + dx;
                let new_hy = ny1 + dy;
                new_cmds[ci + 1] = PathCommand::CurveTo { x1: new_hx, y1: new_hy, x2: nx2, y2: ny2, x: nx, y: ny };
                // Rotate opposite (in) handle
                if let PathCommand::CurveTo { x1, y1, x2, y2, x, y } = d[ci] {
                    let (rx, ry) = reflect_handle_keep_distance(ax, ay, new_hx, new_hy, x2, y2);
                    new_cmds[ci] = PathCommand::CurveTo { x1, y1, x2: rx, y2: ry, x, y };
                }
            }
        }
    }

    PathElem { d: new_cmds, ..elem.clone() }
}

fn move_path_command_points(
    d: &[PathCommand],
    indices: &HashSet<usize>,
    dx: f64,
    dy: f64,
) -> Vec<PathCommand> {
    let mut new_cmds: Vec<PathCommand> = d.to_vec();
    let mut anchor_idx = 0usize;
    for ci in 0..d.len() {
        if matches!(d[ci], PathCommand::ClosePath) {
            continue;
        }
        if indices.contains(&anchor_idx) {
            match d[ci] {
                PathCommand::MoveTo { x, y } => {
                    new_cmds[ci] = PathCommand::MoveTo {
                        x: x + dx,
                        y: y + dy,
                    };
                    // Move outgoing handle
                    if ci + 1 < d.len() {
                        if let PathCommand::CurveTo {
                            x1, y1, x2, y2, x, y,
                        } = d[ci + 1]
                        {
                            new_cmds[ci + 1] = PathCommand::CurveTo {
                                x1: x1 + dx,
                                y1: y1 + dy,
                                x2,
                                y2,
                                x,
                                y,
                            };
                        }
                    }
                }
                PathCommand::CurveTo {
                    x1, y1, x2, y2, x, y,
                } => {
                    new_cmds[ci] = PathCommand::CurveTo {
                        x1,
                        y1,
                        x2: x2 + dx,
                        y2: y2 + dy,
                        x: x + dx,
                        y: y + dy,
                    };
                    // Move outgoing handle
                    if ci + 1 < d.len() {
                        if let PathCommand::CurveTo {
                            x1,
                            y1,
                            x2,
                            y2,
                            x,
                            y,
                        } = d[ci + 1]
                        {
                            new_cmds[ci + 1] = PathCommand::CurveTo {
                                x1: x1 + dx,
                                y1: y1 + dy,
                                x2,
                                y2,
                                x,
                                y,
                            };
                        }
                    }
                }
                PathCommand::LineTo { x, y } => {
                    new_cmds[ci] = PathCommand::LineTo {
                        x: x + dx,
                        y: y + dy,
                    };
                }
                _ => {}
            }
        }
        anchor_idx += 1;
    }
    new_cmds
}

// ---------------------------------------------------------------------------
// Translate element
// ---------------------------------------------------------------------------

fn translate_path_commands(d: &[PathCommand], dx: f64, dy: f64) -> Vec<PathCommand> {
    d.iter()
        .map(|cmd| match cmd {
            PathCommand::MoveTo { x, y } => PathCommand::MoveTo { x: x + dx, y: y + dy },
            PathCommand::LineTo { x, y } => PathCommand::LineTo { x: x + dx, y: y + dy },
            PathCommand::CurveTo { x1, y1, x2, y2, x, y } => PathCommand::CurveTo {
                x1: x1 + dx, y1: y1 + dy, x2: x2 + dx, y2: y2 + dy, x: x + dx, y: y + dy,
            },
            PathCommand::SmoothCurveTo { x2, y2, x, y } => PathCommand::SmoothCurveTo {
                x2: x2 + dx, y2: y2 + dy, x: x + dx, y: y + dy,
            },
            PathCommand::QuadTo { x1, y1, x, y } => PathCommand::QuadTo {
                x1: x1 + dx, y1: y1 + dy, x: x + dx, y: y + dy,
            },
            PathCommand::SmoothQuadTo { x, y } => PathCommand::SmoothQuadTo { x: x + dx, y: y + dy },
            PathCommand::ArcTo { rx, ry, x_rotation, large_arc, sweep, x, y } => PathCommand::ArcTo {
                rx: *rx, ry: *ry, x_rotation: *x_rotation, large_arc: *large_arc, sweep: *sweep,
                x: x + dx, y: y + dy,
            },
            PathCommand::ClosePath => PathCommand::ClosePath,
        })
        .collect()
}

/// Translate an element by (dx, dy), recursing into groups.
pub fn translate_element(elem: &Element, dx: f64, dy: f64) -> Element {
    match elem {
        Element::Line(e) => Element::Line(LineElem {
            x1: e.x1 + dx, y1: e.y1 + dy, x2: e.x2 + dx, y2: e.y2 + dy, ..e.clone()
        }),
        Element::Rect(e) => Element::Rect(RectElem {
            x: e.x + dx, y: e.y + dy, ..e.clone()
        }),
        Element::Circle(e) => Element::Circle(CircleElem {
            cx: e.cx + dx, cy: e.cy + dy, ..e.clone()
        }),
        Element::Ellipse(e) => Element::Ellipse(EllipseElem {
            cx: e.cx + dx, cy: e.cy + dy, ..e.clone()
        }),
        Element::Polyline(e) => Element::Polyline(PolylineElem {
            points: e.points.iter().map(|(x, y)| (x + dx, y + dy)).collect(), ..e.clone()
        }),
        Element::Polygon(e) => Element::Polygon(PolygonElem {
            points: e.points.iter().map(|(x, y)| (x + dx, y + dy)).collect(), ..e.clone()
        }),
        Element::Path(e) => Element::Path(PathElem {
            d: translate_path_commands(&e.d, dx, dy), ..e.clone()
        }),
        Element::Text(e) => Element::Text(TextElem {
            x: e.x + dx, y: e.y + dy, ..e.clone()
        }),
        Element::TextPath(e) => Element::TextPath(TextPathElem {
            d: translate_path_commands(&e.d, dx, dy), ..e.clone()
        }),
        Element::Group(e) => Element::Group(GroupElem {
            children: e.children.iter().map(|c| Rc::new(translate_element(c, dx, dy))).collect(),
            ..e.clone()
        }),
        Element::Layer(e) => Element::Layer(LayerElem {
            children: e.children.iter().map(|c| Rc::new(translate_element(c, dx, dy))).collect(),
            ..e.clone()
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rect(x: f64, y: f64, w: f64, h: f64) -> Element {
        Element::Rect(RectElem {
            x, y, width: w, height: h, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(),
        })
    }

    fn line(x1: f64, y1: f64, x2: f64, y2: f64) -> Element {
        Element::Line(LineElem {
            x1, y1, x2, y2,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            common: CommonProps::default(),
        })
    }

    fn circle(cx: f64, cy: f64, r: f64) -> Element {
        Element::Circle(CircleElem {
            cx, cy, r,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(),
        })
    }

    fn ellipse(cx: f64, cy: f64, rx: f64, ry: f64) -> Element {
        Element::Ellipse(EllipseElem {
            cx, cy, rx, ry,
            fill: None, stroke: None,
            common: CommonProps::default(),
        })
    }

    fn path_elem(d: Vec<PathCommand>) -> Element {
        Element::Path(PathElem {
            d, fill: None, stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            common: CommonProps::default(),
        })
    }

    fn group(children: Vec<Element>) -> Element {
        Element::Group(GroupElem {
            children: children.into_iter().map(Rc::new).collect(),
            common: CommonProps::default(),
        })
    }

    // --- Bounds tests ---

    #[test]
    fn rect_bounds() {
        assert_eq!(rect(10.0, 20.0, 30.0, 40.0).bounds(), (10.0, 20.0, 30.0, 40.0));
    }

    #[test]
    fn line_bounds_no_stroke() {
        let e = Element::Line(LineElem {
            x1: 0.0, y1: 0.0, x2: 50.0, y2: 50.0,
            stroke: None, common: CommonProps::default(),
        });
        assert_eq!(e.bounds(), (0.0, 0.0, 50.0, 50.0));
    }

    #[test]
    fn line_bounds_with_stroke() {
        let e = line(0.0, 0.0, 50.0, 50.0);
        let (bx, by, bw, bh) = e.bounds();
        assert!(bx < 0.0); // inflated by stroke
        assert!(by < 0.0);
        assert!(bw > 50.0);
        assert!(bh > 50.0);
    }

    #[test]
    fn circle_bounds() {
        let (bx, by, bw, bh) = circle(50.0, 50.0, 20.0).bounds();
        assert_eq!((bx, by, bw, bh), (30.0, 30.0, 40.0, 40.0));
    }

    #[test]
    fn ellipse_bounds() {
        let (bx, by, bw, bh) = ellipse(50.0, 50.0, 30.0, 15.0).bounds();
        assert_eq!((bx, by, bw, bh), (20.0, 35.0, 60.0, 30.0));
    }

    #[test]
    fn group_bounds() {
        let g = group(vec![
            rect(0.0, 0.0, 10.0, 10.0),
            rect(20.0, 20.0, 10.0, 10.0),
        ]);
        assert_eq!(g.bounds(), (0.0, 0.0, 30.0, 30.0));
    }

    #[test]
    fn empty_group_bounds() {
        let g = group(vec![]);
        assert_eq!(g.bounds(), (0.0, 0.0, 0.0, 0.0));
    }

    // --- Control points tests ---

    #[test]
    fn rect_has_4_control_points() {
        assert_eq!(control_point_count(&rect(0.0, 0.0, 10.0, 10.0)), 4);
    }

    #[test]
    fn line_has_2_control_points() {
        assert_eq!(control_point_count(&line(0.0, 0.0, 10.0, 10.0)), 2);
    }

    #[test]
    fn circle_has_4_control_points() {
        assert_eq!(control_point_count(&circle(50.0, 50.0, 20.0)), 4);
    }

    #[test]
    fn rect_control_points_are_corners() {
        let cps = control_points(&rect(10.0, 20.0, 30.0, 40.0));
        assert_eq!(cps, vec![
            (10.0, 20.0), (40.0, 20.0), (40.0, 60.0), (10.0, 60.0)
        ]);
    }

    #[test]
    fn line_control_points_are_endpoints() {
        let cps = control_points(&line(5.0, 10.0, 15.0, 20.0));
        assert_eq!(cps, vec![(5.0, 10.0), (15.0, 20.0)]);
    }

    // --- Translate tests ---

    #[test]
    fn translate_rect() {
        let e = translate_element(&rect(10.0, 20.0, 30.0, 40.0), 5.0, -3.0);
        if let Element::Rect(r) = e {
            assert_eq!(r.x, 15.0);
            assert_eq!(r.y, 17.0);
        } else {
            panic!("expected Rect");
        }
    }

    #[test]
    fn translate_line() {
        let e = translate_element(&line(0.0, 0.0, 10.0, 10.0), 5.0, 5.0);
        if let Element::Line(l) = e {
            assert_eq!((l.x1, l.y1, l.x2, l.y2), (5.0, 5.0, 15.0, 15.0));
        } else {
            panic!("expected Line");
        }
    }

    // --- Path flattening ---

    #[test]
    fn flatten_line_path() {
        let d = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 10.0, y: 0.0 },
        ];
        let pts = flatten_path_commands(&d);
        assert_eq!(pts.len(), 2);
        assert_eq!(pts[0], (0.0, 0.0));
        assert_eq!(pts[1], (10.0, 0.0));
    }

    #[test]
    fn flatten_empty_path() {
        let pts = flatten_path_commands(&[]);
        assert!(pts.is_empty());
    }

    #[test]
    fn flatten_curve_path() {
        let d = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::CurveTo { x1: 10.0, y1: 0.0, x2: 10.0, y2: 10.0, x: 10.0, y: 10.0 },
        ];
        let pts = flatten_path_commands(&d);
        assert!(pts.len() > 2); // Bezier gets subdivided
        assert_eq!(pts[0], (0.0, 0.0));
        let last = pts.last().unwrap();
        assert!((last.0 - 10.0).abs() < 0.01);
        assert!((last.1 - 10.0).abs() < 0.01);
    }
}
