//! Immutable document elements conforming to SVG element types.
//!
//! All elements are immutable value objects. To modify an element, create a new
//! one with the desired changes. Element types and attributes follow the SVG 1.1
//! specification.

/// Line segments per Bezier curve when flattening paths.
pub const FLATTEN_STEPS: usize = 20;

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

fn inflate_bounds(bbox: Bounds, stroke: Option<&Stroke>) -> Bounds {
    match stroke {
        None => bbox,
        Some(s) => {
            let half = s.width / 2.0;
            (
                bbox.0 - half,
                bbox.1 - half,
                bbox.2 + s.width,
                bbox.3 + s.width,
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
    pub children: Vec<Element>,
    pub common: CommonProps,
}

#[derive(Debug, Clone, PartialEq)]
pub struct LayerElem {
    pub name: String,
    pub children: Vec<Element>,
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

    pub fn children(&self) -> Option<&[Element]> {
        match self {
            Element::Group(g) => Some(&g.children),
            Element::Layer(l) => Some(&l.children),
            _ => None,
        }
    }

    pub fn children_mut(&mut self) -> Option<&mut Vec<Element>> {
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
                    let approx_width = e.content.len() as f64 * e.font_size * 0.6;
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

fn path_bounds(d: &[PathCommand]) -> Bounds {
    let mut xs = Vec::new();
    let mut ys = Vec::new();
    for cmd in d {
        match cmd {
            PathCommand::MoveTo { x, y }
            | PathCommand::LineTo { x, y }
            | PathCommand::SmoothQuadTo { x, y } => {
                xs.push(*x);
                ys.push(*y);
            }
            PathCommand::CurveTo {
                x1, y1, x2, y2, x, y,
            } => {
                xs.extend_from_slice(&[*x1, *x2, *x]);
                ys.extend_from_slice(&[*y1, *y2, *y]);
            }
            PathCommand::SmoothCurveTo { x2, y2, x, y } => {
                xs.extend_from_slice(&[*x2, *x]);
                ys.extend_from_slice(&[*y2, *y]);
            }
            PathCommand::QuadTo { x1, y1, x, y } => {
                xs.extend_from_slice(&[*x1, *x]);
                ys.extend_from_slice(&[*y1, *y]);
            }
            PathCommand::ArcTo { x, y, .. } => {
                xs.push(*x);
                ys.push(*y);
            }
            PathCommand::ClosePath => {}
        }
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

fn children_bounds(children: &[Element]) -> Bounds {
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
