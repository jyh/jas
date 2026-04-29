//! Immutable document elements conforming to SVG element types.
//!
// Public API surface — convenience constructors and predicates are
// exposed for callers that aren't all wired up yet.
#![allow(dead_code)]
//!
//! All elements are immutable value objects. To modify an element, create a new
//! one with the desired changes. Element types and attributes follow the SVG 1.1
//! specification.

use std::rc::Rc;

/// A width control point for variable-width stroke profiles.
/// Stored as a sorted list on PathElem/LineElem.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct StrokeWidthPoint {
    /// Position along path [0.0, 1.0].
    pub t: f64,
    /// Half-width on the left side of the centerline.
    pub width_left: f64,
    /// Half-width on the right side of the centerline.
    pub width_right: f64,
}

/// Convert a named profile preset to width control points.
pub fn profile_to_width_points(profile: &str, width: f64, flipped: bool) -> Vec<StrokeWidthPoint> {
    let hw = width / 2.0;
    let pts = match profile {
        "taper_both" => vec![
            StrokeWidthPoint { t: 0.0, width_left: 0.0, width_right: 0.0 },
            StrokeWidthPoint { t: 0.5, width_left: hw, width_right: hw },
            StrokeWidthPoint { t: 1.0, width_left: 0.0, width_right: 0.0 },
        ],
        "taper_start" => vec![
            StrokeWidthPoint { t: 0.0, width_left: 0.0, width_right: 0.0 },
            StrokeWidthPoint { t: 1.0, width_left: hw, width_right: hw },
        ],
        "taper_end" => vec![
            StrokeWidthPoint { t: 0.0, width_left: hw, width_right: hw },
            StrokeWidthPoint { t: 1.0, width_left: 0.0, width_right: 0.0 },
        ],
        "bulge" => vec![
            StrokeWidthPoint { t: 0.0, width_left: hw, width_right: hw },
            StrokeWidthPoint { t: 0.5, width_left: hw * 1.5, width_right: hw * 1.5 },
            StrokeWidthPoint { t: 1.0, width_left: hw, width_right: hw },
        ],
        "pinch" => vec![
            StrokeWidthPoint { t: 0.0, width_left: hw, width_right: hw },
            StrokeWidthPoint { t: 0.5, width_left: hw * 0.5, width_right: hw * 0.5 },
            StrokeWidthPoint { t: 1.0, width_left: hw, width_right: hw },
        ],
        _ => return vec![], // "uniform" or unknown → empty = use Stroke.width
    };
    if flipped {
        // Reverse the t values
        pts.into_iter().rev().map(|p| StrokeWidthPoint {
            t: 1.0 - p.t,
            width_left: p.width_left,
            width_right: p.width_right,
        }).collect()
    } else {
        pts
    }
}

/// Line segments per Bezier curve when flattening paths.
pub const FLATTEN_STEPS: usize = 20;

/// Average character width as a fraction of font size.
pub const APPROX_CHAR_WIDTH_FACTOR: f64 = 0.6;

// ---------------------------------------------------------------------------
// SVG presentation attributes
// ---------------------------------------------------------------------------

/// Color with support for RGB, HSB, and CMYK color spaces.
///
/// Components are normalized to [0, 1] except HSB hue which is [0, 360).
/// Each variant carries its own alpha in [0, 1].
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum Color {
    /// Red, green, blue, alpha — all in [0, 1].
    Rgb { r: f64, g: f64, b: f64, a: f64 },
    /// Hue [0, 360), saturation [0, 1], brightness [0, 1], alpha [0, 1].
    Hsb { h: f64, s: f64, b: f64, a: f64 },
    /// Cyan, magenta, yellow, key (black), alpha — all in [0, 1].
    Cmyk { c: f64, m: f64, y: f64, k: f64, a: f64 },
}

impl Color {
    /// Create an RGB color (backward-compatible alias for `Color::Rgb`).
    pub const fn new(r: f64, g: f64, b: f64, a: f64) -> Self {
        Self::Rgb { r, g, b, a }
    }

    /// Create an opaque RGB color.
    pub const fn rgb(r: f64, g: f64, b: f64) -> Self {
        Self::Rgb { r, g, b, a: 1.0 }
    }

    /// Create an opaque HSB color.
    pub const fn hsb(h: f64, s: f64, b: f64) -> Self {
        Self::Hsb { h, s, b, a: 1.0 }
    }

    /// Create an opaque CMYK color.
    pub const fn cmyk(c: f64, m: f64, y: f64, k: f64) -> Self {
        Self::Cmyk { c, m, y, k, a: 1.0 }
    }

    pub const BLACK: Self = Self::rgb(0.0, 0.0, 0.0);
    pub const WHITE: Self = Self::rgb(1.0, 1.0, 1.0);

    /// Alpha component, regardless of color space.
    pub fn alpha(&self) -> f64 {
        match self {
            Self::Rgb { a, .. } | Self::Hsb { a, .. } | Self::Cmyk { a, .. } => *a,
        }
    }

    /// Return a copy of this color with the alpha component replaced.
    pub fn with_alpha(&self, a: f64) -> Self {
        match *self {
            Self::Rgb { r, g, b, .. } => Self::Rgb { r, g, b, a },
            Self::Hsb { h, s, b, .. } => Self::Hsb { h, s, b, a },
            Self::Cmyk { c, m, y, k, .. } => Self::Cmyk { c, m, y, k, a },
        }
    }

    /// Convert to (r, g, b, a) with all components in [0, 1].
    pub fn to_rgba(&self) -> (f64, f64, f64, f64) {
        match *self {
            Self::Rgb { r, g, b, a } => (r, g, b, a),
            Self::Hsb { h, s, b, a } => {
                let (r, g, bl) = hsb_to_rgb_components(h, s, b);
                (r, g, bl, a)
            }
            Self::Cmyk { c, m, y, k, a } => {
                let r = (1.0 - c) * (1.0 - k);
                let g = (1.0 - m) * (1.0 - k);
                let b = (1.0 - y) * (1.0 - k);
                (r, g, b, a)
            }
        }
    }

    /// Convert to (h, s, b, a) with h in [0, 360), s/b in [0, 1].
    pub fn to_hsba(&self) -> (f64, f64, f64, f64) {
        match *self {
            Self::Hsb { h, s, b, a } => (h, s, b, a),
            _ => {
                let (r, g, b, a) = self.to_rgba();
                let (h, s, br) = rgb_to_hsb_components(r, g, b);
                (h, s, br, a)
            }
        }
    }

    /// Convert to a 6-character lowercase hex string (no `#` prefix).
    pub fn to_hex(&self) -> String {
        let (r, g, b, _) = self.to_rgba();
        let ri = (r * 255.0).round() as u8;
        let gi = (g * 255.0).round() as u8;
        let bi = (b * 255.0).round() as u8;
        format!("{ri:02x}{gi:02x}{bi:02x}")
    }

    /// Parse a 6-character hex string into an opaque RGB color.
    /// An optional leading `#` is stripped.
    pub fn from_hex(s: &str) -> Option<Self> {
        let s = s.strip_prefix('#').unwrap_or(s);
        if s.len() != 6 {
            return None;
        }
        let r = u8::from_str_radix(&s[0..2], 16).ok()?;
        let g = u8::from_str_radix(&s[2..4], 16).ok()?;
        let b = u8::from_str_radix(&s[4..6], 16).ok()?;
        Some(Self::rgb(r as f64 / 255.0, g as f64 / 255.0, b as f64 / 255.0))
    }

    /// Convert to (c, m, y, k, a) with all components in [0, 1].
    pub fn to_cmyka(&self) -> (f64, f64, f64, f64, f64) {
        match *self {
            Self::Cmyk { c, m, y, k, a } => (c, m, y, k, a),
            _ => {
                let (r, g, b, a) = self.to_rgba();
                let max = r.max(g).max(b);
                let k = 1.0 - max;
                if k >= 1.0 {
                    (0.0, 0.0, 0.0, 1.0, a)
                } else {
                    let c = (1.0 - r - k) / (1.0 - k);
                    let m = (1.0 - g - k) / (1.0 - k);
                    let y = (1.0 - b - k) / (1.0 - k);
                    (c, m, y, k, a)
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Color-space conversion helpers
// ---------------------------------------------------------------------------

fn hsb_to_rgb_components(h: f64, s: f64, v: f64) -> (f64, f64, f64) {
    if s == 0.0 {
        return (v, v, v);
    }
    let h = ((h % 360.0) + 360.0) % 360.0; // normalize hue
    let hi = (h / 60.0).floor() as u32 % 6;
    let f = h / 60.0 - hi as f64;
    let p = v * (1.0 - s);
    let q = v * (1.0 - s * f);
    let t = v * (1.0 - s * (1.0 - f));
    match hi {
        0 => (v, t, p),
        1 => (q, v, p),
        2 => (p, v, t),
        3 => (p, q, v),
        4 => (t, p, v),
        _ => (v, p, q),
    }
}

fn rgb_to_hsb_components(r: f64, g: f64, b: f64) -> (f64, f64, f64) {
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let delta = max - min;

    let brightness = max;
    let saturation = if max == 0.0 { 0.0 } else { delta / max };

    let hue = if delta == 0.0 {
        0.0
    } else if max == r {
        60.0 * (((g - b) / delta) % 6.0)
    } else if max == g {
        60.0 * ((b - r) / delta + 2.0)
    } else {
        60.0 * ((r - g) / delta + 4.0)
    };
    let hue = ((hue % 360.0) + 360.0) % 360.0;

    (hue, saturation, brightness)
}

impl Default for Color {
    fn default() -> Self {
        Self::BLACK
    }
}

/// Arrowhead shape identifier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub enum Arrowhead {
    #[default]
    None,
    SimpleArrow,
    OpenArrow,
    ClosedArrow,
    StealthArrow,
    BarbedArrow,
    HalfArrowUpper,
    HalfArrowLower,
    Circle,
    OpenCircle,
    Square,
    OpenSquare,
    Diamond,
    OpenDiamond,
    Slash,
}

impl Arrowhead {
    pub fn from_str(s: &str) -> Self {
        match s {
            "simple_arrow" => Self::SimpleArrow,
            "open_arrow" => Self::OpenArrow,
            "closed_arrow" => Self::ClosedArrow,
            "stealth_arrow" => Self::StealthArrow,
            "barbed_arrow" => Self::BarbedArrow,
            "half_arrow_upper" => Self::HalfArrowUpper,
            "half_arrow_lower" => Self::HalfArrowLower,
            "circle" => Self::Circle,
            "open_circle" => Self::OpenCircle,
            "square" => Self::Square,
            "open_square" => Self::OpenSquare,
            "diamond" => Self::Diamond,
            "open_diamond" => Self::OpenDiamond,
            "slash" => Self::Slash,
            _ => Self::None,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::None => "none",
            Self::SimpleArrow => "simple_arrow",
            Self::OpenArrow => "open_arrow",
            Self::ClosedArrow => "closed_arrow",
            Self::StealthArrow => "stealth_arrow",
            Self::BarbedArrow => "barbed_arrow",
            Self::HalfArrowUpper => "half_arrow_upper",
            Self::HalfArrowLower => "half_arrow_lower",
            Self::Circle => "circle",
            Self::OpenCircle => "open_circle",
            Self::Square => "square",
            Self::OpenSquare => "open_square",
            Self::Diamond => "diamond",
            Self::OpenDiamond => "open_diamond",
            Self::Slash => "slash",
        }
    }
}

/// Arrow alignment mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub enum ArrowAlign {
    #[default]
    TipAtEnd,
    CenterAtEnd,
}

/// Stroke alignment relative to the path.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub enum StrokeAlign {
    #[default]
    Center,
    Inside,
    Outside,
}

/// SVG stroke-linecap.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub enum LineCap {
    #[default]
    Butt,
    Round,
    Square,
}

/// SVG stroke-linejoin.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub enum LineJoin {
    #[default]
    Miter,
    Round,
    Bevel,
}

/// Gradient type: linear (along a vector), radial (from a center), or
/// freeform (from 2-D scattered nodes). See `transcripts/GRADIENT.md`
/// §Gradient types.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GradientType {
    #[default]
    Linear,
    Radial,
    Freeform,
}

/// Gradient interpolation / topology method. Semantics depend on the
/// gradient type — `classic` / `smooth` apply to linear/radial;
/// `points` / `lines` apply to freeform. See GRADIENT.md §Method.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GradientMethod {
    #[default]
    Classic,
    Smooth,
    Points,
    Lines,
}

/// Stroke sub-mode — how a gradient on a stroke maps onto the path.
/// See GRADIENT.md §Stroke sub-modes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StrokeSubMode {
    #[default]
    Within,
    Along,
    Across,
}

/// A single color stop inside a linear/radial gradient.
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct GradientStop {
    pub color: Color,
    /// Opacity 0–100 (percentage).
    pub opacity: f64,
    /// Location 0–100 (percentage along the gradient strip).
    pub location: f64,
    /// Midpoint between this stop and the next, stored as a
    /// percentage-between value (0–100, where 50 = halfway).
    /// Ignored on the last stop.
    #[serde(default = "default_midpoint")]
    pub midpoint_to_next: f64,
}

fn default_midpoint() -> f64 {
    50.0
}

/// A single node of a freeform gradient.
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct GradientNode {
    /// Position in the element's bounding box, normalized to [0, 1].
    pub x: f64,
    pub y: f64,
    pub color: Color,
    /// Opacity 0–100 (percentage).
    pub opacity: f64,
    /// Spread radius 0–100 (percentage of bounding-box diagonal).
    pub spread: f64,
}

/// A gradient value that can be used as a fill or stroke.
///
/// Gradients are inline on the element — `Fill.gradient` / `Stroke.gradient`
/// carry an `Option<Gradient>`. When present the element is painted with
/// the gradient; when None the `color` field of Fill/Stroke is used.
/// See GRADIENT.md §Document model.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Gradient {
    #[serde(rename = "type", default)]
    pub gtype: GradientType,
    /// Angle in degrees, −180..+180. Linear/radial only. Default 0.
    #[serde(default)]
    pub angle: f64,
    /// Aspect ratio as a percentage, 1–1000. Linear/radial only.
    /// 100 = isotropic (circle for radial). Default 100.
    #[serde(default = "default_aspect_ratio")]
    pub aspect_ratio: f64,
    #[serde(default)]
    pub method: GradientMethod,
    #[serde(default)]
    pub dither: bool,
    /// Stroke sub-mode. Applies when this gradient is on a stroke.
    #[serde(default)]
    pub stroke_sub_mode: StrokeSubMode,
    /// Stops for linear/radial gradients. Empty for freeform.
    #[serde(default)]
    pub stops: Vec<GradientStop>,
    /// Nodes for freeform gradients. Empty for linear/radial.
    #[serde(default)]
    pub nodes: Vec<GradientNode>,
}

fn default_aspect_ratio() -> f64 {
    100.0
}

impl Default for Gradient {
    fn default() -> Self {
        Self {
            gtype: GradientType::default(),
            angle: 0.0,
            aspect_ratio: 100.0,
            method: GradientMethod::default(),
            dither: false,
            stroke_sub_mode: StrokeSubMode::default(),
            stops: Vec::new(),
            nodes: Vec::new(),
        }
    }
}

/// SVG fill presentation attribute.
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Fill {
    pub color: Color,
    pub opacity: f64,
}

impl Fill {
    pub const fn new(color: Color) -> Self {
        Self { color, opacity: 1.0 }
    }
}

/// SVG stroke presentation attributes.
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Stroke {
    pub color: Color,
    pub width: f64,
    pub linecap: LineCap,
    pub linejoin: LineJoin,
    pub miter_limit: f64,
    pub align: StrokeAlign,
    /// Dash pattern as fixed-size array (up to 6 values: 3 dash/gap pairs).
    /// Unused slots are 0.0. `dash_len` indicates how many values are active.
    pub dash_pattern: [f64; 6],
    pub dash_len: u8,
    /// When true, per-segment dash and gap lengths flex so a dash is
    /// centered on every anchor and a full dash sits at each open path
    /// end. When false (default), the dash pattern lays out by exact
    /// length along the path. See DASH_ALIGN.md.
    pub dash_align_anchors: bool,
    pub start_arrow: Arrowhead,
    pub end_arrow: Arrowhead,
    pub start_arrow_scale: f64,
    pub end_arrow_scale: f64,
    pub arrow_align: ArrowAlign,
    pub opacity: f64,
}

impl Stroke {
    pub fn new(color: Color, width: f64) -> Self {
        Self {
            color,
            width,
            linecap: LineCap::Butt,
            linejoin: LineJoin::Miter,
            miter_limit: 10.0,
            align: StrokeAlign::Center,
            dash_pattern: [0.0; 6],
            dash_len: 0,
            dash_align_anchors: false,
            start_arrow: Arrowhead::None,
            end_arrow: Arrowhead::None,
            start_arrow_scale: 100.0,
            end_arrow_scale: 100.0,
            arrow_align: ArrowAlign::TipAtEnd,
            opacity: 1.0,
        }
    }

    /// Get the active dash array slice, or empty if no dashing.
    pub fn dash_array(&self) -> &[f64] {
        &self.dash_pattern[..self.dash_len as usize]
    }
}

/// SVG transform as a 2D affine matrix [a b c d e f].
///
/// Represents the matrix:
///     | a c e |
///     | b d f |
///     | 0 0 1 |
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
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

    /// Return a new transform equal to `translate(dx, dy) * self`
    /// — i.e., this transform with a world-space translation of
    /// (dx, dy) pre-pended. The rotation / scale components of
    /// `self` are preserved; only `e` and `f` change.
    ///
    /// Used by the Align panel operations per ALIGN.md §SVG
    /// attribute mapping: moving an element adds (dx, dy) to its
    /// existing transforms translation in world coordinates,
    /// regardless of any rotation or scale it already carries.
    pub fn translated(self, dx: f64, dy: f64) -> Self {
        Self { e: self.e + dx, f: self.f + dy, ..self }
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

    /// Apply this transform to a point, returning the transformed point.
    pub fn apply_point(&self, x: f64, y: f64) -> (f64, f64) {
        (self.a * x + self.c * y + self.e,
         self.b * x + self.d * y + self.f)
    }

    /// Return the inverse transform, or `None` if the matrix is singular.
    pub fn inverse(&self) -> Option<Self> {
        let det = self.a * self.d - self.b * self.c;
        if det.abs() < 1e-12 {
            return None;
        }
        let inv_det = 1.0 / det;
        Some(Self {
            a: self.d * inv_det,
            b: -self.b * inv_det,
            c: -self.c * inv_det,
            d: self.a * inv_det,
            e: (self.c * self.f - self.d * self.e) * inv_det,
            f: (self.b * self.e - self.a * self.f) * inv_det,
        })
    }

    /// Shear matrix with horizontal shear factor `kx` (x ← x + kx·y)
    /// and vertical shear factor `ky` (y ← y + ky·x).
    pub fn shear(kx: f64, ky: f64) -> Self {
        Self {
            a: 1.0,
            b: ky,
            c: kx,
            d: 1.0,
            e: 0.0,
            f: 0.0,
        }
    }

    /// Return `self * other` — the matrix that applies `other` first,
    /// then `self`. Equivalent to: for any point p,
    /// `self.then(other).apply_point(p) == self.apply_point(other.apply_point(p))`
    /// when read as `composed = self ∘ other`.
    pub fn multiply(&self, other: &Self) -> Self {
        Self {
            a: self.a * other.a + self.c * other.b,
            b: self.b * other.a + self.d * other.b,
            c: self.a * other.c + self.c * other.d,
            d: self.b * other.c + self.d * other.d,
            e: self.a * other.e + self.c * other.f + self.e,
            f: self.b * other.e + self.d * other.f + self.f,
        }
    }

    /// Conjugate this transform around the point `(rx, ry)` —
    /// returns `T(rx, ry) * self * T(-rx, -ry)`. The result, when
    /// applied to any point, behaves as if `self` were applied with
    /// `(rx, ry)` as the origin.
    ///
    /// Used by the transform-tool family (Scale, Rotate, Shear) to
    /// pivot a base transform around the user-set reference point.
    pub fn around_point(&self, rx: f64, ry: f64) -> Self {
        let pre = Self::translate(-rx, -ry);
        let post = Self::translate(rx, ry);
        post.multiply(self).multiply(&pre)
    }
}

// ---------------------------------------------------------------------------
// SVG path commands (the 'd' attribute)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
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

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
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
    /// A non-destructive element whose geometry is evaluated on demand
    /// from its source inputs. See `super::live::LiveVariant`.
    Live(super::live::LiveVariant),
}

/// Per-element visibility mode.
///
/// Ordered from maximum visibility (`Preview`) to minimum
/// (`Invisible`). The `Ord` derivation makes `min(a, b)` produce the
/// more restrictive of two modes, which is the rule used to combine
/// an element's own visibility with the capping visibility inherited
/// from its parent Group or Layer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, serde::Serialize, serde::Deserialize)]
#[derive(Default)]
pub enum Visibility {
    /// Not rendered; cannot be selected or hit-tested.
    Invisible,
    /// Drawn as a thin black outline (stroke width 0, no fill). Hit
    /// detection ignores fill and stroke width. Text is the single
    /// exception: Text in outline mode still renders as Preview.
    Outline,
    /// Element is fully drawn with its fill, stroke, and effects.
    #[default]
    Preview,
}


/// Blend mode for compositing an element against its parent layer.
/// Values mirror the Opacity panel's mode dropdown and serialize as
/// snake_case to match opacity.yaml mode ids (e.g. `color_burn`,
/// `soft_light`). Default is `Normal` (no compositing effect).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash,
         serde::Serialize, serde::Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum BlendMode {
    #[default]
    Normal,
    Darken,
    Multiply,
    ColorBurn,
    Lighten,
    Screen,
    ColorDodge,
    Overlay,
    SoftLight,
    HardLight,
    Difference,
    Exclusion,
    Hue,
    Saturation,
    Color,
    Luminosity,
}


/// An opacity mask attached to an element. See OPACITY.md § Document model.
/// The mask subtree carries the artwork whose luminance drives the element's
/// alpha at compositing time. Storage-only in Phase 3a — renderer wiring,
/// MAKE_MASK_BUTTON, CLIP_CHECKBOX, INVERT_MASK_CHECKBOX, LINK_INDICATOR,
/// and the disable/unlink menu items land in Phase 3b.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Mask {
    /// Artwork whose luminance drives the element's alpha.
    pub subtree: Box<Element>,
    /// When true, the mask also clips the element to its bounds.
    pub clip: bool,
    /// When true, the luminance mapping is inverted (light becomes opaque).
    pub invert: bool,
    /// When true, the element renders as if no mask were attached. The mask
    /// subtree is preserved so re-enabling restores the prior state.
    #[serde(default)]
    pub disabled: bool,
    /// When true, mask transforms follow the element's transform.
    /// When false, the mask uses `unlink_transform` as its fixed baseline.
    #[serde(default = "default_mask_linked")]
    pub linked: bool,
    /// Captured at unlink time: the element's transform when the link was
    /// broken. Used as the mask's effective transform while `linked` is
    /// false. Cleared on relink.
    #[serde(default)]
    pub unlink_transform: Option<Transform>,
}

fn default_mask_linked() -> bool { true }

/// Common properties shared by all visible elements.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct CommonProps {
    pub opacity: f64,
    #[serde(default)]
    pub mode: BlendMode,
    pub transform: Option<Transform>,
    pub locked: bool,
    pub visibility: Visibility,
    /// Optional opacity mask attached to this element. When `None`, the
    /// element composites normally. When `Some(_)`, the mask's artwork
    /// modulates alpha per OPACITY.md. Storage-only in Phase 3a.
    #[serde(default)]
    pub mask: Option<Box<Mask>>,
    /// Optional `jas:tool-origin` tag identifying the tool that
    /// produced this element. Blob Brush sets `"blob_brush"` on its
    /// commits so subsequent sweeps can merge / erase into the same
    /// element. Preserved by mutations; optional on export.
    /// See BLOB_BRUSH_TOOL.md §Fill and stroke.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_origin: Option<String>,
}

impl Default for CommonProps {
    fn default() -> Self {
        Self {
            opacity: 1.0,
            mode: BlendMode::Normal,
            transform: None,
            locked: false,
            visibility: Visibility::Preview,
            mask: None,
            tool_origin: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct LineElem {
    pub x1: f64,
    pub y1: f64,
    pub x2: f64,
    pub y2: f64,
    pub stroke: Option<Stroke>,
    pub width_points: Vec<StrokeWidthPoint>,
    pub common: CommonProps,
    /// Optional gradient applied to the stroke (in lieu of `stroke.color`).
    /// Phase 1b adds gradient paint per-element rather than nested in
    /// Stroke to avoid removing Copy from Stroke. See GRADIENT.md
    /// §Document model.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stroke_gradient: Option<Box<Gradient>>,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fill_gradient: Option<Box<Gradient>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stroke_gradient: Option<Box<Gradient>>,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct CircleElem {
    pub cx: f64,
    pub cy: f64,
    pub r: f64,
    pub fill: Option<Fill>,
    pub stroke: Option<Stroke>,
    pub common: CommonProps,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fill_gradient: Option<Box<Gradient>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stroke_gradient: Option<Box<Gradient>>,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct EllipseElem {
    pub cx: f64,
    pub cy: f64,
    pub rx: f64,
    pub ry: f64,
    pub fill: Option<Fill>,
    pub stroke: Option<Stroke>,
    pub common: CommonProps,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fill_gradient: Option<Box<Gradient>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stroke_gradient: Option<Box<Gradient>>,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct PolylineElem {
    pub points: Vec<(f64, f64)>,
    pub fill: Option<Fill>,
    pub stroke: Option<Stroke>,
    pub common: CommonProps,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fill_gradient: Option<Box<Gradient>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stroke_gradient: Option<Box<Gradient>>,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct PolygonElem {
    pub points: Vec<(f64, f64)>,
    pub fill: Option<Fill>,
    pub stroke: Option<Stroke>,
    pub common: CommonProps,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fill_gradient: Option<Box<Gradient>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stroke_gradient: Option<Box<Gradient>>,
}

#[derive(Debug, Clone, Default, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct PathElem {
    pub d: Vec<PathCommand>,
    pub fill: Option<Fill>,
    pub stroke: Option<Stroke>,
    pub width_points: Vec<StrokeWidthPoint>,
    pub common: CommonProps,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fill_gradient: Option<Box<Gradient>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stroke_gradient: Option<Box<Gradient>>,
    /// Active-brush reference as "<library_slug>/<brush_slug>", or
    /// None for a plain native-stroke path. Consumed by the
    /// Calligraphic outliner in the canvas renderer. See
    /// transcripts/BRUSHES.md §Stroke styling interaction.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stroke_brush: Option<String>,
    /// Per-instance brush-parameter overrides as a compact JSON
    /// object layered over the master brush at render time. Phase 1
    /// stored as a JSON string so the interpreter's typed
    /// set-effect machinery can round-trip it. See BRUSHES.md
    /// §Panel state.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stroke_brush_overrides: Option<String>,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct TextElem {
    pub x: f64,
    pub y: f64,
    /// Ordered, non-empty list of tspans. The derived text content is the
    /// concatenation of each tspan's `content`; use `content()` to read it.
    /// See TSPAN.md.
    pub tspans: Vec<crate::geometry::tspan::Tspan>,
    pub font_family: String,
    pub font_size: f64,
    pub font_weight: String,
    pub font_style: String,
    pub text_decoration: String,
    /// CSS `text-transform` — `"uppercase"` for All Caps, `"lowercase"`,
    /// or empty (none). Per CHARACTER.md SVG-attribute mapping.
    #[serde(default)]
    pub text_transform: String,
    /// CSS `font-variant` — `"small-caps"` for Small Caps, or empty.
    #[serde(default)]
    pub font_variant: String,
    /// CSS `baseline-shift` — `"super"`, `"sub"`, a length, or empty.
    /// Mutually exclusive super/sub are enforced at the panel layer.
    #[serde(default)]
    pub baseline_shift: String,
    /// CSS `line-height` — e.g. `"14.4pt"`, or empty for Auto
    /// (inherits 120% × font-size). Panel field: Leading.
    #[serde(default)]
    pub line_height: String,
    /// CSS `letter-spacing` — e.g. `"0.025em"`, or empty for 0.
    /// Panel field: Tracking, value is (panel.tracking / 1000) em.
    #[serde(default)]
    pub letter_spacing: String,
    /// SVG `xml:lang` — ISO 639-1 language code, or empty. Used for
    /// hyphenation and line-breaking. Panel field: Language.
    #[serde(default)]
    pub xml_lang: String,
    /// Jas custom anti-alias mode — `"None"`, `"Sharp"`, `"Crisp"`,
    /// `"Strong"`, `"Smooth"`, or empty. Emitted as the custom SVG
    /// attribute `urn:jas:1:aa-mode`; also maps to CSS `text-rendering`
    /// on export. Panel field: Anti-aliasing.
    #[serde(default)]
    pub aa_mode: String,
    /// Character rotation in degrees (SVG `rotate` attribute on the
    /// text element). Signed; positive = clockwise per SVG. Empty =
    /// identity (0°). Panel field: Character rotation.
    #[serde(default)]
    pub rotate: String,
    /// Horizontal glyph scale, percent. Identity (100) = empty so the
    /// attribute is omitted. Panel field: Horizontal scale.
    #[serde(default)]
    pub horizontal_scale: String,
    /// Vertical glyph scale, percent. Identity (100) = empty so the
    /// attribute is omitted. Panel field: Vertical scale.
    #[serde(default)]
    pub vertical_scale: String,
    /// Kerning adjustment — stored verbatim as the value of the
    /// `urn:jas:1:kerning-mode` custom attribute. Named modes
    /// (`"Auto"`, `"Optical"`, `"Metrics"`) or a length like
    /// `"0.025em"`. Empty = Auto (default). Panel field: Kerning.
    #[serde(default)]
    pub kerning: String,
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

    /// Derived content: the concatenation of each tspan's `content` in
    /// reading order. Replaces the previous flat `content: String` field.
    pub fn content(&self) -> String {
        crate::geometry::tspan::concat_content(&self.tspans)
    }

    /// Construct a `TextElem` holding a single default tspan whose
    /// `content` is the provided string. Convenience factory for callers
    /// that build text with a flat string (Type Tool, SVG import of
    /// `<text>` without `<tspan>` children, legacy construction).
    pub fn from_string(
        x: f64,
        y: f64,
        content: impl Into<String>,
        font_family: impl Into<String>,
        font_size: f64,
        font_weight: impl Into<String>,
        font_style: impl Into<String>,
        text_decoration: impl Into<String>,
        width: f64,
        height: f64,
        fill: Option<Fill>,
        stroke: Option<Stroke>,
        common: CommonProps,
    ) -> Self {
        let t = crate::geometry::tspan::Tspan {
            content: content.into(),
            ..crate::geometry::tspan::Tspan::default_tspan()
        };
        Self {
            x,
            y,
            tspans: vec![t],
            font_family: font_family.into(),
            font_size,
            font_weight: font_weight.into(),
            font_style: font_style.into(),
            text_decoration: text_decoration.into(),
            text_transform: String::new(),
            font_variant: String::new(),
            baseline_shift: String::new(),
            line_height: String::new(),
            letter_spacing: String::new(),
            xml_lang: String::new(),
            aa_mode: String::new(),
            rotate: String::new(),
            horizontal_scale: String::new(),
            vertical_scale: String::new(),
            kerning: String::new(),
            width,
            height,
            fill,
            stroke,
            common,
        }
    }
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct TextPathElem {
    pub d: Vec<PathCommand>,
    /// See `TextElem::tspans`. The `content()` accessor returns the
    /// concatenation.
    pub tspans: Vec<crate::geometry::tspan::Tspan>,
    pub start_offset: f64,
    pub font_family: String,
    pub font_size: f64,
    pub font_weight: String,
    pub font_style: String,
    pub text_decoration: String,
    /// See `TextElem::text_transform`.
    #[serde(default)]
    pub text_transform: String,
    /// See `TextElem::font_variant`.
    #[serde(default)]
    pub font_variant: String,
    /// See `TextElem::baseline_shift`.
    #[serde(default)]
    pub baseline_shift: String,
    /// See `TextElem::line_height`.
    #[serde(default)]
    pub line_height: String,
    /// See `TextElem::letter_spacing`.
    #[serde(default)]
    pub letter_spacing: String,
    /// See `TextElem::xml_lang`.
    #[serde(default)]
    pub xml_lang: String,
    /// See `TextElem::aa_mode`.
    #[serde(default)]
    pub aa_mode: String,
    /// See `TextElem::rotate`.
    #[serde(default)]
    pub rotate: String,
    /// See `TextElem::horizontal_scale`.
    #[serde(default)]
    pub horizontal_scale: String,
    /// See `TextElem::vertical_scale`.
    #[serde(default)]
    pub vertical_scale: String,
    /// See `TextElem::kerning`.
    #[serde(default)]
    pub kerning: String,
    pub fill: Option<Fill>,
    pub stroke: Option<Stroke>,
    pub common: CommonProps,
}

impl TextPathElem {
    pub fn content(&self) -> String {
        crate::geometry::tspan::concat_content(&self.tspans)
    }

    pub fn from_string(
        d: Vec<PathCommand>,
        content: impl Into<String>,
        start_offset: f64,
        font_family: impl Into<String>,
        font_size: f64,
        font_weight: impl Into<String>,
        font_style: impl Into<String>,
        text_decoration: impl Into<String>,
        fill: Option<Fill>,
        stroke: Option<Stroke>,
        common: CommonProps,
    ) -> Self {
        let t = crate::geometry::tspan::Tspan {
            content: content.into(),
            ..crate::geometry::tspan::Tspan::default_tspan()
        };
        Self {
            d,
            tspans: vec![t],
            start_offset,
            font_family: font_family.into(),
            font_size,
            font_weight: font_weight.into(),
            font_style: font_style.into(),
            text_decoration: text_decoration.into(),
            text_transform: String::new(),
            font_variant: String::new(),
            baseline_shift: String::new(),
            line_height: String::new(),
            letter_spacing: String::new(),
            xml_lang: String::new(),
            aa_mode: String::new(),
            rotate: String::new(),
            horizontal_scale: String::new(),
            vertical_scale: String::new(),
            kerning: String::new(),
            fill,
            stroke,
            common,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Default, serde::Serialize, serde::Deserialize)]
pub struct GroupElem {
    pub children: Vec<Rc<Element>>,
    pub common: CommonProps,
    /// When true, children composite in isolation from elements outside the
    /// group (Opacity panel, Page Isolated Blending). Storage-only in
    /// Phase 2; renderer support is deferred. Default `false`.
    #[serde(default)]
    pub isolated_blending: bool,
    /// When true, children of this group punch through underlying elements
    /// rather than blending with them (Opacity panel, Page Knockout Group).
    /// Storage-only in Phase 2; renderer support is deferred. Default `false`.
    #[serde(default)]
    pub knockout_group: bool,
}

#[derive(Debug, Clone, PartialEq, Default, serde::Serialize, serde::Deserialize)]
pub struct LayerElem {
    pub name: String,
    pub children: Vec<Rc<Element>>,
    pub common: CommonProps,
    /// See [`GroupElem::isolated_blending`]. Present on layers so the
    /// document root (a Layer) can carry the flag today; per-group UI
    /// exposure is deferred.
    #[serde(default)]
    pub isolated_blending: bool,
    /// See [`GroupElem::knockout_group`].
    #[serde(default)]
    pub knockout_group: bool,
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
            Element::Live(e) => super::live::LiveElement::common(e),
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
            Element::Live(e) => super::live::LiveElement::common_mut(e),
        }
    }

    pub fn locked(&self) -> bool {
        self.common().locked
    }

    pub fn visibility(&self) -> Visibility {
        self.common().visibility
    }

    pub fn opacity(&self) -> f64 {
        self.common().opacity
    }

    pub fn mode(&self) -> BlendMode {
        self.common().mode
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
            Element::Live(e) => super::live::LiveElement::fill(e),
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
            Element::Live(e) => super::live::LiveElement::stroke(e),
            _ => None,
        }
    }

    /// Return the optional gradient applied to the element's fill, if any.
    /// Phase 1b: lives directly on each Element variant rather than nested
    /// inside Fill — see GRADIENT.md §Document model.
    pub fn fill_gradient(&self) -> Option<&Gradient> {
        match self {
            Element::Rect(e) => e.fill_gradient.as_deref(),
            Element::Circle(e) => e.fill_gradient.as_deref(),
            Element::Ellipse(e) => e.fill_gradient.as_deref(),
            Element::Polyline(e) => e.fill_gradient.as_deref(),
            Element::Polygon(e) => e.fill_gradient.as_deref(),
            Element::Path(e) => e.fill_gradient.as_deref(),
            _ => None,
        }
    }

    /// Return the optional gradient applied to the element's stroke, if any.
    pub fn stroke_gradient(&self) -> Option<&Gradient> {
        match self {
            Element::Line(e) => e.stroke_gradient.as_deref(),
            Element::Rect(e) => e.stroke_gradient.as_deref(),
            Element::Circle(e) => e.stroke_gradient.as_deref(),
            Element::Ellipse(e) => e.stroke_gradient.as_deref(),
            Element::Polyline(e) => e.stroke_gradient.as_deref(),
            Element::Polygon(e) => e.stroke_gradient.as_deref(),
            Element::Path(e) => e.stroke_gradient.as_deref(),
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
                    // The canvas renderer treats `e.y` as the top edge of
                    // the text run (baseline at e.y + 0.8*font_size). The
                    // bounding box must therefore extend *downward* from
                    // e.y, not upward. Hard line breaks in the content
                    // grow the box vertically and the width is the widest
                    // line, measured with the real font (via the shared
                    // hidden-canvas measurer in-browser, falling back to
                    // a 0.55*font_size stub on host/cargo-test).
                    let content_str = e.content();
                    let lines: Vec<&str> = if content_str.is_empty() {
                        vec![""]
                    } else {
                        content_str.split('\n').collect()
                    };
                    #[cfg(feature = "web")]
                    let max_width = {
                        let font = crate::tools::text_measure::font_string(
                            &e.font_style, &e.font_weight, e.font_size, &e.font_family);
                        let measure = crate::tools::text_measure::make_measurer(&font, e.font_size);
                        lines.iter().map(|l| measure(l)).fold(0.0_f64, f64::max)
                    };
                    #[cfg(not(feature = "web"))]
                    let max_width = lines
                        .iter()
                        .map(|l| l.len() as f64 * e.font_size * APPROX_CHAR_WIDTH_FACTOR)
                        .fold(0.0_f64, f64::max);
                    let height = lines.len() as f64 * e.font_size;
                    (e.x, e.y, max_width, height)
                }
            }
            Element::TextPath(e) => inflate_bounds(path_bounds(&e.d), e.stroke.as_ref()),
            Element::Group(g) => children_bounds(&g.children),
            Element::Layer(l) => children_bounds(&l.children),
            Element::Live(e) => super::live::LiveElement::bounds(e),
        }
    }

    /// Return the geometric bounding box — the bbox of the path /
    /// shape geometry alone, ignoring stroke width. Used by Align
    /// operations when Use Preview Bounds is off (the default) per
    /// ALIGN.md §Bounding box selection.
    pub fn geometric_bounds(&self) -> Bounds {
        match self {
            Element::Line(e) => {
                let min_x = e.x1.min(e.x2);
                let min_y = e.y1.min(e.y2);
                (min_x, min_y, (e.x2 - e.x1).abs(), (e.y2 - e.y1).abs())
            }
            Element::Rect(e) => (e.x, e.y, e.width, e.height),
            Element::Circle(e) => (e.cx - e.r, e.cy - e.r, e.r * 2.0, e.r * 2.0),
            Element::Ellipse(e) => (e.cx - e.rx, e.cy - e.ry, e.rx * 2.0, e.ry * 2.0),
            Element::Polyline(e) => points_bounds(&e.points, None),
            Element::Polygon(e) => points_bounds(&e.points, None),
            Element::Path(e) => path_bounds(&e.d),
            Element::Text(_) | Element::TextPath(_) => {
                // Text has no stroke inflation today; preview and
                // geometric bounds are equivalent.
                self.bounds()
            }
            Element::Group(g) => geometric_children_bounds(&g.children),
            Element::Layer(l) => geometric_children_bounds(&l.children),
            // Phase 1 stub: geometric bounds match bounds (no stroke
            // inflation distinction until compound shapes evaluate).
            Element::Live(e) => super::live::LiveElement::bounds(e),
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

fn geometric_children_bounds(children: &[Rc<Element>]) -> Bounds {
    if children.is_empty() {
        return (0.0, 0.0, 0.0, 0.0);
    }
    let all: Vec<Bounds> = children.iter().map(|c| c.geometric_bounds()).collect();
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

/// Flatten path commands into one polyline per subpath, suitable for
/// use as boolean-operation operand rings under the even-odd fill
/// rule. Each MoveTo starts a new ring; each ClosePath finalizes the
/// current ring. Open subpaths (no ClosePath) are implicitly closed
/// by the boolean algorithm consuming the first and last points.
/// Rings with fewer than 3 points are dropped.
///
/// Uses the same fixed per-curve step count as `flatten_path_commands`.
/// Precision-adaptive subdivision is a future enhancement.
pub fn flatten_path_to_rings(d: &[PathCommand]) -> Vec<Vec<(f64, f64)>> {
    let steps = FLATTEN_STEPS;
    let mut rings: Vec<Vec<(f64, f64)>> = Vec::new();
    let mut cur: Vec<(f64, f64)> = Vec::new();
    let mut cx = 0.0_f64;
    let mut cy = 0.0_f64;

    let flush_cur = |cur: &mut Vec<(f64, f64)>, rings: &mut Vec<Vec<(f64, f64)>>| {
        if cur.len() >= 3 {
            rings.push(std::mem::take(cur));
        } else {
            cur.clear();
        }
    };

    for cmd in d {
        match cmd {
            PathCommand::MoveTo { x, y } => {
                flush_cur(&mut cur, &mut rings);
                cur.push((*x, *y));
                cx = *x;
                cy = *y;
            }
            PathCommand::LineTo { x, y } => {
                cur.push((*x, *y));
                cx = *x;
                cy = *y;
            }
            PathCommand::CurveTo { x1, y1, x2, y2, x, y } => {
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
                    cur.push((px, py));
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
                    cur.push((px, py));
                }
                cx = *x;
                cy = *y;
            }
            PathCommand::ClosePath => {
                flush_cur(&mut cur, &mut rings);
            }
            PathCommand::SmoothCurveTo { x, y, .. }
            | PathCommand::SmoothQuadTo { x, y }
            | PathCommand::ArcTo { x, y, .. } => {
                cur.push((*x, *y));
                cx = *x;
                cy = *y;
            }
        }
    }
    flush_cur(&mut cur, &mut rings);
    rings
}

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

use crate::document::document::SelectionKind;

/// Return a new element with the specified control points moved by (dx, dy).
///
/// `kind == SelectionKind::All` translates the whole element in-place
/// (preserving its primitive type). `Partial(s)` moves only the listed
/// CPs and may convert Rect/Circle/Ellipse into a Polygon when the
/// resulting shape is no longer axis-aligned.
///
/// `Partial(empty)` — "element selected, no CPs highlighted" — is a
/// no-op: the element is returned unchanged. Without this guard, the
/// Rect/Circle/Ellipse branches would fall through to their polygon-
/// conversion path (since `is_all(n)` is false for an empty set) and
/// silently change the primitive type without any visible movement.
pub fn move_control_points(
    elem: &Element,
    kind: &SelectionKind,
    dx: f64,
    dy: f64,
) -> Element {
    if let SelectionKind::Partial(s) = kind
        && s.is_empty() {
            return elem.clone();
        }
    match elem {
        Element::Line(e) => {
            let mut new = e.clone();
            if kind.contains(0) {
                new.x1 += dx;
                new.y1 += dy;
            }
            if kind.contains(1) {
                new.x2 += dx;
                new.y2 += dy;
            }
            Element::Line(new)
        }
        Element::Rect(e) => {
            if kind.is_all(4) {
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
                    if kind.contains(i) {
                        pts[i].0 += dx;
                        pts[i].1 += dy;
                    }
                }
                Element::Polygon(PolygonElem {
                    points: pts,
                    fill: e.fill,
                    stroke: e.stroke,
                    common: e.common.clone(),
                                    fill_gradient: None,
                    stroke_gradient: None,
                })
            }
        }
        Element::Circle(e) => {
            if kind.is_all(4) {
                let mut new = e.clone();
                new.cx += dx;
                new.cy += dy;
                Element::Circle(new)
            } else {
                let mut cps = [(e.cx, e.cy - e.r),
                    (e.cx + e.r, e.cy),
                    (e.cx, e.cy + e.r),
                    (e.cx - e.r, e.cy)];
                for i in 0..4 {
                    if kind.contains(i) {
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
            if kind.is_all(4) {
                let mut new = e.clone();
                new.cx += dx;
                new.cy += dy;
                Element::Ellipse(new)
            } else {
                let mut cps = [(e.cx, e.cy - e.ry),
                    (e.cx + e.rx, e.cy),
                    (e.cx, e.cy + e.ry),
                    (e.cx - e.rx, e.cy)];
                for i in 0..4 {
                    if kind.contains(i) {
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
                if kind.contains(i) {
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
            let new_d = move_path_command_points(&e.d, kind, dx, dy);
            Element::Path(PathElem {
                d: new_d,
                ..e.clone()
            })
        }
        Element::TextPath(e) => {
            let new_d = move_path_command_points(&e.d, kind, dx, dy);
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
            if ci + 1 < d.len()
                && let PathCommand::CurveTo { x1: nx1, y1: ny1, x2: nx2, y2: ny2, x: nx, y: ny } = d[ci + 1] {
                    let (rx, ry) = reflect_handle_keep_distance(ax, ay, new_hx, new_hy, nx1, ny1);
                    new_cmds[ci + 1] = PathCommand::CurveTo { x1: rx, y1: ry, x2: nx2, y2: ny2, x: nx, y: ny };
                }
        }
    } else if handle_type == "out"
        && ci + 1 < d.len()
            && let PathCommand::CurveTo { x1: nx1, y1: ny1, x2: nx2, y2: ny2, x: nx, y: ny } = d[ci + 1] {
                let new_hx = nx1 + dx;
                let new_hy = ny1 + dy;
                new_cmds[ci + 1] = PathCommand::CurveTo { x1: new_hx, y1: new_hy, x2: nx2, y2: ny2, x: nx, y: ny };
                // Rotate opposite (in) handle
                if let PathCommand::CurveTo { x1, y1, x2, y2, x, y } = d[ci] {
                    let (rx, ry) = reflect_handle_keep_distance(ax, ay, new_hx, new_hy, x2, y2);
                    new_cmds[ci] = PathCommand::CurveTo { x1, y1, x2: rx, y2: ry, x, y };
                }
            }

    PathElem { d: new_cmds, ..elem.clone() }
}

/// Move a single handle without reflecting the opposite handle (cusp behavior).
pub fn move_path_handle_independent(
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

    let mut new_cmds = d.clone();

    if handle_type == "in" {
        if let PathCommand::CurveTo { x1, y1, x2, y2, x, y } = d[ci] {
            new_cmds[ci] = PathCommand::CurveTo { x1, y1, x2: x2 + dx, y2: y2 + dy, x, y };
        }
    } else if handle_type == "out"
        && ci + 1 < d.len()
            && let PathCommand::CurveTo { x1, y1, x2, y2, x, y } = d[ci + 1] {
                new_cmds[ci + 1] = PathCommand::CurveTo { x1: x1 + dx, y1: y1 + dy, x2, y2, x, y };
            }

    PathElem { d: new_cmds, ..elem.clone() }
}

/// Set a path handle to an absolute position without affecting the opposite handle.
pub fn set_path_handle_absolute(
    elem: &PathElem,
    anchor_idx: usize,
    handle_type: &str,
    hx: f64,
    hy: f64,
) -> PathElem {
    let d = &elem.d;
    let indices = cmd_indices_for_path(d);
    if anchor_idx >= indices.len() {
        return elem.clone();
    }
    let ci = indices[anchor_idx];

    let mut new_cmds = d.clone();

    if handle_type == "in" {
        if let PathCommand::CurveTo { x1, y1, x: ex, y: ey, .. } = d[ci] {
            new_cmds[ci] = PathCommand::CurveTo { x1, y1, x2: hx, y2: hy, x: ex, y: ey };
        }
    } else if handle_type == "out"
        && ci + 1 < d.len()
            && let PathCommand::CurveTo { x2, y2, x, y, .. } = d[ci + 1] {
                new_cmds[ci + 1] = PathCommand::CurveTo { x1: hx, y1: hy, x2, y2, x, y };
            }

    PathElem { d: new_cmds, ..elem.clone() }
}

/// Convert a corner point (LineTo or CurveTo with collapsed handles) to a smooth
/// point with symmetric handles pulled toward (hx, hy).
/// The outgoing handle is placed at (hx, hy) and the incoming handle is reflected.
pub fn convert_corner_to_smooth(
    elem: &PathElem,
    anchor_idx: usize,
    hx: f64,
    hy: f64,
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

    // Reflected handle: mirror (hx,hy) through (ax,ay)
    let rhx = 2.0 * ax - hx;
    let rhy = 2.0 * ay - hy;

    let mut new_cmds = d.clone();

    // Set incoming handle (x2,y2 on this command) to the reflected position
    match new_cmds[ci] {
        PathCommand::LineTo { x, y } => {
            new_cmds[ci] = PathCommand::CurveTo { x1: x, y1: y, x2: rhx, y2: rhy, x, y };
            // Also need to fix x1,y1: use the previous anchor's position
            if ci > 0 {
                let (px, py) = match d[ci - 1] {
                    PathCommand::MoveTo { x, y }
                    | PathCommand::LineTo { x, y }
                    | PathCommand::CurveTo { x, y, .. } => (x, y),
                    _ => (ax, ay),
                };
                if let PathCommand::CurveTo { ref mut x1, ref mut y1, .. } = new_cmds[ci] {
                    *x1 = px;
                    *y1 = py;
                }
            }
        }
        PathCommand::CurveTo { x1, y1, x, y, .. } => {
            new_cmds[ci] = PathCommand::CurveTo { x1, y1, x2: rhx, y2: rhy, x, y };
        }
        PathCommand::MoveTo { .. } => {
            // Can't set incoming handle on MoveTo, only outgoing
        }
        _ => {}
    }

    // Set outgoing handle (x1,y1 on the next command) to (hx,hy)
    if ci + 1 < new_cmds.len() {
        match new_cmds[ci + 1] {
            PathCommand::LineTo { x, y } => {
                // Need incoming handle for the next anchor too
                let (nx2, ny2) = (x, y);
                new_cmds[ci + 1] = PathCommand::CurveTo { x1: hx, y1: hy, x2: nx2, y2: ny2, x, y };
            }
            PathCommand::CurveTo { x2, y2, x, y, .. } => {
                new_cmds[ci + 1] = PathCommand::CurveTo { x1: hx, y1: hy, x2, y2, x, y };
            }
            _ => {}
        }
    }

    PathElem { d: new_cmds, ..elem.clone() }
}

/// Convert a smooth point to a corner point by collapsing both handles to the anchor.
pub fn convert_smooth_to_corner(
    elem: &PathElem,
    anchor_idx: usize,
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

    // Collapse incoming handle (x2,y2) to anchor
    if let PathCommand::CurveTo { x1, y1, x, y, .. } = new_cmds[ci] {
        new_cmds[ci] = PathCommand::CurveTo { x1, y1, x2: ax, y2: ay, x, y };
    }

    // Collapse outgoing handle (x1,y1 of next command) to anchor
    if ci + 1 < new_cmds.len()
        && let PathCommand::CurveTo { x2, y2, x, y, .. } = new_cmds[ci + 1] {
            new_cmds[ci + 1] = PathCommand::CurveTo { x1: ax, y1: ay, x2, y2, x, y };
        }

    PathElem { d: new_cmds, ..elem.clone() }
}

/// Check whether a path anchor is a "smooth" point (has non-degenerate handles).
pub fn is_smooth_point(d: &[PathCommand], anchor_idx: usize) -> bool {
    let (h_in, h_out) = path_handle_positions(d, anchor_idx);
    h_in.is_some() || h_out.is_some()
}

fn move_path_command_points(
    d: &[PathCommand],
    kind: &SelectionKind,
    dx: f64,
    dy: f64,
) -> Vec<PathCommand> {
    let mut new_cmds: Vec<PathCommand> = d.to_vec();
    let mut anchor_idx = 0usize;
    for ci in 0..d.len() {
        if matches!(d[ci], PathCommand::ClosePath) {
            continue;
        }
        if kind.contains(anchor_idx) {
            match d[ci] {
                PathCommand::MoveTo { x, y } => {
                    new_cmds[ci] = PathCommand::MoveTo {
                        x: x + dx,
                        y: y + dy,
                    };
                    // Move outgoing handle
                    if ci + 1 < d.len()
                        && let PathCommand::CurveTo {
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
                PathCommand::CurveTo {
                    x1: _, y1: _, x2, y2, x, y,
                } => {
                    // Preserve x1,y1 from new_cmds — a previous anchor's
                    // outgoing-handle logic may have already adjusted them.
                    let (cur_x1, cur_y1) = match new_cmds[ci] {
                        PathCommand::CurveTo { x1, y1, .. } => (x1, y1),
                        _ => unreachable!(),
                    };
                    new_cmds[ci] = PathCommand::CurveTo {
                        x1: cur_x1,
                        y1: cur_y1,
                        x2: x2 + dx,
                        y2: y2 + dy,
                        x: x + dx,
                        y: y + dy,
                    };
                    // Move outgoing handle
                    if ci + 1 < d.len()
                        && let PathCommand::CurveTo {
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
                PathCommand::LineTo { x, y } => {
                    new_cmds[ci] = PathCommand::LineTo {
                        x: x + dx,
                        y: y + dy,
                    };
                    // Move outgoing handle
                    if ci + 1 < d.len()
                        && let PathCommand::CurveTo {
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
        Element::Live(v) => match v {
            super::live::LiveVariant::CompoundShape(cs) => Element::Live(
                super::live::LiveVariant::CompoundShape(super::live::CompoundShape {
                    operands: cs.operands.iter()
                        .map(|c| Rc::new(translate_element(c, dx, dy)))
                        .collect(),
                    ..cs.clone()
                }),
            ),
        },
    }
}

/// Return a copy of the element with its `fill_gradient` replaced.
/// Elements that do not support a fill gradient (Line, Text, TextPath,
/// Group, Layer, Live) are returned unchanged.
pub fn with_fill_gradient(elem: &Element, gradient: Option<Box<Gradient>>) -> Element {
    match elem {
        Element::Rect(e) => Element::Rect(RectElem { fill_gradient: gradient, ..e.clone() }),
        Element::Circle(e) => Element::Circle(CircleElem { fill_gradient: gradient, ..e.clone() }),
        Element::Ellipse(e) => Element::Ellipse(EllipseElem { fill_gradient: gradient, ..e.clone() }),
        Element::Polyline(e) => Element::Polyline(PolylineElem { fill_gradient: gradient, ..e.clone() }),
        Element::Polygon(e) => Element::Polygon(PolygonElem { fill_gradient: gradient, ..e.clone() }),
        Element::Path(e) => Element::Path(PathElem { fill_gradient: gradient, ..e.clone() }),
        _ => elem.clone(),
    }
}

/// Return a copy of the element with its `stroke_gradient` replaced.
/// Elements that do not support a stroke gradient (Text, TextPath,
/// Group, Layer, Live) are returned unchanged.
pub fn with_stroke_gradient(elem: &Element, gradient: Option<Box<Gradient>>) -> Element {
    match elem {
        Element::Line(e) => Element::Line(LineElem { stroke_gradient: gradient, ..e.clone() }),
        Element::Rect(e) => Element::Rect(RectElem { stroke_gradient: gradient, ..e.clone() }),
        Element::Circle(e) => Element::Circle(CircleElem { stroke_gradient: gradient, ..e.clone() }),
        Element::Ellipse(e) => Element::Ellipse(EllipseElem { stroke_gradient: gradient, ..e.clone() }),
        Element::Polyline(e) => Element::Polyline(PolylineElem { stroke_gradient: gradient, ..e.clone() }),
        Element::Polygon(e) => Element::Polygon(PolygonElem { stroke_gradient: gradient, ..e.clone() }),
        Element::Path(e) => Element::Path(PathElem { stroke_gradient: gradient, ..e.clone() }),
        _ => elem.clone(),
    }
}

/// Return a copy of the element with its fill replaced.
/// Elements that do not support fill (Line, Group, Layer) are returned unchanged.
pub fn with_fill(elem: &Element, fill: Option<Fill>) -> Element {
    match elem {
        Element::Rect(e) => Element::Rect(RectElem { fill, ..e.clone() }),
        Element::Circle(e) => Element::Circle(CircleElem { fill, ..e.clone() }),
        Element::Ellipse(e) => Element::Ellipse(EllipseElem { fill, ..e.clone() }),
        Element::Polyline(e) => Element::Polyline(PolylineElem { fill, ..e.clone() }),
        Element::Polygon(e) => Element::Polygon(PolygonElem { fill, ..e.clone() }),
        Element::Path(e) => Element::Path(PathElem { fill, ..e.clone() }),
        Element::Text(e) => Element::Text(TextElem { fill, ..e.clone() }),
        Element::TextPath(e) => Element::TextPath(TextPathElem { fill, ..e.clone() }),
        Element::Line(_) | Element::Group(_) | Element::Layer(_) => elem.clone(),
        Element::Live(v) => match v {
            super::live::LiveVariant::CompoundShape(cs) => Element::Live(
                super::live::LiveVariant::CompoundShape(super::live::CompoundShape {
                    fill,
                    ..cs.clone()
                }),
            ),
        },
    }
}

/// Return a copy of the element with its stroke_brush replaced.
/// Only Path supports brushes today; other elements are returned
/// unchanged. See BRUSHES.md §Stroke styling interaction.
pub fn with_stroke_brush(elem: &Element, stroke_brush: Option<String>) -> Element {
    match elem {
        Element::Path(e) => Element::Path(PathElem { stroke_brush, ..e.clone() }),
        _ => elem.clone(),
    }
}

/// Return a copy of the element with its stroke_brush_overrides
/// replaced. Path-only, like with_stroke_brush.
pub fn with_stroke_brush_overrides(elem: &Element, overrides: Option<String>) -> Element {
    match elem {
        Element::Path(e) => Element::Path(PathElem { stroke_brush_overrides: overrides, ..e.clone() }),
        _ => elem.clone(),
    }
}

/// Return a copy of the element with its stroke replaced.
/// Elements that do not support stroke (Group, Layer) are returned unchanged.
pub fn with_stroke(elem: &Element, stroke: Option<Stroke>) -> Element {
    match elem {
        Element::Line(e) => Element::Line(LineElem { stroke, ..e.clone() }),
        Element::Rect(e) => Element::Rect(RectElem { stroke, ..e.clone() }),
        Element::Circle(e) => Element::Circle(CircleElem { stroke, ..e.clone() }),
        Element::Ellipse(e) => Element::Ellipse(EllipseElem { stroke, ..e.clone() }),
        Element::Polyline(e) => Element::Polyline(PolylineElem { stroke, ..e.clone() }),
        Element::Polygon(e) => Element::Polygon(PolygonElem { stroke, ..e.clone() }),
        Element::Path(e) => Element::Path(PathElem { stroke, ..e.clone() }),
        Element::Text(e) => Element::Text(TextElem { stroke, ..e.clone() }),
        Element::TextPath(e) => Element::TextPath(TextPathElem { stroke, ..e.clone() }),
        Element::Group(_) | Element::Layer(_) => elem.clone(),
        Element::Live(v) => match v {
            super::live::LiveVariant::CompoundShape(cs) => Element::Live(
                super::live::LiveVariant::CompoundShape(super::live::CompoundShape {
                    stroke,
                    ..cs.clone()
                }),
            ),
        },
    }
}

/// Set width profile points on an element (Line and Path only).
pub fn with_width_points(elem: &Element, width_points: Vec<StrokeWidthPoint>) -> Element {
    match elem {
        Element::Line(e) => Element::Line(LineElem { width_points, ..e.clone() }),
        Element::Path(e) => Element::Path(PathElem { width_points, ..e.clone() }),
        _ => elem.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gradient_json_roundtrip_linear() {
        let g = Gradient {
            gtype: GradientType::Linear,
            angle: 45.0,
            aspect_ratio: 100.0,
            method: GradientMethod::Classic,
            dither: false,
            stroke_sub_mode: StrokeSubMode::Within,
            stops: vec![
                GradientStop {
                    color: Color::rgb(1.0, 0.0, 0.0),
                    opacity: 100.0, location: 0.0, midpoint_to_next: 50.0,
                },
                GradientStop {
                    color: Color::rgb(0.0, 0.0, 1.0),
                    opacity: 100.0, location: 100.0, midpoint_to_next: 50.0,
                },
            ],
            nodes: Vec::new(),
        };
        let json = serde_json::to_string(&g).unwrap();
        let parsed: Gradient = serde_json::from_str(&json).unwrap();
        assert_eq!(g, parsed);
    }

    #[test]
    fn gradient_json_roundtrip_radial_with_midpoints_method_dither() {
        let g = Gradient {
            gtype: GradientType::Radial,
            angle: 0.0,
            aspect_ratio: 200.0,
            method: GradientMethod::Smooth,
            dither: true,
            stroke_sub_mode: StrokeSubMode::Across,
            stops: vec![
                GradientStop { color: Color::rgb(1.0, 1.0, 0.0), opacity: 100.0, location: 0.0,  midpoint_to_next: 30.0 },
                GradientStop { color: Color::rgb(0.5, 0.0, 0.5), opacity:  50.0, location: 50.0, midpoint_to_next: 70.0 },
                GradientStop { color: Color::rgb(0.0, 0.0, 0.0), opacity:   0.0, location: 100.0, midpoint_to_next: 50.0 },
            ],
            nodes: Vec::new(),
        };
        let json = serde_json::to_string(&g).unwrap();
        let parsed: Gradient = serde_json::from_str(&json).unwrap();
        assert_eq!(g, parsed);
    }

    #[test]
    fn gradient_json_roundtrip_freeform() {
        let g = Gradient {
            gtype: GradientType::Freeform,
            angle: 0.0,
            aspect_ratio: 100.0,
            method: GradientMethod::Points,
            dither: false,
            stroke_sub_mode: StrokeSubMode::Within,
            stops: Vec::new(),
            nodes: vec![
                GradientNode { x: 0.25, y: 0.25, color: Color::rgb(1.0, 0.0, 0.0), opacity: 100.0, spread: 30.0 },
                GradientNode { x: 0.75, y: 0.75, color: Color::rgb(0.0, 0.0, 1.0), opacity: 100.0, spread: 25.0 },
            ],
        };
        let json = serde_json::to_string(&g).unwrap();
        let parsed: Gradient = serde_json::from_str(&json).unwrap();
        assert_eq!(g, parsed);
    }

    #[test]
    fn gradient_serde_field_names() {
        // Verify wire format matches GRADIENT.md §Document model:
        // type → "linear"/"radial"/"freeform"; method → "classic"/"smooth"/"points"/"lines";
        // stroke_sub_mode → "within"/"along"/"across".
        let g = Gradient::default();
        let json = serde_json::to_string(&g).unwrap();
        assert!(json.contains(r#""type":"linear""#), "json={json}");
        assert!(json.contains(r#""method":"classic""#), "json={json}");
        assert!(json.contains(r#""stroke_sub_mode":"within""#), "json={json}");
    }

    #[test]
    fn rect_with_fill_gradient_roundtrips() {
        let g = Gradient {
            gtype: GradientType::Linear,
            angle: 45.0,
            aspect_ratio: 100.0,
            method: GradientMethod::Classic,
            dither: false,
            stroke_sub_mode: StrokeSubMode::Within,
            stops: vec![
                GradientStop { color: Color::rgb(1.0, 0.0, 0.0), opacity: 100.0, location: 0.0,   midpoint_to_next: 50.0 },
                GradientStop { color: Color::rgb(0.0, 0.0, 1.0), opacity: 100.0, location: 100.0, midpoint_to_next: 50.0 },
            ],
            nodes: Vec::new(),
        };
        let el = RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
            common: CommonProps::default(),
            fill_gradient: Some(Box::new(g.clone())),
            stroke_gradient: None,
        };
        let json = serde_json::to_string(&el).unwrap();
        // The gradient field is present in the JSON when set.
        assert!(json.contains("fill_gradient"));
        // stroke_gradient is omitted because it's None.
        assert!(!json.contains("stroke_gradient"));
        let parsed: RectElem = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.fill_gradient.as_deref(), Some(&g));
        assert!(parsed.stroke_gradient.is_none());
    }

    #[test]
    fn rect_without_gradient_omits_fields() {
        let el = RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        };
        let json = serde_json::to_string(&el).unwrap();
        assert!(!json.contains("fill_gradient"));
        assert!(!json.contains("stroke_gradient"));
        let parsed: RectElem = serde_json::from_str(&json).unwrap();
        assert!(parsed.fill_gradient.is_none());
        assert!(parsed.stroke_gradient.is_none());
    }

    #[test]
    fn gradient_stop_default_midpoint() {
        // midpoint_to_next defaults to 50 when absent on parse. Color uses
        // the same on-disk encoding as elsewhere in the document model
        // (see geometry::test_json::parse_color).
        let g = Gradient {
            stops: vec![GradientStop {
                color: Color::rgb(1.0, 0.0, 0.0),
                opacity: 100.0, location: 0.0, midpoint_to_next: 50.0,
            }],
            ..Gradient::default()
        };
        let json = serde_json::to_string(&g).unwrap();
        // Round-trips cleanly:
        let _: Gradient = serde_json::from_str(&json).unwrap();
        // And midpoint defaults if missing — synthesise a JSON without it
        // by string-replacing.
        let no_mid = json.replace(r#","midpoint_to_next":50.0"#, "");
        let parsed: Gradient = serde_json::from_str(&no_mid).unwrap();
        assert_eq!(parsed.stops[0].midpoint_to_next, 50.0);
    }

    fn rect(x: f64, y: f64, w: f64, h: f64) -> Element {
        Element::Rect(RectElem {
            x, y, width: w, height: h, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        })
    }

    fn line(x1: f64, y1: f64, x2: f64, y2: f64) -> Element {
        Element::Line(LineElem {
            x1, y1, x2, y2,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            width_points: Vec::new(),
            common: CommonProps::default(),
                    stroke_gradient: None,
        })
    }

    fn circle(cx: f64, cy: f64, r: f64) -> Element {
        Element::Circle(CircleElem {
            cx, cy, r,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        })
    }

    fn ellipse(cx: f64, cy: f64, rx: f64, ry: f64) -> Element {
        Element::Ellipse(EllipseElem {
            cx, cy, rx, ry,
            fill: None, stroke: None,
            common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        })
    }

    fn path_elem(d: Vec<PathCommand>) -> Element {
        Element::Path(PathElem {
            d, fill: None, stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            width_points: Vec::new(),
            common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
            stroke_brush: None,
            stroke_brush_overrides: None,
        })
    }

    fn group(children: Vec<Element>) -> Element {
        Element::Group(GroupElem {
            children: children.into_iter().map(Rc::new).collect(),
            isolated_blending: false,
            knockout_group: false,
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
            stroke: None, width_points: Vec::new(), common: CommonProps::default(),
                    stroke_gradient: None,
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

    // ── geometric_bounds vs bounds ───────────────────────────
    // geometric_bounds ignores stroke inflation; Align operations
    // read it when Use Preview Bounds is off (ALIGN.md §Bounding
    // box selection).

    #[test]
    fn geometric_bounds_ignores_stroke_inflation_on_line() {
        let e = line(0.0, 0.0, 50.0, 50.0);
        assert_eq!(e.geometric_bounds(), (0.0, 0.0, 50.0, 50.0));
    }

    #[test]
    fn geometric_bounds_rect_matches_raw_dimensions() {
        let e = rect(10.0, 20.0, 30.0, 40.0);
        assert_eq!(e.geometric_bounds(), (10.0, 20.0, 30.0, 40.0));
    }

    #[test]
    fn geometric_bounds_circle() {
        let e = circle(50.0, 50.0, 20.0);
        assert_eq!(e.geometric_bounds(), (30.0, 30.0, 40.0, 40.0));
    }

    #[test]
    fn geometric_bounds_ellipse() {
        let e = ellipse(50.0, 50.0, 30.0, 15.0);
        assert_eq!(e.geometric_bounds(), (20.0, 35.0, 60.0, 30.0));
    }

    #[test]
    fn geometric_bounds_group_unions_children_without_inflation() {
        let g = group(vec![
            rect(0.0, 0.0, 10.0, 10.0),
            rect(20.0, 20.0, 10.0, 10.0),
        ]);
        assert_eq!(g.geometric_bounds(), (0.0, 0.0, 30.0, 30.0));
    }

    #[test]
    fn geometric_bounds_matches_bounds_for_unstroked_shapes() {
        let e = circle(50.0, 50.0, 20.0);
        assert_eq!(e.geometric_bounds(), e.bounds());
    }

    #[test]
    fn geometric_bounds_narrower_than_preview_for_stroked_line() {
        let e = line(0.0, 0.0, 50.0, 50.0);
        let (_, _, gw, gh) = e.geometric_bounds();
        let (_, _, pw, ph) = e.bounds();
        assert!(pw > gw);
        assert!(ph > gh);
    }

    // ── Transform::translated ────────────────────────────────
    // Pre-pending a translation adds to (e, f) regardless of the
    // existing rotation / scale components. Used by Align ops.

    #[test]
    fn translated_on_identity_writes_into_e_f() {
        let t = Transform::IDENTITY.translated(10.0, 20.0);
        assert_eq!(t, Transform::translate(10.0, 20.0));
    }

    #[test]
    fn translated_on_existing_translate_accumulates() {
        let t = Transform::translate(5.0, 7.0).translated(10.0, -3.0);
        assert_eq!(t.e, 15.0);
        assert_eq!(t.f, 4.0);
    }

    #[test]
    fn translated_preserves_rotation_and_scale() {
        let t = Transform::rotate(90.0).translated(10.0, 20.0);
        let rot = Transform::rotate(90.0);
        assert_eq!(t.a, rot.a);
        assert_eq!(t.b, rot.b);
        assert_eq!(t.c, rot.c);
        assert_eq!(t.d, rot.d);
        assert_eq!(t.e, 10.0);
        assert_eq!(t.f, 20.0);
    }

    #[test]
    fn translated_zero_is_identity_change() {
        let t0 = Transform::rotate(45.0);
        let t1 = t0.translated(0.0, 0.0);
        assert_eq!(t0, t1);
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

    fn point_text(content: &str, x: f64, y: f64, font_size: f64) -> Element {
        Element::Text(TextElem::from_string(
            x, y, content,
            "sans-serif", font_size,
            "normal", "normal", "none",
            0.0, 0.0,
            Some(Fill::new(Color::BLACK)), None,
            CommonProps::default(),
        ))
    }

    #[test]
    fn point_text_bounds_extend_downward_from_y() {
        // The renderer treats `e.y` as the top edge of the text run, so
        // the bounding box must start at `e.y` and grow downward — not
        // sit above the text as it did historically.
        let e = point_text("hi", 100.0, 50.0, 16.0);
        let (bx, by, _bw, bh) = e.bounds();
        assert_eq!(bx, 100.0);
        assert_eq!(by, 50.0);
        assert_eq!(bh, 16.0);
    }

    #[test]
    fn point_text_bounds_grow_with_hard_line_breaks() {
        let one = point_text("a", 0.0, 0.0, 20.0);
        let two = point_text("a\nb", 0.0, 0.0, 20.0);
        let three = point_text("a\nb\nc", 0.0, 0.0, 20.0);
        let (_, _, _, h1) = one.bounds();
        let (_, _, _, h2) = two.bounds();
        let (_, _, _, h3) = three.bounds();
        assert_eq!(h1, 20.0);
        assert_eq!(h2, 40.0);
        assert_eq!(h3, 60.0);
    }

    #[test]
    fn point_text_bounds_width_uses_widest_line() {
        // 5-char line should dominate over the 2-char line.
        let e = point_text("hi\nhello", 0.0, 0.0, 10.0);
        let (_, _, w, _) = e.bounds();
        let one_line = point_text("hello", 0.0, 0.0, 10.0);
        let (_, _, w_ref, _) = one_line.bounds();
        assert_eq!(w, w_ref);
    }

    #[test]
    fn point_text_empty_content_still_has_one_line_height() {
        let e = point_text("", 0.0, 0.0, 18.0);
        let (_, _, _, h) = e.bounds();
        assert_eq!(h, 18.0);
    }

    #[test]
    fn point_text_bounds_width_matches_real_measurer_not_stub() {
        // Regression: the selection bounding box used to derive its
        // width from a fixed 0.6*font_size per-character stub
        // (APPROX_CHAR_WIDTH_FACTOR), which made the blue selection box
        // noticeably wider than the rendered glyphs. It must now come
        // from the same measurer the renderer and editor use.
        //
        // On host (cargo test) the measurer falls back to 0.55*font_size,
        // so we can pin the width to that value and verify it is not
        // using the old 0.6 stub.
        let font_size = 16.0;
        let content = "hello";
        let e = point_text(content, 0.0, 0.0, font_size);
        let (_, _, w, _) = e.bounds();
        let expected = content.chars().count() as f64 * font_size * 0.55;
        assert!(
            (w - expected).abs() < 1e-9,
            "expected w = {expected} (0.55*font_size per char, matching \
             the shared measurer), got {w}"
        );
        // And it must *not* equal the old stub based on APPROX_CHAR_WIDTH_FACTOR.
        let old_stub = content.chars().count() as f64 * font_size * APPROX_CHAR_WIDTH_FACTOR;
        assert!(
            (w - old_stub).abs() > 1e-6,
            "width ({w}) matches the old APPROX_CHAR_WIDTH_FACTOR stub \
             ({old_stub}); bounds() is still using the stub instead of \
             the real measurer"
        );
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

    // --- Color space conversion tests ---

    const EPS: f64 = 1e-10;

    fn assert_near(a: f64, b: f64, label: &str) {
        assert!((a - b).abs() < EPS, "{label}: expected {b}, got {a}");
    }

    // -- Constructors & alpha --

    #[test]
    fn color_rgb_constructor() {
        let c = Color::rgb(0.2, 0.4, 0.6);
        assert!(matches!(c, Color::Rgb { .. }));
        assert_near(c.alpha(), 1.0, "alpha");
    }

    #[test]
    fn color_hsb_constructor() {
        let c = Color::hsb(120.0, 0.5, 0.8);
        assert!(matches!(c, Color::Hsb { .. }));
        assert_near(c.alpha(), 1.0, "alpha");
    }

    #[test]
    fn color_cmyk_constructor() {
        let c = Color::cmyk(0.1, 0.2, 0.3, 0.4);
        assert!(matches!(c, Color::Cmyk { .. }));
        assert_near(c.alpha(), 1.0, "alpha");
    }

    #[test]
    fn color_new_creates_rgb() {
        let c = Color::new(0.1, 0.2, 0.3, 0.5);
        assert!(matches!(c, Color::Rgb { .. }));
        assert_near(c.alpha(), 0.5, "alpha");
    }

    // -- RGB identity --

    #[test]
    fn rgb_to_rgba_identity() {
        let c = Color::new(0.2, 0.4, 0.6, 0.8);
        let (r, g, b, a) = c.to_rgba();
        assert_near(r, 0.2, "r");
        assert_near(g, 0.4, "g");
        assert_near(b, 0.6, "b");
        assert_near(a, 0.8, "a");
    }

    // -- RGB → HSB --

    #[test]
    fn rgb_black_to_hsb() {
        let (h, s, b, _) = Color::BLACK.to_hsba();
        assert_near(h, 0.0, "h");
        assert_near(s, 0.0, "s");
        assert_near(b, 0.0, "b");
    }

    #[test]
    fn rgb_white_to_hsb() {
        let (h, s, b, _) = Color::WHITE.to_hsba();
        assert_near(h, 0.0, "h");
        assert_near(s, 0.0, "s");
        assert_near(b, 1.0, "b");
    }

    #[test]
    fn rgb_red_to_hsb() {
        let (h, s, b, _) = Color::rgb(1.0, 0.0, 0.0).to_hsba();
        assert_near(h, 0.0, "h");
        assert_near(s, 1.0, "s");
        assert_near(b, 1.0, "b");
    }

    #[test]
    fn rgb_green_to_hsb() {
        let (h, s, b, _) = Color::rgb(0.0, 1.0, 0.0).to_hsba();
        assert_near(h, 120.0, "h");
        assert_near(s, 1.0, "s");
        assert_near(b, 1.0, "b");
    }

    #[test]
    fn rgb_blue_to_hsb() {
        let (h, s, b, _) = Color::rgb(0.0, 0.0, 1.0).to_hsba();
        assert_near(h, 240.0, "h");
        assert_near(s, 1.0, "s");
        assert_near(b, 1.0, "b");
    }

    #[test]
    fn rgb_yellow_to_hsb() {
        let (h, s, b, _) = Color::rgb(1.0, 1.0, 0.0).to_hsba();
        assert_near(h, 60.0, "h");
        assert_near(s, 1.0, "s");
        assert_near(b, 1.0, "b");
    }

    // -- HSB → RGB --

    #[test]
    fn hsb_red_to_rgb() {
        let (r, g, b, _) = Color::hsb(0.0, 1.0, 1.0).to_rgba();
        assert_near(r, 1.0, "r");
        assert_near(g, 0.0, "g");
        assert_near(b, 0.0, "b");
    }

    #[test]
    fn hsb_green_to_rgb() {
        let (r, g, b, _) = Color::hsb(120.0, 1.0, 1.0).to_rgba();
        assert_near(r, 0.0, "r");
        assert_near(g, 1.0, "g");
        assert_near(b, 0.0, "b");
    }

    #[test]
    fn hsb_blue_to_rgb() {
        let (r, g, b, _) = Color::hsb(240.0, 1.0, 1.0).to_rgba();
        assert_near(r, 0.0, "r");
        assert_near(g, 0.0, "g");
        assert_near(b, 1.0, "b");
    }

    #[test]
    fn hsb_black_to_rgb() {
        let (r, g, b, _) = Color::hsb(0.0, 0.0, 0.0).to_rgba();
        assert_near(r, 0.0, "r");
        assert_near(g, 0.0, "g");
        assert_near(b, 0.0, "b");
    }

    #[test]
    fn hsb_white_to_rgb() {
        let (r, g, b, _) = Color::hsb(0.0, 0.0, 1.0).to_rgba();
        assert_near(r, 1.0, "r");
        assert_near(g, 1.0, "g");
        assert_near(b, 1.0, "b");
    }

    // -- RGB → CMYK --

    #[test]
    fn rgb_black_to_cmyk() {
        let (c, m, y, k, _) = Color::BLACK.to_cmyka();
        assert_near(c, 0.0, "c");
        assert_near(m, 0.0, "m");
        assert_near(y, 0.0, "y");
        assert_near(k, 1.0, "k");
    }

    #[test]
    fn rgb_white_to_cmyk() {
        let (c, m, y, k, _) = Color::WHITE.to_cmyka();
        assert_near(c, 0.0, "c");
        assert_near(m, 0.0, "m");
        assert_near(y, 0.0, "y");
        assert_near(k, 0.0, "k");
    }

    #[test]
    fn rgb_red_to_cmyk() {
        let (c, m, y, k, _) = Color::rgb(1.0, 0.0, 0.0).to_cmyka();
        assert_near(c, 0.0, "c");
        assert_near(m, 1.0, "m");
        assert_near(y, 1.0, "y");
        assert_near(k, 0.0, "k");
    }

    // -- CMYK → RGB --

    #[test]
    fn cmyk_black_to_rgb() {
        let (r, g, b, _) = Color::cmyk(0.0, 0.0, 0.0, 1.0).to_rgba();
        assert_near(r, 0.0, "r");
        assert_near(g, 0.0, "g");
        assert_near(b, 0.0, "b");
    }

    #[test]
    fn cmyk_white_to_rgb() {
        let (r, g, b, _) = Color::cmyk(0.0, 0.0, 0.0, 0.0).to_rgba();
        assert_near(r, 1.0, "r");
        assert_near(g, 1.0, "g");
        assert_near(b, 1.0, "b");
    }

    #[test]
    fn cmyk_red_to_rgb() {
        let (r, g, b, _) = Color::cmyk(0.0, 1.0, 1.0, 0.0).to_rgba();
        assert_near(r, 1.0, "r");
        assert_near(g, 0.0, "g");
        assert_near(b, 0.0, "b");
    }

    // -- Round-trip tests --

    #[test]
    fn rgb_hsb_roundtrip() {
        let orig = Color::rgb(0.3, 0.6, 0.9);
        let (h, s, br, a) = orig.to_hsba();
        let back = Color::Hsb { h, s, b: br, a };
        let (r, g, b, _) = back.to_rgba();
        assert_near(r, 0.3, "r");
        assert_near(g, 0.6, "g");
        assert_near(b, 0.9, "b");
    }

    #[test]
    fn rgb_cmyk_roundtrip() {
        let orig = Color::rgb(0.3, 0.6, 0.9);
        let (c, m, y, k, a) = orig.to_cmyka();
        let back = Color::Cmyk { c, m, y, k, a };
        let (r, g, b, _) = back.to_rgba();
        assert_near(r, 0.3, "r");
        assert_near(g, 0.6, "g");
        assert_near(b, 0.9, "b");
    }

    #[test]
    fn hsb_rgb_roundtrip() {
        let orig = Color::hsb(210.0, 0.667, 0.9);
        let (r, g, b, a) = orig.to_rgba();
        let back = Color::Rgb { r, g, b, a };
        let (h, s, br, _) = back.to_hsba();
        assert_near(h, 210.0, "h");
        assert!((s - 0.667).abs() < 1e-3, "s: expected ~0.667, got {s}");
        assert_near(br, 0.9, "b");
    }

    #[test]
    fn cmyk_rgb_roundtrip() {
        // Round-trip is exact when min(C,M,Y) = 0.
        let orig = Color::cmyk(0.2, 0.4, 0.0, 0.3);
        let (r, g, b, a) = orig.to_rgba();
        let back = Color::Rgb { r, g, b, a };
        let (c, m, y, k, _) = back.to_cmyka();
        assert_near(c, 0.2, "c");
        assert_near(m, 0.4, "m");
        assert_near(y, 0.0, "y");
        assert_near(k, 0.3, "k");
    }

    #[test]
    fn cmyk_rgb_visual_equivalence() {
        // When min(C,M,Y)>0, CMYK→RGB→CMYK may shift values
        // but the visual RGB color must be preserved.
        let orig = Color::cmyk(0.2, 0.4, 0.1, 0.3);
        let (r1, g1, b1, _) = orig.to_rgba();
        let (c, m, y, k, a) = orig.to_cmyka();
        let back = Color::Cmyk { c, m, y, k, a };
        let (r2, g2, b2, _) = back.to_rgba();
        assert_near(r1, r2, "r");
        assert_near(g1, g2, "g");
        assert_near(b1, b2, "b");
    }

    // -- Alpha preservation --

    #[test]
    fn hsb_preserves_alpha() {
        let c = Color::Hsb { h: 180.0, s: 0.5, b: 0.8, a: 0.3 };
        let (_, _, _, a) = c.to_rgba();
        assert_near(a, 0.3, "alpha");
    }

    #[test]
    fn cmyk_preserves_alpha() {
        let c = Color::Cmyk { c: 0.1, m: 0.2, y: 0.3, k: 0.4, a: 0.7 };
        let (_, _, _, a) = c.to_rgba();
        assert_near(a, 0.7, "alpha");
    }

    // -- HSB identity --

    #[test]
    fn hsb_to_hsba_identity() {
        let c = Color::Hsb { h: 123.0, s: 0.45, b: 0.67, a: 0.89 };
        let (h, s, b, a) = c.to_hsba();
        assert_near(h, 123.0, "h");
        assert_near(s, 0.45, "s");
        assert_near(b, 0.67, "b");
        assert_near(a, 0.89, "a");
    }

    // -- CMYK identity --

    #[test]
    fn cmyk_to_cmyka_identity() {
        let c = Color::Cmyk { c: 0.1, m: 0.2, y: 0.3, k: 0.4, a: 0.5 };
        let (cv, m, y, k, a) = c.to_cmyka();
        assert_near(cv, 0.1, "c");
        assert_near(m, 0.2, "m");
        assert_near(y, 0.3, "y");
        assert_near(k, 0.4, "k");
        assert_near(a, 0.5, "a");
    }

    #[test]
    fn color_with_alpha_rgb() {
        let c = Color::rgb(1.0, 0.0, 0.0).with_alpha(0.5);
        assert_eq!(c, Color::Rgb { r: 1.0, g: 0.0, b: 0.0, a: 0.5 });
    }

    #[test]
    fn color_with_alpha_hsb() {
        let c = Color::hsb(180.0, 1.0, 1.0).with_alpha(0.3);
        assert_eq!(c, Color::Hsb { h: 180.0, s: 1.0, b: 1.0, a: 0.3 });
    }

    #[test]
    fn color_with_alpha_cmyk() {
        let c = Color::cmyk(0.0, 1.0, 1.0, 0.0).with_alpha(0.7);
        assert_eq!(c, Color::Cmyk { c: 0.0, m: 1.0, y: 1.0, k: 0.0, a: 0.7 });
    }

    #[test]
    fn fill_default_opacity() {
        assert_eq!(Fill::new(Color::BLACK).opacity, 1.0);
    }

    #[test]
    fn stroke_default_opacity() {
        assert_eq!(Stroke::new(Color::BLACK, 1.0).opacity, 1.0);
    }

    // --- with_fill / with_stroke ---

    #[test]
    fn with_fill_sets_fill_on_rect() {
        let r = rect(10.0, 20.0, 100.0, 50.0);
        let red_fill = Some(Fill::new(Color::rgb(1.0, 0.0, 0.0)));
        let r2 = with_fill(&r, red_fill);
        assert_eq!(r2.fill(), Some(&Fill::new(Color::rgb(1.0, 0.0, 0.0))));
    }

    #[test]
    fn with_fill_on_line_is_noop() {
        let line = Element::Line(LineElem {
            x1: 0.0, y1: 0.0, x2: 100.0, y2: 100.0,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            width_points: Vec::new(),
            common: CommonProps::default(),
                    stroke_gradient: None,
        });
        let red_fill = Some(Fill::new(Color::rgb(1.0, 0.0, 0.0)));
        let line2 = with_fill(&line, red_fill);
        // Line has no fill field, so it should be unchanged
        assert_eq!(line2.fill(), None);
    }

    #[test]
    fn with_stroke_sets_stroke_on_path() {
        let path = Element::Path(PathElem {
            d: vec![],
            fill: None,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            width_points: Vec::new(),
            common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
            stroke_brush: None,
            stroke_brush_overrides: None,
        });
        let blue_stroke = Some(Stroke::new(Color::rgb(0.0, 0.0, 1.0), 2.0));
        let path2 = with_stroke(&path, blue_stroke);
        assert_eq!(path2.stroke(), Some(&Stroke::new(Color::rgb(0.0, 0.0, 1.0), 2.0)));
    }

    #[test]
    fn with_fill_on_group_is_noop() {
        let group = Element::Group(GroupElem {
            children: vec![],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let red_fill = Some(Fill::new(Color::rgb(1.0, 0.0, 0.0)));
        let group2 = with_fill(&group, red_fill);
        assert_eq!(group2.fill(), None);
    }

    #[test]
    fn with_stroke_none_clears_stroke() {
        let r = rect(10.0, 20.0, 100.0, 50.0);
        // First give it a stroke
        let r2 = with_stroke(&r, Some(Stroke::new(Color::BLACK, 1.0)));
        assert!(r2.stroke().is_some());
        // Now clear it
        let r3 = with_stroke(&r2, None);
        assert_eq!(r3.stroke(), None);
    }

    // --- Color::to_hex / Color::from_hex ---

    #[test]
    fn color_to_hex_black() {
        assert_eq!(Color::BLACK.to_hex(), "000000");
    }

    #[test]
    fn color_to_hex_red() {
        assert_eq!(Color::rgb(1.0, 0.0, 0.0).to_hex(), "ff0000");
    }

    #[test]
    fn color_to_hex_white() {
        assert_eq!(Color::WHITE.to_hex(), "ffffff");
    }

    #[test]
    fn color_from_hex_valid() {
        let c = Color::from_hex("ff0000").unwrap();
        let (r, g, b, _) = c.to_rgba();
        assert_eq!(r, 1.0);
        assert_eq!(g, 0.0);
        assert_eq!(b, 0.0);
    }

    #[test]
    fn color_from_hex_with_hash() {
        let c = Color::from_hex("#00ff00").unwrap();
        let (r, g, b, _) = c.to_rgba();
        assert_eq!(r, 0.0);
        assert_near(g, 1.0, "green");
        assert_eq!(b, 0.0);
    }

    #[test]
    fn color_from_hex_invalid_returns_none() {
        assert!(Color::from_hex("xyz").is_none());
        assert!(Color::from_hex("").is_none());
        assert!(Color::from_hex("gg0000").is_none());
    }

    #[test]
    fn color_hex_roundtrip() {
        let c = Color::rgb(0.5019607843137255, 0.25098039215686274, 0.7529411764705882);
        let hex = c.to_hex();
        let c2 = Color::from_hex(&hex).unwrap();
        let (r1, g1, b1, _) = c.to_rgba();
        let (r2, g2, b2, _) = c2.to_rgba();
        assert!((r1 - r2).abs() < 0.004);
        assert!((g1 - g2).abs() < 0.004);
        assert!((b1 - b2).abs() < 0.004);
    }

    #[test]
    fn element_serde_roundtrip_layer() {
        let elem = Element::Layer(LayerElem {
            name: "Layer 1".into(),
            children: Vec::new(),
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps { opacity: 0.75, mode: BlendMode::Normal,
                                  transform: None, locked: true,
                                  visibility: Visibility::Outline, mask: None,
                                  tool_origin: None },
        });
        let json = serde_json::to_value(&elem).unwrap();
        let back: Element = serde_json::from_value(json).unwrap();
        assert_eq!(elem, back);
    }

    #[test]
    fn element_serde_roundtrip_rect() {
        let elem = rect(10.0, 20.0, 30.0, 40.0);
        let json = serde_json::to_value(&elem).unwrap();
        let back: Element = serde_json::from_value(json).unwrap();
        assert_eq!(elem, back);
    }

    #[test]
    fn element_serde_roundtrip_group_with_children() {
        use std::rc::Rc;
        let child = rect(0.0, 0.0, 10.0, 10.0);
        let group = Element::Group(GroupElem {
            children: vec![Rc::new(child)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let json = serde_json::to_value(&group).unwrap();
        let back: Element = serde_json::from_value(json).unwrap();
        assert_eq!(group, back);
    }

    // ── BlendMode ─────────────────────────────────────────────

    #[test]
    fn blend_mode_default_is_normal() {
        assert_eq!(BlendMode::default(), BlendMode::Normal);
    }

    #[test]
    fn blend_mode_has_sixteen_variants() {
        let all = [
            BlendMode::Normal,
            BlendMode::Darken, BlendMode::Multiply, BlendMode::ColorBurn,
            BlendMode::Lighten, BlendMode::Screen, BlendMode::ColorDodge,
            BlendMode::Overlay, BlendMode::SoftLight, BlendMode::HardLight,
            BlendMode::Difference, BlendMode::Exclusion,
            BlendMode::Hue, BlendMode::Saturation, BlendMode::Color, BlendMode::Luminosity,
        ];
        assert_eq!(all.len(), 16);
    }

    #[test]
    fn blend_mode_serde_uses_snake_case() {
        let json = serde_json::to_value(BlendMode::ColorBurn).unwrap();
        assert_eq!(json, serde_json::json!("color_burn"));
        let back: BlendMode = serde_json::from_value(serde_json::json!("soft_light")).unwrap();
        assert_eq!(back, BlendMode::SoftLight);
    }

    #[test]
    fn blend_mode_serde_roundtrip_all_variants() {
        for mode in [
            BlendMode::Normal,
            BlendMode::Darken, BlendMode::Multiply, BlendMode::ColorBurn,
            BlendMode::Lighten, BlendMode::Screen, BlendMode::ColorDodge,
            BlendMode::Overlay, BlendMode::SoftLight, BlendMode::HardLight,
            BlendMode::Difference, BlendMode::Exclusion,
            BlendMode::Hue, BlendMode::Saturation, BlendMode::Color, BlendMode::Luminosity,
        ] {
            let json = serde_json::to_value(mode).unwrap();
            let back: BlendMode = serde_json::from_value(json).unwrap();
            assert_eq!(mode, back);
        }
    }

    // ── CommonProps.mode ──────────────────────────────────────

    #[test]
    fn common_props_default_mode_is_normal() {
        let c = CommonProps::default();
        assert_eq!(c.mode, BlendMode::Normal);
    }

    #[test]
    fn element_mode_accessor_returns_default() {
        let r = rect(0.0, 0.0, 10.0, 10.0);
        assert_eq!(r.mode(), BlendMode::Normal);
    }

    #[test]
    fn common_props_serde_defaults_mode_when_missing() {
        let json = serde_json::json!({
            "opacity": 0.5,
            "transform": null,
            "locked": false,
            "visibility": "Preview",
        });
        let c: CommonProps = serde_json::from_value(json).unwrap();
        assert_eq!(c.mode, BlendMode::Normal);
        assert_eq!(c.opacity, 0.5);
    }

    // ── Mask (Phase 3a storage) ─────────────────────────────

    fn make_square_mask() -> Mask {
        Mask {
            subtree: Box::new(rect(0.0, 0.0, 10.0, 10.0)),
            clip: true,
            invert: false,
            disabled: false,
            linked: true,
            unlink_transform: None,
        }
    }

    #[test]
    fn common_props_default_mask_is_none() {
        let c = CommonProps::default();
        assert!(c.mask.is_none());
    }

    #[test]
    fn mask_default_linked_true_disabled_false() {
        let json = serde_json::json!({
            "subtree": rect(0.0, 0.0, 5.0, 5.0),
            "clip": false,
            "invert": false,
        });
        let m: Mask = serde_json::from_value(json).unwrap();
        assert!(m.linked, "linked default should be true");
        assert!(!m.disabled, "disabled default should be false");
        assert!(m.unlink_transform.is_none());
    }

    #[test]
    fn mask_serde_roundtrip() {
        let m = make_square_mask();
        let json = serde_json::to_value(&m).unwrap();
        let back: Mask = serde_json::from_value(json).unwrap();
        assert_eq!(m, back);
    }

    #[test]
    fn element_with_mask_serde_roundtrip() {
        let elem = Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 20.0, height: 20.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
            common: CommonProps {
                opacity: 1.0,
                mode: BlendMode::Normal,
                transform: None,
                locked: false,
                visibility: Visibility::Preview,
                mask: Some(Box::new(make_square_mask())),
                tool_origin: None,
            },
                    fill_gradient: None,
            stroke_gradient: None,
        });
        let json = serde_json::to_value(&elem).unwrap();
        let back: Element = serde_json::from_value(json).unwrap();
        assert_eq!(elem, back);
        assert!(back.common().mask.is_some());
    }

    #[test]
    fn element_without_mask_deserializes_from_legacy_json() {
        // Legacy JSON without a `mask` key must still parse, with mask = None.
        let json = serde_json::json!({
            "Rect": {
                "x": 0.0, "y": 0.0, "width": 10.0, "height": 10.0,
                "rx": 0.0, "ry": 0.0,
                "fill": null, "stroke": null,
                "common": {
                    "opacity": 1.0,
                    "mode": "normal",
                    "transform": null,
                    "locked": false,
                    "visibility": "Preview"
                }
            }
        });
        let back: Element = serde_json::from_value(json).unwrap();
        assert!(back.common().mask.is_none());
    }

    #[test]
    fn element_serde_roundtrip_preserves_non_default_mode() {
        let elem = Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
            common: CommonProps {
                opacity: 1.0,
                mode: BlendMode::Multiply,
                transform: None,
                locked: false,
                visibility: Visibility::Preview,
                mask: None,
                tool_origin: None,
            },
                    fill_gradient: None,
            stroke_gradient: None,
        });
        let json = serde_json::to_value(&elem).unwrap();
        let back: Element = serde_json::from_value(json).unwrap();
        assert_eq!(elem, back);
        assert_eq!(back.mode(), BlendMode::Multiply);
    }
}
